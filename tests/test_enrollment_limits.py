"""Spec #20 per-source enrollment limits and block (decision #69 (a)); route authentication (S9)."""

import asyncio
import io
import json
import time
import unittest

import aiohttp

from services.access import edge
from services.access.observe import EnrollmentGuard, Events
from services.access.server import UNAUTHENTICATED_ROUTES
from gateway_harness import HOST, BioClient, Clock, Device, Harness, pair, pem
from test_permanent_credentials import pem_csr


class GuardTests(unittest.TestCase):
    def setUp(self):
        self.clock, self.wall = Clock(), Clock(1793600000.0)
        self.stream = io.StringIO()
        self.guard = EnrollmentGuard(Events(self.stream, clock=self.wall), clock=self.clock, wall=self.wall)

    def blocks(self):
        return [json.loads(line) for line in self.stream.getvalue().splitlines() if '"enroll-block"' in line]

    def test_ten_per_minute_per_source_then_429_and_window_rolls(self):
        self.assertEqual([None] * 10, [self.guard.admit("A") for _ in range(10)])
        self.assertEqual("enroll-rate", self.guard.admit("A"))
        self.assertIsNone(self.guard.admit("B"))
        self.clock.advance(60.1)
        self.assertIsNone(self.guard.admit("A"))

    def test_eight_failures_in_ten_minutes_block_for_fifteen_minutes_with_one_line(self):
        for _ in range(7):
            self.assertFalse(self.guard.failed("A"))
            self.clock.advance(60)
        self.assertTrue(self.guard.failed("A"))
        self.assertEqual("enroll-blocked", self.guard.admit("A"))
        self.assertIsNone(self.guard.admit("B"))
        # Requests during the block are refused, not counted again; one line per block.
        for _ in range(20):
            self.guard.failed("A")
            self.assertEqual("enroll-blocked", self.guard.admit("A"))
        self.assertEqual(1, len(self.blocks()))
        line = self.blocks()[0]
        self.assertEqual({"time", "event", "source", "failures", "block_start", "block_end"}, set(line))
        self.assertEqual(("A", 8), (line["source"], line["failures"]))
        self.clock.advance(899)
        self.assertEqual("enroll-blocked", self.guard.admit("A"))
        self.clock.advance(1.1)
        self.assertIsNone(self.guard.admit("A"))
        # After the block a fresh 8 failures are needed.
        self.assertFalse(self.guard.failed("A"))

    def test_seven_failures_then_a_pause_past_the_window_then_one_more_do_not_block(self):
        for _ in range(7):
            self.guard.failed("A")
        self.clock.advance(600.1)
        self.assertFalse(self.guard.failed("A"))
        self.assertIsNone(self.guard.admit("A"))
        self.assertEqual([], self.blocks())

    def test_global_backstop_cannot_be_exhausted_by_one_source(self):
        with self.assertRaises(ValueError):
            EnrollmentGuard(Events(io.StringIO()), rate=10, global_rate=10)
        sources = ["198.51.100.%d" % n for n in range(13)]
        results = [self.guard.admit(source) for source in sources for _ in range(10)]
        self.assertEqual(120, results.count(None))
        self.assertEqual({"enroll-global"}, set(results[120:]))


class EnrollmentOverProxyTests(unittest.IsolatedAsyncioTestCase):
    """Two crafted sources through the real PROXY v2 accept path."""

    async def asyncSetUp(self):
        self.clock = Clock()
        self.harness = Harness(guard_clock=self.clock)
        await self.harness.start()

    async def asyncTearDown(self):
        await self.harness.stop()

    def post(self, source, path, body, **context):
        client = BioClient(self.harness.connect(), self.harness.client_context(**context), prefix=edge.proxy_header(source))
        try:
            data = json.dumps(body).encode()
            return client.request("POST", path, data, {"Content-Type": "application/json"})
        finally:
            client.close()

    def get(self, source, path, device=None, certificate=None):
        client = BioClient(self.harness.connect(), self.harness.client_context(device, certificate), prefix=edge.proxy_header(source))
        try:
            return client.request("GET", path)
        finally:
            client.close()

    async def test_rate_block_unblock_isolation_and_paired_device_on_blocked_source(self):
        registry = self.harness.gateway.registry
        invitation, request = registry.invite("alice", "write"), pem_csr(Device().key)
        A, B, C = "203.0.113.10", "198.51.100.20", "192.0.2.30"
        bogus = {"code": "0" * 32, "csr": request}
        second = {"code": registry.invite("bob", "write")["code"], "csr": pem_csr(Device().key)}

        def run():
            results = {}
            results["A rate"] = [self.post(A, "/v1/enroll/status", {"code": invitation["code"], "csr": request})[0] for _ in range(11)]
            results["C failures"] = [self.post(C, "/v1/enroll", bogus)[0] for _ in range(9)]
            results["B enrolls"] = self.post(B, "/v1/enroll", second)
            return results
        results = await asyncio.to_thread(run)
        self.assertEqual([200] * 10 + [429], results["A rate"])
        self.assertEqual([400] * 8 + [429], results["C failures"])
        self.assertEqual((200, "pending"), (results["B enrolls"][0], json.loads(results["B enrolls"][2])["state"]))
        blocks = [line for line in self.harness.lines() if line["event"] == "enroll-block"]
        self.assertEqual([(C, 8)], [(line["source"], line["failures"]) for line in blocks])
        # The block covers enrollment only: a paired device sharing C's source keeps syncing.
        device = Device()
        _, certificate = pair(registry, self.harness.authority, device, "carol")
        status, _, body = await asyncio.to_thread(self.get, C, "/dav/notes.txt", device, certificate)
        self.assertEqual((200, b"synthetic content"), (status, body))
        status, _, _ = await asyncio.to_thread(self.post, C, "/v1/enroll/status", bogus)
        self.assertEqual(429, status)
        self.clock.advance(900.1)
        status, _, _ = await asyncio.to_thread(self.post, C, "/v1/enroll", bogus)
        self.assertEqual(400, status)
        # 429s are limit hits: aggregated per source per minute, never one request line each.
        self.assertEqual([], self.harness.requests(status=429))
        self.assertEqual(1, self.harness.counted("enroll-rate", A))
        self.assertEqual(2, self.harness.counted("enroll-blocked", C))
        log = self.harness.stream.getvalue()
        for secret in ("0" * 32, invitation["code"], second["code"], "BEGIN CERTIFICATE REQUEST", "token-carol", "notes.txt"):
            self.assertNotIn(secret, log)


class EnrollmentBodyDeadlineTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.harness = Harness()
        await self.harness.start()
        self.harness.gateway.body_timeout = 0.5

    async def asyncTearDown(self):
        await self.harness.stop()

    async def test_missing_or_trickled_enrollment_body_is_answered_408_and_closed(self):
        def run():
            outcomes = {}
            for name, trickle in (("missing", False), ("trickled", True)):
                client = BioClient(self.harness.connect(), self.harness.client_context(), prefix=edge.proxy_header("203.0.113.77"))
                client.send(("POST /v1/enroll HTTP/1.1\r\nHost: " + HOST + "\r\nContent-Type: application/json\r\n"
                             "Content-Length: 200\r\n\r\n").encode())
                if trickle:
                    for _ in range(3):
                        client.send(b" ")
                        time.sleep(0.2)
                started = time.monotonic()
                status, _, _ = client.response()
                closed = client.closed_within(2.0)
                outcomes[name] = (status, closed, time.monotonic() - started)
                client.close()
            return outcomes
        outcomes = await asyncio.to_thread(run)
        for name, (status, closed, seconds) in outcomes.items():
            self.assertEqual((408, True), (status, closed), name)
            self.assertLess(seconds, 3.0, name)
        # A timeout is not a rejected code: no failure counted, no block.
        self.assertEqual({}, self.harness.guard.failures)
        self.assertEqual(2, len(self.harness.requests(route="enroll", status=408, reason="body-timeout")))


class RouteAuthenticationTests(unittest.IsolatedAsyncioTestCase):
    """Every route except GET /health, GET /v1/ca and POST /v1/enroll* answers 401 without a device certificate."""

    async def asyncSetUp(self):
        self.harness = Harness(listener="tcp")
        await self.harness.start()

    async def asyncTearDown(self):
        await self.harness.stop()

    async def test_router_enumeration(self):
        app = self.harness.runner.app
        routes = {}
        for route in app.router.routes():
            info = route.resource.get_info()
            path = info.get("path") or info.get("formatter", "").replace("{path}", "probe/file.txt").replace("{share_id}", "1") \
                .replace("{uid}", "alice").replace("{device_id}", "00000000-0000-4000-8000-000000000000") \
                .replace("{invitation_id}", "00000000-0000-4000-8000-000000000001").replace("{operation}", "0" * 32) \
                .replace("{target}", "android-arm64")
            methods = ["GET", "HEAD", "OPTIONS", "PROPFIND", "PUT", "MKCOL", "DELETE", "MOVE", "COPY", "LOCK", "POST", "PATCH"] \
                if route.method == "*" else [route.method]
            for method in methods:
                routes[(method, path)] = route.resource.canonical
        self.assertIn(("GET", "/v1/device/certificate"), routes)
        self.assertIn(("GET", "/v1/files/added"), routes)
        self.assertTrue(any(path.startswith("/dav/") for _, path in routes))
        context = self.harness.client_context()
        statuses = {}
        async with aiohttp.ClientSession(connector=aiohttp.TCPConnector(ssl=context), trust_env=False) as session:
            for method, path in sorted(routes):
                url = f"https://127.0.0.1:{self.harness.port}{path}"
                async with session.request(method, url, server_hostname=HOST, allow_redirects=False,
                                           headers={"Host": HOST}, data=b"{}" if method in ("POST", "PUT") else None,
                                           ) as response:
                    statuses[(method, path)] = response.status
        for key, status in statuses.items():
            if key in UNAUTHENTICATED_ROUTES:
                self.assertNotEqual(401, status, key)
            else:
                self.assertEqual(401, status, key)
        self.assertEqual(401, statuses[("GET", "/v1/device/certificate")])
        self.assertEqual(401, statuses[("GET", "/v1/files/added")])
        # Client update feed (spec #28 G1): both routes need a device certificate.
        self.assertEqual(401, statuses[("GET", "/v1/client/releases/android-arm64")])
        self.assertEqual(401, statuses[("GET", "/v1/client/releases/android-arm64/package")])
        # Directory sharing (spec #26): every route needs a device certificate.
        for key in (("GET", "/v1/household/users"), ("GET", "/v1/shares/outgoing"), ("GET", "/v1/shares/incoming"),
                    ("POST", "/v1/shares"), ("PATCH", "/v1/shares/1"), ("DELETE", "/v1/shares/1")):
            self.assertEqual(401, statuses[key], key)
        # Household administration (spec #27): /v1/account and every /v1/admin/ route need a certificate.
        admin = [key for key in statuses if key[1] == "/v1/account" or key[1].startswith("/v1/admin/")]
        self.assertEqual(18, len([key for key in admin if key[0] != "HEAD"]), admin)
        self.assertIn(("GET", "/v1/admin/operations/" + "0" * 32), admin)   # SC-041 long actions
        for key in admin:
            self.assertEqual(401, statuses[key], key)
        self.assertEqual({("GET", "/health"), ("HEAD", "/health"), ("GET", "/v1/ca"), ("HEAD", "/v1/ca"), ("POST", "/v1/enroll"),
                          ("POST", "/v1/enroll/status")}, {key for key in statuses if key in UNAUTHENTICATED_ROUTES})
        # Spec #35: the CA route answers without a certificate, with the public issuer certificate only.
        self.assertEqual(200, statuses[("GET", "/v1/ca")])


if __name__ == "__main__":
    unittest.main()
