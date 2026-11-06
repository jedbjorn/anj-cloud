#!/usr/bin/env python3
"""DDNS updater for the production hostname, in the anj-prod VM (spec #23 rev7; decisions #61,
#69 (b), #72, #73, #84, #85).

Standard library only. Runs as PM2 app `ddns` (`autorestart: false`, `cron_restart: */5`), so it
runs when PM2 resurrects the stack after a VM boot and every 5 minutes; see `pm2-app`.

One cycle (`run`):

1. Read the public IPv4 from two independent endpoints. Act only when both answer, both
   answers are equal and the address is public (not RFC1918, not 100.64.0.0/10, not
   loopback, link-local, multicast or reserved).
2. Read the record by its exact name and type A in the configured zone. Exactly one must
   exist; it is never created or deleted, and no other record is touched.
3. If its content differs or it is proxied, PATCH only `content` and `proxied=false`.
4. Household address (#69 (b), relocated by #84): write the address atomically to
   state/haproxy/household.acl when it changed or the file is missing, then replace the
   file-backed ACL's runtime entry through HAProxy's admin socket (prepare/add/commit, or
   clear + add on an older HAProxy) and verify `show acl`. No reload. While the emergency-stop
   flag exists HAProxy is stopped on purpose: the file is still written, the socket is skipped.

Every failure in a cycle is counted; the 3rd consecutive one raises a category-only alert
(then at most hourly). An address that is not one public IPv4 never reaches the ACL and alerts
at once. The token is read from a 0600 file and is never printed or logged.

    python3 -I deploy/ddns.py run                   # one cycle (PM2's command)
    python3 -I deploy/ddns.py check                 # one read-only GET of the record
    python3 -I deploy/ddns.py pm2-app [--source-dir <release source>] [--answers <toml>]
                                                    # PM2 app entry as JSON; [] unless ddns = "on"
"""

import argparse
import contextlib
import errno
import fcntl
import http.client
import ipaddress
import json
import os
from pathlib import Path
import re
import socket
import stat
import subprocess
import sys
import time
import tomllib
import urllib.error
import urllib.parse
import urllib.request

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from deploy import deployment_profile  # noqa: E402
from deploy.vm import paths  # noqa: E402

# Consecutive failures, last alert and last_success (epoch); spec #21's watchdog reads last_success.
STATE_FILE = paths.DDNS_STATE
# Non-secret updater configuration: the Cloudflare zone (spec #23, DNS and DDNS 3).
ZONE_ID = deployment_profile.load()["dns"]["zone_id"]   # the VM passes --zone-id explicitly
API = "https://api.cloudflare.com/client/v4"
# Two independent operators (Amazon and ipify); both serve IPv4 only.
ENDPOINTS = ("https://checkip.amazonaws.com/", "https://api.ipify.org/")
HOUSEHOLD_MAX_BYTES = 64
CRON = "*/5 * * * *"
ALERT_AFTER = 3
ALERT_REPEAT_SECONDS = 3600
TIMEOUT = 20
MAX_BODY = 1 << 20
HEX32 = re.compile(r"[0-9a-f]{32}")
HOST = re.compile(r"(?=.{4,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]")


# Alert categories. Alerts carry only these, never paths, codes or raw error text.
CATEGORIES = {"network", "address-endpoint", "address-disagree", "address-not-public", "dns-api",
              "dns-record", "token", "household-write", "household-apply", "household-invalid", "internal"}
# Categories that alert on the first occurrence: an invalid household address must never be silent.
ALERT_AT_ONCE = {"household-invalid"}

class Failure(Exception):
    """A cycle that must change nothing. The message never carries the token or a file path.

    `category` is the short reason an alert may carry (spec B 5, decision #68 (2)); the message is
    journal detail only."""

    def __init__(self, message, category="internal"):
        super().__init__(message)
        self.category = category if category in CATEGORIES else "internal"


# Unreachable-network errors: during the boot window these are retried and never counted.
NETWORK_ERRORS = (ConnectionError, TimeoutError, socket.gaierror)
NETWORK_ERRNOS = {errno.ENETUNREACH, errno.EHOSTUNREACH, errno.ENETDOWN}


def is_network_error(error):
    return isinstance(error, NETWORK_ERRORS) or (isinstance(error, OSError) and error.errno in NETWORK_ERRNOS)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    """Never follow a redirect: it would carry the Authorization header to another target."""

    def redirect_request(self, request, fp, code, msg, headers, newurl):
        raise urllib.error.HTTPError(request.full_url, code, "redirect refused", headers, fp)


def public_ipv4(text):
    """The address if `text` is exactly one public IPv4 address, else None."""
    text = (text or "").strip()
    if not re.fullmatch(r"\d{1,3}(\.\d{1,3}){3}", text):  # household-apply's rule (d1b705c)
        return None
    try:
        address = ipaddress.IPv4Address(text)
    except ValueError:
        return None
    shared = ipaddress.IPv4Network("100.64.0.0/10")
    if (not address.is_global or address.is_private or address in shared or address.is_loopback
            or address.is_link_local or address.is_multicast or address.is_reserved or address.is_unspecified):
        return None
    return str(address)


class Http:
    """Small JSON/text HTTPS client. Certificates and hostnames are always verified."""

    def __init__(self, opener=None):
        self.opener = opener or urllib.request.build_opener(NoRedirect)

    def request(self, method, url, *, headers=None, body=None):
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(url, data=data, method=method, headers=dict(headers or {}))
        if data is not None:
            request.add_header("Content-Type", "application/json")
        try:
            with self.opener.open(request, timeout=TIMEOUT) as response:
                return response.status, response.read(MAX_BODY)
        except urllib.error.HTTPError as error:
            with error:
                return error.code, error.read(MAX_BODY) if error.fp else b""
        except urllib.error.URLError as error:
            reason = error.reason
            category = "network" if is_network_error(reason) else "internal"
            raise Failure(f"{urllib.parse.urlsplit(url).hostname}: {type(reason).__name__}", category) from None
        except (http.client.HTTPException, OSError, ValueError) as error:
            category = "network" if is_network_error(error) else "internal"
            raise Failure(f"{urllib.parse.urlsplit(url).hostname}: {type(error).__name__}", category) from None


def discover(http, endpoints=ENDPOINTS):
    """Both endpoints' answers; raises unless they agree on one public IPv4."""
    answers = []
    for url in endpoints:
        status, body = http.request("GET", url)
        host = urllib.parse.urlsplit(url).hostname
        text = body.decode("ascii", "replace").strip() if status == 200 else ""
        if status != 200:
            raise Failure(f"public address endpoint {host} answered HTTP {status}", "address-endpoint")
        answers.append(text[:64])
    if len(set(answers)) != 1:
        raise Failure(f"public address endpoints disagree: {answers[0]!r} vs {answers[1]!r}", "address-disagree")
    address = public_ipv4(answers[0])
    if address is None:
        raise Failure(f"public address endpoints report a non-public or invalid address: {answers[0]!r}",
                      "address-not-public")
    return address


class Cloudflare:
    """Only two operations exist: read the A record by exact name, patch its content."""

    def __init__(self, http, token, zone_id, api=API):
        self.http, self._token, self.zone_id, self.api = http, token, zone_id, api.rstrip("/")

    def _call(self, method, path, body=None):
        status, raw = self.http.request(method, self.api + path, body=body,
                                        headers={"Authorization": "Bearer " + self._token, "Accept": "application/json"})
        try:
            payload = json.loads(raw or b"{}")
        except ValueError:
            payload = {}
        if status != 200 or not isinstance(payload, dict) or payload.get("success") is not True:
            codes = [error.get("code") for error in payload.get("errors", []) if isinstance(error, dict)] \
                if isinstance(payload, dict) and isinstance(payload.get("errors"), list) else []
            raise Failure(f"Cloudflare {method} answered HTTP {status}, errors {codes}", "dns-api")
        return payload.get("result")

    def record(self, name):
        query = urllib.parse.urlencode({"type": "A", "name.exact": name, "per_page": 5})
        result = self._call("GET", f"/zones/{self.zone_id}/dns_records?{query}")
        if not isinstance(result, list):
            raise Failure("Cloudflare record listing was not a list", "dns-api")
        matches = [item for item in result if isinstance(item, dict) and item.get("name") == name and item.get("type") == "A"]
        if len(matches) != 1 or len(result) != 1:
            raise Failure(f"expected exactly one A record named {name}, found {len(matches)} (never created or deleted here)",
                          "dns-record")
        record = matches[0]
        if not isinstance(record.get("id"), str) or not HEX32.fullmatch(record["id"]):
            raise Failure("Cloudflare record id has an unexpected shape", "dns-record")
        return record

    def update(self, record, address):
        """Only content and proxied=false; name, type, TTL and every other record are untouched."""
        result = self._call("PATCH", f"/zones/{self.zone_id}/dns_records/{record['id']}",
                            body={"content": address, "proxied": False})
        if (not isinstance(result, dict) or result.get("id") != record["id"] or result.get("content") != address
                or result.get("proxied") is not False):
            raise Failure("Cloudflare did not confirm the update", "dns-api")
        return result


def read_token(path):
    """0600 regular file owned by this user, not a symlink; contents never leave this process."""
    path = Path(path)
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        raise Failure("DNS token file is missing", "token") from None
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise Failure("DNS token file must be a regular 0600 file owned by this user", "token")
    token = path.read_text().strip()
    if not token or any(ch.isspace() for ch in token) or len(token) > 512:
        raise Failure("DNS token file does not hold a single token", "token")
    return token


def redact(message, token):
    message = str(message)
    if token:
        message = message.replace(token, "[token]")
    return message.replace("\n", " ")[:500]


def write_household_acl(path, address):
    """Atomic 0644 write of the one-entry ACL file by rename inside HAPROXY_STATE_DIR (mounted
    read-only as a directory into the capability-less HAProxy container, which reads it at start),
    only when it changes or is missing.
    Returns True if written. Anything but one public IPv4 is refused before touching the file."""
    if public_ipv4(address) != address:
        raise Failure("household address is not one public IPv4; ACL unchanged", "household-invalid")
    path = Path(path)
    if not path.parent.is_dir() or path.parent.is_symlink():
        raise Failure("household ACL directory is missing (spec #20 state/haproxy)", "household-write")
    content = address + "\n"
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
        try:
            if stat.S_ISREG(os.fstat(fd).st_mode) and os.read(fd, HOUSEHOLD_MAX_BYTES + 1) == content.encode():
                return False
        finally:
            os.close(fd)
    except OSError:
        pass
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o644)
    try:
        os.fchmod(fd, 0o644)
        with os.fdopen(fd, "w") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    except BaseException:
        with contextlib.suppress(OSError):
            temporary.unlink()
        raise
    return True


class HaproxyAdmin:
    """HAProxy's runtime API on the admin socket. The file-backed ACL is addressed by its file
    name, as declared in the HAProxy template (`acl household src -f <HOUSEHOLD_ACL>`)."""

    def __init__(self, socket_path=paths.HAPROXY_ADMIN_SOCKET, acl=paths.HOUSEHOLD_ACL, timeout=5.0):
        self.socket_path, self.acl, self.timeout = str(socket_path), str(acl), timeout

    def runtime(self, command):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(self.timeout)
            client.connect(self.socket_path)
            client.sendall(command.encode("ascii") + b"\n")
            chunks = []
            while True:
                chunk = client.recv(65536)
                if not chunk:
                    break
                chunks.append(chunk)
        return b"".join(chunks).decode("utf-8", "replace")

    def entries(self):
        output = self.runtime(f"show acl {self.acl}")
        if "Unknown ACL" in output or "No such" in output:
            raise Failure("HAProxy does not know the household ACL file", "household-apply")
        return [fields[1] for fields in (line.split() for line in output.splitlines())
                if len(fields) >= 2 and fields[0].startswith("0x")]

    def replace(self, address):
        """Make `address` the ACL's only runtime entry: prepare/add/commit (atomic), or clear + add."""
        prepared = self.runtime(f"prepare acl {self.acl}")
        match = re.search(r"New version created:\s*(\d+)", prepared)
        if match:
            version = match.group(1)
            if self.runtime(f"add acl @{version} {self.acl} {address}").strip():
                raise Failure("HAProxy refused the household address", "household-apply")
            if self.runtime(f"commit acl @{version} {self.acl}").strip():
                raise Failure("HAProxy refused to commit the household ACL", "household-apply")
        else:
            self.runtime(f"clear acl {self.acl}")
            if self.runtime(f"add acl {self.acl} {address}").strip():
                raise Failure("HAProxy refused the household address", "household-apply")
        if self.entries() != [address]:
            raise Failure("runtime household ACL does not hold the address after the update", "household-apply")


def apply_household(address, *, acl_file=paths.HOUSEHOLD_ACL, admin=None, emergency_flag=paths.EMERGENCY_STOP):
    """File first (HAProxy loads it at start), then the runtime entry. Returns an outcome record."""
    written = write_household_acl(acl_file, address)
    result = {"household_file": "written" if written else "current"}
    if Path(emergency_flag).exists():
        result["household_runtime"] = "skipped: haproxy stopped by emergency stop"
        return result
    admin = admin or HaproxyAdmin(acl=acl_file)
    try:
        if admin.entries() == [address]:
            result["household_runtime"] = "current"
            return result
        admin.replace(address)
    except OSError as error:
        raise Failure(f"HAProxy admin socket: {type(error).__name__}", "household-apply") from None
    result["household_runtime"] = "applied"
    return result


class State:
    """Consecutive failures and last alert, in the production state root (0600)."""

    def __init__(self, path):
        self.path = Path(path)

    @contextlib.contextmanager
    def locked(self):
        self.path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        lock = os.open(self.path.with_suffix(".lock"), os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
        try:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise Failure("another DDNS cycle is running") from None
            try:
                data = json.loads(self.path.read_text())
                if not isinstance(data, dict):
                    data = {}
            except (OSError, ValueError):
                data = {}
            data.setdefault("failures", 0)
            data.setdefault("alerted_at", None)
            yield data
            temporary = self.path.with_name(self.path.name + ".tmp")
            fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
            with os.fdopen(fd, "w") as stream:
                json.dump(data, stream, sort_keys=True)
            os.replace(temporary, self.path)
        finally:
            os.close(lock)


def log(event, **fields):
    """One JSON line to stdout (the user journal under the timer). Never the token."""
    print(json.dumps({"event": event, **fields}, sort_keys=True), flush=True)


ALERT_KEY = "ddns"
ALERT_TITLE = "anj-cloud DDNS"


def alert_argv(message, *, key, command=paths.ALERT_COMMAND, every=None, title=None, priority=None, sudo=False):
    """Spec #21's dispatcher contract (paths.ALERT_COMMAND):
    anj-alert --key K [--every S] [--title T] [--priority P] -- MESSAGE
    The dispatcher defaults to --every 3600 per key; callers that throttle themselves pass every=0.
    `sudo` prefixes `sudo -n` (never prompts) for a root-only dispatcher allowed by a sudoers rule."""
    argv = (["sudo", "-n"] if sudo else []) + [str(command), "--key", key]
    if every is not None:
        argv += ["--every", str(int(every))]
    if title:
        argv += ["--title", title]
    if priority:
        argv += ["--priority", priority]
    return argv + ["--", message]


def alert(message, *, key, command=paths.ALERT_COMMAND, every=None, title=None, priority=None, sudo=False,
          runner=None):
    """The single alert adapter: one dispatcher call. Returns whether it exited 0 (delivered or
    spooled by the dispatcher)."""
    if not command:
        return False
    runner = runner or subprocess.run
    try:
        result = runner(alert_argv(message, key=key, command=command, every=every, title=title, priority=priority,
                                   sudo=sudo), capture_output=True, timeout=60, check=False, stdin=subprocess.DEVNULL)
    except (OSError, subprocess.SubprocessError):
        return False
    return result.returncode == 0


BOOT_WINDOW_SECONDS = 300
BOOT_RETRY_SECONDS = 5
BOOT_RETRY_LIMIT = 30
NETWORK_WAIT_SECONDS = 60


def system_uptime():
    try:
        return float(Path("/proc/uptime").read_text().split()[0])
    except (OSError, ValueError, IndexError):
        return float("inf")


def wait_network_online(runner, sleep, uptime, limit=NETWORK_WAIT_SECONDS):
    """Wait (bounded) for the system manager's network-online.target, which a user unit
    cannot order itself after. Returns whether it became active."""
    deadline = uptime() + limit
    while True:
        try:
            if runner(["systemctl", "--system", "is-active", "--quiet", "network-online.target"],
                      timeout=10, check=False).returncode == 0:
                return True
        except (OSError, subprocess.SubprocessError):
            return False
        if uptime() >= deadline:
            return False
        sleep(BOOT_RETRY_SECONDS)


class Updater:
    def __init__(self, *, name, zone_id, token_file=paths.CLOUDFLARE_TOKEN, http=None,
                 household_acl=paths.HOUSEHOLD_ACL, admin=None, emergency_flag=paths.EMERGENCY_STOP, state=None,
                 alert_command=paths.ALERT_COMMAND, endpoints=ENDPOINTS, api=API, clock=time.time, uptime=None,
                 sleep=time.sleep, runner=subprocess.run):
        if not HOST.fullmatch(name or ""):
            raise Failure("--name must be a lowercase DNS name")
        if not HEX32.fullmatch(zone_id or ""):
            raise Failure("--zone-id must be a 32-character Cloudflare zone id")
        self.name, self.zone_id, self.token_file = name, zone_id, Path(token_file)
        self.http = http or Http()
        self.household = Path(household_acl)
        self.admin = admin or HaproxyAdmin(acl=self.household)
        self.emergency_flag = Path(emergency_flag)
        self.state = State(state or STATE_FILE)
        self.alert_command, self.endpoints, self.api, self.clock = alert_command, endpoints, api, clock
        self.uptime, self.sleep, self.runner = uptime or system_uptime, sleep, runner

    def cycle(self):
        """One cycle under the state lock. Returns the outcome record; never raises.

        ANY exception inside the cycle is a failure: counted, persisted and alerted on, with its
        detail (type only for unexpected errors, never a path or the token) in the journal."""
        token = None
        try:
            with self.state.locked() as state:
                try:
                    token = read_token(self.token_file)
                    outcome = self._attempt(token)
                except Exception as error:  # noqa: BLE001 - every failure must be counted
                    if isinstance(error, Failure):
                        category, detail = error.category, redact(error, token)
                    elif isinstance(error, OSError) and self._household_error(error):
                        category, detail = "household-write", f"{type(error).__name__} writing the household ACL file"
                    elif is_network_error(error):
                        category, detail = "network", type(error).__name__
                    else:
                        category, detail = "internal", type(error).__name__
                    if category == "network" and self.in_boot_window():
                        outcome = {"outcome": "boot-no-network", "reason": detail,
                                   "consecutive_failures": state["failures"]}
                    else:
                        outcome = self._failed(state, category, detail)
                else:
                    if state["failures"] >= ALERT_AFTER:
                        outcome["recovered_after"] = state["failures"]
                    state.update(failures=0, alerted_at=None, last_success=self.clock())
        except Failure as failure:  # the lock itself
            outcome = {"outcome": "skipped", "reason": redact(failure, token)}
        except Exception as error:  # noqa: BLE001 - e.g. the state file cannot be saved
            outcome = {"outcome": "failed", "category": "internal", "reason": f"state: {type(error).__name__}"}
        log("ddns", **outcome)
        return outcome

    def _household_error(self, error):
        filename = getattr(error, "filename", None)
        return bool(filename) and Path(filename).parent == self.household.parent

    def in_boot_window(self):
        return self.uptime() < BOOT_WINDOW_SECONDS

    def _attempt(self, token):
        """PM2 resurrects the stack early in boot: wait (bounded) for network-online.target,
        then retry unreachable-network errors briefly; a boot run without network is not counted."""
        if not self.in_boot_window():
            return self._cycle(token)
        wait_network_online(self.runner, self.sleep, self.uptime)
        deadline = self.uptime() + BOOT_RETRY_LIMIT
        while True:
            try:
                return self._cycle(token)
            except Failure as failure:
                if failure.category != "network" or self.uptime() >= deadline:
                    raise
            self.sleep(BOOT_RETRY_SECONDS)

    def _failed(self, state, category, detail):
        state["failures"] += 1
        outcome = {"outcome": "failed", "category": category, "reason": detail,
                   "consecutive_failures": state["failures"]}
        now = self.clock()
        due = state["alerted_at"] is None or now - state["alerted_at"] >= ALERT_REPEAT_SECONDS
        if (state["failures"] >= ALERT_AFTER or category in ALERT_AT_ONCE) and due:
            # Category only: no file names, error codes or raw error text (spec B 5; #68 (2)).
            message = f"anj-cloud DDNS: {state['failures']} consecutive failures ({category}); DNS unchanged."
            # D gates repeats itself (hourly, retry when undelivered), so the dispatcher's own per-key
            # throttle (default --every 3600) is disabled with --every 0, as A's prod.py does.
            delivered = alert(message, key=ALERT_KEY, command=self.alert_command, every=0, title=ALERT_TITLE)
            outcome["alert"] = "sent" if delivered else "not-delivered"
            log("ddns-alert", consecutive_failures=state["failures"], category=category, delivered=delivered)
            if delivered:  # an undelivered alert is retried next cycle, not an hour later
                state["alerted_at"] = now
        return outcome

    def _cycle(self, token):
        address = discover(self.http, self.endpoints)
        cloudflare = Cloudflare(self.http, token, self.zone_id, self.api)
        record = cloudflare.record(self.name)
        old = record.get("content")
        if old == address and record.get("proxied") is False:
            outcome = {"outcome": "unchanged", "name": self.name, "address": address}
        else:
            cloudflare.update(record, address)
            outcome = {"outcome": "updated", "name": self.name, "old": old, "new": address,
                       "proxied_was": record.get("proxied")}
        outcome.update(apply_household(address, acl_file=self.household, admin=self.admin,
                                       emergency_flag=self.emergency_flag))
        return outcome

    def check(self):
        """Read-only: one GET of the record. Reports shape, never the token."""
        token = read_token(self.token_file)
        try:
            record = Cloudflare(self.http, token, self.zone_id, self.api).record(self.name)
        except Failure as failure:
            raise Failure(redact(failure, token)) from None
        return {"name": record.get("name"), "type": record.get("type"), "proxied": record.get("proxied"),
                "dns_only": record.get("proxied") is False, "ttl": record.get("ttl"),
                "content_is_public_ipv4": public_ipv4(record.get("content")) is not None}


def recorded_host(stack_config=paths.STACK_CONFIG):
    """The hostname spec A's `prod.py setup --host` recorded (decision #64), if any."""
    try:
        value = json.loads(Path(stack_config).read_text()).get("host")
    except (OSError, ValueError, AttributeError):
        return None
    return value if isinstance(value, str) else None


def ddns_enabled(answers):
    """Opt-in: only an explicit `ddns = "on"` in the answers file installs the updater (spec #21's
    bootstrap writes it for production). A missing key, no answers file or `ddns = "off"`
    (qualification and drill VMs) installs nothing."""
    value = (answers or {}).get("ddns", "off")
    if value not in ("on", "off"):
        raise Failure('answers key ddns must be "on" or "off"')
    return value == "on"


def read_answers(path):
    if not path:
        return {}
    try:
        with open(path, "rb") as stream:
            return tomllib.load(stream)
    except (OSError, tomllib.TOMLDecodeError) as error:
        raise Failure(f"cannot read the answers file: {type(error).__name__}") from None


def pm2_apps(source_dir, answers=None):
    """The PM2 ecosystem entry for spec #23's updater: a list with one app when the answers say
    ddns = "on", else [] (opt-in).
    Spec #21's bootstrap merges it into the ecosystem and `pm2 save`s."""
    if not ddns_enabled(answers):
        return []
    source_dir = Path(source_dir)
    if not source_dir.is_absolute():
        raise Failure("--source-dir must be absolute")
    app = {"name": paths.DDNS_APP, "script": str(source_dir / "deploy" / "ddns.py"), "args": "run",
           "interpreter": "/usr/bin/python3", "interpreter_args": "-I", "cwd": str(source_dir),
           "autorestart": False, "cron_restart": CRON, "time": True}
    return [app]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--name", help="Exact record name (default: the host recorded by prod.py setup)")
    parser.add_argument("--zone-id", default=ZONE_ID)
    parser.add_argument("--token-file", default=str(paths.CLOUDFLARE_TOKEN))
    parser.add_argument("--household-acl", default=str(paths.HOUSEHOLD_ACL))
    parser.add_argument("--admin-socket", default=str(paths.HAPROXY_ADMIN_SOCKET))
    parser.add_argument("--state-file", default=str(STATE_FILE))
    parser.add_argument("--source-dir", default=str(paths.RELEASE_CURRENT),
                        help="pm2-app: release source holding deploy/ddns.py (default: the release/current symlink)")
    parser.add_argument("--answers", help='pm2-app: answers TOML; only ddns = "on" yields the app (opt-in)')
    parser.add_argument("action", nargs="?", choices=("run", "check", "pm2-app"), default="run")
    args = parser.parse_args(argv)
    try:
        if args.action == "pm2-app":
            print(json.dumps(pm2_apps(args.source_dir, read_answers(args.answers)), indent=2))
            return 0
        name = args.name or recorded_host()
        if not name:
            raise Failure("no hostname: pass --name or run prod.py setup --host first")
        updater = Updater(name=name, zone_id=args.zone_id, token_file=args.token_file,
                          household_acl=args.household_acl,
                          admin=HaproxyAdmin(socket_path=args.admin_socket, acl=args.household_acl),
                          state=args.state_file)
        if args.action == "check":
            print(json.dumps(updater.check(), indent=2, sort_keys=True))
            return 0
        # boot-no-network is tolerated (not counted); every failure exits non-zero.
        return 0 if updater.cycle()["outcome"] in ("updated", "unchanged", "boot-no-network") else 1
    except Failure as failure:
        print(f"ddns: {failure}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
