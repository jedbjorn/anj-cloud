"""Hermetic tests of deploy/macos_admin_fixture.py and tool/macos/check_m5.sh (spec #31 M5).

No guest, stack or SSH: the guest command, the operator and the admin CLI are fakes. They carry the
lessons of the Windows W6 driver (PR #74): a run passes only on its own result, each cleanup step
runs on its own, fixture users are reset per run, and the configuration (with a pairing code) is
never fetched into the evidence.
"""

from pathlib import Path
import json
import subprocess
import unittest
from unittest.mock import patch

from deploy import macos_admin_fixture as fixture

ROOT = Path(__file__).resolve().parent.parent
DONE = json.dumps([{"claim": "home shown"}, {"claim": "done"}])
PASSED_LOG = "00:42 +2: All tests passed!\nM5 GUI RESULT 0\n__ANJ_RC=0\n"
ALICE, BOB = fixture.ALICE, fixture.BOB


class RunVerdict(unittest.TestCase):
    def test_a_complete_run_passes(self):
        self.assertEqual(fixture.run_verdict(0, PASSED_LOG, {"ui": DONE, "admin": DONE}), [])

    def test_an_earlier_runs_log_without_this_runs_result_fails(self):
        reasons = fixture.run_verdict(0, "00:42 +2: All tests passed!\n", {"ui": DONE, "admin": DONE})
        self.assertTrue(any("no result line" in reason for reason in reasons), reasons)

    def test_a_nonzero_gui_result_fails_even_with_a_passing_log(self):
        reasons = fixture.run_verdict(0, "All tests passed!\nM5 GUI RESULT 124\n", {"ui": DONE, "admin": DONE})
        self.assertEqual(reasons, ["gui job result 124"])

    def test_the_guest_status_counts(self):
        self.assertIn("guest run exit 255", fixture.run_verdict(255, PASSED_LOG, {"ui": DONE, "admin": DONE}))

    def test_both_progress_files_must_end_with_done(self):
        stopped = json.dumps([{"claim": "alice paired and admin"}, {"claim": "stopped"}])
        for progress in ({"ui": DONE, "admin": None}, {"ui": DONE, "admin": stopped},
                         {"ui": "not json", "admin": DONE}, {"ui": "[]", "admin": DONE}):
            reasons = fixture.run_verdict(0, PASSED_LOG, progress)
            self.assertTrue(any("progress.json ends with" in reason for reason in reasons), (progress, reasons))
        self.assertEqual(fixture.run_verdict(0, PASSED_LOG, {"ui": DONE, "admin": None}, admin=False), [])


class Cleanup(unittest.TestCase):
    def test_a_raising_step_never_skips_the_later_ones(self):
        ran = []

        def boom(error):
            def action():
                ran.append(type(error).__name__)
                raise error
            return action

        with patch("builtins.print"):
            failed = fixture.cleanup([
                ("timeout", boom(subprocess.TimeoutExpired(["ssh"], 10))),
                ("exit", boom(SystemExit("step failed"))),
                ("runtime", boom(RuntimeError("Operator action rejected"))),
                ("last", lambda: ran.append("last")),
            ])
        self.assertEqual(failed, ["timeout", "exit", "runtime"])
        self.assertEqual(ran, ["TimeoutExpired", "SystemExit", "RuntimeError", "last"])

    def test_the_guest_run_is_stopped_by_its_own_label_and_task_directory(self):
        commands = []

        def guest(command, **_):
            commands.append(command)
            return 0, ""

        with patch.object(fixture, "guest", guest), patch.object(fixture, "HOST", "sam@mac-test"), patch("builtins.print"):
            fixture.stop_guest_run("work/LANE1/m5-1")
        self.assertIn("work/LANE1/m5-1/build/m5/gui.label", commands[0])
        self.assertIn("local.anj-test.gui.[0-9]*)", commands[0])
        self.assertIn("pkill -f /Users/sam/work/LANE1/m5-1/build/macos/", commands[0])

    def test_a_guest_run_that_does_not_stop_fails_the_step(self):
        with patch.object(fixture, "guest", lambda command, **_: (1, "")), self.assertRaises(RuntimeError):
            fixture.stop_guest_run("work/LANE1/m5-1")

    def test_the_run_files_go_configuration_first(self):
        commands = []
        with patch.object(fixture, "guest", lambda command, **_: (commands.append(command), (0, ""))[1]):
            fixture.remove_guest_run_files("work/LANE1/m5-1")
        self.assertLess(commands[0].index("config.json"), commands[0].index("rm -rf"))


class Forward(unittest.TestCase):
    def test_the_reverse_forward_is_plain_ssh_to_the_guest_with_a_pinned_host_key(self):
        command = fixture.forward_command(18876, "/run/known_hosts")
        self.assertEqual(command[0], "ssh")
        self.assertNotIn("tailscale", command)
        self.assertEqual(command[-1], fixture.HOST)
        for option in ("ExitOnForwardFailure=yes", "StrictHostKeyChecking=yes", "UserKnownHostsFile=/run/known_hosts"):
            self.assertIn(option, command)
        self.assertEqual(command[command.index("-R") + 1], "127.0.0.1:18876:127.0.0.1:18876")

    def test_known_hosts_come_from_the_keys_tailscale_advertises(self):
        status = {"Peer": {
            "a": {"DNSName": "other.ts.net.", "TailscaleIPs": ["100.1.1.1"], "sshHostKeys": ["ssh-ed25519 X"]},
            "b": {"DNSName": "mac-test.example.ts.net.", "TailscaleIPs": ["100.64.0.2"],
                  "sshHostKeys": ["ssh-ed25519 AAA", "ecdsa-sha2-nistp256 BBB"]}}}
        self.assertEqual(fixture.known_hosts_lines(status, "sam@mac-test"), [
            "mac-test,mac-test.example.ts.net,100.64.0.2 ssh-ed25519 AAA",
            "mac-test,mac-test.example.ts.net,100.64.0.2 ecdsa-sha2-nistp256 BBB"])
        with self.assertRaises(RuntimeError):
            fixture.known_hosts_lines({"Peer": {}}, "sam@mac-test")


class Task(unittest.TestCase):
    def test_only_this_owners_task_directories(self):
        self.assertEqual(fixture.task_dir("LANE1/m5-1"), "work/LANE1/m5-1")
        self.assertEqual(fixture.task_dir("LANE1/m5"), "work/LANE1/m5")
        for bad in ("LANE1/m6-1", "LANE1/m5rev-1", "../m5", "LANE1/m5-1/..", "m5-1"):
            with self.assertRaises(SystemExit, msg=bad):
                fixture.task_dir(bad)


class FakeOperator:
    def __init__(self, pending=(), devices=()):
        self.pending = [dict(row) for row in pending]
        self.devices = [dict(row) for row in devices]
        self.actions = []

    def call(self, action, **data):
        self.actions.append((action, data))
        if action == "pending":
            return [dict(row) for row in self.pending]
        if action == "devices":
            return [dict(row) for row in self.devices]
        if action == "deny":
            for row in self.pending:
                if row["id"] == data["pairing_id"]:
                    row["state"] = "denied"
            return {}
        raise AssertionError(action)

    def revoke(self, identity):
        self.actions.append(("revoke", identity))
        for row in self.devices:
            if row["id"] == identity:
                row["state"] = "revoked"


class FakeCli:
    def __init__(self, admins):
        self.admins = set(admins)

    def __call__(self, action, *args):
        if action == "admins":
            return subprocess.CompletedProcess([], 0, stdout=json.dumps(sorted(self.admins)), stderr="")
        if action == "admin-remove":
            if args[0] in self.admins and len(self.admins) > 1:
                self.admins.discard(args[0])
                return subprocess.CompletedProcess([], 0, stdout="", stderr="")
            return subprocess.CompletedProcess([], 1, stdout="", stderr="last-admin")
        raise AssertionError(action)


class Users(unittest.TestCase):
    def test_bob_is_reset_fully(self):
        operator = FakeOperator(
            pending=[{"id": "p1", "uid": BOB, "state": "issued"}, {"id": "p2", "uid": ALICE, "state": "issued"}],
            devices=[{"id": "d1", "uid": BOB, "state": "active"}, {"id": "d2", "uid": ALICE, "state": "active"}])
        cli = FakeCli({ALICE, BOB})
        with patch("builtins.print"):
            fixture.reset_user(operator, cli, BOB)
        self.assertIn(("deny", {"pairing_id": "p1"}), operator.actions)
        self.assertIn(("revoke", "d1"), operator.actions)
        self.assertNotIn(("revoke", "d2"), operator.actions)
        self.assertEqual(cli.admins, {ALICE})

    def test_alice_keeps_her_role_on_a_reset(self):
        operator = FakeOperator(devices=[{"id": "d2", "uid": ALICE, "state": "active"}])
        cli = FakeCli({ALICE})
        with patch("builtins.print"):
            fixture.reset_user(operator, cli, ALICE, role=False)
        self.assertEqual(cli.admins, {ALICE})
        self.assertIn(("revoke", "d2"), operator.actions)

    def test_a_user_still_admin_is_not_reset(self):
        with patch("builtins.print"), self.assertRaises(RuntimeError):
            fixture.reset_user(FakeOperator(), FakeCli({BOB}), BOB)

    def test_alice_is_removed_or_kept_only_as_the_last_admin(self):
        with patch("builtins.print"):
            cli = FakeCli({ALICE, BOB})
            fixture.remove_admin(cli, ALICE)
            self.assertEqual(cli.admins, {BOB})
            fixture.remove_admin(FakeCli({ALICE}), ALICE)


class GuestScript(unittest.TestCase):
    script = (ROOT / "apps/client/tool/macos/check_m5.sh").read_text()

    def test_stale_results_are_removed_before_the_run(self):
        self.assertLess(self.script.index('rm -rf -- "$out" "$run/gui" "$run/gui.label"'),
                        self.script.index("tool/macos/gui_run.sh \"$run/gui\""))

    def test_the_run_reports_its_own_result_and_label(self):
        self.assertIn('print -r -- "M5 GUI RESULT $rc"', self.script)
        self.assertIn('print -r -- "local.anj-test.gui.$job" > "$run/gui.label"', self.script)
        self.assertTrue(self.script.rstrip().endswith("exit $rc"))

    def test_tmpdir_is_a_real_path_in_the_task_directory(self):
        self.assertIn("TMPDIR=\"$tmp\"", self.script)
        self.assertIn("tmp=${run:A}/tmp", self.script)

    def test_the_driver_fetches_only_the_evidence_never_the_configuration(self):
        driver = (ROOT / "deploy/macos_admin_fixture.py").read_text()
        self.assertIn('"fetch", args.task, f"{run}/out"', driver)
        self.assertIn("--config {run}/config.json", driver)
        self.assertNotIn("/out/config.json", driver)


if __name__ == "__main__":
    unittest.main()
