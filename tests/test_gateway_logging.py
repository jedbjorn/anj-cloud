"""Spec #20 structured logging (M8; decisions #68, #69 (g)): what is written and what never is."""

import asyncio
import io
import json
import unittest

from cryptography.hazmat.primitives import hashes

from services.access import edge, observe
from gateway_harness import BioClient, Clock, Device, Harness, pair
from test_permanent_credentials import pem_csr

REQUEST_FIELDS = {"time", "event", "source", "route", "method", "status", "bytes", "duration_ms"}


class EventsTests(unittest.TestCase):
    def test_rejects_and_limit_hits_aggregate_per_source_per_minute(self):
        clock, stream = Clock(1793600000.0), io.StringIO()
        events = observe.Events(stream, clock=clock)
        for _ in range(500):
            events.count("203.0.113.5", "proxy-header")
        events.count("203.0.113.5", "enroll-rate")
        events.count("198.51.100.1", "header-timeout")
        self.assertEqual("", stream.getvalue())  # nothing until the minute closes
        clock.advance(60)
        events.count("203.0.113.5", "proxy-header")
        lines = [json.loads(line) for line in stream.getvalue().splitlines()]
        self.assertEqual(2, len(lines))
        by_source = {line["source"]: line for line in lines}
        self.assertEqual({"enroll-rate": 1, "proxy-header": 500}, by_source["203.0.113.5"]["counts"])
        self.assertEqual(501, by_source["203.0.113.5"]["total"])
        self.assertEqual({"header-timeout": 1}, by_source["198.51.100.1"]["counts"])
        events.flush(force=True)
        self.assertEqual(3, len(stream.getvalue().splitlines()))

    def test_source_table_is_bounded(self):
        clock, stream = Clock(1793600000.0), io.StringIO()
        events = observe.Events(stream, clock=clock)
        for n in range(observe.MAX_SOURCES_PER_MINUTE + 50):
            events.count("source-%d" % n, "tls-handshake")
        events.flush(force=True)
        lines = [json.loads(line) for line in stream.getvalue().splitlines()]
        self.assertEqual(observe.MAX_SOURCES_PER_MINUTE + 1, len(lines))
        self.assertEqual(50, [line for line in lines if line["source"] == "other"][0]["total"])


class LoggingContentTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.harness = Harness()
        await self.harness.start()

    async def asyncTearDown(self):
        await self.harness.stop()

    async def test_events_carry_source_and_never_codes_csrs_tokens_keys_paths_or_names(self):
        registry = self.harness.gateway.registry
        invitation = registry.invite("alice", "write")
        csr = pem_csr(Device().key)
        device = Device()
        identity, certificate = pair(registry, self.harness.authority, device, "dana")
        token = registry.device(identity)["token"]
        secret_name = "Tax Return 2026 private.pdf"
        A, B, D = "203.0.113.40", "198.51.100.41", "192.0.2.42"

        def call(source, method, path, body=None, device=None, certificate=None, prefix=None):
            client = BioClient(self.harness.connect(), self.harness.client_context(device, certificate),
                               prefix=edge.proxy_header(source) if prefix is None else prefix)
            try:
                data = json.dumps(body).encode() if body is not None else b""
                return client.request(method, path, data, {"Content-Type": "application/json"} if body is not None else None)[0]
            finally:
                client.close()

        def run():
            statuses = {}
            statuses["enroll"] = call(A, "POST", "/v1/enroll", {"code": invitation["code"], "csr": csr, "label": "Kitchen laptop"})
            statuses["bad code"] = call(A, "POST", "/v1/enroll", {"code": "SECRETCODE0000000000000000000000", "csr": csr})
            statuses["dav 401"] = call(B, "PROPFIND", "/dav/" + secret_name.replace(" ", "%20") + "?probe=querysecret")
            statuses["dav read"] = call(D, "GET", "/dav/Documents/" + secret_name.replace(" ", "%20"), device=device, certificate=certificate)
            statuses["files added"] = call(D, "GET", "/v1/files/added?after=0", device=device, certificate=certificate)
            statuses["rate"] = [call(B, "POST", "/v1/enroll/status", {"code": invitation["code"], "csr": csr}) for _ in range(11)][-1]
            raw = self.harness.connect()
            raw.sendall(b"GARBAGE-NOT-PROXY-HEADER")
            raw.close()
            return statuses
        statuses = await asyncio.to_thread(run)
        await asyncio.sleep(0.1)
        self.assertEqual({"enroll": 200, "bad code": 400, "dav 401": 401, "dav read": 200, "files added": 200, "rate": 429}, statuses)
        lines = self.harness.lines()
        requests = [line for line in lines if line["event"] == "request"]
        for line in requests:
            self.assertTrue(REQUEST_FIELDS <= set(line), line)
            self.assertLessEqual(set(line), REQUEST_FIELDS | {"bytes_in", "device", "cert_sha256", "reason"})
        routes = {(line["route"], line["source"], line["status"]) for line in requests}
        self.assertTrue({("enroll", A, 200), ("enroll", A, 400), ("dav-read", B, 401), ("dav-read", D, 200),
                         ("files-added", D, 200), ("enroll-status", B, 200)} <= routes)
        dav = [line for line in requests if line["route"] == "dav-read" and line["status"] == 200][0]
        self.assertEqual((identity, certificate.fingerprint(hashes.SHA256()).hex()),
                         (dav["device"], dav["cert_sha256"]))
        unauthenticated = [line for line in requests if line["status"] == 401][0]
        self.assertEqual("no-certificate", unauthenticated["reason"])
        self.assertEqual([], [line for line in requests if line["status"] == 429])
        self.assertEqual(1, self.harness.counted("enroll-rate", B))
        self.assertEqual(1, self.harness.counted("proxy-header"))
        text = self.harness.stream.getvalue()
        for forbidden in (invitation["code"], "SECRETCODE", "CERTIFICATE REQUEST", "BEGIN", token, "Tax", "Return", "private.pdf",
                          "Documents", "querysecret", "probe", "Kitchen", "PRIVATE KEY", "Authorization", "Content-Type"):
            self.assertNotIn(forbidden, text, forbidden)


if __name__ == "__main__":
    unittest.main()
