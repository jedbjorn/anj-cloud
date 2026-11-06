"""Spec #21: the VM host routines (anjvm templates, host dispatcher, host-check, vm-start) against
stub commands and a loopback ntfy stand-in. No real topic, libvirt, nft or ufw is touched.
"""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

REPO = Path(__file__).resolve().parent.parent
HOST = REPO / "deploy" / "host"
MOCK = Path(__file__).resolve().parent / "host_mock_ntfy.py"
TOPIC = "testTopicNotReal_0123456789abcdef"
UUID = "e90d687d-0eca-4589-a0be-793beae2e305"


def anjvm(*args, check=True):
    return subprocess.run([sys.executable, str(HOST / "anjvm.py"), *args], capture_output=True, text=True, check=check)


class AnjVmTests(unittest.TestCase):
    def test_render_domain_and_share(self):
        plain = anjvm("render-domain", "anj-prod", "--uuid", UUID).stdout
        shared = anjvm("render-domain", "anj-prod", "--uuid", UUID, "--share", "/mnt/anj-backup/anj-cloud-prod").stdout
        for text in (plain, shared):
            self.assertIn("<memballoon model='none'/>", text)
            self.assertIn("<source type='memfd'/>", text)
            self.assertIn("<emulatorpin cpuset='14-15,30-31'/>", text)
            self.assertIn("<os firmware='efi'>", text)
        self.assertNotIn("<filesystem", plain)
        self.assertIn("<source dir='/mnt/anj-backup/anj-cloud-prod'/>", shared)
        self.assertIn("<target dir='anj-backup'/>", shared)
        # Decision #115: the share is served by the root-owned wrapper, never libvirt's <idmap>
        # (virtiofsd refuses --uid-map as root) and never the bare virtiofsd.
        self.assertIn("<binary path='/usr/local/lib/anj-cloud-host/virtiofsd-anj-cloud'/>", shared)
        self.assertNotIn("<idmap", shared)
        self.assertNotIn("/usr/lib/virtiofsd", shared)
        qual = anjvm("render-domain", "anj-qual", "--uuid", UUID, "--share", "/tmp/x", "--readonly").stdout
        self.assertIn("<readonly/>", qual)
        self.assertIn("52:54:00:a7:11:10", qual)
        self.assertEqual(anjvm("render-domain", "anj-prod", "--uuid", "nope", check=False).returncode, 2)

    def test_compare_reports_meaningful_differences_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            expected = Path(tmp, "e.xml")
            expected.write_text(anjvm("render-domain", "anj-prod", "--uuid", UUID).stdout)
            live = Path(tmp, "l.xml")
            # libvirt adds ids, addresses, aliases and controllers; those are not facts.
            live.write_text(expected.read_text().replace("<devices>", "<devices><controller type='usb' index='0'/>")
                            .replace("<domain type='kvm'>", "<domain type='kvm' id='6'>"))
            self.assertEqual(anjvm("compare-domain", str(expected), str(live)).stdout.strip(), "{}")
            live.write_text(expected.read_text().replace("cpuset='31'", "cpuset='12'"))
            result = anjvm("compare-domain", str(expected), str(live), check=False)
            self.assertEqual(result.returncode, 1)
            self.assertIn("vcpupin", result.stdout)

    def test_seed_has_keys_sudo_and_no_secrets(self):
        with tempfile.TemporaryDirectory() as tmp:
            key = Path(tmp, "k.pub")
            key.write_text("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFake test\n")
            anjvm("seed", "anj-qual", "--out", str(Path(tmp, "seed")), "--key", str(key))
            user = Path(tmp, "seed/user-data").read_text()
            self.assertIn('sudo: "ALL=(ALL) NOPASSWD:ALL"', user)
            self.assertIn("ssh_pwauth: false", user)
            self.assertIn("AAAAC3NzaC1lZDI1NTE5AAAAIFake", user)
            self.assertNotIn("fs_setup", user)  # the bootstrap owns the data disk (never formats)
            self.assertIn("10.77.11.10/24", Path(tmp, "seed/network-config").read_text())
            key.write_text("not a key\n")
            self.assertEqual(anjvm("seed", "anj-qual", "--out", str(Path(tmp, "s2")), "--key", str(key),
                                   check=False).returncode, 2)

    def test_cpus_and_headroom(self):
        with tempfile.TemporaryDirectory() as tmp:
            dom = Path(tmp, "d.xml")
            dom.write_text("<domain><name>x</name><cputune><vcpupin vcpu='0' cpuset='8-10,^9'/>"
                           "<emulatorpin cpuset='24'/></cputune></domain>")
            self.assertEqual(anjvm("cpus", str(dom)).stdout.strip(), "8 10 24")
            cgroup = Path(tmp, "machine.slice")
            cgroup.mkdir()
            Path(cgroup, "memory.current").write_text("1073741824\n")
            Path(cgroup, "memory.high").write_text("4294967296\n")
            Path(cgroup, "memory.max").write_text("max\n")
            env = dict(os.environ, ANJ_CGROUP_ROOT=tmp)
            result = json.loads(subprocess.run([sys.executable, str(HOST / "anjvm.py"), "headroom", "--reserved-kib",
                                                str(2 * 1024 * 1024)], capture_output=True, text=True, env=env).stdout)
            self.assertEqual(result["headroom"], 2 * 1024 ** 3)


class ShareOwnershipTests(unittest.TestCase):
    """Decision #115: the backup share's owner, its migration, the VM host-side probe and the
    wrapper's mapping (ownership the unprivileged test cannot set comes from the test overlay)."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="anj-share-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.passwd = self.tmp / "passwd"
        self.passwd.write_text("anj-cloud-backup:x:961:961::/:/usr/bin/nologin\n"
                               "loginy:x:962:962::/:/bin/bash\nuser-like:x:1000:1000::/home/j:/bin/bash\n")
        self.owners = self.tmp / "owners.json"
        self.env = dict(os.environ, ANJ_HOST_TEST="1", ANJ_HOST_TEST_OWNERS=str(self.owners))
        self.share = self.tmp / "anj-cloud-prod"

    def anjvm(self, *args):
        result = subprocess.run([sys.executable, str(HOST / "anjvm.py"), *args], capture_output=True, text=True,
                                env=self.env)
        return result.returncode, (json.loads(result.stdout) if result.stdout.strip().startswith(("{", "[")) else
                                   result.stdout + result.stderr)

    def own(self, uid, gid, mode, path=None):
        data = json.loads(self.owners.read_text()) if self.owners.exists() else {}
        data[str(path or self.share)] = [uid, gid, mode]
        self.owners.write_text(json.dumps(data))

    def test_share_own_creates_then_is_compliant(self):
        code, result = self.anjvm("share-own", str(self.share), "--passwd", str(self.passwd))
        self.assertEqual((code, result["action"], result["after"]), (0, "created", "961:961 0700"), result)
        self.assertTrue(self.share.is_dir())
        code, check = self.anjvm("share-check", str(self.share), "--passwd", str(self.passwd))
        self.assertEqual((code, check["ok"], check["mode"]), (0, True, "0700"), check)
        code, result = self.anjvm("share-own", str(self.share), "--passwd", str(self.passwd))
        self.assertEqual(result["action"], "compliant")

    def test_empty_root_share_is_migrated_and_a_full_one_never(self):
        self.share.mkdir()
        self.own(0, 0, 0o750)   # what the VM host has today: root:root 0750, empty
        code, check = self.anjvm("share-check", str(self.share), "--passwd", str(self.passwd))
        self.assertEqual(code, 1)
        self.assertIn("owner 0:0, expected anj-cloud-backup (961:961)", check["problems"])
        self.assertIn("mode 0750, expected 0700", check["problems"])
        code, result = self.anjvm("share-own", str(self.share), "--passwd", str(self.passwd))
        self.assertEqual((code, result["action"], result["before"]), (0, "migrated", "0:0 0750"), result)
        self.own(961, 961, 0o750)
        self.assertEqual(self.anjvm("share-own", str(self.share), "--passwd", str(self.passwd))[1]["action"], "mode-fixed")
        (self.share / "restic").mkdir()
        self.own(0, 0, 0o750)
        code, message = self.anjvm("share-own", str(self.share), "--passwd", str(self.passwd))
        self.assertEqual(code, 2)
        self.assertIn("holds data owned by 0:0; not changed", message)
        self.assertEqual(json.loads(self.owners.read_text())[str(self.share)], [0, 0, 0o750])

    def test_account_rules(self):
        for name, wanted in (("absent", "account anj-cloud-backup absent"), ("loginy", "has a login shell"),
                             ("user-like", "never 0 or 1000")):
            self.anjvm("share-own", str(self.share), "--passwd", str(self.passwd))  # noqa: the account differs
            code, message = self.anjvm("share-own", str(self.share), "--account", name, "--passwd", str(self.passwd))
            self.assertEqual(code, 2, name)
            self.assertIn(wanted, message, name)

    def test_probe_reports_what_halo_uids_can_do(self):
        self.share.mkdir()
        self.own(961, 961, 0o700)
        code, result = self.anjvm("share-probe", str(self.share), "--uid", "1000")
        self.assertEqual((code, result), (0, {"1000": {"read": False, "write": False}}))
        self.own(961, 961, 0o757)
        code, result = self.anjvm("share-probe", str(self.share), "--uid", "1000")
        self.assertEqual((code, result["1000"]["write"]), (1, True))
        self.own(1000, 1000, 0o700)
        self.assertEqual(self.anjvm("share-probe", str(self.share), "--uid", "1000")[0], 1)

    def test_probe_really_attempts_for_the_caller(self):
        self.env.pop("ANJ_HOST_TEST")
        self.share.mkdir(mode=0o700)
        code, result = self.anjvm("share-probe", str(self.share), "--uid", str(os.getuid()))
        self.assertEqual((code, result[str(os.getuid())]), (1, {"read": True, "write": True}))
        self.assertEqual(list(self.share.iterdir()), [])  # the probe file is removed

    @unittest.skipIf(os.geteuid() == 0, "an unprivileged caller cannot try as another uid")
    def test_a_probe_that_did_not_run_is_not_a_denial(self):
        self.env.pop("ANJ_HOST_TEST")
        self.share.mkdir(mode=0o700)
        code, result = self.anjvm("share-probe", str(self.share), "--uid", str(os.getuid() + 1))
        self.assertEqual(code, 3)
        self.assertIsNone(result[str(os.getuid() + 1)]["write"])

    def test_translate_args_map_anj_squash_root_forbid_the_rest(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("anjvm_t", HOST / "anjvm.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        self.share.mkdir()
        os.environ["ANJ_HOST_TEST"] = "1"
        os.environ["ANJ_HOST_TEST_OWNERS"] = str(self.owners)
        self.addCleanup(os.environ.pop, "ANJ_HOST_TEST")
        self.addCleanup(os.environ.pop, "ANJ_HOST_TEST_OWNERS")
        self.own(961, 962, 0o700)
        self.assertEqual(module.translate_args(str(self.share)), [
            "--translate-uid", "squash-guest:0:961:1", "--translate-uid", "forbid-guest:1:999",
            "--translate-uid", "map:1000:961:1", "--translate-uid", "forbid-guest:1001:4294966294",
            "--translate-gid", "squash-guest:0:962:1", "--translate-gid", "forbid-guest:1:999",
            "--translate-gid", "map:1000:962:1", "--translate-gid", "forbid-guest:1001:4294966294"])
        for owner in ((0, 961, 0o700), (961, 0, 0o700), (1000, 961, 0o700), (961, 1000, 0o700), (961, 961, 0o750)):
            self.own(*owner)
            with self.assertRaises(ValueError, msg=owner):
                module.translate_args(str(self.share))

    def test_share_facts_and_running_virtiofsd_args(self):
        dom = self.tmp / "d.xml"
        dom.write_text(anjvm("render-domain", "anj-prod", "--uuid", UUID, "--share", "/mnt/anj-backup/anj-cloud-prod").stdout)
        code, facts = self.anjvm("share-facts", str(dom))
        self.assertEqual(facts, [{"binary": "/usr/local/lib/anj-cloud-host/virtiofsd-anj-cloud", "driver": "virtiofs",
                                  "idmap": False, "readonly": False, "source": "/mnt/anj-backup/anj-cloud-prod",
                                  "target": "anj-backup"}])
        proc = self.tmp / "proc"
        for pid, argv in (("10", ["/usr/lib/virtiofsd", "--fd=35", "--shared-dir", "/mnt/anj-backup/anj-cloud-prod", "-x"]),
                          ("11", ["/usr/lib/virtiofsd", "--shared-dir=/srv/other"]),
                          ("12", ["/usr/bin/python3", "--shared-dir", "/mnt/anj-backup/anj-cloud-prod"])):
            (proc / pid).mkdir(parents=True)
            (proc / pid / "cmdline").write_bytes(b"\0".join(a.encode() for a in argv) + b"\0")
        code, found = self.anjvm("virtiofsd-args", "/mnt/anj-backup/anj-cloud-prod", "--proc", str(proc))
        self.assertEqual(found, [["/usr/lib/virtiofsd", "--fd=35", "--shared-dir", "/mnt/anj-backup/anj-cloud-prod", "-x"]])

    @unittest.skipUnless(shutil.which("unshare") and shutil.which("newuidmap"), "needs util-linux unshare and newuidmap")
    def test_scratch_share_is_owned_by_a_subuid_and_unreachable(self):
        env = {k: v for k, v in os.environ.items() if not k.startswith("ANJ_")}
        env["HOME"] = str(self.tmp)
        base = self.tmp / ".local/share/anj-cloud/qualification"
        base.mkdir(parents=True)
        run = lambda *a: subprocess.run([sys.executable, "-I", str(HOST / "anjvm.py"), *a], capture_output=True,  # noqa: E731
                                        text=True, env=env, timeout=120)
        # Only directly under the qualification directory: never anything else the user owns.
        elsewhere = self.tmp / "precious"
        elsewhere.mkdir()
        (elsewhere / "file").write_text("keep")
        for action in ("remove", "create"):
            for target in (elsewhere, base, base / "a" / "b", self.tmp):
                result = run("scratch-share", action, str(target))
                self.assertEqual(result.returncode, 2, (action, target))
        self.assertEqual((elsewhere / "file").read_text(), "keep")
        path = base / "scratch"
        created = run("scratch-share", "create", str(path))
        if created.returncode:
            self.skipTest("no subordinate uid range for this user: " + created.stderr.strip())
        self.addCleanup(run, "scratch-share", "remove", str(path))
        info = json.loads(created.stdout)
        self.assertEqual((path.stat().st_uid, path.stat().st_mode & 0o777), (info["uid"], 0o700))
        self.assertNotIn(info["uid"], (0, 1000, os.getuid()))
        self.assertEqual(json.loads(run("share-probe", str(path), "--uid", str(os.getuid())).stdout),
                         {str(os.getuid()): {"read": False, "write": False}})
        self.assertEqual(run("share-exec", str(path), "--", "touch", str(path / "f")).returncode, 0)
        self.assertEqual(json.loads(run("scratch-share", "remove", str(path)).stdout)["removed"], True)


class WrapperTests(unittest.TestCase):
    """deploy/host/virtiofsd-anj-cloud: libvirt's arguments plus the mapping, or nothing at all."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="anj-wrapper-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.fake = self.tmp / "virtiofsd"
        self.fake.write_text(f"#!/bin/sh\nfor a in \"$@\"; do echo \"$a\"; done > {self.tmp}/argv\n")
        self.fake.chmod(0o755)
        self.owners = self.tmp / "owners.json"
        self.share = self.tmp / "share"
        self.share.mkdir()

    def run_wrapper(self, *args, owner=(961, 961, 0o700), test=True):
        self.owners.write_text(json.dumps({str(self.share): list(owner)}))
        env = {"PATH": "/usr/bin:/bin", "ANJ_VIRTIOFSD": str(self.fake), "ANJ_HOST_TEST_OWNERS": str(self.owners),
               "ANJ_WRAPPER_TEST_BASE": str(self.tmp)}
        if test:
            env["ANJ_HOST_TEST"] = "1"
        (self.tmp / "argv").unlink(missing_ok=True)
        result = subprocess.run([sys.executable, "-I", str(HOST / "virtiofsd-anj-cloud"), *args], capture_output=True,
                                text=True, env=env, timeout=60)
        argv = (self.tmp / "argv").read_text().splitlines() if (self.tmp / "argv").exists() else None
        return result, argv

    def test_appends_the_mapping_to_libvirts_arguments(self):
        result, argv = self.run_wrapper("--fd=35", "--shared-dir", str(self.share))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(argv[:3], ["--fd=35", "--shared-dir", str(self.share)])
        self.assertIn("map:1000:961:1", argv)
        self.assertIn("squash-guest:0:961:1", argv)
        self.assertEqual(argv.count("--translate-uid"), 4)
        self.assertEqual(argv.count("--translate-gid"), 4)

    def test_capability_probe_passes_through(self):
        result, argv = self.run_wrapper("--print-capabilities")
        self.assertEqual((result.returncode, argv), (0, ["--print-capabilities"]))

    def test_fails_closed(self):
        cases = [((0, 0, 0o700), "never root or 1000"), ((0, 0, 0o750), "expected 0700"), ((1000, 1000, 0o700), "never root or 1000"),
                 ((961, 961, 0o755), "expected 0700")]
        for owner, message in cases:
            result, argv = self.run_wrapper("--fd=3", "--shared-dir", str(self.share), owner=owner)
            self.assertEqual((result.returncode, argv), (1, None), owner)
            self.assertIn(message, result.stderr)
        # Only libvirt's shape: --fd=N --shared-dir PATH [--readonly].
        for extra in (["--uid-map=:0:1:1:"], ["--translate-uid", "map:0:0:1"], ["-o", "xattr"], ["--sandbox", "none"],
                      ["--seccomp", "none"], ["--modcaps=+sys_admin"], ["--xattr"], ["--cache", "auto"]):
            result, argv = self.run_wrapper("--fd=3", "--shared-dir", str(self.share), *extra)
            self.assertEqual((result.returncode, argv), (1, None), extra)
            self.assertIn("refusing arguments", result.stderr)
        for argv_in in (["-o", f"source={self.share}"], ["--shared-dir", str(self.share)], ["--fd=3"],
                        ["--print-capabilities", "--fd=3"]):
            result, argv = self.run_wrapper(*argv_in)
            self.assertEqual((result.returncode, argv), (1, None), argv_in)
        result, argv = self.run_wrapper("--fd=3", "--shared-dir", str(self.share), "--readonly")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--readonly", argv)
        # Only the production share and qualification scratch directories, by a path without links.
        other = self.tmp / "sub" / "deeper"
        other.mkdir(parents=True)
        link = self.tmp / "link"
        link.symlink_to(self.share)
        for path in (other, link, Path("/etc")):
            self.owners.write_text(json.dumps({str(path): [961, 961, 0o700]}))
            result, argv = self.run_wrapper("--fd=3", "--shared-dir", str(path))
            self.assertEqual((result.returncode, argv), (1, None), path)
            self.assertIn("not a served share", result.stderr)
        if os.geteuid() != 0:
            result, argv = self.run_wrapper("--fd=3", "--shared-dir", str(self.share), test=False)
            self.assertEqual((result.returncode, argv), (1, None))
            self.assertIn("root", result.stderr)


class Routines(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="anj-hostroutines-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.config = self.tmp / "etc"
        self.config.mkdir()
        topic = self.config / "ntfy-topic"
        topic.write_text(TOPIC)
        topic.chmod(0o600)
        self.log = self.tmp / "ntfy.jsonl"
        self.log.touch()
        self.server = subprocess.Popen([sys.executable, str(MOCK), str(self.tmp / "port"), str(self.log)])
        self.addCleanup(self.server.wait, 10)
        self.addCleanup(self.server.terminate)
        for _ in range(100):
            if (self.tmp / "port").exists():
                break
            time.sleep(0.05)
        self.url = f"http://127.0.0.1:{(self.tmp / 'port').read_text()}"
        (self.config / "anj-cloud-host.json").write_text(json.dumps(
            {"ntfy_server": self.url, "lan_addr": "127.0.0.1", "host": "localhost",
             "backup_mount": str(self.tmp / "mnt")}))
        self.stubs = self.tmp / "stubs"
        self.stubs.mkdir()

    def stub(self, name, body):
        path = self.stubs / name
        path.write_text(f'#!/bin/sh\necho "{name} $*" >> "{self.tmp}/calls.log"\n' + body + "\n")
        path.chmod(0o755)

    def calls(self):
        path = self.tmp / "calls.log"
        return path.read_text().splitlines() if path.exists() else []

    def alerts(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def run_routine(self, name, *args, env=None, stdin=""):
        environment = {"PATH": f"{self.stubs}:/usr/bin:/bin", "ANJ_HOST_TEST": "1", "ANJ_HOST_CONFIG_DIR": str(self.config),
                       "ANJ_HOST_STATE_DIR": str(self.tmp / "state"), "ANJ_HOST_RECHECK_SECONDS": "0", "LANG": "C"}
        environment.update(env or {})
        result = subprocess.run([sys.executable, "-I", str(HOST / name), *args], capture_output=True, text=True,
                                env=environment, timeout=120, input=stdin)
        self.output = result.stdout + result.stderr
        return result


class DispatcherTests(Routines):
    def test_sudo_floor_queues_and_announces(self):
        sudo = {"SUDO_USER": "operator"}
        codes = [self.run_routine("anj-alert", "--every", "0", "--", f"stop {n}", env=sudo).returncode for n in range(12)]
        self.assertEqual(codes, [0] * 10 + [5, 5])
        self.assertEqual(len(self.alerts()), 10)
        self.assertEqual(self.run_routine("anj-alert", "--flush-suppressed", env=sudo).returncode, 2)  # root timers only
        self.assertEqual(self.run_routine("anj-alert", "--flush-suppressed").returncode, 0)
        notices = [a for a in self.alerts() if "alerts suppressed" in a["title"]]
        self.assertEqual(len(notices), 1)
        self.assertIn("alerts suppressed (2)", notices[0]["body"])
        self.run_routine("anj-alert", "--flush-suppressed")
        self.assertEqual(len([a for a in self.alerts() if "alerts suppressed" in a["title"]]), 1)  # once only
        self.assertEqual(self.run_routine("anj-alert", "--every", "0", "--", "root path").returncode, 0)  # no floor

    def test_prefix_throttle_scrub_and_root_only(self):
        self.run_routine("anj-alert", "--key", "k", "--", "drive /mnt/anj-backup/anj-cloud-prod missing")
        self.run_routine("anj-alert", "--key", "k", "--", "again")
        alerts = self.alerts()
        self.assertEqual(len(alerts), 1)
        self.assertTrue(alerts[0]["body"].startswith("VM host: "))
        self.assertNotIn("/mnt/anj-backup", alerts[0]["body"])
        self.assertEqual(alerts[0]["path"], "/" + TOPIC)
        self.assertNotIn(TOPIC, self.output)
        result = subprocess.run([sys.executable, "-I", str(HOST / "anj-alert"), "--", "x"], capture_output=True, text=True,
                                env={"PATH": "/usr/bin:/bin", "ANJ_HOST_CONFIG_DIR": str(self.config)})
        self.assertEqual(result.returncode, 2)  # not root and not the test flag
        (self.config / "ntfy-topic").chmod(0o640)
        self.assertEqual(self.run_routine("anj-alert", "--", "x").returncode, 2)


class HostCheckTests(Routines):
    def setUp(self):
        super().setUp()
        (self.tmp / "mnt").mkdir()

    def world(self, vm="running", table=True, rule=True, heal=True):
        self.stub("virsh", f"echo {vm}")
        marker = self.tmp / "table"
        if table:
            marker.touch()
        self.stub("nft", f'[ -e "{marker}" ]')
        self.stub("systemctl", f'{"touch " + str(marker) if heal else "true"}')
        self.stub("ufw", 'echo "Status: active"' + ('; echo "443 ALLOW # anj-cloud-vm inbound 443"' if rule else ""))
        self.stub("uname", "uname_real=$(/usr/bin/uname -r); echo $uname_real")

    def test_watchdog_down_once_recovered_once(self):
        self.world(vm="shut off")
        self.run_routine("host-check", "--watchdog", env={"ANJ_HOST_NOW": str(time.mktime((2026, 11, 3, 12, 0, 0, 0, 0, -1)))})
        self.run_routine("host-check", "--watchdog", env={"ANJ_HOST_NOW": str(time.mktime((2026, 11, 3, 12, 5, 0, 0, 0, -1)))})
        self.assertEqual([a["title"] for a in self.alerts()], ["VM host: anj-cloud DOWN"])
        self.assertIn("vm-not-running", self.alerts()[0]["body"])
        self.assertEqual(sum(1 for c in self.calls() if c.startswith("virsh")), 6)  # each run: a check and two rechecks
        self.world(vm="running")
        self.run_routine("host-check", "--watchdog")
        # TLS to 127.0.0.1:443 is refused here, so the VM stays "down": no recovery message yet.
        self.assertEqual(len(self.alerts()), 1)

    def test_reboot_window_needs_ten_minutes(self):
        self.world(vm="shut off")
        at = lambda minute: str(time.mktime((2026, 11, 3, 4, minute, 0, 0, 0, -1)))  # noqa: E731
        self.run_routine("host-check", "--watchdog", env={"ANJ_HOST_NOW": at(5)})
        self.assertIn("failing-in-reboot-window", self.output)
        self.run_routine("host-check", "--watchdog", env={"ANJ_HOST_NOW": at(10)})
        self.assertEqual(self.alerts(), [])
        self.run_routine("host-check", "--watchdog", env={"ANJ_HOST_NOW": at(16)})
        self.assertEqual([a["title"] for a in self.alerts()], ["VM host: anj-cloud DOWN"])

    def test_missing_forward_table_is_reapplied_and_alerted(self):
        self.world(table=False)
        self.run_routine("host-check", "--check")
        self.assertIn("systemctl restart anj-cloud-forward.service", self.calls())
        titles = [a["title"] for a in self.alerts()]
        self.assertIn("VM host: anj-cloud forward re-applied", titles)
        self.assertNotIn("forward-table-missing", self.output)

    def test_hook_never_fails_and_notes_qemu_update(self):
        self.world(vm="shut off")
        result = self.run_routine("host-check", "--hook", stdin="qemu-base\nlibvirt\nzsh\n")
        self.assertEqual(result.returncode, 0)
        record = json.loads(self.output.strip().splitlines()[-1])
        self.assertIn("kernel/QEMU/libvirt updated: the VM runs the old QEMU until its next restart", record["notes"])
        self.assertIn("backup-drive-not-mounted", record["failures"])

    def test_forward_off_is_not_healed(self):
        self.world(table=False)
        (self.config / "forward-off").touch()
        self.run_routine("host-check", "--check")
        self.assertNotIn("systemctl restart anj-cloud-forward.service", self.calls())


class VmStartTests(Routines):
    def setUp(self):
        super().setUp()
        self.state = self.tmp / "dom"
        self.state.mkdir()
        (self.state / "state").write_text("shut off")
        (self.state / "xml").write_text(anjvm("render-domain", "anj-prod", "--uuid", UUID).stdout)
        s = self.state
        self.stub("virsh", f"""while [ "$1" = -q ] || [ "$1" = -c ]; do [ "$1" = -c ] && shift; shift; done
case "$1" in
  domstate) cat "{s}/state";;
  domuuid) echo {UUID};;
  dumpxml) cat "{s}/xml";;
  define) cp "$2" "{s}/xml"; echo defined;;
  start) echo running > "{s}/state";;
  shutdown) echo "shut off" > "{s}/state";;
esac""")

    def test_starts_without_share_and_alerts_once(self):
        result = self.run_routine("vm-start", env={"ANJ_BACKUP_MOUNT": str(self.tmp / "absent")})
        self.assertEqual(result.returncode, 0, self.output)
        self.assertEqual((self.state / "state").read_text().strip(), "running")
        self.assertEqual([a["title"] for a in self.alerts()], ["VM host: anj-cloud running without backups"])
        self.assertNotIn("<filesystem", (self.state / "xml").read_text())

    def share_env(self, owner):
        share = self.tmp / "mnt" / "anj-cloud-prod"
        share.mkdir(parents=True, exist_ok=True)
        (self.tmp / "passwd").write_text("anj-cloud-backup:x:961:961::/:/usr/bin/nologin\n")
        (self.tmp / "owners.json").write_text(json.dumps({str(share): list(owner)}))
        return {"ANJ_BACKUP_MOUNT": str(self.tmp / "mnt"), "ANJ_HOST_TEST_MOUNTED": "1",
                "ANJ_HOST_PASSWD": str(self.tmp / "passwd"), "ANJ_HOST_TEST_OWNERS": str(self.tmp / "owners.json")}

    def test_starts_with_share_when_the_drive_is_mounted(self):
        result = self.run_routine("vm-start", env=self.share_env((961, 961, 0o700)))
        self.assertEqual(result.returncode, 0, self.output)
        xml = (self.state / "xml").read_text()
        self.assertIn("<filesystem", xml)
        self.assertIn(str(self.tmp / "mnt" / "anj-cloud-prod"), xml)
        self.assertIn("<binary path='/usr/local/lib/anj-cloud-host/virtiofsd-anj-cloud'/>", xml)
        self.assertEqual(self.alerts(), [])

    def test_an_old_share_definition_is_switched_to_the_wrapper(self):
        # The live anj-prod today: a share served by the bare virtiofsd (no mapping).
        old = anjvm("render-domain", "anj-prod", "--uuid", UUID, "--share", str(self.tmp / "mnt" / "anj-cloud-prod")).stdout
        (self.state / "xml").write_text(old.replace("/usr/local/lib/anj-cloud-host/virtiofsd-anj-cloud", "/usr/lib/virtiofsd"))
        result = self.run_routine("vm-start", env=self.share_env((961, 961, 0o700)))
        self.assertEqual(result.returncode, 0, self.output)
        self.assertIn('"redefined": "with share"', self.output)
        self.assertIn("virtiofsd-anj-cloud", (self.state / "xml").read_text())

    def test_a_share_that_fails_to_start_falls_back_to_no_share(self):
        # The wrapper (or virtiofsd) fails: libvirt cannot start a domain with the share.
        s = self.state
        self.stub("virsh", f"""while [ "$1" = -q ] || [ "$1" = -c ]; do [ "$1" = -c ] && shift; shift; done
case "$1" in
  domstate) cat "{s}/state";;
  domuuid) echo {UUID};;
  dumpxml) cat "{s}/xml";;
  define) cp "$2" "{s}/xml"; echo defined;;
  start) if grep -q "<filesystem" "{s}/xml"; then echo "virtiofsd died unexpectedly" >&2; exit 1; fi
         echo running > "{s}/state";;
esac""")
        result = self.run_routine("vm-start", env=self.share_env((961, 961, 0o700)))
        self.assertEqual(result.returncode, 0, self.output)
        self.assertEqual((self.state / "state").read_text().strip(), "running")
        self.assertNotIn("<filesystem", (self.state / "xml").read_text())
        self.assertIn('"share_start_failed": true', self.output)
        alerts = self.alerts()
        self.assertEqual([a["title"] for a in alerts], ["VM host: anj-cloud running without backups"])
        self.assertIn("fs0 virtiofsd log", alerts[0]["body"])   # anj-alert scrubs paths; the record has it
        self.assertIn("/var/log/libvirt/qemu/anj-prod-fs0-virtiofsd.log", self.output)

    def test_stop_waits_for_shut_off_and_fails_at_the_timeout(self):
        (self.state / "state").write_text("running")
        s = self.state
        self.stub("virsh", f"""while [ "$1" = -q ] || [ "$1" = -c ]; do [ "$1" = -c ] && shift; shift; done
case "$1" in
  domstate) cat "{s}/state";;
  domuuid) echo {UUID};;
  shutdown) echo "in shutdown" > "{s}/state";;
  start) echo "domain is already active" >&2; exit 1;;
esac""")
        result = self.run_routine("vm-start", "--stop", env={"ANJ_VM_STOP_TIMEOUT": "3"})
        self.assertEqual(result.returncode, 1, self.output)
        self.assertIn('"result": "timeout"', self.output)
        self.assertIn("in shutdown", self.output)
        # A start while the guest is still "in shutdown" never switches or starts anything.
        result = self.run_routine("vm-start", env={"ANJ_VM_STOP_TIMEOUT": "3"})
        self.assertEqual(result.returncode, 1, self.output)
        self.assertIn("not shut off", self.output)
        self.assertFalse([c for c in self.calls() if " define" in c or c.endswith(" start anj-prod")])

    def test_an_undefined_domain_neither_waits_nor_says_vm_is_empty(self):
        # anj-prod undefined (e.g. mid --recreate): every lookup fails, domstate prints nothing.
        self.stub("virsh", 'echo "error: failed to get domain" >&2; exit 1')
        began = time.time()
        result = self.run_routine("vm-start", "--stop", env={"ANJ_VM_STOP_TIMEOUT": "30"})
        self.assertEqual(result.returncode, 0, self.output)
        self.assertIn('"result": "not-defined"', self.output)
        self.assertLess(time.time() - began, 10)
        self.assertFalse([c for c in self.calls() if " shutdown" in c])
        began = time.time()
        result = self.run_routine("vm-start", env={"ANJ_VM_STOP_TIMEOUT": "30"})
        self.assertEqual(result.returncode, 1, self.output)
        self.assertLess(time.time() - began, 10)
        self.assertEqual([a["title"] for a in self.alerts()], ["VM host: anj-cloud VM missing"])

    def test_a_share_with_the_wrong_owner_is_not_attached(self):
        result = self.run_routine("vm-start", env=self.share_env((0, 0, 0o750)))
        self.assertEqual(result.returncode, 0, self.output)
        self.assertNotIn("<filesystem", (self.state / "xml").read_text())
        self.assertEqual((self.state / "state").read_text().strip(), "running")
        alerts = self.alerts()
        self.assertEqual([a["title"] for a in alerts], ["VM host: anj-cloud running without backups"])
        self.assertIn("not owned by anj-cloud-backup", alerts[0]["body"])

    def test_virsh_runs_in_the_c_locale(self):
        # Under a French locale virsh would answer "en cours d'exécution"; vm-start must still see "running".
        (self.state / "state").write_text("running")
        self.stub("virsh", f"""[ "$LC_ALL" = C ] || {{ echo "en cours d'exécution"; exit 0; }}
cat "{self.state}/state" """)
        self.run_routine("vm-start", env={"LANG": "fr_FR.UTF-8", "LC_ALL": "fr_FR.UTF-8"})
        self.assertIn("already-running", self.output)

    def test_already_running_is_left_alone(self):
        (self.state / "state").write_text("running")
        self.run_routine("vm-start")
        self.assertIn("already-running", self.output)
        self.assertFalse([c for c in self.calls() if " start" in c or " define" in c])

    def test_stop_waits_for_clean_shutdown(self):
        (self.state / "state").write_text("running")
        self.run_routine("vm-start", "--stop", env={"ANJ_VM_STOP_TIMEOUT": "5"})
        self.assertIn("shut-off", self.output)


if __name__ == "__main__":
    unittest.main()
