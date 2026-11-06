"""Spec #21 (B2) VM rows on the throwaway anj-qual VM, plus the carried rows of specs #20 and #23.

Run on the VM host by an agent inside a bounded scope (`halo-vm.sh --qual`/`--qual-destroy` touch only
anj-qual, no sudo). The enrolment row needs `cryptography`, so run it with the access venv:

    systemd-run --user --scope --unit=anj-test-<tag>-<n> -p MemoryMax=2G -p TasksMax=512 \\
        deploy/.local/access-venv/bin/python deploy/vm/qualify.py --run-id <tag>-<n> \\
        [--commit HEAD] [--rows a,b,...] [--keep] [--list]

The `upgrade` row (decision #122) updates the installed release to --upgrade-to (default HEAD), so
bootstrap an older one: `--commit origin/main --rows create,stage,install,upgrade`.

The commit defaults to this checkout's HEAD (the PR head before its merge). Rows run in order on
one anj-qual; a row whose prerequisite failed is skipped. `--qual-destroy --run-id` runs in every
outcome unless --keep. Nothing secret is printed or saved: the scratch Cloudflare token is random
and never real, the qualification ntfy topic and pairing codes stay in the VM or in memory, and log
searches use pattern files inside the VM.

Evidence: ~/.local/share/anj-cloud/qualification/f15-b2/qual-<UTC>/ (summary.json, step outputs).
"""

import argparse
import calendar
from collections import Counter
import datetime
import hashlib
import json
import os
from pathlib import Path
import pty
import re
import secrets
import select
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from deploy.vm import paths, stage  # noqa: E402
from deploy.vm.pm2json import jlist_rows  # noqa: E402
from services.access.codes import grouped_pattern  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent.parent
HALO_VM = ROOT / "deploy" / "host" / "halo-vm.sh"
EVIDENCE = Path.home() / ".local" / "share" / "anj-cloud" / "qualification" / "f15-b2"
ANSWERS = ROOT / "deploy" / "vm" / "answers" / "qual.toml"
SETUP = stage.SETUP
COMMAND = "anj-cloud-setup"          # the stable command step 10 links (bootstrap UX S3)
HANDOFF_ANSWERS = "/tmp/qual-handoff.toml"
SCRATCH_TOKEN = "/var/lib/anj-cloud-setup/qual-scratch-token"
CURRENT = paths.RELEASE_CURRENT
OPERATOR = (f"cd {CURRENT} && python3 -m deploy.access_operator --project {paths.PROJECT} "
            f"--state-root {paths.STATE_ROOT}")
PROD = f"python3 {CURRENT}/deploy/prod.py"
ACCESS = f"{paths.PROJECT}-access-1"
PM2_LOGS = "/home/anj/.pm2/logs"
DIGEST = ("sudo find /etc -xdev -type f -print0 | sudo xargs -0 sha256sum | sha256sum | cut -c1-16; "
          "dpkg-query -W | sha256sum | cut -c1-16; (sudo docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo none)")
# Everything doctor could change: the state root (minus run/, rewritten every minute by the
# watchdog and watchers, and setup-log/, written only by setup), /etc and the staged bootstrap
# source (a __pycache__ there would be a write).
STATE_DIGEST = (f"sudo find {paths.STATE_ROOT} /etc /var/lib/anj-cloud-setup -xdev \\( -path {paths.RUN_DIR} -o "
                f"-path {paths.SETUP_LOG_DIR} \\) -prune -o -type f -printf '%p %s %T@\\n' 2>/dev/null | sort | "
                "sha256sum | cut -c1-16")
# PM2 God daemons running (any user) and anj's daemon pid: doctor/status/--dry-run start none.
PM2_DAEMONS = "pgrep -fc 'PM2 v[0-9.]*: God Daemon' || true; cat /home/anj/.pm2/pm2.pid 2>/dev/null || echo none"
ADMIN_ROWS = ("import json,sqlite3\n"
              "db=sqlite3.connect('file:/var/lib/anj/registry.sqlite?mode=ro',uri=True)\n"
              "print(json.dumps({u: a for u, a in db.execute('SELECT uid,admin FROM accounts')}))\n")
# Decision #112 (3): the bootstrap's first-admin write is audited (actor bootstrap, role-grant).
# SC-041: the held user add's audit rows (one, when it finished).
SLOW_AUDIT = ("import json,sqlite3\n"
              "db=sqlite3.connect('file:/var/lib/anj/registry.sqlite?mode=ro',uri=True)\n"
              "print(json.dumps(db.execute(\"SELECT action,result FROM admin_audit WHERE action='user-add' "
              "AND target_uid='qualslow'\").fetchall()))\n")
AUDIT_ROWS = ("import json,sqlite3\n"
              "db=sqlite3.connect('file:/var/lib/anj/registry.sqlite?mode=ro',uri=True)\n"
              "print(json.dumps(db.execute(\"SELECT actor_uid,action,target_uid,result FROM admin_audit "
              "WHERE actor_uid='bootstrap'\").fetchall()))\n")
STEP_RESULT = re.compile(r"^\[\s*\d+/\d+\] .*: (already done|done ✓)")
# A pinned code (decision #151), shown in groups of 4; its length comes from services/access/codes.py.
CODE = re.compile(r"Pairing code for \w+:\s+(" + grouped_pattern() + ")")
# Secret patterns live only in the VM (root, 0700), one file per label, no trailing newline; the
# leak search prints labels, locations and found/clean, never a pattern (the ntfy topic, the
# pairing codes and the scratch token are never on the VM host's disk or in any output).
PATTERNS = "/var/lib/anj-cloud-setup/qual-patterns"
LEAK_LABELS = ("install-code", "reissued-code", "ntfy-topic", "scratch-token")
def piped(producer):
    """`producer | grep -qF -f "$f"` with an honest status: 0 found, 1 clean only when the producer
    succeeded and grep found nothing (exit 1), 2 for any other case: a failing producer, or a grep
    error (exit 2+) (review L-d, round 5 L2). grep -q stops at the first match, so a producer killed
    by SIGPIPE then is a find."""
    return (f'{producer} | grep -qF -f "$f"; s=("${{PIPESTATUS[@]}}"); '
            'if [ "${s[1]}" = 0 ]; then true; elif [ "${s[0]}" = 0 ] && [ "${s[1]}" = 1 ]; then (exit 1); '
            'else (exit 2); fi')


LEAK_LOCATIONS = {
    "setup-log": f"grep -rqsF -f \"$f\" {paths.SETUP_LOG_DIR}",
    "var-log": "grep -rqsF -f \"$f\" --exclude-dir=journal /var/log",
    "pm2-logs": f"grep -rqsF -f \"$f\" {PM2_LOGS} /home/anj/.pm2/pm2.log",
    "state-run": f"grep -rqsF -f \"$f\" {paths.RUN_DIR}",
    "journal": piped("journalctl -o cat --no-pager"),
}


def leak_search_command(patterns=PATTERNS, locations=None, labels=LEAK_LABELS, sudo="sudo "):
    """In-VM: one line "<label> <location> <grep status>" per pattern and place (0 found, 1 clean),
    or "<label> - missing". Prints nothing else; grep -q never prints a match."""
    locations = LEAK_LOCATIONS if locations is None else locations
    checks = " ".join(f"{command}; echo \"$p {name} $?\";" for name, command in locations.items())
    return (f"{sudo}bash -c 'for p in {' '.join(labels)}; do f={patterns}/$p; "
            f"if ! test -s \"$f\"; then echo \"$p - missing\"; continue; fi; {checks} done'")


LEAK_SEARCH = leak_search_command()


def save_pattern(source, label, patterns=PATTERNS, sudo="sudo ", owner="-o root -g root "):
    """In-VM: copy a secret file's content (newlines stripped) into the pattern file `label`."""
    return (f"{sudo}bash -c 'install -d -m 700 {owner}{patterns} && umask 077 && "
            f"tr -d \"\\n\" < {source} > {patterns}/{label}.new && test -s {patterns}/{label}.new && "
            f"mv -f {patterns}/{label}.new {patterns}/{label}'")


# Firewall probes from a source that is not the admin source: a network namespace inside the VM.
NETNS_UP = ("sudo ip netns add anjprobe && sudo ip link add anjp0 type veth peer name anjp1 && "
            "sudo ip link set anjp1 netns anjprobe && sudo ip addr add 10.200.9.1/30 dev anjp0 && "
            "sudo ip link set anjp0 up && sudo ip netns exec anjprobe ip addr add 10.200.9.2/30 dev anjp1 && "
            "sudo ip netns exec anjprobe ip link set anjp1 up && sudo ip netns exec anjprobe ip link set lo up && "
            "sudo ip netns exec anjprobe ip route add default via 10.200.9.1")
NETNS_DOWN = "sudo ip netns del anjprobe 2>/dev/null; sudo ip link del anjp0 2>/dev/null; true"


class Skip(Exception):
    pass


class Qualification:
    def __init__(self, run_id, commit, evidence, *, keep=False, upgrade_to="HEAD"):
        self.run_id, self.commit, self.evidence, self.keep = run_id, commit, Path(evidence), keep
        self.upgrade_to = upgrade_to          # the `upgrade` row's release B (decision #122)
        self.results = []
        self.done = set()
        self.facts = {}

    # Plumbing ---------------------------------------------------------------------------------
    def record(self, check, passed, **detail):
        self.results.append({"check": check, "pass": bool(passed), **detail})
        print(("PASS " if passed else "FAIL ") + check, flush=True)
        return bool(passed)

    def ssh(self, command, *, data=None, timeout=3600):
        try:
            result = subprocess.run(stage.ssh_argv("anj-qual", command), input=data, capture_output=True, text=True,
                                    timeout=timeout, check=False)
        except subprocess.TimeoutExpired:
            return 124, "", "timed out"
        return result.returncode, result.stdout, result.stderr

    def save(self, name, text):
        (self.evidence / name).write_text(text)

    def wait(self, predicate, timeout, interval=10):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate():
                return True
            time.sleep(interval)
        return False

    def ssh_up(self):
        return self.ssh("true", timeout=30)[0] == 0

    def status(self):
        code, out, _ = self.ssh(f"{PROD} status", timeout=300)
        try:
            return json.loads(out) if code == 0 else {}
        except ValueError:
            return {}

    def healthy(self):
        status = self.status()
        return status.get("healthcheck") == "ready" and all(
            (row or {}).get("status") == "online" for row in (status.get("apps") or {}).values()) and status.get("apps")

    def pm2_log(self, app):
        return self.ssh(f"cat {PM2_LOGS}/{app}-out.log 2>/dev/null", timeout=60)[1]

    def count(self, app, text):
        return self.pm2_log(app).count(text)

    def uptime(self):
        try:
            return float(self.ssh("cut -d' ' -f1 /proc/uptime", timeout=30)[1].strip())
        except ValueError:
            return 0.0

    def after_boot_grace(self):
        """The watchdog is quiet for 10 minutes after boot (review M3); wait it out."""
        remaining = 620 - self.uptime()
        if remaining > 0:
            time.sleep(remaining)

    def reboot(self):
        self.ssh("sudo systemctl reboot", timeout=30)
        time.sleep(30)
        return self.wait(self.ssh_up, 600, 10)

    def need(self, *rows):
        missing = [row for row in rows if row not in self.done]
        if missing:
            raise Skip("needs " + ", ".join(missing))

    # Rows ---------------------------------------------------------------------------------
    def row_create(self):
        created = subprocess.run([str(HALO_VM), "--qual", "--run-id", self.run_id], capture_output=True, text=True,
                                 timeout=1800, check=False)
        self.save("halo-vm-qual.log", created.stdout + created.stderr)
        if created.returncode == 3:
            # qual-busy or unknown ownership: stop; never --force a VM this run did not create.
            self.facts["create_refused"] = True
        return self.record("anj-qual created and reachable", created.returncode == 0 and self.wait(self.ssh_up, 600),
                           exit=created.returncode)

    def row_stage(self):
        self.need("create")
        staged = stage.stage(stage.Runner(), "anj-qual", self.commit)
        # Throwaway values, never real ones: the install row hands them over the way
        # `stage.py --with-secrets` does on anj-prod (decision #109).
        self.handoff = {"token": "scratch-" + secrets.token_hex(16), "topic": "qualtopic-" + secrets.token_hex(11)}
        token = self.ssh(f"sudo install -m 600 -o root -g root /dev/stdin {SCRATCH_TOKEN}",
                         data=self.handoff["token"] + "\n")[0]
        pattern = self.ssh(save_pattern(SCRATCH_TOKEN, "scratch-token"))[0]
        answers = self.ssh("umask 077 && cat > /tmp/qual.toml", data=ANSWERS.read_text())[0]
        handoff = "".join(line for line in ANSWERS.read_text().splitlines(keepends=True) if not line.startswith("token_file"))
        answers |= self.ssh(f"umask 077 && cat > {HANDOFF_ANSWERS}", data=handoff)[0]
        # A fresh VM: the bootstrap's preflight requires a synchronized clock; wait for it (bounded)
        # instead of failing the dry run and the install on boot timing.
        started = time.monotonic()
        synced = self.wait(lambda: self.ssh("timedatectl show -p NTPSynchronized --value", timeout=30)[1].strip()
                           == "yes", 600, 10)
        return self.record("release, scratch token and qual.toml staged; clock synchronized",
                           token == 0 and answers == 0 and pattern == 0 and synced, commit=staged["commit"][:12],
                           time_sync_s=round(time.monotonic() - started))

    def row_dry_run(self):
        self.need("stage")
        before = self.ssh(DIGEST)[1]
        code, out, err = self.ssh(f"sudo {SETUP} --dry-run --answers /tmp/qual.toml", timeout=900)
        self.save("dry-run.txt", out + err)
        after = self.ssh(DIGEST)[1]
        return self.record("dry run changes nothing (/etc, packages, Docker) and asks no secret",
                           code == 0 and before == after and "input hidden" not in out,
                           before=before.split(), after=after.split())

    def row_install(self):
        """The install through the secret hand-off (decision #109, throwaway values): the token and
        the topic reach the VM's setup over the forwarded socket, never as an argument; then the
        summary's checklist and client fields (bootstrap UX M3)."""
        self.need("stage")
        output = self.evidence / "install.txt"
        with open(output, "w") as stream:
            # Popen, not run: the hand-off serves only the ssh child it knows by pid (SO_PEERCRED).
            code, served = stage.run_with_secrets("anj-qual", self.handoff, ["--answers", HANDOFF_ANSWERS],
                                                  popen=lambda argv: subprocess.Popen(argv, stdin=subprocess.DEVNULL,
                                                                                      stdout=stream, stderr=stream))
        out = output.read_text(errors="replace")
        address = self.ssh(f"python3 -c 'import json;print(json.load(open(\"{paths.STACK_CONFIG}\"))[\"bind_address\"])'",
                           timeout=30)[1].strip()
        self.facts.update(address=address, host=self.status().get("host"))
        sums = self.ssh(f"sudo sha256sum {paths.CLOUDFLARE_TOKEN} {paths.NTFY_TOPIC}", timeout=30)[1].split()
        delivered = sums[::2] == [hashlib.sha256((self.handoff[key] + "\n").encode()).hexdigest() for key in ("token", "topic")]
        sockets = self.ssh(f"ls /home/{paths.VM_USER}/.anj-cloud-setup-*.sock 2>/dev/null | wc -l", timeout=30)[1].strip()
        # The VM end sshd created is owner-only: sshd's StreamLocalBindMask, and the mode setup saw.
        mask = self.ssh("sudo sshd -T | grep -i '^streamlocalbindmask'", timeout=30)[1].split()
        handoff = self.ssh(f"sudo sh -c 'cat $(ls -t {paths.SETUP_LOG_DIR}/*.json | tail -n 1)'", timeout=30)[1]
        try:
            seen = (json.loads(handoff).get("handoff") or {})
        except ValueError:
            seen = {}
        owner_only = mask[1:] == ["0177"] and seen.get("socket_mode") == "0o600" and \
            sorted(seen.get("read") or []) == ["Cloudflare DNS token", "ntfy alert topic"]
        # Read now: the first-code file is swept once its invitation expires (10 minutes). The
        # install-time code and the topic become in-VM patterns for the leak search (review: both
        # codes and the topic), never read onto the VM host.
        mode = self.ssh(f"sudo stat -c '%a %U' {paths.FIRST_PAIRING_CODE} 2>/dev/null || echo absent", timeout=30)[1]
        self.facts["code_file_mode"] = mode.strip()
        patterns = [self.ssh(save_pattern(source, label), timeout=30)[0] == 0
                    for source, label in ((paths.FIRST_PAIRING_CODE, "install-code"), (paths.NTFY_TOPIC, "ntfy-topic"))]
        host = self.facts["host"]
        summary = {"progress [n/12]": "[12/12] Turning on security updates: done ✓" in out,
                   "checklist": "What to do now, in order:" in out,
                   "server origin": f"Server       https://{host}" in out,
                   "code only": "Code         the pairing code" in out and "CA file" not in out
                   and "Check approval" not in out,
                   "pair command": f"sudo {COMMAND} pair" in out,
                   "no code on stdout": "Pairing code for" not in out}
        return self.record("bootstrap via answers file completes (ddns off); token and topic handed over the forwarded "
                           "socket (owner-only, 0600; StreamLocalBindMask 0177), byte-exact, socket removed; summary "
                           "checklist with the client fields",
                           code == 0 and served and delivered and sockets == "0" and owner_only and self.healthy()
                           and all(patterns) and all(summary.values()), address=address,
                           code_file=self.facts["code_file_mode"], handed_over=served, delivered=delivered,
                           sockets_left=sockets, stream_local_bind_mask=mask[1:], socket_mode=seen.get("socket_mode"),
                           **summary)

    def row_status_doctor(self):
        """status ready; doctor passes and changes nothing; with pm2-anj.service down, doctor, status
        and --dry-run on the complete install start no PM2 daemon and change nothing (L2, R3)."""
        self.need("install")
        results = {}
        code, out, _ = self.ssh(f"{SETUP} status --json", timeout=600)
        self.save("status.json", out)
        results["status ready"] = code == 0 and '"healthcheck": "ready"' in out
        before, daemons = self.ssh(STATE_DIGEST)[1], self.ssh(PM2_DAEMONS)[1]
        doctor, text, err = self.ssh(f"sudo {SETUP} doctor", timeout=1800)
        self.save("doctor.txt", text + err)
        results["doctor passes"] = doctor == 0
        results["doctor changed nothing"] = self.ssh(STATE_DIGEST)[1] == before
        results["doctor kept the one PM2 daemon"] = self.ssh(PM2_DAEMONS)[1] == daemons and daemons.split()[0] == "1"
        self.ssh("sudo systemctl stop pm2-anj.service", timeout=300)
        try:
            results["PM2 stopped for the check"] = self.ssh(PM2_DAEMONS)[1].split()[0] == "0"
            before = self.ssh(STATE_DIGEST)[1]
            doctor, text, err = self.ssh(f"sudo {SETUP} doctor", timeout=1800)
            self.save("doctor-pm2-down.txt", text + err)
            results["PM2 down: doctor names it"] = doctor == 1 and "PM2 not running" in text
            status, out, err = self.ssh(f"{SETUP} status --json", timeout=600)
            self.save("status-pm2-down.json", out + err)
            results["PM2 down: status answers"] = status == 0
            dry, text, err = self.ssh(f"sudo {SETUP} --dry-run --answers /tmp/qual.toml", timeout=900)
            self.save("dry-run-pm2-down.txt", text + err)
            results["PM2 down: dry run answers"] = "Dry run: nothing is changed" in text
            results["PM2 down: no PM2 daemon started"] = self.ssh(PM2_DAEMONS)[1].split()[0] == "0"
            results["PM2 down: nothing changed"] = self.ssh(STATE_DIGEST)[1] == before
        finally:
            self.ssh("sudo systemctl start pm2-anj.service", timeout=600)
            results["healthy again"] = self.wait(self.healthy, 900, 15)
        return self.record("status ready; doctor passes; doctor, status and --dry-run change nothing and start no "
                           "PM2 daemon (PM2 up and PM2 down)", all(results.values()), **results)

    def restart_counts(self):
        _code, out, _ = self.ssh("pm2 jlist", timeout=120)
        try:
            return {row["name"]: row["pm2_env"]["restart_time"] for row in jlist_rows(out)}
        except (ValueError, KeyError, TypeError):
            return None

    def first_invite(self):
        return json.loads(self.ssh(f"cat {paths.STATE_ROOT}/setup.json", timeout=30)[1] or "{}").get("first_invite") or {}

    def row_idempotence(self):
        self.need("install")
        restarts, invite = self.restart_counts(), self.first_invite().get("id")
        code, out, err = self.ssh(f"sudo {SETUP} --answers /tmp/qual.toml", timeout=3600)
        self.save("rerun.txt", out + err)
        steps = [line for line in out.splitlines() if STEP_RESULT.match(line)]
        return self.record("idempotence: every step already done, no restart, no second first code",
                           code == 0 and len(steps) == 12 and all(": already done" in line for line in steps)
                           and self.restart_counts() == restarts and self.first_invite().get("id") == invite,
                           restarts_before=restarts)

    def row_firewall(self):
        self.need("install")
        address, host = self.facts["address"], self.facts["host"]
        issuer = self.ssh(f"cat {paths.OPERATOR_DIR}/issuer.crt", timeout=30)[1]
        with tempfile.NamedTemporaryFile("w", suffix=".crt") as cafile:
            cafile.write(issuer)
            cafile.flush()
            halo = https_status(address, host, cafile.name)
        self.ssh(NETNS_DOWN, timeout=60)
        try:
            built = self.ssh(NETNS_UP, timeout=60)[0] == 0
            ssh_blocked = self.ssh(f"sudo ip netns exec anjprobe timeout 5 bash -c '</dev/tcp/{address}/22'",
                                   timeout=30)[0] != 0
            https_open = self.ssh(f"sudo ip netns exec anjprobe timeout 5 bash -c '</dev/tcp/{address}/443'",
                                  timeout=30)[0] == 0
        finally:
            self.ssh(NETNS_DOWN, timeout=60)
        tables = self.ssh("sudo nft list tables", timeout=30)[1]
        return self.record("firewall: 443 from the VM host (outside the VM) and from a non-admin source; 22 refused from "
                           "a non-admin source; Docker's tables intact",
                           halo == 200 and built and ssh_blocked and https_open and "table ip nat" in tables
                           and "table ip filter" in tables, halo_health=halo)

    def admin_rows(self):
        code, out, _ = self.ssh(f"docker exec -i --user {paths.GATEWAY_UID}:{paths.GATEWAY_GID} {ACCESS} python -",
                                data=ADMIN_ROWS, timeout=60)
        try:
            return json.loads(out) if code == 0 else {}
        except ValueError:
            return {}

    def row_first_admin(self):
        self.need("install")
        roles = self.admin_rows()
        mode = self.facts.get("code_file_mode")
        code, out, _ = self.ssh(f"docker exec -i --user {paths.GATEWAY_UID}:{paths.GATEWAY_GID} {ACCESS} python -",
                                data=AUDIT_ROWS, timeout=60)
        try:
            audit = json.loads(out) if code == 0 else None
        except ValueError:
            audit = None
        return self.record("first admin: sam admin, alex not, one audit entry (bootstrap role-grant sam, #112 (3)); "
                           "the first code was only in a 0600 anj file",
                           roles.get("sam") == 1 and roles.get("alex") == 0 and mode == "600 anj"
                           and audit == [["bootstrap", "role-grant", "sam", "ok"]],
                           roles=roles, code_file_at_install=mode, audit=audit)

    def row_pair_commands(self):
        """M2 without a terminal (#104 (5), (6)): `pair --new-code` replaces the code (0600 file),
        `pair` never replaces a live one, `first-code --reissue` still works; status through the
        stable command."""
        self.need("install")
        results = {"status via /usr/local/bin": self.ssh(f"{COMMAND} status --json", timeout=600)[0] == 0}
        before = self.first_invite().get("id")
        results["pair --new-code replaced it"] = self.ssh(f"sudo {COMMAND} pair --new-code", timeout=600)[0] == 0 and \
            self.first_invite().get("id") not in (None, before)
        live = self.first_invite().get("id")
        code, out, _ = self.ssh(f"sudo {COMMAND} pair", timeout=600)
        self.save("pair-no-terminal.txt", out)
        results["pair kept the live code"] = code == 0 and self.first_invite().get("id") == live and \
            "Pairing code for" not in out
        results["code file 0600 anj"] = self.ssh(f"sudo stat -c '%a %U' {paths.FIRST_PAIRING_CODE}", timeout=30)[1].strip() \
            == "600 anj"
        results["first-code --reissue"] = self.ssh(f"sudo {COMMAND} first-code --reissue", timeout=600)[0] == 0 and \
            self.first_invite().get("id") != live
        return self.record("pair without a terminal: --new-code replaces, a live code is kept, first-code --reissue; "
                           "status through the stable command", all(results.values()), **results)

    def row_enrol(self):
        """M2 at a terminal: `sudo anj-cloud-setup pair --new-code` over `ssh -tt` shows the grouped
        code; a synthetic device enrols with it through HAProxy and the gateway approves it by itself
        (decision #151: no fingerprint typed); setup reports it paired; then mTLS DAV. Neither pairing code nor the ntfy topic is in any log or output."""
        self.need("install")
        from deploy.vm import qual_client  # needs cryptography: run with the access venv
        issuer = self.ssh(f"cat {paths.OPERATOR_DIR}/issuer.crt", timeout=30)[1]
        state = Path(tempfile.mkdtemp(prefix="anj-qual-device-"))
        terminal = PtySession(["ssh", "-F", str(stage.SSH_CONFIG), "-tt", "anj-qual", f"sudo {COMMAND} pair --new-code"])
        pending, approved, dav, saved, code = {}, False, {}, False, None
        try:
            ready = terminal.read_until("Press Enter when ready, or type 'later': ", 300)
            if ready:
                terminal.send("")                    # the app is open (the qual client)
            shown = ready and terminal.read_until("Waiting for the app to pair", 300)
            match = CODE.search(terminal.output)
            code = match.group(1) if (shown and match) else None
            if code:
                saved = self.ssh(f"sudo bash -c 'install -d -m 700 -o root -g root {PATTERNS} && umask 077 && "
                                 f"cat > {PATTERNS}/reissued-code'", data=code.replace("-", ""), timeout=30)[0] == 0
                (state / "issuer.crt").write_text(issuer)
                client = qual_client.Client(self.facts["address"], self.facts["host"], state / "issuer.crt", state)
                pending = client.enroll(code)
                approved = terminal.read_until("Paired: ", 300)
                dav = client.dav(code) if approved else {}
        finally:
            transcript = terminal.close()
            self.save("pair-terminal.txt", transcript.replace(code, "[pairing code]") if code else transcript)
            code = None
            # The approved device (sam's, write grant) is the console row's admin client; its key
            # stays in this the VM host temp directory, 0700, removed when the run ends.
            if dav.get("get") == 200:
                self.facts["device_state"] = state
            else:
                subprocess.run(["rm", "-rf", str(state)], check=False)
        clean, leaks = self.leak_search()
        return self.record("pair at a terminal: grouped code shown once, the device enrols through HAProxy and is "
                           "approved automatically, mTLS DAV write/read; neither pairing code nor the ntfy "
                           "topic is in any VM log, journal, PM2 log or this run's outputs",
                           saved and pending.get("enroll") == 200 and approved and dav.get("put") in (201, 204)
                           and dav.get("get") == 200 and dav.get("sha256_match") and clean,
                           enroll=pending.get("enroll"), approved=approved, dav=dav, leaks=leaks)

    def console_socket_facts(self):
        """The backend's directory and socket (owner, group, mode), the gateway mount and the
        gateway process's groups and capabilities, read inside the VM."""
        script = (
            "import json,os,stat,subprocess\n"
            f"d='{paths.CONSOLE_DIR}'\ns=d+'/{paths.CONSOLE_SOCKET_NAME}'\nout={{}}\n"
            "for k,p in (('dir',d),('socket',s)):\n"
            "    try:\n        i=os.lstat(p)\n"
            "        out[k]=[i.st_uid,i.st_gid,oct(stat.S_IMODE(i.st_mode)),stat.S_ISSOCK(i.st_mode)]\n"
            "    except OSError as e:\n        out[k]=type(e).__name__\n"
            "import pwd\nout['anj_uid']=pwd.getpwnam('anj').pw_uid\n"
            f"m=json.loads(subprocess.run(['docker','inspect','--format','{{{{json .Mounts}}}}','{ACCESS}'],"
            "capture_output=True,text=True).stdout or '[]')\n"
            "out['mount']=[[x.get('Source'),x.get('RW')] for x in m if x.get('Destination')==d]\n"
            f"pid=subprocess.run(['docker','inspect','--format','{{{{.State.Pid}}}}','{ACCESS}'],capture_output=True,"
            "text=True).stdout.strip()\n"
            # The container's first process is the server: access.start drops and execs in place.
            "for line in open('/proc/%s/status'%pid):\n"
            "    if line.startswith(('Uid:','Groups:','CapEff:')):\n"
            "        out[line.split(':')[0]]=line.split(':',1)[1].split()\n"
            "print(json.dumps(out))\n")
        code, out, _ = self.ssh("sudo python3 -", data=script, timeout=60)
        try:
            return json.loads(out.strip().splitlines()[-1]) if code == 0 else {}
        except (ValueError, IndexError):
            return {}

    def row_console(self):
        """Decision #112 (1) and SC-041 on anj-qual: the bootstrap started the PM2 app `console`;
        its socket is private (2750 anj:anj-gw directory, 0660 socket, mounted read-only into the
        gateway, whose process keeps group anj-gw and no capability; another account is refused;
        no network listener); the watchdog checks it; the enrolled admin device lists users and
        makes a confirmed role change through HAProxy and the gateway; Health reads PM2 through the
        backend; a user add held 150 s behind the operator lock is not cut (every exchange
        answered within the gateway's hold, the account added, setup incomplete while it ran);
        anj-cloud-admin runs over SSH."""
        self.need("install", "enrol")
        from deploy.vm import qual_client
        results, detail = {}, {}
        apps = {row.get("name"): row for row in jlist_rows(self.ssh("pm2 jlist", timeout=120)[1] or "[]")}
        console = apps.get(paths.CONSOLE_APP) or {}
        results["console app online (started by the bootstrap)"] = (console.get("pm2_env") or {}).get("status") == "online"
        ecosystem = self.ssh(f"cat {paths.STATE_ROOT}/ops/ecosystem.config.js", timeout=30)[1]
        results["in the operations ecosystem"] = f'"name": "{paths.CONSOLE_APP}"' in ecosystem
        facts = self.console_socket_facts()
        detail["socket"] = facts
        anj = facts.get("anj_uid")
        results["directory 2750 anj:anj-gw"] = facts.get("dir") == [anj, paths.GATEWAY_GID, "0o2750", False]
        results["socket 0660 anj:anj-gw"] = facts.get("socket") == [anj, paths.GATEWAY_GID, "0o660", True]
        results["mounted read-only into the gateway"] = facts.get("mount") == [[str(paths.CONSOLE_DIR), False]]
        results["gateway: uid 10001, groups [10002], no capability"] = (
            (facts.get("Uid") or [None])[0] == str(paths.GATEWAY_UID) and facts.get("Groups") == [str(paths.GATEWAY_GID)]
            and int((facts.get("CapEff") or ["1"])[0], 16) == 0)
        probe = ("python3 -c \"import socket,sys;c=socket.socket(socket.AF_UNIX);c.settimeout(5)\n"
                 f"try:\n c.connect('{paths.CONSOLE_SOCKET}');c.sendall(b'{{}}');c.shutdown(1);"
                 "print('reply' if c.recv(99) else 'nothing')\nexcept OSError as e:\n print(type(e).__name__)\"")
        detail["nobody"] = self.ssh(f"sudo -u nobody {probe}", timeout=60)[1].strip()
        detail["anj"] = self.ssh(probe, timeout=60)[1].strip()
        results["another account is refused, anj is served"] = detail["nobody"] == "PermissionError" and detail["anj"] == "reply"
        pid = console.get("pid")
        listeners = self.ssh("sudo ss -tulpnH", timeout=60)[1]
        results["no network listener"] = bool(pid) and f"pid={pid}," not in listeners
        # The admin device, through HAProxy and the gateway, as the app calls them.
        client = qual_client.Client(self.facts["address"], self.facts["host"],
                                    Path(self.facts["device_state"]) / "issuer.crt", self.facts["device_state"])
        status, account, _ = client.admin("GET", "/v1/account")
        results["account: sam, admin"] = status == 200 and (account or {}).get("uid") == "sam" and \
            (account or {}).get("admin") is True
        status, users, _ = client.admin_action("GET", "/v1/admin/users")
        rows = {row["uid"]: row for row in (users or {}).get("users", [])} if status == 200 else {}
        results["users: sam admin, alex not"] = rows.get("sam", {}).get("admin") is True and rows.get("alex", {}).get("admin") is False
        roles = []
        for admin in (True, False):
            status, users, _ = client.admin_action("GET", "/v1/admin/users")
            expect = next((row["revision"] for row in (users or {}).get("users", []) if row["uid"] == "alex"), None)
            first, prompt, _ = client.admin("POST", "/v1/admin/users/alex/admin", {"admin": admin, "expect": expect})
            status, reply, _ = client.confirmed("POST", "/v1/admin/users/alex/admin", {"admin": admin, "expect": expect})
            roles.append([first, (prompt or {}).get("error"), status, (reply or {}).get("admin")])
        detail["role_change"] = roles
        results["role change asks for confirmation, then applies (grant, remove)"] = roles == [
            [428, "confirmation-required", 200, True], [428, "confirmation-required", 200, False]]
        status, health, _ = client.admin_action("GET", "/v1/admin/health")
        pm2 = ((health or {}).get("server") or {}).get("pm2") if isinstance(health, dict) else None
        detail["health"] = {"status": status, "pm2": (pm2 or {}).get("state")}
        names = {app.get("name"): app.get("status") for app in (pm2 or {}).get("apps", [])}
        results["health reads PM2 through the backend"] = status == 200 and names.get(paths.CONSOLE_APP) == "online"
        # SC-041: an action longer than HAProxy's 120 s idle limit, held behind the operator lock.
        lock = f"{paths.OPERATOR_DIR}/operation.lock"
        held = self.ssh(f"setsid -f flock {lock} sleep 150 </dev/null >/dev/null 2>&1; sleep 2; "
                        f"flock -n {lock} true && echo free || echo held", timeout=60)[1].strip()
        started, outcome = time.monotonic(), {}

        def slow():
            outcome["reply"] = client.admin_action("POST", "/v1/admin/users", {"uid": "qualslow", "display_name": "Qual Slow"})
            outcome["seconds"] = round(time.monotonic() - started)
        worker = threading.Thread(target=slow, daemon=True)
        worker.start()
        time.sleep(45)                          # past the first hold: the action is running in the gateway
        _, users, _ = client.admin_action("GET", "/v1/admin/users")
        midway = {row["uid"]: row for row in (users or {}).get("users", [])}.get("qualslow", {})
        detail["slow_midway"] = {key: midway.get(key) for key in ("setup_incomplete", "enabled")}
        worker.join(400)
        status, reply, exchanges = outcome.get("reply") or (None, None, [])
        elapsed = outcome.get("seconds")
        _, users, _ = client.admin_action("GET", "/v1/admin/users")
        added = {row["uid"]: row for row in (users or {}).get("users", [])}.get("qualslow", {})
        audit = self.ssh(f"docker exec -i --user {paths.GATEWAY_UID}:{paths.GATEWAY_GID} {ACCESS} python -",
                         data=SLOW_AUDIT, timeout=60)[1].strip()
        detail["slow"] = {"lock": held, "status": status, "seconds": elapsed, "exchanges": exchanges, "audit": audit}
        results["a 150 s user add is not cut: setup incomplete while it ran, then added, audited once"] = (
            held == "held" and midway.get("setup_incomplete") is True and status == 201
            and (reply or {}).get("state") == "created" and (elapsed or 0) > 120
            and all(seconds < 60 for _status, seconds in exchanges) and exchanges[0][0] == 202
            and added.get("enabled") is True and not added.get("setup_incomplete") and audit == '[["user-add", "ok"]]')
        # Last: the watchdog is quiet for 10 minutes after boot (run console-1 checked inside that
        # grace and saw only suppressed rounds); by now the grace is usually over.
        self.after_boot_grace()

        def watched():
            rounds = [row for row in self.events("watchdog") if row.get("event") == "watchdog"
                      and paths.CONSOLE_APP in (row.get("apps") or {})]
            detail["watchdog"] = rounds[-1]["apps"][paths.CONSOLE_APP] if rounds else None
            return detail["watchdog"] == "ok"
        results["the watchdog checks it"] = self.wait(watched, 240, 30)
        code, out, err = self.ssh("command -v anj-cloud-admin && readlink /usr/local/bin/anj-cloud-admin && "
                                  "anj-cloud-admin admins && anj-cloud-admin health", timeout=300)
        self.save("anj-cloud-admin.txt", out + err)
        results["anj-cloud-admin runs (admins, health)"] = code == 0 and "sam" in out and \
            f"{paths.RELEASE_CURRENT}/deploy/vm/anj-cloud-admin" in out
        self.save("console.json", json.dumps({"results": results, "detail": detail}, indent=2) + "\n")
        return self.record("console backend in production: PM2 app console started by the bootstrap; private socket "
                           "(2750 anj:anj-gw, 0660, read-only in the gateway, group anj-gw, no capability; other "
                           "accounts refused; no listener); watched; admin device lists users and changes a role with "
                           "confirmation through HAProxy; a 150 s action is not cut; anj-cloud-admin runs",
                           all(results.values()), **results)

    def row_adopt_same_disk(self):
        self.need("install")
        roles, invite = self.admin_rows(), self.first_invite().get("id")
        code, out, err = self.ssh(f"sudo {SETUP} --adopt-data --answers /tmp/qual.toml", timeout=3600)
        self.save("adopt.txt", out + err)
        return self.record("--adopt-data on the existing disk keeps roles and issues no code (partial: the "
                           "OS-rebuild form needs halo-vm.sh --recreate-os on anj-prod)",
                           code == 0 and self.admin_rows() == roles and self.first_invite().get("id") == invite)

    def doctor_reports(self, text):
        code, out, err = self.ssh(f"sudo {SETUP} doctor", timeout=1800)
        return code == 1 and text in out, out

    def row_doctor_failures(self):
        self.need("install")
        results = {}
        self.ssh("pm2 stop cron", timeout=120)
        try:
            results["stopped app"], out = self.doctor_reports("PM2 app cron is stopped")
            status = self.ssh(f"{SETUP} status --json", timeout=600)[1]
            results["status shows it"] = '"cron": "stopped"' in status
        finally:
            self.ssh("pm2 start cron", timeout=120)
        self.ssh("sudo nft delete table inet anj_cloud", timeout=30)
        try:
            results["missing firewall table"], out = self.doctor_reports("table inet anj_cloud is not loaded")
        finally:
            self.ssh("sudo systemctl reload anj-cloud-firewall.service", timeout=60)
        free = self.ssh(f"df --output=avail -B1 {paths.DATA_ROOT} | tail -n1", timeout=30)[1].strip()
        size = self.ssh(f"df --output=size -B1 {paths.DATA_ROOT} | tail -n1", timeout=30)[1].strip()
        filler = f"{paths.DATA_ROOT}/qual-fill"
        try:
            fill = int(free) - int(int(size) * 0.05)      # leave 5 %: above the 90 % warning
            self.ssh(f"sudo fallocate -l {fill} {filler}", timeout=300)
            results["full data disk"], out = self.doctor_reports("The data disk is")
        finally:
            self.ssh(f"sudo rm -f {filler}", timeout=60)
        return self.record("status and doctor failure rows: stopped app, missing firewall table, full data disk",
                           all(results.values()), **results)

    def row_updates(self):
        """Security-only origins; with a backup marker, spec #22's `window --check` says busy and
        systemd skips the update run on its ExecCondition (not on any other condition or error)."""
        self.need("install")
        _code, dump, _ = self.ssh("apt-config dump | grep -E 'Origins-Pattern|Automatic-Reboot'", timeout=60)
        _code, out, err = self.ssh("sudo unattended-upgrade --dry-run --debug 2>&1 | grep 'Allowed origins'", timeout=1200)
        origins = (out + err).strip()
        window = f"python3 -I {CURRENT}/deploy/backup.py window --check >/dev/null 2>&1; echo $?"
        results = {"window clear without a marker": self.ssh(window, timeout=120)[1].strip() == "0"}
        marker = paths.BACKUP_IN_PROGRESS
        self.ssh(f"echo '{{\"deadline_epoch\": '$(( $(date +%s) + 900 ))'}}' > {marker}", timeout=30)
        try:
            results["window busy with the marker"] = self.ssh(window, timeout=120)[1].strip() == "1"
            since = self.ssh("date +%s", timeout=30)[1].strip()
            self.ssh("sudo systemctl start apt-daily-upgrade.service", timeout=600)
            result = self.ssh("systemctl show -p Result --value apt-daily-upgrade.service", timeout=30)[1].strip()
            journal = self.ssh(f"sudo journalctl -u apt-daily-upgrade.service --since @{since} -o cat", timeout=60)[1]
            self.save("updates-journal.txt", journal)
        finally:
            self.ssh(f"rm -f {marker}", timeout=30)
        results["window clear after the marker"] = self.ssh(window, timeout=120)[1].strip() == "0"
        results["skipped by its ExecCondition"] = result == "exec-condition" and \
            "Skipped due to 'exec-condition'" in journal
        from deploy.vm.bootstrap import allowed_origins
        labels = {label for _origin, label in allowed_origins(origins)}
        results["security origins only"] = labels == {"Debian-Security"} and 'Automatic-Reboot "false"' in dump
        return self.record("security-only updates; the update run is skipped on its ExecCondition while a backup "
                           "marker is active", all(results.values()), origins=origins, result=result, **results)

    def row_hung_gateway(self):
        """SIGSTOP on access (alive, not answering): within 4 minutes one watchdog `pm2 restart
        gateway`, exactly one "restarted" message delivered, healthy again, no "down"."""
        self.need("install")
        self.after_boot_grace()
        self.wait(self.healthy, 600, 15)
        restarts, queued, sent = self.watchdog_restarts("gateway"), self.watchdog_alerts(), self.sent_alerts()
        self.ssh(f"sudo docker kill --signal SIGSTOP {ACCESS}", timeout=60)
        started = time.monotonic()
        restarted = self.wait(lambda: self.watchdog_restarts("gateway") > restarts, 300, 15)
        elapsed = time.monotonic() - started
        healthy = self.wait(self.healthy, 300)
        delivered = self.wait(lambda: self.sent_alerts()["watchdog:restart:gateway"] >
                              sent["watchdog:restart:gateway"], 180, 10)
        time.sleep(60)                         # a late second restart or "down" would show by now
        raised = delta(self.watchdog_alerts(), queued)
        delivered_keys = delta(self.sent_alerts(), sent)
        return self.record("hung gateway (SIGSTOP) restarted within 4 minutes, one 'restarted' message, no 'down'",
                           restarted and elapsed <= 240 and healthy and delivered
                           and self.watchdog_restarts("gateway") - restarts == 1
                           and raised == {"watchdog:restart:gateway": 1}
                           and delivered_keys.get("watchdog:restart:gateway") == 1, seconds=round(elapsed),
                           raised=raised, delivered=delivered_keys)

    def row_watchdog_quiet(self):
        """No restart and no watchdog alert while a backup marker is before its deadline, or for the
        emergency stop."""
        self.need("install")
        self.after_boot_grace()
        self.wait(self.healthy, 600, 15)
        restarts, queued = self.watchdog_restarts(), self.watchdog_alerts()
        marker = paths.BACKUP_IN_PROGRESS
        self.ssh(f"echo '{{\"deadline_epoch\": '$(( $(date +%s) + 600 ))'}}' > {marker}", timeout=30)
        self.ssh(f"sudo docker kill --signal SIGSTOP {ACCESS}", timeout=60)
        time.sleep(270)
        quiet_marker = self.watchdog_restarts() == restarts and not delta(self.watchdog_alerts(), queued)
        self.ssh(f"sudo docker kill --signal SIGCONT {ACCESS}; rm -f {marker}", timeout=60)
        self.wait(self.healthy, 300)
        restarts, queued = self.watchdog_restarts(), self.watchdog_alerts()
        self.ssh(f"{PROD} emergency-stop --reason qualification", timeout=600)
        time.sleep(270)
        quiet_stop = self.watchdog_restarts() == restarts and not delta(self.watchdog_alerts(), queued)
        status = self.status()
        self.ssh(f"{PROD} resume", timeout=900)
        self.wait(self.healthy, 600, 15)
        return self.record("watchdog raises none (no restart, no watchdog alert) under a backup marker and for the "
                           "emergency stop", quiet_marker and quiet_stop and status.get("emergency_stop") is True,
                           quiet_marker=quiet_marker, quiet_stop=quiet_stop)

    def restart_times(self, app):
        """Epoch seconds of the watchdog's `pm2 restart <app>` runs (its own log's UTC times)."""
        times = []
        for row in self.events("watchdog"):
            if row.get("event") == "watchdog-restart" and row.get("app") == app:
                try:
                    times.append(datetime.datetime.strptime(row["time"], "%Y-%m-%dT%H:%M:%SZ").replace(
                        tzinfo=datetime.timezone.utc).timestamp())
                except (KeyError, ValueError):
                    continue
        return times

    def alert_times(self, key):
        times = []
        for row in self.events("watchdog"):
            if row.get("event") == "watchdog-alert" and row.get("key") == key:
                try:
                    times.append(datetime.datetime.strptime(row["time"], "%Y-%m-%dT%H:%M:%SZ").replace(
                        tzinfo=datetime.timezone.utc).timestamp())
                except (KeyError, ValueError):
                    continue
        return times

    def seed_watchdog(self, app, restarts_ago):
        """Stop the watchdog, record `restarts_ago` (seconds) as its recent restarts of `app` in
        state/run/watchdog.json, start it again: a cap is then one real hang away (decision #111;
        the hour's timing is proven by the unit tests with a fake clock)."""
        script = ("import json,os,sys,time\n"
                  f"p='{paths.RUN_DIR}/watchdog.json'\n"
                  "s=json.load(open(p)) if os.path.exists(p) else {}\n"
                  f"row=s.setdefault('apps',{{}}).setdefault('{app}',{{}})\n"
                  f"row.update(restarts=[time.time()-a for a in {list(restarts_ago)!r}], restarted_at=None, down=False,"
                  " fails=0, cap_alerted_at=None, unhealthy_since=None)\n"
                  "t=p+'.seed'\nfd=os.open(t,os.O_WRONLY|os.O_CREAT|os.O_TRUNC,0o600)\n"
                  "os.write(fd,json.dumps(s).encode());os.close(fd);os.replace(t,p)\n")
        stopped = self.ssh("pm2 stop watchdog", timeout=120)[0] == 0
        seeded = self.ssh("python3 -", data=script, timeout=60)[0] == 0
        started = self.ssh("pm2 start watchdog", timeout=120)[0] == 0
        return stopped and seeded and started

    def row_watchdog_cap(self):
        """The cap's wiring with one real hang (decision #111: at most 2 watchdog restarts per app per
        hour): two recent restarts seeded into watchdog.json, then SIGSTOP on access -> one "down, not
        restarting" alert, no restart then or 3 minutes later; healthy again -> one "recovered"."""
        self.need("install")
        self.after_boot_grace()
        self.wait(self.healthy, 600, 15)
        cap_key = "watchdog:cap:gateway"
        seeded = self.seed_watchdog("gateway", (1200, 600))
        restarts, queued, sent = self.watchdog_restarts("gateway"), self.watchdog_alerts(), self.sent_alerts()
        self.ssh(f"sudo docker kill --signal SIGSTOP {ACCESS}", timeout=60)
        started = time.monotonic()
        capped = self.wait(lambda: self.watchdog_alerts()[cap_key] > queued[cap_key], 420, 15)
        cap_seconds = round(time.monotonic() - started)
        time.sleep(180)                         # a restart would show within three more checks
        not_restarted = self.watchdog_restarts("gateway") == restarts
        self.ssh("pm2 restart gateway", timeout=300)
        recovered = self.wait(lambda: self.watchdog_alerts()["watchdog:recovered:gateway"] >
                              queued["watchdog:recovered:gateway"], 600, 30)
        self.wait(lambda: self.sent_alerts()["watchdog:recovered:gateway"] > sent["watchdog:recovered:gateway"], 180, 10)
        raised, delivered = delta(self.watchdog_alerts(), queued), delta(self.sent_alerts(), sent)
        expected = {cap_key: 1, "watchdog:recovered:gateway": 1}
        return self.record("watchdog cap (seeded with 2 restarts this hour): one hang -> one 'down, not restarting' "
                           "alert, no further restart; one 'recovered'", seeded and capped and not_restarted
                           and recovered and raised == expected
                           and {k: v for k, v in delivered.items() if k.startswith("watchdog:")} == expected,
                           cap_seconds=cap_seconds, raised=raised, delivered=delivered)

    def boot_health(self):
        return self.ssh("sudo journalctl -b -u anj-cloud-boot-health.service -o cat", timeout=60)[1]

    def row_reboot(self):
        """Spec #21 post-reboot notice and spec #20's PM2 resurrect; no watchdog restart in the first
        10 minutes after boot (review M3)."""
        self.need("install")
        restarts = self.watchdog_restarts()
        rebooted = self.reboot()
        healthy = self.wait(self.healthy, 600, 15)
        notice = self.wait(lambda: '"result": "healthy"' in self.boot_health(), 660, 20)
        self.after_boot_grace()
        quiet = self.watchdog_restarts() == restarts
        return self.record("reboot: PM2 resurrects the stack; one 'back healthy' notice within 10 minutes; no "
                           "watchdog restart in the first 10 minutes", rebooted and healthy and notice and quiet)

    def row_reboot_emergency(self):
        """Spec #20: the emergency stop persists across a reboot (haproxy and gateway stopped, 443
        refuses, the other apps online); the boot notice is "healthy" and states the stop."""
        self.need("install")
        self.wait(self.healthy, 600, 15)
        self.ssh(f"{PROD} emergency-stop --reason qualification", timeout=600)
        results = {}
        try:
            results["rebooted"] = self.reboot()
            results["boot notice"] = self.wait(lambda: self.boot_health_result().get("result") == "healthy", 900, 20)
            notice = self.boot_health_result()
            results["stop stated"] = notice.get("emergency_stop_stated") is True
            status = self.status()
            apps = {app: (row or {}).get("status") for app, row in (status.get("apps") or {}).items()}
            results["flag kept"] = status.get("emergency_stop") is True
            results["haproxy and gateway stopped"] = all(apps.get(app) == "stopped" for app in paths.EMERGENCY_APPS)
            results["other apps online"] = all(apps.get(app) == "online" for app in paths.STACK_APPS
                                               if app not in paths.EMERGENCY_APPS)
            results["443 refuses"] = tcp_refused(self.facts["address"], 443)
        finally:
            self.ssh(f"{PROD} resume", timeout=900)
            results["healthy after resume"] = self.wait(self.healthy, 900, 15)
        return self.record("emergency stop persists across a reboot: haproxy and gateway stopped, 443 refuses, other "
                           "apps online; boot notice healthy with the stop stated", all(results.values()), **results)

    def row_reboot_failure(self):
        """Spec #21 failure path: Nextcloud held down -> one alert at 10 minutes naming it."""
        self.need("install")
        self.ssh("pm2 stop nextcloud && pm2 save", timeout=300)
        try:
            rebooted = self.reboot()
            alerted = self.wait(lambda: '"result": "unhealthy"' in self.boot_health(), 900, 30)
            named = "nextcloud" in self.boot_health()
        finally:
            self.ssh("pm2 start nextcloud && pm2 save", timeout=300)
            self.wait(self.healthy, 600)
        return self.record("boot notice failure path: one alert at 10 minutes naming nextcloud",
                           rebooted and alerted and named)

    def container_ready_since(self, container, since):
        """Docker health `healthy` for a container started after `since` (VM epoch seconds)."""
        out = self.ssh(f"docker inspect -f '{{{{.State.Health.Status}}}} {{{{.State.StartedAt}}}}' {container}",
                       timeout=30)[1].split()
        if len(out) != 2 or out[0] != "healthy":
            return False
        try:
            started = calendar.timegm(time.strptime(out[1][:19], "%Y-%m-%dT%H:%M:%S"))
        except ValueError:
            return False
        return started >= since

    def row_killed_containers(self):
        """Spec #20: `docker kill` of access, then of db: PM2 restarts it within 60 s (counted in
        `pm2 ls`; not the watchdog, which needs 3 failing checks a minute apart); within 3 minutes the
        new container is Docker-healthy (started after the kill: db's own pg_isready, since the
        gateway's /health does not depend on db) and the production healthcheck is ready; no manual
        action."""
        self.need("install")
        results = {}
        for app, container in (("gateway", ACCESS), ("db", f"{paths.PROJECT}-db-1")):
            self.wait(self.healthy, 600, 15)
            before = (self.restart_counts() or {}).get(app)
            by_watchdog = self.watchdog_restarts(app)
            try:
                kill_epoch = int(self.ssh("date +%s", timeout=30)[1].strip())
            except ValueError:
                kill_epoch = None
            self.ssh(f"sudo docker kill {container}", timeout=60)
            killed = time.monotonic()
            restarted = self.wait(lambda: ((self.restart_counts() or {}).get(app) or 0) > (before or 0), 60, 3)
            restart_seconds = round(time.monotonic() - killed)
            ready = kill_epoch is not None and self.wait(
                lambda: self.container_ready_since(container, kill_epoch) and
                self.status().get("healthcheck") == "ready", max(1.0, 180 - (time.monotonic() - killed)), 5)
            ready_seconds = round(time.monotonic() - killed)
            listing = self.ssh("pm2 ls --no-color", timeout=120)[1]
            self.save(f"pm2-ls-after-kill-{app}.txt", listing)
            results[app] = {"pm2_restart": restarted and before is not None, "restart_s": restart_seconds,
                            "ready": ready and ready_seconds <= 180, "ready_s": ready_seconds,
                            "counted": ((self.restart_counts() or {}).get(app) or 0) > (before or 0),
                            "not_the_watchdog": self.watchdog_restarts(app) == by_watchdog}
        self.wait(self.healthy, 600, 15)
        passed = all(row["pm2_restart"] and row["ready"] and row["counted"] and row["not_the_watchdog"]
                     for row in results.values())
        return self.record("killed containers (access, db): PM2 restart within 60 s, counted in pm2 ls; the new "
                           "container healthy and the healthcheck ready within 3 minutes; no manual action",
                           passed, **results)

    def row_ddns(self):
        """Spec #23 in anj-qual: no ddns app with ddns off; the household address applied through the
        real HAProxy admin socket and read back from the runtime (`show acl`); an invalid address is
        refused with the file and runtime unchanged and raises exactly one alert over two cycles."""
        self.need("install")
        apps = self.ssh("pm2 jlist", timeout=120)[1]
        no_app = '"name":"ddns"' not in apps.replace(" ", "")
        sent = self.sent_alerts()
        script = ("import json,os,sys,tempfile\nsys.path.insert(0,'.')\nfrom deploy import ddns\nfrom deploy.vm import paths\n"
                  "admin=ddns.HaproxyAdmin()\nout={'apply':ddns.apply_household('1.1.1.1')}\n"
                  "out['runtime']=admin.entries()\nout['listed']=str(paths.HOUSEHOLD_ACL) in admin.runtime('show acl')\n"
                  "d=tempfile.mkdtemp(prefix='anj-qual-ddns-')\n"
                  "u=ddns.Updater(name='gateway.example.com',zone_id='0'*32,state=os.path.join(d,'state.json'))\n"
                  "u._attempt=lambda token: ddns.apply_household('10.0.0.1')\n"
                  "out['cycles']=[[o.get('category'),o.get('alert')] for o in (u.cycle(),u.cycle())]\n"
                  "out['runtime_after']=admin.entries()\nprint(json.dumps(out))\n")
        code, out, err = self.ssh(f"cd {CURRENT} && python3 -", data=script, timeout=120)
        self.save("ddns.txt", out + err)
        try:
            result = json.loads(out.strip().splitlines()[-1])
        except (ValueError, IndexError):
            result = {}
        acl = self.ssh(f"cat {paths.HOUSEHOLD_ACL}", timeout=30)[1].strip()
        delivered = self.wait(lambda: self.sent_alerts()["ddns"] - sent["ddns"] >= 1, 120, 10)
        time.sleep(30)
        alerts = self.sent_alerts()["ddns"] - sent["ddns"]
        return self.record("DDNS off: no ddns app; household address in HAProxy's runtime ACL (show acl); an invalid "
                           "one refused, file and runtime unchanged, one alert over two cycles",
                           no_app and code == 0 and result.get("runtime") == ["1.1.1.1"] and result.get("listed")
                           and result.get("cycles") == [["household-invalid", "sent"], ["household-invalid", None]]
                           and result.get("runtime_after") == ["1.1.1.1"] and acl == "1.1.1.1" and delivered
                           and alerts == 1, ddns=result, acl=acl, ddns_alerts_delivered=alerts)

    def events(self, app):
        """The JSON lines of an operations app's PM2 log (PM2 prefixes each with a timestamp)."""
        rows = []
        for line in self.pm2_log(app).splitlines():
            start = line.find("{")
            if start < 0:
                continue
            try:
                row = json.loads(line[start:])
            except ValueError:
                continue
            if isinstance(row, dict):
                rows.append(row)
        return rows

    def watchdog_restarts(self, app=None):
        """`pm2 restart` runs the watchdog made (of one app, or of all)."""
        return sum(1 for row in self.events("watchdog") if row.get("event") == "watchdog-restart"
                   and (app is None or row.get("app") == app))

    def watchdog_alerts(self):
        """{key: count} of the alerts the watchdog queued."""
        return Counter(row.get("key") for row in self.events("watchdog") if row.get("event") == "watchdog-alert")

    def sent_alerts(self):
        """{key: count} the dispatcher delivered (`alert-sent`; `alert-retry` is not a delivery)."""
        return Counter(row.get("key") for row in self.events("alerts") if row.get("event") == "alert-sent")

    def leak_search(self):
        """Every in-VM log and this run's host-side outputs, searched for each secret pattern inside
        the VM. Returns (clean, {label: {location: found|clean|missing|error}}); never a pattern."""
        _code, out, _err = self.ssh(LEAK_SEARCH, timeout=900)
        table = {}
        for line in out.splitlines():
            parts = line.split()
            if len(parts) == 3 and parts[0] in LEAK_LABELS:
                label, where, result = parts
                table.setdefault(label, {})[where] = {"0": "found", "1": "clean", "missing": "missing"}.get(
                    result, "error " + result)
        outputs = "".join(path.read_text(errors="replace") for path in sorted(self.evidence.iterdir())
                          if path.is_file())
        for label, places in table.items():
            if "-" not in places:
                code = self.ssh(f"sudo grep -qF -f {PATTERNS}/{label}", data=outputs, timeout=300)[0]
                places["halo-evidence"] = {0: "found", 1: "clean"}.get(code, f"error {code}")
        self.save("leak-search.json", json.dumps(table, indent=2, sort_keys=True) + "\n")
        complete = set(table) == set(LEAK_LABELS) and all(
            set(places) == set(LEAK_LOCATIONS) | {"halo-evidence"} for places in table.values())
        return complete and all(r == "clean" for places in table.values() for r in places.values()), table

    def boot_health_result(self):
        """boot-health's own final journal line of this boot ({"result", "failures", "emergency_stop_stated"})."""
        for line in reversed(self.boot_health().splitlines()):
            start = line.find("{")
            try:
                row = json.loads(line[start:]) if start >= 0 else {}
            except ValueError:
                continue
            if row.get("event") == "boot-health":
                return row
        return {}

    # Decision #122: production release updates (stage.py --upgrade, setup upgrade/--rollback).
    # One digest over every secret file except the first pairing code, which the watchers app sweeps
    # once its invitation expires (10 minutes, possibly during the row); no value leaves the VM.
    UPGRADE_SECRETS = (f"sudo sh -c 'cd {paths.SECRETS_DIR} && find . -type f ! -name {paths.FIRST_PAIRING_CODE.name} "
                       "-print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -c1-16'")
    UPGRADE_DATA = f"findmnt -no SOURCE,UUID {paths.DATA_ROOT}"

    def vm_ms(self):
        try:
            return int(self.ssh("date +%s%3N", timeout=30)[1].strip())
        except ValueError:
            return 0

    def ops_rows(self):
        """{app: (pid, pm_uptime ms)} of the operations apps redeploy restarts (console, watchdog, watchers)."""
        try:
            rows = jlist_rows(self.ssh("pm2 jlist", timeout=120)[1] or "[]")
        except ValueError:
            return {}
        return {row.get("name"): (row.get("pid"), (row.get("pm2_env") or {}).get("pm_uptime"))
                for row in rows if row.get("name") in (paths.CONSOLE_APP, "watchdog", "watchers")}

    def keep_facts(self):
        """What an update must never change: the secrets, the accounts, the data disk."""
        accounts = self.ssh(f"{OPERATOR} accounts", timeout=300)[1]
        try:
            uids = sorted(row.get("uid") for row in json.loads(accounts))
        except (ValueError, TypeError, AttributeError):
            uids = None
        return {"secrets": self.ssh(self.UPGRADE_SECRETS, timeout=60)[1].strip(), "accounts": uids,
                "data_disk": self.ssh(self.UPGRADE_DATA, timeout=30)[1].strip()}

    def stack_json(self):
        try:
            return json.loads(self.ssh(f"cat {paths.STACK_CONFIG}", timeout=30)[1])
        except ValueError:
            return {}

    def switched_to(self, commit, previous, started_ms, before_ops, label):
        """The release switch, health, the regenerated release files and the operations apps."""
        results = {}
        stack = self.stack_json()
        short = commit[:12]
        results[f"{label}: stack.json release {short}, previous {previous[:12]}"] = (
            stack.get("release") == commit and stack.get("previous_release") == previous)
        results[f"{label}: release/current -> {short}"] = \
            self.ssh(f"readlink {CURRENT}", timeout=30)[1].strip() == short
        results[f"{label}: healthy"] = bool(self.wait(self.healthy, 300, 10))
        release = f"{paths.RELEASE_DIR}/{short}"
        files = self.ssh(f"cd {release} && ls compose.json haproxy.cfg ecosystem.config.js release.json source.tar && "
                         f"cmp -s compose.json {paths.RELEASE_SOURCE_DIR}/{short}/deploy/compose.prod.json && "
                         "! grep -q '{{' haproxy.cfg && echo regenerated", timeout=30)[1]
        results[f"{label}: release files rendered from its source"] = files.strip().endswith("regenerated")
        switched_ms = 0
        try:
            switched_ms = int(self.ssh(f"stat -c %Y {CURRENT}", timeout=30)[1].strip()) * 1000
        except ValueError:
            pass
        after = self.ops_rows()
        for app in (paths.CONSOLE_APP, "watchdog", "watchers"):
            pid, since = after.get(app, (None, None))
            results[f"{label}: {app} restarted after the switch"] = (
                pid is not None and pid != (before_ops.get(app) or (None,))[0] and since is not None
                and since >= max(started_ms, switched_ms - 1000))
        return results

    def run_upgrade(self, name):
        """stage.py --upgrade's two halves (the check and the staging on the VM host, then the staged
        copy's upgrade over ssh), with the output kept."""
        stage.check_upgrade("anj-qual", self.upgrade_to)
        stage.stage(stage.Runner(), "anj-qual", self.upgrade_to)
        return self.ssh_setup(f"sudo {SETUP} upgrade --expect {self.upgrade_to}", name)

    def redeploy_running(self):
        # The bracket keeps pgrep from matching this very command line (bash -c carries the pattern).
        return self.ssh("pgrep -f '[d]eploy/prod.py redeploy' >/dev/null && echo yes", timeout=30)[1].strip() == "yes"

    def upgrade_session_dropped(self, name):
        """Review H1 on the VM: the ssh session that runs the upgrade dies mid-switch (the local
        ssh is killed, so sshd closes the pty and the kernel hangs up on the setup's session);
        prod.py, in its own session with no terminal, finishes."""
        stage.check_upgrade("anj-qual", self.upgrade_to)
        stage.stage(stage.Runner(), "anj-qual", self.upgrade_to)
        argv = stage.upgrade_argv("anj-qual", self.upgrade_to, terminal=True)
        argv[3] = "-tt"                    # a remote pty, as at a terminal: its hang-up SIGHUPs the setup
        with open(self.evidence / name, "w") as stream:
            child = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=stream, stderr=stream)
            seen = self.wait(self.redeploy_running, 120, 2)
            time.sleep(5)                                  # inside the build/restart phase
            child.kill()
            child.wait()
        time.sleep(3)
        self.facts["setup_after_hangup"] = self.ssh("pgrep -fc '[a]nj-cloud-setup upgrade' || true", timeout=30)[1].strip()
        self.facts["redeploy_after_hangup"] = self.redeploy_running()
        finished = self.wait(lambda: not self.redeploy_running(), 900, 10)
        return seen, finished

    def ssh_setup(self, command, name):
        code, out, err = self.ssh(command, timeout=1800)
        self.save(name, out + err)
        return code, out

    def row_upgrade(self):
        """Decision #122 on anj-qual: from the bootstrap's release A to B and back, through the
        health-checked redeploy path, with secrets, accounts and the data disk untouched."""
        self.need("install")
        results = {}
        a = self.stack_json().get("release") or ""
        b = stage.resolve(self.upgrade_to)
        self.upgrade_to = b
        results["A and B differ"] = bool(a) and a != b
        kept, timings = self.keep_facts(), {}
        results["facts readable"] = bool(kept["secrets"]) and bool(kept["accounts"]) and bool(kept["data_disk"])
        # 1. Upgrade A -> B.
        before, started = self.ops_rows(), self.vm_ms()
        clock = time.monotonic()
        code, out = self.run_upgrade("upgrade-1.txt")
        timings["upgrade"] = round(time.monotonic() - clock)
        results["upgrade exit 0"] = code == 0 and f"Release {b[:12]} is live and healthy" in out
        results.update(self.switched_to(b, a, started, before, "upgrade"))
        results["upgrade: secrets, accounts, data disk unchanged"] = self.keep_facts() == kept
        doctor, text, err = self.ssh(f"sudo {COMMAND} doctor", timeout=1800)
        self.save("upgrade-doctor.txt", text + err)
        results["upgrade: doctor passes"] = doctor == 0
        # 2. The same release again: a no-op.
        restarts = self.restart_counts()
        code, out = self.ssh_setup(f"sudo {SETUP} upgrade", "upgrade-noop.txt")
        results["no-op: exit 0, nothing restarted"] = code == 0 and "already live" in out and \
            self.restart_counts() == restarts
        # 3. Roll back to A.
        before, started = self.ops_rows(), self.vm_ms()
        clock = time.monotonic()
        code, out = self.ssh_setup(f"sudo {COMMAND} upgrade --rollback", "rollback.txt")
        timings["rollback"] = round(time.monotonic() - clock)
        results["rollback exit 0"] = code == 0 and f"Release {a[:12]} is live and healthy" in out
        # Review L1: release A predates `upgrade`, so the hint is the re-stage from the VM host.
        results["rollback: forward hint is stage.py --upgrade"] = \
            f"deploy/vm/stage.py <vm> --commit {b[:12]} --upgrade" in out and "upgrade --rollback` switches back" not in out
        results.update(self.switched_to(a, b, started, before, "rollback"))
        results["rollback: secrets, accounts, data disk unchanged"] = self.keep_facts() == kept
        # 4. Upgrade again (re-staged from the VM host; B's tar and tree are reused), and the ssh session
        #    dies mid-switch: the switch completes in the VM by itself (review H1).
        before, started = self.ops_rows(), self.vm_ms()
        clock = time.monotonic()
        seen, finished = self.upgrade_session_dropped("upgrade-2.txt")
        timings["upgrade again"] = round(time.monotonic() - clock)
        results["upgrade again: session dropped mid-switch, prod.py finished by itself"] = \
            seen and finished and self.facts.get("redeploy_after_hangup") is True
        results.update(self.switched_to(b, a, started, before, "upgrade again"))
        results["upgrade again: secrets, accounts, data disk unchanged"] = self.keep_facts() == kept
        return self.record("upgrade: A -> B, no-op, rollback to A, B again with the session dropped; health-checked switch, console, "
                           "watchdog and watchers on the new release, secrets/accounts/data disk untouched",
                           all(results.values()), a=a[:12], b=b[:12], seconds=timings,
                           setup_processes_after_hangup=self.facts.get("setup_after_hangup"), **results)

    def row_leaks(self):
        """Last row: the leak search again over everything every row wrote."""
        self.need("install")
        clean, table = self.leak_search()
        return self.record("final sweep: no pairing code, ntfy topic or scratch token in any VM log, journal, PM2 log "
                           "or this run's outputs", clean, leaks=table)

    ROWS = ("create", "stage", "dry_run", "install", "status_doctor", "idempotence", "firewall", "first_admin",
            "pair_commands", "enrol", "console", "adopt_same_disk", "doctor_failures", "updates", "killed_containers", "ddns", "hung_gateway",
            "watchdog_quiet", "watchdog_cap", "reboot", "reboot_emergency", "reboot_failure", "upgrade", "leaks")

    def run(self, rows):
        self.evidence.mkdir(mode=0o700, parents=True, exist_ok=True)
        try:
            for name in rows:
                if self.facts.get("create_refused"):
                    break                  # exit 3: another run's or an unknown anj-qual; report and stop
                try:
                    if getattr(self, "row_" + name)():
                        self.done.add(name)
                except Skip as reason:
                    self.record(name + " (skipped)", False, reason=str(reason))
                except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
                    self.record(name, False, error=type(error).__name__)
        finally:
            if self.facts.get("device_state"):
                subprocess.run(["rm", "-rf", str(self.facts["device_state"])], check=False)
            if not self.keep and "create" in rows and not self.facts.get("create_refused"):
                destroyed = subprocess.run([str(HALO_VM), "--qual-destroy", "--run-id", self.run_id],
                                           capture_output=True, text=True, timeout=1800, check=False)
                self.save("halo-vm-destroy.log", destroyed.stdout + destroyed.stderr)
                self.record("anj-qual destroyed", destroyed.returncode == 0)


class PtySession:
    """A local pseudo-terminal around one command (ssh -tt): what a person at a terminal sees."""

    def __init__(self, argv):
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.execvp(argv[0], argv)
        self.output = ""

    def read_until(self, text, timeout):
        deadline = time.monotonic() + timeout
        while text not in self.output:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return False
            ready, _, _ = select.select([self.fd], [], [], remaining)
            if ready:
                try:
                    chunk = os.read(self.fd, 4096)
                except OSError:
                    return False
                if not chunk:
                    return False
                self.output += chunk.decode("utf-8", "replace")
        return True

    def send(self, text):
        os.write(self.fd, (text + "\r").encode())

    def close(self):
        self.read_until("\0", 5)                  # drain what is left
        try:
            os.kill(self.pid, 9)
        except ProcessLookupError:
            pass
        os.waitpid(self.pid, 0)
        os.close(self.fd)
        return self.output


def delta(after, before):
    """{key: increase} of two Counters, only the keys that increased."""
    return {key: after[key] - before.get(key, 0) for key in after if after[key] > before.get(key, 0)}


def tcp_refused(address, port, timeout=10):
    """True when a TCP connect is actively refused (nothing listens; the firewall accepts the port)."""
    try:
        with socket.create_connection((address, port), timeout=timeout):
            return False
    except ConnectionRefusedError:
        return True
    except OSError:
        return False


def https_status(address, host, cafile, timeout=15):
    """GET /health over TLS to <address>:443 with SNI <host>, pinned to the issuer; the HTTP status."""
    try:
        context = ssl.create_default_context(cafile=cafile)
        with socket.create_connection((address, 443), timeout=timeout) as raw, \
                context.wrap_socket(raw, server_hostname=host) as tls:
            tls.sendall(f"GET /health HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n".encode())
            head = tls.recv(64).split(b"\r\n", 1)[0].split()
        return int(head[1]) if len(head) > 1 else None
    except (OSError, ssl.SSLError, ValueError):
        return None


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--run-id", help="halo-vm.sh run id (owner tag), e.g. b2dev-1")
    parser.add_argument("--commit", default="HEAD", help="Commit to stage (default: this checkout's HEAD)")
    parser.add_argument("--upgrade-to", default="HEAD",
                        help="upgrade row: the release to update to (default HEAD; bootstrap with --commit origin/main)")
    parser.add_argument("--rows", help="Comma-separated rows (default: all, in order)")
    parser.add_argument("--keep", action="store_true", help="Leave anj-qual (destroy it with --qual-destroy --run-id)")
    parser.add_argument("--list", action="store_true", help="List the rows and exit")
    parser.add_argument("--evidence", help="Evidence directory (default: f15-b2/qual-<UTC>/)")
    args = parser.parse_args(argv)
    if args.list:
        print("\n".join(Qualification.ROWS))
        return 0
    if not args.run_id:
        parser.error("--run-id is required")
    rows = args.rows.split(",") if args.rows else list(Qualification.ROWS)
    unknown = [row for row in rows if row not in Qualification.ROWS]
    if unknown:
        parser.error("unknown rows: " + ", ".join(unknown))
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    qualification = Qualification(args.run_id, args.commit, Path(args.evidence) if args.evidence else
                                  EVIDENCE / f"qual-{stamp}", keep=args.keep, upgrade_to=args.upgrade_to)
    error = None
    try:
        qualification.run(rows)
    except Exception as failure:  # noqa: BLE001 - the summary is written in every outcome
        error = type(failure).__name__
    summary = {"spec": 21, "unit": "B2", "seat": "anj-qual", "run_id": args.run_id, "commit": args.commit,
               "error": error, "results": qualification.results,
               "passed": error is None and all(row["pass"] for row in qualification.results)}
    (qualification.evidence / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps({"passed": summary["passed"], "evidence": str(qualification.evidence)}))
    return 0 if summary["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
