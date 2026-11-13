"""File names: the #120 shared vectors, and what the gateway accepts (spec #49 Gateway, AC9).

The vectors in name_policy_vectors.json are also run by the client's NamePolicy
(apps/client/test/name_policy_test.dart). The gateway tests run the real Gateway.dav and
Mutations against an in-process fake Nextcloud that lists folders like Nextcloud 33.
"""

import asyncio
from collections import defaultdict
import json
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unicodedata
import unittest
from urllib.parse import quote, unquote

from aiohttp import ClientSession, DummyCookieJar, web
from aiohttp.test_utils import TestServer

from services.access import name_tables, portable_names
from services.access.mutations import Mutations, split_leaf
from services.access.registry import Registry
from services.access.server import Gateway, safe_errors
from services.access.sharing import ShareError, Sharing
from test_files_added import activate

ROOT = Path(__file__).resolve().parent.parent
VECTORS = json.loads((ROOT / "tests/name_policy_vectors.json").read_text(encoding="utf-8"))
ORIGIN = "https://127.0.0.1:8834"


class SharedVectorTests(unittest.TestCase):
    def test_checks_match_the_shared_vectors(self):
        for vector in VECTORS["check"]:
            with self.subTest(name=vector["name"]):
                self.assertEqual(vector["reason"], portable_names.check(vector["name"]))

    def test_fold_keys_match_the_shared_vectors(self):
        self.assertGreater(len(VECTORS["fold"]), 1000)
        for vector in VECTORS["fold"]:
            with self.subTest(name=vector["name"]):
                self.assertEqual(vector["key"], portable_names.fold_key(vector["name"]))

    def test_clashes_match_the_shared_vectors(self):
        for vector in VECTORS["clash"]:
            with self.subTest(name=vector["name"], siblings=vector["siblings"]):
                self.assertEqual(vector["clash"], portable_names.clash(vector["name"], vector["siblings"]))

    def test_every_reason_is_covered_and_described(self):
        reasons = {vector["reason"] for vector in VECTORS["check"]} - {None}
        self.assertEqual(set(portable_names.REASONS) - {"clash"}, reasons)
        self.assertEqual(set(portable_names.REASONS), set(portable_names.TEXT))

    def test_tables_and_vectors_are_generated_from_one_unicode_version(self):
        self.assertEqual(VECTORS["unicode"], name_tables.UNICODE_VERSION)
        dart = (ROOT / "apps/client/lib/core/sync/name_tables.dart").read_text(encoding="utf-8")
        self.assertIn("const nameTablesUnicodeVersion = '%s';" % name_tables.UNICODE_VERSION, dart)
        if unicodedata.unidata_version != name_tables.UNICODE_VERSION:
            self.skipTest("this Python's Unicode %s differs from the tables' %s" % (unicodedata.unidata_version, name_tables.UNICODE_VERSION))
        result = subprocess.run([sys.executable, str(ROOT / "tests/name_policy_gen.py"), "--check"], capture_output=True, text=True)
        self.assertEqual(0, result.returncode, result.stderr)

    def test_fold_key_equals_canonical_caseless_matching_for_every_code_point(self):
        if unicodedata.unidata_version != name_tables.UNICODE_VERSION:
            self.skipTest("reference Unicode version differs")
        for cp in [*range(0, 0xD800), *range(0xE000, 0x30000), *range(0xE0000, 0xE0080)]:
            char = chr(cp)
            expected = unicodedata.normalize("NFD", unicodedata.normalize("NFD", char).casefold())
            if portable_names.fold_key(char) != expected:
                self.fail("U+%04X folds differently" % cp)


class FakeNextcloud:
    """Decoded path -> {'etag', 'collection'}; PROPFIND Depth 0 and 1, PUT, MKCOL, MOVE, DELETE, GET."""

    def __init__(self):
        self.items = {"Documents": {"etag": '"d1"', "collection": True}}
        self.calls = []
        self.counter = 0
        self.listing_padding = 0

    def href(self, path, collection):
        segments = "/".join(quote(part, safe="-._~") for part in path.split("/")) if path else ""
        return "/remote.php/dav/files/alice/anj-cloud/" + segments + ("/" if collection and path else "")

    def response(self, path):
        item = self.items[path] if path else {"etag": '"root"', "collection": True}
        kind = "<d:collection/>" if item["collection"] else ""
        return ("<d:response><d:href>" + self.href(path, item["collection"]) + "</d:href><d:propstat><d:prop><d:getetag>"
                + item["etag"] + "</d:getetag><d:resourcetype>" + kind + "</d:resourcetype><oc:fileid>7</oc:fileid></d:prop>"
                "<d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>")

    def multistatus(self, parts):
        return ('<?xml version="1.0"?><d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">' + "".join(parts)
                + "<!--" + "x" * self.listing_padding + "--></d:multistatus>").encode()

    def path(self, raw):
        return unquote(raw.split("/anj-cloud/", 1)[1]).rstrip("/")

    def store(self, path, collection):
        self.counter += 1
        self.items[path] = {"etag": '"v%d"' % self.counter, "collection": collection}

    async def handle(self, request):
        path = self.path(request.raw_path)
        self.calls.append((request.method, request.headers.get("Depth"), path))
        exists = path == "" or path in self.items
        if request.method == "PROPFIND":
            if not exists:
                return web.Response(status=404)
            parts = [self.response(path)]
            if request.headers.get("Depth") == "1":
                prefix = path + "/" if path else ""
                parts += [self.response(child) for child in sorted(self.items)
                          if child.startswith(prefix) and "/" not in child[len(prefix):]]
            return web.Response(status=207, body=self.multistatus(parts))
        parent = path.rpartition("/")[0]
        if request.method in {"PUT", "MKCOL"}:
            await request.read()
            if parent and parent not in self.items:
                return web.Response(status=409)
            created = path not in self.items
            self.store(path, request.method == "MKCOL")
            return web.Response(status=201 if created else 204, headers={"ETag": self.items[path]["etag"], "OC-FileId": "00000007ocinst"})
        if request.method == "MOVE":
            target = self.path(request.headers["Destination"])
            if target in self.items:
                return web.Response(status=412)
            self.items[target] = self.items.pop(path)
            return web.Response(status=201)
        if request.method == "DELETE":
            self.items.pop(path, None)
            return web.Response(status=204)
        if request.method == "GET":
            return web.Response(body=b"bytes", headers={"ETag": self.items[path]["etag"]})
        return web.Response(status=405)


class GatewayNameTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.registry = Registry(self.temporary.name)
        self.device = activate(self.registry)
        self.nextcloud = FakeNextcloud()
        backend = web.Application()
        backend.router.add_route("*", "/{path:.*}", self.nextcloud.handle)
        self.backend = TestServer(backend)
        await self.backend.start_server()
        self.session = ClientSession(cookie_jar=DummyCookieJar(), auto_decompress=False)
        gateway = Gateway.__new__(Gateway)
        gateway.registry, gateway.backend, gateway.origin = self.registry, str(self.backend.make_url("")).rstrip("/"), ORIGIN
        gateway.active, gateway.transports, gateway.throttle = defaultdict(set), defaultdict(set), 0
        gateway.session = self.session
        gateway.mutations = Mutations(gateway)
        gateway.identity = lambda request: self.device
        self.gateway = gateway
        app = web.Application(middlewares=[safe_errors])
        app.router.add_route("*", "/dav/{path:.*}", gateway.dav)
        self.server = TestServer(app)
        await self.server.start_server()
        self.client = ClientSession(cookie_jar=DummyCookieJar())

    async def asyncTearDown(self):
        await self.client.close()
        await self.server.close()
        await self.session.close()
        await self.backend.close()
        self.registry.db.close()
        self.temporary.cleanup()

    def url(self, relative):
        return str(self.server.make_url("/dav/" + "/".join(quote(part, safe="-._~") for part in relative.split("/"))))

    async def send(self, method, relative, body=b"", **headers):
        if "Destination" in headers:
            headers["Destination"] = ORIGIN + "/dav/" + "/".join(quote(part, safe="-._~") for part in headers["Destination"].split("/"))
        async with self.client.request(method, self.url(relative), data=body if method == "PUT" else None, headers=headers) as response:
            text = await response.read()
            return response.status, (json.loads(text) if response.content_type == "application/json" else text)

    async def create(self, relative, body=b"data"):
        return await self.send("PUT", relative, body, **{"If-None-Match": "*"})

    def writes(self):
        return [call for call in self.nextcloud.calls if call[0] not in {"PROPFIND", "GET"}]

    def assert_refused(self, result, reason):
        status, body = result
        self.assertEqual(422, status)
        self.assertEqual({"error", "reason", "message"}, set(body))
        self.assertEqual(("name-not-portable", reason), (body["error"], body["reason"]))
        self.assertTrue(body["message"].startswith("Name not allowed in the cloud."))
        self.assertNotIn("Documents", body["message"])
        self.assertTrue(self.registry.mutation_ready())
        self.assertEqual(set(), self.gateway.mutations.tasks)

    def move(self, source, target):
        etag = self.nextcloud.items[source]["etag"]
        return self.send("MOVE", source, Destination=target, Overwrite="F", **{"If-Match": etag})

    async def test_untrimmed_and_unstorable_new_names_are_refused_before_any_backend_request(self):
        cases = {" leading.txt": "untrimmed", "trailing.txt ": "untrimmed", "Folder ": "untrimmed",
                 "\u00a0nbsp.txt": "untrimmed", "ideographic\u3000": "untrimmed", ".htaccess": "forbiddenName",
                 ".HTACCESS": "forbiddenName", "movie.part": "forbiddenExtension", "Disc.FilePart": "forbiddenExtension",
                 "e" * 247 + ".txt": "tooLong", "é" * 126: "tooLong"}
        for name, reason in cases.items():
            with self.subTest(name=name):
                self.assert_refused(await self.create("Documents/" + name), reason)
                self.assert_refused(await self.send("MKCOL", "Documents/" + name, **{"If-None-Match": "*"}), reason)
        self.assertEqual([], self.nextcloud.calls)
        self.assertEqual([], list(self.gateway.mutations.directory.iterdir()))

    async def test_formerly_blocked_names_are_accepted_exactly(self):
        names = ["a:b?.txt", "CON.txt", "CON", "nul", "Lpt9.log", "x.", "report.", 'quote".txt', "star*.txt", "pipe|.txt",
                 "lt<.txt", "gt>.txt", "Report.pdf", "report.pdf", "REPORT.PDF", "caf\u00e9.txt", "cafe\u0301.txt",
                 "e" * 246 + ".txt", "雪 #1 100%.txt", ".bashrc", "name .pdf", "a.b.c"]
        for name in names:
            with self.subTest(name=name):
                self.assertEqual(201, (await self.create("Documents/" + name))[0])
        for name in ("AUX", "trip.", "Notes", "notes"):
            with self.subTest(name=name):
                self.assertEqual(201, (await self.send("MKCOL", "Documents/" + name, **{"If-None-Match": "*"}))[0])
        expected = {"Documents/" + name for name in names + ["AUX", "trip.", "Notes", "notes"]}
        self.assertEqual(expected | {"Documents"}, set(self.nextcloud.items))
        # Nothing compares a new name with its siblings any more: no folder listing.
        self.assertEqual([], [call for call in self.nextcloud.calls if call[:2] == ("PROPFIND", "1")])

    async def test_move_destinations_follow_the_same_rule(self):
        await self.create("Documents/draft.txt")
        await self.create("Documents/Other.txt")
        await self.send("MKCOL", "Archive", **{"If-None-Match": "*"})
        await self.create("Archive/Draft.txt")
        self.assert_refused(await self.move("Documents/draft.txt", "Documents/draft.txt "), "untrimmed")
        self.assert_refused(await self.move("Documents/draft.txt", "Documents/ draft.txt"), "untrimmed")
        self.assert_refused(await self.move("Documents/draft.txt", "Documents/draft.part"), "forbiddenExtension")
        self.assertIn("Documents/draft.txt", self.nextcloud.items)
        for source, target in (("Documents/draft.txt", "Documents/PRN.txt"), ("Documents/PRN.txt", "Documents/draft."),
                               ("Documents/draft.", "Documents/other.txt"), ("Documents/other.txt", "Archive/draft.txt"),
                               ("Archive/draft.txt", "Archive/a:b?.txt")):
            with self.subTest(target=target):
                self.assertEqual(201, (await self.move(source, target))[0])
        self.assertEqual({"Documents", "Documents/Other.txt", "Archive", "Archive/Draft.txt", "Archive/a:b?.txt"},
                         set(self.nextcloud.items))

    async def test_existing_untrimmed_names_stay_readable_writable_movable_and_deletable(self):
        self.nextcloud.store("Documents/old ", False)
        self.nextcloud.store("Documents/ older", False)
        etag = self.nextcloud.items["Documents/old "]["etag"]
        self.assertEqual(200, (await self.send("GET", "Documents/old "))[0])
        self.assertEqual(207, (await self.send("PROPFIND", "Documents", Depth="1"))[0])
        self.assertEqual(204, (await self.send("PUT", "Documents/old ", b"edit", **{"If-Match": etag}))[0])
        self.assertEqual(201, (await self.move("Documents/old ", "Documents/old"))[0])  # The cleanup rename.
        etag = self.nextcloud.items["Documents/ older"]["etag"]
        self.assertEqual(204, (await self.send("DELETE", "Documents/ older", **{"If-Match": etag}))[0])
        self.assertEqual({"Documents", "Documents/old"}, set(self.nextcloud.items))

    async def test_concurrent_creates_differing_by_case_are_all_accepted(self):
        names = ["Documents/report.txt", "Documents/Report.txt", "Documents/REPORT.txt"]
        results = await asyncio.gather(*(self.create(name) for name in names))
        self.assertEqual([201, 201, 201], [status for status, _ in results])
        self.assertEqual(set(names), {path for path in self.nextcloud.items if path.lower() == "documents/report.txt"})

    async def test_missing_parent_is_the_backends_answer(self):
        status, _ = await self.create("Missing/a.txt")
        self.assertEqual(409, status)
        self.assertTrue(self.registry.mutation_ready())

    async def test_read_only_and_root_rules_are_unchanged(self):
        self.device = {**self.device, "rights": "read"}
        self.assertEqual(403, (await self.create("Documents/CON"))[0])
        self.assertEqual(403, (await self.create("Documents/ x"))[0])
        self.assertEqual([], self.nextcloud.calls)

    def test_refused_is_cloud_check_on_the_final_name(self):
        self.assertEqual("untrimmed", Mutations.refused("Documents%20/x%20"))
        self.assertIsNone(Mutations.refused("Documents%20/x"))
        self.assertIsNone(Mutations.refused("a/CON.txt"))

    def test_split_leaf(self):
        self.assertEqual(("", "a b"), split_leaf("a%20b"))
        self.assertEqual(("Documents/", "x"), split_leaf("Documents/x/"))
        self.assertEqual(("a/b/", "c?.txt"), split_leaf("a/b/c%3F.txt"))


class ShareNameTests(unittest.TestCase):
    def test_a_folder_whose_name_the_cloud_refuses_is_not_shared(self):
        for path, reason in (("Trips ", "untrimmed"), ("Photos/ aux", "untrimmed"), ("a/Disc.part", "forbiddenExtension")):
            with self.subTest(path=path), self.assertRaises(ShareError) as caught:
                Sharing.directory(path)
            self.assertEqual((422, "name-not-portable", reason), (caught.exception.status, caught.exception.detail["code"],
                                                                 caught.exception.detail["reason"]))
            self.assertNotIn(path, caught.exception.message)
        # Formerly blocked names are shared (spec #49 Gateway).
        for path in ("CON", "Photos/aux.d", "Trips.", "a/b:c", "Photos/.trip"):
            with self.subTest(path=path):
                self.assertEqual(("/anj-cloud/" + path, "/".join(quote(p, safe="-._~") for p in path.split("/"))),
                                 Sharing.directory(path))
        # An untrimmed parent does not block a clean child: only the mount's own name matters.
        self.assertEqual("/anj-cloud/Trips /Photos", Sharing.directory("Trips /Photos")[0])

    def test_the_error_body_carries_the_code_and_reason(self):
        async def handler(request):
            Sharing.directory("Trips ")

        async def run():
            app = web.Application(middlewares=[safe_errors])
            app.router.add_post("/v1/shares", handler)
            server = TestServer(app)
            await server.start_server()
            try:
                async with ClientSession() as session, session.post(server.make_url("/v1/shares")) as response:
                    return response.status, await response.json()
            finally:
                await server.close()

        status, body = asyncio.run(run())
        self.assertEqual(422, status)
        self.assertEqual(("name-not-portable", "untrimmed"), (body["code"], body["reason"]))
        self.assertIn("not allowed in the cloud", body["error"])


if __name__ == "__main__":
    unittest.main()
