"""Spec #23 DDNS updater against a fake Cloudflare API and fake address endpoints (never the network)."""

import contextlib
import io
import json
from pathlib import Path
import shutil
import socket
import stat
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import unittest
from types import SimpleNamespace
from unittest.mock import patch
import urllib.parse

from deploy import ddns

TOKEN = "cf-test-SECRET-token-0123456789abcdefABCDEF"
ZONE = "1b2c3d4e5f60718293a4b5c6d7e8f901"   # a made-up zone id
RECORD = "0123456789abcdef0123456789abcdef"
OTHER = "fedcba9876543210fedcba9876543210"
NAME = "gateway.example.com"


class FakeWorld:
    """Fake Cloudflare v4 API plus two address endpoints, served over local HTTP."""

    def __init__(self):
        self.records = {
            RECORD: {"id": RECORD, "type": "A", "name": NAME, "content": "5.6.7.7", "proxied": False, "ttl": 300},
            OTHER: {"id": OTHER, "type": "TXT", "name": "example.com", "content": "keep me", "proxied": False, "ttl": 1},
        }
        self.addresses = ["5.6.7.20", "5.6.7.20"]
        self.address_status = [200, 200]
        self.fail = {}  # method -> (status, payload)
        self.redirect = False
        self.requests = []
        world = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def _send(self, status, body, kind="application/json"):
                data = body if isinstance(body, bytes) else json.dumps(body).encode()
                self.send_response(status)
                self.send_header("Content-Type", kind)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def _handle(self):
                length = int(self.headers.get("Content-Length") or 0)
                body = json.loads(self.rfile.read(length)) if length else None
                url = urllib.parse.urlsplit(self.path)
                world.requests.append({"method": self.command, "path": url.path, "query": urllib.parse.parse_qs(url.query),
                                       "auth": self.headers.get("Authorization"), "body": body})
                if url.path == "/ip/garbage":  # a broken HTTP status line
                    self.wfile.write(b"NOT-HTTP garbage\r\n\r\n")
                    return None
                if url.path == "/redirected":
                    return self._send(200, {"success": True, "result": []})
                if world.redirect and url.path.startswith("/client"):
                    self.send_response(302)
                    self.send_header("Location", world.base + "/redirected")
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return None
                if url.path in ("/ip/a", "/ip/b"):
                    index = 0 if url.path.endswith("a") else 1
                    return self._send(world.address_status[index], world.addresses[index].encode(), "text/plain")
                if self.headers.get("Authorization") != "Bearer " + TOKEN:
                    return self._send(403, {"success": False, "errors": [{"code": 9109}]})
                if self.command in world.fail:
                    status, payload = world.fail[self.command]
                    return self._send(status, payload)
                prefix = f"/client/v4/zones/{ZONE}/dns_records"
                if self.command == "GET" and url.path == prefix:
                    query = urllib.parse.parse_qs(url.query)
                    found = [r for r in world.records.values()
                             if r["type"] == query.get("type", [None])[0] and r["name"] == query.get("name.exact", [None])[0]]
                    return self._send(200, {"success": True, "errors": [], "result": found})
                if self.command == "PATCH" and url.path.startswith(prefix + "/"):
                    record = world.records.get(url.path.rsplit("/", 1)[1])
                    if record is None:
                        return self._send(404, {"success": False, "errors": [{"code": 81044}]})
                    record.update(body)
                    return self._send(200, {"success": True, "errors": [], "result": record})
                return self._send(405, {"success": False, "errors": [{"code": 10000}]})

            do_GET = do_PATCH = do_POST = do_PUT = do_DELETE = _handle

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.base = f"http://127.0.0.1:{self.server.server_address[1]}"
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()

    def methods(self):
        return [r["method"] for r in self.requests if r["path"].startswith("/client")]


class StubHaproxy:
    """HAProxy's admin socket for one file-backed ACL: show/prepare/add/commit/clear acl.
    `atomic=False` behaves like an older HAProxy without prepare/commit."""

    def __init__(self, path, acl, atomic=True):
        self.path, self.acl, self.atomic = str(path), str(acl), atomic
        self.entries, self.pending, self.commands = [], {}, []
        self.refuse_add = False
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.bind(self.path)
        self.listener.listen(16)
        self.running = True
        threading.Thread(target=self.serve, daemon=True).start()

    def answer(self, command):
        words = command.split()
        self.commands.append(command)
        if words[:2] == ["show", "acl"]:
            if words[2] != self.acl:
                return "Unknown ACL identifier. Please use #<id> or <file>.\n"
            return "".join(f"0x{index:x} {entry}\n" for index, entry in enumerate(self.entries)) + "\n"
        if words[:2] == ["prepare", "acl"] and self.atomic:
            version = str(len(self.pending) + 2)
            self.pending[version] = []
            return f"New version created: {version}\n"
        if words[:2] == ["add", "acl"]:
            if self.refuse_add:
                return "'add acl' expects two parameters\n"
            if words[2].startswith("@"):
                self.pending[words[2][1:]].append(words[4])
            else:
                self.entries.append(words[3])
            return "\n"
        if words[:2] == ["commit", "acl"]:
            self.entries = self.pending.pop(words[2][1:])
            return "\n"
        if words[:2] == ["clear", "acl"]:
            self.entries = []
            return "\n"
        return "Unknown command\n"

    def serve(self):
        while self.running:
            try:
                connection, _ = self.listener.accept()
            except OSError:
                return
            with connection:
                data = b""
                while not data.endswith(b"\n"):
                    chunk = connection.recv(4096)
                    if not chunk:
                        break
                    data += chunk
                connection.sendall(self.answer(data.decode().strip()).encode())

    def mutations(self):
        return [c for c in self.commands if not c.startswith("show")]

    def close(self):
        self.running = False
        self.listener.close()


class DdnsCase(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="anj-ddns-")
        self.root = Path(self.temporary.name)
        self.token = self.root / "secrets" / "cloudflare-dns-token"
        self.token.parent.mkdir(mode=0o700)
        self.token.write_text(TOKEN + "\n")
        self.token.chmod(0o600)
        self.household_dir = self.root / "vm-state" / "haproxy"
        self.household_dir.mkdir(parents=True)
        self.household = self.household_dir / "household.acl"
        self.flag = self.root / "vm-state" / "run" / "emergency-stop"
        self.haproxy = StubHaproxy(self.root / "admin.sock", self.household)
        self.alerts = self.root / "alerts.log"
        self.alert_command = self.root / "anj-alert"
        self.alert_command.write_text(
            "#!/bin/sh\n"  # anj-alert contract: --key K [--every S] [--title T] [--priority P] -- MESSAGE
            f"printf '%s\\n' \"$*\" >> '{self.alerts}.argv'\n"
            "case \" $* \" in *\" -- \"*) ;; *) exit 64;; esac\n"
            "[ \"$1\" = --key ] || exit 64\n"
            "for a; do last=$a; done\n"
            f"printf '%s\\n' \"$last\" >> '{self.alerts}'\n")
        self.alert_command.chmod(0o700)
        self.world = FakeWorld()
        self.now = 1_000_000.0
        self.uptime = 86400.0  # well past boot unless a test says otherwise
        self.sleeps, self.systemctl = [], []
        self.network_online = True
        self.output = io.StringIO()

    def tearDown(self):
        self.world.close()
        self.haproxy.close()
        self.temporary.cleanup()

    def updater(self, **overrides):
        options = dict(name=NAME, zone_id=ZONE, token_file=self.token, household_acl=self.household,
                       admin=ddns.HaproxyAdmin(socket_path=self.haproxy.path, acl=self.household),
                       emergency_flag=self.flag,
                       state=self.root / "state" / "ddns-state.json", alert_command=str(self.alert_command),
                       endpoints=(self.world.base + "/ip/a", self.world.base + "/ip/b"),
                       api=self.world.base + "/client/v4", clock=lambda: self.now,
                       uptime=lambda: self.uptime, sleep=self.fake_sleep, runner=self.fake_systemctl)
        options.update(overrides)
        return ddns.Updater(**options)

    def fake_sleep(self, seconds):
        self.sleeps.append(seconds)
        self.uptime += seconds

    def fake_systemctl(self, argv, **kwargs):
        self.systemctl.append(argv)
        return SimpleNamespace(returncode=0 if self.network_online else 3)

    def cycle(self, **overrides):
        with contextlib.redirect_stdout(self.output), contextlib.redirect_stderr(self.output):
            return self.updater(**overrides).cycle()

    def alerts_sent(self):
        return self.alerts.read_text().splitlines() if self.alerts.exists() else []

    def assert_untouched(self, content="5.6.7.7"):
        self.assertNotIn("PATCH", self.world.methods())
        self.assertEqual(self.world.records[RECORD]["content"], content)
        self.assertIs(self.world.records[RECORD]["proxied"], False)
        self.assertEqual(self.world.records[OTHER]["content"], "keep me")

    def assert_no_create_or_delete(self):
        self.assertTrue(set(self.world.methods()) <= {"GET", "PATCH"}, self.world.methods())
        self.assertEqual(set(self.world.records), {RECORD, OTHER})


class UpdatePath(DdnsCase):
    def test_changed_address_patches_only_content_and_proxied_of_the_exact_record(self):
        outcome = self.cycle()
        self.assertEqual(outcome["outcome"], "updated")
        self.assertEqual((outcome["old"], outcome["new"]), ("5.6.7.7", "5.6.7.20"))
        cloud = [r for r in self.world.requests if r["path"].startswith("/client")]
        self.assertEqual([r["method"] for r in cloud], ["GET", "PATCH"])
        self.assertEqual(cloud[0]["query"]["type"], ["A"])
        self.assertEqual(cloud[0]["query"]["name.exact"], [NAME])
        self.assertTrue(cloud[1]["path"].endswith(f"/zones/{ZONE}/dns_records/{RECORD}"))
        self.assertEqual(cloud[1]["body"], {"content": "5.6.7.20", "proxied": False})
        self.assertEqual(self.world.records[RECORD]["ttl"], 300)
        self.assertEqual(self.world.records[OTHER]["content"], "keep me")
        self.assert_no_create_or_delete()
        self.assertEqual(self.household.read_text(), "5.6.7.20\n")
        self.assertEqual(stat.S_IMODE(self.household.stat().st_mode), 0o644)
        line = json.loads(self.output.getvalue().splitlines()[-1])
        self.assertEqual((line["event"], line["old"], line["new"]), ("ddns", "5.6.7.7", "5.6.7.20"))

    def test_unchanged_record_makes_no_patch_and_household_file_is_written_only_when_missing_or_changed(self):
        self.world.records[RECORD]["content"] = "5.6.7.20"
        self.assertEqual(self.cycle()["household_file"], "written")
        before = self.household.stat()
        outcome = self.cycle()
        self.assertEqual((outcome["outcome"], outcome["household_file"]), ("unchanged", "current"))
        self.assertNotIn("PATCH", self.world.methods())
        after = self.household.stat()
        self.assertEqual((before.st_ino, before.st_mtime_ns), (after.st_ino, after.st_mtime_ns))
        self.household.write_text("5.6.7.1\n")
        self.assertEqual(self.cycle()["household_file"], "written")
        self.assertEqual(self.household.read_text(), "5.6.7.20\n")
        self.assertEqual(list(self.household_dir.iterdir()), [self.household])  # no temporary left

    def test_proxied_record_is_forced_back_to_dns_only(self):
        self.world.records[RECORD].update(content="5.6.7.20", proxied=True)
        outcome = self.cycle()
        self.assertEqual((outcome["outcome"], outcome["proxied_was"]), ("updated", True))
        self.assertIs(self.world.records[RECORD]["proxied"], False)
        self.assert_no_create_or_delete()


class NoChange(DdnsCase):
    def assert_failed_without_cloudflare(self, outcome):
        self.assertEqual(outcome["outcome"], "failed")
        self.assertEqual(self.world.methods(), [])
        self.assert_untouched()
        self.assertFalse(self.household.exists())

    def test_endpoint_disagreement_changes_nothing(self):
        self.world.addresses = ["5.6.7.20", "5.6.7.21"]
        outcome = self.cycle()
        self.assert_failed_without_cloudflare(outcome)
        self.assertIn("disagree", outcome["reason"])

    def test_non_public_addresses_change_nothing(self):
        for address in ("192.168.0.10", "10.1.2.3", "172.16.0.1", "100.64.0.1", "100.127.255.254", "127.0.0.1",
                        "169.254.1.1", "224.0.0.1", "240.0.0.1", "0.0.0.0", "255.255.255.255", "2001:db8::1",
                        "not-an-ip", ""):
            with self.subTest(address=address):
                self.world.addresses = [address, address]
                self.assert_failed_without_cloudflare(self.cycle())

    def test_endpoint_http_error_or_unreachable_changes_nothing(self):
        self.world.address_status = [200, 503]
        self.assert_failed_without_cloudflare(self.cycle())
        outcome = self.cycle(endpoints=(self.world.base + "/ip/a", "http://127.0.0.1:9/unreachable"))
        self.assert_failed_without_cloudflare(outcome)

    def test_api_errors_and_unexpected_record_sets_change_nothing(self):
        cases = {
            "get 500": lambda: self.world.fail.__setitem__("GET", (500, {"success": False, "errors": [{"code": 1}]})),
            "get unsuccessful": lambda: self.world.fail.__setitem__("GET", (200, {"success": False, "errors": []})),
            "get not json": lambda: self.world.fail.__setitem__("GET", (200, "oops")),
            "missing record": lambda: self.world.records.pop(RECORD),
            "duplicate record": lambda: self.world.records.__setitem__(
                "a" * 32, dict(self.world.records[RECORD], id="a" * 32, content="5.6.7.8")),
        }
        for label, arrange in cases.items():
            with self.subTest(label):
                self.world.close()
                self.world = FakeWorld()
                arrange()
                outcome = self.cycle()
                self.assertEqual(outcome["outcome"], "failed")
                self.assertEqual(set(self.world.methods()), {"GET"})
                self.assertFalse(self.household.exists())

    def test_patch_rejected_or_unconfirmed_is_a_failure_and_never_retried_as_create(self):
        self.world.fail["PATCH"] = (403, {"success": False, "errors": [{"code": 10000}]})
        outcome = self.cycle()
        self.assertEqual(outcome["outcome"], "failed")
        self.assertEqual(self.world.methods(), ["GET", "PATCH"])
        self.assertEqual(self.world.records[RECORD]["content"], "5.6.7.7")
        self.assert_no_create_or_delete()
        self.assertFalse(self.household.exists())

    def test_wrong_token_is_refused_by_api_and_changes_nothing(self):
        self.token.write_text("another-token\n")
        outcome = self.cycle()
        self.assertEqual(outcome["outcome"], "failed")
        self.assert_untouched()

    def test_missing_household_directory_is_a_failure(self):
        shutil.rmtree(self.household_dir)
        self.world.records[RECORD]["content"] = "5.6.7.20"
        outcome = self.cycle()
        self.assertEqual(outcome["outcome"], "failed")
        self.assertIn("household ACL directory", outcome["reason"])
        self.assertFalse(self.household_dir.exists())

    def test_token_file_must_be_private_regular_file(self):
        self.token.chmod(0o640)
        self.assertEqual(self.cycle()["outcome"], "failed")
        self.assertEqual(self.world.requests, [])
        self.token.chmod(0o600)
        link = self.root / "link-token"
        link.symlink_to(self.token)
        self.assertEqual(self.cycle(token_file=link)["outcome"], "failed")
        self.assertEqual(self.world.requests, [])

    def test_concurrent_cycle_is_skipped(self):
        updater = self.updater()
        with updater.state.locked():
            with contextlib.redirect_stdout(self.output):
                self.assertEqual(self.updater().cycle()["outcome"], "skipped")
        self.assertEqual(self.world.requests, [])


class Alerts(DdnsCase):
    def test_alert_on_third_consecutive_failure_then_hourly_and_reset_on_success(self):
        self.world.addresses = ["5.6.7.20", "5.6.7.21"]
        for expected in (0, 0, 1, 1, 1):
            outcome = self.cycle()
            self.assertEqual(len(self.alerts_sent()), expected)
            self.now += 300
        self.assertEqual(outcome["consecutive_failures"], 5)
        self.now += 3600
        self.cycle()
        self.assertEqual(len(self.alerts_sent()), 2)
        self.assertIn("consecutive failures", self.alerts_sent()[0])
        self.world.addresses = ["5.6.7.20", "5.6.7.20"]
        self.assertEqual(self.cycle()["recovered_after"], 6)
        self.world.addresses = ["5.6.7.20", "5.6.7.21"]
        self.cycle(), self.cycle()
        self.assertEqual(len(self.alerts_sent()), 2)  # counter reset: two new failures, no alert
        self.cycle()
        self.assertEqual(len(self.alerts_sent()), 3)

    def test_undeliverable_or_absent_dispatcher_still_logs_the_alert(self):
        self.world.addresses = ["10.0.0.1", "10.0.0.1"]
        for _ in range(3):
            outcome = self.cycle(alert_command=None)
        self.assertEqual(outcome["alert"], "not-delivered")
        alert = [json.loads(line) for line in self.output.getvalue().splitlines() if '"ddns-alert"' in line]
        self.assertEqual(len(alert), 1)
        self.assertEqual(alert[0]["consecutive_failures"], 3)

    def test_state_file_is_private(self):
        self.cycle()
        state = self.root / "state" / "ddns-state.json"
        self.assertEqual(stat.S_IMODE(state.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(state.parent.stat().st_mode), 0o700)


class TokenNeverPrinted(DdnsCase):
    def test_token_absent_from_output_logs_alerts_and_errors_in_every_path(self):
        echo = {"success": False, "errors": [{"code": 6003, "message": "bad header Bearer " + TOKEN}]}
        scenarios = [
            lambda: None,
            lambda: self.world.fail.__setitem__("GET", (400, echo)),
            lambda: self.world.fail.__setitem__("PATCH", (400, echo)),
            lambda: setattr(self.world, "addresses", ["10.0.0.1", "10.0.0.1"]),
        ]
        for arrange in scenarios:
            arrange()
            for _ in range(3):
                self.cycle()
        # An exception message that embeds the token is redacted too.
        with patch.object(ddns, "discover", side_effect=ddns.Failure("boom " + TOKEN)):
            outcome = self.cycle()
        self.assertIn("[token]", outcome["reason"])
        text = self.output.getvalue() + "".join(self.alerts_sent())
        text += (self.root / "state" / "ddns-state.json").read_text()
        self.assertNotIn(TOKEN, text)
        self.assertNotIn(TOKEN[:16], text)
        self.assertTrue(self.alerts_sent())

    def test_check_is_read_only_and_reports_shape_without_token(self):
        stdout = io.StringIO()
        with contextlib.redirect_stdout(stdout):
            result = self.updater().check()
        self.assertEqual(result, {"name": NAME, "type": "A", "proxied": False, "dns_only": True, "ttl": 300,
                                  "content_is_public_ipv4": True})
        self.assertEqual(self.world.methods(), ["GET"])
        self.assertNotIn(TOKEN, stdout.getvalue() + json.dumps(result))

    def test_cli_failure_output_has_no_token(self):
        result = subprocess.run(
            ["python3", "-I", str(Path(ddns.__file__)), "--name", NAME, "--token-file", str(self.token),
             "--state-file", str(self.root / "s.json"), "--household-acl", str(self.household), "--zone-id", "bad"],
            capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 1)
        self.assertNotIn(TOKEN, result.stdout + result.stderr)


class EveryFailureCounts(DdnsCase):
    """Review PR #35 finding 1: any exception in a cycle is counted, persisted and alerted on."""

    def state(self):
        return json.loads((self.root / "state" / "ddns-state.json").read_text())

    def test_unwritable_household_directory_counts_and_alerts(self):
        self.household_dir.chmod(0o500)
        try:
            for expected in (1, 2, 3):
                outcome = self.cycle()
                self.assertEqual((outcome["outcome"], outcome["category"]), ("failed", "household-write"))
                self.assertEqual(self.state()["failures"], expected)
        finally:
            self.household_dir.chmod(0o755)
        self.assertEqual(len(self.alerts_sent()), 1)
        self.assertEqual(outcome["alert"], "sent")
        self.assertNotIn(str(self.household_dir), self.output.getvalue() + "".join(self.alerts_sent()))

    def test_broken_status_line_from_an_endpoint_counts_and_alerts(self):
        endpoints = (self.world.base + "/ip/a", self.world.base + "/ip/garbage")
        for expected in (1, 2, 3):
            outcome = self.cycle(endpoints=endpoints)
            self.assertEqual(outcome["outcome"], "failed")
            self.assertEqual(self.state()["failures"], expected)
        self.assertEqual(len(self.alerts_sent()), 1)
        self.assertEqual(self.world.methods(), [])

    def test_unexpected_exception_counts_and_is_logged_by_type_only(self):
        with patch.object(ddns, "discover", side_effect=RuntimeError("detail /secret/path")):
            outcome = self.cycle()
        self.assertEqual((outcome["outcome"], outcome["category"], outcome["reason"]), ("failed", "internal", "RuntimeError"))
        self.assertEqual(self.state()["failures"], 1)
        self.assertNotIn("/secret/path", self.output.getvalue())

    def test_unsavable_state_is_a_failure_not_a_traceback(self):
        state_dir = self.root / "state"
        state_dir.mkdir(mode=0o500)
        try:
            outcome = self.cycle()
        finally:
            state_dir.chmod(0o700)
        self.assertEqual(outcome["outcome"], "failed")

    def test_cli_exits_non_zero_on_failure_and_zero_on_tolerated_boot(self):
        argv = ["--name", NAME, "--token-file", str(self.token), "--state-file", str(self.root / "s.json")]
        for outcome, code in (("failed", 1), ("skipped", 1), ("updated", 0), ("unchanged", 0), ("boot-no-network", 0)):
            with self.subTest(outcome), patch.object(ddns.Updater, "cycle", return_value={"outcome": outcome}):
                self.assertEqual(ddns.main(argv), code)


class AlertContent(DdnsCase):
    def test_alerts_carry_only_a_category(self):
        scenarios = {
            "address-disagree": lambda: setattr(self.world, "addresses", ["5.6.7.20", "5.6.7.21"]),
            "address-not-public": lambda: setattr(self.world, "addresses", ["10.0.0.1", "10.0.0.1"]),
            "dns-api": lambda: self.world.fail.__setitem__("GET", (400, {"success": False, "errors": [{"code": 6003}]})),
            "token": lambda: self.token.chmod(0o644),
        }
        for category, arrange in scenarios.items():
            with self.subTest(category):
                self.world.close()
                self.world = FakeWorld()
                self.token.chmod(0o600)
                (self.root / "state" / "ddns-state.json").unlink(missing_ok=True)
                self.alerts.unlink(missing_ok=True)
                arrange()
                for _ in range(3):
                    self.cycle()
                [message] = self.alerts_sent()
                self.assertEqual(message, f"anj-cloud DDNS: 3 consecutive failures ({category}); DNS unchanged.")
                self.assertNotIn("/", message)
                self.assertNotIn("6003", message)

    def test_undelivered_alert_is_retried_next_cycle(self):
        self.world.addresses = ["10.0.0.1", "10.0.0.1"]
        failing = self.root / "failing-alert"
        failing.write_text("#!/bin/sh\nexit 1\n")
        failing.chmod(0o700)
        for _ in range(3):
            outcome = self.cycle(alert_command=str(failing))
        self.assertEqual(outcome["alert"], "not-delivered")
        self.now += 300
        outcome = self.cycle()
        self.assertEqual(outcome["alert"], "sent")
        self.now += 300
        self.assertNotIn("alert", self.cycle())


class Redirects(DdnsCase):
    def test_cloudflare_redirect_is_refused_and_the_token_never_follows(self):
        self.world.redirect = True
        updater = self.updater()
        updater.http = ddns.Http()  # the production opener
        with contextlib.redirect_stdout(self.output):
            outcome = updater.cycle()
        self.assertEqual((outcome["outcome"], outcome["category"]), ("failed", "dns-api"))
        self.assertNotIn("/redirected", [r["path"] for r in self.world.requests])
        self.assert_untouched()


class BootNetwork(DdnsCase):
    def test_waits_for_network_online_and_does_not_count_no_network_at_boot(self):
        self.uptime = 50.0
        self.network_online = False
        down = (self.world.base + "/ip/a", "http://127.0.0.1:9/unreachable")
        outcome = self.cycle(endpoints=down)
        self.assertEqual(outcome["outcome"], "boot-no-network")
        self.assertEqual(outcome["consecutive_failures"], 0)
        self.assertTrue(self.systemctl)
        self.assertEqual(self.systemctl[0], ["systemctl", "--system", "is-active", "--quiet", "network-online.target"])
        self.assertLessEqual(sum(self.sleeps), ddns.NETWORK_WAIT_SECONDS + ddns.BOOT_RETRY_LIMIT + ddns.BOOT_RETRY_SECONDS)
        self.assertEqual(self.alerts_sent(), [])
        self.uptime = 1000.0
        self.assertEqual(self.cycle(endpoints=down)["consecutive_failures"], 1)  # after boot it counts

    def test_network_coming_up_during_the_boot_retry_succeeds(self):
        self.uptime = 50.0
        calls = []
        real = ddns.discover

        def flaky(http, endpoints):
            calls.append(1)
            if len(calls) < 3:
                raise ddns.Failure("no route", "network")
            return real(http, endpoints)

        with patch.object(ddns, "discover", side_effect=flaky):
            outcome = self.cycle()
        self.assertEqual(outcome["outcome"], "updated")
        self.assertEqual(len(calls), 3)

    def test_non_network_failures_at_boot_still_count(self):
        self.uptime = 50.0
        self.world.addresses = ["5.6.7.20", "5.6.7.21"]
        self.assertEqual(self.cycle()["consecutive_failures"], 1)


class Validation(unittest.TestCase):
    def test_public_ipv4(self):
        self.assertIsNone(ddns.public_ipv4("203.0.113.9"))  # TEST-NET-3 is documentation: not global
        self.assertEqual(ddns.public_ipv4(" 5.6.7.20\n"), "5.6.7.20")
        self.assertEqual(ddns.public_ipv4("5.6.7.20"), "5.6.7.20")
        for value in ("100.64.0.1", "192.168.0.1", "8.8.8.8.8", "1.1.1.1/32", "::1"):
            self.assertIsNone(ddns.public_ipv4(value))

    def test_rejects_bad_name_or_zone(self):
        for name, zone in (("Gateway.example.com", ZONE), ("family", ZONE), (NAME, "zone"), (NAME, ZONE.upper())):
            with self.assertRaises(ddns.Failure):
                ddns.Updater(name=name, zone_id=zone, token_file="/nonexistent")

    def test_recorded_host_comes_from_prod_setup(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory, "stack.json")
            self.assertIsNone(ddns.recorded_host(config))
            config.write_text(json.dumps({"host": NAME}))
            self.assertEqual(ddns.recorded_host(config), NAME)


class HouseholdAcl(DdnsCase):
    """Spec #23 Household address, unit part: ACL file and runtime commands against a stub socket."""

    def test_new_address_writes_the_file_and_replaces_the_runtime_entry_atomically(self):
        self.haproxy.entries = ["5.6.7.7"]
        outcome = self.cycle()
        self.assertEqual((outcome["household_file"], outcome["household_runtime"]), ("written", "applied"))
        self.assertEqual(self.household.read_text(), "5.6.7.20\n")
        self.assertEqual(stat.S_IMODE(self.household.stat().st_mode), 0o644)
        self.assertEqual(sorted(p.name for p in self.household_dir.iterdir()), ["household.acl"])  # rename, no temp left
        self.assertEqual(self.haproxy.entries, ["5.6.7.20"])
        acl = str(self.household)
        self.assertEqual(self.haproxy.mutations(), [f"prepare acl {acl}", f"add acl @2 {acl} 5.6.7.20", f"commit acl @2 {acl}"])
        self.assertFalse(any("reload" in c for c in self.haproxy.commands))

    def test_older_haproxy_gets_clear_then_add(self):
        self.haproxy.close()
        self.haproxy = StubHaproxy(self.root / "admin2.sock", self.household, atomic=False)
        self.haproxy.entries = ["5.6.7.7"]
        outcome = self.cycle()
        self.assertEqual(outcome["household_runtime"], "applied")
        acl = str(self.household)
        self.assertEqual(self.haproxy.mutations(), [f"prepare acl {acl}", f"clear acl {acl}", f"add acl {acl} 5.6.7.20"])
        self.assertEqual(self.haproxy.entries, ["5.6.7.20"])

    def test_current_file_and_runtime_send_no_mutation(self):
        self.world.records[RECORD]["content"] = "5.6.7.20"
        self.cycle()
        self.haproxy.commands.clear()
        outcome = self.cycle()
        self.assertEqual((outcome["household_file"], outcome["household_runtime"]), ("current", "current"))
        self.assertEqual(self.haproxy.mutations(), [])

    def test_runtime_lost_after_a_haproxy_restart_is_reapplied_from_the_next_cycle(self):
        self.cycle()
        self.haproxy.entries = []  # a restarted HAProxy without the file mount would look like this
        outcome = self.cycle()
        self.assertEqual((outcome["household_file"], outcome["household_runtime"]), ("current", "applied"))
        self.assertEqual(self.haproxy.entries, ["5.6.7.20"])

    def test_invalid_address_leaves_the_acl_unchanged_and_alerts_at_once(self):
        self.household.write_text("5.6.7.7\n")
        self.haproxy.entries = ["5.6.7.7"]
        for address in ("192.168.0.10", "100.64.1.1", "5.6.7.20\nadd acl x", "5.6.7.020", "1.2.3", ""):
            with self.subTest(address=address):
                with self.assertRaises(ddns.Failure) as caught:
                    ddns.apply_household(address, acl_file=self.household,
                                         admin=ddns.HaproxyAdmin(self.haproxy.path, self.household), emergency_flag=self.flag)
                self.assertEqual(caught.exception.category, "household-invalid")
        self.assertEqual(self.household.read_text(), "5.6.7.7\n")
        self.assertEqual(self.haproxy.commands, [])
        with patch.object(ddns, "discover", return_value="10.0.0.1"):
            outcome = self.cycle()
        self.assertEqual((outcome["category"], outcome["consecutive_failures"], outcome["alert"]),
                         ("household-invalid", 1, "sent"))
        self.assertEqual(self.alerts_sent(), ["anj-cloud DDNS: 1 consecutive failures (household-invalid); DNS unchanged."])
        self.assertEqual(self.haproxy.entries, ["5.6.7.7"])

    def test_haproxy_refusal_or_missing_socket_is_a_counted_failure(self):
        self.haproxy.refuse_add = True
        outcome = self.cycle()
        self.assertEqual((outcome["outcome"], outcome["category"]), ("failed", "household-apply"))
        self.haproxy.close()
        Path(self.haproxy.path).unlink()
        outcome = self.cycle()
        self.assertEqual((outcome["outcome"], outcome["category"]), ("failed", "household-apply"))
        self.assertEqual(outcome["consecutive_failures"], 2)
        self.assertNotIn(self.haproxy.path, outcome["reason"])

    def test_unknown_acl_reference_is_a_failure(self):
        outcome = self.cycle(admin=ddns.HaproxyAdmin(self.haproxy.path, self.root / "other.acl"))
        self.assertEqual(outcome["category"], "household-apply")

    def test_emergency_stop_writes_the_file_but_skips_the_stopped_haproxy(self):
        self.flag.parent.mkdir(parents=True)
        self.flag.write_text("stopped\n")
        self.haproxy.close()
        Path(self.haproxy.path).unlink()
        outcome = self.cycle()
        self.assertEqual(outcome["outcome"], "updated")
        self.assertIn("emergency stop", outcome["household_runtime"])
        self.assertEqual(self.household.read_text(), "5.6.7.20\n")

    def test_success_records_last_success_for_the_watchdog(self):
        self.cycle()
        state = json.loads((self.root / "state" / "ddns-state.json").read_text())
        self.assertEqual(state["last_success"], self.now)


class AlertContract(DdnsCase):
    """D's single alert adapter speaks spec #21's anj-alert CLI (paths.ALERT_COMMAND)."""

    def test_argv_follows_the_dispatcher_contract(self):
        from deploy.vm import paths
        self.assertEqual(ddns.alert_argv("m", key="ddns"), [str(paths.ALERT_COMMAND), "--key", "ddns", "--", "m"])
        self.assertEqual(ddns.alert_argv("-m starts with a dash", key="k", command="/x/anj-alert", every=3600,
                                         title="T", priority="high"),
                         ["/x/anj-alert", "--key", "k", "--every", "3600", "--title", "T", "--priority", "high",
                          "--", "-m starts with a dash"])
        self.assertEqual(ddns.Updater(name=NAME, zone_id=ZONE).alert_command, paths.ALERT_COMMAND)

    def test_third_failure_calls_anj_alert_with_key_ddns(self):
        self.world.addresses = ["10.0.0.1", "10.0.0.1"]
        for _ in range(3):
            self.cycle()
        [argv] = Path(str(self.alerts) + ".argv").read_text().splitlines()
        self.assertEqual(argv, "--key ddns --every 0 --title anj-cloud DDNS -- "
                               "anj-cloud DDNS: 3 consecutive failures (address-not-public); DNS unchanged.")

    def test_every_ddns_alert_disables_the_dispatcher_throttle_with_every_0(self):
        calls = []

        def runner(argv, **kwargs):
            calls.append((argv, kwargs))
            return subprocess.CompletedProcess(argv, 0)
        with patch.object(ddns.subprocess, "run", side_effect=runner):
            self.world.addresses = ["10.0.0.1", "10.0.0.1"]
            for _ in range(3):
                self.cycle()  # address-not-public: alert on the 3rd
            self.now += 3600
            with patch.object(ddns, "discover", return_value="10.0.0.1"):
                self.cycle()  # a different condition within the next hour still reaches the dispatcher
        alert_calls = [argv for argv, _ in calls if argv[0] == str(self.alert_command)]
        self.assertEqual(len(alert_calls), 2)
        for argv in alert_calls:
            index = argv.index("--every")
            self.assertEqual(argv[index + 1], "0")
            self.assertLess(index, argv.index("--"))
            self.assertEqual(argv[1:3], ["--key", "ddns"])
        self.assertTrue(all(kwargs.get("stdin") is subprocess.DEVNULL for argv, kwargs in calls
                            if argv[0] == str(self.alert_command)))

    def test_no_parallel_alert_path(self):
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
            ddns.main(["--alert-command", "/x", "run"])
        [app] = ddns.pm2_apps("/s", {"ddns": "on"})
        self.assertNotIn("env", app)
        self.assertNotIn("ANJ_ALERT_COMMAND", Path(ddns.__file__).read_text())


class Pm2App(unittest.TestCase):
    def test_entry_runs_every_five_minutes_without_autorestart(self):
        [app] = ddns.pm2_apps("/srv/anj-cloud/release/source", {"ddns": "on"})
        self.assertEqual(app["name"], "ddns")
        self.assertIs(app["autorestart"], False)
        self.assertEqual(app["cron_restart"], "*/5 * * * *")
        self.assertEqual(app["script"], "/srv/anj-cloud/release/source/deploy/ddns.py")
        self.assertEqual((app["interpreter_args"], app["args"]), ("-I", "run"))
        self.assertNotIn("token", json.dumps(app).lower())

    def test_ddns_off_installs_nothing_and_bad_values_are_refused(self):
        self.assertEqual(ddns.pm2_apps("/s", {"ddns": "off"}), [])
        self.assertEqual(len(ddns.pm2_apps("/s", {"ddns": "on"})), 1)
        for value in (False, "no", "OFF", 0):
            with self.assertRaises(ddns.Failure):
                ddns.pm2_apps("/s", {"ddns": value})
        with self.assertRaises(ddns.Failure):
            ddns.pm2_apps("relative", {"ddns": "on"})

    def test_ddns_is_opt_in_a_missing_key_installs_nothing(self):
        self.assertEqual(ddns.pm2_apps("/s", {"hostname": "gateway.example.com"}), [])
        self.assertEqual(ddns.pm2_apps("/s", {}), [])
        self.assertEqual(ddns.pm2_apps("/s"), [])

    def test_explicit_ddns_on_installs_the_app(self):
        [app] = ddns.pm2_apps("/s", {"ddns": "on", "hostname": "gateway.example.com"})
        self.assertEqual(app["name"], "ddns")

    def test_cli_reads_the_answers_file(self):
        with tempfile.TemporaryDirectory() as directory:
            answers = Path(directory) / "qual.toml"
            for text, expected in (('ddns = "off"\ntoken_file = "/x"\n', 0), ('token_file = "/x"\n', 0),
                                   ('ddns = "on"\n', 1)):
                answers.write_text(text)
                out = io.StringIO()
                with contextlib.redirect_stdout(out):
                    self.assertEqual(ddns.main(["pm2-app", "--source-dir", "/s", "--answers", str(answers)]), 0)
                self.assertEqual(len(json.loads(out.getvalue())), expected)
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                self.assertEqual(ddns.main(["pm2-app"]), 0)  # no answers file: opt-in, nothing
            self.assertEqual(json.loads(out.getvalue()), [])

    def test_defaults_come_from_the_vm_interface(self):
        from deploy.vm import paths
        self.assertEqual(ddns.STATE_FILE, paths.DDNS_STATE)
        [app] = ddns.pm2_apps(paths.RELEASE_CURRENT, {"ddns": "on"})
        self.assertEqual(app["script"], str(paths.RELEASE_CURRENT / "deploy" / "ddns.py"))
        parser_defaults = ddns.Updater(name=NAME, zone_id=ZONE)
        self.assertEqual(parser_defaults.token_file, paths.CLOUDFLARE_TOKEN)
        self.assertEqual(parser_defaults.household, paths.HOUSEHOLD_ACL)
        self.assertEqual(parser_defaults.admin.socket_path, str(paths.HAPROXY_ADMIN_SOCKET))
        self.assertEqual(parser_defaults.emergency_flag, paths.EMERGENCY_STOP)
        self.assertFalse(Path(ddns.__file__).with_name("prod").joinpath("systemd").exists())

if __name__ == "__main__":
    unittest.main()
