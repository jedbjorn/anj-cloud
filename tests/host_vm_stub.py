"""Stateful stand-ins for the VM host commands halo-vm.sh, host-check and vm-start call (spec #21).

One executable per command name in a stub directory runs `python3 host_vm_stub.py <name> ...`.
Every call is appended to $ANJ_HOST_STUBS/calls.log (JSON argv); state lives in state.json there.
Nothing touches the real host: libvirt, ufw, nft and systemd are simulated, files land under
$ANJ_HOST_ROOT. Carried and extended from d1b705c's tests/host_stub.py.
"""

import json
import os
from pathlib import Path
import re
import sys
import xml.etree.ElementTree as ET

STUBS = Path(os.environ["ANJ_HOST_STUBS"])
ROOT = Path(os.environ.get("ANJ_HOST_ROOT", "/nonexistent"))
STATE = STUBS / "state.json"


def load():
    return json.loads(STATE.read_text())


def save(state):
    STATE.write_text(json.dumps(state, indent=1))


def out(text="", code=0):
    if text:
        sys.stdout.write(text if text.endswith("\n") else text + "\n")
    sys.exit(code)


def fail(message):
    sys.stderr.write(f"error: {message}\n")
    sys.exit(1)


def unit(state, name):
    return state.setdefault("units", {}).setdefault(name, {"enabled": "disabled", "active": "inactive"})


# virsh ----------------------------------------------------------------------------------------

def virsh(state, args):
    args = [a for a in args if a not in ("-q",)]
    if args[:1] == ["-c"]:
        args = args[2:]
    command, rest = args[0], args[1:]
    doms, nets, pools = state["domains"], state["networks"], state["pools"]
    flags = [a for a in rest if a.startswith("--")]
    names = [a for a in rest if not a.startswith("--")]
    if command == "version":
        out("Compiled against library: libvirt 12.8.0\nUsing library: libvirt 12.8.0\nRunning against daemon: "
            + state.get("libvirt", "12.8.0"))
    if command == "list":
        rows = [n for n, d in doms.items() if "--state-running" not in flags or d["state"] == "running"]
        if "--name" in flags:
            out("\n".join(rows))
        out(" Id   Name   State\n------------------\n" + "\n".join(f" -    {n}   {doms[n]['state']}" for n in rows))
    if command == "net-list":
        out("\n".join(nets))
    if command == "pool-list":
        out("\n".join(pools))
    if command in ("dominfo", "domstate", "domuuid", "dumpxml", "undefine", "start", "destroy", "shutdown", "autostart",
                   "vcpupin", "emulatorpin"):
        name = names[0]
        if name not in doms:
            fail(f"failed to get domain '{name}'")
        dom = doms[name]
        if command == "dominfo":
            out(f"Name:           {name}\nState:          {dom['state']}\nMax memory:     {dom.get('kib', 4194304)} KiB\n"
                f"Autostart:      {'enable' if dom.get('autostart') else 'disable'}")
        if command == "domstate":
            out(dom["state"])
        if command == "domuuid":
            out(dom["uuid"])
        if command == "dumpxml":
            out(dom["xml"])
        if command == "vcpupin":
            out(" VCPU   CPU Affinity\n----------------------\n 0      14\n 1      30\n 2      15\n 3      31")
        if command == "emulatorpin":
            out(" emulator: CPU Affinity\n----------------------------------\n       *: 14-15,30-31")
        if command == "undefine":
            if dom["state"] == "running":
                fail("cannot undefine a running domain in this stub")
            del doms[name]
        elif command == "start":
            if name in state.get("fail_start", []):
                fail("start failed")
            dom["state"] = "running"
        elif command in ("destroy", "shutdown"):
            dom["state"] = "shut off"
        elif command == "autostart":
            dom["autostart"] = "--disable" not in flags
        save(state)
        out()
    if command == "define":
        root = ET.parse(names[0]).getroot()
        name, uuid = root.findtext("name"), root.findtext("uuid")
        previous = doms.get(name, {})
        doms[name] = {"state": previous.get("state", "shut off"), "uuid": uuid, "xml": Path(names[0]).read_text(),
                      "autostart": previous.get("autostart", False)}
        save(state)
        out(f"Domain '{name}' defined")
    if command.startswith("net-"):
        if command == "net-define":
            name = ET.parse(names[0]).getroot().findtext("name")
            nets[name] = {"xml": Path(names[0]).read_text(), "active": False, "autostart": False}
            save(state)
            out()
        name = names[0]
        if name not in nets:
            fail(f"network '{name}' not found")
        net = nets[name]
        if command == "net-info":
            out(f"Name:  {name}\nActive:         {'yes' if net['active'] else 'no'}\n"
                f"Autostart:      {'yes' if net['autostart'] else 'no'}")
        if command == "net-dumpxml":
            out(net["xml"])
        if command == "net-start":
            net["active"] = True
        elif command == "net-destroy":
            net["active"] = False
        elif command == "net-autostart":
            net["autostart"] = True
        elif command == "net-undefine":
            del nets[name]
        save(state)
        out()
    if command.startswith("pool-"):
        if command == "pool-define":
            name = ET.parse(names[0]).getroot().findtext("name")
            pools[name] = {"state": "inactive", "vols": [], "built": False}
            save(state)
            out()
        name = names[0]
        if name not in pools:
            fail(f"storage pool '{name}' not found")
        pool = pools[name]
        if command == "pool-info":
            out(f"Name:           {name}\nState:          {pool['state']}")
        if command == "pool-build":
            pool["built"] = True
            (ROOT / "var/lib/libvirt/images" / name).mkdir(parents=True, exist_ok=True)
        elif command == "pool-start":
            pool["state"] = "running"
        elif command == "pool-destroy":
            pool["state"] = "inactive"
        elif command == "pool-delete":
            directory = ROOT / "var/lib/libvirt/images" / name
            if pool["vols"]:
                fail("Directory not empty")
            if directory.exists():
                directory.rmdir()
        elif command == "pool-undefine":
            del pools[name]
        save(state)
        out()
    if command.startswith("vol-"):
        pool_name = rest[rest.index("--pool") + 1] if "--pool" in rest else names[0]
        positional = [a for a in names if a != pool_name]
        pool = pools.get(pool_name)
        if pool is None:
            fail("pool not found")
        if command == "vol-list":
            out("\n".join(f" {v}   /var/lib/libvirt/images/{pool_name}/{v}" for v in pool["vols"]))
        vol = positional[0]
        if command == "vol-info":
            out("Name: " + vol, 0 if vol in pool["vols"] else 1)
        if command == "vol-create-as":
            if vol in pool["vols"]:
                fail("volume exists")
            pool["vols"].append(vol)
        elif command == "vol-delete":
            pool["vols"].remove(vol)
        save(state)
        out()
    out()


# ufw ------------------------------------------------------------------------------------------

def ufw(state, args):
    rules = state["ufw"]
    if args[:1] == ["status"]:
        numbered = args[1:2] == ["numbered"]
        lines = ["Status: active", ""]
        for index, rule in enumerate(rules, 1):
            suffix = f"  # {rule['comment']}" if rule["comment"] else ""
            lines.append((f"[{index:>2}] " if numbered else "") + rule["text"] + suffix)
        out("\n".join(lines))
    if args[:2] == ["--force", "delete"]:
        del rules[int(args[2]) - 1]
        save(state)
        out("Rule deleted")
    words = list(args)
    comment = ""
    if "comment" in words:
        comment = words[words.index("comment") + 1]
        words = words[:words.index("comment")]
    prepend = "prepend" in words
    words = [w for w in words if w != "prepend"]
    if words[:1] == ["delete"] or words[1:2] == ["delete"]:
        fail("stub: delete by spec not supported")
    if any(w in ("enable", "disable", "reload", "reset") for w in words[:1]):
        fail("forbidden")
    text = " ".join(words)
    delay = state.get("ufw_delay")
    if delay and delay[0] == comment:
        import time
        time.sleep(delay[1])
    for rule in rules:
        if rule["text"] == text:
            if prepend:
                out("Skipping inserting existing rule")  # ufw: insert/prepend never moves a match
            rule["comment"] = comment  # ufw: a plain add replaces a rule differing only in comment
            save(state)
            out("Rule updated")
    rule = {"text": text, "comment": comment}
    rules.insert(0, rule) if prepend else rules.append(rule)
    save(state)
    out("Rule added")


# nft, systemctl and the rest -------------------------------------------------------------------

def nft(state, args):
    tables = state["nft"]
    if args[:1] == ["-c"]:
        out("", state.get("nft_check_rc", 0))
    if args[:1] == ["-f"]:
        if re.search(r"table ip anj_cloud_fwd \{", Path(args[1]).read_text()):
            tables["ip anj_cloud_fwd"] = Path(args[1]).read_text()
        save(state)
        out()
    if args[:2] == ["list", "table"]:
        key = " ".join(args[2:4])
        out(tables.get(key, ""), 0 if key in tables else 1)
    if args[:2] == ["list", "tables"]:
        out("\n".join("table " + k for k in tables))
    if args[:2] == ["delete", "table"]:
        tables.pop(" ".join(args[2:4]), None)
        save(state)
        out()
    if args[:1] == ["-s"]:
        out("table ip libvirt_network { }")
    out("table ip libvirt_network { }")


def vm_start(state, dom):
    """What the installed vm-start does on a cold start: switch the share in the definition (with
    the backup share only when it is owned by the account, 0700), and the wrapper's virtiofsd."""
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "deploy" / "host"))
    import anjvm
    share = ROOT / "mnt/anj-backup/anj-cloud-prod"
    ok = state.get("mounted") and share.is_dir() and anjvm.share_check(
        str(share), anjvm.SHARE_ACCOUNT, str(ROOT / "etc/passwd"))["ok"]
    uuid = ET.fromstring(dom["xml"]).findtext("uuid")
    dom["xml"] = anjvm.render_domain("anj-prod", uuid, "/mnt/anj-backup/anj-cloud-prod" if ok else None)
    proc = ROOT / "proc/4242"
    if ok:
        proc.mkdir(parents=True, exist_ok=True)
        argv = ["/usr/lib/virtiofsd", "--fd=35", "--shared-dir", "/mnt/anj-backup/anj-cloud-prod",
                *anjvm.translate_args(str(share))]
        (proc / "cmdline").write_bytes(b"\0".join(a.encode() for a in argv) + b"\0")
    elif (proc / "cmdline").exists():
        (proc / "cmdline").unlink()


def sysusers(state, args):
    """systemd-sysusers FILE: the u lines become passwd/group entries under ROOT (system ids)."""
    passwd, group = ROOT / "etc/passwd", ROOT / "etc/group"
    for line in Path(args[-1]).read_text().splitlines():
        fields = line.split()
        if fields[:1] != ["u"]:
            continue
        name = fields[1]
        if any(row.split(":")[0] == name for row in passwd.read_text().splitlines()):
            continue
        uid = state.get("sysusers_uid", 961)
        with passwd.open("a") as stream:
            stream.write(f"{name}:x:{uid}:{uid}:anj-cloud backup share owner:/:/usr/bin/nologin\n")
        with group.open("a") as stream:
            stream.write(f"{name}:x:{uid}:\n")
    out()


def systemctl(state, args):
    args = [a for a in args if a not in ("--quiet", "--no-block", "--plain", "--no-legend")]
    command, names = args[0], args[1:]
    now = "--now" in names
    names = [n for n in names if not n.startswith("-")]
    if command == "is-active":
        value = unit(state, names[0])["active"]
        out(value, 0 if value == "active" else 3)
    if command == "is-enabled":
        value = unit(state, names[0])["enabled"]
        out(value, 0 if value == "enabled" else 1)
    if command == "show":
        out(str(unit(state, names[-1]).get("MainPID", "")))
    if command == "list-units":
        out("\n".join(f"{n} loaded active running x" for n, u in state["units"].items()
                      if u["active"] == "active" and n.endswith(".service")))
    for name in names:
        u = unit(state, name)
        if command == "enable":
            u["enabled"] = "enabled"
            if now:
                u["active"] = "active"
        elif command == "disable":
            u["enabled"] = "disabled"
            if now:
                u["active"] = "inactive"
        elif command in ("start", "restart"):
            u["active"] = "active"
            if name == "anj-cloud-forward.service":
                # ConditionPathExists=!/etc/anj-cloud-host/forward-off: skipped, not failed.
                if (ROOT / "etc/anj-cloud-host/forward-off").exists():
                    u["active"] = "inactive"
                else:
                    state["nft"]["ip anj_cloud_fwd"] = (ROOT / "etc/anj-cloud-host/anj-cloud-fwd.nft").read_text()
            if name == "anj-cloud-vm.service":
                # vm-start: a running domain is left alone ("already-running"); only a shut-off one
                # gets its share switched and is started.
                dom = state["domains"].get("anj-prod")
                if dom and dom["state"] != "running":
                    vm_start(state, dom)
                    dom["state"] = "running"
        elif command == "stop":
            u["active"] = "inactive"
            if name == "anj-cloud-vm-stop.service" and "anj-prod" in state["domains"]:
                # ExecStop=vm-start --stop: clean shutdown to "shut off"; virtiofsd goes with it.
                state["domains"]["anj-prod"]["state"] = "shut off"
                (ROOT / "proc/4242/cmdline").unlink(missing_ok=True)
            if name == "anj-cloud-forward.service":
                state["nft"].pop("ip anj_cloud_fwd", None)
    save(state)
    out()


def main():
    name, args = sys.argv[1], sys.argv[2:]
    with open(STUBS / "calls.log", "a") as log:
        log.write(json.dumps([name, *args]) + "\n")
    state = load()
    for command, word in state.get("fail", []):
        if command == name and word in args:
            fail(f"injected failure: {name} {word}")
    if name == "ufw" and args[:1] != ["status"] and "fail_nth_ufw" in state:
        state["ufw_calls"] = state.get("ufw_calls", 0) + 1
        save(state)
        if state["ufw_calls"] == state["fail_nth_ufw"]:
            fail(f"injected failure: ufw call {state['ufw_calls']}")
    if name == "virsh" and state.get("virsh_delay"):
        import time
        time.sleep(state["virsh_delay"])
    if name == "visudo":
        out("", state.get("visudo_rc", 0))
    if name == "sudo":
        out("", state.get("sudo_l_rc", 0) if "-l" in args else 1)
    if name == "virsh":
        virsh(state, args)
    if name == "ufw":
        ufw(state, args)
    if name == "nft":
        nft(state, args)
    if name == "systemctl":
        systemctl(state, args)
    if name == "uname":
        out(state.get("hostname", "vm-host") if args == ["-n"] else "7.3.1-1-cachyos")
    if name == "systemd-sysusers":
        sysusers(state, args)
    if name == "systemd-analyze":
        out("", state.get("verify_rc", 0))
    if name == "ip":
        if args[:3] == ["-4", "route", "show"]:
            out(state.get("routes", {}).get(args[3], ""))
        out("5: virbr0    inet 192.168.122.1/24 brd 192.168.122.255 scope global virbr0")
    if name == "ss":
        out('tcp LISTEN 0 128 192.168.122.1:22 0.0.0.0:* users:(("sshd",pid=600,fd=3))')
    if name == "sshd":
        out("port 22")
    if name == "mountpoint":
        out("", 0 if state.get("mounted") else 1)
    if name == "xorriso":
        target = args[args.index("-o") + 1]
        Path(target).write_bytes(b"seed")
        out()
    if name == "ssh" and args[:1] == ["-G"]:
        os.execv("/usr/bin/ssh", ["ssh", *args])
    if name == "ssh":
        out("status: done\nDebian GNU/Linux 13 (trixie)\n6.12.0-cloud\n4\n3900\nsudo-ok\nuefi", state.get("ssh_rc", 0))
    if name == "tailscale":
        out("No serve config")
    if name == "docker":
        out(state.get("docker_out", ""))
    if name == "runuser":
        command = args[args.index("--") + 1:]
        os.execvp(command[0], command)
    out()


if __name__ == "__main__":
    main()
