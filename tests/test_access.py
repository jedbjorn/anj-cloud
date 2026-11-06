"""Deterministic protocol/registry checks supplement the real TLS integration fixture."""

import tempfile
import unittest
import asyncio
import json
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID

from services.access import protocol
from services.access.registry import Registry
from services.access.server import Gateway
from services.access.server import safe_errors
from aiohttp import BasicAuth, web
from aiohttp.test_utils import TestServer
from aiohttp.test_utils import TestClient
from aiohttp import ClientSession, DummyCookieJar
from deploy.access_operator import Operator
from services.access.mutations import Mutations


def csr():
    key = ec.generate_private_key(ec.SECP256R1())
    request = x509.CertificateSigningRequestBuilder().subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "untrusted label")])).sign(key, hashes.SHA256())
    return request.public_bytes(serialization.Encoding.PEM).decode()


class AccessTests(unittest.TestCase):
    def test_invitation_encoding_and_qr_manual_normalization(self):
        self.assertEqual("0" * 32, protocol.code_from_bytes(bytes(20)))
        self.assertEqual("Z" * 32, protocol.code_from_bytes(bytes([255] * 20)))
        value = protocol.code_from_bytes(bytes(range(20)))
        manual = "-".join(value[i:i+4] for i in range(0, 32, 4)).lower()
        self.assertEqual(value, protocol.normalize_code(manual))
        for bad in ("I" * 32, "0" * 31, "0" * 33):
            with self.assertRaises(ValueError):
                protocol.normalize_code(bad)

    def test_reservation_retries_expiry_restart_and_denial(self):
        now = [1000.0]
        with tempfile.TemporaryDirectory() as directory:
            registry = Registry(directory, clock=lambda: now[0])
            invite = registry.invite("alice", "write")
            request = csr()
            first = registry.enroll(invite["code"], request)
            self.assertEqual(first, registry.enroll(invite["code"].lower(), request))
            with self.assertRaises(ValueError):
                registry.enroll(invite["code"], csr())
            with self.assertRaises(ValueError):
                registry.begin(first["pairing_id"], "0" * 64)
            registry.db.close()
            registry = Registry(directory, clock=lambda: now[0])
            self.assertEqual(first, registry.enroll(invite["code"], request))
            now[0] = 1600
            self.assertEqual("expired", registry.enroll(invite["code"], request)["state"])
            with self.assertRaises(ValueError):
                registry.begin(first["pairing_id"], first["fingerprint"])
            another = registry.invite("bob", "read")
            pending = registry.enroll(another["code"], csr())
            registry.deny(pending["pairing_id"])
            self.assertEqual("denied", registry.enroll(another["code"], csr())["state"])
            registry.db.close()

    def test_activation_boundary_and_completed_retrieval_never_resurrects(self):
        now = [1000.0]
        with tempfile.TemporaryDirectory() as directory:
            registry = Registry(directory, clock=lambda: now[0])
            invite, request = registry.invite("alice", "write"), csr()
            pending = registry.enroll(invite["code"], request)
            registry.begin(pending["pairing_id"], pending["fingerprint"])
            registry.activate(pending["pairing_id"], pending["fingerprint"], "private-token", "42", "public-cert", 3000, "leaf-one")
            now[0] = 2000
            self.assertEqual("public-cert", registry.enroll(invite["code"], request)["certificate"])
            registry.disable(pending["device_id"])
            self.assertEqual("revoked", registry.enroll(invite["code"], request)["state"])
            with self.assertRaises(ValueError):
                registry.admit(pending["fingerprint"], "leaf-one")
            late = registry.invite("bob", "write")
            pending = registry.enroll(late["code"], csr())
            registry.begin(pending["pairing_id"], pending["fingerprint"])
            now[0] = late["expires"]
            with self.assertRaises(ValueError):
                registry.activate(pending["pairing_id"], pending["fingerprint"], "private", "43", "cert", 5000, "leaf-two")
            registry.db.close()

    def test_path_boundaries_and_same_origin_move(self):
        self.assertEqual("Music/a%20b.txt", protocol.canonical_path("Music/a%20b.txt"))
        self.assertEqual("", protocol.canonical_path(""))
        for path in ("../private", "%2e%2e/private", "a%2fb", "a//b", "a\\b", "a%00", "a%ff", "a%", "/outside"):
            with self.assertRaises((ValueError, UnicodeError)):
                protocol.canonical_path(path)
        origin = "https://127.0.0.1:8834"
        self.assertEqual("Music/target", protocol.move_destination(origin + "/dav/Music/target", origin))
        for destination in ("https://foreign/dav/x", origin + "/outside", origin + "/dav/../x"):
            with self.assertRaises(ValueError):
                protocol.move_destination(destination, origin)

    def test_cleanup_obligation_and_fence_clear_commit_atomically(self):
        class Interrupted(BaseException):
            pass
        for boundary in ("before-clear", "after-commit"):
            with self.subTest(boundary=boundary), tempfile.TemporaryDirectory() as directory:
                registry = Registry(directory)
                registry.mutation_begin("fixture-device", "operator-sharing")
                connection = registry.db
                class Connection:
                    def execute(self, sql, *args):
                        if boundary == "before-clear" and sql.startswith("UPDATE mutation_fence"):
                            raise Interrupted()
                        return connection.execute(sql, *args)
                    def commit(self):
                        connection.commit()
                        if boundary == "after-commit":
                            raise Interrupted()
                    def rollback(self):
                        connection.rollback()
                with patch.object(registry, "db", Connection()):
                    with self.assertRaises(Interrupted):
                        registry.note_share_cleanup_and_finish("42", "fixture-device")
                rows = registry.db.execute("SELECT share_id FROM share_cleanup").fetchall()
                # Never expose a ready fence while losing the known cleanup obligation.
                self.assertFalse(registry.mutation_ready() and not rows)
                self.assertEqual(boundary == "after-commit", registry.mutation_ready())
                registry.db.close()

    def test_same_key_repair_binds_exact_new_leaf_without_revoked_leaf_resurrection(self):
        with tempfile.TemporaryDirectory() as directory:
            now = [1000]
            registry = Registry(directory, clock=lambda: now[0])
            request = csr()
            def activate(leaf):
                invite = registry.invite("alice", "write")
                pending = registry.enroll(invite["code"], request)
                registry.begin(pending["pairing_id"], pending["fingerprint"])
                registry.activate(pending["pairing_id"], pending["fingerprint"], "private", leaf, "public", now[0] + 2000, leaf)
                return pending
            first = activate("old-leaf")
            registry.disable(first["device_id"])
            second = activate("new-leaf")
            self.assertNotEqual(first["device_id"], second["device_id"])
            with self.assertRaises(ValueError):
                registry.admit(first["fingerprint"], "old-leaf")
            self.assertEqual(second["device_id"], registry.admit(second["fingerprint"], "new-leaf")["id"])
            now[0] = 4000
            third = activate("replacement-after-expiry")
            with self.assertRaises(ValueError):
                registry.admit(second["fingerprint"], "new-leaf")
            self.assertEqual(third["device_id"], registry.admit(third["fingerprint"], "replacement-after-expiry")["id"])
            registry.db.close()

    def test_multistatus_rewrite_rejects_foreign_references_and_dtd(self):
        body = b'<d:multistatus xmlns:d="DAV:"><d:response><d:href>/remote.php/dav/files/alice/anj-cloud/Music/a%20b</d:href><d:propstat><d:prop><d:getetag>"version"</d:getetag></d:prop></d:propstat></d:response></d:multistatus>'
        result = protocol.rewrite_multistatus(body, "alice", "https://127.0.0.1:8834", "http://nextcloud")
        self.assertIn(b"https://127.0.0.1:8834/dav/Music/a%20b", result)
        self.assertNotIn(b"/remote.php", result)
        with self.assertRaises(ValueError):
            protocol.rewrite_multistatus(body.replace(b"alice/anj-cloud", b"bob/private"), "alice", "https://127.0.0.1:8834", "http://nextcloud")
        with self.assertRaises(Exception):
            protocol.rewrite_multistatus(b'<!DOCTYPE x [<!ENTITY a "bad">]><x>&a;</x>', "alice", "https://127.0.0.1:8834", "http://nextcloud")


if __name__ == "__main__":
    unittest.main()


class BackendIsolationTests(unittest.IsolatedAsyncioTestCase):
    async def test_sharing_fence_requires_confirmed_reconciliation_and_no_pending_cleanup(self):
        with tempfile.TemporaryDirectory() as directory:
            registry = Registry(directory)
            gateway = Gateway.__new__(Gateway)
            gateway.registry = registry
            gateway.mutations = Mutations(gateway)
            registry.mutation_begin("fixture-device", json.dumps({"kind": "share", "path": "/anj-cloud/a"}))
            registry.maintenance()
            app = web.Application(middlewares=[safe_errors])
            app.router.add_post("/operator", gateway.admin)
            client = TestClient(TestServer(app))
            await client.start_server()
            try:
                response = await client.post("/operator", json={"action": "recover"})
                self.assertEqual(400, response.status)
                self.assertFalse(registry.mutation_ready())
                response = await client.post("/operator", json={"action": "recover", "sharing_reconciled": True})
                self.assertEqual(200, response.status)
                self.assertTrue(registry.mutation_ready())
                registry.mutation_begin("fixture-device", "operator-sharing")
                registry.note_share_cleanup_and_finish("42", "fixture-device")
                registry.maintenance()
                response = await client.post("/operator", json={"action": "recover", "sharing_reconciled": True})
                self.assertEqual(400, response.status)
                self.assertFalse(registry.mutation_ready())
            finally:
                await client.close()
                registry.db.close()

    async def test_transfer_limit_is_bounded_json_without_dispatch_or_reservation(self):
        with tempfile.TemporaryDirectory() as directory:
            registry = Registry(directory)
            invite = registry.invite("alice", "write")
            pending = registry.enroll(invite["code"], csr())
            registry.begin(pending["pairing_id"], pending["fingerprint"])
            registry.activate(pending["pairing_id"], pending["fingerprint"], "private", "1", "public", registry.clock() + 1000, "leaf")
            device = registry.device(pending["device_id"])
            gateway = SimpleNamespace(registry=registry, throttle=0)
            mutations = Mutations(gateway)
            request = SimpleNamespace(method="PUT", content_length=mutations.limit + 1)
            with self.assertRaises(web.HTTPRequestEntityTooLarge) as caught:
                await mutations.run(request, device, "Documents/large", {})
            self.assertEqual({"error": "transfer_limit", "message": "Upload is too large for this server (limit 64 MB).",
                              "actual_bytes": mutations.limit + 1, "max_bytes": mutations.limit}, json.loads(caught.exception.text))
            self.assertTrue(registry.mutation_ready())
            self.assertEqual([], list(mutations.directory.iterdir()))
            registry.db.close()

    # The unconfined-share cleanup test moved to test_sharing.ConfinementTests (spec #26 sharing component).

    async def test_invalid_operator_share_id_has_no_backend_request_or_write_fence(self):
        with tempfile.TemporaryDirectory() as directory:
            registry = Registry(directory)
            invite = registry.invite("alice", "write")
            pending = registry.enroll(invite["code"], csr())
            registry.begin(pending["pairing_id"], pending["fingerprint"])
            registry.activate(pending["pairing_id"], pending["fingerprint"], "private", "1", "public", registry.clock() + 1000, "leaf")
            gateway = Gateway.__new__(Gateway)
            gateway.registry = registry
            gateway.backend = "http://backend.invalid"
            gateway.origin = "https://127.0.0.1:8834"
            gateway.mutations = Mutations(gateway)
            requests = []
            class Backend:
                def get(self, *args, **kwargs):
                    requests.append(args)
                    raise AssertionError("Local validation must precede any backend request")
            gateway.session = Backend()
            app = web.Application(middlewares=[safe_errors])
            app.router.add_post("/operator", gateway.admin)
            client = TestClient(TestServer(app))
            await client.start_server()
            try:
                response = await client.post("/operator", json={"action": "unshare", "device_id": pending["device_id"], "share_id": "invalid"})
                self.assertEqual(400, response.status)
                self.assertTrue(registry.mutation_ready())
                self.assertEqual([], requests)
            finally:
                await client.close()
                registry.db.close()

    async def test_alternating_backend_accounts_never_reuse_response_cookies(self):
        seen_cookies = []

        async def backend(request):
            seen_cookies.append(request.headers.get("Cookie"))
            auth = BasicAuth.decode(request.headers["Authorization"])
            uid = request.cookies.get("session_uid", auth.login)
            response = web.json_response({"uid": uid})
            response.set_cookie("session_uid", uid)
            return response

        app = web.Application()
        app.router.add_get("/identity", backend)
        server = TestServer(app, host="localhost")
        await server.start_server()
        gateway = Gateway.__new__(Gateway)
        await gateway.start(None)
        try:
            for uid in ("alice", "bob", "alice", "bob"):
                async with gateway.session.get(server.make_url("/identity"), auth=BasicAuth(uid, "synthetic")) as response:
                    self.assertEqual(uid, (await response.json())["uid"])
            self.assertEqual([None] * 4, seen_cookies)
        finally:
            await gateway.session.close()
            await server.close()

    async def test_unknown_dispatched_mutation_fences_restart_and_new_writes(self):
        started, release = asyncio.Event(), asyncio.Event()
        writes = []

        async def backend(request):
            if request.method == "PROPFIND":
                return web.Response(status=404)
            writes.append(await request.read())
            started.set()
            await release.wait()  # No receipt establishes whether the backend commit finished.
            return web.Response(status=201)

        app = web.Application()
        app.router.add_route("*", "/{path:.*}", backend)
        server = TestServer(app)
        await server.start_server()
        with tempfile.TemporaryDirectory() as directory:
            registry = Registry(directory)
            invite = registry.invite("alice", "write")
            pending = registry.enroll(invite["code"], csr())
            registry.begin(pending["pairing_id"], pending["fingerprint"])
            registry.activate(pending["pairing_id"], pending["fingerprint"], "synthetic", "1", "public", registry.clock() + 1000, "leaf-one")
            device = registry.device(pending["device_id"])
            session = ClientSession(cookie_jar=DummyCookieJar())
            gateway = SimpleNamespace(registry=registry, session=session, backend=str(server.make_url("")).rstrip("/"), origin="https://127.0.0.1:8834", throttle=0)
            mutations = Mutations(gateway)
            async def empty_chunks(_):
                if False:
                    yield b""
            request = SimpleNamespace(method="PUT", content_length=0, content=SimpleNamespace(iter_chunked=empty_chunks), headers={"If-None-Match": "*"})
            task = asyncio.create_task(mutations.run(request, device, "Documents/empty", {"If-None-Match": "*", "Content-Length": "0"}))
            mutations.register(task, device["id"])
            task.add_done_callback(mutations.finished)
            try:
                await asyncio.wait_for(started.wait(), 5)
                self.assertFalse(registry.mutation_ready())
                self.assertEqual([], mutations.cancel_unsubmitted(device["id"]))
                self.assertFalse(task.done())
                task.cancel()  # Simulate service process loss while the backend has no known receipt.
                with self.assertRaises(asyncio.CancelledError):
                    await task
                registry.db.close()
                gateway.registry = Registry(directory)
                self.assertFalse(gateway.registry.mutation_ready())
                with self.assertRaises(web.HTTPServiceUnavailable):
                    await mutations.run(request, device, "Documents/other", {"If-None-Match": "*"})
                self.assertEqual(1, len(writes))
                with self.assertRaises(ValueError):
                    gateway.registry.recover()
                gateway.registry.maintenance()
                gateway.registry.recover()
                self.assertTrue(gateway.registry.mutation_ready())
            finally:
                release.set()
                await session.close()
                gateway.registry.db.close()
                await server.close()

    async def test_staging_revocation_releases_reserved_file_and_lock_without_dispatch(self):
        with tempfile.TemporaryDirectory() as directory:
            registry = Registry(directory)
            invite = registry.invite("alice", "write")
            pending = registry.enroll(invite["code"], csr())
            registry.begin(pending["pairing_id"], pending["fingerprint"])
            registry.activate(pending["pairing_id"], pending["fingerprint"], "private", "1", "public", registry.clock() + 1000, "leaf")
            device = registry.device(pending["device_id"])
            gateway = SimpleNamespace(registry=registry, throttle=0)
            mutations = Mutations(gateway)
            staged, release = asyncio.Event(), asyncio.Event()
            async def chunks(_):
                yield b"part"
                staged.set()
                await release.wait()
            request = SimpleNamespace(method="PUT", content_length=4096, content=SimpleNamespace(iter_chunked=chunks), headers={"If-None-Match": "*"})
            real_file = tempfile.TemporaryFile
            files = []
            def capture(*args, **kwargs):
                stream = real_file(*args, **kwargs)
                files.append(stream)
                return stream
            with patch("services.access.mutations.tempfile.TemporaryFile", side_effect=capture):
                task = asyncio.create_task(mutations.run(request, device, "Documents/staging", {}))
                mutations.register(task, device["id"])
                task.add_done_callback(mutations.finished)
                await asyncio.wait_for(staged.wait(), 5)
                self.assertTrue(mutations.lock.locked())
                registry.disable(device["id"])
                self.assertEqual([task], mutations.cancel_unsubmitted(device["id"]))
                with self.assertRaises(asyncio.CancelledError):
                    await task
                self.assertEqual(1, len(files))
                self.assertTrue(files[0].closed)
                self.assertFalse(mutations.lock.locked())
                self.assertTrue(registry.mutation_ready())
                self.assertEqual([], list(mutations.directory.iterdir()))
            registry.db.close()


class ProvisioningFailureTests(unittest.TestCase):
    def exercise(self, boundary):
        with tempfile.TemporaryDirectory() as directory:
            tokens = [{"id": "900", "name": "prior-device"}]
            row = {"id": "pairing", "device": "00000000-0000-0000-0000-000000000001", "uid": "alice", "csr": "public CSR", "state": "provisioning"}

            class Stack:
                local = Path(directory)

                def occ(self, *args):
                    if args[0] == "user:auth-tokens:list":
                        return json.dumps(tokens)
                    if args[0] == "user:auth-tokens:add":
                        tokens.append({"id": "901", "name": args[3]})
                        if boundary == "issuance-response-lost":
                            raise RuntimeError("Timeout after creation")
                        return "app password:\n" + "A" * 72
                    if args[0] == "user:auth-tokens:delete":
                        tokens[:] = [token for token in tokens if token["id"] != args[-1]]
                        return ""
                    raise AssertionError("Unexpected operation")

            operator = Operator(Stack())
            def call(action, **data):
                if action in {"begin", "inspect"}:
                    return dict(row)
                if action == "activate":
                    if boundary == "activation-response-lost":
                        row["state"] = "approved"
                        raise RuntimeError("Lost committed receipt")
                    raise RuntimeError("Activation rejected")
                raise AssertionError("Unexpected operator action")
            def sign(source, target, identity):
                if boundary == "signing-failed":
                    raise RuntimeError("Issuer unavailable")
                target.write_text("public certificate")
            with patch.object(operator, "call", side_effect=call), patch.object(operator, "sign", side_effect=sign):
                if boundary == "activation-response-lost":
                    self.assertEqual("active", operator.approve("pairing", "a" * 64)["state"])
                    self.assertEqual(2, len(tokens))
                else:
                    with self.assertRaises(RuntimeError):
                        operator.approve("pairing", "a" * 64)
                    self.assertEqual([{"id": "900", "name": "prior-device"}], tokens)
                journal = next(operator.journals.glob("*.json")).read_text()
                self.assertNotIn("A" * 72, journal)

    def test_uncertain_creation_and_failed_signing_or_activation_clean_exact_tokens(self):
        for boundary in ("issuance-response-lost", "signing-failed", "activation-rejected"):
            with self.subTest(boundary=boundary):
                self.exercise(boundary)

    def test_lost_activation_receipt_preserves_committed_device_without_reissuing(self):
        self.exercise("activation-response-lost")
