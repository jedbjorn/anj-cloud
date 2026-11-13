"""Spec #20 rev7 supervision: run-service, the PM2 ecosystem and prod.py through PM2.

Offline: `pm2` and `docker` are stubs (scripts on PATH or patched methods); a temporary git
repository stands in for the release source. No container, PM2 daemon or VM is touched.
"""

import contextlib
import io
import json
import os
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

from deploy import prod
from deploy.vm import paths, render, stackenv

ROOT = Path(__file__).resolve().parent.parent
HOST = "gateway.f15a.test"
RUN_SERVICE = ROOT / "deploy" / "vm" / "run-service"
COMMIT_ENV = {"GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.invalid", "GIT_COMMITTER_NAME": "t",
              "GIT_COMMITTER_EMAIL": "t@example.invalid"}

# A docker stub: logs every call; `inspect` reports running+healthy unless the service is listed
# in $STUB_UNHEALTHY; `compose ... up` blocks until signalled or exits with $STUB_EXIT.
DOCKER_STUB = r'''#!/bin/sh
echo "$*" >> "$STUB_LOG"
if [ "$1" = inspect ]; then
  for name in $STUB_UNHEALTHY; do
    case "$*" in *"-$name-1"*) echo '{"Running":true,"Health":{"Status":"starting"}}'; exit 0;; esac
  done
  echo '{"Running":true,"Health":{"Status":"healthy"}}'
  exit 0
fi
case "$*" in
  *" up "*) if [ -n "$STUB_EXIT" ]; then exit "$STUB_EXIT"; fi
            echo $$ > "$STUB_LOG.up"; trap 'exit 0' TERM INT; while :; do sleep 0.1; done;;
  "stop "*|*" stop "*) [ -f "$STUB_LOG.up" ] && kill "$(cat "$STUB_LOG.up")";;
esac
exit 0
'''


def load_service_module():
    """run-service as a module (it has no .py suffix)."""
    import importlib.machinery
    import importlib.util
    loader = importlib.machinery.SourceFileLoader("run_service", str(RUN_SERVICE))
    spec = importlib.util.spec_from_loader("run_service", loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


run_service = load_service_module()


class StateFixture:
    """A recorded production setup in a temporary state root."""

    def __init__(self, directory):
        self.root = Path(directory) / "state"
        self.root.mkdir(mode=0o700)
        (self.root / "run").mkdir(mode=0o700)
        config = {"host": HOST, "release": "a" * 40, "bind_address": "10.77.10.10", "household_lan": "192.168.0.0/24",
                  "vm_gid": 1000, "socket_dir": "/run/anj-cloud-gw"}
        (self.root / "stack.json").write_text(json.dumps(config))

    def flag(self):
        path = self.root / "run" / "emergency-stop"
        path.write_text('{"reason": "test"}')
        return path


class RunServiceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.state = StateFixture(self.temporary.name)

    def tearDown(self):
        self.temporary.cleanup()

    def test_unknown_app_and_missing_setup_are_refused(self):
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(2, run_service.run("postgres", self.state.root))
            (self.state.root / "stack.json").write_text("{}")
            self.assertEqual(1, run_service.run("db", self.state.root, popen=self.fail))

    def test_emergency_flag_refuses_only_ingress_apps_with_the_stop_exit_code(self):
        self.state.flag()
        with contextlib.redirect_stdout(io.StringIO()) as output:
            for app in paths.EMERGENCY_APPS:
                self.assertEqual(paths.EMERGENCY_EXIT_CODE, run_service.run(app, self.state.root, popen=self.fail))
        self.assertIn("emergency stop is active", output.getvalue())
        started = []

        class Child:
            def wait(self, timeout=None):
                return 0
        run_service.run("db", self.state.root, popen=lambda argv, env, **kw: started.append(argv) or Child(), ready=lambda p, s: True)
        self.assertEqual(1, len(started))

    def test_dependencies_are_waited_for_in_order_and_bounded(self):
        for app, needs in (("db", []), ("redis", []), ("nextcloud", ["db", "redis"]), ("cron", ["nextcloud"]),
                           ("gateway", ["nextcloud"]), ("haproxy", ["access"])):
            asked = []
            self.assertEqual([], run_service.wait_for_dependencies(app, paths.PROJECT, ready=lambda p, s: asked.append(s) or True))
            self.assertEqual(needs, asked, app)
        clock = [0.0]
        calls = []

        def ready(project, service):
            calls.append(service)
            return service != "access"
        missing = run_service.wait_for_dependencies("haproxy", paths.PROJECT, timeout=10, ready=ready, clock=lambda: clock[0],
                                                    sleep=lambda seconds: clock.__setitem__(0, clock[0] + seconds))
        self.assertEqual(["access"], missing)
        self.assertGreater(len(calls), 3)
        with contextlib.redirect_stderr(io.StringIO()) as error:
            code = run_service.run("haproxy", self.state.root, popen=self.fail, ready=lambda p, s: False, timeout=0,
                                   sleep=lambda s: None)
        self.assertEqual((1, True), (code, "access" in error.getvalue()))

    def test_compose_runs_the_one_service_attached_and_propagates_its_exit(self):
        seen = {}

        class Child:
            def wait(self, timeout=None):
                return 3

        def popen(argv, env, **kwargs):
            seen.update(argv=argv, env=env, **kwargs)
            return Child()
        code = run_service.run("gateway", self.state.root, popen=popen, ready=lambda p, s: True)
        self.assertEqual(3, code)
        self.assertEqual(["docker", "compose", "--env-file", "/dev/null", "--project-name", paths.PROJECT, "--file",
                          str(self.state.root / "release" / "aaaaaaaaaaaa" / "compose.json"),
                          "up", "--no-deps", "--no-log-prefix", "--exit-code-from", "access", "access"], seen["argv"])
        environment = seen["env"]
        self.assertEqual((HOST, "anj-cloud-prod-access:aaaaaaaaaaaa", str(self.state.root / "secrets")),
                         (environment["ANJ_HOST"], environment["ANJ_ACCESS_IMAGE"], environment["ANJ_SECRETS_DIR"]))
        self.assertEqual(str(self.state.root / "release" / "aaaaaaaaaaaa" / "haproxy.cfg"), environment["ANJ_HAPROXY_CFG"])
        self.assertEqual(str(self.state.root / "haproxy"), environment["ANJ_HAPROXY_STATE"])

    def test_compose_child_gets_a_parent_death_signal(self):
        seen = {}

        class Child:
            def wait(self, timeout=None):
                return 0
        run_service.run("db", self.state.root, popen=lambda argv, env, **kw: seen.update(kw) or Child(), ready=lambda p, s: True)
        self.assertIs(run_service.parent_death_signal, seen["preexec_fn"])

    def test_signal_before_or_during_compose_start_is_honoured(self):
        stops = []
        original = signal.getsignal(signal.SIGTERM)

        def ready(project, service):
            os.kill(os.getpid(), signal.SIGTERM)  # pm2 stop while waiting for dependencies
            return False
        code = run_service.run("nextcloud", self.state.root, popen=self.fail, ready=ready, sleep=lambda s: None,
                               stop=lambda project, service: stops.append(service))
        self.assertEqual((0, []), (code, stops))  # nothing started, nothing to stop

        class Child:
            def __init__(self):
                self.waits = 0

            def wait(self, timeout=None):
                self.waits += 1
                return 0

        def popen(argv, env, **kwargs):
            os.kill(os.getpid(), signal.SIGTERM)  # arrives while compose is starting
            return Child()
        code = run_service.run("nextcloud", self.state.root, popen=popen, ready=lambda p, s: True,
                               stop=lambda project, service: stops.append((project, service)))
        self.assertEqual((0, [(paths.PROJECT, "nextcloud")]), (code, stops))
        self.assertEqual(original, signal.getsignal(signal.SIGTERM))  # handlers restored afterwards

    def test_real_script_stops_its_container_on_sigterm_and_restarts_after_exit(self):
        """The executable as PM2 runs it, with stub docker on PATH."""
        directory = Path(self.temporary.name)
        stub = directory / "bin"
        stub.mkdir()
        (stub / "docker").write_text(DOCKER_STUB)
        (stub / "docker").chmod(0o755)
        log = directory / "docker.log"
        environment = dict(os.environ, PATH=f"{stub}:{os.environ['PATH']}", STUB_LOG=str(log), STUB_UNHEALTHY="")
        argv = [sys.executable, "-I", str(RUN_SERVICE), "nextcloud", "--state-root", str(self.state.root)]
        process = subprocess.Popen(argv, env=environment, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                   start_new_session=True)
        # Whatever happens, never leave the wrapper or its stub children running.
        self.addCleanup(lambda: process.poll() is not None or os.killpg(process.pid, signal.SIGKILL))
        self.addCleanup(lambda: process.poll() is not None or process.wait(timeout=5))
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline and not (log.exists() and " up " in log.read_text()):
            time.sleep(0.05)
        process.send_signal(signal.SIGTERM)
        self.assertEqual(0, process.wait(timeout=20))
        calls = log.read_text().splitlines()
        self.assertTrue(calls[0].startswith("inspect") and "anj-cloud-prod-db-1" in calls[0])
        self.assertTrue(any("anj-cloud-prod-redis-1" in call for call in calls))
        self.assertIn("up --no-deps --no-log-prefix --exit-code-from nextcloud nextcloud", calls[-2])
        self.assertEqual(f"stop --time {paths.STOP_GRACE_SECONDS} anj-cloud-prod-nextcloud-1", calls[-1])
        # A container exit ends the wrapper with its code, so PM2 restarts it.
        log.write_text("")
        environment["STUB_EXIT"] = "137"
        result = subprocess.run(argv, env=environment, capture_output=True, timeout=20, start_new_session=True)
        self.assertEqual(137, result.returncode)
        # Unhealthy dependency: no compose up until it is healthy (bounded wait elsewhere).
        environment.pop("STUB_EXIT")
        self.state.flag()
        result = subprocess.run([*argv[:3], "haproxy", "--state-root", str(self.state.root)], env=environment,
                                capture_output=True, timeout=20)
        self.assertEqual(paths.EMERGENCY_EXIT_CODE, result.returncode)

    def fail(self, *args, **kwargs):
        raise AssertionError("must not start a container")


class SuperviseTests(unittest.TestCase):
    def test_a_child_that_ignores_the_stop_is_terminated_after_the_grace(self):
        clock = [0.0]

        class Child:
            def __init__(self):
                self.events = []

            def wait(self, timeout=None):
                if "terminate" in self.events:
                    return -15
                clock[0] += 1
                raise subprocess.TimeoutExpired("compose", timeout)

            def terminate(self):
                self.events.append("terminate")

            def kill(self):
                self.events.append("kill")
        child = Child()
        self.assertEqual(-15, run_service.supervise(child, [(signal.SIGTERM, 0.0)], clock=lambda: clock[0], grace=5))
        self.assertEqual(["terminate"], child.events)
        self.assertGreater(clock[0], 5)


class EcosystemTests(unittest.TestCase):
    def setUp(self):
        self.text = render.ecosystem(state_root=paths.STATE_ROOT, bin_dir=paths.BIN_DIR)
        self.config = json.loads(self.text.split("module.exports = ", 1)[1].rstrip().rstrip(";"))

    def test_one_app_per_service_with_backoff_kill_timeout_and_stop_code(self):
        apps = self.config["apps"]
        self.assertEqual(list(paths.STACK_APPS), [app["name"] for app in apps])
        for app in apps:
            self.assertEqual((str(paths.BIN_DIR / "run-service"), "/usr/bin/python3", "-I"),
                             (app["script"], app["interpreter"], app["interpreter_args"]))
            self.assertEqual([app["name"], "--state-root", str(paths.STATE_ROOT), "--project", paths.PROJECT], app["args"])
            self.assertTrue(app["autorestart"])
            self.assertEqual(1000, app["exp_backoff_restart_delay"])
            # Above the worst stop path: docker stop (grace + 20 s) then terminate + kill (grace + 15 + 5 s).
            self.assertGreater(app["kill_timeout"], (paths.STOP_GRACE_SECONDS + 20 + 5) * 1000)
            self.assertGreater(app["kill_timeout"], (paths.STOP_GRACE_SECONDS + 15 + 5) * 1000)
            self.assertEqual([paths.EMERGENCY_EXIT_CODE], app["stop_exit_codes"])
            self.assertFalse(app["treekill"])
            quiet = app["name"] in ("nextcloud", "cron", "db", "redis")
            self.assertEqual(quiet, app.get("out_file") == "/dev/null" == app.get("error_file"), app["name"])
        self.assertNotIn("out_file", {key for app in apps if app["name"] in ("haproxy", "gateway") for key in app})

    @unittest.skipUnless(shutil.which("node"), "node not installed")
    def test_node_loads_the_rendered_ecosystem(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "ecosystem.config.js"
            path.write_text(self.text)
            output = subprocess.run(["node", "-e", f"console.log(JSON.stringify(require({json.dumps(str(path))}).apps.map(a => a.name)))"],
                                    capture_output=True, text=True, check=True, timeout=30).stdout
        self.assertEqual(list(paths.STACK_APPS), json.loads(output))


class Pm2Stub:
    """Records pm2 calls; `jlist` reports the apps' states."""

    def __init__(self, states=None):
        self.calls = []
        self.states = dict(states or {})

    def __call__(self, *args):
        self.calls.append(args)
        if args[0] == "jlist":
            return json.dumps([{"name": name, "pid": 1, "pm2_env": {"status": status, "restart_time": 0}}
                               for name, status in self.states.items()])
        if args[0] in ("stop",):
            self.states[args[1]] = "stopped"
        if args[0] in ("restart",):
            self.states[args[1]] = "online"
        if args[0] == "start":
            self.states[args[-1]] = "online"
        return ""


class ProdThroughPm2Tests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.stack = prod.ProdStack("anj-cloud-test-prod", Path(self.temporary.name) / "state")
        self.stack.save_config(host=HOST, release="a" * 40, bind_address="10.77.10.10", household_lan="192.168.0.0/24",
                               vm_gid=os.getgid())
        self.pm2 = Pm2Stub({app: "online" for app in paths.STACK_APPS})

    def tearDown(self):
        self.temporary.cleanup()

    def patched(self, **extra):
        stack = self.stack
        patches = [patch.object(stack, "pm2", side_effect=self.pm2), patch.object(stack, "wait_ready"),
                   patch.object(stack, "ensure_tls_fresh"), patch.object(stack, "status", return_value={"apps": {}}),
                   patch.object(stack, "check", return_value={"checked": True}),
                   patch.object(stack, "apply_trash", return_value=7), patch.object(stack, "advertise_trash", return_value=7),
                   patch.object(stack, "migrate_names", return_value={"renamed": 0})]
        patches += [patch.object(stack, name, **value) for name, value in extra.items()]
        stack_context = contextlib.ExitStack()
        for item in patches:
            stack_context.enter_context(item)
        return stack_context

    def test_emergency_stop_writes_the_flag_stops_ingress_and_saves(self):
        with self.patched():
            result = self.stack.emergency_stop("Port 8080 answered from outside")
        flag = self.stack.local / "run" / "emergency-stop"
        self.assertEqual(0o600, stat.S_IMODE(flag.stat().st_mode))
        self.assertEqual("Port 8080 answered from outside", json.loads(flag.read_text())["reason"])
        self.assertEqual([("stop", "haproxy"), ("stop", "gateway"), ("stop", "fetch"), ("stop", "fetch-net"), ("save",)], self.pm2.calls)
        self.assertEqual(["haproxy", "gateway", "fetch", "fetch-net"], result["stopped"])
        for reason in ("", "x" * 201, "line\nbreak"):
            with self.subTest(reason=reason), self.assertRaisesRegex(RuntimeError, "--reason"):
                self.stack.emergency_stop(reason)
        # While flagged, up starts and expects only the other apps.
        self.assertEqual(["db", "redis", "nextcloud", "cron"], self.stack.active_apps())

    def dispatcher(self, exit_code=0):
        log = Path(self.temporary.name) / "alerts.log"
        command = self.stack.local / "bin" / "anj-alert"
        command.parent.mkdir(mode=0o700, exist_ok=True)
        command.write_text(f'#!/bin/sh\nfor a in "$@"; do printf "%s\\n" "$a"; done >> "{log}"\necho --- >> "{log}"\nexit {exit_code}\n')
        command.chmod(0o700)
        return log

    def spooled(self):
        spool = self.stack.local / "run" / "alerts"
        return [json.loads(path.read_text()) for path in sorted(spool.glob("*.json"))] if spool.exists() else []

    def test_emergency_stop_alerts_once_through_the_dispatcher(self):
        log = self.dispatcher()
        with self.patched():
            result = self.stack.emergency_stop("Port 8080 answered from outside")
        calls = log.read_text().split("---\n")[:-1]
        self.assertEqual(1, len(calls))
        argv = calls[0].splitlines()
        self.assertEqual(["--key", "emergency-stop", "--every", "0"], argv[:4])
        self.assertIn("--", argv)
        message = argv[argv.index("--") + 1]
        self.assertIn("Port 8080 answered from outside", message)
        self.assertIn(HOST, message)
        self.assertEqual(("dispatcher", []), (result["alert"], self.spooled()))
        # resume sends one "re-enabled" message.
        with self.patched():
            result = self.stack.resume()
        calls = log.read_text().split("---\n")[:-1]
        self.assertEqual(2, len(calls))
        argv = calls[1].splitlines()
        self.assertEqual(["--key", "emergency-resume"], argv[:2])
        self.assertIn("re-enabled", argv[argv.index("--") + 1])
        self.assertEqual("dispatcher", result["alert"])

    def test_missing_or_failing_dispatcher_spools_and_never_fails_the_stop(self):
        with self.patched():
            result = self.stack.emergency_stop("scan showed 22/tcp open")
        self.assertEqual("spool", result["alert"])
        records = self.spooled()
        self.assertEqual(1, len(records))
        self.assertEqual(set(paths.ALERT_SPOOL_FIELDS), set(records[0]))
        self.assertEqual("emergency-stop", records[0]["key"])
        self.assertIn("scan showed 22/tcp open", records[0]["message"])
        for path in (self.stack.local / "run" / "alerts").iterdir():
            self.assertEqual(0o600, stat.S_IMODE(path.stat().st_mode))
        self.assertEqual(0o700, stat.S_IMODE((self.stack.local / "run" / "alerts").stat().st_mode))
        prod.check_private_tree(self.stack.local)
        self.dispatcher(exit_code=1)
        with self.patched():
            self.assertEqual("spool", self.stack.resume()["alert"])
        self.assertEqual(["emergency-stop", "emergency-resume"], [record["key"] for record in self.spooled()])

    def test_alert_goes_out_even_when_pm2_fails(self):
        log = self.dispatcher()

        def failing(*args):
            raise RuntimeError("Command failed (exit 1); output withheld: pm2")
        with patch.object(self.stack, "pm2", side_effect=failing), self.assertRaisesRegex(RuntimeError, "pm2"):
            self.stack.emergency_stop("forward pointed elsewhere")
        self.assertTrue((self.stack.local / "run" / "emergency-stop").exists())
        self.assertEqual(1, log.read_text().count("--key\nemergency-stop"))

    def test_resume_clears_the_flag_and_starts_gateway_then_haproxy(self):
        with self.patched():
            self.stack.emergency_stop("drill")
            self.pm2.calls.clear()
            self.stack.resume()
        self.assertFalse((self.stack.local / "run" / "emergency-stop").exists())
        self.assertEqual([("jlist",), ("restart", "gateway"), ("restart", "haproxy"), ("restart", "fetch-net"), ("restart", "fetch"),
                          ("save",)], self.pm2.calls)
        self.assertEqual(list(paths.STACK_APPS), self.stack.active_apps())

    def test_up_starts_backend_first_then_the_rest_and_saves(self):
        self.pm2.states = {}
        order = []
        with self.patched(preflight_runtime_dirs={"return_value": None}, build={"return_value": "image"},
                          export_release={"return_value": None}, activate_release={"return_value": None},
                          configure_nextcloud={"side_effect": lambda: order.append("configure")}):
            self.stack.wait_ready.side_effect = lambda apps: order.append(("wait", tuple(apps)))
            self.assertEqual({"checked": True, "name_migration": {"renamed": 0}}, self.stack.up())
        starts = [call[-1] for call in self.pm2.calls if call[0] == "start"]
        self.assertEqual(list(paths.STACK_APPS), starts)
        self.assertEqual(("save",), self.pm2.calls[-1])
        self.assertEqual([("wait", ("db", "redis", "nextcloud")), "configure", ("wait", paths.STACK_APPS)], order)

    def test_up_under_emergency_stop_leaves_ingress_down(self):
        self.pm2.states = {}
        with self.patched():
            self.stack.emergency_stop("drill")
        self.pm2.states = {}
        self.pm2.calls.clear()
        with self.patched(preflight_runtime_dirs={"return_value": None}, build={"return_value": "image"},
                          export_release={"return_value": None}, activate_release={"return_value": None},
                          configure_nextcloud={"return_value": None}):
            self.stack.up()
            self.stack.ensure_tls_fresh.assert_not_called()
        started = {call[-1] for call in self.pm2.calls if call[0] in ("start", "restart")}
        self.assertEqual({"db", "redis", "nextcloud", "cron"}, started)

    def test_stop_is_front_to_back_and_not_saved(self):
        with self.patched():
            self.stack.stop()
        self.assertEqual([("stop", app) for app in reversed(paths.STACK_APPS)], self.pm2.calls)

    def redeploy_patches(self, events, check=None):
        record = lambda name: (lambda *args, **kwargs: events.append((name, self.stack.release[:1])))
        return dict(preflight_runtime_dirs={"return_value": None}, resolve_commit={"return_value": "b" * 40},
                    build={"side_effect": record("build")}, export_release={"side_effect": record("export")},
                    verify_release={"side_effect": record("verify")}, activate_release={"side_effect": record("activate")},
                    install_bin={"side_effect": record("bin")})

    def test_redeploy_verifies_first_restarts_in_order_and_switches_only_after_a_healthy_check(self):
        events = []
        with self.patched(**self.redeploy_patches(events)):
            self.stack.wait_ready.side_effect = lambda apps: events.append(("wait", tuple(apps)))
            self.stack.check.side_effect = lambda: events.append(("check", self.stack.release[:1])) or {"checked": True}
            result = self.stack.redeploy("bbbbbbbbbbbb")
        names = [event[0] for event in events]
        self.assertEqual(["build", "export", "verify"], names[:3])
        self.assertEqual([("build", "a"), ("export", "a"), ("verify", "a")], events[:3])  # nothing recorded yet
        self.assertEqual([("wait", (app,)) for app in paths.STACK_APPS], [e for e in events if e[0] == "wait"])
        self.assertLess(names.index("check"), names.index("activate"))
        self.assertEqual(("activate", "b"), events[-1])
        restarts = [call[1] for call in self.pm2.calls if call[0] == "restart"]
        self.assertEqual(list(paths.STACK_APPS), restarts)
        self.assertEqual(("b" * 40, "a" * 40, "aaaaaaaaaaaa"),
                         (self.stack.release, self.stack.config["previous_release"], result["previous_release"]))
        self.assertEqual(("save",), self.pm2.calls[-1])
        self.assertEqual({"console": "not running", "watchdog": "not running", "watchers": "not running"},
                         result["operations"])

    def test_redeploy_restarts_console_and_watchdog_onto_the_new_release_after_the_switch(self):
        """Decision #114: the operations apps that run release/current's code restart after it
        points at the new release, inside the redeploy run; the other operations apps do not."""
        events = []
        self.pm2.states.update(console="online", watchdog="online", watchers="online", alerts="online")
        original = self.pm2

        def pm2(*args):
            if args[0] == "restart" and args[1] in ("console", "watchdog", "watchers"):
                events.append(("restart " + args[1], self.stack.release[:1]))
            return original(*args)
        with self.patched(**self.redeploy_patches(events), pm2={"side_effect": pm2}):
            self.stack.check.side_effect = lambda: {"checked": True}
            result = self.stack.redeploy("bbbbbbbbbbbb")
        names = [event[0] for event in events]
        self.assertEqual(["activate", "restart console", "restart watchdog", "restart watchers"], names[-4:],
                         "after the switch")
        self.assertEqual({"console": "restarted", "watchdog": "restarted", "watchers": "restarted"}, result["operations"])
        restarted = [call[1] for call in self.pm2.calls if call[0] == "restart"]
        self.assertNotIn("alerts", restarted)
        self.assertNotIn("ddns", restarted)
        self.assertEqual(("save",), self.pm2.calls[-1])
        # A failed restart after the switch is reported and alerted; the release stays switched.
        self.pm2.calls.clear()
        self.stack.save_config(release="a" * 40)
        alerts = []

        def failing(*args):
            if args[:2] == ("restart", "console"):
                raise RuntimeError("Command failed (exit 1)")
            return original(*args)
        with self.patched(**self.redeploy_patches([]), pm2={"side_effect": failing},
                          alert={"side_effect": lambda *a, **k: alerts.append(a[0])}):
            self.stack.check.side_effect = lambda: {"checked": True}
            result = self.stack.redeploy("bbbbbbbbbbbb")
        self.assertEqual({"console": "restart failed", "watchdog": "restarted", "watchers": "restarted"},
                         result["operations"])
        self.assertEqual(["redeploy-ops"], alerts)
        self.assertEqual("b" * 40, self.stack.release)

    def test_failed_redeploy_rolls_back_and_never_switches_the_live_release(self):
        events = []
        with self.patched(**self.redeploy_patches(events)):
            self.stack.check.side_effect = RuntimeError("Gateway healthcheck is not ready")
            with self.assertRaisesRegex(RuntimeError, r"Redeploy of bbbbbbbbbbbb failed \(Gateway healthcheck is not ready\); "
                                                      r"release/current stays on aaaaaaaaaaaa, restarted on aaaaaaaaaaaa"):
                self.stack.redeploy("bbbbbbbbbbbb")
        self.assertNotIn("activate", [event[0] for event in events])
        self.assertEqual("a" * 40, self.stack.release)
        self.assertNotIn("previous_release", self.stack.config)
        restarts = [call[1] for call in self.pm2.calls if call[0] == "restart"]
        self.assertEqual(list(paths.STACK_APPS) * 2, restarts)  # onto the new release, then back
        self.assertEqual(("save",), self.pm2.calls[-1])
        # A failed verification restarts nothing and changes nothing.
        self.pm2.calls.clear()
        events.clear()
        with self.patched(**self.redeploy_patches(events)):
            self.stack.verify_release.side_effect = RuntimeError("Release bbbbbbbbbbbb is missing haproxy.cfg")
            with self.assertRaisesRegex(RuntimeError, "missing haproxy.cfg"):
                self.stack.redeploy("bbbbbbbbbbbb")
        self.assertEqual(([], "a" * 40), (self.pm2.calls, self.stack.release))

    def test_status_maps_pm2_states_into_the_documented_values(self):
        cases = {("db", "waiting restart", False): "launching", ("db", "one-launch-status", False): "stopped",
                 ("db", "online", False): "online", ("db", "something-new", False): "errored", ("db", None, False): "missing",
                 ("gateway", "waiting restart", True): "stopped", ("haproxy", "errored", True): "stopped",
                 ("haproxy", "online", True): "online", ("cron", "waiting restart", True): "launching"}
        for (app, raw, flagged), expected in cases.items():
            with self.subTest(app=app, raw=raw, flagged=flagged):
                status = prod.ProdStack.app_status(app, raw, flagged)
                self.assertEqual(expected, status)
                self.assertIn(status, prod.STATUS_VALUES)
        # Through status(): an emergency-held app exiting 78 shows "waiting restart" in PM2.
        self.pm2.states = {app: "online" for app in paths.STACK_APPS}
        self.pm2.states.update(gateway="waiting restart", haproxy="stopped", db="one-launch-status")
        with self.patched():
            self.stack.emergency_stop("drill")
        self.pm2.states.update(gateway="waiting restart")
        with patch.object(self.stack, "pm2", side_effect=self.pm2), patch.object(self.stack, "containers", return_value=[]), \
                patch.object(self.stack, "compose", side_effect=RuntimeError("exec failed")):
            status = self.stack.status()
        self.assertEqual({"gateway": "stopped", "haproxy": "stopped", "db": "stopped", "nextcloud": "online"},
                         {app: status["apps"][app]["status"] for app in ("gateway", "haproxy", "db", "nextcloud")})

    def test_emergency_alert_goes_out_before_the_stops(self):
        order = []
        with patch.object(self.stack, "pm2", side_effect=lambda *args: order.append(("pm2",) + args) or ""), \
                patch.object(self.stack, "alert", side_effect=lambda key, *a, **k: order.append(("alert", key)) or "dispatcher"):
            self.stack.emergency_stop("drill")
        self.assertTrue((self.stack.local / "run" / "emergency-stop").exists())
        self.assertEqual([("alert", "emergency-stop"), ("pm2", "stop", "haproxy"), ("pm2", "stop", "gateway"), ("pm2", "stop", "fetch"),
                          ("pm2", "stop", "fetch-net"), ("pm2", "save")], order)

    def test_status_shape_has_every_app_with_fixed_keys(self):
        self.pm2.states = {"db": "online", "redis": "online", "nextcloud": "online", "cron": "online", "gateway": "stopped"}
        containers = [{"Config": {"Labels": {"com.docker.compose.service": "db"}}, "State": {"Status": "running", "Health": {"Status": "healthy"}}},
                      {"Config": {"Labels": {"com.docker.compose.service": "access"}}, "State": {"Status": "exited"}}]
        with patch.object(self.stack, "pm2", side_effect=self.pm2), patch.object(self.stack, "containers", return_value=containers), \
                patch.object(self.stack, "compose", side_effect=RuntimeError("exec failed")):
            status = self.stack.status()
        self.assertEqual({"project", "host", "release", "emergency_stop", "apps", "healthcheck"}, set(status))
        self.assertEqual(list(paths.STACK_APPS), list(status["apps"]))
        for app, state in status["apps"].items():
            self.assertEqual({"status", "restarts", "pid", "service"}, set(state), app)
        self.assertEqual(("stopped", "missing"), (status["apps"]["gateway"]["status"], status["apps"]["haproxy"]["status"]))
        self.assertEqual({"status": "running", "health": "healthy"}, status["apps"]["db"]["service"])
        self.assertIsNone(status["apps"]["redis"]["service"])
        self.assertEqual(("unavailable", False, "aaaaaaaaaaaa"), (status["healthcheck"], status["emergency_stop"], status["release"]))
        json.dumps(status)

    def test_runtime_directory_preflight(self):
        self.stack.socket_dir = str(Path(self.temporary.name) / "gw")
        self.stack.config["haproxy_run_dir"] = str(Path(self.temporary.name) / "haproxy-run")
        with self.assertRaisesRegex(RuntimeError, "missing"):
            self.stack.preflight_runtime_dirs()
        Path(self.stack.socket_dir).mkdir(mode=0o750)
        with self.assertRaisesRegex(RuntimeError, "10001:10002 mode 0o2750"):
            self.stack.preflight_runtime_dirs()
        # Decision #112 (1): the console socket directory is checked too (owner: this account).
        self.stack.config["console_dir"] = str(Path(self.temporary.name) / "console")
        Path(self.stack.config["haproxy_run_dir"]).mkdir(mode=0o750)
        # The other two pass as if tmpfiles made them (their owners cannot be created on the VM host).
        fixed = {self.stack.socket_dir: (10001, 10002, 0o2750),
                 self.stack.config["haproxy_run_dir"]: (0, self.stack.config.get("vm_gid"), 0o750)}

        def lstat(path):
            info = os.lstat(path)
            if str(path) not in fixed:
                return info
            uid, gid, mode = fixed[str(path)]
            values = list(info)
            values[0], values[4], values[5] = stat.S_IFDIR | mode, uid, gid
            return os.stat_result(values)
        with patch.object(Path, "lstat", lstat):
            with self.assertRaisesRegex(RuntimeError, "console is missing"):
                self.stack.preflight_runtime_dirs()
            Path(self.stack.config["console_dir"]).mkdir(mode=0o750)
            with self.assertRaisesRegex(RuntimeError, "console must be %d:10002 mode 0o2750" % os.getuid()):
                self.stack.preflight_runtime_dirs()
            fixed[self.stack.config["console_dir"]] = (os.getuid(), 10002, 0o2750)
            self.stack.preflight_runtime_dirs()


class ReleaseExportTests(unittest.TestCase):
    """export_release from a release's own source.tar; state/bin run-service works as PM2 runs it."""

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.repository), *args], capture_output=True, text=True, check=True,
                              env={**os.environ, **COMMIT_ENV}).stdout.strip()

    def test_export_writes_source_rendered_configs_and_bin(self):
        with tempfile.TemporaryDirectory() as directory:
            self.repository = Path(directory) / "repo"
            for name in ("deploy/compose.prod.json", "deploy/prod/haproxy.cfg.tmpl", "deploy/vm/run-service",
                         "deploy/vm/paths.py", "deploy/vm/stackenv.py", "services/access/Dockerfile"):
                target = self.repository / name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(ROOT / name, target)
            self.git("init", "-q", "-b", "main")
            self.git("add", "-A")
            self.git("commit", "-q", "-m", "release")
            commit = self.git("rev-parse", "HEAD")
            stack = prod.ProdStack("anj-cloud-test-prod", Path(directory) / "state", checkout=self.repository)
            stack.save_config(host=HOST, release=commit, bind_address="10.77.10.10", household_lan="192.168.0.0/24",
                              vm_gid=os.getgid())
            target = stack.export_release(commit)
            names = {path.name for path in target.iterdir()}
            self.assertEqual({"source.tar", "compose.json", "haproxy.cfg", "ecosystem.config.js", "release.json"}, names)
            self.assertEqual(0o644, stat.S_IMODE((target / "haproxy.cfg").stat().st_mode))
            for name in names - {"haproxy.cfg"}:
                self.assertEqual(0o600, stat.S_IMODE((target / name).stat().st_mode), name)
            self.assertIn("bind 10.77.10.10:443", (target / "haproxy.cfg").read_text())
            self.assertEqual(json.loads((ROOT / "deploy" / "compose.prod.json").read_text()),
                             json.loads((target / "compose.json").read_text()))
            record = json.loads((target / "release.json").read_text())
            self.assertEqual(commit, record["commit"])
            self.assertEqual(64, len(record["source_sha256"]))
            # Export switches nothing live: no state/bin, no release/current yet.
            current = Path(directory) / "release" / "current"
            self.assertFalse((stack.local / "bin").exists() or os.path.lexists(current))
            self.assertTrue((Path(directory) / "release" / commit[:12] / "deploy" / "vm" / "run-service").is_file())
            with patch.object(stack, "image_revision", return_value=commit), patch.object(stack, "run", return_value="") as run:
                self.assertTrue(stack.verify_release(commit))
            self.assertEqual(["config", "--quiet"], run.call_args[0][0][-2:])
            (target / "haproxy.cfg").chmod(0o600)
            (target / "haproxy.cfg").write_text("bind {{BIND_ADDRESS}}")
            with patch.object(stack, "image_revision", return_value=commit), self.assertRaisesRegex(RuntimeError, "unrendered"):
                stack.verify_release(commit)
            stack.export_release(commit)
            stack.activate_release(commit)
            self.assertEqual({"run-service", "paths.py", "stackenv.py"}, {path.name for path in (stack.local / "bin").iterdir()})
            prod.check_private_tree(stack.local)
            # The stable release path: <data root>/release/current -> <commit12>, extracted source.
            self.assertEqual((True, commit[:12]), (current.is_symlink(), os.readlink(current)))
            self.assertTrue((current / "deploy" / "vm" / "run-service").is_file())
            self.assertEqual((ROOT / "deploy" / "vm" / "paths.py").read_text(), (current / "deploy" / "vm" / "paths.py").read_text())
            # The source survives without the checkout: a second export reads source.tar only.
            shutil.rmtree(self.repository)
            stack.export_release(commit)
            # The installed run-service runs standalone from state/bin (no repository on sys.path).
            result = subprocess.run([sys.executable, "-I", str(stack.local / "bin" / "run-service"), "postgres"],
                                    capture_output=True, text=True, timeout=30)
            self.assertEqual(2, result.returncode)
            (stack.local / "run").mkdir(mode=0o700, exist_ok=True)
            (stack.local / "run" / "emergency-stop").write_text("{}")
            result = subprocess.run([sys.executable, "-I", str(stack.local / "bin" / "run-service"), "gateway",
                                     "--state-root", str(stack.local)], capture_output=True, text=True, timeout=30)
            self.assertEqual(paths.EMERGENCY_EXIT_CODE, result.returncode)


class HaproxyCheckTests(unittest.TestCase):
    """The rendered template passes `haproxy -c` on the pinned image, in a bounded container."""

    @unittest.skipUnless(shutil.which("docker") and os.environ.get("ANJ_SKIP_DOCKER") != "1", "docker not available")
    def test_rendered_template_passes_haproxy_check(self):
        image = json.loads((ROOT / "deploy" / "compose.prod.json").read_text())["services"]["haproxy"]["image"]
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "haproxy.cfg"
            state = Path(directory) / "haproxy"
            state.mkdir()
            acl = state / "household.acl"
            config.write_text(render.haproxy((ROOT / "deploy" / "prod" / "haproxy.cfg.tmpl").read_text(), vm_gid=1000))
            acl.write_text("203.0.113.7\n")
            for path in (Path(directory), state, config, acl):
                path.chmod(0o755 if path.is_dir() else 0o644)
            result = subprocess.run(["docker", "run", "--rm", "--memory", "256m", "--pids-limit", "64", "--network", "none",
                                     "--label", "anj.owner=" + os.environ.get("ANJ_TEST_OWNER", "tests"),
                                     "--cap-drop", "ALL", "--security-opt", "no-new-privileges",
                                     "--volume", f"{config}:/usr/local/etc/haproxy/haproxy.cfg:ro",
                                     "--volume", f"{state}:{paths.HAPROXY_STATE_DIR}:ro",
                                     image, "haproxy", "-c", "-f", "/usr/local/etc/haproxy/haproxy.cfg"],
                                    capture_output=True, text=True, timeout=300)
        self.assertEqual(0, result.returncode, result.stdout[-500:] + result.stderr[-500:])


class StackEnvironmentTests(unittest.TestCase):
    def test_inherited_values_never_leak_into_compose(self):
        config = {"host": HOST, "release": "c" * 40}
        environment = stackenv.environment(paths.STATE_ROOT, config,
                                           base={"PATH": "/usr/bin", "ANJ_HOST": "evil.example", "COMPOSE_FILE": "x", "SC_DEV_PORT": "1"})
        self.assertEqual(("/usr/bin", HOST), (environment["PATH"], environment["ANJ_HOST"]))
        self.assertNotIn("COMPOSE_FILE", environment)
        self.assertNotIn("SC_DEV_PORT", environment)
        self.assertEqual(str(paths.GATEWAY_SOCKET_DIR), environment["ANJ_SOCKET_DIR"])
        self.assertEqual(str(paths.HAPROXY_RUN_DIR), environment["ANJ_HAPROXY_RUN_DIR"])
        self.assertEqual(str(paths.CONSOLE_DIR), environment["ANJ_CONSOLE_DIR"])


if __name__ == "__main__":
    unittest.main()
