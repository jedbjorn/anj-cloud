"""Flag SC-110: `anj-cloud-setup converge`, which `upgrade` runs with the live release's own setup
after every switch, and the semantic comparisons that keep a reworded file from looking like drift.

Offline: every /srv/anj-cloud path lives under a temporary root (vm_bootstrap_flow.sandbox), the
live release is this checkout (release/current -> <commit12> -> the checkout, so ddns.py really
renders the PM2 entry), FakeSystem records every changing command, PM2 and doctor are stand-ins.
The real step 10 (Operations) runs state -> apply -> verify; the other steps are stubs.
"""

import contextlib
import copy
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock

from deploy.vm import bootstrap, paths
from tests.vm_bootstrap_fakes import FakeFacts, FakeSystem
from tests.vm_bootstrap_flow import sandbox

HOST = "family.converge.test"
ZONE = "0123456789abcdef" * 2                       # an obvious fake Cloudflare zone id
RELEASE = "c" * 40
RUNNING = {"alerts": "online", "watchdog": "online", "watchers": "online", paths.CONSOLE_APP: "online",
           paths.DDNS_APP: "stopped"}             # ddns is idle between its 5-minute runs


class ScriptedSystem(FakeSystem):
    """FakeSystem whose changing commands can fail: `failing` maps an argv prefix to (code, err)."""

    failing = {}

    def change(self, argv, **options):
        result = super().change(argv, **options)
        text = " ".join(str(a) for a in argv)
        for prefix, (code, err) in self.failing.items():
            if text.startswith(prefix):
                if options.get("check", True):
                    raise bootstrap.SetupError(f"`{argv[0]} {argv[1]}` failed (exit {code}). {err}", "Fix it.")
                return code, "", err
        return result


class Stub(bootstrap.Step):
    """A setup step that only reports a state (and counts applies)."""

    def __init__(self, setup, number, name, done=True, disruptive="it restarts a core service"):
        super().__init__(setup)
        self.number, self.name, self.title = number, name, name
        self.done, self.disruptive, self.applied = done, disruptive, 0

    def state(self):
        return (True, "in place") if self.done else (False, "to fix: something")

    def apply(self):
        self.applied += 1
        self.done = True


class ConvergeTests(unittest.TestCase):
    def setUp(self):
        self.addCleanup(os.umask, os.umask(0o022))
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        stack = contextlib.ExitStack()
        self.addCleanup(stack.close)
        stack.enter_context(sandbox(self.root))
        for directory in (paths.STATE_ROOT, paths.RUN_DIR, paths.SECRETS_DIR, paths.BIN_DIR, paths.RELEASE_SOURCE_DIR,
                          bootstrap.COMMAND_LINK.parent):
            directory.mkdir(parents=True, exist_ok=True)
        # The live release is this checkout: converge runs the live release's own setup only.
        (paths.RELEASE_SOURCE_DIR / RELEASE[:12]).symlink_to(bootstrap.ROOT)
        paths.RELEASE_CURRENT.symlink_to(RELEASE[:12])
        bootstrap.COMMAND_LINK.symlink_to(bootstrap.COMMAND_TARGET)
        bootstrap.ADMIN_LINK.symlink_to(bootstrap.ADMIN_TARGET)
        self.answers = {"host": HOST, "ddns": "on", "zone_id": ZONE, "household_lan": "192.168.77.0/24",
                        "bind_address": "10.99.0.10", "admin_ssh_source": "10.99.0.1", "timezone": "Europe/Paris",
                        "start_stack": True}
        paths.STACK_CONFIG.write_text(json.dumps({"host": HOST, "release": RELEASE, "bind_address": "10.99.0.10",
                                                  "household_lan": "192.168.77.0/24"}))
        paths.NTFY_TOPIC.write_text("t" * 32 + "\n")
        paths.CLOUDFLARE_TOKEN.write_text("not-a-real-token\n")
        paths.ALERT_COMMAND.write_bytes((paths.RELEASE_CURRENT / "deploy" / "vm" / "ops" / "anj-alert").read_bytes())
        bootstrap.OPS_CONFIG.write_text(bootstrap.ops_config_text(self.answers))
        # What step 10 wants under this release: the ddns entry carries --zone-id (the answer).
        self.wanted = self.operations_apps()
        [ddns] = [app for app in self.wanted if app["name"] == paths.DDNS_APP]
        self.assertIn(f"--zone-id {ZONE}", ddns["args"])
        self.doctor_problems = []
        self.doctor_calls = []
        self.steps = None
        self.responses, self.failing, self.facts_values = {}, {}, {}
        etc = self.root / "etc-anj-cloud"
        for patch in (mock.patch.multiple(bootstrap, ETC_DIR=etc, FIREWALL_FILE=etc / "firewall.nft",
                                          SYSTEMD_DIR=self.root / "etc-systemd", PM2_DIR=self.root / "opt" / "pm2",
                                          PM2_LINK=self.root / "usr-local-bin" / "pm2"),):
            stack.enter_context(patch)
        for patch in (mock.patch.object(bootstrap.os, "geteuid", return_value=0),
                      mock.patch.object(bootstrap, "pm2_list", return_value=dict(RUNNING)),
                      mock.patch.object(bootstrap, "doctor", side_effect=self.doctor),
                      mock.patch.object(bootstrap.Setup, "step_list", lambda setup: self.step_list(setup))):
            stack.enter_context(patch)

    def operations_apps(self):
        system = FakeSystem(dry=True)
        setup = bootstrap.Setup(bootstrap.parser().parse_args([]), system=system, facts=FakeFacts(system),
                                out=io.StringIO())
        setup.answers = dict(self.answers)
        return bootstrap.Operations(setup).apps()

    def installed(self, apps):
        """Step 10 as an earlier release left it: this ecosystem, these apps started (setup.json)."""
        bootstrap.OPS_ECOSYSTEM.parent.mkdir(parents=True, exist_ok=True)
        bootstrap.OPS_ECOSYSTEM.write_text(bootstrap.ecosystem_text(apps))
        bootstrap.SETUP_RECORD.write_text(json.dumps({
            "answers": self.answers, "accounts": ["sam"], "timezone": "Europe/Paris", "release": RELEASE,
            "ops_apps": {app["name"]: bootstrap.app_digest(app) for app in apps}}))

    def old_release_apps(self):
        """The release before: ddns ran with `run` only (it then read the zone from a profile)."""
        apps = copy.deepcopy(self.wanted)
        for app in apps:
            if app["name"] == paths.DDNS_APP:
                app["args"] = "run"
        return apps

    def step_list(self, setup):
        if self.steps is None:
            self.steps = {"docker": Stub(setup, 4, "Docker", done=self.docker_done,
                                         disruptive="it restarts the Docker daemon, and with it every container")}
            for name, factory in self.extra_steps:
                self.steps[name] = factory(setup)
            self.steps.update({"operations": bootstrap.Operations(setup),
                               "timers": Stub(setup, 11, "Timers", disruptive=None)})
        else:
            for step in self.steps.values():
                step.setup, step.system, step.facts = setup, setup.system, setup.facts
        return list(self.steps.values())

    docker_done = True
    extra_steps = ()            # (name, factory) of real steps placed before step 10

    def doctor(self, setup):
        self.doctor_calls.append((setup.read_only, setup.system.dry))
        return list(self.doctor_problems), {}

    def converge(self, *argv):
        self.out = io.StringIO()
        self.system = ScriptedSystem(dry=False, out=self.out, responses=self.responses)
        self.system.failing = self.failing
        code = bootstrap.main(["converge", "--json", *argv], system=self.system,
                              facts=FakeFacts(self.system, **self.facts_values), out=self.out)
        self.result = json.loads(self.out.getvalue().strip().splitlines()[-1])
        return code

    def commands(self):
        return [entry["argv"] for entry in self.system.commands]

    def evidence(self):
        return json.loads(Path(self.result["evidence"]).read_text())

    # ---------------------------------------------------------------------------------------------
    def test_changed_ddns_arguments_reapply_step_10_and_are_recorded(self):
        """The 56d348d -> eb11af9 case: the release's step 10 wants `run --zone-id <zone>`; the
        live ecosystem still has `run`. Converge re-applies step 10, and only it."""
        self.installed(self.old_release_apps())
        self.assertEqual(0, self.converge(), self.out.getvalue())
        self.assertEqual([[10, "Operations apps", "changed", True]],
                         [[e["step"], e["name"], e["result"], e["passed"]] for e in self.result["steps"]])
        self.assertIn("to do: ecosystem, app ddns", self.result["steps"][0]["before"])
        self.assertEqual("converged", self.result["result"])
        self.assertEqual([["pm2", "delete", paths.DDNS_APP],
                          ["pm2", "start", str(bootstrap.OPS_ECOSYSTEM), "--only", paths.DDNS_APP], ["pm2", "save"]],
                         self.commands())
        self.assertIn(f"--zone-id {ZONE}", bootstrap.OPS_ECOSYSTEM.read_text())
        record = json.loads(bootstrap.SETUP_RECORD.read_text())
        self.assertEqual(bootstrap.app_digest(next(a for a in self.wanted if a["name"] == paths.DDNS_APP)),
                         record["ops_apps"][paths.DDNS_APP])
        self.assertEqual(0, self.steps["timers"].applied)
        self.assertEqual([(True, True)], self.doctor_calls)        # doctor ran read-only, after the apply
        evidence = self.evidence()
        self.assertEqual(("converged", "converge"), (evidence["result"], evidence["command"]))
        self.assertEqual([10], [entry["step"] for entry in evidence["steps"]])
        self.assertNotIn("not-a-real-token", json.dumps(evidence))
        self.assertIn("Setup re-applied: step 10 Operations apps. Doctor: all checks pass.", self.out.getvalue())

    def test_nothing_changed_records_no_steps_and_changes_nothing(self):
        self.installed(self.wanted)
        self.assertEqual(0, self.converge(), self.out.getvalue())
        self.assertEqual([], self.result["steps"])
        self.assertEqual([], self.commands())
        self.assertEqual([], self.evidence()["steps"])
        self.assertEqual(1, len(self.doctor_calls))
        self.assertIn("Setup re-applied: none needed. Doctor: all checks pass.", self.out.getvalue())

    def test_a_disruptive_step_not_done_stops_before_anything_is_applied(self):
        self.docker_done = False
        self.installed(self.old_release_apps())            # step 10 would be safe, but waits too
        self.assertEqual(1, self.converge())
        text = self.out.getvalue()
        self.assertIn("Step 4 Docker: to fix: something", text)
        self.assertIn("not applied: it restarts the Docker daemon, and with it every container", text)
        self.assertIn("also waiting: step 10 Operations apps", text)
        self.assertIn("anj-cloud-setup` shows each step and applies it", text)
        self.assertEqual(0, self.steps["docker"].applied)
        self.assertEqual([], self.commands())
        self.assertNotIn("--zone-id", bootstrap.OPS_ECOSYSTEM.read_text())
        self.assertEqual([], self.doctor_calls)
        self.assertEqual("blocked", self.result["result"])
        self.assertEqual([{"step": 4, "name": "Docker", "state": "to fix: something",
                           "why": "it restarts the Docker daemon, and with it every container"}], self.result["blocked"])
        self.assertEqual("blocked", self.evidence()["result"])

    def test_a_missing_secret_is_never_invented(self):
        paths.NTFY_TOPIC.unlink()
        self.installed(self.wanted)
        self.assertEqual(1, self.converge())
        self.assertIn("the ntfy topic is missing, and only setup at a terminal asks for it", self.out.getvalue())
        self.assertFalse(paths.NTFY_TOPIC.exists())
        self.assertEqual([], self.commands())

    def test_doctor_problems_after_the_reapply_fail_loudly(self):
        self.installed(self.old_release_apps())
        self.doctor_problems = [("Firewall", "Step 5 Firewall: not installed or different", "Run setup.")]
        self.assertEqual(1, self.converge())
        self.assertEqual([10], [entry["step"] for entry in self.result["steps"]])   # what did run is kept
        self.assertEqual(("problems remain", ["Step 5 Firewall: not installed or different"]),
                         (self.result["result"], self.result["problems"]))
        text = self.out.getvalue()
        self.assertIn("Doctor still finds 1 problem(s) (setup re-applied: step 10 Operations apps)", text)
        self.assertIn("PROBLEM Step 5 Firewall: not installed or different", text)
        self.assertEqual("problems remain", self.evidence()["result"])

    def test_refusals_change_nothing(self):
        self.installed(self.old_release_apps())
        cases = []
        record = json.loads(bootstrap.SETUP_RECORD.read_text())
        # DDNS on with no real zone recorded: the placeholder would fail Cloudflare (403) every 5 minutes.
        record["answers"]["zone_id"] = bootstrap.PLACEHOLDER_ZONE
        bootstrap.SETUP_RECORD.write_text(json.dumps(record))
        cases.append(("does not record zone_id", self.converge()))
        record["answers"]["zone_id"] = ZONE
        bootstrap.SETUP_RECORD.write_text(json.dumps(record))
        # A switch that did not finish: stack.json names another release than release/current.
        paths.STACK_CONFIG.write_text(json.dumps({"host": HOST, "release": "d" * 40, "bind_address": "10.99.0.10"}))
        cases.append(("a switch did not finish", self.converge()))
        paths.STACK_CONFIG.write_text(json.dumps({"host": HOST, "release": RELEASE, "bind_address": "10.99.0.10",
                                                  "household_lan": "192.168.77.0/24"}))
        # Another copy than the live release's: its steps would want another release's state.
        with mock.patch.object(bootstrap, "ROOT", self.root):
            cases.append(("is not the live release's", self.converge()))
        with mock.patch.object(bootstrap.os, "geteuid", return_value=1000):
            cases.append(("converge needs root", self.converge()))
        for expected, code in cases:
            self.assertEqual(1, code, expected)
        text = self.out.getvalue()
        self.assertIn("converge needs root", text)
        self.assertEqual("refused", self.result["result"])
        self.assertNotIn("--zone-id", bootstrap.OPS_ECOSYSTEM.read_text())
        self.assertEqual([], self.doctor_calls)

    # B1: the SSH source ------------------------------------------------------------------------------
    def firewall_step(self, live_source="10.99.0.1", drop_rule="udp dport 546"):
        """Real step 5. The installed file is this release's rendering for `live_source`, minus one
        rule (an older release's file), so the step is not done."""
        self.extra_steps = (("firewall", bootstrap.Firewall),)
        wanted = bootstrap.render_firewall("10.99.0.10", live_source)
        bootstrap.FIREWALL_FILE.parent.mkdir(parents=True, exist_ok=True)
        bootstrap.FIREWALL_FILE.write_text("\n".join(line for line in wanted.splitlines() if drop_rule not in line) + "\n")
        units = bootstrap.SYSTEMD_DIR
        units.mkdir(parents=True, exist_ok=True)
        (units / "anj-cloud-firewall.service").write_text(
            (bootstrap.SOURCE_DIR / "systemd" / "anj-cloud-firewall.service").read_text())
        self.responses.update({"nft list table inet anj_cloud": (0, "", ""),
                               "systemctl is-enabled anj-cloud-firewall.service": (0, "enabled\n", ""),
                               "systemctl is-active anj-cloud-firewall.service": (0, "active\n", ""),
                               "nft list tables": (0, "table ip nat\ntable ip filter\ntable inet anj_cloud\n", "")})

    def test_the_firewall_step_is_reapplied_through_check_and_atomic_reload(self):
        self.installed(self.wanted)
        self.firewall_step()
        self.assertEqual(0, self.converge(), self.out.getvalue())
        self.assertEqual([[5, "Firewall", "changed", True]],
                         [[e["step"], e["name"], e["result"], e["passed"]] for e in self.result["steps"]])
        candidate = str(bootstrap.FIREWALL_FILE) + ".new"
        self.assertEqual([["nft", "-c", "-f", candidate], ["systemctl", "daemon-reload"],
                          ["systemctl", "enable", "anj-cloud-firewall.service"],
                          ["systemctl", "reload", "anj-cloud-firewall.service"]], self.commands())
        self.assertEqual(bootstrap.render_firewall("10.99.0.10", "10.99.0.1"), bootstrap.FIREWALL_FILE.read_text())

    def test_a_live_ssh_source_other_than_the_recorded_one_blocks_the_firewall(self):
        """setup.json says one admin source, the live firewall (changed by hand) another: rewriting
        it for the recorded one would drop every new SSH login from the real admin address."""
        self.installed(self.wanted)
        self.firewall_step(live_source="10.99.0.2")
        before = bootstrap.FIREWALL_FILE.read_text()
        self.assertEqual(1, self.converge())
        self.assertEqual("blocked", self.result["result"])
        [blocked] = self.result["blocked"]
        self.assertEqual(5, blocked["step"])
        self.assertIn("the live firewall accepts SSH from 10.99.0.2 but setup.json records 10.99.0.1", blocked["why"])
        self.assertEqual(before, bootstrap.FIREWALL_FILE.read_text())
        self.assertEqual([], self.commands())

    def test_the_lockout_guard_of_the_answers_path_blocks_the_firewall(self):
        self.installed(self.wanted)
        self.firewall_step()
        self.facts_values = {"ssh_client": "10.99.0.77"}           # this session comes from another address
        self.assertEqual(1, self.converge())
        [blocked] = self.result["blocked"]
        self.assertEqual(5, blocked["step"])
        self.assertIn("You are connected over SSH from 10.99.0.77", blocked["why"])
        self.assertEqual([], self.commands())
        self.facts_values = {"ssh_client": "10.99.0.1"}            # from the recorded source: applied
        self.steps = None
        self.assertEqual(0, self.converge(), self.out.getvalue())

    def test_answers_prefer_the_record_and_fall_back_to_the_live_rule_never_a_commented_one(self):
        bootstrap.FIREWALL_FILE.parent.mkdir(parents=True, exist_ok=True)
        rendered = bootstrap.render_firewall("10.99.0.10", "10.99.0.3")
        bootstrap.FIREWALL_FILE.write_text(rendered)
        self.installed(self.wanted)
        setup = bootstrap.Setup(bootstrap.parser().parse_args(["converge"]), system=FakeSystem(),
                                facts=FakeFacts(FakeSystem()), out=io.StringIO())
        self.assertEqual("10.99.0.1", bootstrap.converge_answers(setup)["admin_ssh_source"])     # recorded wins
        record = json.loads(bootstrap.SETUP_RECORD.read_text())
        del record["answers"]["admin_ssh_source"]
        bootstrap.SETUP_RECORD.write_text(json.dumps(record))
        self.assertEqual("10.99.0.3", bootstrap.converge_answers(setup)["admin_ssh_source"])     # the live rule
        commented = rendered.replace("\t\tip saddr 10.99.0.3 tcp dport 22 accept",
                                     "\t\t# ip saddr 10.99.0.3 tcp dport 22 accept")
        self.assertNotEqual(rendered, commented)
        bootstrap.FIREWALL_FILE.write_text(commented)
        self.assertIsNone(bootstrap.firewall_admin_source())
        with self.assertRaisesRegex(bootstrap.SetupError, "does not record admin_ssh_source"):
            bootstrap.converge_answers(setup)
        bootstrap.FIREWALL_FILE.write_text(commented.replace("ip daddr 10.99.0.10 tcp dport 443",
                                                             "# ip daddr 10.99.0.10 tcp dport 443"))
        self.assertIsNone(bootstrap.firewall_bind_address())

    # B2 and continuation -------------------------------------------------------------------------------
    def test_a_failed_pm2_install_keeps_the_old_tree_and_the_later_steps_still_run(self):
        old = bootstrap.PM2_DIR / "node_modules" / "pm2"
        (old / "bin").mkdir(parents=True)
        (old / "package.json").write_text(json.dumps({"version": "6.0.0"}))
        (bootstrap.PM2_DIR / "package-lock.json").write_text("{}")
        (old / "bin" / "pm2").write_text("old pm2\n")
        self.extra_steps = (("pm2", bootstrap.Pm2),)
        self.failing = {"npm ci": (1, "npm error network request to registry.npmjs.org failed")}
        self.installed(self.old_release_apps())
        self.assertEqual(1, self.converge())
        self.assertEqual("old pm2\n", (old / "bin" / "pm2").read_text())                    # untouched
        self.assertEqual({"version": "6.0.0"}, json.loads((old / "package.json").read_text()))
        self.assertFalse([entry for entry in self.system.files if "exchanged_with" in entry or "renamed_from" in entry])
        self.assertEqual("failed", self.result["result"])
        self.assertEqual(1, len(self.result["problems"]))
        self.assertIn("Step 2 PM2: `npm ci` failed (exit 1). npm error network", self.result["problems"][0])
        # Step 10, the incident's fix, still ran after the failed step 2.
        self.assertEqual([[2, "failed"], [10, "changed"]], [[e["step"], e["result"]] for e in self.result["steps"]])
        self.assertIn(["pm2", "start", str(bootstrap.OPS_ECOSYSTEM), "--only", paths.DDNS_APP], self.commands())
        text = self.out.getvalue()
        self.assertIn("Step 2 (PM2) failed: `npm ci` failed", text)
        self.assertIn("1 setup step(s) could not be re-applied: step 2 PM2 (re-applied: step 10 Operations apps)", text)
        self.assertEqual([], self.doctor_calls)
        self.assertTrue(self.result["evidence"].endswith("-converge.json"))

    def test_an_operations_app_that_will_not_start_gets_its_previous_definition_back(self):
        self.installed(self.old_release_apps())
        new_start = f"pm2 start {bootstrap.OPS_ECOSYSTEM} --only {paths.DDNS_APP}"
        self.failing = {new_start: (1, "[PM2][ERROR] Script not found")}
        self.assertEqual(1, self.converge())
        self.assertEqual([["pm2", "delete", paths.DDNS_APP],
                          ["pm2", "start", str(bootstrap.OPS_ECOSYSTEM), "--only", paths.DDNS_APP],
                          ["pm2", "start", str(bootstrap.OPS_ECOSYSTEM_PREVIOUS), "--only", paths.DDNS_APP],
                          ["pm2", "save"]], self.commands())
        self.assertIn("PM2 could not start ddns from the new definition (exit 1) [PM2][ERROR] Script not found; its "
                      "previous definition runs again.", self.result["problems"][0])
        old = next(app for app in self.old_release_apps() if app["name"] == paths.DDNS_APP)
        record = json.loads(bootstrap.SETUP_RECORD.read_text())
        self.assertEqual(bootstrap.app_digest(old), record["ops_apps"][paths.DDNS_APP])      # still the old one
        self.assertIn('"args": "run"', bootstrap.OPS_ECOSYSTEM_PREVIOUS.read_text())

    def test_delete_and_start_run_with_hang_up_held_off(self):
        self.installed(self.old_release_apps())
        seen = []
        original = ScriptedSystem.change

        def change(system, argv, **options):
            if argv[:2] in (["pm2", "delete"], ["pm2", "start"]):
                seen.append((argv[1], bootstrap.signal.getsignal(bootstrap.signal.SIGHUP)))
            return original(system, argv, **options)
        with mock.patch.object(ScriptedSystem, "change", change):
            self.assertEqual(0, self.converge(), self.out.getvalue())
        self.assertEqual([("delete", bootstrap.signal.SIG_IGN), ("start", bootstrap.signal.SIG_IGN)], seen)
        self.assertNotEqual(bootstrap.signal.SIG_IGN, bootstrap.signal.getsignal(bootstrap.signal.SIGHUP))
        self.assertFalse(bootstrap.OPS_ECOSYSTEM_PREVIOUS.exists())

    # The lock and the evidence ---------------------------------------------------------------------------
    def test_converge_takes_the_setup_lock(self):
        import fcntl
        self.installed(self.old_release_apps())
        bootstrap.UPGRADE_LOCK.parent.mkdir(parents=True, exist_ok=True)
        with open(bootstrap.UPGRADE_LOCK, "w") as held:
            fcntl.flock(held, fcntl.LOCK_EX)
            self.assertEqual(1, self.converge())
            self.assertIn("Another upgrade, rollback, converge or setup run is in progress", self.out.getvalue())
            self.assertEqual([], self.commands())
            # A descriptor of another open of the lock file is not the holder's.
            with open(bootstrap.UPGRADE_LOCK) as other:
                self.assertEqual(1, self.converge("--lock-fd", str(other.fileno())))
            self.assertIn("--lock-fd is not the upgrade lock held for this run", self.out.getvalue())
            # The holder's own descriptor (what upgrade hands down) is.
            self.assertEqual(0, self.converge("--lock-fd", str(held.fileno())), self.out.getvalue())
        self.assertTrue(self.result["evidence"].endswith("-converge.json"))

    def test_setup_lock_excludes_a_setup_rerun(self):
        with bootstrap.setup_lock():
            with self.assertRaisesRegex(bootstrap.SetupError, "Another upgrade, rollback, converge or setup run"):
                bootstrap.setup_lock()
        with bootstrap.setup_lock():
            pass

    def test_arguments(self):
        for argv in (["converge", "--dry-run"], ["converge", "--answers", "/dev/null"], ["converge", "--rollback"]):
            with self.subTest(argv=argv), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                bootstrap.main(argv, system=FakeSystem(), out=io.StringIO())


class ReapplyPolicyTests(unittest.TestCase):
    def test_only_steps_that_restart_no_core_service_are_reapplied(self):
        system = FakeSystem(dry=True)
        setup = bootstrap.Setup(bootstrap.parser().parse_args([]), system=system, facts=FakeFacts(system),
                                out=io.StringIO())
        policy = {step.name: step.reapply_refusal("to do: ecosystem") is None for step in setup.step_list()}
        self.assertEqual({"Packages": False, "PM2": True, "Data disk": False, "Docker": False, "Firewall": True,
                          "Journald": True, "SSH (read-only)": False, "Release": False, "Stack": False,
                          "Operations apps": True, "Timers": True, "Updates": True}, policy)
        self.assertIsNotNone(bootstrap.Operations(setup).reapply_refusal("to do: DNS token, ecosystem"))


class SemanticDriftTests(unittest.TestCase):
    """A reworded comment or a relicensed root package is not drift; a rule or a pin is."""

    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.system = FakeSystem(dry=True, responses={"nft list table inet anj_cloud": (0, "", ""),
                                                      "systemctl is-enabled": (0, "enabled\n", ""),
                                                      "python3 -I -c": (0, "", "")})
        self.setup = bootstrap.Setup(bootstrap.parser().parse_args([]), system=self.system,
                                     facts=FakeFacts(self.system), out=io.StringIO())
        self.setup.answers = {"bind_address": "10.99.0.10", "admin_ssh_source": "10.99.0.1"}

    def test_a_firewall_file_that_differs_only_in_a_comment_is_done(self):
        step = bootstrap.Firewall(self.setup)
        wanted = step.text()
        units = self.root / "systemd"
        units.mkdir()
        (units / "anj-cloud-firewall.service").write_text(step.unit())
        installed = self.root / "firewall.nft"
        with mock.patch.multiple(bootstrap, FIREWALL_FILE=installed, SYSTEMD_DIR=units):
            first_comment = next(line for line in wanted.splitlines() if line.startswith("#"))
            installed.write_text(wanted.replace(first_comment, "# an older wording of the header", 1))
            self.assertTrue(step.state()[0])
            installed.write_text(wanted.replace("tcp dport 443", "tcp dport 8443", 1))
            self.assertEqual((False, "not installed or different"), step.state())
            installed.unlink()
            self.assertFalse(step.state()[0])

    def test_a_lockfile_that_differs_only_in_license_is_done(self):
        step = bootstrap.Pm2(self.setup)
        source = json.loads((bootstrap.SOURCE_DIR / "pm2" / "package-lock.json").read_text())
        pm2_dir = self.root / "opt-pm2"
        (pm2_dir / "node_modules" / "pm2" / "bin").mkdir(parents=True)
        (pm2_dir / "node_modules" / "pm2" / "package.json").write_text(json.dumps({"version": step.pin()}))
        link = self.root / "pm2"
        link.symlink_to(pm2_dir / "node_modules" / "pm2" / "bin" / "pm2")
        relicensed = copy.deepcopy(source)
        relicensed["packages"][""]["license"] = "UNLICENSED"
        with mock.patch.multiple(bootstrap, PM2_DIR=pm2_dir, PM2_LINK=link):
            (pm2_dir / "package-lock.json").write_text(json.dumps(relicensed, indent=2))
            self.assertTrue(step.state()[0], step.state())
            moved = copy.deepcopy(source)
            name = next(key for key in moved["packages"] if key)
            moved["packages"][name]["integrity"] = "sha512-" + "A" * 86 + "=="
            (pm2_dir / "package-lock.json").write_text(json.dumps(moved))
            self.assertFalse(step.state()[0])
            (pm2_dir / "package-lock.json").write_text("{not json")
            self.assertFalse(step.state()[0])
        self.assertIsNone(bootstrap.lock_pins(None))
        self.assertEqual(bootstrap.nft_rules("table x {}\n# c\n"), bootstrap.nft_rules("table x {}\n  # other\n"))


if __name__ == "__main__":
    unittest.main()
