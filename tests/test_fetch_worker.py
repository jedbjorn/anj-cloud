"""Media fetch worker and its deployment (spec #42 F1, F3), without the worker image.

Presets, the reach precheck, the ffprobe verdict, error classification, the network guard's
ruleset, the updater's keep-the-working-copy rule, the worker's side of the spool, and the Compose
files' isolation (the production file never names a fixture host).
"""

import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "services/fetch"))

import guard  # noqa: E402
import presets  # noqa: E402
import worker  # noqa: E402


def probe(streams, name="mov,mp4,m4a,3gp,3g2,mj2"):
    return json.dumps({"format": {"format_name": name}, "streams": streams})


AAC = {"codec_type": "audio", "codec_name": "aac", "disposition": {"attached_pic": 0}}
COVER = {"codec_type": "video", "codec_name": "png", "height": 320, "disposition": {"attached_pic": 1}}


def video(codec="h264", height=1080):
    return {"codec_type": "video", "codec_name": codec, "height": height, "disposition": {"attached_pic": 0}}


class PresetTests(unittest.TestCase):
    def test_selectors_only_copy_h264_and_aac(self):
        self.assertEqual("bestaudio[acodec~='^(mp4a|aac)'][vcodec=none]/best[acodec~='^(mp4a|aac)'][vcodec~='^(avc|h264)']",
                         presets.selector("audio"))
        self.assertEqual("bestvideo[vcodec~='^(avc|h264)'][height<=720]+bestaudio[acodec~='^(mp4a|aac)']"
                         "/best[vcodec~='^(avc|h264)'][acodec~='^(mp4a|aac)'][height<=720]", presets.selector("video", 720))
        for kind in presets.PRESETS:
            args = " ".join(presets.PRESETS[kind]["args"])
            for transcode in ("--recode-video", "--postprocessor-args", "--audio-quality", "-S"):
                self.assertNotIn(transcode, args)

    def test_verdict(self):
        self.assertEqual((True, None), presets.verdict(probe([AAC, COVER]), "audio"))
        self.assertEqual((True, 720), presets.verdict(probe([video(height=720), AAC]), "video", 1080))
        self.assertEqual((False, 1080), presets.verdict(probe([video(height=1080), AAC]), "video", 720))
        for streams, kind in (([video(), AAC], "audio"), ([dict(AAC, codec_name="opus")], "audio"), ([AAC, AAC], "audio"),
                              ([video("vp9"), AAC], "video"), ([video()], "video"), ([video(), video(), AAC], "video"),
                              ([video(), AAC, {"codec_type": "subtitle", "codec_name": "mov_text"}], "video")):
            self.assertFalse(presets.verdict(probe(streams), kind, 1080)[0], (streams, kind))
        self.assertFalse(presets.verdict(probe([AAC], name="matroska,webm"), "audio")[0])
        self.assertFalse(presets.verdict(b"not json", "audio")[0])

    def test_limits_from_metadata(self):
        self.assertIsNone(presets.limits({"duration": 4 * 3600, "requested_formats": [{"filesize": 8 * 2 ** 30}]}))
        self.assertEqual("too-long", presets.limits({"duration": 4 * 3600 + 1}))
        self.assertEqual("too-large", presets.limits({"requested_formats": [{"filesize": 6 * 2 ** 30}, {"filesize_approx": 3 * 2 ** 30}]}))
        self.assertEqual("too-large", presets.limits({"duration": 3600, "requested_formats": [{"tbr": 25000}]}))
        self.assertEqual("live", presets.limits({"is_live": True}))
        self.assertIsNone(presets.limits({}))

    def test_errors_become_codes(self):
        cases = {"ERROR: [generic] x: Requested format is not available. Use --list-formats": ("unsupported-format", False),
                 "ERROR: [youtube] x: Sign in to confirm you're not a bot. Use --cookies-from-browser": ("login-required", False),
                 "ERROR: [youtube] x: Video unavailable": ("unavailable", False),
                 "ERROR: [x] The uploader has not made this video available in your country": ("geo-blocked", False),
                 "ERROR: Unsupported URL: https://a.example/": ("unsupported-link", False),
                 "ERROR: Unable to download webpage: <urlopen error [Errno -2] Name or service not known>": ("network", False),
                 "ERROR: [site] x: Unable to extract title; please report this issue": ("site-error", True),
                 "ERROR: unable to download video data: HTTP Error 403: Forbidden": ("site-error", False)}
        for text, expected in cases.items():
            self.assertEqual(expected, presets.classify("WARNING: noise\n" + text + "\n"), text)


class ReachTests(unittest.TestCase):
    def resolver(self, *addresses):
        return lambda host, port, proto=0: [(socket.AF_INET, socket.SOCK_STREAM, 6, "", (address, port)) for address in addresses]

    def test_private_and_local_addresses_are_refused(self):
        for address in ("127.0.0.1", "10.1.2.3", "172.16.5.5", "192.168.0.1", "169.254.169.254", "100.64.0.1", "224.0.0.1",
                        "0.0.0.0", "240.0.0.1", "::1", "fe80::1", "fd00::1", "::ffff:192.168.0.1", "64:ff9b::a00:1", "2002:c0a8:1::1",
                        "ff02::1"):
            self.assertEqual("private-address", presets.reach("https://media.example/x", resolve=self.resolver(address)), address)
        self.assertEqual("private-address", presets.reach("https://m.example/", resolve=self.resolver("93.184.215.14", "10.0.0.1")))
        self.assertIsNone(presets.reach("https://m.example/", resolve=self.resolver("93.184.215.14")))
        self.assertIsNone(presets.reach("http://[2606:4700::1111]/", resolve=self.resolver("2606:4700::1111")))

    def test_only_http_and_the_fixture_allowance(self):
        for link in ("ftp://a.example/", "file:///etc/passwd", "https://", "https://a.example:notaport/"):
            self.assertEqual("unsupported-link", presets.reach(link, resolve=self.resolver("93.184.215.14")))
        self.assertIsNone(presets.reach("http://fetch-fixture:8080/x", "fetch-fixture", resolve=self.resolver("172.20.0.3")))
        self.assertEqual("private-address", presets.reach("http://other:8080/x", "fetch-fixture", resolve=self.resolver("172.20.0.3")))

    def test_resolution_failure(self):
        def fail(*args, **kwargs):
            raise socket.gaierror("no")
        self.assertEqual("network", presets.reach("https://nowhere.example/", resolve=fail))


class GuardTests(unittest.TestCase):
    def test_ruleset_drops_private_ranges_with_two_exceptions(self):
        rules = guard.ruleset()
        self.assertIn("type filter hook output priority filter; policy accept;", rules)
        for network in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "127.0.0.0/8", "169.254.0.0/16", "100.64.0.0/10", "224.0.0.0/4"):
            self.assertIn(network, rules)
        for network in ("fc00::/7", "fe80::/10", "ff00::/8", "::ffff:0:0/96"):
            self.assertIn(network, rules)
        lines = [line.strip() for line in rules.splitlines()]
        accepts = [line for line in lines if line.endswith("accept") and "policy" not in line]
        self.assertEqual(['oifname "lo" accept'], accepts)
        dns = guard.ruleset(dns=["10.77.10.1"]).splitlines()
        rule = "\t\tip daddr 10.77.10.1 meta l4proto { tcp, udp } th dport 53 accept"
        self.assertLess(dns.index(rule), dns.index("\t\tip daddr @private4 drop"))

    def test_resolvers_named_by_docker(self):
        self.assertEqual([], guard.resolvers("nameserver 127.0.0.11\n# ExtServers: [host(127.0.0.53)]\n"))
        self.assertEqual(["10.77.10.1"], guard.resolvers("# ExtServers: [host(127.0.0.53) 10.77.10.1 nonsense fd00::1]\n"))
        self.assertEqual([], guard.resolvers("nameserver 10.0.0.1\n"))
        self.assertTrue(guard.ruleset().startswith("table inet anj_fetch_guard {}\ndelete table inet anj_fetch_guard\n"))

    def test_fixture_allowance_is_one_address(self):
        rules = guard.ruleset(["172.30.0.4"])
        self.assertIn("ip daddr 172.30.0.4 accept", rules)
        self.assertEqual([], guard.fixture_addresses(""))


class ToolsTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.dir = Path(self.temporary.name)
        (self.dir / "baseline").write_text("2026.10.26")
        self.now = [1_800_000_000.0]
        self.network = True

    def tearDown(self):
        self.temporary.cleanup()

    def run_tool(self, argv, **kwargs):
        """A stand-in yt-dlp: the file's text is its version; --update-to rewrites it if the network is up."""
        path = Path(argv[2])
        if "--version" in argv:
            text = path.read_text() if path.exists() else ""
            return subprocess.CompletedProcess(argv, 0 if text.count(".") == 2 else 1, text + "\n", "")
        if "--update-to" in argv:
            if not self.network:
                return subprocess.CompletedProcess(argv, 100, "", "ERROR: Unable to obtain version info")
            path.write_text("2026.11.10")
            return subprocess.CompletedProcess(argv, 0, "Updated yt-dlp to stable@2026.11.10", "")
        raise AssertionError(argv)

    def tools(self):
        return worker.Tools(self.dir / "tools", self.dir / "baseline", run=self.run_tool, clock=lambda: self.now[0])

    def test_baseline_is_the_floor(self):
        (self.dir / "tools").mkdir()
        (self.dir / "tools/yt-dlp").write_text("2025.10.22")
        self.assertEqual("2026.10.26", self.tools().install())
        (self.dir / "tools/yt-dlp").write_text("2026.11.01")
        self.assertEqual("2026.11.01", self.tools().install())

    def test_update_advances_and_a_blocked_update_keeps_the_working_copy(self):
        (self.dir / "tools").mkdir()
        (self.dir / "tools/yt-dlp").write_text("2026.10.26")
        tools = self.tools()
        self.assertTrue(tools.due())
        self.network = False
        self.assertEqual("2026.10.26", tools.update("daily"))
        self.assertEqual("2026.10.26", (self.dir / "tools/yt-dlp").read_text())
        self.assertFalse((self.dir / "tools/yt-dlp.next").exists())
        self.assertEqual("failed", json.loads((self.dir / "tools/update.json").read_text())["outcome"])
        self.assertFalse(tools.due())
        self.now[0] += 24 * 3600
        self.assertTrue(tools.due())
        self.network = True
        self.assertEqual("2026.11.10", tools.update("daily"))
        self.assertEqual("2026.11.10", (self.dir / "tools/yt-dlp").read_text())

    def test_an_update_that_does_not_run_is_not_kept(self):
        (self.dir / "tools").mkdir()
        (self.dir / "tools/yt-dlp").write_text("2026.10.26")

        def broken(argv, **kwargs):
            if "--update-to" in argv:
                Path(argv[2]).write_text("garbage")
                return subprocess.CompletedProcess(argv, 0, "", "")
            return self.run_tool(argv, **kwargs)
        tools = worker.Tools(self.dir / "tools", self.dir / "baseline", run=broken, clock=lambda: self.now[0])
        self.assertEqual("2026.10.26", tools.update("daily"))
        self.assertEqual("2026.10.26", (self.dir / "tools/yt-dlp").read_text())


class WorkerSpoolTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.spool = Path(self.temporary.name)
        (self.spool / "jobs").mkdir()
        (self.spool / "worker").mkdir()
        self.worker = worker.Worker(self.spool, tools=mock.Mock())

    def tearDown(self):
        self.temporary.cleanup()

    def request(self, name, body):
        (self.spool / "jobs" / name).mkdir()
        (self.spool / "jobs" / name / "request.json").write_text(json.dumps(body))

    def test_only_unclaimed_valid_requests_are_taken(self):
        self.request("a" * 24, {"v": 1, "url": "https://m.example/1", "kind": "video", "height": 480})
        self.request("b" * 24, {"v": 1, "url": "https://m.example/2", "kind": "audio"})
        (self.spool / "jobs" / ("b" * 24) / "status.json").write_text("{}")
        self.request("c" * 24, {"v": 1, "url": "https://m.example/3", "kind": "audio", "height": None})
        (self.spool / "jobs" / ("c" * 24) / "cancel").write_text("")
        self.request("d" * 24, {"v": 1, "url": "https://m.example/4", "kind": "video", "height": 720})
        self.request("short", {"v": 1, "url": "https://m.example/5", "kind": "audio"})
        name, _, request = self.worker.next_request()
        self.assertEqual(("d" * 24, 720), (name, request["height"]))

    def test_heartbeat_names_the_current_job(self):
        self.worker.job, self.worker.version = "d" * 24, "2026.10.26"
        self.worker.beat()
        beat = json.loads((self.spool / "worker/heartbeat.json").read_text())
        self.assertEqual({"v", "boot", "seq", "job", "version"}, set(beat))
        self.assertEqual(("d" * 24, 1, 16), (beat["job"], beat["seq"], len(beat["boot"])))

    def test_status_is_never_written_into_a_removed_run(self):
        self.request("e" * 24, {"v": 1, "url": "https://m.example/1", "kind": "audio"})
        job = worker.Job(self.worker, self.spool / "jobs" / ("e" * 24), {"url": "x", "kind": "audio"})
        job.report(state="checking")
        self.assertTrue((self.spool / "jobs" / ("e" * 24) / "status.json").exists())
        (self.spool / "jobs" / ("e" * 24) / "request.json").unlink()
        self.assertTrue(job.stopped())
        (self.spool / "jobs" / ("e" * 24) / "status.json").unlink()
        job.report(state="downloading")
        self.assertFalse((self.spool / "jobs" / ("e" * 24) / "status.json").exists())


class SpoolHandOverTests(unittest.TestCase):
    def test_root_owned_spool_goes_to_the_gateway_and_spool_group(self):
        sys.path.insert(0, str(ROOT))
        from services.access import install_tls
        with tempfile.TemporaryDirectory() as directory:
            calls = []
            with mock.patch.object(install_tls.os, "chown", side_effect=lambda path, uid, gid: calls.append(("chown", uid, gid))), \
                    mock.patch.object(install_tls.os, "chmod", side_effect=lambda path, mode: calls.append(("chmod", mode))):
                self.assertTrue(install_tls.own_spool(directory, root=os.getuid()))
                self.assertEqual([("chmod", 0o2750), ("chown", 10001, 10004)], calls)
                calls.clear()
                self.assertFalse(install_tls.own_spool(directory, root=os.getuid() + 1))
                self.assertEqual([], calls)
            with mock.patch.dict(os.environ, {"ANJ_FETCH_SPOOL": ""}):
                self.assertFalse(install_tls.own_spool())


class ComposeTests(unittest.TestCase):
    def load(self, name):
        return json.loads((ROOT / "deploy" / name).read_text())

    def test_production_names_no_fixture_host(self):
        text = (ROOT / "deploy/compose.prod.json").read_text()
        self.assertNotIn("ANJ_FETCH_FIXTURE_HOST", text)
        self.assertNotIn("fetch-fixture", text)
        self.assertNotIn("ANJ_FETCH_FIXTURE_HOST", (ROOT / "deploy/compose.json").read_text())
        fixture = self.load("compose.fetch-fixture.json")["services"]
        self.assertEqual("fetch-fixture", fixture["fetch-net"]["environment"]["ANJ_FETCH_FIXTURE_HOST"])

    def test_worker_isolation_in_every_stack(self):
        for name in ("compose.json", "compose.prod.json"):
            compose = self.load(name)
            services = compose["services"]
            worker_service, net = services["fetch"], services["fetch-net"]
            self.assertEqual("service:fetch-net", worker_service["network_mode"], name)
            self.assertEqual(["fetch"], net["networks"], name)
            self.assertNotIn("internal", compose["networks"]["fetch"], name)
            for other in ("db", "redis", "nextcloud", "cron", "access"):
                self.assertNotIn("fetch", services[other].get("networks", []), (name, other))
            self.assertEqual((["ALL"], True, ["no-new-privileges:true"]),
                             (worker_service["cap_drop"], worker_service["read_only"], worker_service["security_opt"]), name)
            self.assertNotIn("cap_add", worker_service)
            self.assertNotIn("user", worker_service)  # the image's uid 10003
            self.assertEqual((["ALL"], ["NET_ADMIN"]), (net["cap_drop"], net["cap_add"]), name)
            self.assertEqual(("512m", 1, 128), (worker_service["mem_limit"], worker_service["cpus"], worker_service["pids_limit"]))
            self.assertEqual(["fetch-spool:/spool", "fetch-tools:/var/lib/anj-fetch-tools"], worker_service["volumes"])
            self.assertIn("fetch-spool:/var/lib/anj-fetch", services["access"]["volumes"])
            self.assertEqual("/var/lib/anj-fetch", services["access"]["environment"]["ANJ_FETCH_SPOOL"])
            self.assertEqual("8590983168", services["nextcloud"]["environment"]["APACHE_BODY_LIMIT"])
        prod = self.load("compose.prod.json")
        self.assertEqual("anj-fetch", prod["networks"]["fetch"]["driver_opts"]["com.docker.network.bridge.name"])
        self.assertEqual("10002,10004", prod["services"]["access"]["environment"]["ANJ_RUN_GROUPS"])
        self.assertEqual("67108864", prod["services"]["access"]["environment"]["ANJ_MAX_TRANSFER_BYTES"])  # client limit unchanged

    def test_backups_exclude_the_fetch_volumes(self):
        text = (ROOT / "deploy/backup.py").read_text()
        for line in text.splitlines():
            if line.startswith(("RESTORED_VOLUMES", "REPLACED_VOLUMES")):
                self.assertNotIn("fetch", line)

    def test_worker_image_pins(self):
        dockerfile = (ROOT / "services/fetch/Dockerfile").read_text()
        for line in dockerfile.splitlines():
            if line.startswith("FROM "):
                self.assertRegex(line, r"@sha256:[0-9a-f]{64}")
        self.assertRegex(dockerfile, r"YTDLP_SHA256=[0-9a-f]{64}")
        self.assertIn("USER 10003:10004", dockerfile)


if __name__ == "__main__":
    unittest.main()
