"""Connection edge: listeners, PROXY v2 accept path, header watchdog and connection cap.

Two listener modes (spec #20, Ingress and Gateway Listener 3):

- ``tcp`` (default, dev): TLS on a TCP port, no PROXY; the peer address is the source.
- ``proxy-unix`` (production only): host HAProxy relays TCP over a Unix socket and prefixes
  each connection with a PROXY v2 header. The header is read with exact-length
  ``sock_recv`` calls, so no TLS byte is consumed, and the socket is then handed to
  ``loop.connect_accepted_socket`` for the TLS handshake.

Every accepted connection is wrapped in :class:`Connection`, which owns the per-connection
state the gateway reads (source, watchdog) and delegates the protocol to aiohttp's handler.
"""

import asyncio
import ipaddress
import os
from pathlib import Path
import socket
import stat
import struct

SIGNATURE = b"\r\n\r\n\x00\r\nQUIT\n"
HEADER_TIMEOUT = 5.0  # PROXY v2 preamble and addresses
HANDSHAKE_TIMEOUT = 10.0  # TLS handshake
REQUEST_HEADER_TIMEOUT = 10.0  # request headers after connection or previous response
KEEPALIVE_TIMEOUT = 15.0  # idle keep-alive (aiohttp's own close)
MAX_CONNECTIONS = 128  # per process
MAX_ADDRESS_BLOCK = 536  # TCP6 addresses (36) plus room for TLVs; anything longer is malformed
LOCAL_SOURCE = "local"


class ProxyHeaderError(ValueError):
    pass


def local_header():
    """A PROXY v2 LOCAL header: health checks from inside the host/container."""
    return SIGNATURE + b"\x20\x00\x00\x00"


def proxy_header(source, port=40000, destination="192.0.2.1", destination_port=443):
    """A PROXY v2 PROXY/TCP header for ``source``; used by tests and probes."""
    address = ipaddress.ip_address(source)
    target = ipaddress.ip_address(destination)
    if address.version == 4:
        target = target if target.version == 4 else ipaddress.ip_address("192.0.2.1")
        body = address.packed + target.packed + struct.pack("!HH", port, destination_port)
        return SIGNATURE + b"\x21\x11" + struct.pack("!H", len(body)) + body
    target = target if target.version == 6 else ipaddress.ip_address("2001:db8::1")
    body = address.packed + target.packed + struct.pack("!HH", port, destination_port)
    return SIGNATURE + b"\x21\x21" + struct.pack("!H", len(body)) + body


def parse_preamble(preamble):
    """Validate the 16-byte preamble; return (command, family, address length)."""
    if len(preamble) != 16 or preamble[:12] != SIGNATURE:
        raise ProxyHeaderError("signature")
    version, command = preamble[12] >> 4, preamble[12] & 0x0F
    family = preamble[13]
    length = struct.unpack("!H", preamble[14:16])[0]
    if version != 2 or command not in (0, 1):
        raise ProxyHeaderError("version")
    if length > MAX_ADDRESS_BLOCK:
        raise ProxyHeaderError("length")
    if command == 1:
        # PROXY: TCP over IPv4 (0x11) or IPv6 (0x21) only.
        if family == 0x11 and length < 12 or family == 0x21 and length < 36 or family not in (0x11, 0x21):
            raise ProxyHeaderError("family")
    return command, family, length


def source_from(command, family, block):
    if command == 0:
        return LOCAL_SOURCE
    if family == 0x11:
        return str(ipaddress.IPv4Address(block[:4]))
    address = ipaddress.IPv6Address(block[:16])
    return str(address.ipv4_mapped or address)


async def read_exactly(loop, sock, size):
    data = bytearray()
    while len(data) < size:
        chunk = await loop.sock_recv(sock, size - len(data))
        if not chunk:
            raise ProxyHeaderError("short")
        data += chunk
    return bytes(data)


async def read_proxy_header(loop, sock):
    """Read exactly the preamble and the declared address block; return the source."""
    command, family, length = parse_preamble(await read_exactly(loop, sock, 16))
    block = await read_exactly(loop, sock, length) if length else b""
    return source_from(command, family, block)


def peer_source(transport):
    peer = transport.get_extra_info("peername")
    if isinstance(peer, (tuple, list)) and peer:
        address = ipaddress.ip_address(peer[0].split("%", 1)[0])
        if address.version == 6 and address.ipv4_mapped:
            address = address.ipv4_mapped
        return str(address)
    return LOCAL_SOURCE


class Connection(asyncio.Protocol):
    """Per-connection wrapper around aiohttp's request handler.

    The header watchdog is armed at connection and after each response, disarmed by the
    outermost middleware when a request starts, and aborts the transport on expiry.
    """

    def __init__(self, edge, source=None, reserved=False):
        self.edge, self.source, self.reserved = edge, source, reserved
        self.handler = None
        self.transport = None
        self.watchdog = None
        self.closed = False

    def connection_made(self, transport):
        self.transport = transport
        if self.source is None:
            self.source = peer_source(transport)
        if not self.reserved and not self.edge.reserve():
            self.edge.events.count(self.source, "connection-cap")
            transport.abort()
            self.closed = True
            return
        self.reserved = True
        self.edge.connections[transport] = self
        self.handler = self.edge.handler_factory()
        self.arm()
        self.handler.connection_made(transport)

    def arm(self):
        self.disarm()
        if not self.closed:
            self.watchdog = asyncio.get_running_loop().call_later(self.edge.request_header_timeout, self.expire)

    def disarm(self):
        if self.watchdog is not None:
            self.watchdog.cancel()
            self.watchdog = None

    def expire(self):
        self.watchdog = None
        if not self.closed and self.transport is not None:
            self.edge.events.count(self.source, "header-timeout")
            self.transport.abort()

    def data_received(self, data):
        if self.handler is not None:
            self.handler.data_received(data)

    def eof_received(self):
        return self.handler.eof_received() if self.handler is not None else None

    def pause_writing(self):
        if self.handler is not None:
            self.handler.pause_writing()

    def resume_writing(self):
        if self.handler is not None:
            self.handler.resume_writing()

    def connection_lost(self, exc):
        if self.closed and self.handler is None:
            return
        self.closed = True
        self.disarm()
        self.edge.connections.pop(self.transport, None)
        if self.reserved:
            self.edge.release()
            self.reserved = False
        if self.handler is not None:
            self.handler.connection_lost(exc)


class Edge:
    """Listener state shared by both modes."""

    def __init__(self, events, handler_factory, context, *, max_connections=MAX_CONNECTIONS,
                 request_header_timeout=REQUEST_HEADER_TIMEOUT, proxy_header_timeout=HEADER_TIMEOUT,
                 handshake_timeout=HANDSHAKE_TIMEOUT):
        self.events = events
        self.handler_factory = handler_factory
        self.context = context
        self.max_connections = max_connections
        self.request_header_timeout = request_header_timeout
        self.proxy_header_timeout = proxy_header_timeout
        self.handshake_timeout = handshake_timeout
        self.connections = {}
        self.slots = 0
        self.servers = []
        self.listener = None
        self.accepting = None
        self.pending = set()

    def reserve(self):
        if self.slots >= self.max_connections:
            return False
        self.slots += 1
        return True

    def release(self):
        self.slots = max(0, self.slots - 1)

    def connection(self, transport):
        return self.connections.get(transport)

    async def start_tcp(self, host, port):
        loop = asyncio.get_running_loop()
        server = await loop.create_server(lambda: Connection(self), host, port, ssl=self.context,
                                          ssl_handshake_timeout=self.handshake_timeout, reuse_address=True)
        self.servers.append(server)
        return server

    async def start_unix(self, path, mode=0o660):
        """Own a listening Unix socket for HAProxy; unlink a stale socket first."""
        path = Path(path)
        try:
            info = path.lstat()
        except FileNotFoundError:
            pass
        else:
            if not stat.S_ISSOCK(info.st_mode):
                raise RuntimeError("Gateway socket path exists and is not a socket")
            path.unlink()
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            listener.bind(str(path))
            os.chmod(path, mode)
            listener.listen(256)
            listener.setblocking(False)
        except BaseException:
            listener.close()
            raise
        self.listener = listener
        self.accepting = asyncio.create_task(self._accept_loop(listener))
        return listener

    async def _accept_loop(self, listener):
        loop = asyncio.get_running_loop()
        while True:
            try:
                sock, _ = await loop.sock_accept(listener)
            except asyncio.CancelledError:
                raise
            except OSError:
                await asyncio.sleep(0.05)
                continue
            sock.setblocking(False)
            if not self.reserve():
                self.events.count("unknown", "connection-cap")
                sock.close()
                continue
            task = asyncio.create_task(self.accept(sock))
            self.pending.add(task)
            task.add_done_callback(self.pending.discard)

    async def accept(self, sock):
        """One PROXY v2 connection: exact header read, then the TLS handshake."""
        loop = asyncio.get_running_loop()
        source = "unknown"
        handed_over = False
        try:
            try:
                source = await asyncio.wait_for(read_proxy_header(loop, sock), self.proxy_header_timeout)
            except (ProxyHeaderError, asyncio.TimeoutError, OSError):
                self.events.count(source, "proxy-header")
                return
            protocol = Connection(self, source, reserved=True)
            try:
                handed_over = True
                await loop.connect_accepted_socket(lambda: protocol, sock, ssl=self.context,
                                                   ssl_handshake_timeout=self.handshake_timeout)
            except (OSError, asyncio.TimeoutError, ConnectionError, ValueError):
                self.events.count(source, "tls-handshake")
                if protocol.transport is None:
                    # The handshake never completed: the protocol was not attached.
                    self.release()
                    sock.close()
        finally:
            if not handed_over:
                self.release()
                sock.close()

    async def close(self):
        if self.accepting is not None:
            self.accepting.cancel()
            try:
                await self.accepting
            except asyncio.CancelledError:
                pass
        for task in list(self.pending):
            task.cancel()
        if self.pending:
            await asyncio.gather(*self.pending, return_exceptions=True)
        if self.listener is not None:
            self.listener.close()
        for server in self.servers:
            server.close()
        for transport in list(self.connections):
            transport.abort()
        for server in self.servers:
            await server.wait_closed()
