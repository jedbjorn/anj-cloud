"""Trash (spec #44): the gateway's /trash/ routes over the caller's own Nextcloud trash.

The gateway's real public router runs over real mutual TLS with fixture CAs; Nextcloud is an in-process fake
that answers the trashbin and files DAV calls the way Nextcloud 33.0.10 does on the review stack: a restore
always goes to the original location whatever the MOVE names, an exact name already there gives
`name (restored).ext`, a missing parent puts the item at the account's top level, and an owner's item
deleted by a share recipient carries a leading slash in its original location.
"""

import asyncio
import base64
import json
import posixpath
from urllib.parse import quote, unquote, urlsplit

import aiohttp
from aiohttp import web
from aiohttp.test_utils import TestServer

import unittest

from gateway_harness import HOST, Harness
from test_permanent_credentials import Device, pair
from services.access.trash import restored_name, root_relative

ROUTES = [("GET", "/trash/"), ("DELETE", "/trash/"), ("POST", "/trash/1/restore"), ("DELETE", "/trash/1"), ("POST", "/trash/restore")]


class FakeTrashCloud:
    """Per-user file trees (path below the user's files root -> bytes, or None for a folder) and trashes."""

    def __init__(self):
        self.tokens, self.tree, self.trash = {}, {}, {}
        self.next_id, self.clock = 500, 1_800_000_000
        self.fail = {}  # "restore" | "delete" | "list" -> status, "lost" (not applied) or "applied-lost"
        self.readonly = set()  # folders the caller may not create in (a View only share)
        self.top_level = False  # every restore lands at the account's top level
        self.listings = 0  # trash listings answered
        self.gate = None  # an Event a restore waits for, after `reached` is set
        self.reached = None
        self.server = None

    def user(self, uid):
        self.tokens["token-" + uid] = uid
        self.tree[uid] = {"anj-cloud": None, "anj-cloud/Documents": None, "anj-cloud/Shared": None}
        self.trash[uid] = {}

    def put(self, uid, path, content=b"x"):
        parts = path.split("/")
        for depth in range(1, len(parts)):
            self.tree[uid].setdefault("/".join(parts[:depth]), None)
        self.tree[uid][path] = content

    def delete(self, uid, path, location=None, by=None):
        """Moves `path` and everything under it into the trash, as a Nextcloud delete does."""
        self.clock += 10
        self.next_id += 1
        subtree = {k: v for k, v in self.tree[uid].items() if k == path or k.startswith(path + "/")}
        for key in subtree:
            del self.tree[uid][key]
        name = "%s.d%d" % (posixpath.basename(path), self.clock)
        self.trash[uid][name] = {"location": location or path, "deleted": self.clock, "fileid": str(self.next_id),
                                 "subtree": {k[len(path):]: v for k, v in subtree.items()}, "by": by or uid}
        return str(self.next_id)

    def caller(self, request):
        try:
            uid, token = base64.b64decode(request.headers.get("Authorization", "").split(" ", 1)[1]).decode().split(":", 1)
        except (IndexError, ValueError):
            return None
        return uid if self.tokens.get(token) == uid else None

    def multistatus(self, responses):
        return web.Response(status=207, body=('<?xml version="1.0"?><d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns" '
                                              'xmlns:nc="http://nextcloud.org/ns">' + "".join(responses) + "</d:multistatus>").encode())

    def restore(self, uid, name):
        item = self.trash[uid].pop(name)
        location = item["location"].lstrip("/")
        parent, leaf = posixpath.split(location)
        if self.top_level or (parent and (self.tree[uid].get(parent, b"") is not None or parent in self.readonly)):
            parent = ""  # Nextcloud restores at the account's top level when the folder is gone or not writable.
        target = (parent + "/" if parent else "") + leaf
        if target in self.tree[uid]:
            base, extension = posixpath.splitext(leaf) if item["subtree"][""] is not None else (leaf, "")
            target = (parent + "/" if parent else "") + base + " (restored)" + extension
        for suffix, value in item["subtree"].items():
            self.tree[uid][target + suffix] = value

    async def handle(self, request):
        uid = self.caller(request)
        if uid is None:
            return web.Response(status=401)
        path = unquote(request.path)
        trash_root = "/remote.php/dav/trashbin/%s/trash/" % uid
        files_root = "/remote.php/dav/files/%s/" % uid
        if path.startswith(trash_root):
            name = path[len(trash_root):].rstrip("/")
            if request.method == "PROPFIND" and not name:
                self.listings += 1
                failure = self.fail.pop("list", None)
                if failure is not None:
                    return web.Response(status=failure if isinstance(failure, int) else 500)
                responses = ["<d:response><d:href>%s</d:href></d:response>" % quote(trash_root)]
                for key, item in self.trash[uid].items():
                    folder = item["subtree"][""] is None
                    size = sum(len(v) for v in item["subtree"].values() if v is not None)
                    responses.append(
                        "<d:response><d:href>%s%s</d:href><d:propstat><d:prop><nc:trashbin-filename>%s</nc:trashbin-filename>"
                        "<nc:trashbin-original-location>%s</nc:trashbin-original-location><nc:trashbin-deletion-time>%d"
                        "</nc:trashbin-deletion-time><oc:size>%d</oc:size><d:resourcetype>%s</d:resourcetype><oc:fileid>%s</oc:fileid>"
                        "</d:prop></d:propstat></d:response>" % (quote(trash_root + key), "/" if folder else "", posixpath.basename(item["location"]),
                                                                  item["location"], item["deleted"], size,
                                                                  "<d:collection/>" if folder else "", item["fileid"]))
                return self.multistatus(responses)
            if name not in self.trash[uid]:
                return web.Response(status=404)
            kind = "restore" if request.method == "MOVE" else "delete" if request.method == "DELETE" else None
            failure = self.fail.pop(kind, None)
            if isinstance(failure, int):
                return web.Response(status=failure)
            if failure == "lost":
                return web.Response(status=500)  # The answer is lost; nothing was applied.
            if request.method == "MOVE" and self.gate is not None:
                self.reached.set()
                await self.gate.wait()
            if request.method == "MOVE":
                if "/remote.php/dav/trashbin/%s/restore/" % uid not in request.headers.get("Destination", ""):
                    return web.Response(status=403)
                self.restore(uid, name)
                status = 201
            elif request.method == "DELETE":
                del self.trash[uid][name]
                status = 204
            else:
                return web.Response(status=405)
            return web.Response(status=500 if failure == "applied-lost" else status)
        if not path.startswith(files_root):
            return web.Response(status=404)
        relative = path[len(files_root):].rstrip("/")
        tree = self.tree[uid]
        if request.method == "PROPFIND":
            if relative not in tree:
                return web.Response(status=404)
            if request.headers.get("Depth") == "1":
                children = sorted(k for k in tree if posixpath.dirname(k) == relative)
                return self.multistatus(["<d:response><d:href>%s</d:href></d:response>" % quote(files_root + relative + "/")] + [
                    "<d:response><d:href>%s%s</d:href></d:response>" % (quote(files_root + child), "/" if tree[child] is None else "")
                    for child in children])
            folder = tree[relative] is None
            permissions = "SG" if relative in self.readonly else "RGDNVCK" if folder else "RGDNVW"
            return self.multistatus(["<d:response><d:href>%s</d:href><d:propstat><d:prop><d:getetag>\"e-%s\"</d:getetag>"
                                     "<d:resourcetype>%s</d:resourcetype><oc:fileid>7</oc:fileid><oc:permissions>%s</oc:permissions>"
                                     "</d:prop></d:propstat></d:response>"
                                     % (quote(files_root + relative), abs(hash(relative)), "<d:collection/>" if folder else "", permissions)])
        if request.method == "MKCOL":
            if relative in tree:
                return web.Response(status=405)
            if posixpath.dirname(relative) not in tree:
                return web.Response(status=409)
            tree[relative] = None
            return web.Response(status=201)
        if request.method == "MOVE":
            destination = unquote(urlsplit(request.headers["Destination"]).path)[len(files_root):].rstrip("/")
            if relative not in tree:
                return web.Response(status=404)
            if destination in tree and request.headers.get("Overwrite") == "F":
                return web.Response(status=412)
            for key in [k for k in tree if k == relative or k.startswith(relative + "/")]:
                tree[destination + key[len(relative):]] = tree.pop(key)
            return web.Response(status=201)
        return web.Response(status=405)

    async def start(self):
        app = web.Application()
        app.router.add_route("*", "/{path:.*}", self.handle)
        self.server = TestServer(app)
        await self.server.start_server()
        return str(self.server.make_url("")).rstrip("/")


class AdvertiseTests(unittest.TestCase):
    def test_advertising_is_best_effort_for_a_gateway_without_the_action(self):
        from unittest import mock
        from deploy.dev import Stack
        stack = Stack("anj-cloud-review-advertise", 18999)
        with mock.patch.object(stack, "compose", side_effect=RuntimeError("Command failed (exit 1)")), \
                mock.patch("sys.stderr"):
            self.assertIsNone(stack.advertise_trash(7))
        with mock.patch.object(stack, "compose", return_value='{"trash_days": 7}') as compose:
            self.assertEqual(7, stack.advertise_trash(7))
            self.assertIn("trash-days", compose.call_args.kwargs["data"])


class NamingTests(unittest.TestCase):
    def test_restored_names(self):
        self.assertEqual("report (restored).pdf", restored_name("report.pdf", False, 1))
        self.assertEqual("report (restored 2).pdf", restored_name("report.pdf", False, 2))
        self.assertEqual("Photos.2024 (restored)", restored_name("Photos.2024", True, 1))
        self.assertEqual(".bashrc (restored)", restored_name(".bashrc", False, 1))

    def test_only_items_below_the_root_are_in_scope(self):
        self.assertEqual("Documents/a.txt", root_relative("anj-cloud/Documents/a.txt"))
        self.assertEqual("Proj/f.txt", root_relative("/anj-cloud/Proj/f.txt"))
        for outside in ("outside.txt", "anj-cloud", "anj-cloud/", "anj-cloudy/a", "Documents/anj-cloud/a", None, "anj-cloud/../x"):
            self.assertIsNone(root_relative(outside), outside)


class TrashTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.harness = Harness(listener="tcp")
        await self.harness.start()
        self.gateway, self.port = self.harness.gateway, self.harness.port
        self.cloud = FakeTrashCloud()
        self.cloud.user("alice")
        self.cloud.user("bob")
        self.gateway.backend = await self.cloud.start()
        self.alice, self.reader = Device(), Device()
        _, self.alice_leaf = pair(self.gateway.registry, self.harness.authority, self.alice, "alice")
        reader_id, self.reader_leaf = pair(self.gateway.registry, self.harness.authority, self.reader, "alice")
        with self.gateway.registry.db:
            self.gateway.registry.db.execute("UPDATE devices SET rights='read' WHERE id=?", (reader_id,))

    async def asyncTearDown(self):
        await self.cloud.server.close()
        await self.harness.stop()

    async def call(self, method, path, who="alice", body=None):
        identity = {"alice": (self.alice, self.alice_leaf), "reader": (self.reader, self.reader_leaf)}.get(who)
        context = self.harness.client_context(*(identity or ()))
        async with aiohttp.ClientSession(connector=aiohttp.TCPConnector(ssl=context), trust_env=False) as session:
            async with session.request(method, "https://127.0.0.1:%d%s" % (self.port, path), server_hostname=HOST,
                                       allow_redirects=False, json=body) as response:
                text = await response.text()
                try:
                    body = json.loads(text)
                except ValueError:
                    body = text
                return response.status, body, response.headers

    def fence(self):
        return self.gateway.registry.db.execute("SELECT state FROM mutation_fence WHERE singleton=1").fetchone()[0]

    async def listed(self, who="alice"):
        status, body, _ = await self.call("GET", "/trash/", who)
        self.assertEqual(200, status)
        return body

    # Listing (AC3).

    async def test_lists_only_items_deleted_under_the_root_newest_first(self):
        cloud = self.cloud
        cloud.put("alice", "anj-cloud/Documents/a.txt", b"12345")
        cloud.put("alice", "outside.txt")
        cloud.put("alice", "anj-cloud/Proj/f.txt", b"shared")
        first = cloud.delete("alice", "anj-cloud/Documents/a.txt")
        cloud.delete("alice", "outside.txt")
        shared = cloud.delete("alice", "anj-cloud/Proj/f.txt", location="/anj-cloud/Proj/f.txt", by="bob")
        status, body, headers = await self.call("GET", "/trash/")
        self.assertEqual((200, "no-store"), (status, headers["Cache-Control"]))
        self.assertEqual(7, body["trash_days"])
        self.assertEqual([shared, first], [item["id"] for item in body["items"]])
        row = body["items"][1]
        self.assertEqual({"id": first, "path": "Documents/a.txt", "kind": "file", "size": 5,
                          "deleted": 1_800_000_010, "expires": 1_800_000_010 + 7 * 86400}, row)
        self.assertEqual("Proj/f.txt", body["items"][0]["path"])
        self.assertNotIn("outside", json.dumps(body))

    async def test_trash_days_come_from_the_deployment_and_set_expiry(self):
        self.cloud.put("alice", "anj-cloud/Documents/a.txt")
        self.cloud.delete("alice", "anj-cloud/Documents/a.txt")
        self.gateway.trash.set_days(3)
        body = await self.listed()
        self.assertEqual((3, body["items"][0]["deleted"] + 3 * 86400), (body["trash_days"], body["items"][0]["expires"]))
        with self.assertRaises(Exception):
            self.gateway.trash.set_days(0)
        self.assertEqual(3, self.gateway.trash.days)

    async def test_every_route_requires_a_certificate_and_logs_without_paths(self):
        for method, path in ROUTES:
            status, _, _ = await self.call(method, path, who=None)
            self.assertEqual(401, status, path)
        self.cloud.put("alice", "anj-cloud/Documents/secret-name.txt")
        self.cloud.delete("alice", "anj-cloud/Documents/secret-name.txt")
        await self.listed()
        self.assertTrue(self.harness.requests(route="trash"))
        self.assertNotIn("secret-name", self.harness.stream.getvalue())

    async def test_unknown_and_outside_ids_are_not_in_trash(self):
        self.cloud.put("alice", "outside.txt")
        outside = self.cloud.delete("alice", "outside.txt")
        for path in ("/trash/%s/restore" % outside, "/trash/999/restore", "/trash/abc/restore"):
            status, body, _ = await self.call("POST", path)
            self.assertEqual((404, "Not in Trash"), (status, body["error"]), path)
        status, _, _ = await self.call("DELETE", "/trash/%s" % outside)
        self.assertEqual(404, status)
        self.assertEqual(["outside.txt"], [key.rsplit(".d", 1)[0] for key in self.cloud.trash["alice"]])

    # Restore (AC3).

    async def test_restore_returns_the_item_to_its_path(self):
        self.cloud.put("alice", "anj-cloud/Documents/a.txt", b"bytes")
        item = self.cloud.delete("alice", "anj-cloud/Documents/a.txt")
        status, body, _ = await self.call("POST", "/trash/%s/restore" % item)
        self.assertEqual((200, {"path": "Documents/a.txt", "renamed": False}), (status, body))
        self.assertEqual(b"bytes", self.cloud.tree["alice"]["anj-cloud/Documents/a.txt"])
        self.assertEqual({}, self.cloud.trash["alice"])
        self.assertEqual("clear", self.fence())

    async def test_restore_recreates_missing_parents_inside_the_root(self):
        self.cloud.put("alice", "anj-cloud/Documents/Trip/Day 1/photo.jpg", b"jpg")
        item = self.cloud.delete("alice", "anj-cloud/Documents/Trip/Day 1/photo.jpg")
        self.cloud.delete("alice", "anj-cloud/Documents/Trip")
        status, body, _ = await self.call("POST", "/trash/%s/restore" % item)
        self.assertEqual((200, "Documents/Trip/Day 1/photo.jpg"), (status, body["path"]))
        self.assertIsNone(self.cloud.tree["alice"]["anj-cloud/Documents/Trip/Day 1"])
        self.assertEqual(b"jpg", self.cloud.tree["alice"]["anj-cloud/Documents/Trip/Day 1/photo.jpg"])
        self.assertNotIn("photo.jpg", self.cloud.tree["alice"])

    async def test_restore_into_a_taken_name_never_overwrites(self):
        tree = self.cloud.tree["alice"]
        self.cloud.put("alice", "anj-cloud/Documents/a.txt", b"old")
        first = self.cloud.delete("alice", "anj-cloud/Documents/a.txt")
        self.cloud.put("alice", "anj-cloud/Documents/a.txt", b"new")
        status, body, _ = await self.call("POST", "/trash/%s/restore" % first)
        self.assertEqual((200, {"path": "Documents/a (restored).txt", "renamed": True}), (status, body))
        self.assertEqual((b"new", b"old"), (tree["anj-cloud/Documents/a.txt"], tree["anj-cloud/Documents/a (restored).txt"]))
        # Taken apart from case: Nextcloud would restore beside it; the gateway renames to the next free name.
        self.cloud.put("alice", "anj-cloud/Documents/Report.TXT", b"r1")
        second = self.cloud.delete("alice", "anj-cloud/Documents/Report.TXT")
        self.cloud.put("alice", "anj-cloud/Documents/report.txt", b"other")
        self.cloud.put("alice", "anj-cloud/Documents/Report (restored).TXT", b"earlier restore")
        status, body, _ = await self.call("POST", "/trash/%s/restore" % second)
        self.assertEqual((200, "Documents/Report (restored 2).TXT"), (status, body["path"]))
        self.assertEqual(b"r1", tree["anj-cloud/Documents/Report (restored 2).TXT"])
        self.assertEqual((b"other", b"earlier restore"), (tree["anj-cloud/Documents/report.txt"], tree["anj-cloud/Documents/Report (restored).TXT"]))
        self.assertNotIn("anj-cloud/Documents/Report.TXT", tree)
        self.assertEqual("clear", self.fence())

    async def test_restore_of_a_folder_brings_its_contents(self):
        self.cloud.put("alice", "anj-cloud/Documents/Album/one.jpg", b"1")
        self.cloud.put("alice", "anj-cloud/Documents/Album/sub/two.jpg", b"2")
        item = self.cloud.delete("alice", "anj-cloud/Documents/Album")
        body = await self.listed()
        self.assertEqual(("folder", 2), (body["items"][0]["kind"], body["items"][0]["size"]))
        status, body, _ = await self.call("POST", "/trash/%s/restore" % item)
        self.assertEqual((200, "Documents/Album"), (status, body["path"]))
        self.assertEqual(b"2", self.cloud.tree["alice"]["anj-cloud/Documents/Album/sub/two.jpg"])

    # Unknown outcomes and the fence.

    async def test_lost_restore_answer_is_read_back(self):
        self.cloud.put("alice", "anj-cloud/Documents/a.txt")
        item = self.cloud.delete("alice", "anj-cloud/Documents/a.txt")
        self.cloud.fail["restore"] = "applied-lost"
        status, body, _ = await self.call("POST", "/trash/%s/restore" % item)
        self.assertEqual((200, "Documents/a.txt"), (status, body["path"]))
        self.assertEqual("clear", self.fence())
        self.cloud.put("alice", "anj-cloud/Documents/b.txt")
        item = self.cloud.delete("alice", "anj-cloud/Documents/b.txt")
        self.cloud.fail["restore"] = "lost"
        status, body, _ = await self.call("POST", "/trash/%s/restore" % item)
        self.assertEqual((502, "The server did not restore this item"), (status, body["error"]))
        self.assertEqual("clear", self.fence())
        self.assertEqual(1, len(self.cloud.trash["alice"]))

    async def test_inconclusive_restore_keeps_writes_fenced(self):
        self.cloud.put("alice", "anj-cloud/Documents/a.txt")
        item = self.cloud.delete("alice", "anj-cloud/Documents/a.txt")
        self.cloud.fail["restore"] = "lost"
        original = self.gateway.trash.in_trash

        async def unreadable(device, entry):
            return None
        self.gateway.trash.in_trash = unreadable
        status, _, _ = await self.call("POST", "/trash/%s/restore" % item)
        self.assertEqual(503, status)
        self.assertEqual("dispatched", self.fence())
        self.gateway.trash.in_trash = original
        for method, path in (("POST", "/trash/%s/restore" % item), ("DELETE", "/trash/%s" % item), ("DELETE", "/trash/")):
            status, body, _ = await self.call(method, path)
            self.assertEqual(503, status, path)
        # Listing is a read: still served while fenced.
        self.assertEqual(1, len((await self.listed())["items"]))

    async def test_known_refusal_finishes_without_fencing(self):
        self.cloud.put("alice", "anj-cloud/Documents/a.txt")
        item = self.cloud.delete("alice", "anj-cloud/Documents/a.txt")
        self.cloud.fail["restore"] = 403
        status, _, _ = await self.call("POST", "/trash/%s/restore" % item)
        self.assertEqual(502, status)
        self.assertEqual("clear", self.fence())

    # Delete now and Empty (AC3).

    async def test_delete_now_and_empty_leave_items_outside_the_root(self):
        for name in ("a.txt", "b.txt", "c.txt"):
            self.cloud.put("alice", "anj-cloud/Documents/" + name)
        self.cloud.put("alice", "outside.txt")
        first = self.cloud.delete("alice", "anj-cloud/Documents/a.txt")
        self.cloud.delete("alice", "anj-cloud/Documents/b.txt")
        self.cloud.delete("alice", "outside.txt")
        self.cloud.delete("alice", "anj-cloud/Documents/c.txt")
        status, _, _ = await self.call("DELETE", "/trash/%s" % first)
        self.assertEqual(204, status)
        self.assertEqual(2, len((await self.listed())["items"]))
        status, body, _ = await self.call("DELETE", "/trash/")
        self.assertEqual((200, {"deleted": 2}), (status, body))
        self.assertEqual([], (await self.listed())["items"])
        self.assertEqual(["outside.txt"], [key.rsplit(".d", 1)[0] for key in self.cloud.trash["alice"]])
        self.assertEqual("clear", self.fence())

    async def test_lost_delete_answer_is_read_back(self):
        self.cloud.put("alice", "anj-cloud/Documents/a.txt")
        item = self.cloud.delete("alice", "anj-cloud/Documents/a.txt")
        self.cloud.fail["delete"] = "applied-lost"
        status, _, _ = await self.call("DELETE", "/trash/%s" % item)
        self.assertEqual((204, "clear"), (status, self.fence()))

    # Read-grant devices (AC7).

    async def test_read_grant_device_lists_but_cannot_restore_or_delete(self):
        self.cloud.put("alice", "anj-cloud/Documents/a.txt")
        item = self.cloud.delete("alice", "anj-cloud/Documents/a.txt")
        self.assertEqual([item], [row["id"] for row in (await self.listed("reader"))["items"]])
        for method, path in (("POST", "/trash/%s/restore" % item), ("DELETE", "/trash/%s" % item), ("DELETE", "/trash/")):
            status, body, _ = await self.call(method, path, "reader")
            self.assertEqual((403, "This device can only view"), (status, body["error"]), path)
        self.assertEqual(1, len(self.cloud.trash["alice"]))

    async def test_each_account_sees_only_its_own_trash(self):
        self.cloud.put("bob", "anj-cloud/Documents/bobs.txt")
        bobs = self.cloud.delete("bob", "anj-cloud/Documents/bobs.txt")
        self.assertEqual([], (await self.listed())["items"])
        status, _, _ = await self.call("POST", "/trash/%s/restore" % bobs)
        self.assertEqual(404, status)
        self.assertEqual(1, len(self.cloud.trash["bob"]))

    # Review fixes S1, S2, S4, S5, S6.

    async def test_restore_into_a_folder_the_caller_cannot_create_in_is_refused(self):
        self.cloud.put("alice", "anj-cloud/Shared/Proj/f.txt", b"shared")
        item = self.cloud.delete("alice", "anj-cloud/Shared/Proj/f.txt")
        self.cloud.readonly.add("anj-cloud/Shared/Proj")  # the share was turned View only
        status, body, _ = await self.call("POST", "/trash/%s/restore" % item)
        self.assertEqual((403, "You can't add to the folder this came from"), (status, body["error"]))
        self.assertEqual(1, len(self.cloud.trash["alice"]))
        self.assertNotIn("f.txt", self.cloud.tree["alice"])
        self.assertEqual("clear", self.fence())

    async def test_success_only_when_the_item_is_in_its_folder(self):
        self.cloud.put("alice", "anj-cloud/Documents/a.txt")
        item = self.cloud.delete("alice", "anj-cloud/Documents/a.txt")
        self.cloud.top_level = True
        status, body, _ = await self.call("POST", "/trash/%s/restore" % item)
        self.assertEqual(503, status)
        self.assertEqual("dispatched", self.fence())

    async def test_a_dropped_client_never_leaves_a_restore_half_done(self):
        self.cloud.put("alice", "anj-cloud/Documents/a.txt", b"bytes")
        item = self.cloud.delete("alice", "anj-cloud/Documents/a.txt")
        self.cloud.gate, self.cloud.reached = asyncio.Event(), asyncio.Event()
        client = asyncio.ensure_future(self.call("POST", "/trash/%s/restore" % item))
        await asyncio.wait_for(self.cloud.reached.wait(), 10)
        client.cancel()
        with self.assertRaises(asyncio.CancelledError):
            await client
        await asyncio.sleep(0.2)
        self.assertEqual("dispatched", self.fence())  # still running behind the shield
        self.cloud.gate.set()
        for _ in range(100):
            if not self.gateway.trash.tasks:
                break
            await asyncio.sleep(0.05)
        self.assertEqual(set(), self.gateway.trash.tasks)
        self.assertEqual("clear", self.fence())
        self.assertEqual(b"bytes", self.cloud.tree["alice"]["anj-cloud/Documents/a.txt"])

    async def test_a_missing_folder_is_recreated_beside_a_case_twin(self):
        # Spec #49 Gateway: a folder differing only by case is another folder, not a refusal.
        self.cloud.put("alice", "anj-cloud/Documents/Trip/photo.jpg")
        item = self.cloud.delete("alice", "anj-cloud/Documents/Trip/photo.jpg")
        self.cloud.delete("alice", "anj-cloud/Documents/Trip")
        self.cloud.put("alice", "anj-cloud/Documents/trip/other.jpg")
        status, _, _ = await self.call("POST", "/trash/%s/restore" % item)
        self.assertEqual(200, status)
        self.assertIn("anj-cloud/Documents/Trip/photo.jpg", self.cloud.tree["alice"])
        self.assertIn("anj-cloud/Documents/trip/other.jpg", self.cloud.tree["alice"])
        self.assertEqual("clear", self.fence())

    async def test_nothing_is_recreated_under_shared(self):
        self.cloud.put("alice", "anj-cloud/Shared/Proj/f.txt")
        item = self.cloud.delete("alice", "anj-cloud/Shared/Proj/f.txt")
        self.cloud.delete("alice", "anj-cloud/Shared/Proj")  # the share was left or renamed
        status, body, _ = await self.call("POST", "/trash/%s/restore" % item)
        self.assertEqual((409, "The share this came from is no longer here"), (status, body["error"]))
        self.assertNotIn("anj-cloud/Shared/Proj", self.cloud.tree["alice"])
        self.assertEqual("clear", self.fence())

    async def test_batch_restore_lists_once_and_answers_per_item(self):
        ids = []
        for name in ("a.txt", "b.txt"):
            self.cloud.put("alice", "anj-cloud/Documents/" + name, name.encode())
            ids.append(self.cloud.delete("alice", "anj-cloud/Documents/" + name))
        self.cloud.put("alice", "anj-cloud/Documents/b.txt", b"taken")
        listings = self.cloud.listings
        status, body, _ = await self.call("POST", "/trash/restore", body={"ids": ids + ["999"]})
        self.assertEqual(200, status)
        self.assertEqual(1, self.cloud.listings - listings)
        self.assertEqual([{"id": ids[0], "path": "Documents/a.txt", "renamed": False},
                          {"id": ids[1], "path": "Documents/b (restored).txt", "renamed": True},
                          {"id": "999", "error": "Not in Trash", "status": 404}], body["results"])
        self.assertEqual("clear", self.fence())
        for bad in ({"ids": []}, {"ids": ["x"]}, {"ids": ["1"], "more": 1}, {"ids": ["1"] * 501}):
            status, _, _ = await self.call("POST", "/trash/restore", body=bad)
            self.assertEqual(400, status, bad)
        status, _, _ = await self.call("POST", "/trash/restore", "reader", body={"ids": ids})
        self.assertEqual(403, status)


class OperatorTrashDaysTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.harness = Harness(listener="tcp")
        await self.harness.start()

    async def asyncTearDown(self):
        await self.harness.stop()

    async def admin(self, body):
        class Request:
            async def json(self):
                return body
        return json.loads((await self.harness.gateway.admin(Request())).text)

    async def test_operator_sets_and_reads_trash_days(self):
        self.assertEqual({"trash_days": 7}, await self.admin({"action": "trash-days"}))
        self.assertEqual({"trash_days": 14}, await self.admin({"action": "trash-days", "days": 14}))
        self.assertEqual(14, self.harness.gateway.trash.days)
        with self.assertRaises(Exception):
            await self.admin({"action": "trash-days", "days": "7"})
        with self.assertRaises(Exception):
            await self.admin({"action": "trash-days", "days": 7, "other": 1})


if __name__ == "__main__":
    unittest.main()
