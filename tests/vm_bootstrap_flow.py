"""A whole guided install of anj-cloud-setup on fakes (bootstrap UX audit; spec #21 B2 tests).

The real Setup code runs from the banner to the last approval: the real prompts, Prompter, secret
notes, review, data-disk question, progress lines with heartbeats, summary, backup offer (the real
backup.py escrow screen on /dev/tty) and pairing. Only the machine is fake: the twelve steps are
stand-ins that take a moment, the gateway's operator CLI is FakeGateway, Cloudflare and ntfy are
recorded calls, and every state path lives under a temporary root. Nothing on the VM host changes.

    python3 -c 'from tests.vm_bootstrap_flow import main; main()' ROOT halo|household

writes ROOT/report.json (every spawned argv, the evidence, the fake secrets) for the leak tests.
"""

import base64
import contextlib
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
import time
from types import SimpleNamespace
from unittest import mock

from deploy import backup
from deploy.vm import bootstrap, guide, paths
from tests.vm_bootstrap_fakes import FakeFacts, FakeSystem

from services.access.codes import ALPHABET, CODE_LENGTH, PINNED_CODE_LENGTH  # noqa: E402
FINGERPRINT = "3fa1c09e" + "5b" * 24 + "7b2e9c41"
STEPS = [(1, "Packages", 1.4), (2, "PM2", 0.05), (3, "Data disk", 0.05), (4, "Docker", 0.05), (5, "Firewall", 0.05),
         (6, "Journald", 0.05), (7, "SSH (read-only)", 0.05), (8, "Release", 0.05), (9, "Stack", 1.4),
         (10, "Operations apps", 0.05), (11, "Timers", 0.05), (12, "Updates", 0.05)]


@contextlib.contextmanager
def sandbox(root):
    """Every /srv/anj-cloud path (paths.* and bootstrap's derived ones) under `root`."""
    root = Path(root)

    def moved(value):
        return root / "srv" / Path(value).relative_to("/srv/anj-cloud")
    patches = [mock.patch.object(paths, name, moved(value)) for name, value in vars(paths).items()
               if isinstance(value, Path) and str(value).startswith("/srv/anj-cloud")]
    patches += [mock.patch.object(bootstrap, name, moved(getattr(bootstrap, name)))
                for name in ("SETUP_RECORD", "OPS_CONFIG", "OPS_ECOSYSTEM", "COMMAND_TARGET", "ADMIN_TARGET")]
    patches += [mock.patch.object(bootstrap, "FALLBACK_LOG_DIR", root / "var-log"),
                mock.patch.object(bootstrap, "COMMAND_LINK", root / "usr-local-bin" / "anj-cloud-setup"),
                mock.patch.object(bootstrap, "ADMIN_LINK", root / "usr-local-bin" / "anj-cloud-admin"),
                mock.patch.object(bootstrap, "FORMATTED_MARKER", root / "formatted")]
    with contextlib.ExitStack() as stack:
        for patch in patches:
            stack.enter_context(patch)
        yield root


class FakeGateway:
    """The operator CLI's invite/pending/approve/deny over an in-memory registry. A device asks to
    pair (reserves the newest live code) after `reserve_after` polls of `pending`. With `pinned`
    (decision #151, what the gateway issues now) a code is PINNED_CODE_LENGTH characters and the gateway approves a
    reserved code by itself on the next poll, unless `auto` is off (its console backend down)."""

    def __init__(self, reserve_after=2, label="sam-laptop", pinned=True, auto=True):
        self.rows, self.calls, self.codes = {}, [], []
        self.polls, self.reserve_after, self.label = 0, reserve_after, label
        self.pinned, self.auto = pinned, auto

    def operator(self, *args, data=None, check=True):
        self.calls.append(args)
        if args[0] == "invite":
            code = "".join(secrets.choice(ALPHABET) for _ in range(PINNED_CODE_LENGTH if self.pinned else CODE_LENGTH))
            self.codes.append(code)
            row = {"id": f"inv-{len(self.rows) + 1}", "uid": args[1], "rights": "write", "expires": time.time() + 600,
                   "state": "issued", "fingerprint": None, "label": None, "pinned": int(self.pinned)}
            self.rows[row["id"]] = row
            return {**{k: row[k] for k in ("id", "uid", "rights", "expires")}, "code": code}
        if args[0] == "pending":
            self.polls += 1
            for row in self.rows.values():
                if row["pinned"] and self.auto and row["state"] == "reserved":
                    row["state"] = "approved"
            live = [row for row in self.rows.values() if row["state"] == "issued" and row["expires"] > time.time()]
            if live and self.reserve_after is not None and self.polls > self.reserve_after:
                live[-1].update(state="reserved", fingerprint=FINGERPRINT, label=self.label)
            return [dict(row) for row in self.rows.values()]
        if args[0] == "approve":
            self.rows[args[1]]["state"] = "approved"
            return {"state": "active"}
        if args[0] == "deny":
            self.rows[args[1]]["state"] = "denied"
            return {"state": "denied"}
        if args[0] == "accounts":
            return [{"uid": "sam"}, {"uid": "alex"}]
        return {}


class FakeStep(bootstrap.Step):
    """One of the twelve steps by its real number, name and progress text; takes `seconds`."""

    def __init__(self, setup, number, name, seconds):
        super().__init__(setup)
        real = next(klass for klass in bootstrap.Step.__subclasses__() if klass.number == number)
        self.number, self.name, self.seconds = number, name, seconds
        self.title, self.purpose, self.expect = real.title, real.purpose, real.expect

    def state(self):
        return False, "not done"

    def apply(self):
        time.sleep(self.seconds)
        setup, system = self.setup, self.system
        if self.number == 9:
            system.write(paths.STACK_CONFIG, json.dumps({"host": setup.answers["host"], "release": "a" * 40,
                                                         "bind_address": setup.answers["bind_address"]}))
            der = b"anj-cloud fake issuer " + bytes(range(64))
            system.write(paths.OPERATOR_DIR / "issuer.crt", "-----BEGIN CERTIFICATE-----\n" +
                         base64.b64encode(der).decode() + "\n-----END CERTIFICATE-----\n")
            setup.release = "a" * 40
        if self.number == 10:
            bootstrap.COMMAND_LINK.parent.mkdir(parents=True, exist_ok=True)
            bootstrap.COMMAND_LINK.unlink(missing_ok=True)
            bootstrap.COMMAND_LINK.symlink_to(bootstrap.LAUNCHER)
            system.write(paths.NTFY_TOPIC, setup.secrets["topic"] + "\n", mode=0o600, secret=True)
            setup.topic_new = True
            if setup.secrets.get("token"):
                system.write(paths.CLOUDFLARE_TOKEN, setup.secrets["token"] + "\n", mode=0o600, secret=True)

    def verify(self):
        return True, "ok"


STATUS = {"healthcheck": "ready", "firewall": "loaded", "ddns": "no success yet", "data_disk_used": "2%",
          "backup": "not set up or never succeeded", "release": "a" * 12,
          "apps": {name: "online" for name in ("alerts", "cron", "db", "gateway", "haproxy", "nextcloud", "redis",
                                               "watchdog", "watchers", "console")} | {"ddns": "stopped"}}


def escrow(root):
    """backup.py init --show-escrow as the setup runs it: the real escrow screen on /dev/tty."""
    password_file = Path(root) / "restic-password"

    def answer(argv, _data):
        password_file.write_text(secrets.token_urlsafe(48) + "\n")
        confirmed = backup.Backup.show_escrow(SimpleNamespace(password_file=password_file,
                                                              ESCROW_NOTE=backup.Backup.ESCROW_NOTE))
        Path(paths.BACKUP_RECORD).write_text(json.dumps({"targets": [{"repository_id": "c0ffee" * 8}]}))
        return 0, json.dumps({"state": "initialized", "repository_id": "c0ffee" * 8,
                              "escrow": "confirmed" if confirmed else "not confirmed"}), ""
    return answer, password_file


def flow(root, scenario, out=sys.stdout, prompter=None, staged=None, heartbeat=0.5):
    """Run the guided install for `scenario` (halo: secrets copied from the VM host, the VM host network;
    household: nothing copied, a home network, a different SSH source). Returns (code, report)."""
    root = Path(root)
    gateway = FakeGateway()
    calls = {"cloudflare": [], "ntfy": []}
    spawned = []
    real_run = subprocess.run

    def recording_run(argv, *args, **kwargs):
        spawned.append([str(part) for part in argv])
        return real_run(argv, *args, **kwargs)

    def cloudflare(token, zone, host, http=None):
        calls["cloudflare"].append({"token_length": len(token), "zone": zone, "host": host})
        return True, f"token works, zone found, record {host} found (A, not proxied)."

    def ntfy(server, topic, opener=None, timeout=15):
        calls["ntfy"].append({"server": server, "topic_length": len(topic)})
        return True, "HTTP 200"
    halo = scenario == "halo"
    if staged is None:
        staged = {"token": "fake-cf-" + secrets.token_hex(16), "topic": "fake-topic-" + secrets.token_hex(11)} \
            if halo else {}
    with sandbox(root):
        answer, password_file = escrow(root)
        system = FakeSystem(dry=False, out=out,
                            responses={f"python3 -I {paths.RELEASE_CURRENT}/deploy/backup.py init": answer})
        facts = FakeFacts(system, route=("10.77.10.10", "10.77.10.1") if halo else ("192.168.1.20", "192.168.1.1"),
                          ssh_client="10.77.10.1" if halo else "192.168.1.50",
                          disks=[{"path": "/dev/vda", "size": 20 << 30, "mounts": ["/"], "children": 2, "fstype": None,
                                  "label": None, "uuid": None, "model": "QEMU HARDDISK"},
                                 {"path": "/dev/vdb", "size": 200 << 30, "mounts": [], "children": 0, "fstype": None,
                                  "label": None, "uuid": None, "model": "QEMU HARDDISK"}],
                          mounted={str(paths.BACKUP_MOUNT): {"source": "anj-backup", "fstype": "virtiofs"}})
        argv = ["--secrets-socket", "/home/anj/.anj-cloud-setup-0123456789abcdef.sock"] if staged else []
        setup_box = {}
        real_init = bootstrap.Setup.__init__

        def init(self, *args, **kwargs):
            real_init(self, *args, **kwargs)
            self.operator = gateway.operator
            setup_box["setup"] = self
        with mock.patch.object(bootstrap.Setup, "__init__", init), \
                mock.patch.object(bootstrap.Setup, "step_list",
                                  lambda self: [FakeStep(self, n, name, s) for n, name, s in STEPS]), \
                mock.patch.object(bootstrap.Status, "collect", lambda self: dict(STATUS)), \
                mock.patch.object(bootstrap, "https_reachable", lambda host, timeout=10: True), \
                mock.patch.object(bootstrap.socket, "getaddrinfo", lambda *a, **k: [()]), \
                mock.patch.object(bootstrap.os, "geteuid", lambda: 0), \
                mock.patch.object(bootstrap, "machine_id", lambda: "fake-machine"), \
                mock.patch.object(bootstrap, "PAIR_POLL_SECONDS", 0.2), \
                mock.patch.object(guide, "HEARTBEAT_SECONDS", heartbeat), \
                mock.patch.object(guide, "read_staged",
                                  lambda path, expected_owner=None, connect=None, seen=None: dict(staged)), \
                mock.patch.object(guide, "cloudflare_check", cloudflare), \
                mock.patch.object(guide, "send_test_alert", ntfy), \
                mock.patch.object(guide.subprocess, "run", recording_run), \
                mock.patch.object(bootstrap.sys.stdin, "isatty", lambda: True):
            code = bootstrap.main(argv, system=system, facts=facts, prompter=prompter, out=out)
        setup = setup_box["setup"]
        evidence = sorted((root / "srv" / "state" / "setup-log").glob("*.json"))
        report = {"code": code, "commands": system.commands, "files": system.files, "spawned": spawned,
                  "evidence": [path.read_text() for path in evidence], "record": bootstrap.SETUP_RECORD.read_text()
                  if bootstrap.SETUP_RECORD.exists() else "", "calls": calls, "gateway_calls": gateway.calls,
                  "secrets": {"token": setup.secrets.get("token"), "topic": setup.secrets.get("topic"),
                              "codes": gateway.codes, "restic": password_file.read_text().strip()
                              if password_file.exists() else None},
                  "topic_file": (paths.NTFY_TOPIC.read_text() if paths.NTFY_TOPIC.exists() else None)}
    return code, report


def main():
    root, scenario = Path(sys.argv[1]), sys.argv[2]
    code, report = flow(root, scenario)
    (root / "report.json").write_text(json.dumps(report))
    print(f"\nFLOW EXIT {code}", flush=True)
    os._exit(0)
