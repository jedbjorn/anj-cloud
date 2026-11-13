"""Directory sharing between household users (spec #26, decisions #78, #79, #80).

The gateway's real public router runs over real mutual TLS with fixture CAs; Nextcloud is an
in-process fake that answers the OCS sharing and DAV calls the sharing component makes, the way
Nextcloud 33 does (checked against a throwaway stack: permissions 1/15, hidden shares of a
disabled owner, mounts under the recipient's Shared/).
"""

import asyncio
import base64
import json
import posixpath
from urllib.parse import parse_qs, quote, unquote

import aiohttp
from aiohttp import web
from aiohttp.test_utils import TestServer

import unittest

from gateway_harness import HOST, Harness
from test_permanent_credentials import Device, admin, leaf_id, pair, pem
from services.access.protocol import Rejection
from services.access.sharing import ShareError

ROUTES = [("GET", "/v1/household/users"), ("GET", "/v1/shares/outgoing"), ("GET", "/v1/shares/incoming"),
          ("POST", "/v1/shares"), ("PATCH", "/v1/shares/1"), ("DELETE", "/v1/shares/1"), ("DELETE", "/v1/shares/incoming/1"),
          ("POST", "/v1/shares/incoming/1/rename")]


def ocs(status, data=None, http=None):
    return web.json_response({"ocs": {"meta": {"statuscode": status}, "data": data if data is not None else []}},
                             status=http or (200 if status in (100, 200) else status))


class FakeShareCloud:
    """Per-user folders/files, OCS user shares, token auth and failure injection."""

    def __init__(self):
        self.tokens = {}
        self.disabled = set()
        self.folders = {}
        self.files = {}
        self.shares = {}
        self.next_id = 1
        self.fail = {}
        self.unconfined = False
        self.fail_incoming = set()  # users whose shared_with_me listing answers 500
        self.fail_owner_listing = set()  # users whose own (owner-side) share list answers 500
        self.owner_listing_reply = {}  # uid -> "404" or "not-a-list"
        self.owner_listing_delay = {}  # uid -> seconds before the owner list answers
        self.mutations = []
        self.moves = []  # (uid, from, to, status) of every mount MOVE
        self.move_status = None  # forced MOVE answer (refusal or 5xx)
        self.move_lands = None  # forced file_target after a MOVE (a mount that escapes)
        self.wrong_mount = False  # the folder at the share's target is not the shared folder
        self.fail_share_reads = False  # GET /shares/<id> answers 500
        self.dav_fail = {}  # method -> status, or "lost" (not applied), or a 5xx (applied, then 500)
        self.trash = {}  # uid -> owner folders deleted into the trash
        self.owner_moves = []
        self.gate = None
        self.server = None

    def user(self, uid, folders=(), files=()):
        self.tokens["token-" + uid] = uid
        self.folders[uid] = {"Shared", *folders}
        self.files[uid] = set(files)

    def caller(self, request):
        header = request.headers.get("Authorization", "")
        try:
            uid, token = base64.b64decode(header.split(" ", 1)[1]).decode().split(":", 1)
        except (IndexError, ValueError):
            return None
        return uid if self.tokens.get(token) == uid and uid not in self.disabled else None

    def visible(self, share):
        return share["uid_owner"] not in self.disabled

    def mount(self, recipient, path):
        name = posixpath.basename(path)
        taken = {share["file_target"] for share in self.shares.values() if share["share_with"] == recipient}
        target, n = "/anj-cloud/Shared/" + name, 2
        while target in taken:
            target, n = "/anj-cloud/Shared/%s (%d)" % (name, n), n + 1
        return "/outside/" + name if self.unconfined else target

    async def handle(self, request):
        uid = self.caller(request)
        if uid is None:
            return web.Response(status=401)
        path = request.path
        if path == "/ocs/v2.php/cloud/user":
            return ocs(200, {"id": uid})
        if path.startswith("/remote.php/dav/files/"):
            relative = path.split("/anj-cloud/", 1)[1].rstrip("/")
            mounts = {s["file_target"][len("/anj-cloud/"):]: s for s in self.shares.values() if s["share_with"] == uid and self.visible(s)}
            under = lambda root, v: v == root or v.startswith(root + "/")  # noqa: E731
            failure = self.dav_fail.pop(request.method, None)
            if request.method == "DELETE":  # The owner deletes a folder: into the trash, shares end.
                if isinstance(failure, int) and failure < 500:
                    return web.Response(status=failure)
                if failure == "lost":
                    return web.Response(status=500)
                if relative not in self.folders[uid]:
                    return web.Response(status=404)
                self.folders[uid] = {v for v in self.folders[uid] if not under(relative, v)}
                self.files[uid] = {v for v in self.files[uid] if not under(relative, v)}
                for key in [k for k, v in self.shares.items() if v["uid_owner"] == uid and under("/anj-cloud/" + relative, v["path"])]:
                    del self.shares[key]
                self.trash.setdefault(uid, []).append(relative)
                return web.Response(status=500 if failure else 204)
            if request.method == "MOVE" and relative in self.folders[uid]:  # The owner renames a folder.
                destination = unquote(request.headers["Destination"].split("/anj-cloud/", 1)[1].rstrip("/"))
                if isinstance(failure, int) and failure < 500:
                    return web.Response(status=failure)
                if failure == "lost":
                    return web.Response(status=500)
                if destination in self.folders[uid] | self.files[uid]:
                    return web.Response(status=412)
                renamed = lambda v: destination + v[len(relative):]  # noqa: E731
                self.folders[uid] = {renamed(v) if under(relative, v) else v for v in self.folders[uid]}
                self.files[uid] = {renamed(v) if under(relative, v) else v for v in self.files[uid]}
                for share in self.shares.values():
                    if share["uid_owner"] == uid and under("/anj-cloud/" + relative, share["path"]):
                        share["path"] = "/anj-cloud/" + renamed(share["path"][len("/anj-cloud/"):])
                self.owner_moves.append((uid, relative, destination))
                return web.Response(status=500 if failure else 201)
            if request.method == "MOVE":
                share = mounts.get(relative)
                destination = unquote(request.headers["Destination"].split("/anj-cloud/", 1)[1].rstrip("/"))
                status = self.move_status or (412 if destination in self.folders[uid] | self.files[uid] | set(mounts) else
                                              409 if posixpath.dirname(destination) not in self.folders[uid] else 201)
                if share is None:
                    status = 404
                if status == 201:
                    share["file_target"] = self.move_lands or "/anj-cloud/" + destination
                self.moves.append((uid, relative, destination, status))
                return web.Response(status=status)
            if request.headers.get("Depth") == "1":
                if relative and relative not in self.folders[uid]:
                    return web.Response(status=404)
                base = "/remote.php/dav/files/%s/anj-cloud/%s" % (uid, relative + "/" if relative else "")
                names = {p.split("/")[-1] for p in self.folders[uid] | self.files[uid] | set(mounts)
                         if p and posixpath.dirname(p) == relative}
                hrefs = [base] + [base + quote(name) + "/" for name in sorted(names)]
                return web.Response(status=207, body=('<?xml version="1.0"?><d:multistatus xmlns:d="DAV:">' + "".join(
                    "<d:response><d:href>%s</d:href></d:response>" % href for href in hrefs) + "</d:multistatus>").encode())
            if relative in self.folders[uid] or relative in mounts:
                kind = "<d:collection/>"
                share = mounts.get(relative)
                if share is not None:  # The mount's identity is the shared folder's (unless forced wrong).
                    kind += ('</d:resourcetype><oc:fileid>%s</oc:fileid><oc:owner-id>%s</oc:owner-id><d:getetag>%s</d:getetag>'
                             '<d:resourcetype>' % (share.get("file_source", "") if not self.wrong_mount else "999999",
                                                   share["uid_owner"], share.get("etag", '"e1"')))
            elif relative in self.files[uid]:
                kind = ""
            else:
                return web.Response(status=404)
            return web.Response(status=207, body=('<?xml version="1.0"?><d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns"><d:response><d:href>/x</d:href>'
                                                  '<d:propstat><d:prop><d:resourcetype>' + kind + '</d:resourcetype></d:prop>'
                                                  '<d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>').encode())
        base = "/ocs/v2.php/apps/files_sharing/api/v1/shares"
        if not path.startswith(base):
            return web.Response(status=404)
        share_id = path[len(base) + 1:] or None
        query = request.query
        if request.method == "GET":
            if share_id:
                if self.fail_share_reads:
                    return web.Response(status=500)
                share = self.shares.get(share_id)
                if not share or not self.visible(share) or uid not in (share["uid_owner"], share["share_with"]):
                    return ocs(404)
                return ocs(200, [share])
            if query.get("shared_with_me") == "true":
                if uid in self.fail_incoming:
                    return web.Response(status=500)
                return ocs(200, [s for s in self.shares.values() if s["share_with"] == uid and self.visible(s)])
            if "path" in query:
                relative = query["path"][len("/anj-cloud/"):]
                if relative not in self.folders[uid] | self.files[uid]:
                    return ocs(404)
                return ocs(200, [s for s in self.shares.values() if s["uid_owner"] == uid and s["path"] == query["path"]])
            if uid in self.fail_owner_listing:
                return web.Response(status=500)
            if uid in self.owner_listing_delay:
                await asyncio.sleep(self.owner_listing_delay[uid])
            if self.owner_listing_reply.get(uid) == "404":
                return ocs(404)
            if self.owner_listing_reply.get(uid) == "not-a-list":
                return ocs(200, {"unexpected": True})
            return ocs(200, [s for s in self.shares.values() if s["uid_owner"] == uid])
        if self.gate is not None:
            await self.gate.wait()
        form = parse_qs(await request.text())
        self.mutations.append((request.method, share_id, uid))
        failure = self.fail.pop(request.method, None)
        if isinstance(failure, int) and failure < 500:
            return ocs(failure)
        if failure == "lost":  # The connection drops before the backend applied anything.
            return web.Response(status=500)
        if failure == "garbled":  # HTTP 200 without an OCS status, nothing applied.
            return web.Response(status=200, text="<html>proxy page</html>")
        if request.method == "POST":
            recipient = form["shareWith"][0]
            if recipient not in self.folders:
                return ocs(404)
            share_id = str(self.next_id)
            self.next_id += 1
            self.shares[share_id] = {"id": share_id, "share_type": 0, "uid_owner": uid, "share_with": recipient, "item_type": "folder",
                                     "path": form["path"][0], "permissions": int(form["permissions"][0]),
                                     "file_target": self.mount(recipient, form["path"][0]), "file_source": 1000 + int(share_id)}
            result = self.shares[share_id]
        else:
            share = self.shares.get(share_id)
            # The recipient may delete a user share made to them (leave it); only the owner changes it.
            if not share or uid not in ((share["uid_owner"], share["share_with"]) if request.method == "DELETE" else (share["uid_owner"],)):
                return ocs(404)
            if request.method == "PUT":
                share["permissions"] = int(form["permissions"][0])
                result = share
            else:
                del self.shares[share_id]
                result = []
        if failure is not None:  # 5xx after applying: the gateway cannot know the outcome.
            return web.Response(status=failure)
        return ocs(200, result)

    async def start(self):
        app = web.Application()
        app.router.add_route("*", "/{path:.*}", self.handle)
        self.server = TestServer(app)
        await self.server.start_server()
        return str(self.server.make_url("")).rstrip("/")


class SharingTests(unittest.IsolatedAsyncioTestCase):
    """The real gateway application behind the real edge (spec #20 harness), TCP listener."""

    async def asyncSetUp(self):
        self.harness = Harness(listener="tcp")
        await self.harness.start()
        self.gateway, self.authority, self.port = self.harness.gateway, self.harness.authority, self.harness.port
        self.cloud = FakeShareCloud()
        self.cloud.user("alice", folders={"Photos", "Photos/2024", "Docs"}, files={"notes.txt", "Photos/a.jpg"})
        self.cloud.user("bob", folders={"Work"})
        self.cloud.user("carol")
        self.gateway.backend = await self.cloud.start()
        registry = self.gateway.registry
        for uid, name in (("alice", "Alice"), ("bob", "Bob"), ("carol", "Carol")):
            registry.account_set(uid, name)
        self.alice, self.bob = Device(), Device()
        self.alice_id, self.alice_leaf = pair(registry, self.authority, self.alice, "alice")
        self.bob_id, self.bob_leaf = pair(registry, self.authority, self.bob, "bob")

    async def asyncTearDown(self):
        await self.cloud.server.close()
        await self.harness.stop()

    def as_alice(self):
        return self.alice, self.alice_leaf

    def as_bob(self):
        return self.bob, self.bob_leaf

    async def call(self, method, path, who=None, body=None, raw=None):
        context = self.harness.client_context(*(who or ()))
        data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
        async with aiohttp.ClientSession(connector=aiohttp.TCPConnector(ssl=context), trust_env=False) as session:
            async with session.request(method, "https://127.0.0.1:%d%s" % (self.port, path), data=data, allow_redirects=False,
                                       server_hostname=HOST,
                                       headers={"Content-Type": "application/json"} if data is not None else {}) as response:
                text = await response.text()
                try:
                    parsed = json.loads(text)
                except ValueError:
                    parsed = text
                return response.status, parsed, response.headers

    def legacy_view(self, share_id):
        """A View only share made before decision #155 (one access level)."""
        self.cloud.shares[share_id]["permissions"] = 1

    async def share(self, path="Photos", recipient="bob", permission="edit", who=None):
        return await self.call("POST", "/v1/shares", who or self.as_alice(), {"path": path, "recipient_id": recipient, "permission": permission})

    # Logs (spec #26 Gateway API 5): route class "share", never a path, folder or display name.

    async def test_share_requests_log_the_share_route_class_without_names_or_paths(self):
        await self.share()
        await self.share("Photos/2024", "carol")
        await self.call("GET", "/v1/shares/outgoing", self.as_alice())
        await self.call("GET", "/v1/shares/incoming", self.as_bob())
        await self.call("GET", "/v1/household/users", self.as_bob())
        self.legacy_view("1")
        await self.call("PATCH", "/v1/shares/1", self.as_alice(), {"permission": "edit"})
        await self.call("DELETE", "/v1/shares/1", self.as_alice())
        await self.share("Missing")
        lines = self.harness.requests(route="share")
        self.assertEqual(8, len(lines))
        self.assertEqual({"GET", "POST", "PATCH", "DELETE"}, {line["method"] for line in lines})
        text = self.harness.stream.getvalue()
        for secret in ("Photos", "2024", "Missing", "Alice", "Bob", "Carol", "/v1/shares", "token-"):
            self.assertNotIn(secret, text)

    # Endpoint scoping.

    async def test_every_sharing_route_requires_a_client_certificate(self):
        for method, path in ROUTES:
            status, _, _ = await self.call(method, path, body={} if method in ("POST", "PATCH") else None)
            self.assertEqual(401, status, path)

    async def test_household_list_is_enabled_others_with_id_and_name_only(self):
        self.gateway.registry.account_set("carol", enabled=False)
        status, body, headers = await self.call("GET", "/v1/household/users", self.as_alice())
        self.assertEqual((200, [{"id": "bob", "display_name": "Bob"}], "no-store"), (status, body, headers["Cache-Control"]))
        status, body, _ = await self.call("GET", "/v1/household/users", self.as_bob())
        self.assertEqual([{"id": "alice", "display_name": "Alice"}], body)

    async def test_share_lifecycle_maps_permissions_and_scopes_lists_to_the_caller(self):
        status, row, headers = await self.share()
        self.assertEqual((201, "no-store"), (status, headers["Cache-Control"]))
        self.assertEqual({"share_id": "1", "path": "Photos", "recipient_id": "bob", "recipient_display_name": "Bob", "permission": "edit"}, row)
        self.assertEqual(15, self.cloud.shares["1"]["permissions"])
        # One access level (decision #155): View only is refused for new shares.
        status, body, _ = await self.share("Docs", "carol", "view")
        self.assertEqual((422, "Sharing has one level: full access"), (status, body["error"]))
        status, row, _ = await self.share("Docs", "carol")
        self.assertEqual((201, "edit"), (status, row["permission"]))
        self.legacy_view("2")
        _, outgoing, _ = await self.call("GET", "/v1/shares/outgoing", self.as_alice())
        self.assertEqual([("Docs", "carol", "view"), ("Photos", "bob", "edit")],
                         [(r["path"], r["recipient_id"], r["permission"]) for r in outgoing])
        _, others, _ = await self.call("GET", "/v1/shares/outgoing", self.as_bob())
        self.assertEqual([], others)
        _, incoming, _ = await self.call("GET", "/v1/shares/incoming", self.as_bob())
        self.assertEqual([{"share_id": "1", "path": "Shared/Photos", "owner_display_name": "Alice", "permission": "edit",
                           "owner_unavailable": False}], incoming)
        self.assertEqual(422, (await self.call("PATCH", "/v1/shares/1", self.as_alice(), {"permission": "view"}))[0])
        # A legacy View only share can be raised to full access (the migration path).
        status, row, _ = await self.call("PATCH", "/v1/shares/2", self.as_alice(), {"permission": "edit"})
        self.assertEqual((200, "edit", 15), (status, row["permission"], self.cloud.shares["2"]["permissions"]))
        status, body, _ = await self.call("DELETE", "/v1/shares/1", self.as_alice())
        self.assertEqual((200, {"state": "removed"}), (status, body))
        self.assertNotIn("1", self.cloud.shares)
        _, incoming, _ = await self.call("GET", "/v1/shares/incoming", self.as_bob())
        self.assertEqual([], incoming)
        self.assertTrue(self.gateway.registry.mutation_ready())

    async def test_foreign_or_unknown_share_ids_are_404_and_owner_fields_are_refused(self):
        await self.share()
        for method, body in (("PATCH", {"permission": "edit"}), ("DELETE", None)):
            for share_id in ("1", "99", "x", "1%2f2"):
                status, error, _ = await self.call(method, "/v1/shares/" + share_id, self.as_bob(), body)
                self.assertEqual(404, status, (method, share_id))
        self.assertEqual(15, self.cloud.shares["1"]["permissions"])
        status, _, _ = await self.call("POST", "/v1/shares", self.as_bob(),
                                       {"path": "Work", "recipient_id": "carol", "permission": "edit", "owner": "alice"})
        self.assertEqual(400, status)
        for raw in (b"{", b"[]", b'"x"'):
            status, _, _ = await self.call("POST", "/v1/shares", self.as_alice(), raw=raw)
            self.assertEqual(400, status)
        status, _, _ = await self.call("GET", "/v1/shares/outgoing?uid=bob", self.as_alice())
        self.assertEqual(400, status)
        status, _, _ = await self.share(permission="admin")
        self.assertEqual(400, status)
        self.assertEqual([("POST", None, "alice")], self.cloud.mutations)

    async def test_read_grant_device_lists_but_cannot_change_shares(self):
        reader = Device()
        invitation = self.gateway.registry.invite("alice", "read")
        pending = self.gateway.registry.enroll(invitation["code"], reader.csr)
        self.gateway.registry.begin(pending["pairing_id"], pending["fingerprint"])
        leaf = self.authority.leaf(reader.key.public_key(), pending["device_id"])
        self.gateway.registry.activate(pending["pairing_id"], pending["fingerprint"], "token-alice", "2", pem(leaf),
                                       leaf.not_valid_after_utc.timestamp(), leaf_id(leaf))
        await self.share()
        for method, path in ROUTES:
            status, body, _ = await self.call(method, path, (reader, leaf), {"permission": "edit"} if method == "PATCH" else
                                              ({"path": "Docs", "recipient_id": "bob", "permission": "edit"} if method == "POST" else None))
            self.assertEqual(200 if method == "GET" else 403, status, path)
        self.assertEqual(1, len(self.cloud.mutations))

    # Directory-only, household-only.

    async def test_only_owned_directories_and_household_recipients(self):
        for path, expected in (("", 422), ("Shared", 422), ("Shared/", 422), ("Shared/Photos", 422), ("notes.txt", 422),
                               ("Photos/a.jpg", 422), ("Missing", 404), ("../bob/Work", 400), ("/Photos", 400), ("Photos//x", 400)):
            status, body, _ = await self.share(path)
            self.assertEqual(expected, status, path)
            if path in ("notes.txt", "Photos/a.jpg", "Missing"):
                self.assertNotIn(path, json.dumps(body))
        self.gateway.registry.account_set("carol", enabled=False)
        for recipient in ("carol", "alice", "dave", "admin", None, 7):
            status, _, _ = await self.share(recipient=recipient)
            self.assertEqual(422, status, recipient)
        self.assertEqual(201, (await self.share("Photos/2024/"))[0])
        self.assertEqual(201, (await self.share())[0])
        status, body, _ = await self.share()
        self.assertEqual(409, status)
        self.assertNotIn("Photos", json.dumps(body))
        self.assertEqual(2, len(self.cloud.shares))

    async def test_documents_music_and_videos_are_private_but_folders_inside_them_are_not(self):
        # Spec #34 P4, decision #148 (ruling B).
        self.cloud.folders["alice"] |= {"Documents", "Music", "Videos", "Documents/Taxes", "Music/Live", "Videos/Trips"}
        for path in ("Documents", "Documents/", "Music", "Videos/"):
            status, body, _ = await self.share(path)
            self.assertEqual(422, status, path)
            self.assertEqual("Documents, Music and Videos are private", body["error"], path)
        self.assertEqual([], self.cloud.mutations)
        for path in ("Documents/Taxes", "Music/Live", "Videos/Trips", "Photos"):
            self.assertEqual(201, (await self.share(path))[0], path)
        self.assertEqual(4, len(self.cloud.shares))

    async def test_recipient_cannot_manage_an_incoming_share_or_share_inside_it(self):
        await self.share()
        status, _, _ = await self.share("Shared/Photos", "carol", who=self.as_bob())
        self.assertEqual(422, status)
        self.assertEqual(404, (await self.call("DELETE", "/v1/shares/1", self.as_bob()))[0])

    # Placement (spec #34 P6, decision #149).

    def private(self, uid, *folders):
        self.cloud.folders[uid] |= {"Documents", "Music", "Videos", *folders}

    async def incoming(self, who):
        status, rows, _ = await self.call("GET", "/v1/shares/incoming", who)
        self.assertEqual(200, status)
        return [(row["path"], row["owner_display_name"]) for row in rows]

    async def test_a_share_from_documents_arrives_in_the_recipients_documents(self):
        self.private("alice", "Documents/Taxes", "Music/Live", "Videos/Trips")
        self.private("bob")
        for path in ("Documents/Taxes", "Music/Live", "Videos/Trips", "Photos"):
            status, row, _ = await self.share(path)
            self.assertEqual((201, path), (status, row["path"]))
        self.assertEqual(["/anj-cloud/Documents/Taxes", "/anj-cloud/Music/Live", "/anj-cloud/Videos/Trips", "/anj-cloud/Shared/Photos"],
                         [share["file_target"] for share in self.cloud.shares.values()])
        self.assertEqual([("Documents/Taxes", "Alice"), ("Music/Live", "Alice"), ("Shared/Photos", "Alice"), ("Videos/Trips", "Alice")],
                         await self.incoming(self.as_bob()))
        self.assertEqual(["placed"] * 3, [r[0] for r in self.gateway.registry.db.execute("SELECT state FROM share_placement")])
        # The owner's side is unchanged: the owner's own path.
        _, outgoing, _ = await self.call("GET", "/v1/shares/outgoing", self.as_alice())
        self.assertEqual(["Documents/Taxes", "Music/Live", "Photos", "Videos/Trips"], [row["path"] for row in outgoing])

    async def test_a_taken_name_gets_the_owners_name_and_else_stays_in_shared(self):
        self.private("alice", "Documents/Taxes", "Documents/Notes", "Documents/Plans")
        # Bob's own Taxes, a case-only twin of Notes, and both names for Plans.
        self.private("bob", "Documents/Taxes", "Documents/NOTES", "Documents/Plans", "Documents/Plans (Alice)")
        for path in ("Documents/Taxes", "Documents/Notes", "Documents/Plans"):
            self.assertEqual(201, (await self.share(path))[0], path)
        self.assertEqual([("Documents/Notes (Alice)", "Alice"), ("Documents/Taxes (Alice)", "Alice"), ("Shared/Plans", "Alice")],
                         await self.incoming(self.as_bob()))
        self.assertEqual({"1": "placed", "2": "placed", "3": "kept"},
                         dict(self.gateway.registry.db.execute("SELECT share_id,state FROM share_placement").fetchall()))
        # Kept means kept: later reads never move it.
        self.cloud.folders["bob"] -= {"Documents/Plans"}
        await self.incoming(self.as_bob())
        self.assertEqual("/anj-cloud/Shared/Plans", self.cloud.shares["3"]["file_target"])

    async def test_an_owner_name_the_cloud_cannot_hold_falls_back_to_the_account_id(self):
        self.gateway.registry.account_set("alice", "Al\\The Best")
        self.private("alice", "Documents/Taxes")
        self.private("bob", "Documents/Taxes")
        await self.share("Documents/Taxes")
        self.assertEqual([("Documents/Taxes (alice)", "Al\\The Best")], await self.incoming(self.as_bob()))

    async def test_an_owner_name_other_devices_could_not_hold_is_used_as_it_is(self):
        # Spec #49 Gateway: Windows clients give it a local name; the cloud name keeps the colon.
        self.gateway.registry.account_set("alice", "Al: The Best")
        self.private("alice", "Documents/Taxes")
        self.private("bob", "Documents/Taxes")
        await self.share("Documents/Taxes")
        self.assertEqual([("Documents/Taxes (Al: The Best)", "Al: The Best")], await self.incoming(self.as_bob()))

    async def test_a_recipient_without_a_device_is_placed_at_their_first_incoming_read(self):
        self.private("alice", "Documents/Taxes")
        self.private("carol")
        self.assertEqual(201, (await self.share("Documents/Taxes", "carol"))[0])
        self.assertEqual("/anj-cloud/Shared/Taxes", self.cloud.shares["1"]["file_target"])
        self.assertEqual("pending", self.gateway.registry.placement("1")["state"])
        carol = Device()
        _, carol_leaf = pair(self.gateway.registry, self.authority, carol, "carol")
        self.assertEqual([("Documents/Taxes", "Alice")], await self.incoming((carol, carol_leaf)))
        self.assertEqual(("/anj-cloud/Documents/Taxes", "placed"),
                         (self.cloud.shares["1"]["file_target"], self.gateway.registry.placement("1")["state"]))

    async def test_a_refused_or_failed_move_keeps_the_share_in_shared(self):
        self.private("alice", "Documents/Taxes", "Documents/Notes")
        self.private("bob")
        self.cloud.move_status = 403
        self.assertEqual(201, (await self.share("Documents/Taxes"))[0])
        self.assertEqual("kept", self.gateway.registry.placement("1")["state"])
        self.cloud.move_status = 500  # Unknown outcome: both places are allowed; looked at again later.
        self.assertEqual(201, (await self.share("Documents/Notes"))[0])
        row = self.gateway.registry.placement("2")
        self.assertEqual(("pending", 1), (row["state"], row["attempts"]))
        self.assertTrue(self.gateway.registry.mutation_ready())
        self.cloud.move_status = None
        # Not before its backoff: no request at all for it.
        moves = len(self.cloud.moves)
        self.assertEqual([("Shared/Notes", "Alice"), ("Shared/Taxes", "Alice")], await self.incoming(self.as_bob()))
        self.assertEqual(moves, len(self.cloud.moves))
        self.gateway.registry.placement_retry("2", 1, 0)
        self.assertEqual([("Documents/Notes", "Alice"), ("Shared/Taxes", "Alice")], await self.incoming(self.as_bob()))

    async def test_placement_retries_are_bounded_then_the_share_stays_in_shared(self):
        from services.access import sharing
        self.private("alice", "Documents/Taxes")
        self.private("bob")
        self.cloud.move_status = 503
        await self.share("Documents/Taxes")
        for _ in range(sharing.PLACEMENT_ATTEMPTS):
            self.gateway.registry.placement_retry("1", self.gateway.registry.placement("1")["attempts"], 0)
            await self.incoming(self.as_bob())
        self.assertEqual("kept", self.gateway.registry.placement("1")["state"])
        self.assertEqual(sharing.PLACEMENT_ATTEMPTS, len(self.cloud.moves))
        self.assertTrue(self.gateway.registry.mutation_ready())

    async def test_only_a_write_grant_device_moves_the_mount(self):
        self.private("alice", "Documents/Taxes")
        self.private("bob")
        self.gateway.registry.db.execute("UPDATE devices SET rights='read' WHERE id=?", (self.bob_id,))
        self.gateway.registry.db.commit()
        await self.share("Documents/Taxes")
        self.assertEqual([("Shared/Taxes", "Alice")], await self.incoming(self.as_bob()))
        self.assertEqual(([], "pending"), (self.cloud.moves, self.gateway.registry.placement("1")["state"]))

    async def test_a_folder_that_is_not_this_shares_mount_is_never_moved(self):
        self.private("alice", "Documents/Taxes")
        self.private("bob")
        self.cloud.wrong_mount = True
        await self.share("Documents/Taxes")
        self.assertEqual([], self.cloud.moves)
        self.assertEqual(("pending", 1), (self.gateway.registry.placement("1")["state"], self.gateway.registry.placement("1")["attempts"]))

    async def test_a_recipient_side_cleanup_is_recorded_under_the_owner_and_repaired_in_one_step(self):
        self.private("alice", "Documents/Taxes")
        self.private("bob")
        self.cloud.move_lands = "/anj-cloud/Music/Taxes"
        self.cloud.fail["DELETE"] = 403
        status, body, _ = await self.share("Documents/Taxes")
        self.assertEqual(502, status)
        self.assertIn("operator repair", body["error"])
        fences = await admin(self.gateway, "share-fences")
        self.assertEqual([("share:1", "cleanup", "alice")], [(f["scope"], f["kind"], f["owner_uid"]) for f in fences])
        cleanup = self.gateway.registry.db.execute("SELECT device, state FROM share_cleanup").fetchone()
        self.assertEqual(("uid:alice", "failed"), tuple(cleanup))
        # The operator's repair-share as the OWNER: removes, then marks resolved (one step).
        del self.cloud.shares["1"]
        await admin(self.gateway, "share-cleanup-resolved", share_id="1", owner_uid="alice")
        await admin(self.gateway, "share-fence-clear", scope="share:1")
        # A later unrelated unknown outcome is then recoverable as usual.
        self.gateway.registry.mutation_begin(self.alice_id, "Documents/x")
        self.gateway.registry.maintenance()
        await admin(self.gateway, "recover")
        self.assertTrue(self.gateway.registry.mutation_ready())

    async def test_a_recipient_without_the_top_folder_keeps_the_share_in_shared(self):
        self.private("alice", "Documents/Taxes")
        self.assertEqual(201, (await self.share("Documents/Taxes"))[0])  # bob has no Documents
        self.assertEqual(("kept", "/anj-cloud/Shared/Taxes"),
                         (self.gateway.registry.placement("1")["state"], self.cloud.shares["1"]["file_target"]))
        self.assertEqual([("Shared/Taxes", "Alice")], await self.incoming(self.as_bob()))

    async def test_existing_and_other_shares_stay_in_shared(self):
        self.private("alice", "Documents/Old")
        self.private("bob")
        # A share made before placement existed: no placement row, so it is never moved.
        self.cloud.shares["9"] = {"id": "9", "share_type": 0, "uid_owner": "alice", "share_with": "bob", "item_type": "folder",
                                  "path": "/anj-cloud/Documents/Old", "permissions": 15, "file_target": "/anj-cloud/Shared/Old"}
        await self.share("Photos")
        self.assertEqual([("Shared/Old", "Alice"), ("Shared/Photos", "Alice")], await self.incoming(self.as_bob()))
        self.assertEqual([], self.cloud.moves)

    async def test_mounts_outside_the_allowed_places_are_never_listed_and_a_placement_escape_is_removed(self):
        self.private("alice", "Documents/Taxes", "Documents/Notes")
        self.private("bob")
        # A mount in a top folder that was not recorded for it, or deeper than a direct child.
        for share_id, target in (("7", "/anj-cloud/Documents/Old"), ("8", "/anj-cloud/Shared/a/b"), ("9", "/anj-cloud/Music/Taxes")):
            self.cloud.shares[share_id] = {"id": share_id, "share_type": 0, "uid_owner": "alice", "share_with": "bob",
                                           "item_type": "folder", "path": "/anj-cloud/Photos", "permissions": 15, "file_target": target}
        self.assertEqual([], await self.incoming(self.as_bob()))
        self.cloud.shares.clear()
        # The move reports success but the mount lands in another folder: the share is removed.
        self.cloud.move_lands = "/anj-cloud/Music/Taxes"
        status, body, _ = await self.share("Documents/Taxes")
        self.assertEqual(502, status)
        self.assertIn("removed", body["error"])
        self.assertEqual({}, self.cloud.shares)
        self.assertTrue(self.gateway.registry.mutation_ready())
        self.assertEqual([], await self.incoming(self.as_bob()))

    async def test_a_disable_records_placed_mounts(self):
        self.private("alice", "Documents/Taxes")
        self.private("bob")
        await self.share("Documents/Taxes")
        await self.share()
        self.assertTrue((await admin(self.gateway, "account-set", uid="alice", enabled=False))["mounts_recorded"])
        self.cloud.disabled.add("alice")
        _, incoming, _ = await self.call("GET", "/v1/shares/incoming", self.as_bob())
        self.assertEqual([("Documents/Taxes", True), ("Shared/Photos", True)], [(r["path"], r["owner_unavailable"]) for r in incoming])

    async def test_recipient_cannot_share_a_placed_mount_or_inside_it(self):
        self.private("alice", "Documents/Taxes")
        self.private("bob", "Documents/Taxes (Alice)", "Documents/Taxes (Alice)/2025")
        await self.share("Documents/Taxes")
        self.assertEqual([("Documents/Taxes", "Alice")], await self.incoming(self.as_bob()))
        self.cloud.folders["bob"] |= {"Documents/Taxes", "Documents/Taxes/2025"}
        for path in ("Documents/Taxes", "Documents/Taxes/2025"):
            status, body, _ = await self.share(path, "carol", who=self.as_bob())
            self.assertEqual((422, "Folders shared with you cannot be shared"), (status, body["error"]), path)
        self.assertEqual(201, (await self.share("Documents/Taxes (Alice)/2025", "carol", who=self.as_bob()))[0])
        self.assertEqual([], await admin(self.gateway, "share-fences"))

    # Leaving a share (spec #34 P6, decision #149).

    async def test_the_recipient_leaves_a_share_and_the_owners_folder_stays(self):
        self.private("alice", "Documents/Taxes")
        self.private("bob")
        await self.share("Documents/Taxes")
        await self.share("Docs")
        await self.incoming(self.as_bob())
        status, body, headers = await self.call("DELETE", "/v1/shares/incoming/1", self.as_bob())
        self.assertEqual((200, {"state": "left"}, "no-store"), (status, body, headers["Cache-Control"]))
        self.assertNotIn("1", self.cloud.shares)
        self.assertIn("Documents/Taxes", self.cloud.folders["alice"])
        self.assertIsNone(self.gateway.registry.placement("1"))
        self.assertEqual([("Shared/Docs", "Alice")], await self.incoming(self.as_bob()))
        self.assertEqual(("DELETE", "1", "bob"), self.cloud.mutations[-1])
        # A share in Shared/ is left the same way.
        self.assertEqual(200, (await self.call("DELETE", "/v1/shares/incoming/2", self.as_bob()))[0])
        self.assertEqual({}, self.cloud.shares)
        self.assertTrue(self.gateway.registry.mutation_ready())

    async def test_a_leave_answered_200_without_a_valid_status_is_read_back(self):
        # Review G-L1: never taken as applied; the share is still there, so not left.
        await self.share()
        self.cloud.fail["DELETE"] = "garbled"
        status, _, _ = await self.call("DELETE", "/v1/shares/incoming/1", self.as_bob())
        self.assertEqual(502, status)
        self.assertIn("1", self.cloud.shares)
        self.assertTrue(self.gateway.registry.mutation_ready())
        self.assertEqual(["share:1"], [f["scope"] for f in await admin(self.gateway, "share-fences")])

    async def test_only_the_recipient_can_leave_and_unknown_ids_are_404(self):
        await self.share()
        for who, share_id in ((self.as_alice(), "1"), (self.as_bob(), "2"), (self.as_bob(), "x"), (self.as_bob(), "1%2f2")):
            self.assertEqual(404, (await self.call("DELETE", "/v1/shares/incoming/" + share_id, who))[0], share_id)
        self.assertIn("1", self.cloud.shares)
        self.assertEqual(1, len(self.cloud.mutations))

    async def test_leaving_fences_like_every_share_mutation(self):
        await self.share()
        await self.share("Docs")
        self.cloud.fail["DELETE"] = 403
        self.assertEqual(502, (await self.call("DELETE", "/v1/shares/incoming/1", self.as_bob()))[0])
        self.assertEqual([("share:1", "leave", "bob")], [(f["scope"], f["kind"], f["owner_uid"]) for f in await admin(self.gateway, "share-fences")])
        self.assertEqual(503, (await self.call("DELETE", "/v1/shares/incoming/1", self.as_bob()))[0])
        # An unknown outcome is read back at once (review L3): gone means left, no write pause.
        self.cloud.fail["DELETE"] = 500
        self.assertEqual((200, {"state": "left"}), (await self.call("DELETE", "/v1/shares/incoming/2", self.as_bob()))[:2])
        self.assertTrue(self.gateway.registry.mutation_ready())
        await self.share("Photos/2024")
        # Still there: not left, scoped fence only.
        self.cloud.fail["DELETE"] = "lost"
        self.assertEqual(502, (await self.call("DELETE", "/v1/shares/incoming/3", self.as_bob()))[0])
        self.assertTrue(self.gateway.registry.mutation_ready())
        self.assertIn("share:3", [f["scope"] for f in await admin(self.gateway, "share-fences")])
        await self.share("Docs", "carol")
        # Unreadable afterwards: this share is paused, never the household (review F-M1).
        self.cloud.shares["4"]["share_with"] = "bob"
        self.cloud.fail["DELETE"] = "lost"
        original = self.gateway.sharing._read

        async def read_then_fail(*args, **kwargs):
            result = await original(*args, **kwargs)
            self.cloud.fail_share_reads = True
            return result
        self.gateway.sharing._read = read_then_fail
        self.assertEqual(503, (await self.call("DELETE", "/v1/shares/incoming/4", self.as_bob()))[0])
        self.gateway.sharing._read = original
        self.cloud.fail_share_reads = False
        self.assertTrue(self.gateway.registry.mutation_ready())
        self.assertIn(("share:4", "leave"), {(f["scope"], f["kind"]) for f in await admin(self.gateway, "share-fences")})

    # Rename for everyone (decision #155); a recipient's delete is a leave (decision #157).

    async def everyone(self, verb, share_id, who=None, body=None):
        return await self.call("POST", "/v1/shares/incoming/%s/%s" % (share_id, verb), who or self.as_bob(),
                               body if body is not None else {})

    async def test_there_is_no_delete_for_everyone_route(self):
        # Decision #157: a recipient's delete is a leave; only the owner deletes the folder.
        await self.share()
        self.assertEqual(404, (await self.everyone("delete", "1"))[0])
        self.assertIn("Photos", self.cloud.folders["alice"])

    async def test_rename_for_everyone_needs_full_access_a_write_device_the_recipient_and_the_owners_device(self):
        self.private("alice", "Documents/Taxes")
        self.private("bob")
        await self.share("Documents/Taxes")
        await self.share("Docs")
        for who, share_id in ((self.as_alice(), "1"), (self.as_bob(), "9"), (self.as_bob(), "x")):
            self.assertEqual(404, (await self.everyone("rename", share_id, who, {"name": "New"}))[0], share_id)
        self.legacy_view("2")
        status, body, _ = await self.everyone("rename", "2", body={"name": "New"})
        self.assertEqual((403, "This shared folder is View only"), (status, body["error"]))
        self.gateway.registry.db.execute("UPDATE devices SET rights='read' WHERE id=?", (self.alice_id,))
        self.gateway.registry.db.commit()
        status, body, _ = await self.everyone("rename", "1", body={"name": "New"})
        self.assertEqual((409, "The owner's device is needed"), (status, body["error"]))
        self.gateway.registry.db.execute("UPDATE devices SET rights='read' WHERE id=?", (self.bob_id,))
        self.gateway.registry.db.commit()
        self.assertEqual(403, (await self.everyone("rename", "1", body={"name": "New"}))[0])
        self.assertEqual([], self.cloud.owner_moves)

    async def test_rename_for_everyone_fences_only_the_share_on_failure_or_unknown_outcome(self):
        self.private("alice", "A", "B", "C")
        self.private("bob")
        for path in ("A", "B", "C"):
            await self.share(path)
        self.cloud.dav_fail["MOVE"] = 403
        self.assertEqual(502, (await self.everyone("rename", "1", body={"name": "A2"}))[0])
        self.cloud.dav_fail["MOVE"] = 500  # Applied, answer lost: read back as renamed.
        self.assertEqual(200, (await self.everyone("rename", "2", body={"name": "B2"}))[0])
        original = self.gateway.sharing._exists

        async def unreadable(*args):
            return None
        self.gateway.sharing._exists = unreadable
        self.cloud.dav_fail["MOVE"] = "lost"
        self.assertEqual(503, (await self.everyone("rename", "3", body={"name": "C2"}))[0])
        self.gateway.sharing._exists = original
        self.assertTrue(self.gateway.registry.mutation_ready())
        self.assertEqual({("share:1", "share-rename"), ("share:3", "share-rename")},
                         {(f["scope"], f["kind"]) for f in await admin(self.gateway, "share-fences")})

    async def test_an_over_long_rename_is_refused_before_anything_is_recorded(self):
        # Review F-M1: a 4,100-character name never pauses the household.
        self.private("alice", "Documents/Taxes")
        self.private("bob")
        await self.share("Documents/Taxes")
        status, body, _ = await self.everyone("rename", "1", body={"name": "x" * 4100})
        self.assertEqual((422, "This folder name is too long"), (status, body["error"]))
        self.assertEqual(422, (await self.everyone("rename", "1", body={"name": "é" * 126}))[0])  # 252 bytes
        self.assertEqual(200, (await self.everyone("rename", "1", body={"name": "é" * 125}))[0])  # 250 bytes
        self.assertTrue(self.gateway.registry.mutation_ready())
        self.assertEqual([], await admin(self.gateway, "share-fences"))
        self.assertEqual(201, (await self.share("Docs", "carol"))[0])

    async def test_a_rename_retried_after_a_partial_failure_finishes_the_other_recipients(self):
        # Review F-L2: the owner's folder was renamed but the follow-up read failed.
        self.private("alice", "Documents/Taxes")
        self.private("bob")
        await self.share("Documents/Taxes")
        await self.share("Documents/Taxes", "carol")
        original = self.gateway.sharing._read
        calls = {"n": 0}

        async def failing_owner_list(method, suffix, principal, query=None):
            if suffix == "" and principal.uid == "alice" and (query or {}).get("path", "").endswith("Taxes 2025"):
                calls["n"] += 1
                raise ShareError(502, "The sharing service is unavailable")
            return await original(method, suffix, principal, query)
        self.gateway.sharing._read = failing_owner_list
        self.assertEqual(502, (await self.everyone("rename", "1", body={"name": "Taxes 2025"}))[0])
        self.gateway.sharing._read = original
        self.assertGreater(calls["n"], 0)
        self.assertIn("Documents/Taxes 2025", self.cloud.folders["alice"])
        self.assertTrue(self.gateway.registry.mutation_ready())
        self.assertEqual([], self.gateway.registry.mount_renames("carol"))
        # The client retries with the same name: the follow-ups are done now.
        status, body, _ = await self.everyone("rename", "1", body={"name": "Taxes 2025"})
        self.assertEqual((200, "Documents/Taxes 2025"), (status, body["path"]))
        self.assertEqual(["Taxes 2025"], [r["name"] for r in self.gateway.registry.mount_renames("carol")])

    async def test_a_recipient_renames_a_shared_folder_for_everyone(self):
        self.private("alice", "Documents/Taxes")
        self.private("bob")
        self.private("carol")
        await self.share("Documents/Taxes")
        await self.share("Documents/Taxes", "carol")  # Carol has no device yet: Shared/Taxes, pending.
        status, body, _ = await self.everyone("rename", "1", body={"name": "Taxes 2025"})
        self.assertEqual((200, {"state": "renamed", "path": "Documents/Taxes 2025"}), (status, body))
        self.assertIn("Documents/Taxes 2025", self.cloud.folders["alice"])
        self.assertNotIn("Documents/Taxes", self.cloud.folders["alice"])
        self.assertEqual("/anj-cloud/Documents/Taxes 2025", self.cloud.shares["2"]["path"])
        self.assertEqual([("Documents/Taxes 2025", "Alice")], await self.incoming(self.as_bob()))
        # Carol's mount follows at her first incoming read (placed, then renamed).
        carol = Device()
        _, carol_leaf = pair(self.gateway.registry, self.authority, carol, "carol")
        self.assertEqual([("Documents/Taxes 2025", "Alice")], await self.incoming((carol, carol_leaf)))
        self.assertEqual([], self.gateway.registry.mount_renames("carol"))
        self.assertTrue(self.gateway.registry.mutation_ready())

    async def test_rename_for_everyone_refuses_a_name_the_owner_has_and_names_the_cloud_refuses(self):
        self.private("alice", "Documents/Taxes", "Documents/Other")
        self.private("bob")
        await self.share("Documents/Taxes")
        await self.share("Docs")
        status, body, _ = await self.everyone("rename", "1", body={"name": "Other"})
        self.assertEqual((409, "The owner already has a folder with this name"), (status, body["error"]))
        for name, reason in (("Other ", "untrimmed"), (" a", "untrimmed"), ("Disc.part", "forbiddenExtension")):
            status, body, _ = await self.everyone("rename", "1", body={"name": name})
            self.assertEqual((422, "name-not-portable", reason), (status, body["code"], body["reason"]), name)
        for name in ("", "a/b", "..", 7):
            self.assertEqual(400, (await self.everyone("rename", "1", body={"name": name}))[0], name)
        # A folder at the root may not take a top folder's name.
        for name in ("Documents", "shared"):
            self.assertEqual(409, (await self.everyone("rename", "2", body={"name": name}))[0], name)
        self.assertEqual([], self.cloud.owner_moves)
        self.assertEqual([], await admin(self.gateway, "share-fences"))
        # A share in Shared/: the owner's folder and this mount take the new name.
        status, body, _ = await self.everyone("rename", "2", body={"name": "Papers"})
        self.assertEqual((200, "Shared/Papers"), (status, body["path"]))
        self.assertIn("Papers", self.cloud.folders["alice"])
        # A name differing from another of the owner's folders only by case is another name (spec #49).
        status, body, _ = await self.everyone("rename", "1", body={"name": "OTHER"})
        self.assertEqual((200, "Documents/OTHER"), (status, body["path"]))
        self.assertIn("Documents/Other", self.cloud.folders["alice"])

    # Serialization and fences.

    async def test_sharing_waits_for_the_single_writer_lock(self):
        await self.gateway.mutations.lock.acquire()
        task = asyncio.create_task(self.share())
        await asyncio.sleep(0.3)
        self.assertEqual([], self.cloud.mutations)
        self.assertFalse(task.done())
        self.gateway.mutations.lock.release()
        self.assertEqual(201, (await task)[0])

    async def test_concurrent_sharing_calls_dispatch_one_at_a_time(self):
        self.cloud.gate = asyncio.Event()
        tasks = [asyncio.create_task(self.share("Photos")), asyncio.create_task(self.share("Docs"))]
        await asyncio.sleep(0.3)
        self.assertEqual(0, len(self.cloud.mutations))
        self.assertTrue(self.gateway.mutations.lock.locked())
        self.cloud.gate.set()
        self.assertEqual([201, 201], [(await task)[0] for task in tasks])

    async def test_global_fence_refuses_every_sharing_mutation_but_serves_reads(self):
        await self.share()
        self.gateway.registry.mutation_begin(self.alice_id, "Documents/x")
        for method, path, body in (("POST", "/v1/shares", {"path": "Docs", "recipient_id": "bob", "permission": "edit"}),
                                   ("PATCH", "/v1/shares/1", {"permission": "edit"}), ("DELETE", "/v1/shares/1", None)):
            self.assertEqual(503, (await self.call(method, path, self.as_alice(), body))[0], method)
        self.assertEqual(200, (await self.call("GET", "/v1/shares/outgoing", self.as_alice()))[0])
        self.assertEqual(200, (await self.call("GET", "/v1/shares/incoming", self.as_bob()))[0])
        self.gateway.registry.maintenance()
        self.assertEqual(503, (await self.call("DELETE", "/v1/shares/1", self.as_alice()))[0])
        self.assertEqual(1, len(self.cloud.mutations))

    async def test_known_failure_fences_only_that_share(self):
        await self.share()
        await self.share("Docs", "carol")
        self.cloud.fail["PUT"] = 403
        self.legacy_view("1")
        self.legacy_view("2")
        status, body, _ = await self.call("PATCH", "/v1/shares/1", self.as_alice(), {"permission": "edit"})
        self.assertEqual(502, status)
        self.assertTrue(self.gateway.registry.mutation_ready())
        fences = await admin(self.gateway, "share-fences")
        self.assertEqual([("share:1", "share-update", "alice", "1")], [(f["scope"], f["kind"], f["owner_uid"], f["share_id"]) for f in fences])
        self.assertEqual(503, (await self.call("DELETE", "/v1/shares/1", self.as_alice()))[0])
        self.assertEqual(200, (await self.call("PATCH", "/v1/shares/2", self.as_alice(), {"permission": "edit"}))[0])
        self.assertEqual(200, (await self.call("GET", "/v1/shares/outgoing", self.as_alice()))[0])
        await admin(self.gateway, "share-fence-clear", scope="share:1")
        self.assertEqual(200, (await self.call("PATCH", "/v1/shares/1", self.as_alice(), {"permission": "edit"}))[0])
        self.cloud.fail["POST"] = 400
        self.assertEqual(502, (await self.share("Photos/2024"))[0])
        self.assertEqual(["path:alice:/anj-cloud/Photos/2024"], [f["scope"] for f in await admin(self.gateway, "share-fences")])
        self.assertEqual(503, (await self.share("Photos/2024", "carol"))[0])
        self.assertEqual(201, (await self.share("Docs", "bob"))[0])

    async def test_unknown_outcome_closes_the_household_fence_with_its_intent(self):
        await self.share()
        self.legacy_view("1")
        for method, path, body, kind in (("PATCH", "/v1/shares/1", {"permission": "edit"}, "share-update"),
                                         ("DELETE", "/v1/shares/1", None, "unshare"),
                                         ("POST", "/v1/shares", {"path": "Docs", "recipient_id": "bob", "permission": "edit"}, "share")):
            self.cloud.fail["PUT" if method == "PATCH" else method] = 500
            status, error, _ = await self.call(method, path, self.as_alice(), body)
            self.assertEqual(503, status, kind)
            self.assertNotIn("Docs", json.dumps(error))
            fence = await admin(self.gateway, "fence")
            intent = json.loads(fence["path"])
            self.assertEqual(("dispatched", kind, "alice", "alice"), (fence["state"], intent["kind"], intent["owner"], fence["owner_uid"]))
            # DAV writes are fenced too, and sharing reconciliation is required to clear it.
            self.assertFalse(self.gateway.registry.mutation_ready())
            self.gateway.registry.maintenance()
            with self.assertRaises(RuntimeError):
                await admin(self.gateway, "recover")
            await admin(self.gateway, "recover", sharing_reconciled=True)
            self.assertTrue(self.gateway.registry.mutation_ready())

    # Disabled accounts (decision #79 (b), #80 (2), (3)).

    async def test_disabled_account_devices_are_refused_reversibly_without_revocation(self):
        result = await admin(self.gateway, "account-set", uid="alice", enabled=False)
        self.assertEqual((False, True), (result["account"]["enabled"], result["changed"]))
        for method, path in ROUTES[:3]:
            self.assertEqual(403, (await self.call(method, path, self.as_alice()))[0])
        status, _, _ = await self.call("GET", "/v1/device/certificate", self.as_alice())
        self.assertIn(status, (403, 404))
        self.assertEqual("active", self.gateway.registry.device(self.alice_id)["state"])
        _, users, _ = await self.call("GET", "/v1/household/users", self.as_bob())
        self.assertEqual(["carol"], [u["id"] for u in users])
        await admin(self.gateway, "account-set", uid="alice", enabled=True)
        self.assertEqual(200, (await self.call("GET", "/v1/shares/outgoing", self.as_alice()))[0])

    async def test_disabled_owner_marks_incoming_shares_unavailable_until_reenabled(self):
        await self.share()
        await self.share("Docs", "bob")
        self.legacy_view("2")
        result = await admin(self.gateway, "account-set", uid="alice", enabled=False)
        self.assertTrue(result["mounts_recorded"])
        self.cloud.disabled.add("alice")  # The operator CLI then disables the Nextcloud account.
        _, incoming, _ = await self.call("GET", "/v1/shares/incoming", self.as_bob())
        self.assertEqual([("Shared/Docs", "view", True), ("Shared/Photos", "edit", True)],
                         [(r["path"], r["permission"], r["owner_unavailable"]) for r in incoming])
        self.assertEqual({"Alice"}, {r["owner_display_name"] for r in incoming})
        self.cloud.disabled.discard("alice")
        await admin(self.gateway, "account-set", uid="alice", enabled=True)
        _, incoming, _ = await self.call("GET", "/v1/shares/incoming", self.as_bob())
        self.assertEqual([False, False], [r["owner_unavailable"] for r in incoming])
        # An unshare is not "unavailable": the mount simply leaves the list.
        await self.call("DELETE", "/v1/shares/1", self.as_alice())
        await admin(self.gateway, "account-set", uid="alice", enabled=False)
        self.cloud.disabled.add("alice")
        _, incoming, _ = await self.call("GET", "/v1/shares/incoming", self.as_bob())
        self.assertEqual(["Shared/Docs"], [r["path"] for r in incoming])

    async def test_disable_is_refused_and_nothing_changes_when_mounts_cannot_be_recorded(self):
        await self.share()
        self.cloud.fail_owner_listing.add("alice")
        with self.assertRaises(RuntimeError) as refused:
            await admin(self.gateway, "account-set", uid="alice", enabled=False)
        self.assertIn("not disabled", str(refused.exception))
        self.assertTrue(self.gateway.registry.account("alice")["enabled"])
        # The owner's devices are still admitted (not 403).
        self.assertEqual(200, (await self.call("GET", "/v1/household/users", self.as_alice()))[0])
        self.assertEqual([], self.gateway.registry.unavailable_incoming("bob"))
        # The operator's retry succeeds once the owner's list can be read.
        self.cloud.fail_owner_listing.clear()
        result = await admin(self.gateway, "account-set", uid="alice", enabled=False)
        self.assertEqual((True, False), (result["mounts_recorded"], result["account"]["enabled"]))

    async def test_an_owner_list_404_or_non_list_refuses_and_keeps_recorded_mounts(self):
        await self.share()
        await self.call("GET", "/v1/shares/incoming", self.as_bob())  # bob's mount is on record
        recorded = lambda: self.gateway.registry.db.execute(
            "SELECT count(*) FROM incoming_mounts WHERE owner_uid='alice'").fetchone()[0]
        self.assertEqual(1, recorded())
        for reply in ("404", "not-a-list"):
            self.cloud.owner_listing_reply["alice"] = reply
            with self.assertRaises(RuntimeError, msg=reply):
                await admin(self.gateway, "account-set", uid="alice", enabled=False)
            self.assertTrue(self.gateway.registry.account("alice")["enabled"], reply)
            self.assertEqual(1, recorded(), reply)

    async def test_a_hung_owner_list_refuses_the_disable_at_the_deadline_and_frees_the_lock(self):
        from unittest.mock import patch
        import time
        from services.access import sharing
        await self.share()
        self.cloud.owner_listing_delay["alice"] = 5
        started = time.monotonic()
        with patch.object(sharing, "DISABLE_READ_TIMEOUT", 0.3):
            with self.assertRaises(RuntimeError) as refused:
                await admin(self.gateway, "account-set", uid="alice", enabled=False)
        self.assertLess(time.monotonic() - started, 2)
        self.assertIn("not disabled", str(refused.exception))
        self.assertFalse(self.gateway.mutations.lock.locked())
        self.assertTrue(self.gateway.registry.account("alice")["enabled"])
        self.assertEqual(30.0, sharing.DISABLE_READ_TIMEOUT)

    async def test_the_disable_holds_the_lock_so_a_queued_share_is_refused_not_missed(self):
        await self.gateway.mutations.lock.acquire()
        disable = asyncio.create_task(admin(self.gateway, "account-set", uid="alice", enabled=False))
        await asyncio.sleep(0.2)
        create = asyncio.create_task(self.share())  # admitted now, queued behind the disable
        await asyncio.sleep(0.3)
        self.assertFalse(disable.done())
        self.assertTrue(self.gateway.registry.account("alice")["enabled"])
        self.gateway.mutations.lock.release()
        self.assertFalse((await disable)["account"]["enabled"])
        status, body, _ = await create
        self.assertEqual((403, {}), (status, self.cloud.shares))

    async def test_a_disabled_recipient_never_blocks_disabling_the_owner(self):
        await self.share()  # alice -> bob, mounted at Shared/Photos
        await admin(self.gateway, "account-set", uid="bob", enabled=False)
        self.cloud.disabled.add("bob")
        self.cloud.fail_incoming.add("bob")  # bob's own list is unreadable: not needed any more
        result = await admin(self.gateway, "account-set", uid="alice", enabled=False)
        self.assertEqual((True, False), (result["mounts_recorded"], result["account"]["enabled"]))
        self.cloud.disabled.add("alice")
        self.assertEqual([("Shared/Photos", "alice")], [(r["path"], r["owner_uid"]) for r in self.gateway.registry.unavailable_incoming("bob")])
        # Bob comes back first: his client sees the folder as owner-unavailable, not unshared.
        self.cloud.disabled.discard("bob")
        self.cloud.fail_incoming.clear()
        await admin(self.gateway, "account-set", uid="bob", enabled=True)
        status, incoming, _ = await self.call("GET", "/v1/shares/incoming", self.as_bob())
        self.assertEqual((200, [("Shared/Photos", "Alice", True)]),
                         (status, [(r["path"], r["owner_display_name"], r["owner_unavailable"]) for r in incoming]))

    async def test_two_users_who_share_with_each_other_can_both_be_disabled(self):
        await self.share()  # alice -> bob
        await self.share("Work", "alice", who=self.as_bob())  # bob -> alice
        self.assertTrue((await admin(self.gateway, "account-set", uid="alice", enabled=False))["mounts_recorded"])
        self.cloud.disabled.add("alice")
        self.assertTrue((await admin(self.gateway, "account-set", uid="bob", enabled=False))["mounts_recorded"])
        self.cloud.disabled.add("bob")
        self.assertEqual(["Shared/Work"], [r["path"] for r in self.gateway.registry.unavailable_incoming("alice")])
        self.assertEqual(["Shared/Photos"], [r["path"] for r in self.gateway.registry.unavailable_incoming("bob")])

    async def test_an_owner_without_a_device_is_disabled_with_the_operator_token_only(self):
        self.cloud.tokens["temp-carol"] = "carol"
        self.cloud.folders["carol"].add("Recipes")
        await admin(self.gateway, "share", owner_uid="carol", token="temp-carol", path="Recipes", recipient="bob")
        with self.assertRaises(RuntimeError):
            await admin(self.gateway, "account-set", uid="carol", enabled=False)
        self.assertTrue(self.gateway.registry.account("carol")["enabled"])
        result = await admin(self.gateway, "account-set", uid="carol", enabled=False, token="temp-carol")
        self.assertTrue(result["mounts_recorded"])
        self.assertEqual(["Shared/Recipes"], [r["path"] for r in self.gateway.registry.unavailable_incoming("bob")])

    async def test_account_set_validates_and_registers(self):
        for bad in ({"uid": "Bad"}, {"uid": "x" * 33, "display_name": "X"}, {"uid": "dave"}, {"uid": "dave", "display_name": " "},
                    {"uid": "dave", "display_name": "D", "enabled": "no"}, {"uid": "dave", "display_name": "D", "role": "admin"},
                    # C1 control, bidi override, zero-width space, BOM: not printable (review L1).
                    {"uid": "dave", "display_name": "Da\u009bve"}, {"uid": "dave", "display_name": "\u202eevaD"},
                    {"uid": "dave", "display_name": "Da\u200bve"}, {"uid": "dave", "display_name": "\ufeffDave"}):
            with self.assertRaises(RuntimeError):
                await admin(self.gateway, "account-set", **bad)
        result = await admin(self.gateway, "account-set", uid="dave", display_name="  Dave   D ")
        self.assertEqual({"uid": "dave", "display_name": "Dave D", "enabled": True}, result["account"])
        await admin(self.gateway, "account-set", uid="dave", display_name="David")
        self.assertIn({"uid": "dave", "display_name": "David", "enabled": True}, await admin(self.gateway, "accounts"))

    # Operator socket: one component, device or temporary owner token (decision #80 (4)).

    async def test_operator_share_uses_corrected_rights_and_refuses_files(self):
        row = await admin(self.gateway, "share", device_id=self.alice_id, path="Photos", recipient="bob", rights="write")
        self.assertEqual((15, "edit", "/dav/Shared/"), (self.cloud.shares[row["share_id"]]["permissions"], row["permission"], row["incoming_root"]))
        # One access level (decision #155): the default is full access, `read` is refused.
        with self.assertRaises(RuntimeError):
            await admin(self.gateway, "share", device_id=self.alice_id, path="Docs", recipient="bob", rights="read")
        row = await admin(self.gateway, "share", device_id=self.alice_id, path="Docs", recipient="bob")
        self.assertEqual(15, self.cloud.shares[row["share_id"]]["permissions"])
        self.legacy_view(row["share_id"])
        with self.assertRaises(RuntimeError):
            await admin(self.gateway, "share", device_id=self.alice_id, path="notes.txt", recipient="bob", rights="write")
        updated = await admin(self.gateway, "share-update", device_id=self.alice_id, share_id=row["share_id"], rights="write")
        self.assertEqual((15, "edit"), (self.cloud.shares[row["share_id"]]["permissions"], updated["permission"]))
        self.assertEqual(2, len(await admin(self.gateway, "shares", device_id=self.alice_id)))

    async def test_owner_without_a_device_uses_a_verified_temporary_token(self):
        self.cloud.tokens["temp-carol"] = "carol"
        self.cloud.folders["carol"].add("Recipes")
        row = await admin(self.gateway, "share", owner_uid="carol", token="temp-carol", path="Recipes", recipient="bob")
        self.assertEqual(("carol", 15), (self.cloud.shares[row["share_id"]]["uid_owner"], self.cloud.shares[row["share_id"]]["permissions"]))
        self.assertEqual([row["share_id"]], [r["share_id"] for r in await admin(self.gateway, "shares", owner_uid="carol", token="temp-carol")])
        with self.assertRaises(RuntimeError):
            await admin(self.gateway, "unshare", owner_uid="alice", token="temp-carol", share_id=row["share_id"])
        with self.assertRaises(RuntimeError):
            await admin(self.gateway, "unshare", owner_uid="carol", token="temp-carol", device_id=self.alice_id, share_id=row["share_id"])
        self.assertEqual({"state": "removed"}, await admin(self.gateway, "unshare", owner_uid="carol", token="temp-carol", share_id=row["share_id"]))
        self.cloud.fail["POST"] = 502
        with self.assertRaises(RuntimeError):
            await admin(self.gateway, "share", owner_uid="carol", token="temp-carol", path="Recipes", recipient="bob")
        fence = await admin(self.gateway, "fence")
        self.assertEqual(("carol", "share"), (fence["owner_uid"], json.loads(fence["path"])["kind"]))
        self.assertNotIn("temp-carol", json.dumps(fence))


class ConfinementTests(SharingTests):
    """A share whose recipient mount escapes Shared/ is removed at once; a failed removal is truthful."""

    async def test_unconfined_share_is_removed_and_failed_cleanup_is_scoped_or_fenced(self):
        self.cloud.unconfined = True
        status, body, _ = await self.share()
        self.assertEqual(502, status)
        self.assertIn("removed", body["error"])
        self.assertEqual({}, self.cloud.shares)
        self.assertEqual([], self.gateway.registry.db.execute("SELECT * FROM share_cleanup").fetchall())
        for failure, ready in ((403, True), (500, False)):
            self.cloud.fail["DELETE"] = failure
            status, body, _ = await self.share("Docs" if ready else "Photos/2024")
            row = self.gateway.registry.db.execute("SELECT * FROM share_cleanup ORDER BY rowid DESC").fetchone()
            self.assertIsNotNone(row)
            self.assertEqual((502 if ready else 503, "failed" if ready else "pending", ready),
                             (status, row["state"], self.gateway.registry.mutation_ready()), failure)
            self.assertNotIn("removed", body["error"].replace("removal", ""))
        self.assertEqual(["share:2"], [f["scope"] for f in await admin(self.gateway, "share-fences")])

    # Only the confinement test runs here.
    for _name in [name for name in dir(SharingTests) if name.startswith("test_")]:
        locals()[_name] = None
    del _name


class RegistryAccountTests(unittest.TestCase):
    def test_unregistered_accounts_are_not_refused_and_rejection_is_a_value_error(self):
        import tempfile
        from services.access.registry import Registry
        with tempfile.TemporaryDirectory() as directory:
            registry = Registry(directory)
            self.assertTrue(registry.account_enabled("legacy"))
            registry.account_set("legacy", "Legacy", enabled=False)
            self.assertFalse(registry.account_enabled("legacy"))
            self.assertTrue(issubclass(Rejection, ValueError))
            # The admin role column exists for the console work (decision #87) and defaults to false.
            self.assertEqual(0, registry.db.execute("SELECT admin FROM accounts WHERE uid='legacy'").fetchone()[0])
            registry.db.close()

