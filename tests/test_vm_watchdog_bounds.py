"""Decision #111 (supersedes #105; PR #45 review round 2, N1-N3): every quiet or "not yet" state of the VM watchdog
is bounded in time, and its expiry raises exactly one alert naming the reason.

Seeded from the reviewer's simulator (qualification/pr45-independent-review-cd2bce3/m3_sim.py):
the real vmops.Probe and watchdog.Watchdog run against a fake runner (PM2, Docker, Nextcloud
status.php) and a fake /proc, minute by minute over hours of simulated time. Nothing real is run.
"""

import datetime
import importlib.machinery
import importlib.util
import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest import mock

from deploy.vm import paths

ROOT = Path(__file__).resolve().parent.parent
OPS = ROOT / "deploy" / "vm" / "ops"
T0 = 1_800_000_000.0
APPS = paths.STACK_APPS + paths.WATCHED_EXTRA_APPS


def load_watchdog():
    loader = importlib.machinery.SourceFileLoader("anj_ops_watchdog_bounds", str(OPS / "watchdog"))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module, sys.modules["vmops"]


def iso(timestamp):
    return datetime.datetime.fromtimestamp(timestamp, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.123456789Z")


class World:
    """The VM as the watchdog sees it. Every app is healthy unless a scenario changes it."""

    def __init__(self):
        self.now = T0
        self.pm2 = {app: {"status": "online", "restart_time": 0, "since": T0 - 7200} for app in APPS}
        self.containers = {service: {"running": True, "started": T0 - 7200, "health": "healthy"}
                           for service in ("db", "redis", "nextcloud", "access")}
        self.containers.update(cron={"running": True, "started": T0 - 7200, "health": None},
                               haproxy={"running": True, "started": T0 - 7200, "health": None})
        self.gateway_ready = True
        self.console_answers = True            # the console backend's socket (spec #27)
        self.maintenance = False
        self.pm2_readable = True
        self.execs = []

    def run(self, argv, **_options):
        if argv[:2] == ["pm2", "jlist"]:
            if not self.pm2_readable:
                return 124, "", "timed out"
            return 0, json.dumps([{"name": name, "pid": 1, "pm2_env": {
                "status": row["status"], "restart_time": row["restart_time"], "pm_uptime": row["since"] * 1000}}
                for name, row in self.pm2.items()]), ""
        if argv[:2] == ["docker", "inspect"]:
            service = argv[-1][len(paths.PROJECT) + 1:-2]
            row = self.containers[service]
            if not row["running"]:
                return 0, json.dumps({"Running": False}), ""
            state = {"Running": True, "StartedAt": iso(row["started"])}
            if row["health"]:
                state["Health"] = {"Status": row["health"]}
            return 0, json.dumps(state), ""
        target = next((part for part in argv[2:] if part.startswith(paths.PROJECT + "-")), "")
        if argv[:2] == ["docker", "exec"] and target.endswith("-access-1") and not self.containers["access"]["running"]:
            return 1, "", "container is not running"
        if argv[:2] == ["docker", "exec"]:
            self.execs.append(target)
        if argv[:2] == ["docker", "exec"] and "access.health" in argv:
            return (0, '{"status": "ready"}\n', "") if self.gateway_ready else (124, "", "timed out")
        if argv[:2] == ["docker", "exec"]:                       # Nextcloud status.php
            return 0, json.dumps({"installed": True, "maintenance": self.maintenance}) + "\n", ""
        return 1, "", "not modelled"


class Fixture(unittest.TestCase):
    """The real probe and watchdog against World, a fake clock and fake actions.

    Every scenario starts as production does, from a warm history: WARM healthy minutes run before
    T0 (review round 7, Z1: an empty history hid that pre-outage healthy rounds counted)."""

    WARM = 60

    def setUp(self):
        self.module, self.vmops = load_watchdog()
        self.world = World()
        self.alerts, self.restarts, self.alert_times = [], [], []
        self.reasons = []
        self.bounds = self.vmops.health_bounds(ROOT / "deploy" / "compose.prod.json")
        self.scratch = Path(tempfile.mkdtemp(prefix="anj-b2-wd-"))
        self.addCleanup(shutil.rmtree, self.scratch, True)
        patcher = mock.patch.object(self.vmops, "haproxy_path", lambda *a, **k: True)
        patcher.start()
        self.addCleanup(patcher.stop)
        patcher = mock.patch.object(self.vmops, "console_answers", lambda *a, **k: self.world.console_answers)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.emergency = False
        self.dog = self.make_dog()
        self.warm(self.WARM)

    def warm(self, minutes):
        """Healthy rounds ending at T0; nothing may be raised by them."""
        self.world.now = T0 - 60 * minutes
        self.run_minutes(minutes)
        assert self.world.now == T0 and not self.alerts and not self.restarts, self.alerts
        del self.alert_times[:], self.messages[:]
        self.priorities = []

    def make_dog(self, quiet=None):
        world = self

        def probe(apps, skip=()):
            check = self.vmops.Probe(self.world, state_root=self.scratch, clock=lambda: self.world.now,
                                     bounds=self.bounds)
            results = check.results(apps, skip=skip)
            world.snapshot = check.pm2
            return results

        def restart(app):
            self.restarts.append(app)
            row = self.world.pm2[app]
            row["restart_time"] += 1               # the watchdog's own `pm2 restart`
            row["since"] = self.world.now

        def alert(key, title, message, priority="high"):
            self.alerts.append(key)
            self.alert_times.append(self.world.now - T0)
            self.messages.append(message)
            self.priorities.append(priority)

        self.messages, self.priorities = [], []
        return self.module.Watchdog(
            probe=probe, restart=restart, alert=alert, clock=lambda: self.world.now,
            quiet=quiet or (lambda: list(self.reasons)), emergency=lambda: self.emergency,
            pm2=lambda: getattr(world, "snapshot", None) or {}, bounds=self.bounds,
            restart_counts=lambda: {name: row.get("restarts") for name, row in (world.snapshot or {}).items()})

    def run_minutes(self, count, each=None):
        reports = []
        for _ in range(count):
            if each:
                each(self.world.now - T0)
            reports.append(self.dog.tick())
            self.world.now += 60
        return reports

    def window(self, app):
        return self.module.NOT_YET_FACTOR * self.vmops.health_window(app, self.bounds)



class Bounded(Fixture):
    # N1: crash loops --------------------------------------------------------------------------
    def crash_phase(self, elapsed, *, count_restarts):
        """The reviewer's crash loop: the gateway's container dies ~20 s after each start, so PM2
        cycles waiting-restart -> online without a container -> health starting, never errored."""
        phase = int(elapsed // 60) % 3
        row, container = self.world.pm2["gateway"], self.world.containers["access"]
        row["status"] = "waiting restart" if phase == 0 else "online"
        if phase == 1:
            row["since"] = self.world.now - 5
        if count_restarts:
            row["restart_time"] += 2               # PM2's backoff is capped at 15 s: ~2 restarts a minute
        container.update(running=phase == 2, started=self.world.now - 10, health="starting")

    def test_crash_loop_without_restart_counts_alerts_once_at_the_not_yet_bound(self):
        """Review N1 exactly as simulated (PM2's restart_time never moves): 2 hours -> one alert."""
        self.run_minutes(120, lambda elapsed: self.crash_phase(elapsed, count_restarts=False))
        self.assertEqual(self.restarts, [])
        self.assertEqual(self.alerts, ["watchdog:down:gateway"])
        self.assertLessEqual(self.alert_times[0], self.window("gateway") + 60)
        self.assertIn("has not been healthy", self.messages[0])

    def test_crash_loop_counted_from_pm2_restarts_alerts_once_and_never_restarts(self):
        self.run_minutes(120, lambda elapsed: self.crash_phase(elapsed, count_restarts=True))
        self.assertEqual(self.restarts, [])
        self.assertEqual(self.alerts, ["watchdog:crashloop:gateway"])
        self.assertIn("crash loop", self.messages[0])
        self.assertLessEqual(self.alert_times[0], 3 * 60)        # the 4th restart within 10 minutes

    def test_crash_loop_then_recovered_once(self):
        self.run_minutes(30, lambda elapsed: self.crash_phase(elapsed, count_restarts=True))
        self.world.pm2["gateway"].update(status="online", since=self.world.now - 600)
        self.world.containers["access"].update(running=True, started=self.world.now - 600, health="healthy")
        self.run_minutes(30)        # one continuous episode: "recovered" on its first healthy round
        self.assertEqual(self.alerts, ["watchdog:crashloop:gateway", "watchdog:recovered:gateway"])

    def test_two_restarts_in_ten_minutes_is_not_a_crash_loop_and_three_is(self):
        def each(elapsed):
            if elapsed in (60, 300):                 # 2 restarts after the first sample
                self.world.pm2["db"]["restart_time"] += 1
        self.run_minutes(30, each)
        self.assertEqual(self.alerts, [])

        def three(elapsed):
            if elapsed in (1860, 1980, 2100):        # 3 within 10 minutes (decision #111: 3 or more)
                self.world.pm2["db"]["restart_time"] += 1
        self.run_minutes(10, three)
        self.assertEqual(self.alerts, ["watchdog:crashloop:db"])

    def test_the_watchdogs_own_restarts_are_not_a_crash_loop(self):
        """Hung gateway kept hung: 2 watchdog restarts in an hour (#111), then the cap; no crash loop."""
        self.world.gateway_ready = False
        self.run_minutes(60)
        self.assertEqual(self.restarts.count("gateway"), 2)
        self.assertIn("down, not restarting", self.messages[self.alerts.index("watchdog:cap:gateway")])
        self.assertNotIn("watchdog:crashloop:gateway", self.alerts)
        self.assertEqual(self.alerts.count("watchdog:down:gateway"), 1)
        self.assertEqual(self.alerts.count("watchdog:cap:gateway"), 1)

    def test_seeded_restarts_reach_the_cap_with_one_hang(self):
        """qualify.py's watchdog_cap seeds two restarts from the last hour (decision #111): one hang
        then gives one "down, not restarting", no restart, and one "recovered" afterwards."""
        self.dog.state["apps"]["gateway"] = {"restarts": [self.world.now - 1200, self.world.now - 600]}
        self.dog.state = json.loads(json.dumps(self.dog.state))       # as loaded from watchdog.json
        self.world.gateway_ready = False
        self.run_minutes(6)
        self.assertEqual(self.restarts, [])
        self.assertEqual(self.alerts, ["watchdog:cap:gateway"])
        self.assertIn("down, not restarting", self.messages[0])
        self.world.gateway_ready = True
        self.run_minutes(2)
        self.assertEqual(self.alerts, ["watchdog:cap:gateway", "watchdog:recovered:gateway"])

    def test_a_slow_start_within_twice_its_window_raises_nothing(self):
        container = self.world.containers["nextcloud"]
        container.update(started=self.world.now, health="starting")      # e.g. a long first start
        self.run_minutes(5)                                               # inside the 330 s health bound
        container.update(health="healthy")
        self.run_minutes(30)
        self.assertEqual((self.restarts, self.alerts), ([], []))

    def test_not_yet_clock_restarts_when_a_dependency_was_the_cause(self):
        """db down 20 minutes (alerted); Nextcloud waited on it; when db is back, Nextcloud's own
        start gets its full window rather than an immediate "down"."""
        self.world.pm2["db"]["status"] = "waiting restart"
        self.run_minutes(20)
        self.assertEqual(self.alerts, ["watchdog:down:db"])
        self.world.pm2["db"]["status"] = "online"
        self.world.containers["nextcloud"].update(started=self.world.now, health="starting")
        self.run_minutes(5)
        self.assertEqual(self.alerts, ["watchdog:down:db", "watchdog:recovered:db"])

    # N2: Nextcloud maintenance ------------------------------------------------------------------
    def test_maintenance_without_a_marker_alerts_once_at_30_minutes_and_never_restarts(self):
        """Review N2 (a failed occ upgrade): 4 hours -> one alert at 30 minutes, no restart."""
        self.world.maintenance = True
        reports = self.run_minutes(240)
        self.assertEqual(self.restarts, [])
        self.assertEqual(self.alerts, ["watchdog:maintenance:nextcloud"])
        self.assertTrue(29 * 60 <= self.alert_times[0] <= 31 * 60, self.alert_times)
        self.assertEqual(reports[-1]["apps"]["nextcloud"], "not yet: maintenance")
        self.world.maintenance = False
        self.run_minutes(3)
        self.assertEqual(self.alerts, ["watchdog:maintenance:nextcloud", "watchdog:recovered:nextcloud"])

    def test_maintenance_failing_nextclouds_own_healthcheck_is_still_maintenance(self):
        """Nextcloud's compose healthcheck fails in maintenance (Docker: unhealthy); still no restart."""
        self.world.maintenance = True
        self.world.containers["nextcloud"]["health"] = "unhealthy"
        self.run_minutes(60)
        self.assertEqual(self.restarts, [])
        self.assertEqual(self.alerts, ["watchdog:maintenance:nextcloud"])

    def test_maintenance_under_an_active_backup_marker_raises_nothing(self):
        self.world.maintenance = True
        self.reasons = [paths.BACKUP_IN_PROGRESS.name]
        reports = self.run_minutes(120)
        self.assertEqual((self.restarts, self.alerts), ([], []))
        self.assertTrue(all(report["result"] == "suppressed" for report in reports))
        self.reasons = []                     # the marker's deadline passed or it was removed
        self.run_minutes(29)
        self.assertEqual(self.alerts, [])     # the 30 minutes count from the end of the marker
        self.run_minutes(2)
        self.assertEqual(self.alerts, ["watchdog:maintenance:nextcloud"])

    # N3: process matching -----------------------------------------------------------------------
    def fake_proc(self, commands):
        proc = self.scratch / "proc"
        shutil.rmtree(proc, ignore_errors=True)
        for pid, argv in enumerate(commands, start=100):
            (proc / str(pid)).mkdir(parents=True)
            (proc / str(pid) / "cmdline").write_bytes(b"\0".join(part.encode() for part in argv) + b"\0")
        (proc / "self").mkdir()
        return proc

    def test_editors_pagers_and_read_only_commands_never_suppress(self):
        setup = "/var/lib/anj-cloud-setup/src/deploy/vm/anj-cloud-setup"
        prod = "/srv/anj-cloud/release/current/deploy/prod.py"
        proc = self.fake_proc([
            ["vim", setup], ["less", setup], ["grep", "-n", "x", setup], ["nano", prod],
            ["/usr/bin/python3", "-I", setup, "status"], ["/usr/bin/python3", "-I", setup, "status", "--json"],
            ["/usr/bin/python3", "-I", setup, "doctor"], ["/usr/bin/python3", "-I", setup, "--dry-run", "--answers", "a"],
            ["/usr/bin/python3", "-I", setup, "first-code", "--reissue"],
            ["python3", "-c", f"print('{setup}')"], ["sudo", setup], ["bash", "-c", f"{setup} install"],
            ["python3", prod, "status"], ["python3", prod, "check"],
            ["dpkg", "--print-architecture"], ["apt-config", "dump"], ["apt-cache", "policy", "x"]])
        self.assertEqual(self.vmops.busy_processes(proc), [])

    def test_pair_and_backup_never_suppress_the_watchdog(self):
        """PR #46 ruling: `pair` waits up to its code's 10 minutes and `backup` talks to the person at
        the terminal; neither stops a service, so neither is a quiet reason, through the staged copy
        or the stable /usr/local/bin link."""
        for setup in ("/var/lib/anj-cloud-setup/src/deploy/vm/anj-cloud-setup", "/usr/local/bin/anj-cloud-setup"):
            for argv in (["/usr/bin/python3", "-I", setup, "pair"], ["/usr/bin/python3", "-I", setup, "pair", "--new-code"],
                         ["/usr/bin/python3", "-I", setup, "backup"],
                         ["/usr/bin/python3", "-I", setup, "backup", "--show-password"]):
                with self.subTest(argv=argv):
                    self.assertEqual(self.vmops.busy_processes(self.fake_proc([argv])), [])
        install = ["/usr/bin/python3", "-I", "/usr/local/bin/anj-cloud-setup"]
        self.assertEqual(self.vmops.busy_processes(self.fake_proc([install])), ["anj-cloud-setup"])

    def test_mutating_runs_are_matched_by_interpreter_and_script(self):
        setup = "/var/lib/anj-cloud-setup/src/deploy/vm/anj-cloud-setup"
        prod = "/srv/anj-cloud/release/current/deploy/prod.py"
        cases = {
            "anj-cloud-setup": [["/usr/bin/python3", "-I", setup], ["/usr/bin/python3", "-I", setup, "--answers", "a"],
                                ["/usr/bin/python3", "-I", setup, "--adopt-data"],
                                ["python3.13", "-I", setup, "--restore-from", "/mnt/anj-backup"],
                                ["python3", "-W", "ignore", setup, "install"],
                                ["python3", "-m", "deploy.vm.bootstrap", "--answers", "a"]],
            "prod.py up": [["python3", prod, "up"]], "prod.py stop": [["python3", "-I", prod, "stop"]],
            "prod.py redeploy": [["/usr/bin/python3", prod, "redeploy", "0123456789ab"]],
            "apt/dpkg": [["/usr/bin/python3", "/usr/bin/unattended-upgrade"], ["apt-get", "install", "-y", "x"],
                         ["/usr/bin/dpkg", "--configure", "-a"], ["apt", "upgrade"]],
        }
        for reason, commands in cases.items():
            for argv in commands:
                with self.subTest(argv=argv):
                    self.assertEqual(self.vmops.busy_processes(self.fake_proc([argv])), [reason])

    def test_an_open_editor_never_hides_a_crash_loop(self):
        """Review N3 as simulated: vim on the setup script + `setup status`, 24 h -> one alert."""
        proc = self.fake_proc([["vim", "/var/lib/anj-cloud-setup/src/deploy/vm/anj-cloud-setup"],
                               ["/usr/bin/python3", "-I", "/srv/anj-cloud/release/current/deploy/vm/anj-cloud-setup",
                                "status"]])
        self.dog = self.make_dog(quiet=lambda: self.vmops.busy_processes(proc))
        self.world.pm2["gateway"]["status"] = "waiting restart"
        self.run_minutes(24 * 60)
        self.assertEqual(self.alerts, ["watchdog:down:gateway"])

    # N3: bounds per reason ------------------------------------------------------------------------
    def test_each_quiet_reason_is_bounded_then_one_alert_names_it(self):
        for reason, limit in (("anj-cloud-setup", 15), ("prod.py redeploy", 15), ("prod.py up", 15),
                              ("prod.py stop", 15), ("apt/dpkg", 15), ("upgrade", 15), ("system starting", 15),
                              ("system stopping", 15), ("boot grace", 15)):
            with self.subTest(reason=reason):
                self.setUp()
                self.world.gateway_ready = False            # production is down the whole time
                self.reasons = [reason]
                reports = self.run_minutes(limit)
                self.assertTrue(all(report["result"] == "suppressed" for report in reports), reason)
                self.assertEqual((self.restarts, self.alerts), ([], []))
                self.run_minutes(24 * 60 - limit)          # the reason never goes away
                key = "watchdog:suppressed:" + self.vmops.alert_slug(reason)
                self.assertEqual(self.alerts.count(key), 1, self.alerts)
                self.assertEqual(self.alerts[0], key)
                self.assertEqual(self.alert_times[0], limit * 60)
                self.assertIn(f"watchdog suppressed by {reason} for {limit} min", self.messages[0])
                self.assertIn("gateway", self.restarts)    # checks resumed
                self.assertIn("watchdog:down:gateway", self.alerts)

    def test_a_hung_interactive_setup_suppresses_at_most_15_minutes(self):
        """An install waiting at its last prompt (stdin, no time limit) while the gateway crash-loops."""
        proc = self.fake_proc([["/usr/bin/python3", "-I", "/var/lib/anj-cloud-setup/src/deploy/vm/anj-cloud-setup"]])
        self.dog = self.make_dog(quiet=lambda: self.vmops.busy_processes(proc))
        self.world.pm2["gateway"]["status"] = "waiting restart"
        self.run_minutes(24 * 60)
        self.assertEqual(self.alerts, ["watchdog:suppressed:anj-cloud-setup", "watchdog:down:gateway"])
        self.assertEqual(self.alert_times[0], 15 * 60)

    def test_markers_are_bounded_by_their_own_deadline_not_a_second_limit(self):
        self.world.gateway_ready = False
        self.reasons = [paths.RESTORE_IN_PROGRESS.name]     # spec #22: up to 8 hours
        self.run_minutes(8 * 60)
        self.assertEqual((self.restarts, self.alerts), ([], []))
        run = self.scratch / "run"
        run.mkdir()
        (run / paths.BACKUP_IN_PROGRESS.name).write_text(json.dumps({"deadline_epoch": T0 - 1}))
        self.assertEqual(self.vmops.maintenance_markers(self.scratch, at=T0), [])   # past its deadline: none

    def test_a_new_episode_after_the_reason_was_gone_and_the_alert_is_throttled(self):
        self.reasons = ["prod.py redeploy"]
        self.run_minutes(16)
        self.assertEqual(self.alerts, ["watchdog:suppressed:prod.py-redeploy"])
        self.reasons = []
        self.run_minutes(5)                                  # gone, but not yet forgotten
        self.reasons = ["prod.py redeploy"]
        self.run_minutes(30)
        self.assertEqual(self.alerts.count("watchdog:suppressed:prod.py-redeploy"), 1)
        self.reasons = []
        self.run_minutes(11)                                 # forgotten: the next run is a new episode
        self.reasons = ["prod.py redeploy"]
        reports = self.run_minutes(14)
        self.assertTrue(all(report["result"] == "suppressed" for report in reports))
        self.assertEqual(self.alerts.count("watchdog:suppressed:prod.py-redeploy"), 1)

    def test_the_suppression_alert_goes_through_the_dispatcher_throttle(self):
        calls = []

        class Runner:
            def run(self, argv, **_options):
                calls.append(argv)
                return 0, "", ""
        with mock.patch.object(self.vmops, "busy_processes", lambda: ["apt/dpkg"]), \
                mock.patch.object(self.vmops, "maintenance_markers", lambda: []), \
                mock.patch.object(self.vmops, "system_quiet", lambda runner: []), \
                mock.patch.object(self.vmops, "log", lambda *a, **k: None):
            dog = self.module.build(Runner(), {"quiet": {"apt/dpkg": {"first": 0, "last": 0, "alerted": False}}})
            dog.tick()
        sent = [argv for argv in calls if "--key" in argv]
        self.assertEqual(len(sent), 1)
        self.assertEqual(sent[0][sent[0].index("--key") + 1], "watchdog:suppressed:apt-dpkg")
        self.assertEqual(sent[0][sent[0].index("--every") + 1], "3600")

    def test_after_upgrade_never_extends_an_expired_upgrade(self):
        self.reasons = ["upgrade"]
        self.world.gateway_ready = False
        self.run_minutes(19)
        self.assertIn("watchdog:suppressed:upgrade", self.alerts)
        self.assertIn("gateway", self.restarts)

    def test_the_tail_after_the_update_run_stays_inside_its_15_minutes(self):
        self.reasons = ["upgrade"]
        self.world.gateway_ready = False
        self.run_minutes(5)
        self.reasons = []
        reports = self.run_minutes(9)                 # 14 minutes since the run was first seen
        self.assertTrue(all(report["result"] == "suppressed" for report in reports))
        self.assertEqual(reports[-1]["reason"], "after upgrade")
        self.run_minutes(4)
        self.assertEqual(self.restarts, ["gateway"])
        self.assertNotIn("watchdog:suppressed:upgrade", self.alerts)

    def test_a_long_update_run_has_no_tail_beyond_its_15_minutes(self):
        self.reasons = ["upgrade"]
        self.world.gateway_ready = False
        self.run_minutes(14)
        self.reasons = []
        reports = self.run_minutes(1)                 # minute 14: still inside the budget
        self.assertEqual(reports[-1]["reason"], "after upgrade")
        report = self.dog.tick()                      # minute 15: the budget is spent
        self.assertEqual(report["result"], "checked")

    # Intentional states stay silent indefinitely ---------------------------------------------------
    def test_a_stopped_stack_and_the_emergency_stop_raise_nothing_in_24_hours(self):
        for app in paths.STACK_APPS:
            self.world.pm2[app]["status"] = "stopped"
        self.run_minutes(24 * 60)
        self.assertEqual((self.restarts, self.alerts), ([], []))
        for app in paths.STACK_APPS:
            self.world.pm2[app]["status"] = "online"
        self.emergency = True
        for app in paths.EMERGENCY_APPS:
            self.world.pm2[app]["status"] = "stopped"
        reports = self.run_minutes(24 * 60)
        self.assertEqual((self.restarts, self.alerts), ([], []))
        self.assertEqual(reports[-1]["apps"]["gateway"], "stopped by emergency stop")

    def test_the_emergency_stop_never_blames_nextcloud(self):
        """anj-qual b2dev-7: with the gateway held, status.php through the gateway container failed
        and the watchdog restarted a healthy Nextcloud. It now asks Nextcloud's own loopback."""
        self.emergency = True
        for app in paths.EMERGENCY_APPS:
            self.world.pm2[app]["status"] = "stopped"
        self.world.containers["access"]["running"] = False
        self.world.containers["haproxy"]["running"] = False
        reports = self.run_minutes(60)
        self.assertEqual((self.restarts, self.alerts), ([], []))
        self.assertEqual(reports[-1]["apps"]["nextcloud"], "ok")
        self.assertIn(f"{paths.PROJECT}-nextcloud-1", self.world.execs)

    def test_a_crashed_gateway_never_blames_nextcloud(self):
        self.world.containers["access"]["running"] = False       # PM2 online, container gone
        self.world.pm2["gateway"]["since"] = self.world.now - 3600
        self.run_minutes(10)
        self.assertNotIn("nextcloud", self.restarts)
        self.assertIn("gateway", self.restarts)

    def test_pm2_not_answering_alerts_once(self):
        self.world.pm2_readable = False
        reports = self.run_minutes(120)
        self.assertEqual(self.alerts, ["watchdog:pm2-unreadable"])
        self.assertEqual(self.restarts, [])
        self.assertEqual(reports[-1]["result"], "pm2 unreadable")

    def test_state_round_trips_through_json(self):
        """watchdog.json is rewritten every round: the new fields survive a save and a reload."""
        self.world.maintenance = True
        self.run_minutes(10)
        state = json.loads(json.dumps(self.dog.state))
        self.dog = self.make_dog()
        self.dog.state = state
        self.dog.state.setdefault("quiet", {})
        self.run_minutes(21)
        self.assertEqual(self.alerts, ["watchdog:maintenance:nextcloud"])


class ReviewRound4(Fixture):
    """PR #45 review at 7958ec8 (wd_sim.py, W1, W2, L-b, L-c), under decision #111: one alert per
    episode, and no unbounded silence. Scenario names follow the reviewer's simulator."""

    # W1 -------------------------------------------------------------------------------------
    def crash_every_4_minutes(self, elapsed):
        """S1: the gateway crashes about every 4 minutes (PM2 restarts it) and is healthy between."""
        row, container = self.world.pm2["gateway"], self.world.containers["access"]
        if int(elapsed // 60) % 4 == 0:
            row["restart_time"] += 1
            row["since"] = self.world.now - 5
            container.update(running=True, started=self.world.now - 5, health="starting")
        else:
            container.update(health="healthy")

    def test_s1_a_crash_every_4_minutes_is_one_episode(self):
        self.run_minutes(120, self.crash_every_4_minutes)
        self.assertEqual(self.alerts, ["watchdog:crashloop:gateway"])       # was 54 alerts
        self.assertEqual(self.restarts, [])
        # Crashes stop (healthy): the crash-loop state ends 10 minutes after the last PM2 restart;
        # the crash-loop rounds are one continuous episode, so its first healthy round recovers.
        self.run_minutes(12)
        self.assertEqual(self.alerts, ["watchdog:crashloop:gateway", "watchdog:recovered:gateway"])

    def test_w1_recovered_only_after_a_full_window_without_a_restart(self):
        """A pure crash loop (a PM2 restart every round for 4 rounds, no healthy round between),
        healthy afterwards: "recovered" only once a full window has passed without a restart."""
        def crash(elapsed):
            if int(elapsed // 60) < 4:
                self.world.pm2["gateway"]["restart_time"] += 1
                self.world.pm2["gateway"]["since"] = self.world.now - 5
        self.run_minutes(4, crash)                               # restarts at minutes 0-3
        self.assertEqual(self.alerts, ["watchdog:crashloop:gateway"])
        while self.world.now - T0 < 3 * 60 + self.module.CRASH_LOOP_WINDOW:
            self.run_minutes(1)                                  # healthy, still inside the window
        self.assertEqual(self.alerts, ["watchdog:crashloop:gateway"])
        self.run_minutes(1)
        self.assertEqual(self.alerts, ["watchdog:crashloop:gateway", "watchdog:recovered:gateway"])

    # W2 -------------------------------------------------------------------------------------
    def test_s2_pm2_answering_every_other_round_never_hides_a_hung_gateway(self):
        self.world.gateway_ready = False
        self.run_minutes(60, lambda elapsed: setattr(self.world, "pm2_readable", int(elapsed // 60) % 2 == 0))
        self.assertIn("gateway", self.restarts)                              # was 0 restarts, 0 alerts
        self.assertEqual(self.alerts.count("watchdog:down:gateway"), 1)
        self.assertEqual(self.alerts.count("watchdog:pm2-unreadable"), 1)

    def test_s2c_pm2_missing_one_round_in_three_never_hides_the_gateway(self):
        for label in ("hung", "waiting restart"):
            with self.subTest(label=label):
                self.setUp()
                if label == "hung":
                    self.world.gateway_ready = False
                else:
                    self.world.pm2["gateway"]["status"] = "waiting restart"
                self.run_minutes(24 * 60, lambda elapsed: setattr(self.world, "pm2_readable",
                                                                  int(elapsed // 60) % 3 != 2))
                self.assertEqual(self.alerts.count("watchdog:down:gateway"), 1)
                self.assertEqual(self.alerts.count("watchdog:pm2-unreadable"), 1)
                first_down = self.alert_times[self.alerts.index("watchdog:down:gateway")]
                self.assertLessEqual(first_down, 12 * 60)

    def test_an_unreadable_round_freezes_the_failure_count(self):
        self.world.gateway_ready = False
        self.run_minutes(2)                                                  # 2 failures
        self.world.pm2_readable = False
        self.run_minutes(1)                                                  # frozen, not cleared
        self.world.pm2_readable = True
        self.run_minutes(1)                                                  # the 3rd failure
        self.assertEqual(self.restarts, ["gateway"])

    def test_s2b_pm2_hanging_5_of_every_6_minutes_alerts_once(self):
        self.run_minutes(120, lambda elapsed: setattr(self.world, "pm2_readable", int(elapsed // 60) % 6 == 5))
        self.assertEqual(self.alerts, ["watchdog:pm2-unreadable"])           # was 20

    def test_a_new_pm2_episode_after_answering_for_10_minutes(self):
        self.world.pm2_readable = False
        self.run_minutes(5)
        self.world.pm2_readable = True
        self.run_minutes(11)
        self.world.pm2_readable = False
        self.run_minutes(5)
        self.assertEqual(self.alerts, ["watchdog:pm2-unreadable", "watchdog:pm2-unreadable"])

    def test_s5_a_flapping_dependency_never_hides_a_down_app(self):
        """The gateway is down; Nextcloud's status probe fails one round in three."""
        self.world.pm2["gateway"]["status"] = "waiting restart"
        self.world.containers["access"]["running"] = False
        real = self.world.run

        def flaky(argv, **options):
            if argv[:2] == ["docker", "exec"] and "php" in argv and int((self.world.now - T0) // 60) % 3 == 2:
                return 124, "", "timed out"
            return real(argv, **options)
        self.world.run = flaky
        self.run_minutes(24 * 60)
        self.assertEqual(self.alerts, ["watchdog:down:gateway"])             # was 0
        self.assertLessEqual(self.alert_times[0], 12 * 60)

    def test_a_down_dependency_covers_its_dependents_then_they_start_fresh(self):
        """db down 30 minutes with Nextcloud failing because of it: one alert (db); when db is back,
        Nextcloud's own start gets a fresh window, not an immediate "down"."""
        self.world.pm2["db"]["status"] = "waiting restart"
        self.world.containers["nextcloud"]["health"] = "unhealthy"
        self.world.maintenance = False
        real = self.world.run

        def nextcloud_failing(argv, **options):
            if argv[:2] == ["docker", "exec"] and self.world.pm2["db"]["status"] != "online" and \
                    "access.health" not in argv:
                return 0, json.dumps({"installed": True, "maintenance": False}) + "\n", ""
            return real(argv, **options)
        self.world.run = nextcloud_failing
        self.run_minutes(30)
        self.assertEqual(self.alerts, ["watchdog:down:db"])
        self.world.pm2["db"]["status"] = "online"
        self.world.containers["nextcloud"].update(health="starting", started=self.world.now)
        self.run_minutes(5)
        self.assertEqual(self.alerts, ["watchdog:down:db", "watchdog:recovered:db"])

    def test_an_intentionally_stopped_dependency_raises_nothing(self):
        self.world.pm2["db"]["status"] = "stopped"
        self.world.containers["nextcloud"]["health"] = "unhealthy"
        self.run_minutes(120)
        self.assertEqual((self.restarts, self.alerts), ([], []))

    # L-b ------------------------------------------------------------------------------------
    def test_s3_a_backward_clock_step_never_stretches_a_bound(self):
        self.world.gateway_ready = False
        self.run_minutes(4)                                                  # restart at minute 2
        self.world.now -= 7200
        step = self.world.now
        self.run_minutes(30)
        downs = [t + T0 - step for key, t in zip(self.alerts, self.alert_times) if key == "watchdog:down:gateway"]
        self.assertEqual(len(downs), 1)
        self.assertLessEqual(downs[0], 6 * 60)                               # was 123 minutes
        self.assertNotIn("watchdog:down:cron", self.alerts)                  # no false pair from StartedAt

    def test_s4_a_wrong_shape_state_is_reset_with_one_alert(self):
        for label, state in (("list", []), ("apps list", {"apps": []}),
                             ("restarts null", {"apps": {"gateway": {"restarts": None}}}),
                             ("quiet str", {"quiet": {"upgrade": "x"}}),
                             ("unhealthy str", {"apps": {"gateway": {"unhealthy_since": "x"}}}),
                             ("events shape", {"apps": {"gateway": {"restart_events": [1, 2]}}})):
            with self.subTest(label=label):
                self.setUp()
                self.dog = self.make_dog()
                self.dog.__init__(probe=self.dog.probe, restart=self.dog.restart, alert=self.dog.alert,
                                  clock=self.dog.clock, state=json.loads(json.dumps(state)), quiet=self.dog.quiet,
                                  emergency=self.dog.emergency, pm2=self.dog.pm2,
                                  restart_counts=self.dog.restart_counts, bounds=self.dog._bounds)
                self.run_minutes(10)
                self.assertEqual(self.alerts, ["watchdog:state-reset"])
        self.assertTrue(self.module.valid_state(json.loads(json.dumps(self.dog.state))))

    def test_a_state_the_watchdog_wrote_is_valid(self):
        self.world.gateway_ready = False
        self.run_minutes(20, self.crash_every_4_minutes)
        self.assertTrue(self.module.valid_state(json.loads(json.dumps(self.dog.state))))

    def test_an_unreadable_marker_suppresses_nothing_and_alerts_once(self):
        run = self.scratch / "run"
        run.mkdir()
        (run / paths.RESTORE_IN_PROGRESS.name).write_text("{not json")
        self.assertEqual(self.vmops.maintenance_markers(self.scratch), [])
        self.assertEqual(self.vmops.unreadable_markers(self.scratch), [paths.RESTORE_IN_PROGRESS.name])
        self.dog.unreadable = lambda: self.vmops.unreadable_markers(self.scratch)
        self.world.gateway_ready = False
        self.run_minutes(30)
        self.assertEqual(self.alerts.count("watchdog:marker:" + paths.RESTORE_IN_PROGRESS.name), 1)
        self.assertIn("gateway", self.restarts)                              # checks went on
        (run / paths.RESTORE_IN_PROGRESS.name).unlink()
        self.run_minutes(1)
        self.assertEqual(self.dog.state["markers_alerted"], [])

    def test_a_failing_round_alerts_once_and_the_watchdog_keeps_running(self):
        calls = []

        class Dog:
            state = {}

            def tick(self):
                raise KeyError("x")

            def alert(self, key, title, message, priority="high"):
                calls.append(key)
        dog = Dog()
        with mock.patch.object(self.module, "build", lambda runner, state: dog), \
                mock.patch.object(self.vmops, "save_json", lambda *a, **k: None), \
                mock.patch.object(self.vmops, "load_json", lambda *a, **k: {}), \
                mock.patch.object(self.vmops, "log", lambda *a, **k: None):
            self.assertEqual(self.module.main(["--once"]), 0)
        self.assertEqual(calls, ["watchdog:error"])
        self.assertEqual(dog.state, {})                       # decision #113: never reset by an error

    def test_every_docker_exec_into_the_gateway_passes_the_same_user(self):
        """Review L-a, coordinator ruling: one --user value (10001:10002) for every exec into the
        gateway container; an exec otherwise inherits the start step's capabilities."""
        expected = f"{paths.GATEWAY_UID}:{paths.GATEWAY_GID}"
        self.assertEqual(self.vmops.GATEWAY_EXEC_USER, expected)
        calls = []

        class Runner:
            def run(self, argv, **_options):
                calls.append(argv)
                return 0, '{"installed": true, "maintenance": false}\n{"status": "ready"}\n', ""
        self.vmops.nextcloud_status(Runner(), via_gateway=True)
        self.vmops.gateway_health(Runner())
        access = f"{paths.PROJECT}-access-1"
        execs = [argv for argv in calls if argv[:2] == ["docker", "exec"] and access in argv]
        self.assertEqual(len(execs), 2)
        for argv in execs:
            self.assertEqual(argv[argv.index("--user") + 1], expected, argv)
        # Every other exec into the gateway in B2's code (bootstrap, qualify.py) names the same
        # pair; a line that execs into it without --user fails here.
        import re
        for path in ("deploy/vm/bootstrap.py", "deploy/vm/qualify.py", "deploy/vm/ops/vmops.py"):
            lines = (ROOT / path).read_text().splitlines()
            for number, line in enumerate(lines):
                if "commands.append" in line or not re.search(r'docker", "exec"|docker exec', line):
                    continue
                statement = " ".join(lines[number:number + 2])
                if not re.search(r"ACCESS(_CONTAINER)?\b|\{ACCESS\}", statement):
                    continue
                with self.subTest(path=path, line=number + 1):
                    self.assertTrue("GATEWAY_EXEC_USER" in statement or
                                    "{paths.GATEWAY_UID}:{paths.GATEWAY_GID}" in statement, statement)

    # L-c ------------------------------------------------------------------------------------
    def test_not_yet_alerts_at_twice_the_window_and_not_a_minute_before(self):
        for app, status in (("gateway", "waiting restart"), ("db", "launching")):
            with self.subTest(app=app):
                self.setUp()
                self.world.pm2[app]["status"] = status
                limit = self.window(app)
                self.assertEqual(limit, 2 * self.vmops.health_window(app, self.bounds))
                while self.world.now - T0 <= limit - 60:
                    self.run_minutes(1)
                self.assertEqual(self.alerts, [])
                while self.world.now - T0 <= limit:
                    self.run_minutes(1)
                self.assertEqual(self.alerts, [f"watchdog:down:{app}"])
                self.assertEqual(self.alert_times[0], limit)

    def test_pm2_unreadable_alerts_at_4_minutes(self):
        self.world.pm2_readable = False
        self.run_minutes(4)
        self.assertEqual(self.alerts, [])
        self.run_minutes(1)
        self.assertEqual(self.alerts, ["watchdog:pm2-unreadable"])
        self.assertEqual(self.alert_times[0], 4 * 60)

    def test_the_production_build_wiring_counts_a_crash_loop_once(self):
        """The reviewer's wd_build_sim.py: counts_from_pm2 over the probe's own PM2 snapshot."""
        sent = []
        defaults = list(self.vmops.Probe.__init__.__defaults__)
        patched = list(defaults)
        patched[1], patched[2] = (lambda: self.world.now), self.bounds
        with mock.patch.object(self.vmops.Probe.__init__, "__defaults__", tuple(patched)), \
                mock.patch.object(self.vmops, "busy_processes", lambda: []), \
                mock.patch.object(self.vmops, "maintenance_markers", lambda: []), \
                mock.patch.object(self.vmops, "unreadable_markers", lambda: []), \
                mock.patch.object(self.vmops, "system_quiet", lambda runner: []), \
                mock.patch.object(self.vmops, "stack_config", lambda *a, **k: {}), \
                mock.patch.object(self.vmops, "log", lambda *a, **k: None), \
                mock.patch.object(self.vmops, "emergency_stopped", lambda: False), \
                mock.patch.object(self.vmops, "ddns_state", lambda: None), \
                mock.patch.object(self.vmops, "send_alert_result",
                                  lambda runner, key, *a, **k: sent.append(key) or "queued"):
            dog = self.module.build(self.world, {})
            dog.clock, dog._bounds = (lambda: self.world.now), self.bounds
            for minute in range(60):
                phase = minute % 3
                row, container = self.world.pm2["gateway"], self.world.containers["access"]
                row["status"] = "waiting restart" if phase == 0 else "online"
                if phase == 1:
                    row["since"] = self.world.now - 5
                row["restart_time"] += 2
                container.update(running=phase == 2, started=self.world.now - 10, health="starting")
                dog.tick()
                self.world.now += 60
        self.assertEqual(sent, ["watchdog:crashloop:gateway"])


class ReviewRound5(Fixture):
    """PR #45 review at 3e8fbd8 (wd_sim4.py, wd_main_sim.py; X1, X2, L1, L2) and decision #113's
    flapping bound (L3). Each fails at 3e8fbd8."""

    # X1 -------------------------------------------------------------------------------------
    def crash_then_hang(self, elapsed):
        """S6: 4 PM2 restarts in 4 minutes, then online with its healthcheck failing (a hang)."""
        if int(elapsed // 60) < 4:
            self.world.pm2["gateway"]["restart_time"] += 1
            self.world.pm2["gateway"]["since"] = self.world.now - 5
        self.world.gateway_ready = False

    def test_s6_a_crash_loop_that_ends_in_a_hang_gets_the_watchdogs_restarts(self):
        self.run_minutes(180, self.crash_then_hang)
        self.assertEqual(self.alerts.count("watchdog:crashloop:gateway"), 1)
        self.assertNotIn("watchdog:down:gateway", self.alerts)              # the same episode, still open
        # After a full window with no PM2 restart: 2 watchdog restarts an hour, then the cap.
        first_restart = self.alert_times[self.alerts.index("watchdog:restart:gateway")]
        self.assertLessEqual(first_restart, (4 + 10 + 3) * 60)
        self.assertEqual(self.restarts.count("gateway"), 6)                 # 3 hours x 2
        self.assertGreaterEqual(self.alerts.count("watchdog:cap:gateway"), 2)
        self.assertNotIn("PM2 keeps retrying", " ".join(self.messages))
        self.world.gateway_ready = True
        self.run_minutes(5)
        self.assertEqual(self.alerts.count("watchdog:recovered:gateway"), 1)  # S6b: one recovered

    def test_s1_still_one_episode_with_the_crash_loop_state_ending_on_time(self):
        def crash(elapsed):
            row, container = self.world.pm2["gateway"], self.world.containers["access"]
            if int(elapsed // 60) % 4 == 0:
                row["restart_time"] += 1
                row["since"] = self.world.now - 5
                container.update(running=True, started=self.world.now - 5, health="starting")
            else:
                container.update(health="healthy")
        self.run_minutes(120, crash)
        self.assertEqual(self.alerts, ["watchdog:crashloop:gateway"])
        self.assertEqual(self.restarts, [])

    # X2 -------------------------------------------------------------------------------------
    def run_main(self, every, minutes):
        """The reviewer's wd_main_sim.py: the real main() loop; `docker inspect` raises (a fork
        failure under pressure) one round in `every`, the gateway hung."""
        self.world.gateway_ready = False
        real, rounds = self.world.run, {"n": 0}

        def run(argv, **options):
            if argv[:2] == ["docker", "inspect"] and rounds["n"] % every == every - 1:
                raise BlockingIOError(11, "Resource temporarily unavailable")
            return real(argv, **options)
        self.world.run = run

        class Done(Exception):
            pass

        monotonic = {"t": 0.0}

        def sleep(_seconds):
            rounds["n"] += 1
            self.world.now += 60
            monotonic["t"] += 60
            if rounds["n"] >= minutes:
                raise Done()
        with mock.patch.object(self.module, "build", lambda runner, state: self.dog), \
                mock.patch.object(self.vmops, "load_json", lambda *a, **k: {}), \
                mock.patch.object(self.vmops, "save_json", lambda *a, **k: None), \
                mock.patch.object(self.vmops, "log", lambda *a, **k: None), \
                mock.patch.object(self.module.time, "sleep", sleep), \
                mock.patch.object(self.module.time, "monotonic", lambda: monotonic["t"]):
            try:
                self.module.main([])
            except Done:
                pass

    def test_x2_an_intermittent_round_error_alerts_hourly_and_never_resets_the_cap(self):
        for every, expected_errors in ((3, 4), (2, 4), (10, 4)):
            with self.subTest(every=every):
                self.setUp()
                self.run_main(every, 240)
                self.assertEqual(self.alerts.count("watchdog:error"), expected_errors)   # was 80 / 120 / 24
                self.assertLessEqual(self.restarts.count("gateway"), 8)                  # the cap: 2 an hour
                self.assertGreater(self.restarts.count("gateway"), 0)
                self.assertEqual(self.alerts.count("watchdog:down:gateway"), 1)          # was 24

    def test_x2_runner_turns_any_oserror_into_a_failed_check(self):
        with mock.patch.object(self.vmops.subprocess, "run", side_effect=BlockingIOError(11, "EAGAIN")):
            code, out, err = self.vmops.Runner().run(["docker", "inspect", "x"])
        self.assertEqual((code, out), (126, ""))
        self.assertIn("BlockingIOError", err)

    def test_x2_the_error_alert_is_throttled_by_the_dispatcher_too(self):
        calls = []

        class Runner:
            def run(self, argv, **_options):
                calls.append(argv)
                return 0, "", ""
        with mock.patch.object(self.vmops, "log", lambda *a, **k: None):
            dog = self.module.build(Runner(), {})
            dog.alert("watchdog:error", "t", "m")
        argv = next(argv for argv in calls if "--key" in argv)
        self.assertEqual(argv[argv.index("--every") + 1], "3600")

    # L1 -------------------------------------------------------------------------------------
    def test_l1_a_quiet_row_without_its_start_time_is_reset_with_one_alert(self):
        for quiet in ({"upgrade": {"last": T0}}, {"upgrade": {"first": None, "last": T0}},
                      {"upgrade": {"first": T0}}):
            with self.subTest(quiet=quiet):
                self.setUp()
                self.assertFalse(self.module.valid_state({"quiet": quiet}))
                self.dog = self.make_dog(quiet=lambda: ["upgrade"])
                self.dog.__init__(probe=self.dog.probe, restart=self.dog.restart, alert=self.dog.alert,
                                  clock=self.dog.clock, state={"quiet": json.loads(json.dumps(quiet))},
                                  quiet=self.dog.quiet, emergency=self.dog.emergency, pm2=self.dog.pm2,
                                  restart_counts=self.dog.restart_counts, bounds=self.dog._bounds)
                self.run_minutes(3)
                self.assertEqual(self.alerts, ["watchdog:state-reset"])

    # L3: flapping (decision #113) ---------------------------------------------------------------
    def test_s8_an_app_down_most_of_the_time_but_under_its_bound_flaps_once(self):
        """db `waiting restart` 9 of every 10 minutes, just under its 9-minute bound: was 0 alerts."""
        self.run_minutes(120, lambda elapsed: self.world.pm2["db"].update(
            status="online" if int(elapsed // 60) % 10 == 9 else "waiting restart"))
        self.assertEqual(self.alerts, ["watchdog:flapping:db"])
        self.assertLessEqual(self.alert_times[0], 17 * 60)
        self.world.pm2["db"]["status"] = "online"                                 # minute 119 was healthy too
        self.run_minutes(28)
        self.assertEqual(self.alerts, ["watchdog:flapping:db"])                  # 29 healthy in a row: open
        self.run_minutes(1)
        self.assertEqual(self.alerts, ["watchdog:flapping:db", "watchdog:recovered:db"])

    def test_flapping_needs_half_of_the_last_30_rounds(self):
        # unhealthy 14 of every 30 rounds (under half, in every sliding window): never flapping
        self.run_minutes(120, lambda elapsed: self.world.pm2["redis"].update(
            status="waiting restart" if int(elapsed // 60) % 30 in range(0, 28, 2) else "online"))
        self.assertNotIn("watchdog:flapping:redis", self.alerts)

        def half(elapsed):
            self.world.pm2["redis"]["status"] = "waiting restart" if int(elapsed // 60) % 2 == 0 else "online"
        self.setUp()
        self.run_minutes(29, half)                                                # 15 unhealthy of 29
        self.assertEqual(self.alerts, ["watchdog:flapping:redis"])

    def test_flapping_never_duplicates_an_open_down_episode(self):
        """A continuous outage alerts "down" once; the flapping rule adds nothing to it."""
        self.world.gateway_ready = False
        self.run_minutes(40)
        self.assertNotIn("watchdog:flapping:gateway", self.alerts)
        self.assertEqual(self.alerts.count("watchdog:down:gateway"), 1)

    def test_a_continuous_outage_is_down_not_flapping(self):
        """Nextcloud's not-yet bound is 15 rounds, as many as the flapping count: a continuous outage
        must still be reported by its own bound (the reviewer's S11 and S13)."""
        self.world.pm2["nextcloud"]["status"] = "waiting restart"
        self.run_minutes(60)
        self.assertEqual(self.alerts, ["watchdog:down:nextcloud"])

    def test_a_down_bound_inside_an_open_flapping_episode_sends_nothing_more(self):
        self.run_minutes(30, lambda elapsed: self.world.pm2["db"].update(
            status="online" if int(elapsed // 60) % 10 == 9 else "waiting restart"))
        self.assertEqual(self.alerts, ["watchdog:flapping:db"])
        self.world.pm2["db"]["status"] = "waiting restart"                       # now down for good
        self.run_minutes(30)
        self.assertEqual(self.alerts, ["watchdog:flapping:db"])                  # one alert per episode
        self.world.pm2["db"]["status"] = "online"
        self.run_minutes(30)
        self.assertEqual(self.alerts, ["watchdog:flapping:db", "watchdog:recovered:db"])

    def test_maintenance_and_intentional_stops_never_count_as_flapping(self):
        self.run_minutes(60, lambda elapsed: (setattr(self.world, "maintenance", int(elapsed // 60) % 2 == 0),
                                              self.world.pm2["cron"].update(
                                                  status="stopped" if int(elapsed // 60) % 2 else "online")))
        self.assertNotIn("watchdog:flapping:nextcloud", self.alerts)
        self.assertNotIn("watchdog:flapping:cron", self.alerts)

    def test_the_flapping_fields_round_trip_through_watchdog_json(self):
        self.run_minutes(20, lambda elapsed: self.world.pm2["db"].update(
            status="online" if int(elapsed // 60) % 10 == 9 else "waiting restart"))
        state = json.loads(json.dumps(self.dog.state))
        self.assertTrue(self.module.valid_state(state))
        self.assertTrue(state["apps"]["db"]["flapping"])


class ReviewRound6(Fixture):
    """PR #45 review at 9434746 (wd_sim5.py F1, F1c, F4; Y1, L4). Each fails at 9434746."""

    @staticmethod
    def minute(elapsed):
        return int(elapsed // 60)

    def test_f1_down_recover_cycles_become_one_flapping_episode(self):
        """gateway `waiting restart` 10 of every 11 rounds (its down bound is 8): was 32 alerts in 3 h."""
        self.run_minutes(180, lambda e: self.world.pm2["gateway"].update(
            status="online" if self.minute(e) % 11 == 10 else "waiting restart"))
        self.assertEqual(self.alerts, ["watchdog:down:gateway", "watchdog:recovered:gateway",
                                       "watchdog:flapping:gateway"])

    def test_f1c_long_down_cycles_become_one_flapping_episode(self):
        """Nextcloud `waiting restart` 20 of every 21 rounds: was 16 alerts in 3 h. Its first outage
        is a single one (recovered at once); the second healthy round converts (ruling, round 6)."""
        self.run_minutes(180, lambda e: self.world.pm2["nextcloud"].update(
            status="online" if self.minute(e) % 21 == 20 else "waiting restart"))
        self.assertLessEqual(len(self.alerts), 3)
        self.assertEqual(self.alerts[:2], ["watchdog:down:nextcloud", "watchdog:recovered:nextcloud"])
        self.world.pm2["nextcloud"]["status"] = "online"
        before = len(self.alerts)
        self.run_minutes(31)
        self.assertEqual(self.alerts[before:], ["watchdog:recovered:nextcloud"])     # one closes it

    def test_a_single_20_minute_db_outage_recovers_on_its_first_healthy_round(self):
        """Round-6 ruling: a single outage, however long, sends "recovered" on its first healthy round."""
        self.world.pm2["db"]["status"] = "waiting restart"
        self.run_minutes(20)
        self.assertEqual(self.alerts, ["watchdog:down:db"])
        self.world.pm2["db"]["status"] = "online"
        self.run_minutes(1)
        self.assertEqual(self.alerts, ["watchdog:down:db", "watchdog:recovered:db"])
        self.assertEqual(self.alert_times[-1], 20 * 60)

    def test_f4_the_cap_never_opens_a_silent_episode(self):
        """Healthcheck failing 4 of every 5 rounds: was 30 bare "recovered" in 3 h (the cap branch set
        down silently in every later cycle of the hour)."""
        self.run_minutes(180, lambda e: setattr(self.world, "gateway_ready", self.minute(e) % 5 == 4))
        self.assertEqual(self.restarts.count("gateway"), 6)
        self.assertEqual(self.alerts.count("watchdog:cap:gateway"), 3)
        self.assertLessEqual(self.alerts.count("watchdog:recovered:gateway"), 1)
        self.assertLessEqual(self.alerts.count("watchdog:flapping:gateway"), 1)
        # every "recovered" closes an episode whose alert was actually sent before it
        opened = 0
        for key in self.alerts:
            if key in ("watchdog:cap:gateway", "watchdog:down:gateway", "watchdog:flapping:gateway"):
                opened += 1
            if key == "watchdog:recovered:gateway":
                self.assertGreater(opened, 0)
                opened = 0

    def test_the_history_survives_a_recovery(self):
        self.world.pm2["gateway"]["status"] = "waiting restart"
        self.run_minutes(10)
        self.world.pm2["gateway"]["status"] = "online"
        self.run_minutes(1)
        self.assertEqual(sum(self.dog.state["apps"]["gateway"]["history"]), 10)

    # L4 -------------------------------------------------------------------------------------
    def test_l4_a_refused_enqueue_is_retried_and_never_marks_the_episode(self):
        refuse = {"on": True}

        def alert(key, title, message, priority="high"):
            self.alerts.append(key)
            self.alert_times.append(self.world.now - T0)
            self.messages.append(message)
            return not refuse["on"]
        self.dog.alert = alert
        self.world.pm2["gateway"]["status"] = "waiting restart"
        limit = self.window("gateway")
        self.run_minutes(int(limit // 60) + 12)                                   # 12 rounds past the bound
        tries = [t for key, t in zip(self.alerts, self.alert_times) if key == "watchdog:down:gateway"]
        self.assertEqual([t - tries[0] for t in tries], [0, 300, 600])            # L6: every 5 rounds
        self.assertFalse(self.dog.state["apps"]["gateway"]["down"])
        refuse["on"] = False
        attempts = len(self.alerts)
        self.run_minutes(10)
        self.assertEqual(self.alerts[attempts:], ["watchdog:down:gateway"])        # then exactly once
        self.assertTrue(self.dog.state["apps"]["gateway"]["down"])

    def test_l5_a_retry_is_never_swallowed_by_the_dispatchers_throttle(self):
        """Round 7 L5: the retry of an alert this episode never delivered bypasses the hourly
        throttle (--every 0) and counts only when queued; "suppressed" is not a delivery."""
        calls, answers = [], iter([(1, ""), (0, "suppressed\n"), (0, "queued\n"), (0, "suppressed\n")])

        class Runner:
            def run(self, argv, **_options):
                if "--key" in argv:
                    calls.append((argv[argv.index("--key") + 1], argv[argv.index("--every") + 1]))
                    code, out = next(answers)
                    return code, out, ""
                return 0, "", ""
        with mock.patch.object(self.vmops, "log", lambda *a, **k: None):
            dog = self.module.build(Runner(), {})
            self.assertFalse(dog.alert("watchdog:recovered:gateway", "t", "m"))   # refused
            self.assertFalse(dog.alert("watchdog:recovered:gateway", "t", "m"))   # retry held back: not delivered
            self.assertTrue(dog.alert("watchdog:recovered:gateway", "t", "m"))    # retry queued
            self.assertTrue(dog.alert("watchdog:suppressed:apt-dpkg", "t", "m"))  # an intended hourly throttle
        self.assertEqual(calls, [("watchdog:recovered:gateway", "0"), ("watchdog:recovered:gateway", "0"),
                                 ("watchdog:recovered:gateway", "0"), ("watchdog:suppressed:apt-dpkg", "3600")])


class ReviewRound7(Fixture):
    """PR #45 review at 9d46ced (wd_sim6.py, Z1): with a warm history (the fixture's 60 healthy
    minutes), a single outage, however long, is one urgent "down" and "recovered" on its first
    healthy round, never "flapping". Each fails at 9d46ced."""

    def single_outage(self, start, stop, minutes):
        start()
        self.run_minutes(minutes)
        stop()
        self.run_minutes(1)

    def assert_single_episode(self, app, minutes):
        self.assertNotIn(f"watchdog:flapping:{app}", self.alerts)
        downs = [i for i, key in enumerate(self.alerts) if key in (f"watchdog:down:{app}", f"watchdog:cap:{app}")]
        self.assertTrue(downs, self.alerts)
        self.assertEqual(self.priorities[downs[0]], "urgent")
        self.assertEqual(self.alerts[-1], f"watchdog:recovered:{app}")
        self.assertEqual(self.alerts.count(f"watchdog:recovered:{app}"), 1)
        self.assertEqual(self.alert_times[-1], minutes * 60)                     # the first healthy round

    def test_a_single_nextcloud_outage_of_16_30_or_60_minutes_is_down_then_recovered(self):
        for minutes in (16, 30, 60):
            with self.subTest(minutes=minutes):
                self.setUp()
                self.single_outage(lambda: self.world.pm2["nextcloud"].update(status="waiting restart"),
                                   lambda: self.world.pm2["nextcloud"].update(status="online"), minutes)
                self.assertEqual(self.alerts, ["watchdog:down:nextcloud", "watchdog:recovered:nextcloud"])
                self.assert_single_episode("nextcloud", minutes)
                self.assertEqual(self.alert_times[0], self.window("nextcloud"))  # urgent DOWN at 15 minutes

    def test_a_single_gateway_outage_of_20_to_25_minutes_recovers_at_once(self):
        for minutes in (20, 22, 25):
            with self.subTest(minutes=minutes):
                self.setUp()
                self.single_outage(lambda: setattr(self.world, "gateway_ready", False),
                                   lambda: setattr(self.world, "gateway_ready", True), minutes)
                self.assert_single_episode("gateway", minutes)

    def test_a_single_db_outage_after_a_warm_history_recovers_at_once(self):
        self.single_outage(lambda: self.world.pm2["db"].update(status="waiting restart"),
                           lambda: self.world.pm2["db"].update(status="online"), 20)
        self.assertEqual(self.alerts, ["watchdog:down:db", "watchdog:recovered:db"])
        self.assert_single_episode("db", 20)

    def test_two_outages_with_a_gap_are_one_flapping_episode(self):
        """Nextcloud out 20 minutes, healthy 5, out again: the second outage is flapping (the
        reviewer's case), and the first one still recovered at once."""
        self.single_outage(lambda: self.world.pm2["nextcloud"].update(status="waiting restart"),
                           lambda: self.world.pm2["nextcloud"].update(status="online"), 20)
        self.run_minutes(4)
        self.world.pm2["nextcloud"]["status"] = "waiting restart"
        self.run_minutes(120)
        self.assertEqual(self.alerts, ["watchdog:down:nextcloud", "watchdog:recovered:nextcloud",
                                       "watchdog:flapping:nextcloud"])


if __name__ == "__main__":
    unittest.main()
