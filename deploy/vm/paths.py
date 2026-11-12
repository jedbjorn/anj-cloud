"""Interface constants of the anj-cloud production VM (spec #20 rev7; decisions #84, #85, #89).

The single source of the paths, socket names, markers, ids and PM2 app names shared by the
stack (spec #20), the bootstrap and VM operations (spec #21), backups (spec #22) and DDNS and
go-live (spec #23). Standard library only, so any tool can import it from a release directory:

    from deploy.vm import paths            # inside the checkout or release source
    python3 -I deploy/vm/paths.py --json   # every constant as JSON, for shell tools

Values describe the VM; nothing here exists on the VM host.
"""

import json
from pathlib import Path
import sys

# Identity -------------------------------------------------------------------------------
PROJECT = "anj-cloud-prod"                  # Compose project
IMAGE_REPOSITORY = PROJECT + "-access"      # gateway image, tagged <commit12>
FETCH_IMAGE_REPOSITORY = PROJECT + "-fetch" # media fetch worker image (spec #42), tagged <commit12>
VM_USER = "anj"                             # runs prod.py and PM2 (passwordless sudo, #89 (5))
VM_GROUP = "anj"                            # group of the HAProxy admin socket
GATEWAY_UID = 10001                         # services/access/Dockerfile USER
GATEWAY_GROUP = "anj-gw"                    # owns the gateway socket directory
GATEWAY_GID = 10002                         # fixed; HAProxy's container gets it as supplementary group
FETCH_UID = 10003                           # services/fetch/Dockerfile USER (media fetch worker, spec #42)
SPOOL_GID = 10004                           # the fetch spool's group: the worker's and the gateway's (ANJ_RUN_GROUPS)
FETCH_BRIDGE = "anj-fetch"                  # the worker network's bridge; the VM firewall drops its private traffic

# Data disk ------------------------------------------------------------------------------
DATA_LABEL = "ANJ_DATA"                     # ext4 label of the data disk
DATA_ROOT = Path("/srv/anj-cloud")
DOCKER_ROOT = DATA_ROOT / "docker"          # Docker data-root: volumes and images on the data disk
# Extracted release sources, outside the private state tree: release/<commit12>/ and the stable
# symlink release/current -> <commit12>, switched atomically by prod.py. Run
# `RELEASE_CURRENT / "deploy/prod.py"` (e.g. over SSH from the VM host) to address the live release.
RELEASE_SOURCE_DIR = DATA_ROOT / "release"
RELEASE_CURRENT = RELEASE_SOURCE_DIR / "current"
STATE_ROOT = DATA_ROOT / "state"            # 0700, owner anj; prod.py --state-root default

OPERATOR_DIR = STATE_ROOT / "operator"      # issuer and server key/certificate, journals
SECRETS_DIR = STATE_ROOT / "secrets"        # 0700; files 0600
RELEASE_DIR = STATE_ROOT / "release"        # release/<commit12>/{source.tar,compose.json,haproxy.cfg,ecosystem.config.js,release.json}
RUN_DIR = STATE_ROOT / "run"                # markers and the alert spool
BIN_DIR = STATE_ROOT / "bin"                # current release's run-service, paths.py, stackenv.py (PM2 scripts)
HAPROXY_STATE_DIR = STATE_ROOT / "haproxy"  # 0755, mounted read-only (whole dir) into haproxy
STACK_CONFIG = STATE_ROOT / "stack.json"    # host, release, recorded by prod.py setup
BACKUP_RECORD = STATE_ROOT / "backup.json"  # spec #22
ACCOUNTS_FILE = STATE_ROOT / "accounts.json"  # first-admin fallback (#89 (9))
SETUP_LOG_DIR = STATE_ROOT / "setup-log"    # spec #21 evidence, no secrets

# Household ACL: spec #23's DDNS app replaces it by atomic rename inside HAPROXY_STATE_DIR (hence
# the directory mount); HAProxy loads it at start (`-f`) and the runtime entry is replaced
# through the admin socket.
HOUSEHOLD_ACL = HAPROXY_STATE_DIR / "household.acl"

# Markers (files under RUN_DIR) ----------------------------------------------------------
EMERGENCY_STOP = RUN_DIR / "emergency-stop"            # prod.py emergency-stop / resume
BACKUP_IN_PROGRESS = RUN_DIR / "backup-in-progress"    # spec #22, holds a deadline
RESTORE_IN_PROGRESS = RUN_DIR / "restore-in-progress"  # spec #22, holds a deadline
ALERT_SPOOL = RUN_DIR / "alerts"                       # spec #21 anj-alert queue, 0700
# The operations lock (flock): spec #22's backup holds it for a run; prod.py redeploy (and so
# anj-cloud-setup upgrade) holds it for a release switch (decision #122). RESTORE_LOCK is held by a restore.
OPS_LOCK = RUN_DIR / "backup.lock"
RESTORE_LOCK = RUN_DIR / "restore.lock"
RELEASE_SWITCH = RUN_DIR / "release-switch"            # {"pid", "started"} while prod.py redeploy holds OPS_LOCK
# Spool record when the dispatcher is unavailable: one file per alert, written atomically,
# 0600, named "<UTC yyyymmddTHHMMSS.ffffffZ>-<key>.json", content
# {"key": str, "title": str, "priority": str, "message": str, "created": ISO-8601 UTC}.
ALERT_SPOOL_FIELDS = ("key", "title", "priority", "message", "created")
ALERT_COMMAND = BIN_DIR / "anj-alert"                  # spec #21 dispatcher CLI: [--key K --every S] [--title T] [--priority P] -- MESSAGE
DDNS_STATE = RUN_DIR / "ddns-state.json"               # spec #23 DDNS last result; the watchdog reads it

# Secrets (agents never read, copy or print the token, restic password or ntfy topic) ----
CLOUDFLARE_TOKEN = SECRETS_DIR / "cloudflare-dns-token"
NTFY_TOPIC = SECRETS_DIR / "ntfy-topic"
RESTIC_PASSWORD = SECRETS_DIR / "restic-password"
FIRST_PAIRING_CODE = SECRETS_DIR / "first-pairing-code"

# Runtime sockets (tmpfs, created by spec #21's tmpfiles.d) -------------------------------
GATEWAY_SOCKET_DIR = Path("/run/anj-cloud-gw")         # uid 10001, gid 10002, mode 2750
GATEWAY_SOCKET_NAME = "gateway.sock"
GATEWAY_SOCKET = GATEWAY_SOCKET_DIR / GATEWAY_SOCKET_NAME  # 0660; HAProxy connects, PROXY v2
GATEWAY_SOCKET_DIR_MODE = 0o2750
HAPROXY_RUN_DIR = Path("/run/anj-haproxy")              # owner root, group anj, mode 0750
HAPROXY_RUN_DIR_MODE = 0o750
HAPROXY_ADMIN_SOCKET_NAME = "admin.sock"
HAPROXY_ADMIN_SOCKET = HAPROXY_RUN_DIR / HAPROXY_ADMIN_SOCKET_NAME  # level admin, 0660, group anj
HAPROXY_ADMIN_SOCKET_MODE = 0o660
# Console backend (spec #27; decision #112 (1)): PM2 app `console`, running as VM_USER, listens
# only on this socket. The directory is owner VM_USER, group anj-gw (GATEWAY_GID), setgid 2750; the
# socket 0660, so only VM_USER (the recovery CLI) and the gateway (supplementary group anj-gw)
# reach it. Bind-mounted read-only into the gateway container at the same path.
CONSOLE_APP = "console"
CONSOLE_DIR = Path("/run/anj-console")
CONSOLE_DIR_MODE = 0o2750
CONSOLE_SOCKET_NAME = "backend.sock"
CONSOLE_SOCKET = CONSOLE_DIR / CONSOLE_SOCKET_NAME
CONSOLE_SOCKET_MODE = 0o660
ADMIN_COMMAND_LINK = Path("/usr/local/bin/anj-cloud-admin")   # -> RELEASE_CURRENT/deploy/vm/anj-cloud-admin

# The only state HAProxy (capability-less container root) reads at start, by exact path relative
# to STATE_ROOT; public content, never group/other-writable: the directory may be 0755 and the
# files 0644. <commit12> stands for one release's 12 lowercase hex digits. Everything else in the
# state tree stays 0700/0600.
PUBLIC_STATE_PATHS = ("haproxy", "haproxy/household.acl", "haproxy/haproxy.cfg", "release/<commit12>/haproxy.cfg")

# Ingress --------------------------------------------------------------------------------
BIND_PORT = 443
DEFAULT_BIND_ADDRESS = "10.77.10.10"        # anj-prod's address on the VM host; a bootstrap parameter
DEFAULT_HOUSEHOLD_LAN = "192.168.0.0/24"    # bootstrap parameter

# Backup share (spec #22) ----------------------------------------------------------------
BACKUP_MOUNT = Path("/mnt/anj-backup")
BACKUP_TAG = "anj-backup"                   # virtiofs tag
RESTIC_REPOSITORY = BACKUP_MOUNT / "restic"

# PM2 ------------------------------------------------------------------------------------
# Stack apps in start (dependency) order; each runs `deploy/vm/run-service <app>` attached.
# fetch-net holds the media fetch worker's network namespace and guard; fetch is the worker (spec #42).
STACK_APPS = ("db", "redis", "nextcloud", "cron", "gateway", "haproxy", "fetch-net", "fetch")
# PM2 app name -> Compose service name.
COMPOSE_SERVICE = {"db": "db", "redis": "redis", "nextcloud": "nextcloud", "cron": "cron",
                   "gateway": "access", "haproxy": "haproxy", "fetch-net": "fetch-net", "fetch": "fetch"}
# An app starts only when these apps' services are healthy.
DEPENDENCIES = {"db": (), "redis": (), "nextcloud": ("db", "redis"), "cron": ("nextcloud",),
                "gateway": ("nextcloud",), "haproxy": ("gateway",), "fetch-net": (), "fetch": ("fetch-net",)}
EMERGENCY_APPS = ("haproxy", "gateway")     # refused while EMERGENCY_STOP exists
EMERGENCY_EXIT_CODE = 78                    # run-service exit while flagged; in PM2 stop_exit_codes
STOP_GRACE_SECONDS = 30                     # run-service: docker compose stop --timeout
# PM2 kill_timeout: above run-service's worst stop path (docker stop up to grace + 20 s, then the
# child is terminated grace + 15 s after the signal and killed 5 s later), so SIGKILL is never normal.
KILL_TIMEOUT_MS = 90000
DEPENDENCY_WAIT_SECONDS = 600               # run-service gives up (PM2 backs off and retries)
QUIET_APPS = ("nextcloud", "cron", "db", "redis")  # PM2 output to /dev/null (#68 (5))
OPERATIONS_APPS = ("watchdog", "watchers", "alerts")  # spec #21
# Every long-running PM2 app outside the stack that the watchdog supervises (spec #21, #27).
WATCHED_EXTRA_APPS = ("alerts", "watchers", CONSOLE_APP)
DDNS_APP = "ddns"                           # spec #23 (cron_restart, autorestart false)

# prod.py subcommands (spec #20 Operator Tooling 5)
PROD_SUBCOMMANDS = ("setup", "up", "check", "status", "stop", "redeploy", "emergency-stop", "resume")
PROD_COMMAND = "deploy/prod.py"             # relative to the release source


def as_dict():
    """Every constant, JSON-friendly."""
    result = {}
    for name, value in globals().items():
        if not name.isupper():
            continue
        if isinstance(value, Path):
            value = str(value)
        elif isinstance(value, tuple):
            value = list(value)
        elif isinstance(value, dict):
            value = {key: list(item) if isinstance(item, tuple) else item for key, item in value.items()}
        result[name] = value
    return result


if __name__ == "__main__":
    if sys.argv[1:] not in ([], ["--json"]):
        raise SystemExit("usage: paths.py [--json]")
    print(json.dumps(as_dict(), indent=2, sort_keys=True))
