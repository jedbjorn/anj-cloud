"""Shared fixture for spec #20 gateway tests: the real gateway app behind the real edge.

A temporary issuer signs a server certificate for a test hostname; a fake Nextcloud answers
status and DAV. Clients are synchronous MemoryBIO TLS clients run in a thread, so a PROXY v2
header and the TLS ClientHello can be sent in the same write.
"""

import asyncio
from contextlib import contextmanager
import io
import json
from pathlib import Path
import socket
import ssl
import tempfile
import time

from aiohttp import web
from aiohttp.test_utils import TestServer
from cryptography import x509
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import ExtendedKeyUsageOID

from services.access.edge import Edge
from services.access.observe import EnrollmentGuard, Events
from services.access.server import Gateway, tls_context
from test_permanent_credentials import Authority, Device, leaf_id, pair, pem

HOST = "gateway.f15a.test"


class Clock:
    def __init__(self, now=1000.0):
        self.now = now

    def __call__(self):
        return self.now

    def advance(self, seconds):
        self.now += seconds


class FakeNextcloud:
    def __init__(self):
        self.requests = []
        self.ready = True

    async def handle(self, request):
        self.requests.append((request.method, request.path))
        if request.path == "/status.php":
            return web.json_response({"installed": True, "maintenance": not self.ready, "versionstring": "33.0.10"})
        if request.method == "GET":
            return web.Response(body=b"synthetic content", content_type="application/octet-stream")
        return web.Response(status=404)


class Harness:
    """Gateway + edge in one event loop; call `await start()` and `await stop()`."""

    def __init__(self, *, listener="proxy-unix", max_connections=128, request_header_timeout=10.0,
                 proxy_header_timeout=5.0, handshake_timeout=10.0, guard_clock=None):
        self.temporary = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary.name)
        self.authority = Authority(self.directory)
        server_key = ec.generate_private_key(ec.SECP256R1())
        server = self.authority.leaf(server_key.public_key(), HOST, usage=ExtendedKeyUsageOID.SERVER_AUTH,
                                     san=[x509.DNSName(HOST)])
        self.server_crt = self.directory / "server.crt"
        self.server_key = self.directory / "server.key"
        self.server_crt.write_text(pem(server))
        self.server_key.write_bytes(server_key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                                             serialization.NoEncryption()))
        self.listener = listener
        self.options = dict(max_connections=max_connections, request_header_timeout=request_header_timeout,
                            proxy_header_timeout=proxy_header_timeout, handshake_timeout=handshake_timeout)
        self.guard_clock = guard_clock or Clock()
        self.wall = Clock(1793600000.0)
        self.stream = io.StringIO()
        self.socket_path = str(self.directory / "gateway.sock")
        self.port = None

    async def start(self):
        self.nextcloud = FakeNextcloud()
        backend = web.Application()
        backend.router.add_route("*", "/{path:.*}", self.nextcloud.handle)
        self.backend = TestServer(backend)
        await self.backend.start_server()
        self.events = Events(self.stream, clock=self.wall)
        self.guard = EnrollmentGuard(self.events, clock=self.guard_clock, wall=self.wall)
        self.gateway = Gateway(self.directory / "state", str(self.backend.make_url("")).rstrip("/"),
                               "https://" + HOST, self.authority.crt, events=self.events, guard=self.guard)
        self.runner = self.gateway.runner(self.gateway.public_app())
        await self.runner.setup()
        context = tls_context(self.server_crt, self.server_key, self.authority.crt)
        self.gateway.edge = Edge(self.events, self.runner.server, context, **self.options)
        if self.listener == "tcp":
            with socket.socket() as probe:
                probe.bind(("127.0.0.1", 0))
                self.port = probe.getsockname()[1]
            await self.gateway.edge.start_tcp("127.0.0.1", self.port)
        else:
            await self.gateway.edge.start_unix(self.socket_path)
        # The server side logs expected handshake failures through the loop handler.
        asyncio.get_running_loop().set_exception_handler(lambda loop, context: None)

    async def stop(self):
        await self.gateway.edge.close()
        await self.runner.cleanup()
        await self.backend.close()
        self.temporary.cleanup()

    def lines(self):
        self.events.flush(force=True)
        return [json.loads(line) for line in self.stream.getvalue().splitlines() if line]

    def requests(self, **match):
        return [line for line in self.lines() if line["event"] == "request" and all(line.get(k) == v for k, v in match.items())]

    def summaries(self, source=None):
        return [line for line in self.lines() if line["event"] == "summary" and (source is None or line["source"] == source)]

    def counted(self, kind, source=None):
        return sum(line["counts"].get(kind, 0) for line in self.summaries(source))

    def client_context(self, device=None, certificate=None, **options):
        context = ssl.create_default_context(cafile=str(self.authority.crt))
        for key, value in options.items():
            setattr(context, key, value)
        if device is not None:
            prefix = self.directory / ("client-" + leaf_id(certificate)[:12])
            prefix.with_suffix(".crt").write_text(pem(certificate))
            prefix.with_suffix(".key").write_bytes(device.key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                                                            serialization.NoEncryption()))
            context.load_cert_chain(prefix.with_suffix(".crt"), prefix.with_suffix(".key"))
        return context

    def connect(self):
        if self.listener == "tcp":
            return socket.create_connection(("127.0.0.1", self.port), timeout=10)
        raw = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        raw.settimeout(10)
        raw.connect(self.socket_path)
        return raw


class BioClient:
    """Blocking TLS over a raw socket via MemoryBIO: `prefix` and the ClientHello share one write."""

    def __init__(self, raw, context, host=HOST, prefix=b""):
        self.raw = raw
        self.incoming, self.outgoing = ssl.MemoryBIO(), ssl.MemoryBIO()
        self.tls = context.wrap_bio(self.incoming, self.outgoing, server_hostname=host)
        try:
            self.tls.do_handshake()
        except ssl.SSLWantReadError:
            pass
        self.raw.sendall(prefix + self.outgoing.read())
        while True:
            try:
                self.tls.do_handshake()
                break
            except ssl.SSLWantReadError:
                self._flush()
                data = self.raw.recv(65536)
                if not data:
                    raise ConnectionError("closed during handshake")
                self.incoming.write(data)
        self._flush()

    def _flush(self):
        data = self.outgoing.read()
        if data:
            self.raw.sendall(data)

    def send(self, data):
        self.tls.write(data)
        self._flush()

    def receive(self):
        """Return decrypted bytes until the server closes (b"" on close)."""
        while True:
            try:
                return self.tls.read(65536)
            except ssl.SSLWantReadError:
                data = self.raw.recv(65536)
                if not data:
                    return b""
                self.incoming.write(data)
            except (ssl.SSLZeroReturnError, ssl.SSLEOFError):
                return b""

    def response(self):
        """Read one response (Content-Length framed or until close)."""
        buffer = b""
        while b"\r\n\r\n" not in buffer:
            chunk = self.receive()
            if not chunk:
                break
            buffer += chunk
        head, _, body = buffer.partition(b"\r\n\r\n")
        lines = head.decode("latin-1").split("\r\n")
        status = int(lines[0].split()[1]) if lines and len(lines[0].split()) > 1 else None
        headers = {}
        for line in lines[1:]:
            key, _, value = line.partition(":")
            headers[key.strip().lower()] = value.strip()
        if "content-length" in headers:
            while len(body) < int(headers["content-length"]):
                chunk = self.receive()
                if not chunk:
                    break
                body += chunk
        return status, headers, body

    def request(self, method, path, body=b"", headers=None, keep_alive=False):
        lines = [f"{method} {path} HTTP/1.1", "Host: " + HOST, "Connection: " + ("keep-alive" if keep_alive else "close")]
        for key, value in (headers or {}).items():
            lines.append(f"{key}: {value}")
        if body:
            lines.append(f"Content-Length: {len(body)}")
        self.send(("\r\n".join(lines) + "\r\n\r\n").encode() + body)
        return self.response()

    def closed_within(self, seconds):
        """True when the server closes (EOF or reset) within `seconds`."""
        self.raw.settimeout(seconds)
        try:
            while True:
                if not self.receive():
                    return True
        except TimeoutError:
            return False
        except (ConnectionError, ssl.SSLError, OSError):
            return True

    def close(self):
        self.raw.close()


def closed_within(raw, seconds):
    raw.settimeout(seconds)
    try:
        while raw.recv(4096):
            pass
        return True
    except (ConnectionError, OSError) as error:
        return not isinstance(error, TimeoutError)


@contextmanager
def elapsed():
    start = time.monotonic()
    result = {}
    yield result
    result["seconds"] = time.monotonic() - start


__all__ = ["Authority", "BioClient", "Clock", "Device", "HOST", "Harness", "closed_within", "elapsed", "leaf_id", "pair", "pem"]
