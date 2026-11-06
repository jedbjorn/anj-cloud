"""Gateway-recorded added times (spec #24, decision #56): record, prune and the uid-scoped read endpoint.

The backend here is an in-process fake Nextcloud; the real-TLS endpoint tests use fixture CAs only.
"""

import asyncio
from pathlib import Path
import ssl
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import aiohttp
from aiohttp import ClientSession, DummyCookieJar, web
from aiohttp.test_utils import TestServer

from services.access.mutations import Mutations, file_id, OC_FILE_ID
from services.access.registry import Registry
from services.access.server import safe_errors
from cryptography.hazmat.primitives import serialization

# Discovery runs with tests/ as the top level (`unittest discover -s tests`). Import the module, not
# the class, so the inherited certificate-pickup suite is not collected a second time here.
import test_permanent_credentials as credentials
from test_access import csr
from test_permanent_credentials import Device, admin, leaf_id, pair, pem


class RegistryAddedTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.now = [1_800_000_000.0]
        self.registry = Registry(Path(self.temporary.name), clock=lambda: self.now[0])

    def tearDown(self):
        self.registry.db.close()
        self.temporary.cleanup()

    def test_first_record_wins(self):
        self.assertTrue(self.registry.record_added("alice", 646))
        self.now[0] += 60
        self.assertFalse(self.registry.record_added("alice", 646))
        self.assertEqual({"646": 1_800_000_000.0}, self.registry.added_since("alice")["added"])

    def test_rows_are_read_only_for_their_own_uid(self):
        self.registry.record_added("alice", 1)
        self.registry.record_added("bob", 2)
        self.registry.record_added("bob", 1)  # Same file ID under another account is a separate row.
        self.assertEqual({"1"}, set(self.registry.added_since("alice")["added"]))
        self.assertEqual({"1", "2"}, set(self.registry.added_since("bob")["added"]))
        self.assertEqual({}, self.registry.added_since("carol")["added"])

    def test_cursor_is_incremental_bounded_and_paged(self):
        for fileid in range(1, 8):
            self.registry.record_added("alice", fileid)
            self.registry.record_added("bob", 100 + fileid)
        first = self.registry.added_since("alice", 0, 3)
        self.assertEqual((["1", "2", "3"], True), (list(first["added"]), first["more"]))
        second = self.registry.added_since("alice", first["cursor"], 3)
        self.assertEqual((["4", "5", "6"], True), (list(second["added"]), second["more"]))
        third = self.registry.added_since("alice", second["cursor"], 3)
        self.assertEqual((["7"], False), (list(third["added"]), third["more"]))
        steady = self.registry.added_since("alice", third["cursor"])
        self.assertEqual(({}, third["cursor"], False, False), (steady["added"], steady["cursor"], steady["more"], steady["reset"]))
        self.registry.record_added("alice", 8)
        self.assertEqual(["8"], list(self.registry.added_since("alice", third["cursor"])["added"]))

    def test_a_page_never_exceeds_the_bound(self):
        with self.registry.db:
            self.registry.db.executemany("INSERT INTO files_added(uid,fileid,added_at) VALUES('alice',?,1)",
                                         [(n,) for n in range(1, Registry.ADDED_PAGE + 2)])
        page = self.registry.added_since("alice", 0, 10 ** 6)
        self.assertEqual((Registry.ADDED_PAGE, True), (len(page["added"]), page["more"]))
        rest = self.registry.added_since("alice", page["cursor"])
        self.assertEqual((1, False), (len(rest["added"]), rest["more"]))

    def test_prune_removes_only_that_row_and_never_reuses_a_cursor(self):
        self.registry.record_added("alice", 1)
        self.registry.record_added("alice", 2)
        cursor = self.registry.added_since("alice")["cursor"]
        self.registry.prune_added("alice", 2)
        self.registry.prune_added("bob", 1)  # Another account's prune never touches alice.
        self.assertEqual({"1"}, set(self.registry.added_since("alice")["added"]))
        self.registry.record_added("alice", 3)
        page = self.registry.added_since("alice", cursor)
        self.assertEqual(["3"], list(page["added"]))
        self.assertGreater(page["cursor"], cursor)

    def test_cursor_beyond_every_issued_sequence_asks_for_a_reset(self):
        self.assertTrue(self.registry.added_since("alice", 5)["reset"])
        self.registry.record_added("alice", 1)
        cursor = self.registry.added_since("alice")["cursor"]
        self.assertFalse(self.registry.added_since("alice", cursor)["reset"])
        self.assertTrue(self.registry.added_since("alice", cursor + 1)["reset"])

    def test_invalid_file_ids_are_refused_and_rows_survive_restart(self):
        for bad in (0, -1, 2 ** 63, "7", True, None):
            with self.assertRaises(ValueError):
                self.registry.record_added("alice", bad)
        self.registry.record_added("alice", 9)
        self.registry.db.close()
        self.registry = Registry(Path(self.temporary.name))
        self.assertEqual({"9": 1_800_000_000.0}, self.registry.added_since("alice")["added"])
        self.assertEqual(2, self.registry.db.execute("PRAGMA user_version").fetchone()[0])

    def test_oc_file_id_header_parsing(self):
        self.assertEqual(646, file_id("00000646ocz4vj02o1mi", OC_FILE_ID))
        self.assertEqual(646, file_id("646"))
        for bad in (None, "", "ocz4vj02o1mi", "00000000ocz4vj02o1mi", "646", "646 oc1", "-1oc1", "99999999999999999999oc1"):
            self.assertIsNone(file_id(bad, OC_FILE_ID), bad)


class FakeNextcloud:
    """Path -> (etag, fileid, collection). Responds like Nextcloud 33 for the gateway's calls."""

    def __init__(self):
        self.items = {}
        self.next_id = 640
        self.fail_put = None
        self.omit_file_id = False
        self.server = None

    def multistatus(self, item):
        etag, fileid, collection = item
        kind = "<d:collection/>" if collection else ""
        return ('<?xml version="1.0"?><d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns"><d:response>'
                '<d:href>/x</d:href><d:propstat><d:prop><d:getetag>' + etag + '</d:getetag><d:resourcetype>' + kind +
                '</d:resourcetype><oc:fileid>' + str(fileid) + '</oc:fileid></d:prop><d:status>HTTP/1.1 200 OK</d:status>'
                '</d:propstat></d:response></d:multistatus>').encode()

    def oc_file_id(self, fileid):
        return {} if self.omit_file_id else {"OC-FileId": "%08docinstance1" % fileid}

    async def handle(self, request):
        path = request.path.split("/anj-cloud/", 1)[1]
        item = self.items.get(path)
        if request.method == "PROPFIND":
            return web.Response(status=207, body=self.multistatus(item)) if item else web.Response(status=404)
        if request.method == "PUT":
            await request.read()
            if self.fail_put:
                return web.Response(status=self.fail_put)
            self.next_id += 1 if item is None else 0
            fileid = item[1] if item else self.next_id
            self.items[path] = ('"v%d-%s"' % (fileid, len(self.items)), fileid, False)
            return web.Response(status=204 if item else 201, headers=self.oc_file_id(fileid))
        if request.method == "MKCOL":
            self.next_id += 1
            self.items[path] = ('"d%d"' % self.next_id, self.next_id, True)
            return web.Response(status=201, headers=self.oc_file_id(self.next_id))
        if request.method == "MOVE":
            target = request.headers["Destination"].split("/anj-cloud/", 1)[1]
            self.items[target] = self.items.pop(path)
            return web.Response(status=201, headers=self.oc_file_id(self.items[target][1]))
        if request.method == "DELETE":
            del self.items[path]
            return web.Response(status=204)
        return web.Response(status=405)

    async def start(self):
        app = web.Application()
        app.router.add_route("*", "/{path:.*}", self.handle)
        self.server = TestServer(app)
        await self.server.start_server()
        return str(self.server.make_url("")).rstrip("/")


def activate(registry, uid="alice"):
    invite = registry.invite(uid, "write")
    pending = registry.enroll(invite["code"], csr())
    registry.begin(pending["pairing_id"], pending["fingerprint"])
    registry.activate(pending["pairing_id"], pending["fingerprint"], "synthetic", "1", "public", registry.clock() + 1000, "leaf-" + uid)
    return registry.device(pending["device_id"])


class MutationRecordingTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.now = [1_800_000_000.0]
        self.registry = Registry(self.temporary.name, clock=lambda: self.now[0])
        self.backend = FakeNextcloud()
        base = await self.backend.start()
        self.session = ClientSession(cookie_jar=DummyCookieJar())
        self.gateway = SimpleNamespace(registry=self.registry, session=self.session, backend=base,
                                       origin="https://127.0.0.1:8834", throttle=0)
        self.mutations = Mutations(self.gateway)
        self.device = activate(self.registry)

    async def asyncTearDown(self):
        await self.session.close()
        await self.backend.server.close()
        self.registry.db.close()
        self.temporary.cleanup()

    async def send(self, method, relative, body=b"", headers=None):
        headers = dict(headers or {})

        async def chunks(_):
            if body:
                yield body
        request = SimpleNamespace(method=method, content_length=len(body) if method == "PUT" else None,
                                  content=SimpleNamespace(iter_chunked=chunks), headers=headers, can_read_body=False)
        forwarded = {key: value for key, value in headers.items() if key != "Destination"}
        if method == "MOVE":
            forwarded["Destination"] = self.gateway.backend + "/remote.php/dav/files/alice/anj-cloud/" + headers["Destination"]
        if method == "PUT":
            forwarded["Content-Length"] = str(len(body))
        return await self.mutations.run(request, self.device, relative, forwarded)

    def added(self, uid="alice"):
        return self.registry.added_since(uid)["added"]

    async def test_new_put_is_recorded_once_with_the_gateway_clock(self):
        response = await self.send("PUT", "Documents/a.txt", b"one", {"If-None-Match": "*"})
        self.assertEqual(201, response.status)
        self.assertNotIn("OC-FileId", response.headers)  # Response headers are unchanged by recording.
        self.assertEqual({"641": 1_800_000_000.0}, self.added())
        self.now[0] += 100
        etag = self.backend.items["Documents/a.txt"][0]
        overwrite = await self.send("PUT", "Documents/a.txt", b"two", {"If-Match": etag})
        self.assertEqual(204, overwrite.status)
        self.assertEqual({"641": 1_800_000_000.0}, self.added())

    async def test_move_mkcol_and_failed_put_record_nothing(self):
        self.assertEqual(201, (await self.send("MKCOL", "Documents/folder", headers={"If-None-Match": "*"})).status)
        await self.send("PUT", "Documents/a.txt", b"one", {"If-None-Match": "*"})
        recorded = self.added()
        self.now[0] += 100
        etag = self.backend.items["Documents/a.txt"][0]
        moved = await self.send("MOVE", "Documents/a.txt", headers={"If-Match": etag, "Overwrite": "F", "Destination": "Documents/folder/b.txt"})
        self.assertEqual(201, moved.status)
        self.backend.fail_put = 507
        failed = await self.send("PUT", "Documents/c.txt", b"three", {"If-None-Match": "*"})
        self.assertEqual(507, failed.status)
        self.assertEqual(recorded, self.added())
        self.assertEqual(1, len(recorded))

    async def test_missing_header_or_failed_record_leaves_the_upload_response_unchanged(self):
        self.backend.omit_file_id = True
        response = await self.send("PUT", "Documents/a.txt", b"one", {"If-None-Match": "*"})
        self.assertEqual(201, response.status)
        self.assertEqual({}, self.added())
        self.assertEqual(1, self.mutations.added_failures)
        self.backend.omit_file_id = False
        with patch.object(self.registry, "record_added", side_effect=RuntimeError("disk full")):
            response = await self.send("PUT", "Documents/b.txt", b"two", {"If-None-Match": "*"})
        self.assertEqual(201, response.status)
        self.assertEqual(2, self.mutations.added_failures)
        self.assertTrue(self.registry.mutation_ready())  # The write fence is clear after both uploads.
        self.assertEqual({}, self.added())

    async def test_upload_refused_for_its_size_records_nothing(self):
        # SC-028 refuses an oversized declared length before any backend request.
        self.mutations.limit = 4
        with self.assertRaises(web.HTTPRequestEntityTooLarge):
            await self.send("PUT", "Documents/big.txt", b"too large", {"If-None-Match": "*"})
        self.assertNotIn("Documents/big.txt", self.backend.items)
        self.assertEqual(({}, 0), (self.added(), self.mutations.added_failures))
        self.assertTrue(self.registry.mutation_ready())

    async def test_delete_prunes_the_row(self):
        await self.send("PUT", "Documents/a.txt", b"one", {"If-None-Match": "*"})
        await self.send("PUT", "Documents/keep.txt", b"two", {"If-None-Match": "*"})
        self.assertEqual(2, len(self.added()))
        etag = self.backend.items["Documents/a.txt"][0]
        self.assertEqual(204, (await self.send("DELETE", "Documents/a.txt", headers={"If-Match": etag})).status)
        self.assertEqual({"642"}, set(self.added()))


class FilesAddedEndpointTests(credentials.EndpointTests):
    """Real mutual TLS against GET /v1/files/added (the harness of the certificate pickup tests)."""

    async def asyncSetUp(self):
        await super().asyncSetUp()
        await self.runner.cleanup()
        app = web.Application(middlewares=[safe_errors])
        app.router.add_get("/v1/files/added", self.gateway.files_added)
        context = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(self.directory / "server.crt", self.directory / "server.key")
        context.load_verify_locations(self.authority.crt)
        context.verify_mode = ssl.CERT_OPTIONAL
        self.runner = web.AppRunner(app, access_log=None)
        await self.runner.setup()
        await web.TCPSite(self.runner, "127.0.0.1", self.port, ssl_context=context).start()

    async def added(self, device=None, certificate=None, query=""):
        context = ssl.create_default_context(cafile=str(self.authority.crt))
        if device:
            prefix = self.directory / ("client-" + leaf_id(certificate)[:12])
            prefix.with_suffix(".crt").write_text(pem(certificate))
            prefix.with_suffix(".key").write_bytes(device.key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                                                            serialization.NoEncryption()))
            context.load_cert_chain(prefix.with_suffix(".crt"), prefix.with_suffix(".key"))
        async with aiohttp.ClientSession(connector=aiohttp.TCPConnector(ssl=context), trust_env=False) as session:
            async with session.get(f"https://127.0.0.1:{self.port}/v1/files/added" + query, allow_redirects=False) as response:
                return response.status, (await response.json(content_type=None) if response.status == 200 else None), response.headers

    async def test_each_device_reads_only_its_own_accounts_rows_incrementally(self):
        alice, bob = Device(), Device()
        _, alice_leaf = pair(self.gateway.registry, self.authority, alice, "alice")
        _, bob_leaf = pair(self.gateway.registry, self.authority, bob, "bob")
        registry = self.gateway.registry
        registry.record_added("alice", 10)
        registry.record_added("bob", 20)
        registry.record_added("alice", 11)
        status, body, headers = await self.added(alice, alice_leaf)
        self.assertEqual((200, {"10", "11"}, False, "no-store"), (status, set(body["added"]), body["more"], headers["Cache-Control"]))
        status, other, _ = await self.added(bob, bob_leaf)
        self.assertEqual({"20"}, set(other["added"]))
        cursor = body["cursor"]
        status, steady, _ = await self.added(alice, alice_leaf, f"?after={cursor}")
        self.assertEqual((200, {}, cursor), (status, steady["added"], steady["cursor"]))
        registry.record_added("alice", 12)
        _, increment, _ = await self.added(alice, alice_leaf, f"?after={cursor}&limit=1")
        self.assertEqual(["12"], list(increment["added"]))
        _, page, _ = await self.added(alice, alice_leaf, "?limit=1")
        self.assertEqual((["10"], True), (list(page["added"]), page["more"]))

    async def test_unauthenticated_revoked_and_malformed_requests_are_refused(self):
        status, _, _ = await self.added()
        self.assertEqual(401, status)
        device = Device()
        identity, leaf = pair(self.gateway.registry, self.authority, device, "alice")
        for query in ("?after=-1", "?after=x", "?limit=0", "?limit=1001", "?uid=bob", "?after=1&after=2", "?after=99999999999999999999",
                      "?after=9223372036854775808"):
            status, _, _ = await self.added(device, leaf, query)
            self.assertEqual(400, status, query)
        await admin(self.gateway, "revoke", device_id=identity)
        status, _, _ = await self.added(device, leaf)
        self.assertEqual(403, status)

    async def test_served_while_writes_are_fenced(self):
        device = Device()
        identity, leaf = pair(self.gateway.registry, self.authority, device, "alice")
        self.gateway.registry.record_added("alice", 5)
        self.gateway.registry.mutation_begin(identity, "Documents/x")
        self.assertFalse(self.gateway.registry.mutation_ready())
        status, body, _ = await self.added(device, leaf)
        self.assertEqual((200, {"5"}), (status, set(body["added"])))

    # The inherited certificate-pickup tests target a route this app does not serve.
    test_device_fetches_only_its_own_current_leaf_and_old_leaf_works_until_new_is_used = None
    test_no_client_certificate_is_401_and_revoked_device_is_refused_for_both_leaves = None
    test_expired_leaf_is_refused = None


if __name__ == "__main__":
    unittest.main()
