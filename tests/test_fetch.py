"""Media fetch in the gateway (spec #42 F2): routes, queue, limits, spool handling and import.

A fake clock drives every timed rule; a test-written spool stands in for the worker and an
in-process fake Nextcloud for the files service. No network, no container.
"""

import asyncio
import json
import os
from pathlib import Path
import tempfile
import unittest
from types import SimpleNamespace
from urllib.parse import unquote

from aiohttp import ClientSession, web
from aiohttp.test_utils import TestClient, TestServer

from services.access import fetch as fetch_module
from services.access.fetch import Fetch, portable_stem, public_row, unique_name, check_link
from services.access.mutations import Mutations
from services.access.observe import route_class
from services.access.registry import Registry
from services.access.server import Gateway, safe_errors

import test_permanent_credentials as credentials

MP4 = b"\x00\x00\x00\x18ftypisom\x00\x00\x02\x00isomiso2" + b"\x00" * 100


class Clock:
    def __init__(self, now=1_800_000_000.0):
        self.now = now

    def __call__(self):
        return self.now

    def advance(self, seconds):
        self.now += seconds


class FakeNextcloud:
    """Files per account: {uid: {path below anj-cloud/: bytes, or None for a folder}}, temporary
    uploads at the user root per account ({uid: {name: bytes}}), PUT, MKCOL, MOVE, DELETE and a
    maintenance switch (503 to everything)."""

    def __init__(self):
        self.files = {}
        self.temps = {}
        self.next_id = 700
        self.drop_move = False
        self.puts = []          # (uid, temporary name) of every completed upload
        self.moves = []         # (uid, target)
        self.busy = 0           # answer this many requests with 503 (maintenance mode)
        self.busy_methods = None
        self.hold_put = None    # an asyncio.Event a PUT waits for (upload in progress)
        self.put_started = asyncio.Event()

    def tree(self, uid):
        return self.files.setdefault(uid, {"": None})

    def temp(self, uid):
        return self.temps.setdefault(uid, {})

    def multistatus(self, uid, entries, prefix):
        body = '<?xml version="1.0"?><d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">'
        for path, value in entries:
            folder = value is None
            href = "/remote.php/dav/files/%s/%s%s" % (uid, prefix + "/".join(p.replace(" ", "%20") for p in path.split("/")) if path else prefix,
                                                     "/" if folder and path else "")
            body += ("<d:response><d:href>%s</d:href><d:propstat><d:prop><d:resourcetype>%s</d:resourcetype>"
                     "<d:getcontentlength>%s</d:getcontentlength><oc:fileid>%d</oc:fileid></d:prop></d:propstat></d:response>"
                     % (href, "<d:collection/>" if folder else "", "" if folder else len(value), 1 + hash(path) % 999))
        return web.Response(status=207, body=(body + "</d:multistatus>").encode())

    def split(self, path):
        uid, _, rest = path.split("/remote.php/dav/files/", 1)[1].partition("/")
        rest = unquote(rest)
        if rest.startswith("anj-cloud"):
            return uid, "root", rest[len("anj-cloud/"):].strip("/") if rest.startswith("anj-cloud/") else ""
        return uid, "user", rest.strip("/")

    async def handle(self, request):
        if self.busy and (self.busy_methods is None or request.method in self.busy_methods):
            self.busy -= 1
            await request.read()
            return web.Response(status=503)
        uid, area, relative = self.split(request.path)
        tree, temps = self.tree(uid), self.temp(uid)
        if request.method == "PROPFIND":
            await request.read()
            if area == "user":
                if relative == "":
                    return self.multistatus(uid, [("", None)] + [(name, data) for name, data in temps.items()], "")
                return self.multistatus(uid, [(relative, temps[relative])], "") if relative in temps else web.Response(status=404)
            if relative not in tree:
                return web.Response(status=404)
            entries = [(relative, tree[relative])]
            if request.headers.get("Depth") == "1" and tree[relative] is None:
                prefix = relative + "/" if relative else ""
                entries += [(path, tree[path]) for path in tree
                            if path.startswith(prefix) and path != relative and "/" not in path[len(prefix):]]
            return self.multistatus(uid, entries, "anj-cloud/")
        if request.method == "MKCOL":
            assert area == "root"
            if relative in tree:
                return web.Response(status=405)
            tree[relative] = None
            return web.Response(status=201)
        if request.method == "PUT":
            assert area == "user" and "If-None-Match" not in request.headers  # only temporary uploads
            self.put_started.set()
            if self.hold_put is not None:
                await self.hold_put.wait()
            temps[relative] = await request.read()
            self.puts.append((uid, relative))
            return web.Response(status=201)
        if request.method == "MOVE":
            assert area == "user" and request.headers.get("Overwrite") == "F"
            _, _, target = self.split(request.headers["Destination"])
            if relative not in temps:
                return web.Response(status=404)
            parent = target.rpartition("/")[0]
            if parent not in tree or tree[parent] is not None:
                return web.Response(status=409)
            if target in tree:
                return web.Response(status=412)
            tree[target] = temps.pop(relative)
            self.moves.append((uid, target))
            if self.drop_move:
                self.drop_move = False
                request.transport.abort()
            return web.Response(status=201)
        if request.method == "DELETE":
            assert area == "user"
            return web.Response(status=204 if temps.pop(relative, None) is not None else 404)
        return web.Response(status=405)


class Stub:
    """The parts of the gateway Fetch uses, with a header naming the calling device."""

    def __init__(self, directory, clock, backend):
        self.registry = Registry(directory / "state", clock=clock)
        self.backend = backend
        self.mutations = Mutations(self)
        self.session = None

    def identity(self, request):
        identity = request.headers.get("X-Test-Device")
        if not identity:
            raise web.HTTPUnauthorized(text="Device certificate required")
        try:
            device = self.registry.device(identity)
            return self.registry.admit(device["fingerprint"], device["certificate_id"])
        except ValueError:
            raise web.HTTPForbidden(text="Device is not active") from None


def add_device(registry, identity, uid, rights="write"):
    with registry.db:
        registry.db.execute("INSERT INTO invitations(id,digest,uid,rights,expires,state) VALUES(?,?,?,?,?,'approved')",
                            ("inv-" + identity, "digest-" + identity, uid, rights, registry.clock() + 600))
        registry.db.execute("INSERT INTO devices(id,invitation,uid,rights,fingerprint,state,certificate,expires,token,token_id,certificate_id) "
                            "VALUES(?,?,?,?,?,'active','pem',?,?,?,?)", (identity, "inv-" + identity, uid, rights, "fp-" + identity,
                                                                         registry.clock() + 10 ** 7, "token-" + identity, "1", "leaf-" + identity))


class FetchTestCase(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary.name)
        self.clock = Clock()
        self.nextcloud = FakeNextcloud()
        backend = web.Application()
        backend.router.add_route("*", "/{path:.*}", self.nextcloud.handle)
        self.backend = TestServer(backend)
        await self.backend.start_server()
        self.gateway = Stub(self.directory, self.clock, str(self.backend.make_url("")).rstrip("/"))
        self.gateway.session = ClientSession()
        self.free = [0.5]
        self.fetch = Fetch(self.gateway, self.directory / "spool", disk=lambda path: SimpleNamespace(total=100, free=self.free[0] * 100),
                           tick=0.01)
        self.fetch.wakeup = asyncio.Event()

        async def sleep(seconds):  # waits in the import advance the fake clock
            self.clock.advance(seconds)
            await asyncio.sleep(0)
        self.fetch.sleep = sleep
        add_device(self.gateway.registry, "alice-1", "alice")
        add_device(self.gateway.registry, "alice-read", "alice", rights="read")
        add_device(self.gateway.registry, "bob-1", "bob")
        app = web.Application(middlewares=[safe_errors])
        self.fetch.add_routes(app.router)
        self.client = TestClient(TestServer(app))
        await self.client.start_server()
        self.boot = "0123456789abcdef"
        self.seq = 0
        self.beat()

    async def asyncTearDown(self):
        if self.fetch.import_task is not None:
            self.fetch.import_task.cancel()
            try:
                await self.fetch.import_task
            except BaseException:  # noqa: BLE001
                pass
        await self.client.close()
        await self.gateway.session.close()
        await self.backend.close()
        self.gateway.registry.db.close()
        self.temporary.cleanup()

    # The worker's side of the spool.

    def beat(self, job=None, boot=None, updating=False):
        self.seq += 1
        path = self.fetch.worker_dir / "heartbeat.json"
        path.write_text(json.dumps({"v": 1, "boot": boot or self.boot, "seq": self.seq, "job": job, "version": "2026.10.26",
                                    "updating": updating}))
        self.fetch.read_heartbeat()

    def status(self, dispatch, state, boot=None, **fields):
        (self.fetch.jobs / dispatch / "status.json").write_text(json.dumps({"v": 1, "boot": boot or self.boot, "state": state, **fields}))

    def staged(self, dispatch, kind="audio", data=MP4):
        (self.fetch.jobs / dispatch / ("media." + ("m4a" if kind == "audio" else "mp4"))).write_bytes(data)
        return len(data)

    async def call(self, method, path, device="alice-1", body=None):
        response = await self.client.request(method, path, headers={"X-Test-Device": device} if device else {},
                                             data=None if body is None else json.dumps(body))
        text = await response.text()
        return response.status, (json.loads(text) if text and response.content_type == "application/json" else None), response

    async def submit(self, urls, kind="audio", height=None, device="alice-1"):
        body = {"urls": urls, "kind": kind}
        if height:
            body["height"] = height
        status, answer, _ = await self.call("POST", "/v1/fetch/jobs", device, body)
        self.assertEqual(202, status, answer)
        return [row["id"] for row in reversed(answer["jobs"])]  # the answer is newest first

    def row(self, identity):
        return self.gateway.registry.fetch_job(identity)

    async def tick(self, beat=True):
        if beat:
            self.beat(job=self.heartbeat_job())
        await self.fetch.tick()

    def heartbeat_job(self):
        return None

    async def run_to(self, identity, state="done", steps=200):
        for _ in range(steps):
            await self.tick()
            if self.fetch.import_task is not None:
                await asyncio.sleep(0)
                try:
                    await asyncio.wait_for(asyncio.shield(self.fetch.import_task), 5)
                except Exception:  # noqa: BLE001
                    pass
            if self.row(identity)["state"] == state:
                return self.row(identity)
        self.fail("job %s never reached %s (at %s)" % (identity, state, self.row(identity)["state"]))

    async def finish_item(self, identity, title="Song", kind="audio", height=None, obtained=None):
        """Drive one dispatched job through a successful worker run to `done`."""
        await self.tick()
        row = self.row(identity)
        self.assertEqual("checking", row["state"])
        dispatch = row["dispatch"]
        self.status(dispatch, "downloading", title=title, percent=40.5, bytes=10)
        await self.tick()
        size = self.staged(dispatch, kind)
        self.status(dispatch, "staged", title=title, id="abc", size=size, height=obtained)
        return await self.run_to(identity)


class RouteTests(FetchTestCase):
    async def test_submit_list_shape_and_cache_control(self):
        status, answer, response = await self.call("POST", "/v1/fetch/jobs", body={"urls": [" https://media.example/a ", "http://media.example/b"],
                                                                                    "kind": "video", "height": 720})
        self.assertEqual(202, status)
        self.assertEqual("no-store", response.headers["Cache-Control"])
        rows = answer["jobs"]
        self.assertEqual(["http://media.example/b", "https://media.example/a"], [row["url"] for row in rows])
        self.assertEqual({"id", "state", "kind", "url", "title", "path", "message", "height", "submitted", "finished"}, set(rows[0]))
        self.assertEqual(("waiting", "video", 720, None, None), (rows[0]["state"], rows[0]["kind"], rows[0]["height"], rows[0]["path"], rows[0]["finished"]))
        status, listed, response = await self.call("GET", "/v1/fetch/jobs")
        self.assertEqual((200, "no-store"), (status, response.headers["Cache-Control"]))
        self.assertEqual([row["id"] for row in rows], [row["id"] for row in listed["jobs"]])

    async def test_refusals(self):
        cases = [({"urls": ["ftp://media.example/a"], "kind": "audio"}, 400), ({"urls": ["javascript:alert(1)"], "kind": "audio"}, 400),
                 ({"urls": ["https://user:pw@media.example/a"], "kind": "audio"}, 400), ({"urls": [], "kind": "audio"}, 400),
                 ({"urls": "https://media.example/a", "kind": "audio"}, 400), ({"urls": ["https://media.example/a"], "kind": "video"}, 400),
                 ({"urls": ["https://media.example/a"], "kind": "video", "height": 480}, 400),
                 ({"urls": ["https://media.example/a"], "kind": "video", "height": True}, 400),
                 ({"urls": ["https://media.example/a"], "kind": "photo"}, 400),
                 ({"urls": ["https://media.example/a"], "kind": "audio", "extra": 1}, 400),
                 ({"urls": ["https://media.example/%d" % n for n in range(51)], "kind": "audio"}, 400),
                 ({"urls": ["https://media.example/" + "a" * 2100], "kind": "audio"}, 400)]
        for body, expected in cases:
            status, answer, _ = await self.call("POST", "/v1/fetch/jobs", body=body)
            self.assertEqual(expected, status, body)
            self.assertNotIn("media.example", json.dumps(answer))
        status, _, _ = await self.call("POST", "/v1/fetch/jobs", "alice-read", {"urls": ["https://media.example/a"], "kind": "audio"})
        self.assertEqual(403, status)
        status, _, _ = await self.call("POST", "/v1/fetch/jobs", None, {"urls": ["https://media.example/a"], "kind": "audio"})
        self.assertEqual(401, status)
        status, _, _ = await self.call("GET", "/v1/fetch/jobs?x=1")
        self.assertEqual(400, status)
        self.assertEqual(1, len(await self.submit(["https://media.example/%d" % n for n in range(50)][:1])))
        self.assertEqual(50, len(await self.submit(["https://media.example/%d" % n for n in range(50)])))

    async def test_worker_down_fenced_disk_floor_and_account_cap(self):
        body = {"urls": ["https://media.example/a"], "kind": "audio"}
        self.clock.advance(fetch_module.WORKER_STALE + 1)
        self.assertEqual(503, (await self.call("POST", "/v1/fetch/jobs", body=body))[0])
        self.beat()
        self.gateway.registry.maintenance()
        self.assertEqual(503, (await self.call("POST", "/v1/fetch/jobs", body=body))[0])
        self.gateway.registry.recover()
        self.free[0] = 0.09
        status, answer, _ = await self.call("POST", "/v1/fetch/jobs", body=body)
        self.assertEqual((507, "Server storage is almost full."), (status, answer["error"]))
        self.free[0] = 0.5
        for _ in range(10):
            await self.submit(["https://media.example/%d" % n for n in range(50)])
        self.assertEqual(429, (await self.call("POST", "/v1/fetch/jobs", body=body))[0])
        self.assertEqual(202, (await self.call("POST", "/v1/fetch/jobs", "bob-1", body))[0])  # the cap is per account

    async def test_tenancy_delete_and_clear(self):
        mine = await self.submit(["https://media.example/a", "https://media.example/b"])
        theirs = await self.submit(["https://media.example/c"], device="bob-1")
        self.assertEqual(set(theirs), {row["id"] for row in (await self.call("GET", "/v1/fetch/jobs", "bob-1"))[1]["jobs"]})
        self.assertEqual(404, (await self.call("DELETE", "/v1/fetch/jobs/" + mine[0], "bob-1"))[0])
        self.assertEqual(404, (await self.call("DELETE", "/v1/fetch/jobs/nonexistent", "bob-1"))[0])
        self.assertEqual(403, (await self.call("DELETE", "/v1/fetch/jobs/" + mine[0], "alice-read"))[0])
        status, _, response = await self.call("DELETE", "/v1/fetch/jobs/" + mine[0])
        self.assertEqual((204, "no-store"), (status, response.headers["Cache-Control"]))
        self.assertEqual(("cancelled", "Cancelled."), (self.row(mine[0])["state"], self.row(mine[0])["message"]))
        self.assertEqual(204, (await self.call("DELETE", "/v1/fetch/jobs/" + mine[0]))[0])  # a finished row is removed
        self.assertIsNone(self.row(mine[0]))
        await self.call("DELETE", "/v1/fetch/jobs/" + mine[1])
        self.assertEqual(204, (await self.call("POST", "/v1/fetch/jobs/clear"))[0])
        self.assertEqual([], (await self.call("GET", "/v1/fetch/jobs"))[1]["jobs"])
        self.assertEqual("waiting", self.row(theirs[0])["state"])

    def test_route_class_and_absent_feature(self):
        self.assertEqual("fetch", route_class(SimpleNamespace(path="/v1/fetch/jobs/abc", method="DELETE")))
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        authority = credentials.Authority(Path(temporary.name))
        without = Gateway(Path(temporary.name) / "s1", "http://nextcloud", "https://gateway.test", authority.crt)
        paths = {resource.canonical for resource in without.public_app().router.resources()}
        self.assertFalse([path for path in paths if path.startswith("/v1/fetch")])
        without.registry.db.close()
        configured = Gateway(Path(temporary.name) / "s2", "http://nextcloud", "https://gateway.test", authority.crt,
                             fetch_spool=Path(temporary.name) / "spool")
        paths = {resource.canonical for resource in configured.public_app().router.resources()}
        self.assertTrue({"/v1/fetch/jobs", "/v1/fetch/jobs/clear", "/v1/fetch/jobs/{job_id}"} <= paths)
        configured.registry.db.close()


class QueueTests(FetchTestCase):
    async def test_one_at_a_time_and_accounts_alternate(self):
        alice = await self.submit(["https://media.example/a%d" % n for n in range(3)])
        self.clock.advance(5)
        bob = await self.submit(["https://media.example/b"], device="bob-1")
        order = []
        for _ in range(4):
            await self.tick()
            running = self.gateway.registry.fetch_running()
            self.assertEqual(1, len(running))
            order.append(running[0]["id"])
            await self.tick()  # still one running: nothing else is dispatched
            self.assertEqual(1, len(self.gateway.registry.fetch_running()))
            self.assertEqual(1, len(os.listdir(self.fetch.jobs)))
            self.clock.advance(10)
            await self.finish_item(running[0]["id"])
            self.clock.advance(1)
        self.assertEqual([alice[0], bob[0], alice[1], alice[2]], order)
        self.assertEqual([], os.listdir(self.fetch.jobs))

    async def test_request_written_for_the_worker(self):
        [identity] = await self.submit(["https://media.example/v?list=x"], "video", 1080)
        await self.tick()
        row = self.row(identity)
        request = json.loads((self.fetch.jobs / row["dispatch"] / "request.json").read_text())
        self.assertEqual({"v": 1, "url": "https://media.example/v?list=x", "kind": "video", "height": 1080, "expand": True}, request)
        self.assertEqual(0o2770, os.stat(self.fetch.jobs / row["dispatch"]).st_mode & 0o7777)
        self.assertEqual(0o640, os.stat(self.fetch.jobs / row["dispatch"] / "request.json").st_mode & 0o777)

    async def test_worker_codes_become_plain_sentences(self):
        for code, state, sentence in (("unsupported-format", "rejected", "This link has no format the Downloader supports yet."),
                                      ("too-long", "rejected", "This item is longer than 4 hours, the Downloader's limit."),
                                      ("too-large", "rejected", "This item is larger than 8 GiB, the Downloader's limit."),
                                      ("login-required", "failed", "This site requires signing in, which the Downloader doesn't support."),
                                      ("ERROR: /etc/passwd https://x", "failed", "The Downloader stopped unexpectedly.")):
            [identity] = await self.submit(["https://media.example/" + code[:5]])
            await self.tick()
            dispatch = self.row(identity)["dispatch"]
            self.status(dispatch, state, code=code)
            await self.tick()
            row = self.row(identity)
            self.assertEqual((state, sentence), (row["state"], row["message"]))
            self.assertIsNotNone(row["finished"])
            self.beat()  # the worker left the run
            await self.tick()
            self.assertEqual([], os.listdir(self.fetch.jobs))

    async def test_progress_title_and_invalid_status(self):
        [identity] = await self.submit(["https://media.example/a"])
        await self.tick()
        dispatch = self.row(identity)["dispatch"]
        self.status(dispatch, "downloading", title="A title", percent=42.7, bytes=5)
        await self.tick()
        row = public_row(self.row(identity))
        self.assertEqual(("downloading", 42, "A title"), (row["state"], row["percent"], row["title"]))
        (self.fetch.jobs / dispatch / "status.json").write_text('{"v": 1, "state": "downloading", "boot": "nothex"}')
        await self.tick()
        self.assertEqual(("failed", "The Downloader stopped unexpectedly."), (self.row(identity)["state"], self.row(identity)["message"]))

    async def test_stalled_and_over_long_runs_fail(self):
        [stalled, slow] = await self.submit(["https://media.example/a", "https://media.example/b"])
        await self.tick()
        dispatch = self.row(stalled)["dispatch"]
        self.status(dispatch, "downloading", percent=10.0, bytes=100)
        await self.tick()
        self.clock.advance(fetch_module.STALL_SECONDS - 1)
        await self.tick()
        self.assertEqual("downloading", self.row(stalled)["state"])
        self.clock.advance(1)
        await self.tick()
        self.assertEqual(("failed", "The download stopped making progress."), (self.row(stalled)["state"], self.row(stalled)["message"]))
        self.assertTrue((self.fetch.jobs / dispatch / "cancel").exists())
        self.beat()
        await self.tick()
        await self.tick()
        dispatch = self.row(slow)["dispatch"]
        for step in range(1, 40):
            self.clock.advance(300 - 1)
            self.status(dispatch, "downloading", percent=1.0, bytes=step)
            self.beat(job=dispatch)
            await self.tick()
            if self.row(slow)["state"] != "downloading":
                break
        self.assertEqual(("failed", "The download took longer than 3 hours."), (self.row(slow)["state"], self.row(slow)["message"]))
        self.assertGreaterEqual(self.clock() - self.row(slow)["started"], fetch_module.RUN_SECONDS)

    async def test_disk_floor_fails_the_head_job(self):
        [identity] = await self.submit(["https://media.example/a"])
        self.free[0] = 0.05
        await self.tick()
        self.assertEqual(("failed", "Server storage is almost full."), (self.row(identity)["state"], self.row(identity)["message"]))
        self.assertEqual([], os.listdir(self.fetch.jobs))

    async def test_revoked_device_fails_the_running_job_and_its_files_go(self):
        [identity] = await self.submit(["https://media.example/a"])
        await self.tick()
        dispatch = self.row(identity)["dispatch"]
        self.status(dispatch, "downloading", percent=10.0, bytes=1)
        (self.fetch.jobs / dispatch / "media.f1.mp4.part").write_bytes(b"partial")
        self.beat(job=dispatch)
        self.gateway.registry.disable("alice-1")
        await self.tick()
        self.assertEqual(("failed", "This device no longer has access."), (self.row(identity)["state"], self.row(identity)["message"]))
        self.beat(job=None)
        await self.tick()
        self.assertEqual([], os.listdir(self.fetch.jobs))

    async def test_worker_restart_requeues_once_then_fails(self):
        [identity] = await self.submit(["https://media.example/a"])
        await self.tick()
        self.status(self.row(identity)["dispatch"], "downloading", percent=10.0, bytes=1)
        await self.tick()
        self.boot = "fedcba9876543210"  # a new worker process
        await self.tick()
        row = self.row(identity)
        self.assertEqual(("waiting", 1, None), (row["state"], row["interrupted"], row["dispatch"]))
        await self.tick()
        dispatch = self.row(identity)["dispatch"]
        self.assertEqual("checking", self.row(identity)["state"])
        self.status(dispatch, "downloading", percent=5.0, bytes=1)
        await self.tick()
        self.boot = "0000000000000001"
        await self.tick()
        self.assertEqual(("failed", "The download was interrupted twice."), (self.row(identity)["state"], self.row(identity)["message"]))

    async def test_gateway_restart_requeues_a_running_job(self):
        [identity] = await self.submit(["https://media.example/a"])
        await self.tick()
        self.status(self.row(identity)["dispatch"], "downloading", percent=10.0, bytes=1)
        await self.tick()
        restarted = Fetch(self.gateway, self.directory / "spool", disk=self.fetch.disk, tick=0.01)
        restarted.recover()
        self.assertEqual(("waiting", 1), (self.row(identity)["state"], self.row(identity)["interrupted"]))

    async def test_playlist_expands_into_a_folder_capped(self):
        [identity] = await self.submit(["https://media.example/list"])
        await self.tick()
        dispatch = self.row(identity)["dispatch"]
        items = [{"url": "https://media.example/i%d" % n} for n in range(201)] + []
        self.status(dispatch, "playlist", title="Mix: Vol/1", id="PL1", items=items, more=True)
        await self.tick()
        row = self.row(identity)
        self.assertEqual(("done", "Added 200 items from this playlist; the rest were not added (at most 200).", "Music/Mix_ Vol_1"),
                         (row["state"], row["message"], row["destination"]))
        children = [r for r in self.gateway.registry.fetch_jobs("alice") if r["id"] != identity]
        self.assertEqual(200, len(children))
        self.assertTrue(all(r["folder"] == "Mix_ Vol_1" and not r["expand"] and r["state"] == "waiting" for r in children))
        # An item that turns out to be a playlist itself is not expanded again.
        await self.tick()
        child = self.gateway.registry.fetch_running()[0]
        self.status(child["dispatch"], "playlist", title="Nested", items=[{"url": "https://media.example/x"}])
        await self.tick()
        self.assertEqual("rejected", self.row(child["id"])["state"])

    async def test_playlist_within_the_account_cap(self):
        [identity] = await self.submit(["https://media.example/list"])
        for _ in range(9):
            await self.submit(["https://media.example/x%d" % n for n in range(50)])  # 451 unfinished
        await self.tick()
        dispatch = self.row(identity)["dispatch"]
        self.status(dispatch, "playlist", title="Big", items=[{"url": "https://media.example/i%d" % n} for n in range(150)])
        await self.tick()
        self.assertIn("too many downloads are waiting", self.row(identity)["message"])
        self.assertLessEqual(self.gateway.registry.fetch_unfinished("alice"), fetch_module.MAX_UNFINISHED)

    async def test_retention_and_sweep(self):
        [identity] = await self.submit(["https://media.example/a"])
        await self.call("DELETE", "/v1/fetch/jobs/" + identity)
        (self.fetch.jobs / ("ab" * 12)).mkdir()
        (self.fetch.jobs / "junk").write_text("x")
        (self.fetch.worker_dir / "stray").write_text("x")
        await self.tick()
        self.assertEqual([], os.listdir(self.fetch.jobs))
        self.assertEqual(["heartbeat.json"], os.listdir(self.fetch.worker_dir))
        self.clock.advance(7 * 24 * 3600 - 10)
        await self.tick()
        self.assertIsNotNone(self.row(identity))
        self.clock.advance(20)
        self.beat()
        await self.tick()
        self.assertIsNone(self.row(identity))


class ImportTests(FetchTestCase):
    async def test_audio_lands_in_music_with_portable_unique_names(self):
        tree = self.nextcloud.tree("alice")
        tree["Music"] = None
        tree["Music/Song_ One.m4a"] = b"existing"
        tree["Music/song_ one (2).m4a"] = b"case clash"
        [identity] = await self.submit(["https://media.example/a"])
        row = await self.finish_item(identity, title="Song: One")
        self.assertEqual(("Music/Song_ One (3).m4a", "Saved to Music."), (row["destination"], row["message"]))
        self.assertEqual(MP4, tree["Music/Song_ One (3).m4a"])
        self.assertEqual(1, len(self.gateway.registry.added_since("alice")["added"]))  # added time recorded
        self.assertEqual([], os.listdir(self.fetch.jobs))
        self.assertTrue(self.gateway.registry.mutation_ready())

    async def test_top_folder_created_and_height_obtained(self):
        [identity] = await self.submit(["https://media.example/v"], "video", 1080)
        row = await self.finish_item(identity, title="Clip", kind="video", obtained=720)
        self.assertEqual(("Videos/Clip.mp4", "Saved to Videos at 720p; 1080p was not available."), (row["destination"], row["message"]))
        self.assertEqual(720, public_row(row)["height"])
        self.assertIsNone(self.nextcloud.tree("alice")["Videos"])

    async def test_video_above_the_chosen_height_is_refused(self):
        [identity] = await self.submit(["https://media.example/v"], "video", 720)
        await self.tick()
        dispatch = self.row(identity)["dispatch"]
        self.status(dispatch, "staged", title="Clip", size=self.staged(dispatch, "video"), height=1080)
        await self.tick()
        self.assertEqual("rejected", self.row(identity)["state"])
        self.assertEqual([], self.nextcloud.puts)

    async def test_playlist_folder_reused_apart_from_case(self):
        tree = self.nextcloud.tree("alice")
        tree["Music"] = None
        tree["Music/mix_ vol_1"] = None
        [identity] = await self.submit(["https://media.example/list"])
        await self.tick()
        self.status(self.row(identity)["dispatch"], "playlist", title="Mix: Vol/1", items=[{"url": "https://media.example/i"}])
        await self.tick()
        [child] = [r["id"] for r in self.gateway.registry.fetch_jobs("alice") if r["id"] != identity]
        row = await self.finish_item(child, title="Track")
        self.assertEqual("Music/mix_ vol_1/Track.m4a", row["destination"])

    async def test_title_cannot_leave_its_folder_and_reserved_names_are_avoided(self):
        for title, expected in (("../../etc/passwd", "Music/_.._etc_passwd.m4a"), ("CON", "Music/CON_.m4a"),
                                ("", "Music/abc.m4a"), ("   ...  ", "Music/abc (2).m4a"), ("a\x00b‮c", "Music/abc (3).m4a")):
            [identity] = await self.submit(["https://media.example/t"])
            row = await self.finish_item(identity, title=title)
            self.assertEqual(expected, row["destination"], title)

    async def test_revoked_before_import_and_fenced_writes(self):
        [identity] = await self.submit(["https://media.example/a"])
        await self.tick()
        dispatch = self.row(identity)["dispatch"]
        self.status(dispatch, "staged", title="Song", size=self.staged(dispatch))
        self.gateway.registry.maintenance()
        for _ in range(3):
            await self.tick()
            await asyncio.sleep(0.02)
        self.assertEqual("placing", self.row(identity)["state"])  # waits while writes are fenced
        self.gateway.registry.recover()
        self.gateway.registry.disable("alice-1")
        row = await self.run_to(identity, "failed")
        self.assertEqual("This device no longer has access.", row["message"])
        await asyncio.sleep(0.05)
        self.assertEqual(([], {}), (self.nextcloud.moves, self.nextcloud.temp("alice")))  # nothing placed, temporary copy removed
        self.assertNotIn("Music/Song.m4a", self.nextcloud.tree("alice"))
        self.beat()
        await self.tick()
        self.assertEqual([], os.listdir(self.fetch.jobs))

    async def test_not_an_mp4_is_never_imported(self):
        [identity] = await self.submit(["https://media.example/a"])
        await self.tick()
        dispatch = self.row(identity)["dispatch"]
        self.status(dispatch, "staged", title="Song", size=self.staged(dispatch, data=b"<html>not media</html>"))
        row = await self.run_to(identity, "rejected")
        self.assertEqual("The downloaded file was not in the promised format.", row["message"])
        self.assertEqual([], self.nextcloud.puts)

    async def test_a_symlink_is_never_followed(self):
        secret = self.directory / "secret"
        secret.write_bytes(MP4)
        [identity] = await self.submit(["https://media.example/a"])
        await self.tick()
        dispatch = self.row(identity)["dispatch"]
        os.symlink(secret, self.fetch.jobs / dispatch / "media.m4a")
        os.symlink(secret, self.fetch.jobs / dispatch / "status.json")
        await self.tick()
        self.assertEqual("failed", self.row(identity)["state"])
        self.status(dispatch, "staged", title="x", size=len(MP4)) if (self.fetch.jobs / dispatch).exists() else None
        self.assertEqual([], self.nextcloud.puts)
        self.assertTrue(secret.exists())

    async def test_unknown_outcome_is_read_back(self):
        self.nextcloud.drop_move = True
        [identity] = await self.submit(["https://media.example/a"])
        row = await self.finish_item(identity, title="Song")
        self.assertEqual("Music/Song.m4a", row["destination"])
        self.assertEqual([("alice", "Music/Song.m4a")], self.nextcloud.moves)  # read back found it: no second move, no " (2)"
        self.assertTrue(self.gateway.registry.mutation_ready())

    async def test_placing_cannot_be_cancelled(self):
        [identity] = await self.submit(["https://media.example/a"])
        await self.tick()
        dispatch = self.row(identity)["dispatch"]
        self.gateway.registry.maintenance()
        self.status(dispatch, "staged", title="Song", size=self.staged(dispatch))
        await self.tick()
        self.assertEqual(409, (await self.call("DELETE", "/v1/fetch/jobs/" + identity))[0])
        self.gateway.registry.recover()


class ImportPhaseTests(FetchTestCase):
    """Review fixes 1-3 and 7 (PR #29)."""

    async def staged_job(self, title="Song"):
        [identity] = await self.submit(["https://media.example/a"])
        await self.tick()
        dispatch = self.row(identity)["dispatch"]
        self.status(dispatch, "staged", title=title, size=self.staged(dispatch))
        return identity, dispatch

    async def test_submit_during_an_import_is_accepted_and_only_maintenance_refuses(self):
        self.gateway.registry.mutation_begin("alice-1", "Music/x.m4a")  # an import or upload in flight
        self.assertEqual(202, (await self.call("POST", "/v1/fetch/jobs", body={"urls": ["https://media.example/a"], "kind": "audio"}))[0])
        self.gateway.registry.mutation_finish()
        self.gateway.registry.maintenance()
        status, answer, _ = await self.call("POST", "/v1/fetch/jobs", body={"urls": ["https://media.example/a"], "kind": "audio"})
        self.assertEqual((503, "The server is paused for maintenance. Try again later."), (status, answer["error"]))

    async def test_upload_runs_without_the_lock_then_one_move_under_it(self):
        self.nextcloud.hold_put = asyncio.Event()
        identity, dispatch = await self.staged_job()
        await self.tick()  # staged -> placing
        await self.tick()  # the import starts
        await asyncio.wait_for(self.nextcloud.put_started.wait(), 5)
        # Uploading: no lock, no fence, so any device's write goes ahead meanwhile.
        self.assertFalse(self.gateway.mutations.lock.locked())
        self.assertEqual("clear", self.gateway.registry.fence_state())
        async with self.gateway.mutations.lock:
            pass
        self.assertEqual("placing", self.row(identity)["state"])
        self.nextcloud.hold_put.set()
        row = await self.run_to(identity)
        self.assertEqual("Music/Song.m4a", row["destination"])
        self.assertEqual(([("alice", ".anj-fetch-%s.tmp" % dispatch)], [("alice", "Music/Song.m4a")], {}),
                         (self.nextcloud.puts, self.nextcloud.moves, self.nextcloud.temp("alice")))
        self.assertEqual(MP4, self.nextcloud.tree("alice")["Music/Song.m4a"])
        self.assertEqual(1, len(self.gateway.registry.added_since("alice")["added"]))

    async def test_restart_during_the_upload_leaves_no_fence_and_resumes(self):
        self.nextcloud.hold_put = asyncio.Event()
        identity, dispatch = await self.staged_job()
        await self.tick()  # staged -> placing
        await self.tick()  # the import starts
        await asyncio.wait_for(self.nextcloud.put_started.wait(), 5)
        self.fetch.import_task.cancel()  # the gateway stops mid-upload
        try:
            await self.fetch.import_task
        except asyncio.CancelledError:
            pass
        self.assertEqual("clear", self.gateway.registry.fence_state())
        self.nextcloud.hold_put.set()
        self.nextcloud.temp("alice")[".anj-fetch-%s.tmp" % ("ab" * 12)] = b"left by an older run"
        restarted = Fetch(self.gateway, self.directory / "spool", disk=self.fetch.disk, tick=0.01)
        restarted.sleep, restarted.wakeup = self.fetch.sleep, asyncio.Event()
        restarted.recover()
        self.assertEqual("placing", self.row(identity)["state"])  # resumes from the staged file
        await restarted.sweep_temps()
        self.assertEqual([], [name for name in self.nextcloud.temp("alice") if "abab" in name])
        self.fetch = restarted
        row = await self.run_to(identity)
        self.assertEqual("Music/Song.m4a", row["destination"])

    async def test_nextcloud_maintenance_is_waited_out(self):
        self.nextcloud.busy = 6
        identity, _ = await self.staged_job()
        row = await self.run_to(identity)
        self.assertEqual(("done", "Music/Song.m4a"), (row["state"], row["destination"]))
        self.assertTrue(self.gateway.registry.mutation_ready())

    async def test_maintenance_longer_than_two_hours_gives_up_and_cleans_up(self):
        self.nextcloud.busy = 10 ** 6
        self.nextcloud.busy_methods = {"MOVE", "PROPFIND", "MKCOL"}
        identity, _ = await self.staged_job()
        started = self.clock()
        row = await self.run_to(identity, "failed", steps=500)
        self.assertEqual("The file could not be saved to the cloud.", row["message"])
        self.assertGreaterEqual(self.clock() - started, fetch_module.BUSY_GIVE_UP)
        self.assertLess(self.clock() - started, fetch_module.BUSY_GIVE_UP + 2 * fetch_module.BUSY_MAX)
        await asyncio.sleep(0.05)
        self.assertEqual({}, self.nextcloud.temp("alice"))
        self.assertTrue(self.gateway.registry.mutation_ready())

    async def test_a_503_on_the_move_clears_the_fence(self):
        identity, _ = await self.staged_job()
        self.nextcloud.busy, self.nextcloud.busy_methods = 1, {"MOVE"}
        row = await self.run_to(identity)
        self.assertEqual("done", row["state"])
        self.assertTrue(self.gateway.registry.mutation_ready())

    async def test_no_answer_and_an_inconclusive_read_back_keep_the_fence(self):
        identity, _ = await self.staged_job()
        self.nextcloud.drop_move = True
        original = self.fetch.stat_url

        async def unknown(device, url):
            return None if url.endswith("Song.m4a") else await original(device, url)
        self.fetch.stat_url = unknown
        for _ in range(5):
            await self.tick()
            await asyncio.sleep(0.02)
        self.assertEqual("dispatched", self.gateway.registry.fence_state())  # house rule: unknown outcome
        self.assertEqual("placing", self.row(identity)["state"])
        self.fetch.stat_url = original
        self.gateway.registry.maintenance()
        self.gateway.registry.recover()  # the operator's recovery
        row = await self.run_to(identity)
        self.assertEqual("Music/Song.m4a", row["destination"])  # read back: already there, no second copy
        self.assertEqual(1, len(self.nextcloud.moves))

    async def test_a_deeply_nested_status_fails_the_job_not_the_queue(self):
        [identity] = await self.submit(["https://media.example/a"])
        await self.tick()
        (self.fetch.jobs / self.row(identity)["dispatch"] / "status.json").write_text("[" * 200000)
        await self.tick()
        self.assertEqual(("failed", "The Downloader stopped unexpectedly."), (self.row(identity)["state"], self.row(identity)["message"]))

    async def test_disk_floor_stops_a_running_download(self):
        [identity] = await self.submit(["https://media.example/a"])
        await self.tick()
        self.status(self.row(identity)["dispatch"], "downloading", percent=50.0, bytes=10)
        await self.tick()
        self.free[0] = 0.08
        await self.tick()
        self.assertEqual(("failed", "Server storage is almost full."), (self.row(identity)["state"], self.row(identity)["message"]))

    async def test_no_stall_while_merging_or_while_the_worker_updates(self):
        [identity] = await self.submit(["https://media.example/a"])
        await self.tick()
        dispatch = self.row(identity)["dispatch"]
        # The worker is updating yt-dlp and has not taken the job yet: no stall clock.
        for _ in range(4):
            self.clock.advance(200)
            self.beat(job=None, updating=True)
            await self.fetch.tick()
        self.assertEqual("checking", self.row(identity)["state"])
        self.beat(job=None)
        await self.fetch.tick()
        self.status(dispatch, "downloading", percent=99.0, bytes=1000, tick=0)
        await self.tick()
        for tick in range(1, 30):  # merging: no byte progress, tick moves every 20 s
            self.clock.advance(20)
            self.status(dispatch, "downloading", percent=99.0, bytes=1000, tick=tick)
            await self.tick()
        self.assertEqual("downloading", self.row(identity)["state"])
        self.clock.advance(fetch_module.STALL_SECONDS)
        await self.tick()
        self.assertEqual(("failed", "The download stopped making progress."), (self.row(identity)["state"], self.row(identity)["message"]))


class NamingTests(unittest.TestCase):
    def test_portable_stem(self):
        self.assertEqual("a_b_c_d", portable_stem("a/b\\c:d", "x"))
        self.assertEqual("x", portable_stem(" . . ", "x"))
        self.assertEqual(150, len(portable_stem("e" * 400, "x")))
        self.assertEqual(100, len(portable_stem("é" * 400, "x")))  # 200 bytes of UTF-8
        self.assertLessEqual(len(portable_stem("😀" * 150, "x").encode()), fetch_module.NAME_BYTES)
        self.assertEqual("NUL_.txt", portable_stem("NUL.txt", "x"))
        self.assertEqual("tab sep", portable_stem("tab\tsep", "x"))
        # Review fix 6: ZWNJ (Persian, Urdu, Indic) and ZWJ (joined emoji) are kept; bidi controls and the BOM go.
        persian = "\u0645\u06cc\u200c\u062e\u0648\u0627\u0647\u0645"
        family = "Family \U0001f468\u200d\U0001f469\u200d\U0001f467"
        self.assertEqual(persian, portable_stem(persian, "x"))
        self.assertEqual(family, portable_stem(family, "x"))
        self.assertEqual("\u0915\u094d\u200d\u0937", portable_stem("\u0915\u094d\u200d\u0937", "x"))
        self.assertEqual("abc", portable_stem("\ufeffa\u202eb\u2066c\u2069", "x"))

    def test_unique_name(self):
        self.assertEqual("A.m4a", unique_name("A", ".m4a", []))
        self.assertEqual("A (2).m4a", unique_name("A", ".m4a", ["a.M4A"]))
        self.assertEqual("Café (2).m4a", unique_name("Café", ".m4a", ["Café.m4a"]))

    def test_links(self):
        self.assertEqual("https://a.example/x?y=1#z", check_link(" https://a.example/x?y=1#z "))
        for bad in ("file:///etc/passwd", "https://", "https://a b", "https://a.example:99999/", "//a.example/x", None, 7):
            self.assertIsNone(check_link(bad), bad)


if __name__ == "__main__":
    unittest.main()
