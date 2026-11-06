"""Spec #21 (B2) qualification script: the guided prompts, driven through a real pseudo-terminal.

The child is anj-cloud-setup's own code (deploy.vm.bootstrap.main and Setup.collect_secrets) with
the machine replaced by tests/vm_bootstrap_fakes.py, so nothing on the VM host changes. The pty is the
child's controlling terminal, so getpass's hidden input is the real one (echo off).
"""

import json
import os
from pathlib import Path
import pty
import select
import shutil
import signal
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parent.parent

DRIVER = r'''
import json, sys
from pathlib import Path
from unittest import mock
from deploy.vm import bootstrap, guide
from tests.vm_bootstrap_fakes import FakeFacts, FakeSystem

mode = sys.argv[1]
patches = [mock.patch.object(bootstrap, "https_reachable", lambda host, timeout=10: True),
           mock.patch.object(bootstrap.socket, "getaddrinfo", lambda *a, **k: [()])]
for patch in patches:
    patch.start()
if mode == "dry-run":
    system = FakeSystem(dry=True)
    code = bootstrap.main(["--dry-run", "--source", sys.argv[2]], system=system, facts=FakeFacts(system))
    print(f"EXIT {code} EXECUTED {len(system.executed)}", flush=True)
else:
    target = Path(sys.argv[2])
    sent = []
    system = bootstrap.System(dry=False)
    setup = bootstrap.Setup(bootstrap.parser().parse_args([]), system=system,
                            facts=FakeFacts(system, route=("10.77.10.10", "10.77.10.1")))
    setup.answers = {"ddns": "on", "zone_id": "00000000000000000000000000000000", "host": "gateway.example.com"}
    with mock.patch.object(bootstrap.paths, "CLOUDFLARE_TOKEN", target.parent / "absent-token"), \
            mock.patch.object(bootstrap.paths, "NTFY_TOPIC", target.parent / "absent-topic"), \
            mock.patch.object(guide, "cloudflare_check", lambda t, z, h, http=None: (True, "token works.")), \
            mock.patch.object(guide, "send_test_alert", lambda server, topic, **k: sent.append(len(topic)) or (True, "ok")):
        setup.collect_secrets(interactive=True)
    system.write(target, setup.secrets["token"] + "\n", mode=0o600, secret=True)
    system.write(target.with_name("topic"), setup.secrets["topic"] + "\n", mode=0o600, secret=True)
    print("FILES " + json.dumps(system.files) + " TOPIC " + str(len(setup.secrets["topic"])) +
          " SOURCE " + setup.topic_source + " TESTS " + str(sent), flush=True)
'''


class Terminal:
    def __init__(self, argv):
        env = dict(os.environ, PYTHONPATH=str(ROOT), TERM="dumb", PYTHONDONTWRITEBYTECODE="1")
        self.pid, self.fd = pty.fork()
        if self.pid == 0:  # child: the pty is its controlling terminal
            os.chdir(ROOT)
            os.execvpe(argv[0], argv, env)
        self.output = ""
        self.mark = 0           # read_until looks only past the previous match: prompts repeat

    def read_until(self, text, timeout=60):
        deadline = time.monotonic() + timeout
        while text not in self.output[self.mark:]:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise AssertionError(f"timed out waiting for {text!r}; got:\n{self.output[-2000:]}")
            ready, _, _ = select.select([self.fd], [], [], remaining)
            if ready:
                try:
                    chunk = os.read(self.fd, 4096)
                except OSError:
                    chunk = b""
                if not chunk:
                    raise AssertionError(f"terminal closed before {text!r}; got:\n{self.output[-2000:]}")
                self.output += chunk.decode("utf-8", "replace")
        self.mark = self.output.index(text, self.mark) + len(text)

    def send(self, text):
        os.write(self.fd, (text + "\r").encode())

    def finish(self, timeout=60):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            ready, _, _ = select.select([self.fd], [], [], 0.5)
            if ready:
                try:
                    chunk = os.read(self.fd, 4096)
                except OSError:
                    chunk = b""
                if not chunk:
                    break
                self.output += chunk.decode("utf-8", "replace")
            pid, _status = os.waitpid(self.pid, os.WNOHANG)
            if pid:
                self.pid = None
                break
        self.close()
        return self.output

    def close(self):
        if self.pid:
            os.kill(self.pid, signal.SIGKILL)
            os.waitpid(self.pid, 0)
            self.pid = None
        try:
            os.close(self.fd)
        except OSError:
            pass


class Prompts(unittest.TestCase):
    def setUp(self):
        self.temp = Path(tempfile.mkdtemp(prefix="anj-b2-pty-"))
        self.addCleanup(shutil.rmtree, self.temp, True)

    def terminal(self, *args, driver=DRIVER):
        terminal = Terminal([sys.executable, "-c", driver, *args])
        self.addCleanup(terminal.close)
        return terminal

    def test_guided_prompts_with_defaults_and_a_dry_run_that_asks_no_secret(self):
        from tests.vm_bootstrap_fakes import git_archive
        tar, commit = git_archive(self.temp)
        t = self.terminal("dry-run", str(tar))
        t.read_until("[1/7] Public hostname")                    # no token or topic question in a dry run
        t.read_until("cannot be changed later without starting over on a new data disk.")
        t.read_until("Public hostname [gateway.example.com]: ")
        t.send("")
        t.read_until("[2/7] Keep the DNS record up to date (DDNS)")
        t.read_until("Turn DDNS on? [Y/n]: ")
        t.send("")
        t.read_until("Zone ID (32 characters).")
        t.read_until("Cloudflare zone ID [00000000000000000000000000000000]: ")
        t.send("")
        t.read_until("[4/7] Household accounts")
        t.read_until("The FIRST name is you: it becomes the")
        t.read_until("Accounts [sam, alex]: ")
        t.send("sam, Alex!")                                     # invalid: asked again with the reason
        t.read_until("Enter distinct account names")
        t.read_until("Accounts [sam, alex]: ")
        t.send("sam, alex, kid")
        t.read_until("Admin: sam     Members: alex, kid     Correct? [Y/n]: ")
        t.send("")
        t.read_until("Home network [192.168.0.0/24]: ")
        t.send("")
        t.read_until("[6/7] Network")                            # off the VM host: asked, never the router by default
        t.read_until("Address to serve on (port 443) [10.77.11.10]: ")
        t.send("")
        t.read_until("Only ONE computer may log in to this server by SSH")
        t.read_until("reserve it in your router")
        t.read_until("Only address allowed to log in by SSH: ")
        t.send("")
        t.read_until("Enter one IPv4 address")
        t.read_until("Only address allowed to log in by SSH: ")
        t.send("10.77.11.1")
        t.read_until("[7/7] Time zone")
        t.read_until("Time zone [Europe/Paris]: ")
        t.send("")
        output = t.finish()
        self.assertIn("EXIT 0 EXECUTED 0", output)
        self.assertNotIn("input hidden", output)                 # a dry run asks for no secret
        self.assertNotIn("Start installing?", output)            # and starts nothing
        self.assertIn("accounts: user-add and account-set sam, alex, kid", output)
        self.assertIn("first admin: sam", output)
        self.assertIn(f"release {commit[:12]}", output)
        self.assertIn("Dry run: nothing is changed and no secret is asked.", output)
        self.assertIn("15 Pair the first device", output)

    def test_hidden_entries_are_typed_twice_never_echoed_and_land_0600(self):
        token = "scratch-" + "T" * 32                            # scratch values, never real ones
        topic = "scratch-topic-" + "Q" * 18
        target = self.temp / "cloudflare-dns-token"
        t = self.terminal("token", str(target))
        t.read_until("My Profile → API Tokens → Create Token")   # M8: what it is, where it lives, if lost
        t.read_until("if lost, create a new token in Cloudflare")
        t.read_until("Cloudflare API token (paste) (input hidden): ")
        t.send(token)
        t.read_until(f"received {len(token)} characters.")
        t.read_until("Type it again (input hidden): ")
        t.send(token + "x")                                      # a typo: both entries asked again
        t.read_until("The two entries differ; try again.")
        t.read_until("Cloudflare API token (paste) (input hidden): ")
        t.send(token)
        t.read_until("Type it again (input hidden): ")
        t.send(token)
        t.read_until("Checking with Cloudflare (read-only)")
        t.read_until("1) I already have a topic — type it")      # The VM host without a hand-off: typing is the default
        t.read_until("2) Create a new topic")
        t.read_until("Choose [1]: ")
        t.send("")
        t.read_until("Anyone who knows it can read your server's alerts")
        t.read_until("Topic (input hidden): ")
        t.send(topic)
        t.read_until("Type it again (input hidden): ")
        t.send(topic)
        t.read_until("Did it arrive on your phone? [Y/n]: ")
        t.send("n")
        t.read_until("Check the ntfy app is subscribed to scra…QQQQ on ntfy.sh.")
        t.read_until("--title \"VM host: test\"")                   # on the VM host: the VM host-side test too
        t.read_until("or type 'skip': ")
        t.send("")
        t.read_until("Did it arrive on your phone? [Y/n]: ")
        t.send("")
        output = t.finish()
        self.assertIn("FILES ", output)
        self.assertNotIn(token, output)                          # echo off: the terminal never shows it
        self.assertNotIn(topic, output)
        self.assertEqual(target.read_text(), token + "\n")
        self.assertEqual(oct(target.stat().st_mode & 0o777), "0o600")
        files = json.loads(output.split("FILES ", 1)[1].split(" TOPIC ")[0])
        self.assertEqual(files, [{"path": str(target), "sha256": "secret"},
                                 {"path": str(target.with_name("topic")), "sha256": "secret"}])
        self.assertIn(f"TOPIC {len(topic)} SOURCE typed TESTS [{len(topic)}, {len(topic)}]", output)


FLOW = "from tests.vm_bootstrap_flow import main; main()"


class WholeInstall(unittest.TestCase):
    """The guided install from the banner to the approved first device, through a real pty (the
    fakes are tests/vm_bootstrap_flow.py). ANJ_UX_TRANSCRIPT_DIR keeps each transcript."""

    def setUp(self):
        self.temp = Path(tempfile.mkdtemp(prefix="anj-ux-flow-"))
        self.addCleanup(shutil.rmtree, self.temp, True)

    def converse(self, scenario, script):
        t = Terminal([sys.executable, "-c", FLOW, str(self.temp), scenario])
        self.addCleanup(t.close)
        for wait, reply in script:
            t.read_until(wait, timeout=60)
            if reply is not None:
                t.send(reply(t.output) if callable(reply) else reply)
        output = t.finish(timeout=60)
        keep = os.environ.get("ANJ_UX_TRANSCRIPT_DIR")
        if keep:
            Path(keep).mkdir(parents=True, exist_ok=True)
            (Path(keep) / f"transcript-{scenario}.txt").write_text(output)
        self.assertIn("FLOW EXIT 0", output)
        return output, json.loads((self.temp / "report.json").read_text())

    @staticmethod
    def password_tail(output):
        return output.split("Backup password (restic):", 1)[1].split()[0][-6:]

    def assert_no_leak(self, output, report, shown=()):
        values = {"token": report["secrets"]["token"], "topic": report["secrets"]["topic"],
                  "restic": report["secrets"]["restic"]}
        for index, code in enumerate(report["secrets"]["codes"]):
            values[f"code{index}"] = code
            values[f"code{index}-grouped"] = "-".join(code[i:i + 4] for i in range(0, len(code), 4))
        argv = json.dumps([report["commands"], report["spawned"], report["gateway_calls"]])
        stored = json.dumps([report["evidence"], report["record"], report["files"], report["calls"]])
        self.assertTrue(report["evidence"])
        for name, value in values.items():
            if not value:
                continue
            self.assertNotIn(value, argv, f"{name} in an argument")
            self.assertNotIn(value, stored, f"{name} in the evidence, setup.json or the file list")
            if name not in shown:
                self.assertNotIn(value, output, f"{name} on the terminal")
        self.assertNotIn(report["secrets"]["codes"][-1], output)            # only the grouped form is shown
        self.assertEqual(output.count(values[f"code{len(report['secrets']['codes']) - 1}-grouped"]), 1)

    def test_halo_install_with_secrets_from_halo(self):
        output, report = self.converse("halo", [
            ("3. The Cloudflare API token for your domain (DNS edit) (copied from the VM host ✓).", None),
            ("Copied from the VM host into this setup's memory (kept on this server where only the setup account can "
             "read them): the Cloudflare DNS token and the ntfy alert topic.", None),
            ("Checking this machine …", None), ("ready ✓", None),
            ("[1/9] Public hostname", None), ("Public hostname [gateway.example.com]: ", ""),
            ("Turn DDNS on? [Y/n]: ", ""), ("Cloudflare zone ID [", ""),
            ("[4/9] Cloudflare API token", None), ("Use the Cloudflare token copied from the VM host? [Y/n]: ", ""),
            ("record gateway.example.com found (A, not proxied). ✓", None),
            ("[5/9] Alert topic for your phone (ntfy)", None),
            ("1) Use the topic copied from the VM host", None), ("Choose [1]: ", ""),
            ("Did it arrive on your phone? [Y/n]: ", ""),
            ("Accounts [sam, alex]: ", ""), ("Correct? [Y/n]: ", ""),
            ("Home network [192.168.0.0/24]: ", ""),
            ("(The VM host itself, where you are connected from: 10.77.10.1)", None), ("Keep these? [Y/n]: ", ""),
            ("Time zone [Europe/Paris]: ", ""),
            ("Ready to install:", None), ("Alerts        ntfy topic from the VM host (test ✓)", None),
            ("200 GiB  (blank — will be formatted, asks below)", None), ("Start installing? [Y/n]: ", ""),
            ("/dev/vdb   200 GiB   QEMU HARDDISK   no file system, no partitions", None),
            ("This erases it. [y/N]: ", "y"),
            ("[ 1/12] Installing system packages (Docker, Node, firewall tools) — usually 2–5 min", None),
            ("still working …", None), ("[12/12] Turning on security updates: done ✓", None),
            ("Set up encrypted backups now? You will save one password. [Y/n]: ", ""),
            ("your backups can ONLY be restored with this password.", None),
            ("type the LAST 6 characters of the password (input hidden): ", "wrong!"),
            ("That does not match; check your saved copy.", None),
            ("type the LAST 6 characters of the password (input hidden): ", self.password_tail),
            ("Backup password saved and confirmed.", None), ("Backups are set up", None),
            ("anj-cloud is installed and healthy.  gateway.example.com", None),
            ("Services      11 of 11 running (ddns idle between runs — normal)", None),
            ("Alerts: using the topic from the VM host — test alert received ✓.", None),
            ("What to do now, in order:", None), ("A. The VM host:", None), ("B. Backups:          set up ✓", None),
            ("C. Router:", None), ("D. First device:", None),
            ("VM host step — run in a terminal ON THE VM HOST", None), ("Issuer fingerprint (it must match", None),
            ("If they differ, stop", None),
            ("Server       https://gateway.example.com", None),
            ("pairs at once", None),
            ("Pair your first device (as sam, the admin)", None),
            ("Is the anj-cloud app open on that device?", None),
            ("Press Enter when ready, or type 'later': ", ""),
            ("Pairing code for sam:", None), ("(10 minutes),\r\n              one use only.", None),
            ("Waiting for the app to pair", None),
            # Decision #151: the gateway approves the redeemed code; nobody compares a fingerprint.
            ("The device asked to pair; the server is approving it", None),
            ("Paired: sam's device \"sam-laptop\".", None),
            ("Done. Saved in your password manager?   ☐ backup password", None),
            ("Check any time: sudo anj-cloud-setup status     Problems: sudo anj-cloud-setup doctor", None)])
        self.assert_no_leak(output, report, shown=("restic", "code0-grouped"))
        self.assertEqual(report["calls"]["cloudflare"][0]["host"], "gateway.example.com")
        self.assertEqual(len(report["calls"]["ntfy"]), 1)
        self.assertEqual(report["topic_file"].strip(), report["secrets"]["topic"])       # The VM host's topic, reused
        self.assertEqual([], [call for call in report["gateway_calls"] if call[0] == "approve"])   # approved by the gateway
        self.assertNotIn("the app should show", output)
        self.assertNotIn("Check approval", output)
        record = json.loads(report["record"])
        self.assertEqual(record["alerts"], {"source": "halo", "test": "received"})
        self.assertNotIn("Generate a new private alert topic", output)

    def test_household_install_new_topic_qr_and_lockout_guard(self):
        token = "household-" + "k" * 30
        output, report = self.converse("household", [
            ("Public hostname [gateway.example.com]: ", "home.example.org"),
            ("You typed home.example.org. Type it again to confirm: ", "home.example.orgg"),
            ("The two entries differ; enter the hostname again.", None),
            ("Public hostname [gateway.example.com]: ", "home.example.org"),
            ("Type it again to confirm: ", "home.example.org"),
            ("Turn DDNS on? [Y/n]: ", ""), ("Cloudflare zone ID [", ""),
            ("Cloudflare API token (paste) (input hidden): ", token), ("Type it again (input hidden): ", token),
            ("1) I already have a topic", None), ("2) Create a new topic", None), ("Choose [2]: ", ""),
            ("A new private topic will be created.", None),
            ("Accounts [sam, alex]: ", ""), ("Correct? [Y/n]: ", ""), ("Home network [192.168.0.0/24]: ", ""),
            ("[8/9] Network", None), ("Address to serve on (port 443) [192.168.1.20]: ", ""),
            ("(this session comes from 192.168.1.50)", None),
            ("Only address allowed to log in by SSH [192.168.1.50]: ", "192.168.1.1"),
            ("Stop: you are connected over SSH from 192.168.1.50, but the firewall would accept SSH only from "
             "192.168.1.1.", None), ("this server may have no password login to fall back on", None),
            ("or press Enter to use 192.168.1.50: ", ""),
            ("Time zone [Europe/Paris]: ", ""),
            ("Network       serve on 192.168.1.20:443, SSH only from 192.168.1.50", None),
            ("Start installing? [Y/n]: ", ""), ("This erases it. [y/N]: ", "y"),
            ("Alerts: subscribe your phone (ntfy)", None), ("Your alert topic:  ", None),
            ("Scan with your phone's camera to subscribe in the ntfy app:", None),
            ("Press Enter once subscribed to send a test alert (or type skip): ", ""),
            ("Did it arrive on your phone? [Y/n]: ", ""),
            ("Set up encrypted backups now? You will save one password. [Y/n]: ", "n"),
            ("Alerts: a new topic, subscribed above — test alert received ✓.", None),
            ("A. Backups:          ⚠ not set up: sudo anj-cloud-setup backup", None), ("B. Router:           forward TCP 443 from the internet to this server", None),
            ("Code         the pairing code", None),
            ("Is the anj-cloud app open on that device?", None), ("Press Enter when ready, or type 'later': ", "later"),
            ("Later: sudo anj-cloud-setup pair", None),
            ("Done. Saved in your password manager?   ☐ ntfy topic", None)])
        self.assertNotIn(token, output)
        self.assertNotIn("The VM host", output)                                      # a household has no the VM host
        self.assertNotRegex(output, r"\bVM\b|0600|readable by anj")             # plain words for a household
        self.assertNotRegex(output, r"#\d|decision|spec |python3 |backup\.py")      # no internal references
        self.assertIn(report["secrets"]["topic"], output)                     # created: shown once, on the terminal
        qrencode = [argv for argv in report["spawned"] if argv[0] == "qrencode"]
        self.assertEqual(qrencode, [["qrencode", "-t", "ANSIUTF8", "-m", "2"]])   # the link went in on stdin
        self.assertRegex(output, "[\u2580\u2584\u2588]")                       # the QR code's block characters
        self.assertEqual(report["secrets"]["codes"], [])                        # no code until asked for
        argv = json.dumps([report["commands"], report["spawned"]])
        stored = json.dumps([report["evidence"], report["record"], report["files"]])
        for value in (token, report["secrets"]["topic"]):
            self.assertNotIn(value, argv)
            self.assertNotIn(value, stored)
        record = json.loads(report["record"])
        self.assertEqual(record["answers"]["admin_ssh_source"], "192.168.1.50")
        self.assertEqual(record["answers"]["host"], "home.example.org")
        self.assertEqual(record["alerts"], {"source": "created", "test": "received"})


if __name__ == "__main__":
    unittest.main()
