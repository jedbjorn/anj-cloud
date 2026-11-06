"""Console backend (spec #27, decision #87): the work behind the Admin section that needs the
issuer key, Nextcloud `occ` or PM2.

In the VM it runs as `anj` as the PM2 app `console` (installed by spec #21 B2); on the VM host it runs
as the dev operator against a dev or review stack. It listens only on a Unix socket (default
`/run/anj-console/backend.sock`), never on a network port. One JSON request per connection, one
JSON reply. Only peers whose `SO_PEERCRED` uid is allowed (the gateway's uid 10001 and the
backend's own account, which the recovery CLI uses) are served, and only the fixed action
allowlist. Every mutation holds the operator `flock`. It never returns key material, tokens or
passwords. Gateway-scoped work goes back through the gateway's operator socket as today.

At start, and every 30 s until done, it imports `state/accounts.json` (first-admin fallback,
decision #89 (9)) and `state/operator/recovery-audit.jsonl` (recovery CLI entries written while
the gateway was down) through the operator socket.
"""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import socket
import socketserver
import stat
import struct
import subprocess
import sys
import threading
import time

from cryptography import x509

from deploy.access_operator import Operator, stack_for
from services.access.naming import (NEW_UID_TEXT, RESERVED_UIDS, UID_TEXT, clean_device_name, clean_display_name, valid_new_uid,
                                    valid_uid)
from deploy.dev import ROOT
from deploy.token_spike import token_rows
from deploy.vm import paths
from deploy.vm.pm2json import jlist_rows

ACTIONS = ("approve", "reissue", "user-add", "nextcloud-enabled", "token-cleanup", "health", "test-alert", "admin-alert",
           "account-disable")
MUTATIONS = ("approve", "reissue", "user-add", "nextcloud-enabled", "token-cleanup", "account-disable")
# Admin-change alerts (decision #101): a fixed event enum and fixed templates, ids only.
ADMIN_EVENTS = {
    "role-grant": "anj-cloud admin: {actor} made {target} an admin",
    "role-remove": "anj-cloud admin: {actor} removed the admin role of {target}",
    "user-disable": "anj-cloud admin: {actor} disabled {target}",
    "device-revoke": "anj-cloud admin: {actor} revoked a device of {target}",
    "device-invite-other": "anj-cloud admin: {actor} created a pairing code for a device of {target}",
    "device-approve-other": "anj-cloud admin: {actor} approved a new device for {target}",
    # Code-only pairing (decision #151, spec #35 rule 4): the gateway approved a device that
    # redeemed a pinned code. The label is the only free text, checked below.
    # Both name the device's reported computer name and the first 8 hex of its key's SHA-256
    # (operator 2026-11-05), checked below.
    "device-paired": "anj-cloud: new device '{label}' (fp {fp}) for {target}",
    # A pairing code some device already holds was tried with another key (spec #35 review M2).
    "code-reused": "anj-cloud: someone tried a used pairing code for {target}: device '{label}' (fp {fp})",
}
DEVICE = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
TOKEN_ID = re.compile(r"[0-9]{1,19}")
FINGERPRINT = re.compile(r"[0-9a-f]{64}")
# Events whose alert names the device (decision #101, #103).
DEVICE_EVENTS = ("device-revoke", "device-approve-other", "device-paired")
# Events whose alert quotes a device's computer name and short key fingerprint.
LABEL_EVENTS = ("device-paired", "code-reused")
SHORT_FINGERPRINT = re.compile(r"[0-9a-f]{8}")
LAST_ADMIN_TEXT = "Make another user an admin first."
MOUNTS_UNRECORDED_PREFIX = "Could not read this account's shares"
GATEWAY_UID = paths.GATEWAY_UID
DEFAULT_SOCKET = paths.CONSOLE_SOCKET
MAX_REQUEST = 65536
CERTIFICATE_WARNING_DAYS = 30
REJECTED = "Operator action rejected: "
GENERIC = "The admin service could not complete this; details withheld."
IMPORT_RETRY_SECONDS = 30


def iso(timestamp):
    return None if timestamp is None else datetime.fromtimestamp(timestamp, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def require(condition, message="Invalid request"):
    """Every value from the socket is checked before it can reach occ or the operator."""
    if not condition:
        raise Refusal("refused", message)


class Refusal(Exception):
    def __init__(self, reason, message):
        super().__init__(message)
        self.reason, self.message = reason, message


class Backend:
    def __init__(self, operator, *, production, alert_command=None, ntfy_topic=None, accounts_file=None,
                 recovery_audit=None, data_root=None, alert_spool=None, clock=time.time):
        self.operator, self.stack, self.production, self.clock = operator, operator.stack, production, clock
        self.alert_command = Path(alert_command) if alert_command else (paths.ALERT_COMMAND if production else None)
        self.ntfy_topic = Path(ntfy_topic) if ntfy_topic else (paths.NTFY_TOPIC if production else self.stack.secret_dir / "ntfy-topic")
        self.accounts_file = Path(accounts_file) if accounts_file else (paths.ACCOUNTS_FILE if production else None)
        self.recovery_audit = Path(recovery_audit) if recovery_audit else operator.directory / "recovery-audit.jsonl"
        self.data_root = Path(data_root) if data_root else (paths.DATA_ROOT if production else self.stack.local)
        self.alert_spool = Path(alert_spool) if alert_spool else (paths.ALERT_SPOOL if production else self.stack.local / "run" / "alerts")

    # Requests --------------------------------------------------------------------------------

    def handle(self, request):
        """One request -> one reply. Errors are curated classes; never traces or secrets."""
        if not isinstance(request, dict) or request.get("action") not in ACTIONS:
            return {"error": "refused", "message": "Unsupported console backend action"}
        action = request["action"]
        data = {key: value for key, value in request.items() if key != "action"}
        try:
            return getattr(self, "do_" + action.replace("-", "_"))(**data)
        except Refusal as refusal:
            return {"error": refusal.reason, "message": refusal.message}
        except TypeError:
            return {"error": "refused", "message": "Unexpected fields for " + action}
        except RuntimeError as error:
            message = str(error)
            if message.startswith(REJECTED):
                # The gateway's own curated refusal.
                return {"error": "refused", "message": message[len(REJECTED):]}
            # Operator and subprocess failures are technical; the reply stays plain (spec #27 Q8).
            return {"error": "failed", "message": GENERIC}
        except Exception:  # noqa: BLE001 - curated reply; diagnostics withheld
            return {"error": "failed", "message": GENERIC}

    def do_approve(self, pairing_id, fingerprint):
        require(isinstance(pairing_id, str) and DEVICE.fullmatch(pairing_id) and isinstance(fingerprint, str)
                and FINGERPRINT.fullmatch(fingerprint))
        try:
            result = self.operator.approve(pairing_id, fingerprint)
        except RuntimeError as error:
            if str(error) == REJECTED + "Fingerprint mismatch":
                raise Refusal("fingerprint-mismatch", "The fingerprint does not match the new device; nothing was approved.") from None
            raise
        return {"state": result.get("state", "active"), "device_id": result.get("device_id")}

    def do_reissue(self, device_id):
        require(isinstance(device_id, str) and DEVICE.fullmatch(device_id))
        result = self.operator.reissue(device_id)
        return {"device_id": result["device_id"], "state": result["state"], "expires_at": result.get("expires_at")}

    def do_user_add(self, uid, display_name, resume=False):
        """New accounts only (decision #103). `resume` (set by the gateway only for an account it
        created whose household row did not follow) accepts the account already existing."""
        require(valid_new_uid(uid), NEW_UID_TEXT)
        require(uid not in RESERVED_UIDS, "Reserved user id")
        require(clean_display_name(display_name) == display_name and isinstance(resume, bool), "Invalid display name")
        add = getattr(self.operator, "user_add", None)
        if add is None:
            raise Refusal("unavailable", "Adding a Nextcloud account is not available in this build")
        result = add(uid, display_name)
        # Operator.user_add checked under its lock and created nothing. `resume` finishes only an
        # account this tooling made: Operator.user_add writes secrets/<uid> before it creates the
        # account and never for one that already existed. The gateway records "Setup incomplete"
        # before it calls (SC-041), so a call it gave up on can leave `resume` set even when this
        # backend refused an existing server account: that one is still refused, never adopted.
        if result.get("state") == "exists" and not (resume and self.created_here(uid)):
            raise Refusal("exists", "There is already a server account %s that is not a household user; choose another user id." % uid)
        # The password stays in secrets/<uid>; neither it nor its path leaves the backend.
        return {"uid": uid, "state": result.get("state", "created")}

    def created_here(self, uid):
        secret_dir = getattr(self.stack, "secret_dir", None)
        return bool(secret_dir) and (Path(secret_dir) / uid).is_file()

    def do_nextcloud_enabled(self, uid, enabled):
        require(valid_uid(uid) and isinstance(enabled, bool))
        with self.operator.lock():
            # Values always follow "--": nothing from a request is ever read as an option.
            self.stack.occ("user:enable" if enabled else "user:disable", "--", uid)
        return {"uid": uid, "enabled": enabled}

    def do_token_cleanup(self, uid, token_id):
        """Remove a revoked device's exact app token and confirm it is gone."""
        require(valid_uid(uid) and isinstance(token_id, str) and TOKEN_ID.fullmatch(token_id))

        def present():
            rows = json.loads(self.stack.occ("user:auth-tokens:list", "--output=json", "--", uid))
            return any(str(row["id"]) == token_id for row in rows) if isinstance(rows, list) else True

        with self.operator.lock():
            if present():
                self.stack.occ("user:auth-tokens:delete", "--", uid, token_id)
            if present():
                raise Refusal("token-cleanup-pending", "The app token is still present")
        return {"state": "done"}

    def do_account_disable(self, uid):
        """Spec #26's disable for an account with no active device (decision #101): the operator
        CLI's own path. A temporary owner app password, journaled so `reconcile` removes an
        interrupted one, lets the gateway record recipients' mounts; it is deleted afterwards
        and never returned. The gateway's refusal on an unreadable owner list still applies."""
        require(valid_uid(uid), UID_TEXT)
        try:
            result = self.operator.account_set(uid, enabled=False)
        except RuntimeError as error:
            message = str(error)
            message = message[len(REJECTED):] if message.startswith(REJECTED) else message
            if message == LAST_ADMIN_TEXT:
                raise Refusal("last-admin", message) from None
            if message.startswith(MOUNTS_UNRECORDED_PREFIX) or message.startswith("Recipients' mounts were not recorded"):
                raise Refusal("share-mounts-unrecorded", message) from None
            raise
        return {"uid": uid, "enabled": False, "nextcloud": result.get("nextcloud")}

    def do_admin_alert(self, event, actor_uid, target_uid, device_id=None, label=None, fingerprint=None):
        """One admin-change alert from a fixed template, ids only (decision #101); a pairing alert
        also quotes the device's computer name and the first 8 hex of its key fingerprint (spec #35
        rule 4, operator 2026-11-05). Both are cleaned here, never refused (PR #92 review H1): the name
        with the gateway's own `clean_device_name` (printable ASCII whatever this Python's Unicode
        version), a fingerprint that is not 8 lowercase hex becomes "unknown"; a pairing alert is
        the check on an intercepted code and must always go out."""
        require(event in ADMIN_EVENTS and valid_uid(actor_uid) and valid_uid(target_uid), "Invalid admin alert")
        require((event in DEVICE_EVENTS) == (device_id is not None) and
                (device_id is None or (isinstance(device_id, str) and DEVICE.fullmatch(device_id))), "Invalid admin alert")
        require((event in LABEL_EVENTS) == (label is not None) == (fingerprint is not None) and
                (label is None or (isinstance(label, str) and isinstance(fingerprint, str))), "Invalid admin alert")
        if event in LABEL_EVENTS:
            label = clean_device_name(label)
            fingerprint = fingerprint if SHORT_FINGERPRINT.fullmatch(fingerprint) else "unknown"
        message = ADMIN_EVENTS[event].format(actor=actor_uid, target=target_uid, label=label, fp=fingerprint)
        if self.dispatch(["--key", "admin", "--every", "0", "--title", "anj-cloud admin"], message) == 0:
            return {"state": "sent"}
        self.spool("admin", "anj-cloud admin", message)
        return {"state": "spooled"}

    def dispatch(self, options, message):
        """Run the dispatcher once; its exit code, or None when it is missing or did not finish.
        Its output may name the topic and is never passed on."""
        if not self.alert_command or not os.access(self.alert_command, os.X_OK):
            return None
        environment = {**os.environ, "ANJ_NTFY_TOPIC_FILE": str(self.ntfy_topic)}
        try:
            return subprocess.run([str(self.alert_command), *options, "--", message], capture_output=True, text=True,
                                  timeout=60, env=environment, check=False).returncode
        except (OSError, subprocess.TimeoutExpired):
            return None

    def spool(self, key, title, message):
        """The dispatcher's spool record (deploy/vm/paths.py ALERT_SPOOL), as prod.py writes it."""
        try:
            self.alert_spool.mkdir(mode=0o700, parents=True, exist_ok=True)
            now = datetime.now(timezone.utc)
            record = {"key": key, "title": title, "priority": "default", "message": message,
                      "created": now.isoformat(timespec="seconds")}
            target = self.alert_spool / (now.strftime("%Y%m%dT%H%M%S.%fZ") + "-" + key + ".json")
            temporary = target.with_suffix(".tmp")
            fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            with os.fdopen(fd, "w") as stream:
                stream.write(json.dumps(record) + "\n")
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, target)
        except OSError:
            raise Refusal("failed", "The alert could not be sent or queued.") from None

    def do_test_alert(self):
        stamp = datetime.fromtimestamp(self.clock(), timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
        return self.alert("console-test", "anj-cloud console test, " + stamp)

    def alert(self, key, message):
        if not self.ntfy_topic.is_file():
            raise Refusal("not-configured", "Alerts are not configured on this server (no ntfy topic).")
        if not self.alert_command or not os.access(self.alert_command, os.X_OK):
            raise Refusal("not-configured", "The alert dispatcher is not installed on this server.")
        code = self.dispatch(["--key", key, "--title", "anj-cloud"], message)
        if code is None:
            raise Refusal("failed", "The alert dispatcher did not complete.")
        if code:
            raise Refusal("failed", "The alert dispatcher reported a failure (exit %d)." % code)
        return {"state": "sent"}

    # Health ----------------------------------------------------------------------------------

    def do_health(self):
        def fact(read):
            try:
                return read()
            except Refusal as refusal:
                return {"state": refusal.reason, "message": refusal.message}
            except Exception:  # noqa: BLE001 - one unavailable source never fails the page
                return {"state": "unavailable"}

        return {"state": "ok", "certificates": fact(self.certificates), "pm2": fact(self.pm2), "containers": fact(self.containers),
                "backup": fact(self.backup), "ddns": fact(self.ddns), "data_disk": fact(self.data_disk),
                "reboot_pending": fact(self.reboot_pending), "emergency_stop": fact(self.emergency_stop)}

    def certificates(self):
        rows = []
        for name in ("issuer", "server"):
            path = self.operator.directory / (name + ".crt")
            if not path.is_file():
                rows.append({"name": name, "state": "missing"})
                continue
            expires = x509.load_pem_x509_certificate(path.read_bytes()).not_valid_after_utc.timestamp()
            days = int((expires - self.clock()) // 86400)
            rows.append({"name": name, "expires_at": iso(expires), "days_left": days,
                         "state": "expired" if days < 0 else "expiring" if days < CERTIFICATE_WARNING_DAYS else "ok"})
        return {"state": "ok", "certificates": rows}

    def pm2(self):
        # Only the VM's PM2 (the anj account's); a dev host's PM2 is never read.
        if not self.production or shutil.which("pm2") is None:
            return {"state": "not-configured"}
        # PM2's first command of a user prints its banner before the JSON (decision #112 (2)).
        apps = jlist_rows(subprocess.run(["pm2", "jlist"], capture_output=True, text=True, timeout=30, check=True).stdout)
        return {"state": "ok", "apps": [{"name": app.get("name"), "status": (app.get("pm2_env") or {}).get("status"),
                                          "restarts": (app.get("pm2_env") or {}).get("restart_time")} for app in apps]}

    def containers(self):
        rows = []
        for line in self.stack.compose("ps", "--all", "--format", "json").splitlines():
            line = line.strip()
            if not line:
                continue
            for item in (json.loads(line) if line.startswith("[") else [json.loads(line)]):
                rows.append({"service": item.get("Service"), "state": item.get("State"), "health": item.get("Health") or None})
        return {"state": "ok", "services": sorted(rows, key=lambda row: row["service"] or "")}

    def backup(self):
        script = ROOT / "backup.py"
        if not self.production or not script.is_file():
            return {"state": "not-configured"}
        report = json.loads(subprocess.run([sys.executable, str(script), "status"], capture_output=True, text=True,
                                           timeout=60, check=True, cwd=ROOT.parent).stdout)
        last = report.get("last_success") or {}
        return {"state": "ok", "last_success": {key: last.get(key) for key in ("finished_at", "result", "duration_seconds", "bytes_added")
                                                 if key in last} or None,
                "hours_since_success": report.get("hours_since_success"),
                "running": bool(report.get("marker") and report["marker"].get("active"))}

    def ddns(self):
        if not self.production or not paths.DDNS_STATE.is_file():
            return {"state": "not-configured"}
        state = json.loads(paths.DDNS_STATE.read_text()[:65536])
        return {"state": "ok", "last_success": state.get("last_success"), "address": state.get("published") or state.get("address")}

    def data_disk(self):
        usage = shutil.disk_usage(self.data_root)
        return {"state": "ok", "used_percent": round(100 * usage.used / usage.total, 1), "free_bytes": usage.free}

    def reboot_pending(self):
        # Decision #86's pending-reboot state belongs to spec #21; until its marker is defined in
        # deploy/vm/paths.py this fact reads "not configured".
        marker = getattr(paths, "REBOOT_PENDING", None)
        if not self.production or marker is None:
            return {"state": "not-configured"}
        return {"state": "ok", "pending": Path(marker).exists()}

    def emergency_stop(self):
        if not self.production:
            return {"state": "not-configured"}
        return {"state": "ok", "stopped": paths.EMERGENCY_STOP.exists()}

    # Start-up imports ------------------------------------------------------------------------

    def import_first_admins(self):
        """`state/accounts.json` -> one-time `accounts-import`; renamed afterwards. True when done."""
        if not self.accounts_file or not self.accounts_file.is_file():
            return True
        data = json.loads(self.accounts_file.read_text()[:65536])
        admins = data.get("admins") if isinstance(data, dict) else None
        if not isinstance(admins, list) or not all(valid_uid(uid) and uid not in RESERVED_UIDS for uid in admins):
            self.safe_alert("first-admin-import", "anj-cloud: first-admin import refused (malformed accounts.json)")
            return True
        known = json.loads(self.stack.occ("user:list", "--output=json"))
        unknown = [uid for uid in admins if uid not in known]
        if unknown:
            self.safe_alert("first-admin-import", "anj-cloud: first-admin import refused (unknown account)")
            return True
        accounts = [{"uid": uid, "display_name": known[uid] if isinstance(known[uid], str) else uid} for uid in admins]
        self.operator.call("admin", op="accounts-import", accounts=accounts, admins=admins)
        self.accounts_file.rename(self.accounts_file.with_name(self.accounts_file.name + ".imported"))
        return True

    def import_recovery_audit(self):
        """Import the CLI's offline audit lines once each. A line that is not a valid entry is
        moved to recovery-audit.jsonl.rejected (alerted once per pass) and never blocks the
        rest; every entry has an id (lines without one get a digest of their text), so a retried
        or partly applied import never duplicates an entry."""
        if not self.recovery_audit.is_file():
            return True
        with self.operator.lock():
            lines = [line for line in self.recovery_audit.read_text().splitlines() if line.strip()]
            entries, sources, bad = [], [], []
            for line in lines:
                try:
                    entry = json.loads(line)
                    if not isinstance(entry, dict):
                        raise ValueError
                except ValueError:
                    bad.append(line)
                    continue
                entry.setdefault("id", hashlib.sha256(line.encode()).hexdigest())
                entries.append(entry)
                sources.append(line)
            for start in range(0, len(entries), 500):
                batch = entries[start:start + 500]
                reply = self.operator.call("admin", op="audit-import", entries=batch)
                bad += [sources[start + index] for index in reply.get("rejected", [])
                        if isinstance(index, int) and 0 <= index < len(batch)]
            if bad:
                rejected = self.recovery_audit.with_name(self.recovery_audit.name + ".rejected")
                fd = os.open(rejected, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)
                try:
                    os.write(fd, ("\n".join(bad) + "\n").encode())
                finally:
                    os.close(fd)
                self.safe_alert("recovery-audit", "anj-cloud: %d recovery audit line(s) were set aside as invalid" % len(bad))
            self.recovery_audit.unlink()
        return True

    def safe_alert(self, key, message):
        try:
            self.alert(key, message)
        except Refusal:
            pass

    def run_imports(self, stop):
        pending = [self.import_first_admins, self.import_recovery_audit]
        while pending and not stop.is_set():
            remaining = []
            for task in pending:
                try:
                    task()
                except Exception:  # noqa: BLE001 - gateway not up yet; retried
                    remaining.append(task)
            pending = remaining
            stop.wait(IMPORT_RETRY_SECONDS)


def short_address(path):
    """An AF_UNIX address for `path` within the 108-byte limit, and a directory fd to close
    after bind/connect. Long paths (a deep dev checkout) go through /proc/self/fd (Linux)."""
    path = Path(path)
    if len(os.fsencode(str(path))) < 100:
        return str(path), None
    directory = os.open(path.parent, os.O_DIRECTORY | os.O_CLOEXEC)
    return "/proc/self/fd/%d/%s" % (directory, path.name), directory


def peer_uid(connection):
    _pid, uid, _gid = struct.unpack("3i", connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i")))
    return uid


def check_socket_directory(directory, *, uid=None, gid=paths.GATEWAY_GID, mode=paths.CONSOLE_DIR_MODE):
    """Production: the socket directory is the tmpfiles one (decision #112 (1)), owner this account,
    group anj-gw, setgid 2750, not a symlink. Anything else and the backend does not start (PM2
    then reports it, and the watchdog alerts), rather than serve on a directory others can reach."""
    info = os.lstat(directory)
    expected = (os.getuid() if uid is None else uid, gid, mode)
    if not stat.S_ISDIR(info.st_mode) or (info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode)) != expected:
        raise RuntimeError("The console socket directory %s must be a directory %d:%d mode %s (tmpfiles)"
                           % (directory, expected[0], expected[1], oct(expected[2])))


class Server(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True

    def handle_error(self, request, client_address):
        # One line, no traceback: a peer that went away mid-reply is routine (#68 (5): no detail).
        print("console: connection ended early (%s)" % (sys.exc_info()[0] or Exception).__name__, file=sys.stderr, flush=True)

    def __init__(self, path, backend, allowed_uids):
        self.backend, self.allowed_uids = backend, frozenset(allowed_uids)
        path = Path(path)
        path.parent.mkdir(mode=0o750, parents=True, exist_ok=True)
        if path.exists() or path.is_symlink():
            if not path.is_socket():
                raise RuntimeError("Refusing to replace a non-socket at the console backend path")
            path.unlink()
        address, directory = short_address(path)
        try:
            super().__init__(address, Handler)
        finally:
            if directory is not None:
                os.close(directory)
        path.chmod(0o660)


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        connection = self.request
        connection.settimeout(30)
        if peer_uid(connection) not in self.server.allowed_uids:
            # A refused peer gets nothing: no reply, no action.
            return
        chunks, size = [], 0
        while True:
            chunk = connection.recv(16384)
            if not chunk:
                break
            size += len(chunk)
            if size > MAX_REQUEST:
                connection.sendall(json.dumps({"error": "refused", "message": "Request too large"}).encode())
                return
            chunks.append(chunk)
        try:
            request = json.loads(b"".join(chunks))
        except ValueError:
            reply = {"error": "refused", "message": "Malformed request"}
        else:
            reply = self.server.backend.handle(request)
        connection.settimeout(None)
        connection.sendall(json.dumps(reply).encode())


def main(argv=None):
    parser = argparse.ArgumentParser(description="anj-cloud console backend (Unix socket only)")
    parser.add_argument("--project", default=paths.PROJECT)
    parser.add_argument("--port", type=int)
    parser.add_argument("--state-root", help="Production state root (VM default %s)" % paths.STATE_ROOT)
    parser.add_argument("--socket", default=str(DEFAULT_SOCKET))
    parser.add_argument("--allow-uid", type=int, action="append", default=[],
                        help="Additional peer uid allowed besides %d and this account" % GATEWAY_UID)
    parser.add_argument("--alert-command")
    parser.add_argument("--ntfy-topic")
    parser.add_argument("--accounts-file", help="First-admin import file (VM default %s)" % paths.ACCOUNTS_FILE)
    args = parser.parse_args(argv)
    state_root = args.state_root
    if state_root is None and args.project == paths.PROJECT:
        state_root = str(paths.STATE_ROOT)
    stack = stack_for(args.project, args.port, state_root)
    operator = Operator(stack)
    production = bool((getattr(stack, "profile", None) or {}).get("production"))
    backend = Backend(operator, production=production, alert_command=args.alert_command, ntfy_topic=args.ntfy_topic,
                      accounts_file=args.accounts_file)
    if production and Path(args.socket) == DEFAULT_SOCKET:
        try:
            check_socket_directory(DEFAULT_SOCKET.parent)
        except (OSError, RuntimeError) as error:
            print("console: " + (str(error) if isinstance(error, RuntimeError) else type(error).__name__), file=sys.stderr)
            return 1
    server = Server(args.socket, backend, {GATEWAY_UID, os.getuid(), *args.allow_uid})
    stop = threading.Event()
    threading.Thread(target=backend.run_imports, args=(stop,), daemon=True).start()
    # PM2 stops apps with SIGINT; SIGTERM ends the server the same way.
    signal.signal(signal.SIGTERM, lambda *_: threading.Thread(target=server.shutdown, daemon=True).start())
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        stop.set()
        server.server_close()
        Path(args.socket).unlink(missing_ok=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
