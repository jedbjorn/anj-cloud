"""Hermetic tests of deploy/windows_admin_fixture.py and tool/windows/w6_run.ps1 (spec #32 W6,
review items 1 to 4). No VM, stack or SSH: the seat, the operator and the admin CLI are fakes.
Run by tool/test_windows_seat.sh (check.sh) with the system python3, so the fixture must import
without the access venv.
"""

from pathlib import Path
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT))

from deploy import windows_admin_fixture as fixture  # noqa: E402

DONE = json.dumps([{"claim": "alice paired and admin"}, {"claim": "done"}])
PASSED_LOG = "00:42 +1: All tests passed!\nW6 TASK RESULT 0\n"


class RunVerdict(unittest.TestCase):
    """Review 1: a task that never ran cannot report an earlier run's PASS."""

    def test_a_complete_run_passes(self):
        self.assertEqual(fixture.run_verdict(0, PASSED_LOG, DONE), [])

    def test_an_earlier_runs_log_without_this_runs_task_result_fails(self):
        # The old driver passed on this: the log says All tests passed, nothing else.
        reasons = fixture.run_verdict(0, "00:42 +1: All tests passed!\n", DONE)
        self.assertTrue(any("no task result" in reason for reason in reasons), reasons)

    def test_a_task_that_never_ran_fails(self):
        log = "W6 NO LOG: the task wrote nothing\nW6 TASK RESULT 267011\n"
        reasons = fixture.run_verdict(1, log, None)
        self.assertIn("task result 267011", reasons)
        self.assertIn("guest run exit 1", reasons)

    def test_a_nonzero_task_result_fails_even_with_a_passing_log(self):
        reasons = fixture.run_verdict(0, "All tests passed!\nW6 TASK RESULT 1\n", DONE)
        self.assertEqual(reasons, ["task result 1"])

    def test_progress_must_end_with_done(self):
        for progress in (None, "", "not json", "[]", json.dumps([{"claim": "home shown"}, {"claim": "stopped"}])):
            reasons = fixture.run_verdict(0, PASSED_LOG, progress)
            self.assertTrue(any("progress.json ends with" in reason for reason in reasons), (progress, reasons))

    def test_w6_run_clears_the_log_before_the_task_and_checks_its_result(self):
        script = (ROOT / "apps/client/tool/windows/w6_run.ps1").read_text()
        clear = script.index("Remove-Item $Log")
        self.assertLess(clear, script.index("Register-ScheduledTask"))
        self.assertIn("if (Test-Path $Log) { throw", script)
        self.assertIn("LastTaskResult", script)
        self.assertIn('"W6 TASK RESULT $result"', script)
        self.assertIn("'Running', 'Queued'", script)
        self.assertTrue(script.rstrip().endswith(
            "if ($timedOut -or $result -ne 0 -or -not (Test-Path $Log)) { exit 1 }"))


class Cleanup(unittest.TestCase):
    """Review 2: each cleanup step runs on its own; the restore is read back as 96 DPI."""

    def test_a_raising_step_never_skips_the_later_ones(self):
        ran = []

        def boom(error):
            def action():
                ran.append(type(error).__name__)
                raise error
            return action

        # The kinds the old cleanup let escape: a forward.wait timeout, step()'s SystemExit,
        # an operator RuntimeError.
        with patch("builtins.print"):
            failed = fixture.cleanup([
                ("timeout", boom(subprocess.TimeoutExpired(["ssh"], 10))),
                ("exit", boom(SystemExit("step failed"))),
                ("runtime", boom(RuntimeError("Operator action rejected"))),
                ("last", lambda: ran.append("last")),
            ])
        self.assertEqual(failed, ["timeout", "exit", "runtime"])
        self.assertEqual(ran, ["TimeoutExpired", "SystemExit", "RuntimeError", "last"])

    def restore(self, code, stdout):
        return lambda: subprocess.CompletedProcess([], code, stdout=stdout, stderr="")

    def test_restore_passes_only_at_96_dpi(self):
        with patch("builtins.print") as printed:
            fixture.restore_scale(self.restore(0, "requested 100% effective dpi 96 = 100%\nscale 100%\n"))
        self.assertIn("effective DPI 96", printed.call_args.args[0])

    def test_restore_fails_on_another_dpi_an_error_or_no_reading(self):
        for code, stdout in ((0, "requested 100% effective dpi 144 = 150%\nscale 100%\n"),
                             (1, "requested 100% effective dpi 96 = 100%\n"),
                             (0, "scale 100%\n")):
            with patch("builtins.print") as printed, self.assertRaises(RuntimeError):
                fixture.restore_scale(self.restore(code, stdout))
            self.assertFalse(any("Scale restored" in str(call) for call in printed.call_args_list))

    def test_a_failed_restore_is_reported_and_the_rest_still_runs(self):
        later = []
        with patch("builtins.print") as printed:
            failed = fixture.cleanup([
                ("scale", lambda: fixture.restore_scale(self.restore(0, "effective dpi 144"))),
                ("revoke", lambda: later.append("revoke")),
            ])
        self.assertEqual(failed, ["scale"])
        self.assertEqual(later, ["revoke"])
        lines = [str(call.args[0]) for call in printed.call_args_list]
        self.assertTrue(any(line.startswith("FAIL cleanup: scale") for line in lines), lines)
        self.assertFalse(any("Scale restored" in line for line in lines), lines)


class RemoveAdmin(unittest.TestCase):
    def test_removed_or_kept_only_as_the_last_admin(self):
        with patch("builtins.print"):
            cli = FakeCli({ALICE, BOB})
            fixture.remove_admin(cli, ALICE)
            self.assertEqual(cli.admins, {BOB})
            fixture.remove_admin(FakeCli({ALICE}, remove_works=False), ALICE)  # 409 last-admin
        with self.assertRaisesRegex(RuntimeError, "still an admin"):
            fixture.remove_admin(FakeCli({ALICE, BOB}, remove_works=False), ALICE)


class ConsoleBackend(unittest.TestCase):
    """Seat run 1: approve stalled because no console backend served the review stack."""

    class Process:
        def __init__(self, code=None):
            self.returncode = code

        def poll(self):
            return self.returncode

    def operator(self, states):
        states = iter(states)
        return type("O", (), {"call": lambda self, action: {"backend": next(states)}})()

    def test_ready_behind_the_gateway(self):
        with patch("builtins.print"):
            fixture.wait_backend(self.operator(["unavailable", "ready"]), self.Process(), sleep=lambda _: None)

    def test_never_ready_or_exited_fails(self):
        clock = iter(range(0, 1000, 10))
        with self.assertRaisesRegex(RuntimeError, "does not reach"):
            fixture.wait_backend(self.operator(["unavailable"] * 100), self.Process(),
                                 clock=lambda: next(clock), sleep=lambda _: None)
        with self.assertRaisesRegex(RuntimeError, "exited"):
            fixture.wait_backend(self.operator([]), self.Process(1), sleep=lambda _: None)

    # A stand-in backend: binds its Unix socket, removes it on SIGTERM and exits, as
    # deploy.vm.console_backend does. `leave` keeps the socket (a backend that died uncleanly).
    BACKEND = (
        "import os, signal, socket, sys, time\n"
        "path, leave = sys.argv[1], sys.argv[2] == 'leave'\n"
        "s = socket.socket(socket.AF_UNIX); s.bind(path); s.listen()\n"
        "def stop(*_):\n"
        "    s.close()\n"
        "    if not leave: os.unlink(path)\n"
        "    sys.exit(0)\n"
        "signal.signal(signal.SIGTERM, stop)\n"
        "print('up', flush=True)\n"
        "while True: time.sleep(0.1)\n"
    )

    def backend(self, leave=False):
        socket = temporary(self) / "backend.sock"
        process = subprocess.Popen([sys.executable, "-I", "-c", self.BACKEND, str(socket), "leave" if leave else "keep"],
                                   stdout=subprocess.PIPE, text=True)
        self.addCleanup(lambda: process.poll() is None and (process.kill(), process.wait()))
        self.assertEqual("up", process.stdout.readline().strip())
        process.stdout.close()
        self.assertTrue(socket.exists())
        return process, socket

    def test_stop_ends_the_process_and_its_socket_is_gone(self):
        process, socket = self.backend()
        with patch("builtins.print"):
            fixture.stop_console_backend(process, socket)
        self.assertIsNotNone(process.poll())
        self.assertFalse(socket.exists())

    def test_a_stop_that_does_nothing_is_caught(self):
        process, socket = self.backend()
        with patch.object(process, "terminate"), patch.object(process, "wait"), patch.object(process, "kill"), \
                self.assertRaisesRegex(RuntimeError, "still running"):
            fixture.stop_console_backend(process, socket)
        self.assertIsNone(process.poll())

    def test_a_socket_left_behind_fails_the_stop(self):
        process, socket = self.backend(leave=True)
        with self.assertRaisesRegex(RuntimeError, "socket left behind"):
            fixture.stop_console_backend(process, socket)
        self.assertIsNotNone(process.poll())

    def test_main_starts_the_backend_and_stops_it_in_cleanup(self):
        source = (ROOT / "deploy/windows_admin_fixture.py").read_text()
        self.assertIn('"-m", "deploy.vm.console_backend"', source)
        self.assertLess(source.index("        start_backend()\n"), source.index("        forward = subprocess.Popen"))
        self.assertIn('("console backend stopped", stop_backend)', source)


class Screenshots(unittest.TestCase):
    def test_cancel_and_ok_of_one_confirmation_keep_their_own_shot(self):
        test = (ROOT / "apps/client/integration_test/windows_admin_test.dart").read_text()
        self.assertIn("await screenshot('confirm-$what-${ok ? 'ok' : 'cancel'}');", test)
        self.assertNotIn("await screenshot('confirm-$what');", test)


class FakeOperator:
    def __init__(self, pending, devices):
        self.pending, self.devices, self.calls = pending, devices, []

    def call(self, action, **data):
        self.calls.append((action, data))
        if action == "pending":
            return [dict(row) for row in self.pending]
        if action == "devices":
            return [dict(row) for row in self.devices]
        if action == "deny":
            next(row for row in self.pending if row["id"] == data["pairing_id"])["state"] = "denied"
            return {"state": "denied"}
        raise AssertionError(action)

    def revoke(self, identity):
        self.calls.append(("revoke", {"device_id": identity}))
        next(row for row in self.devices if row["id"] == identity)["state"] = "revoked"


class FakeCli:
    def __init__(self, admins, remove_works=True):
        self.admins, self.remove_works, self.calls = set(admins), remove_works, []

    def __call__(self, *args):
        self.calls.append(args)
        if args[0] == "admin-remove":
            if args[1] not in self.admins:
                return subprocess.CompletedProcess(args, 1, stdout="", stderr="ERROR not an admin")
            if self.remove_works:
                self.admins.discard(args[1])
            return subprocess.CompletedProcess(args, 0, stdout="{}", stderr="")
        if args[0] == "admins":
            return subprocess.CompletedProcess(args, 0, stdout=json.dumps(sorted(self.admins)), stderr="")
        raise AssertionError(args)


BOB, ALICE = fixture.BOB, fixture.ALICE


def temporary(case):
    path = Path(tempfile.mkdtemp(prefix="anj-w6-fixture-test-"))
    case.addCleanup(shutil.rmtree, path, ignore_errors=True)
    return path


def leftovers():
    pending = [{"id": "i-issued", "uid": BOB, "state": "issued"},
               {"id": "i-reserved", "uid": BOB, "state": "reserved"},
               {"id": "i-prov", "uid": BOB, "state": "provisioning"},
               {"id": "i-approved", "uid": BOB, "state": "approved"},
               {"id": "i-denied", "uid": BOB, "state": "denied"},
               {"id": "i-alice", "uid": ALICE, "state": "reserved"}]
    devices = [{"id": "d-bob", "uid": BOB, "state": "active"},
               {"id": "d-bob-old", "uid": BOB, "state": "revoked"},
               {"id": "d-alice", "uid": ALICE, "state": "active"}]
    return FakeOperator(pending, devices)


class ResetBob(unittest.TestCase):
    """Review 3: a failed run's invitation, device and admin role of Bob are withdrawn first."""

    def test_an_earlier_runs_bob_is_withdrawn_and_alice_is_untouched(self):
        operator, cli = leftovers(), FakeCli({ALICE, BOB})
        with patch("builtins.print"):
            fixture.reset_user(operator, cli, BOB)
        denied = sorted(data["pairing_id"] for action, data in operator.calls if action == "deny")
        revoked = [data["device_id"] for action, data in operator.calls if action == "revoke"]
        self.assertEqual(denied, ["i-issued", "i-prov", "i-reserved"])
        self.assertEqual(revoked, ["d-bob"])
        self.assertEqual(cli.admins, {ALICE})
        self.assertEqual(next(r for r in operator.pending if r["id"] == "i-alice")["state"], "reserved")
        self.assertEqual(next(r for r in operator.devices if r["id"] == "d-alice")["state"], "active")

    def test_a_clean_stack_resets_without_error(self):
        operator, cli = FakeOperator([], []), FakeCli(set())
        with patch("builtins.print"):
            fixture.reset_user(operator, cli, BOB)
        self.assertIn(("admin-remove", BOB), cli.calls)

    def test_bob_still_an_admin_fails_the_reset(self):
        operator, cli = leftovers(), FakeCli({BOB}, remove_works=False)
        with self.assertRaisesRegex(RuntimeError, "not reset"):
            fixture.reset_user(operator, cli, BOB)

    def test_every_run_scale_resets_bob_before_it_starts(self):
        order = []
        with patch.object(fixture, "reset_user", side_effect=lambda *a: order.append("reset")), \
                patch.object(fixture, "seat", side_effect=lambda *a, **k: order.append(a[0]) or ""), \
                patch("builtins.print"):
            operator = FakeOperator([], [])
            operator.call = lambda action, **data: (_ for _ in ()).throw(SystemExit("stop after the reset"))
            with self.assertRaises(SystemExit):
                fixture.run_scale(object(), operator, 100, temporary(self), [])
        self.assertEqual(order[0], "reset")


class GuestTaskStop(unittest.TestCase):
    """Review 4: past the deadline, the guest task is ended before the driver goes on."""

    def test_an_overrunning_guest_run_is_ended_before_cleanup(self):
        events = []

        class Runner:
            returncode = None

            def __init__(self, *args, **kwargs):
                kwargs["stdout"].close()

            def poll(self):
                return self.returncode

            def terminate(self):
                events.append("terminate")
                self.returncode = -15

            def wait(self, timeout=None):
                return self.returncode

            def kill(self):
                self.returncode = -9

        clock = iter(range(0, 10 ** 6, 1000))
        work = temporary(self)
        operator = FakeOperator([], [])
        operator.call = lambda action, **data: {"id": "i", "code": "C"} if action == "invite" else []
        with patch.object(fixture, "reset_user"), \
                patch.object(fixture, "seat", return_value=""), \
                patch.object(fixture, "guest_file", return_value=None), \
                patch.object(fixture, "stop_guest_task", side_effect=lambda: events.append("stop task")), \
                patch.object(fixture.subprocess, "Popen", Runner), \
                patch.object(fixture.subprocess, "run"), \
                patch.object(fixture.time, "monotonic", side_effect=lambda: next(clock)), \
                patch.object(fixture.time, "sleep"), \
                patch("builtins.print"), \
                self.assertRaises(SystemExit):
            stack = type("S", (), {"origin": "https://127.0.0.1:1", "local": work})()
            fixture.run_scale(stack, operator, 100, work, [])
        self.assertEqual(events, ["stop task", "terminate"])


if __name__ == "__main__":
    unittest.main()
