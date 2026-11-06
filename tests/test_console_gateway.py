"""Spec #27 gateway side: runtime upload limit, operator settings/status actions, device labels."""

import asyncio
import io
from collections import defaultdict
import json
import os
import sqlite3
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

from aiohttp import web
from aiohttp.test_utils import TestClient, TestServer
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID

from services.access.mutations import Mutations
from services.access.protocol import UPLOAD_LIMIT_HEADER, UPLOAD_LIMIT_MAX, UPLOAD_LIMIT_MIN
from services.access.registry import Registry
from services.access.server import Gateway, safe_errors

MIB = 1024 * 1024


def csr():
    key = ec.generate_private_key(ec.SECP256R1())
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "fixture")])
    request = x509.CertificateSigningRequestBuilder().subject_name(name).sign(key, hashes.SHA256())
    return request.public_bytes(serialization.Encoding.PEM).decode()


class Backend:
    """Fake Nextcloud: a missing resource for the version read, 201 for the PUT, ready status."""

    def __init__(self):
        self.calls, self.stored = [], None

    def get(self, url, **kwargs):
        return self.request("GET", url, **kwargs)

    def request(self, method, url, data=None, headers=None, **kwargs):
        self.calls.append(method)
        backend = self

        class Response:
            status = 404 if method == "PROPFIND" else 201 if method == "PUT" else 200
            headers = {"ETag": '"v1"'} if method == "PUT" else {"Allow": "OPTIONS, PUT"}

            async def __aenter__(self):
                if method == "PUT":
                    backend.stored = data.read()
                return self

            async def __aexit__(self, *args):
                pass

            async def json(self, content_type=None):
                return {"installed": True, "maintenance": False}

            class content:
                @staticmethod
                async def iter_chunked(size):
                    if False:
                        yield b""

        return Response()


class RuntimeLimitTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.registry = Registry(self.temporary.name)
        invite = self.registry.invite("alice", "write")
        pending = self.registry.enroll(invite["code"], csr(), "Alice's laptop")
        self.registry.begin(pending["pairing_id"], pending["fingerprint"])
        self.registry.activate(pending["pairing_id"], pending["fingerprint"], "private", "1", "public",
                               self.registry.clock() + 1000, "leaf")
        self.device = self.registry.device(pending["device_id"])
        gateway = Gateway.__new__(Gateway)
        gateway.registry, gateway.backend, gateway.origin = self.registry, "http://backend.invalid", "https://127.0.0.1:8834"
        gateway.active, gateway.transports, gateway.throttle = defaultdict(set), defaultdict(set), 0
        with patch.dict(os.environ, {}, clear=True):
            gateway.mutations = Mutations(gateway)
        gateway.session = self.backend = Backend()
        gateway.identity = lambda request: self.device
        self.gateway = gateway
        app = web.Application(middlewares=[safe_errors])
        app.router.add_route("*", "/dav/{path:.*}", gateway.dav)
        app.router.add_post("/operator", gateway.admin)
        app.on_response_prepare.append(gateway.advertise_limit)
        self.server = TestServer(app)
        await self.server.start_server()
        self.client = TestClient(self.server)

    async def asyncTearDown(self):
        await self.client.close()
        await self.server.close()
        self.registry.db.close()
        self.temporary.cleanup()

    async def operator(self, action, **data):
        response = await self.client.post("/operator", json={"action": action, **data})
        return response.status, await response.json()

    async def test_settings_get_reports_default_and_bounds(self):
        status, body = await self.operator("settings-get")
        self.assertEqual(200, status)
        self.assertEqual({"upload_limit_bytes": 64 * MIB, "upload_limit_min_bytes": MIB,
                          "upload_limit_max_bytes": 64 * MIB, "staging_bytes": 128 * MIB}, body)

    async def test_out_of_range_and_non_integer_limits_are_refused_and_unchanged(self):
        for value in (0, MIB - 1, -MIB, 1.5 * MIB, float(MIB), "33554432", True, None, []):
            with self.subTest(value=value):
                status, body = await self.operator("settings-set", upload_limit_bytes=value)
                self.assertEqual(400, status)
                self.assertEqual("Upload limit must be a whole number of bytes from 1 MiB to 64 MiB", body["error"])
        status, body = await self.operator("settings-set", upload_limit_bytes=65 * MIB)
        self.assertEqual(400, status)
        self.assertEqual("Above 64 MiB needs large-transfer support (Feature #6)", body["error"])
        self.assertEqual(64 * MIB, self.gateway.mutations.limit)
        self.assertIsNone(self.registry.setting(Mutations.LIMIT_SETTING))

    async def test_new_limit_is_advertised_at_once_and_refuses_larger_puts_before_their_body(self):
        status, body = await self.operator("settings-set", upload_limit_bytes=32 * MIB)
        self.assertEqual((200, 32 * MIB), (status, body["upload_limit_bytes"]))
        response = await self.client.options("/dav/Documents/")
        self.assertEqual(str(32 * MIB), response.headers[UPLOAD_LIMIT_HEADER])
        reader, writer = await asyncio.open_connection(self.server.host, self.server.port)
        try:
            writer.write(("PUT /dav/Documents/big.bin HTTP/1.1\r\nHost: fixture\r\nIf-None-Match: *\r\n"
                          "Content-Length: %d\r\n\r\n" % (40 * MIB)).encode())
            await writer.drain()
            raw = await asyncio.wait_for(reader.read(), timeout=5)
        finally:
            writer.close()
        self.assertTrue(raw.startswith(b"HTTP/1.1 413 "), raw[:40])
        self.assertIn(("%s: %d" % (UPLOAD_LIMIT_HEADER, 32 * MIB)).encode(), raw)
        self.assertNotIn("PUT", self.backend.calls)
        self.assertTrue(UPLOAD_LIMIT_MIN <= 32 * MIB <= UPLOAD_LIMIT_MAX)

    async def test_upload_started_under_the_old_limit_completes_after_a_lower_limit(self):
        await self.gateway.mutations.lock.acquire()
        try:
            put = asyncio.create_task(self.client.put("/dav/Documents/inflight.bin", data=io.BytesIO(b"a" * (2 * MIB)),
                                                      headers={"If-None-Match": "*"}))
            for _ in range(200):
                if self.gateway.mutations.tasks:
                    break
                await asyncio.sleep(0.01)
            self.assertTrue(self.gateway.mutations.tasks, "the upload is admitted and waiting for the lock")
            self.gateway.mutations.set_limit(MIB)
        finally:
            self.gateway.mutations.lock.release()
        response = await put
        self.assertEqual(201, response.status)
        self.assertEqual(str(MIB), response.headers[UPLOAD_LIMIT_HEADER], "the response advertises the new limit")
        self.assertEqual(2 * MIB, len(self.backend.stored))
        later = await self.client.put("/dav/Documents/later.bin", data=io.BytesIO(b"a" * (2 * MIB)), headers={"If-None-Match": "*"})
        self.assertEqual(413, later.status)

    async def test_settings_set_waits_for_the_single_writer_lock(self):
        await self.gateway.mutations.lock.acquire()
        change = asyncio.create_task(self.operator("settings-set", upload_limit_bytes=8 * MIB))
        await asyncio.sleep(0.1)
        self.assertFalse(change.done())
        self.assertEqual(64 * MIB, self.gateway.mutations.limit)
        self.gateway.mutations.lock.release()
        self.assertEqual(200, (await change)[0])
        self.assertEqual(8 * MIB, self.gateway.mutations.limit)

    async def test_limit_survives_a_gateway_restart_and_wins_over_the_environment(self):
        await self.operator("settings-set", upload_limit_bytes=16 * MIB)
        reopened = Registry(self.temporary.name)
        try:
            gateway = SimpleNamespace(registry=reopened)
            with patch.dict(os.environ, {"ANJ_MAX_TRANSFER_BYTES": str(64 * MIB)}):
                self.assertEqual(16 * MIB, Mutations(gateway).limit)
        finally:
            reopened.db.close()

    async def test_status_reports_backend_fence_kind_leaves_and_limit_without_paths(self):
        status, body = await self.operator("status")
        self.assertEqual(200, status)
        self.assertEqual({"backend": "ready", "write_fence": {"state": "clear", "kind": None},
                          "transition_leaves": 0, "upload_limit_bytes": 64 * MIB}, body)
        intent = json.dumps({"kind": "share", "path": "/anj-cloud/Private Folder", "recipient": "bob"})
        for path, kind in ((intent, "share"), ("Documents/secret name.txt", "file-write"),
                           ("cleanup-unconfined-share-7", "share-cleanup"), ("provision-enrolled-root", "root-provisioning")):
            with self.subTest(kind=kind):
                self.registry.mutation_begin(self.device["id"], path)
                status, body = await self.operator("status")
                self.assertEqual({"state": "dispatched", "kind": kind}, body["write_fence"])
                self.assertNotIn("Private Folder", json.dumps(body))
                self.assertNotIn("secret name", json.dumps(body))
                self.registry.mutation_finish()
        self.registry.maintenance()
        self.assertEqual({"state": "maintenance", "kind": "maintenance"}, (await self.operator("status"))[1]["write_fence"])

    async def test_unavailable_backend_reports_unavailable_instead_of_failing(self):
        def broken(url, **kwargs):
            raise OSError("down")
        self.gateway.session.get = broken
        status, body = await self.operator("status")
        self.assertEqual((200, "unavailable"), (status, body["backend"]))


class LabelTests(unittest.TestCase):
    def test_label_is_kept_from_first_reservation_and_listed(self):
        with tempfile.TemporaryDirectory() as directory:
            registry = Registry(directory)
            request = csr()
            invite = registry.invite("alice", "write")
            pending = registry.enroll(invite["code"], request, "The VM host")
            registry.enroll(invite["code"], request, "Renamed on retry")
            self.assertEqual("The VM host", registry.invitation(pending["pairing_id"])["label"])
            registry.begin(pending["pairing_id"], pending["fingerprint"])
            registry.activate(pending["pairing_id"], pending["fingerprint"], "t", "1", "c", registry.clock() + 100, "leaf")
            self.assertEqual(["The VM host"], [row["label"] for row in registry.public_devices()])
            unlabeled = registry.invite("bob", "read")
            self.assertIsNone(registry.invitation(registry.enroll(unlabeled["code"], csr())["pairing_id"])["label"])
            registry.db.close()

    def test_existing_registry_gains_the_label_column_without_losing_rows(self):
        with tempfile.TemporaryDirectory() as directory:
            registry = Registry(directory)
            invite = registry.invite("alice", "write")
            registry.db.close()
            connection = sqlite3.connect(os.path.join(directory, "registry.sqlite"))
            connection.execute("ALTER TABLE invitations DROP COLUMN label")
            connection.commit()
            connection.close()
            registry = Registry(directory)
            self.assertIsNone(registry.invitation(invite["id"])["label"])
            self.assertEqual("alice", registry.invitation(invite["id"])["uid"])
            registry.db.close()


if __name__ == "__main__":
    unittest.main()
