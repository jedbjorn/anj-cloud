"""Shared helpers of the anj-prod VM operations (spec #21 VM Operations; decisions #85, #86, #89 (4)).

Standard library only. The PM2 apps (watchdog, watchers, alerts, console) and the systemd jobs (boot
health, reboot guard, image check) import this module from the live release source
(/srv/anj-cloud/release/current/deploy/vm/ops). Every path, marker and app name comes from
spec #20's deploy/vm/paths.py; nothing here redefines them.

Nothing here prints or records file names, codes, tokens, the ntfy topic or configuration text.
"""

import calendar
import json
import os
from pathlib import Path
import re
import socket
import ssl
import subprocess
import sys
import time

HERE = Path(os.path.realpath(__file__)).parent
sys.path.insert(0, str(HERE.parent.parent.parent))
try:
    from deploy.vm import paths  # noqa: E402  release source or checkout
    from deploy.vm.pm2json import jlist_rows  # noqa: E402
except ImportError:  # pragma: no cover - state/bin copy beside paths.py
    sys.path.insert(0, str(HERE))
    import paths  # noqa: E402

    def jlist_rows(text):
        return json.loads(text or "[]")

ALERT_EVERY_DEFAULT = 3600
CHECK_TIMEOUT = 20
OPS_CONFIG = "run/ops.json"             # alerts_tag, ntfy_server (bootstrap; run/ is machine-local)
ACCESS_CONTAINER = f"{paths.PROJECT}-{paths.COMPOSE_SERVICE['gateway']}-1"
NEXTCLOUD_CONTAINER = f"{paths.PROJECT}-{paths.COMPOSE_SERVICE['nextcloud']}-1"
# Every `docker exec` into the gateway container runs as the gateway user, the same value as the
# bootstrap's and qualify.py's: an exec otherwise inherits the start step's capabilities.
GATEWAY_EXEC_USER = f"{paths.GATEWAY_UID}:{paths.GATEWAY_GID}"
# Nextcloud's own loopback (as its compose healthcheck reads it), for when the gateway container
# is not running (emergency stop, a gateway crash): Nextcloud is never blamed for the gateway.
NEXTCLOUD_STATUS_LOCAL = ('$s=json_decode(@file_get_contents("http://127.0.0.1/status.php"),true);'
                          'echo json_encode(["installed"=>(bool)($s["installed"]??false),'
                          '"maintenance"=>(bool)($s["maintenance"]??false)]),PHP_EOL;')
NEXTCLOUD_STATUS = (
    "import json,urllib.request\n"
    "with urllib.request.urlopen('http://nextcloud/status.php',timeout=10) as r:\n"
    "    s=json.loads(r.read(65536))\n"
    "print(json.dumps({'installed':bool(s.get('installed')),'maintenance':bool(s.get('maintenance'))}))\n")


def now():
    return time.time()


def iso(timestamp=None):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now() if timestamp is None else timestamp))


def log(event, **fields):
    """One JSON line on stdout (PM2 log or the journal): event names, counts, states only."""
    print(json.dumps({"time": iso(), "event": event, **fields}, sort_keys=True), flush=True)


class Runner:
    """Runs commands; never raises for a non-zero exit. Tests substitute a fake."""

    def run(self, argv, *, timeout=60, data=None, env=None):
        environment = dict(os.environ, LC_ALL="C")
        if env:
            environment.update(env)
        try:
            result = subprocess.run(argv, input=data, capture_output=True, timeout=timeout, check=False,
                                    env=environment, text=isinstance(data, str) or data is None)
        except FileNotFoundError:
            return 127, "", f"{argv[0]}: not found"
        except subprocess.TimeoutExpired:
            return 124, "", f"{argv[0]}: timed out"
        except OSError as error:
            # e.g. fork failing (EAGAIN/ENOMEM) under memory or task pressure: a failed check, never
            # an exception out of the round (decision #113, review X2).
            return 126, "", f"{argv[0]}: {type(error).__name__}"
        return result.returncode, result.stdout, result.stderr


def load_json(path, default):
    try:
        return json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return default


def save_json(path, data, mode=0o600):
    path = Path(path)
    temporary = path.with_name("." + path.name + ".tmp")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, mode)
    with os.fdopen(fd, "w") as stream:
        json.dump(data, stream, indent=1, sort_keys=True)
    os.replace(temporary, path)


def ops_config(state_root=paths.STATE_ROOT):
    return load_json(Path(state_root) / OPS_CONFIG, {})


# Markers (spec #22 owns them; the names are spec #20's) ------------------------------------

def marker_status(path, at=None):
    """"active" while a backup or restore marker is before its deadline, "inactive" when absent or
    past it, "unreadable" when it cannot be parsed."""
    try:
        data = json.loads(Path(path).read_text())
    except FileNotFoundError:
        return "inactive"
    except (OSError, ValueError):
        return "unreadable"
    try:
        return "active" if float(data.get("deadline_epoch", 0)) >= (now() if at is None else at) else "inactive"
    except (AttributeError, TypeError, ValueError):
        return "unreadable"


def marker_active(path, at=None):
    return marker_status(path, at) == "active"


MARKERS = (paths.BACKUP_IN_PROGRESS.name, paths.RESTORE_IN_PROGRESS.name)


def maintenance_markers(state_root=paths.STATE_ROOT, at=None):
    """Markers before their deadline. An unreadable one suppresses nothing (decision #111 review
    round 4: nothing would ever clear a corrupt restore marker); see unreadable_markers."""
    run_dir = Path(state_root) / paths.RUN_DIR.name
    return [name for name in MARKERS if marker_status(run_dir / name, at) == "active"]


def unreadable_markers(state_root=paths.STATE_ROOT):
    run_dir = Path(state_root) / paths.RUN_DIR.name
    return [name for name in MARKERS if marker_status(run_dir / name) == "unreadable"]


def emergency_stopped(state_root=paths.STATE_ROOT):
    return (Path(state_root) / paths.RUN_DIR.name / paths.EMERGENCY_STOP.name).exists()


# Alerts --------------------------------------------------------------------------------------

def alert_command(state_root=paths.STATE_ROOT):
    return Path(state_root) / paths.BIN_DIR.name / paths.ALERT_COMMAND.name


def send_alert_result(runner, key, title, message, *, every=ALERT_EVERY_DEFAULT, priority="high",
                      state_root=paths.STATE_ROOT):
    """Queue one alert through spec #21's dispatcher (paths.ALERT_COMMAND): "queued", "suppressed"
    (its per-key throttle held it back) or "refused" (it failed, or could not be run)."""
    command = alert_command(state_root)
    argv = [sys.executable, "-I", str(command), "--key", key, "--every", str(int(every)), "--title", title,
            "--priority", priority, "--", message]
    code, out, _err = runner.run(argv, timeout=60)
    if code != 0:
        return "refused"
    lines = (out or "").strip().splitlines()
    return "suppressed" if lines and lines[-1].strip() == "suppressed" else "queued"


def send_alert(runner, key, title, message, *, every=ALERT_EVERY_DEFAULT, priority="high", state_root=paths.STATE_ROOT):
    """True when the dispatcher accepted the alert (queued, or held back by its own throttle)."""
    return send_alert_result(runner, key, title, message, every=every, priority=priority,
                             state_root=state_root) != "refused"


# Production checks -------------------------------------------------------------------------

def stack_config(state_root=paths.STATE_ROOT):
    return load_json(Path(state_root) / paths.STACK_CONFIG.name, {})


def pm2_apps(runner):
    """{name: {"status", "restarts", "pid"}} from `pm2 jlist`; None when PM2 cannot be read."""
    code, out, _err = runner.run(["pm2", "jlist"], timeout=CHECK_TIMEOUT)
    if code != 0:
        return None
    try:
        rows = jlist_rows(out)
    except ValueError:
        return None
    return {row.get("name"): {"status": (row.get("pm2_env") or {}).get("status"),
                              "restarts": (row.get("pm2_env") or {}).get("restart_time", 0), "pid": row.get("pid"),
                              "since_ms": (row.get("pm2_env") or {}).get("pm_uptime")}
            for row in rows if isinstance(row, dict)}


def container_state(runner, service):
    code, out, _err = runner.run(["docker", "inspect", "--format", "{{json .State}}", f"{paths.PROJECT}-{service}-1"],
                                 timeout=CHECK_TIMEOUT)
    if code != 0:
        return None
    try:
        return json.loads(out)
    except ValueError:
        return None


def gateway_health(runner):
    """Spec #20's production healthcheck: PROXY v2 LOCAL to the socket, TLS, GET /health."""
    code, out, _err = runner.run(["docker", "exec", "--user", GATEWAY_EXEC_USER, ACCESS_CONTAINER, "python", "-m",
                                  "access.health"],
                                 timeout=CHECK_TIMEOUT)
    try:
        return code == 0 and json.loads(out.strip().splitlines()[-1]) == {"status": "ready"}
    except (ValueError, IndexError):
        return False


def nextcloud_status(runner, via_gateway=True):
    """Nextcloud status.php: "ok", "maintenance" (an upgrade or the backup window; not a failure)
    or "failed". From the internal network through the gateway container when it runs, else from
    Nextcloud's own loopback (anj-qual b2dev-7: with the gateway held by the emergency stop the
    old probe failed and the watchdog restarted a healthy Nextcloud)."""
    # As the gateway user: a `docker exec` inherits the container's start-step capabilities
    # (CHOWN, DAC_READ_SEARCH, SETGID, SETUID), which this read-only probe must not hold (review L-a).
    argv = (["docker", "exec", "--user", GATEWAY_EXEC_USER, ACCESS_CONTAINER, "python", "-c", NEXTCLOUD_STATUS]
            if via_gateway else
            ["docker", "exec", NEXTCLOUD_CONTAINER, "php", "-r", NEXTCLOUD_STATUS_LOCAL])
    code, out, _err = runner.run(argv, timeout=CHECK_TIMEOUT)
    try:
        status = json.loads(out.strip().splitlines()[-1])
    except (ValueError, IndexError):
        return "failed"
    if code != 0 or status.get("installed") is not True:
        return "failed"
    return "maintenance" if status.get("maintenance") else "ok"


def duration(text):
    """Seconds of a Compose duration such as "5s", "1m30s" or "500ms"."""
    total = 0.0
    for value, unit in re.findall(r"(\d+(?:\.\d+)?)(ms|us|ns|h|m|s)", str(text or "")):
        total += float(value) * {"h": 3600, "m": 60, "s": 1, "ms": 1e-3, "us": 1e-6, "ns": 1e-9}[unit]
    return total


def health_bounds(compose_path=None):
    """{compose service: seconds a container may report health `starting` before it counts as a
    failure}: the service's own healthcheck start_period + interval x retries (spec #20's
    compose.prod.json), e.g. Nextcloud 30 s + 60 x 5 s = 330 s."""
    compose_path = compose_path or paths.RELEASE_CURRENT / "deploy" / "compose.prod.json"
    bounds = {}
    for service, spec in (load_json(compose_path, {}).get("services") or {}).items():
        check = spec.get("healthcheck") or {}
        if check.get("test"):
            bounds[service] = duration(check.get("start_period", "0s")) + \
                duration(check.get("interval", "30s")) * int(check.get("retries", 3))
    return bounds


def started_at(state):
    """Epoch seconds of Docker's State.StartedAt ("2026-11-03T10:00:00.123456789Z"), or None."""
    text = str((state or {}).get("StartedAt") or "")
    try:
        return calendar.timegm(time.strptime(text[:19], "%Y-%m-%dT%H:%M:%S"))
    except ValueError:
        return None


WAIT = "wait:"              # a result that is not a failure yet: starting, stopped on purpose, maintenance
CLOCK_SLACK = 60            # a recorded time this far ahead of now means the clock stepped back
NO_HEALTHCHECK_GRACE = 60   # seconds a service without a healthcheck is "starting" after its container starts
CONTAINER_PENDING_GRACE = 120  # PM2 online, container not yet created (run-service starts it after its waits)


def health_window(app, bounds):
    """Seconds one normal start of `app` may take before it is healthy: the container pending
    grace plus the service's own healthcheck bound (or the no-healthcheck grace). The operations
    apps and the console backend have no container: the pending grace only. Decision #113 bounds
    "not yet" at twice this."""
    if app not in paths.STACK_APPS:
        return CONTAINER_PENDING_GRACE
    if not bounds:                     # compose.prod.json unreadable: the most generous window known
        return UNKNOWN_HEALTH_WINDOW
    return CONTAINER_PENDING_GRACE + bounds.get(paths.COMPOSE_SERVICE[app], NO_HEALTHCHECK_GRACE)


UNKNOWN_HEALTH_WINDOW = 900


def haproxy_path(host, bind_address, cafile, timeout=10.0):
    """TLS to the bind address with SNI <host>, pinned to the household issuer, GET /health."""
    try:
        context = ssl.create_default_context(cafile=str(cafile))
        with socket.create_connection((bind_address, paths.BIND_PORT), timeout=timeout) as raw, \
                context.wrap_socket(raw, server_hostname=host) as tls:
            tls.sendall(b"GET /health HTTP/1.1\r\nHost: " + host.encode() + b"\r\nConnection: close\r\n\r\n")
            data = b""
            while len(data) < 16384:
                chunk = tls.recv(4096)
                if not chunk:
                    break
                data += chunk
    except (OSError, ssl.SSLError, ValueError):
        return False
    return data.startswith(b"HTTP/1.1 200")


def console_answers(socket_path=None, timeout=CHECK_TIMEOUT):
    """The console backend (PM2 app `console`, spec #27) serves its socket: an empty request gets
    its curated refusal, which proves the server loop answers; nothing is changed or logged. The
    watchdog runs as the backend's own account, an allowed peer."""
    socket_path = socket_path or paths.CONSOLE_SOCKET
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(timeout)
            connection.connect(str(socket_path))
            connection.sendall(b"{}")
            connection.shutdown(socket.SHUT_WR)
            data = b""
            while len(data) < 4096:
                chunk = connection.recv(4096)
                if not chunk:
                    break
                data += chunk
        reply = json.loads(data)
    except (OSError, ValueError):
        return False
    return isinstance(reply, dict) and reply.get("error") == "refused"


class Probe:
    """One round of the watchdog's checks: {app: None (healthy), "wait:<why>" (not a failure: an
    intentional or not-yet state) or a failure name}.

    Only PM2 `errored`, or an app PM2 reports `online` whose checks fail, is a failure. PM2
    `stopped`/`stopping`/`launching`/`waiting restart` (prod.py stop, redeploy, PM2's own backoff)
    are intentional or in progress. Docker health `starting` is "not yet" for the service's own
    start_period + interval x retries; only `unhealthy`, or `starting` beyond that bound, fails.
    Per app: gateway -> spec #20's healthcheck, haproxy -> the HAProxy path, nextcloud ->
    status.php (maintenance is "not yet"), console -> its socket answers (after a start grace like
    a service without a healthcheck). Apps held by the emergency stop are skipped by the caller."""

    def __init__(self, runner, state_root=paths.STATE_ROOT, clock=time.time, bounds=None):
        self.runner = runner
        self.state_root = Path(state_root)
        self.clock = clock
        self.bounds = bounds

    def results(self, apps, *, skip=()):
        pm2 = pm2_apps(self.runner)
        self.pm2 = pm2           # the same snapshot for the watchdog's crash-loop count
        results = {}
        config = stack_config(self.state_root)
        bounds = self.bounds if self.bounds is not None else health_bounds()
        now = self.clock()
        gateway = {}

        def via_gateway():
            if "running" not in gateway:
                gateway["running"] = bool((container_state(self.runner, paths.COMPOSE_SERVICE["gateway"]) or {})
                                          .get("Running"))
            return gateway["running"]
        for app in apps:
            if app in skip:
                continue
            if pm2 is None:
                results[app] = WAIT + "pm2-unreadable"
                continue
            row = pm2.get(app) or {}
            status = row.get("status")
            if status == "errored":
                results[app] = "pm2-errored"
                continue
            if status != "online":
                results[app] = WAIT + "pm2-" + (status or "missing").replace(" ", "-")
                continue
            if app == paths.CONSOLE_APP:
                if console_answers():
                    results[app] = None
                else:
                    online_for = now - (row.get("since_ms") or 0) / 1000
                    if online_for < -CLOCK_SLACK:      # PM2's start time is ahead: the clock stepped back
                        online_for = NO_HEALTHCHECK_GRACE
                    results[app] = (WAIT + "starting") if online_for < NO_HEALTHCHECK_GRACE else "console-socket"
                continue
            if app not in paths.STACK_APPS:
                results[app] = None
                continue
            service = paths.COMPOSE_SERVICE[app]
            state = container_state(self.runner, service)
            if not state or not state.get("Running"):
                online_for = now - (row.get("since_ms") or 0) / 1000
                if online_for < -CLOCK_SLACK:          # PM2's start time is ahead: the clock stepped back
                    online_for = CONTAINER_PENDING_GRACE
                results[app] = (WAIT + "starting") if online_for < CONTAINER_PENDING_GRACE else "container-not-running"
                continue
            age = now - (started_at(state) or 0)
            if age < -CLOCK_SLACK:                     # StartedAt is ahead: the clock stepped back
                age = NO_HEALTHCHECK_GRACE
            health = (state.get("Health") or {}).get("Status")
            if health == "starting":
                results[app] = (WAIT + "starting") if age <= bounds.get(service, 0) else "container-starting-too-long"
                continue
            if health not in (None, "healthy"):
                # Nextcloud's own healthcheck fails while it is in maintenance (an upgrade, or one
                # left behind by a failed upgrade): that is the maintenance state, bounded by the
                # watchdog (30 minutes, then one alert), never a restart.
                if app == "nextcloud" and nextcloud_status(self.runner, via_gateway()) == "maintenance":
                    results[app] = WAIT + "maintenance"
                else:
                    results[app] = "container-" + str(health)
                continue
            if health is None and age < NO_HEALTHCHECK_GRACE:
                results[app] = WAIT + "starting"
                continue
            nextcloud = nextcloud_status(self.runner, via_gateway()) if app == "nextcloud" else None
            if app == "gateway" and not gateway_health(self.runner):
                results[app] = "healthcheck"
            elif nextcloud == "maintenance":
                results[app] = WAIT + "maintenance"
            elif nextcloud == "failed":
                results[app] = "status-php"
            elif app == "haproxy" and not haproxy_path(config.get("host") or "", config.get("bind_address") or "",
                                                       self.state_root / paths.OPERATOR_DIR.name / "issuer.crt"):
                results[app] = "haproxy-path"
            else:
                results[app] = None
        return results


def ddns_state(state_root=paths.STATE_ROOT):
    return load_json(Path(state_root) / paths.RUN_DIR.name / paths.DDNS_STATE.name, None)


# Quiet windows (the watchdog never fights intentional work, decision #111 bounds each) --------

PROD_ACTIONS = {"up", "stop", "redeploy"}          # spec #20 lifecycle commands that restart apps
# pair and backup stop no service (pair issues and approves a code; a real backup run suppresses
# through its own spec #22 marker and deadline), so they never quiet the watchdog either.
SETUP_READ_ONLY = {"status", "doctor", "first-code", "pair", "backup", "--dry-run", "-h", "--help"}
APT_TOOLS = {"apt-get", "apt", "dpkg"}
PYTHON = re.compile(r"python3(\.\d+)?$")
PYTHON_VALUE_OPTIONS = {"-W", "-X", "--check-hash-based-pycs"}


def script_and_arguments(words):
    """(script, arguments) when `words` is a real Python interpreter running a script (or `-m`
    module): the interpreter's own options are skipped, so `vim script`, `less script`,
    `grep x script` or `python3 -c ...` never match."""
    if not words or not PYTHON.search(Path(words[0]).name):
        return None, []
    index = 1
    while index < len(words) and words[index].startswith("-"):
        if words[index] == "-c":
            return None, []
        if words[index] == "-m":
            index += 1
            break
        index += 2 if words[index] in PYTHON_VALUE_OPTIONS else 1
    return (words[index], words[index + 1:]) if index < len(words) else (None, [])


def busy_processes(proc=Path("/proc")):
    """Quiet reasons from running processes (decision #111): only a real interpreter running
    anj-cloud-setup with a changing command (install, --adopt-data, --restore-from), prod.py
    up/stop/redeploy, or a package run (unattended-upgrade, apt, apt-get, dpkg). Never a read-only
    or service-neutral command (status, doctor, first-code, pair, backup, --dry-run), an editor or a pager. Each reason is bounded
    by the watchdog (QUIET_BOUNDS)."""
    reasons = set()
    for entry in proc.iterdir():
        if not entry.name.isdigit():
            continue
        try:
            words = [part.decode("utf-8", "replace") for part in (entry / "cmdline").read_bytes().split(b"\0") if part]
        except OSError:
            continue
        if not words:
            continue
        script, arguments = script_and_arguments(words)
        name = Path(script).name if script else ""
        if (name == "anj-cloud-setup" or script == "deploy.vm.bootstrap") and not SETUP_READ_ONLY & set(arguments):
            reasons.add("anj-cloud-setup")
        elif name == "prod.py" and arguments[:1] and arguments[0] in PROD_ACTIONS:
            reasons.add("prod.py " + arguments[0])
        elif name == "unattended-upgrade":
            reasons.add("apt/dpkg")
        elif Path(words[0]).name in APT_TOOLS and not (len(words) > 1 and words[1].startswith("--print")):
            reasons.add("apt/dpkg")
    return sorted(reasons)


# Decision #111: every mutating maintenance run suppresses the watchdog for at most 15 minutes,
# measured from when the watchdog first saw it; past it that reason no longer suppresses anything
# and one "watchdog suppressed by <reason>" alert is sent. Spec #22's backup and restore markers
# are bounded by their own deadline instead (marker_active); the watchdog keeps its short tail
# after the update run inside the run's own 15 minutes.
MAINTENANCE_QUIET = 15 * 60
QUIET_BOUNDS = (("anj-cloud-setup", MAINTENANCE_QUIET), ("prod.py", MAINTENANCE_QUIET), ("apt/dpkg", MAINTENANCE_QUIET),
                ("upgrade", MAINTENANCE_QUIET), ("system", MAINTENANCE_QUIET), ("boot grace", MAINTENANCE_QUIET),
                ("after upgrade", MAINTENANCE_QUIET))
QUIET_BOUND_DEFAULT = MAINTENANCE_QUIET


def quiet_bound(reason):
    """Seconds `reason` may suppress the watchdog; None for the markers (their deadline bounds them)."""
    if reason in (paths.BACKUP_IN_PROGRESS.name, paths.RESTORE_IN_PROGRESS.name):
        return None
    return next((bound for prefix, bound in QUIET_BOUNDS if reason.startswith(prefix)), QUIET_BOUND_DEFAULT)


def alert_slug(text):
    """`text` as part of an alert key (letters, digits, '.', '_', '-')."""
    return re.sub(r"[^A-Za-z0-9._-]+", "-", text).strip("-")[:40] or "unknown"


def system_quiet(runner, uptime_seconds=None, boot_grace=600):
    """Reasons from systemd: the update run active, the system starting or stopping (the guarded
    reboot), and the first 10 minutes after boot, which belong to the boot health notice."""
    reasons = []
    _code, out, _err = runner.run(["systemctl", "is-active", "apt-daily-upgrade.service"], timeout=CHECK_TIMEOUT)
    if out.strip() in ("active", "activating", "deactivating", "reloading"):
        reasons.append("upgrade")
    _code, out, _err = runner.run(["systemctl", "is-system-running"], timeout=CHECK_TIMEOUT)
    if out.strip() in ("initializing", "starting", "stopping"):
        reasons.append("system " + out.strip())
    if uptime_seconds is None:
        try:
            uptime_seconds = float(Path("/proc/uptime").read_text().split()[0])
        except (OSError, ValueError, IndexError):
            uptime_seconds = boot_grace
    if uptime_seconds < boot_grace:
        reasons.append("boot grace")
    return reasons


SUBSCRIBE_LINK_LIFETIME = 86400


def sweep_one_time_secrets(state_root=paths.STATE_ROOT, now=None):
    """Spec #21's one-time files never outlive their use: the first pairing code once its
    invitation expired (the gateway's 10 minutes, recorded by the bootstrap in setup.json), the
    no-terminal ntfy subscribe link after a day. Returns the names removed (never contents)."""
    now = time.time() if now is None else now
    secrets_dir = Path(state_root) / paths.SECRETS_DIR.name
    removed = []
    code = secrets_dir / paths.FIRST_PAIRING_CODE.name
    invite = load_json(Path(state_root) / "setup.json", {}).get("first_invite") or {}
    try:
        expires = float(invite.get("expires") or 0)
    except (TypeError, ValueError):
        expires = 0
    if code.exists() and expires and expires < now:
        code.unlink(missing_ok=True)
        removed.append(code.name)
    link = secrets_dir / "ntfy-subscribe-link"
    try:
        if now - link.stat().st_mtime > SUBSCRIBE_LINK_LIFETIME:
            link.unlink(missing_ok=True)
            removed.append(link.name)
    except FileNotFoundError:
        pass
    return removed
