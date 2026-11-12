"""Spec #21 (B2) merge rows on the VM host: preflight fixes and script safety of anj-cloud-setup.

Offline: the machine is FakeFacts (a fresh Debian 13 VM like anj-qual) and FakeSystem, which never
runs a changing command. Real Debian, Docker, PM2 and disks are the VM rows on anj-qual.
"""

import ast
import io
import json
import os
from pathlib import Path
import pwd
import re
import shutil
import socket
import subprocess
import tarfile
import tempfile
import unittest
from unittest import mock

from deploy.vm import bootstrap, paths
from tests.vm_bootstrap_fakes import FakeFacts, FakeSystem, git_archive, write_answers

ROOT = Path(__file__).resolve().parent.parent
QUAL = ROOT / "deploy" / "vm" / "answers" / "qual.toml"


def run_main(argv, facts_overrides=None, responses=None, dry=True, reachable=True, dns=True):
    out = io.StringIO()
    system = FakeSystem(dry=dry, responses=responses or {}, out=out)
    facts = FakeFacts(system, **(facts_overrides or {}))
    resolver = (lambda *a, **k: [()]) if dns else mock.Mock(side_effect=socket.gaierror("no dns"))
    with mock.patch.object(bootstrap, "https_reachable", lambda host, timeout=10: reachable), \
            mock.patch.object(bootstrap.socket, "getaddrinfo", resolver):
        code = bootstrap.main(argv, system=system, facts=facts, prompter=None, out=out)
    return code, out.getvalue(), system


class Answers(unittest.TestCase):
    def setUp(self):
        self.temp = Path(tempfile.mkdtemp(prefix="anj-b2-answers-"))
        self.addCleanup(shutil.rmtree, self.temp, True)

    def test_qualification_answers_file_is_valid_and_keeps_ddns_off(self):
        answers = bootstrap.validate_answers(bootstrap.load_answers(QUAL))
        self.assertEqual(answers["ddns"], "off")
        self.assertTrue(answers["token_file"].startswith("/var/lib/anj-cloud-setup/"))
        self.assertTrue(answers["data_disk_init"])

    def test_production_example_writes_ddns_on_explicitly(self):
        answers = bootstrap.load_answers(ROOT / "deploy" / "vm" / "answers" / "prod.example.toml")
        self.assertEqual(answers["ddns"], "on")
        self.assertTrue(answers["data_disk_init"])
        bootstrap.validate_answers(answers)

    def test_inline_secrets_and_unknown_keys_are_refused_by_name(self):
        for text, word in (('token = "abc"', "token"), ('ntfy_topic = "abc"', "ntfy_topic"),
                           ('restic_password = "x"', "restic_password"), ('hostt = "x"', "hostt")):
            with self.assertRaises(bootstrap.SetupError) as raised:
                bootstrap.load_answers(write_answers(self.temp, text + "\n"))
            self.assertIn(word, str(raised.exception))

    def test_invalid_values_name_their_key(self):
        cases = {"host": "Not A Host", "ddns": "maybe", "accounts": ["Sam"], "bind_address": "0.0.0.0",
                 "household_lan": "8.8.8.0/24", "timezone": "not a zone", "data_disk_init": "yes",
                 "token_file": "relative/path", "ntfy_server": "http://example.com", "zone_id": "xyz"}
        for key, value in cases.items():
            with self.assertRaises(bootstrap.SetupError) as raised:
                bootstrap.validate_answers({key: value})
            self.assertIn(key, str(raised.exception), key)

    def test_flags_override_the_answers_file(self):
        tar, _commit = git_archive(self.temp)
        answers = write_answers(self.temp, 'ddns = "off"\nhost = "a.example.org"\ndata_disk_init = true\n')
        code, out, _ = run_main(["--dry-run", "--answers", str(answers), "--host", "b.example.org", "--source", str(tar)])
        self.assertEqual(code, 0, out)
        self.assertIn("prod.py setup --host b.example.org", out)


class Preflight(unittest.TestCase):
    """Each preflight failure prints its plain-language fix and changes nothing (spec #21 row)."""

    def preflight(self, mode="install", answers=None, existing=False, reachable=True, **overrides):
        facts = FakeFacts(FakeSystem(), **overrides)
        with mock.patch.object(bootstrap.socket, "getaddrinfo", lambda *a, **k: [()]):
            return bootstrap.preflight(facts, answers or {"ddns": "off"}, mode=mode, root=True,
                                       reachable=lambda host: reachable, existing_install=existing)

    def only(self, failures, name):
        self.assertEqual([f[0] for f in failures], [name], failures)
        _name, problem, fix = failures[0]
        self.assertTrue(problem and fix)
        return problem, fix

    def test_a_fresh_debian_13_vm_passes(self):
        self.assertEqual(self.preflight(), [])

    def test_wrong_os(self):
        problem, fix = self.only(self.preflight(os={"ID": "arch", "PRETTY_NAME": "Arch Linux"}), "os")
        self.assertIn("Arch Linux", problem)
        self.assertIn("Debian 13", fix)

    def test_low_ram(self):
        problem, fix = self.only(self.preflight(memory=2 * 1024 * 1024), "memory")
        self.assertIn("2.0 GiB", problem)
        self.assertIn("4 GiB", fix)

    def test_port_443_taken_names_the_process_and_the_command(self):
        problem, fix = self.only(self.preflight(listeners=["apache2"]), "port-443")
        self.assertEqual(problem, "Port 443 is used by apache2.")
        self.assertEqual(fix, "Stop it with `sudo systemctl disable --now apache2`, then run setup again.")

    def test_our_own_haproxy_on_443_is_not_a_failure(self):
        self.assertEqual(self.preflight(listeners=["haproxy"], haproxy=True), [])

    def test_no_dns(self):
        facts = FakeFacts(FakeSystem())
        with mock.patch.object(bootstrap.socket, "getaddrinfo", mock.Mock(side_effect=socket.gaierror("x"))):
            failures = bootstrap.preflight(facts, {"ddns": "off"}, mode="install", reachable=lambda h: True)
        problem, fix = self.only(failures, "dns")
        self.assertIn("resolv", fix)

    def test_no_outbound_https(self):
        failures = self.preflight(reachable=False)
        self.assertEqual({f[0] for f in failures}, {"https"})
        self.assertIn("ntfy.sh", " ".join(f[1] for f in failures))
        self.assertNotIn("api.cloudflare.com", " ".join(f[1] for f in failures))   # DDNS off
        failures = self.preflight(reachable=False, answers={"ddns": "on"})
        self.assertIn("api.cloudflare.com", " ".join(f[1] for f in failures))

    def test_missing_data_disk(self):
        problem, fix = self.only(self.preflight(disks=[{"path": "/dev/vda", "size": 1, "mounts": ["/"], "children": 1,
                                                        "fstype": None, "label": None, "uuid": None}]), "data-disk")
        self.assertIn("none", problem)
        self.assertIn("data_disk", fix)

    def test_two_spare_disks_need_a_choice(self):
        disks = FakeFacts(FakeSystem()).values["disks"] + [{"path": "/dev/vdc", "size": 1, "mounts": [], "children": 0,
                                                            "fstype": None, "label": None, "uuid": None}]
        self.only(self.preflight(disks=disks), "data-disk")
        self.assertEqual(self.preflight(disks=disks, answers={"ddns": "off", "data_disk": "/dev/vdb"},
                                        signatures={"/dev/vdb": []}), [])

    def test_a_disk_with_any_signature_is_never_proposed_for_formatting(self):
        for signature in (["ext4"], ["gpt"], ["non-zero data"], ["unreadable data (run as root)"]):
            problem, fix = self.only(self.preflight(signatures={"/dev/vdb": signature}), "data-disk")
            self.assertIn("never formats", problem)
            self.assertIn("wipefs", fix)

    def test_existing_anj_data_needs_adopt_and_adopt_needs_it(self):
        disks = FakeFacts(FakeSystem()).values["disks"]
        disks[1] = dict(disks[1], fstype="ext4", label="ANJ_DATA")
        problem, fix = self.only(self.preflight(disks=disks), "data-disk")
        self.assertIn("--adopt-data", fix)
        self.assertEqual(self.preflight(mode="adopt", disks=disks), [])
        problem, fix = self.only(self.preflight(mode="adopt"), "data-disk")
        self.assertIn("blank", problem)

    def test_a_mounted_state_of_another_install_needs_adopt(self):
        mounted = {str(paths.DATA_ROOT): {"source": "/dev/vdb", "label": "ANJ_DATA", "uuid": "u"}}
        problem, fix = self.only(self.preflight(mounted=mounted), "data-disk")
        self.assertIn("--adopt-data", fix)
        self.assertEqual(self.preflight(mounted=mounted, existing=True), [])

    def test_small_machine_and_other_docker_ports_and_time(self):
        failures = self.preflight(cpus=1, free=2 << 30, synced=False, published=["web-1"], arch="arm64")
        self.assertEqual({f[0] for f in failures}, {"cpus", "os-disk", "time", "docker-ports", "architecture"})
        for _name, problem, fix in failures:
            self.assertTrue(problem.endswith(".") and fix)

    def test_preflight_failure_through_main_changes_nothing_and_exits_1(self):
        temp = Path(tempfile.mkdtemp(prefix="anj-b2-pre-"))
        self.addCleanup(shutil.rmtree, temp, True)
        answers = write_answers(temp, 'ddns = "off"\n')
        with mock.patch.object(bootstrap.os, "geteuid", lambda: 0), \
                mock.patch.object(bootstrap.Setup, "write_evidence", lambda self, *a, **k: None):
            code, out, system = run_main(["--answers", str(answers)], {"listeners": ["apache2"], "memory": 1 << 20},
                                         dry=False)
        self.assertEqual(code, 1)
        self.assertIn("Preflight found problems; nothing was changed", out)
        self.assertIn("Fix: Stop it with `sudo systemctl disable --now apache2`", out)
        self.assertEqual((system.executed, system.files), ([], []))


class DryRun(unittest.TestCase):
    def setUp(self):
        self.temp = Path(tempfile.mkdtemp(prefix="anj-b2-dry-"))
        self.addCleanup(shutil.rmtree, self.temp, True)
        self.tar, self.commit = git_archive(self.temp)

    def test_dry_run_plans_every_step_changes_nothing_and_asks_no_secret(self):
        token = self.temp / "token"
        token.write_text("not-a-real-token-but-secret-shaped-0123456789\n")
        answers = write_answers(self.temp, f'ddns = "on"\ntoken_file = "{token}"\n')
        prompter = mock.Mock()
        out = io.StringIO()
        system = FakeSystem(dry=True, out=out)
        with mock.patch.object(bootstrap, "https_reachable", lambda host, timeout=10: True), \
                mock.patch.object(bootstrap.socket, "getaddrinfo", lambda *a, **k: [()]), \
                mock.patch.object(bootstrap, "read_secret_file", mock.Mock(side_effect=AssertionError("secret read"))):
            code = bootstrap.main(["--dry-run", "--answers", str(answers), "--source", str(self.tar)], system=system,
                                  facts=FakeFacts(system), prompter=prompter, out=out)
        text = out.getvalue()
        self.assertEqual(code, 0, text)
        self.assertEqual(system.executed, [])
        prompter.hidden.assert_not_called()
        for number in range(1, 13):
            self.assertRegex(text, rf"(?m)^\s*{number} \S")
        self.assertIn("mkfs.ext4 -L ANJ_DATA /dev/vdb (blank disk; asks for confirmation first)", text)
        self.assertIn(f"release {self.commit[:12]}", text)
        self.assertIn("443 to 10.77.11.10, 22 from 10.77.11.1", text)
        self.assertIn("anj-cloud-backup.timer", text)        # spec #22's units are installed by the bootstrap
        self.assertIn("ddns", text)
        self.assertNotIn("not-a-real-token", text)

    def test_dry_run_never_proposes_formatting_a_disk_with_data(self):
        answers = write_answers(self.temp, 'ddns = "off"\n')
        code, out, system = run_main(["--dry-run", "--answers", str(answers), "--source", str(self.tar)],
                                     {"signatures": {"/dev/vdb": ["xfs"]}})
        self.assertEqual(code, 1)
        self.assertIn("refuse: /dev/vdb holds xfs", out)
        self.assertNotIn("mkfs", out)
        self.assertEqual(system.executed, [])


class ReleaseApply(unittest.TestCase):
    def test_local_source_install_records_release_as_the_setup_user(self):
        temp = Path(tempfile.mkdtemp(prefix="anj-b2-release-"))
        self.addCleanup(shutil.rmtree, temp, True)
        system = FakeSystem(dry=False)
        setup = mock.Mock()
        setup.system = system
        setup.facts = FakeFacts(system)
        setup.user = setup.facts.user()
        setup.release = "a" * 40
        setup.release_tar = None
        setup.checkout = None
        with mock.patch.object(bootstrap, "install_release_source"), \
                mock.patch.object(bootstrap.paths, "STACK_CONFIG", temp / "stack.json"), \
                mock.patch.object(system, "write", wraps=system.write) as write:
            bootstrap.Release(setup).apply()
        write.assert_called_once()
        self.assertIs(write.call_args.kwargs["owner"], setup.user)
        self.assertEqual(json.loads((temp / "stack.json").read_text()), {"release": setup.release})


class Pm2Permissions(unittest.TestCase):
    """Real subprocess/file permissions with an offline npm fixture; no PM2 daemon."""

    def setUp(self):
        self.temp = Path(tempfile.mkdtemp(prefix="anj-pm2-permissions-"))
        self.addCleanup(shutil.rmtree, self.temp, True)
        self.directory = self.temp / "opt" / "pm2"
        self.bin = self.temp / "bin"
        self.bin.mkdir()
        self.link = self.bin / "pm2"
        npm = self.bin / "npm"
        npm.write_text("#!/usr/bin/python3\n"
                       "import json,os,pathlib,shutil\n"
                       "p=pathlib.Path\n"
                       "count=p('install-count')\n"
                       "count.write_text(str(int(count.read_text())+1) if count.exists() else '1')\n"
                       # Simulate root npm replacing its private dependency tree in this unprivileged test.
                       "dep=p('node_modules/dependency')\n"
                       "if dep.exists(): dep.chmod(0o755)\n"
                       # npm ci removes installed packages but retains node_modules and its mode.
                       "p('node_modules').mkdir(exist_ok=True)\n"
                       "for child in p('node_modules').iterdir():\n"
                       " if child.is_dir(): shutil.rmtree(child)\n"
                       " else: child.unlink()\n"
                       "p('node_modules/pm2/bin').mkdir(parents=True)\n"
                       "p('node_modules/dependency').mkdir()\n"
                       "p('node_modules/dependency/index.js').write_text('module.exports = {};')\n"
                       "pin=json.loads(p('package.json').read_text())['dependencies']['pm2']\n"
                       "p('node_modules/pm2/package.json').write_text(json.dumps({'version':pin}))\n"
                       # Loadable, as the post-install check requires (no daemon: nothing runs).
                       "p('node_modules/pm2/index.js').write_text('module.exports = {};')\n"
                       "binary=p('node_modules/pm2/bin/pm2')\n"
                       "binary.write_text('#!/bin/sh\\ntouch '+str(p('daemon-started').absolute())+'\\n')\n"
                       "binary.chmod(0o755)\n")
        npm.chmod(0o755)
        self.enterContext(mock.patch.dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ["PATH"]))
        self.enterContext(mock.patch.object(bootstrap, "PM2_DIR", self.directory))
        self.enterContext(mock.patch.object(bootstrap, "PM2_LINK", self.link))
        self.system = bootstrap.System(out=io.StringIO())
        self.setup = mock.Mock(system=self.system, facts=mock.Mock(), user=pwd.getpwuid(os.getuid()).pw_name, steps=[])
        self.step = bootstrap.Pm2(self.setup)

    def test_restrictive_parent_umask_does_not_make_pm2_private_or_change_parent(self):
        previous = os.umask(0o077)
        try:
            self.step.apply()
            with mock.patch.object(self.system, "read", wraps=self.system.read) as read:
                self.assertTrue(self.step.verify()[0])
                self.assertTrue(any(call.kwargs.get("user") == self.setup.user for call in read.call_args_list))
            parent_file = self.temp / "still-private"
            parent_file.write_text("private fixture")
            self.assertEqual(parent_file.stat().st_mode & 0o777, 0o600)
        finally:
            os.umask(previous)
        self.assertEqual((self.directory / "node_modules").stat().st_mode & 0o777, 0o755)
        self.assertEqual((self.directory / "node_modules/dependency/index.js").stat().st_mode & 0o777, 0o644)
        self.assertFalse((self.directory / "daemon-started").exists())

    def test_reinstall_repairs_existing_private_node_modules_directory(self):
        self.step.apply()
        modules = self.directory / "node_modules"
        modules.chmod(0o700)
        previous = os.umask(0o077)
        try:
            self.step.apply()
            private_file = self.temp / "still-private-after-repair"
            private_file.write_text("private fixture")
        finally:
            os.umask(previous)
        self.assertEqual(modules.stat().st_mode & 0o777, 0o755)
        self.assertEqual((modules / "dependency/index.js").stat().st_mode & 0o777, 0o644)
        self.assertEqual(private_file.stat().st_mode & 0o777, 0o600)
        # SC-110: every install is a fresh tree swapped in whole, so each counts once.
        self.assertEqual((self.directory / "install-count").read_text(), "1")
        self.assertFalse(self.directory.with_name("pm2.new").exists())
        self.assertTrue(self.step.verify()[0])
        self.assertFalse((self.directory / "daemon-started").exists())

    @unittest.skipIf(os.geteuid() == 0, "permission denial fixture requires an unprivileged test runner")
    def test_rerun_repairs_inaccessible_dependencies_then_is_idempotent(self):
        self.step.apply()
        dependency = self.directory / "node_modules/dependency"
        dependency.chmod(0o000)
        self.addCleanup(dependency.chmod, 0o755)
        # After the swap the unreadable tree is the previous one (pm2.new), which a non-root runner cannot remove.
        previous = self.directory.with_name("pm2.new") / "node_modules" / "dependency"
        self.addCleanup(lambda: previous.chmod(0o755) if previous.exists() else None)
        self.assertFalse(self.step.state()[0])
        self.assertFalse(self.step.verify()[0])
        bootstrap.Setup.execute(self.setup, self.step, 2, 12)
        self.assertEqual(self.setup.steps[-1]["result"], "changed")
        self.assertTrue(self.step.verify()[0])
        bootstrap.Setup.execute(self.setup, self.step, 2, 12)
        self.assertEqual(self.setup.steps[-1]["result"], "already done")
        self.assertEqual((self.directory / "install-count").read_text(), "1")   # the one fresh install
        self.assertFalse((self.directory / "daemon-started").exists())

    def test_a_failed_or_unloadable_install_leaves_the_installed_pm2_untouched(self):
        """SC-110: npm ci empties node_modules first, so it runs in a staging tree; only a complete,
        loadable install of the pin is swapped in."""
        self.step.apply()
        before = sorted(str(path.relative_to(self.directory)) for path in self.directory.rglob("*"))
        npm = self.bin / "npm"
        working = npm.read_text()
        npm.write_text("#!/usr/bin/python3\nimport pathlib,shutil,sys\nshutil.rmtree('node_modules')\n"
                       "print('npm error network', file=sys.stderr)\nsys.exit(1)\n")
        with self.assertRaisesRegex(bootstrap.SetupError, "npm ci` failed"):
            self.step.apply()
        npm.write_text(working.replace("index.js').write_text('module.exports = {};')",
                                       "index.js').write_text('throw new Error(\"broken\")')"))
        with self.assertRaisesRegex(bootstrap.SetupError, "does not load as pin"):
            self.step.apply()
        self.assertEqual(before, sorted(str(path.relative_to(self.directory)) for path in self.directory.rglob("*")))
        self.assertEqual("1", (self.directory / "install-count").read_text())
        self.assertTrue(self.step.verify()[0])

    def test_dry_run_never_installs_pm2(self):
        self.system.dry = True
        self.step.apply()
        self.assertFalse(self.directory.exists())
        self.assertFalse(self.link.exists())


class DiskRule(unittest.TestCase):
    def setup(self, answers, **overrides):
        args = bootstrap.parser().parse_args(["--answers", "/dev/null"])
        system = FakeSystem(dry=False)
        setup = bootstrap.Setup(args, system=system, facts=FakeFacts(system, **overrides), out=io.StringIO())
        setup.answers = answers
        return setup, system

    def test_blank_disk_needs_the_explicit_answer(self):
        setup, _ = self.setup({"ddns": "off"})
        with self.assertRaises(bootstrap.SetupError) as raised:
            setup.confirm_disk_init(False, "/dev/vdb")
        self.assertIn("data_disk_init", str(raised.exception))
        setup.answers["data_disk_init"] = True
        self.assertTrue(setup.confirm_disk_init(False, "/dev/vdb"))

    def test_format_is_rechecked_and_refused_when_the_disk_changed(self):
        setup, system = self.setup({"ddns": "off"})
        step = bootstrap.DataDisk(setup)
        calls = iter([[], ["ext4"]])        # blank when chosen, holds data right before mkfs
        setup.facts.signatures = lambda device: next(calls)
        with self.assertRaises(bootstrap.SetupError):
            step.apply()
        self.assertFalse([argv for argv in system.executed if argv[0].startswith("mkfs")])

    def test_foreign_disk_apply_refuses(self):
        setup, system = self.setup({"ddns": "off"}, signatures={"/dev/vdb": ["LVM2_member"]})
        with self.assertRaises(bootstrap.SetupError):
            bootstrap.DataDisk(setup).apply()
        self.assertEqual(system.executed, [])


class ScriptSafety(unittest.TestCase):
    SOURCES = [ROOT / "deploy" / "vm" / "bootstrap.py", ROOT / "deploy" / "vm" / "stage.py"] + \
              [path for path in (ROOT / "deploy" / "vm" / "ops").iterdir() if path.is_file() and path.suffix in ("", ".py")]

    def test_no_shell_and_no_ruleset_flush(self):
        for path in self.SOURCES:
            text = path.read_text()
            self.assertNotIn("shell=True", text, path)
            self.assertNotRegex(text, r'"flush",\s*"ruleset"|nft flush', path)
        firewall = (ROOT / "deploy" / "vm" / "config" / "firewall.nft.tmpl").read_text()
        self.assertNotRegex("\n".join(l for l in firewall.splitlines() if not l.lstrip().startswith("#")), "flush")

    def test_mkfs_appears_only_in_the_guarded_data_disk_step(self):
        tree = ast.parse((ROOT / "deploy" / "vm" / "bootstrap.py").read_text())
        owners = []
        for cls in [node for node in ast.walk(tree) if isinstance(node, ast.ClassDef)]:
            for node in ast.walk(cls):
                if isinstance(node, ast.Constant) and node.value == "mkfs.ext4" and isinstance(node, ast.Constant):
                    owners.append(cls.name)
        self.assertEqual(set(owners), {"DataDisk"})
        source = (ROOT / "deploy" / "vm" / "bootstrap.py").read_text()
        guard = source.index('if classify_disk(self.facts, device)[0] != "blank":')
        self.assertLess(guard, source.index('self.system.change(["mkfs.ext4"'))

    def test_every_changing_command_goes_through_system_change(self):
        tree = ast.parse((ROOT / "deploy" / "vm" / "bootstrap.py").read_text())
        direct = []
        for node in ast.walk(tree):
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr in ("run", "Popen") \
                    and isinstance(node.func.value, ast.Name) and node.func.value.id == "subprocess":
                direct.append(node.lineno)
        # System.read (the one executor), System.attended (the terminal-attended one, backup.py's
        # escrow), System.detached (upgrade's redeploy and converge in their own session, decision
        # #122, flag SC-110), resolve_source's `git rev-parse` and Release's `git archive`.
        self.assertEqual(len(direct), 5, direct)

    def test_firewall_render(self):
        text = bootstrap.render_firewall("10.77.10.10", "10.77.10.1")
        self.assertIn("type filter hook input priority filter; policy drop;", text)
        self.assertIn("ip daddr 10.77.10.10 tcp dport 443 accept", text)
        self.assertIn("ip saddr 10.77.10.1 tcp dport 22 accept", text)
        self.assertIn("table inet anj_cloud {}\ndelete table inet anj_cloud\n", text)
        inbound, _, forward = text.partition("\tchain forward {")
        self.assertEqual(len(re.findall(r"dport", inbound)), 4)    # 68, 546, 443, 22: nothing else is opened
        # The media fetch worker's bridge (spec #42): nothing to the VM, nothing private but DNS forwarded.
        self.assertIn('iif "lo" accept\n\t\tiifname "anj-fetch" drop', inbound)
        self.assertIn('iifname "anj-fetch" ip daddr { 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8', forward)
        self.assertEqual(1, len(re.findall(r"dport", forward)))
        with self.assertRaises(ValueError):
            bootstrap.render_firewall("10.77.10.10; flush ruleset", "10.77.10.1")
        if shutil.which("nft"):
            path = Path(tempfile.mkdtemp(prefix="anj-b2-nft-")) / "f.nft"
            self.addCleanup(shutil.rmtree, path.parent, True)
            path.write_text(text)
            check = subprocess.run(["nft", "-c", "-f", str(path)], capture_output=True, text=True, timeout=30)
            if "Operation not permitted" not in check.stderr:
                self.assertEqual(check.returncode, 0, check.stderr)

    def test_units_render_and_verify(self):
        units = bootstrap.rendered_units("/home/anj", json.loads(subprocess.run(
            ["python3", "-I", str(ROOT / "deploy" / "backup.py"), "units", "--source", str(paths.RELEASE_CURRENT)],
            capture_output=True, text=True, check=True).stdout)["units"])
        self.assertEqual(set(bootstrap.ENABLED_UNITS) - set(units), set())
        for name, text in units.items():
            self.assertNotIn("@", text.replace("pm2-anj", ""), name)   # every placeholder filled
        self.assertIn("User=anj", units["anj-cloud-boot-health.service"])
        self.assertIn("After=pm2-anj.service", units["anj-cloud-boot-health.service"])
        self.assertNotIn("User=", units["anj-cloud-reboot-guard.service"])  # root: it reboots
        dropins = bootstrap.rendered_dropins("/home/anj")
        self.assertIn("pm2-anj.service.d/zz-anj-cloud.conf", dropins)
        self.assertIn("RequiresMountsFor=/srv/anj-cloud", dropins["docker.service.d/zz-anj-cloud.conf"])
        if shutil.which("systemd-analyze"):
            directory = Path(tempfile.mkdtemp(prefix="anj-b2-units-"))
            self.addCleanup(shutil.rmtree, directory, True)
            for name, text in units.items():
                # The release path exists only in the VM; point ExecStart at this checkout to verify syntax.
                (directory / name).write_text(text.replace(str(paths.RELEASE_CURRENT), str(ROOT)))
            (directory / "anj-cloud-firewall.service").write_text(
                (ROOT / "deploy" / "vm" / "systemd" / "anj-cloud-firewall.service").read_text())
            result = subprocess.run(["systemd-analyze", "verify", "--man=no", *sorted(map(str, directory.iterdir()))],
                                    capture_output=True, text=True, timeout=120)
            self.assertEqual((result.returncode, result.stderr.strip()), (0, ""))

    def test_ops_ecosystem(self):
        apps = bootstrap.ops_apps(paths.STATE_ROOT, paths.RELEASE_CURRENT)
        self.assertEqual([app["name"] for app in apps], ["alerts", "watchdog", "watchers", "console"])
        self.assertEqual(apps[0]["script"], str(paths.ALERT_COMMAND))
        self.assertEqual(apps[0]["args"], ["--drain"])
        self.assertEqual([app["name"] for app in bootstrap.ops_apps(paths.STATE_ROOT, paths.RELEASE_CURRENT,
                                                                     start_stack=False)], ["alerts"])
        self.assertTrue(set(paths.OPERATIONS_APPS) | {paths.CONSOLE_APP} == {app["name"] for app in apps})
        # Decision #112 (1): the console backend runs the live release's launcher with the system
        # python (cryptography from python3-cryptography), isolated, defaults only (no arguments).
        console = apps[-1]
        self.assertEqual((str(paths.RELEASE_CURRENT / "deploy" / "vm" / "ops" / "console"), "/usr/bin/python3", "-I"),
                         (console["script"], console["interpreter"], console["interpreter_args"]))
        self.assertNotIn("args", console)
        self.assertTrue(os.access(ROOT / "deploy" / "vm" / "ops" / "console", os.X_OK))
        text = bootstrap.ecosystem_text(apps)
        self.assertTrue(text.startswith("// Generated") and "module.exports = " in text)

    def test_tmpfiles_make_the_three_runtime_directories(self):
        """Decision #112 (1): the console backend's socket directory beside spec #20's two."""
        text = bootstrap.render_template((ROOT / "deploy" / "vm" / "config" / "anj-cloud.tmpfiles").read_text(), "/home/anj")
        entries = [line.split() for line in text.splitlines() if line and not line.startswith("#")]
        self.assertEqual([["d", "/run/anj-cloud-gw", "2750", "10001", "10002", "-"],
                          ["d", "/run/anj-haproxy", "0750", "root", "anj", "-"],
                          ["d", str(paths.CONSOLE_DIR), "2750", paths.VM_USER, str(paths.GATEWAY_GID), "-"]], entries)
        self.assertEqual(oct(paths.CONSOLE_DIR_MODE), "0o2750")
        self.assertNotIn("@", text)

    def test_release_tar_commit(self):
        temp = Path(tempfile.mkdtemp(prefix="anj-b2-tar-"))
        self.addCleanup(shutil.rmtree, temp, True)
        tar, commit = git_archive(temp)
        self.assertEqual(bootstrap.tar_commit(tar), commit)
        plain = temp / "plain.tar"
        with tarfile.open(plain, "w") as archive:
            archive.add(__file__, arcname="x.py")
        with self.assertRaises(bootstrap.SetupError):
            bootstrap.tar_commit(plain)

    def test_docker_versions_and_origins_parsing(self):
        self.assertGreaterEqual(bootstrap.version_tuple("26.1.5+dfsg1-9+deb13u1"), bootstrap.ENGINE_MIN)
        self.assertGreaterEqual(bootstrap.version_tuple("2.26.1-4"), bootstrap.COMPOSE_MIN)
        self.assertLess(bootstrap.version_tuple("20.10.24+dfsg1-1"), bootstrap.ENGINE_MIN)
        self.assertEqual(bootstrap.version_tuple("5:29.9.2-1~debian.13~trixie"), (29, 9, 2))
        text = ("Allowed origins are: ['origin=Debian,codename=trixie-security,label=Debian-Security', "
                "'origin=Debian,codename=trixie,label=Debian-Security']")
        self.assertEqual({label for _o, label in bootstrap.allowed_origins(text)}, {"Debian-Security"})

    def test_debian_13_docker_is_chosen_when_its_versions_fit(self):
        system = FakeSystem()
        setup = bootstrap.Setup(bootstrap.parser().parse_args([]), system=system, out=io.StringIO(),
                                facts=FakeFacts(system, candidate={"docker.io": "26.1.5+dfsg1-9+deb13u1",
                                                                   "docker-compose": "2.26.1-4"}))
        self.assertEqual(bootstrap.Packages(setup).docker_choice(), "debian")
        old = FakeFacts(system, candidate={"docker.io": "20.10.5", "docker-compose": "1.29.2"})
        setup.facts = old
        self.assertEqual(bootstrap.Packages(setup).docker_choice(), "docker-repo")


class Staging(unittest.TestCase):
    """deploy/vm/stage.py: the release reaches a fresh VM before its first bootstrap (The VM host side)."""

    def test_stage_pipes_git_archive_into_the_vm_and_names_the_setup(self):
        from deploy.vm import stage
        pipes = []

        class Runner:
            def pipe(self, producer, consumer, *, timeout=300):
                pipes.append((producer, consumer))
                return True
        with mock.patch.object(stage, "resolve", lambda commit, checkout=None: "a" * 40):
            result = stage.stage(Runner(), "anj-qual")
        producer, consumer = pipes[0]
        self.assertEqual(producer[-3:], ["archive", "--format=tar", "a" * 40])
        self.assertEqual(consumer[:7], ["ssh", "-F", str(stage.SSH_CONFIG), "-T", "-o", "BatchMode=yes", "anj-qual"])
        self.assertIn("tar --no-same-owner -C /var/lib/anj-cloud-setup/src.new -xf /var/lib/anj-cloud-setup/source.tar",
                      consumer[-1])
        self.assertEqual(result, {"commit": "a" * 40, "setup": "/var/lib/anj-cloud-setup/src/deploy/vm/anj-cloud-setup"})
        self.assertEqual(Path(result["setup"]).relative_to(bootstrap.STAGE_SRC).as_posix(), "deploy/vm/anj-cloud-setup")

    def test_a_failed_pipe_is_a_failure_and_the_drill_records_it(self):
        from deploy import backup
        from deploy.vm import stage

        class Runner:
            def pipe(self, producer, consumer, *, timeout=300):
                return False
        with mock.patch.object(stage, "resolve", lambda commit, checkout=None: "a" * 40):
            with self.assertRaises(RuntimeError):
                stage.stage(Runner(), "anj-qual")
            with self.assertRaises(backup.BackupError) as raised:
                backup.stage_bootstrap(Runner(), "anj-qual")
        self.assertEqual(raised.exception.reason, "stage-failed")

    def test_the_staged_tree_is_the_default_source(self):
        temp = Path(tempfile.mkdtemp(prefix="anj-b2-stage-"))
        self.addCleanup(shutil.rmtree, temp, True)
        tar, commit = git_archive(temp)
        with mock.patch.object(bootstrap, "STAGE_TAR", tar), mock.patch.object(bootstrap, "STAGE_SRC", bootstrap.ROOT):
            self.assertEqual(bootstrap.resolve_source(None), (commit, tar, None))
        with self.assertRaises(bootstrap.SetupError) as raised:
            bootstrap.resolve_source(None)            # not running from a staged tree, no --source
        self.assertIn("stage.py", raised.exception.fix)


class QualificationDriver(unittest.TestCase):
    """deploy/vm/qualify.py and qual_client.py offline: rows, defaults, the HAProxy-path client."""

    def test_rows_and_defaults(self):
        from deploy.vm import qualify
        out = io.StringIO()
        with mock.patch("sys.stdout", out):
            self.assertEqual(qualify.main(["--list"]), 0)
        rows = out.getvalue().split()
        self.assertEqual(rows[:4], ["create", "stage", "dry_run", "install"])
        for row in ("firewall", "enrol", "doctor_failures", "updates", "hung_gateway", "watchdog_cap", "reboot",
                    "reboot_failure", "killed_containers", "ddns", "first_admin", "adopt_same_disk", "console"):
            self.assertIn(row, rows)
            self.assertTrue(callable(getattr(qualify.Qualification, "row_" + row)))
        self.assertEqual(qualify.main.__defaults__, (None,))
        self.assertIn('default="HEAD"', (ROOT / "deploy" / "vm" / "qualify.py").read_text())

    def test_client_enrols_over_tls_to_haproxy_and_https_status(self):
        import http.server
        import ssl as ssl_module
        import threading
        from deploy.vm import qual_client, qualify
        if not shutil.which("openssl"):
            self.skipTest("openssl needed")
        temp = Path(tempfile.mkdtemp(prefix="anj-b2-client-"))
        self.addCleanup(shutil.rmtree, temp, True)
        subprocess.run(["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256", "-noenc",
                        "-subj", "/CN=qual.test", "-addext", "subjectAltName=DNS:qual.test", "-days", "1",
                        "-keyout", str(temp / "key"), "-out", str(temp / "crt")], capture_output=True, check=True)
        seen = []

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def answer(self, body):
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                seen.append(("GET", self.path, self.headers.get("Host")))
                self.answer(b"ok")

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                seen.append(("POST", self.path, sorted(body)))
                self.answer(json.dumps({"state": "pending", "pairing_id": "p1", "fingerprint": "f" * 64}).encode())

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        context = ssl_module.SSLContext(ssl_module.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(temp / "crt", temp / "key")
        server.socket = context.wrap_socket(server.socket, server_side=True)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.shutdown)
        port = server.server_address[1]
        with mock.patch.object(qual_client.HaproxyConnection, "connect", lambda conn: setattr(
                conn, "sock", conn.context.wrap_socket(socket.create_connection(("127.0.0.1", port), timeout=10),
                                                       server_hostname=conn.host))):
            result = qual_client.Client("127.0.0.1", "qual.test", temp / "crt", temp).enroll("CODE-1234")
        self.assertEqual((result["enroll"], result["pairing_id"]), (200, "p1"))
        self.assertIn(("POST", "/v1/enroll", ["code", "csr", "label"]), seen)
        self.assertEqual(seen[0][2], "qual.test")
        self.assertNotIn("CODE-1234", json.dumps(result))
        real = socket.create_connection
        with mock.patch.object(qualify.socket, "create_connection",
                               lambda address, timeout=None: real(("127.0.0.1", port), timeout)):
            self.assertEqual(qualify.https_status("10.77.11.10", "qual.test", str(temp / "crt")), 200)


class QualificationAdminClient(unittest.TestCase):
    def test_admin_action_follows_202_operations_with_the_device_certificate(self):
        """SC-041: the console row's client polls like the app's AdminClient."""
        import http.server
        import ssl as ssl_module
        import threading
        from deploy.vm import qual_client
        if not shutil.which("openssl"):
            self.skipTest("openssl needed")
        temp = Path(tempfile.mkdtemp(prefix="anj-console-client-"))
        self.addCleanup(shutil.rmtree, temp, True)
        for name, cn in (("crt", "qual.test"), ("device", "device")):
            subprocess.run(["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256", "-noenc",
                            "-subj", "/CN=" + cn, "-addext", "subjectAltName=DNS:" + cn, "-days", "1",
                            "-keyout", str(temp / (name + ".key")), "-out", str(temp / (name + ".pem"))],
                           capture_output=True, check=True)
        (temp / "device.crt").write_bytes((temp / "device.pem").read_bytes())
        operation, seen, polls = "ab" * 16, [], []

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def answer(self, status, body):
                data = json.dumps(body).encode()
                self.send_response(status)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def do_GET(self):
                seen.append(("GET", self.path, bool(self.connection.getpeercert())))
                polls.append(1)
                if len(polls) < 2:
                    self.answer(202, {"operation": operation, "state": "running"})
                else:
                    self.answer(201, {"uid": "qualslow", "state": "created"})

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                seen.append(("POST", self.path, sorted(body)))
                self.answer(202, {"operation": operation, "state": "running"})

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        context = ssl_module.SSLContext(ssl_module.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(temp / "crt.pem", temp / "crt.key")
        context.verify_mode = ssl_module.CERT_OPTIONAL
        context.load_verify_locations(temp / "device.pem")
        server.socket = context.wrap_socket(server.socket, server_side=True)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        port = server.server_address[1]
        with mock.patch.object(qual_client.HaproxyConnection, "connect", lambda conn: setattr(
                conn, "sock", conn.context.wrap_socket(socket.create_connection(("127.0.0.1", port), timeout=10),
                                                       server_hostname=conn.host))):
            status, reply, exchanges = qual_client.Client("127.0.0.1", "qual.test", temp / "crt.pem", temp).admin_action(
                "POST", "/v1/admin/users", {"uid": "qualslow", "display_name": "Qual Slow"})
        self.assertEqual((201, {"uid": "qualslow", "state": "created"}), (status, reply))
        self.assertEqual([202, 202, 201], [code for code, _seconds in exchanges])
        self.assertEqual([("POST", "/v1/admin/users", ["display_name", "uid"]),
                          ("GET", "/v1/admin/operations/" + operation, True),
                          ("GET", "/v1/admin/operations/" + operation, True)], seen)


class FirstAdminAndEvidence(unittest.TestCase):
    def setUp(self):
        self.temp = Path(tempfile.mkdtemp(prefix="anj-b2-admin-"))
        self.addCleanup(shutil.rmtree, self.temp, True)
        self.record = {}
        args = bootstrap.parser().parse_args(["--answers", "/dev/null"])
        self.system = FakeSystem(dry=False)
        self.setup = bootstrap.Setup(args, system=self.system, facts=FakeFacts(self.system), out=io.StringIO())
        self.setup.answers = {"accounts": ["sam", "alex"], "host": "gateway.example.com", "ddns": "off"}
        self.operations = []
        record = self.record

        def operator(*args, data=None, check=True):
            self.operations.append(args)
            if args[0] == "invite":
                return {"id": "inv-" + str(len(self.operations)), "uid": args[1], "rights": "write",
                        "expires": 1.0, "code": "ABCD-EFGH-IJKL-" + str(len(self.operations))}
            if args[0] == "pending":
                return [{"id": record.get("first_invite", {}).get("id"), "state": "issued"}]
            return {}
        self.setup.operator = operator
        # Restored to the real property (captured before the stub replaces it): a stub left on the
        # class would leak into every later test module.
        self.addCleanup(setattr, bootstrap.Setup, "record", bootstrap.Setup.__dict__["record"])
        type(self.setup).record = property(lambda s: dict(record))
        self.setup.save_record = lambda **changes: record.update(changes)

    def test_first_code_goes_to_a_0600_file_without_a_terminal_never_to_evidence(self):
        self.setup.answers["start_stack"] = True
        self.system.dry = True                             # record the write; /srv does not exist here
        self.setup.pairing_phase(interactive=False)        # --answers, no terminal: issued once, 0600 file
        code = self.setup.first_code
        self.assertTrue(code.startswith("ABCD"))
        self.assertEqual(self.record["first_invite"]["uid"], "sam")
        self.assertNotIn("code", self.record["first_invite"])
        written = [f for f in self.system.files if f["path"] == str(paths.FIRST_PAIRING_CODE)]
        self.assertEqual(written, [{"path": str(paths.FIRST_PAIRING_CODE), "sha256": "secret", "mode": "0o600"}])
        self.assertNotIn(code, self.setup.out.getvalue())
        evidence = self.temp / "evidence.json"
        with mock.patch.object(bootstrap.paths, "STATE_ROOT", self.temp / "absent"), \
                mock.patch.object(bootstrap, "FALLBACK_LOG_DIR", self.temp), \
                mock.patch.object(bootstrap, "utc_stamp", lambda moment=None: "evidence"):
            self.system.dry = False
            self.setup.write_evidence("complete")
        self.assertNotIn(code, evidence.read_text())
        self.assertNotIn(code.replace("-", ""), evidence.read_text())

    def test_an_answers_re_run_never_issues_a_second_code(self):          # decision #104 (5)
        self.setup.answers["start_stack"] = True
        self.system.dry = True
        self.setup.pairing_phase(interactive=False)
        first = self.record["first_invite"]["id"]
        self.setup.pairing_phase(interactive=False)
        self.assertEqual(self.record["first_invite"]["id"], first)
        self.assertEqual([op for op in self.operations if op[0] == "invite"], [("invite", "sam", "--rights", "write")])

    def test_terminal_shows_the_code_once_grouped_with_its_clock_expiry(self):
        self.setup.issue_first_code("sam")

        class Tty(io.StringIO):
            def isatty(self):
                return True
        self.setup.out = Tty()
        self.setup.show_code("sam")
        text = self.setup.out.getvalue()
        grouped = "-".join(self.setup.first_code[i:i + 4] for i in range(0, len(self.setup.first_code), 4))
        self.assertEqual(text.count(grouped), 1)
        self.assertRegex(text, r"Valid until \d\d:\d\d")
        self.assertIn("pair --new-code", text)
        self.assertNotIn(str(paths.FIRST_PAIRING_CODE), text)

    def test_terminal_shows_the_code_as_a_qr_code_too(self):
        """#97 review M3: the app's Scan QR code reads the same code; only on a terminal."""
        self.setup.issue_first_code("sam")
        seen = []

        def qr(value, runner=None):
            seen.append(value)
            return "<qr>\n"

        class Tty(io.StringIO):
            def isatty(self):
                return True
        with mock.patch.object(bootstrap.guide, "qr_text", qr):
            self.setup.out = Tty()
            self.setup.show_code("sam")
            self.assertEqual(seen, [self.setup.first_code])
            self.assertIn("<qr>", self.setup.out.getvalue())
            self.assertIn("Scan QR code", self.setup.out.getvalue())
            seen.clear()
            self.system.dry = True
            self.setup.out = io.StringIO()
            self.setup.show_code("sam")   # no terminal: the 0600 file only
            self.assertEqual(seen, [])
            self.assertNotIn("<qr>", self.setup.out.getvalue())

    @unittest.skipUnless(shutil.which("qrencode") and shutil.which("zbarimg"), "qrencode and zbarimg needed")
    def test_the_terminal_qr_code_decodes_to_exactly_the_code(self):
        """The terminal rendering itself (qrencode ANSIUTF8, white glyphs on black) read back as an
        image: zbarimg decodes the pairing code, nothing else."""
        code = "0BCDEFGHJKMNPQRSTVWXYZ012345"
        text = bootstrap.guide.qr_text(code)
        rows = []
        for line in re.sub(r"\x1b\[[0-9;]*m", "", text).splitlines():
            if not line:
                continue
            rows.append([0 if c in "█▀" else 1 for c in line])   # top half: lit means light
            rows.append([0 if c in "█▄" else 1 for c in line])   # bottom half
        scale, width = 6, max(len(r) for r in rows)
        pixels = bytearray()
        for row in rows:
            line = bytearray()
            for x in range(width):
                dark = row[x] if x < len(row) else 0
                line += bytes([0 if dark else 255]) * scale
            pixels += bytes(line) * scale
        folder = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, folder, True)
        image = Path(folder) / "qr.pgm"
        image.write_bytes(b"P5 %d %d 255\n" % (width * scale, len(rows) * scale) + bytes(pixels))
        decoded = subprocess.run(["zbarimg", "-q", "--raw", str(image)], capture_output=True, text=True).stdout.strip()
        self.assertEqual(decoded, code)

    def test_reissue_denies_the_unused_code_then_issues_one(self):
        self.setup.issue_first_code("sam")
        first = self.record["first_invite"]["id"]
        self.system.dry = True
        with mock.patch.object(bootstrap.sys.stdout, "isatty", lambda: False):
            bootstrap.reissue(self.setup)
        self.assertIn(("deny", first), self.operations)
        self.assertNotEqual(self.record["first_invite"]["id"], first)

    def test_evidence_scrubs_secrets_held_in_memory(self):
        self.setup.secrets = {"token": "tok-" + "z" * 30, "topic": "topic-" + "y" * 26}
        self.setup.notes.append("leak tok-" + "z" * 30)
        with mock.patch.object(bootstrap.paths, "STATE_ROOT", self.temp / "absent"), \
                mock.patch.object(bootstrap, "FALLBACK_LOG_DIR", self.temp), \
                mock.patch.object(bootstrap, "utc_stamp", lambda moment=None: "e"):
            self.setup.write_evidence("complete")
        text = (self.temp / "e.json").read_text()
        self.assertNotIn("z" * 30, text)
        self.assertNotIn("y" * 26, text)
        self.assertIn("[redacted]", text)


class StatusIsReadOnly(unittest.TestCase):
    def test_status_and_doctor_only_read(self):
        out = io.StringIO()
        system = FakeSystem(dry=True, out=out)
        self.assertEqual(bootstrap.main(["status", "--json"], system=system, facts=FakeFacts(system), out=out), 0)
        status = json.loads(out.getvalue())
        self.assertIn("apps", status)
        self.assertIn("firewall", status)
        out = io.StringIO()
        with mock.patch.object(bootstrap, "https_reachable", lambda host, timeout=10: True), \
                mock.patch.object(bootstrap.socket, "getaddrinfo", lambda *a, **k: [()]):
            code = bootstrap.main(["doctor"], system=system, facts=FakeFacts(system), out=out)
        self.assertEqual(code, 1)                         # nothing installed on this fake machine
        self.assertEqual(system.executed, [])
        self.assertIn("PROBLEM Step 1 Packages", out.getvalue())
        self.assertIn("Fix:", out.getvalue())


class ReviewFixes(unittest.TestCase):
    """PR #45 review: M1, M2, L2-L4, L6-L8, L10 (the ops items are in tests/test_vm_ops.py)."""

    def setUp(self):
        self.temp = Path(tempfile.mkdtemp(prefix="anj-b2-review-"))
        self.addCleanup(shutil.rmtree, self.temp, True)

    def patch(self, target, name, value):
        patcher = mock.patch.object(target, name, value)
        patcher.start()
        self.addCleanup(patcher.stop)

    def setup_for(self, argv, answers=None, dry=False, **facts):
        system = FakeSystem(dry=dry, out=io.StringIO())
        setup = bootstrap.Setup(bootstrap.parser().parse_args(argv), system=system,
                                facts=FakeFacts(system, **facts), out=io.StringIO())
        if answers is not None:
            setup.answers = answers
        return setup, system

    # M1 ------------------------------------------------------------------------------------
    def adopt_run(self, token_on_disk):
        token, topic = self.temp / "secrets" / "cloudflare-dns-token", self.temp / "secrets" / "ntfy-topic"
        self.patch(bootstrap.paths, "CLOUDFLARE_TOKEN", token)
        self.patch(bootstrap.paths, "NTFY_TOPIC", topic)
        answers = write_answers(self.temp, 'ddns = "on"\n')               # production answers, no token_file
        disks = FakeFacts(FakeSystem()).values["disks"]
        disks[1] = dict(disks[1], fstype="ext4", label="ANJ_DATA", uuid="u-1")
        setup, _system = self.setup_for(["--adopt-data", "--answers", str(answers)], disks=disks)
        seen = {}

        class MountedDisk(bootstrap.DataDisk):
            """Step 3 makes the data disk (and the secrets on it) visible."""
            def state(self):
                return False, "not mounted"

            def apply(self):
                token.parent.mkdir()
                topic.write_text("t" * 32 + "\n")
                if token_on_disk:
                    token.write_text("on-disk-token\n")

            def verify(self):
                return True, "mounted"

        class Later(bootstrap.Ssh):
            def apply(self):
                seen["secrets"] = dict(setup.secrets)

            def state(self):
                return False, "x"

            def verify(self):
                return True, "x"
        self.patch(bootstrap.Setup, "step_list", lambda self: [MountedDisk(self), Later(self)])
        for name in ("summary", "write_evidence", "save_record", "sweep_first_code"):
            self.patch(bootstrap.Setup, name, lambda self, *a, **k: None)
        self.patch(bootstrap, "preflight", lambda *a, **k: [])
        return setup.run(), setup, seen

    def test_adopt_with_ddns_on_and_the_token_on_the_data_disk_succeeds(self):
        code, setup, seen = self.adopt_run(token_on_disk=True)
        self.assertEqual(code, 0, setup.out.getvalue())
        self.assertEqual(seen["secrets"], {})                  # nothing asked, nothing new

    def test_adopt_without_a_token_on_the_disk_refuses_with_a_plain_fix(self):
        code, setup, _seen = self.adopt_run(token_on_disk=False)
        self.assertEqual(code, 1)
        text = setup.out.getvalue()
        self.assertIn("the data disk holds no token", text)
        self.assertIn('Fix: Add token_file = "/path/to/token" to the answers file, or set ddns = "off".', text)

    def test_adopt_and_restore_ask_for_no_state_secret_before_the_disk(self):
        for argv in (["--adopt-data"], ["--restore-from", "/mnt/anj-backup"]):
            setup, _ = self.setup_for(argv, answers={"ddns": "on", "restic_password_file": "/run/x"})
            prompter = mock.Mock()
            setup.prompter = prompter
            setup.collect_secrets(interactive=True)
            prompter.hidden.assert_not_called()
            prompter.yes.assert_not_called()
            self.assertNotIn("token", setup.secrets)
            self.assertNotIn("topic", setup.secrets)

    # M2 ------------------------------------------------------------------------------------
    def stack_files(self, bind, firewall_bind, rendered_bind):
        release = "c" * 40
        stack = self.temp / "stack.json"
        stack.write_text(json.dumps({"host": "gateway.example.com", "release": release, "bind_address": bind,
                                     "household_lan": "192.168.0.0/24"}))
        firewall = self.temp / "firewall.nft"
        firewall.write_text(bootstrap.render_firewall(firewall_bind, "10.77.11.1"))
        (self.temp / "release" / release[:12]).mkdir(parents=True)
        (self.temp / "release" / release[:12] / "haproxy.cfg").write_text(f"frontend f\n    bind {rendered_bind}:443\n")
        self.patch(bootstrap.paths, "STACK_CONFIG", stack)
        self.patch(bootstrap.paths, "RELEASE_DIR", self.temp / "release")
        self.patch(bootstrap, "FIREWALL_FILE", firewall)
        return release

    def test_changed_bind_address_is_applied_to_haproxy_and_restarted(self):
        release = self.stack_files("10.77.11.10", "10.77.11.20", "10.77.11.10")
        answers = {"host": "gateway.example.com", "bind_address": "10.77.11.20", "household_lan": "192.168.0.0/24",
                   "accounts": ["sam"], "ddns": "off", "start_stack": True}
        setup, system = self.setup_for(["--answers", "/dev/null"], answers=answers)
        setup.mode = "adopt"
        setup.release = release
        step = bootstrap.Stack(setup)
        system.responses["pm2 jlist"] = (0, json.dumps([{"name": "haproxy", "pm2_env": {"status": "online"}}]), "")
        self.assertIn("bind address changed", step.problems())
        self.assertIn("443 bind differs (firewall 10.77.11.20, stack 10.77.11.10, haproxy 10.77.11.10)", step.problems())
        self.patch(bootstrap, "TMPFILES_CONF", self.temp / "tmpfiles")
        self.patch(bootstrap, "SYSTEMD_DIR", self.temp / "systemd")
        (self.temp / "systemd").mkdir()
        (self.temp / "systemd" / "pm2-anj.service").write_text("")
        step.apply()
        commands = [" ".join(c["argv"]) for c in system.commands]
        setup_command = next(c for c in commands if " setup " in c)
        self.assertIn("--bind-address 10.77.11.20", setup_command)
        up = [i for i, c in enumerate(commands) if c.endswith("prod.py up")]
        restart = commands.index("pm2 restart haproxy")
        self.assertTrue(up[0] < restart < up[1], commands)   # re-render, restart onto it, wait healthy

    def test_consistent_bind_passes_the_check(self):
        self.stack_files("10.77.11.10", "10.77.11.10", "10.77.11.10")
        setup, system = self.setup_for([], answers={})
        system.responses["ss -ltnH"] = (0, "LISTEN 0 4096 10.77.11.10:443 0.0.0.0:*\n", "")   # round 3 (R1)
        self.assertEqual(bootstrap.Stack(setup).consistency(json.loads(bootstrap.paths.STACK_CONFIG.read_text())), [])

    def test_a_changed_hostname_is_refused_before_any_step(self):
        stack = self.temp / "stack.json"
        stack.write_text(json.dumps({"host": "gateway.example.com"}))
        self.patch(bootstrap.paths, "STACK_CONFIG", stack)
        self.patch(bootstrap.paths, "STATE_ROOT", self.temp)
        setup, _ = self.setup_for([], answers={"host": "other.example.org"})
        with self.assertRaises(bootstrap.SetupError) as raised:
            setup.refuse_host_change()
        self.assertIn("new server certificate", str(raised.exception))

    # L2 ------------------------------------------------------------------------------------
    def test_doctor_never_runs_pm2_or_unattended_upgrade(self):
        out = io.StringIO()
        system = FakeSystem(dry=True, out=out)
        system.responses["systemctl is-active pm2-anj.service"] = (3, "inactive\n", "")
        with mock.patch.object(bootstrap, "https_reachable", lambda host, timeout=10: True), \
                mock.patch.object(bootstrap.socket, "getaddrinfo", lambda *a, **k: [()]):
            bootstrap.main(["doctor"], system=system, facts=FakeFacts(system), out=out)
            bootstrap.main(["status"], system=system, facts=FakeFacts(system), out=out)
        programs = {argv[0] for argv in system.reads}
        self.assertNotIn("pm2", programs)
        self.assertNotIn("unattended-upgrade", programs)
        self.assertFalse([argv for argv in system.reads if "prod.py" in " ".join(argv)])

    def test_read_only_update_check_uses_apt_config(self):
        setup, system = self.setup_for([])
        setup.read_only = True
        system.responses["apt-config dump"] = (0, 'Unattended-Upgrade::Origins-Pattern:: "origin=Debian,codename='
                                                  '${distro_codename}-security,label=Debian-Security";\n'
                                                  'Unattended-Upgrade::Automatic-Reboot "false";\n', "")
        ok, detail = bootstrap.Updates(setup).verify_read_only("files ok", {"Debian-Security"})
        self.assertTrue(ok, detail)
        system.responses["apt-config dump"] = (0, 'Unattended-Upgrade::Origins-Pattern:: "origin=Debian,codename='
                                                  '${distro_codename},label=Debian";\n', "")
        self.assertFalse(bootstrap.Updates(setup).verify_read_only("x", {"Debian-Security"})[0])

    # L3, L4, L7 -----------------------------------------------------------------------------
    def test_a_mounted_backup_share_root_is_never_chmodded_or_remounted(self):
        """SC-067: the restore drill mounts the share ro before setup; step 3 must leave the share's
        root (The VM host's 0700 directory, read-only in the drill) alone, and mount it only when absent."""
        self.patch(bootstrap, "FSTAB", self.temp / "fstab")
        uuid = "1b2c3d4e-0000-4000-8000-000000000001"
        for mounted, expect_share_touched in ((True, False), (False, True)):
            with self.subTest(share_mounted=mounted):
                mounts = {str(bootstrap.paths.DATA_ROOT): {"source": "/dev/vdb", "uuid": uuid}}
                if mounted:
                    mounts[str(bootstrap.paths.BACKUP_MOUNT)] = {"source": "anj-backup", "fstype": "virtiofs"}
                setup, system = self.setup_for(["--restore-from", str(bootstrap.paths.BACKUP_MOUNT)],
                                               answers={"ddns": "off"}, mounted=mounts)
                system.responses["blkid -s UUID"] = (0, uuid + "\n", "")
                bootstrap.DataDisk(setup).apply()
                share = [f for f in system.files if f["path"] == str(bootstrap.paths.BACKUP_MOUNT) + "/"]
                mount = [argv for argv in system.executed if argv == ["mount", str(bootstrap.paths.BACKUP_MOUNT)]]
                self.assertEqual(bool(share), expect_share_touched)
                self.assertEqual(bool(mount), expect_share_touched)

    def test_blkid_failure_stops_before_fstab(self):
        self.patch(bootstrap, "FORMATTED_MARKER", self.temp / "formatted")
        self.patch(bootstrap, "STAGE_DIR", self.temp)
        setup, system = self.setup_for(["--answers", "/dev/null"], answers={"ddns": "off"})
        with self.assertRaises(bootstrap.SetupError) as raised:
            bootstrap.DataDisk(setup).apply()            # mkfs "succeeds"; blkid is not modelled (fails)
        self.assertIn("/etc/fstab was not changed", str(raised.exception))
        self.assertFalse([f for f in system.files if f["path"] == str(bootstrap.FSTAB)])
        mkfs = next(c["argv"] for c in system.commands if c["argv"][0] == "mkfs.ext4")
        self.assertEqual(mkfs[mkfs.index("-U") + 1], (self.temp / "formatted").read_text().strip())

    def test_mkfs_runs_with_empty_stdin(self):
        self.patch(bootstrap, "FORMATTED_MARKER", self.temp / "formatted")
        self.patch(bootstrap, "STAGE_DIR", self.temp)
        setup, system = self.setup_for(["--answers", "/dev/null"], answers={"ddns": "off"})
        calls = []
        original = system.change
        system.change = lambda argv, **options: calls.append((argv, options)) or original(argv, **options)
        with self.assertRaises(bootstrap.SetupError):
            bootstrap.DataDisk(setup).apply()
        argv, options = next(call for call in calls if call[0][0] == "mkfs.ext4")
        self.assertEqual(options.get("data"), "")

    def test_an_interrupted_install_recognises_its_own_formatted_disk(self):
        marker = self.temp / "formatted"
        self.patch(bootstrap, "FORMATTED_MARKER", marker)
        disks = FakeFacts(FakeSystem()).values["disks"]
        disks[1] = dict(disks[1], fstype="ext4", label="ANJ_DATA", uuid="1b2c3d4e-0000-4000-8000-000000000001")
        facts = FakeFacts(FakeSystem(), disks=disks)
        refused = bootstrap.disk_preflight(facts, {}, mode="install", existing_install=False)
        self.assertIn("--adopt-data", refused[0][2])
        marker.write_text("1b2c3d4e-0000-4000-8000-000000000001\n")
        self.assertEqual(bootstrap.disk_preflight(facts, {}, mode="install", existing_install=False), [])
        marker.write_text("another-uuid\n")
        self.assertTrue(bootstrap.disk_preflight(facts, {}, mode="install", existing_install=False))

    def test_probe_errors_count_as_foreign(self):
        for responses, expected in (({"blkid -p": (8, "", "")}, "a blkid probe error (exit 8)"),
                                    ({"blkid -p": (2, "", ""), "wipefs": (1, "", "")}, "a wipefs probe error (exit 1)")):
            system = FakeSystem(responses=responses)
            facts = bootstrap.Facts(system)
            self.assertIn(expected, facts.signatures("/dev/vdb"))

    # L5, L6 ---------------------------------------------------------------------------------
    def test_expired_first_code_file_is_removed_on_a_re_run(self):
        code = self.temp / "first-pairing-code"
        code.write_text("x\n")
        self.patch(bootstrap.paths, "FIRST_PAIRING_CODE", code)
        setup, _ = self.setup_for([])
        self.patch(bootstrap.Setup, "record", property(lambda s: {"first_invite": {"expires": 100.0}}))
        setup.sweep_first_code(now=50.0)
        self.assertTrue(code.exists())
        setup.sweep_first_code(now=200.0)
        self.assertFalse(code.exists())

    def test_halo_issuer_command_never_installs_an_empty_or_bad_file(self):
        if not shutil.which("openssl") or not shutil.which("bash"):
            self.skipTest("openssl and bash needed")
        good = self.temp / "good.crt"
        subprocess.run(["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256", "-noenc",
                        "-subj", "/CN=t", "-days", "1", "-keyout", str(self.temp / "k"), "-out", str(good)],
                       capture_output=True, check=True)
        for source, installed in ((self.temp / "missing.crt", False), (self.temp / "empty.crt", False),
                                  (good, True)):
            if source.name == "empty.crt":
                source.write_text("")
            target = self.temp / "etc"
            shutil.rmtree(target, ignore_errors=True)
            target.mkdir()
            command = bootstrap.HALO_ISSUER_COMMAND.replace(
                f"ssh -F ~/.local/share/anj-cloud/prod-vm/ssh_config anj-prod cat {paths.OPERATOR_DIR}/issuer.crt",
                f"cat {source}").replace("sudo ", "").replace(" -o root -g root", "").replace(
                "/etc/anj-cloud-host", str(target)).replace("~/anj-cloud-ca.crt", str(target / "ca.crt"))
            self.assertNotIn("ssh", command)
            self.assertNotIn("~", command)                          # nothing lands in the real home here
            result = subprocess.run(["bash", "-c", command.split("'", 1)[1].rsplit("'", 1)[0]], capture_output=True,
                                    text=True, timeout=30)
            self.assertEqual((target / "issuer.crt").exists(), installed, source.name)
            self.assertEqual((target / "ca.crt").exists(), installed, source.name)   # the device's CA file
            self.assertEqual("sha256 Fingerprint=" in result.stdout, installed, source.name)
            self.assertFalse((target / "issuer.crt.new").exists())

    # L8 ------------------------------------------------------------------------------------
    def test_firewall_change_is_validated_then_reloaded(self):
        self.patch(bootstrap, "FIREWALL_FILE", self.temp / "etc" / "firewall.nft")
        self.patch(bootstrap, "ETC_DIR", self.temp / "etc")
        self.patch(bootstrap, "SYSTEMD_DIR", self.temp / "systemd")
        setup, system = self.setup_for([], answers={"bind_address": "10.77.11.10", "admin_ssh_source": "10.77.11.1"})
        system.responses["systemctl is-active anj-cloud-firewall.service"] = (0, "active\n", "")
        bootstrap.Firewall(setup).apply()
        commands = [" ".join(c["argv"]) for c in system.commands]
        self.assertIn(f"nft -c -f {self.temp}/etc/firewall.nft.new", commands)
        self.assertIn("systemctl reload anj-cloud-firewall.service", commands)
        self.assertFalse([c for c in commands if "restart anj-cloud-firewall" in c or "stop anj-cloud-firewall" in c])
        order = [f["path"] for f in system.files]
        self.assertLess(order.index(f"{self.temp}/etc/firewall.nft.new"), order.index(f"{self.temp}/etc/firewall.nft"))

    # L10 -----------------------------------------------------------------------------------
    def test_restore_installs_the_dispatcher_before_init_records_it(self):
        self.patch(bootstrap.paths, "BACKUP_RECORD", self.temp / "backup.json")
        self.patch(bootstrap.paths, "BIN_DIR", self.temp / "bin")
        self.patch(bootstrap.paths, "ALERT_COMMAND", self.temp / "bin" / "anj-alert")
        self.patch(bootstrap.paths, "RUN_DIR", self.temp / "run")
        self.patch(bootstrap, "OPS_CONFIG", self.temp / "run" / "ops.json")
        self.patch(bootstrap.paths, "DATA_ROOT", self.temp)
        original = tempfile.TemporaryDirectory
        self.patch(bootstrap.tempfile, "TemporaryDirectory", lambda **k: original(dir=self.temp))
        self.patch(bootstrap.os, "chown", lambda *a, **k: None)
        setup, system = self.setup_for(["--restore-from", "/mnt/anj-backup"],
                                       answers={"alerts_tag": "drill", "restic_password_file": "/run/anj-drill/p"})
        setup.secrets = {"restic_file": "/run/anj-drill/p"}
        bootstrap.Restore(setup).apply()
        events = system.events
        files = [f["path"] for f in system.files]
        dispatcher = events.index(("write", str(self.temp / "bin" / "anj-alert")))
        self.assertLess(dispatcher, next(i for i, e in enumerate(events) if e[0] == "run" and " init " in e[1]))
        self.assertIn(str(self.temp / "bin" / "anj-alert"), files)
        self.assertIn(str(self.temp / "run" / "ops.json"), files)
        init = next(c["argv"] for c in system.commands if "init" in c["argv"])
        self.assertEqual(init[init.index("--alert-command") + 1], str(self.temp / "bin" / "anj-alert"))
        self.assertTrue(events)

    def test_ops_config_is_machine_local(self):
        self.assertEqual(bootstrap.OPS_CONFIG.parent, paths.RUN_DIR)   # run/ is never backed up or restored


if __name__ == "__main__":
    unittest.main()
