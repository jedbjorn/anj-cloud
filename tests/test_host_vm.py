"""Spec #21: deploy/host/halo-vm.sh in a stubbed-command harness (tests/host_vm_stub.py).

libvirt, ufw, nft and systemd are simulated and every file path is prefixed by a temporary root,
so nothing touches the real VM host. The script refuses the harness variables unless every external
command resolves inside the stub directory.
"""

import hashlib
import json
import os
from pathlib import Path
import pwd
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parent.parent
HOST = REPO / "deploy" / "host"
SCRIPT = HOST / "halo-vm.sh"
STUB = Path(__file__).resolve().parent / "host_vm_stub.py"
COMMANDS = ("virsh ufw nft systemctl systemd-analyze ip ss sshd uname pacman docker runuser tailscale visudo sudo xorriso ssh "
            "ssh-keygen mountpoint gpgv sysctl systemd-sysusers").split()
# The planner's hand-made rules exactly as prod-vm/ufw-anj-prod.sh issued them (stub text = ufw args).
PLANNER_TEXT = {
    "anj-prod DHCP": "allow in on virbr-anjprod proto udp from any port 68 to any port 67",
    "anj-prod DNS UDP": "allow in on virbr-anjprod proto udp from 10.77.10.0/24 to 10.77.10.1 port 53",
    "anj-prod DNS TCP": "allow in on virbr-anjprod proto tcp from 10.77.10.0/24 to 10.77.10.1 port 53",
    "anj-prod no LAN 10.0.0.0/8": "route deny in on virbr-anjprod out on eth0 from 10.77.10.0/24 to 10.0.0.0/8",
    "anj-prod no LAN 172.16.0.0/12": "route deny in on virbr-anjprod out on eth0 from 10.77.10.0/24 to 172.16.0.0/12",
    "anj-prod no LAN 192.168.0.0/16": "route deny in on virbr-anjprod out on eth0 from 10.77.10.0/24 to 192.168.0.0/16",
    "anj-prod outbound NAT": "route allow in on virbr-anjprod out on eth0 from 10.77.10.0/24",
}
PLANNER = ["anj-prod DHCP", "anj-prod DNS UDP", "anj-prod DNS TCP", "anj-prod no LAN 10.0.0.0/8",
           "anj-prod no LAN 172.16.0.0/12", "anj-prod no LAN 192.168.0.0/16", "anj-prod outbound NAT"]
USER = pwd.getpwuid(os.getuid()).pw_name
HOME = pwd.getpwuid(os.getuid()).pw_dir
KEY = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeKeyForTestsOnly0000000000000000000000 test@halo"
GIB = 1024 ** 3

MUTATING_VIRSH = {"define", "undefine", "start", "destroy", "shutdown", "autostart", "net-define", "net-start",
                  "net-destroy", "net-undefine", "net-autostart", "pool-define", "pool-build", "pool-start",
                  "pool-destroy", "pool-delete", "pool-undefine", "pool-autostart", "vol-create-as", "vol-upload",
                  "vol-resize", "vol-delete"}
MUTATING_SYSTEMCTL = {"enable", "disable", "start", "stop", "restart", "reload", "daemon-reload"}
OURS = {"anj-prod", "anj-qual", "anj-prod-os.qcow2", "anj-prod-data.qcow2", "anj-prod-seed.iso",
        "anj-qual-os.qcow2", "anj-qual-data.qcow2", "anj-qual-seed.iso"}


def _addr_in(spec, addr):
    import ipaddress
    if spec in ("any", None):
        return True
    return ipaddress.ip_address(addr) in ipaddress.ip_network(spec, strict=False)


def parse_rule(text):
    words = text.split()
    rule = {"route": False, "in": None, "out": None, "proto": None, "from": "any", "sport": None, "to": "any",
            "dport": None}
    if words[:1] == ["route"]:
        rule["route"] = True
        words = words[1:]
    rule["action"] = words[0]
    i = 1
    while i < len(words):
        w = words[i]
        if w in ("in", "out") and words[i + 1:i + 2] == ["on"]:
            rule[w] = words[i + 2]
            i += 3
        elif w == "proto":
            rule["proto"] = words[i + 1]
            i += 2
        elif w in ("from", "to"):
            rule[w] = words[i + 1]
            i += 2
            if words[i:i + 1] == ["port"]:
                rule["sport" if w == "from" else "dport"] = words[i + 1]
                i += 2
        elif "/" in w and ":" in w or w.split("/")[0].isdigit():  # e.g. 1714:1764/tcp
            port, _, proto = w.partition("/")
            rule["dport"], rule["proto"] = port, proto or None
            i += 1
        else:
            i += 1
    return rule


def _port_in(spec, port):
    if spec is None:
        return True
    if ":" in spec:
        low, high = spec.split(":")
        return int(low) <= int(port) <= int(high)
    return spec == port


def first_match(rules, route, src, dst, proto, dport, sport="40000", inbound="virbr-anjprod", outbound="eth0"):
    """ufw-style first match over the stub's rule list; the default for both chains is deny."""
    for rule in rules:
        r = parse_rule(rule["text"])
        if r["route"] != route or r["in"] not in (None, inbound):
            continue
        if route and r["out"] not in (None, outbound):
            continue
        if (r["proto"] not in (None, proto) or not _addr_in(r["from"], src) or not _addr_in(r["to"], dst)
                or not _port_in(r["sport"], sport) or not _port_in(r["dport"], dport)):
            continue
        return r["action"], rule["comment"]
    return "deny", "(default policy)"


def virsh_command(call):
    args = [a for a in call[1:] if a != "-q"]
    if args[:1] == ["-c"]:
        args = args[2:]
    return args


def mutating(calls):
    found = []
    for call in calls:
        if call[0] == "virsh" and virsh_command(call)[0] in MUTATING_VIRSH:
            found.append(call)
        elif call[0] == "systemctl" and len(call) > 1 and call[1] in MUTATING_SYSTEMCTL:
            found.append(call)
        elif call[0] == "ufw" and call[1:2] != ["status"]:
            found.append(call)
        elif call[0] == "nft" and call[1:2] in (["-f"], ["delete"]):
            found.append(call)
    return found


class Harness:
    def __init__(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="anj-vm-test-"))
        self.root = self.tmp / "root"
        self.stubs = self.tmp / "stubs"
        self.stubs.mkdir()
        for command in COMMANDS:
            path = self.stubs / command
            path.write_text(f"#!/bin/sh\nexec {sys.executable} {STUB} {command} \"$@\"\n")
            path.chmod(0o755)
        for directory in ("etc/ssh/sshd_config.d", "etc/systemd/system/machine.slice.d", "etc/systemd/system/user.slice.d",
                          "usr/local/lib/halo-host-memory", "proc/sys/kernel/random", "var/lib/libvirt/images",
                          "etc/pacman.d/hooks", "dev/disk/by-uuid", "mnt/anj-backup", "var/tmp"):
            (self.root / directory).mkdir(parents=True, exist_ok=True)
        (self.root / "etc/os-release").write_text("ID=cachyos\nID_LIKE=arch\n")
        # Decision #115: accounts and ownership the unprivileged test cannot really create.
        (self.root / "etc/passwd").write_text(f"{USER}:x:{os.getuid()}:{os.getgid()}::{HOME}:/bin/bash\n")
        (self.root / "etc/group").write_text(f"{USER}:x:{os.getgid()}:\n")
        (self.root / "etc/subuid").write_text(f"{USER}:100000:65536\n")
        (self.root / "etc/subgid").write_text(f"{USER}:100000:65536\n")
        self.owners = self.tmp / "owners.json"
        (self.root / "etc/hosts").write_text("127.0.0.1 localhost\n")
        (self.root / "etc/ssh/sshd_config").write_text("Include /etc/ssh/sshd_config.d/*.conf\n")
        (self.root / "etc/ssh/sshd_config.d/90-windows-test-controller.conf").write_text("ListenAddress 192.168.122.1\n")
        (self.root / "etc/systemd/system/machine.slice.d/90-halo-memory.conf").write_text("[Slice]\nMemoryHigh=22G\n")
        (self.root / "usr/local/lib/halo-host-memory/policy.json").write_text("{}\n")
        (self.root / "proc/sys/kernel/random/boot_id").write_text("boot-1\n")
        (self.root / "dev/disk/by-uuid/00000000-0000-4000-8000-000000000000").touch()
        self.image_dir = self.tmp / "image"
        self.image_dir.mkdir()
        self.image = self.image_dir / "debian-13-genericcloud-amd64.qcow2"
        self.image.write_bytes(b"not really a qcow2")
        digest = hashlib.sha512(self.image.read_bytes()).hexdigest()
        (self.image_dir / "SHA512SUMS").write_text(f"{digest}  debian-13-genericcloud-amd64.qcow2\n")
        self.pin = self.tmp / "pin.sha512"
        self.pin.write_text(f"{digest}  debian-13-genericcloud-amd64.qcow2\n")
        self.key = self.tmp / "admin.pub"
        self.key.write_text(KEY + "\n")
        self.cgroup = self.tmp / "cgroup/machine.slice"
        self.cgroup.mkdir(parents=True)
        self.set_memory(current=2 * GIB)
        self.topic = self.tmp / "topic"
        self.topic.write_text("testTopicNotReal_0123456789abcdef\n")
        self.tty = self.tmp / "tty"
        self.evidence = self.tmp / "evidence"
        other_xml = ("<domain type='kvm'><name>W10C-Testing</name><uuid>11111111-1111-4111-8111-111111111111</uuid>"
                     "<memory unit='KiB'>12582912</memory><vcpu>10</vcpu><cputune><vcpupin vcpu='0' cpuset='8'/>"
                     "<emulatorpin cpuset='8-12,24-28'/></cputune><os><type>hvm</type></os><devices/></domain>")
        self.state = {
            "domains": {"W10C-Testing": {"state": "shut off", "uuid": "11111111-1111-4111-8111-111111111111",
                                         "xml": other_xml, "kib": 12582912},
                        "demo": {"state": "shut off", "uuid": "22222222-2222-4222-8222-222222222222",
                                 "xml": other_xml.replace("W10C-Testing", "demo")}},
            "networks": {"default": {"xml": "<network><name>default</name><bridge name='virbr0'/></network>",
                                     "active": True, "autostart": True}},
            "pools": {"default": {"state": "running", "vols": ["W10C-Testing.qcow2", "demo.qcow2"]}},
            "ufw": [{"text": "allow in on virbr0 to 192.168.122.1 port 22 proto tcp", "comment": ""},
                    {"text": "allow 1714:1764/tcp", "comment": ""}]
                   + [{"text": PLANNER_TEXT[c], "comment": c} for c in PLANNER],
            "nft": {"ip libvirt_network": "table ip libvirt_network {}"},
            "units": {"sshd.service": {"enabled": "enabled", "active": "active", "MainPID": "600"},
                      "libvirtd.service": {"enabled": "enabled", "active": "active"},
                      "docker.service": {"enabled": "enabled", "active": "inactive"}},
            "mounted": True,
        }
        self.save_state()

    def set_memory(self, current, high=int(22.5 * GIB)):
        (self.cgroup / "memory.current").write_text(f"{current}\n")
        (self.cgroup / "memory.high").write_text(f"{high}\n")
        (self.cgroup / "memory.max").write_text(f"{int(23.5 * GIB)}\n")

    def save_state(self):
        (self.stubs / "state.json").write_text(json.dumps(self.state))

    def load_state(self):
        self.state = json.loads((self.stubs / "state.json").read_text())
        return self.state

    def calls(self):
        log = self.stubs / "calls.log"
        return [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []

    def reset_calls(self):
        (self.stubs / "calls.log").unlink(missing_ok=True)

    def own(self, path, uid, gid, mode=0o700):
        """Record (test overlay) that path is owned by uid:gid with mode."""
        data = json.loads(self.owners.read_text()) if self.owners.exists() else {}
        data[str(path)] = [uid, gid, mode]
        self.owners.write_text(json.dumps(data))

    def owner(self, path):
        data = json.loads(self.owners.read_text()) if self.owners.exists() else {}
        return data.get(str(path))

    def add_account(self, uid=961):
        with (self.root / "etc/passwd").open("a") as stream:
            stream.write(f"anj-cloud-backup:x:{uid}:{uid}::/:/usr/bin/nologin\n")

    def install_wrapper(self):
        """What step 6 of an operator apply leaves: the wrapper and the anjvm.py it imports."""
        lib = self.root / "usr/local/lib/anj-cloud-host"
        lib.mkdir(parents=True, exist_ok=True)
        for name in ("virtiofsd-anj-cloud", "anjvm.py"):
            shutil.copy(HOST / name, lib / name)

    def qual_dir(self):
        path = self.root / HOME.lstrip("/") / ".local/share/anj-cloud/qualification"
        path.mkdir(parents=True, exist_ok=True)
        return path

    def tag_file(self):
        return self.root / HOME.lstrip("/") / ".local/state/anj-cloud-qual/run-id"

    def env(self, root=True, extra=None):
        environment = {"PATH": f"{self.stubs}:/usr/bin:/bin", "HOME": HOME, "LANG": "C",
                       "ANJ_HOST_ROOT": str(self.root), "ANJ_HOST_STUBS": str(self.stubs),
                       "ANJ_HOST_TTY": str(self.tty), "ANJ_HOST_TOPIC_INPUT": str(self.topic),
                       "ANJ_HOST_IMAGE_PIN": str(self.pin), "ANJ_CGROUP_ROOT": str(self.cgroup.parent),
                       "ANJ_QUAL_SSH_TIMEOUT": "5", "ANJ_HOST_TEST_OWNERS": str(self.owners),
                       "ANJ_PROFILE": str(HOST.parent / "profile.example.toml")}
        if root:
            environment.update(ANJ_HOST_FAKE_ROOT="1", SUDO_USER=USER)
        environment.update(extra or {})
        return environment

    def argv(self, *args):
        return ["bash", str(SCRIPT), *args, "--image", str(self.image), "--key", str(self.key),
                "--evidence-dir", str(self.evidence)]

    def popen(self, *args, root=False):
        return subprocess.Popen(self.argv(*args), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                                env=self.env(root))

    def run(self, *args, answers=("yes",) * 6, root=True, env=None):
        self.tty.write_text("".join(a + "\n" for a in answers))
        result = subprocess.run(self.argv(*args), capture_output=True, text=True, env=self.env(root, env), timeout=300)
        self.output = result.stdout + result.stderr
        return result

    def summary(self):
        runs = sorted(self.evidence.glob("f15-vm-host-*"))
        return json.loads((runs[-1] / "summary.json").read_text()), runs[-1]

    def tree(self):
        rows = {}
        for path in sorted(self.root.rglob("*")):
            key = str(path.relative_to(self.root))
            rows[key] = (oct(path.stat().st_mode), path.read_bytes() if path.is_file() else b"")
        return rows

    def manifest(self):
        path = self.root / "etc/anj-cloud-host/manifest"
        return [line.split("\t") for line in path.read_text().splitlines()] if path.exists() else []

    def close(self):
        shutil.rmtree(self.tmp, ignore_errors=True)


class HaloVmTests(unittest.TestCase):
    def setUp(self):
        self.h = Harness()
        self.addCleanup(self.h.close)

    def assertOthersUntouched(self):
        for call in self.h.calls():
            if call[0] == "virsh":
                args = virsh_command(call)
                if args[0] in MUTATING_VIRSH:
                    targets = [a for a in args[1:] if not a.startswith("--") and not a.startswith("/")
                               and not a.endswith(("G", ".xml")) and not a.isdigit() and a not in ("raw", "qcow2")]
                    self.assertTrue(set(targets) <= OURS, call)
            if call[0] == "systemctl" and len(call) > 1 and call[1] in MUTATING_SYSTEMCTL:
                names = [a for a in call[2:] if not a.startswith("-")]
                self.assertTrue(all(n.startswith(("anj-cloud-", "mnt-anj")) for n in names), call)
            if call[0] == "ufw" and call[1:2] != ["status"]:
                self.assertNotIn(call[1], ("enable", "disable", "reload", "reset"))
                if call[1:3] != ["--force", "delete"]:
                    self.assertIn("comment", call)
                    self.assertTrue(call[call.index("comment") + 1].startswith(("anj-cloud-vm", "anj-cloud-qual")), call)
            if call[0] == "sshd":
                self.assertEqual(call[1:], ["-T"])

    def test_dry_run_changes_nothing(self):
        before = self.h.tree()
        result = self.h.run("--dry-run")
        self.assertEqual(result.returncode, 0, self.h.output)
        self.assertEqual(mutating(self.h.calls()), [])
        self.assertEqual(before, self.h.tree())
        summary, run = self.h.summary()
        self.assertTrue(summary["pass"], self.h.output)
        self.assertEqual({s["step"] for s in summary["steps"]}, set(range(1, 9)))
        self.assertTrue((run / "others-before.txt").exists())
        text = "".join(p.read_text() for p in run.rglob("*") if p.is_file())
        self.assertNotIn("ListenAddress", text)
        self.assertNotIn("testTopicNotReal", text)
        self.assertNotIn("AAAAC3NzaC1lZDI1NTE5AAAAIFake", text)

    def test_apply_fresh_then_idempotent_then_verify(self):
        result = self.h.run("--apply")
        self.assertEqual(result.returncode, 0, self.h.output)
        summary, _ = self.h.summary()
        self.assertTrue(summary["pass"], self.h.output)
        self.assertTrue(summary["others_untouched"]["pass"], summary["others_untouched"])
        self.assertOthersUntouched()
        state = self.h.load_state()
        prod = state["domains"]["anj-prod"]
        self.assertEqual(prod["state"], "running")
        self.assertFalse(prod["autostart"])
        # vm-start (the stub's anj-cloud-vm start) attached the share: owned by the account, 0700.
        expected = subprocess.run([sys.executable, str(HOST / "anjvm.py"), "render-domain", "anj-prod", "--uuid",
                                   prod["uuid"], "--share", "/mnt/anj-backup/anj-cloud-prod"],
                                  capture_output=True, text=True, check=True).stdout
        (self.h.tmp / "e.xml").write_text(expected)
        (self.h.tmp / "a.xml").write_text(prod["xml"])
        diff = subprocess.run([sys.executable, str(HOST / "anjvm.py"), "compare-domain", str(self.h.tmp / "e.xml"),
                               str(self.h.tmp / "a.xml")], capture_output=True, text=True)
        self.assertEqual(diff.returncode, 0, diff.stdout)
        self.assertEqual(sorted(state["pools"]["anj-prod"]["vols"]),
                         ["anj-prod-data.qcow2", "anj-prod-os.qcow2", "anj-prod-seed.iso"])
        self.assertIn("ip anj_cloud_fwd", state["nft"])
        self.assertIn("dnat to 10.77.10.10:443", state["nft"]["ip anj_cloud_fwd"])
        self.assertNotIn("masquerade", state["nft"]["ip anj_cloud_fwd"])
        comments = [r["comment"] for r in state["ufw"]]
        for wanted in ("anj-cloud-vm inbound 443", "anj-cloud-vm router dns", "anj-cloud-vm egress",
                       "anj-cloud-vm no LAN 192.168.0.0/16", "anj-cloud-vm dhcp", "anj-cloud-vm dns udp",
                       "anj-cloud-vm dns tcp", "anj-cloud-vm bridge deny"):
            self.assertIn(wanted, comments)
        self.assertFalse([c for c in comments if c.startswith("anj-prod ")])  # planner rules adopted
        self.assertNotIn("anj-cloud-vm no host", comments)
        deny = [r for r in state["ufw"] if r["comment"] == "anj-cloud-vm bridge deny"][0]
        self.assertEqual(deny["text"], "deny in on virbr-anjprod")
        for allow in ("anj-cloud-vm dhcp", "anj-cloud-vm dns udp", "anj-cloud-vm dns tcp"):
            self.assertLess(comments.index(allow), comments.index("anj-cloud-vm bridge deny"), allow)
        dns = [r["text"] for r in state["ufw"] if r["comment"] == "anj-cloud-vm dns udp"][0]
        self.assertIn("to 10.77.10.1 port 53 proto udp", dns)
        sudoers = self.h.root / "etc/sudoers.d/anj-cloud-host-alert"
        self.assertEqual(oct(sudoers.stat().st_mode & 0o777), "0o440")
        self.assertIn(f"{USER} ALL=(root) NOPASSWD: /usr/local/lib/anj-cloud-host/anj-alert\n", sudoers.read_text())
        self.assertEqual(sum(1 for line in sudoers.read_text().splitlines() if "NOPASSWD" in line), 1)
        order = [r["comment"] for r in state["ufw"]]
        self.assertLess(order.index("anj-cloud-vm router dns"), order.index("anj-cloud-vm no LAN 192.168.0.0/16"))
        self.assertLess(order.index("anj-cloud-vm no LAN 192.168.0.0/16"), order.index("anj-cloud-vm egress"))
        for name in ("anj-cloud-vm.service", "anj-cloud-vm-stop.service", "anj-cloud-forward.service",
                     "anj-cloud-host-boot.timer", "anj-cloud-host-watchdog.timer", "mnt-anj\\x2dbackup.mount"):
            self.assertEqual(state["units"][name]["enabled"], "enabled", name)
        self.assertNotEqual(state["units"]["anj-cloud-host-boot.timer"]["active"], "active")
        self.assertTrue((self.h.root / "etc/hosts").read_text().endswith(
            "192.168.0.10 gateway.example.com # anj-cloud\n"))
        topic = self.h.root / "etc/anj-cloud-host/ntfy-topic"
        self.assertEqual(oct(topic.stat().st_mode & 0o777), "0o600")
        self.assertTrue((self.h.root / "mnt/anj-backup/anj-cloud-prod").is_dir())
        for row in self.h.manifest():
            if row[1] == "file":
                self.assertTrue("anj-cloud" in row[2] or row[2].endswith("mnt-anj\\x2dbackup.mount"), row)
                self.assertTrue((self.h.root / row[2].lstrip("/")).exists(), row)

        self.h.reset_calls()
        before = self.h.tree()
        self.assertEqual(self.h.run("--apply").returncode, 0, self.h.output)
        self.assertEqual(mutating(self.h.calls()), [])
        changed = {k for k in set(before) | set(self.h.tree()) if before.get(k) != self.h.tree().get(k)}
        self.assertTrue(changed <= {"var/lib/anj-cloud-host/anj-cloud-others-before.txt"}, changed)

        self.h.reset_calls()
        result = self.h.run("--verify")
        self.assertEqual(mutating(self.h.calls()), [])
        summary, _ = self.h.summary()
        statuses = {s["step"]: s["status"] for s in summary["steps"]}
        self.assertTrue(all(v == "pass" for v in statuses.values()), (statuses, self.h.output))

    def fail_on(self, command, word):
        self.h.load_state()
        self.h.state.setdefault("fail", []).append([command, word])
        self.h.save_state()

    def test_failed_network_define_fails_the_run(self):
        self.fail_on("virsh", "net-define")
        result = self.h.run("--apply")
        self.assertEqual(result.returncode, 1, self.h.output)
        summary, _ = self.h.summary()
        self.assertFalse(summary["pass"])
        self.assertEqual(summary["stopped_at"], "2")
        failed = [s for s in summary["steps"] if s["status"] == "fail"]
        self.assertEqual(failed[0]["step"], 2)
        self.assertIn("command failed: V net-define", failed[0]["detail"])
        self.assertNotIn("anj-prod", self.h.load_state()["networks"])
        self.assertFalse([s for s in summary["steps"] if s["step"] > 2 and s["status"] in ("pass", "changed")])

    def test_failed_enable_fails_the_run(self):
        self.fail_on("systemctl", "enable")
        result = self.h.run("--apply")
        self.assertEqual(result.returncode, 1, self.h.output)
        summary, _ = self.h.summary()
        self.assertFalse(summary["pass"])
        self.assertTrue([s for s in summary["steps"] if s["status"] == "fail" and "systemctl enable" in s["detail"]])

    def test_failed_disk_upload_in_recreate_stops_before_define_and_cleans_up(self):
        self.h.run("--apply")
        self.fail_on("virsh", "vol-upload")
        self.h.reset_calls()
        result = self.h.run("--recreate", "--confirm", "anj-prod")
        self.assertEqual(result.returncode, 1, self.h.output)
        calls = [virsh_command(c) for c in self.h.calls() if c[0] == "virsh"]
        upload = next(i for i, c in enumerate(calls) if c[0] == "vol-upload")
        self.assertFalse([c for c in calls[upload:] if c[0] in ("define", "start")])
        state = self.h.load_state()
        self.assertNotIn("anj-prod", state["domains"])
        self.assertEqual(state["pools"]["anj-prod"]["vols"], [])
        summary, _ = self.h.summary()
        self.assertFalse(summary["pass"])
        self.assertIn("vol-upload", [s for s in summary["steps"] if s["status"] == "fail"][0]["detail"])

    def test_visudo_rejection_fails_step_8_and_installs_nothing(self):
        self.h.state["visudo_rc"] = 1
        self.h.save_state()
        self.assertEqual(self.h.run("--apply").returncode, 1, self.h.output)
        summary, _ = self.h.summary()
        self.assertEqual(summary["stopped_at"], "8")
        self.assertFalse((self.h.root / "etc/sudoers.d/anj-cloud-host-alert").exists())

    def test_image_reverified_before_upload_under_only_domain(self):
        self.h.image.write_bytes(b"tampered after review")
        self.h.reset_calls()
        self.assertNotEqual(self.h.run("--apply", "--only", "domain").returncode, 0)
        self.assertFalse([c for c in self.h.calls() if c[0] == "virsh" and virsh_command(c)[0] == "vol-upload"])
        self.assertFalse(list((self.h.root / "var/tmp").iterdir()))  # the private copy is removed

    def test_dry_run_lists_planner_rules_to_replace(self):
        self.h.run("--dry-run")
        for comment in PLANNER:
            self.assertIn(f"will replace planner-made rule: {comment}", self.h.output)

    def test_unwritable_hosts_file_fails_step_7(self):
        hosts = self.h.root / "etc/hosts"
        hosts.chmod(0o444)
        self.addCleanup(hosts.chmod, 0o644)
        self.assertEqual(self.h.run("--apply").returncode, 1, self.h.output)
        summary, _ = self.h.summary()
        self.assertEqual(summary["stopped_at"], "7")
        self.assertIn("cannot write /etc/hosts", [s for s in summary["steps"] if s["status"] == "fail"][0]["detail"])
        self.assertNotIn("anj-cloud", hosts.read_text())

    def test_unwritable_topic_path_fails_step_8(self):
        (self.h.root / "etc/anj-cloud-host/ntfy-topic").mkdir(parents=True)  # a directory where the file goes
        self.assertEqual(self.h.run("--apply").returncode, 1, self.h.output)
        summary, _ = self.h.summary()
        self.assertEqual(summary["stopped_at"], "8")
        self.assertFalse(summary["pass"])

    def planner_state(self):
        state = self.h.load_state()
        return {r["comment"] for r in state["ufw"] if r["comment"].startswith("anj-prod ")}

    def test_planner_route_rules_survive_a_run_that_stops_at_step_3(self):
        self.h.run("--apply")
        state = self.h.load_state()
        state["ufw"] = [r for r in state["ufw"] if not r["comment"].startswith("anj-cloud-vm")]
        state["ufw"] += [{"text": PLANNER_TEXT[c], "comment": c} for c in PLANNER]
        state["domains"]["anj-prod"]["xml"] = state["domains"]["anj-prod"]["xml"].replace(
            "<memballoon model='none'/>", "<memballoon model='virtio'/>")
        self.h.state = state
        self.h.save_state()
        self.assertNotEqual(self.h.run("--apply").returncode, 0)
        summary, _ = self.h.summary()
        self.assertEqual(summary["stopped_at"], "3")
        remaining = self.planner_state()
        self.assertEqual(remaining, set(PLANNER[3:]))  # route rules untouched until step 5
        comments = {r["comment"] for r in self.h.load_state()["ufw"]}
        self.assertTrue({"anj-cloud-vm dhcp", "anj-cloud-vm dns udp", "anj-cloud-vm dns tcp"} <= comments)
        self.h.reset_calls()
        self.assertEqual(self.h.run("--recreate", "--confirm", "anj-prod").returncode, 0, self.h.output)
        self.assertEqual(self.planner_state(), set(PLANNER[3:]))  # recreate (steps 1-3) leaves them too

    def assertSafe(self, label):
        """First-match evaluation of the stub ruleset: the VM never reaches the LAN, and keeps DHCP,
        DNS to the bridge address and internet egress (so no adopted rule is missing)."""
        rules = self.h.load_state()["ufw"]
        for lan in ("192.168.0.50", "10.0.0.5", "172.16.0.5"):
            verdict = first_match(rules, route=True, src="10.77.10.10", dst=lan, proto="tcp", dport="80")
            self.assertEqual(verdict[0], "deny", (label, lan, verdict, rules))
        verdict = first_match(rules, route=True, src="10.77.10.10", dst="1.1.1.1", proto="tcp", dport="443")
        self.assertEqual(verdict[0], "allow", (label, "egress", verdict, rules))
        for proto, src, dst, sport, dport in (("udp", "0.0.0.0", "255.255.255.255", "68", "67"),
                                              ("udp", "10.77.10.10", "10.77.10.1", "40000", "53"),
                                              ("tcp", "10.77.10.10", "10.77.10.1", "40000", "53")):
            verdict = first_match(rules, route=False, src=src, dst=dst, proto=proto, sport=sport, dport=dport)
            self.assertEqual(verdict[0], "allow", (label, proto, dport, verdict, rules))

    def test_every_ufw_failure_point_in_steps_2_and_5_leaves_a_safe_rule_set(self):
        self.assertSafe("before")
        self.h.state["fail_nth_ufw"] = 10 ** 6  # count only
        self.h.save_state()
        self.assertEqual(self.h.run("--apply").returncode, 0, self.h.output)
        total = self.h.load_state()["ufw_calls"]
        self.assertSafe("after a full apply")
        self.assertGreaterEqual(total, 10)
        for n in range(1, total + 1):
            with self.subTest(failing_ufw_call=n):
                h = Harness()
                try:
                    self.h, outer = h, self.h
                    h.state["fail_nth_ufw"] = n
                    h.save_state()
                    result = h.run("--apply")
                    self.assertEqual(result.returncode, 1, h.output)
                    self.assertIn(h.summary()[0]["stopped_at"], ("2", "5"))
                    self.assertNotIn("UNSAFE UFW ORDER", h.output)
                    self.assertSafe(f"ufw call {n} failed")
                finally:
                    self.h = outer
                    h.close()

    def test_signal_mid_step_restores_a_safe_rule_set(self):
        self.h.state["ufw_delay"] = ["anj-cloud-vm bridge deny", 3]
        self.h.save_state()
        proc = self.h.popen("--apply", root=True)
        import time
        deadline = time.time() + 120
        while time.time() < deadline:
            if any(c[0] == "ufw" and "anj-cloud-vm bridge deny" in c for c in self.h.calls()):
                break
            time.sleep(0.1)
        proc.send_signal(15)
        output = proc.communicate(timeout=120)[0]
        self.assertEqual(proc.returncode, 1, output)
        self.assertIn("interrupted by SIGTERM", output)
        self.assertIn("restoring ufw rule", output)
        self.assertSafe("SIGTERM during the bridge deny")

    def test_rollback_5_keeps_the_forward_off_flag(self):
        self.h.run("--apply")
        self.assertEqual(self.h.run("--forward", "off").returncode, 0, self.h.output)
        self.assertEqual(self.h.run("--rollback", "5").returncode, 0, self.h.output)
        self.assertTrue((self.h.root / "etc/anj-cloud-host/forward-off").exists())
        self.assertFalse([r for r in self.h.manifest() if r[2].endswith("forward-off")])

    def test_step_8_verify_needs_sudo_to_honour_the_drop_in(self):
        self.h.run("--apply")
        self.h.state = self.h.load_state()
        self.h.state["sudo_l_rc"] = 1
        self.h.save_state()
        self.assertNotEqual(self.h.run("--verify").returncode, 0)
        summary, _ = self.h.summary()
        step8 = [s for s in summary["steps"] if s["step"] == 8][0]
        self.assertEqual(step8["status"], "fail")
        self.assertIn("sudo does not grant", step8["detail"])

    def test_existing_domain_that_differs_is_never_redefined(self):
        self.h.run("--apply")
        state = self.h.load_state()
        state["domains"]["anj-prod"]["xml"] = state["domains"]["anj-prod"]["xml"].replace(
            "<memballoon model='none'/>", "<memballoon model='virtio'/>")
        self.h.state = state
        self.h.save_state()
        self.h.reset_calls()
        self.assertNotEqual(self.h.run("--apply").returncode, 0)
        summary, _ = self.h.summary()
        self.assertEqual(summary["stopped_at"], "3")
        self.assertFalse([c for c in self.h.calls() if c[0] == "virsh" and virsh_command(c)[0] in ("define", "undefine")])
        self.assertIn("memballoon", self.h.output)

    def test_recreate_requires_confirm_and_touches_only_anj_prod(self):
        self.h.run("--apply")
        self.assertEqual(self.h.run("--recreate").returncode, 2)
        self.assertIn("--confirm anj-prod", self.h.output)
        old_uuid = self.h.load_state()["domains"]["anj-prod"]["uuid"]
        self.h.reset_calls()
        self.assertEqual(self.h.run("--recreate", "--confirm", "anj-prod").returncode, 0, self.h.output)
        state = self.h.load_state()
        self.assertNotEqual(state["domains"]["anj-prod"]["uuid"], old_uuid)
        self.assertEqual(state["domains"]["anj-prod"]["state"], "running")
        self.assertEqual(state["pools"]["default"]["vols"], ["W10C-Testing.qcow2", "demo.qcow2"])
        deleted = [virsh_command(c)[-1] for c in self.h.calls() if c[0] == "virsh" and virsh_command(c)[0] == "vol-delete"]
        self.assertEqual(sorted(deleted), ["anj-prod-data.qcow2", "anj-prod-os.qcow2", "anj-prod-seed.iso"])
        self.assertOthersUntouched()

    def test_recreate_os_keeps_the_data_disk(self):
        self.h.run("--apply")
        self.h.reset_calls()
        self.assertEqual(self.h.run("--recreate-os").returncode, 0, self.h.output)
        deleted = [virsh_command(c)[-1] for c in self.h.calls() if c[0] == "virsh" and virsh_command(c)[0] == "vol-delete"]
        self.assertEqual(sorted(deleted), ["anj-prod-os.qcow2", "anj-prod-seed.iso"])
        self.assertIn("anj-prod-data.qcow2", self.h.load_state()["pools"]["anj-prod"]["vols"])

    def test_rollback_steps(self):
        original = (self.h.root / "etc/hosts").read_text()
        self.h.run("--apply")
        for step in (8, 7, 6, 5, 4):
            self.assertEqual(self.h.run("--rollback", str(step)).returncode, 0, self.h.output)
        self.assertEqual((self.h.root / "etc/hosts").read_text(), original)
        state = self.h.load_state()
        self.assertNotIn("ip anj_cloud_fwd", state["nft"])
        self.assertFalse([r for r in state["ufw"] if r["comment"].startswith("anj-cloud-vm") and r["comment"] not in
                          ("anj-cloud-vm dhcp", "anj-cloud-vm dns udp", "anj-cloud-vm dns tcp", "anj-cloud-vm bridge deny")])
        self.assertFalse((self.h.root / "etc/sudoers.d/anj-cloud-host-alert").exists())
        self.assertEqual([r for r in self.h.manifest() if r[0] in ("4", "5", "6", "7", "8") and r[1] == "file"], [])
        self.assertTrue((self.h.root / "mnt/anj-backup/anj-cloud-prod").is_dir())  # data dir kept
        self.assertEqual(state["domains"]["anj-prod"]["state"], "running")  # rollback never stops the VM

    def test_open_mode_adds_masquerade(self):
        self.assertEqual(self.h.run("--apply", "--net-mode", "open").returncode, 0, self.h.output)
        state = self.h.load_state()
        self.assertIn("masquerade", state["nft"]["ip anj_cloud_fwd"])
        self.assertIn("<forward mode='open'/>", state["networks"]["anj-prod"]["xml"])

    def test_forward_off_and_on(self):
        self.h.run("--apply")
        self.assertEqual(self.h.run("--forward", "off").returncode, 0, self.h.output)
        state = self.h.load_state()
        self.assertNotIn("ip anj_cloud_fwd", state["nft"])
        self.assertEqual(state["units"]["anj-cloud-forward.service"]["enabled"], "disabled")
        self.assertTrue((self.h.root / "etc/anj-cloud-host/forward-off").exists())
        unit = (self.h.root / "etc/systemd/system/anj-cloud-forward.service").read_text()
        self.assertIn("ConditionPathExists=!/etc/anj-cloud-host/forward-off", unit)
        # A start from anywhere (reboot, the VM unit's Wants=) is skipped by the condition.
        subprocess.run([str(self.h.stubs / "systemctl"), "start", "anj-cloud-forward.service"], env=self.h.env(), check=True)
        self.assertNotIn("ip anj_cloud_fwd", self.h.load_state()["nft"])
        self.assertEqual(self.h.run("--apply").returncode, 0, self.h.output)
        state = self.h.load_state()
        self.assertNotIn("ip anj_cloud_fwd", state["nft"])  # apply respects the emergency stop
        self.assertEqual(state["units"]["anj-cloud-forward.service"]["enabled"], "disabled")
        self.assertEqual(self.h.run("--forward", "on").returncode, 0, self.h.output)
        state = self.h.load_state()
        self.assertIn("ip anj_cloud_fwd", state["nft"])
        self.assertEqual(state["units"]["anj-cloud-forward.service"]["enabled"], "enabled")

    def test_preflight_refusals(self):
        self.h.state["domains"]["W10C-Testing"]["xml"] = self.h.state["domains"]["W10C-Testing"]["xml"].replace(
            "cpuset='8'", "cpuset='14'")
        self.h.save_state()
        self.assertNotEqual(self.h.run("--apply").returncode, 0)
        self.assertIn("threads 14,30,15,31 pinned by another domain", self.h.output)
        self.h.state["domains"]["W10C-Testing"]["xml"] = self.h.state["domains"]["W10C-Testing"]["xml"].replace(
            "cpuset='14'", "cpuset='8'")
        self.h.save_state()
        self.h.image.write_bytes(b"tampered")
        self.assertNotEqual(self.h.run("--apply").returncode, 0)
        self.assertIn("Debian image not verified", self.h.output)
        self.assertFalse([c for c in self.h.calls() if c[0] == "virsh" and virsh_command(c)[0] in MUTATING_VIRSH])

    def test_privilege_and_host_refusals(self):
        self.assertEqual(self.h.run("--apply", root=False).returncode, 2)
        self.assertIn("needs sudo", self.h.output)
        self.h.state["hostname"] = "laptop"
        self.h.save_state()
        self.assertEqual(self.h.run("--dry-run").returncode, 2)
        environment = dict(os.environ, ANJ_HOST_ROOT=str(self.h.root))
        result = subprocess.run(["bash", str(SCRIPT), "--dry-run"], capture_output=True, text=True, env=environment)
        self.assertIn("test harness pair", result.stdout + result.stderr)

    SHARE = "mnt/anj-backup/anj-cloud-prod"

    def step(self, number):
        summary, _ = self.h.summary()
        return [s for s in summary["steps"] if s["step"] == number]

    def test_step_4_account_share_and_verify(self):
        self.assertEqual(self.h.run("--apply").returncode, 0, self.h.output)
        passwd = (self.h.root / "etc/passwd").read_text()
        self.assertIn("anj-cloud-backup:x:961:961:", passwd)
        self.assertTrue(passwd.rstrip().endswith("/usr/bin/nologin"))
        self.assertEqual(self.h.owner(self.h.root / self.SHARE), [961, 961, 0o700])
        sysusers = self.h.root / "etc/sysusers.d/anj-cloud-backup.conf"
        self.assertEqual(sysusers.read_text(), (HOST / "units/anj-cloud-backup.sysusers").read_text())
        self.assertIn(["4", "account", "anj-cloud-backup"], self.h.manifest())
        self.assertIn(["4", "file", "/etc/sysusers.d/anj-cloud-backup.conf"], self.h.manifest())
        self.assertIn(["6", "file", "/usr/local/lib/anj-cloud-host/virtiofsd-anj-cloud"], self.h.manifest())
        self.assertIn("account anj-cloud-backup 961:961", self.h.output)
        self.assertEqual(self.h.run("--verify", "--only", "backup-share").returncode, 0, self.h.output)
        [row] = self.step(4)
        self.assertEqual(row["status"], "pass", row)
        self.assertIn("running virtiofsd maps guest 1000 to 961:961", row["detail"])
        self.assertIn('{"read": false, "write": false}', row["detail"])
        # uid 1000 able to write, a stale wrapper, or a running virtiofsd without the mapping: verify fails.
        for breakage in ("mode", "wrapper", "proc"):
            if breakage == "mode":
                self.h.own(self.h.root / self.SHARE, 961, 961, 0o777)
            elif breakage == "wrapper":
                (self.h.root / "usr/local/lib/anj-cloud-host/virtiofsd-anj-cloud").write_text("#!/bin/sh\n")
            else:
                (self.h.root / "proc/4242/cmdline").write_bytes(b"/usr/lib/virtiofsd\0--shared-dir\0/mnt/anj-backup/anj-cloud-prod\0")
            self.assertEqual(self.h.run("--verify", "--only", "backup-share").returncode, 1, breakage)
            [row] = self.step(4)
            self.assertEqual(row["status"], "fail", breakage)
            self.assertIn({"mode": "The VM host uid can reach the share", "wrapper": "differs from this checkout",
                           "proc": "does not map guest 1000"}[breakage], row["detail"])
            self.assertEqual(self.h.run("--apply").returncode, 0, self.h.output)  # apply repairs mode and wrapper
            if breakage == "proc":   # only the cold restart brings the mapped virtiofsd back
                self.cold_restart()

    def systemctl(self, *args):
        subprocess.run(["systemctl", *args], env=self.h.env(), check=True, capture_output=True)

    def cold_restart(self):
        self.systemctl("stop", "anj-cloud-vm-stop.service")
        self.assertEqual(self.h.load_state()["domains"]["anj-prod"]["state"], "shut off")
        self.systemctl("restart", "anj-cloud-vm.service")
        self.systemctl("start", "anj-cloud-vm-stop.service")

    def test_migration_of_todays_root_owned_share(self):
        # The VM host today: a compliant anj-prod running with the share served by the bare virtiofsd, the
        # share root:root 0750 and empty, no account.
        self.assertEqual(self.h.run("--apply").returncode, 0, self.h.output)
        lines = (self.h.root / "etc/passwd").read_text().splitlines()
        (self.h.root / "etc/passwd").write_text("".join(f"{line}\n" for line in lines if not line.startswith("anj-cloud-backup:")))
        self.h.own(self.h.root / self.SHARE, 0, 0, 0o750)
        state = self.h.load_state()
        prod = state["domains"]["anj-prod"]
        prod["xml"] = prod["xml"].replace("/usr/local/lib/anj-cloud-host/virtiofsd-anj-cloud", "/usr/lib/virtiofsd")
        self.h.save_state()
        (self.h.root / "proc/4242/cmdline").unlink()
        # The plan shows the account, the re-own and the cold restart, and changes nothing.
        self.h.reset_calls()
        before = self.h.tree()
        self.assertEqual(self.h.run("--dry-run", "--only", "backup-share").returncode, 0, self.h.output)
        self.assertEqual(before, self.h.tree())
        self.assertIn("would run: systemd-sysusers", self.h.output)
        self.assertIn("share-own", self.h.output)
        self.assertIn("0:0 0750 -> anj-cloud-backup 0700", self.h.output)
        self.assertIn("COLD RESTART REQUIRED after this apply (sudo systemctl stop anj-cloud-vm-stop.service; "
                      "sudo systemctl restart anj-cloud-vm.service; sudo systemctl start anj-cloud-vm-stop.service)",
                      self.h.output)
        self.assertEqual(self.h.owner(self.h.root / self.SHARE), [0, 0, 0o750])
        # The apply migrates the empty share and installs the wrapper; the VM is left running.
        self.assertEqual(self.h.run("--apply").returncode, 0, self.h.output)
        self.assertEqual(self.h.owner(self.h.root / self.SHARE), [961, 961, 0o700])
        self.assertEqual(self.h.load_state()["domains"]["anj-prod"]["state"], "running")
        self.assertNotIn(["virsh", "-q", "-c", "qemu:///system", "shutdown", "anj-prod"], self.h.calls())
        self.assertEqual(self.h.run("--verify", "--only", "backup-share").returncode, 1)
        self.assertIn("cold restart", self.step(4)[0]["detail"])
        # A restart without the stop first is a no-op (vm-start: already-running): still failing.
        self.systemctl("restart", "anj-cloud-vm.service")
        self.assertEqual(self.h.run("--verify", "--only", "backup-share").returncode, 1)
        # The operator's cold restart: vm-start switches the definition to the wrapper.
        self.cold_restart()
        self.assertEqual(self.h.run("--verify", "--only", "backup-share").returncode, 0, self.h.output)
        self.assertEqual(self.step(4)[0]["status"], "pass")

    def test_a_share_holding_foreign_data_is_never_reowned(self):
        self.assertEqual(self.h.run("--apply").returncode, 0, self.h.output)
        (self.h.root / self.SHARE / "restic").mkdir()
        self.h.own(self.h.root / self.SHARE, 0, 0, 0o750)
        # Before the account exists, the plan already says it will refuse (as apply does).
        lines = (self.h.root / "etc/passwd").read_text().splitlines()
        (self.h.root / "etc/passwd").write_text("".join(f"{line}\n" for line in lines if not line.startswith("anj-cloud-backup:")))
        self.h.run("--dry-run", "--only", "backup-share")
        self.assertIn("holds data owned by 0:0; not re-owned", self.step(4)[0]["detail"])
        self.assertNotIn("-> anj-cloud-backup 0700", self.h.output)
        self.assertEqual(self.h.run("--apply").returncode, 1, self.h.output)
        [row] = self.step(4)
        self.assertEqual(row["status"], "fail")
        self.assertIn("holds data owned by 0:0; not re-owned", row["detail"])
        self.assertEqual(self.h.owner(self.h.root / self.SHARE), [0, 0, 0o750])
        self.assertTrue((self.h.root / self.SHARE / "restic").is_dir())

    def test_qual_lifecycle_as_agent(self):
        before = self.h.tree()
        result = self.h.run("--qual", "--run-id", "c-drill-1", root=False)
        self.assertEqual(result.returncode, 0, self.h.output)
        self.assertIn("<description>anj-qual run-id=c-drill-1</description>", self.h.load_state()["domains"]["anj-qual"]["xml"])
        ssh_config = (self.h.root / HOME.lstrip("/") / ".local/share/anj-cloud/prod-vm/ssh_config").read_text()
        self.assertIn("Host anj-qual", ssh_config)
        self.assertIn("HostName 10.77.11.10", ssh_config)
        state = self.h.load_state()
        self.assertEqual(state["domains"]["anj-qual"]["state"], "running")
        self.assertIn("anj-qual", state["networks"])
        self.assertNotIn("anj-prod", state["domains"])
        self.assertIn("10.77.11.1", state["networks"]["anj-qual"]["xml"])
        self.assertFalse([c for c in self.h.calls() if c[0] in ("ufw", "nft", "systemctl") and mutating([c])])
        self.h.reset_calls()
        self.assertEqual(self.h.run("--qual", "--run-id", "other", root=False).returncode, 3)
        self.assertIn("qual-busy", self.h.output)
        self.assertEqual(mutating(self.h.calls()), [])
        self.assertEqual(self.h.run("--qual-destroy", "--run-id", "other", root=False).returncode, 3)
        self.assertIn("qual-tag-mismatch", self.h.output)
        self.assertIn("anj-qual", self.h.load_state()["domains"])
        self.assertEqual(self.h.run("--qual-destroy", "--run-id", "c-drill-1", root=False).returncode, 0, self.h.output)
        state = self.h.load_state()
        self.assertNotIn("anj-qual", state["domains"])
        self.assertNotIn("anj-qual", state["networks"])
        self.assertNotIn("anj-qual", state["pools"])
        def outside(tree):
            return {k for k in tree if not k.startswith(("var/lib/libvirt", "home"))}
        self.assertEqual(outside(self.h.tree()), outside(before))  # nothing outside libvirt and the user's files
        self.assertFalse((self.h.root / HOME.lstrip("/") / ".local/state/anj-cloud-qual/run-id").exists())
        self.assertOthersUntouched()

    def test_qual_shares_and_forced_cleanup(self):
        scratch = self.h.qual_dir() / "scratch"
        scratch.mkdir()
        self.h.own(scratch, 160999, 160999)   # one of the user's subuids (anjvm.py scratch-share create)
        self.h.install_wrapper()
        self.h.add_account()
        self.assertEqual(self.h.run("--qual", "--run-id", "a", "--scratch-share", str(scratch), root=False).returncode, 0,
                         self.h.output)
        xml = self.h.load_state()["domains"]["anj-qual"]["xml"]
        self.assertIn(f"<source dir='{scratch}'/>", xml)
        self.assertNotIn("<readonly/>", xml.split("<filesystem")[1])
        self.assertEqual(self.h.run("--qual-destroy", "--force", root=False).returncode, 0, self.h.output)
        (self.h.root / "mnt/anj-backup/anj-cloud-prod").mkdir(parents=True)
        self.h.own(self.h.root / "mnt/anj-backup/anj-cloud-prod", 961, 961)
        self.assertEqual(self.h.run("--qual", "--run-id", "b", "--share-readonly", root=False).returncode, 0, self.h.output)
        self.assertIn("guest 1000:1000 mapped to 961:961", self.h.output)
        xml = self.h.load_state()["domains"]["anj-qual"]["xml"]
        self.assertIn("<source dir='/mnt/anj-backup/anj-cloud-prod'/>", xml)
        self.assertIn("<readonly/>", xml.split("<filesystem")[1])
        self.assertEqual(self.h.run("--qual-destroy", root=False).returncode, 3)  # no run id given: not ours
        self.assertEqual(self.h.run("--qual-destroy", "--run-id", "b", root=False).returncode, 0, self.h.output)

    def test_scratch_share_uses_the_production_ownership_model(self):
        scratch = self.h.qual_dir() / "scratch"
        scratch.mkdir()
        for owner, message in (((os.getuid(), os.getgid(), 0o700), "must not be owned by root, 1000"),
                               ((1000, 1000, 0o700), "must not be owned by root, 1000"),
                               ((0, 0, 0o700), "must not be owned by root, 1000"),
                               ((160999, 160999, 0o750), "mode 0700"),
                               ((5000, 5000, 0o700), "subuids/subgids or by anj-cloud-backup")):
            self.h.own(scratch, *owner)
            self.h.reset_calls()
            result = self.h.run("--qual", "--run-id", "x", "--scratch-share", str(scratch), root=False)
            self.assertEqual(result.returncode, 2, (owner, self.h.output))
            self.assertIn(message, self.h.output, owner)
            self.assertEqual(mutating(self.h.calls()), [], owner)
        # A good owner but no root-installed wrapper (no operator apply yet): refused before anything is made.
        self.h.own(scratch, 160999, 160999)
        self.assertEqual(self.h.run("--qual", "--run-id", "x", "--scratch-share", str(scratch), root=False).returncode, 1)
        self.assertIn("virtiofsd-anj-cloud (and its anjvm.py) installed", self.h.output)
        self.assertNotIn("anj-qual", self.h.load_state()["domains"])
        self.h.install_wrapper()
        self.assertEqual(self.h.run("--qual", "--run-id", "x", "--scratch-share", str(scratch), root=False).returncode, 0,
                         self.h.output)
        xml = self.h.load_state()["domains"]["anj-qual"]["xml"]
        self.assertIn("<binary path='/usr/local/lib/anj-cloud-host/virtiofsd-anj-cloud'/>", xml)
        self.assertIn("guest 1000:1000 mapped to 160999:160999", self.h.output)
        self.assertEqual(self.h.run("--qual-destroy", "--run-id", "x", root=False).returncode, 0, self.h.output)
        # --share-readonly needs the production share already under the account.
        (self.h.root / "mnt/anj-backup/anj-cloud-prod").mkdir(parents=True)
        self.h.own(self.h.root / "mnt/anj-backup/anj-cloud-prod", 0, 0, 0o750)
        self.assertEqual(self.h.run("--qual", "--run-id", "y", "--share-readonly", root=False).returncode, 1)
        self.assertIn("owned by anj-cloud-backup, 0700", self.h.output)

    def test_scratch_share_confined(self):
        base = self.h.qual_dir()
        (base / "real").mkdir()
        (base / "link").symlink_to(base / "real")
        outside = self.h.tmp / "outside"
        outside.mkdir()
        for path in (str(outside), "/etc", str(base / "link"), str(base / "missing"), "relative/dir", str(base)):
            self.h.reset_calls()
            result = self.h.run("--qual", "--run-id", "x", "--scratch-share", path, root=False)
            self.assertEqual(result.returncode, 2, (path, self.h.output))
            self.assertEqual(mutating(self.h.calls()), [], path)
        self.assertNotIn("anj-qual", self.h.load_state()["domains"])

    def test_qual_argument_rules(self):
        self.assertEqual(self.h.run("--qual", root=False).returncode, 2)
        self.assertIn("--run-id", self.h.output)
        self.assertEqual(self.h.run("--qual", "--run-id", "r", root=True).returncode, 2)
        self.assertIn("never as root", self.h.output)
        self.assertEqual(self.h.run("--qual-destroy", "--force", root=True).returncode, 2)
        for combo in (("--apply", "--dry-run"), ("--recreate", "--confirm", "anj-prod", "--apply"), ("--qual", "--verify"),
                      ("--qual", "--qual-destroy", "--run-id", "r")):
            self.assertEqual(self.h.run(*combo).returncode, 2, combo)
            self.assertIn("choose one mode", self.h.output)

    def test_untagged_qual_needs_force(self):
        self.h.state["domains"]["anj-qual"] = {"state": "running", "uuid": "33333333-3333-4333-8333-333333333333",
                                               "xml": "<domain><name>anj-qual</name></domain>"}
        self.h.save_state()
        self.assertEqual(self.h.run("--qual-destroy", "--run-id", "anything", root=False).returncode, 3)
        self.assertIn("qual-untagged", self.h.output)
        self.assertEqual(self.h.run("--qual-destroy", "--force", root=False).returncode, 0, self.h.output)
        self.assertNotIn("anj-qual", self.h.load_state()["domains"])

    def test_description_is_authoritative_over_the_tag_file(self):
        self.assertEqual(self.h.run("--qual", "--run-id", "owner", root=False).returncode, 0, self.h.output)
        self.h.tag_file().write_text("intruder\n")  # a stale or overwritten tag file
        self.assertEqual(self.h.run("--qual-destroy", "--run-id", "intruder", root=False).returncode, 3)
        self.assertIn("anj-qual", self.h.load_state()["domains"])
        self.assertEqual(self.h.run("--qual-destroy", "--run-id", "owner", root=False).returncode, 0, self.h.output)

    def test_libvirt_listing_failure_means_unknown_and_destroys_nothing(self):
        self.assertEqual(self.h.run("--qual", "--run-id", "owner", root=False).returncode, 0, self.h.output)
        self.fail_on("virsh", "list")  # `virsh list --all --name` fails; lookups still answer
        self.h.reset_calls()
        for args in (("--qual-destroy", "--run-id", "owner"), ("--qual-destroy", "--force"), ("--qual", "--run-id", "x")):
            self.assertEqual(self.h.run(*args, root=False).returncode, 3, args)
            self.assertIn("qual-unknown", self.h.output)
        self.assertEqual(mutating(self.h.calls()), [])
        self.assertIn("anj-qual", self.h.load_state()["domains"])

    def test_concurrent_qual_runs_exactly_one_wins(self):
        self.h.state["virsh_delay"] = 0.2
        self.h.save_state()
        first = self.h.popen("--qual", "--run-id", "run-a")
        second = self.h.popen("--qual", "--run-id", "run-b")
        outputs = [first.communicate(timeout=300)[0], second.communicate(timeout=300)[0]]
        codes = sorted([first.returncode, second.returncode])
        self.assertEqual(codes, [0, 3], outputs)
        winner = "run-a" if first.returncode == 0 else "run-b"
        loser_output = outputs[1] if first.returncode == 0 else outputs[0]
        self.assertIn("qual-busy", loser_output)
        self.assertEqual(self.h.tag_file().read_text().strip(), winner)
        self.assertIn(f"run-id={winner}", self.h.load_state()["domains"]["anj-qual"]["xml"])
        self.assertEqual(self.h.run("--qual-destroy", "--run-id", winner, root=False).returncode, 0, self.h.output)

    def test_qual_refused_below_five_gib_headroom(self):
        self.h.state["domains"]["W10C-Testing"]["state"] = "running"   # 12 GiB at full size
        self.h.state["domains"]["W10C"] = dict(self.h.state["domains"]["demo"], state="running", kib=8 * 1024 * 1024,
                                               xml=self.h.state["domains"]["demo"]["xml"].replace("demo", "W10C"))
        self.h.save_state()
        self.h.set_memory(current=7 * GIB)
        self.assertEqual(self.h.run("--qual", "--run-id", "x", root=False).returncode, 1)
        self.assertIn("headroom below 5 GiB", self.h.output)
        self.assertNotIn("anj-qual", self.h.load_state()["domains"])

    def test_others_untouched_flags_another_domain_change(self):
        self.h.run("--apply")
        self.h.state = self.h.load_state()
        self.h.state["domains"]["demo"]["xml"] = self.h.state["domains"]["demo"]["xml"].replace("<vcpu>10", "<vcpu>2")
        self.h.state["domains"]["W10C-Testing"]["state"] = "running"
        self.h.save_state()
        self.assertNotEqual(self.h.run("--verify").returncode, 0)
        summary, _ = self.h.summary()
        self.assertIn("libvirt.domain.demo", [d["item"] for d in summary["others_untouched"]["differences"]])
        self.assertIn("vm.W10C-Testing", [d["item"] for d in summary["others_untouched"]["confirm"]])


if __name__ == "__main__":
    unittest.main()
