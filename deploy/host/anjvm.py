#!/usr/bin/python3 -I
"""anj-cloud VM objects on the VM host (spec #21 the VM host Host Script; decisions #84, #89).

Renders the libvirt templates in deploy/host/libvirt, builds NoCloud seeds and compares a live
definition with the template by its meaningful facts (memory, backing, pinning, firmware, disks,
interfaces, shares), so an existing domain that differs is reported, never redefined silently.
Standard library only; used by halo-vm.sh and by the root copy of vm-start.

    anjvm.py render-domain <profile> --uuid U [--share DIR [--readonly]]
    anjvm.py render-net <profile> [--mode nat|open]
    anjvm.py render-pool <profile>
    anjvm.py seed <profile> --out DIR --key FILE [--key FILE] [--instance-id ID]
    anjvm.py compare-domain <expected.xml> <actual.xml>
    anjvm.py compare-net <expected.xml> <actual.xml>
    anjvm.py cpus <domain.xml>...           # host threads pinned by these definitions
    anjvm.py headroom [--reserved-kib N]     # bytes left under machine.slice's limit, else host MemAvailable (JSON)
    anjvm.py share-check DIR [--account NAME] [--passwd FILE]   # owner/mode of a backup share (JSON)
    anjvm.py share-own DIR --account NAME [--passwd FILE]       # root: create or migrate it to the account
    anjvm.py share-probe DIR --uid N [--uid N]                  # can these the VM host uids read or write it?
    anjvm.py share-facts <domain.xml>                           # its virtiofs shares (binary, source, tag)
    anjvm.py virtiofsd-args DIR [--proc ROOT]                   # argv of the virtiofsd serving DIR
    anjvm.py scratch-share create|remove DIR                    # agent: a qualification share owned by a subuid
    anjvm.py share-exec DIR -- COMMAND...                       # agent: run COMMAND as the share's owner

Backup share ownership (decision #115): DOS_BACKUP/anj-cloud-prod is owned by the VM host system
account anj-cloud-backup (no login, never uid 1000), mode 0700, so the operator's user and the VM host's agents
cannot read or write it. The share's virtiofsd is the root-owned wrapper virtiofsd-anj-cloud
(libvirt <binary path>), which adds --translate-uid/--translate-gid map:1000:<owner>:1: guest anj
(1000:1000) reads and writes as the share directory's owner; guest root (restic's container) is
squashed to the owner and every other guest id is forbidden to create or chown. libvirt's <idmap>
is not used: it becomes virtiofsd --uid-map, which virtiofsd refuses when libvirt (qemu:///system)
runs it as root.
"""

import argparse
import json
import os
from pathlib import Path
import pwd
import re
import stat
import subprocess
import sys
import xml.etree.ElementTree as ET

HERE = Path(os.path.realpath(__file__)).parent
TEMPLATES = Path(os.environ.get("ANJ_VM_TEMPLATES", HERE / "libvirt"))
CGROUP = Path(os.environ.get("ANJ_CGROUP_ROOT", "/sys/fs/cgroup"))
MEMINFO = Path(os.environ.get("ANJ_MEMINFO", "/proc/meminfo"))

PROFILES = {
    "anj-prod": {"name": "anj-prod", "network": "anj-prod", "bridge": "virbr-anjprod", "subnet": "10.77.10",
                 "mac": "52:54:00:a7:10:10", "pool": "anj-prod", "pool_dir": "/var/lib/libvirt/images/anj-prod",
                 "os_gib": 20, "data_gib": 200, "memory_kib": 4194304, "threads": [14, 30, 15, 31]},
    "anj-qual": {"name": "anj-qual", "network": "anj-qual", "bridge": "virbr-anjqual", "subnet": "10.77.11",
                 "mac": "52:54:00:a7:11:10", "pool": "anj-qual", "pool_dir": "/var/lib/libvirt/images/anj-qual",
                 "os_gib": 20, "data_gib": 20, "memory_kib": 4194304, "threads": [14, 30, 15, 31]},
}
SHARE_TAG = "anj-backup"
SHARE_ACCOUNT = "anj-cloud-backup"   # decision #115: owner of DOS_BACKUP/anj-cloud-prod on the VM host
GUEST_ID = 1000                      # the VM's anj user and group (deploy/vm/paths.py VM_USER)
SHARE_MODE = 0o700
VIRTIOFSD_WRAPPER = "/usr/local/lib/anj-cloud-host/virtiofsd-anj-cloud"   # installed by halo-vm.sh step 4
MAX_ID = 4294967294                 # (uid_t)-1 is not an id
FORBIDDEN_OWNERS = (0, GUEST_ID)     # never root, never the VM host's uid 1000 (the operator's user and the agents)
UUID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")


def xml_text(value):
    return value.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("'", "&apos;")


def render_domain(profile, uuid, share=None, readonly=False, description=None):
    if not UUID.fullmatch(uuid):
        raise ValueError("uuid must be a lowercase RFC 4122 UUID")
    text = (TEMPLATES / f"{profile}.xml").read_text()
    if description is not None:
        if not re.fullmatch(r"[A-Za-z0-9 ._:=-]{1,120}", description):
            raise ValueError("description holds letters, digits, spaces and . _ : = - only")
        text = text.replace(f"<name>{profile}</name>", f"<name>{profile}</name>\n  <description>{description}</description>", 1)
    block = ""
    if share:
        if not os.path.isabs(share) or "'" in share:
            raise ValueError("share must be an absolute path")
        # The wrapper maps guest 1000:1000 to the share directory's owner (decision #115).
        block = ("<filesystem type='mount' accessmode='passthrough'>\n"
                 "      <driver type='virtiofs' queue='1024'/>\n"
                 f"      <binary path='{VIRTIOFSD_WRAPPER}'/>\n"
                 f"      <source dir='{xml_text(share)}'/>\n"
                 f"      <target dir='{SHARE_TAG}'/>\n" + ("      <readonly/>\n" if readonly else "")
                 + "    </filesystem>")
    return text.replace("@UUID@", uuid).replace("<!--@SHARE@-->", block)


def render_net(profile, mode="nat"):
    if mode not in ("nat", "open"):
        raise ValueError("mode is nat or open")
    if profile != "anj-prod" and mode != "nat":
        raise ValueError("only anj-prod may use open mode")
    return (TEMPLATES / f"{profile}-net.xml").read_text().replace("@FORWARD_MODE@", mode)


def render_pool(profile):
    p = PROFILES[profile]
    return (f"<pool type='dir'>\n  <name>{p['pool']}</name>\n  <features><cow state='no'/></features>\n"
            f"  <target><path>{p['pool_dir']}</path></target>\n</pool>\n")


SSH_KEY = re.compile(r"(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|sk-ssh-ed25519@openssh.com) "
                     r"[A-Za-z0-9+/=]+( [^\n]{0,200})?")


def seed(profile, out, keys, instance_id=None, timezone="Europe/Paris"):
    """NoCloud seed: user anj (SSH keys only, passwordless sudo), hostname, timezone. No secrets."""
    p = PROFILES[profile]
    lines = []
    for key in keys:
        for line in Path(key).read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#"):
                if not SSH_KEY.fullmatch(line):
                    raise ValueError("not an SSH public key line")
                if line not in lines:
                    lines.append(line)
    if not lines:
        raise ValueError("at least one SSH public key is required")
    if not re.fullmatch(r"[A-Za-z]+(/[A-Za-z_+-]+){0,2}|UTC", timezone):
        raise ValueError("timezone must be an IANA name")
    out = Path(out)
    out.mkdir(parents=True, exist_ok=True)
    (out / "meta-data").write_text(f"instance-id: {instance_id or p['name'] + '-1'}\nlocal-hostname: {p['name']}\n")
    keys_yaml = "".join(f"      - {json.dumps(line)}\n" for line in lines)
    (out / "user-data").write_text(
        "#cloud-config\n"
        f"hostname: {p['name']}\n"
        f"timezone: {timezone}\n"
        "users:\n"
        "  - name: anj\n"
        "    groups: [sudo]\n"
        "    shell: /bin/bash\n"
        '    sudo: "ALL=(ALL) NOPASSWD:ALL"\n'
        "    lock_passwd: true\n"
        "    ssh_authorized_keys:\n" + keys_yaml +
        "ssh_pwauth: false\n"
        "disable_root: true\n"
        # No packages: first boot needs no network beyond the VM host; the bootstrap (B2) installs the rest.
        "package_update: false\n")
    # A static address: the VM is reachable from the VM host even before any DHCP firewall rule exists.
    (out / "network-config").write_text(
        "version: 2\n"
        "ethernets:\n"
        "  primary:\n"
        "    match:\n"
        f"      macaddress: \"{p['mac']}\"\n"
        f"    addresses: [{p['subnet']}.10/24]\n"
        "    routes:\n"
        f"      - to: default\n        via: {p['subnet']}.1\n"
        "    nameservers:\n"
        f"      addresses: [{p['subnet']}.1]\n")
    return sorted(path.name for path in out.iterdir())


def cpuset(text):
    threads = set()
    for part in (text or "").split(","):
        part = part.strip()
        if not part:
            continue
        if part.startswith("^"):
            threads.discard(int(part[1:]))
        elif "-" in part:
            low, high = part.split("-")
            threads.update(range(int(low), int(high) + 1))
        else:
            threads.add(int(part))
    return sorted(threads)


def domain_facts(text):
    root = ET.fromstring(text)
    get = lambda path, attr=None: (root.find(path).get(attr) if attr else (root.find(path).text or "").strip()) \
        if root.find(path) is not None else None  # noqa: E731
    disks = []
    for disk in root.findall("./devices/disk"):
        source = disk.find("source")
        name = None
        if source is not None:
            name = source.get("volume") or os.path.basename(source.get("file") or source.get("dev") or "")
        disks.append({"device": disk.get("device"), "target": disk.find("target").get("dev"), "source": name})
    shares = []
    for fs in root.findall("./devices/filesystem"):
        shares.append({"driver": fs.find("driver").get("type") if fs.find("driver") is not None else None,
                       "binary": fs.find("binary").get("path") if fs.find("binary") is not None else None,
                       "source": fs.find("source").get("dir") or fs.find("source").get("socket"),
                       "target": fs.find("target").get("dir"),
                       "readonly": fs.find("readonly") is not None, "idmap": fs.find("idmap") is not None})
    features = {f.get("name"): f.get("enabled") for f in root.findall("./os/firmware/feature")}
    memory = int(get("memory") or 0) * {"KiB": 1, "MiB": 1024, "GiB": 1048576}.get(get("memory", "unit") or "KiB", 1)
    return {
        "name": get("name"),
        "memory_kib": memory,
        "memory_backing": [get("memoryBacking/source", "type"), get("memoryBacking/access", "mode")],
        "vcpus": int(get("vcpu") or 0),
        "vcpupin": sorted((int(v.get("vcpu")), cpuset(v.get("cpuset"))) for v in root.findall("./cputune/vcpupin")),
        "emulatorpin": cpuset(get("cputune/emulatorpin", "cpuset")),
        "firmware": get("os", "firmware") or ("efi" if root.find("./os/loader") is not None else "bios"),
        "secure_boot": features.get("secure-boot", "no"),
        "disks": sorted(disks, key=lambda d: d["target"]),
        "interfaces": sorted((i.find("mac").get("address") if i.find("mac") is not None else None,
                              i.find("source").get("network") if i.find("source") is not None else None)
                             for i in root.findall("./devices/interface")),
        "shares": shares,
        "memballoon": get("devices/memballoon", "model"),
        "on_reboot": get("on_reboot"),
        "description": get("description"),
    }


def net_facts(text):
    root = ET.fromstring(text)
    ip = root.find("ip")
    return {
        "name": root.findtext("name"),
        "forward": root.find("forward").get("mode") if root.find("forward") is not None else None,
        "bridge": root.find("bridge").get("name") if root.find("bridge") is not None else None,
        "ip": [ip.get("address"), ip.get("netmask")] if ip is not None else None,
        "dhcp_hosts": sorted((h.get("mac"), h.get("ip")) for h in root.findall("./ip/dhcp/host")),
    }


def compare(expected, actual):
    """{fact: [expected, actual]} for every fact that differs."""
    return {key: [expected[key], actual.get(key)] for key in expected if expected[key] != actual.get(key)}


def mem_available():
    """Host MemAvailable in bytes, or None when /proc/meminfo cannot be read or has no such line."""
    try:
        for line in MEMINFO.read_text().splitlines():
            if line.startswith("MemAvailable:"):
                return int(line.split()[1]) * 1024
    except (OSError, ValueError, IndexError):
        pass
    return None


def headroom(reserved_kib=0):
    """Bytes left for new domains, counting running domains at their full size. basis "slice-limit": machine.slice's
    lowest limit minus use, never more than host MemAvailable when that is readable. basis "host-available": the
    slice has no limit, so MemAvailable less what running domains have yet to touch; None when it cannot be read."""
    root = CGROUP / "machine.slice"
    used = int((root / "memory.current").read_text())
    current = max(used, reserved_kib * 1024)
    available = mem_available()
    limits = {}
    for name in ("memory.high", "memory.max"):
        value = (root / name).read_text().strip()
        if value != "max":
            limits[name] = int(value)
    if not limits:
        room = None if available is None else available - (current - used)
        return {"current": current, "limit": None, "headroom": room, "basis": "host-available",
                "mem_available": available}
    limit = min(limits.values())
    room = limit - current if available is None else min(limit - current, available)
    return {"current": current, "limit": limit, "headroom": room, "basis": "slice-limit", "mem_available": available}


# ---------------------------------------------------------------------------------------------
# Backup share ownership (decision #115)

def test_mode():
    """Test harness hooks are honoured only for an unprivileged caller: never as root."""
    return os.geteuid() != 0 and bool(os.environ.get("ANJ_HOST_TEST") or os.environ.get("ANJ_HOST_ROOT"))


def _owners_overlay():
    """Test harness only (non-root, ANJ_HOST_TEST or ANJ_HOST_ROOT set): a JSON file
    {path: [uid, gid, mode]} standing in for ownership the unprivileged test cannot really set."""
    if not test_mode():
        return None
    return os.environ.get("ANJ_HOST_TEST_OWNERS") or None


def _overlay_read():
    path = _owners_overlay()
    if not path:
        return {}
    try:
        return json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return {}


def _overlay_write(key, uid, gid, mode):
    path = _owners_overlay()
    data = _overlay_read()
    data[key] = [uid, gid, mode]
    Path(path).write_text(json.dumps(data))


def lookup_account(name, passwd=None):
    """{name, uid, gid, home, shell} or None. passwd: a passwd(5) file instead of NSS (tests)."""
    if passwd:
        for line in Path(passwd).read_text().splitlines():
            fields = line.split(":")
            if len(fields) >= 7 and fields[0] == name:
                return {"name": name, "uid": int(fields[2]), "gid": int(fields[3]), "home": fields[5], "shell": fields[6]}
        return None
    try:
        entry = pwd.getpwnam(name)
    except KeyError:
        return None
    return {"name": name, "uid": entry.pw_uid, "gid": entry.pw_gid, "home": entry.pw_dir, "shell": entry.pw_shell}


def account_problems(account):
    if account is None:
        return [f"account {SHARE_ACCOUNT} absent"]
    problems = []
    if account["uid"] in FORBIDDEN_OWNERS or account["gid"] in FORBIDDEN_OWNERS:
        problems.append(f"account {account['name']} has uid/gid {account['uid']}/{account['gid']} (never 0 or 1000)")
    if not 0 < account["uid"] < 1000:
        problems.append(f"account {account['name']} is not a system account (uid {account['uid']})")
    if os.path.basename(account["shell"]) not in ("nologin", "false"):
        problems.append(f"account {account['name']} has a login shell ({account['shell']})")
    return problems


def owner_of(path):
    """(uid, gid, mode) of path itself (never followed), with the test overlay applied."""
    info = os.lstat(path)
    found = _overlay_read().get(str(path))
    if found:
        return int(found[0]), int(found[1]), int(found[2])
    return info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode)


def share_check(path, account_name=SHARE_ACCOUNT, passwd=None):
    """Whether the share is a real directory owned by the account, mode 0700. `empty` is None when
    the caller cannot list it (an agent: that is the point)."""
    path = str(path)
    account = lookup_account(account_name, passwd)
    result = {"path": path, "exists": False, "account": account, "ok": False, "problems": account_problems(account)}
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        result["problems"].append("share directory absent")
        return result
    result["exists"] = True
    if not stat.S_ISDIR(info.st_mode):
        result["problems"].append("share is not a directory (or is a symlink)")
        return result
    uid, gid, mode = owner_of(path)
    result.update(uid=uid, gid=gid, mode=f"{mode:04o}")
    try:
        result["empty"] = not os.listdir(path)
    except PermissionError:
        result["empty"] = None
    if account and (uid, gid) != (account["uid"], account["gid"]):
        result["problems"].append(f"owner {uid}:{gid}, expected {account['name']} ({account['uid']}:{account['gid']})")
    if mode != SHARE_MODE:
        result["problems"].append(f"mode {mode:04o}, expected 0700")
    result["ok"] = not result["problems"]
    return result


def share_own(path, account_name=SHARE_ACCOUNT, passwd=None):
    """Root (operator, halo-vm.sh step 4): create the share, or migrate an EMPTY share to the account.
    A share already owned by the account only has its mode corrected. A non-empty share owned by
    anyone else is never changed (its data is not ours to re-own blindly)."""
    path = str(path)
    account = lookup_account(account_name, passwd)
    problems = account_problems(account)
    if problems:
        raise ValueError("; ".join(problems))
    uid, gid = account["uid"], account["gid"]
    test = bool(_owners_overlay())

    def apply(action):
        if test:
            _overlay_write(path, uid, gid, SHARE_MODE)
        else:
            os.chown(path, uid, gid, follow_symlinks=False)
            os.chmod(path, SHARE_MODE, follow_symlinks=False)
        return {"path": path, "action": action, "before": before, "after": f"{uid}:{gid} 0700"}

    try:
        info = os.lstat(path)
    except FileNotFoundError:
        os.mkdir(path, 0o700)
        before = "absent"
        return apply("created")
    if not stat.S_ISDIR(info.st_mode):
        raise ValueError(f"{path} is not a directory (or is a symlink); not changed")
    have_uid, have_gid, mode = owner_of(path)
    before = f"{have_uid}:{have_gid} {mode:04o}"
    if (have_uid, have_gid, mode) == (uid, gid, SHARE_MODE):
        return {"path": path, "action": "compliant", "before": before, "after": before}
    if (have_uid, have_gid) == (uid, gid):
        return apply("mode-fixed")
    if os.listdir(path):
        raise ValueError(f"{path} holds data owned by {have_uid}:{have_gid}; not changed (inspect it by hand)")
    return apply("migrated")


def _may(uid, gid, owner, mode, bits):
    """DAC for the test overlay: owner bits for the owner, group bits for the group, else other."""
    if uid == owner[0]:
        return mode & (bits << 6) == bits << 6
    if gid == owner[1]:
        return mode & (bits << 3) == bits << 3
    return mode & bits == bits


def _probe_here(path):
    result = {"read": False, "write": False}
    try:
        os.listdir(path)
        result["read"] = True
    except OSError:
        pass
    probe = os.path.join(path, f".anj-cloud-probe-{os.getpid()}")
    try:
        fd = os.open(probe, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    except OSError:
        return result
    os.close(fd)
    os.unlink(probe)  # only reached when the share is wrongly writable
    result["write"] = True
    return result


PRODUCTION_SHARE = "/mnt/anj-backup/anj-cloud-prod"
QUAL_BASE = (".local", "share", "anj-cloud", "qualification")   # under a the VM host user's home


def qual_base(home=None):
    return os.path.join(home or str(Path.home()), *QUAL_BASE)


def served_allowed(path):
    """The wrapper serves only the production share and direct children of a the VM host user's
    qualification directory (~/.local/share/anj-cloud/qualification/<name>), by a path without
    symlinks. Test harness only: ANJ_WRAPPER_TEST_BASE adds one more base."""
    if os.path.realpath(path) != os.path.normpath(path) or not os.path.isabs(path):
        return False
    if path == PRODUCTION_SHARE:
        return True
    parent = os.path.dirname(path)
    bases = {qual_base(entry.pw_dir) for entry in pwd.getpwall() if entry.pw_uid >= 1000}
    if test_mode() and os.environ.get("ANJ_WRAPPER_TEST_BASE"):
        bases.add(os.path.normpath(os.environ["ANJ_WRAPPER_TEST_BASE"]))
    return parent in bases and os.path.basename(path) not in ("", ".", "..")


def serve_check(path):
    """The wrapper's checks, against the directory itself: allowlisted path; opened once
    (O_DIRECTORY|O_NOFOLLOW) and checked through that descriptor; the path must still name the
    same inode afterwards. Returns the mapping (translate_args) for it."""
    if not served_allowed(path):
        raise ValueError(f"{path} is not a served share (only {PRODUCTION_SHARE} and ~/{'/'.join(QUAL_BASE)}/<name>)")
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        opened = os.fstat(fd)
        args = translate_args(path, opened)
        again = os.lstat(path)
        if (again.st_dev, again.st_ino) != (opened.st_dev, opened.st_ino):
            raise ValueError(f"{path} changed while it was checked")
    finally:
        os.close(fd)
    return args


def translate_args(path, info=None):
    """The wrapper's mapping for a share (decision #115): guest anj (1000:1000) <-> the directory's
    owner; guest root (restic runs as its container's root) creates as the owner too, so the VM host sees
    one owner and the guest sees anj everywhere; every other guest uid/gid may not create or chown
    anything there. Refuses (ValueError) a share owned by root or 1000, or not mode 0700."""
    info = info or os.lstat(path)
    if not stat.S_ISDIR(info.st_mode):
        raise ValueError(f"{path} is not a directory (or is a symlink)")
    uid, gid, mode = info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode)
    found = _overlay_read().get(str(path))
    if found:
        uid, gid, mode = int(found[0]), int(found[1]), int(found[2])
    if mode != SHARE_MODE:
        raise ValueError(f"{path} is mode {mode:04o}, expected 0700 (decision #115)")
    if uid in FORBIDDEN_OWNERS or gid in FORBIDDEN_OWNERS:
        raise ValueError(f"{path} is owned by {uid}:{gid}; never root or 1000 (decision #115)")
    args = []
    for kind, host in (("uid", uid), ("gid", gid)):
        args += [f"--translate-{kind}", f"squash-guest:0:{host}:1",            # guest root (restic's container)
                 f"--translate-{kind}", f"forbid-guest:1:{GUEST_ID - 1}",
                 f"--translate-{kind}", f"map:{GUEST_ID}:{host}:1",            # guest anj <-> the owner
                 f"--translate-{kind}", f"forbid-guest:{GUEST_ID + 1}:{MAX_ID - GUEST_ID}"]
    return args


def shared_dir(argv):
    """The --shared-dir value of a virtiofsd argv, or None."""
    for index, arg in enumerate(argv):
        if arg == "--shared-dir" and index + 1 < len(argv):
            return argv[index + 1]
        if arg.startswith("--shared-dir="):
            return arg.split("=", 1)[1]
    return None


def virtiofsd_args(share, proc="/proc"):
    """argv of every running virtiofsd serving this share (read from /proc; world-readable)."""
    found = []
    for entry in sorted(Path(proc).glob("[0-9]*")):
        try:
            argv = [a.decode(errors="replace") for a in (entry / "cmdline").read_bytes().split(b"\0") if a]
        except OSError:
            continue
        if argv and os.path.basename(argv[0]) == "virtiofsd" and shared_dir(argv) == share:
            found.append(argv)
    return found


def share_probe(path, uids):
    """{uid: {read, write}} for each the VM host uid: really attempted (root drops to the uid in a child;
    an agent can test only its own uid). The result is the observed access, never inferred."""
    path = str(path)
    results = {}
    overlay = _overlay_read().get(path)
    for uid in uids:
        try:
            gid = pwd.getpwuid(uid).pw_gid
        except KeyError:
            gid = uid
        if overlay:
            results[str(uid)] = {"read": _may(uid, gid, overlay, overlay[2], 0o5),
                                 "write": _may(uid, gid, overlay, overlay[2], 0o3)}
        elif os.geteuid() == 0:
            reader, writer = os.pipe()
            child = os.fork()
            if child == 0:
                try:
                    os.close(reader)
                    os.setgroups([])
                    os.setgid(gid)
                    os.setuid(uid)
                    os.write(writer, json.dumps(_probe_here(path)).encode())
                finally:
                    os._exit(0)
            os.close(writer)
            with os.fdopen(reader) as stream:
                text = stream.read()
            os.waitpid(child, 0)
            results[str(uid)] = json.loads(text) if text else {"read": None, "write": None}
        elif os.getuid() == uid:
            results[str(uid)] = _probe_here(path)
        else:
            results[str(uid)] = {"read": None, "write": None, "note": "needs root to test another uid"}
    return results


def subids(kind, passwd_entry=None):
    """The caller's subordinate ranges from /etc/subuid or /etc/subgid: [(start, count)]."""
    entry = passwd_entry or pwd.getpwuid(os.getuid())
    names = {entry.pw_name, str(entry.pw_uid)}
    ranges = []
    try:
        lines = Path(f"/etc/sub{kind}").read_text().splitlines()
    except OSError:
        return ranges
    for line in lines:
        fields = line.strip().split(":")
        if len(fields) == 3 and fields[0] in names and fields[1].isdigit() and fields[2].isdigit():
            ranges.append((int(fields[1]), int(fields[2])))
    return ranges


SCRATCH_NS_ID = 61000   # inside the namespace; the share's host owner is <first subuid> + 60999


def _ns_prefix():
    uids, gids = subids("uid"), subids("gid")
    if not uids or not gids:
        raise ValueError("no subordinate uid/gid range for this user in /etc/subuid and /etc/subgid")
    (ustart, ucount), (gstart, gcount) = uids[0], gids[0]
    return (["unshare", "--map-root-user", f"--map-users=1:{ustart}:{ucount}", f"--map-groups=1:{gstart}:{gcount}", "--"],
            (ustart, ucount), (gstart, gcount))


def _ns_id(start, count):
    ns = min(SCRATCH_NS_ID, count)
    return ns, start + ns - 1


def scratch_share(action, path):
    """Agent-side qualification share with the production ownership model (decision #115): owned by
    one of the caller's subordinate uids, mode 0700, so the caller cannot enter it on the VM host and only
    the virtiofs mapping reaches it. Created and removed through an unprivileged user namespace."""
    path = os.path.abspath(path)
    if os.path.dirname(path) != qual_base() or os.path.basename(path) in ("", ".", "..") \
            or os.path.realpath(os.path.dirname(path)) != os.path.dirname(path):
        raise ValueError(f"scratch shares live directly under {qual_base()} (no symlinks); refusing {path}")
    prefix, (ustart, ucount), (gstart, gcount) = _ns_prefix()
    ns_uid, host_uid = _ns_id(ustart, ucount)
    ns_gid, host_gid = _ns_id(gstart, gcount)
    if action == "create":
        os.mkdir(path, 0o700)
        subprocess.run([*prefix, "chown", f"{ns_uid}:{ns_gid}", path], check=True, timeout=60)
        return {"path": path, "uid": host_uid, "gid": host_gid, "mode": "0700"}
    if action == "remove":
        if not os.path.lexists(path):
            return {"path": path, "removed": True, "note": "absent"}
        if os.path.islink(path) or not os.path.isdir(path):
            raise ValueError(f"{path} is not a directory; not removed")
        uid, _gid, _mode = owner_of(path)
        if uid == os.getuid() and not os.listdir(path):
            os.rmdir(path)   # a create that stopped before its chown
            return {"path": path, "removed": True}
        if uid != host_uid:
            raise ValueError(f"{path} is owned by uid {uid}, not this user's scratch uid {host_uid}; not removed")
        subprocess.run([*prefix, "rm", "-rf", "--one-file-system", "--", path], check=True, timeout=600)
        return {"path": path, "removed": not os.path.lexists(path)}
    raise ValueError("scratch-share create|remove")


def share_exec(path, command):
    """Run command with access to a scratch share: directly when the caller owns it, through the
    user namespace when one of the caller's subordinate uids does. Never for the production share."""
    uid, _gid, _mode = owner_of(path)
    if uid == os.getuid():
        os.execvp(command[0], command)
    prefix, (ustart, ucount), _g = _ns_prefix()
    if not ustart <= uid < ustart + ucount:
        raise ValueError(f"{path} is owned by uid {uid}, outside this user's subordinate range (needs the operator)")
    os.execvp(prefix[0], [*prefix, *command])


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("render-domain")
    p.add_argument("profile", choices=PROFILES)
    p.add_argument("--uuid", required=True)
    p.add_argument("--share")
    p.add_argument("--readonly", action="store_true")
    p.add_argument("--description")
    p = sub.add_parser("render-net")
    p.add_argument("profile", choices=PROFILES)
    p.add_argument("--mode", default="nat")
    p = sub.add_parser("render-pool")
    p.add_argument("profile", choices=PROFILES)
    p = sub.add_parser("seed")
    p.add_argument("profile", choices=PROFILES)
    p.add_argument("--out", required=True)
    p.add_argument("--key", action="append", default=[])
    p.add_argument("--instance-id")
    p.add_argument("--timezone", default="Europe/Paris")
    for name in ("compare-domain", "compare-net"):
        p = sub.add_parser(name)
        p.add_argument("expected")
        p.add_argument("actual")
        p.add_argument("--ignore", action="append", default=[], help="fact to leave out (repeatable)")
    p = sub.add_parser("cpus")
    p.add_argument("files", nargs="*")
    sub.add_parser("headroom").add_argument("--reserved-kib", type=int, default=0)
    sub.add_parser("profile").add_argument("profile", choices=PROFILES)
    for name in ("share-check", "share-own"):
        p = sub.add_parser(name)
        p.add_argument("dir")
        p.add_argument("--account", default=SHARE_ACCOUNT)
        p.add_argument("--passwd", help="a passwd(5) file instead of NSS (test harness)")
    sub.add_parser("share-facts", help="the virtiofs shares (binary, source, tag) of a domain XML").add_argument("xml")
    p = sub.add_parser("virtiofsd-args", help="argv of the running virtiofsd serving DIR (JSON)")
    p.add_argument("dir")
    p.add_argument("--proc", default="/proc")
    p = sub.add_parser("share-probe")
    p.add_argument("dir")
    p.add_argument("--uid", type=int, action="append", required=True)
    p = sub.add_parser("scratch-share")
    p.add_argument("action", choices=("create", "remove"))
    p.add_argument("dir")
    p = sub.add_parser("share-exec")
    p.add_argument("dir")
    p.add_argument("exec_command", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    try:
        if args.command == "render-domain":
            sys.stdout.write(render_domain(args.profile, args.uuid, args.share, args.readonly, args.description))
        elif args.command == "render-net":
            sys.stdout.write(render_net(args.profile, args.mode))
        elif args.command == "render-pool":
            sys.stdout.write(render_pool(args.profile))
        elif args.command == "seed":
            print(" ".join(seed(args.profile, args.out, args.key, args.instance_id, args.timezone)))
        elif args.command in ("compare-domain", "compare-net"):
            facts = domain_facts if args.command == "compare-domain" else net_facts
            differences = compare(facts(Path(args.expected).read_text()), facts(Path(args.actual).read_text()))
            differences = {key: value for key, value in differences.items() if key not in args.ignore}
            print(json.dumps(differences, sort_keys=True))
            return 1 if differences else 0
        elif args.command == "cpus":
            threads = set()
            for path in args.files:
                facts = domain_facts(Path(path).read_text())
                for _vcpu, pins in facts["vcpupin"]:
                    threads.update(pins)
                threads.update(facts["emulatorpin"])
            print(" ".join(str(t) for t in sorted(threads)))
        elif args.command == "headroom":
            print(json.dumps(headroom(args.reserved_kib)))
        elif args.command == "share-check":
            result = share_check(args.dir, args.account, args.passwd)
            print(json.dumps(result, sort_keys=True))
            return 0 if result["ok"] else 1
        elif args.command == "share-own":
            print(json.dumps(share_own(args.dir, args.account, args.passwd), sort_keys=True))
        elif args.command == "share-facts":
            print(json.dumps(domain_facts(Path(args.xml).read_text())["shares"], sort_keys=True))
        elif args.command == "virtiofsd-args":
            print(json.dumps(virtiofsd_args(args.dir, args.proc)))
        elif args.command == "share-probe":
            result = share_probe(args.dir, args.uid)
            print(json.dumps(result, sort_keys=True))
            # A probe that did not run (None) is not "denied": exit 3 so verify fails on it.
            if any(r.get("read") is None or r.get("write") is None for r in result.values()):
                return 3
            return 1 if any(r.get("read") or r.get("write") for r in result.values()) else 0
        elif args.command == "scratch-share":
            print(json.dumps(scratch_share(args.action, args.dir), sort_keys=True))
        elif args.command == "share-exec":
            command = args.exec_command[1:] if args.exec_command[:1] == ["--"] else args.exec_command
            if not command:
                raise ValueError("share-exec DIR -- COMMAND...")
            share_exec(args.dir, command)
        elif args.command == "profile":
            for key, value in PROFILES[args.profile].items():
                print(f"{key}={' '.join(map(str, value)) if isinstance(value, list) else value}")
    except (OSError, ValueError, ET.ParseError, subprocess.SubprocessError) as error:
        print(f"anjvm: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
