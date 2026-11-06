"""SC-028: oversized uploads are refused from the declared length, before any body byte is read."""

import asyncio
from collections import defaultdict
import os
import tempfile
import time
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
from services.access.protocol import UPLOAD_LIMIT, UPLOAD_LIMIT_HEADER, size_label
from services.access.registry import Registry
from services.access.server import Gateway, safe_errors

LIMIT = 64 * 1024


def csr():
    key = ec.generate_private_key(ec.SECP256R1())
    request = x509.CertificateSigningRequestBuilder().subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "fixture")])).sign(key, hashes.SHA256())
    return request.public_bytes(serialization.Encoding.PEM).decode()


class Content:
    """Stands in for an aiohttp request stream; records how much was read."""

    def __init__(self, chunks):
        self.chunks, self.read = chunks, 0

    async def iter_chunked(self, size):
        for chunk in self.chunks:
            self.read += len(chunk)
            yield chunk


class Backend:
    """Fake Nextcloud: a missing resource for the version read, then 201 for the PUT."""

    def __init__(self):
        self.calls, self.stored = [], None

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

            class content:
                @staticmethod
                async def iter_chunked(size):
                    if False:
                        yield b""

        return Response()


class UploadLimitTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.registry = Registry(self.temporary.name)
        invite = self.registry.invite("alice", "write")
        pending = self.registry.enroll(invite["code"], csr())
        self.registry.begin(pending["pairing_id"], pending["fingerprint"])
        self.registry.activate(pending["pairing_id"], pending["fingerprint"], "private", "1", "public",
                               self.registry.clock() + 1000, "leaf")
        self.device = self.registry.device(pending["device_id"])
        gateway = Gateway.__new__(Gateway)
        gateway.registry, gateway.backend, gateway.origin = self.registry, "http://backend.invalid", "https://127.0.0.1:8834"
        gateway.active, gateway.transports, gateway.throttle = defaultdict(set), defaultdict(set), 0
        with patch.dict(os.environ, {"ANJ_MAX_TRANSFER_BYTES": str(LIMIT)}):
            gateway.mutations = Mutations(gateway)
        gateway.session = self.backend = Backend()
        gateway.identity = lambda request: self.device
        self.gateway = gateway
        app = web.Application(middlewares=[safe_errors])
        app.router.add_route("*", "/dav/{path:.*}", gateway.dav)
        app.on_response_prepare.append(gateway.advertise_limit)
        self.server = TestServer(app)
        await self.server.start_server()

    async def asyncTearDown(self):
        await self.server.close()
        self.registry.db.close()
        self.temporary.cleanup()

    def assert_untouched(self):
        self.assertEqual([], self.backend.calls)
        self.assertEqual(set(), self.gateway.mutations.tasks)
        self.assertTrue(self.registry.mutation_ready())
        self.assertEqual([], list(self.gateway.mutations.directory.iterdir()))

    def test_default_limit_is_the_named_constant(self):
        self.assertEqual(64 * 1024 * 1024, UPLOAD_LIMIT)
        self.assertEqual("64 MB", size_label(UPLOAD_LIMIT))
        with patch.dict(os.environ, {}, clear=True):
            self.assertEqual(UPLOAD_LIMIT, Mutations(self.gateway).limit)

    async def test_oversized_declared_length_is_413_before_any_body_byte(self):
        reader, writer = await asyncio.open_connection(self.server.host, self.server.port)
        try:
            # Headers only: the refusal must not wait for a body that never comes.
            writer.write(("PUT /dav/Documents/large.bin HTTP/1.1\r\nHost: fixture\r\nIf-None-Match: *\r\n"
                          "Content-Length: %d\r\n\r\n" % (LIMIT + 1)).encode())
            await writer.drain()
            response = await asyncio.wait_for(reader.read(), timeout=5)  # EOF: the server closed it
        finally:
            writer.close()
        head, _, body = response.partition(b"\r\n\r\n")
        lines = head.decode().split("\r\n")
        headers = {name.lower(): value for name, _, value in (line.partition(": ") for line in lines[1:])}
        self.assertTrue(lines[0].startswith("HTTP/1.1 413 "), lines[0])
        self.assertEqual(str(LIMIT), headers[UPLOAD_LIMIT_HEADER.lower()])
        self.assertEqual("close", headers["connection"].lower())
        self.assertIn(b'"max_bytes": %d' % LIMIT, body)
        self.assertIn(b"too large for this server (limit 64 KB)", body)
        self.assert_untouched()

    async def test_a_client_still_sending_is_cut_off_instead_of_drained(self):
        # aiohttp drains an unread body for up to 10 s; the refusal closes at once.
        reader, writer = await asyncio.open_connection(self.server.host, self.server.port)
        declared = 512 * 1024 * 1024
        writer.write(("PUT /dav/Documents/large.bin HTTP/1.1\r\nHost: fixture\r\nIf-None-Match: *\r\n"
                      "Content-Length: %d\r\n\r\n" % declared).encode())
        chunk, sent, started = b"x" * (256 * 1024), 0, time.monotonic()
        try:
            while sent < declared:
                writer.write(chunk)
                await asyncio.wait_for(writer.drain(), timeout=5)
                sent += len(chunk)
        except (ConnectionError, asyncio.TimeoutError):
            pass
        finally:
            writer.close()
        self.assertLess(time.monotonic() - started, 5)
        self.assertLess(sent, 64 * 1024 * 1024, "only socket buffers' worth, not the declared body")
        self.assert_untouched()

    async def test_missing_length_is_411_before_queueing(self):
        async def chunks():
            yield b"x" * 10
        client = TestClient(self.server)
        try:
            response = await client.put("/dav/Documents/a.bin", data=chunks(), headers={"If-None-Match": "*"})
            self.assertEqual(411, response.status)
        finally:
            await client.close()
        self.assert_untouched()

    async def test_at_and_under_the_limit_are_stored_and_report_the_limit(self):
        client = TestClient(self.server)
        try:
            for size in (LIMIT, LIMIT - 1, 0):
                with self.subTest(size=size):
                    self.backend.calls.clear()
                    response = await client.put("/dav/Documents/s%d.bin" % size, data=b"a" * size, headers={"If-None-Match": "*"})
                    self.assertEqual(201, response.status)
                    self.assertEqual(str(LIMIT), response.headers[UPLOAD_LIMIT_HEADER])
                    # The version read, then the sibling listing of a new name (decision #120).
                    self.assertEqual(["PROPFIND", "PROPFIND", "PUT"], self.backend.calls)
                    self.assertEqual(b"a" * size, self.backend.stored)
            response = await client.options("/dav/Documents/")
            self.assertEqual(200, response.status)
            self.assertEqual(str(LIMIT), response.headers[UPLOAD_LIMIT_HEADER], "every DAV response advertises it")
        finally:
            await client.close()
        self.assertTrue(self.registry.mutation_ready())
        self.assertEqual([], list(self.gateway.mutations.directory.iterdir()))

    async def test_body_larger_than_its_declared_length_is_refused_mid_stream(self):
        content = Content([b"x" * 1024] * 8)
        request = SimpleNamespace(method="PUT", content_length=4096, content=content)
        with self.assertRaises(web.HTTPBadRequest) as caught:
            await self.gateway.mutations.run(request, self.device, "Documents/lying.bin", {})
        self.assertEqual("Upload exceeded declared length", caught.exception.text)
        self.assertEqual(5 * 1024, content.read, "stops at the first byte past the declared length")
        self.assert_untouched()

    async def test_mutation_path_keeps_its_own_size_refusal(self):
        request = SimpleNamespace(method="PUT", content_length=LIMIT + 1, content=Content([]))
        with self.assertRaises(web.HTTPRequestEntityTooLarge) as caught:
            await self.gateway.mutations.run(request, self.device, "Documents/large.bin", {})
        self.assertEqual(str(LIMIT), caught.exception.headers[UPLOAD_LIMIT_HEADER])
        self.assertEqual(0, request.content.read)
        self.assert_untouched()


if __name__ == "__main__":
    unittest.main()
