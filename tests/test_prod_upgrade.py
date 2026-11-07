"""Decision #122: production release updates without git in the VM.

prod.py redeploy --source <tar>, anj-cloud-setup upgrade / upgrade --rollback and
deploy/vm/stage.py --upgrade. Offline: two commits of a throwaway git repository are the releases,
PM2 and the stack are stubs, and FakeSystem stands in for the machine (only the release extraction
really runs). The VM proof is qualify.py's `upgrade` row on anj-qual.
"""

import contextlib
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import tarfile
import tempfile
import unittest
from unittest import mock

from deploy import prod
from deploy.vm import bootstrap, local_upgrade, paths, stage
from tests.vm_bootstrap_fakes import FakeFacts, FakeSystem

ROOT = Path(__file__).resolve().parent.parent
HOST = "family.upgrade.test"
COMMIT_ENV = {"GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.invalid", "GIT_COMMITTER_NAME": "t",
              "GIT_COMMITTER_EMAIL": "t@example.invalid", "GIT_CONFIG_GLOBAL": "/dev/null"}


def git(repository, *args):
    return subprocess.run(["git", "-C", str(repository), *args], capture_output=True, text=True, check=True,
                          env=dict(os.environ, **COMMIT_ENV)).stdout.strip()


def make_releases(directory, *, new_has_source=True, old_has_source=False):
    """A git repository with releases A then B; returns (repository, {"a": sha, "b": sha})."""
    repository = Path(directory) / "repo"
    repository.mkdir()
    git(repository, "init", "-q", "-b", "main")
    commits = {}
    for name, has_source, alert in (("a", old_has_source, "old dispatcher\n"), ("b", new_has_source, "new dispatcher\n")):
        (repository / "deploy" / "vm" / "ops").mkdir(parents=True, exist_ok=True)
        (repository / "deploy" / "prod.py").write_text(f"# release {name}\n" + ("# redeploy --source\n" if has_source else ""))
        (repository / "deploy" / "vm" / "ops" / "anj-alert").write_text(alert)
        for member in prod.BIN_FILES:
            (repository / member).write_text(f"# {member} of release {name}\n")
        if has_source:
            (repository / "deploy" / "vm" / "bootstrap.py").write_text('choices = ("install", "upgrade")\n')
        git(repository, "add", "-A")
        git(repository, "commit", "-q", "-m", name)
        commits[name] = git(repository, "rev-parse", "HEAD")
    return repository, commits


def archive(repository, commit, path):
    with open(path, "wb") as stream:
        subprocess.run(["git", "-C", str(repository), "archive", "--format=tar", commit], stdout=stream, check=True)
    return Path(path)


# prod.py redeploy --source ---------------------------------------------------------------------

class RedeploySourceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.temp = Path(self.temporary.name)
        self.repository, self.commits = make_releases(self.temp)
        self.tar_b = archive(self.repository, self.commits["b"], self.temp / "b.tar")
        self.stack = prod.ProdStack("anj-cloud-test-prod", self.temp / "data" / "state")
        self.stack.save_config(host=HOST, release=self.commits["a"], bind_address="10.77.10.10",
                               household_lan="192.168.0.0/24", vm_gid=os.getgid())
        self.alerts = []

    def tearDown(self):
        self.temporary.cleanup()

    def patched(self, **extra):
        stack = self.stack
        defaults = dict(preflight_runtime_dirs={"return_value": None},
                        resolve_commit={"side_effect": AssertionError("--source never looks up git")},
                        build={"return_value": "image"}, export_release={"return_value": None},
                        verify_release={"return_value": True}, activate_release={"return_value": None},
                        install_bin={"return_value": None},
                        restart_stack={"return_value": None}, ensure_tls_fresh={"return_value": False},
                        check={"return_value": {"checked": True}},
                        restart_release_ops={"return_value": {"console": "restarted", "watchdog": "restarted"}},
                        pm2={"return_value": ""},
                        alert={"side_effect": lambda key, *a, **k: self.alerts.append((key, a[1])) or "dispatcher"})
        defaults.update(extra)
        context = contextlib.ExitStack()
        for name, value in defaults.items():
            context.enter_context(mock.patch.object(stack, name, **value))
        return context

    def test_tar_commit_reads_the_git_archive_header_and_refuses_other_tars(self):
        self.assertEqual(self.commits["b"], prod.ProdStack.tar_commit(self.tar_b))
        plain = self.temp / "plain.tar"
        with tarfile.open(plain, "w") as archive_file:
            archive_file.add(self.repository / "deploy" / "prod.py", arcname="deploy/prod.py")
        self.assertIsNone(prod.ProdStack.tar_commit(plain))
        (self.temp / "junk.tar").write_bytes(b"not a tar")
        self.assertIsNone(prod.ProdStack.tar_commit(self.temp / "junk.tar"))

    def test_adopt_source_installs_the_tar_privately_and_checks_its_commit(self):
        full = self.stack.adopt_source(None, self.tar_b)
        self.assertEqual(self.commits["b"], full)
        target = self.stack.release_dir(full) / "source.tar"
        self.assertEqual(self.tar_b.read_bytes(), target.read_bytes())
        self.assertEqual(0o600, stat.S_IMODE(target.stat().st_mode))
        self.assertEqual(0o700, stat.S_IMODE(target.parent.stat().st_mode))
        prod.check_private_tree(self.stack.local)
        self.assertEqual(full, self.stack.adopt_source(full[:12], self.tar_b))       # again: kept, no error
        with self.assertRaisesRegex(RuntimeError, "not " + self.commits["a"][:12]):
            self.stack.adopt_source(self.commits["a"][:12], self.tar_b)
        with self.assertRaisesRegex(RuntimeError, "not a tar made with `git archive"):
            self.stack.adopt_source(None, self.temp / "missing.tar")
        # A source.tar already there for that commit must be that release.
        tar_a = archive(self.repository, self.commits["a"], self.temp / "a.tar")
        shutil.copy(tar_a, target)
        with self.assertRaisesRegex(RuntimeError, "is not release"):
            self.stack.adopt_source(None, self.tar_b)

    def test_redeploy_with_source_needs_no_git_and_switches_after_a_healthy_check(self):
        with self.patched():
            result = self.stack.redeploy(None, source=str(self.tar_b))
            self.stack.activate_release.assert_called_once_with(self.commits["b"])
        self.assertEqual(self.commits["b"], self.stack.release)
        self.assertEqual(self.commits["a"], self.stack.config["previous_release"])
        self.assertEqual(self.commits["a"][:12], result["previous_release"])
        self.assertEqual([], self.alerts)

    def test_failed_health_check_does_not_switch_and_alerts_once(self):
        with self.patched(check={"side_effect": RuntimeError("Gateway healthcheck is not ready")}):
            with self.assertRaisesRegex(RuntimeError, "release/current stays on " + self.commits["a"][:12]):
                self.stack.redeploy(self.commits["b"], source=str(self.tar_b))
            self.stack.activate_release.assert_not_called()
            self.assertEqual(2, self.stack.restart_stack.call_count)       # onto the new release, then back
        self.assertEqual(self.commits["a"], self.stack.release)
        self.assertNotIn("previous_release", self.stack.config)
        self.assertEqual(1, len(self.alerts))
        key, message = self.alerts[0]
        self.assertEqual("redeploy-failed", key)
        self.assertIn("Gateway healthcheck is not ready", message)
        self.assertIn(self.commits["a"][:12], message)

    def test_failed_build_or_verification_restarts_nothing_and_alerts(self):
        with self.patched(verify_release={"side_effect": RuntimeError("Release b is missing haproxy.cfg")}):
            with self.assertRaisesRegex(RuntimeError, "missing haproxy.cfg"):
                self.stack.redeploy(None, source=str(self.tar_b))
            self.stack.restart_stack.assert_not_called()
        self.assertEqual(self.commits["a"], self.stack.release)
        self.assertEqual(["redeploy-failed"], [key for key, _ in self.alerts])
        self.assertIn("nothing was restarted", self.alerts[0][1])

    def real_bin(self):
        return {"side_effect": prod.ProdStack.install_bin.__get__(self.stack)}

    def write_bin(self, release):
        (self.stack.local / "bin").mkdir(mode=0o700, exist_ok=True)
        for member, name in prod.BIN_FILES.items():
            (self.stack.local / "bin" / name).write_text(f"# {member} of release {release}\n")

    def bin_text(self):
        return {name: (self.stack.local / "bin" / name).read_text() for name in prod.BIN_FILES.values()}

    def test_ctrl_c_during_the_restarts_falls_back_and_alerts(self):
        """The reviewer's H1 probe: KeyboardInterrupt from the first restart_stack."""
        self.write_bin("a")
        calls = []

        def restart():
            calls.append((self.stack.release[:12], self.bin_text()["run-service"]))
            if len(calls) == 1:
                raise KeyboardInterrupt()
        with self.patched(restart_stack={"side_effect": restart}, install_bin=self.real_bin()), \
                contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaisesRegex(RuntimeError, r"failed \(interrupted \(SIGINT\)\); release/current stays on "
                                                      + self.commits["a"][:12] + r", restarted on .* \(alert: dispatcher\)"):
                self.stack.redeploy(None, source=str(self.tar_b))
            self.stack.activate_release.assert_not_called()
        b, a = self.commits["b"][:12], self.commits["a"][:12]
        # Review M2: B's wrapper ran the health-checked restarts; A's came back for the fallback.
        self.assertEqual([(b, "# deploy/vm/run-service of release b\n"), (a, "# deploy/vm/run-service of release a\n")],
                         calls)
        self.assertEqual(self.commits["a"], json.loads(self.stack.config_path.read_text())["release"])
        self.assertEqual("# deploy/vm/run-service of release a\n", self.bin_text()["run-service"])
        self.assertEqual(["redeploy-failed"], [key for key, _ in self.alerts])
        self.assertIn("interrupted (SIGINT)", self.alerts[0][1])

    def test_sigterm_and_sighup_during_the_restarts_fall_back_and_the_fallback_ignores_ctrl_c(self):
        import signal as signals
        for number in (signals.SIGTERM, signals.SIGHUP):
            self.alerts.clear()
            self.stack.save_config(release=self.commits["a"])
            calls = []

            def restart():
                calls.append(self.stack.release[:1])
                if len(calls) == 1:
                    signals.raise_signal(number)          # setup's timeout, or the session hanging up
                else:
                    os.kill(os.getpid(), signals.SIGINT)  # a second Ctrl-C during the fallback: ignored
            real_detail = prod.ProdStack.failure_detail

            def duplicate(error, number=number):
                signals.raise_signal(number)              # a forwarded duplicate before the fallback (D1)
                return real_detail(error)
            with self.subTest(signal=number.name), self.patched(restart_stack={"side_effect": restart},
                                                                failure_detail={"side_effect": duplicate}), \
                    contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaisesRegex(RuntimeError, rf"interrupted \({number.name}\)"):
                    self.stack.redeploy(None, source=str(self.tar_b))
            self.assertEqual(2, len(calls))
            self.assertEqual(self.commits["a"], self.stack.release)
            self.assertEqual(["redeploy-failed"], [key for key, _ in self.alerts])
        self.assertIs(signals.getsignal(signals.SIGTERM), signals.SIG_DFL)   # handlers restored afterwards
        self.assertIs(signals.getsignal(signals.SIGINT), signals.default_int_handler)

    def test_an_interrupted_build_restarts_nothing_and_alerts(self):
        with self.patched(build={"side_effect": KeyboardInterrupt()}), contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaisesRegex(RuntimeError, r"interrupted \(SIGINT\); nothing was restarted"):
                self.stack.redeploy(None, source=str(self.tar_b))
            self.stack.restart_stack.assert_not_called()
        self.assertEqual(self.commits["a"], self.stack.release)
        self.assertEqual(["redeploy-failed"], [key for key, _ in self.alerts])

    def test_a_failed_activation_after_the_check_falls_back_consistently(self):
        """Review L3: never stack.json on B with release/current on A."""
        root = self.stack.source_root
        root.mkdir()
        (root / self.commits["a"][:12]).mkdir()
        (root / "current").symlink_to(self.commits["a"][:12])
        with self.patched(activate_release={"side_effect": OSError("No space left on device")}), \
                contextlib.redirect_stderr(io.StringIO()) as err:
            with self.assertRaisesRegex(RuntimeError, r"failed \(OSError\)"):
                self.stack.redeploy(None, source=str(self.tar_b))
            self.assertEqual(2, self.stack.restart_stack.call_count)
        self.assertEqual(self.commits["a"], self.stack.release)
        self.assertEqual(self.commits["a"][:12], os.readlink(root / "current"))
        self.assertNotIn("previous_release", self.stack.config)
        self.assertIn("ALERT: redeploy-failed dispatcher", err.getvalue())

    def test_the_operations_lock_keeps_backups_restores_and_redeploys_apart(self):
        import fcntl
        run = self.stack.local / "run"
        run.mkdir(mode=0o700, exist_ok=True)
        for name, message in (("backup.lock", "operations lock"), ("restore.lock", "A restore is running")):
            with self.subTest(lock=name), open(run / name, "w") as held:
                fcntl.flock(held, fcntl.LOCK_EX)
                with self.patched(), self.assertRaisesRegex(RuntimeError, message):
                    self.stack.redeploy(None, source=str(self.tar_b))
                    self.stack.restart_stack.assert_not_called()
        held_inside = []
        with self.patched(restart_stack={"side_effect": lambda: held_inside.append(prod.lock_held(run / "backup.lock"))}):
            self.stack.redeploy(None, source=str(self.tar_b))
        self.assertEqual([True], held_inside)
        self.assertFalse(prod.lock_held(run / "backup.lock"))

    def test_the_live_release_is_the_fallback_after_an_interrupted_run(self):
        """stack.json may name a release that never went live (a killed run); release/current wins."""
        live = self.stack.release_dir(self.commits["a"])
        live.mkdir(parents=True, mode=0o700)
        (live / "release.json").write_text(json.dumps({"commit": self.commits["a"]}))
        self.stack.source_root.mkdir()
        (self.stack.source_root / "current").symlink_to(self.commits["a"][:12])
        self.stack.save_config(release="c" * 40)
        self.assertEqual(self.commits["a"], self.stack.live_release())
        with self.patched():
            self.stack.redeploy(None, source=str(self.tar_b))
        self.assertEqual(self.commits["a"], self.stack.config["previous_release"])

    def test_cli_takes_source_without_a_commit_and_refuses_neither(self):
        args = prod.parser().parse_args(["redeploy", "--source", "/x.tar"])
        self.assertEqual((None, "/x.tar"), (args.commit, args.source))
        with mock.patch.object(prod, "refuse_root"), mock.patch.object(prod, "ProdStack"), \
                contextlib.redirect_stderr(io.StringIO()) as err:
            self.assertEqual(1, prod.main(["redeploy"]))
        self.assertIn("redeploy needs a commit, or --source", err.getvalue())


# anj-cloud-setup upgrade -------------------------------------------------------------------------

class UpgradeSystem(FakeSystem):
    """FakeSystem that really extracts a release (as the test user) and answers prod.py redeploy
    the way the real one ends: stack.json and release/current switched, or an ERROR line."""

    def __init__(self, test, **options):
        super().__init__(dry=False, **options)
        self.test = test
        self.detached_calls = []
        self.backup_detached = []

    def change(self, argv, *, user=None, timeout=1800, data=None, cwd=None, show_errors=False, check=True):
        argv = [str(a) for a in argv]
        self.commands.append({"argv": argv, **({"user": user} if user else {})})
        self.events.append(("run", " ".join(argv)))
        if argv[:3] == ["python3", "-I", "-c"]:
            result = subprocess.run(argv, capture_output=True, text=True, check=False)
            return result.returncode, result.stdout, result.stderr
        if len(argv) > 3 and argv[2].endswith("deploy/backup.py") and argv[-1] == "run":
            return self.test.backup_run
        return 0, "", ""

    def detached(self, argv, *, user=None, cwd=None, timeout=3600, grace=1800, logs=None):
        argv = [str(a) for a in argv]
        self.commands.append({"argv": argv, **({"user": user} if user else {})})
        self.detached_calls.append({"timeout": timeout, "grace": grace, "logs": [str(p) for p in logs]})
        if len(argv) > 3 and argv[2].endswith("deploy/backup.py"):
            self.backup_detached.append(argv)
            return self.test.backup_run
        if self.test.detached_raises:
            raise self.test.detached_raises
        return self.test.redeploy(argv, user, cwd)

    def read(self, argv, *, user=None, timeout=120, data=None, cwd=None):
        argv = [str(a) for a in argv]
        if len(argv) > 3 and argv[2].endswith("deploy/backup.py") and argv[3] == "status":
            return 0, json.dumps(self.test.backup_status), ""
        return super().read(argv, user=user, timeout=timeout, data=data, cwd=cwd)


class UpgradeTests(unittest.TestCase):
    def setUp(self):
        # The extraction runs as anj through runuser (umask 022 there); other test modules may
        # leave a tighter umask in this process.
        self.addCleanup(os.umask, os.umask(0o022))
        self.temporary = tempfile.TemporaryDirectory()
        self.temp = Path(self.temporary.name)
        self.repository, self.commits = make_releases(self.temp)
        a, b = self.commits["a"], self.commits["b"]
        data = self.temp / "srv"
        self.state = data / "state"
        self.sources = data / "release"
        self.stage_dir = self.temp / "var-lib-anj-cloud-setup"
        self.staged_src = self.stage_dir / "src"
        for directory in (self.state / "release", self.state / "bin", self.sources, self.staged_src):
            directory.mkdir(parents=True)
        archive(self.repository, b, self.stage_dir / "source.tar")
        # Release A is installed and live, as the bootstrap left it.
        tar_a = self.state / "release" / a[:12] / "source.tar"
        tar_a.parent.mkdir()
        archive(self.repository, a, tar_a)
        subprocess.run(["python3", "-I", "-c", bootstrap.EXTRACT_SCRIPT, str(tar_a), str(self.sources / a[:12])], check=True)
        (self.sources / "current").symlink_to(a[:12])
        (self.state / "release" / a[:12] / "release.json").write_text(json.dumps({"commit": a}))
        (self.state / "bin" / "anj-alert").write_text("old dispatcher\n")
        self.write_stack(release=a)
        (self.state / "setup.json").write_text(json.dumps({"answers": {"host": HOST, "ddns": "off"},
                                                           "accounts": ["sam"], "release": a}))
        self.redeploys = []
        self.redeploy_result = "ok"
        self.detached_raises = None
        self.backup_status = {}
        self.backup_run = (0, "{}", "")
        (self.state / "run").mkdir()
        self.out = io.StringIO()
        patches = [mock.patch.multiple(paths, STATE_ROOT=self.state, STACK_CONFIG=self.state / "stack.json",
                                       RELEASE_DIR=self.state / "release", RELEASE_SOURCE_DIR=self.sources,
                                       RELEASE_CURRENT=self.sources / "current", BIN_DIR=self.state / "bin",
                                       ALERT_COMMAND=self.state / "bin" / "anj-alert",
                                       SETUP_LOG_DIR=self.state / "setup-log", RUN_DIR=self.state / "run",
                                       OPS_LOCK=self.state / "run" / "backup.lock",
                                       RESTORE_LOCK=self.state / "run" / "restore.lock",
                                       BACKUP_IN_PROGRESS=self.state / "run" / "backup-in-progress",
                                       RESTORE_IN_PROGRESS=self.state / "run" / "restore-in-progress",
                                       BACKUP_RECORD=self.state / "backup.json"),
                   mock.patch.multiple(bootstrap, SETUP_RECORD=self.state / "setup.json", STAGE_DIR=self.stage_dir,
                                       STAGE_TAR=self.stage_dir / "source.tar", STAGE_SRC=self.staged_src,
                                       ROOT=self.staged_src, UPGRADE_LOCK=self.temp / "upgrade.lock",
                                       COMMAND_LINK=self.temp / "no-link", FALLBACK_LOG_DIR=self.temp / "log",
                                       UPGRADE_LOG_DIR=self.temp / "log"),
                   mock.patch.object(bootstrap.os, "geteuid", return_value=0),
                   mock.patch.object(bootstrap, "pm2_list", return_value={"alerts": "online", "console": "online"})]
        for item in patches:
            item.start()
            self.addCleanup(item.stop)
        self.addCleanup(self.temporary.cleanup)

    def write_stack(self, **changes):
        path = self.state / "stack.json"
        stack = json.loads(path.read_text()) if path.exists() else {"host": HOST, "bind_address": "10.77.10.10"}
        stack.update(changes)
        path.write_text(json.dumps(stack))

    def redeploy(self, argv, user, cwd):
        """prod.py redeploy as it ends: a switch on success, nothing on failure."""
        self.redeploys.append({"argv": argv, "user": user, "cwd": cwd})
        commit, source = argv[3], argv[argv.index("--source") + 1]
        stack = json.loads((self.state / "stack.json").read_text())
        if self.redeploy_result == "unhealthy":
            return 1, "", "ALERT: redeploy-failed dispatcher\n" \
                          f"ERROR: Redeploy of {commit[:12]} failed (Gateway healthcheck is not ready); release/current " \
                          f"stays on {stack['release'][:12]}, restarted on {stack['release'][:12]} (alert: dispatcher)\n"
        if self.redeploy_result == "refused":
            return 1, "", "ERROR: A backup or another redeploy holds the operations lock (backup.lock)\n"
        if self.redeploy_result == "timeout":
            return 124, "", ""
        self.assertEqual(commit, prod.ProdStack.tar_commit(source))
        previous = stack["release"]
        self.write_stack(release=commit, previous_release=previous)
        current = self.sources / "current"
        current.unlink()
        current.symlink_to(commit[:12])
        (self.state / "release" / commit[:12] / "release.json").write_text(json.dumps({"commit": commit}))
        return 0, json.dumps({"release": commit[:12], "previous_release": previous[:12],
                              "operations": {"console": "restarted", "watchdog": "restarted"}}), ""

    def main(self, *argv):
        self.system = UpgradeSystem(self, out=self.out)
        return bootstrap.main(list(argv), system=self.system, facts=FakeFacts(self.system), prompter=None, out=self.out)

    def record(self):
        return json.loads((self.state / "setup.json").read_text())

    def evidence(self):
        files = sorted((self.state / "setup-log").glob("*.json"))
        return json.loads(files[-1].read_text())

    def test_upgrade_installs_the_staged_release_and_switches_through_redeploy(self):
        a, b = self.commits["a"], self.commits["b"]
        self.assertEqual(0, self.main("upgrade"), self.out.getvalue())
        tar = self.state / "release" / b[:12] / "source.tar"
        self.assertEqual((self.stage_dir / "source.tar").read_bytes(), tar.read_bytes())
        self.assertIn({"path": str(tar), "sha256": bootstrap.sha256(tar.read_bytes()), "mode": "0o600"}, self.system.files)
        self.assertIn({"path": str(tar.parent) + "/", "mode": "0o700"}, self.system.files)
        self.assertTrue((self.sources / b[:12] / "deploy" / "prod.py").is_file())
        self.assertEqual(0o755, stat.S_IMODE((self.sources / b[:12]).stat().st_mode))
        [call] = self.redeploys
        self.assertEqual(["python3", str(self.sources / b[:12] / "deploy" / "prod.py"), "redeploy", b, "--source", str(tar)],
                         call["argv"])
        [detached] = self.system.detached_calls             # its own session, bounded, logged (H1, M1)
        self.assertEqual((bootstrap.UPGRADE_TIMEOUT, bootstrap.FALLBACK_GRACE), (detached["timeout"], detached["grace"]))
        self.assertTrue(all(path.startswith(str(self.temp / "log")) for path in detached["logs"]))
        self.assertIn("Backups are not set up on this server: updating without a backup", self.out.getvalue())
        self.assertEqual((paths.VM_USER, str(self.sources / b[:12])), (call["user"], call["cwd"]))
        self.assertEqual(b[:12], os.readlink(self.sources / "current"))
        self.assertTrue((self.sources / a[:12]).is_dir(), "the old release is kept for rollback")
        self.assertTrue((self.state / "release" / a[:12] / "source.tar").is_file())
        # Release-specific operations state follows the new release; nothing else is touched.
        self.assertEqual("new dispatcher\n", (self.state / "bin" / "anj-alert").read_text())
        self.assertIn(["pm2", "restart", "alerts"], [c["argv"] for c in self.system.commands])
        touched = {entry["path"] for entry in self.system.files}
        self.assertFalse([path for path in touched if "/secrets" in path or path.startswith("/etc")], touched)
        self.assertEqual(b, self.record()["release"])
        self.assertEqual({"from": a[:12], "to": b[:12], "rollback": False}, {k: v for k, v in
                                                                            self.record()["last_upgrade"].items() if k != "at"})
        text = self.out.getvalue()
        self.assertIn(f"Release {b[:12]} is live and healthy (was {a[:12]}", text)
        self.assertIn("upgrade --rollback` switches back", text)
        self.assertEqual(("upgraded", "upgrade"), (self.evidence()["result"], self.evidence()["command"]))

    def test_upgrading_to_the_live_release_is_a_no_op(self):
        self.assertEqual(0, self.main("upgrade"))
        self.redeploys.clear()
        self.out.truncate(0)
        self.assertEqual(0, self.main("upgrade"))
        self.assertEqual([], self.redeploys)
        self.assertEqual([], [c for c in self.system.commands if c["argv"][0] in ("pm2", "python3")])
        self.assertIn("is already live", self.out.getvalue())
        self.assertEqual("already current", self.evidence()["result"])

    def test_a_failed_health_check_switches_nothing_and_says_so(self):
        a = self.commits["a"]
        self.redeploy_result = "unhealthy"
        self.assertEqual(1, self.main("upgrade"))
        self.assertEqual(a[:12], os.readlink(self.sources / "current"))
        self.assertEqual(a, json.loads((self.state / "stack.json").read_text())["release"])
        self.assertEqual(a, self.record()["release"])
        self.assertEqual("old dispatcher\n", (self.state / "bin" / "anj-alert").read_text())
        text = self.out.getvalue()
        self.assertIn("Gateway healthcheck is not ready", text)
        self.assertIn(f"The live release is still {a[:12]}; nothing switched. An alert was sent.", text)
        self.assertEqual("failed", self.evidence()["result"])
        # Review L3: only a failure prod.py alerted says so.
        self.redeploy_result = "refused"
        self.out.truncate(0)
        self.assertEqual(1, self.main("upgrade"))
        self.assertIn("No alert was sent", self.out.getvalue())
        self.assertNotIn("An alert was sent", self.out.getvalue())

    def test_rollback_switches_back_through_the_same_path_with_the_live_prod_py(self):
        a, b = self.commits["a"], self.commits["b"]
        self.assertEqual(0, self.main("upgrade"))
        self.redeploys.clear()
        self.assertEqual(0, self.main("upgrade", "--rollback"))
        [call] = self.redeploys
        # Release A's prod.py predates --source: the live release (B) drives the switch back.
        self.assertEqual(["python3", str(self.sources / b[:12] / "deploy" / "prod.py"), "redeploy", a, "--source",
                          str(self.state / "release" / a[:12] / "source.tar")], call["argv"])
        self.assertEqual(a[:12], os.readlink(self.sources / "current"))
        self.assertEqual(b, json.loads((self.state / "stack.json").read_text())["previous_release"])
        self.assertTrue(self.record()["last_upgrade"]["rollback"])
        self.assertEqual("rolled back", self.evidence()["result"])
        # Review L1: A has no `upgrade`, so the way forward is re-staging, not --rollback.
        text = self.out.getvalue().rsplit("Rolling back", 1)[1]
        self.assertIn(f"on the VM host run `deploy/vm/stage.py <vm> --commit {b[:12]} --upgrade`", text)
        self.assertNotIn("upgrade --rollback` switches back", text)
        # And forward again from the staged copy (the same B: its tar and tree are reused).
        self.redeploys.clear()
        self.assertEqual(0, self.main("upgrade"))
        self.assertEqual(b[:12], os.readlink(self.sources / "current"))
        self.assertEqual(1, len(self.redeploys))

    def test_rollback_without_a_previous_release_is_refused(self):
        self.assertEqual(1, self.main("upgrade", "--rollback"))
        self.assertIn("No previous release is recorded", self.out.getvalue())
        self.assertEqual([], self.redeploys)

    def test_the_installed_copy_without_a_staged_source_refuses_and_names_stage_py(self):
        with mock.patch.object(bootstrap, "ROOT", self.sources / self.commits["a"][:12]):
            self.assertEqual(1, self.main("upgrade"))
        self.assertIn("stage.py <vm> --commit <sha> --upgrade", self.out.getvalue())
        self.assertEqual([], self.redeploys)

    def test_a_state_tar_of_another_commit_is_replaced_unless_live_or_previous(self):
        b = self.commits["b"]
        wrong = self.state / "release" / b[:12] / "source.tar"
        wrong.parent.mkdir()
        archive(self.repository, self.commits["a"], wrong)
        # Recorded as the previous release: kept, and refused.
        self.write_stack(previous_release=b)
        self.assertEqual(1, self.main("upgrade"))
        self.assertIn(f"is not release {b[:12]}", self.out.getvalue())
        self.assertEqual([], self.redeploys)
        # Neither live nor previous: a stale leftover, replaced by the staged source (review L4).
        self.write_stack(previous_release=None)
        self.assertEqual(0, self.main("upgrade"), self.out.getvalue())
        self.assertEqual(b, prod.ProdStack.tar_commit(wrong))

    def test_a_stack_that_does_not_run_is_refused(self):
        record = self.record()
        record["answers"]["start_stack"] = False
        (self.state / "setup.json").write_text(json.dumps(record))
        self.assertEqual(1, self.main("upgrade"))
        self.assertIn("does not run the stack", self.out.getvalue())

    def test_arguments(self):
        for argv in (["upgrade", "--rollback", "--source", "/x.tar"], ["upgrade", "--dry-run"], ["--rollback"],
                     ["upgrade", "--answers", "/dev/null"]):
            with self.subTest(argv=argv), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                self.main(*argv)
        with mock.patch.object(bootstrap.os, "geteuid", return_value=1000):
            self.assertEqual(1, self.main("upgrade"))
        self.assertIn("upgrade needs root", self.out.getvalue())

    def set_up_backups(self, finished_hours_ago=None):
        (self.state / "backup.json").write_text(json.dumps({"targets": [{"repository_id": "r1"}]}))
        self.backup_status = {}
        if finished_hours_ago is not None:
            import datetime as dt
            finished = dt.datetime.now(dt.timezone.utc) - dt.timedelta(hours=finished_hours_ago)
            self.backup_status = {"last_success": {"finished_at": finished.isoformat(timespec="seconds")}}

    def backup_runs(self):
        return self.system.backup_detached          # detached like the switch (delta review D2)

    def test_backup_first_when_set_up_and_older_than_a_day(self):
        self.set_up_backups(finished_hours_ago=30)
        self.assertEqual(0, self.main("upgrade"), self.out.getvalue())
        self.assertEqual([["python3", "-I", str(self.sources / "current" / "deploy" / "backup.py"), "run"]],
                         self.backup_runs())
        self.assertEqual("done", self.evidence()["backup"])

    def test_a_recent_backup_needs_none_and_a_failed_one_refuses(self):
        self.set_up_backups(finished_hours_ago=2)
        self.assertEqual(0, self.main("upgrade"))
        self.assertEqual([], self.backup_runs())
        self.assertEqual("recent", self.evidence()["backup"])
        self.assertEqual(0, self.main("upgrade", "--rollback"))     # back on A, for the failing case
        self.set_up_backups(finished_hours_ago=None)                # never succeeded
        self.backup_run = (1, "", "")
        self.redeploys.clear()
        self.out.truncate(0)
        self.assertEqual(1, self.main("upgrade"))
        self.assertIn("The backup before the update failed, so nothing was updated", self.out.getvalue())
        self.assertIn("--no-backup", self.out.getvalue())
        self.assertEqual([], self.redeploys)
        self.out.truncate(0)
        self.assertEqual(0, self.main("upgrade", "--no-backup"))
        self.assertIn("--no-backup: updating without a fresh backup", self.out.getvalue())
        self.assertEqual("skipped (--no-backup)", self.evidence()["backup"])

    def test_ctrl_c_while_waiting_leaves_the_switch_running_and_says_so(self):
        self.detached_raises = KeyboardInterrupt()
        self.assertEqual(130, self.main("upgrade"))
        text = self.out.getvalue()
        self.assertIn("The upgrade is still running in the VM", text)
        self.assertIn("status", text)
        self.assertNotIn("run setup again", text)
        self.assertEqual("waiting interrupted", self.evidence()["result"])

    def test_a_timeout_reports_an_unknown_state(self):
        self.redeploy_result = "timeout"
        self.assertEqual(1, self.main("upgrade"))
        text = self.out.getvalue()
        self.assertIn("The state is unknown", text)
        self.assertNotIn("nothing switched", text)
        self.assertEqual("timed out", self.evidence()["result"])

    def test_expect_refuses_a_staged_tar_of_another_commit(self):
        self.assertEqual(1, self.main("upgrade", "--expect", self.commits["a"]))
        self.assertIn(f"not the expected {self.commits['a'][:12]}", self.out.getvalue())
        self.assertEqual([], self.redeploys)
        self.assertEqual(0, self.main("upgrade", "--expect", self.commits["b"]))

    def test_a_stale_state_tar_of_the_same_commit_is_replaced(self):
        b = self.commits["b"]
        stale = self.state / "release" / b[:12] / "source.tar"
        stale.parent.mkdir()
        archive(self.repository, b, stale)
        with open(stale, "ab") as stream:
            stream.write(b"\0" * 10240)                     # same header, other bytes
        (self.sources / b[:12]).mkdir()                     # a broken tree from an earlier try
        self.assertEqual(0, self.main("upgrade"), self.out.getvalue())
        self.assertEqual((self.stage_dir / "source.tar").read_bytes(), stale.read_bytes())
        self.assertTrue((self.sources / b[:12] / "deploy" / "prod.py").is_file())

    def test_rollback_after_an_unfinished_switch_goes_to_the_live_release(self):
        a, b = self.commits["a"], self.commits["b"]
        self.assertEqual(0, self.main("upgrade"))
        # A later switch to C was cut short: stack.json names C, release/current is still B.
        self.write_stack(release="c" * 40)
        self.redeploys.clear()
        self.assertEqual(0, self.main("upgrade", "--rollback"))
        [call] = self.redeploys
        self.assertEqual(b, call["argv"][3])
        self.assertIn(f"rolling back to the live release {b[:12]}", self.out.getvalue())
        self.assertNotEqual(a, call["argv"][3])

    def test_busy_operations_refuse_before_anything_changes(self):
        import fcntl
        with open(self.state / "run" / "backup.lock", "w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            self.assertEqual(1, self.main("upgrade"))
        self.assertIn("a backup or a release switch is running", self.out.getvalue())
        self.assertEqual([], self.redeploys)
        self.assertFalse((self.state / "release" / self.commits["b"][:12]).exists())
        (self.state / "run" / "restore-in-progress").write_text(json.dumps({"deadline_epoch": 4102444800}))
        self.assertIn("restore-in-progress is set", bootstrap.ops_busy())
        (self.state / "run" / "restore-in-progress").write_text(json.dumps({"deadline_epoch": 1}))
        self.assertIsNone(bootstrap.ops_busy())             # past its deadline: suppresses nothing

    def test_status_shows_a_running_switch_then_the_last_upgrade(self):
        proc = self.temp / "proc"
        (proc / "77").mkdir(parents=True)
        (proc / "77" / "cmdline").write_bytes(b"python3\0/srv/anj-cloud/release/x/deploy/prod.py\0redeploy\0" +
                                              self.commits["b"].encode() + b"\0--source\0/t\0")
        self.assertIn(f"running now (to {self.commits['b'][:12]}", bootstrap.update_state(proc))
        self.assertEqual(0, self.main("upgrade"))
        (proc / "77" / "cmdline").write_bytes(b"python3\0/x/deploy/prod.py\0status\0")
        self.assertIn(f"last upgrade {self.commits['a'][:12]} -> {self.commits['b'][:12]}", bootstrap.update_state(proc))

    def test_the_watchdog_treats_upgrade_and_rollback_as_maintenance(self):
        loader = importlib.machinery.SourceFileLoader("vmops_upgrade", str(ROOT / "deploy" / "vm" / "ops" / "vmops.py"))
        spec = importlib.util.spec_from_loader("vmops_upgrade", loader)
        vmops = importlib.util.module_from_spec(spec)
        loader.exec_module(vmops)
        proc = self.temp / "proc"
        for pid, argv in (("21", ["/usr/bin/python3", "-I", "/var/lib/anj-cloud-setup/src/deploy/vm/anj-cloud-setup",
                                  "upgrade"]),):
            (proc / pid).mkdir(parents=True)
            (proc / pid / "cmdline").write_bytes(b"\0".join(p.encode() for p in argv) + b"\0")
        self.assertEqual(["anj-cloud-setup"], vmops.busy_processes(proc))
        (proc / "21" / "cmdline").write_bytes(b"\0".join(p.encode() for p in [
            "/usr/bin/python3", "-I", "/usr/local/bin/anj-cloud-setup", "upgrade", "--rollback"]) + b"\0")
        self.assertEqual(["anj-cloud-setup"], vmops.busy_processes(proc))
        self.assertEqual(15 * 60, vmops.quiet_bound("anj-cloud-setup"))


class DetachedTests(unittest.TestCase):
    """System.detached (review H1, M1): its own session, and the timeout reaches the grandchild."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.temp = Path(self.temporary.name)
        self.addCleanup(self.temporary.cleanup)

    def logs(self):
        return (self.temp / "log" / "x.out", self.temp / "log" / "x.err")

    def test_runs_in_its_own_session_with_logs(self):
        code, out, err = bootstrap.System().detached(
            ["python3", "-c", "import os,sys; print(os.getsid(0)); print('e', file=sys.stderr)"], logs=self.logs())
        self.assertEqual(0, code)
        self.assertNotEqual(os.getsid(0), int(out.strip()))
        self.assertEqual("e\n", err)
        self.assertEqual(0o600, stat.S_IMODE(self.logs()[1].stat().st_mode))

    def test_the_timeout_lets_the_fallback_finish_with_no_watching_parent(self):
        """Delta review D1/D4: the real exec shape. The command is the session leader itself (no
        runuser, which SIGKILLs its child 2 s after forwarding SIGTERM); a fallback that takes
        longer than 2 s, with a second SIGTERM arriving, completes before the code is 124."""
        marker = self.temp / "marker"
        root = Path(__file__).resolve().parent.parent
        script = self.temp / "child.py"
        script.write_text(f"import os,sys,time\nsys.path.insert(0, {str(root)!r})\n"
                          "from deploy import prod\n"
                          f"marker = {str(marker)!r}\n"
                          "try:\n"
                          "    with prod.signals_as_interrupts():\n"
                          "        open(marker, 'w').write('started %d %d' % (os.getpid(), os.getsid(0)))\n"
                          "        time.sleep(30)\n"
                          "except prod.Interrupted:\n"
                          "    with prod.signals_ignored():\n"
                          "        time.sleep(3)\n"
                          "        open(marker, 'w').write('fell back')\n"
                          "    sys.exit(1)\n")
        system = bootstrap.System()
        timer = __import__("threading").Timer(3.0, lambda: os.kill(int(marker.read_text().split()[1]), signal.SIGTERM))
        timer.start()                                       # the duplicate SIGTERM a forwarder would add
        started = __import__("time").monotonic()
        with mock.patch.object(bootstrap.System, "user_argv", side_effect=AssertionError("no runuser")):
            code, _out, _err = system.detached(["python3", str(script)], timeout=2, grace=20, logs=self.logs())
        timer.cancel()
        self.assertEqual(124, code)
        self.assertEqual("fell back", marker.read_text())
        self.assertLess(__import__("time").monotonic() - started, 15)

    def test_identity_drops_to_the_user_with_its_groups_and_no_intermediate(self):
        entry = mock.Mock(pw_uid=1000, pw_gid=1000, pw_dir="/home/anj")
        with mock.patch.object(bootstrap.os, "geteuid", return_value=0), \
                mock.patch.object(bootstrap.pwd, "getpwnam", return_value=entry), \
                mock.patch.object(bootstrap.os, "getgrouplist", return_value=[1000, 27, 999]) as groups:
            identity, environment = bootstrap.System.identity("anj")
        groups.assert_called_once_with("anj", 1000)
        self.assertEqual({"user": 1000, "group": 1000, "extra_groups": [1000, 27, 999], "umask": 0o022}, identity)
        self.assertEqual({"HOME": "/home/anj", "PM2_HOME": "/home/anj/.pm2", "PATH": "/usr/local/bin:/usr/bin:/bin",
                          "LC_ALL": "C.UTF-8", "USER": "anj", "LOGNAME": "anj"}, environment)
        popen = mock.Mock(side_effect=OSError("stop"))
        with mock.patch.object(bootstrap.System, "identity", return_value=(identity, environment)), \
                mock.patch.object(bootstrap.subprocess, "Popen", popen), self.assertRaises(OSError):
            bootstrap.System().detached(["python3", "/srv/x/deploy/prod.py", "redeploy"], user="anj", logs=self.logs())
        args, kwargs = popen.call_args
        self.assertEqual(["python3", "/srv/x/deploy/prod.py", "redeploy"], args[0])    # prod.py is the direct child
        self.assertTrue(kwargs["start_new_session"])
        self.assertEqual((1000, 1000, [1000, 27, 999]), (kwargs["user"], kwargs["group"], kwargs["extra_groups"]))


class OperationsRestartTests(unittest.TestCase):
    def test_ddns_needs_no_restart_its_script_resolves_through_release_current(self):
        """Coordinator ruling on #122: console, watchdog and watchers restart after a switch
        (prod.RELEASE_OPS_APPS); ddns is a cron_restart app with autorestart off whose script and cwd
        are release/current's, so its next 5-minute run starts the new release by itself."""
        self.assertEqual(("console", "watchdog", "watchers"), prod.RELEASE_OPS_APPS)
        self.assertNotIn(paths.DDNS_APP, prod.RELEASE_OPS_APPS)
        args = bootstrap.parser().parse_args([])
        system = FakeSystem(dry=True)
        setup = bootstrap.Setup(args, system=system, facts=FakeFacts(system), out=io.StringIO())
        setup.answers = {"ddns": "on", "start_stack": True}
        [ddns] = [app for app in bootstrap.Operations(setup).apps() if app["name"] == paths.DDNS_APP]
        current = str(paths.RELEASE_CURRENT)
        self.assertEqual(current + "/deploy/ddns.py", ddns["script"])
        self.assertEqual(current, ddns["cwd"])
        self.assertIs(False, ddns["autorestart"])
        self.assertTrue(ddns["cron_restart"].startswith("*/5 "))
        # Every other operations app that runs release code is restarted by redeploy.
        for app in bootstrap.ops_apps(paths.STATE_ROOT, paths.RELEASE_CURRENT):
            if app["script"].startswith(current):
                self.assertIn(app["name"], prod.RELEASE_OPS_APPS)


# deploy/vm/stage.py --upgrade ----------------------------------------------------------------------

class StageUpgradeTests(unittest.TestCase):
    def git_run(self, dirty="", merged=True, fixes=True, public=False, public_known=False):
        calls = []

        def run(argv, **_options):
            calls.append(argv[3:])
            if argv[3] == "status":
                return subprocess.CompletedProcess(argv, 0, dirty, "")
            if argv[3] == "rev-parse":
                return subprocess.CompletedProcess(argv, 0 if public_known else 1,
                                                   prod.PUBLIC_HISTORY_COMMIT if public_known else "", "")
            ancestor, descendant = argv[5], argv[6]
            if ancestor == prod.PUBLIC_HISTORY_COMMIT:
                ok = public
            else:
                ok = merged if descendant == "origin/main" else fixes
            return subprocess.CompletedProcess(argv, 0 if ok else 1, "", "")
        return run, calls

    def test_check_upgrade_refuses_dirty_unmerged_or_unfixed_commits(self):
        full = "b" * 40
        run, calls = self.git_run()
        stage.check_upgrade("anj-prod", full, "/c", run=run)
        self.assertIn(["merge-base", "--is-ancestor", full, "origin/main"], calls)
        self.assertEqual(len(prod.REQUIRED_COMMITS), sum(1 for c in calls if c[-1] == full))
        cases = ((dict(dirty=" M deploy/prod.py\n"), "anj-prod", "uncommitted or untracked"),
                 (dict(dirty="?? notes.txt\n"), "anj-qual", "uncommitted or untracked"),
                 (dict(merged=False), "anj-prod", "not merged into origin/main"),
                 (dict(fixes=False), "anj-qual", "does not contain 4c3bb82"))
        for options, target, message in cases:
            run, _calls = self.git_run(**options)
            with self.subTest(options=options), self.assertRaisesRegex(RuntimeError, message):
                stage.check_upgrade(target, full, "/c", run=run)
        run, calls = self.git_run(merged=False)
        stage.check_upgrade("anj-qual", full, "/c", run=run)        # qualification takes a PR head
        self.assertNotIn("origin/main", [c[-1] for c in calls])

    def test_check_upgrade_accepts_only_descendants_of_the_public_root(self):
        full = "b" * 40
        run, calls = self.git_run(fixes=False, public=True, public_known=True)
        stage.check_upgrade("anj-prod", full, "/c", run=run)
        self.assertIn(["merge-base", "--is-ancestor", full, "origin/main"], calls)
        self.assertIn(["merge-base", "--is-ancestor", prod.PUBLIC_HISTORY_COMMIT, full], calls)
        self.assertFalse([c for c in calls if c[:1] == ["merge-base"] and c[2] in prod.REQUIRED_COMMITS])
        run, _calls = self.git_run(fixes=False, public=False, public_known=True)
        with self.assertRaisesRegex(RuntimeError, "does not contain 4c3bb82"):
            stage.check_upgrade("anj-prod", full, "/c", run=run)
        run, calls = self.git_run(merged=False, fixes=False, public=True, public_known=True)
        with self.assertRaisesRegex(RuntimeError, "not merged into origin/main"):
            stage.check_upgrade("anj-prod", full, "/c", run=run)
        self.assertNotIn(["merge-base", "--is-ancestor", prod.PUBLIC_HISTORY_COMMIT, full], calls)

    def test_upgrade_argv_runs_the_staged_copy_over_ssh(self):
        full = "b" * 40
        self.assertEqual(["ssh", "-F", "/cfg", "-t", "anj-prod",
                          f"sudo /var/lib/anj-cloud-setup/src/deploy/vm/anj-cloud-setup upgrade --expect {full}"],
                         stage.upgrade_argv("anj-prod", full, "/cfg", terminal=True))
        self.assertEqual("-T", stage.upgrade_argv("anj-qual", full, "/cfg", terminal=False)[3])
        self.assertTrue(stage.upgrade_argv("anj-qual", full, "/cfg", terminal=False, no_backup=True)[-1]
                        .endswith(" --no-backup"))

    def test_main_checks_then_stages_then_upgrades(self):
        order = []
        with mock.patch.object(stage, "resolve", return_value="b" * 40), \
                mock.patch.object(stage, "check_upgrade", side_effect=lambda *a: order.append(("check",) + a[:2])), \
                mock.patch.object(stage, "stage", side_effect=lambda *a: order.append(("stage", a[1], a[2])) or
                                  {"commit": "b" * 40}), \
                mock.patch.object(stage, "run_upgrade", side_effect=lambda target, commit, no_backup=False:
                                  order.append(("upgrade", target, commit, no_backup)) or 7), \
                contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(7, stage.main(["anj-prod", "--commit", "bbbb", "--upgrade"]))
        self.assertEqual([("check", "anj-prod", "b" * 40), ("stage", "anj-prod", "bbbb"),
                          ("upgrade", "anj-prod", "b" * 40, False)], order)
        with mock.patch.object(stage, "resolve", return_value="b" * 40), \
                mock.patch.object(stage, "check_upgrade", side_effect=RuntimeError("x is not merged")), \
                mock.patch.object(stage, "stage") as staged, contextlib.redirect_stderr(io.StringIO()) as err:
            self.assertEqual(1, stage.main(["anj-prod", "--upgrade"]))
            staged.assert_not_called()
        self.assertIn("stage: x is not merged", err.getvalue())
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            stage.main(["anj-prod", "--upgrade", "--with-secrets"])


class LocalUpgradeTests(unittest.TestCase):
    full = "c" * 40
    checkout = Path("/checkout")

    def invoke(self, argv=(), *, resolved=None, resolve_error=None, fetch_code=0, check_error=None,
               archive_code=0, setup_code=0):
        events, sources = [], []

        def resolve(commit, checkout):
            events.append(("resolve", commit, checkout))
            if resolve_error:
                raise resolve_error
            return self.full if resolved is None else resolved

        def check(target, commit, checkout, run):
            events.append(("check", target, commit, checkout))
            if check_error:
                raise check_error

        def run(command, **kwargs):
            if command[:4] == ["git", "-C", str(self.checkout), "fetch"]:
                kind, code = "fetch", fetch_code
            elif command[:4] == ["git", "-C", str(self.checkout), "archive"]:
                kind, code = "archive", archive_code
                sources.append(Path(kwargs["stdout"].name))
                kwargs["stdout"].write(b"tar")
            elif command[:1] == ["sudo"]:
                kind, code = "setup", setup_code
                source = Path(command[command.index("--source") + 1])
                self.assertTrue(source.is_file())
            else:
                raise AssertionError(command)
            events.append((kind, command, kwargs))
            return subprocess.CompletedProcess(command, code)

        error = io.StringIO()
        with mock.patch.object(local_upgrade, "CHECKOUT", self.checkout), \
                mock.patch.object(local_upgrade.Path, "cwd", return_value=self.checkout), \
                mock.patch.object(local_upgrade.stage, "resolve", side_effect=resolve), \
                mock.patch.object(local_upgrade.stage, "check_upgrade", side_effect=check), \
                mock.patch.object(local_upgrade.subprocess, "run", side_effect=run), \
                contextlib.redirect_stderr(error):
            code = local_upgrade.main(list(argv))
        return code, events, sources, error.getvalue()

    def test_successful_call_order_exact_arguments_and_cleanup(self):
        code, events, sources, error = self.invoke()
        self.assertEqual(code, 0)
        self.assertEqual(error, "")
        self.assertEqual([event[0] for event in events], ["resolve", "fetch", "check", "archive", "setup"])
        self.assertEqual(events[0], ("resolve", "HEAD", self.checkout))
        self.assertEqual(events[1][1], ["git", "-C", str(self.checkout), "fetch", "origin", "main"])
        self.assertEqual(events[2], ("check", "anj-prod", self.full, self.checkout))
        self.assertEqual(events[3][1], ["git", "-C", str(self.checkout), "archive", "--format=tar", self.full])
        [source] = sources
        self.assertEqual(events[4][1], ["sudo", "/usr/local/bin/anj-cloud-setup", "upgrade", "--source", str(source),
                                       "--expect", self.full])
        self.assertEqual(events[4][2], {"check": False})
        self.assertNotIn("--no-backup", events[4][1])
        self.assertFalse(source.exists())
        self.assertFalse(source.parent.exists())

    def test_no_backup_is_forwarded_only_when_requested(self):
        code, events, sources, _error = self.invoke(["--no-backup"])
        self.assertEqual(code, 0)
        self.assertEqual(events[-1][1][-1], "--no-backup")
        self.assertEqual(events[-1][1][-3:-1], ["--expect", self.full])
        self.assertFalse(sources[0].exists())

    def test_failed_prerequisites_never_call_setup_and_clean_any_archive(self):
        cases = (
            ("resolve", dict(resolve_error=RuntimeError("resolve failed")), ["resolve"]),
            ("short commit", dict(resolved="c" * 7), ["resolve"]),
            ("fetch", dict(fetch_code=1), ["resolve", "fetch"]),
            ("check", dict(check_error=RuntimeError("not merged")), ["resolve", "fetch", "check"]),
            ("archive", dict(archive_code=1), ["resolve", "fetch", "check", "archive"]),
        )
        for name, options, expected in cases:
            with self.subTest(name):
                code, events, sources, error = self.invoke(**options)
                self.assertEqual(code, 1)
                self.assertEqual([event[0] for event in events], expected)
                self.assertNotIn("setup", [event[0] for event in events])
                self.assertIn("local-upgrade:", error)
                for source in sources:
                    self.assertFalse(source.exists())
                    self.assertFalse(source.parent.exists())

    def test_setup_failure_propagates_and_cleans_the_archive(self):
        code, events, sources, error = self.invoke(setup_code=23)
        self.assertEqual(code, 23)
        self.assertEqual([event[0] for event in events], ["resolve", "fetch", "check", "archive", "setup"])
        self.assertEqual(error, "")
        self.assertFalse(sources[0].exists())
        self.assertFalse(sources[0].parent.exists())

    def test_wrong_cwd_fails_before_resolving_or_running_git(self):
        with mock.patch.object(local_upgrade, "CHECKOUT", self.checkout), \
                mock.patch.object(local_upgrade.Path, "cwd", return_value=Path("/elsewhere")), \
                mock.patch.object(local_upgrade.stage, "resolve") as resolve, \
                contextlib.redirect_stderr(io.StringIO()) as error:
            self.assertEqual(local_upgrade.main([]), 1)
        resolve.assert_not_called()
        self.assertIn("root of the anj-cloud checkout", error.getvalue())


if __name__ == "__main__":
    unittest.main()
