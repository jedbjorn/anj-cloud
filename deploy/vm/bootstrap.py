"""anj-cloud-setup — set up and look after an anj-cloud server on Debian 13.

  sudo anj-cloud-setup              guided install (or repair: re-runs only what is missing)
  sudo anj-cloud-setup pair         pair the first device (new code, wait until the device pairs)
  sudo anj-cloud-setup backup       set up encrypted backups and save the password
  anj-cloud-setup status            one-screen health summary (read-only)
  sudo anj-cloud-setup doctor       find problems and print the fix for each (read-only)
  sudo …/anj-cloud-setup upgrade    switch to the release deploy/vm/stage.py --upgrade staged (decision #122)
  sudo anj-cloud-setup upgrade --rollback   switch back to the previous release (same health-checked path)
  --dry-run                         show what would change; changes nothing, asks no secret
  --answers FILE                    unattended install from a TOML file (secrets by file path only)
  --adopt-data / --restore-from     rebuild onto the existing data disk / from the backup drive

Before the first install the command is the staged copy, `sudo /var/lib/anj-cloud-setup/src/deploy/vm/
anj-cloud-setup` (deploy/vm/stage.py prints the exact ssh line); the install links
/usr/local/bin/anj-cloud-setup to the installed release.

Turns a fresh Debian 13 machine (the anj-prod VM on the VM host, anj-qual, or any small amd64 machine
with a spare data disk and the admin user `anj`) into a complete anj-cloud server (spec #21; #85,
#87, #89; the guided flow follows the bootstrap UX audit, decisions #109 and #112).

Every step is check -> plan -> apply -> verify; a re-run on a complete install reports each step
"already done" and restarts nothing. A disk with any signature is never formatted. Secrets (the
Cloudflare token, the ntfy topic, the restic password, the first pairing code) never reach
arguments, logs or the evidence file /srv/anj-cloud/state/setup-log/<UTC>.json; they are shown
only on the terminal.

Standard library only (Debian 13 ships Python 3.13). Paths, ids and app names are spec #20's
deploy/vm/paths.py; the guided copy is deploy/vm/guide.py.
"""

import argparse
import datetime
import fcntl
import getpass
import grp
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import platform
import pwd
import re
import secrets
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
import tomllib
import uuid as uuid_module
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parent.parent.parent      # the source tree this tool runs from
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from deploy import deployment_profile  # noqa: E402
from deploy.vm import guide, paths  # noqa: E402
from deploy.vm.pm2json import jlist_rows  # noqa: E402

# Interfaces ------------------------------------------------------------------------------------
# Where deploy/vm/stage.py puts a release source before the first bootstrap of a fresh VM (the
# data disk, and so /srv/anj-cloud/release/current, exists only after step 3).
STAGE_DIR = Path("/var/lib/anj-cloud-setup")
STAGE_TAR = STAGE_DIR / "source.tar"
STAGE_SRC = STAGE_DIR / "src"
PM2_DIR = Path("/opt/anj-cloud/pm2")
PM2_LINK = Path("/usr/local/bin/pm2")
ETC_DIR = Path("/etc/anj-cloud")
FIREWALL_FILE = ETC_DIR / "firewall.nft"
SYSTEMD_DIR = Path("/etc/systemd/system")
FSTAB = Path("/etc/fstab")
DAEMON_JSON = Path("/etc/docker/daemon.json")
JOURNALD_CONF = Path("/etc/systemd/journald.conf.d/zz-anj-cloud.conf")
LOGROTATE_CONF = Path("/etc/logrotate.d/anj-cloud-pm2")
TMPFILES_CONF = Path("/etc/tmpfiles.d/anj-cloud.conf")
APT_UU_CONF = Path("/etc/apt/apt.conf.d/52anj-cloud-unattended-upgrades")
APT_PERIODIC_CONF = Path("/etc/apt/apt.conf.d/21anj-cloud-periodic")
DOCKER_KEY = Path("/etc/apt/keyrings/anj-cloud-docker.asc")
DOCKER_LIST = Path("/etc/apt/sources.list.d/anj-cloud-docker.list")
DOCKER_PREFS = Path("/etc/apt/preferences.d/anj-cloud-docker")
FALLBACK_LOG_DIR = Path("/var/log/anj-cloud-setup")
SETUP_RECORD = paths.STATE_ROOT / "setup.json"     # this install: machine, release, first invitation id
# This machine's alerts_tag and ntfy_server for the dispatcher. In run/, which backups skip and a
# restore never moves (spec #22 STATE_LOCAL): a drill VM keeps its own tag, and the restore step
# can install the dispatcher before the snapshot lands.
OPS_CONFIG = paths.RUN_DIR / "ops.json"
OPS_ECOSYSTEM = paths.STATE_ROOT / "ops" / "ecosystem.config.js"
SOURCE_DIR = Path(__file__).resolve().parent         # deploy/vm of this tree
# The stable command every printed instruction uses once step 10 links it (S3); before that, the
# absolute path of the copy that is running.
COMMAND_LINK = Path("/usr/local/bin/anj-cloud-setup")
LAUNCHER = SOURCE_DIR / "anj-cloud-setup"
COMMAND_TARGET = paths.RELEASE_CURRENT / "deploy" / "vm" / "anj-cloud-setup"
# Spec #27's recovery CLI, run as anj over SSH from the VM host (decision #112 (1)): the live release's.
ADMIN_LINK = paths.ADMIN_COMMAND_LINK
ADMIN_TARGET = paths.RELEASE_CURRENT / "deploy" / "vm" / "anj-cloud-admin"
FSTAB_MARK = "# anj-cloud"
# The operator's one VM host step for B1's host check (#49, #104 (2)): copy the public issuer certificate
# to a temp file, check it is a certificate and print its fingerprint, then install it atomically,
# and keep a user-owned copy (~/anj-cloud-ca.crt; devices no longer need it, decision #151). A failed
# ssh never installs an empty or partial file (the && chain stops, the temp file is removed).
HALO_ISSUER_COMMAND = (   # bash -c: the VM host's login shell is fish
    "bash -c 't=$(mktemp) && ssh -F ~/.local/share/anj-cloud/prod-vm/ssh_config anj-prod "
    f"cat {paths.OPERATOR_DIR}/issuer.crt > \"$t\" && openssl x509 -noout -fingerprint -sha256 -in \"$t\" && "
    "sudo install -m 644 -o root -g root \"$t\" /etc/anj-cloud-host/issuer.crt.new && "
    "sudo mv -f /etc/anj-cloud-host/issuer.crt.new /etc/anj-cloud-host/issuer.crt && "
    "install -m 644 \"$t\" ~/anj-cloud-ca.crt; rm -f \"$t\"'")
# Written on the OS disk before the only mkfs this tool runs (the UUID is chosen here and passed
# to mkfs): an install interrupted after mkfs recognises its own data disk on the next run.
FORMATTED_MARKER = STAGE_DIR / "formatted-data-disk-uuid"

# Package source (decision #89 (1)): Debian 13's docker.io 26.1.5 and docker-compose 2.26.1
# satisfy compose.prod.json (healthcheck start_interval needs Engine >= 25.0 and Compose >= 2.20.2).
ENGINE_MIN = (25, 0)
COMPOSE_MIN = (2, 20, 2)
BASE_PACKAGES = ("nodejs", "npm", "nftables", "unattended-upgrades", "logrotate", "curl", "ca-certificates", "python3",
                 # prod.py and the operator CLI verify certificates (cryptography) and sign with openssl.
                 "python3-cryptography", "openssl",
                 # Terminal QR codes (the ntfy subscribe link), rendered from stdin to the terminal only.
                 "qrencode",
                 # B1's cloud-init seed installs no packages; the guest agent lets libvirt shut down cleanly.
                 "qemu-guest-agent")
# Debian 13 splits the CLI out of docker.io (docker-cli is only Recommended, and setup installs with
# --no-install-recommends): name it, or /usr/bin/docker is missing (anj-qual run b2dev-2).
DEBIAN_DOCKER = ("docker.io", "docker-cli", "docker-compose")
# Fallback only when Debian's versions do not fit (not taken on Debian 13): Docker's apt repository,
# key pinned by digest, versions pinned to a series, its origin added to unattended-upgrades.
DOCKER_REPO = "https://download.docker.com/linux/debian"
DOCKER_KEY_URL = DOCKER_REPO + "/gpg"
DOCKER_KEY_SHA256 = "1500c1f56fa9e26b9b8f42452a553675796ade0807cdce11975eb98170b3a570"
DOCKER_REPO_PACKAGES = ("docker-ce", "docker-ce-cli", "containerd.io", "docker-compose-plugin")
DOCKER_PIN = {"docker-ce": "5:29.9.*", "docker-ce-cli": "5:29.9.*", "docker-compose-plugin": "5.7.*"}
DOCKER_ORIGIN = '\t"origin=Docker,label=Docker CE,codename=${distro_codename}";\n'

_PROFILE = deployment_profile.load()    # household values: deploy/deployment_profile.py
DEFAULT_HOST = _PROFILE["gateway"]["host"]
DEFAULT_ACCOUNTS = tuple(_PROFILE["household"]["accounts"])
DEFAULT_ZONE_ID = _PROFILE["dns"]["zone_id"]           # spec #23's ddns zone
HOST = re.compile(r"(?=.{4,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]")
ACCOUNT = re.compile(r"[a-z][a-z0-9-]{0,31}")     # both the registry's and the operator's rules
TOPIC = re.compile(r"[A-Za-z0-9_-]{24,64}")
ZONE = re.compile(r"[0-9a-f]{32}")
TIMEZONE = re.compile(r"[A-Za-z]+(/[A-Za-z0-9_+-]+){0,2}|UTC")
DISPLAY_NAME = re.compile(r"[^\x00-\x1f\x7f]{1,64}")
COMMIT = re.compile(r"[0-9a-f]{40}")

ANSWER_KEYS = {
    "host": "public hostname", "ddns": '"on" or "off"', "zone_id": "Cloudflare zone ID",
    "token_file": "file holding the Cloudflare DNS token", "ntfy_topic_file": "file holding an ntfy topic",
    "ntfy_server": "ntfy server URL", "accounts": "first accounts (the first one is the admin)",
    "display_names": "display names by account", "household_lan": "household LAN range",
    "bind_address": "address HAProxy binds on 443", "admin_ssh_source": "the only address SSH is accepted from",
    "timezone": "IANA time zone", "data_disk": "data disk device", "data_disk_init": "initialise a blank data disk",
    "source": "release source (git-archive tar or git checkout)", "alerts_tag": "tag prefixed to alert titles",
    "restic_password_file": "file holding the escrowed backup password (restore)",
    "start_stack": "start the stack (false: restore drill)", "wait_first_device": "wait to approve the first device",
}
INLINE_SECRETS = ("token", "cloudflare_token", "dns_token", "ntfy_topic", "topic", "restic_password", "password",
                  "pairing_code", "code")


class SetupError(Exception):
    """A refusal or failure with its plain-language fix."""

    def __init__(self, message, fix=None):
        super().__init__(message)
        self.fix = fix


def setup_command():
    """How to call this tool in a printed instruction: `anj-cloud-setup` once step 10 linked it,
    else the absolute path of the running copy (always runnable, from any directory)."""
    try:
        if COMMAND_LINK.is_symlink() and COMMAND_LINK.resolve().is_file():
            return COMMAND_LINK.name
    except OSError:
        pass
    return str(LAUNCHER)


def machine_id():
    return (System.text("/etc/machine-id") or "").strip() if Path("/etc/machine-id").exists() else ""


def utc_stamp(moment=None):
    return (moment or datetime.datetime.now(datetime.timezone.utc)).strftime("%Y%m%dT%H%M%SZ")


def sha256(data):
    return hashlib.sha256(data if isinstance(data, bytes) else data.encode()).hexdigest()


def version_tuple(text):
    match = re.match(r"(?:\d+:)?(\d+(?:\.\d+)*)", (text or "").strip().lstrip("v"))
    return tuple(int(part) for part in match.group(1).split(".")) if match else ()


# System access (tests substitute a fake) -------------------------------------------------------

class System:
    """Every command and file operation of the bootstrap. `dry` turns changes into plan lines."""

    def __init__(self, *, dry=False, out=sys.stdout):
        self.dry = dry
        self.out = out
        self.commands = []          # (argv, user) of changes made: the evidence (never stdin)
        self.files = []             # (path, sha256 | "secret") written

    # Commands -----------------------------------------------------------------------------
    def user_argv(self, argv, user):
        if user is None or os.geteuid() != 0:
            return list(argv)
        entry = pwd.getpwnam(user)
        quiet = ["PYTHONDONTWRITEBYTECODE=1"] if self.dry else []
        return ["runuser", "-u", user, "--", "env", f"HOME={entry.pw_dir}", f"PM2_HOME={entry.pw_dir}/.pm2",
                "PATH=/usr/local/bin:/usr/bin:/bin", "LC_ALL=C.UTF-8", *quiet, *argv]

    def read(self, argv, *, user=None, timeout=120, data=None, cwd=None, umask=-1):
        """A read-only command: always runs (dry run too). Returns (code, stdout, stderr). In a dry
        run (and doctor) a Python child writes no bytecode cache either (review R3)."""
        environment = dict(os.environ, LC_ALL="C.UTF-8", **({"PYTHONDONTWRITEBYTECODE": "1"} if self.dry else {}))
        try:
            result = subprocess.run(self.user_argv(argv, user), input=data, capture_output=True, text=True,
                                    timeout=timeout, check=False, cwd=cwd, env=environment, umask=umask)
        except FileNotFoundError:
            return 127, "", f"{argv[0]}: not found"
        except subprocess.TimeoutExpired:
            return 124, "", f"{argv[0]}: timed out"
        return result.returncode, result.stdout, result.stderr

    def change(self, argv, *, user=None, timeout=1800, data=None, cwd=None, show_errors=False, check=True, umask=-1):
        """A changing command: skipped in a dry run. stdin (`data`) is never recorded."""
        self.commands.append({"argv": [str(a) for a in argv], **({"user": user} if user else {})})
        if self.dry:
            return 0, "", ""
        options = {"umask": umask} if umask != -1 else {}
        code, out, err = self.read(argv, user=user, timeout=timeout, data=data, cwd=cwd, **options)
        if check and code:
            detail = (" " + err.strip().splitlines()[-1][:300]) if show_errors and err.strip() else ""
            raise SetupError(f"`{argv[0]} {argv[1] if len(argv) > 1 else ''}` failed (exit {code}).{detail}",
                             "Fix the cause above, then run setup again; every finished step is kept.")
        return code, out, err

    def attended(self, argv, *, user=None, timeout=3600):
        """A changing command that talks to the person at the terminal: stdin is inherited (it
        reads /dev/tty), stdout and stderr are captured. Skipped in a dry run; never given a secret."""
        self.commands.append({"argv": [str(a) for a in argv], **({"user": user} if user else {})})
        if self.dry:
            return 0, "", ""
        environment = dict(os.environ, LC_ALL="C.UTF-8")
        try:
            result = subprocess.run(self.user_argv(argv, user), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                    text=True, timeout=timeout, check=False, env=environment, cwd="/")
        except FileNotFoundError:
            return 127, "", f"{argv[0]}: not found"
        except subprocess.TimeoutExpired:
            return 124, "", f"{argv[0]}: timed out"
        return result.returncode, result.stdout, result.stderr

    def detached(self, argv, *, user=None, cwd=None, timeout=3600, grace=1800, logs=None):
        """A changing command in its own session with no terminal (decision #122 review H1): Ctrl-C
        at this terminal or a dropped ssh never reaches it, so it finishes or falls back by
        itself. stdout and stderr go to `logs` (two files, 0600, in a root 0700 directory) and are
        returned. On timeout every process of its session gets SIGTERM (prod.py's handler falls
        back), SIGKILL after `grace` seconds; the code is then 124 (review M1). Skipped in a dry run."""
        self.commands.append({"argv": [str(a) for a in argv], **({"user": user} if user else {})})
        if self.dry:
            return 0, "", ""
        out_path, err_path = (Path(path) for path in logs)
        out_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        streams = [os.fdopen(os.open(path, os.O_RDWR | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600), "w+b")
                   for path in (out_path, err_path)]
        identity, environment = self.identity(user)
        try:
            # No runuser: it stays as a watching parent that SIGKILLs its child 2 s after forwarding
            # a SIGTERM (util-linux su-common.c), which would cut prod.py's fallback short (delta
            # review D1). The command itself is the session leader, under anj's uid, gid and groups.
            child = subprocess.Popen([str(a) for a in argv], stdin=subprocess.DEVNULL, stdout=streams[0],
                                     stderr=streams[1], cwd=cwd, env=environment, start_new_session=True,
                                     **identity)
            try:
                code = child.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                signal_session(child.pid, signal.SIGTERM)
                try:
                    child.wait(timeout=grace)
                except subprocess.TimeoutExpired:
                    signal_session(child.pid, signal.SIGKILL)
                    child.wait()
                code = 124
            texts = []
            for stream in streams:
                stream.seek(0)
                texts.append(stream.read().decode("utf-8", "replace"))
        finally:
            for stream in streams:
                stream.close()
        return code, texts[0], texts[1]

    @staticmethod
    def identity(user):
        """Popen arguments that run a command as `user` (from root) without an intermediate
        process, and the environment runuser's `env` would give it (user_argv)."""
        environment = dict(os.environ, LC_ALL="C.UTF-8")
        if user is None or os.geteuid() != 0:
            return {}, environment
        entry = pwd.getpwnam(user)
        environment = {"HOME": entry.pw_dir, "PM2_HOME": f"{entry.pw_dir}/.pm2", "PATH": "/usr/local/bin:/usr/bin:/bin",
                       "LC_ALL": "C.UTF-8", "USER": user, "LOGNAME": user}
        return {"user": entry.pw_uid, "group": entry.pw_gid,
                "extra_groups": os.getgrouplist(user, entry.pw_gid), "umask": 0o022}, environment

    # Files --------------------------------------------------------------------------------
    def write(self, path, data, *, mode=0o644, owner=None, secret=False):
        """Atomic write (temp file, fsync, rename), chowned to `owner` (a user name)."""
        path = Path(path)
        data = data.encode() if isinstance(data, str) else data
        self.files.append({"path": str(path), "sha256": "secret" if secret else sha256(data)})
        if self.dry:
            return
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_name("." + path.name + ".anj-tmp")
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, mode)
        try:
            os.fchmod(fd, mode)
            if owner:
                entry = pwd.getpwnam(owner)
                os.fchown(fd, entry.pw_uid, entry.pw_gid)
            os.write(fd, data)
            os.fsync(fd)
        finally:
            os.close(fd)
        os.replace(temporary, path)

    def remove(self, path):
        """Remove a file if present (a consumed or replaced secret file)."""
        self.files.append({"path": str(path), "removed": True})
        if not self.dry:
            Path(path).unlink(missing_ok=True)

    def mkdir(self, path, *, mode, owner=None, group=None):
        path = Path(path)
        self.files.append({"path": str(path) + "/", "mode": oct(mode)})
        if self.dry:
            return
        path.mkdir(parents=True, exist_ok=True)
        os.chmod(path, mode)
        uid = pwd.getpwnam(owner).pw_uid if owner else -1
        gid = grp.getgrnam(group).gr_gid if group else (pwd.getpwnam(owner).pw_gid if owner else -1)
        os.chown(path, uid, gid)

    def symlink(self, target, link):
        self.files.append({"path": str(link), "symlink": str(target)})
        if self.dry:
            return
        temporary = Path(link).with_name("." + Path(link).name + ".anj-tmp")
        temporary.unlink(missing_ok=True)
        temporary.symlink_to(target)
        os.replace(temporary, link)

    @staticmethod
    def text(path):
        try:
            return Path(path).read_text()
        except (OSError, UnicodeDecodeError):
            return None


def signal_session(session, number, proc=Path("/proc")):
    """Send `number` to every process of session `session` (its leader's pid): runuser's child and
    prod.py are in it even when they are in another process group."""
    pids = {session}
    for entry in proc.iterdir():
        if entry.name.isdigit():
            try:
                fields = (entry / "stat").read_text().rsplit(")", 1)[1].split()
            except (OSError, IndexError):
                continue
            if len(fields) > 3 and fields[3] == str(session):
                pids.add(int(entry.name))
    for pid in sorted(pids):
        try:
            os.kill(pid, number)
        except (ProcessLookupError, PermissionError):
            pass


# Facts: read-only observations of the machine ----------------------------------------------

class Facts:
    def __init__(self, system):
        self.system = system
        self._cache = {}

    def cached(self, key, compute):
        if key not in self._cache:
            self._cache[key] = compute()
        return self._cache[key]

    def os_release(self):
        values = {}
        for line in (System.text("/etc/os-release") or "").splitlines():
            if "=" in line:
                key, value = line.split("=", 1)
                values[key] = value.strip().strip('"')
        return values

    def architecture(self):
        code, out, _ = self.system.read(["dpkg", "--print-architecture"])
        return out.strip() if code == 0 else platform.machine()

    def memory_kib(self):
        for line in (System.text("/proc/meminfo") or "").splitlines():
            if line.startswith("MemTotal:"):
                return int(line.split()[1])
        return 0

    def cpus(self):
        return os.cpu_count() or 0

    def free_bytes(self, path="/"):
        return shutil.disk_usage(path).free

    def default_route(self):
        """(source address, gateway) of the default IPv4 route, or (None, None)."""
        def compute():
            code, out, _ = self.system.read(["ip", "-j", "-4", "route", "show", "default"])
            gateway = None
            try:
                rows = json.loads(out) if code == 0 else []
                gateway = rows[0].get("gateway") if rows else None
            except ValueError:
                pass
            code, out, _ = self.system.read(["ip", "-j", "-4", "route", "get", "1.1.1.1"])
            source = None
            try:
                rows = json.loads(out) if code == 0 else []
                source = rows[0].get("prefsrc") if rows else None
            except ValueError:
                pass
            return source, gateway
        return self.cached("route", compute)

    def ssh_client(self):
        """Where this SSH session comes from (the lockout guard, M4), or None on a console."""
        return guide.ssh_client_address()

    def ssh_client_live(self):
        """Whether that address belongs to an open sshd connection (False: possibly stale, tmux)."""
        return guide.ssh_client_info()[1]

    def timezone(self):
        code, out, _ = self.system.read(["timedatectl", "show", "-p", "Timezone", "--value"])
        if code == 0 and out.strip():
            return out.strip()
        return (System.text("/etc/timezone") or "UTC").strip() or "UTC"

    def time_synchronized(self):
        code, out, _ = self.system.read(["timedatectl", "show", "-p", "NTPSynchronized", "--value"])
        return code == 0 and out.strip() == "yes"

    def user(self, name=paths.VM_USER):
        try:
            return pwd.getpwnam(name)
        except KeyError:
            return None

    def block_devices(self):
        def compute():
            code, out, _ = self.system.read(["lsblk", "-J", "-b", "-o",
                                             "NAME,PATH,TYPE,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINTS,RO,RM,PKNAME,MODEL"])
            try:
                return json.loads(out).get("blockdevices", []) if code == 0 else []
            except ValueError:
                return []
        return self.cached("lsblk", compute)

    def disks(self):
        """[{path, size, in_use, children, fstype, label, uuid}] of whole disks (no cdrom/seed)."""
        result = []
        for device in self.block_devices():
            if device.get("type") != "disk" or device.get("ro") in (True, "1") or device.get("rm") in (True, "1"):
                continue
            tree = [device] + flatten(device.get("children") or [])
            mounts = [m for node in tree for m in (node.get("mountpoints") or []) if m]
            result.append({"path": device.get("path") or "/dev/" + device["name"], "size": int(device.get("size") or 0),
                           "mounts": mounts, "children": len(device.get("children") or []),
                           "fstype": device.get("fstype"), "label": device.get("label"), "uuid": device.get("uuid"),
                           "model": (device.get("model") or "").strip()})
        return result

    def signatures(self, device):
        """Any signature the low-level probe or wipefs sees, plus non-zero first/last MiB."""
        found = []
        # blkid -p: 0 found, 2 nothing found; any other exit (8 ambivalent, errors) fails closed.
        code, out, _ = self.system.read(["blkid", "-p", "-o", "export", device])
        if code == 0 and out.strip():
            values = dict(line.split("=", 1) for line in out.splitlines() if "=" in line)
            found.append(values.get("TYPE") or values.get("PTTYPE") or "signature")
        elif code != 2:
            found.append(f"a blkid probe error (exit {code})")
        code, out, _ = self.system.read(["wipefs", "--no-act", "--json", device])
        if code != 0:
            found.append(f"a wipefs probe error (exit {code})")
        else:
            try:
                rows = json.loads(out).get("signatures", []) if out.strip() else []
            except ValueError:
                rows, found = [], found + ["unparseable wipefs output"]
            found += [row.get("type", "signature") for row in rows]
        if not found:
            edges = self.zero_edges(device)
            if edges is None:
                found.append("unreadable data (run as root)")
            elif not edges:
                found.append("non-zero data")
        return sorted(set(found))

    @staticmethod
    def zero_edges(device, span=1 << 20):
        try:
            with open(device, "rb") as stream:
                head = stream.read(span)
                stream.seek(0, os.SEEK_END)
                size = stream.tell()
                stream.seek(max(0, size - span))
                tail = stream.read(span)
        except OSError:
            return None
        return not head.strip(b"\0") and not tail.strip(b"\0")

    def mount_source(self, target):
        code, out, _ = self.system.read(["findmnt", "-J", "-n", "-o", "SOURCE,FSTYPE,LABEL,UUID", "--mountpoint", str(target)])
        try:
            rows = json.loads(out).get("filesystems", []) if code == 0 else []
        except ValueError:
            rows = []
        return rows[0] if rows else None

    def listeners_443(self):
        code, out, _ = self.system.read(["ss", "-Hltnp", "sport = :443"])
        rows = []
        for line in out.splitlines() if code == 0 else []:
            match = re.search(r'users:\(\("([^"]+)"', line)
            rows.append(match.group(1) if match else "an unknown process")
        return rows

    def docker_published(self):
        code, out, _ = self.system.read(["docker", "ps", "--format", "{{.Names}}\t{{.Ports}}"])
        if code != 0:
            return []
        return [line.split("\t")[0] for line in out.splitlines()
                if "\t" in line and "->" in line.split("\t", 1)[1] and not line.startswith(paths.PROJECT + "-")]

    def our_haproxy_running(self):
        code, out, _ = self.system.read(["docker", "inspect", "--format", "{{.State.Running}}",
                                         f"{paths.PROJECT}-haproxy-1"])
        return code == 0 and out.strip() == "true"

    def installed(self, package):
        code, out, _ = self.system.read(["dpkg-query", "-W", "-f", "${Status}\t${Version}", package])
        if code == 0 and out.startswith("install ok installed"):
            return out.split("\t", 1)[1].strip()
        return None

    def candidate(self, package):
        code, out, _ = self.system.read(["apt-cache", "policy", package])
        match = re.search(r"Candidate:\s*(\S+)", out) if code == 0 else None
        return None if not match or match.group(1) == "(none)" else match.group(1)


def flatten(nodes):
    result = []
    for node in nodes:
        result.append(node)
        result += flatten(node.get("children") or [])
    return result


# Answers -----------------------------------------------------------------------------------

def load_answers(path):
    try:
        with open(path, "rb") as stream:
            data = tomllib.load(stream)
    except FileNotFoundError:
        raise SetupError(f"The answers file {path} does not exist.", "Pass the path of an existing TOML file.") from None
    except (OSError, tomllib.TOMLDecodeError) as error:
        raise SetupError(f"The answers file cannot be read ({type(error).__name__}).",
                         "Check it is valid TOML (key = \"value\" lines).") from None
    for key in data:
        if key in INLINE_SECRETS:
            raise SetupError(f"The answers file holds a secret inline ({key}).",
                             "Secrets are given only by file path: token_file, ntfy_topic_file, restic_password_file.")
        if key not in ANSWER_KEYS:
            raise SetupError(f"Unknown answers key: {key}.", "Known keys: " + ", ".join(sorted(ANSWER_KEYS)) + ".")
    return data


def validate_answers(answers):
    """Raises SetupError naming the key; returns the answers normalised."""
    def fail(key, problem):
        raise SetupError(f"Answer {key}: {problem}.", f"Fix {key} ({ANSWER_KEYS[key]}) and run setup again.")

    if "host" in answers and not HOST.fullmatch(str(answers["host"])):
        fail("host", "must be a lowercase DNS name such as gateway.example.com")
    if answers.get("ddns", "off") not in ("on", "off"):
        fail("ddns", 'must be "on" or "off"')
    if "zone_id" in answers and not ZONE.fullmatch(str(answers["zone_id"])):
        fail("zone_id", "must be the 32 hex characters of the Cloudflare zone ID")
    accounts = answers.get("accounts")
    if accounts is not None:
        if not isinstance(accounts, list) or not accounts or len(set(accounts)) != len(accounts):
            fail("accounts", "must be a non-empty list of distinct account names")
        for uid in accounts:
            if not isinstance(uid, str) or not ACCOUNT.fullmatch(uid):
                fail("accounts", f"{uid!r} is not 1-32 lowercase letters, digits or '-' starting with a letter")
    names = answers.get("display_names", {})
    if not isinstance(names, dict) or any(not isinstance(v, str) or not DISPLAY_NAME.fullmatch(v) for v in names.values()):
        fail("display_names", "must map accounts to 1-64 printable characters")
    for key in ("bind_address", "admin_ssh_source"):
        if key in answers:
            try:
                address = ipaddress.IPv4Address(str(answers[key]))
            except ValueError:
                fail(key, "must be one IPv4 address")
            if address.is_unspecified or address.is_loopback:
                fail(key, "must be a real address of this network")
    if "household_lan" in answers:
        try:
            network = ipaddress.ip_network(str(answers["household_lan"]), strict=True)
        except ValueError:
            fail("household_lan", "must be a network such as 192.168.0.0/24")
        if network.version != 4 or not network.is_private:
            fail("household_lan", "must be a private IPv4 network")
    if "timezone" in answers and not TIMEZONE.fullmatch(str(answers["timezone"])):
        fail("timezone", "must be an IANA name such as Europe/Paris")
    for key in ("data_disk_init", "start_stack", "wait_first_device"):
        if key in answers and not isinstance(answers[key], bool):
            fail(key, "must be true or false")
    for key in ("token_file", "ntfy_topic_file", "restic_password_file", "source", "data_disk"):
        if key in answers and not str(answers[key]).startswith("/"):
            fail(key, "must be an absolute path")
    if "ntfy_server" in answers:
        server = str(answers["ntfy_server"])
        if not (server.startswith("https://") or re.match(r"http://(127\.0\.0\.1|localhost)(:\d+)?/?$", server)):
            fail("ntfy_server", "must be https (http only for a loopback test server)")
    if "alerts_tag" in answers and not re.fullmatch(r"[A-Za-z0-9 _-]{1,24}", str(answers["alerts_tag"])):
        fail("alerts_tag", "must be 1-24 letters, digits, spaces, '_' or '-'")
    return answers


def read_secret_file(path, what):
    """A secret given by file path: a regular file, not group/world-writable; value stripped."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except OSError:
        raise SetupError(f"The {what} file cannot be opened.", f"Check the path given for the {what}.") from None
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            raise SetupError(f"The {what} file is not a regular file.", f"Give the path of a file holding the {what}.")
        value = os.read(fd, 4096).decode("utf-8", "replace").strip()
    finally:
        os.close(fd)
    if not value or "\n" in value:
        raise SetupError(f"The {what} file must hold exactly one line.", f"Put only the {what} in that file.")
    return value


# Prompts -----------------------------------------------------------------------------------

class Prompter:
    """Interactive questions with defaults. `ask` and `secret` are injectable for tests."""

    def __init__(self, ask=input, secret=getpass.getpass, out=sys.stdout):
        self.ask_raw, self.secret_raw, self.out = ask, secret, out

    def say(self, text=""):
        print(text, file=self.out, flush=True)

    def ask(self, question, default, validate=None, explain=None):
        if explain:
            self.say(explain)
        while True:
            answer = self.ask_raw(f"{question} [{default}]: " if default not in (None, "") else f"{question}: ").strip()
            value = answer or default
            problem = validate(value) if validate else None
            if value not in (None, "") and not problem:
                return value
            self.say(problem or "An answer is needed here.")

    def yes(self, question, default=True):
        answer = self.ask_raw(f"{question} [{'Y/n' if default else 'y/N'}]: ").strip().lower()
        return default if not answer else answer in ("y", "yes")

    def hidden(self, question, validate=None, *, twice=False):
        """Hidden input; only its length is echoed back (M8). With `twice`, it is typed again and
        both entries must match (a typo in a hidden field is otherwise invisible)."""
        while True:
            value = self.secret_raw(question + " (input hidden): ").strip()
            problem = validate(value) if validate else (None if value else "An answer is needed here.")
            if problem:
                self.say(problem)
                continue
            self.say(f"  received {len(value)} characters.")
            if twice and self.secret_raw("Type it again (input hidden): ").strip() != value:
                self.say("The two entries differ; try again.")
                continue
            return value

    def choose(self, question, options, default):
        """Numbered choice: options is [(key, label)]; returns the chosen key."""
        for index, (_key, label) in enumerate(options, 1):
            self.say(f"  {index}) {label}")
        numbers = {str(index): key for index, (key, _label) in enumerate(options, 1)}
        default_number = next(number for number, key in numbers.items() if key == default)
        while True:
            answer = self.ask_raw(f"{question} [{default_number}]: ").strip() or default_number
            if answer in numbers:
                return numbers[answer]
            self.say(f"Enter a number from 1 to {len(options)}.")


def check(pattern, message):
    return lambda value: None if pattern.fullmatch(str(value)) else message


def check_ip(value):
    try:
        ipaddress.IPv4Address(value)
    except ValueError:
        return "Enter one IPv4 address, such as 10.77.10.10."
    return None


def check_lan(value):
    try:
        network = ipaddress.ip_network(value, strict=True)
    except ValueError:
        return "Enter a network such as 192.168.0.0/24."
    return None if network.version == 4 and network.is_private else "Enter a private IPv4 network."


def check_accounts(value):
    names = [part.strip() for part in str(value).replace(",", " ").split()]
    if not names or len(set(names)) != len(names) or any(not ACCOUNT.fullmatch(n) for n in names):
        return "Enter distinct account names (lowercase letters, digits, '-'), separated by commas."
    return None


# Disk classification (the no-format rule) ---------------------------------------------------

def classify_disk(facts, device):
    """('blank'|'anj-data'|'foreign', detail). Blank = no signature at all and zero edges."""
    disk = next((d for d in facts.disks() if d["path"] == device), None)
    if disk is None:
        return "missing", "not a whole disk on this machine"
    if disk["mounts"]:
        return "in-use", "mounted at " + ", ".join(disk["mounts"])
    if disk["fstype"] == "ext4" and disk["label"] == paths.DATA_LABEL and not disk["children"]:
        return "anj-data", f"ext4 labelled {paths.DATA_LABEL}"
    found = facts.signatures(device)
    if found or disk["children"]:
        return "foreign", "holds " + ", ".join(found or ["partitions"])
    return "blank", "no signature"


def unused_disks(facts):
    return [disk for disk in facts.disks() if not disk["mounts"]]


# Preflight ---------------------------------------------------------------------------------

def preflight(facts, answers, *, mode, root=True, reachable=None, existing_install=False):
    """[(check, problem, fix)] of every failed check; nothing is changed."""
    failures = []

    def fail(name, problem, fix):
        failures.append((name, problem, fix))

    release = facts.os_release()
    if release.get("ID") != "debian" or release.get("VERSION_CODENAME") != "trixie":
        fail("os", f"This is {release.get('PRETTY_NAME') or 'not Debian 13'}; anj-cloud-setup needs Debian 13 (trixie).",
             "Install Debian 13 (the genericcloud image on the VM host) and run setup there.")
    if facts.architecture() not in ("amd64", "x86_64"):
        fail("architecture", f"This machine is {facts.architecture()}; only amd64 is qualified.",
             "Use an amd64 (x86-64) machine.")
    if facts.memory_kib() < 3.5 * 1024 * 1024:
        fail("memory", f"This machine has {facts.memory_kib() / 1048576:.1f} GiB of RAM; at least 3.5 GiB is needed.",
             "Give the machine (or VM) 4 GiB of RAM.")
    if facts.cpus() < 2:
        fail("cpus", f"This machine has {facts.cpus()} CPU; at least 2 are needed.", "Give the machine 2 or more CPUs.")
    if facts.free_bytes("/") < 8 * 1024 ** 3:
        fail("os-disk", f"The OS disk has {facts.free_bytes('/') / 1024 ** 3:.1f} GiB free; at least 8 GiB is needed.",
             "Free space on / (for example `sudo apt-get clean`) or enlarge the OS disk.")
    if facts.user() is None:
        fail("admin-user", f"There is no user {paths.VM_USER}; production runs as that user.",
             f"Create it: `sudo adduser --disabled-password {paths.VM_USER}`, then run setup again.")
    if not root:
        fail("root", "Setup changes the system and must run as root.", f"Run it with sudo: `sudo {setup_command()}`.")
    failures += disk_preflight(facts, answers, mode=mode, existing_install=existing_install)
    try:
        socket.getaddrinfo("deb.debian.org", 443)
    except OSError:
        fail("dns", "Names cannot be resolved (deb.debian.org).",
             "Check /etc/resolv.conf and the network (`resolvectl status`), then run setup again.")
    else:
        reachable = reachable or https_reachable
        targets = ["deb.debian.org", "registry-1.docker.io", "registry.npmjs.org", "ntfy.sh"]
        if answers.get("ddns") == "on":
            targets.append("api.cloudflare.com")
        for target in targets:
            if not reachable(target):
                fail("https", f"No HTTPS connection to {target}.",
                     "Allow outbound HTTPS (TCP 443) from this machine to the internet, then run setup again.")
    listeners = [name for name in facts.listeners_443() if not (name == "haproxy" and facts.our_haproxy_running())]
    if listeners:
        name = listeners[0]
        fail("port-443", f"Port 443 is used by {name}.",
             f"Stop it with `sudo systemctl disable --now {name}`, then run setup again.")
    if not facts.time_synchronized():
        fail("time", "The clock is not synchronized.",
             "Wait a minute for time sync (`timedatectl`), or enable it with `sudo timedatectl set-ntp true`.")
    published = facts.docker_published()
    if published:
        fail("docker-ports", f"Another Docker container publishes a port ({published[0]}).",
             f"Stop it (`sudo docker stop {published[0]}`) or use a machine of its own for anj-cloud.")
    return failures


def formatted_here():
    """The UUID of the data disk this machine's setup formatted (FORMATTED_MARKER), or None."""
    return (System.text(FORMATTED_MARKER) or "").strip() or None


def disk_preflight(facts, answers, *, mode, existing_install):
    mounted = facts.mount_source(paths.DATA_ROOT)
    ours = formatted_here()
    if mounted:
        if mounted.get("label") != paths.DATA_LABEL:
            return [("data-disk", f"{paths.DATA_ROOT} is mounted from a disk not labelled {paths.DATA_LABEL}.",
                     f"Unmount it and let setup mount the anj-cloud data disk at {paths.DATA_ROOT}.")]
        if not existing_install and mode == "install" and not (ours and mounted.get("uuid") == ours):
            return [("data-disk", "The data disk already holds an anj-cloud state that this install did not create.",
                     f"Run `sudo {setup_command()} --adopt-data` to keep it (no new CA, secrets or accounts).")]
        return []
    device = answers.get("data_disk")
    if not device:
        unused = unused_disks(facts)
        if len(unused) != 1:
            found = ", ".join(d["path"] for d in unused) or "none"
            return [("data-disk", f"Setup needs exactly one spare data disk; unused disks found: {found}.",
                     "Attach one empty disk (200 GiB on the VM host), or name it with data_disk = \"/dev/vdb\".")]
        device = unused[0]["path"]
    kind, detail = classify_disk(facts, device)
    if kind in ("missing", "in-use"):
        return [("data-disk", f"The data disk {device} is {detail}.", "Name a spare disk with data_disk = \"/dev/…\".")]
    if kind == "foreign":
        return [("data-disk", f"The data disk {device} {detail}; setup never formats a disk that has any signature.",
                 "Choose another disk. Only if you are sure its contents are not needed, wipe it yourself "
                 f"(`sudo wipefs -a {device}`) and run setup again.")]
    disk = next((d for d in facts.disks() if d["path"] == device), {})
    if kind == "anj-data" and mode == "install" and ours and disk.get("uuid") == ours:
        return []   # formatted by this machine's interrupted install: continue it
    if kind == "anj-data" and mode != "adopt":
        return [("data-disk", f"The data disk {device} already holds anj-cloud data.",
                 f"Run `sudo {setup_command()} --adopt-data` to rebuild onto it.")]
    if kind == "blank" and mode == "adopt":
        return [("data-disk", f"--adopt-data needs the existing anj-cloud data disk, but {device} is blank.",
                 "Attach the old data disk, or run setup without --adopt-data (or with --restore-from).")]
    return []


def https_reachable(host, timeout=10):
    try:
        request = urllib.request.Request(f"https://{host}/", method="HEAD", headers={"User-Agent": "anj-cloud-setup"})
        with urllib.request.urlopen(request, timeout=timeout):
            return True
    except urllib.error.HTTPError:
        return True    # any HTTP answer proves the path
    except (urllib.error.URLError, OSError, ValueError):
        return False


# Release source ----------------------------------------------------------------------------

def tar_commit(path):
    """The commit `git archive` records in the tar's pax global header."""
    try:
        with tarfile.open(path) as archive:
            comment = archive.pax_headers.get("comment", "")
    except (OSError, tarfile.TarError):
        raise SetupError("The release source is not a readable tar file.",
                         "Create it with `git archive --format=tar <commit> > source.tar`.") from None
    if not COMMIT.fullmatch(comment.strip()):
        raise SetupError("The release tar carries no commit id.", "Create it with `git archive --format=tar <commit>`.")
    return comment.strip()


def resolve_source(source):
    """(commit, tar path or None, checkout or None) for --source, else the staged source."""
    if source:
        path = Path(source)
        if path.is_dir():
            if not (path / ".git").exists():
                raise SetupError("The source directory is not a git checkout.",
                                 "Pass a git checkout or a tar made with `git archive`.")
            code = subprocess.run(["git", "-C", str(path), "rev-parse", "HEAD"], capture_output=True, text=True,
                                  check=False)
            if code.returncode or not COMMIT.fullmatch(code.stdout.strip()):
                raise SetupError("Cannot read the checkout's commit.", "Install git or pass a tar made with git archive.")
            return code.stdout.strip(), None, path
        return tar_commit(path), path, None
    if STAGE_TAR.is_file() and str(ROOT).startswith(str(STAGE_SRC)):
        return tar_commit(STAGE_TAR), STAGE_TAR, None
    raise SetupError("No release source.",
                     "Pass --source <tar made with git archive>, or stage one from the VM host with deploy/vm/stage.py.")


# Rendering ---------------------------------------------------------------------------------

def render_firewall(bind_address, admin_source):
    template = (SOURCE_DIR / "config" / "firewall.nft.tmpl").read_text()
    return template.replace("{{BIND_ADDRESS}}", str(ipaddress.IPv4Address(bind_address))).replace(
        "{{ADMIN_SOURCE}}", str(ipaddress.IPv4Address(admin_source)))


def render_template(text, home):
    values = {"@USER@": paths.VM_USER, "@SOURCE@": str(paths.RELEASE_CURRENT), "@DATA_ROOT@": str(paths.DATA_ROOT),
              "@PM2_LOGS@": str(Path(home) / ".pm2" / "logs"), "@GATEWAY_SOCKET_DIR@": str(paths.GATEWAY_SOCKET_DIR),
              "@GATEWAY_UID@": str(paths.GATEWAY_UID), "@GATEWAY_GID@": str(paths.GATEWAY_GID),
              "@HAPROXY_RUN_DIR@": str(paths.HAPROXY_RUN_DIR), "@VM_GROUP@": paths.VM_GROUP,
              "@CONSOLE_DIR@": str(paths.CONSOLE_DIR)}
    for key, value in values.items():
        text = text.replace(key, value)
    return text


OUR_UNITS = ("anj-cloud-boot-health.service", "anj-cloud-reboot-guard.service", "anj-cloud-reboot-guard.timer",
             "anj-cloud-image-check.service", "anj-cloud-image-check.timer")
ENABLED_UNITS = ("anj-cloud-boot-health.service", "anj-cloud-reboot-guard.timer", "anj-cloud-image-check.timer",
                 "anj-cloud-backup.timer", "anj-cloud-backup-stale.timer")
TIMERS = tuple(unit for unit in ENABLED_UNITS if unit.endswith(".timer"))


def rendered_units(home, backup_units):
    units = {name: render_template((SOURCE_DIR / "systemd" / name).read_text(), home) for name in OUR_UNITS}
    units.update(backup_units)
    return units


def rendered_dropins(home):
    result = {}
    base = SOURCE_DIR / "systemd" / "dropins"
    for directory in sorted(base.iterdir()):
        for item in sorted(directory.iterdir()):
            result[render_template(directory.name, home) + "/" + item.name] = render_template(item.read_text(), home)
    return result


def daemon_json():
    return json.dumps({"data-root": str(paths.DOCKER_ROOT), "log-driver": "journald", "userland-proxy": False,
                       "live-restore": False}, indent=2, sort_keys=True) + "\n"


def ops_apps(state_root, release_current, *, start_stack=True):
    """PM2 apps of spec #21 VM Operations (the `alerts` dispatcher always; the watchdog, the
    watchers and spec #27's console backend only with a running stack, decision #112 (1))."""
    ops = Path(release_current) / "deploy" / "vm" / "ops"
    common = {"interpreter": "/usr/bin/python3", "interpreter_args": "-I", "cwd": str(state_root), "autorestart": True,
              "exp_backoff_restart_delay": 1000, "merge_logs": True, "time": True,
              "env": {"PYTHONUNBUFFERED": "1", "PYTHONDONTWRITEBYTECODE": "1"}}
    apps = [dict(common, name="alerts", script=str(Path(state_root) / paths.BIN_DIR.name / paths.ALERT_COMMAND.name),
                 args=["--drain"])]
    if start_stack:
        apps += [dict(common, name="watchdog", script=str(ops / "watchdog")),
                 dict(common, name="watchers", script=str(ops / "watchers")),
                 # Its socket directory comes from the tmpfiles entry (step 9); the launcher refuses
                 # any other owner or mode. SIGINT (PM2's stop) closes and removes the socket.
                 dict(common, name=paths.CONSOLE_APP, script=str(ops / "console"))]
    return apps


def ecosystem_text(apps):
    return ("// Generated by deploy/vm/anj-cloud-setup (spec #21 VM Operations); do not edit.\n"
            "module.exports = " + json.dumps({"apps": apps}, indent=2, sort_keys=True) + ";\n")


def app_digest(app):
    return sha256(json.dumps(app, sort_keys=True))


# Registry helpers (run inside the gateway container as its own user) --------------------------

ADMIN_SCRIPT = r'''
import json, sqlite3, sys, time
uid = sys.stdin.readline().strip()
db = sqlite3.connect("/var/lib/anj/registry.sqlite", timeout=30)
columns = [row[1] for row in db.execute("PRAGMA table_info(accounts)")]
if "admin" not in columns:
    print(json.dumps({"table": False}))
    sys.exit(0)
granted = audited = False
if uid:
    with db:
        db.execute("BEGIN IMMEDIATE")
        if not db.execute("SELECT 1 FROM accounts WHERE admin=1").fetchone():
            db.execute("UPDATE accounts SET admin=1 WHERE uid=?", (uid,))
            granted = db.execute("SELECT changes()").fetchone()[0] == 1
            # Decision #112 (3): the direct write records one audit entry in the same transaction,
            # as #43's first-admin import does (actor bootstrap; ids and result only).
            if granted and db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='admin_audit'").fetchone():
                db.execute("INSERT INTO admin_audit(time,actor_uid,action,target_uid,result) VALUES(?,?,?,?,?)",
                           (time.time(), "bootstrap", "role-grant", uid, "ok"))
                audited = True
admins = [row[0] for row in db.execute("SELECT uid FROM accounts WHERE admin=1 AND enabled=1 ORDER BY uid")]
print(json.dumps({"table": True, "admins": admins, "granted": granted, "audited": audited}))
'''
ACCESS_CONTAINER = f"{paths.PROJECT}-{paths.COMPOSE_SERVICE['gateway']}-1"
PAIR_POLL_SECONDS = 3
# Code-only pairing (decision #151, spec #35): a device that redeemed a pinned code is approved by
# the gateway at once (through the console backend). If it is still waiting after this long (the
# `console` app down), setup approves it itself, through the same operator path, without a person
# comparing anything: redeeming the valid code is the approval.
PINNED_APPROVAL_GRACE = 45


# The bootstrap -----------------------------------------------------------------------------

class Setup:
    def __init__(self, args, system=None, facts=None, prompter=None, out=sys.stdout):
        self.args = args
        self.out = out
        self.system = system or System(dry=args.dry_run, out=out)
        self.facts = facts or Facts(self.system)
        self.prompter = prompter or Prompter(out=out)
        self.mode = "restore" if args.restore_from else "adopt" if args.adopt_data else "install"
        self.answers = {}
        self.secrets = {}                  # in memory only: token, topic, restic password
        self.staged = {}                   # decision #109: secrets stage.py copied from the VM host (memory only)
        self.notes = []
        self.warnings = []                 # notes the summary puts first, marked ⚠
        self.steps = []
        self.started = datetime.datetime.now(datetime.timezone.utc)
        self.first_code = None             # shown on the terminal only (or the 0600 file)
        self.topic_new = False
        self.topic_source = None           # this run: "halo", "typed", "created" or "file"
        self.topic_test = None             # "received" or "not confirmed"
        self.cloudflare = None             # "ok" or "unchecked" after the read-only check
        self.backup_done = None            # backup.py's escrow result when backups were set up now
        self.topic_shown = False
        self.current = None                # (position, total, step) of the running step
        self.release = None
        self.release_tar = None
        self.checkout = None
        self.backup_units = {}
        self.read_only = False             # doctor and --dry-run: no command that changes or spawns anything
        self._ssh_source = False           # False: not looked up yet
        self.handoff = None                # what the VM host hand-off delivered (names, socket mode)

    # Output -------------------------------------------------------------------------------
    def say(self, text=""):
        print(text, file=self.out, flush=True)

    def warn(self, text):
        self.notes.append(text)
        self.warnings.append(text)

    def tty(self):
        """Secrets (a new topic, a pairing code) are shown only when output is a terminal."""
        return getattr(self.out, "isatty", lambda: False)()

    def attended_terminal(self):
        """A person at a terminal: output to it and answers from it (waiting, fingerprints)."""
        return self.tty() and sys.stdin.isatty()

    @property
    def user(self):
        return paths.VM_USER

    @property
    def home(self):
        entry = self.facts.user()
        return entry.pw_dir if entry else "/home/" + paths.VM_USER

    def as_anj(self, argv, **options):
        return self.system.read(argv, user=self.user, **options)

    def change_as_anj(self, argv, **options):
        return self.system.change(argv, user=self.user, **options)

    @property
    def record(self):
        return json.loads(System.text(SETUP_RECORD) or "{}")

    def save_record(self, **changes):
        record = dict(self.record, **changes)
        self.system.write(SETUP_RECORD, json.dumps(record, indent=2, sort_keys=True) + "\n", mode=0o600, owner=self.user)

    def installed_here(self):
        """This machine's own earlier install (the setup record names this machine)."""
        machine = machine_id()
        return bool(machine) and self.record.get("machine_id") == machine

    def ssh_source(self):
        """The address this SSH session comes from (M4's lockout guard), or None."""
        if self._ssh_source is False:
            self._ssh_source = self.facts.ssh_client()
        return self._ssh_source

    def on_halo(self):
        return self.facts.default_route()[1] == guide.HALO_GATEWAY

    # Secrets copied from the VM host (decision #109) -------------------------------------------------
    def load_staged(self):
        path = getattr(self.args, "secrets_socket", None)
        if not path:
            return
        if self.args.dry_run:
            discard_staged(path)
            self.notes.append("Dry run: the secrets copied from the VM host were not read (a dry run reads no secret).")
            return
        seen = {}
        try:
            anj = self.facts.user()
            self.staged = guide.read_staged(path, expected_owner=anj.pw_uid if anj else None, seen=seen)
        except (OSError, ValueError) as error:
            reason = str(error) if isinstance(error, ValueError) else f"the socket could not be read ({type(error).__name__})"
            raise SetupError(f"The secrets copied from the VM host could not be read: {reason}.",
                             "Run stage.py --with-secrets again, or run setup without it and type them.") from None
        names = [name for key, name in (("token", "Cloudflare DNS token"), ("topic", "ntfy alert topic"))
                 if key in self.staged]
        if names:
            self.notes.append("Copied from the VM host: the " + " and the ".join(names) + ".")
            self.handoff = {"read": names, "socket_mode": seen.get("mode")}      # evidence: no value

    # Answers --------------------------------------------------------------------------------
    def collect(self, interactive):
        given = load_answers(self.args.answers) if self.args.answers else {}
        for key, flag in (("host", self.args.host), ("ddns", self.args.ddns), ("source", self.args.source),
                          ("data_disk", self.args.data_disk)):
            if flag is not None:
                given[key] = flag
        validate_answers(given)
        stack = json.loads(System.text(paths.STACK_CONFIG) or "{}")
        source_ip, gateway = self.facts.default_route()
        defaults = {"host": stack.get("host") or DEFAULT_HOST, "ddns": "on" if interactive else "off",
                    "zone_id": DEFAULT_ZONE_ID, "accounts": list(DEFAULT_ACCOUNTS),
                    "household_lan": stack.get("household_lan") or paths.DEFAULT_HOUSEHOLD_LAN,
                    "bind_address": stack.get("bind_address") or source_ip or paths.DEFAULT_BIND_ADDRESS,
                    "admin_ssh_source": gateway or "10.77.10.1", "timezone": self.facts.timezone(),
                    "start_stack": True, "wait_first_device": False, "data_disk_init": False}
        # A re-run (or an adopted disk) defaults to the choices this install recorded.
        record = self.record if os.access(paths.STATE_ROOT, os.X_OK) else {}
        defaults.update({k: v for k, v in (record.get("answers") or {}).items() if k in ANSWER_KEYS})
        if record.get("accounts"):
            defaults["accounts"] = list(record["accounts"])
        answers = dict(defaults)
        answers.update(given)
        self.answers = answers
        if interactive:
            answers = self.prompt(answers, given, recorded_host=stack.get("host"))
        self.answers = validate_answers(answers)
        self.collect_secrets(interactive)

    def prompt(self, answers, given, recorded_host=None):
        """The guided questions, numbered [n/N], each with what it is for (audit C-05..C-17)."""
        p = self.prompter
        secrets_here = self.mode == "install" and not self.args.dry_run
        source = self.ssh_source()

        def needed():
            ddns = answers.get("ddns") == "on"
            return [name for name, wanted in (
                ("host", "host" not in given and not recorded_host), ("ddns", "ddns" not in given),
                ("zone", ddns and "zone_id" not in given),
                ("token", secrets_here and ddns and self.token_needed()),
                ("topic", secrets_here and self.topic_needed()),
                ("accounts", "accounts" not in given and self.mode == "install"),
                ("lan", "household_lan" not in given),
                ("network", "bind_address" not in given or "admin_ssh_source" not in given),
                ("timezone", "timezone" not in given)) if wanted]
        asked = []

        def section(name, title):
            asked.append(name)
            p.say(f"\n[{len(asked)}/{len(asked) + len([n for n in needed() if n not in asked])}] {title}")

        if recorded_host:
            p.say(f"\nPublic hostname: {recorded_host} (chosen at the first install; it cannot change).")
        elif "host" not in given:
            section("host", "Public hostname")
            answers["host"] = self.ask_host(answers["host"])
        if "ddns" not in given:
            section("ddns", "Keep the DNS record up to date (DDNS)")
            p.say(f"Your home internet address can change. With DDNS on, anj-cloud updates the Cloudflare record for\n"
                  f"{answers['host']} within 5 minutes of a change. Needs a Cloudflare API token (next questions).")
            answers["ddns"] = "on" if p.yes("Turn DDNS on?", answers["ddns"] == "on") else "off"
        if answers["ddns"] == "on" and "zone_id" not in given:
            section("zone", "Cloudflare zone ID")
            answers["zone_id"] = p.ask("Cloudflare zone ID", answers["zone_id"], check(ZONE, "Enter the 32 hex characters."),
                                       "Cloudflare dashboard → your domain → Overview → right-hand column \"API\" → "
                                       "Zone ID (32 characters).")
        self.answers = answers
        if "token" in needed():
            section("token", "Cloudflare API token")
            self.secrets["token"] = self.ask_token()
            self.check_cloudflare(interactive=True)
        if "topic" in needed():
            section("topic", "Alert topic for your phone (ntfy)")
            self.ask_topic()
        if "accounts" not in given and self.mode == "install":
            section("accounts", "Household accounts")
            answers["accounts"] = self.ask_accounts(answers["accounts"])
        if "household_lan" not in given:
            section("lan", "Home network")
            answers["household_lan"] = p.ask(
                "Home network", answers["household_lan"], check_lan,
                "Devices on your home network get higher connection limits (they sync many files at once).\n"
                "Enter your router's network range — most homes use 192.168.0.0/24 or 192.168.1.0/24.")
        if "bind_address" not in given or "admin_ssh_source" not in given:
            if self.on_halo():
                section("network", "Network (detected — correct on the VM host)")
                p.say(f"  Serve anj-cloud on    {answers['bind_address']} port 443")
                p.say(f"  Accept SSH only from  {answers['admin_ssh_source']}   (The VM host itself" +
                      (f", where you are connected from: {source})" if source else ")"))
                keep = p.yes("Keep these?", True)
            else:
                section("network", "Network")
                keep = False
            if not keep:
                if "bind_address" not in given:
                    answers["bind_address"] = p.ask("Address to serve on (port 443)", answers["bind_address"], check_ip,
                                                    "Detected from this machine's network; press Enter to keep it.")
                if "admin_ssh_source" not in given:
                    suggested = guide.ipv4_for(source) if source else None
                    if not self.on_halo():
                        answers["admin_ssh_source"] = suggested       # never the router: ask, or this session's
                    answers["admin_ssh_source"] = p.ask(
                        "Only address allowed to log in by SSH", answers["admin_ssh_source"], check_ip,
                        "Only ONE computer may log in to this server by SSH; every other address is refused. Enter the\n"
                        "address of the computer you manage it from" +
                        (f" (this session comes from {source}" + ("" if self.facts.ssh_client_live() else
                                                                  ", which may be stale inside tmux or screen") + ")"
                         if source else "") + ".\n"
                        "If that computer gets its address by DHCP, reserve it in your router, or SSH stops working\n"
                        "when the address changes.")
            answers["admin_ssh_source"] = self.lockout_guard(answers["admin_ssh_source"], source)
        if "timezone" not in given:
            section("timezone", "Time zone")
            answers["timezone"] = p.ask(
                "Time zone", answers["timezone"], check(TIMEZONE, "Enter a name like Europe/Paris."),
                "Nightly backup (03:30), security updates (04:12) and the automatic reboot window (04:15–05:00) use it.")
        return answers

    def ask_host(self, default):
        p = self.prompter
        p.say("Your devices always connect to this name, at home and away. It is built into the server's\n"
              "certificate, so it cannot be changed later without starting over on a new data disk.")
        while True:
            host = p.ask("Public hostname", default, check(HOST, "Enter a lowercase DNS name such as gateway.example.com."))
            if host == default:
                return host
            if p.ask_raw(f"You typed {host}. Type it again to confirm: ").strip() == host:
                return host
            p.say("The two entries differ; enter the hostname again.")

    def ask_accounts(self, default):
        p = self.prompter
        p.say("One name per person (lowercase letters, digits, '-'). The FIRST name is you: it becomes the\n"
              "household admin and pairs the first device. Add more people later in the app's Admin section.")
        while True:
            text = p.ask("Accounts", ", ".join(default), check_accounts)
            names = [part.strip() for part in text.replace(",", " ").split()]
            members = ", ".join(names[1:]) or "none"
            if p.yes(f"  Admin: {names[0]}     Members: {members}     Correct?", True):
                return names
            default = names

    def token_needed(self):
        return not paths.CLOUDFLARE_TOKEN.exists() and "token" not in self.secrets and not self.answers.get("token_file")

    def topic_needed(self):
        return not paths.NTFY_TOPIC.exists() and "topic" not in self.secrets and not self.answers.get("ntfy_topic_file")

    def ask_token(self):
        p = self.prompter
        if self.staged.get("token") and p.yes("Use the Cloudflare token copied from the VM host?", True):
            return self.staged["token"]
        p.say(guide.token_note(paths.CLOUDFLARE_TOKEN))
        return p.hidden("Cloudflare API token (paste)", lambda v: None if guide.TOKEN.fullmatch(v)
                        else "That does not look like a Cloudflare token (20-200 letters, digits, '-' or '_').", twice=True)

    def check_cloudflare(self, interactive):
        """M5: one read-only GET proves the token, the zone ID and the hostname before anything is
        installed. Interactive: retry or continue knowingly; with --answers a failure stops the run."""
        p = self.prompter
        while True:
            self.say("Checking with Cloudflare (read-only) …")
            ok, message = guide.cloudflare_check(self.secrets["token"], self.answers["zone_id"], self.answers["host"])
            self.say(f"  {message}" + (" ✓" if ok else ""))
            if ok:
                self.cloudflare = "ok"
                return
            if not interactive:
                raise SetupError(f"The Cloudflare check failed: {message}",
                                 "Fix token_file or zone_id in the answers file, then run setup again; nothing was changed.")
            untouched = not self.steps
            choice = p.choose("What now?", [("token", "Paste the token again"), ("zone", "Change the zone ID"),
                                            ("skip", "Continue anyway (DDNS alerts until this is fixed)"),
                                            ("stop", "Stop here (nothing has changed yet)" if untouched else
                                             "Stop here (the finished steps are kept)")], "token")
            if choice == "token":
                self.staged.pop("token", None)
                self.secrets["token"] = self.ask_token()
            elif choice == "zone":
                self.answers["zone_id"] = p.ask("Cloudflare zone ID", self.answers["zone_id"],
                                                check(ZONE, "Enter the 32 hex characters."))
            elif choice == "skip":
                self.cloudflare = "unchecked"
                self.warn("The Cloudflare check did not pass; DDNS alerts until the token or zone ID is fixed.")
                return
            else:
                raise SetupError("Stopped before any change." if untouched else "Stopped; the finished steps are kept.",
                                 "Run setup again when the token and zone ID are at hand.")

    def ask_topic(self):
        """M1: which topic, explicitly; reuse is the default on the VM host; typed entry twice; a test
        alert proves a reused topic reaches the phone before anything is installed."""
        p = self.prompter
        options = []
        if self.staged.get("topic"):
            options.append(("halo", "Use the topic copied from the VM host        (recommended on the VM host — the VM host already alerts on it)"))
        options += [("typed", "I already have a topic — type it"),
                    ("created", "Create a new topic                    (first anj-cloud server, nothing set up yet)")]
        default = "halo" if self.staged.get("topic") else "typed" if self.on_halo() else "created"
        while True:
            choice = p.choose("Choose", options, default)
            if choice == "halo":
                topic = self.staged["topic"]
            elif choice == "typed":
                p.say(guide.topic_entry_note(paths.NTFY_TOPIC, self.on_halo()))
                topic = p.hidden("Topic", lambda v: None if TOPIC.fullmatch(v) else
                                 "Use 24-64 letters, digits, '-' or '_'.", twice=True)
            else:
                topic = secrets.token_urlsafe(24)    # 32 characters (decision #98)
                p.say("A new private topic will be created. At the end of setup you subscribe your phone to it\n"
                      "(a QR code is shown) and a test alert checks it.")
            self.secrets["topic"], self.topic_source = topic, choice
            if choice == "created" or self.test_alert(topic, allow_change=True) != "change":
                return

    def test_alert(self, topic, allow_change=False):
        """C-12: one test message straight to ntfy (never through a log), confirmed by the user."""
        p = self.prompter
        server = self.answers.get("ntfy_server") or "https://ntfy.sh"
        name = server.split("://", 1)[1].rstrip("/")
        while True:
            sent, detail = guide.send_test_alert(server, topic)
            if sent:
                p.say('Sent a test alert: "anj-cloud setup: test alert — alerts work."')
                if p.yes("Did it arrive on your phone?", True):
                    self.topic_test = "received"
                    return "received"
                p.say(f"Check the ntfy app is subscribed to {guide.short(topic)} on {name}.")
                if self.on_halo():
                    p.say(f"On the VM host, this sends a test on the VM host's own topic: sudo {guide.HALO_ALERT} --key test "
                          "--title \"VM host: test\" -- \"The VM host alerts work\"")
            else:
                p.say(f"The test alert could not be sent: {detail}.")
            choices = "Press Enter to send another test" + (", type 'change' to choose the topic again," if allow_change
                                                            else ",") + " or type 'skip': "
            answer = p.ask_raw(choices).strip().lower()
            if answer == "skip":
                self.topic_test = "not confirmed"
                self.warn("The ntfy test alert was not confirmed; check the phone's subscription.")
                return "skipped"
            if answer == "change" and allow_change:
                return "change"

    def lockout_guard(self, admin, current):
        """M4: a wrong SSH source locks every later login out (the current session survives through
        `established`, so the mistake would be invisible). The firewall rule itself is unchanged."""
        if not current or (guide.ipv4_for(current) or current) == admin:     # ::ffff:a.b.c.d is a.b.c.d
            return admin
        p = self.prompter
        usable = guide.ipv4_for(current)
        stale = "" if self.facts.ssh_client_live() else \
            " (read from this terminal's SSH environment; inside tmux or screen it may be stale)"
        p.say(f"Stop: you are connected over SSH from {current}{stale}, but the firewall would accept SSH only from "
              f"{admin}.\nAfter setup you could not log in again by SSH, and this server may have no password login "
              "to fall back on.")
        if not usable:
            p.say("The firewall accepts one IPv4 address: to keep this computer, reconnect over IPv4 (ssh -4) and run "
                  "setup again.")
        while True:
            question = f"Type {admin} again to keep it anyway" + (f", or press Enter to use {usable}: " if usable else ": ")
            answer = p.ask_raw(question).strip()
            if answer == admin:
                self.warn(f"SSH is accepted only from {admin}, not from this session's {current} (confirmed).")
                return admin
            if not answer and usable:
                return usable

    def guard_answers(self):
        """M4 for --answers: refuse a source that would lock this very session out."""
        current, admin = self.ssh_source(), self.answers.get("admin_ssh_source")
        if current and admin and current != admin and guide.ipv4_for(current) != admin:
            usable = guide.ipv4_for(current)
            stale = "" if self.facts.ssh_client_live() else " (this address may be stale: tmux or screen)"
            raise SetupError(f"You are connected over SSH from {current}{stale}, but admin_ssh_source is {admin}: after "
                             "setup no SSH login could reach this machine again.",
                             f"Set admin_ssh_source = \"{usable}\", or run setup from {admin}." if usable else
                             "admin_ssh_source takes one IPv4 address: reconnect over IPv4 (ssh -4) and set "
                             "admin_ssh_source to that computer's IPv4 address, or run setup from " + admin + ".")

    def collect_secrets(self, interactive):
        """Secrets live in memory until their step writes them 0600; a dry run asks for none."""
        a = self.answers
        if self.args.dry_run:
            # A dry run reads no secret: it only notes which secret files are missing.
            for key in ("token_file", "ntfy_topic_file", "restic_password_file"):
                if a.get(key) and not os.path.exists(a[key]):
                    self.notes.append(f"{key} {a[key]} does not exist (a real run stops there).")
            return
        if self.mode == "restore":
            if a.get("restic_password_file"):
                self.secrets["restic_file"] = a["restic_password_file"]
            elif interactive:
                self.prompter.say("\nBackup password (restic) — the one saved as \"anj-cloud backup password\" when "
                                  "backups were set up.\nWithout it the backup cannot be read; it is used only for "
                                  "this restore and kept on this server where only the setup account can read it.")
                self.secrets["restic"] = self.prompter.hidden("Paste it")
            else:
                raise SetupError("Missing answer: restic_password_file (restore).",
                                 "Add restic_password_file = \"/path\" to the answers file.")
        if self.mode == "install":
            self.collect_state_secrets(interactive)
        # --adopt-data and --restore-from: the token and topic live on the data disk or in the
        # snapshot, visible only after step 3 or the restore; run() asks for what is still missing then.

    def collect_state_secrets(self, interactive):
        """The DNS token and the ntfy topic: only what the state root does not hold yet (the
        guided questions may already have collected them)."""
        a = self.answers
        where = "the data disk" if self.mode == "adopt" else "the restored snapshot" if self.mode == "restore" else None
        state_token = paths.CLOUDFLARE_TOKEN.exists()
        if not state_token and "token" not in self.secrets:
            token = None
            if a.get("token_file"):
                token = read_secret_file(a["token_file"], "Cloudflare token")
            elif self.staged.get("token") and not interactive:
                token = self.staged["token"]
            elif a["ddns"] == "on" and interactive and not self.args.dry_run:
                self.prompter.say("\nCloudflare API token")
                token = self.ask_token()
            elif a["ddns"] == "on" and not self.args.dry_run:
                raise SetupError("Missing answer: token_file (DDNS is on" + (f" and {where} holds no token" if where
                                                                              else "") + ").",
                                 "Add token_file = \"/path/to/token\" to the answers file, or set ddns = \"off\".")
            elif self.staged.get("token"):
                token = self.staged["token"]                      # kept for a later switch-on
            if token:
                self.secrets["token"] = token
                if a["ddns"] == "on" and not self.args.dry_run:
                    self.check_cloudflare(interactive)
        if not paths.NTFY_TOPIC.exists() and "topic" not in self.secrets:
            if a.get("ntfy_topic_file"):
                topic = read_secret_file(a["ntfy_topic_file"], "ntfy topic")
                if not TOPIC.fullmatch(topic):
                    raise SetupError("The ntfy topic must be 24-64 letters, digits, '-' or '_'.", "Fix the topic file.")
                self.secrets["topic"], self.topic_source = topic, "file"
            elif interactive and not self.args.dry_run:
                self.prompter.say("\nAlert topic for your phone (ntfy)")
                self.ask_topic()
            elif self.staged.get("topic"):
                self.secrets["topic"], self.topic_source = self.staged["topic"], "halo"
            else:
                self.secrets["topic"], self.topic_source = secrets.token_urlsafe(24), "created"   # 32 characters (#98)

    def sweep_first_code(self, now=None):
        """The first-code file never outlives its invitation (10 minutes, the gateway's clock is
        epoch seconds); the watchers app sweeps it too, and backups exclude it (spec #22)."""
        invite = self.record.get("first_invite") or {}
        expires = float(invite.get("expires") or 0)
        if paths.FIRST_PAIRING_CODE.exists() and expires and expires < (time.time() if now is None else now):
            self.system.remove(paths.FIRST_PAIRING_CODE)

    def install_dispatcher(self, source_root):
        """state/bin/anj-alert (+ paths.py beside it) and run/ops.json, from `source_root`. Both
        directories are machine-local (a restore never moves them), so the restore step installs
        the dispatcher before spec #22's init records it (no undeliverable alert command)."""
        anj = self.user
        self.system.mkdir(paths.BIN_DIR, mode=0o700, owner=anj)
        self.system.mkdir(paths.RUN_DIR, mode=0o700, owner=anj)
        self.system.write(paths.ALERT_COMMAND, (Path(source_root) / "deploy" / "vm" / "ops" / "anj-alert").read_bytes(),
                          mode=0o700, owner=anj)
        if not (paths.BIN_DIR / "paths.py").exists():   # prod.py's activate_release writes the release's copy
            self.system.write(paths.BIN_DIR / "paths.py", (Path(source_root) / "deploy" / "vm" / "paths.py").read_bytes(),
                              mode=0o600, owner=anj)
        self.system.write(OPS_CONFIG, ops_config_text(self.answers), mode=0o600, owner=anj)

    def refuse_host_change(self):
        stack = json.loads(System.text(paths.STACK_CONFIG) or "{}") if os.access(paths.STATE_ROOT, os.X_OK) else {}
        if stack.get("host") and stack["host"] != self.answers["host"]:
            raise SetupError(f"This server is set up for {stack['host']}; changing it to {self.answers['host']} needs a "
                             "new server certificate, so setup does not do it (prod.py refuses it too).",
                             f"Keep host = \"{stack['host']}\", or set up a new data disk for the new name.")

    def confirm_disk_init(self, interactive, device):
        if self.answers.get("data_disk_init"):
            return True
        if interactive and not self.args.dry_run:
            disk = next((d for d in self.facts.disks() if d["path"] == device), {})
            self.say("\nThe data disk holds all household files and the server's keys.")
            self.say(f"  {device}   {disk.get('size', 0) / 1024 ** 3:.0f} GiB   {disk.get('model') or 'unknown model'}"
                     "   no file system, no partitions")
            return self.prompter.yes(f"Format {device} as the anj-cloud data disk? This erases it.", False)
        if self.args.dry_run:
            return True
        raise SetupError(f"Missing answer: data_disk_init ({device} is blank and would be initialised).",
                         "Add data_disk_init = true to the answers file to allow it.")

    # Guided frame (M9) ------------------------------------------------------------------------
    def banner(self):
        p = self.prompter
        if self.mode == "install":
            token = " (copied from the VM host ✓)" if self.staged.get("token") else \
                ", unless it was copied from the VM host" if self.on_halo() else ""
            p.say("anj-cloud setup — about 15–25 minutes. Press Enter to accept a [default].\n\n"
                  "Before you start, have ready:\n"
                  "  1. Your password manager, open. Setup shows secrets you must save there.\n"
                  "  2. Your phone with the ntfy app installed (for server alerts).\n"
                  f"  3. The Cloudflare API token for your domain (DNS edit){token}.\n"
                  "  4. The anj-cloud app installed on the computer you will pair first.\n")
            copied = [name for key, name in (("token", "the Cloudflare DNS token"), ("topic", "the ntfy alert topic"))
                      if key in self.staged]
            if copied:
                p.say("Copied from the VM host into this setup's memory (kept on this server where only the setup account can read "
                      "them): "
                      + " and ".join(copied) + ".\n")
        else:
            what = "rebuild onto the existing data disk" if self.mode == "adopt" else "restore from the backup drive"
            ready = "\nHave ready: the backup password (restic) from your password manager.\n" if self.mode == "restore" else ""
            p.say(f"anj-cloud setup — {what}. Press Enter to accept a [default].\n{ready}")
        p.say("Setup checks this machine first and changes nothing until you confirm.")

    def early_preflight(self):
        """S4: the machine checks before any question, so a failure never discards typed answers."""
        self.say("Checking this machine …")
        failures = preflight(self.facts, {"ddns": "off", **({"data_disk": self.args.data_disk} if self.args.data_disk
                                                            else {})},
                             mode=self.mode, root=os.geteuid() == 0, existing_install=self.installed_here())
        if not failures:
            self.say("  ready ✓")
            return False
        self.say("Preflight found problems; nothing was changed:")
        for _name, problem, fix in failures:
            self.say(f"  - {problem}\n    Fix: {fix}")
        self.write_evidence("preflight-failed", failures=failures)
        return True

    def confirm_review(self, disk):
        """C-18: one look at every answer before about 15 minutes of work."""
        a = self.answers
        if a["ddns"] == "on":
            token = {"ok": "token ✓", "unchecked": "token NOT checked"}.get(self.cloudflare, "token kept")
            ddns = f"on (zone {guide.short(a['zone_id'])}, {token})"
        else:
            ddns = "off"
        alerts = {"halo": "ntfy topic from the VM host", "typed": "your ntfy topic", "created": "a new ntfy topic",
                  "file": "ntfy topic from the answers file"}.get(self.topic_source, "ntfy topic kept")
        if self.topic_test:
            alerts += " (test ✓)" if self.topic_test == "received" else " (test not confirmed)"
        device = disk.device()
        if disk.needs_init():
            size = next((d.get("size", 0) for d in self.facts.disks() if d["path"] == device), 0) / 1024 ** 3
            data = f"{device}  {size:.0f} GiB  (blank — will be formatted, asks below)"
        elif self.facts.mount_source(paths.DATA_ROOT):
            data = f"{device}  (already set up, kept)"
        else:
            data = f"{device or 'none found'}  (existing anj-cloud data, kept)" if self.mode != "install" else str(device)
        accounts = a.get("accounts") or []
        self.say("\nReady to install:" if self.mode == "install" else "\nReady to rebuild:")
        self.say(f"  Hostname      {a['host']}")
        self.say(f"  DDNS          {ddns}")
        if self.mode == "install":
            self.say(f"  Admin         {accounts[0]}        Members  {', '.join(accounts[1:]) or 'none'}")
        self.say(f"  Alerts        {alerts}")
        self.say(f"  Home network  {a['household_lan']}        Time zone  {a['timezone']}")
        self.say(f"  Network       serve on {a['bind_address']}:443, SSH only from {a['admin_ssh_source']}")
        self.say(f"  Data disk     {data}")
        return self.prompter.yes("Start installing?" if self.mode == "install" else "Start?", True)

    def stopped(self, what, fix, recorded):
        """C-21: where it stopped, in plain words, and the two commands that help."""
        position, total, step = self.current or (0, 0, None)
        evidence = self.write_evidence("failed", quiet=True, error=recorded)
        command = setup_command()
        where = f"at step {position} of {total} ({step.title.lower()})" if step else "before the first step"
        self.say(f"\nSetup stopped {where}. Nothing is lost: finished steps are kept.")
        self.say(f"What happened: {what}")
        if fix:
            self.say(f"Fix: {fix}")
        self.say("Next:")
        self.say(f"  1. sudo {command} doctor        lists what is wrong and how to fix each item")
        self.say(f"  2. sudo {command}               re-run; it continues where it stopped")
        if evidence:
            self.say(f"Details (no secrets): {evidence}")
        return 1

    # Steps ----------------------------------------------------------------------------------
    def step_list(self):
        steps = [Packages(self), Pm2(self), DataDisk(self), Docker(self), Firewall(self), Journald(self), Ssh(self)]
        if self.mode == "restore":
            steps.append(Restore(self))
        steps += [Release(self), Stack(self), Operations(self), Timers(self), Updates(self)]
        return steps

    def run(self):
        interactive = not self.args.answers and sys.stdin.isatty()
        if not self.args.answers and not interactive and not self.args.dry_run:
            discard_staged(getattr(self.args, "secrets_socket", None))
            raise SetupError("No terminal for the questions.",
                             "Run it in a terminal (ssh -t …; deploy/vm/stage.py prints the exact command), "
                             "or pass --answers <file>.")
        self.load_staged()
        if interactive and not self.args.dry_run:
            self.banner()
            if self.early_preflight():
                return 1
        self.collect(interactive)
        self.refuse_host_change()
        if not interactive and not self.args.dry_run:
            self.guard_answers()
        failures = preflight(self.facts, self.answers, mode=self.mode, root=os.geteuid() == 0 or self.args.dry_run,
                             existing_install=self.installed_here())
        if failures:
            self.say("Preflight found problems; nothing was changed:")
            for name, problem, fix in failures:
                self.say(f"  - {problem}\n    Fix: {fix}")
            if not self.args.dry_run:
                self.write_evidence("preflight-failed", failures=failures)
                return 1
        if self.args.dry_run:
            return self.dry_run(bool(failures))
        busy = ops_busy() if self.installed_here() else None
        if busy:
            # Review M3: a re-run restarts apps (prod.py up); never during a backup, restore or update.
            raise SetupError(f"Not now: {busy}. Nothing was changed.", "Run setup again when that has finished.")
        disk = DataDisk(self)
        if interactive and not self.confirm_review(disk):
            self.say("Nothing was changed. Run setup again when you are ready.")
            return 1
        if disk.needs_init():
            if not self.confirm_disk_init(interactive, disk.device()):
                raise SetupError("Nothing was changed.",
                                 "Run setup again when the right disk is attached (or name it: --data-disk /dev/…).")
        result = "complete"
        steps = self.step_list()
        self.say("")
        try:
            for position, step in enumerate(steps, 1):
                self.current = (position, len(steps), step)
                self.execute(step, position, len(steps))
                if (self.mode == "adopt" and isinstance(step, DataDisk)) or \
                        (self.mode == "restore" and isinstance(step, Restore)):
                    # The state root is visible only now: refuse a changed host before any later
                    # step keeps the recorded one silently (review R2), then collect the secrets.
                    self.refuse_host_change()
                    self.collect_state_secrets(interactive)
        except SetupError as error:
            return self.stopped(str(error), error.fix, str(error))
        except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
            # Unexpected: report the kind only (a message could carry a value), keep the evidence.
            return self.stopped(guide.plain_error(error), None, type(error).__name__)
        self.sweep_first_code()
        a = self.answers
        alerts = dict(self.record.get("alerts") or {})
        if self.topic_new:
            alerts = {"source": self.topic_source or "created", "test": self.topic_test}
        self.save_record(machine_id=machine_id(), release=self.release, completed_at=datetime.datetime.now(
            datetime.timezone.utc).isoformat(timespec="seconds"), timezone=a.get("timezone"),
            **({"accounts": a["accounts"]} if self.mode == "install" and not self.record.get("accounts") else {}),
            **({"alerts": alerts} if alerts else {}),
            answers={key: a[key] for key in ("host", "ddns", "zone_id", "household_lan", "bind_address",
                                             "admin_ssh_source", "timezone", "alerts_tag", "ntfy_server", "start_stack")
                     if key in a})
        self.write_evidence(result, quiet=True)
        # Secrets first (the backup screen is cleared after its confirmation), then the summary and
        # checklist, which stay on the screen for the pairing that comes last.
        self.alerts_phase(interactive)
        if interactive:
            self.offer_backup()
        self.summary(interactive)
        self.pairing_phase(interactive)
        evidence = self.write_evidence(result, quiet=interactive)
        if interactive:
            self.farewell(evidence)
        return 0

    def execute(self, step, position, total):
        """C-20: [n/N] with a plain name, a purpose and the usual duration; a heartbeat on long
        steps. The before/after detail goes to the evidence (and --dry-run)."""
        label = f"[{position:>2}/{total}] {step.title}"
        self.say(label + (f" ({step.purpose})" if step.purpose else "") + f" — usually {step.expect}")
        entry = {"step": step.number, "name": step.name}
        with guide.Heartbeat(self.say) as beat:
            done, current = step.state()
            entry["before"] = current
            if done:
                ok, detail = step.verify()
                if ok:
                    entry.update(result="already done", after=detail, passed=True)
                    self.steps.append(entry)
                    self.say(f"{label}: already done ({guide.duration(beat.elapsed())})")
                    return
            step.apply()
            ok, detail = step.verify()
        entry.update(result="changed", after=detail, passed=ok, seconds=round(beat.elapsed()))
        self.steps.append(entry)
        if not ok:
            raise SetupError(f"Step {step.number} ({step.name}) did not verify: {detail}", step.fix)
        self.say(f"{label}: done ✓ ({guide.duration(beat.elapsed())})")

    def dry_run(self, preflight_failed):
        self.say("Dry run: nothing is changed and no secret is asked.\n")
        for step in self.step_list():
            try:
                done, current = step.state()
                plan = [] if done else step.plan()
            except (SetupError, OSError, ValueError) as error:
                done, current, plan = False, f"unknown ({error})", []
            self.say(f"{step.number:>2} {step.name}")
            self.say(f"   now:  {current}")
            if done:
                self.say("   plan: already done")
            for line in plan:
                self.say(f"   will: {line}")
        self.say("13 Summary\n   will: print the summary and an ordered checklist; write state/setup-log/<UTC>.json")
        if self.mode == "install":
            self.say("14 Backups\n   will: offer `backup.py init --show-escrow` (the password is confirmed by its last "
                     "6 characters)")
            self.say(f"15 Pair the first device\n   will: offer a pairing code for {self.answers['accounts'][0]} "
                     "(issued only then, valid 10 minutes) and wait until the device has paired")
        for note in self.notes:
            self.say(f"Note: {note}")
        return 1 if preflight_failed else 0

    # After the steps: alerts, summary, backups, pairing --------------------------------------
    def alerts_phase(self, interactive):
        """C-11/C-23: a topic setup created is shown once with its QR code (the terminal only) and
        checked with a test alert; with no terminal its link goes to a 0600 file (#104 (6))."""
        record = self.record.get("alerts") or {}
        created = record.get("source") == "created" or (self.topic_new and self.topic_source in (None, "created"))
        if not created or not paths.NTFY_TOPIC.exists() and not self.secrets.get("topic"):
            return
        if record.get("test") == "received" and not self.topic_new:
            return
        topic = self.secrets.get("topic") or (System.text(paths.NTFY_TOPIC) or "").strip()
        if not topic:
            return
        self.secrets.setdefault("topic", topic)      # redacted from the evidence
        server = self.answers.get("ntfy_server") or "https://ntfy.sh"
        if not (interactive and self.tty()):
            if self.topic_new:
                link = f"{server.rstrip('/')}/{topic}"
                path = paths.SECRETS_DIR / "ntfy-subscribe-link"
                self.system.write(path, link + "\n", mode=0o600, owner=self.user, secret=True)
                self.notes.append(f"Alerts: the subscribe link is in {path} (0600; no terminal to show it).")
            return
        p = self.prompter
        p.say("\n" + "─" * 64 + "\nAlerts: subscribe your phone (ntfy)\n")
        p.say(f"Your alert topic:  {topic}")
        p.say(guide.topic_note(paths.NTFY_TOPIC))
        qr = guide.qr_text(guide.ntfy_link(server, topic))
        if qr:
            p.say("\nScan with your phone's camera to subscribe in the ntfy app:")
            self.out.write(qr)
            self.out.flush()
        p.say(f"Or in the ntfy app: + → Topic name: {topic} → Subscribe.")
        self.topic_shown = True
        if p.ask_raw("Press Enter once subscribed to send a test alert (or type skip): ").strip().lower() == "skip":
            self.topic_test = "not confirmed"
        else:
            self.test_alert(topic)
        self.save_record(alerts={"source": "created", "test": self.topic_test})

    def backup_state(self):
        record = json.loads(System.text(paths.BACKUP_RECORD) or "{}") if os.access(paths.STATE_ROOT, os.X_OK) else {}
        if (record.get("targets") or [{}])[0].get("repository_id"):
            return "set up"
        return "ready" if self.facts.mount_source(paths.BACKUP_MOUNT) else "no share"

    def first_account(self):
        accounts = self.record.get("accounts") or self.answers.get("accounts") or []
        invite = self.record.get("first_invite") or {}
        return invite.get("uid") or (accounts[0] if accounts else None)

    def issuer_fingerprint(self):
        """SHA-256 of the issuer certificate (DER), as `openssl x509 -fingerprint -sha256` prints it."""
        import base64
        text = System.text(paths.OPERATOR_DIR / "issuer.crt") or ""
        match = re.search(r"-----BEGIN CERTIFICATE-----(.*?)-----END CERTIFICATE-----", text, re.S)
        if not match:
            return None
        try:
            digest = hashlib.sha256(base64.b64decode("".join(match.group(1).split()))).hexdigest().upper()
        except ValueError:
            return None
        return ":".join(digest[i:i + 2] for i in range(0, 64, 2))

    def pairing_instructions(self):
        """C-30/C-31: what the client's pairing dialog asks for, field by field (decision #151:
        the server and the code; the code carries the CA's pin, so no CA file is copied)."""
        lines = ["P1. In the app: press \"Pair device\" (top bar). Fill in:",
                 f"      Server       https://{self.answers.get('host')}     (prefilled; change it only if it differs)",
                 "      Code         the pairing code (dashes are fine; paste is easiest)",
                 "    Press \"Pair\". The app checks the code belongs to this server and pairs at once:",
                 "    sync starts and the Admin section appears. Every new device sends one alert to your phone."]
        return "\n".join(lines)

    def summary(self, interactive):
        """C-22/C-25/C-29..C-31: status in plain words, warnings first, then an ordered checklist."""
        status = Status(self.system, self.facts).collect()
        a = self.answers
        command = setup_command()
        healthy = status.get("healthcheck") == "ready"
        self.say("\n" + "═" * 64)
        head = "anj-cloud is installed and healthy." if healthy else "anj-cloud is installed, but not healthy yet."
        self.say(f"{head}  {a.get('host')}  (release {(self.release or status.get('release') or '-')[:12]})\n")
        self.say(render_summary_status(status, a, self.backup_state()))
        alerts = {"halo": "using the topic from the VM host", "typed": "using your ntfy topic", "file": "using the topic file",
                  "created": "a new topic, subscribed above" if self.topic_shown else "a new topic"}.get(
            self.topic_source if self.topic_new else None, "the ntfy topic of the earlier install")
        test = {"received": " — test alert received ✓", "not confirmed": " — ⚠ test alert not confirmed"}.get(
            self.topic_test, "")
        self.say(f"\nAlerts: {alerts}{test}.")
        backup = self.backup_state()
        for note in self.notes:
            if note.startswith("The backup share is not attached") and backup == "no share":
                continue                                     # the Backups line below says it, with the fix
            self.say(f"⚠ {note}" if note in self.warnings else f"Note: {note}")
        steps = []
        if self.on_halo():
            steps.append(("The VM host", "one command, in a terminal ON THE VM HOST, not here: see \"VM host step\" below"))
        if backup == "set up" and "last success" in str(status.get("backup")):
            steps.append(("Backups", "set up ✓"))
        elif backup == "set up":
            steps.append(("Backups", f"⚠ mandatory first backup: python3 {paths.RELEASE_CURRENT}/deploy/backup.py "
                                      "seed --cap <minutes>"))
        elif backup == "ready":
            steps.append(("Backups", f"⚠ not set up: sudo {command} backup (at a terminal; you save one password)"))
        else:
            steps.append(("Backups", "⚠ " + guide.no_share_text(self.on_halo(), command)))
        target = "the VM host, which forwards it to this VM" if self.on_halo() else f"this server ({a.get('bind_address')})"
        steps.append(("Router", f"forward TCP 443 from the internet to {target}. Skip if done."))
        if self.mode == "install":
            paired = (self.invite_state() == "approved")
            steps.append(("First device", "paired ✓" if paired else
                          f"pair it (offered last), or later: sudo {command} pair" if interactive else
                          f"at a terminal: sudo {command} pair"))
        else:
            steps.append(("Devices", "check a paired device syncs without re-pairing (same issuer)"))
        self.say("\nWhat to do now, in order:")
        for letter, (name, text) in zip("ABCDE", steps):
            self.say(f"  {letter}. {name + ':':<17} {text}")
        if self.mode == "install":
            self.say("After pairing, the Admin section appears in the app: add members' devices from there.")
        if self.on_halo():
            self.say("Updates later: on the VM host, `deploy/vm/stage.py <vm> --commit <sha> --upgrade` "
                     "(deploy/README.md, \"Updating production\").")
        if self.on_halo():
            fingerprint = self.issuer_fingerprint()
            self.say("\nVM host step — run in a terminal ON THE VM HOST (not in this VM). It lets the VM host's health check trust this\n"
                     "server and keeps a copy of its CA certificate (~/anj-cloud-ca.crt):\n"
                     f"  {HALO_ISSUER_COMMAND}")
            if fingerprint:
                self.say(f"Issuer fingerprint (it must match what that command prints): SHA256 {fingerprint}\n"
                         "If they differ, stop: delete /etc/anj-cloud-host/issuer.crt and ~/anj-cloud-ca.crt on the VM host and "
                         "do not pair — that is not this server.")
        if self.mode == "install":
            self.say("\nPairing the first device needs:\n" + self.pairing_instructions())

    def run_backup(self, argv_tail):
        """backup.py (spec #22) as anj with this terminal: the password goes to /dev/tty only."""
        argv = ["python3", "-I", str(paths.RELEASE_CURRENT / "deploy" / "backup.py"), *argv_tail]
        code, out, err = self.system.attended(argv, user=self.user)
        try:
            result = json.loads(out) if code == 0 and out.strip() else {}
        except ValueError:
            result = {}
        if code != 0:
            try:
                reason = json.loads(err.strip().splitlines()[-1]).get("error")
            except (ValueError, IndexError, AttributeError):
                reason = None
            self.say(f"Backups could not be set up: {reason or 'backup.py failed'}.")
            return None
        return result

    def offer_backup(self):
        """M7 (C-26): offered at the end of the install, with the share attached."""
        if self.backup_state() != "ready" or not self.answers.get("start_stack", True):
            return
        self.say("\n" + "─" * 64 + "\nBackups")
        if not self.prompter.yes("Set up encrypted backups now? You will save one password.", True):
            self.say(f"Later: sudo {setup_command()} backup")
            return
        self.setup_backups()

    def setup_backups(self):
        result = self.run_backup(["init", "--show-escrow"])
        if result is None:
            return 1
        self.backup_done = result.get("escrow")
        self.say(f"Backup repository initialized ({str(result.get('repository_id', ''))[:8]}).")
        if result.get("escrow") != "confirmed":
            self.say(f"⚠ The backup password was not confirmed: sudo {setup_command()} backup --show-password shows it again.")
        self.say("Run the first full backup before relying on the timers: cd /srv/anj-cloud/release/current && "
                 "python3 deploy/backup.py seed --cap <minutes>")
        self.say("Nightly runs refuse, and the 36-hour stale alert stays unarmed, until that first backup succeeds.")
        return 0

    def farewell(self, evidence=None):
        """C-33."""
        saved = (["ntfy topic"] if self.topic_shown else []) + (["backup password"] if self.backup_done else [])
        self.say("\n" + ("Done. Saved in your password manager?   " + "   ".join(f"☐ {item}" for item in saved)
                         if saved else "Done."))
        command = setup_command()
        self.say(f"Check any time: sudo {command} status     Problems: sudo {command} doctor")
        if evidence:
            self.say(f"Details (no secrets): {evidence}")

    def write_evidence(self, result, quiet=False, **extra):
        record = {"tool": "anj-cloud-setup", "spec": 21, "mode": self.mode, "result": result,
                  "started_at": self.started.isoformat(timespec="seconds"),
                  "finished_at": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
                  "release": self.release, "host": self.answers.get("host"), "ddns": self.answers.get("ddns"),
                  "accounts": self.answers.get("accounts") if self.mode == "install" else None,
                  "alerts": {"topic": self.topic_source, "test": self.topic_test}, "cloudflare_check": self.cloudflare,
                  "handoff": self.handoff,
                  "steps": self.steps, "commands": self.system.commands, "files": self.system.files,
                  "notes": self.notes, **{k: v for k, v in extra.items() if k != "failures"}}
        if "failures" in extra:
            record["preflight"] = [{"check": name, "problem": problem, "fix": fix} for name, problem, fix in extra["failures"]]
        text = json.dumps(record, indent=2, sort_keys=True) + "\n"
        for value in self.secret_values():
            if value and value in text:   # defence in depth: a secret never lands in evidence
                text = text.replace(value, "[redacted]")
        # Before a restore has placed the snapshot, the state root must stay empty (spec #22 refuses
        # a state root holding entries the snapshot restores), so that evidence goes to /var/log.
        restoring = self.mode == "restore" and not paths.STACK_CONFIG.exists()
        directory = paths.SETUP_LOG_DIR if paths.STATE_ROOT.is_dir() and self.facts.user() and not restoring \
            else FALLBACK_LOG_DIR
        path = directory / f"{utc_stamp(self.started)}.json"
        try:
            if directory == paths.SETUP_LOG_DIR:
                self.system.mkdir(directory, mode=0o700, owner=self.user)
                self.system.write(path, text, mode=0o600, owner=self.user)
            else:
                self.system.mkdir(directory, mode=0o700)
                self.system.write(path, text, mode=0o600)
            if not quiet:
                self.say(f"Evidence: {path}")
            return path
        except OSError as error:
            self.say(f"Evidence could not be written ({type(error).__name__}).")
            return None

    def secret_values(self):
        values = [self.secrets.get("token"), self.secrets.get("topic"), self.secrets.get("restic"), self.first_code,
                  self.staged.get("token"), self.staged.get("topic")]
        if self.first_code:
            values.append(guide.group(self.first_code))
        for path in (paths.CLOUDFLARE_TOKEN, paths.NTFY_TOPIC):
            values.append((System.text(path) or "").strip() or None)
        return [v for v in values if v]

    # First device pairing (decision #87; audit M2) ------------------------------------------
    def operator(self, *args, data=None, check=True):
        argv = ["python3", "-m", "deploy.access_operator", "--project", paths.PROJECT, "--state-root",
                str(paths.STATE_ROOT), *args]
        code, out, err = self.as_anj(argv, cwd=str(paths.RELEASE_CURRENT), timeout=600, data=data)
        if check and code:
            raise SetupError(f"The operator command `{args[0]}` failed.",
                             "Check `prod.py status`; then run setup again.")
        return json.loads(out) if code == 0 and out.strip() else None

    def operator_change(self, *args):
        self.system.commands.append({"argv": ["python3", "-m", "deploy.access_operator", *args], "user": self.user})
        return self.operator(*args)

    def issue_first_code(self, uid):
        """One invitation for the first account through the same operator path as `invite`; the
        code goes only to the terminal (or the 0600 file), its id and expiry to setup.json."""
        self.system.commands.append({"argv": ["python3", "-m", "deploy.access_operator", "invite", uid], "user": self.user})
        result = self.operator("invite", uid, "--rights", "write")
        self.first_code = result["code"]
        self.save_record(first_invite={"id": result["id"], "uid": uid, "expires": result["expires"],
                                       "issued_at": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")})

    def invitation_state(self, invite_id):
        rows = self.operator("pending", check=False) or []
        row = next((row for row in rows if row.get("id") == invite_id), None)
        return row

    def invite_state(self, row=False):
        """none, live (issued, unexpired), waiting (a device asked), approved, or dead."""
        invite = self.record.get("first_invite") or {}
        if not invite.get("id"):
            return "none"
        if row is False:
            row = self.invitation_state(invite["id"])
        state = (row or {}).get("state")
        expires = float((row or {}).get("expires") or invite.get("expires") or 0)
        if state == "approved":
            return "approved"
        if state in ("denied", "revoked") or expires <= time.time():
            return "dead"
        if state in ("reserved", "provisioning") and (row or {}).get("fingerprint"):
            return "waiting"
        return "live"

    def show_code(self, uid):
        """C-24: the code once, grouped, with its clock expiry; with no terminal, the 0600 file."""
        expires = guide.clock(self.record["first_invite"]["expires"])
        if self.tty():
            self.say(f"\n  Pairing code for {uid}:   {guide.group(self.first_code)}\n")
            # The same code as a QR code for the app's Scan QR code (terminal only, never a file).
            qr = guide.qr_text(self.first_code)
            if qr:
                self.say("  Or scan it in the app (Pair device, Scan QR code):")
                self.out.write(qr)
                self.out.flush()
            self.say("  " + guide.code_note(uid, expires, "sudo " + setup_command()).replace("\n", "\n  "))
        else:
            self.system.write(paths.FIRST_PAIRING_CODE, self.first_code + "\n", mode=0o600, owner=self.user, secret=True)
            self.say(f"\nFirst admin pairing code: in {paths.FIRST_PAIRING_CODE} (0600), valid until {expires}.")

    def pairing_phase(self, interactive):
        """The last phase of an install (M2): pairing when the user is ready. With --answers one
        code is issued once (#104 (5)): shown on a terminal, else the 0600 file."""
        if self.mode != "install" or not self.answers.get("start_stack", True):
            return
        if interactive or (self.attended_terminal() and self.answers.get("wait_first_device")):
            self.pair()
            return
        if not self.record.get("first_invite"):
            uid = self.first_account()
            self.issue_first_code(uid)
            self.show_code(uid)
        if self.answers.get("wait_first_device"):
            self.say(f"wait_first_device needs a terminal; the device pairs by itself with the code. To watch it: "
                     f"sudo {setup_command()} pair")

    def pair(self, *, new_code=False, standalone=False):
        """`sudo anj-cloud-setup pair` and the install's last phase: a code on demand, wait, approve."""
        p = self.prompter
        command = setup_command()
        uid = self.first_account()
        if not uid:
            raise SetupError("This install recorded no first account.", f"Run the install first: sudo {command}")
        invite = self.record.get("first_invite") or {}
        row = self.invitation_state(invite["id"]) if invite.get("id") else None
        state = self.invite_state(row)
        if not self.attended_terminal():
            # No terminal: never wait; a code goes to the 0600 file and the device pairs with it by itself.
            if state == "approved" and not new_code:
                self.say(f"{uid}'s first device is already paired.")
            elif new_code or state in ("none", "dead"):
                if state in ("live", "waiting"):
                    self.operator_change("deny", invite["id"])
                self.issue_first_code(uid)
                self.show_code(uid)
            else:
                self.say(f"A pairing code issued for {uid} works until {guide.clock(invite['expires'])}; a new one: "
                         f"sudo {command} pair --new-code")
            return 0
        p.say("\n" + "─" * 64 + f"\nPair your first device (as {uid}, the admin)")
        if standalone:
            p.say(self.pairing_instructions())
        if state == "approved" and not new_code:
            p.say(f"{uid}'s first device is already paired. Pair more devices from the app's Admin section.")
            return 0
        if state == "waiting" and not new_code and (row or {}).get("pinned"):
            pass                                                # being approved automatically: wait below
        elif state == "waiting" and not new_code:
            result = self.approve(row)
            if result != "expired":
                return result
            if not self.renew(uid):
                return 0
        elif state == "live" and not new_code:
            p.say(f"A pairing code works until {guide.clock(invite['expires'])}. It is shown only once; without it: "
                  f"sudo {command} pair --new-code")
            if not p.yes("Wait here for the device to use it?", True):
                p.say(f"Later: sudo {command} pair")
                return 0
        else:
            p.say("You need: the anj-cloud app open on that device (P1).")
            if state == "dead":
                p.say("The last pairing code expired.")
            # The 10-minute clock starts only once the app is open where the code goes.
            ready = "Is the anj-cloud app open on that device?"
            answer = p.ask_raw(f"{ready} The pairing code (valid 10 minutes) is issued next.\n"
                               "Press Enter when ready, or type 'later': ").strip().lower()
            if answer == "later":
                p.say(f"Later: sudo {command} pair")
                return 0
            if state in ("live", "waiting"):
                self.operator_change("deny", invite["id"])
            self.issue_first_code(uid)
            self.show_code(uid)
        while True:
            outcome = self.wait_device()
            if isinstance(outcome, dict) and outcome.get("pinned"):
                if outcome.get("state") == "approved":
                    return self.paired(outcome)
                result = self.approve_pinned(outcome)
                if result != "expired":
                    return result
            elif isinstance(outcome, dict):
                result = self.approve(outcome)
                if result != "expired":
                    return result
            elif outcome == "interrupted":
                p.say(f"\nStopped waiting. Pair later with: sudo {command} pair")
                return 0
            elif outcome == "closed":
                return 0
            else:
                p.say(f"The code expired at {guide.clock(self.record['first_invite']['expires'])} before a device used it.")
            if not self.renew(uid):
                return 0

    def renew(self, uid):
        """After an expiry: a new code only on an explicit yes (the old one is denied first)."""
        if not self.prompter.yes("Get a new code?", True):
            self.say(f"Later: sudo {setup_command()} pair --new-code")
            return False
        self.operator_change("deny", self.record["first_invite"]["id"])
        self.issue_first_code(uid)
        self.show_code(uid)
        return True

    def wait_device(self):
        invite = self.record.get("first_invite") or {}
        expires = float(invite.get("expires") or 0)
        self.say(f"\nWaiting for the app to pair (Ctrl-C stops waiting; resume with: sudo {setup_command()} pair) …")
        last = time.monotonic()
        asked = None
        try:
            while time.time() < expires:
                row = self.invitation_state(invite.get("id"))
                if row and row.get("pinned"):
                    # Decision #151: the gateway approves a redeemed pinned code by itself.
                    if row.get("state") == "approved":
                        return row
                    if row.get("fingerprint") and row.get("state") in ("reserved", "provisioning"):
                        if asked is None:
                            asked = time.monotonic()
                            self.say("  The device asked to pair; the server is approving it …")
                        elif time.monotonic() - asked >= PINNED_APPROVAL_GRACE:
                            return row
                elif row and row.get("fingerprint") and row.get("state") in ("reserved", "provisioning"):
                    return row
                if row and row.get("state") in ("approved", "denied", "revoked"):
                    self.say(f"The invitation is already {row['state']}.")
                    return "closed"
                if time.monotonic() - last >= 60:
                    last = time.monotonic()
                    self.say(f"  still waiting … (the code works until {guide.clock(expires)})")
                time.sleep(PAIR_POLL_SECONDS)
        except KeyboardInterrupt:
            return "interrupted"
        return "expired"

    def approve(self, row):
        """C-32: both fingerprint forms; the user types the last 4; the full 64 characters are what
        `approve` checks, so typing 4 is a reading aid, not a weaker check. Enter does nothing here:
        refusing burns the code, so it takes an explicit 'deny' (L-5). An approval after the code's
        10 minutes says so and offers a new code (L-2). Returns 0, 1 or "expired"."""
        p = self.prompter
        command = setup_command()
        fingerprint = row["fingerprint"]
        expires = float(row.get("expires") or (self.record.get("first_invite") or {}).get("expires") or 0)
        label = "".join(ch for ch in str(row.get("label") or "") if ch.isprintable())[:80] or "unnamed"
        uid = "".join(ch for ch in str(row.get("uid") or "") if ch.isprintable())[:32]
        p.say(f"\nP3. {uid}'s device \"{label}\" asked to pair. Approve it before {guide.clock(expires)}, when the code "
              "stops working.\n    Compare with the app's \"Device fingerprint (SHA-256)\":")
        p.say(f"      the app should show:   {fingerprint}")
        p.say(f"      grouped:               {guide.group(fingerprint, 4, ' ')}")
        p.say(f"    Check the first 8 ({fingerprint[:8]}) and the last 8 ({fingerprint[-8:]}) match.")
        while True:
            answer = p.ask_raw("    Type the last 4 characters to approve, or 'deny' to refuse it: ").strip().lower()
            if not answer:
                p.say("    Enter does nothing here: type the last 4 characters, or 'deny'.")
                continue
            if answer == "deny":
                self.operator_change("deny", row["id"])
                p.say(f"Refused. Nothing was approved. Start again with: sudo {command} pair --new-code")
                return 1
            if answer != fingerprint[-4:].lower():
                p.say("    That is not the last 4 characters of the fingerprint above; compare again.")
                continue
            if time.time() >= expires:
                return self.expired_approval(expires)
            try:
                self.operator_change("approve", row["id"], "--fingerprint", fingerprint)
            except SetupError:
                if time.time() >= expires - 5:
                    return self.expired_approval(expires)
                raise
            self.system.remove(paths.FIRST_PAIRING_CODE)   # consumed
            p.say("    Approved. In the app, press \"Pair\" again — sync starts and the Admin section appears.")
            return 0

    def paired(self, row, fallback=False):
        label = "".join(ch for ch in str(row.get("label") or "") if ch.isprintable())[:80] or "unnamed"
        uid = "".join(ch for ch in str(row.get("uid") or "") if ch.isprintable())[:32]
        self.system.remove(paths.FIRST_PAIRING_CODE)       # consumed
        # The gateway sends the new-device alert, at least once, through the console app; after the
        # fallback (that app not answering) it goes out once the console answers again.
        alert = ("Your phone gets the new-device alert once the server's console app answers again "
                 f"(check: sudo {setup_command()} status)." if fallback else "Your phone gets one alert for the new device.")
        self.prompter.say(f"\nPaired: {uid}'s device \"{label}\". Sync starts in the app and the Admin section appears.\n"
                          + alert)
        return 0

    def approve_pinned(self, row):
        """The gateway's automatic approval did not finish within PINNED_APPROVAL_GRACE (its console
        backend is down): approve through the operator path with the fingerprint of the CSR that
        redeemed the code. Nobody compares anything; redeeming the valid code is the approval."""
        expires = float(row.get("expires") or (self.record.get("first_invite") or {}).get("expires") or 0)
        if time.time() >= expires:
            return self.expired_approval(expires)
        try:
            self.operator_change("approve", row["id"], "--fingerprint", row["fingerprint"])
        except SetupError:
            if time.time() >= expires - 5:
                return self.expired_approval(expires)
            raise
        return self.paired({**row, "state": "approved"}, fallback=True)

    def expired_approval(self, expires):
        self.say(f"The code expired at {guide.clock(expires)} before the approval, so this device cannot be approved "
                 f"with it. A new code: sudo {setup_command()} pair --new-code")
        return "expired"


# Steps -------------------------------------------------------------------------------------

class Step:
    number = 0
    name = ""
    title, purpose, expect = "", "", "under 1 min"     # the plain-language progress line (C-20)
    fix = "Run setup again; finished steps are kept."

    def __init__(self, setup):
        self.setup = setup
        self.system = setup.system
        self.facts = setup.facts

    def state(self):
        raise NotImplementedError

    def plan(self):
        return []

    def apply(self):
        raise NotImplementedError

    def verify(self):
        done, current = self.state()
        return done, current


class Packages(Step):
    number, name = 1, "Packages"
    title, purpose, expect = "Installing system packages", "Docker, Node, firewall tools", "2–5 min"

    def docker_choice(self):
        if self.facts.installed("docker-ce"):
            return "docker-repo"
        engine = self.facts.installed("docker.io") or self.facts.candidate("docker.io")
        compose = self.facts.installed("docker-compose") or self.facts.candidate("docker-compose")
        if engine and compose and version_tuple(engine) >= ENGINE_MIN and version_tuple(compose) >= COMPOSE_MIN:
            return "debian"
        return "docker-repo" if engine and compose else "unknown"

    def wanted(self, choice):
        return list(BASE_PACKAGES) + list(DEBIAN_DOCKER if choice != "docker-repo" else DOCKER_REPO_PACKAGES)

    def state(self):
        choice = self.docker_choice()
        missing = [p for p in self.wanted(choice) if not self.facts.installed(p)]
        if missing:
            return False, "missing: " + ", ".join(missing)
        return True, f"installed (Docker from {'Debian' if choice == 'debian' else 'the pinned Docker repository'})"

    def plan(self):
        choice = self.docker_choice()
        lines = ["apt-get update"]
        if choice == "debian":
            lines.append("Docker from Debian 13 (docker.io, docker-cli, docker-compose): versions satisfy compose.prod.json")
        elif choice == "docker-repo":
            lines += [f"Docker's apt repository: {DOCKER_LIST}, key {DOCKER_KEY} (sha256 pinned), "
                      f"pins {DOCKER_PREFS}", "its origin added to unattended-upgrades"]
        else:
            lines.append("decide the Docker source after apt-get update (Debian 13 if its versions fit)")
        lines.append("apt-get install -y --no-install-recommends " + " ".join(self.wanted(choice)))
        lines.append("start qemu-guest-agent")
        return lines

    def apply(self):
        env = ["env", "DEBIAN_FRONTEND=noninteractive"]
        self.system.change([*env, "apt-get", "update"], show_errors=True)
        self.system.change([*env, "apt-get", "install", "-y", "--no-install-recommends", *BASE_PACKAGES], show_errors=True)
        self.facts._cache.clear()
        choice = self.docker_choice()
        if choice != "debian":
            self.docker_repository()
        self.system.change([*env, "apt-get", "install", "-y", "--no-install-recommends",
                            *(DEBIAN_DOCKER if choice == "debian" else DOCKER_REPO_PACKAGES)], show_errors=True)
        if Path("/dev/virtio-ports/org.qemu.guest_agent.0").exists():
            self.system.change(["systemctl", "start", "qemu-guest-agent.service"], check=False)

    def docker_repository(self):
        """Fallback (#89 (1)): Docker's apt repository, key by pinned digest, versions pinned."""
        with tempfile.TemporaryDirectory() as directory:
            key = Path(directory) / "docker.asc"
            self.system.change(["curl", "-fsSL", "-o", str(key), DOCKER_KEY_URL], show_errors=True)
            if not self.system.dry and sha256(key.read_bytes()) != DOCKER_KEY_SHA256:
                raise SetupError("Docker's repository key does not match the pinned digest.",
                                 "Do not continue; report it. The pin is in deploy/vm/bootstrap.py.")
            self.system.write(DOCKER_KEY, key.read_bytes() if not self.system.dry else b"", mode=0o644)
        self.system.write(DOCKER_LIST, f"deb [arch=amd64 signed-by={DOCKER_KEY}] {DOCKER_REPO} trixie stable\n")
        self.system.write(DOCKER_PREFS, "".join(f"Package: {name}\nPin: version {version}\nPin-Priority: 1001\n\n"
                                                for name, version in DOCKER_PIN.items()))
        self.system.change(["env", "DEBIAN_FRONTEND=noninteractive", "apt-get", "update"], show_errors=True)

    def verify(self):
        done, current = self.state()
        if not done:
            return False, current
        code, engine, _ = self.system.read(["docker", "version", "--format", "{{.Server.Version}}"])
        code2, compose, _ = self.system.read(["docker", "compose", "version", "--short"])
        if code or code2:
            return False, "docker or docker compose does not answer"
        if version_tuple(engine) < ENGINE_MIN or version_tuple(compose) < COMPOSE_MIN:
            return False, f"Docker {engine.strip()} / Compose {compose.strip()} below the requirement"
        return True, f"Docker {engine.strip()}, Compose {compose.strip()}, Node {self.facts.installed('nodejs')}"


class Pm2(Step):
    number, name = 2, "PM2"
    title, purpose, expect = "Installing PM2", "it keeps the services running", "about 1 min"

    def pin(self):
        return json.loads((SOURCE_DIR / "pm2" / "package.json").read_text())["dependencies"]["pm2"]

    def state(self):
        installed = json.loads(System.text(PM2_DIR / "node_modules" / "pm2" / "package.json") or "{}").get("version")
        lock = System.text(PM2_DIR / "package-lock.json")
        if installed != self.pin() or lock != (SOURCE_DIR / "pm2" / "package-lock.json").read_text():
            return False, f"PM2 {installed or 'absent'} (pin {self.pin()})"
        if not PM2_LINK.is_symlink() or os.readlink(PM2_LINK) != str(PM2_DIR / "node_modules" / "pm2" / "bin" / "pm2"):
            return False, f"PM2 {installed}, {PM2_LINK} missing"
        # Root can read an installation that the service user cannot. Check the package
        # tree as anj without invoking PM2 (even --version can start its daemon).
        probe = ("import os,sys\n"
                 "def fail(*args): sys.exit(1)\n"
                 "root,binary=sys.argv[1:]\n"
                 "if not os.path.isdir(root) or not os.access(binary,os.R_OK|os.X_OK): fail()\n"
                 "for path,dirs,files in os.walk(root,onerror=fail):\n"
                 " if not os.access(path,os.R_OK|os.X_OK): fail()\n"
                 " for name in dirs:\n"
                 "  if not os.access(os.path.join(path,name),os.R_OK|os.X_OK): fail()\n"
                 " for name in files:\n"
                 "  if not os.access(os.path.join(path,name),os.R_OK): fail()\n")
        code, _, _ = self.system.read(["python3", "-I", "-c", probe, str(PM2_DIR / "node_modules"), str(PM2_LINK)],
                                     user=self.setup.user)
        if code:
            return False, f"PM2 {installed}, installed files are not accessible to {self.setup.user}"
        return True, f"PM2 {installed}"

    def plan(self):
        return [f"{PM2_DIR}/package.json and package-lock.json from deploy/vm/pm2 (pm2 {self.pin()}, integrity-checked)",
                f"npm ci --omit=optional --ignore-scripts in {PM2_DIR}", f"link {PM2_LINK}"]

    def apply(self):
        self.system.mkdir(PM2_DIR.parent, mode=0o755)
        self.system.mkdir(PM2_DIR, mode=0o755)
        # npm ci replaces the packages but retains this directory and its old mode.
        # Repair the public package directory too when resuming a restrictive install.
        self.system.mkdir(PM2_DIR / "node_modules", mode=0o755)
        for name in ("package.json", "package-lock.json"):
            self.system.write(PM2_DIR / name, (SOURCE_DIR / "pm2" / name).read_bytes())
        # Only npm's public package tree needs this mask; preserve the installer's
        # inherited mask for all other work, including secret material.
        self.system.change(["npm", "ci", "--omit=optional", "--ignore-scripts", "--no-audit", "--no-fund"],
                           cwd=str(PM2_DIR), show_errors=True, umask=0o022)
        self.system.symlink(PM2_DIR / "node_modules" / "pm2" / "bin" / "pm2", PM2_LINK)

    def verify(self):
        done, current = self.state()
        if not done:
            return False, current
        # Not `pm2 --version`: every pm2 command connects to a daemon and starts one if none runs.
        binary = PM2_DIR / "node_modules" / "pm2" / "bin" / "pm2"
        if not os.access(binary, os.X_OK):
            return False, f"{binary} is not executable"
        return True, current + f" (lockfile digest {sha256((PM2_DIR / 'package-lock.json').read_bytes())[:12]})"


class DataDisk(Step):
    number, name = 3, "Data disk"
    title, purpose, expect = "Preparing the data disk", "", "seconds"
    fix = "Check the data disk (`lsblk`), then run setup again."

    def device(self):
        mounted = self.facts.mount_source(paths.DATA_ROOT)
        if mounted:
            return mounted.get("source")
        if self.setup.answers.get("data_disk"):
            return self.setup.answers["data_disk"]
        unused = unused_disks(self.facts)
        return unused[0]["path"] if len(unused) == 1 else None

    def needs_init(self):
        if self.facts.mount_source(paths.DATA_ROOT) or not self.device():
            return False
        return classify_disk(self.facts, self.device())[0] == "blank"

    def fstab_lines(self, uuid):
        return [f"UUID={uuid} {paths.DATA_ROOT} ext4 defaults,nofail,noatime 0 2 {FSTAB_MARK} data disk",
                f"{paths.BACKUP_TAG} {paths.BACKUP_MOUNT} virtiofs nofail,nodev,nosuid,noexec 0 0 {FSTAB_MARK} backup share"]

    def state(self):
        mounted = self.facts.mount_source(paths.DATA_ROOT)
        if not mounted:
            device = self.device()
            if not device:
                return False, "no data disk chosen"
            kind, detail = classify_disk(self.facts, device)
            return False, f"{device}: {detail}, not mounted"
        fstab = System.text(FSTAB) or ""
        missing = [line for line in self.fstab_lines(mounted.get("uuid")) if line not in fstab.splitlines()]
        if missing:
            return False, f"mounted from {mounted.get('source')}, fstab lines missing"
        state = paths.STATE_ROOT
        anj = self.facts.user()
        try:
            info = os.lstat(state)
            release = os.lstat(paths.RELEASE_SOURCE_DIR)
        except OSError:
            return False, "mounted; state/ or release/ missing"
        if (info.st_uid, stat.S_IMODE(info.st_mode)) != (anj.pw_uid, 0o700) or release.st_uid != anj.pw_uid:
            return False, f"mounted; {state} must be 0700 owned by {paths.VM_USER}"
        return True, f"{mounted.get('source')} ({paths.DATA_LABEL}) on {paths.DATA_ROOT}"

    def plan(self):
        device = self.device()
        lines = []
        kind, detail = classify_disk(self.facts, device) if device else ("missing", "no disk")
        if kind in ("foreign", "missing", "in-use"):
            return [f"refuse: {device or 'no spare disk'} {detail} (a disk with any signature is never formatted)"]
        if kind == "blank":
            lines.append(f"mkfs.ext4 -L {paths.DATA_LABEL} {device} (blank disk; asks for confirmation first)")
        lines += [f"/etc/fstab: {line}" for line in self.fstab_lines("<uuid>")]
        lines += [f"mount {paths.DATA_ROOT}; {paths.STATE_ROOT} 0700 {paths.VM_USER}; "
                  f"{paths.RELEASE_SOURCE_DIR} 0755 {paths.VM_USER}", f"mount {paths.BACKUP_MOUNT} if the share is attached"]
        return lines

    def apply(self):
        device = self.device()
        mounted = self.facts.mount_source(paths.DATA_ROOT)
        if not mounted:
            kind, detail = classify_disk(self.facts, device)
            if kind == "blank":
                # Re-checked here, right before the only format this tool ever runs.
                self.facts._cache.clear()
                if classify_disk(self.facts, device)[0] != "blank":
                    raise SetupError(f"{device} changed and now holds data; it is not formatted.", self.fix)
                uuid = str(uuid_module.uuid4())
                self.system.mkdir(STAGE_DIR, mode=0o755)
                self.system.write(FORMATTED_MARKER, uuid + "\n", mode=0o644)
                # stdin is empty: should mke2fs itself see a signature, its "Proceed anyway?" reads no.
                self.system.change(["mkfs.ext4", "-q", "-L", paths.DATA_LABEL, "-U", uuid, "-m", "1", device],
                                   show_errors=True, data="")
            elif kind == "anj-data" and self.setup.mode == "install" and formatted_here() != \
                    next((d.get("uuid") for d in self.facts.disks() if d["path"] == device), None):
                raise SetupError(f"{device} already holds anj-cloud data.", "Run with --adopt-data to keep it.")
            elif kind != "anj-data":
                raise SetupError(f"{device} {detail}; setup never formats a disk that has any signature.", self.fix)
            self.facts._cache.clear()
        code, out, _ = self.system.read(["blkid", "-s", "UUID", "-o", "value", device])
        uuid = out.strip()
        if self.system.dry:
            uuid = uuid or "<uuid>"
        elif code != 0 or not re.fullmatch(r"[0-9a-fA-F-]{8,36}", uuid):
            raise SetupError(f"The UUID of {device} cannot be read (blkid exit {code}); /etc/fstab was not changed.",
                             "Check the disk with `sudo blkid " + str(device) + "`, then run setup again.")
        fstab = System.text(FSTAB) or ""
        lines = [line for line in fstab.splitlines() if FSTAB_MARK not in line]
        lines += self.fstab_lines(uuid)
        self.system.write(FSTAB, "\n".join(lines) + "\n", mode=0o644)
        self.system.change(["systemctl", "daemon-reload"])
        self.system.mkdir(paths.DATA_ROOT, mode=0o755)
        if not self.facts.mount_source(paths.DATA_ROOT):
            self.system.change(["mount", str(paths.DATA_ROOT)], show_errors=True)
        anj = self.facts.user()
        if paths.STATE_ROOT.exists() and os.lstat(paths.STATE_ROOT).st_uid != anj.pw_uid:
            raise SetupError(f"{paths.STATE_ROOT} is owned by uid {os.lstat(paths.STATE_ROOT).st_uid}, not "
                             f"{paths.VM_USER} ({anj.pw_uid}).",
                             f"Give it back: `sudo chown -R {paths.VM_USER}: {paths.STATE_ROOT}` (old install's user id).")
        self.system.mkdir(paths.STATE_ROOT, mode=0o700, owner=self.setup.user)
        self.system.mkdir(paths.RELEASE_SOURCE_DIR, mode=0o755, owner=self.setup.user)
        if self.setup.mode != "restore":
            # This machine owns the state from now on (a re-run after a later failure is not a
            # foreign state). A restore writes nothing into the state root before the snapshot.
            self.setup.save_record(machine_id=machine_id())
        if not self.facts.mount_source(paths.BACKUP_MOUNT):
            # Only an unmounted mount point is created or chmodded: on a mounted share this path is
            # the share's root (The VM host's 0700 directory), and a read-only share refuses the chmod (SC-067).
            self.system.mkdir(paths.BACKUP_MOUNT, mode=0o755)
            code, _, _ = self.system.change(["mount", str(paths.BACKUP_MOUNT)], check=False)
            if code:
                self.setup.notes.append("The backup share is not attached; production runs without backups until it is "
                                        "(backups cannot run meanwhile).")
        self.facts._cache.clear()


class Docker(Step):
    number, name = 4, "Docker"
    title, purpose, expect = "Configuring Docker", "its data goes on the data disk", "under 1 min"

    def state(self):
        problems = []
        if System.text(DAEMON_JSON) != daemon_json():
            problems.append("daemon.json")
        anj = self.facts.user()
        groups = {g.gr_name for g in grp.getgrall() if anj and anj.pw_name in g.gr_mem}
        if not {"docker", "systemd-journal"} <= groups:
            problems.append(f"{paths.VM_USER} groups")
        try:
            if grp.getgrgid(paths.GATEWAY_GID).gr_name != paths.GATEWAY_GROUP:
                problems.append("gid 10002 is another group")
        except KeyError:
            problems.append(f"group {paths.GATEWAY_GROUP}")
        dropin = SYSTEMD_DIR / "docker.service.d" / "zz-anj-cloud.conf"
        if System.text(dropin) != rendered_dropins(self.setup.home)["docker.service.d/zz-anj-cloud.conf"]:
            problems.append("docker drop-in")
        code, out, _ = self.system.read(["docker", "info", "--format", "{{.DockerRootDir}} {{.LoggingDriver}}"])
        if code != 0 or out.strip() != f"{paths.DOCKER_ROOT} journald":
            problems.append("daemon not on the data disk")
        return (not problems), ("configured" if not problems else "to fix: " + ", ".join(problems))

    def plan(self):
        return [f"{DAEMON_JSON}: " + daemon_json().replace("\n", " "),
                f"groupadd -g {paths.GATEWAY_GID} {paths.GATEWAY_GROUP}; usermod -aG docker,systemd-journal {paths.VM_USER}",
                f"{SYSTEMD_DIR}/docker.service.d/zz-anj-cloud.conf (RequiresMountsFor={paths.DATA_ROOT})",
                "systemctl restart docker (only when its configuration changed)"]

    def apply(self):
        changed = False
        if System.text(DAEMON_JSON) != daemon_json():
            self.system.write(DAEMON_JSON, daemon_json())
            changed = True
        try:
            if grp.getgrgid(paths.GATEWAY_GID).gr_name != paths.GATEWAY_GROUP:
                raise SetupError(f"gid {paths.GATEWAY_GID} belongs to another group; the gateway socket needs it.",
                                 "Free that gid (anj-cloud needs this fixed one), then run setup again.")
        except KeyError:
            self.system.change(["groupadd", "-g", str(paths.GATEWAY_GID), paths.GATEWAY_GROUP])
        self.system.change(["usermod", "-aG", "docker,systemd-journal", self.setup.user])
        dropin = SYSTEMD_DIR / "docker.service.d" / "zz-anj-cloud.conf"
        text = rendered_dropins(self.setup.home)["docker.service.d/zz-anj-cloud.conf"]
        if System.text(dropin) != text:
            self.system.write(dropin, text)
            self.system.change(["systemctl", "daemon-reload"])
            changed = True
        code, out, _ = self.system.read(["docker", "info", "--format", "{{.DockerRootDir}} {{.LoggingDriver}}"])
        if changed or code != 0 or out.strip() != f"{paths.DOCKER_ROOT} journald":
            self.system.change(["systemctl", "restart", "docker.service"], show_errors=True)


class Firewall(Step):
    number, name = 5, "Firewall"
    title, purpose, expect = "Turning on the firewall", "only 443, and SSH from one address", "seconds"

    def text(self):
        return render_firewall(self.setup.answers["bind_address"], self.setup.answers["admin_ssh_source"])

    def unit(self):
        return (SOURCE_DIR / "systemd" / "anj-cloud-firewall.service").read_text()

    def state(self):
        if System.text(FIREWALL_FILE) != self.text() or System.text(SYSTEMD_DIR / "anj-cloud-firewall.service") != self.unit():
            return False, "not installed or different"
        code, _, _ = self.system.read(["nft", "list", "table", "inet", "anj_cloud"])
        enabled = self.system.read(["systemctl", "is-enabled", "anj-cloud-firewall.service"])[1].strip()
        if code != 0 or enabled != "enabled":
            return False, "installed, table not loaded or unit not enabled"
        return True, f"table inet anj_cloud: 443 to {self.setup.answers['bind_address']}, 22 from " \
                     f"{self.setup.answers['admin_ssh_source']}"

    def plan(self):
        return [f"{FIREWALL_FILE}: table inet anj_cloud (input drop; lo, established, ICMP, DHCP replies, "
                f"443 to {self.setup.answers['bind_address']}, 22 from {self.setup.answers['admin_ssh_source']})",
                f"{SYSTEMD_DIR}/anj-cloud-firewall.service; systemctl enable --now (never flush ruleset)"]

    def apply(self):
        self.system.mkdir(ETC_DIR, mode=0o755)
        # Validated before it becomes the file the unit loads at boot.
        candidate = FIREWALL_FILE.with_name(FIREWALL_FILE.name + ".new")
        self.system.write(candidate, self.text())
        self.system.change(["nft", "-c", "-f", str(candidate)], show_errors=True)
        self.system.write(FIREWALL_FILE, self.text())
        self.system.remove(candidate)
        self.system.write(SYSTEMD_DIR / "anj-cloud-firewall.service", self.unit())
        self.system.change(["systemctl", "daemon-reload"])
        self.system.change(["systemctl", "enable", "anj-cloud-firewall.service"])
        active = self.system.read(["systemctl", "is-active", "anj-cloud-firewall.service"])[1].strip() == "active"
        # reload = `nft -f` again: one atomic transaction; never stop/start (no window without the table).
        self.system.change(["systemctl", "reload" if active else "start", "anj-cloud-firewall.service"],
                           show_errors=True)

    def verify(self):
        done, current = self.state()
        if not done:
            return False, current
        _, tables, _ = self.system.read(["nft", "list", "tables"])
        if "table ip nat" not in tables or "table ip filter" not in tables:
            return False, "Docker's tables (ip nat, ip filter) are missing"
        return True, current + "; Docker's tables intact"


class Journald(Step):
    number, name = 6, "Journald"
    title, purpose, expect = "Keeping system logs", "90 days, at most 1 GiB", "seconds"

    def text(self):
        return (SOURCE_DIR / "config" / "zz-anj-cloud-journald.conf").read_text()

    def state(self):
        if System.text(JOURNALD_CONF) != self.text():
            return False, "drop-in absent"
        code, out, _ = self.system.read(["systemd-analyze", "cat-config", "systemd/journald.conf"])
        effective = {}
        for line in out.splitlines() if code == 0 else []:
            if "=" in line and not line.lstrip().startswith(("#", ";")):
                key, value = line.split("=", 1)
                effective[key.strip()] = value.strip()
        wanted = {"Storage": "persistent", "SystemMaxUse": "1G", "MaxRetentionSec": "90day"}
        if any(effective.get(k) != v for k, v in wanted.items()):
            return False, "drop-in present but not effective"
        return True, "persistent, 1G, 90 days"

    def plan(self):
        return [f"{JOURNALD_CONF}: Storage=persistent, SystemMaxUse=1G, MaxRetentionSec=90day",
                "systemctl restart systemd-journald"]

    def apply(self):
        self.system.write(JOURNALD_CONF, self.text())
        self.system.change(["systemctl", "restart", "systemd-journald.service"])


class Ssh(Step):
    number, name = 7, "SSH (read-only)"
    title, purpose, expect = "Checking SSH settings", "read-only", "seconds"

    def state(self):
        code, out, _ = self.system.read(["sshd", "-T"])
        if code != 0:
            return True, "posture unreadable (sshd -T needs root)"
        values = dict(line.split(" ", 1) for line in out.splitlines() if " " in line)
        return True, (f"password authentication {values.get('passwordauthentication', '?')}, "
                      f"root login {values.get('permitrootlogin', '?')} (reported, never changed)")

    def apply(self):
        pass


class Restore(Step):
    number, name = 7.5, "Restore (spec #22)"
    title, purpose, expect = "Restoring from the backup", "the household data and keys", "minutes to hours"
    fix = "Check the backup share and the password, then run setup again with --restore-from."

    def state(self):
        record = json.loads(System.text(paths.BACKUP_RECORD) or "{}")
        last = paths.RUN_DIR / "last-restore.json"
        if (record.get("targets") or [{}])[0].get("repository_id") and paths.STACK_CONFIG.exists() and last.exists():
            return True, "restored"
        return False, "not restored"

    def plan(self):
        return [f"backup.py init --adopt (repository ID read from {self.setup.args.restore_from}; nothing written)",
                "backup.py restore --snapshot latest into the state root and Docker volumes"]

    def apply(self):
        backup = ["python3", "-I", str(ROOT / "deploy" / "backup.py")]
        source = Path(self.setup.args.restore_from)
        if source != paths.BACKUP_MOUNT:
            raise SetupError(f"--restore-from must be the backup share {paths.BACKUP_MOUNT}.", self.fix)
        with tempfile.TemporaryDirectory(prefix="anj-cloud-setup-", dir="/run") as directory:
            os.chmod(directory, 0o700)
            os.chown(directory, self.facts.user().pw_uid, self.facts.user().pw_gid)
            password = self.setup.secrets.get("restic_file")
            if not password:
                password = str(Path(directory) / "restic-password")
                self.system.write(password, self.setup.secrets["restic"] + "\n", mode=0o600, owner=self.setup.user,
                                  secret=True)
            self.setup.install_dispatcher(ROOT)   # before init records it (spec #22 alerts during the restore)
            if not json.loads(System.text(paths.BACKUP_RECORD) or "{}").get("targets"):
                self.setup.change_as_anj([*backup, "init", "--adopt", "--password-file", password, "--alert-command",
                                          str(paths.ALERT_COMMAND)], timeout=1800, show_errors=True)
            work = paths.DATA_ROOT / "restore-work"
            self.system.mkdir(work, mode=0o700, owner=self.setup.user)
            target = work / utc_stamp()
            self.setup.change_as_anj([*backup, "restore", "--snapshot", "latest", "--target", str(target), "--project",
                                      paths.PROJECT, "--state-root", str(paths.STATE_ROOT)], timeout=6 * 3600,
                                     show_errors=True)
            if not self.system.dry:
                shutil.rmtree(target, ignore_errors=True)


class Release(Step):
    number, name = 8, "Release"
    title, purpose, expect = "Unpacking the release", "", "under 1 min"

    def resolve(self):
        if self.setup.release:
            return self.setup.release
        stack = json.loads(System.text(paths.STACK_CONFIG) or "{}")
        recorded = stack.get("release")
        if recorded:
            self.setup.release = recorded
            wanted = self.setup.answers.get("source")
            if wanted:
                commit = resolve_source(wanted)[0]
                if commit != recorded:
                    self.setup.notes.append(f"Release {recorded[:12]} stays installed (setup never switches a running "
                                            f"release). To update to {commit[:12]}, run on the VM host: `deploy/vm/stage.py <vm> "
                                            f"--commit {commit[:12]} --upgrade` (deploy/README.md, Updating production).")
            return recorded
        if self.setup.mode != "install" and self.setup.mode != "restore":
            raise SetupError("The adopted data disk records no release.", "Use --restore-from, or a fresh install.")
        commit, tar, checkout = resolve_source(self.setup.answers.get("source"))
        self.setup.release, self.setup.release_tar, self.setup.checkout = commit, tar, checkout
        return commit

    def paths_for(self, commit):
        return release_paths(commit)

    def state(self):
        commit = self.resolve()
        tar, tree = self.paths_for(commit)
        stack = json.loads(System.text(paths.STACK_CONFIG) or "{}")
        if not tar.is_file() or not (tree / "deploy" / "prod.py").is_file() or stack.get("release") != commit:
            return False, f"release {commit[:12]} not in place"
        return True, f"release {commit[:12]}"

    def plan(self):
        commit = self.resolve()
        tar, tree = self.paths_for(commit)
        return [f"{tar} (0600 {paths.VM_USER})", f"extract to {tree}", f"{paths.STACK_CONFIG}: release {commit[:12]}"]

    def apply(self):
        commit = self.resolve()
        install_release_source(self.setup, commit, self.setup.release_tar, self.setup.checkout)
        if not paths.STACK_CONFIG.exists():
            # prod.py setup takes the release recorded here (the VM has no git checkout).
            self.system.write(paths.STACK_CONFIG, json.dumps({"release": commit}, indent=2) + "\n", mode=0o600,
                              owner=self.setup.user)


EXTRACT_SCRIPT = ("import sys,tarfile,os,shutil\n"
                  "tar,dest=sys.argv[1],sys.argv[2]\n"
                  "stage=os.path.join(os.path.dirname(dest),'.extract-'+os.path.basename(dest))\n"
                  "shutil.rmtree(stage,ignore_errors=True); os.mkdir(stage,0o755)\n"
                  "tarfile.open(tar).extractall(stage,filter='data')\n"
                  "os.replace(stage,dest)\n")


def release_paths(commit):
    """(state/release/<commit12>/source.tar, /srv/anj-cloud/release/<commit12>)."""
    return paths.RELEASE_DIR / commit[:12] / "source.tar", paths.RELEASE_SOURCE_DIR / commit[:12]


def install_release_source(setup, commit, release_tar=None, checkout=None, replace_stale=False):
    """Step 8's layout, also used by `upgrade` (decision #122): the source as
    state/release/<commit12>/source.tar (0600 anj, in 0700 directories), extracted by anj to
    /srv/anj-cloud/release/<commit12>/ (0755). An existing tar must be that same release; an
    existing tree is kept. Nothing switches.

    `replace_stale` (upgrade, for a release that is neither live nor previous): an existing tar
    whose bytes differ from the new source is replaced and its tree extracted again (review L4)."""
    tar, tree = release_paths(commit)
    anj = setup.user
    setup.system.mkdir(paths.RELEASE_DIR, mode=0o700, owner=anj)
    setup.system.mkdir(tar.parent, mode=0o700, owner=anj)
    if tar.is_file() and replace_stale and release_tar and Path(release_tar) != tar and \
            sha256(tar.read_bytes()) != sha256(Path(release_tar).read_bytes()):
        setup.notes.append(f"Replaced a stale {tar} (same commit, other bytes) and its extracted tree.")
        setup.system.remove(tar)
        if not setup.system.dry:
            shutil.rmtree(tree, ignore_errors=True)
    if tar.is_file():
        if tar_commit(tar) != commit:
            raise SetupError(f"{tar} is not release {commit[:12]}.",
                             f"Move {tar.parent} aside (it is not the live release), then run this again.")
    else:
        if checkout:
            data = subprocess.run(["git", "-C", str(checkout), "archive", "--format=tar", commit],
                                  capture_output=True, check=True).stdout
        else:
            data = Path(release_tar).read_bytes()
        setup.system.write(tar, data, mode=0o600, owner=anj)
    if not (tree / "deploy" / "prod.py").is_file():
        setup.change_as_anj(["python3", "-I", "-c", EXTRACT_SCRIPT, str(tar), str(tree)])
    return tar, tree


class Stack(Step):
    number, name = 9, "Stack"
    title, purpose, expect = "Starting anj-cloud", "builds the server, waits until healthy", "5–10 min"
    fix = "See `prod.py status`, fix the failing service, then run setup again (finished parts are kept)."

    def prod(self, *args, change=True, timeout=3600):
        tree = paths.RELEASE_SOURCE_DIR / self.setup.release[:12]
        argv = ["python3", str(tree / "deploy" / "prod.py"), *args]
        if change:
            return self.setup.change_as_anj(argv, timeout=timeout, cwd=str(tree), show_errors=True)
        return self.setup.as_anj(argv, timeout=timeout, cwd=str(tree))

    def tmpfiles_text(self):
        return render_template((SOURCE_DIR / "config" / "anj-cloud.tmpfiles").read_text(), self.setup.home)

    def pm2_dropin(self):
        name, text = next((k, v) for k, v in rendered_dropins(self.setup.home).items() if k.startswith("pm2-"))
        return SYSTEMD_DIR / name, text

    def admins(self):
        code, out, _ = self.setup.as_anj(["docker", "exec", "-i", "--user", f"{paths.GATEWAY_UID}:{paths.GATEWAY_GID}",
                                          ACCESS_CONTAINER, "python", "-c", ADMIN_SCRIPT], data="\n", timeout=60)
        try:
            return json.loads(out.strip().splitlines()[-1]) if code == 0 else None
        except (ValueError, IndexError):
            return None

    def live_443(self):
        """Local addresses listening on TCP 443 now (`ss -ltnH`, read-only), or None if unreadable.
        HAProxy bind-mounts one file whose inode an atomic write replaces, so a running HAProxy
        keeps its old bind until restarted: only the live listener shows what it serves (review R1)."""
        code, out, _ = self.system.read(["ss", "-ltnH", "sport = :443"])
        if code != 0:
            return None
        return sorted({fields[3].rsplit(":", 1)[0].strip("[]") for fields in (line.split() for line in out.splitlines())
                       if len(fields) >= 4})

    def serving(self):
        """HAProxy is meant to listen: the stack runs and no emergency stop holds it."""
        return self.setup.answers.get("start_stack", True) and not paths.EMERGENCY_STOP.exists()

    def consistency(self, stack):
        """The firewall's 443 accept, the recorded bind, the rendered HAProxy bind and the live
        443 listener are one address."""
        problems = []
        firewall = firewall_bind_address()
        rendered = re.search(r"^\s*bind\s+([0-9.]+):443\b", System.text(
            paths.RELEASE_DIR / (stack.get("release") or "x")[:12] / "haproxy.cfg") or "", re.M)
        addresses = {"firewall": firewall, "stack": stack.get("bind_address"),
                     "haproxy": rendered.group(1) if rendered else None}
        if len(set(addresses.values())) != 1:
            problems.append("443 bind differs (" + ", ".join(f"{k} {v}" for k, v in addresses.items()) + ")")
        if self.serving():
            live = self.live_443()
            if live is None:
                problems.append("443 listener unreadable (ss)")
            elif not live:
                problems.append("nothing listens on 443")
            elif live != [stack.get("bind_address")]:
                problems.append(f"443 listener {', '.join(live)} is not {stack.get('bind_address')} "
                                "(HAProxy runs an old configuration)")
        return problems

    def problems(self):
        problems = []
        a = self.setup.answers
        if System.text(TMPFILES_CONF) != self.tmpfiles_text():
            problems.append("tmpfiles")
        stack = json.loads(System.text(paths.STACK_CONFIG) or "{}")
        if not stack.get("host"):
            problems.append("prod.py setup")
            return problems
        for key in ("bind_address", "household_lan"):
            if stack.get(key) != a.get(key):
                problems.append(f"{key.replace('_', ' ')} changed")
        problems += self.consistency(stack)
        if self.setup.read_only and not pm2_running(self.system, self.setup.home):
            return problems + [f"PM2 not running (pm2-{paths.VM_USER}.service inactive)"]
        code, out, _ = self.prod("status", change=False, timeout=300)
        try:
            status = json.loads(out) if code == 0 else {}
        except ValueError:
            status = {}
        start = a.get("start_stack", True)
        if not start:
            current = paths.RELEASE_CURRENT
            if not current.is_symlink() or os.readlink(current) != self.setup.release[:12] or not \
                    (paths.BIN_DIR / "run-service").exists():
                problems.append("release not exported")
        if start:
            expected = [app for app in paths.STACK_APPS
                        if not (status.get("emergency_stop") and app in paths.EMERGENCY_APPS)]
            offline = [app for app in expected if (status.get("apps") or {}).get(app, {}).get("status") != "online"]
            if offline or status.get("healthcheck") != "ready":
                problems.append("apps not online: " + ", ".join(offline) if offline else "healthcheck not ready")
        if self.setup.mode == "install" and start and not problems:
            accounts = [row.get("uid") for row in (self.setup.operator("accounts", check=False) or [])]
            if any(uid not in accounts for uid in a["accounts"]):
                problems.append("accounts")
            admins = self.admins()
            if admins is None or (admins.get("table") and not admins.get("admins")) or (
                    admins.get("table") is False and not paths.ACCOUNTS_FILE.exists()):
                problems.append("first admin")
        dropin, text = self.pm2_dropin()
        if System.text(dropin) != text or not (SYSTEMD_DIR / f"pm2-{paths.VM_USER}.service").exists():
            problems.append("pm2 startup")
        elif start and self.system.read(["systemctl", "is-active", f"pm2-{paths.VM_USER}.service"])[1].strip() != "active":
            problems.append("pm2-anj.service not active")
        if not (Path(self.setup.home) / ".pm2" / "dump.pm2").exists() and start:
            problems.append("pm2 save")
        return problems

    def state(self):
        if not self.setup.release:
            Release(self.setup).resolve()
        problems = self.problems()
        if problems:
            return False, "to do: " + ", ".join(problems)
        return True, "stack healthy; accounts and first admin in place" if self.setup.mode == "install" \
            else "stack healthy (adopted state kept)"

    def plan(self):
        a = self.setup.answers
        lines = [f"{TMPFILES_CONF}: {paths.GATEWAY_SOCKET_DIR} 2750 10001:10002, {paths.HAPROXY_RUN_DIR} 0750 root:anj, "
                 f"{paths.CONSOLE_DIR} 2750 anj:10002",
                 f"prod.py setup --host {a['host']} --bind-address {a['bind_address']} --household-lan {a['household_lan']}",
                 "prod.py up (build, start the six PM2 apps, wait healthy, pm2 save)" if a.get("start_stack", True)
                 else "build and export the release without starting it (restore drill)"]
        if self.setup.mode == "install":
            lines += [f"accounts: user-add and account-set {', '.join(a['accounts'])}",
                      f"first admin: {a['accounts'][0]} (registry accounts table, one audit entry; else "
                      "state/accounts.json)"]
        lines += [f"pm2 startup systemd -u {paths.VM_USER}; drop-in RequiresMountsFor={paths.DATA_ROOT}; pm2 save"]
        return lines

    def apply(self):
        a = self.setup.answers
        anj = self.setup.user
        self.system.write(TMPFILES_CONF, self.tmpfiles_text())
        self.system.change(["systemd-tmpfiles", "--create", str(TMPFILES_CONF)])
        stack = json.loads(System.text(paths.STACK_CONFIG) or "{}")
        # The current answers win (spec #21 idempotence with changed settings): prod.py setup records
        # them and `up` re-renders HAProxy; a running HAProxy is restarted onto the new bind/LAN, so
        # the firewall (step 5, same answers) and HAProxy always agree. A host change is refused
        # before any step (it needs a new server certificate).
        changed = [key for key in ("bind_address", "household_lan") if stack.get(key) and stack[key] != a[key]]
        self.prod("setup", "--host", stack.get("host") or a["host"], "--bind-address", a["bind_address"],
                  "--household-lan", a["household_lan"])
        if a.get("start_stack", True):
            self.prod("up")
            # Restart HAProxy onto the current answers when they changed now, or when an earlier
            # run was interrupted between the re-render and the restart: then `changed` is empty
            # and only the live listener still shows the old address (review R1).
            live = self.live_443()
            stale = bool(live) and live != [a["bind_address"]] and not paths.EMERGENCY_STOP.exists()
            if (changed or stale) and "haproxy" in (pm2_list(self.setup) or {}):
                what = " and ".join(changed).replace("_", " ") if changed else "bind address (listener was stale)"
                self.setup.notes.append("HAProxy restarted onto the new " + what + ".")
                self.setup.change_as_anj(["pm2", "restart", "haproxy"], show_errors=True)
                self.prod("up")
        else:
            prepare = ("import sys; sys.path.insert(0, '.')\n"
                       "from deploy.prod import ProdStack\n"
                       "from deploy.vm import paths\n"
                       "s = ProdStack(paths.PROJECT, paths.STATE_ROOT).require_setup()\n"
                       "s.build(s.release); s.export_release(s.release); s.activate_release(s.release)\n")
            tree = paths.RELEASE_SOURCE_DIR / self.setup.release[:12]
            self.setup.change_as_anj(["python3", "-c", prepare], cwd=str(tree), timeout=3600, show_errors=True)
        if self.setup.mode == "install" and a.get("start_stack", True):
            self.accounts()
        unit = SYSTEMD_DIR / f"pm2-{anj}.service"
        if not unit.exists():
            self.system.change(["env", "PATH=/usr/local/bin:/usr/bin:/bin", "pm2", "startup", "systemd", "-u", anj,
                                "--hp", self.setup.home], show_errors=True)
        dropin, text = self.pm2_dropin()
        self.system.write(dropin, text)
        self.system.change(["systemctl", "daemon-reload"])
        if a.get("start_stack", True):
            self.setup.change_as_anj(["pm2", "save"])
            if self.system.read(["systemctl", "is-active", f"pm2-{anj}.service"])[1].strip() != "active":
                # The first install's PM2 daemon was started from this session; hand the saved stack
                # to pm2-anj.service (systemd) now, so it is supervised exactly as after a reboot.
                self.setup.change_as_anj(["pm2", "kill"])
                self.system.change(["systemctl", "start", f"pm2-{anj}.service"], show_errors=True)
                self.prod("up")

    def accounts(self):
        a = self.setup.answers
        names = a.get("display_names") or {}
        for uid in a["accounts"]:
            self.setup.operator_change("user-add", uid, "--display-name", names.get(uid, uid.capitalize()))
            known = {row.get("uid") for row in (self.setup.operator("accounts", check=False) or [])}
            if uid not in known:
                self.setup.operator_change("account-set", uid, "--display-name", names.get(uid, uid.capitalize()))
        first = a["accounts"][0]
        admins = self.admins()
        if admins is None:
            raise SetupError("The registry could not be read to record the first admin.", self.fix)
        if admins.get("table"):
            if not admins.get("admins"):
                # Decision #89 (9): the role is the registry accounts table's (spec #26 built it); no
                # gateway API sets it yet (spec #27 owns that API), so the bootstrap writes it once,
                # only while no admin exists, never demoting anyone.
                self.system.commands.append({"argv": ["docker", "exec", ACCESS_CONTAINER, "registry: admin", first]})
                code, out, _ = self.setup.as_anj(["docker", "exec", "-i", "--user",
                                                  f"{paths.GATEWAY_UID}:{paths.GATEWAY_GID}", ACCESS_CONTAINER,
                                                  "python", "-c", ADMIN_SCRIPT], data=first + "\n", timeout=60)
                written = json.loads(out.strip().splitlines()[-1]) if code == 0 and out.strip() else {}
                if first not in (written.get("admins") or []):
                    raise SetupError("The first admin could not be recorded.", self.fix)
                if written.get("granted") and not written.get("audited"):
                    self.setup.warn("The registry has no admin audit table; the first admin grant is not audited.")
        elif not paths.ACCOUNTS_FILE.exists():
            self.system.write(paths.ACCOUNTS_FILE, json.dumps({"admins": [first]}) + "\n", mode=0o600, owner=self.setup.user)
        # The first pairing code is no longer issued here: pairing is the install's last phase (M2).


class Operations(Step):
    number, name = 10, "Operations apps"
    title, purpose, expect = "Starting alerts and monitoring", "", "under 1 min"

    def apps(self):
        start = self.setup.answers.get("start_stack", True)
        apps = ops_apps(paths.STATE_ROOT, paths.RELEASE_CURRENT, start_stack=start)
        if start:
            apps += self.ddns_apps()
        return apps

    def ddns_apps(self):
        # The answer goes in on stdin: nothing is written, so doctor stays read-only.
        code, out, _ = self.system.read(["python3", "-I", str(ROOT / "deploy" / "ddns.py"), "pm2-app", "--source-dir",
                                         str(paths.RELEASE_CURRENT), "--answers", "/dev/stdin"],
                                        data=f'ddns = "{self.setup.answers["ddns"]}"\n')
        if code != 0:
            raise SetupError("The DDNS service entry could not be prepared.", self.fix)
        apps = json.loads(out)
        zone = self.setup.answers.get("zone_id", DEFAULT_ZONE_ID)
        for app in apps:
            # Always explicit: the VM has no deployment profile, so ddns.py's own default is a placeholder.
            if zone:
                app["args"] = f"{app.get('args', 'run')} --zone-id {zone}"
            app["cwd"] = app.get("cwd") or str(paths.RELEASE_CURRENT)
        return apps

    def ops_config(self):
        return ops_config_text(self.setup.answers)

    def problems(self):
        problems = []
        source = System.text(paths.RELEASE_CURRENT / "deploy" / "vm" / "ops" / "anj-alert")
        if source is None or System.text(paths.ALERT_COMMAND) != source:
            problems.append("dispatcher")
        if System.text(OPS_CONFIG) != self.ops_config():
            problems.append("ops.json")
        if not paths.NTFY_TOPIC.exists():
            problems.append("ntfy topic")
        if self.setup.answers["ddns"] == "on" and not paths.CLOUDFLARE_TOKEN.exists():
            problems.append("DNS token")
        if not COMMAND_LINK.is_symlink() or os.readlink(COMMAND_LINK) != str(COMMAND_TARGET):
            problems.append("command " + str(COMMAND_LINK))
        if self.setup.answers.get("start_stack", True) and (
                not ADMIN_LINK.is_symlink() or os.readlink(ADMIN_LINK) != str(ADMIN_TARGET)):
            problems.append("command " + str(ADMIN_LINK))
        apps = self.apps()
        if System.text(OPS_ECOSYSTEM) != ecosystem_text(apps):
            problems.append("ecosystem")
        running = pm2_list(self.setup)
        if running is None:
            return problems + ["PM2 not running"]
        recorded = self.setup.record.get("ops_apps", {})
        for app in apps:
            if app["name"] not in running or recorded.get(app["name"]) != app_digest(app):
                problems.append("app " + app["name"])
            elif app["name"] != paths.DDNS_APP and running[app["name"]] != "online":
                problems.append("app " + app["name"] + " " + str(running[app["name"]]))
        if self.setup.answers["ddns"] == "off" and paths.DDNS_APP in running:
            problems.append("ddns app to remove")
        return problems

    def state(self):
        if not self.setup.release:
            Release(self.setup).resolve()
        problems = self.problems()
        return (not problems), ("to do: " + ", ".join(problems)) if problems else \
            "alerts, " + ("watchdog, watchers, console" if self.setup.answers.get("start_stack", True) else "no stack apps") + \
            (", ddns" if self.setup.answers["ddns"] == "on" else "; ddns off")

    def plan(self):
        a = self.setup.answers
        return [f"{paths.ALERT_COMMAND} (0700 {paths.VM_USER}) from deploy/vm/ops/anj-alert",
                f"{COMMAND_LINK} -> {COMMAND_TARGET} (every printed command is `sudo anj-cloud-setup …`)",
                *([f"{ADMIN_LINK} -> {ADMIN_TARGET} (recovery CLI, run as {paths.VM_USER})"]
                  if a.get("start_stack", True) else []),
                f"{paths.NTFY_TOPIC} (0600; generated, 32 characters)" if not paths.NTFY_TOPIC.exists()
                else "ntfy topic kept",
                (f"{paths.CLOUDFLARE_TOKEN} (0600, from the hidden prompt or token_file)"
                 if a["ddns"] == "on" else "DDNS off: no ddns app"),
                f"{OPS_ECOSYSTEM}: " + ", ".join(app["name"] for app in self.apps()),
                "pm2 start (only missing or changed apps); pm2 save"]

    def apply(self):
        anj = self.setup.user
        self.setup.install_dispatcher(paths.RELEASE_CURRENT)
        if not COMMAND_LINK.is_symlink() or os.readlink(COMMAND_LINK) != str(COMMAND_TARGET):
            self.system.symlink(COMMAND_TARGET, COMMAND_LINK)
        if self.setup.answers.get("start_stack", True) and (
                not ADMIN_LINK.is_symlink() or os.readlink(ADMIN_LINK) != str(ADMIN_TARGET)):
            self.system.symlink(ADMIN_TARGET, ADMIN_LINK)
        self.system.mkdir(paths.SECRETS_DIR, mode=0o700, owner=anj)
        if not paths.NTFY_TOPIC.exists():
            self.system.write(paths.NTFY_TOPIC, self.setup.secrets["topic"] + "\n", mode=0o600, owner=anj, secret=True)
            self.setup.topic_new = True
        if self.setup.secrets.get("token") and not paths.CLOUDFLARE_TOKEN.exists():
            self.system.write(paths.CLOUDFLARE_TOKEN, self.setup.secrets["token"] + "\n", mode=0o600, owner=anj,
                              secret=True)
        apps = self.apps()
        self.system.mkdir(OPS_ECOSYSTEM.parent, mode=0o700, owner=anj)
        self.system.write(OPS_ECOSYSTEM, ecosystem_text(apps), mode=0o600, owner=anj)
        running = pm2_list(self.setup) or {}
        recorded = dict(self.setup.record.get("ops_apps", {}))
        for app in apps:
            name = app["name"]
            if name in running and recorded.get(name) == app_digest(app) and (
                    name == paths.DDNS_APP or running[name] == "online"):
                continue
            if name in running:
                self.setup.change_as_anj(["pm2", "delete", name])
            self.setup.change_as_anj(["pm2", "start", str(OPS_ECOSYSTEM), "--only", name], show_errors=True)
            recorded[name] = app_digest(app)
        if self.setup.answers["ddns"] == "off" and paths.DDNS_APP in running:
            self.setup.change_as_anj(["pm2", "delete", paths.DDNS_APP])
            recorded.pop(paths.DDNS_APP, None)
        self.setup.save_record(ops_apps=recorded)
        self.setup.change_as_anj(["pm2", "save"])


def ops_config_text(answers):
    config = {key: answers[key] for key in ("alerts_tag", "ntfy_server") if answers.get(key)}
    return json.dumps(config, indent=2, sort_keys=True) + "\n"


def pm2_running(system, home):
    """True only while pm2-anj.service runs a live PM2 daemon. Any `pm2` command connects to (and
    would otherwise spawn) a daemon, so read-only paths call pm2 only when this holds."""
    if system.read(["systemctl", "is-active", f"pm2-{paths.VM_USER}.service"])[1].strip() != "active":
        return False
    try:
        pid = int((Path(home) / ".pm2" / "pm2.pid").read_text().strip())
    except (OSError, ValueError):
        return False
    return Path(f"/proc/{pid}").exists()


def pm2_list(setup):
    if setup.read_only and not pm2_running(setup.system, setup.home):
        return None
    code, out, _ = setup.as_anj(["pm2", "jlist"], timeout=60)
    try:
        rows = jlist_rows(out) if code == 0 else None
    except ValueError:
        return None
    return None if rows is None else {row.get("name"): (row.get("pm2_env") or {}).get("status") for row in rows}


class Timers(Step):
    number, name = 11, "Timers"
    title, purpose, expect = "Scheduling backups, reboots and checks", "", "under 1 min"

    def backup(self):
        if not self.setup.backup_units:
            code, out, _ = self.system.read(["python3", "-I", str(ROOT / "deploy" / "backup.py"), "units", "--source",
                                             str(paths.RELEASE_CURRENT)], user=self.setup.user, cwd="/")
            if code != 0:
                raise SetupError("The backup timers could not be prepared.", self.fix)
            self.setup.backup_units = json.loads(out)["units"]
        return self.setup.backup_units

    def units(self):
        return rendered_units(self.setup.home, self.backup())

    def state(self):
        problems = []
        if self.facts.timezone() != self.setup.answers["timezone"]:
            problems.append("timezone")
        for name, text in self.units().items():
            if System.text(SYSTEMD_DIR / name) != text:
                problems.append(name)
        if not problems:
            _code, out, _ = self.system.read(["systemctl", "is-enabled", *ENABLED_UNITS])
            if any(line.strip() != "enabled" for line in out.splitlines()) or len(out.splitlines()) != len(ENABLED_UNITS):
                problems.append("units not enabled")
            _code, out, _ = self.system.read(["systemctl", "is-active", *TIMERS])
            if any(line.strip() != "active" for line in out.splitlines()):
                problems.append("timers not active")
        return (not problems), ("to do: " + ", ".join(problems)) if problems else \
            f"time zone {self.setup.answers['timezone']}; boot health, reboot guard 04:15, image check weekly, backup 03:30"

    def plan(self):
        return [f"timedatectl set-timezone {self.setup.answers['timezone']}"] + \
               [f"{SYSTEMD_DIR}/{name}" for name in self.units()] + \
               ["systemctl enable " + " ".join(ENABLED_UNITS) + "; start the timers", "systemd-analyze verify"]

    def apply(self):
        if self.facts.timezone() != self.setup.answers["timezone"]:
            self.system.change(["timedatectl", "set-timezone", self.setup.answers["timezone"]], show_errors=True)
            self.facts._cache.clear()
        for name, text in self.units().items():
            self.system.write(SYSTEMD_DIR / name, text)
        self.system.change(["systemctl", "daemon-reload"])
        self.system.change(["systemctl", "enable", *ENABLED_UNITS])
        self.system.change(["systemctl", "start", *TIMERS])

    def verify(self):
        done, current = self.state()
        if not done:
            return False, current
        code, _out, err = self.system.read(["systemd-analyze", "verify", *(str(SYSTEMD_DIR / n) for n in self.units())],
                                           timeout=120)
        if code != 0:
            return False, "systemd-analyze verify: " + (err.strip().splitlines() or ["failed"])[-1][:200]
        return True, current + "; units verified"


class Updates(Step):
    number, name = 12, "Updates"
    title, purpose, expect = "Turning on security updates", "security fixes only, no automatic reboot", "1–2 min"

    def files(self):
        docker_repo = bool(self.facts.installed("docker-ce"))
        uu = (SOURCE_DIR / "config" / "52anj-cloud-unattended-upgrades").read_text().replace(
            "@EXTRA_ORIGINS@", DOCKER_ORIGIN if docker_repo else "")
        files = {APT_UU_CONF: uu, APT_PERIODIC_CONF: (SOURCE_DIR / "config" / "21anj-cloud-periodic").read_text(),
                 LOGROTATE_CONF: render_template((SOURCE_DIR / "config" / "anj-cloud-pm2.logrotate").read_text(),
                                                 self.setup.home)}
        for name, text in rendered_dropins(self.setup.home).items():
            if name.startswith("apt-daily-upgrade"):
                files[SYSTEMD_DIR / name] = text
        return files

    def state(self):
        stale = [str(path) for path, text in self.files().items() if System.text(path) != text]
        return (not stale), ("to write: " + ", ".join(stale)) if stale else \
            "security origins only; update run after 04:10, skipped while a backup or restore runs"

    def plan(self):
        return [str(path) for path in self.files()] + ["systemctl daemon-reload; restart apt-daily-upgrade.timer",
                                                       "unattended-upgrade --dry-run lists only security origins"]

    def apply(self):
        for path, text in self.files().items():
            self.system.write(path, text)
        self.system.change(["systemctl", "daemon-reload"])
        self.system.change(["systemctl", "restart", "apt-daily-upgrade.timer"])

    def verify_read_only(self, current, allowed):
        return _verify_updates_read_only(self, current, allowed)

    def verify(self):
        done, current = self.state()
        if not done:
            return False, current
        allowed = {"Debian-Security"} | ({"Docker CE"} if self.facts.installed("docker-ce") else set())
        if self.setup.read_only:
            return self.verify_read_only(current, allowed)
        code, out, err = self.system.read(["unattended-upgrade", "--dry-run", "--debug"], timeout=900)
        origins = allowed_origins(out + "\n" + err)
        labels = {label for _origin, label in origins}
        if code != 0 or not origins or not labels <= allowed:
            return False, f"unattended-upgrade origins: {sorted(labels) or 'unreadable'}"
        return True, current + "; origins " + ", ".join(sorted(labels))


UU_LOG = Path("/var/log/unattended-upgrades/unattended-upgrades.log")


def configured_origins(text):
    """[(origin, label)] of Unattended-Upgrade::Origins-Pattern in `apt-config dump` output."""
    result = []
    for line in text.splitlines():
        match = re.match(r'Unattended-Upgrade::Origins-Pattern:: "(.*)";', line.strip())
        if match:
            fields = dict(part.split("=", 1) for part in match.group(1).split(",") if "=" in part)
            result.append((fields.get("origin", ""), fields.get("label", "")))
    return result


def allowed_origins(text):
    """[(origin, label)] from unattended-upgrade --debug: "Allowed origins are: a, b" (Debian 13's
    unattended-upgrades 2.12, seen on anj-qual) or the older list repr "['a', 'b']"."""
    match = re.search(r"Allowed origins are: (.*)", text)
    if not match:
        return []
    listed = match.group(1).strip()
    if listed.startswith("["):
        items = re.findall(r"'([^']*)'", listed)
    else:
        items = [item.strip() for item in listed.split(", ") if "=" in item]
    result = []
    for item in items:
        fields = dict(part.split("=", 1) for part in item.split(",") if "=" in part)
        result.append((fields.get("origin", ""), fields.get("label", "")))
    return result


# status and doctor -------------------------------------------------------------------------

def _verify_updates_read_only(step, current, allowed):
    """doctor: the configured origins (`apt-config dump`) and the last run's log; nothing runs apt."""
    code, out, _ = step.system.read(["apt-config", "dump"])
    labels = {label for _origin, label in configured_origins(out)} if code == 0 else set()
    if not labels or not labels <= allowed:
        return False, f"configured origins: {sorted(labels) or 'unreadable'}"
    if 'Unattended-Upgrade::Automatic-Reboot "false";' not in out:
        return False, "Automatic-Reboot is not false"
    logged = allowed_origins("\n".join((System.text(UU_LOG) or "").splitlines()[-400:]))
    last = {label for _origin, label in logged}
    if last and not last <= allowed:
        return False, f"last run used origins {sorted(last)}"
    return True, current + "; configured " + ", ".join(sorted(labels)) + \
        ("; last run " + ", ".join(sorted(last)) if last else "; no run logged yet")


class Status:
    """Read-only facts; runs as anj (directly, or from root through runuser)."""

    def __init__(self, system, facts):
        self.system, self.facts = system, facts

    def anj(self, argv, **options):
        user = paths.VM_USER if os.geteuid() == 0 else None
        if os.geteuid() != 0 and pwd.getpwuid(os.geteuid()).pw_name != paths.VM_USER:
            return 126, "", "not anj"
        return self.system.read(argv, user=user, **options)

    def collect(self):
        stack = json.loads(System.text(paths.STACK_CONFIG) or "{}") if os.access(paths.STATE_ROOT, os.X_OK) else {}
        result = {"hostname": socket.gethostname(), "host": stack.get("host"), "vm_address": stack.get("bind_address"),
                  "release": (stack.get("release") or "")[:12] or None}
        home = (self.facts.user() or pwd.getpwnam("root")).pw_dir
        running = pm2_running(self.system, home)
        code, out, _ = self.anj(["pm2", "jlist"], timeout=60) if running else (1, "", "")
        try:
            result["apps"] = {row.get("name"): (row.get("pm2_env") or {}).get("status") for row in jlist_rows(out)} \
                if code == 0 else ("unreadable (run as anj or root)" if running else
                                   f"PM2 not running (pm2-{paths.VM_USER}.service inactive)")
        except ValueError:
            result["apps"] = "unreadable"
        if stack.get("release") and running:
            tree = paths.RELEASE_CURRENT
            code, out, _ = self.anj(["python3", str(tree / "deploy" / "prod.py"), "status"], timeout=300, cwd=str(tree))
            try:
                status = json.loads(out) if code == 0 else {}
            except ValueError:
                status = {}
            result["healthcheck"] = status.get("healthcheck", "unavailable")
            result["emergency_stop"] = status.get("emergency_stop")
            code, out, _ = self.anj(["python3", "-I", str(tree / "deploy" / "backup.py"), "status"], timeout=120)
            try:
                backup = json.loads(out) if code == 0 else {}
            except ValueError:
                backup = {}
            last = (backup.get("last_success") or {}) if isinstance(backup.get("last_success"), dict) else {}
            result["backup"] = (f"last success {last.get('finished_at')}" if last.get("finished_at")
                                else "not set up or never succeeded" if backup else "unavailable")
        ddns = json.loads(System.text(paths.DDNS_STATE) or "null") if os.access(paths.RUN_DIR, os.X_OK) else None
        if isinstance(ddns, dict):
            result["ddns"] = (f"last success {datetime.datetime.fromtimestamp(ddns['last_success']).isoformat(timespec='minutes')}"
                              if ddns.get("last_success") else "no success yet") + \
                             (f", {ddns.get('failures')} consecutive failures" if ddns.get("failures") else "")
        else:
            result["ddns"] = "off or not run yet"
        result["update"] = update_state()
        code, _, _ = self.system.read(["nft", "list", "table", "inet", "anj_cloud"])
        result["firewall"] = "loaded" if code == 0 else ("missing" if os.geteuid() == 0 else "unknown (needs root)")
        try:
            usage = shutil.disk_usage(paths.DATA_ROOT)
            result["data_disk_used"] = f"{100 * usage.used // max(usage.total, 1)}%"
        except OSError:
            result["data_disk_used"] = "not mounted"
        return result


def update_state(proc=Path("/proc")):
    """`status`: a release switch running now (prod.py redeploy, which holds the operations lock),
    else the last recorded upgrade (setup.json, when readable)."""
    for entry in proc.iterdir():
        if not entry.name.isdigit():
            continue
        try:
            words = (entry / "cmdline").read_bytes().split(b"\0")
        except OSError:
            continue
        names = [Path(word.decode("utf-8", "replace")).name for word in words[:3]]
        if "prod.py" in names and b"redeploy" in words:
            target = words[words.index(b"redeploy") + 1].decode("utf-8", "replace")[:12] \
                if words.index(b"redeploy") + 1 < len(words) else "?"
            return f"running now (to {target}; prod.py redeploy, pid {entry.name})"
    try:
        last = json.loads(SETUP_RECORD.read_text()).get("last_upgrade") or {}
    except (OSError, ValueError, AttributeError):
        return "-"
    if not last:
        return "-"
    return f"last {'rollback' if last.get('rollback') else 'upgrade'} {last.get('from')} -> {last.get('to')} at {last.get('at')}"


def render_status(status):
    lines = [f"Hostname        {status.get('hostname')}  ({status.get('host') or 'not set up'})",
             f"VM address      {status.get('vm_address') or '-'}",
             f"Release         {status.get('release') or '-'}"]
    apps = status.get("apps")
    if isinstance(apps, dict):
        lines.append("PM2 apps        " + ", ".join(f"{name} {state}" for name, state in sorted(apps.items())))
    else:
        lines.append(f"PM2 apps        {apps}")
    lines += [f"Healthcheck     {status.get('healthcheck', '-')}" +
              (" (emergency stop in place)" if status.get("emergency_stop") else ""),
              f"Backup          {status.get('backup', '-')}", f"DDNS            {status.get('ddns', '-')}",
              f"Update          {status.get('update', '-')}",
              f"Firewall        {status.get('firewall')}", f"Data disk used  {status.get('data_disk_used')}"]
    return "\n".join(lines)


def doctor(setup):
    """Preflight plus every step's verification; read-only. Returns [(check, problem, fix)]."""
    problems = []
    stack = json.loads(System.text(paths.STACK_CONFIG) or "{}")
    setup.answers = {"host": stack.get("host") or DEFAULT_HOST, "ddns": "on" if paths.CLOUDFLARE_TOKEN.exists() else "off",
                     "bind_address": stack.get("bind_address") or paths.DEFAULT_BIND_ADDRESS,
                     "household_lan": stack.get("household_lan") or paths.DEFAULT_HOUSEHOLD_LAN,
                     "admin_ssh_source": firewall_admin_source() or setup.facts.default_route()[1] or "10.77.10.1",
                     "timezone": setup.record.get("timezone") or setup.facts.timezone(),
                     "accounts": setup.record.get("accounts") or list(DEFAULT_ACCOUNTS), "start_stack": True,
                     "zone_id": DEFAULT_ZONE_ID}
    setup.answers.update(setup.record.get("answers") or {})
    for name, problem, fix in preflight(setup.facts, setup.answers, mode="adopt", root=True, existing_install=True):
        if name in ("port-443", "data-disk"):
            continue
        problems.append((name, problem, fix))
    for step in setup.step_list():
        if isinstance(step, (Ssh, Restore)):
            continue
        try:
            ok, detail = step.verify()
        except (SetupError, OSError, ValueError, KeyError) as error:
            ok, detail = False, str(error)
        if not ok:
            problems.append((step.name, f"Step {step.number} {step.name}: {detail}",
                             f"Run `sudo {setup_command()}` (re-runs fix only what is missing)."))
    status = Status(setup.system, setup.facts).collect()
    apps = status.get("apps") if isinstance(status.get("apps"), dict) else {}
    for app, state in sorted(apps.items()):
        if app != paths.DDNS_APP and state != "online" and not (status.get("emergency_stop") and app in paths.EMERGENCY_APPS):
            problems.append(("app", f"PM2 app {app} is {state}.", f"`pm2 restart {app}` as {paths.VM_USER}; "
                             f"`pm2 logs {app}` shows why."))
    if status.get("firewall") == "missing":
        problems.append(("firewall", "The firewall table inet anj_cloud is not loaded.",
                         "`sudo systemctl restart anj-cloud-firewall.service`"))
    try:
        usage = shutil.disk_usage(paths.DATA_ROOT)
        if usage.used / max(usage.total, 1) > 0.9:
            problems.append(("data-disk", f"The data disk is {100 * usage.used // usage.total}% full.",
                             "Free space (old releases in /srv/anj-cloud/release, Docker images: `docker image prune`) "
                             "or enlarge the data disk."))
    except OSError:
        problems.append(("data-disk", f"{paths.DATA_ROOT} is not mounted.", "`sudo mount /srv/anj-cloud`, then check `lsblk`."))
    admins = Stack(setup).admins() if apps else None
    if admins is not None:
        count = len(admins.get("admins") or []) if admins.get("table") else None
        if count == 0:
            problems.append(("admins", "No enabled admin account exists.",
                             "Make an admin again over SSH from the VM host with the recovery command (deploy/README.md, recovery CLI)."))
        setup.notes.append(f"enabled admins: {count if count is not None else 'accounts.json fallback'}")
    return problems, status


def firewall_bind_address():
    match = re.search(r"ip daddr (\S+) tcp dport 443", System.text(FIREWALL_FILE) or "")
    return match.group(1) if match else None


def firewall_admin_source():
    match = re.search(r"ip saddr (\S+) tcp dport 22", System.text(FIREWALL_FILE) or "")
    return match.group(1) if match else None


# first-code --reissue ----------------------------------------------------------------------

def reissue(setup):
    """`first-code --reissue` (kept for scripts and the qualification rows) = `pair --new-code`
    without waiting: the unused code is denied, a new one issued, shown once or put in the 0600 file."""
    invite = setup.record.get("first_invite")
    uid = setup.first_account()
    if not uid:
        raise SetupError("This install recorded no first account.", "Run the install first.")
    if invite:
        row = setup.invitation_state(invite["id"])
        if row and row.get("state") in ("issued", "reserved", "provisioning"):
            setup.operator_change("deny", invite["id"])
    setup.issue_first_code(uid)
    setup.system.remove(paths.FIRST_PAIRING_CODE)    # the replaced code's file never outlives it
    setup.show_code(uid)
    if setup.tty():
        setup.say("  The previous code no longer works.")
    return 0


# upgrade and upgrade --rollback (decision #122) -----------------------------------------------

UPGRADE_LOCK = Path("/run/lock/anj-cloud-upgrade.lock")
UPGRADE_TIMEOUT = 3600          # the build and health waits; the watchdog's own bound is 15 min (#113)
FALLBACK_GRACE = 1800           # after SIGTERM at the timeout: prod.py's own fallback restarts the old release
BACKUP_TIMEOUT = 3600           # backup.py run: its 30-minute window cap plus housekeeping
BACKUP_FRESH = 24 * 3600        # a successful backup younger than this needs no new one before an update
UPGRADE_LOG_DIR = FALLBACK_LOG_DIR      # root 0700: prod.py redeploy's output (it carries no secret)


def prod_takes_source(tree):
    """Whether a release tree's prod.py has `redeploy --source` (releases before #122 do not)."""
    return "--source" in (System.text(Path(tree) / "deploy" / "prod.py") or "")


def setup_has_upgrade(tree):
    """Whether a release tree's anj-cloud-setup knows `upgrade` (releases before #122 do not)."""
    return '"upgrade"' in (System.text(Path(tree) / "deploy" / "vm" / "bootstrap.py") or "")


def lock_held(path):
    """True while another process holds an flock on `path` (never creates it)."""
    try:
        fd = os.open(path, os.O_RDWR | os.O_NOFOLLOW)
    except OSError:
        return False
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return True
    finally:
        os.close(fd)
    return False


def ops_busy():
    """Why a backup, a restore or a release switch is running now (review M3), or None. A
    redeploy and a backup hold the operations lock (state/run/backup.lock), a restore restore.lock;
    the backup and restore markers count while they exist."""
    if not os.access(paths.RUN_DIR, os.X_OK):
        return None
    if lock_held(paths.OPS_LOCK):
        return "a backup or a release switch is running (backup.lock is held)"
    if lock_held(paths.RESTORE_LOCK):
        return "a restore is running (restore.lock is held)"
    for marker in (paths.BACKUP_IN_PROGRESS, paths.RESTORE_IN_PROGRESS):
        try:
            deadline = float(json.loads(marker.read_text()).get("deadline_epoch", 0))
        except (OSError, ValueError, AttributeError, TypeError):
            continue                          # absent, or unreadable: suppresses nothing (as the watchdog)
        if deadline >= time.time():
            return f"{marker.name} is set until {datetime.datetime.fromtimestamp(deadline).isoformat(timespec='minutes')}"
    return None


class Upgrade:
    """Switch the live release to another one through prod.py redeploy's health-checked path.

    upgrade:            the source staged from the VM host (stage.py --upgrade --expect <sha>; --source for
                        a tar) becomes release/<commit12> exactly as step 8 lays it out, then
                        `prod.py redeploy <commit> --source <its tar>` builds, exports and verifies
                        it, installs its state/bin, restarts the stack onto it, switches
                        release/current only after a healthy check and restarts console, watchdog
                        and watchers (#114, extended with #122; ddns starts the new release on its
                        next 5-minute run). The previous release stays in place.
    upgrade --rollback: the same path back to stack.json's previous_release (or, when the last
                        switch did not finish, to the release that is live).

    First a backup when backups are set up and the last success is older than 24 hours (review
    H2 (1)); `--no-backup` skips it with a warning. prod.py runs in its own session without a
    terminal, so Ctrl-C or a dropped ssh never reaches it: it finishes, or falls back by itself
    (review H1). Upgrading to the live release is a no-op. Secrets, accounts, the data disk and
    every other step's work are never touched. The running command is maintenance to the watchdog
    (`anj-cloud-setup` with a changing command, bounded at 15 minutes, decision #113)."""

    def __init__(self, setup):
        self.setup = setup
        self.system = setup.system

    @staticmethod
    def stack():
        return json.loads(System.text(paths.STACK_CONFIG) or "{}")

    @staticmethod
    def live():
        try:
            return os.readlink(paths.RELEASE_CURRENT)
        except OSError:
            return None

    def live_commit(self):
        """The full commit release/current names (its release.json), or None."""
        name = self.live()
        try:
            commit = json.loads(System.text(paths.RELEASE_DIR / (name or "x") / "release.json") or "{}").get("commit")
        except ValueError:
            return None
        return commit if isinstance(commit, str) and COMMIT.fullmatch(commit) and commit[:12] == name else None

    def target(self, rollback, source, expect):
        """(commit, tar, checkout) of the release to switch to."""
        if rollback:
            stack, live = self.stack(), self.live_commit()
            if live and stack.get("release") != live:
                # The last switch did not finish (review L2): back to what is live, not two back.
                commit = live
                self.setup.say(f"The last update to {(stack.get('release') or '-')[:12]} did not finish; rolling back "
                               f"to the live release {live[:12]}.")
            else:
                commit = stack.get("previous_release")
            if not commit or not COMMIT.fullmatch(commit):
                raise SetupError("No previous release is recorded, so there is nothing to roll back to.",
                                 "Update to the wanted release from the VM host instead: deploy/vm/stage.py <vm> --commit "
                                 "<sha> --upgrade.")
            tar, _tree = release_paths(commit)
            if not tar.is_file():
                raise SetupError(f"The previous release's source ({tar}) is missing.",
                                 f"Stage it again from the VM host: deploy/vm/stage.py <vm> --commit {commit[:12]} --upgrade.")
            return commit, tar, None
        if source is None and not (STAGE_TAR.is_file() and str(ROOT).startswith(str(STAGE_SRC))):
            raise SetupError("Nothing is staged to upgrade to: `upgrade` installs the release that deploy/vm/stage.py "
                             "staged, and runs from that staged copy.",
                             "On the VM host, from a clean checkout: python3 deploy/vm/stage.py <vm> --commit <sha> --upgrade "
                             "(it stages the release and runs this for you).")
        commit, tar, checkout = resolve_source(source)
        if expect and commit != expect:
            # Review L4: the staged tar is not what the VM host staged now (a failed or concurrent stage).
            raise SetupError(f"The staged release is {commit[:12]}, not the expected {expect[:12]}; nothing was changed.",
                             f"Stage it again from the VM host: deploy/vm/stage.py <vm> --commit {expect[:12]} --upgrade.")
        return commit, tar, checkout

    def runner_tree(self, rollback, tree):
        """The prod.py that drives the switch: the new release's own (upgrade), else the live one
        (rollback to a release older than `--source`); whichever has `redeploy --source`."""
        live = Path(os.path.realpath(paths.RELEASE_CURRENT))
        for candidate in ((live, tree) if rollback else (tree, live)):
            if prod_takes_source(candidate):
                return candidate
        raise SetupError("Neither the live release nor the target has `prod.py redeploy --source`.",
                         "Update from the VM host with deploy/vm/stage.py <vm> --commit <sha> --upgrade.")

    def refresh_dispatcher(self):
        """state/bin/anj-alert is a copy of the live release's dispatcher (step 10): refresh it and
        restart `alerts` only when the new release changed it."""
        source = paths.RELEASE_CURRENT / "deploy" / "vm" / "ops" / "anj-alert"
        data = Path(source).read_bytes() if Path(source).is_file() else None
        if data is None or (Path(paths.ALERT_COMMAND).is_file() and Path(paths.ALERT_COMMAND).read_bytes() == data):
            return "unchanged"
        self.system.write(paths.ALERT_COMMAND, data, mode=0o700, owner=self.setup.user)
        if "alerts" in (pm2_list(self.setup) or {}):
            self.setup.change_as_anj(["pm2", "restart", "alerts"], check=False)
            return "updated, alerts restarted"
        return "updated"

    # Backup first (review H2 (1)) -------------------------------------------------------------
    def last_backup_age(self):
        """Seconds since spec #22's last successful backup, or None (never, or unreadable)."""
        code, out, _ = self.setup.as_anj(["python3", "-I", str(paths.RELEASE_CURRENT / "deploy" / "backup.py"),
                                          "status"], timeout=120)
        try:
            last = (json.loads(out) if code == 0 else {}).get("last_success") or {}
            finished = datetime.datetime.fromisoformat(last["finished_at"])
        except (ValueError, KeyError, TypeError, AttributeError):
            return None
        if finished.tzinfo is None:
            finished = finished.replace(tzinfo=datetime.timezone.utc)
        return (datetime.datetime.now(datetime.timezone.utc) - finished).total_seconds()

    def backup_first(self, skip):
        setup = self.setup
        if setup.backup_state() != "set up":
            setup.say("⚠ Backups are not set up on this server: updating without a backup. "
                      f"(Set them up: sudo {setup_command()} backup)")
            return "not set up"
        if skip:
            setup.say("⚠ --no-backup: updating without a fresh backup. A release that migrates data can then only "
                      "be undone from an older backup.")
            return "skipped (--no-backup)"
        age = self.last_backup_age()
        if age is not None and age < BACKUP_FRESH:
            setup.say(f"  Last successful backup {guide.duration(age)} ago: no new backup needed.")
            return "recent"
        setup.say("  Backing up first (" + ("no successful backup yet" if age is None else
                                            f"last success {guide.duration(age)} ago") + ") — usually 5–30 min")
        # Detached like the switch (delta review D2): a dropped session must not kill a backup that
        # has Nextcloud in maintenance; backup.py turns SIGTERM (the timeout) into its own cleanup.
        stamp = utc_stamp()
        logs = (UPGRADE_LOG_DIR / f"backup-{stamp}.out", UPGRADE_LOG_DIR / f"backup-{stamp}.err")
        try:
            with guide.Heartbeat(setup.say):
                code, _out, err = self.system.detached(
                    ["python3", "-I", str(paths.RELEASE_CURRENT / "deploy" / "backup.py"), "run"], user=setup.user,
                    cwd=str(paths.STATE_ROOT), timeout=BACKUP_TIMEOUT, grace=600, logs=logs)
        except KeyboardInterrupt:
            raise SetupError("Stopped waiting for the backup; it is still running in the VM and nothing was updated.",
                             f"Run the upgrade again when it has finished (`{setup_command()} status`).") from None
        if code != 0:
            raise SetupError("The backup before the update failed, so nothing was updated.",
                             "See `python3 /srv/anj-cloud/release/current/deploy/backup.py status` (as anj) and fix it; "
                             f"or update without a fresh backup: sudo {setup_command()} upgrade --no-backup.")
        return "done"

    # The switch ---------------------------------------------------------------------------------
    def run(self, rollback=False, source=None, expect=None, no_backup=False):
        setup = self.setup
        load_installed_answers(setup)
        if (setup.record.get("answers") or {}).get("start_stack") is False:
            raise SetupError("This install does not run the stack (start_stack = false), so there is nothing to update.",
                             "Run the install with the stack started first.")
        UPGRADE_LOCK.parent.mkdir(parents=True, exist_ok=True)
        with open(UPGRADE_LOCK, "w") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise SetupError("Another upgrade or rollback is running.", "Wait for it to finish.") from None
            return self.switch(rollback, source, expect, no_backup)

    def switch(self, rollback, source, expect, no_backup):
        setup = self.setup
        command = "upgrade --rollback" if rollback else "upgrade"
        busy = ops_busy()
        if busy:
            raise SetupError(f"Not now: {busy}. Nothing was changed.", "Run it again when that has finished.")
        commit, tar, checkout = self.target(rollback, source, expect)
        setup.release = commit
        stack, live = self.stack(), self.live()
        before = live or (stack.get("release") or "-")[:12]
        if stack.get("release") == commit and live == commit[:12]:
            setup.say(f"Release {commit[:12]} is already live on {setup.answers.get('host')}; nothing to do.")
            setup.write_evidence("already current", quiet=True, command=command)
            return 0
        verb = "Rolling back" if rollback else "Updating"
        setup.say(f"{verb} {setup.answers.get('host')}: release {before} -> {commit[:12]}")
        backup = self.backup_first(no_backup)
        live_commit = self.live_commit()
        protected = {c for c in (live_commit, stack.get("release"), stack.get("previous_release")) if c}
        state_tar, tree = install_release_source(setup, commit, tar, checkout, replace_stale=commit not in protected)
        runner = self.runner_tree(rollback, tree)
        setup.say("  Building and checking it, then restarting the stack onto it; the live release switches only "
                  "after a healthy check — usually 2–10 min. It runs on in the VM if this session ends.")
        stamp = utc_stamp()
        logs = (UPGRADE_LOG_DIR / f"upgrade-{stamp}.out", UPGRADE_LOG_DIR / f"upgrade-{stamp}.err")
        argv = ["python3", str(runner / "deploy" / "prod.py"), "redeploy", commit, "--source", str(state_tar)]
        try:
            with guide.Heartbeat(setup.say) as beat:
                code, out, err = self.system.detached(argv, user=setup.user, cwd=str(runner), timeout=UPGRADE_TIMEOUT,
                                                      grace=FALLBACK_GRACE, logs=logs)
                elapsed = beat.elapsed()
        except KeyboardInterrupt:
            setup.say("\nStopped waiting. The upgrade is still running in the VM (it finishes, or falls back to "
                      f"{before} by itself); see `{setup_command()} status`. Output: {logs[1]}")
            setup.write_evidence("waiting interrupted", quiet=True, command=command, target=commit, logs=[str(p) for p in logs])
            return 130
        if code != 0:
            return self.failed(command, verb, commit, before, code, err, elapsed, logs)
        try:
            result = json.loads(out)
        except ValueError:
            result = {}
        dispatcher = self.refresh_dispatcher()
        previous = (result.get("previous_release") or before)[:12]
        setup.save_record(release=commit, last_upgrade={
            "from": previous, "to": commit[:12], "rollback": rollback,
            "at": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")})
        operations = result.get("operations") or {}
        setup.say(f"\nRelease {commit[:12]} is live and healthy (was {previous}; {guide.duration(elapsed)}).")
        if operations:
            setup.say("  Operations apps: " + ", ".join(f"{app} {state}" for app, state in sorted(operations.items())))
        if dispatcher != "unchanged":
            setup.say(f"  Alert dispatcher: {dispatcher}")
        if setup_has_upgrade(paths.RELEASE_CURRENT):
            setup.say(f"  Release {previous} is kept: `sudo {setup_command()} upgrade --rollback` switches back.")
        else:
            # Review L1: this release predates `upgrade`; forward again only by re-staging.
            setup.say(f"  Release {previous} is kept. This release has no `upgrade` command: to go forward again, on the VM host "
                      f"run `deploy/vm/stage.py <vm> --commit {previous} --upgrade`.")
        setup.write_evidence("rolled back" if rollback else "upgraded", quiet=False, command=command,
                             previous=previous, operations=operations, dispatcher=dispatcher, backup=backup)
        return 0

    def failed(self, command, verb, commit, before, code, err, elapsed, logs):
        setup = self.setup
        lines = (err or "").strip().splitlines()
        reason = next((line[len("ERROR: "):] for line in reversed(lines) if line.startswith("ERROR: ")), None)
        alerted = any(re.fullmatch(r"ALERT: redeploy-failed (dispatcher|spool)", line) for line in lines)
        now = self.live() or before
        if code == 124:
            setup.say(f"\n{verb} did not finish within {guide.duration(UPGRADE_TIMEOUT)}; it was stopped and fell back "
                      "if it could. The state is unknown: check it before anything else.")
            setup.say(f"Next: `{setup_command()} status`, and `python3 {paths.RELEASE_CURRENT}/deploy/prod.py status` "
                      f"as {paths.VM_USER}. Output: {logs[1]}")
            setup.write_evidence("timed out", quiet=False, command=command, target=commit, live=now)
            return 1
        reason = reason or f"prod.py redeploy exit {code}"
        setup.say(f"\n{verb} failed after {guide.duration(elapsed)}: {reason[:400]}")
        setup.say(f"The live release is still {now}; nothing switched." +
                  (" An alert was sent." if alerted else " No alert was sent (prod.py stopped before it could)."))
        setup.say(f"Next: `{setup_command()} status`, and `python3 {paths.RELEASE_CURRENT}/deploy/prod.py "
                  f"status` as {paths.VM_USER}. Output: {logs[1]}")
        setup.write_evidence("failed", quiet=False, command=command, target=commit, live=now, error=reason[:400],
                             alerted=alerted)
        return 1


def render_summary_status(status, answers, backup):
    """C-22: the status block in plain words (ddns `stopped` between runs is normal)."""
    apps = status.get("apps") if isinstance(status.get("apps"), dict) else {}
    idle = apps.get(paths.DDNS_APP) == "stopped"
    running = [name for name, state in apps.items() if state == "online" or (name == paths.DDNS_APP and idle)]
    server = "ready" if status.get("healthcheck") == "ready" else f"⚠ {status.get('healthcheck', 'unknown')}"
    if status.get("emergency_stop"):
        server += " (emergency stop in place)"
    firewall = {"loaded": "on", "missing": "⚠ OFF"}.get(status.get("firewall"), str(status.get("firewall")))
    if answers.get("ddns") != "on":
        ddns = "off"
    elif "last success" in str(status.get("ddns")):
        ddns = f"checks every 5 minutes — {status['ddns']}"
    else:
        ddns = "checks every 5 minutes — first update pending"
    if backup == "set up":
        backups = status.get("backup") if "last success" in str(status.get("backup")) else \
            "⚠ repository initialized — mandatory first backup required"
    elif backup == "ready":
        backups = "⚠ not set up yet (next: Backups, below)"
    else:
        backups = "⚠ not possible yet: the backup drive is not attached"
    services = (f"{len(running)} of {len(apps)} running" + (" (ddns idle between runs — normal)" if idle else "")
                if apps else str(status.get("apps")))
    return "\n".join([f"  Server        {server:<16} Firewall   {firewall}", f"  DNS (DDNS)    {ddns}",
                      f"  Backups       {backups}", f"  Data disk     {status.get('data_disk_used')} used",
                      f"  Services      {services}"])


# CLI ---------------------------------------------------------------------------------------

def parser():
    p = argparse.ArgumentParser(prog="anj-cloud-setup", description=__doc__.split("\n\n", 2)[0] + "\n\n" +
                                __doc__.split("\n\n", 2)[1],
                                formatter_class=argparse.RawDescriptionHelpFormatter,
                                epilog="Answers file keys: " + ", ".join(sorted(ANSWER_KEYS)))
    p.add_argument("command", nargs="?", default="install",
                   choices=("install", "pair", "backup", "status", "doctor", "first-code", "upgrade"),
                   help="install (default), pair, backup, status, doctor, upgrade [--rollback]; first-code --reissue "
                        "(= pair --new-code, no waiting)")
    p.add_argument("--dry-run", action="store_true", help="Plan only: change nothing, ask no secret")
    p.add_argument("--answers", help="Non-interactive: TOML answers file (secrets only by file path)")
    p.add_argument("--adopt-data", action="store_true", help="Rebuild onto an existing anj-cloud data disk")
    p.add_argument("--restore-from", help=f"Rebuild from the backup share ({paths.BACKUP_MOUNT})")
    p.add_argument("--source", help="Release source: a tar made with git archive, or a git checkout (install, upgrade)")
    p.add_argument("--host", help="Public hostname (overrides the answers file)")
    p.add_argument("--ddns", choices=("on", "off"), help="DDNS on or off (overrides the answers file)")
    p.add_argument("--data-disk", help="Data disk device (overrides the answers file)")
    p.add_argument("--json", action="store_true", help="status: JSON")
    p.add_argument("--new-code", action="store_true", help="pair: replace the first device's pairing code")
    p.add_argument("--show-password", action="store_true", help="backup: show the backup password again")
    p.add_argument("--reissue", action="store_true", help="first-code: replace the first admin pairing code")
    p.add_argument("--rollback", action="store_true", help="upgrade: switch back to the previous release")
    p.add_argument("--no-backup", action="store_true", help="upgrade: skip the backup before the switch (warns)")
    p.add_argument("--expect", help=argparse.SUPPRESS)          # stage.py --upgrade: the commit it staged (review L4)
    p.add_argument("--secrets-socket", help=argparse.SUPPRESS)   # stage.py --with-secrets (decision #109)
    return p


def discard_staged(path):
    """L-3: a hand-off socket this run will not read is removed at once, so stage.py reports the
    secrets as not used (nothing was sent) instead of the socket lingering."""
    if path and guide.STAGED_SOCKET.fullmatch(str(path)):
        try:
            if stat.S_ISSOCK(os.lstat(path).st_mode):
                os.unlink(path)
        except OSError:
            pass


def load_installed_answers(setup):
    """pair and backup on a finished install: the recorded answers (host, bind address, accounts)."""
    stack = json.loads(System.text(paths.STACK_CONFIG) or "{}") if os.access(paths.STATE_ROOT, os.X_OK) else {}
    if not stack.get("host"):
        raise SetupError("anj-cloud is not installed on this machine yet.", f"Run the install first: sudo {setup_command()}")
    setup.answers = dict(setup.record.get("answers") or {}, host=stack["host"],
                         bind_address=stack.get("bind_address"), accounts=setup.record.get("accounts") or [])


def backup_command(setup, show_password):
    if os.geteuid() != 0:
        raise SetupError("backup needs root.", f"Run it with sudo: sudo {setup_command()} backup")
    if not sys.stdin.isatty():
        raise SetupError("backup needs a terminal: the password is shown only there.", "Run it in a terminal (ssh -t).")
    load_installed_answers(setup)
    state = setup.backup_state()
    if show_password:
        if state != "set up":
            raise SetupError("Backups are not set up yet, so there is no password to show.",
                             f"Set them up: sudo {setup_command()} backup")
        return 0 if setup.run_backup(["show-password"]) is not None else 1
    if state == "set up":
        setup.say(f"Backups are already set up. To see the password again: sudo {setup_command()} backup --show-password")
        return 0
    if state == "no share":
        setup.say(guide.no_share_text(setup.on_halo(), setup_command()))
        return 1
    setup.say("Set up encrypted backups: one password protects every backup on the backup drive.")
    return setup.setup_backups()


def main(argv=None, *, system=None, facts=None, prompter=None, out=sys.stdout):
    args = parser().parse_args(argv)
    for stream in (sys.stdout, sys.stderr):
        # The guided copy uses ✓, ⚠ and box lines: a terminal without UTF-8 shows "?", never a crash.
        try:
            stream.reconfigure(errors="replace")
        except (AttributeError, ValueError):
            pass
    if args.adopt_data and args.restore_from:
        parser().error("--adopt-data and --restore-from exclude each other")
    setup = Setup(args, system=system, facts=facts, prompter=prompter, out=out)
    if args.command != "install":
        discard_staged(args.secrets_socket)          # only an install reads the hand-off
    try:
        if args.command == "status":
            status = Status(setup.system, setup.facts).collect()
            setup.say(json.dumps(status, indent=2, sort_keys=True) if args.json else render_status(status))
            return 0
        if args.command == "doctor":
            setup.system.dry = True     # read-only by construction: any change is refused
            setup.read_only = True      # and nothing that spawns (pm2) or writes caches (apt)
            problems, _status = doctor(setup)
            for _name, problem, fix in problems:
                setup.say(f"PROBLEM {problem}\n  Fix: {fix}")
            for note in setup.notes:
                setup.say(f"Note: {note}")
            setup.say("doctor: all checks pass" if not problems else f"doctor: {len(problems)} problem(s)")
            return 0 if not problems else 1
        if args.command == "first-code":
            if not args.reissue:
                parser().error("first-code takes --reissue")
            if os.geteuid() != 0:
                raise SetupError("first-code needs root.", "Run it with sudo.")
            return reissue(setup)
        if args.command == "pair":
            if os.geteuid() != 0:
                raise SetupError("pair needs root.", f"Run it with sudo: sudo {setup_command()} pair")
            load_installed_answers(setup)
            return setup.pair(new_code=args.new_code, standalone=True)
        if args.command == "backup":
            return backup_command(setup, args.show_password)
        if args.command == "upgrade":
            if args.dry_run or args.answers or args.adopt_data or args.restore_from:
                parser().error("upgrade takes only --rollback or --source")
            if args.rollback and (args.source or args.expect):
                parser().error("--rollback switches to the recorded previous release; it takes no --source")
            if args.expect and not COMMIT.fullmatch(args.expect):
                parser().error("--expect takes a full commit id")
            if os.geteuid() != 0:
                raise SetupError("upgrade needs root.", f"Run it with sudo: sudo {setup_command()} upgrade")
            setup.mode = "upgrade"
            return Upgrade(setup).run(rollback=args.rollback, source=args.source, expect=args.expect,
                                      no_backup=args.no_backup)
        if args.rollback or args.no_backup or args.expect:
            parser().error("--rollback, --no-backup and --expect belong to upgrade")
        if args.dry_run:
            # Review R3: strictly read-only, like doctor. No pm2 (which starts a daemon), no
            # prod.py status, no unattended-upgrade run; System(dry=True) skips every change.
            setup.read_only = True
        if os.geteuid() != 0 and not args.dry_run:
            raise SetupError("Setup changes the system and must run as root.",
                             f"Run it with sudo: `sudo {setup_command()}`.")
        return setup.run()
    except SetupError as error:
        setup.say(f"anj-cloud-setup: {error}")
        if error.fix:
            setup.say(f"Fix: {error.fix}")
        return 1
    except KeyboardInterrupt:
        if args.command == "upgrade":
            setup.say("\nInterrupted before the switch started; nothing was switched. Run the upgrade again "
                      "(on the VM host: deploy/vm/stage.py <vm> --commit <sha> --upgrade).")
        else:
            setup.say("\nInterrupted; run setup again to continue (finished steps are kept).")
        return 130
