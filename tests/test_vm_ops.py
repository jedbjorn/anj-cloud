"""Spec #21 VM operations (B2): dispatcher, watchdog, watchers, boot health, reboot window guard.

Offline and bounded: clocks, markers, probes and actions are injected; the dispatcher runs as a
subprocess against a loopback ntfy stand-in with a throwaway topic. No PM2, Docker or VM is touched.
"""

import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import unittest.mock

from deploy.vm import paths

ROOT = Path(__file__).resolve().parent.parent
OPS = ROOT / "deploy" / "vm" / "ops"


def load(name):
    loader = importlib.machinery.SourceFileLoader("anj_ops_" + name.replace("-", "_"), str(OPS / name))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


class MockNtfy:
    """Loopback ntfy.sh stand-in: records POSTs; `fail` makes it answer 503."""

    def __init__(self):
        self.posts = []
        self.fail = False
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(self):
                body = self.rfile.read(int(self.headers.get("Content-Length", "0"))).decode()
                if owner.fail:
                    self.send_response(503)
                    self.end_headers()
                    return
                owner.posts.append({"path": self.path, "title": self.headers.get("Title"),
                                    "priority": self.headers.get("Priority"), "body": body})
                self.send_response(200)
                self.send_header("Content-Length", "2")
                self.end_headers()
                self.wfile.write(b"{}")

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}"
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()


class Dispatcher(unittest.TestCase):
    TOPIC = "qualtopic-" + "x" * 22   # throwaway test topic, never a real one

    def setUp(self):
        self.temp = Path(tempfile.mkdtemp(prefix="anj-b2-alert-"))
        self.state = self.temp / "state"
        (self.state / "run").mkdir(parents=True)
        (self.state / "secrets").mkdir(mode=0o700)
        topic = self.state / "secrets" / "ntfy-topic"
        topic.write_text(self.TOPIC + "\n")
        topic.chmod(0o600)
        self.ntfy = MockNtfy()
        self.addCleanup(self.ntfy.close)
        self.addCleanup(shutil.rmtree, self.temp, True)

    def alert(self, *args):
        env = dict(os.environ, ANJ_ALERT_TEST="1", ANJ_ALERT_STATE_ROOT=str(self.state), ANJ_NTFY_SERVER=self.ntfy.url)
        return subprocess.run([sys.executable, "-I", str(OPS / "anj-alert"), *args], capture_output=True, text=True,
                              env=env, timeout=60)

    def spool(self):
        return sorted((self.state / "run" / "alerts").glob("*.json"))

    def test_contract_enqueues_a_spool_record_with_the_published_fields(self):
        result = self.alert("--key", "backup-cap", "--title", "anj-cloud backup", "--priority", "urgent", "--",
                            "cap reached")
        self.assertEqual((result.returncode, result.stdout.strip()), (0, "queued"))
        records = self.spool()
        self.assertEqual(len(records), 1)
        self.assertRegex(records[0].name, r"^\d{8}T\d{6}\.\d{6}Z-backup-cap\.json$")
        self.assertEqual(oct(records[0].stat().st_mode & 0o777), "0o600")
        self.assertEqual(oct((self.state / "run" / "alerts").stat().st_mode & 0o777), "0o700")
        record = json.loads(records[0].read_text())
        self.assertEqual(tuple(record), paths.ALERT_SPOOL_FIELDS)
        self.assertEqual((record["key"], record["priority"], record["message"]), ("backup-cap", "urgent", "cap reached"))

    def test_default_every_is_one_per_key_per_hour_and_every_zero_always_queues(self):
        self.assertEqual(self.alert("--key", "k1", "--", "one").stdout.strip(), "queued")
        self.assertEqual(self.alert("--key", "k1", "--", "two").stdout.strip(), "suppressed")
        self.assertEqual(self.alert("--key", "k2", "--", "other key").stdout.strip(), "queued")
        for _ in range(3):
            self.assertEqual(self.alert("--key", "ddns", "--every", "0", "--", "self-throttled").stdout.strip(), "queued")
        self.assertEqual(len(self.spool()), 5)

    def test_messages_carry_no_paths_or_secret_like_runs(self):
        self.alert("--key", "x", "--", "failed reading /srv/anj-cloud/state/secrets/restic-password token",
                   "A" * 40, "photo.jpg/../x.txt", "LAN 192.168.0.0/24 ok", "/health ok")
        message = json.loads(self.spool()[0].read_text())["message"]
        self.assertNotIn("/srv", message)
        self.assertNotIn("A" * 40, message)
        self.assertIn("[path]", message)
        self.assertIn("192.168.0.0/24", message)
        self.assertIn("/health", message)

    def test_drain_posts_oldest_first_and_removes_only_delivered_records(self):
        self.alert("--key", "a", "--title", "first", "--", "one")
        self.alert("--key", "b", "--title", "second", "--", "two")
        self.ntfy.fail = True
        result = self.alert("--drain", "--once")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(len(self.spool()), 2)                         # kept for the retry
        self.assertIn("alert-retry", result.stdout)
        self.ntfy.fail = False
        result = self.alert("--drain", "--once")
        self.assertEqual(self.spool(), [])
        self.assertEqual([post["title"] for post in self.ntfy.posts], ["first", "second"])
        self.assertEqual(self.ntfy.posts[0]["path"], "/" + self.TOPIC)
        self.assertNotIn(self.TOPIC, result.stdout + result.stderr)    # the topic is never logged
        self.assertIn('"event": "alert-sent"', result.stdout)

    def test_drain_sends_records_spooled_by_prod_py_and_scrubs_them(self):
        spool = self.state / "run" / "alerts"
        spool.mkdir(mode=0o700)
        record = {"key": "emergency-stop", "title": "anj-cloud emergency stop", "priority": "urgent",
                  "message": "stopped; see /srv/anj-cloud/state/run/emergency-stop", "created": "2026-11-03T10:00:00+00:00"}
        path = spool / "20261103T100000.000000Z-emergency-stop.json"
        path.write_text(json.dumps(record))
        path.chmod(0o600)
        self.alert("--drain", "--once")
        self.assertEqual(len(self.ntfy.posts), 1)
        self.assertNotIn("/srv", self.ntfy.posts[0]["body"])

    def test_alerts_tag_prefixes_titles(self):
        (self.state / "run" / "ops.json").write_text(json.dumps({"alerts_tag": "drill"}))
        self.alert("--key", "x", "--title", "anj-cloud backup", "--", "m")
        self.assertEqual(json.loads(self.spool()[0].read_text())["title"], "[drill] anj-cloud backup")

    def test_a_loose_topic_file_is_refused_and_nothing_is_sent(self):
        (self.state / "secrets" / "ntfy-topic").chmod(0o644)
        self.alert("--key", "x", "--", "m")
        result = self.alert("--drain", "--once")
        self.assertIn("alerts-not-configured", result.stdout)
        self.assertEqual(self.ntfy.posts, [])
        self.assertEqual(len(self.spool()), 1)

    def test_bad_arguments_are_refused(self):
        self.assertEqual(self.alert("--key", "bad key", "--", "m").returncode, 2)
        self.assertEqual(self.alert("--every", "-1", "--", "m").returncode, 2)
        self.assertEqual(self.alert("--key", "x").returncode, 2)


class Clock:
    def __init__(self, start=1_800_000_000.0):
        self.now = start

    def __call__(self):
        return self.now

    def advance(self, seconds):
        self.now += seconds


class WatchdogLogic(unittest.TestCase):
    def setUp(self):
        self.module = load("watchdog")
        self.clock = Clock()
        self.failing = {}
        self.restarts = []
        self.alerts = []
        self.markers = []
        self.emergency = False
        self.pm2 = {app: "online" for app in paths.STACK_APPS}
        self.ddns = None
        self.dog = self.module.Watchdog(
            probe=lambda apps, skip=(): {app: self.failing.get(app) for app in apps if app not in skip},
            restart=self.restarts.append, alert=lambda key, title, message, priority="high": self.alerts.append(key),
            clock=self.clock, quiet=lambda: list(self.markers), emergency=lambda: self.emergency,
            ddns=lambda: self.ddns, pm2=lambda: self.pm2,
            bounds=sys.modules["vmops"].health_bounds(ROOT / "deploy" / "compose.prod.json"))

    def ticks(self, count):
        for _ in range(count):
            self.dog.tick()
            self.clock.advance(60)

    def test_hung_gateway_restarted_after_three_failures_once_and_no_down(self):
        self.failing["gateway"] = "healthcheck"
        self.ticks(2)
        self.assertEqual(self.restarts, [])
        self.ticks(1)
        self.assertEqual(self.restarts, ["gateway"])
        self.assertEqual(self.alerts, ["watchdog:restart:gateway"])
        self.ticks(2)                                     # still starting: no second restart, no down
        self.failing.pop("gateway")
        self.ticks(3)
        self.assertEqual(self.restarts, ["gateway"])
        self.assertEqual(self.alerts, ["watchdog:restart:gateway"])

    def test_down_five_minutes_after_restart_then_recovered_once(self):
        self.failing["nextcloud"] = "status-php"
        self.ticks(3)
        self.ticks(5)
        self.assertIn("watchdog:down:nextcloud", self.alerts)
        self.assertEqual(self.alerts.count("watchdog:down:nextcloud"), 1)
        self.failing.pop("nextcloud")
        self.ticks(2)
        self.assertEqual(self.alerts.count("watchdog:recovered:nextcloud"), 1)

    def test_at_most_two_restarts_per_hour_then_an_alert_instead(self):
        self.failing["haproxy"] = "haproxy-path"       # decision #111: 2 per app per hour
        self.ticks(40)
        self.assertEqual(self.restarts.count("haproxy"), 2)
        self.assertIn("watchdog:cap:haproxy", self.alerts)
        self.assertEqual(self.alerts.count("watchdog:cap:haproxy"), 1)

    def test_dependency_failure_is_not_counted_against_dependents(self):
        self.failing.update(db="container-unhealthy", nextcloud="status-php", gateway="healthcheck")
        self.ticks(3)
        self.assertEqual(self.restarts, ["db"])

    def test_backup_marker_suppresses_everything(self):
        self.markers = ["backup-in-progress"]
        self.failing["gateway"] = "healthcheck"
        self.ticks(10)
        self.assertEqual((self.restarts, self.alerts), ([], []))
        self.assertEqual(self.dog.tick()["result"], "suppressed")

    def test_emergency_stop_apps_are_reported_not_restarted(self):
        self.emergency = True
        self.failing.update(gateway="pm2-stopped", haproxy="pm2-stopped")
        self.ticks(10)
        self.assertEqual((self.restarts, self.alerts), ([], []))
        self.assertEqual(self.dog.tick()["apps"]["gateway"], "stopped by emergency stop")

    def test_ddns_stale_alerts_only_when_ddns_has_stopped_running(self):
        self.pm2[paths.DDNS_APP] = "stopped"
        self.ddns = {"last_success": self.clock.now - 3600, "failures": 4}    # DDNS alerted itself (--every 0)
        self.ticks(3)
        self.assertNotIn("watchdog:ddns", self.alerts)
        self.ddns = {"last_success": self.clock.now - 3600, "failures": 0}    # not running at all
        self.ticks(3)
        self.assertEqual(self.alerts.count("watchdog:ddns"), 1)
        self.assertEqual(self.restarts, [])

    def test_real_probe_reports_pm2_and_container_states(self):
        vmops = sys.modules["vmops"]

        class Runner:
            def run(self, argv, **_options):
                if argv[:2] == ["pm2", "jlist"]:
                    return 0, json.dumps([{"name": "db", "pm2_env": {"status": "online"}},
                                          {"name": "redis", "pm2_env": {"status": "errored"}}]), ""
                if argv[0] == "docker" and argv[1] == "inspect":
                    return 0, json.dumps({"Running": True, "Health": {"Status": "unhealthy"}}), ""
                return 1, "", ""

        results = vmops.Probe(Runner(), Path(tempfile.gettempdir())).results(("db", "redis", "cron"))
        self.assertEqual(results, {"db": "container-unhealthy", "redis": "pm2-errored", "cron": "wait:pm2-missing"})


class WatchdogIntentionalStates(unittest.TestCase):
    """Review M3: the watchdog never fights stop, redeploy, updates, reboots or a slow start."""

    def setUp(self):
        self.module = load("watchdog")
        self.vmops = sys.modules["vmops"]
        self.clock = Clock()
        self.restarts, self.alerts = [], []
        self.pm2_status = {app: "online" for app in paths.STACK_APPS + paths.WATCHED_EXTRA_APPS}
        self.since = {}                                  # PM2 start time per app (default: an hour ago)
        self.console_answers = True
        self.started = {service: self.clock.now - 3600 for service in paths.COMPOSE_SERVICE.values()}
        self.health = {"db": "healthy", "redis": "healthy", "nextcloud": "healthy", "access": "healthy"}
        self.gateway_ready = True
        test = self

        class Runner:
            def run(self, argv, **_options):
                if argv[:2] == ["pm2", "jlist"]:
                    return 0, json.dumps([{"name": name, "pm2_env": {
                        "status": status, "pm_uptime": test.since.get(name, test.clock.now - 3600) * 1000}}
                        for name, status in test.pm2_status.items()]), ""
                if argv[:2] == ["docker", "inspect"]:
                    service = argv[-1][len(paths.PROJECT) + 1:-2]
                    started = datetime.datetime.fromtimestamp(test.started[service], datetime.timezone.utc)
                    state = {"Running": True, "StartedAt": started.strftime("%Y-%m-%dT%H:%M:%S.123456789Z")}
                    if service in test.health:
                        state["Health"] = {"Status": test.health[service]}
                    return 0, json.dumps(state), ""
                if argv[:2] == ["docker", "exec"] and "access.health" in argv:
                    return (0, '{"status": "ready"}\n', "") if test.gateway_ready else (124, "", "timed out")
                if argv[:2] == ["docker", "exec"]:
                    return 0, '{"installed": true, "maintenance": false}\n', ""
                return 1, "", ""

        bounds = self.vmops.health_bounds(ROOT / "deploy" / "compose.prod.json")
        self.dog = self.module.Watchdog(
            probe=lambda apps, skip=(): self.vmops.Probe(Runner(), Path(tempfile.gettempdir()), clock=self.clock,
                                                        bounds=bounds).results(apps, skip=skip),
            restart=self.restarts.append, alert=lambda key, title, message, priority="high": self.alerts.append(key),
            clock=self.clock, quiet=lambda: [], bounds=bounds)
        patcher = unittest.mock.patch.object(self.vmops, "haproxy_path", lambda *a, **k: True)
        patcher.start()
        self.addCleanup(patcher.stop)
        patcher = unittest.mock.patch.object(self.vmops, "console_answers", lambda *a, **k: self.console_answers)
        patcher.start()
        self.addCleanup(patcher.stop)

    def ticks(self, count):
        for _ in range(count):
            self.dog.tick()
            self.clock.advance(60)

    def test_prod_py_stop_is_never_restarted(self):
        for app in paths.STACK_APPS:
            self.pm2_status[app] = "stopped"
        self.ticks(15)
        self.assertEqual((self.restarts, self.alerts), ([], []))
        self.assertEqual(self.dog.tick()["apps"]["db"], "not yet: pm2-stopped")

    def test_launching_and_waiting_restart_are_not_failures(self):
        self.pm2_status["gateway"] = "launching"
        self.pm2_status["cron"] = "waiting restart"
        self.ticks(10)
        self.assertEqual(self.restarts, [])

    def test_nextcloud_starting_for_five_and_a_half_minutes_is_not_restarted(self):
        self.started["nextcloud"] = self.clock.now
        self.health["nextcloud"] = "starting"            # e.g. an occ upgrade during redeploy
        self.ticks(6)                                    # 0..300 s, within 30 s + 60 x 5 s
        self.clock.advance(30)                           # 5.5 minutes
        self.dog.tick()
        self.assertEqual(self.restarts, [])
        self.assertEqual(self.alerts, [])

    def test_starting_beyond_its_own_bound_counts(self):
        self.started["nextcloud"] = self.clock.now
        self.health["nextcloud"] = "starting"
        self.ticks(12)                                   # bound 330 s, then 3 failing checks
        self.assertEqual(self.restarts, ["nextcloud"])

    def test_a_genuinely_hung_gateway_is_restarted_after_three_checks(self):
        self.gateway_ready = False                       # online, healthy container, not answering
        self.ticks(2)
        self.assertEqual(self.restarts, [])
        self.ticks(1)
        self.assertEqual(self.restarts, ["gateway"])
        self.assertEqual(self.alerts, ["watchdog:restart:gateway"])

    def test_a_console_backend_that_stops_answering_is_restarted_after_three_checks(self):
        """Decision #112 (1): the console app is watched like the others (online, socket answers)."""
        self.console_answers = False
        self.ticks(2)
        self.assertEqual((self.restarts, self.alerts), ([], []))
        self.ticks(1)
        self.assertEqual(self.restarts, ["console"])
        self.assertEqual(self.alerts, ["watchdog:restart:console"])

    def test_a_console_backend_just_started_gets_a_start_grace_then_counts(self):
        self.console_answers = False
        self.since["console"] = self.clock.now
        self.assertEqual("not yet: starting", self.dog.tick()["apps"]["console"])
        self.clock.advance(30)
        self.assertEqual("not yet: starting", self.dog.tick()["apps"]["console"])
        self.clock.advance(30)
        self.assertEqual("console-socket", self.dog.tick()["apps"]["console"])
        self.assertEqual(self.restarts, [])
        self.console_answers = True
        self.clock.advance(60)
        self.assertEqual("ok", self.dog.tick()["apps"]["console"])
        self.assertEqual((self.restarts, self.alerts), ([], []))

    def test_a_stopped_console_backend_is_intentional(self):
        self.pm2_status["console"] = "stopped"
        self.console_answers = False
        self.ticks(15)
        self.assertEqual((self.restarts, self.alerts), ([], []))

    def test_errored_is_a_failure(self):
        self.pm2_status["redis"] = "errored"
        self.ticks(3)
        self.assertEqual(self.restarts, ["redis"])

    def test_quiet_windows_and_ten_minutes_after_an_update(self):
        reasons = ["upgrade"]
        self.dog.quiet = lambda: list(reasons)
        self.gateway_ready = False
        self.ticks(5)
        reasons.clear()
        self.ticks(9)                                    # still inside the 10 minutes after the update
        self.assertEqual(self.restarts, [])
        self.ticks(4)
        self.assertEqual(self.restarts, ["gateway"])

    def test_busy_processes_and_system_state(self):
        temp = Path(tempfile.mkdtemp(prefix="anj-b2-busy-"))
        self.addCleanup(shutil.rmtree, temp, True)
        for pid, argv in (("11", ["python3", "/srv/anj-cloud/release/current/deploy/prod.py", "redeploy", "abc"]),
                          ("12", ["/usr/bin/python3", "/usr/bin/unattended-upgrade"]),
                          ("13", ["python3", "/srv/x/deploy/prod.py", "status"])):
            (temp / pid).mkdir()
            (temp / pid / "cmdline").write_bytes(b"\0".join(p.encode() for p in argv) + b"\0")
        self.assertEqual(self.vmops.busy_processes(temp), ["apt/dpkg", "prod.py redeploy"])

        class Runner:
            def __init__(self, outputs):
                self.outputs = outputs

            def run(self, argv, **_options):
                return 0, self.outputs.get(argv[-1], ""), ""
        self.assertEqual(self.vmops.system_quiet(Runner({"apt-daily-upgrade.service": "inactive",
                                                         "is-system-running": "running"}), uptime_seconds=3600), [])
        self.assertEqual(self.vmops.system_quiet(Runner({"apt-daily-upgrade.service": "activating",
                                                         "is-system-running": "stopping"}), uptime_seconds=120),
                         ["upgrade", "system stopping", "boot grace"])

    def test_health_bounds_come_from_compose(self):
        bounds = self.vmops.health_bounds(ROOT / "deploy" / "compose.prod.json")
        self.assertEqual(bounds["nextcloud"], 330.0)       # 30 s + 60 x 5 s
        self.assertEqual(self.vmops.duration("1m30s"), 90.0)


class OneTimeSecrets(unittest.TestCase):
    def test_expired_first_code_and_old_subscribe_link_are_removed(self):
        vmops = load("watchdog") and sys.modules["vmops"]
        temp = Path(tempfile.mkdtemp(prefix="anj-b2-sweep-"))
        self.addCleanup(shutil.rmtree, temp, True)
        (temp / "secrets").mkdir()
        code, link = temp / "secrets" / "first-pairing-code", temp / "secrets" / "ntfy-subscribe-link"
        code.write_text("x\n")
        link.write_text("y\n")
        (temp / "setup.json").write_text(json.dumps({"first_invite": {"expires": 1000.0}}))
        self.assertEqual(vmops.sweep_one_time_secrets(temp, now=999.0), [])
        self.assertEqual(vmops.sweep_one_time_secrets(temp, now=1001.0), ["first-pairing-code"])
        os.utime(link, (0, 0))
        self.assertEqual(vmops.sweep_one_time_secrets(temp, now=time.time()), ["ntfy-subscribe-link"])
        self.assertFalse(code.exists() or link.exists())

    def test_backups_exclude_the_one_time_files(self):
        from deploy import backup
        self.assertIn("/backup/state/secrets/first-pairing-code", backup.RESTIC_EXCLUDES)
        self.assertIn("/backup/state/secrets/ntfy-subscribe-link", backup.RESTIC_EXCLUDES)


class WatchersLogic(unittest.TestCase):
    def setUp(self):
        self.module = load("watchers")
        self.clock = Clock()
        self.watchers = self.module.Watchers({}, clock=self.clock)

    def test_enrollment_blocks_cap_six_per_hour_with_one_summary(self):
        alerts = []
        events = [{"event": "enroll-block", "source": f"203.0.113.{i}", "failures": 8, "_t": self.clock.now}
                  for i in range(9)]
        self.watchers.gateway(events, alerts, self.module.Counter())
        self.assertEqual(len([a for a in alerts if a[0] == "watchers:enroll-block"]), 6)
        self.clock.advance(3600)
        later = []
        self.watchers.gateway([], later, self.module.Counter())
        self.assertEqual([a[0] for a in later], ["watchers:enroll-block-summary"])
        self.assertIn("3 more enrollment blocks", later[0][2])

    def test_bursts_of_429_and_401(self):
        alerts = []
        now = self.clock.now
        events = [{"event": "summary", "counts": {"enroll-limit": 25}, "_t": now}]
        events += [{"event": "request", "status": 401, "source": "198.51.100.7", "_t": now} for _ in range(10)]
        self.watchers.gateway(events, alerts, self.module.Counter())
        keys = [a[0] for a in alerts]
        self.assertIn("watchers:enroll-429", keys)
        self.assertIn("watchers:auth:198.51.100.7", keys)
        self.assertFalse(any("/" in a[2].replace("401/403", "") for a in alerts))

    def test_certificate_within_30_days_alerts(self):
        alerts = []
        self.watchers.certificates(lambda name: 12.0 if name == "server.crt" else 3000.0, alerts)
        self.assertEqual([a[0] for a in alerts], ["watchers:cert:server"])

    def test_backup_and_ddns_failures_are_digest_only(self):
        temp = Path(tempfile.mkdtemp(prefix="anj-b2-watchers-"))
        self.addCleanup(shutil.rmtree, temp, True)
        (temp / "run").mkdir()
        (temp / "backup-status.json").write_text(json.dumps({"last_run": {"result": "failed"}}))
        (temp / "run" / "ddns-state.json").write_text(json.dumps({"failures": 5}))
        facts = self.module.owner_facts(temp)
        self.assertEqual(facts, {"backup-last": "failed", "ddns-consecutive-failures": 5})
        alerts = []
        self.watchers.digest(self.module.Counter(requests=3), facts, alerts)
        self.assertEqual(alerts, [])                       # same day: nothing; never a failure alert
        self.clock.advance(86400)
        self.watchers.digest(self.module.Counter(), facts, alerts)
        self.assertEqual(len(alerts), 1)
        self.assertTrue(alerts[0][0].startswith("watchers:digest:"))


class BootHealth(unittest.TestCase):
    def setUp(self):
        self.module = load("boot-health")
        self.alerts = []
        self.up = Clock(30)

    def run_until(self, failing_until=None, emergency=False):
        def probe(apps, skip=()):
            bad = self.up() < failing_until if failing_until else False
            return {app: ("healthcheck" if bad and app == "nextcloud" else None) for app in apps if app not in skip}
        return self.module.wait_healthy(probe=probe, emergency=lambda: emergency,
                                        alert=lambda key, title, message, priority: self.alerts.append(message),
                                        uptime=self.up, sleep=self.up.advance)

    def test_one_back_healthy_message(self):
        self.assertEqual(self.run_until(failing_until=200)[0], "healthy")
        self.assertEqual(self.alerts, ["anj-cloud back healthy after reboot."])

    def test_emergency_stop_is_stated(self):
        self.run_until(emergency=True)
        self.assertIn("emergency stop in place", self.alerts[0])

    def test_its_log_records_that_the_stop_was_stated_never_the_text(self):
        """qualify.py's reboot_emergency row reads boot-health's own journal line."""
        vmops = sys.modules["vmops"]
        logged = []

        def fake_wait(*, probe, emergency, alert, **_kw):
            alert("boot-health", "anj-cloud back healthy", "anj-cloud back healthy after reboot" +
                  self.module.EMERGENCY_NOTE + ".", "default")
            return "healthy", []
        with unittest.mock.patch.object(self.module, "wait_healthy", fake_wait), \
                unittest.mock.patch.object(vmops, "send_alert", lambda *a, **k: True), \
                unittest.mock.patch.object(vmops, "log", lambda event, **fields: logged.append((event, fields))):
            self.assertEqual(self.module.main([]), 0)
        final = dict(logged)["boot-health"]
        self.assertEqual(final, {"result": "healthy", "failures": [], "emergency_stop_stated": True})
        self.assertNotIn("public access", json.dumps(logged))

    def test_unhealthy_at_ten_minutes_names_the_failed_check(self):
        result, failures = self.run_until(failing_until=10_000)
        self.assertEqual((result, failures), ("unhealthy", ["nextcloud:healthcheck"]))
        self.assertEqual(len(self.alerts), 1)
        self.assertIn("nextcloud:healthcheck", self.alerts[0])


class RebootGuard(unittest.TestCase):
    """Decision #86 logic with the clock and markers injected (spec #21 'Reboot window guard', merge row)."""

    def setUp(self):
        self.module = load("reboot-guard")
        self.moment = datetime.datetime(2026, 11, 4, 4, 15).astimezone()
        self.reboots = []
        self.alerts = []
        self.logs = []
        self.saved = {}
        self.required = True
        self.busy = []
        self.processes = []
        self.dpkg = False

    def clock(self):
        return self.moment

    def sleep(self, seconds):
        self.moment += datetime.timedelta(seconds=seconds)
        # Busy conditions clear after the first wait when the test says so.
        if getattr(self, "clear_after_wait", False):
            self.busy, self.processes, self.dpkg = [], [], False

    def guard(self, state=None):
        return self.module.Guard(
            clock=self.clock, sleep=self.sleep, reboot_required=lambda: self.required,
            window_busy=lambda: list(self.busy), processes=lambda: list(self.processes), dpkg_busy=lambda: self.dpkg,
            reboot=lambda: self.reboots.append(self.moment.strftime("%H:%M")),
            alert=lambda key, title, message: self.alerts.append(key), state=state if state is not None else {},
            save=lambda data: self.saved.update(data), log=lambda event, **fields: self.logs.append(fields))

    def test_reboots_in_the_window_when_everything_is_clear(self):
        self.assertEqual(self.guard().run(), "reboot")
        self.assertEqual(self.reboots, ["04:15"])
        self.assertEqual(self.logs[-1]["decision"], "reboot")

    def test_no_reboot_outside_the_window(self):
        for hour, minute in ((3, 59), (5, 0), (12, 0), (23, 30)):
            self.moment = datetime.datetime(2026, 11, 4, hour, minute).astimezone()
            self.assertEqual(self.guard().run(), "skip")
        self.assertEqual(self.reboots, [])

    def test_nothing_to_do_without_reboot_required(self):
        self.required = False
        self.assertEqual(self.guard().run(), "none")
        self.assertEqual(self.reboots, [])

    def test_backup_marker_waits_in_five_minute_steps_until_05_00_then_skips(self):
        self.busy = ["backup-marker"]
        self.assertEqual(self.guard().run(), "skip")
        self.assertEqual(self.reboots, [])
        self.assertEqual(self.moment.strftime("%H:%M"), "04:55")
        self.assertEqual([entry["decision"] for entry in self.logs].count("wait"), 8)
        self.assertTrue(all(entry["reasons"] == ["backup-marker"] for entry in self.logs))

    def test_live_backup_process_and_dpkg_lock_block(self):
        self.processes = ["backup-process"]
        self.assertEqual(self.guard().run(), "skip")
        self.moment = datetime.datetime(2026, 11, 5, 4, 15).astimezone()
        self.processes, self.dpkg = [], True
        self.assertEqual(self.guard().run(), "skip")
        self.assertEqual(self.reboots, [])

    def test_waits_then_reboots_once_the_window_clears(self):
        self.busy, self.clear_after_wait = ["restore-marker"], True
        self.assertEqual(self.guard().run(), "reboot")
        self.assertEqual(self.reboots, ["04:20"])

    def test_window_check_error_counts_as_busy(self):
        self.busy = ["window-check-error"]
        self.assertEqual(self.guard().run(), "skip")
        self.assertEqual(self.reboots, [])

    def test_pending_more_than_three_nights_alerts_once(self):
        self.busy = ["backup-running"]
        state = {}
        for night in range(6):
            self.moment = datetime.datetime(2026, 11, 4 + night, 4, 15).astimezone()
            guard = self.guard(state)
            guard.run()
            state = guard.state
        self.assertEqual(self.alerts, ["reboot-guard:pending"])
        self.assertEqual(self.reboots, [])

    def test_pending_episode_resets_after_the_reboot(self):
        state = {"pending_since": "2026-10-01", "alerted": True}
        self.required = False
        guard = self.guard(state)
        guard.run()
        self.assertNotIn("pending_since", guard.state)

    def test_decide_is_pure(self):
        decide = self.module.decide
        at = datetime.datetime(2026, 11, 4, 4, 58).astimezone()
        self.assertEqual(decide(at, reboot_required=True, window_busy=["x"], processes=[], dpkg_busy=False)[0], "skip")
        at = datetime.datetime(2026, 11, 4, 4, 0).astimezone()
        self.assertEqual(decide(at, reboot_required=True, window_busy=[], processes=[], dpkg_busy=False)[0], "reboot")

    def test_dpkg_lock_probe_sees_a_held_lock(self):
        temp = Path(tempfile.mkdtemp(prefix="anj-b2-dpkg-"))
        self.addCleanup(shutil.rmtree, temp, True)
        lock = temp / "lock"
        lock.write_text("")
        holder = subprocess.Popen([sys.executable, "-c", "import fcntl,os,sys,time\n"
                                   "fd=os.open(sys.argv[1],os.O_RDWR); fcntl.lockf(fd,fcntl.LOCK_EX); print('held',flush=True)\n"
                                   "time.sleep(30)", str(lock)], stdout=subprocess.PIPE, text=True)
        self.addCleanup(holder.wait)
        self.addCleanup(holder.kill)
        self.assertEqual(holder.stdout.readline().strip(), "held")
        self.assertTrue(self.module.lock_held(lock))
        holder.kill()
        holder.wait()
        self.assertFalse(self.module.lock_held(lock))

    def test_backup_process_scan(self):
        temp = Path(tempfile.mkdtemp(prefix="anj-b2-proc-"))
        self.addCleanup(shutil.rmtree, temp, True)
        for pid, argv in (("101", ["/usr/bin/python3", "-I", "/srv/anj-cloud/release/current/deploy/backup.py", "run"]),
                          ("102", ["/usr/bin/python3", "-I", "/srv/x/deploy/backup.py", "window", "--check"]),
                          ("103", ["sshd"])):
            (temp / pid).mkdir()
            (temp / pid / "cmdline").write_bytes(b"\0".join(part.encode() for part in argv) + b"\0")
        self.assertEqual(self.module.backup_processes(temp), ["backup-process"])


class Units(unittest.TestCase):
    def test_boot_health_never_blocks_boot_or_degrades_the_system(self):
        unit = (ROOT / "deploy" / "vm" / "systemd" / "anj-cloud-boot-health.service").read_text()
        self.assertIn("Type=exec", unit)
        self.assertNotIn("Type=oneshot", unit)
        self.assertNotIn("RemainAfterExit", unit)
        self.assertIn("return 0   # the message or alert is the result", (OPS / "boot-health").read_text())

    def test_firewall_unit_never_deletes_the_table(self):
        unit = (ROOT / "deploy" / "vm" / "systemd" / "anj-cloud-firewall.service").read_text()
        self.assertNotIn("\nExecStop", unit)
        self.assertNotIn("delete table", "\n".join(l for l in unit.splitlines() if not l.startswith("#")))
        self.assertIn("ExecReload=/usr/sbin/nft -f /etc/anj-cloud/firewall.nft", unit)

    def test_reboot_guard_and_update_run_timing(self):
        timer = (ROOT / "deploy" / "vm" / "systemd" / "anj-cloud-reboot-guard.timer").read_text()
        self.assertIn("OnCalendar=*-*-* 04:15:00", timer)
        self.assertIn("Persistent=false", timer)
        upgrade = (ROOT / "deploy" / "vm" / "systemd" / "dropins" / "apt-daily-upgrade.timer.d" / "zz-anj-cloud.conf").read_text()
        self.assertIn("OnCalendar=\nOnCalendar=*-*-* 04:12:00", upgrade)   # after 04:10 (decision #98)
        self.assertIn("RandomizedDelaySec=0", upgrade)
        condition = (ROOT / "deploy" / "vm" / "systemd" / "dropins" / "apt-daily-upgrade.service.d" /
                     "zz-anj-cloud.conf").read_text()
        self.assertIn("ExecCondition=/usr/bin/python3 -I @SOURCE@/deploy/backup.py window --check", condition)

    def test_unattended_upgrades_security_origins_only(self):
        text = (ROOT / "deploy" / "vm" / "config" / "52anj-cloud-unattended-upgrades").read_text()
        self.assertIn("#clear Unattended-Upgrade::Origins-Pattern;", text)
        origins = [line for line in text.splitlines() if line.strip().startswith('"origin=')]
        self.assertEqual(len(origins), 2)
        self.assertTrue(all("label=Debian-Security" in line for line in origins))
        self.assertIn('Unattended-Upgrade::Automatic-Reboot "false";', text)


if __name__ == "__main__":
    unittest.main()
