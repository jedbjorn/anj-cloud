"""PR #45 review round 2, residual Lows R1-R3 (spec #21 bootstrap).

R3 runs the real System (not FakeSystem) with every file-changing call and every non-read-only
command turned into a recorded failure: a dry run on a complete install whose pm2-anj.service is
down must neither write nor spawn anything (no PM2 daemon, no prod.py, no apt run).
"""

import builtins
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

from deploy.vm import bootstrap, paths
from tests.vm_bootstrap_fakes import FakeFacts, FakeSystem, git_archive, write_answers

ROOT = Path(__file__).resolve().parent.parent
WRITE_FLAGS = os.O_WRONLY | os.O_RDWR | os.O_CREAT | os.O_TRUNC | os.O_APPEND

# Commands a dry run may run: each only reads. Anything else (pm2, prod.py, the operator CLI,
# npm, apt-get, unattended-upgrade, systemctl start/reload, docker exec, nft -f, mkfs ...) fails.
READ_ONLY = (
    ("systemctl", "is-active"), ("systemctl", "is-enabled"), ("systemctl", "is-system-running"), ("systemctl", "show"),
    ("nft", "list"), ("nft", "-c"), ("ss",), ("ip", "-j"), ("lsblk",), ("blkid",), ("wipefs", "--no-act"), ("findmnt",),
    ("timedatectl", "show"), ("sshd", "-T"), ("systemd-analyze",), ("dpkg-query",), ("dpkg", "--print-architecture"),
    ("apt-cache", "policy"), ("apt-config", "dump"), ("docker", "info"), ("docker", "ps"), ("docker", "inspect"),
    ("docker", "version"), ("docker", "compose", "version"), ("id",), ("getent",))
RENDERERS = ("deploy/ddns.py", "deploy/backup.py")     # pure renderers (stdin in, stdout out)


class DryRunIsStrictlyReadOnly(unittest.TestCase):
    def setUp(self):
        self.temp = Path(tempfile.mkdtemp(prefix="anj-b2-ro-"))
        self.addCleanup(shutil.rmtree, self.temp, True)
        self.tar, self.commit = git_archive(self.temp)
        # A complete install as the dry run finds it: state root, stack record, release tree.
        state = self.temp / "state"
        release = self.commit[:12]
        for directory in (state / "run", state / "bin", state / "secrets", state / "release" / release,
                          self.temp / "release" / release / "deploy"):
            directory.mkdir(parents=True)
        (self.temp / "release" / release / "deploy" / "prod.py").write_text("# staged\n")
        (state / "release" / release / "source.tar").write_bytes(self.tar.read_bytes())
        (self.temp / "release" / "current").symlink_to(release)
        stack = {"host": "gateway.example.com", "release": self.commit, "bind_address": "10.77.11.10",
                 "household_lan": "192.168.0.0/24"}
        (state / "stack.json").write_text(json.dumps(stack))
        (state / "setup.json").write_text(json.dumps({"first_invite": {"id": "i-1"}, "accounts": ["sam", "alex"]}))
        (state / "secrets" / "ntfy-topic").write_text("t" * 32 + "\n")
        self.answers = write_answers(self.temp, 'ddns = "off"\n')
        for target, name, value in (
                (paths, "STATE_ROOT", state), (paths, "STACK_CONFIG", state / "stack.json"),
                (paths, "RELEASE_DIR", state / "release"), (paths, "RELEASE_SOURCE_DIR", self.temp / "release"),
                (paths, "RELEASE_CURRENT", self.temp / "release" / "current"), (paths, "BIN_DIR", state / "bin"),
                (paths, "RUN_DIR", state / "run"), (paths, "SECRETS_DIR", state / "secrets"),
                (paths, "NTFY_TOPIC", state / "secrets" / "ntfy-topic"),
                (paths, "ALERT_COMMAND", state / "bin" / "anj-alert"),
                (bootstrap, "SETUP_RECORD", state / "setup.json"), (bootstrap, "OPS_CONFIG", state / "run" / "ops.json"),
                (bootstrap, "OPS_ECOSYSTEM", state / "ops" / "ecosystem.config.js")):
            patcher = mock.patch.object(target, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        self.violations = []

    # Guards ---------------------------------------------------------------------------------
    def refuse(self, what):
        self.violations.append(what)
        raise PermissionError(f"read-only test: {what}")

    def guarded(self, name, original, check=lambda *a, **k: True):
        def wrapper(*args, **kwargs):
            if check(*args, **kwargs):
                self.refuse(f"{name}{tuple(str(a) for a in args[:2])}")
            return original(*args, **kwargs)
        return wrapper

    def run_dry(self):
        real_run = subprocess.run
        real_open, real_os_open = builtins.open, os.open

        def command(argv, *args, input=None, env=None, **kwargs):
            argv = [str(part) for part in argv]
            if argv[0] == "python3" and any(part.endswith(RENDERERS) for part in argv) and \
                    ("pm2-app" in argv or "units" in argv):
                if (env or {}).get("PYTHONDONTWRITEBYTECODE") != "1":
                    self.violations.append("python child may write bytecode: " + " ".join(argv[:4]))
                return real_run(argv, *args, input=input, env=env, **kwargs)
            if not any(argv[:len(prefix)] == list(prefix) for prefix in READ_ONLY):
                self.violations.append("command: " + " ".join(argv[:4]))
                return subprocess.CompletedProcess(argv, 1, "", "refused by the read-only test")
            if argv[:2] == ["systemctl", "is-active"] and any(part.startswith("pm2-") for part in argv):
                return subprocess.CompletedProcess(argv, 3, "inactive\n", "")      # PM2 is down
            return subprocess.CompletedProcess(argv, 1, "", "")

        def writes_mode(file, mode="r", *args, **kwargs):
            # A file descriptor (subprocess pipes) creates nothing; a path opened to write does.
            return not isinstance(file, int) and any(flag in mode for flag in "wax+")

        out = io.StringIO()
        system = bootstrap.System(dry=True, out=out)
        guards = [mock.patch.object(subprocess, "run", command),
                  mock.patch.object(bootstrap, "https_reachable", lambda host, timeout=10: True),
                  mock.patch.object(bootstrap.socket, "getaddrinfo", lambda *a, **k: [()]),
                  mock.patch.object(builtins, "open", self.guarded("open", real_open, writes_mode)),
                  mock.patch.object(io, "open", self.guarded("open", real_open, writes_mode)),
                  mock.patch.object(os, "open", self.guarded("os.open", real_os_open,
                                                             lambda path, flags, *a, **k: bool(flags & WRITE_FLAGS)))]
        for name in ("replace", "rename", "mkdir", "makedirs", "unlink", "remove", "rmdir", "chmod", "chown",
                     "fchmod", "fchown", "symlink", "link", "truncate", "utime"):
            guards.append(mock.patch.object(os, name, self.guarded("os." + name, getattr(os, name))))
        for name in ("rmtree", "copyfile", "copy2", "move"):
            guards.append(mock.patch.object(shutil, name, self.guarded("shutil." + name, getattr(shutil, name))))
        for name in ("mkstemp", "mkdtemp", "NamedTemporaryFile", "TemporaryDirectory"):
            guards.append(mock.patch.object(tempfile, name, self.guarded("tempfile." + name, getattr(tempfile, name))))
        dont_write = sys.dont_write_bytecode
        sys.dont_write_bytecode = True
        try:
            for guard in guards:
                guard.start()
            try:
                code = bootstrap.main(["--dry-run", "--answers", str(self.answers), "--source", str(self.tar)],
                                      system=system, facts=FakeFacts(system), prompter=mock.Mock(), out=out)
            finally:
                for guard in reversed(guards):
                    guard.stop()
        finally:
            sys.dont_write_bytecode = dont_write
        return code, out.getvalue()

    def test_dry_run_on_a_complete_install_with_pm2_down_writes_and_spawns_nothing(self):
        code, text = self.run_dry()
        self.assertEqual(self.violations, [], text)
        self.assertIn("Dry run: nothing is changed", text)
        self.assertIn(code, (0, 1), text)
        self.assertRegex(text, r"(?m)^ 9 Stack\n   now:  to do: .*PM2 not running")
        self.assertRegex(text, r"(?m)^10 Operations apps\n   now:  to do: .*PM2 not running")

    def test_the_guards_catch_a_write_and_a_spawning_command(self):
        """The test itself: a dry run that wrote or ran pm2 would be reported."""
        original = bootstrap.Setup.dry_run

        def leaky(setup, preflight_failed):
            setup.system.read(["pm2", "jlist"])
            Path(paths.STATE_ROOT / "leak").write_text("x")
            return original(setup, preflight_failed)
        with mock.patch.object(bootstrap.Setup, "dry_run", leaky):
            with self.assertRaises(PermissionError):
                self.run_dry()
        self.assertEqual(self.violations[0], "command: pm2 jlist")
        self.assertTrue(self.violations[1].startswith("open("), self.violations)

    def test_children_of_a_dry_run_write_no_bytecode(self):
        system = bootstrap.System(dry=True)
        with mock.patch.object(subprocess, "run", lambda argv, **kw: subprocess.CompletedProcess(argv, 0, kw["env"], "")):
            _code, env, _err = system.read(["true"])
        self.assertEqual(env.get("PYTHONDONTWRITEBYTECODE"), "1")
        launcher = (ROOT / "deploy" / "vm" / "anj-cloud-setup").read_text()
        self.assertIn("sys.dont_write_bytecode = True", launcher)


class LiveListenerAndHost(unittest.TestCase):
    """R1: the live 443 listener is part of step 9's check and repair. R2: a changed host is
    refused after the data disk (adopt) or the restore makes the recorded one visible."""

    def setUp(self):
        self.temp = Path(tempfile.mkdtemp(prefix="anj-b2-r1-"))
        self.addCleanup(shutil.rmtree, self.temp, True)

    def patch(self, target, name, value):
        patcher = mock.patch.object(target, name, value)
        patcher.start()
        self.addCleanup(patcher.stop)

    def setup_for(self, argv, answers=None, **facts):
        system = FakeSystem(dry=False, out=io.StringIO())
        setup = bootstrap.Setup(bootstrap.parser().parse_args(argv), system=system,
                                facts=FakeFacts(system, **facts), out=io.StringIO())
        if answers is not None:
            setup.answers = answers
        return setup, system

    def stack_files(self, bind):
        release = "c" * 40
        stack = self.temp / "stack.json"
        stack.write_text(json.dumps({"host": "gateway.example.com", "release": release, "bind_address": bind,
                                     "household_lan": "192.168.0.0/24"}))
        firewall = self.temp / "firewall.nft"
        firewall.write_text(bootstrap.render_firewall(bind, "10.77.11.1"))
        (self.temp / "release" / release[:12]).mkdir(parents=True)
        (self.temp / "release" / release[:12] / "haproxy.cfg").write_text(f"frontend f\n    bind {bind}:443\n")
        self.patch(bootstrap.paths, "STACK_CONFIG", stack)
        self.patch(bootstrap.paths, "RELEASE_DIR", self.temp / "release")
        self.patch(bootstrap.paths, "EMERGENCY_STOP", self.temp / "emergency-stop")
        self.patch(bootstrap, "FIREWALL_FILE", firewall)
        return release

    @staticmethod
    def listener(*addresses):
        lines = "".join(f"LISTEN 0      4096     {address}:443      0.0.0.0:*\n" for address in addresses)
        return (0, lines, "")

    def test_the_live_listener_is_compared_not_only_the_rendered_file(self):
        self.stack_files("10.77.11.20")
        setup, system = self.setup_for([], answers={"start_stack": True})
        stack = json.loads(bootstrap.paths.STACK_CONFIG.read_text())
        step = bootstrap.Stack(setup)
        system.responses["ss -ltnH"] = self.listener("10.77.11.20")
        self.assertEqual(step.consistency(stack), [])
        system.responses["ss -ltnH"] = self.listener("10.77.11.10")    # HAProxy still on the old bind
        self.assertEqual(step.consistency(stack),
                         ["443 listener 10.77.11.10 is not 10.77.11.20 (HAProxy runs an old configuration)"])
        system.responses["ss -ltnH"] = (0, "", "")
        self.assertEqual(step.consistency(stack), ["nothing listens on 443"])
        system.responses["ss -ltnH"] = (1, "", "")
        self.assertEqual(step.consistency(stack), ["443 listener unreadable (ss)"])
        self.assertIn(["ss", "-ltnH", "sport = :443"], system.reads)

    def test_no_listener_is_expected_under_the_emergency_stop_or_without_the_stack(self):
        self.stack_files("10.77.11.20")
        setup, system = self.setup_for([], answers={"start_stack": False})
        stack = json.loads(bootstrap.paths.STACK_CONFIG.read_text())
        system.responses["ss -ltnH"] = (0, "", "")
        self.assertEqual(bootstrap.Stack(setup).consistency(stack), [])
        setup.answers = {"start_stack": True}
        (self.temp / "emergency-stop").write_text("")
        self.assertEqual(bootstrap.Stack(setup).consistency(stack), [])

    def test_an_interrupted_bind_change_restarts_haproxy_on_the_re_run(self):
        """Interrupted after prod.py setup/up, before `pm2 restart haproxy`: stack.json already
        holds the new address, so nothing looks changed; the live listener still shows the old one."""
        release = self.stack_files("10.77.11.20")
        answers = {"host": "gateway.example.com", "bind_address": "10.77.11.20", "household_lan": "192.168.0.0/24",
                   "accounts": ["sam"], "ddns": "off", "start_stack": True}
        setup, system = self.setup_for(["--answers", "/dev/null"], answers=answers)
        setup.mode = "adopt"
        setup.release = release
        system.responses["pm2 jlist"] = (0, json.dumps([{"name": "haproxy", "pm2_env": {"status": "online"}}]), "")
        system.responses["ss -ltnH"] = self.listener("10.77.11.10")
        self.patch(bootstrap, "TMPFILES_CONF", self.temp / "tmpfiles")
        self.patch(bootstrap, "SYSTEMD_DIR", self.temp / "systemd")
        (self.temp / "systemd").mkdir()
        (self.temp / "systemd" / "pm2-anj.service").write_text("")
        step = bootstrap.Stack(setup)
        self.assertNotIn("bind address changed", step.problems())
        self.assertIn("443 listener 10.77.11.10 is not 10.77.11.20 (HAProxy runs an old configuration)", step.problems())
        step.apply()
        commands = [" ".join(c["argv"]) for c in system.commands]
        up = [i for i, c in enumerate(commands) if c.endswith("prod.py up")]
        restart = commands.index("pm2 restart haproxy")
        self.assertTrue(up[0] < restart < up[1], commands)
        self.assertIn("HAProxy restarted onto the new bind address (listener was stale).", setup.notes)

    def test_a_current_listener_restarts_nothing(self):
        release = self.stack_files("10.77.11.20")
        answers = {"host": "gateway.example.com", "bind_address": "10.77.11.20", "household_lan": "192.168.0.0/24",
                   "accounts": ["sam"], "ddns": "off", "start_stack": True}
        setup, system = self.setup_for(["--answers", "/dev/null"], answers=answers)
        setup.mode = "adopt"
        setup.release = release
        system.responses["pm2 jlist"] = (0, json.dumps([{"name": "haproxy", "pm2_env": {"status": "online"}}]), "")
        system.responses["ss -ltnH"] = self.listener("10.77.11.20")
        self.patch(bootstrap, "TMPFILES_CONF", self.temp / "tmpfiles")
        self.patch(bootstrap, "SYSTEMD_DIR", self.temp / "systemd")
        (self.temp / "systemd").mkdir()
        (self.temp / "systemd" / "pm2-anj.service").write_text("")
        bootstrap.Stack(setup).apply()
        self.assertNotIn("pm2 restart haproxy", [" ".join(c["argv"]) for c in system.commands])

    def run_mode(self, argv, recorded_host):
        """adopt or restore with an answers file naming gateway.example.com; step 3 (or the
        restore) reveals a state root recorded for `recorded_host`."""
        state = self.temp / "state"
        self.patch(bootstrap.paths, "STATE_ROOT", state)
        self.patch(bootstrap.paths, "STACK_CONFIG", state / "stack.json")
        self.patch(bootstrap.paths, "CLOUDFLARE_TOKEN", state / "secrets" / "cloudflare-dns-token")
        self.patch(bootstrap.paths, "NTFY_TOPIC", state / "secrets" / "ntfy-topic")
        answers = write_answers(self.temp, 'ddns = "off"\nhost = "gateway.example.com"\n'
                                           'restic_password_file = "/run/anj-drill/p"\n')
        setup, _system = self.setup_for([*argv, "--answers", str(answers)])
        reached = []

        class Reveal(bootstrap.DataDisk if "--adopt-data" in argv else bootstrap.Restore):
            def state(self):
                return False, "not yet"

            def apply(self):
                (state / "secrets").mkdir(parents=True)
                (state / "secrets" / "ntfy-topic").write_text("t" * 32 + "\n")
                (state / "stack.json").write_text(json.dumps({"host": recorded_host}))

            def verify(self):
                return True, "visible"

        class Later(bootstrap.Release):
            def state(self):
                reached.append("later")
                return True, "x"

            def verify(self):
                return True, "x"
        self.patch(bootstrap.Setup, "step_list", lambda self: [Reveal(self), Later(self)])
        for name in ("summary", "write_evidence", "save_record", "sweep_first_code"):
            self.patch(bootstrap.Setup, name, lambda self, *a, **k: None)
        self.patch(bootstrap, "preflight", lambda *a, **k: [])
        self.patch(bootstrap.DataDisk, "needs_init", lambda self: False)
        return setup.run(), setup.out.getvalue(), reached

    def test_adopt_refuses_a_changed_host_once_the_disk_is_mounted(self):
        code, text, reached = self.run_mode(["--adopt-data"], "other.example.org")
        self.assertEqual(code, 1, text)
        self.assertIn("This server is set up for other.example.org", text)
        self.assertIn('Fix: Keep host = "other.example.org"', text)
        self.assertEqual(reached, [])

    def test_restore_refuses_a_changed_host_once_the_snapshot_is_restored(self):
        code, text, reached = self.run_mode(["--restore-from", "/mnt/anj-backup"], "other.example.org")
        self.assertEqual(code, 1, text)
        self.assertIn("needs a new server certificate", text)
        self.assertEqual(reached, [])

    def test_adopt_with_the_recorded_host_continues(self):
        code, text, reached = self.run_mode(["--adopt-data"], "gateway.example.com")
        self.assertEqual(code, 0, text)
        self.assertEqual(reached, ["later"])


class QualifyRows(unittest.TestCase):
    """deploy/vm/qualify.py round-3 rows offline: the in-VM leak search, log parsing, probes."""

    def setUp(self):
        from deploy.vm import qualify
        self.qualify = qualify
        self.temp = Path(tempfile.mkdtemp(prefix="anj-b2-qualrows-"))
        self.addCleanup(shutil.rmtree, self.temp, True)

    def test_every_in_vm_snippet_is_valid_shell(self):
        q = self.qualify
        for snippet in (q.DIGEST, q.STATE_DIGEST, q.PM2_DAEMONS, q.LEAK_SEARCH, q.NETNS_UP, q.NETNS_DOWN,
                        q.save_pattern(paths.FIRST_PAIRING_CODE, "install-code")):
            with self.subTest(snippet=snippet[:40]):
                result = subprocess.run(["bash", "-n", "-c", snippet], capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_leak_search_reports_found_and_clean_and_never_prints_a_secret(self):
        """The real snippet, run locally without sudo against stand-in places."""
        q = self.qualify
        secret_a, secret_b = "qual-topic-" + "x" * 24, "CODE-7731-QUAL"
        (self.temp / "secrets").mkdir()
        (self.temp / "secrets" / "a").write_text(secret_a + "\n")
        (self.temp / "secrets" / "b").write_text(secret_b + "\n")
        patterns = self.temp / "patterns"
        for label in ("a", "b"):
            saved = subprocess.run(["bash", "-c", q.save_pattern(self.temp / "secrets" / label, label, patterns=patterns,
                                                                 sudo="", owner="")], capture_output=True, text=True)
            self.assertEqual(saved.returncode, 0, saved.stderr)
        self.assertEqual((patterns / "a").read_text(), secret_a)          # newline stripped: no empty pattern
        self.assertEqual(oct(patterns.stat().st_mode & 0o777), "0o700")
        (self.temp / "logs").mkdir()
        (self.temp / "logs" / "app.log").write_text(f"enrolled with {secret_b} oops\n")
        (self.temp / "stream").write_text("nothing here\n")
        locations = {"logs": f'grep -rqsF -f "$f" {self.temp}/logs',
                     "stream": f'cat {self.temp}/stream | grep -qF -f "$f"'}
        command = q.leak_search_command(patterns=patterns, locations=locations, labels=("a", "b", "c"), sudo="")
        result = subprocess.run(["bash", "-c", command], capture_output=True, text=True)
        self.assertEqual(result.stdout.split("\n"), ["a logs 1", "a stream 1", "b logs 0", "b stream 1", "c - missing", ""])
        for secret in (secret_a, secret_b):
            self.assertNotIn(secret, result.stdout + result.stderr + command)

    def test_the_journal_check_never_reads_a_failing_producer_as_clean(self):
        """Review L-d: `journalctl | grep -q` without its exit codes passed when journalctl failed."""
        q = self.qualify
        patterns = self.temp / "p"
        patterns.mkdir()
        (patterns / "a").write_text("needle")
        # (The in-VM snippet is one single-quoted bash -c, so producers carry no single quotes.)
        for producer, expected in (("echo hay", "1"), ("echo a needle", "0"), ("false", "2"), ("yes needle", "0")):
            with self.subTest(producer=producer):
                command = q.leak_search_command(patterns=patterns, locations={"j": q.piped(producer)},
                                                labels=("a",), sudo="")
                result = subprocess.run(["bash", "-c", command], capture_output=True, text=True, timeout=30)
                self.assertEqual(result.stdout.split(), ["a", "j", expected], result.stderr)

    def test_l2_a_grep_error_is_an_error_not_clean(self):
        """Round 5 L2: grep exit 2 (here an unreadable pattern file) with a good producer was "clean"."""
        q = self.qualify
        patterns = self.temp / "p2"
        patterns.mkdir()
        (patterns / "a").write_text("needle")
        command = q.leak_search_command(patterns=patterns, locations={"j": q.piped("echo hay")}, labels=("a",),
                                        sudo="").replace('-f "$f"', '-f "$f.absent"')
        result = subprocess.run(["bash", "-c", command], capture_output=True, text=True, timeout=30)
        self.assertEqual(result.stdout.split(), ["a", "j", "2"], result.stderr)

    def test_container_readiness_needs_a_healthy_container_started_after_the_kill(self):
        answers = iter(["healthy 2026-11-03T20:00:10.123Z", "healthy 2026-11-03T19:59:00.123Z", "starting 2026-11-03T20:00:10Z"])
        qualification = self.qualification(lambda command, data=None, timeout=0: (0, next(answers), ""))
        since = 1_793_736_000                                   # 2026-11-03T20:00:00Z
        self.assertTrue(qualification.container_ready_since("c", since))
        self.assertFalse(qualification.container_ready_since("c", since))    # the old container
        self.assertFalse(qualification.container_ready_since("c", since))    # not healthy yet

    def qualification(self, ssh):
        qualification = self.qualify.Qualification("b2dev-test", "HEAD", self.temp / "evidence")
        qualification.evidence.mkdir(exist_ok=True)
        (qualification.evidence / "install.txt").write_text("output\n")
        qualification.ssh = ssh
        return qualification

    def test_leak_search_table_is_clean_only_when_complete_and_clean(self):
        labels, places = self.qualify.LEAK_LABELS, self.qualify.LEAK_LOCATIONS
        lines = "".join(f"{label} {place} 1\n" for label in labels for place in places)
        calls = []

        def ssh(command, data=None, timeout=0):
            calls.append((command, data))
            return (0, lines, "") if command == self.qualify.LEAK_SEARCH else (1, "", "")
        clean, table = self.qualification(ssh).leak_search()
        self.assertTrue(clean, table)
        self.assertEqual(set(table), set(labels))
        self.assertEqual(table["ntfy-topic"]["halo-evidence"], "clean")
        self.assertIn("output\n", [data for _command, data in calls])         # The VM host outputs are searched in the VM
        self.assertTrue((self.temp / "evidence" / "leak-search.json").exists())
        for broken in (lines.replace("ntfy-topic journal 1", "ntfy-topic journal 0"),
                       lines.replace("install-code journal 1", "install-code journal 2"),
                       "\n".join(line for line in lines.splitlines() if not line.startswith("reissued-code")),
                       lines.replace("scratch-token setup-log 1", "scratch-token - missing")):
            with self.subTest(broken=broken[-40:]):
                clean, _table = self.qualification(lambda command, data=None, timeout=0: (
                    (0, broken, "") if command == self.qualify.LEAK_SEARCH else (1, "", ""))).leak_search()
                self.assertFalse(clean)
        clean, table = self.qualification(lambda command, data=None, timeout=0: (
            (0, lines, "") if command == self.qualify.LEAK_SEARCH else (0, "", ""))).leak_search()
        self.assertFalse(clean)                                             # found in a host-side output
        self.assertEqual(table["install-code"]["halo-evidence"], "found")

    def test_log_events_restart_and_alert_counts(self):
        watchdog = "\n".join([
            '2026-11-03T20:00:00: {"app": "gateway", "event": "watchdog-restart", "result": "ok"}',
            '2026-11-03T20:00:01: {"event": "watchdog-alert", "key": "watchdog:restart:gateway", "queued": true}',
            '2026-11-03T20:05:00: {"app": "db", "event": "watchdog-restart", "result": "ok"}',
            "2026-11-03T20:06:00: not json {", ""])
        alerts = "\n".join([
            '2026-11-03T20:00:02: {"event": "alert-retry", "key": "watchdog:restart:gateway"}',
            '2026-11-03T20:00:09: {"event": "alert-sent", "key": "watchdog:restart:gateway", "title": "t"}', ""])
        qualification = self.qualification(lambda *a, **k: (1, "", ""))
        qualification.pm2_log = lambda app: {"watchdog": watchdog, "alerts": alerts}[app]
        self.assertEqual(qualification.watchdog_restarts("gateway"), 1)
        self.assertEqual(qualification.watchdog_restarts(), 2)
        self.assertEqual(qualification.watchdog_alerts(), {"watchdog:restart:gateway": 1})
        self.assertEqual(qualification.sent_alerts(), {"watchdog:restart:gateway": 1})    # a retry is not a delivery
        before = qualification.sent_alerts()
        self.assertEqual(self.qualify.delta(qualification.sent_alerts(), before), {})
        watchdog = "\n".join([
            '2026-11-03T20:00:00: {"app": "gateway", "event": "watchdog-restart", "time": "2026-11-03T19:00:00Z"}',
            '2026-11-03T20:00:01: {"event": "watchdog-alert", "key": "watchdog:cap:gateway", "time": "2026-11-03T19:30:00Z"}'])
        qualification.pm2_log = lambda app: watchdog
        self.assertEqual(qualification.restart_times("gateway"), [1_793_732_400.0])
        self.assertEqual(qualification.alert_times("watchdog:cap:gateway"), [1_793_734_200.0])

    def test_tcp_refused_tells_nothing_listening_from_listening(self):
        import socket
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            listener.listen()
            port = listener.getsockname()[1]
            self.assertFalse(self.qualify.tcp_refused("127.0.0.1", port))
        self.assertTrue(self.qualify.tcp_refused("127.0.0.1", port))

    def test_boot_health_result_reads_its_own_final_line(self):
        qualification = self.qualification(lambda *a, **k: (1, "", ""))
        qualification.boot_health = lambda: ('{"event": "boot-health-alert", "key": "boot-health", "queued": true}\n'
                                             '{"emergency_stop_stated": true, "event": "boot-health", "failures": [], '
                                             '"result": "healthy", "time": "x"}\n')
        self.assertEqual(qualification.boot_health_result()["emergency_stop_stated"], True)

    def test_every_self_attribute_qualify_uses_exists(self):
        """b2dev-8 aborted with AttributeError: a rewrite had dropped boot_health()."""
        import ast
        tree = ast.parse((ROOT / "deploy" / "vm" / "qualify.py").read_text())
        cls = next(node for node in tree.body if isinstance(node, ast.ClassDef) and node.name == "Qualification")
        targets = [element for node in ast.walk(cls) for target in getattr(node, "targets", [])
                   for element in (target.elts if isinstance(target, ast.Tuple) else [target])]
        assigned = {target.attr for target in targets
                    if isinstance(target, ast.Attribute) and isinstance(target.value, ast.Name) and target.value.id == "self"}
        used = {node.attr for node in ast.walk(cls) if isinstance(node, ast.Attribute)
                and isinstance(node.value, ast.Name) and node.value.id == "self"}
        missing = sorted(name for name in used - assigned if not hasattr(self.qualify.Qualification, name))
        self.assertEqual(missing, [])

    def test_rows_end_with_the_final_leak_sweep_and_take_an_evidence_directory(self):
        self.assertEqual(self.qualify.Qualification.ROWS[-1], "leaks")
        for row in ("status_doctor", "enrol", "killed_containers", "updates", "ddns", "first_admin", "hung_gateway",
                    "watchdog_quiet", "watchdog_cap", "reboot_emergency"):
            self.assertTrue(callable(getattr(self.qualify.Qualification, "row_" + row)))
        self.assertIn('"--evidence"', (ROOT / "deploy" / "vm" / "qualify.py").read_text())


class DebianDockerPackages(unittest.TestCase):
    def test_the_docker_cli_is_installed_explicitly(self):
        """anj-qual b2dev-2: Debian 13's docker.io only Recommends docker-cli; with
        --no-install-recommends /usr/bin/docker was missing and step 1 failed to verify."""
        self.assertIn("docker-cli", bootstrap.DEBIAN_DOCKER)
        system = FakeSystem(dry=True, out=io.StringIO())
        setup = bootstrap.Setup(bootstrap.parser().parse_args(["--dry-run"]), system=system,
                                facts=FakeFacts(system, candidate={"docker.io": "26.1.5+dfsg1-9+deb13u1",
                                                                   "docker-compose": "2.26.1-4"}), out=io.StringIO())
        step = bootstrap.Packages(setup)
        self.assertIn("docker-cli", step.wanted(step.docker_choice()))
        self.assertIn("docker-cli", step.state()[1])           # missing until installed


class NoBytecodeInTheStateTree(unittest.TestCase):
    """anj-qual b2dev-3: run-service (PM2, from state/bin) wrote state/bin/__pycache__ (0755), and
    prod.py's private-tree check then refused every up/status/check."""

    def test_state_bin_scripts_import_their_siblings_without_writing_bytecode(self):
        temp = Path(tempfile.mkdtemp(prefix="anj-b2-pyc-"))
        self.addCleanup(shutil.rmtree, temp, True)
        for name, source in (("run-service", ROOT / "deploy/vm/run-service"), ("anj-alert", ROOT / "deploy/vm/ops/anj-alert"),
                             ("paths.py", ROOT / "deploy/vm/paths.py"), ("stackenv.py", ROOT / "deploy/vm/stackenv.py")):
            shutil.copy(source, temp / name)
        environment = {key: value for key, value in os.environ.items() if key != "PYTHONDONTWRITEBYTECODE"}
        for script in ("run-service", "anj-alert"):
            result = subprocess.run([sys.executable, "-I", str(temp / script), "--help"], capture_output=True,
                                    text=True, timeout=60, env=environment, cwd=temp)
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((temp / "__pycache__").exists())

    def test_the_stack_ecosystem_disables_bytecode(self):
        from deploy.vm import render
        text = render.ecosystem(state_root=Path("/srv/anj-cloud/state"))
        apps = json.loads(text[text.index("{"):text.rindex("}") + 1])["apps"]
        self.assertTrue(all(app["env"].get("PYTHONDONTWRITEBYTECODE") == "1" for app in apps))


class Pm2Banner(unittest.TestCase):
    """anj-qual b2dev-4: the first `pm2 jlist` (daemon spawn) printed PM2's banner before the JSON
    and prod.py up failed with "Expecting value: line 2 column 25"."""

    BANNER = ("\n                        -------------\n\n__/\\\\\\\\\\\\\\_____/\\\\____________/\\\\\n"
              "[PM2] Spawning PM2 daemon with pm2_home=/home/anj/.pm2\n[PM2] PM2 Successfully daemonized\n")

    def test_jlist_rows_skips_the_spawn_banner(self):
        from deploy.vm.pm2json import jlist_rows
        rows = [{"name": "db", "pm2_env": {"status": "online", "restart_time": 2}}]
        with self.assertRaises(ValueError):
            json.loads(self.BANNER + json.dumps(rows))
        self.assertEqual(jlist_rows(self.BANNER + json.dumps(rows) + "\n"), rows)
        self.assertEqual(jlist_rows((self.BANNER + "[]\n").encode()), [])
        self.assertEqual(jlist_rows(""), [])
        with self.assertRaises(ValueError):
            jlist_rows(self.BANNER)

    def test_every_jlist_reader_uses_it(self):
        for path in ("deploy/prod.py", "deploy/backup.py", "deploy/vm/bootstrap.py", "deploy/vm/ops/vmops.py",
                     "deploy/vm/qualify.py"):
            text = (ROOT / path).read_text()
            self.assertIn("jlist_rows(", text, path)

    def test_vmops_reads_rows_after_a_banner(self):
        sys.path.insert(0, str(ROOT / "deploy" / "vm" / "ops"))
        import vmops

        class Runner:
            def run(self, argv, **_kw):
                return 0, Pm2Banner.BANNER + json.dumps([{"name": "db", "pm2_env": {"status": "online"}}]), ""
        self.assertEqual(vmops.pm2_apps(Runner())["db"]["status"], "online")


class UnattendedUpgradeOrigins(unittest.TestCase):
    def test_both_output_formats(self):
        """anj-qual b2dev-5: Debian 13's 2.12 joins the origins with ", "; older versions print a list."""
        new = ("Allowed origins are: origin=Debian,codename=trixie-security,label=Debian-Security, "
               "origin=Debian,codename=trixie,label=Debian-Security\nInitial blacklist: \n")
        old = "Allowed origins are: ['origin=Debian,codename=trixie-security,label=Debian-Security']\n"
        self.assertEqual(bootstrap.allowed_origins(new), [("Debian", "Debian-Security"), ("Debian", "Debian-Security")])
        self.assertEqual(bootstrap.allowed_origins(old), [("Debian", "Debian-Security")])
        wide = "Allowed origins are: origin=Debian,codename=trixie,label=Debian, origin=Debian,label=Debian-Security\n"
        self.assertEqual({label for _o, label in bootstrap.allowed_origins(wide)}, {"Debian", "Debian-Security"})
        self.assertEqual(bootstrap.allowed_origins("nothing"), [])
