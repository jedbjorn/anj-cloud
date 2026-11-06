"""Spec #20 listener and edge: PROXY v2 accept path, timeouts, connection cap, headers, TLS.

The real gateway app and edge run in-process on a temporary Unix socket (production mode) or
TCP port (dev mode). Every certificate is a temporary fixture; nothing outside the temp dir.
"""

import asyncio
import json
import os
from pathlib import Path
import socket
import ssl
import stat
import struct
import unittest

from services.access import edge, health
from gateway_harness import HOST, BioClient, Harness, closed_within, elapsed


class ProxyHeaderParsingTests(unittest.TestCase):
    def test_valid_headers_and_sources(self):
        cases = {("203.0.113.7",): "203.0.113.7", ("2001:db8::7",): "2001:db8::7", ("::ffff:198.51.100.9",): "198.51.100.9"}
        for (address,), expected in cases.items():
            header = edge.proxy_header(address)
            command, family, length = edge.parse_preamble(header[:16])
            self.assertEqual((1, len(header) - 16), (command, length))
            self.assertEqual(expected, edge.source_from(command, family, header[16:]))
        command, family, length = edge.parse_preamble(edge.local_header())
        self.assertEqual((0, 0, "local"), (command, length, edge.source_from(command, family, b"")))

    def test_malformed_preambles_are_refused(self):
        good = edge.proxy_header("203.0.113.7")
        bad = {
            "signature": b"\x16\x03\x01" + good[3:16],
            "version 1": good[:12] + b"\x11" + good[13:16],
            "command": good[:12] + b"\x22" + good[13:16],
            "udp": good[:13] + b"\x12" + good[14:16],
            "unix": good[:13] + b"\x31" + good[14:16],
            "unspec proxy": good[:13] + b"\x00" + good[14:16],
            "short ipv4 block": good[:14] + struct.pack("!H", 8),
            "short ipv6 block": good[:13] + b"\x21" + struct.pack("!H", 20),
            "oversized": good[:14] + struct.pack("!H", 4096),
            "truncated": good[:10],
        }
        for name, preamble in bad.items():
            with self.subTest(name), self.assertRaises(edge.ProxyHeaderError):
                edge.parse_preamble(preamble)


class ProxyAcceptPathTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.harness = Harness(proxy_header_timeout=0.4, handshake_timeout=0.6, request_header_timeout=0.6)
        await self.harness.start()

    async def asyncTearDown(self):
        await self.harness.stop()

    def proxied(self, source="203.0.113.7", prefix=None, **context):
        raw = self.harness.connect()
        return BioClient(raw, self.harness.client_context(**context), prefix=edge.proxy_header(source) if prefix is None else prefix)

    async def test_header_and_client_hello_in_one_write_complete_tls_and_source_is_logged(self):
        def run():
            results = []
            for source in ("203.0.113.7", "2001:db8::7"):
                client = self.proxied(source)
                results.append(client.request("GET", "/health"))
                client.close()
            return results
        results = await asyncio.to_thread(run)
        for status, headers, body in results:
            self.assertEqual((200, {"status": "ready"}), (status, json.loads(body)))
            self.assertNotIn("server", headers)
        self.assertEqual(["203.0.113.7", "2001:db8::7"], [line["source"] for line in self.harness.requests(route="health")])
        self.assertEqual([], self.harness.summaries())

    async def test_local_header_is_accepted_by_the_production_healthcheck(self):
        state = await asyncio.to_thread(health.check, self.harness.socket_path, HOST, str(self.harness.authority.crt))
        self.assertEqual({"status": "ready"}, state)
        self.assertEqual(["local"], [line["source"] for line in self.harness.requests(route="health")])
        # Hostname verification is pinned: another name fails.
        with self.assertRaises(ssl.SSLCertVerificationError):
            await asyncio.to_thread(health.check, self.harness.socket_path, "other.f15a.test", str(self.harness.authority.crt))
        self.harness.nextcloud.ready = False
        with self.assertRaisesRegex(RuntimeError, "503"):
            await asyncio.to_thread(health.check, self.harness.socket_path, HOST, str(self.harness.authority.crt))

    async def test_missing_short_and_malformed_headers_are_closed(self):
        good = edge.proxy_header("203.0.113.7")

        def run():
            outcomes = {}
            # No header: the ClientHello's first 16 bytes fail the signature check.
            raw = self.harness.connect()
            try:
                BioClient(raw, self.harness.client_context())
                outcomes["missing"] = False
            except (ConnectionError, ssl.SSLError, OSError):
                outcomes["missing"] = True
            raw.close()
            for name, payload in {"short": good[:10], "declared longer": good[:-4],
                                  "version": good[:12] + b"\x11" + good[13:],
                                  "udp": good[:13] + b"\x12" + good[14:]}.items():
                raw = self.harness.connect()
                raw.sendall(payload)
                outcomes[name] = closed_within(raw, 2.0)
                raw.close()
            return outcomes
        outcomes = await asyncio.to_thread(run)
        self.assertEqual({"missing": True, "short": True, "declared longer": True, "version": True, "udp": True}, outcomes)
        self.assertEqual(5, self.harness.counted("proxy-header"))
        # The listener keeps serving.
        def again():
            client = self.proxied()
            try:
                return client.request("GET", "/health")[0]
            finally:
                client.close()
        self.assertEqual(200, await asyncio.to_thread(again))

    async def test_handshake_deadline_and_header_watchdog_close_slow_connections(self):
        def run():
            outcomes = {}
            raw = self.harness.connect()
            raw.sendall(edge.proxy_header("198.51.100.20"))
            with elapsed() as timing:
                outcomes["no client hello"] = closed_within(raw, 3.0)
            outcomes["no client hello seconds"] = timing["seconds"]
            raw.close()
            client = self.proxied("198.51.100.21")
            client.send(b"GET /health HTTP/1.1\r\nHost: " + HOST.encode())
            with elapsed() as timing:
                outcomes["incomplete headers"] = client.closed_within(3.0)
            outcomes["incomplete headers seconds"] = timing["seconds"]
            client.close()
            client = self.proxied("198.51.100.22")
            status, _, _ = client.request("GET", "/health", keep_alive=True)
            outcomes["keep-alive status"] = status
            with elapsed() as timing:
                outcomes["idle keep-alive"] = client.closed_within(3.0)
            outcomes["idle keep-alive seconds"] = timing["seconds"]
            client.close()
            return outcomes
        outcomes = await asyncio.to_thread(run)
        self.assertTrue(outcomes["no client hello"] and outcomes["incomplete headers"] and outcomes["idle keep-alive"])
        self.assertEqual(200, outcomes["keep-alive status"])
        for key in ("no client hello seconds", "incomplete headers seconds", "idle keep-alive seconds"):
            self.assertLess(outcomes[key], 2.0, key)
        self.assertEqual(1, self.harness.counted("tls-handshake", "198.51.100.20"))
        self.assertEqual(1, self.harness.counted("header-timeout", "198.51.100.21"))
        self.assertEqual(1, self.harness.counted("header-timeout", "198.51.100.22"))

    async def test_socket_is_0660_and_a_stale_socket_is_replaced(self):
        info = os.stat(self.harness.socket_path)
        self.assertTrue(stat.S_ISSOCK(info.st_mode))
        self.assertEqual(0o660, stat.S_IMODE(info.st_mode))
        await self.harness.gateway.edge.close()
        # A stale socket file from a crash is unlinked; a non-socket is refused.
        stale = socket.socket(socket.AF_UNIX)
        stale.bind(str(Path(self.harness.directory) / "stale.sock"))
        stale.close()
        replacement = edge.Edge(self.harness.events, self.harness.runner.server, None)
        await replacement.start_unix(Path(self.harness.directory) / "stale.sock")
        await replacement.close()
        regular = Path(self.harness.directory) / "regular"
        regular.write_text("x")
        with self.assertRaisesRegex(RuntimeError, "not a socket"):
            await edge.Edge(self.harness.events, self.harness.runner.server, None).start_unix(regular)
        self.harness.gateway.edge = edge.Edge(self.harness.events, self.harness.runner.server, None)


class ConnectionCapTests(unittest.IsolatedAsyncioTestCase):
    async def test_connections_beyond_the_cap_are_refused_in_both_modes(self):
        for listener in ("proxy-unix", "tcp"):
            with self.subTest(listener):
                harness = Harness(listener=listener, max_connections=2)
                await harness.start()
                try:
                    def run():
                        prefix = (lambda source: edge.proxy_header(source)) if listener == "proxy-unix" else (lambda source: b"")
                        held = [BioClient(harness.connect(), harness.client_context(), prefix=prefix("192.0.2.%d" % n)) for n in (1, 2)]
                        refused = harness.connect()
                        try:
                            # Production refuses before the handshake; the dev TCP listener's
                            # protocol sees the connection after it, then aborts unserved.
                            third = BioClient(refused, harness.client_context(), prefix=prefix("192.0.2.3")).closed_within(2.0)
                        except (ConnectionError, ssl.SSLError, OSError):
                            third = True
                        refused.close()
                        statuses = [client.request("GET", "/health")[0] for client in held]
                        for client in held:
                            client.close()
                        return third, statuses
                    third, statuses = await asyncio.to_thread(run)
                    self.assertTrue(third)
                    self.assertEqual([200, 200], statuses)
                    self.assertEqual(1, harness.counted("connection-cap"))
                    # Slots are released: a new connection is served again.
                    await asyncio.sleep(0.1)
                    prefix = edge.proxy_header("192.0.2.4") if listener == "proxy-unix" else b""
                    def again():
                        client = BioClient(harness.connect(), harness.client_context(), prefix=prefix)
                        try:
                            return client.request("GET", "/health")[0]
                        finally:
                            client.close()
                    self.assertEqual(200, await asyncio.to_thread(again))
                finally:
                    await harness.stop()


class DevListenerTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.harness = Harness(listener="tcp", request_header_timeout=0.6)
        await self.harness.start()

    async def asyncTearDown(self):
        await self.harness.stop()

    async def test_tcp_listener_needs_no_proxy_header_and_applies_the_watchdog(self):
        def run():
            client = BioClient(self.harness.connect(), self.harness.client_context())
            status, _, body = client.request("GET", "/health", keep_alive=True)
            with elapsed() as timing:
                closed = client.closed_within(3.0)
            client.close()
            partial = BioClient(self.harness.connect(), self.harness.client_context())
            partial.send(b"GET /health HTTP/1.1\r\n")
            partial_closed = partial.closed_within(3.0)
            partial.close()
            return status, json.loads(body), closed, timing["seconds"], partial_closed
        status, body, closed, seconds, partial_closed = await asyncio.to_thread(run)
        self.assertEqual((200, {"status": "ready"}), (status, body))
        self.assertTrue(closed and partial_closed)
        self.assertLess(seconds, 2.0)
        self.assertEqual(["127.0.0.1"], [line["source"] for line in self.harness.requests(route="health")])
        self.assertEqual(2, self.harness.counted("header-timeout", "127.0.0.1"))


class HeadersAndTlsTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.harness = Harness()
        await self.harness.start()

    async def asyncTearDown(self):
        await self.harness.stop()

    async def test_server_header_is_absent_on_routed_unrouted_and_parser_error_responses(self):
        def run():
            responses = {}
            for name, path in (("health", "/health"), ("unrouted", "/nothing-here"), ("unauthenticated", "/dav/")):
                client = BioClient(self.harness.connect(), self.harness.client_context(), prefix=edge.proxy_header("203.0.113.9"))
                responses[name] = client.request("GET", path)
                client.close()
            client = BioClient(self.harness.connect(), self.harness.client_context(), prefix=edge.proxy_header("203.0.113.9"))
            client.send(b"NOT A REQUEST LINE\r\n\r\n")
            responses["malformed"] = client.response()
            client.close()
            return responses
        responses = await asyncio.to_thread(run)
        self.assertEqual({"health": 200, "unrouted": 404, "unauthenticated": 401, "malformed": 400},
                         {name: response[0] for name, response in responses.items()})
        for name, (_, headers, _) in responses.items():
            self.assertNotIn("server", headers, name)
        self.assertEqual(b'{"status": "ready"}', responses["health"][2])

    async def test_aead_only_tls_policy(self):
        def handshake(**options):
            client = BioClient(self.harness.connect(), self.harness.client_context(**options), prefix=edge.local_header())
            version, cipher = client.tls.version(), client.tls.cipher()[0]
            client.close()
            return version, cipher

        def run():
            results = {"default": handshake()}
            cbc = self.harness.client_context(maximum_version=ssl.TLSVersion.TLSv1_2)
            cbc.set_ciphers("ECDHE-ECDSA-AES128-SHA256:ECDHE-ECDSA-AES256-SHA:ECDHE-ECDSA-AES128-SHA")
            raw = self.harness.connect()
            try:
                BioClient(raw, cbc, prefix=edge.local_header())
                results["cbc"] = "accepted"
            except (ssl.SSLError, ConnectionError, OSError):
                results["cbc"] = "refused"
            raw.close()
            gcm = self.harness.client_context(maximum_version=ssl.TLSVersion.TLSv1_2)
            gcm.set_ciphers("ECDHE-ECDSA-AES128-GCM-SHA256")
            client = BioClient(self.harness.connect(), gcm, prefix=edge.local_header())
            results["tls12 gcm"] = (client.tls.version(), client.tls.cipher()[0])
            client.close()
            return results
        results = await asyncio.to_thread(run)
        self.assertEqual("TLSv1.3", results["default"][0])
        self.assertEqual("refused", results["cbc"])
        self.assertEqual(("TLSv1.2", "ECDHE-ECDSA-AES128-GCM-SHA256"), results["tls12 gcm"])


if __name__ == "__main__":
    unittest.main()
