"""Client update feed (spec #28 G1, decision #108 Q6): operator publish, device-authenticated
manifest and package routes, retention, refusals and what is never logged or exposed.

Real gateway behind the real edge (gateway_harness), real operator socket application on a
temporary Unix socket, and the in-container publish helper. Every CA is a temporary fixture.
"""

import asyncio
import hashlib
import io
import json
import os
from pathlib import Path
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

from aiohttp import web

from deploy import access_operator
from gateway_harness import BioClient, Device, Harness, pair
from services.access import edge, release_publish, releases
from services.access.release_manifest import SIGNED, ManifestError, manifest_from, signed_message
from services.access.server import operator_app
from test_permanent_credentials import leaf_id, pem

TARGET = "android-arm64"
SIGNER = "ab" * 32


def package(version_code, size=300_000):
    seed = hashlib.sha256(str(version_code).encode()).digest()
    data = (seed * (size // len(seed) + 1))[:size]
    return data, {"version": f"1.0.{version_code}", "version_code": version_code, "size": len(data),
                  "sha256": hashlib.sha256(data).hexdigest(), "signer_sha256": SIGNER}


class ManifestRuleTests(unittest.TestCase):
    def test_a_complete_manifest_is_normalised_with_its_target(self):
        _data, manifest = package(7)
        self.assertEqual({"target": TARGET, **manifest}, manifest_from(manifest, TARGET))
        self.assertEqual(manifest_from(manifest, TARGET), manifest_from({**manifest, "target": TARGET}, TARGET))

    def test_bad_manifests_are_refused_with_the_field(self):
        _data, good = package(7)
        cases = [([], "object"), ({**good, "path": "/x"}, "Unexpected"), ({**good, "target": "linux-x86_64"}, "another target"),
                 ({k: v for k, v in good.items() if k != "signer_sha256"}, "lacks signer_sha256"),
                 ({**good, "version": "../1"}, "version"), ({**good, "version": ""}, "version"),
                 ({**good, "version_code": 0}, "version_code"), ({**good, "version_code": "7"}, "version_code"),
                 ({**good, "version_code": True}, "version_code"), ({**good, "version_code": 2_100_000_001}, "version_code"),
                 ({**good, "size": 0}, "size"), ({**good, "size": 512 * 1024 * 1024 + 1}, "size"),
                 ({**good, "sha256": good["sha256"].upper()}, "sha256"), ({**good, "signer_sha256": "ab:cd"}, "signer_sha256")]
        for data, reason in cases:
            with self.subTest(reason=reason), self.assertRaises(ManifestError) as caught:
                manifest_from(data, TARGET)
            self.assertIn(reason, str(caught.exception))

    def test_android_and_the_three_desktop_targets_are_served(self):
        self.assertEqual({TARGET, "linux-x86_64", "macos-arm64", "windows-x64"}, set(releases.TARGETS))
        self.assertEqual("application/vnd.android.package-archive", releases.TARGETS[TARGET])
        self.assertEqual("application/gzip", releases.TARGETS["linux-x86_64"])
        self.assertEqual({"linux-x86_64", "macos-arm64", "windows-x64"}, set(SIGNED))


VECTOR = json.loads((Path(__file__).resolve().parent.parent / "apps/client/tool/testdata/release_signature_vector.json").read_text())


def desktop(version_code, size=300_000, target="linux-x86_64", **extra):
    """A desktop package and a manifest shaped like deploy/release.py's. The gateway checks the
    signature's shape only (clients verify it), so a fixed placeholder signature is enough here."""
    data, android = package(version_code, size)
    manifest = {name: android[name] for name in ("version", "version_code", "size", "sha256")}
    return data, {**manifest, "key_id": "0123456789abcdef", "signature": "A" * 86 + "==", **extra}


class DesktopManifestTests(unittest.TestCase):
    """Spec #37 U-core: the gateway stores and serves the signature; it never signs or verifies."""

    def test_desktop_manifests_carry_key_id_and_signature(self):
        for target in ("linux-x86_64", "macos-arm64", "windows-x64"):
            _data, manifest = desktop(9, target=target)
            self.assertEqual({"target": target, **manifest}, manifest_from(manifest, target))
        _data, manifest = desktop(9, min_client_version_code=4)
        self.assertEqual(4, manifest_from(manifest, "linux-x86_64")["min_client_version_code"])

    def test_bad_desktop_manifests_are_refused(self):
        _data, good = desktop(9)
        cases = [({k: v for k, v in good.items() if k != "signature"}, "lacks signature"),
                 ({k: v for k, v in good.items() if k != "key_id"}, "lacks key_id"),
                 ({**good, "signer_sha256": SIGNER}, "Unexpected"),
                 ({**good, "key_id": "0123456789ABCDEF"}, "key_id"), ({**good, "key_id": "01"}, "key_id"),
                 ({**good, "signature": "A" * 88}, "signature"), ({**good, "signature": 7}, "signature"),
                 ({**good, "min_client_version_code": 10}, "min_client_version_code"),
                 ({**good, "min_client_version_code": True}, "min_client_version_code")]
        for data, reason in cases:
            with self.subTest(reason=reason), self.assertRaises(ManifestError) as caught:
                manifest_from(data, "linux-x86_64")
            self.assertIn(reason, str(caught.exception))
        _data, android = package(3)
        with self.assertRaisesRegex(ManifestError, "Unexpected"):
            manifest_from({**android, "min_client_version_code": 1}, TARGET)

    def test_signed_message_is_the_shared_vector(self):
        """The bytes the release key signs; the Linux manager and the Dart client build the same."""
        manifest = manifest_from(VECTOR["manifest"], "linux-x86_64")
        self.assertEqual(VECTOR["signed_message"].encode(), signed_message(manifest))
        self.assertEqual(b"anj-cloud release v1\ntarget linux-x86_64\n", signed_message(manifest)[:41])


class RangeTests(unittest.TestCase):
    def test_single_ranges(self):
        cases = {None: None, "bytes=0-99": (0, 99), "bytes=100-": (100, 999), "bytes=-10": (990, 999),
                 "bytes=-5000": (0, 999), "bytes=900-5000": (900, 999), "bytes=1000-": "unsatisfiable",
                 "bytes=-0": "unsatisfiable", "bytes=5-1": None, "bytes=0-1,5-6": None, "items=0-1": None,
                 "bytes=-": None, "bytes=" + "9" * 70 + "-": None}
        for header, expected in cases.items():
            with self.subTest(header=header):
                self.assertEqual(expected, releases.parse_range(header, 1000))


class FeedTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.harness = Harness()
        await self.harness.start()
        self.gateway = self.harness.gateway
        self.registry = self.gateway.registry
        self.socket = str(self.harness.directory / "operator.sock")
        self.operator = web.AppRunner(operator_app(self.gateway), access_log=None)
        await self.operator.setup()
        await web.UnixSite(self.operator, self.socket).start()
        self.device = Device()
        self.identity, self.certificate = pair(self.registry, self.harness.authority, self.device, "alice")
        self.root = self.harness.directory / "state" / "releases"

    async def asyncTearDown(self):
        await self.operator.cleanup()
        await self.harness.stop()

    async def publish(self, data, manifest, target=TARGET):
        return await release_publish.publish(target, manifest, io.BytesIO(data), socket=self.socket)

    async def call(self, method, path, device=None, certificate=None, headers=None):
        device = self.device if device is None else device
        certificate = self.certificate if certificate is None else certificate

        def run():
            context = self.harness.client_context(device or None, certificate or None) if device else self.harness.client_context()
            raw = self.harness.connect()
            try:
                client = BioClient(raw, context, prefix=edge.proxy_header("192.0.2.50"))
            except BaseException:
                raw.close()
                raise
            try:
                return client.request(method, path, headers=headers)
            finally:
                client.close()
        return await asyncio.to_thread(run)

    def kept(self):
        return sorted(entry.name for entry in (self.root / TARGET).iterdir())

    # Publish -----------------------------------------------------------------------------------

    async def test_publish_then_fetch_manifest_and_package(self):
        data, manifest = package(1, size=1_500_000)
        status, result = await self.publish(data, manifest)
        self.assertEqual(200, status, result)
        self.assertEqual({"state": "published", "release": {"target": TARGET, **manifest}, "previous_version_code": None,
                          "pruned_version_codes": [], "prune": "done"}, result)
        status, headers, body = await self.call("GET", "/v1/client/releases/" + TARGET)
        self.assertEqual(200, status)
        self.assertEqual("no-store", headers["cache-control"])
        self.assertEqual({"target": TARGET, **manifest}, json.loads(body))
        status, headers, body = await self.call("GET", "/v1/client/releases/" + TARGET + "/package")
        self.assertEqual(200, status)
        self.assertEqual((str(len(data)), "bytes", '"' + manifest["sha256"] + '"', "no-store"),
                         (headers["content-length"], headers["accept-ranges"], headers["etag"], headers["cache-control"]))
        self.assertEqual("application/vnd.android.package-archive", headers["content-type"])
        self.assertNotIn("content-disposition", headers)
        self.assertEqual(manifest["sha256"], hashlib.sha256(body).hexdigest())
        status, headers, body = await self.call("HEAD", "/v1/client/releases/" + TARGET + "/package")
        self.assertEqual((200, str(len(data)), b""), (status, headers["content-length"], body))

    async def test_a_desktop_release_is_stored_and_served_with_its_signature(self):
        """Spec #37 U-core: what the operator signed on the VM host reaches the device unchanged."""
        target = "linux-x86_64"
        data, manifest = desktop(612, min_client_version_code=600)
        status, result = await self.publish(data, manifest, target)
        self.assertEqual(200, status, result)
        status, _headers, body = await self.call("GET", "/v1/client/releases/" + target)
        self.assertEqual((200, {"target": target, **manifest}), (status, json.loads(body)))
        status, headers, body = await self.call("GET", "/v1/client/releases/" + target + "/package")
        self.assertEqual((200, "application/gzip", data), (status, headers["content-type"], body))
        status, _headers, body = await self.call("GET", "/v1/client/releases/" + TARGET)
        self.assertEqual((404, {"error": "no_release"}), (status, json.loads(body)))
        _data, unsigned = desktop(613)
        del unsigned["signature"]
        status, result = await self.publish(data, unsigned, target)
        self.assertEqual((400, "Release manifest lacks signature"), (status, result["error"]))

    async def test_ranges_resume_a_download_and_a_changed_release_is_sent_whole(self):
        data, manifest = package(1)
        await self.publish(data, manifest)
        route = "/v1/client/releases/" + TARGET + "/package"
        etag = '"' + manifest["sha256"] + '"'
        status, headers, body = await self.call("GET", route, headers={"Range": "bytes=1000-"})
        self.assertEqual((206, f"bytes 1000-{len(data) - 1}/{len(data)}", str(len(data) - 1000)),
                         (status, headers["content-range"], headers["content-length"]))
        self.assertEqual(data[1000:], body)
        status, headers, body = await self.call("GET", route, headers={"Range": "bytes=10-19", "If-Range": etag})
        self.assertEqual((206, data[10:20]), (status, body))
        status, _headers, body = await self.call("GET", route, headers={"Range": "bytes=-7"})
        self.assertEqual((206, data[-7:]), (status, body))
        status, headers, body = await self.call("GET", route, headers={"Range": "bytes=10-19", "If-Range": '"' + "0" * 64 + '"'})
        self.assertEqual((200, data), (status, body))
        status, headers, _body = await self.call("GET", route, headers={"Range": f"bytes={len(data)}-"})
        self.assertEqual((416, f"bytes */{len(data)}"), (status, headers["content-range"]))

    async def test_retention_keeps_current_and_previous(self):
        for code in (1, 2, 5):
            data, manifest = package(code)
            status, result = await self.publish(data, manifest)
            self.assertEqual(200, status, result)
        self.assertEqual({"previous_version_code": 2, "pruned_version_codes": [1]},
                         {key: result[key] for key in ("previous_version_code", "pruned_version_codes")})
        self.assertEqual(["2.json", "2.pkg", "5.json", "5.pkg", "current.json"], self.kept())
        self.assertEqual([], list((self.root / ".incoming").iterdir()))
        self.assertEqual({TARGET: {"current": {"target": TARGET, **manifest}, "kept": [5, 2]},
                          **{target: {"current": None, "kept": []} for target in ("linux-x86_64", "macos-arm64", "windows-x64")}},
                         self.gateway.releases.status())
        status, _headers, body = await self.call("GET", "/v1/client/releases/" + TARGET)
        self.assertEqual(5, json.loads(body)["version_code"])
        for path in [self.root, *self.root.rglob("*")]:
            self.assertEqual(0, path.stat().st_mode & 0o077, path)

    async def test_publish_refusals_leave_the_current_release_untouched(self):
        data, manifest = package(3)
        self.assertEqual(200, (await self.publish(data, manifest))[0])
        before = {name: (self.root / TARGET / name).read_bytes() for name in self.kept()}
        newer, newer_manifest = package(4)
        cases = {
            "SHA-256 differs": (newer[:-1] + b"!", newer_manifest, TARGET),
            "size differs": (newer[:-10], newer_manifest, TARGET),
            "larger than": (newer + b"extra", newer_manifest, TARGET),
            "greater than the current release's (3)": (data, manifest, TARGET),
            "Unknown release target": (newer, newer_manifest, "linux-arm64"),
            "lacks sha256": (newer, {k: v for k, v in newer_manifest.items() if k != "sha256"}, TARGET),
        }
        older, older_manifest = package(2)
        cases["greater than the current release's (3) "] = (older, older_manifest, TARGET)
        for reason, (body, sent, target) in cases.items():
            with self.subTest(reason=reason):
                status, result = await self.publish(body, sent, target)
                self.assertEqual(400, status)
                self.assertIn(reason.strip(), result["error"])
                self.assertNotIn(str(self.root), json.dumps(result))
        self.assertEqual(before, {name: (self.root / TARGET / name).read_bytes() for name in self.kept()})
        self.assertEqual([], list((self.root / ".incoming").iterdir()))
        self.assertEqual(3, self.gateway.releases.current(TARGET)["version_code"])

    async def test_one_publish_at_a_time(self):
        data, manifest = package(1, size=2_000_000)
        started, release = threading.Event(), threading.Event()

        class Slow(io.BytesIO):
            def read(self, size=-1):
                if self.tell():
                    started.set()
                    release.wait(10)
                return super().read(size)
        first = asyncio.create_task(release_publish.publish(TARGET, manifest, Slow(data), socket=self.socket))
        try:
            await asyncio.to_thread(started.wait, 10)
            for _ in range(200):
                if self.gateway.releases.publishing.locked():
                    break
                await asyncio.sleep(0.01)
            other, other_manifest = package(2)
            status, result = await self.publish(other, other_manifest)
            self.assertEqual((400, "Another release publish is in progress"), (status, result["error"]))
        finally:
            release.set()
        self.assertEqual(200, (await first)[0])
        self.assertEqual(1, self.gateway.releases.current(TARGET)["version_code"])

    # Devices -----------------------------------------------------------------------------------

    async def test_refusals_before_and_without_a_release(self):
        status, _headers, body = await self.call("GET", "/v1/client/releases/" + TARGET)
        self.assertEqual((404, {"error": "no_release"}), (status, json.loads(body)))
        status, _headers, body = await self.call("GET", "/v1/client/releases/" + TARGET + "/package")
        self.assertEqual((404, {"error": "no_release"}), (status, json.loads(body)))
        status, _headers, body = await self.call("GET", "/v1/client/releases/ios-arm64")
        self.assertEqual((404, {"error": "unknown_target"}), (status, json.loads(body)))
        data, manifest = package(1)
        await self.publish(data, manifest)
        status, _headers, _body = await self.call("GET", "/v1/client/releases/" + TARGET, device=False)
        self.assertEqual(401, status)
        status, _headers, _body = await self.call("GET", "/v1/client/releases/" + TARGET + "/package", device=False)
        self.assertEqual(401, status)
        status, _headers, _body = await self.call("GET", "/v1/client/releases/" + TARGET + "?v=1")
        self.assertEqual(400, status)
        # An unknown target is 401 too without a certificate: nothing is learned unauthenticated.
        status, _headers, _body = await self.call("GET", "/v1/client/releases/ios-arm64", device=False)
        self.assertEqual(401, status)

    async def test_revoked_devices_and_disabled_accounts_are_refused_read_grants_and_fences_are_not(self):
        data, manifest = package(1)
        await self.publish(data, manifest)
        route = "/v1/client/releases/" + TARGET + "/package"
        reader = Device()
        invitation = self.registry.invite("bob", "read")
        pending = self.registry.enroll(invitation["code"], reader.csr)
        self.registry.begin(pending["pairing_id"], pending["fingerprint"])
        reader_certificate = self.harness.authority.leaf(reader.key.public_key(), pending["device_id"])
        self.registry.activate(pending["pairing_id"], pending["fingerprint"], "token-bob", "2", pem(reader_certificate),
                               reader_certificate.not_valid_after_utc.timestamp(), leaf_id(reader_certificate))
        self.registry.maintenance()
        status, _headers, body = await self.call("GET", route, reader, reader_certificate)
        self.assertEqual((200, data), (status, body))
        self.registry.account_set("bob", "Bob", False)
        status, _headers, _body = await self.call("GET", route, reader, reader_certificate)
        self.assertEqual(403, status)
        self.registry.disable(self.identity)
        status, _headers, _body = await self.call("GET", "/v1/client/releases/" + TARGET)
        self.assertEqual(403, status)

    async def test_per_device_request_window(self):
        data, manifest = package(1)
        await self.publish(data, manifest)
        statuses = [(await self.call("GET", "/v1/client/releases/" + TARGET))[0] for _ in range(releases.RELEASE_RATE + 1)]
        self.assertEqual([200] * releases.RELEASE_RATE + [429], statuses)
        other = Device()
        identity, certificate = pair(self.registry, self.harness.authority, other, "carol")
        self.assertEqual(200, (await self.call("GET", "/v1/client/releases/" + TARGET, other, certificate))[0])

    async def test_package_streams_in_chunks_and_never_reads_the_whole_file(self):
        data, manifest = package(1, size=3 * releases.CHUNK + 17)
        await self.publish(data, manifest)
        writes = []
        original_write = web.StreamResponse.write

        async def write(response, chunk):
            writes.append(len(chunk))
            return await original_write(response, chunk)
        with patch.object(web.StreamResponse, "write", write):
            status, _headers, body = await self.call("GET", "/v1/client/releases/" + TARGET + "/package")
        self.assertEqual((200, data), (status, body))
        # One read and one drained write per chunk: memory stays at a chunk whatever the size.
        self.assertEqual([releases.CHUNK] * 3 + [17], writes)
        self.assertEqual({}, dict(self.gateway.releases.streams))
        self.assertEqual(set(), self.gateway.active[self.identity])

    async def test_revoking_the_device_aborts_its_download_in_flight(self):
        data, manifest = package(1, size=8 * 1024 * 1024)
        await self.publish(data, manifest)
        started, resume = threading.Event(), threading.Event()

        def download():
            received, raw = 0, self.harness.connect()
            try:
                client = BioClient(raw, self.harness.client_context(self.device, self.certificate),
                                   prefix=edge.proxy_header("192.0.2.50"))
                client.send(b"GET /v1/client/releases/" + TARGET.encode() + b"/package HTTP/1.1\r\nHost: x\r\n\r\n")
                received += len(client.receive())
                started.set()
                resume.wait(10)
                while chunk := client.receive():
                    received += len(chunk)
                return received
            except (ConnectionError, OSError):
                return received
            finally:
                raw.close()
        task = asyncio.create_task(asyncio.to_thread(download))
        await asyncio.to_thread(started.wait, 10)
        self.assertEqual(1, self.gateway.releases.streams[self.identity])
        self.registry.disable(self.identity)
        await self.gateway.abort_devices([self.identity])
        resume.set()
        self.assertLess(await task, len(data))
        for _ in range(100):
            if not self.gateway.releases.streams:
                break
            await asyncio.sleep(0.01)
        self.assertEqual({}, dict(self.gateway.releases.streams))

    async def test_requests_are_logged_as_release_without_names_or_paths(self):
        data, manifest = package(1)
        await self.publish(data, manifest)
        await self.call("GET", "/v1/client/releases/" + TARGET)
        await self.call("GET", "/v1/client/releases/" + TARGET + "/package")
        await self.call("GET", "/v1/client/releases/" + TARGET, device=False)
        requests = self.harness.requests(route="release")
        self.assertEqual([200, 200, 401], [line["status"] for line in requests])
        self.assertGreaterEqual(requests[1]["bytes"], len(data))  # wire bytes, headers included (as for DAV)
        self.assertEqual((self.identity, leaf_id(self.certificate)), (requests[1]["device"], requests[1]["cert_sha256"]))
        for line in requests:
            self.assertLessEqual(set(line), {"time", "event", "source", "route", "method", "status", "bytes", "duration_ms",
                                             "device", "cert_sha256", "reason"})
        published = [line for line in self.harness.lines() if line["event"] == "release-publish"]
        self.assertEqual([{"target": TARGET, "version_code": 1, "size": len(data), "sha256": manifest["sha256"]}],
                         [{k: v for k, v in line.items() if k not in ("time", "event")} for line in published])
        text = self.harness.stream.getvalue()
        for forbidden in (str(self.harness.directory), "releases/", ".pkg", ".json", ".part", "current"):
            self.assertNotIn(forbidden, text)

    async def test_stored_state_errors_never_name_a_path(self):
        data, manifest = package(1)
        await self.publish(data, manifest)
        (self.root / TARGET / "1.pkg").unlink()
        status, headers, body = await self.call("GET", "/v1/client/releases/" + TARGET + "/package")
        self.assertEqual(503, status)
        self.assertNotIn(str(self.harness.directory), body.decode() + json.dumps(headers))
        (self.root / TARGET / "current.json").write_text("{}")
        status, _headers, body = await self.call("GET", "/v1/client/releases/" + TARGET)
        self.assertEqual(503, status)
        self.assertNotIn("releases", body.decode())


    # Review findings F1-F4 (PR #56) --------------------------------------------------------------

    def open_download(self):
        """A download that read only its first piece; the caller decides how (or whether) to go on."""
        raw = self.harness.connect()
        try:
            client = BioClient(raw, self.harness.client_context(self.device, self.certificate), prefix=edge.proxy_header("192.0.2.50"))
            client.send(b"GET /v1/client/releases/" + TARGET.encode() + b"/package HTTP/1.1\r\nHost: x\r\n\r\n")
            return raw, client, client.receive()
        except BaseException:
            raw.close()
            raise

    async def freed(self, seconds=10):
        for _ in range(int(seconds * 100)):
            if not self.gateway.releases.streams and not self.gateway.active[self.identity]:
                return True
            await asyncio.sleep(0.01)
        return False

    async def test_a_reader_that_stops_reading_is_cut_after_the_write_timeout(self):
        data, manifest = package(1, size=16 * 1024 * 1024)
        await self.publish(data, manifest)
        self.gateway.releases.write_timeout = 0.5
        raw, client, _first = await asyncio.to_thread(self.open_download)
        try:
            self.assertEqual(1, self.gateway.releases.streams[self.identity])
            self.assertTrue(await self.freed(), "a stalled reader kept its slot")
            self.assertTrue(await asyncio.to_thread(client.closed_within, 5))
        finally:
            raw.close()
        line = self.harness.requests(route="release")[-1]
        self.assertEqual("stream-timeout", line["reason"])
        self.assertEqual(200, (await self.call("GET", "/v1/client/releases/" + TARGET + "/package"))[0])

    async def test_a_slow_reader_is_cut_at_the_total_download_limit(self):
        data, manifest = package(1, size=16 * 1024 * 1024)
        await self.publish(data, manifest)
        self.gateway.releases.stream_limit = 1.0

        def drip():
            raw, client, first = self.open_download()
            received = len(first)
            try:
                while chunk := client.receive():
                    received += len(chunk)
                    time.sleep(0.05)     # always moving, never idle: only the total limit ends it
            except (ConnectionError, OSError):
                pass
            finally:
                raw.close()
            return received
        received = await asyncio.wait_for(asyncio.to_thread(drip), 30)
        self.assertLess(received, len(data))
        self.assertTrue(await self.freed())
        self.assertEqual("stream-timeout", self.harness.requests(route="release")[-1]["reason"])

    async def test_a_read_failure_after_the_headers_cuts_the_connection_without_a_second_response(self):
        data, manifest = package(1, size=4 * 1024 * 1024)
        await self.publish(data, manifest)
        started, resume = threading.Event(), threading.Event()

        def download():
            raw, client, buffer = self.open_download()
            try:
                started.set()
                resume.wait(10)
                while chunk := client.receive():
                    buffer += chunk
            except (ConnectionError, OSError):
                pass
            finally:
                raw.close()
            return buffer
        task = asyncio.create_task(asyncio.to_thread(download))
        await asyncio.to_thread(started.wait, 10)
        os.truncate(self.root / TARGET / "1.pkg", 300_000)
        resume.set()
        head, _, body = (await task).partition(b"\r\n\r\n")
        self.assertTrue(head.startswith(b"HTTP/1.1 200"))
        self.assertLess(len(body), len(data))
        self.assertNotIn(b"HTTP/1.1", body)
        self.assertNotIn(b"Service operation failed", body)
        self.assertTrue(await self.freed())
        self.assertEqual("stream-failed", self.harness.requests(route="release")[-1]["reason"])

    async def test_a_prune_failure_after_the_swap_still_publishes(self):
        for code in (1, 2):
            data, manifest = package(code)
            await self.publish(data, manifest)
        new, new_manifest = package(3)
        with patch.object(releases.Releases, "prune", side_effect=OSError("disk")):
            status, result = await self.publish(new, new_manifest)
        self.assertEqual((200, "published", "failed", [], 2), (status, result["state"], result["prune"],
                                                              result["pruned_version_codes"], result["previous_version_code"]))
        self.assertEqual(3, self.gateway.releases.current(TARGET)["version_code"])
        events = [line["event"] for line in self.harness.lines() if line["event"].startswith("release-")]
        self.assertEqual(["release-publish"] * 3 + ["release-prune-failed"], events)
        self.assertEqual(["1.json", "1.pkg", "2.json", "2.pkg", "3.json", "3.pkg", "current.json"], self.kept())
        # The next publish keeps only its own two and removes the rest.
        later, later_manifest = package(4)
        status, result = await self.publish(later, later_manifest)
        self.assertEqual((200, "done", [1, 2]), (status, result["prune"], result["pruned_version_codes"]))
        self.assertEqual(["3.json", "3.pkg", "4.json", "4.pkg", "current.json"], self.kept())

    async def test_symlinked_release_storage_is_refused(self):
        decoy = self.harness.directory / "decoy"
        decoy.mkdir()
        (decoy / "precious.part").write_text("x")
        self.root.mkdir(mode=0o700)
        (self.root / ".incoming").symlink_to(decoy)
        data, manifest = package(1)
        status, result = await self.publish(data, manifest)
        self.assertEqual(400, status)
        self.assertIn("not a plain directory", result["error"])
        self.assertNotIn(str(self.harness.directory), result["error"])
        self.assertEqual(["precious.part"], sorted(entry.name for entry in decoy.iterdir()))
        (self.root / ".incoming").unlink()
        (self.root / TARGET).rmdir()             # created, empty, by the refused publish
        (self.root / TARGET).symlink_to(decoy)
        status, result = await self.publish(data, manifest)
        self.assertEqual((400, True), (status, "not a plain directory" in result["error"]))
        status, _headers, body = await self.call("GET", "/v1/client/releases/" + TARGET)
        self.assertEqual(503, status)
        self.assertNotIn(b"decoy", body)
        self.assertEqual(["precious.part"], sorted(entry.name for entry in decoy.iterdir()))


class StartupTests(unittest.IsolatedAsyncioTestCase):
    async def test_leftover_uploads_are_removed_when_the_gateway_starts(self):
        harness = Harness()
        incoming = harness.directory / "state" / "releases" / ".incoming"
        incoming.mkdir(parents=True)
        (incoming / "deadbeef.part").write_bytes(b"x" * 1000)
        (incoming / "other").write_text("kept: not an upload")
        await harness.start()
        try:
            self.assertEqual(["other"], sorted(entry.name for entry in incoming.iterdir()))
        finally:
            await harness.stop()


class FakeStack:
    def __init__(self, directory, current=None, answer=None):
        self.local = Path(directory)
        self.profile = None
        self.current, self.calls, self.uploads = current, [], []
        self.answer, self.alerts = answer or {"state": "published"}, []

    def alert(self, key, title, message, priority="urgent"):
        self.alerts.append((key, message, priority))
        return "dispatcher"

    def compose(self, *args, data=None):
        self.calls.append(json.loads(data)["action"])
        return json.dumps({TARGET: {"current": self.current, "kept": []}})

    def compose_stream(self, *args, source, timeout=1800):
        self.uploads.append((args, hashlib.sha256(source.read()).hexdigest()))
        return json.dumps(self.answer)


class OperatorCommandTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary.name)
        os.chmod(self.directory, 0o700)

    def tearDown(self):
        self.temporary.cleanup()

    def files(self, data, manifest):
        (self.directory / "app.apk").write_bytes(data)
        (self.directory / "app.json").write_text(json.dumps(manifest))
        return str(self.directory / "app.apk"), str(self.directory / "app.json")

    def test_checks_locally_then_streams_the_file_through_the_helper(self):
        data, manifest = package(4)
        stack = FakeStack(self.directory / "stack", current={"version_code": 3})
        result = access_operator.Operator(stack).release_publish(TARGET, *self.files(data, manifest))
        self.assertEqual({"state": "published"}, result)
        self.assertEqual(["releases"], stack.calls)
        (args, digest), = stack.uploads
        self.assertEqual(("exec", "-T", "access", "python", "-m", "access.release_publish", TARGET), args[:7])
        self.assertEqual({"target": TARGET, **manifest}, json.loads(args[7]))
        self.assertEqual(manifest["sha256"], digest)

    def test_refuses_before_any_upload(self):
        data, manifest = package(4)
        cases = {"the manifest says": (data[:-1], manifest, TARGET, None),
                 "SHA-256 differs": (data[:-1] + b"x", manifest, TARGET, None),
                 "greater than the current release's (4)": (data, manifest, TARGET, {"version_code": 4}),
                 "Unknown release target": (data, manifest, "linux-arm64", None),
                 "lacks signer_sha256": (data, {k: v for k, v in manifest.items() if k != "signer_sha256"}, TARGET, None)}
        for reason, (body, sent, target, current) in cases.items():
            with self.subTest(reason=reason):
                stack = FakeStack(self.directory / "stack", current=current)
                with self.assertRaises(RuntimeError) as caught:
                    access_operator.Operator(stack).release_publish(target, *self.files(body, sent))
                self.assertIn(reason, str(caught.exception))
                self.assertEqual([], stack.uploads)

    def test_refuses_while_a_backup_or_restore_marker_is_present(self):
        data, manifest = package(4)
        for name, what in (("backup-in-progress", "A backup is running"), ("restore-in-progress", "A restore is running")):
            with self.subTest(marker=name):
                stack = FakeStack(self.directory / "stack")
                run = stack.local / "run"
                run.mkdir(parents=True, exist_ok=True)
                (run / name).write_text(json.dumps({"deadline": "2026-11-05T03:40:00Z", "deadline_epoch": 1793850000}))
                with self.assertRaises(RuntimeError) as caught:
                    access_operator.Operator(stack).release_publish(TARGET, *self.files(data, manifest))
                self.assertIn(what, str(caught.exception))
                self.assertIn("deadline 2026-11-05T03:40:00Z", str(caught.exception))
                self.assertIn("Retry after it finishes", str(caught.exception))
                self.assertEqual([], stack.uploads)
                (run / name).unlink()
        stack = FakeStack(self.directory / "stack")
        self.assertEqual({"state": "published"}, access_operator.Operator(stack).release_publish(TARGET, *self.files(data, manifest)))

    def test_a_prune_failure_is_reported_and_alerted_but_the_publish_stands(self):
        data, manifest = package(4)
        stack = FakeStack(self.directory / "stack", answer={"state": "published", "prune": "failed"})
        with patch("sys.stderr", io.StringIO()) as stderr:
            result = access_operator.Operator(stack).release_publish(TARGET, *self.files(data, manifest))
        self.assertEqual(("published", "dispatcher"), (result["state"], result["alert"]))
        (key, message, priority), = stack.alerts
        self.assertEqual(("release-prune-failed", "default"), (key, priority))
        self.assertIn("published and served", message)
        self.assertIn("WARNING", stderr.getvalue())

    def test_cli_parses_release_publish(self):
        data, manifest = package(1)
        package_path, manifest_path = self.files(data, manifest)
        seen = {}

        class Recorder(access_operator.Operator):
            def __init__(self, stack):
                pass

            def release_publish(self, target, package, manifest):
                seen.update(target=target, package=package, manifest=manifest)
                return {"state": "published"}
        argv = ["access_operator", "release-publish", TARGET, package_path, "--manifest", manifest_path]
        with patch.object(access_operator, "Operator", Recorder), patch.object(access_operator, "stack_for", lambda *a: None), \
                patch("sys.argv", argv), patch("sys.stdout", io.StringIO()):
            self.assertEqual(0, access_operator.main())
        self.assertEqual({"target": TARGET, "package": package_path, "manifest": manifest_path}, seen)


if __name__ == "__main__":
    unittest.main()
