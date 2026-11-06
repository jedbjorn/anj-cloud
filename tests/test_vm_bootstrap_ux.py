"""Bootstrap UX audit M1-M9 and decisions #109/#112 (3), unit by unit, on the VM host without a VM.

The whole guided flow through a real pty is tests/test_vm_prompts_pty.py; these pin each piece:
the topic choice and test alert, pairing on demand, the summary checklist, the SSH lockout guard,
the hostname and Cloudflare checks, stage.py's command and secret hand-off, the backup password
confirmation, hidden-input feedback, progress and plain failure text, the first-admin audit entry,
and that no secret reaches an argument, a log or the evidence.
"""

import contextlib
import http.server
import io
import json
import os
from pathlib import Path
import shutil
import socket
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

from deploy import backup
from deploy.vm import bootstrap, guide, paths, stage
from tests.vm_bootstrap_fakes import FakeFacts, FakeSystem, write_answers
from tests.vm_bootstrap_flow import FINGERPRINT, FakeGateway, FakeStep, STATUS, sandbox
from services.access.codes import PINNED_CODE_LENGTH

ROOT = Path(__file__).resolve().parent.parent


class Tty(io.StringIO):
    def isatty(self):
        return True


class Script:
    """Scripted answers for Prompter: each call pops the next one; the prompts are kept."""

    def __init__(self, *answers):
        self.answers, self.prompts = list(answers), []

    def __call__(self, prompt=""):
        self.prompts.append(prompt)
        if not self.answers:
            raise AssertionError(f"no scripted answer for {prompt!r}")
        return self.answers.pop(0)


class Base(unittest.TestCase):
    def setUp(self):
        self.temp = Path(tempfile.mkdtemp(prefix="anj-ux-"))
        self.addCleanup(shutil.rmtree, self.temp, True)
        box = sandbox(self.temp)
        box.__enter__()
        self.addCleanup(box.__exit__, None, None, None)

    def make(self, *answers, secret=(), argv=(), tty=True, halo=True, **facts):
        self.out = Tty() if tty else io.StringIO()
        self.ask, self.secret = Script(*answers), Script(*secret)
        self.system = FakeSystem(dry=False, out=self.out)
        facts.setdefault("route", ("10.77.10.10", "10.77.10.1") if halo else ("192.168.1.20", "192.168.1.1"))
        self.facts = FakeFacts(self.system, **facts)
        setup = bootstrap.Setup(bootstrap.parser().parse_args(list(argv)), system=self.system, facts=self.facts,
                                prompter=bootstrap.Prompter(ask=self.ask, secret=self.secret, out=self.out),
                                out=self.out)
        setup.answers = {"host": "gateway.example.com", "ddns": "on", "zone_id": bootstrap.DEFAULT_ZONE_ID,
                         "accounts": ["sam", "alex"], "bind_address": "10.77.10.10", "household_lan": "192.168.0.0/24",
                         "admin_ssh_source": "10.77.10.1", "timezone": "Europe/Paris", "start_stack": True}
        # A legacy (fingerprint-approved) gateway unless a test sets pinned: rule 6's path stays covered.
        self.gateway = FakeGateway(reserve_after=None, pinned=False)
        setup.operator = self.gateway.operator
        return setup

    def text(self):
        return self.out.getvalue()


# M1: the ntfy topic --------------------------------------------------------------------------------

class Topic(Base):
    def choose(self, setup, sent=True):
        calls = []
        with mock.patch.object(guide, "send_test_alert",
                               lambda server, topic, **k: calls.append((server, topic)) or (sent, "HTTP 200")):
            setup.ask_topic()
        return calls

    def test_reuse_from_halo_is_the_default_when_staged_and_is_tested_before_install(self):
        setup = self.make("", "")
        setup.staged = {"topic": "halo-topic-" + "h" * 20}
        calls = self.choose(setup)
        self.assertEqual((setup.secrets["topic"], setup.topic_source, setup.topic_test),
                         (setup.staged["topic"], "halo", "received"))
        self.assertEqual(calls, [("https://ntfy.sh", setup.staged["topic"])])
        self.assertIn("Choose [1]: ", self.ask.prompts)
        self.assertIn("1) Use the topic copied from the VM host", self.text())
        self.assertNotIn(setup.staged["topic"], self.text())

    def test_without_a_hand_off_typing_is_the_default_on_halo_and_creating_elsewhere(self):
        setup = self.make("", "", secret=["typed-topic-" + "t" * 20] * 2)
        self.choose(setup)
        self.assertEqual(setup.topic_source, "typed")
        self.assertNotIn("copied from the VM host", self.text())
        setup = self.make("", halo=False)
        self.assertEqual(self.choose(setup), [])                  # created: the test alert comes at the end
        self.assertEqual((setup.topic_source, len(setup.secrets["topic"])), ("created", 32))

    def test_a_missing_test_alert_can_change_the_topic(self):
        first, second = "first-topic-" + "a" * 20, "second-topic-" + "b" * 20
        setup = self.make("", "n", "change", "", "", secret=[first, first, second, second])
        calls = self.choose(setup)
        self.assertEqual([topic for _server, topic in calls], [first, second])
        self.assertEqual(setup.secrets["topic"], second)
        self.assertIn("Check the ntfy app is subscribed to firs…aaaa on ntfy.sh.", self.text())
        self.assertIn(guide.HALO_ALERT, self.text())

    def test_a_failed_send_says_why_and_skip_is_recorded_as_a_warning(self):
        setup = self.make("", "skip", secret=["typed-topic-" + "t" * 20] * 2)
        self.choose(setup, sent=False)
        self.assertEqual(setup.topic_test, "not confirmed")
        self.assertIn("The test alert could not be sent: HTTP 200.", self.text())
        self.assertTrue(setup.warnings)

    def test_send_test_alert_posts_to_the_topic_and_never_names_it(self):
        seen = []

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(self):
                seen.append((self.path, self.headers.get("Title"), self.rfile.read(int(self.headers["Content-Length"]))))
                self.send_response(200 if self.path != "/redirect-topic-xxxxxxxxxxxxxxxx" else 302)
                self.send_header("Location", "http://127.0.0.1:1/elsewhere")
                self.send_header("Content-Length", "0")
                self.end_headers()
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        base = f"http://127.0.0.1:{server.server_address[1]}"
        topic = "test-topic-" + "x" * 20
        self.assertEqual(guide.send_test_alert(base, topic), (True, "HTTP 200"))
        self.assertEqual(seen[0][:2], ("/" + topic, "anj-cloud setup: test alert"))
        sent, detail = guide.send_test_alert(base, "redirect-topic-xxxxxxxxxxxxxxxx")
        self.assertEqual((sent, detail), (False, "the ntfy server answered HTTP 302"))   # never followed
        sent, detail = guide.send_test_alert("http://127.0.0.1:1", topic)
        self.assertFalse(sent)
        self.assertNotIn(topic, detail)

    def test_the_qr_code_takes_the_link_on_stdin_only(self):
        calls = []

        def runner(argv, **kwargs):
            calls.append((argv, kwargs["input"]))
            return subprocess.CompletedProcess(argv, 0, b"\xe2\x96\x80\xe2\x96\x84\n", b"")
        link = guide.ntfy_link(None, "abc-" + "d" * 28)
        self.assertEqual(link, "ntfy://ntfy.sh/abc-" + "d" * 28 + "?display=anj-cloud")
        self.assertEqual(guide.qr_text(link, runner), "▀▄\n")
        self.assertEqual(calls, [(["qrencode", "-t", "ANSIUTF8", "-m", "2"], link.encode())])
        self.assertIsNone(guide.qr_text(link, lambda argv, **k: (_ for _ in ()).throw(FileNotFoundError())))

    @unittest.skipUnless(shutil.which("qrencode") and shutil.which("zbarimg"), "qrencode and zbarimg needed")
    def test_qrencode_encodes_exactly_the_subscribe_link(self):
        link = guide.ntfy_link("https://ntfy.sh", "qr-topic-" + "q" * 23)
        text = guide.qr_text(link)
        self.assertIn("▀", text)
        self.assertNotIn("qr-topic", text)
        png = self.temp / "qr.png"
        subprocess.run(["qrencode", "-o", str(png), "-m", "2"], input=link.encode(), check=True)
        decoded = subprocess.run(["zbarimg", "-q", "--raw", str(png)], capture_output=True, text=True).stdout.strip()
        self.assertEqual(decoded, link)

    def test_no_terminal_puts_a_new_topic_link_in_a_0600_file(self):
        setup = self.make(tty=False)
        setup.secrets["topic"], setup.topic_source, setup.topic_new = "new-topic-" + "n" * 22, "created", True
        setup.alerts_phase(interactive=False)
        written = [f for f in self.system.files if f["path"].endswith("ntfy-subscribe-link")]
        self.assertEqual(written[0]["sha256"], "secret")
        self.assertEqual(written[0]["mode"], "0o600")
        self.assertNotIn(setup.secrets["topic"], self.text())


# M2: pairing last, on demand -------------------------------------------------------------------------

class Pairing(Base):
    def setUp(self):
        super().setUp()
        self.patch = mock.patch.object(bootstrap, "PAIR_POLL_SECONDS", 0)
        self.patch.start()
        self.addCleanup(self.patch.stop)

    def attended(self, setup):
        setup.attended_terminal = lambda: True
        return setup

    def test_the_code_is_issued_only_when_asked_then_approved_by_its_last_four(self):
        setup = self.attended(self.make("", FINGERPRINT[-4:].upper()))
        self.gateway.reserve_after = 1
        self.assertEqual(setup.pair(), 0)
        self.assertEqual([c[0] for c in self.gateway.calls if c[0] in ("invite", "approve", "deny")],
                         ["invite", "approve"])
        self.assertIn(("approve", "inv-1", "--fingerprint", FINGERPRINT), self.gateway.calls)
        text = self.text()
        self.assertIn("Is the anj-cloud app open on that device?", self.ask.prompts[0])   # the clock starts then
        self.assertIn("issued next", self.ask.prompts[0])
        self.assertIn(guide.group(self.gateway.codes[0]), text)
        self.assertNotIn(self.gateway.codes[0], text)
        self.assertIn('press "Pair" again', text)                          # a legacy code (rule 6)

    def test_a_pinned_code_pairs_without_any_fingerprint_step(self):          # decision #151, spec #35
        setup = self.attended(self.make(""))
        self.gateway.pinned, self.gateway.reserve_after = True, 1
        self.assertEqual(setup.pair(), 0)
        self.assertEqual(["invite"], [c[0] for c in self.gateway.calls if c[0] in ("invite", "approve", "deny")])
        text = self.text()
        self.assertEqual(PINNED_CODE_LENGTH, len(self.gateway.codes[0]))
        self.assertIn(guide.group(self.gateway.codes[0]), text)
        self.assertIn('Paired: sam\'s device "sam-laptop".', text)
        for line in ("fingerprint", "Type the last 4", "Check approval", "CA file"):
            self.assertNotIn(line, text)
        self.assertIn("revoke one you do not expect", text)

    def test_a_pinned_code_the_gateway_cannot_approve_is_approved_by_setup_without_typing(self):
        setup = self.attended(self.make(""))
        self.gateway.pinned, self.gateway.auto, self.gateway.reserve_after = True, False, 1
        with mock.patch.object(bootstrap, "PINNED_APPROVAL_GRACE", 0):
            self.assertEqual(setup.pair(), 0)
        self.assertIn(("approve", "inv-1", "--fingerprint", FINGERPRINT), self.gateway.calls)
        self.assertEqual(1, len(self.ask.prompts), "nothing typed after the ready prompt")
        self.assertIn("Paired:", self.text())
        # The gateway's alert pass sends its alert once the console answers (review M1): said so.
        self.assertIn("new-device alert once the server's console app answers again", self.text())
        self.assertNotIn("Your phone gets one alert", self.text())

    def test_declining_issues_nothing_and_names_the_command(self):
        setup = self.attended(self.make("later"))
        self.assertEqual(setup.pair(), 0)
        self.assertEqual(self.gateway.codes, [])
        self.assertIn("Later: sudo", self.text())

    def test_enter_never_burns_the_code_only_deny_refuses(self):              # review L-5
        setup = self.attended(self.make("", "", "", "deny"))
        self.gateway.reserve_after = 0
        self.assertEqual(setup.pair(), 1)
        self.assertEqual(self.text().count("Enter does nothing here"), 2)
        self.assertIn(("deny", "inv-1"), self.gateway.calls)
        self.assertNotIn("approve", [c[0] for c in self.gateway.calls])
        self.assertIn("Refused. Nothing was approved.", self.text())

    def test_an_approval_after_the_code_expired_says_so_and_offers_a_new_code(self):   # review L-2
        setup = self.attended(self.make("", FINGERPRINT[-4:], "n"))
        self.gateway.reserve_after = 0
        real_time = time.time
        with mock.patch.object(bootstrap.time, "time", lambda: real_time() + 601 if self.gateway.rows.get("inv-1", {})
                               .get("state") == "reserved" else real_time()):
            self.assertEqual(setup.pair(), 0)
        self.assertNotIn("approve", [c[0] for c in self.gateway.calls])
        self.assertIn("expired at", self.text())
        self.assertIn("pair --new-code", self.text())
        self.assertIn("Get a new code?", self.ask.prompts[-1])

    def test_a_device_label_is_printed_without_control_characters(self):     # review L-6
        setup = self.attended(self.make("deny"))
        self.gateway.rows["inv-9"] = {"id": "inv-9", "state": "reserved"}
        setup.approve({"id": "inv-9", "uid": "sam", "fingerprint": FINGERPRINT, "expires": time.time() + 600,
                       "label": "lap\x9b31mtop\x7f\x1b[2J"})
        self.assertIn('"lap31mtop[2J"', self.text())
        self.assertNotRegex(self.text(), "[\x1b\x7f\x9b]")

    def test_a_live_code_is_never_replaced_without_new_code(self):          # decision #104 (5)
        setup = self.attended(self.make("n"))
        setup.issue_first_code("sam")
        self.gateway.codes.clear()
        self.assertEqual(setup.pair(standalone=True), 0)
        self.assertEqual(self.gateway.codes, [])
        self.assertIn("It is shown only once; without it:", self.text())
        self.assertIn("Server       https://gateway.example.com", self.text())   # standalone: P1

    def test_new_code_denies_the_live_one_and_issues_another(self):
        setup = self.attended(self.make(""))
        setup.issue_first_code("sam")
        with mock.patch.object(setup, "wait_device", lambda: "interrupted"):
            self.assertEqual(setup.pair(new_code=True), 0)
        self.assertIn(("deny", "inv-1"), self.gateway.calls)
        self.assertEqual(len(self.gateway.codes), 2)
        self.assertIn("Stopped waiting. Pair later with:", self.text())

    def test_an_expired_wait_offers_a_new_code(self):
        setup = self.attended(self.make("", "", "n"))
        outcomes = iter(["expired", "expired"])
        with mock.patch.object(setup, "wait_device", lambda: next(outcomes)):
            setup.pair()
        self.assertEqual(len(self.gateway.codes), 2)
        self.assertIn(("deny", "inv-1"), self.gateway.calls)
        self.assertIn("before a device used it", self.text())

    def test_without_a_terminal_pair_never_waits_and_uses_the_0600_file(self):
        setup = self.make(tty=False)
        self.assertEqual(setup.pair(), 0)
        self.assertEqual(len(self.gateway.codes), 1)
        self.assertTrue(any(f["path"] == str(paths.FIRST_PAIRING_CODE) and f["sha256"] == "secret"
                            for f in self.system.files))
        setup.pair()                                                       # live: no second code
        self.assertEqual(len(self.gateway.codes), 1)
        self.gateway.rows["inv-1"]["state"] = "approved"
        setup.pair()
        self.assertIn("already paired", self.text())
        self.assertNotIn(self.gateway.codes[0], self.text())

    def test_the_stack_step_no_longer_issues_a_code(self):
        setup = self.make()
        stack = bootstrap.Stack(setup)
        with mock.patch.object(stack, "admins", lambda: {"table": True, "admins": ["sam"]}):
            stack.accounts()
        self.assertNotIn("invite", [c[0] for c in self.gateway.calls])

    def test_first_code_reissue_is_kept_for_scripts(self):
        setup = self.make(tty=False)
        setup.issue_first_code("sam")
        bootstrap.reissue(setup)
        self.assertIn(("deny", "inv-1"), self.gateway.calls)
        self.assertEqual(len(self.gateway.codes), 2)


# M3: the summary checklist ---------------------------------------------------------------------------

class Summary(Base):
    def summary(self, setup, interactive=False):
        with mock.patch.object(bootstrap.Status, "collect", lambda s: dict(STATUS)):
            setup.summary(interactive)
        return self.text()

    def test_an_ordered_checklist_with_the_client_fields(self):
        setup = self.make(tty=False, mounted={str(paths.BACKUP_MOUNT): {"source": "anj-backup"}})
        text = self.summary(setup)
        for line in ("anj-cloud is installed and healthy.  gateway.example.com",
                     "Services      11 of 11 running (ddns idle between runs — normal)",
                     "What to do now, in order:", "A. The VM host:", "B. Backups:          ⚠ not set up: sudo",
                     "C. Router:           forward TCP 443 from the internet to the VM host", "D. First device:",
                     "VM host step — run in a terminal ON THE VM HOST (not in this VM).", "~/anj-cloud-ca.crt",
                     "P1. In the app", "Server       https://gateway.example.com",
                     "Code         the pairing code", "pairs at once"):
            self.assertIn(line, text)
        for line in ("CA file", "Check approval", "32-character", "fingerprint (SHA-256)"):   # decision #151
            self.assertNotIn(line, text)
        self.assertNotIn("127.0.0.1:8834", text)
        self.assertNotIn("link above", text)
        self.assertLess(text.index("What to do now"), text.index("VM host step"))

    def test_warnings_come_before_the_checklist_and_a_missing_share_is_named(self):
        setup = self.make(tty=False)
        setup.warn("The ntfy test alert was not confirmed; check the phone's subscription.")
        text = self.summary(setup)
        self.assertLess(text.index("⚠ The ntfy test alert"), text.index("What to do now"))
        self.assertIn("The backup drive is not attached to this server", text)
        self.assertIn("(VM host: DOS_BACKUP)", text)                           # on the VM host only
        self.assertNotIn("The VM host", guide.no_share_text(False, "anj-cloud-setup"))

    def test_the_issuer_fingerprint_matches_openssl(self):
        if not shutil.which("openssl"):
            self.skipTest("openssl needed")
        subprocess.run(["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256", "-noenc",
                        "-subj", "/CN=t", "-days", "1", "-keyout", str(self.temp / "k"), "-out", str(self.temp / "c")],
                       capture_output=True, check=True)
        paths.OPERATOR_DIR.mkdir(parents=True)
        shutil.copy(self.temp / "c", paths.OPERATOR_DIR / "issuer.crt")
        expected = subprocess.run(["openssl", "x509", "-noout", "-fingerprint", "-sha256", "-in", str(self.temp / "c")],
                                  capture_output=True, text=True, check=True).stdout.strip().split("=", 1)[1]
        self.assertEqual(self.make().issuer_fingerprint(), expected)

    def test_the_halo_command_prints_the_fingerprint_and_keeps_the_ca_file(self):
        self.assertIn("openssl x509 -noout -fingerprint -sha256", bootstrap.HALO_ISSUER_COMMAND)
        self.assertIn('install -m 644 "$t" ~/anj-cloud-ca.crt; rm -f "$t"', bootstrap.HALO_ISSUER_COMMAND)


# M4: the SSH lockout guard ----------------------------------------------------------------------------

class LockoutGuard(Base):
    def test_enter_takes_the_current_source_and_retyping_keeps_the_typed_one(self):
        setup = self.make("")
        self.assertEqual(setup.lockout_guard("10.77.10.9", "10.77.10.1"), "10.77.10.1")
        self.assertIn("this server may have no password login to fall back on", self.text())
        setup = self.make("10.0.0.1", "10.77.10.9")
        self.assertEqual(setup.lockout_guard("10.77.10.9", "10.77.10.1"), "10.77.10.9")
        self.assertTrue(setup.warnings)
        self.assertEqual(self.make().lockout_guard("10.77.10.1", "10.77.10.1"), "10.77.10.1")
        self.assertEqual(self.make().lockout_guard("10.77.10.1", None), "10.77.10.1")   # console
        self.assertEqual(self.make().lockout_guard("10.77.10.1", "::ffff:10.77.10.1"), "10.77.10.1")   # mapped: no prompt

    def test_answers_mode_refuses_a_source_that_locks_this_session_out(self):
        setup = self.make(ssh_client="192.168.1.50")
        with self.assertRaises(bootstrap.SetupError) as raised:
            setup.guard_answers()
        self.assertIn('admin_ssh_source = "192.168.1.50"', raised.exception.fix)
        self.make(ssh_client="10.77.10.1").guard_answers()

    def test_ipv6_and_stale_sources_get_honest_advice(self):                # review L-7
        setup = self.make(ssh_client="2001:db8::5")
        with self.assertRaises(bootstrap.SetupError) as raised:
            setup.guard_answers()
        self.assertIn("ssh -4", raised.exception.fix)
        self.assertNotIn("2001:db8::5\"", raised.exception.fix)                 # never a value the check refuses
        setup = self.make(ssh_client="::ffff:10.77.10.9")
        with self.assertRaises(bootstrap.SetupError) as raised:
            setup.guard_answers()
        self.assertIn('admin_ssh_source = "10.77.10.9"', raised.exception.fix)
        self.assertEqual(bootstrap.validate_answers({"admin_ssh_source": "10.77.10.9"})["admin_ssh_source"], "10.77.10.9")
        setup = self.make("", ssh_live=False)
        self.assertEqual(setup.lockout_guard("10.77.10.9", "10.77.10.1"), "10.77.10.1")
        self.assertIn("it may be stale", self.text())

    def test_a_live_sshd_ancestor_marks_the_address_current(self):
        proc = self.temp / "proc"
        for pid, ppid, comm, environ in ((300, 200, "python3", b""), (200, 150, "bash", b"SSH_CONNECTION=1.2.3.4 5 6.7.8.9 22\0"),
                                         (150, 100, "sshd-session", b""), (100, 1, "sshd", b"")):
            (proc / str(pid)).mkdir(parents=True)
            (proc / str(pid) / "environ").write_bytes(environ)
            (proc / str(pid) / "comm").write_text(comm + "\n")
            (proc / str(pid) / "stat").write_text(f"{pid} ({comm}) S {ppid} 1 1")
        self.assertEqual(guide.ssh_client_info({}, proc, pid=300), ("1.2.3.4", True))
        (proc / "150" / "comm").write_text("tmux: server\n")
        (proc / "100" / "comm").write_text("systemd\n")
        self.assertEqual(guide.ssh_client_info({}, proc, pid=300), ("1.2.3.4", False))   # possibly stale

    def test_the_client_address_is_found_past_sudo(self):
        proc = self.temp / "proc"
        for pid, ppid, environ in ((300, 200, b"PATH=/bin\0"), (200, 100, b"SSH_CONNECTION=10.77.10.1 51000 10.77.10.10 22\0"),
                                   (100, 1, b"")):
            (proc / str(pid)).mkdir(parents=True)
            (proc / str(pid) / "environ").write_bytes(environ)
            (proc / str(pid) / "stat").write_text(f"{pid} (sudo (x)) S {ppid} 1 1")
        self.assertEqual(guide.ssh_client_address({}, proc, pid=300), "10.77.10.1")
        self.assertEqual(guide.ssh_client_address({"SSH_CONNECTION": "1.2.3.4 5 6.7.8.9 22"}, proc, pid=300), "1.2.3.4")
        self.assertIsNone(guide.ssh_client_address({}, proc, pid=100))


# M5: hostname and Cloudflare ------------------------------------------------------------------------

class FakeHttp:
    def __init__(self, status, body):
        self.status, self.body, self.seen = status, body, []

    def request(self, method, url, *, headers=None, body=None):
        self.seen.append((method, url, body))
        return self.status, json.dumps(self.body).encode()


class Cloudflare(Base):
    TOKEN = "cf-token-" + "z" * 30

    def test_one_read_only_get_proves_token_zone_and_record(self):
        record = {"id": "a" * 32, "name": "gateway.example.com", "type": "A", "proxied": False, "content": "1.1.1.1"}
        http = FakeHttp(200, {"success": True, "result": [record]})
        ok, message = guide.cloudflare_check(self.TOKEN, "b" * 32, "gateway.example.com", http)
        self.assertTrue(ok)
        self.assertEqual(message, "token works, zone found, record gateway.example.com found (A, not proxied).")
        self.assertEqual([(method, body) for method, _url, body in http.seen], [("GET", None)])

    def test_failures_are_plain_and_never_name_the_token(self):
        cases = ((FakeHttp(403, {"success": False, "errors": [{"code": 9109}]}), "refused the token (HTTP 403)"),
                 (FakeHttp(400, {"success": False, "errors": [{"code": 7003}]}), "does not know the zone ID"),
                 (FakeHttp(200, {"success": True, "result": []}), "has no single A record named gateway.example.com"),
                 (FakeHttp(400, {"success": False, "errors": [{"code": 6003}]}), "refused the token (HTTP 400)"),
                 (FakeHttp(400, {"success": False, "errors": []}), "did not accept the token or the zone ID (HTTP 400)"))
        for fake, expected in cases:
            ok, message = guide.cloudflare_check(self.TOKEN, "b" * 32, "gateway.example.com", fake)
            self.assertFalse(ok)
            self.assertIn(expected, message)
            self.assertNotIn(self.TOKEN, message)

    def test_answers_mode_stops_before_any_change_and_interactive_can_retry(self):
        setup = self.make(tty=False)
        setup.secrets["token"] = self.TOKEN
        with mock.patch.object(guide, "cloudflare_check", lambda *a, **k: (False, "Cloudflare refused the token.")):
            with self.assertRaises(bootstrap.SetupError):
                setup.check_cloudflare(interactive=False)
            setup = self.make("1", "3", secret=[self.TOKEN + "b"] * 2)
            setup.secrets["token"] = self.TOKEN
            setup.check_cloudflare(interactive=True)
        self.assertEqual(setup.secrets["token"], self.TOKEN + "b")
        self.assertEqual(setup.cloudflare, "unchecked")
        self.assertTrue(setup.warnings)

    def test_after_steps_ran_stopping_does_not_claim_nothing_changed(self):    # review L-8
        setup = self.make("4")
        setup.secrets["token"] = self.TOKEN
        setup.steps.append({"step": 3, "name": "Data disk"})
        with mock.patch.object(guide, "cloudflare_check", lambda *a, **k: (False, "Cloudflare refused the token.")), \
                self.assertRaises(bootstrap.SetupError) as raised:
            setup.check_cloudflare(interactive=True)
        self.assertEqual(str(raised.exception), "Stopped; the finished steps are kept.")
        self.assertIn("Stop here (the finished steps are kept)", self.text())
        self.assertNotIn("nothing has changed yet", self.text())

    def test_a_new_hostname_is_typed_twice(self):
        setup = self.make("home.example.org", "home.example.org")
        self.assertEqual(setup.ask_host("gateway.example.com"), "home.example.org")
        self.assertIn("cannot be changed later", self.text())
        setup = self.make("")
        self.assertEqual(setup.ask_host("gateway.example.com"), "gateway.example.com")


# M6 and decision #109: stage.py ----------------------------------------------------------------------

class Stage(Base):
    def test_the_printed_command_is_runnable(self):
        out = io.StringIO()
        with mock.patch.object(stage, "stage", lambda *a, **k: {"commit": "c" * 40, "setup": str(stage.SETUP)}), \
                mock.patch("sys.stdout", out):
            self.assertEqual(stage.main(["anj-prod"]), 0)
        text = out.getvalue()
        line = next(line.strip() for line in text.splitlines() if line.strip().startswith("ssh "))
        self.assertEqual(line, f"ssh -t -F {stage.SSH_CONFIG} anj-prod sudo /var/lib/anj-cloud-setup/src/deploy/vm/anj-cloud-setup")
        self.assertNotIn("...", text)
        self.assertIn("--with-secrets", text)

    def test_halo_secrets_are_read_into_memory_with_sudo_for_the_topic(self):
        calls = []
        token = self.temp / "token"
        token.write_text("fake-token-" + "t" * 20 + "\n")

        def run(argv, **kwargs):
            calls.append(argv)
            return subprocess.CompletedProcess(argv, 0, b"fake-halo-topic-" + b"h" * 16 + b"\n", b"")
        with mock.patch("sys.stderr", io.StringIO()):
            values = stage.read_halo_secrets(token, None, run)
        self.assertEqual(calls, [["sudo", "cat", "/etc/anj-cloud-host/ntfy-topic"]])
        self.assertEqual(values, {"token": "fake-token-" + "t" * 20, "topic": "fake-halo-topic-" + "h" * 16})
        topic = self.temp / "topic"
        topic.write_text("file-topic-" + "f" * 20)
        self.assertEqual(stage.read_halo_secrets(self.temp / "absent", topic, run), {"topic": "file-topic-" + "f" * 20})

    def test_the_hand_off_serves_once_over_a_forwarded_socket_and_never_in_argv(self):
        values = {"token": "fake-token-" + "t" * 20, "topic": "fake-topic-" + "p" * 20}
        remote = self.temp / "home" / "anj" / ".anj-cloud-setup-0123456789abcdef.sock"
        remote.parent.mkdir(parents=True)
        received, argvs = {}, []

        def ssh(argv, check=False):
            """Stands in for `ssh -R remote:local`: the VM end is a socket that relays to `local`."""
            argvs.append(argv)
            local = argv[argv.index("-R") + 1].split(":", 1)[1]
            relay = socket.socket(socket.AF_UNIX)
            relay.bind(str(remote))
            os.chmod(remote, 0o600)                     # as sshd's StreamLocalBindMask 0177 makes it
            relay.listen(1)

            def forward():
                connection, _ = relay.accept()
                with connection, socket.socket(socket.AF_UNIX) as upstream:
                    upstream.connect(local)
                    connection.sendall(upstream.recv(8192))
            threading.Thread(target=forward, daemon=True).start()
            with mock.patch.object(guide, "STAGED_SOCKET", guide.re.compile(guide.re.escape(str(remote)))):
                received.update(guide.read_staged(remote, expected_owner=os.getuid()))
            relay.close()
            return subprocess.CompletedProcess(argv, 0)
        code, served = stage.run_with_secrets("anj-qual", values, ["--answers", "/tmp/qual.toml"], run=ssh,
                                              server_dir=self.temp)
        self.assertEqual((code, served, received), (0, True, values))
        self.assertFalse(remote.exists())                                  # setup removes the VM end
        joined = json.dumps(argvs)
        for value in values.values():
            self.assertNotIn(value, joined)
        argv = argvs[0]
        self.assertIn("ExitOnForwardFailure=yes", argv)
        self.assertRegex(argv[-1], r"^sudo /var/lib/anj-cloud-setup/src/deploy/vm/anj-cloud-setup --secrets-socket "
                                   r"/home/anj/\.anj-cloud-setup-[0-9a-f]{16}\.sock --answers /tmp/qual\.toml$")
        self.assertEqual(list(self.temp.glob("anj-stage-*")), [])          # the private directory is gone

    def test_only_the_ssh_child_is_served_and_others_get_nothing(self):    # review L-1
        values = {"topic": "fake-topic-" + "p" * 20}
        logged, got = [], {}

        class Child:
            """The 'ssh' child: a stranger process connects first (refused, nothing sent), then
            the child itself (here: this process) reads the payload."""
            pid = os.getpid()

            def __init__(self, argv):
                self.local = argv[argv.index("-R") + 1].split(":", 1)[1]

            def wait(self):
                stranger = subprocess.run([sys.executable, "-I", "-c", "import socket,sys;s=socket.socket(socket.AF_UNIX);"
                                           "s.connect(sys.argv[1]);print(len(s.recv(8192)))", self.local],
                                          capture_output=True, text=True, timeout=30)
                got["stranger"] = stranger.stdout.strip()
                with socket.socket(socket.AF_UNIX) as own:
                    own.connect(self.local)
                    got["child"] = own.recv(8192)
                return 0
        code, served = stage.run_with_secrets("anj-qual", values, popen=Child, server_dir=self.temp, log=logged.append)
        self.assertEqual((code, served, got["stranger"]), (0, True, "0"))
        self.assertEqual(json.loads(got["child"]), values)
        self.assertEqual(len(logged), 1)
        self.assertIn("refused a connection to the hand-off socket", logged[0])
        self.assertNotIn(values["topic"], logged[0])
        argv = stage.handoff_argv("anj-prod", "/l", "/r", terminal=True)
        self.assertIn("ControlMaster=no", argv)                            # the forward is this ssh's own

    def test_the_served_mark_is_read_after_the_server_finished(self):        # review M-1
        class SlowEvent(threading.Event):
            def set(self):
                time.sleep(0.2)
                super().set()

        def ssh(argv, check=False):
            with socket.socket(socket.AF_UNIX) as client:
                client.connect(argv[argv.index("-R") + 1].split(":", 1)[1])
                client.recv(8192)
            return subprocess.CompletedProcess(argv, 0)
        with mock.patch.object(stage.threading, "Event", SlowEvent):
            for _ in range(5):
                self.assertEqual(stage.run_with_secrets("anj-qual", {"topic": "t" * 30}, run=ssh, server_dir=self.temp),
                                 (0, True))

    def test_a_hand_off_socket_that_will_not_be_read_is_removed_at_once(self):   # review L-3
        path = self.temp / "home" / "anj" / ".anj-cloud-setup-0123456789abcdef.sock"
        path.parent.mkdir(parents=True)
        for argv in (["pair"], ["status"], ["--dry-run"]):
            listener = socket.socket(socket.AF_UNIX)
            listener.bind(str(path))
            out = io.StringIO()
            system = FakeSystem(dry=True, out=out)
            with mock.patch.object(guide, "STAGED_SOCKET", guide.re.compile(guide.re.escape(str(path)))), \
                    mock.patch.object(bootstrap, "https_reachable", lambda host, timeout=10: True), \
                    mock.patch.object(bootstrap.socket, "getaddrinfo", lambda *a, **k: [()]), \
                    mock.patch.object(bootstrap.sys.stdin, "isatty", lambda: False):
                bootstrap.main([*argv, "--secrets-socket", str(path)], system=system, facts=FakeFacts(system), out=out)
            listener.close()
            self.assertFalse(path.exists(), argv)

    def test_read_staged_refuses_anything_unexpected(self):
        for payload in (b"not json", json.dumps({"token": "short"}).encode(), json.dumps({"other": "x"}).encode()):
            path = self.temp / "home" / "anj" / f".anj-cloud-setup-{os.urandom(8).hex()}.sock"
            path.parent.mkdir(parents=True, exist_ok=True)
            listener = socket.socket(socket.AF_UNIX)
            listener.bind(str(path))
            os.chmod(path, 0o600)                       # owner-only: the payload checks are what is tested
            listener.listen(1)

            def serve():
                connection, _ = listener.accept()
                with connection:
                    connection.sendall(payload)
            threading.Thread(target=serve, daemon=True).start()
            with mock.patch.object(guide, "STAGED_SOCKET", guide.re.compile(guide.re.escape(str(path)))), \
                    self.assertRaises(ValueError) as raised:
                guide.read_staged(path)
            self.assertNotIn("short", str(raised.exception))
            listener.close()
        with self.assertRaises(ValueError):
            guide.read_staged("/tmp/elsewhere.sock")
        path = self.temp / "home" / "anj" / ".anj-cloud-setup-fedcba9876543210.sock"
        with socket.socket(socket.AF_UNIX) as listener:
            listener.bind(str(path))
            os.chmod(path, 0o660)
            with mock.patch.object(guide, "STAGED_SOCKET", guide.re.compile(guide.re.escape(str(path)))), \
                    self.assertRaises(ValueError) as raised:
                guide.read_staged(path)
        self.assertIn("open to other users", str(raised.exception))

    def test_answers_mode_takes_the_staged_secrets_when_no_file_is_named(self):
        setup = self.make(tty=False)
        setup.answers["ddns"] = "off"
        setup.staged = {"token": "fake-token-" + "t" * 20, "topic": "fake-topic-" + "p" * 20}
        setup.collect_state_secrets(interactive=False)
        self.assertEqual((setup.secrets["token"], setup.secrets["topic"], setup.topic_source),
                         (setup.staged["token"], setup.staged["topic"], "halo"))
        self.assertIn(setup.staged["token"], setup.secret_values())


# M7: the backup password ----------------------------------------------------------------------------

class BackupPassword(Base):
    def escrow(self, *typed):
        password = self.temp / "restic-password"
        password.write_text("p" * 58 + "TAIL42\n")
        tty = self.temp / "tty"
        tty.touch()
        answers = list(typed)
        stdout = io.StringIO()
        with mock.patch.object(backup.sys.stdin, "isatty", lambda: True), mock.patch("sys.stdout", stdout):
            confirmed = backup.Backup.show_escrow(mock.Mock(password_file=password, ESCROW_NOTE=backup.Backup.ESCROW_NOTE),
                                                  tty=str(tty), ask=lambda prompt: answers.pop(0))
        return confirmed, tty.read_text(), stdout.getvalue()

    def test_the_stakes_are_plain_and_the_last_six_confirm_it(self):
        confirmed, screen, stdout = self.escrow("nope", "TAIL42")
        self.assertTrue(confirmed)
        self.assertIn("your backups can ONLY be restored with this password", screen)
        self.assertIn("unreadable — by anyone, including you", screen)
        self.assertIn('"anj-cloud backup password"', screen)
        self.assertIn("That does not match; check your saved copy.", screen)
        self.assertIn("\033[H\033[2J\033[3J", screen)
        self.assertNotIn("not shown again", screen)
        self.assertEqual(stdout, "")                                       # /dev/tty only

    def test_ctrl_c_or_ctrl_d_still_clears_the_screen_and_scrollback(self):   # review M-2
        for error in (KeyboardInterrupt, EOFError):
            password = self.temp / "restic-password"
            password.write_text("p" * 58 + "TAIL42\n")
            tty = self.temp / f"tty-{error.__name__}"
            tty.touch()

            def ask(prompt):
                raise error()
            with mock.patch.object(backup.sys.stdin, "isatty", lambda: True), self.assertRaises(error):
                backup.Backup.show_escrow(mock.Mock(password_file=password, ESCROW_NOTE=backup.Backup.ESCROW_NOTE),
                                          tty=str(tty), ask=ask)
            screen = tty.read_text()
            self.assertGreater(screen.rindex("\033[3J"), screen.index("TAIL42"))
            self.assertIn("\033[2J", screen)
            self.assertIn("Not confirmed", screen)

    def test_three_misses_leave_it_unconfirmed_with_the_re_show_command(self):
        confirmed, screen, _ = self.escrow("a", "b", "c")
        self.assertFalse(confirmed)
        self.assertIn("anj-cloud-setup backup --show-password", screen)

    def test_offered_at_the_end_of_the_install_with_the_share_attached(self):
        setup = self.make("", mounted={str(paths.BACKUP_MOUNT): {"source": "anj-backup"}})
        self.system.responses[f"python3 -I {paths.RELEASE_CURRENT}/deploy/backup.py init --show-escrow"] = \
            (0, json.dumps({"repository_id": "r" * 64, "escrow": "confirmed"}), "")
        setup.offer_backup()
        self.assertEqual(setup.backup_done, "confirmed")
        self.assertIn({"argv": ["python3", "-I", f"{paths.RELEASE_CURRENT}/deploy/backup.py", "init", "--show-escrow"],
                       "user": "anj"}, self.system.commands)
        self.assertIn("First full backup: tonight at 03:30", self.text())
        self.make("").offer_backup()                                         # no share: no offer
        self.assertNotIn("Set up encrypted backups now?", self.text())


# M8: hidden input -------------------------------------------------------------------------------------

class HiddenInput(Base):
    def test_only_the_length_is_echoed_and_both_entries_must_match(self):
        out = io.StringIO()
        secret = Script("abcdefghij", "abcdefghiX", "abcdefghij", "abcdefghij")
        prompter = bootstrap.Prompter(ask=Script(), secret=secret, out=out)
        self.assertEqual(prompter.hidden("Thing", twice=True), "abcdefghij")
        self.assertEqual(out.getvalue().count("received 10 characters."), 2)
        self.assertIn("The two entries differ; try again.", out.getvalue())
        self.assertNotIn("abcdefghij", out.getvalue())

    def test_every_secret_note_says_what_why_where_and_if_lost(self):
        for note in (guide.token_note("/x"), guide.topic_note("/x"), guide.topic_entry_note("/x"),
                     guide.code_note("sam", "14:32", "sudo anj-cloud-setup"), backup.Backup.ESCROW_NOTE):
            self.assertIn("What it is", note)
            self.assertRegex(note, "Where|password manager")
            self.assertRegex(note, "lost|Why it matters|ONLY")


# M9: start-to-end frame --------------------------------------------------------------------------------

class Frame(Base):
    def test_progress_counts_steps_with_a_heartbeat(self):
        setup = self.make(tty=False)
        step = FakeStep(setup, 1, "Packages", 0.25)
        with mock.patch.object(guide, "HEARTBEAT_SECONDS", 0.1):
            setup.execute(step, 1, 12)
        text = self.text()
        self.assertIn("[ 1/12] Installing system packages (Docker, Node, firewall tools) — usually 2–5 min", text)
        self.assertIn("still working …", text)
        self.assertRegex(text, r"\[ 1/12\] Installing system packages: done ✓ \(\d+s\)")

    def test_a_failure_is_plain_with_where_what_and_the_next_commands(self):
        setup = self.make(tty=False)

        class Broken(FakeStep):
            def apply(self):
                raise subprocess.CalledProcessError(1, ["secret-carrying", "argv"])
        with mock.patch.object(bootstrap.Setup, "step_list",
                               lambda s: [FakeStep(s, 8, "Release", 0), Broken(s, 9, "Stack", 0), FakeStep(s, 10, "x", 0)]):
            steps = setup.step_list()
            try:
                for position, step in enumerate(steps, 1):
                    setup.current = (position, len(steps), step)
                    setup.execute(step, position, len(steps))
            except subprocess.CalledProcessError as error:
                code = setup.stopped(guide.plain_error(error), None, type(error).__name__)
        text = self.text()
        self.assertEqual(code, 1)
        self.assertIn("Setup stopped at step 2 of 3 (starting anj-cloud). Nothing is lost: finished steps are kept.",
                      text)
        self.assertIn("What happened: a command it ran failed", text)
        self.assertIn("doctor        lists what is wrong", text)
        self.assertIn("Details (no secrets): ", text)
        self.assertNotIn("CalledProcessError", text)
        self.assertNotIn("secret-carrying", text)

    def test_the_review_can_stop_before_any_change(self):
        setup = self.make("n")
        setup.topic_source, setup.topic_test, setup.cloudflare = "halo", "received", "ok"
        self.assertFalse(setup.confirm_review(bootstrap.DataDisk(setup)))
        self.assertIn("Alerts        ntfy topic from the VM host (test ✓)", self.text())
        self.assertIn("DDNS          on (zone 0000…0000, token ✓)", self.text())

    def test_preflight_runs_before_the_first_question(self):
        out = Tty()
        system = FakeSystem(dry=False, out=out)
        facts = FakeFacts(system, memory=1 << 20)
        prompter = bootstrap.Prompter(ask=Script(), secret=Script(), out=out)
        with mock.patch.object(bootstrap.sys.stdin, "isatty", lambda: True), \
                mock.patch.object(bootstrap.os, "geteuid", lambda: 0), \
                mock.patch.object(bootstrap, "https_reachable", lambda host, timeout=10: True), \
                mock.patch.object(bootstrap.socket, "getaddrinfo", lambda *a, **k: [()]):
            self.assertEqual(bootstrap.main([], system=system, facts=facts, prompter=prompter, out=out), 1)
        self.assertIn("Before you start, have ready:", out.getvalue())
        self.assertIn("Preflight found problems; nothing was changed", out.getvalue())
        self.assertNotIn("[1/", out.getvalue())

    def test_plain_errors_name_no_exception_class(self):
        for error in (subprocess.TimeoutExpired(["x"], 1), FileNotFoundError("/secret"), PermissionError(), KeyError("k"),
                      json.JSONDecodeError("m", "d", 0), OSError()):
            text = guide.plain_error(error)
            self.assertNotIn("Error", text)
            self.assertNotIn("secret", text)

    def test_help_is_plain(self):
        out = io.StringIO()
        with mock.patch("sys.stdout", out), self.assertRaises(SystemExit):
            bootstrap.parser().parse_args(["--help"])
        self.assertIn("sudo anj-cloud-setup pair         pair the first device (new code, wait until the device pairs)",
                      out.getvalue())
        self.assertNotIn("#85", out.getvalue().split("positional arguments")[0])

    def test_the_command_link_is_made_in_step_10_and_used_in_every_instruction(self):
        self.assertEqual(bootstrap.setup_command(), str(bootstrap.LAUNCHER))
        bootstrap.COMMAND_LINK.parent.mkdir(parents=True)
        bootstrap.COMMAND_LINK.symlink_to(bootstrap.LAUNCHER)
        self.assertEqual(bootstrap.setup_command(), "anj-cloud-setup")
        setup = self.make()
        lines = bootstrap.Operations(setup).plan()
        self.assertIn(f"{bootstrap.COMMAND_LINK} -> {bootstrap.COMMAND_TARGET}", " ".join(lines))
        # Decision #112 (1): the recovery CLI is installed beside it.
        self.assertIn(f"{bootstrap.ADMIN_LINK} -> {bootstrap.ADMIN_TARGET}", " ".join(lines))


# Decision #112 (3): the first-admin audit entry ---------------------------------------------------------

class FirstAdminAudit(unittest.TestCase):
    def test_the_direct_write_records_one_role_grant_by_bootstrap(self):
        try:
            from services.access.registry import Registry
        except ImportError as error:                                      # needs the access venv (cryptography)
            self.skipTest(str(error))
        temp = Path(tempfile.mkdtemp(prefix="anj-ux-registry-"))
        self.addCleanup(shutil.rmtree, temp, True)
        registry = Registry(temp)
        self.addCleanup(registry.db.close)
        for uid in ("sam", "alex"):
            registry.db.execute("INSERT INTO accounts(uid,display_name,enabled,admin) VALUES(?,?,1,0)", (uid, uid))
        registry.db.commit()
        database = next(temp.glob("*.sqlite"))
        script = bootstrap.ADMIN_SCRIPT.replace("/var/lib/anj/registry.sqlite", str(database))

        def run(uid):
            result = subprocess.run([sys.executable, "-c", script], input=uid + "\n", capture_output=True, text=True,
                                    check=True)
            return json.loads(result.stdout.strip().splitlines()[-1])
        self.assertEqual(run("sam"), {"table": True, "admins": ["sam"], "granted": True, "audited": True})
        self.assertEqual(run("sam")["granted"], False)                    # a re-run grants and audits nothing
        self.assertEqual(run("alex")["admins"], ["sam"])                   # never a second admin, never a demotion
        with contextlib.closing(sqlite3.connect(database)) as db:
            rows = db.execute("SELECT actor_uid, action, target_uid, result FROM admin_audit").fetchall()
        self.assertEqual(rows, [("bootstrap", "role-grant", "sam", "ok")])


# Secrets never in arguments, logs or evidence (--answers) ----------------------------------------------

class NoSecretLeaks(Base):
    def test_an_answers_install_keeps_every_secret_out_of_argv_output_and_evidence(self):
        token, topic = "leak-token-" + "t" * 30, "leak-topic-" + "p" * 21
        (self.temp / "token").write_text(token + "\n")
        (self.temp / "topic").write_text(topic + "\n")
        answers = write_answers(self.temp, f'ddns = "on"\ntoken_file = "{self.temp}/token"\n'
                                           f'ntfy_topic_file = "{self.temp}/topic"\ndata_disk_init = true\n')
        out = io.StringIO()
        system = FakeSystem(dry=False, out=out)
        facts = FakeFacts(system, ssh_client="10.77.11.1")
        gateway = FakeGateway(reserve_after=None)
        spawned = []
        real_run = subprocess.run
        with mock.patch.object(bootstrap.Setup, "step_list",
                               lambda s: [FakeStep(s, n, name, 0) for n, name in ((9, "Stack"), (10, "Operations apps"))]), \
                mock.patch.object(bootstrap.Setup, "operator", lambda s, *a, **k: gateway.operator(*a, **k)), \
                mock.patch.object(bootstrap.Status, "collect", lambda s: dict(STATUS)), \
                mock.patch.object(bootstrap, "https_reachable", lambda host, timeout=10: True), \
                mock.patch.object(bootstrap.socket, "getaddrinfo", lambda *a, **k: [()]), \
                mock.patch.object(bootstrap.os, "geteuid", lambda: 0), \
                mock.patch.object(guide, "cloudflare_check", lambda *a, **k: (True, "token works.")), \
                mock.patch.object(subprocess, "run", lambda argv, *a, **k: spawned.append(argv) or real_run(argv, *a, **k)):
            code = bootstrap.main(["--answers", str(answers)], system=system, facts=facts, out=out)
        self.assertEqual(code, 0, out.getvalue())
        evidence = "".join(path.read_text() for path in paths.SETUP_LOG_DIR.glob("*.json"))
        record = bootstrap.SETUP_RECORD.read_text()
        argv = json.dumps([system.commands, spawned, gateway.calls])
        self.assertTrue(evidence)
        for value in (token, topic, *gateway.codes, *(guide.group(c) for c in gateway.codes)):
            self.assertNotIn(value, argv)
            self.assertNotIn(value, out.getvalue())
            self.assertNotIn(value, evidence)
            self.assertNotIn(value, record)
        self.assertEqual(paths.FIRST_PAIRING_CODE.read_text().strip(), gateway.codes[0])   # the 0600 file only
        self.assertEqual(oct(paths.FIRST_PAIRING_CODE.stat().st_mode & 0o777), "0o600")
        self.assertIn("What to do now, in order:", out.getvalue())
        self.assertIn("Server       https://gateway.example.com", out.getvalue())


if __name__ == "__main__":
    unittest.main()
