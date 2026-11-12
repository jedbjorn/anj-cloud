#!/usr/bin/env python3
"""Encrypted onsite backup, restore and restore drill for the anj-cloud production VM (spec #22 rev7).

Inside the anj-prod VM (user anj):

    python3 deploy/backup.py init [--show-escrow | --adopt]
    python3 deploy/backup.py show-password                # the escrowed password again, on the terminal only
    python3 deploy/backup.py seed --cap <minutes>        # one-off first full backup, operator-scheduled
    python3 deploy/backup.py run                          # nightly: anj-cloud-backup.timer, 03:30, 30-minute cap
    python3 deploy/backup.py check [--read-data-subset]
    python3 deploy/backup.py status [--alert-stale]       # hourly: anj-cloud-backup-stale.timer
    python3 deploy/backup.py window --check               # exit 0 clear, 1 busy (update run, reboot guard)
    python3 deploy/backup.py restore --snapshot <id|latest> --target <empty dir> --project <name> --state-root <dir>
    python3 deploy/backup.py drill-checks                 # inside a drill VM, after the restore
    python3 deploy/backup.py units [--source DIR]         # unit files for spec #21's bootstrap (release/current)

On the VM host (The VM host parent):

    python3 deploy/backup.py drill                        # rebuild anj-qual, restore into it, check, destroy;
                                                          # unattended: password piped VM to VM (#95)

Restic runs as a one-off container (pinned by digest) with --network none, every source read-only,
--cap-drop ALL plus DAC_READ_SEARCH, DAC_OVERRIDE and FOWNER (restic is the container's root, guest
root under the VM's rootful Docker, and must write the anj-owned /repo and /cache, its only writable
mounts), and a 2 GiB / 256-pid bound. The repository lives at
/mnt/anj-backup/restic, the virtiofs share of DOS_BACKUP/anj-cloud-prod/ (decision #84); the VM can
reach nothing else on the drive. Output is JSON; it never carries file paths, file names or secrets.
"""

import argparse
import contextlib
from datetime import datetime, timedelta, timezone
import fcntl
import getpass
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from deploy.vm import paths  # noqa: E402  spec #20's interface constants; never redefined here
from deploy.vm.pm2json import jlist_rows  # noqa: E402

PROJECT = paths.PROJECT
RESTORE_PROJECT = "anj-cloud-restore"
DEFAULT_STATE_ROOT = paths.STATE_ROOT
CACHE_HOME = Path.home() / ".cache" / "anj-cloud-backup"
QUALIFICATION = Path.home() / ".local" / "share" / "anj-cloud" / "qualification"
UNIT_TEMPLATES = Path(__file__).resolve().parent / "vm" / "systemd"
DRILL_BLACKOUT = ((3, 20), (5, 0))     # the drill never runs between 03:20 and 05:00 local (spec #22 rev7)
RESTORE_DEADLINE = timedelta(hours=8)
LAST_RESTORE = "last-restore.json"     # in the state root's run/, read by drill-checks  # restore marker deadline; longer than any restore step's timeout

RESTIC_IMAGE = "restic/restic:0.18.1@sha256:39d9072fb5651c80d75c7a811612eb60b4c06b32ffe87c2e9f3c7222e1797e76"
CAP_MINUTES = 30
MARGIN_BYTES = 10 * 1000**3            # space kept free beyond the estimated increment
CAPACITY_MIN_FREE = 20 * 1000**3       # alert below 20 GB free
CAPACITY_MAX_USED = 0.80               # alert above 80 % used
STALE_HOURS = 36                       # no successful backup in 36 h -> one alert (decision #69 (d))
RETENTION = ("--keep-daily", "7", "--keep-weekly", "4", "--keep-monthly", "6")
PRUNE_EVERY = timedelta(days=7)
CHECK_EVERY = timedelta(days=7)
READ_CHECK_EVERY = timedelta(days=30)
FORGET_EVERY = timedelta(days=1)
# Forget, prune and check need no maintenance: they run after the window, under the backup lock
# (so `window --check` stays busy), with their own deadline at 04:10 local, before the 04:15
# guarded reboot (coordinator ruling on the PR #38 review; decision #86).
HOUSEKEEPING_END = (4, 10)
HOUSEKEEPING_MAX = timedelta(hours=6)  # a seed or manual run at another hour is bounded too
OVERDUE_GRACE = timedelta(days=8)      # one alert once any of them is more than 8 days overdue
HOUSEKEEPING_PERIODS = {"forget": FORGET_EVERY, "prune": PRUNE_EVERY, "check": CHECK_EVERY,
                        "read_check": READ_CHECK_EVERY}
READ_SUBSET = "5%"
CONTAINER_UID = paths.GATEWAY_UID
# Every one-off container is bounded: the VM has 4 GiB, the VM host's user slice is shared.
LIMITS = ("--memory", "2g", "--pids-limit", "256")
# restic runs as the container's root. Under the VM's rootful Docker that is guest root, while the
# cache (on the VM disk) and the repository (on the share) belong to anj: DAC_READ_SEARCH alone
# reads everything but writes nothing there. DAC_OVERRIDE and FOWNER let restic create its files
# and set them read-only; its only writable mounts are /repo and /cache (sources are mounted ro).
# On the share, the VM host's virtiofsd wrapper turns guest root into the share's owner, so every
# repository file is anj's in the VM and anj-cloud-backup's on the VM host (decision #115).
RESTIC_CAPS = ("DAC_READ_SEARCH", "DAC_OVERRIDE", "FOWNER")
GATEWAY_USER = f"{CONTAINER_UID}:{CONTAINER_UID}"

PROJECT_NAME = re.compile(r"anj-cloud-[a-z0-9][a-z0-9-]{0,30}")
DEV_PROJECT = re.compile(r"anj-cloud-dev(-[a-z0-9-]+)?")
SCRATCH_PROJECT = re.compile(r"anj-cloud-(review|test)(-[a-z0-9]+)*")
SNAPSHOT_ID = re.compile(r"[0-9a-f]{8,64}")
SHARE_TAG = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,35}")
# Volumes restored and recreated; Redis is excluded (a restored stack starts empty) and
# access-tls (older spec A layouts) is regenerated from the operator directory; removed if present.
RESTORED_VOLUMES = ("nextcloud", "access", "database")
REPLACED_VOLUMES = ("nextcloud", "access", "database", "redis", "access-tls")
# State-root entries that belong to this host's backup setup, never moved by a restore.
STATE_LOCAL = {"run", "bin", "backup.json", "backup-status.json"}
RESTIC_EXCLUDES = (
    "/backup/state/run",
    "/backup/state/bin",
    "/backup/state/backup-status.json",
    "/backup/state/secrets/restic-password",
    # Spec #21's one-time secrets: the first pairing code (10 minutes) and the ntfy subscribe link
    # written when setup had no terminal; never kept in a snapshot.
    "/backup/state/secrets/first-pairing-code",
    "/backup/state/secrets/ntfy-subscribe-link",
    "/backup/access/registry.sqlite",
    "/backup/access/registry.sqlite-*",
    "/backup/access/*.sock",
    # Published client releases (spec #28 G1) are kept, so a restored server still serves the
    # current update; an upload still in progress is not.
    "/backup/access/releases/.incoming",
)
MANIFEST_VERSION = 1

SECRET_NAME = paths.RESTIC_PASSWORD.name


# Small helpers --------------------------------------------------------------------------

def utcnow(clock=time.time):
    return datetime.fromtimestamp(clock(), timezone.utc)


def iso(moment):
    return moment.astimezone(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def parse_iso(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00")) if value else None


def stamp(moment):
    return moment.astimezone(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def inside_git_worktree(path):
    path = Path(path)
    return any(os.path.lexists(candidate / ".git") for candidate in (path, *path.parents))


def private_directory(path):
    path = Path(path)
    if path.is_symlink():
        raise BackupError(f"Refusing symlink directory: {path.name}")
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
        raise BackupError(f"Directory must be owned by this user: {path.name}")
    path.chmod(0o700)
    return path


def atomic_write(path, data, mode=0o600):
    path = Path(path)
    temporary = path.with_name("." + path.name + ".tmp")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, mode)
    with os.fdopen(fd, "wb" if isinstance(data, bytes) else "w") as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())
    os.chmod(temporary, mode)
    os.replace(temporary, path)


def write_json(path, data):
    atomic_write(path, json.dumps(data, indent=2, sort_keys=True) + "\n")


def read_json(path, default=None):
    try:
        return json.loads(Path(path).read_text())
    except FileNotFoundError:
        return default


def checked_directory(path, label, *, create=False, must_exist=True):
    """Absolute, not a symlink, outside every git worktree; created 0700 when asked."""
    if path is None:
        raise BackupError(f"{label} is required")
    path = Path(path).expanduser()
    if not path.is_absolute():
        raise BackupError(f"{label} must be an absolute path")
    path = Path(os.path.normpath(path))
    if path.is_symlink():
        raise BackupError(f"{label} must not be a symlink")
    if inside_git_worktree(path) or inside_git_worktree(path.resolve()):
        raise BackupError(f"{label} must be outside every git worktree")
    if path.exists():
        info = path.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
            raise BackupError(f"{label} must be a directory owned by this user")
        if info.st_mode & 0o077:
            raise BackupError(f"{label} mode is looser than 0700")
    elif create:
        private_directory(path)
    elif must_exist:
        raise BackupError(f"{label} does not exist")
    return path


def validate_project(project, *, purpose):
    if not project or not PROJECT_NAME.fullmatch(project):
        raise BackupError("Project must start anj-cloud- and contain lowercase letters, digits and hyphens")
    if DEV_PROJECT.fullmatch(project):
        raise BackupError("Development projects are never backup or restore targets")
    if purpose == "backup" and project != PROJECT and not SCRATCH_PROJECT.fullmatch(project):
        raise BackupError("Backups cover anj-cloud-prod, or a disposable review/test project")
    if purpose == "drill" and project != RESTORE_PROJECT and not SCRATCH_PROJECT.fullmatch(project):
        raise BackupError("The drill restores into anj-cloud-restore (or a disposable review/test project)")
    return project


class BackupError(RuntimeError):
    """A curated failure. `reason` is the alert class; the message never holds paths or secrets."""

    def __init__(self, message, reason="failed"):
        super().__init__(message)
        self.reason = reason


class Preflight(BackupError):
    pass


class Capped(BackupError):
    def __init__(self, message="Maintenance window reached its hard cap"):
        super().__init__(message, "cap-reached")


class RepositoryLocked(BackupError):
    def __init__(self):
        super().__init__("Restic repository is locked exclusively (prune in progress); retry after it finishes",
                         "repository-locked")


# Command runner -------------------------------------------------------------------------

class CommandFailed(BackupError):
    def __init__(self, argv, returncode, stderr=b""):
        # Diagnostics stay private: command output can name files or carry configuration. Only the
        # synthetic qualification sets ANJ_BACKUP_DIAGNOSTICS; the timers and operators never do.
        message = f"Command failed (exit {returncode}); output withheld: {' '.join(argv[:2])}"
        if os.environ.get("ANJ_BACKUP_DIAGNOSTICS") == "synthetic-only" and stderr:
            message += " | " + stderr[-400:].decode(errors="replace").strip()
        super().__init__(message)
        self.returncode = returncode
        self.stderr = stderr or b""


class Runner:
    """Runs host commands. Tests substitute a fake with the same three methods."""

    def run(self, argv, *, data=None, timeout=600, stdout=None, check=True):
        try:
            result = subprocess.run(argv, input=data, stdout=stdout or subprocess.PIPE, stderr=subprocess.PIPE,
                                    timeout=timeout, check=False)
        except subprocess.TimeoutExpired:
            raise
        if check and result.returncode:
            raise CommandFailed(argv, result.returncode, result.stderr)
        return result

    def popen(self, argv):
        return subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    def pipe(self, producer, consumer, *, timeout=300):
        """producer | consumer, connected directly; this process never sees the bytes."""
        first = subprocess.Popen(producer, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        try:
            second = subprocess.Popen(consumer, stdin=first.stdout, stdout=subprocess.DEVNULL,
                                      stderr=subprocess.DEVNULL)
            first.stdout.close()
            try:
                second.wait(timeout=timeout)
                first.wait(timeout=30)
            except subprocess.TimeoutExpired:
                second.kill()
                first.kill()
                second.wait()
                first.wait()
                return False
            return first.returncode == 0 and second.returncode == 0
        finally:
            if first.poll() is None:
                first.kill()
                first.wait()

    def sleep(self, seconds):
        time.sleep(seconds)


def restic_error(error):
    """Map restic's stderr to a curated class; never echo it."""
    text = getattr(error, "stderr", b"") or b""
    if b"locked exclusively" in text or b"unable to create lock" in text or b"repository is already locked" in text:
        return RepositoryLocked()
    if b"wrong password" in text or b"no key found" in text:
        return BackupError("Restic rejected the repository password", "wrong-password")
    if b"Is there a repository at the following location" in text or b"repository does not exist" in text:
        return Preflight("No restic repository at the recorded location", "wrong-repository")
    return error


# Alerts ---------------------------------------------------------------------------------

class Alerter:
    """Spec B's ntfy dispatcher. Messages carry no file names, codes or secrets.

    Calling convention: spec #21's `anj-alert --key <key> -- <message>` (paths.ALERT_COMMAND).
    The command is recorded in backup.json (`alert_command`) at init.
    """

    def __init__(self, command, runner, record):
        self.command = command
        self.runner = runner
        self.record = record

    def send(self, key, message):
        entry = {"key": key, "message": message, "at": iso(utcnow()), "delivered": False}
        if self.command:
            try:
                self.runner.run([*self.command, "--key", key, "--", message], timeout=60)
                entry["delivered"] = True
            except (BackupError, OSError, subprocess.TimeoutExpired):
                entry["delivered"] = False
        # One journal line per alert so spec B's watchers can also see it.
        print(json.dumps({"event": "alert", "key": key, "delivered": entry["delivered"]}), file=sys.stderr, flush=True)
        self.record(entry)
        return entry["delivered"]


# The backup -----------------------------------------------------------------------------

REGISTRY_SNAPSHOT = r'''
import hashlib, json, os, sqlite3, sys
os.umask(0o077)
root = "/var/lib/anj"
stage = os.path.join(root, "backup-staging")
if sys.argv[1] == "clean":
    for name in ("registry.sqlite", "registry.sqlite.tmp"):
        try:
            os.unlink(os.path.join(stage, name))
        except FileNotFoundError:
            pass
    try:
        os.rmdir(stage)
    except FileNotFoundError:
        pass
    print("{}")
    raise SystemExit(0)
if sys.argv[1] == "snapshot":
    os.makedirs(stage, mode=0o700, exist_ok=True)
    target = os.path.join(stage, "registry.sqlite")
    temporary = target + ".tmp"
    if os.path.exists(temporary):
        os.unlink(temporary)
    source = sqlite3.connect("file:" + os.path.join(root, "registry.sqlite") + "?mode=ro", uri=True)
    copy = sqlite3.connect(temporary)
    source.backup(copy)
    source.close()
else:
    target = os.path.join(root, sys.argv[2])
    copy = sqlite3.connect("file:" + target + "?mode=ro", uri=True)
ok = copy.execute("PRAGMA integrity_check").fetchone()[0] == "ok"
rows = [list(row) for row in copy.execute(
    "SELECT id, uid, state, fingerprint, certificate_id, certificate FROM devices ORDER BY id")]
for row in rows:
    row[5] = hashlib.sha256((row[5] or "").encode()).hexdigest()
tables = {name for (name,) in copy.execute("SELECT name FROM sqlite_master WHERE type='table'")}
leaves = copy.execute("SELECT count(*) FROM device_leaves").fetchone()[0] if "device_leaves" in tables else None
added = copy.execute("SELECT count(*) FROM files_added").fetchone()[0] if "files_added" in tables else None
copy.close()
if sys.argv[1] == "snapshot":
    os.replace(temporary, target)
print(json.dumps({"integrity": ok, "devices": len(rows), "device_leaves": leaves, "files_added": added,
                  "digest": hashlib.sha256(json.dumps(rows).encode()).hexdigest()}))
'''

SENTINEL_QUERY = (
    "SELECT f.fileid, substr(s.id, 7), f.path FROM {p}filecache f JOIN {p}storages s ON s.numeric_id = f.storage "
    "WHERE s.id LIKE 'home::%' AND f.path LIKE 'files/%' AND f.size > 0 "
    "AND strpos(f.path, chr(10)) = 0 AND strpos(f.path, chr(9)) = 0 "
    "AND f.mimetype <> (SELECT id FROM {p}mimetypes WHERE mimetype = 'httpd/unix-directory') "
    "ORDER BY f.fileid DESC LIMIT 1")
SENTINEL_BY_ID = (
    "SELECT f.fileid, substr(s.id, 7), f.path FROM {p}filecache f JOIN {p}storages s ON s.numeric_id = f.storage "
    "WHERE f.fileid = {fileid}")
# Reads one path from stdin so it never appears in an argument list or a log.
HASH_STDIN = 'IFS= read -r p; sha256sum -- "$p" | cut -d" " -f1'
UNMAINTAIN = r'''
$file = '/var/www/html/config/config.php';
include $file;
$CONFIG['maintenance'] = false;
$temporary = $file . '.anj-restore';
file_put_contents($temporary, "<?php\n\$CONFIG = " . var_export($CONFIG, true) . ";\n");
chmod($temporary, fileperms($file) & 0777);
rename($temporary, $file);
echo "{}";
'''


class Backup:
    def __init__(self, project=PROJECT, state_root=None, *, runner=None, clock=time.time, cache_home=CACHE_HOME,
                 out=None, tz=None):
        self.project = validate_project(project, purpose="backup")
        if state_root is None:
            if project != PROJECT:
                raise BackupError("--state-root is required for a review or test project")
            state_root = DEFAULT_STATE_ROOT
        self.state_root = checked_directory(state_root, "--state-root", create=False)
        # Marker names are spec #20's (paths.py); a review state root keeps the same layout.
        self.run_dir = self.state_root / paths.RUN_DIR.name
        self.marker_path = self.run_dir / paths.BACKUP_IN_PROGRESS.name
        self.restore_marker_path = self.run_dir / paths.RESTORE_IN_PROGRESS.name
        self.lock_path = self.run_dir / "backup.lock"
        self.restore_lock_path = self.run_dir / "restore.lock"
        self.config_path = self.state_root / paths.BACKUP_RECORD.name
        self.status_path = self.state_root / "backup-status.json"
        self.password_file = self.state_root / paths.SECRETS_DIR.name / SECRET_NAME
        self.runner = runner or Runner()
        self.clock = clock
        self.cache_dir = Path(cache_home) / self.project
        self.tz = tz  # None: the VM's local time zone
        self.out = out or sys.stdout
        self.config = read_json(self.config_path, {}) or {}
        self.status = read_json(self.status_path, {}) or {}
        self.alerter = Alerter(self.config.get("alert_command"), self.runner, self._record_alert)

    # State ------------------------------------------------------------------------------

    def now(self):
        return utcnow(self.clock)

    def _record_alert(self, entry):
        alerts = self.status.setdefault("alerts", [])
        alerts.append(entry)
        del alerts[:-20]
        self.save_status()

    def save_status(self):
        private_directory(self.run_dir)
        write_json(self.status_path, self.status)

    def save_config(self):
        write_json(self.config_path, self.config)

    @property
    def target(self):
        targets = self.config.get("targets") or []
        if len(targets) != 1:
            raise BackupError("No backup target recorded; run init first", "not-initialized")
        return targets[0]

    def repository_path(self, target=None):
        """paths.RESTIC_REPOSITORY in production; <scratch mount>/restic for review projects."""
        target = target or self.target
        return Path(target["mount"]) / paths.RESTIC_REPOSITORY.name

    @contextlib.contextmanager
    def lock(self, path=None):
        private_directory(self.run_dir)
        fd = os.open(path or self.lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise BackupError("Another backup operation holds the lock", "busy") from None
            yield
        finally:
            os.close(fd)

    def lock_held(self, path=None):
        path = path or self.lock_path
        if not path.exists():
            return False
        fd = os.open(path, os.O_RDWR | os.O_NOFOLLOW)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return True
        finally:
            os.close(fd)
        return False

    # Markers (read by spec #21's watchdog, update run and reboot guard) ----------------

    def write_marker(self, kind, run_id, deadline, started=None, path=None):
        private_directory(self.run_dir)
        write_json(path or self.marker_path, {
            "version": 1, "project": self.project, "kind": kind, "run_id": run_id, "pid": os.getpid(),
            "started_at": iso(started or self.now()), "deadline": iso(deadline),
            "deadline_epoch": int(deadline.timestamp())})

    def read_marker(self, path=None):
        try:
            marker = read_json(path or self.marker_path)
        except (ValueError, OSError):
            return {"run_id": "unreadable", "deadline_epoch": 0}
        return marker

    def clear_marker(self):
        with contextlib.suppress(FileNotFoundError):
            self.marker_path.unlink()

    # Share and repository -------------------------------------------------------------

    def findmnt(self, mount):
        result = self.runner.run(["findmnt", "--json", "--mountpoint", str(mount), "--output",
                                  "TARGET,SOURCE,FSTYPE,OPTIONS"], timeout=30, check=False)
        if result.returncode:
            return []
        try:
            entries = json.loads(result.stdout or b"{}").get("filesystems", [])
        except ValueError:
            return []
        return [entry for entry in entries if entry.get("target") == str(mount) and entry.get("fstype") != "autofs"]

    def check_share(self, target, *, repository=True, writable=True, probe=False):
        """The backup target is the virtiofs share with the recorded tag (decision #84), never a
        directory on the VM's own disks. The drive's UUID is the VM host's check (spec #21): the VM
        cannot see the block device. Returns whether the share is read-only.

        Backups (writable=True) need the repository lock and refuse a share mounted `ro`. Read
        paths (writable=False) accept a read-only share. Only a caller that would take a restic
        lock otherwise (restore) asks for `probe`: then a share that refuses an actual write is
        read-only too (SC-067: a share the VM host serves read-only, libvirt <readonly/>, can still be
        mounted `rw` in the guest, so mount options alone never prove restic could write its
        lock). init --adopt never probes: it writes nothing to the share."""
        mount = Path(target["mount"])
        entries = self.findmnt(mount)
        if not entries:
            raise Preflight("Backup share is not mounted", "share-absent")
        entry = entries[-1]
        try:
            on_root = entry.get("target") == "/" or os.stat(mount).st_dev == self.root_device()
        except OSError:
            raise Preflight("Backup share is not reachable", "share-absent") from None
        if on_root:
            raise Preflight("Backup mount point is on the VM's own disk", "share-absent")
        if entry.get("fstype") != "virtiofs":
            raise Preflight("Backup mount is not a virtiofs share", "not-virtiofs")
        if entry.get("source") != target["tag"]:
            raise Preflight("Backup share has an unexpected virtiofs tag", "wrong-tag")
        read_only = "ro" in (entry.get("options") or "").split(",")
        if writable and read_only:
            raise Preflight("Backup share is mounted read-only", "share-read-only")
        if repository:
            path = self.repository_path(target)
            try:
                info = path.lstat()
            except FileNotFoundError:
                raise Preflight("Recorded repository directory is missing on the share", "wrong-repository") from None
            # Ownership on a virtiofs share follows the VM host's mapping (spec #21; decision #115: guest
            # anj is the share owner anj-cloud-backup); only refuse links and directories others
            # could write.
            if not stat.S_ISDIR(info.st_mode) or info.st_mode & 0o022:
                raise Preflight("Repository must be a directory others cannot write", "wrong-repository")
        if probe and not writable and not read_only:
            read_only = not self.writable(self.repository_path(target) if repository else mount)
        return read_only

    @staticmethod
    def writable(directory):
        """An actual write probe: a uniquely named empty file created and removed at once. Any
        refusal (EROFS from a read-only virtiofs export, EACCES, EPERM, ENOSPC) means restic could
        not write its lock either. The file is removed whatever happens once it exists; a removal
        that fails is reported (restic ignores the file) and counts as not writable, since restic
        could not remove its lock either."""
        probe = Path(directory) / f".anj-write-probe-{secrets.token_hex(8)}"
        try:
            descriptor = os.open(probe, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        except OSError:
            return False
        try:
            os.close(descriptor)
        finally:
            try:
                probe.unlink()
            except OSError as error:
                print(json.dumps({"event": "write-probe-left", "file": probe.name,
                                  "error": error.strerror or type(error).__name__}), file=sys.stderr, flush=True)
                removed = False
            else:
                removed = True
        return removed

    @staticmethod
    def root_device():
        return os.stat("/").st_dev

    def space(self, target):
        info = os.statvfs(Path(target["mount"]))
        free = info.f_bavail * info.f_frsize
        total = info.f_blocks * info.f_frsize
        used = 1 - (info.f_bfree / info.f_blocks) if info.f_blocks else 1
        return {"free_bytes": free, "total_bytes": total, "used_fraction": round(used, 4)}

    # Restic ---------------------------------------------------------------------------

    def restic_argv(self, args, *, mounts=(), caps=RESTIC_CAPS, name=None, repository=None,
                    password_file=None, workdir=None, read_only=False):
        repository = Path(repository or self.repository_path())
        password_file = Path(password_file or self.password_file)
        private_directory(self.cache_dir)
        # Restic stages pack files in TMPDIR; a slow upload would fill a small tmpfs, so they go
        # to host disk under the private cache (cleared by the locked run path).
        private_directory(self.cache_dir / "tmp")
        argv = ["docker", "run", "--rm", *LIMITS, "--network", "none", "--cap-drop", "ALL"]
        for cap in caps:
            argv += ["--cap-add", cap]
        argv += ["--security-opt", "no-new-privileges", "--read-only", "--tmpfs", "/tmp:size=64m",
                 "--label", "anj-cloud.backup=" + self.project,
                 "--env", "RESTIC_REPOSITORY=/repo", "--env", "RESTIC_PASSWORD_FILE=/run/restic/password",
                 "--env", "RESTIC_CACHE_DIR=/cache", "--env", "TMPDIR=/cache/tmp",
                 "--volume", f"{repository}:/repo" + (":ro" if read_only else ""),
                 "--volume", f"{password_file}:/run/restic/password:ro",
                 "--volume", f"{self.cache_dir}:/cache"]
        if name:
            argv += ["--name", name]
        if workdir:
            argv += ["--workdir", workdir]
        for source, target, mode in mounts:
            argv += ["--volume", f"{source}:{target}:{mode}"]
        # A read-only share (the drill) takes no restic lock: --no-lock (spec #22 rev7, Drill).
        return argv + [RESTIC_IMAGE, *args, *(["--no-lock"] if read_only and "--no-lock" not in args else [])]

    def restic(self, args, *, timeout=3600, data=None, **options):
        try:
            return self.runner.run(self.restic_argv(args, **options), data=data, timeout=timeout)
        except CommandFailed as error:
            raise restic_error(error) from None

    def repository_id(self, **options):
        output = self.restic(["cat", "config", "--json", "--no-lock"], timeout=300, **options).stdout
        identity = json.loads(output)["id"]
        if not re.fullmatch(r"[0-9a-f]{64}", identity):
            raise BackupError("Unexpected repository identity")
        return identity

    # Stack ------------------------------------------------------------------------------

    def containers(self, project=None):
        project = project or self.project
        output = self.runner.run(["docker", "ps", "--all", "--no-trunc", "--filter",
                                  "label=com.docker.compose.project=" + project, "--format", "{{json .}}"],
                                 timeout=60).stdout.decode()
        rows = {}
        for line in output.splitlines():
            row = json.loads(line)
            labels = dict(item.split("=", 1) for item in row.get("Labels", "").split(",") if "=" in item)
            if labels.get("com.docker.compose.project") != project:
                continue
            rows[labels.get("com.docker.compose.service")] = {"id": row["ID"], "state": row.get("State")}
        return rows

    def exec(self, service, argv, *, data=None, timeout=300, user=None, containers=None, stdout=None):
        containers = containers or self.containers()
        if service not in containers:
            raise BackupError(f"Service is missing: {service}", "stack-unhealthy")
        command = ["docker", "exec"] + (["--interactive"] if data is not None else [])
        if user:
            command += ["--user", user]
        return self.runner.run([*command, containers[service]["id"], *argv], data=data, timeout=timeout,
                               stdout=stdout)

    def occ(self, *args, timeout=300, containers=None):
        return self.exec("nextcloud", ["php", "occ", *args], user="www-data", timeout=timeout,
                         containers=containers).stdout.decode().strip()

    def database_identity(self, containers):
        inspect = json.loads(self.runner.run(["docker", "inspect", containers["db"]["id"]], timeout=60).stdout)[0]
        env = dict(item.split("=", 1) for item in inspect["Config"]["Env"] if "=" in item)
        return env.get("POSTGRES_USER", "postgres"), env.get("POSTGRES_DB", env.get("POSTGRES_USER", "postgres"))

    def psql(self, sql, containers, timeout=300):
        user, database = self.database_identity(containers)
        return self.exec("db", ["psql", "--no-psqlrc", "--username", user, "--dbname", database, "--tuples-only",
                                "--no-align", "--field-separator", "\t", "--command", sql],
                         timeout=timeout, containers=containers).stdout.decode()

    def check_stack(self):
        containers = self.containers()
        for service in ("db", "nextcloud", "access"):
            if containers.get(service, {}).get("state") != "running":
                raise Preflight(f"Production service is not running: {service}", "stack-unhealthy")
        for service, row in containers.items():
            if service not in ("access-tls",) and row["state"] != "running":
                raise Preflight(f"Production service is not running: {service}", "stack-unhealthy")
        try:
            health = self.exec("access", ["python", "-m", "access.health"], timeout=60, containers=containers)
            if json.loads(health.stdout) != {"status": "ready"}:
                raise ValueError
        except (BackupError, ValueError, subprocess.TimeoutExpired):
            raise Preflight("Gateway healthcheck is not ready", "stack-unhealthy") from None
        if "enabled" in self.occ("maintenance:mode", containers=containers):
            raise Preflight("Nextcloud is already in maintenance mode (another operation?)", "stack-unhealthy")
        return containers

    def volume_bytes(self, names, timeout=600):
        mounts = [(f"{self.project}_{name}", f"/v/{name}", "ro") for name in names]
        argv = ["docker", "run", "--rm", *LIMITS, "--network", "none", "--cap-drop", "ALL", "--cap-add", "DAC_READ_SEARCH",
                "--security-opt", "no-new-privileges", "--entrypoint", "du"]
        for source, target, mode in mounts:
            argv += ["--volume", f"{source}:{target}:{mode}"]
        output = self.runner.run([*argv, RESTIC_IMAGE, "-sk", "/v"], timeout=timeout).stdout.decode()
        return int(output.split()[0]) * 1024

    # Init -------------------------------------------------------------------------------

    def init(self, *, mount=None, tag=None, alert_command=None, show_escrow=False, adopt=False,
             password_file=None):
        with self.lock():
            if self.project == PROJECT:
                if mount not in (None, str(paths.BACKUP_MOUNT)) or tag not in (None, paths.BACKUP_TAG):
                    raise BackupError("Production uses the anj-backup virtiofs share only")
                target = {"name": "onsite", "kind": "virtiofs-share", "mount": str(paths.BACKUP_MOUNT),
                          "tag": paths.BACKUP_TAG}
            else:
                if not mount or not tag:
                    raise BackupError("Review and test projects need an explicit scratch --mount and --tag")
                if not SHARE_TAG.fullmatch(tag):
                    raise BackupError("--tag must be a virtiofs tag")
                if os.path.normpath(mount) == str(paths.BACKUP_MOUNT) or tag == paths.BACKUP_TAG:
                    raise BackupError("Only anj-cloud-prod may use the production backup share")
                target = {"name": "onsite", "kind": "virtiofs-share", "mount": os.path.normpath(mount), "tag": tag}
            existing = self.config.get("targets")
            if existing and existing[0].get("repository_id"):
                recorded = dict(existing[0])
                recorded.pop("repository_id", None)
                recorded.pop("initialized_at", None)
                recorded.pop("adopted_at", None)
                if recorded != target:
                    raise BackupError("A different backup target is already recorded")
                self.check_share(existing[0])
                if self.repository_id() != existing[0]["repository_id"]:
                    raise Preflight("Repository on the share is not the recorded one", "wrong-repository")
                result = {"state": "exists", "repository_id": existing[0]["repository_id"]}
            elif adopt:
                # Rebuilt VM (full recovery, drill): the escrowed password opens the existing
                # repository, whose ID is read and recorded; nothing on the share is written, so a
                # read-only share (the drill) is accepted.
                self.check_share(target, writable=False)
                private_directory(self.password_file.parent)
                if password_file:
                    if self.password_file.exists():
                        raise BackupError("A repository password is already in this state root")
                    atomic_write(self.password_file, Path(password_file).read_bytes())
                elif not self.password_file.exists():
                    raise BackupError("--adopt needs the escrowed password (--password-file, or secrets/restic-password)")
                self._password()  # validates owner and mode of the placed file
                target["repository_id"] = self.repository_id(repository=self.repository_path(target))
                target["adopted_at"] = iso(self.now())
                self.config.update(version=1, project=self.project, targets=[target])
                result = {"state": "adopted", "repository_id": target["repository_id"]}
            else:
                self.check_share(target, repository=False)
                repository = self.repository_path(target)
                if os.path.lexists(repository):
                    raise BackupError("A repository already exists on the share but is not recorded here; "
                                      "use init --adopt with the escrowed password")
                # Only restic/ is created, inside the share (which is DOS_BACKUP/anj-cloud-prod/ on the VM host).
                repository.mkdir(mode=0o700)
                private_directory(self.password_file.parent)
                self._password()
                self.restic(["init"], repository=repository, timeout=600)
                target["repository_id"] = self.repository_id(repository=repository)
                target["initialized_at"] = iso(self.now())
                self.config.update(version=1, project=self.project, targets=[target])
                result = {"state": "initialized", "repository_id": target["repository_id"]}
            if alert_command is not None:
                self.config["alert_command"] = alert_command
            elif "alert_command" not in self.config:
                self.config["alert_command"] = default_alert_command()
            self.save_config()
            self.alerter.command = self.config.get("alert_command")
            result.update(project=self.project, target=self.target["name"],
                          alert_dispatcher="configured" if self.config.get("alert_command") else "missing")
            if show_escrow:
                result["escrow"] = "confirmed" if self.show_escrow() else "not confirmed"
            return result

    def _password(self):
        try:
            fd = os.open(self.password_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        except FileExistsError:
            info = self.password_file.lstat()
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
                raise BackupError("Repository password must be a private regular file") from None
            return
        with os.fdopen(fd, "w") as stream:
            stream.write(secrets.token_urlsafe(48) + "\n")

    ESCROW_NOTE = (
        "What it is: the key that encrypts every backup on the backup drive.\n"
        "Why it matters: if this server's disks are lost, your backups can ONLY be restored with this password.\n"
        "                Without it the backups are unreadable — by anyone, including you.\n"
        "Save it now in your password manager as \"anj-cloud backup password\", and keep that entry\n"
        "somewhere that does not depend on this server.\n")

    def show_escrow(self, *, tty="/dev/tty", ask=None, attempts=3):
        """The repository password on the terminal device only (never stdout, a pipe or the journal),
        with what is at stake, then a confirmation by its last 6 characters (hidden input, up to
        `attempts` tries). Returns whether the save was confirmed; the screen is cleared either way."""
        try:
            if not sys.stdin.isatty():
                raise OSError("no terminal")
            terminal = open(tty, "w")
        except OSError:
            raise BackupError("--show-escrow needs an interactive terminal; the password is never logged") from None
        password = self.password_file.read_text().strip()
        ask = ask or (lambda prompt: getpass.getpass(prompt, stream=terminal))
        confirmed = False
        with terminal:
            try:
                terminal.write("\nBackup password (restic):\n\n  " + password + "\n\n" + self.ESCROW_NOTE + "\n")
                terminal.flush()
                for _attempt in range(attempts):
                    if ask("To confirm, type the LAST 6 characters of the password (input hidden): ").strip() == \
                            password[-6:]:
                        confirmed = True
                        break
                    terminal.write("That does not match; check your saved copy.\n")
                    terminal.flush()
            finally:
                # Always, also on Ctrl-C or Ctrl-D at the prompt: the screen and (where the terminal
                # supports it) the scrollback are cleared, so the password never stays visible.
                terminal.write("\033[H\033[2J\033[3J")
                terminal.write("Backup password saved and confirmed.\n" if confirmed else
                               "Not confirmed — run `sudo anj-cloud-setup backup --show-password` to see it again.\n")
                terminal.flush()
        return confirmed

    def show_password(self):
        """`show-password`: a read-only re-show of the escrowed password (the same terminal-only path)."""
        if not self.password_file.exists():
            raise BackupError("No backup password in this state root; run init first")
        self._password()  # validates owner and mode
        return {"escrow": "confirmed" if self.show_escrow() else "not confirmed"}

    # Run --------------------------------------------------------------------------------

    def run(self, kind="nightly", cap_seconds=None, limit_upload=None):
        """One backup: preflight, maintenance window under a hard cap, then housekeeping."""
        if kind not in ("nightly", "seed", "manual"):
            raise BackupError("Unknown run kind")
        if self.project == PROJECT and not qualification_vm():
            if kind == "nightly" and cap_seconds not in (None, CAP_MINUTES * 60):
                raise BackupError("Nightly production runs keep the 30-minute cap")
            if limit_upload is not None:
                raise BackupError("Upload throttling is a review-project test aid only")
        cap_seconds = cap_seconds or CAP_MINUTES * 60
        started = self.now()
        run_id = stamp(started) + "-" + secrets.token_hex(3)
        record = {"run_id": run_id, "kind": kind, "started_at": iso(started), "cap_seconds": cap_seconds,
                  "result": "running"}
        try:
            # The lock is held through housekeeping too, so nothing (a reboot guard, an update
            # window, a second run) sees the repository idle while forget/prune/check still run.
            with self.lock():
                self._attempt(record, kind, run_id, started, cap_seconds, limit_upload)
                self._finish(record, kind, started)
        except BackupError as error:  # the lock itself was busy
            if error.reason == "busy" and release_switch_running(self.run_dir):
                # A release switch holds the lock (decision #122): not a failure; the next run takes it.
                record.update(result="skipped", reason="release-switch")
                print(json.dumps({"skipped": "a release switch (prod.py redeploy) holds the operations lock; "
                                             "the next scheduled run backs up"}), file=sys.stderr)
            else:
                record.update(result="failed", reason=error.reason, error=str(error))
            self._finish(record, kind, started)
        return record

    def _attempt(self, record, kind, run_id, started, cap_seconds, limit_upload):
        try:
            self._recover_marker()
            if kind == "nightly" and not self.status.get("seeded_at"):
                raise BackupError("Nightly backups start after the seed backup succeeds", "not-seeded")
            record.update(self._run_locked(kind, run_id, started, cap_seconds, limit_upload))
        except (subprocess.TimeoutExpired, OSError, ValueError) as error:
            record.update(result="failed", reason="timeout" if isinstance(error, subprocess.TimeoutExpired) else "failed",
                          error=type(error).__name__)
        except BackupError as error:
            record.update(result="capped" if isinstance(error, Capped) else
                          ("preflight-failed" if isinstance(error, Preflight) else "failed"),
                          reason=error.reason, error=str(error))

    def _finish(self, record, kind, started):
        if getattr(self, "_window_s", None) is not None:
            record.setdefault("maintenance_s", self._window_s)
            self._window_s = None
        record["finished_at"] = iso(self.now())
        record["duration_s"] = round((self.now() - started).total_seconds(), 1)
        self.status["last_run"] = record
        if record["result"] == "success":
            self.status["last_success"] = record
            self.status.pop("stale_alerted_for", None)
            if kind == "seed" and not self.status.get("seeded_at"):
                self.status["seeded_at"] = record["finished_at"]
        self.save_status()
        if record["result"] != "success":
            self._alert_for(record)
            return
        try:
            self._housekeeping(record)
        except (BackupError, subprocess.TimeoutExpired, OSError, ValueError) as error:
            # The snapshot is safe; a housekeeping failure is reported, never turned into a crash.
            reason = getattr(error, "reason", None) or type(error).__name__
            record.setdefault("housekeeping", {})["error"] = reason
            self.status["last_run"] = self.status["last_success"] = record
            self.save_status()
            self.alerter.send("backup-check-failed", f"{self.project} post-backup housekeeping failed ({reason})")

    def _alert_for(self, record):
        reason = record.get("reason", "failed")
        if record["result"] == "skipped":
            return                       # a release switch held the lock: logged, never alerted
        if record["result"] == "capped":
            self.alerter.send("backup-cap", f"{self.project} backup stopped at its {record['cap_seconds'] // 60}-minute "
                              "cap; production is serving again; the next run continues from the uploaded data")
        elif record["result"] == "preflight-failed":
            self.alerter.send("backup-preflight", f"{self.project} backup preflight failed ({reason}); "
                              "maintenance was not entered")
        elif reason == "busy":
            self.alerter.send("backup-failed", f"{self.project} backup skipped: another backup operation is running")
        else:
            self.alerter.send("backup-failed", f"{self.project} {record['kind']} backup failed ({reason})")

    def _recover_marker(self):
        """A marker left by a crashed run: alert once, repair the index, never leave maintenance on."""
        if not self.marker_path.exists():
            return
        marker = self.read_marker() or {}
        self.status["needs_index_repair"] = True
        self.save_status()
        if self.status.get("stale_marker_alerted") != marker.get("run_id"):
            self.status["stale_marker_alerted"] = marker.get("run_id")
            self.alerter.send("backup-marker-stale", f"{self.project} found a backup marker from an interrupted run; "
                              "maintenance is being cleared")
        with contextlib.suppress(BackupError, subprocess.TimeoutExpired):
            containers = self.containers()
            if "enabled" in self.occ("maintenance:mode", containers=containers):
                self.occ("maintenance:mode", "--off", containers=containers)
        self.clear_marker()

    def _estimate(self):
        """Measured on every run, before the window: today's source size against the last
        success, the last upload, and prune headroom on prune nights."""
        source = self.volume_bytes(("nextcloud", "access", "database"))
        last = self.status.get("last_success")
        if not last or not last.get("source_bytes"):
            estimate = int(source * 1.1)  # first (seed) backup: everything is new
        else:
            estimate = max(source - int(last["source_bytes"]), 2 * int(last.get("bytes_added") or 0), 256 * 1024**2)
        headroom = self.prune_headroom() if self._due("last_prune", PRUNE_EVERY) else 0
        return estimate + headroom, source, headroom

    def prune_headroom(self):
        """Prune writes repacked packs before deleting old ones: keep 10 % of the repository free."""
        total = 0
        for directory, _, files in os.walk(self.repository_path() / "data"):
            for name in files:
                with contextlib.suppress(OSError):
                    total += os.lstat(os.path.join(directory, name)).st_size
        return total // 10

    def _run_locked(self, kind, run_id, started, cap_seconds, limit_upload):
        target = self.target
        # Temp packs left by a stopped or crashed backup; only a backup writes them, and the lock is held.
        for leftover in (self.cache_dir / "tmp").glob("restic-temp-pack-*"):
            with contextlib.suppress(OSError):
                leftover.unlink()
        # 1. Preflight, before any maintenance.
        self.check_share(target)
        try:
            if self.repository_id() != target["repository_id"]:
                raise Preflight("Repository on the share is not the recorded one", "wrong-repository")
        except RepositoryLocked:
            raise BackupError("Repository is locked by another restic operation", "repository-locked") from None
        except BackupError as error:
            if error.reason != "wrong-password":
                raise
            # Another repository at the path almost never opens with ours: same refusal, no maintenance.
            raise Preflight("Repository on the share does not open with the recorded password", "wrong-repository") from None
        if self.status.get("needs_index_repair"):
            # Packs uploaded by a capped or crashed run are adopted, so this run reuses them.
            self.restic(["repair", "index"], timeout=3600)
            self.status["needs_index_repair"] = False
            self.save_status()
        containers = self.check_stack()
        estimate, source, headroom = self._estimate()
        space = self.space(target)
        if space["free_bytes"] < estimate + int(self.config.get("margin_bytes", MARGIN_BYTES)):
            raise Preflight("Not enough free space on the backup share for this run", "low-space")
        result = {"estimate_bytes": estimate, "source_bytes": source, "prune_headroom_bytes": headroom}
        # 2-6. Marker and maintenance window under the hard cap.
        deadline = started + timedelta(seconds=cap_seconds)
        staging = self.run_dir / "staging"
        self.write_marker(kind, run_id, deadline, started)
        maintenance_started = None
        restic_started = False
        try:
            maintenance_started = self.now()
            self.occ("maintenance:mode", "--on", timeout=self.remaining(deadline), containers=containers)
            if staging.exists():
                shutil.rmtree(staging)
            private_directory(staging)
            manifest = self._capture(containers, staging, deadline, run_id, kind)
            manifest["source_bytes"] = source
            write_json(staging / "manifest.json", manifest)
            restic_started = True
            summary = self._restic_backup(kind, run_id, deadline, limit_upload)
            result.update(snapshot=summary["snapshot_id"], bytes_added=summary.get("data_added"),
                          bytes_added_packed=summary.get("data_added_packed"),
                          snapshot_bytes=summary.get("total_bytes_processed"), files=summary.get("total_files_processed"),
                          source_bytes=source, filecache_rows=manifest["filecache_rows"],
                          registry_devices=manifest["registry"]["devices"])
        except subprocess.TimeoutExpired:
            raise Capped() from None
        except BackupError:
            if restic_started:
                self.status["needs_index_repair"] = True
            raise
        finally:
            # Production first: leave maintenance before any cleanup can lengthen the window.
            if maintenance_started is not None:
                for attempt in range(3):
                    try:
                        self.occ("maintenance:mode", "--off", timeout=120, containers=containers)
                        break
                    except (BackupError, subprocess.TimeoutExpired):
                        self.runner.sleep(5)
                else:
                    self.alerter.send("backup-maintenance-stuck", f"{self.project} could not leave Nextcloud "
                                      "maintenance mode after a backup; production needs attention")
                result["maintenance_s"] = round((self.now() - maintenance_started).total_seconds(), 1)
                self._window_s = result["maintenance_s"]
            self.clear_marker()
            with contextlib.suppress(BackupError, subprocess.TimeoutExpired):
                self.exec("access", ["python", "-c", REGISTRY_SNAPSHOT, "clean"], timeout=60, containers=containers,
                          user=GATEWAY_USER)
            if staging.exists():
                shutil.rmtree(staging, ignore_errors=True)
        result["result"] = "success"
        return result

    def remaining(self, deadline, floor=1):
        seconds = (deadline - self.now()).total_seconds()
        if seconds < floor:
            raise subprocess.TimeoutExpired("backup", 0)
        return seconds

    def _capture(self, containers, staging, deadline, run_id, kind):
        """Database dump, file-cache count and sentinels, registry snapshot; inside maintenance."""
        prefix = self.occ("config:system:get", "dbtableprefix", timeout=self.remaining(deadline), containers=containers) or "oc_"
        if not re.fullmatch(r"[a-z0-9_]{0,16}", prefix):
            raise BackupError("Unexpected Nextcloud table prefix")
        datadir = self.occ("config:system:get", "datadirectory", timeout=self.remaining(deadline), containers=containers)
        count = int(self.psql(f"SELECT count(*) FROM {prefix}filecache", containers, self.remaining(deadline)).strip())
        sentinel = None
        row = self.psql(SENTINEL_QUERY.format(p=prefix), containers, self.remaining(deadline)).strip()
        if row:
            fileid, uid, path = row.split("\t", 2)
            digest = self.exec("nextcloud", ["sh", "-c", HASH_STDIN], user="www-data",
                               data=f"{datadir}/{uid}/{path}\n".encode(), timeout=self.remaining(deadline),
                               containers=containers).stdout.decode().strip()
            sentinel = {"fileid": int(fileid), "sha256": digest}
        config_digest = self.exec("nextcloud", ["sh", "-c", HASH_STDIN], user="www-data",
                                  data=b"/var/www/html/config/config.php\n", timeout=self.remaining(deadline),
                                  containers=containers).stdout.decode().strip()
        user, database = self.database_identity(containers)
        dump = staging / "database.dump"
        fd = os.open(dump, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "wb") as stream:
            self.exec("db", ["pg_dump", "--username", user, "--dbname", database, "--format", "custom",
                             "--compress", "0"], timeout=self.remaining(deadline), containers=containers, stdout=stream)
        # Nextcloud's installer owns its tables with its own role; roles are cluster-wide and
        # pg_dump omits them, so they travel beside the dump (password hashes stay encrypted).
        roles = staging / "roles.sql"
        fd = os.open(roles, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "wb") as stream:
            self.exec("db", ["pg_dumpall", "--username", user, "--roles-only"], timeout=self.remaining(deadline),
                      containers=containers, stdout=stream)
        digest = hashlib.sha256()
        with open(dump, "rb") as stream:
            for chunk in iter(lambda: stream.read(1 << 20), b""):
                digest.update(chunk)
        # The state volume belongs to the gateway user (spec A's start hands it over); container
        # root holds no DAC override, so the snapshot runs as that user.
        registry = json.loads(self.exec("access", ["python", "-c", REGISTRY_SNAPSHOT, "snapshot"], user=GATEWAY_USER,
                                        timeout=self.remaining(deadline), containers=containers).stdout)
        if not registry.get("integrity"):
            raise BackupError("Registry snapshot failed its integrity check")
        stack = read_json(self.state_root / "stack.json", {}) or {}
        return {"version": MANIFEST_VERSION, "project": self.project, "run_id": run_id, "kind": kind,
                "captured_at": iso(self.now()), "release": (stack.get("release") or "")[:12] or None,
                "host": stack.get("host"), "table_prefix": prefix, "datadir": datadir, "filecache_rows": count,
                "sentinels": {"config_sha256": config_digest, "user_file": sentinel},
                "database": {"sha256": digest.hexdigest(), "bytes": dump.stat().st_size, "user": user, "name": database,
                             "roles": True},
                "registry": registry}

    def _restic_backup(self, kind, run_id, deadline, limit_upload):
        name = f"{self.project}-backup-{run_id}"
        mounts = [(str(self.state_root), "/backup/state", "ro"),
                  (f"{self.project}_nextcloud", "/backup/nextcloud", "ro"),
                  (f"{self.project}_access", "/backup/access", "ro"),
                  (str(self.run_dir / "staging"), "/backup/staging", "ro")]
        args = ["backup", "--json", "--host", self.project, "--tag", kind]
        for pattern in RESTIC_EXCLUDES:
            args += ["--exclude", pattern]
        if limit_upload:
            args += ["--limit-upload", str(int(limit_upload))]
        args.append("/backup")
        timeout = self.remaining(deadline)
        process = self.runner.popen(self.restic_argv(args, mounts=mounts, name=name))
        capped = False
        try:
            stdout, stderr = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            capped = True
            stdout, stderr = self._stop_restic(name, process)
        except BaseException:
            # systemd stop (SIGTERM -> KeyboardInterrupt): restic must not outlive the run.
            with contextlib.suppress(Exception):
                self._stop_restic(name, process)
            raise
        if capped:
            self.status["needs_index_repair"] = True
            raise Capped()
        if process.returncode:
            error = restic_error(CommandFailed(["restic", "backup"], process.returncode, stderr))
            if process.returncode == 3:
                raise BackupError("Restic could not read every source file; snapshot incomplete", "incomplete-snapshot")
            raise error
        summary = None
        for line in stdout.decode(errors="replace").splitlines():
            with contextlib.suppress(ValueError):
                message = json.loads(line)
                if message.get("message_type") == "summary":
                    summary = message
        if not summary or not summary.get("snapshot_id"):
            raise BackupError("Restic reported no snapshot")
        return summary

    def _stop_restic(self, name, process):
        """Restic stops on SIGTERM and keeps uploaded packs (the next run adopts them). Every
        wait is bounded; a container that does not stop is killed."""
        with contextlib.suppress(BackupError, subprocess.TimeoutExpired, OSError):
            self.runner.run(["docker", "stop", "--time", "20", name], timeout=60, check=False)
        try:
            return process.communicate(timeout=60)
        except subprocess.TimeoutExpired:
            with contextlib.suppress(BackupError, subprocess.TimeoutExpired, OSError):
                self.runner.run(["docker", "kill", name], timeout=30, check=False)
            process.kill()
            return process.communicate(timeout=30)

    # Housekeeping after the window -------------------------------------------------------

    def _due(self, key, every):
        last = parse_iso(self.status.get(key))
        return last is None or self.now() - last >= every - timedelta(hours=6)

    def housekeeping_deadline(self, moment):
        """The next 04:10 local at or after `moment`, and never more than 6 hours away."""
        local = moment.astimezone(self.tz)
        end = local.replace(hour=HOUSEKEEPING_END[0], minute=HOUSEKEEPING_END[1], second=0, microsecond=0)
        if end <= local:
            end += timedelta(days=1)
        return min(end, moment + HOUSEKEEPING_MAX)

    def _housekeeping(self, record):
        """Retention, weekly prune and checks after maintenance is cleared (the stack serves),
        under the backup lock, until 04:10 local. What still does not fit is deferred; the
        last success of each is recorded and long overdue work alerts (see _overdue)."""
        target = self.target
        deadline = self.housekeeping_deadline(self.now())
        notes = {}
        prune = self._due("last_prune", PRUNE_EVERY)
        notes["forget"] = self._bounded("forget", ["forget", "--host", self.project, *RETENTION,
                                                   *(["--prune"] if prune else [])], deadline)
        if notes["forget"] == "ok":
            self.status["last_forget"] = iso(self.now())
            if prune:
                self.status["last_prune"] = self.status["last_forget"]
                notes["forget"] = "pruned"
        elif notes["forget"] != "deferred":
            self.alerter.send("backup-check-failed", f"{self.project} retention/prune failed ({notes['forget']})")
        if self._due("last_read_check", READ_CHECK_EVERY):
            notes["check"] = self._check(read_subset=True, deadline=deadline)
        elif self._due("last_check", CHECK_EVERY):
            notes["check"] = self._check(read_subset=False, deadline=deadline)
        try:
            space = self.space(target)
            record["share"] = space
            if space["free_bytes"] < CAPACITY_MIN_FREE or space["used_fraction"] > CAPACITY_MAX_USED:
                self.alerter.send("backup-capacity", f"{self.project} backup share is low on space "
                                  f"({space['free_bytes'] // 1000**3} GB free, {round(space['used_fraction'] * 100)}% used)")
        except OSError:
            notes["capacity"] = "unavailable"
        record["housekeeping"] = notes
        self.status["last_run"] = record
        self.status["last_success"] = record
        self._overdue()
        self.save_status()

    def overdue(self):
        """Housekeeping more than 8 days past its period, measured from its last success (or
        the seed, before the first)."""
        now = self.now()
        baseline = parse_iso(self.status.get("seeded_at"))
        late = []
        for name, period in HOUSEKEEPING_PERIODS.items():
            last = parse_iso(self.status.get("last_" + name)) or baseline
            if last is not None and now - last > period + OVERDUE_GRACE:
                late.append(name)
        return late

    def _overdue(self):
        late = self.overdue()
        if not late:
            self.status.pop("overdue_alerted", None)
            return
        if not self.status.get("overdue_alerted"):
            self.status["overdue_alerted"] = iso(self.now())
            self.alerter.send("backup-housekeeping-overdue", f"{self.project} backup housekeeping is more than "
                              f"8 days overdue ({', '.join(late)})")

    def _bounded(self, kind, args, deadline, floor=120):
        """One restic housekeeping command, stopped at the deadline (restic exits cleanly on
        SIGTERM; an interrupted prune leaves only unreferenced packs for the next prune)."""
        if deadline is None:
            try:
                self.restic(args, timeout=6 * 3600)
                return "ok"
            except BackupError as error:
                return error.reason
        remaining = (deadline - self.now()).total_seconds()
        if remaining < floor:
            return "deferred"
        name = f"{self.project}-{kind}-{secrets.token_hex(3)}"
        process = self.runner.popen(self.restic_argv(args, name=name))
        try:
            _, stderr = process.communicate(timeout=remaining)
        except subprocess.TimeoutExpired:
            self._stop_restic(name, process)
            return "deferred"
        except BaseException:
            with contextlib.suppress(Exception):
                self._stop_restic(name, process)
            raise
        if process.returncode:
            return restic_error(CommandFailed(["restic", kind], process.returncode, stderr)).reason
        return "ok"

    def _check(self, read_subset, deadline=None):
        args = ["check"] + (["--read-data-subset", READ_SUBSET] if read_subset else [])
        outcome = self._bounded("check", args, deadline)
        if outcome == "deferred":
            return "deferred"  # last_check is not advanced; _overdue alerts if this persists
        if outcome != "ok":
            self.status["last_check_result"] = {"at": iso(self.now()), "result": "failed", "reason": outcome}
            self.alerter.send("backup-check-failed", f"{self.project} repository check failed ({outcome})")
            return "failed"
        self.status["last_check"] = iso(self.now())
        if read_subset:
            self.status["last_read_check"] = self.status["last_check"]
        self.status["last_check_result"] = {"at": self.status["last_check"], "result": "ok",
                                            "read_subset": READ_SUBSET if read_subset else None}
        return "ok"

    def check(self, read_subset=False):
        with self.lock():
            try:
                self.check_share(self.target)
                if self.repository_id() != self.target["repository_id"]:
                    raise Preflight("Repository on the share is not the recorded one", "wrong-repository")
            except BackupError as error:
                self.alerter.send("backup-check-failed", f"{self.project} repository check could not start ({error.reason})")
                raise
            result = self._check(read_subset)
            self.save_status()
            return {"project": self.project, "check": result, "read_subset": READ_SUBSET if read_subset else None}

    # Status and the 36-hour watcher -------------------------------------------------------

    def report(self, alert_stale=False):
        now = self.now()
        marker = self.read_marker() if self.marker_path.exists() else None
        held = self.lock_held()
        last_success = self.status.get("last_success")
        hours = None
        if last_success:
            hours = round((now - parse_iso(last_success["finished_at"])).total_seconds() / 3600, 1)
        if alert_stale:
            if marker and marker.get("deadline_epoch", 0) < now.timestamp():
                if self.status.get("stale_marker_alerted") != marker.get("run_id"):
                    self.status["stale_marker_alerted"] = marker.get("run_id")
                    self.alerter.send("backup-marker-stale", f"{self.project} backup marker is past its deadline"
                                      + (" while a run still holds the lock" if held else "; the run did not finish"))
            if marker and marker.get("deadline_epoch", 0) < now.timestamp() and not held:
                # A crashed run left production in maintenance: clear it now, not at the next 03:30.
                with contextlib.suppress(BackupError):
                    with self.lock():
                        self._recover_marker()
            self._overdue()
            seeded = self.status.get("seeded_at")
            reference = last_success["finished_at"] if last_success else seeded
            if seeded and reference and now - parse_iso(reference) > timedelta(hours=STALE_HOURS):
                if self.status.get("stale_alerted_for") != reference:
                    self.status["stale_alerted_for"] = reference
                    self.alerter.send("backup-stale", f"{self.project} has had no successful backup in "
                                      f"{STALE_HOURS} hours")
            self.save_status()
        target = (self.config.get("targets") or [{}])[0]
        last = self.status.get("last_run")
        return {
            "project": self.project, "target": target.get("name"), "repository_id": target.get("repository_id"),
            "alert_dispatcher": "configured" if self.config.get("alert_command") else "missing",
            "seeded_at": self.status.get("seeded_at"),
            "last_run": summary_of(last), "last_success": summary_of(last_success),
            "hours_since_success": hours,
            "marker": None if not marker else {"kind": marker.get("kind"), "deadline": marker.get("deadline"),
                                                "active": marker.get("deadline_epoch", 0) >= now.timestamp(),
                                                "lock_held": held},
            "needs_index_repair": bool(self.status.get("needs_index_repair")),
            "last_check": self.status.get("last_check_result"), "last_prune": self.status.get("last_prune"),
            "housekeeping": {"last_forget": self.status.get("last_forget"), "last_prune": self.status.get("last_prune"),
                             "last_check": self.status.get("last_check"),
                             "last_read_check": self.status.get("last_read_check"), "overdue": self.overdue()},
            "recent_alerts": [{key: alert[key] for key in ("key", "at", "delivered")}
                              for alert in self.status.get("alerts", [])[-5:]],
        }

    # Window coordination (spec #22 rev7 Run Sequence 7; decision #86) -----------------

    def window(self):
        return window_check(self.state_root, self.now())


# Window coordination: read-only, root-capable (coordinator ruling on the PR #38 review) -------

WINDOW_CLEAR, WINDOW_BUSY, WINDOW_ERROR = 0, 1, 2  # systemd ExecCondition: 1-254 = skip


class WindowError(Exception):
    pass


def lock_busy(path):
    """True while another process holds the lock; probed with a shared non-blocking flock on a
    read-only descriptor, so root or anj can ask without creating or changing anything."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    except FileNotFoundError:
        return False
    try:
        fcntl.flock(fd, fcntl.LOCK_SH | fcntl.LOCK_NB)
    except BlockingIOError:
        return True
    finally:
        os.close(fd)
    return False


def window_check(state_root, now=None):
    """Whether spec #21's update run and reboot guard may proceed. Busy while a backup or restore
    marker is before its deadline (an unreadable marker counts as busy) or a backup or restore
    process holds its lock. Reads only; any problem raises WindowError (the caller fails closed)."""
    now = (now or utcnow()).timestamp()
    state_root = Path(state_root)
    if not state_root.is_dir():
        raise WindowError("state root missing")
    run_dir = state_root / paths.RUN_DIR.name
    busy = []
    for kind, name in (("backup", paths.BACKUP_IN_PROGRESS.name), ("restore", paths.RESTORE_IN_PROGRESS.name)):
        path = run_dir / name
        if not os.path.lexists(path):
            continue
        try:
            marker = json.loads(path.read_text())
            active = float(marker.get("deadline_epoch", 0)) >= now
        except (OSError, ValueError, TypeError, AttributeError):
            active = True
        if active:
            busy.append(kind + "-marker")
    for kind, name in (("backup", "backup.lock"), ("restore", "restore.lock")):
        try:
            if lock_busy(run_dir / name):
                busy.append(kind + "-running")
        except OSError as error:
            raise WindowError(type(error).__name__) from None
    return {"clear": not busy, "busy": busy, "checked_at": iso(utcnow() if now is None else
                                                               datetime.fromtimestamp(now, timezone.utc))}


def window_alert_stamp():
    """Once-per-day dedup outside the state root: /run as root, the user runtime dir otherwise."""
    if os.geteuid() == 0:
        return Path("/run/anj-cloud-backup-window-alert")
    runtime = os.environ.get("XDG_RUNTIME_DIR") or tempfile.gettempdir()
    return Path(runtime) / f"anj-cloud-backup-window-alert-{os.getuid()}"


def window_command(state_root, *, now=None, runner=None, stamp_path=None, out=None):
    """`window --check`: 0 clear, 1 busy, 2 error. An error is busy (never reboot mid-backup) and
    alerts once per day, so a broken check cannot silently block updates forever."""
    now = now or utcnow()
    try:
        result = window_check(state_root, now)
    except Exception as error:  # noqa: BLE001 - fail closed on anything
        emit({"clear": False, "error": type(error).__name__}, out)
        stamp_path = Path(stamp_path or window_alert_stamp())
        today = now.astimezone().date().isoformat()
        try:
            already = stamp_path.read_text().strip() == today
        except OSError:
            already = False
        if not already:
            try:
                config = json.loads((Path(state_root) / paths.BACKUP_RECORD.name).read_text())
                command = config.get("alert_command")
            except (OSError, ValueError, AttributeError):
                command = None
            command = command or default_alert_command()
            if command:
                with contextlib.suppress(Exception):
                    (runner or Runner()).run([*command, "--key", "backup-window-check", "--",
                                              "update window check failing; updates and reboots wait"], timeout=60)
            with contextlib.suppress(OSError):
                stamp_path.write_text(today + "\n")
        return WINDOW_ERROR
    emit(result, out)
    return WINDOW_CLEAR if result["clear"] else WINDOW_BUSY


@contextlib.contextmanager
def restore_window(state_root, project, kind, now):
    """Hold paths.RESTORE_IN_PROGRESS (with a deadline) and the restore lock in the target state
    root's run/ for the whole restore or drill, so the update run and the reboot guard wait (#86)."""
    state_root = Path(state_root)
    if not state_root.exists():
        private_directory(state_root)
    run_dir = private_directory(state_root / paths.RUN_DIR.name)
    marker = run_dir / paths.RESTORE_IN_PROGRESS.name
    fd = os.open(run_dir / "restore.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise BackupError("Another restore or drill is running", "busy") from None
        started = now()
        deadline = started + RESTORE_DEADLINE
        write_json(marker, {"version": 1, "project": project, "kind": kind, "run_id": stamp(started),
                            "pid": os.getpid(), "started_at": iso(started), "deadline": iso(deadline),
                            "deadline_epoch": int(deadline.timestamp())})
        try:
            yield marker
        finally:
            with contextlib.suppress(FileNotFoundError):
                marker.unlink()
    finally:
        os.close(fd)


def render_units(source=paths.RELEASE_CURRENT, templates=UNIT_TEMPLATES):
    """The VM system units, rendered for spec #21's bootstrap, which installs and enables them.

    `source` is the extracted release source directory in the VM (the bootstrap knows it); the
    units run backup.py from there as paths.VM_USER. No PM2 app: a PM2 restart never starts a
    backup (decision #89 (4))."""
    source = Path(source)
    if not source.is_absolute() or any(c in str(source) for c in " \t\n%\\"):
        raise BackupError("--source must be an absolute path without spaces")
    units = {}
    for template in sorted(Path(templates).glob("anj-cloud-backup*")):
        units[template.name] = (template.read_text().replace("@SOURCE@", str(source))
                                .replace("@USER@", paths.VM_USER))
    if not units:
        raise BackupError("Unit templates are missing")
    return units


def summary_of(record):
    if not record:
        return None
    keys = ("run_id", "kind", "result", "reason", "started_at", "finished_at", "duration_s", "maintenance_s",
            "snapshot", "snapshot_bytes", "bytes_added", "files", "cap_seconds")
    return {key: record[key] for key in keys if key in record}


def qualification_vm():
    """True only inside the throwaway anj-qual VM (spec #21), where the hard-cap row shortens the
    cap and throttles restic; never in anj-prod."""
    import socket
    return socket.gethostname() == "anj-qual"


def default_alert_command():
    """Spec #21's in-VM dispatcher, paths.ALERT_COMMAND (`anj-alert [--key K] -- MESSAGE`, spooling
    to paths.ALERT_SPOOL), else `anj-alert` on PATH; recorded at init so the timer does not
    depend on PATH."""
    if os.access(paths.ALERT_COMMAND, os.X_OK):
        return [str(paths.ALERT_COMMAND)]
    found = shutil.which("anj-alert")
    return [found] if found else None


# Restore --------------------------------------------------------------------------------

class Restore:
    """Restore one snapshot into a fresh project: state root, volumes and a pg_restored database."""

    def __init__(self, backup, project, state_root, target, *, replace_production=False, confirm=None,
                 password_file=None):
        self.backup = backup
        self.password_source = Path(password_file) if password_file else None
        self.password_copy = None
        self.read_only = False
        self.runner = backup.runner
        self.project = validate_project(project, purpose="restore")
        self.state_root = checked_directory(state_root, "--state-root", create=False, must_exist=False)
        self.target = checked_directory(target, "--target", create=False, must_exist=False)
        if self.target.exists() and any(self.target.iterdir()):
            raise BackupError("--target must be an empty directory")
        self.replace = bool(replace_production)
        if self.replace and (self.project != PROJECT or confirm != PROJECT):
            raise BackupError("--replace-production applies only to anj-cloud-prod with --confirm anj-cloud-prod")
        if (self.state_root == self.backup.state_root or self.state_root == DEFAULT_STATE_ROOT) and self.project != PROJECT:
            raise BackupError("A non-production restore needs its own --state-root")
        self.existing_volumes = self.volumes()
        if self.existing_volumes:
            if self.project == PROJECT and not self.replace:
                raise BackupError("anj-cloud-prod volumes exist; a restore over production needs "
                                  "--replace-production --confirm anj-cloud-prod")
            if self.project != PROJECT:
                raise BackupError(f"{self.project} already has volumes; a restore needs a fresh project")

    def volumes(self):
        output = self.runner.run(["docker", "volume", "ls", "--quiet"], timeout=60).stdout.decode()
        return sorted(name for name in output.split() if name.startswith(self.project + "_"))

    def docker(self, *args, timeout=600, data=None, check=True, stdout=None):
        return self.runner.run(["docker", *args], timeout=timeout, data=data, check=check, stdout=stdout)

    def helper(self, *args, mounts=(), caps=(), user=None, entrypoint="sh", image=RESTIC_IMAGE, data=None, timeout=600):
        argv = ["run", "--rm", *LIMITS, "--network", "none", "--cap-drop", "ALL", "--security-opt", "no-new-privileges"]
        if data is not None:
            argv.append("--interactive")  # stdin carries paths, never arguments
        for cap in caps:
            argv += ["--cap-add", cap]
        if user:
            argv += ["--user", user]
        if entrypoint:
            argv += ["--entrypoint", entrypoint]
        for source, target, mode in mounts:
            argv += ["--volume", f"{source}:{target}:{mode}"]
        return self.docker(*argv, image, *args, timeout=timeout, data=data)

    def resolve_snapshot(self, snapshot, source_project):
        if snapshot == "latest":
            rows = json.loads(self.restic(["snapshots", "--json", "--host", source_project, "--latest", "1"],
                                                 timeout=600).stdout or b"[]")
            if not rows:
                raise BackupError("The repository holds no snapshot for this project")
            return rows[-1]["id"]
        if not SNAPSHOT_ID.fullmatch(snapshot):
            raise BackupError("--snapshot must be a snapshot ID or latest")
        return snapshot

    def restic_restore(self, snapshot, subfolder, destination_mount, *, caps):
        # restic >= 0.17 restores <snapshot>:<subfolder> contents directly into --target.
        self.restic(["restore", f"{snapshot}:/backup/{subfolder}", "--target", "/target"],
                           mounts=[destination_mount], caps=caps, timeout=6 * 3600)

    def run(self, snapshot="latest", source_project=PROJECT):
        """Non-destructive steps first; production volumes go only after the snapshot is staged,
        and the state root is replaced last. The repository password is held in a private copy
        for the whole restore, so replacing secrets/ can never strand the restic calls."""
        backup = self.backup
        private_directory(self.target)
        self.password_copy = self.target / ".restic-password"
        source = self.password_source or backup.password_file
        try:
            secret = Path(source).read_bytes()
        except OSError:
            raise BackupError("Repository password is not readable (state root secrets or --password-file)") from None
        atomic_write(self.password_copy, secret)
        staging = self.target / "staging"
        try:
            with restore_window(self.state_root, self.project, "restore", self.backup.now):
                return self._run(snapshot, source_project, staging)
        finally:
            for path in (staging / "database.dump", staging / "roles.sql", self.password_copy):
                with contextlib.suppress(FileNotFoundError):
                    path.unlink()  # household rows, role hashes and the password never stay behind

    def restic(self, args, **options):
        return self.backup.restic(args, password_file=self.password_copy, read_only=self.read_only, **options)

    def _run(self, snapshot, source_project, staging):
        backup = self.backup
        # 1. Read-only checks: share, repository identity (proves the password), snapshot. A share
        # that cannot be written (mounted ro, or refusing a write probe: the drill's read-only
        # export) is read without a lock (--no-lock) and mounted :ro into restic (SC-067).
        self.read_only = backup.check_share(backup.target, writable=False, probe=True)
        if backup.repository_id(password_file=self.password_copy, read_only=self.read_only) != backup.target["repository_id"]:
            raise Preflight("Repository on the share is not the recorded one", "wrong-repository")
        if self.replace:
            running = [service for service, row in backup.containers(self.project).items() if row["state"] == "running"]
            if running:
                raise BackupError("Stop production first (deploy/prod.py stop); its containers are running")
        snapshot = self.resolve_snapshot(snapshot, source_project)
        restore_caps = ("CHOWN", "DAC_OVERRIDE", "DAC_READ_SEARCH", "FOWNER", "FSETID")
        # 2. Host-side pieces into the private target: manifest, dump, roles and the state root.
        private_directory(staging)
        self.restic_restore(snapshot, "staging", (str(staging), "/target", "rw"), caps=restore_caps)
        manifest = json.loads((staging / "manifest.json").read_text())
        if manifest.get("version") != MANIFEST_VERSION:
            raise BackupError("Snapshot manifest has an unsupported format")
        extract = private_directory(self.target / "state")
        self.restic_restore(snapshot, "state", (str(extract), "/target", "rw"), caps=restore_caps)
        release = release_config(extract)
        self.check_state_conflicts(extract)
        # 3. Volumes: production's are removed only now, with the explicit flag; others are fresh.
        if self.replace:
            for container in backup.containers(self.project).values():
                self.docker("rm", container["id"], timeout=120)
            for name in REPLACED_VOLUMES:
                if f"{self.project}_{name}" in self.existing_volumes:
                    self.docker("volume", "rm", f"{self.project}_{name}", timeout=120)
        for name in RESTORED_VOLUMES:
            self.docker("volume", "create", "--label", "com.docker.compose.project=" + self.project,
                        "--label", "com.docker.compose.volume=" + name,
                        "--label", "anj-cloud.restored-from=" + snapshot[:12], f"{self.project}_{name}", timeout=60)
        for name in ("nextcloud", "access"):
            self.restic_restore(snapshot, name, (f"{self.project}_{name}", "/target", "rw"), caps=restore_caps)
        self.helper("-c", "mv /v/backup-staging/registry.sqlite /v/registry.sqlite && rmdir /v/backup-staging",
                    mounts=[(f"{self.project}_access", "/v", "rw")], caps=("DAC_OVERRIDE", "FOWNER"))
        checks = {}
        config_digest = self.helper("-c", HASH_STDIN, mounts=[(f"{self.project}_nextcloud", "/var/www/html", "ro")],
                                    caps=("DAC_READ_SEARCH",), data=b"/var/www/html/config/config.php\n").stdout.decode().strip()
        checks["config_sentinel"] = config_digest == manifest["sentinels"]["config_sha256"]
        # 4. A fresh PostgreSQL from the release's own image, then roles and pg_restore.
        checks.update(self.restore_database(release, manifest, staging / "database.dump", staging / "roles.sql",
                                            extract / "secrets" / "database"))
        # 5. Registry rows and certificate fingerprints, read with the release image when present.
        checks["registry"] = self.verify_registry(release, manifest)
        # 6. The snapshot was taken in maintenance; the restored instance starts out of it.
        self.helper("-r", UNMAINTAIN, mounts=[(f"{self.project}_nextcloud", "/var/www/html", "rw")],
                    user="www-data", entrypoint="php", image=release["services"]["nextcloud"]["image"])
        # 7. The state root last.
        moved = self.place_state(extract)
        failed = [name for name, value in checks.items() if value is False]
        result = {"project": self.project, "snapshot": snapshot[:12], "source_release": manifest.get("release"),
                  "host": manifest.get("host"), "state_entries": moved, "volumes": list(RESTORED_VOLUMES),
                  "checks": checks, "manifest": {"filecache_rows": manifest["filecache_rows"],
                                                "registry_devices": manifest["registry"]["devices"],
                                                "captured_at": manifest["captured_at"]}}
        # Recorded for drill-checks (no secrets: counts, digests' equality, names of checks).
        write_json(self.state_root / paths.RUN_DIR.name / LAST_RESTORE,
                   {key: result[key] for key in ("snapshot", "source_release", "checks", "manifest")})
        if failed:
            error = BackupError("Restored data does not match the snapshot manifest: " + ", ".join(failed),
                                "restore-mismatch")
            error.checks = checks
            raise error
        return result

    def state_plan(self, extract):
        """Entries to place: top-level ones, except secrets/, which merges file by file so the
        host's own restic password (never in a snapshot) and backup config stay where they are."""
        plan = []
        for entry in sorted(extract.iterdir(), key=lambda path: path.name):
            if entry.name in STATE_LOCAL:
                continue
            if entry.name == "secrets" and entry.is_dir():
                for child in sorted(entry.iterdir(), key=lambda path: path.name):
                    if child.name != SECRET_NAME:
                        plan.append(Path("secrets") / child.name)
            else:
                plan.append(Path(entry.name))
        return plan

    def check_state_conflicts(self, extract):
        if self.state_root.exists():
            checked_directory(self.state_root, "--state-root")
            conflicts = [str(item) for item in self.state_plan(extract) if os.path.lexists(self.state_root / item)]
            if conflicts and not self.replace:
                raise BackupError("--state-root already holds entries this snapshot restores; use an empty state "
                                  "root (only secrets/restic-password and backup.json may be there)")

    def place_state(self, extract):
        if not self.state_root.exists():
            private_directory(self.state_root)
        self.check_state_conflicts(extract)
        plan = self.state_plan(extract)
        aside = None
        for item in plan:
            if os.path.lexists(self.state_root / item):
                aside = aside or private_directory(self.state_root / ("replaced-" + stamp(self.backup.now())))
                private_directory((aside / item).parent)
                os.replace(self.state_root / item, aside / item)
        for item in plan:
            private_directory((self.state_root / item).parent)
            os.replace(extract / item, self.state_root / item)
        shutil.rmtree(extract)
        return [str(item) for item in plan]

    def restore_database(self, release, manifest, dump, roles=None, password=None):
        db = release["services"]["db"]
        env = db.get("environment") or {}
        user, name = env.get("POSTGRES_USER", "postgres"), env.get("POSTGRES_DB", "postgres")
        container = f"{self.project}-restore-db-{secrets.token_hex(3)}"
        password = password or self.state_root / "secrets" / "database"
        self.docker("run", "--detach", *LIMITS, "--name", container, "--network", "none",
                    "--label", "anj-cloud.backup=" + self.project,
                    "--env", "POSTGRES_USER=" + user, "--env", "POSTGRES_DB=" + name,
                    "--env", "POSTGRES_PASSWORD_FILE=/run/secrets/database",
                    "--volume", f"{password}:/run/secrets/database:ro",
                    "--volume", f"{self.project}_database:/var/lib/postgresql/data", db["image"], timeout=300)
        try:
            deadline = time.monotonic() + 300
            while True:
                # The entrypoint's init server listens on the socket only; TCP answers once it is final.
                if self.docker("exec", container, "pg_isready", "--host", "127.0.0.1", "--username", user,
                               "--dbname", name, timeout=30, check=False).returncode == 0:
                    break
                if time.monotonic() > deadline:
                    raise BackupError("Fresh PostgreSQL did not become ready")
                self.runner.sleep(2)
            if roles is not None and roles.exists():
                # The bootstrap role already exists in the fresh cluster; every other role is created.
                bootstrap = re.compile(r'^CREATE ROLE "?' + re.escape(user) + r'"?;$')
                script = "\n".join(line for line in roles.read_text().splitlines() if not bootstrap.match(line))
                self.runner.run(["docker", "exec", "--interactive", container, "psql", "--no-psqlrc", "--quiet",
                                 "--username", user, "--dbname", "postgres", "--set", "ON_ERROR_STOP=1"],
                                data=script.encode(), timeout=600)
            with open(dump, "rb") as stream:
                self.runner.run(["docker", "exec", "--interactive", container, "pg_restore", "--username", user,
                                 "--dbname", name, "--exit-on-error", "--single-transaction"],
                                data=stream.read(), timeout=6 * 3600)
            prefix = manifest.get("table_prefix", "oc_")

            def psql(sql):
                return self.docker("exec", container, "psql", "--no-psqlrc", "--username", user, "--dbname", name,
                                   "--tuples-only", "--no-align", "--field-separator", "\t", "--command", sql,
                                   timeout=300).stdout.decode().strip()

            checks = {"filecache_rows": int(psql(f"SELECT count(*) FROM {prefix}filecache")) == manifest["filecache_rows"]}
            sentinel = manifest["sentinels"].get("user_file")
            if sentinel:
                row = psql(SENTINEL_BY_ID.format(p=prefix, fileid=int(sentinel["fileid"])))
                if not row:
                    checks["user_file_sentinel"] = False
                else:
                    _, uid, path = row.split("\t", 2)
                    datadir = manifest.get("datadir") or "/var/www/html/data"
                    if not datadir.startswith("/var/www/html/"):
                        raise BackupError("Nextcloud data directory is outside its volume")
                    digest = self.helper("-c", HASH_STDIN,
                                         mounts=[(f"{self.project}_nextcloud", "/var/www/html", "ro")],
                                         caps=("DAC_READ_SEARCH",),
                                         data=f"{datadir}/{uid}/{path}\n".encode()).stdout.decode().strip()
                    checks["user_file_sentinel"] = digest == sentinel["sha256"]
            else:
                checks["user_file_sentinel"] = None
            return checks
        finally:
            self.docker("stop", "--time", "60", container, timeout=120, check=False)
            self.docker("rm", "--force", container, timeout=60, check=False)

    def verify_registry(self, release, manifest):
        image = release.get("access_image")
        if not image or self.docker("image", "inspect", image, timeout=60, check=False).returncode:
            return None  # e.g. a new host before the release image is rebuilt
        output = self.helper("-c", REGISTRY_SNAPSHOT, "verify", "registry.sqlite",
                             mounts=[(f"{self.project}_access", "/var/lib/anj", "ro")],
                             entrypoint="python", image=image).stdout
        found = json.loads(output)
        expected = manifest["registry"]
        return bool(found.get("integrity")) and found["devices"] == expected["devices"] and found["digest"] == expected["digest"]


def release_config(state_root):
    """The restored release: spec A's stack.json, release/<commit12>/compose.json and release.json."""
    stack = read_json(state_root / "stack.json", {}) or {}
    release = stack.get("release")
    directories = sorted(path for path in (state_root / "release").glob("*") if path.is_dir()) \
        if (state_root / "release").is_dir() else []
    if release:
        directory = state_root / "release" / release[:12]
    elif len(directories) == 1:
        directory = directories[0]
    else:
        raise BackupError("Restored state root has no single recorded release")
    compose = read_json(directory / "compose.json")
    record = read_json(directory / "release.json", {}) or {}
    if not compose:
        raise BackupError("Restored release has no compose file")
    host = stack.get("host") or record.get("host")
    commit = release or record.get("commit") or directory.name
    repository = stack.get("image_repository")
    image = record.get("image") or (f"{repository}:{commit[:12]}" if repository else None)
    return {"services": compose["services"], "host": host, "commit": commit, "access_image": image,
            "directory": directory}


# Drill ----------------------------------------------------------------------------------
#
# Rev7: "rebuild a VM and restore into it" (decision #84; spec #21 Qualification Budget, #89 (6)).
# On the VM host, `drill` creates anj-qual with the backup share read-only, hands the restore to the
# bootstrap's restore mode (spec #21) with ddns off, runs `drill-checks` inside the drill VM, writes
# the receipt and always destroys anj-qual. Nothing here starts a container on the VM host.

def openssl_pubkey(argv):
    return subprocess.run(["openssl", *argv], capture_output=True, timeout=60, check=True).stdout


def in_blackout(moment):
    """03:20-05:00 local belongs to the nightly backup, update run and guarded reboot."""
    local = moment.astimezone()
    start, end = DRILL_BLACKOUT
    minutes = local.hour * 60 + local.minute
    return start[0] * 60 + start[1] <= minutes < end[0] * 60 + end[1]


# The drill VM runs the stack without its ingress: no haproxy, no forward, no DDNS (coordinator
# ruling on A's #39). Derived from spec #20's app list, never redefined. Nor the media fetch worker
# (spec #42): a drill makes no downloads; restored waiting jobs just wait.
DRILL_APPS = tuple(app for app in paths.STACK_APPS if app not in ("haproxy", "fetch-net", "fetch"))
# Where the drill puts the password inside anj-qual (tmpfs; gone with the VM, decision #95).
DRILL_PASSWORD_DIR = "/run/anj-drill"
DRILL_PASSWORD = DRILL_PASSWORD_DIR + "/" + paths.RESTIC_PASSWORD.name

DRILL_ANSWERS = f"""# anj-qual restore drill (spec #22 rev7): never acts as production.
ddns = "off"
alerts_tag = "drill"
restic_password_file = "{DRILL_PASSWORD}"
start_stack = false
data_disk_init = true
"""


# Spec #21's the VM host script (PR #40, deploy/host/halo-vm.sh): its ssh aliases (anj-prod, anj-qual)
# live in one ssh_config; its qualification-VM ownership tag is a run id written to the domain
# description and to a tag file before anything is defined; --qual exits 3 on qual-busy.
# SC-067: a fresh anj-qual's clock may still be unsynchronized when ssh answers, and the
# bootstrap's preflight refuses an unsynchronized clock; the drill waits for NTP, bounded.
CLOCK_SYNC_TIMEOUT = 300
CLOCK_SYNC_INTERVAL = 5
CLOCK_SYNC_COMMAND = "timedatectl show -p NTPSynchronized --value"
# SC-067: the drill never writes to the share, and the VM host serves it read-only (<readonly/>), but the
# guest's own fstab line mounts it rw; the drill mounts it ro itself before the bootstrap (which
# then leaves an existing mount alone), and confirms `ro` is in effect.
# The mount point is created only when nothing is mounted there and it is missing: on a mounted
# share it is the share's root, never chmodded (PR #90 review L1).
def drill_share_mount(mount=paths.BACKUP_MOUNT, tag=paths.BACKUP_TAG):
    return (f"{{ if findmnt --mountpoint {mount} >/dev/null; "
            f"then sudo mount -o remount,ro {mount}; "
            f"else {{ [ -d {mount} ] || sudo install -d -m 0755 {mount}; }} && "
            f"sudo mount -t virtiofs -o ro,nodev,nosuid,noexec {tag} {mount}; fi; }} && "
            f"findmnt -n -o OPTIONS --mountpoint {mount} | tr , '\\n' | grep -qx ro")


DRILL_SHARE_MOUNT = drill_share_mount()


HALO_SSH_CONFIG = Path.home() / ".local" / "share" / "anj-cloud" / "prod-vm" / "ssh_config"
QUAL_TAG_FILE = Path.home() / ".local" / "state" / "anj-cloud-qual" / "run-id"
QUAL_BUSY_EXIT = 3
QUAL_DESCRIPTION = re.compile(r"<description>anj-qual run-id=([^<]*)</description>")
OWNER_UNKNOWN = object()


def stage_bootstrap(runner, target, commit="HEAD"):
    """Spec #21's deploy/vm/stage.py: git archive <commit> (default this checkout's HEAD) unpacked in the VM at
    /var/lib/anj-cloud-setup/src, whose anj-cloud-setup then installs (or restores) the release."""
    from deploy.vm import stage
    try:
        return stage.stage(runner, target, commit)
    except (RuntimeError, OSError, subprocess.SubprocessError):
        raise BackupError("Could not stage the bootstrap into anj-qual", "stage-failed") from None


def ssh_argv(target, command):
    return ["ssh", "-F", str(HALO_SSH_CONFIG), "-T", "-o", "BatchMode=yes", target, command]


LIBVIRT = "qemu:///system"
QUAL_DOMAIN = "anj-qual"


def virsh(runner, *args, timeout=60):
    """Every virsh call: C locale (output never localised), never raises on a failure."""
    return runner.run(["env", "LC_ALL=C", "virsh", "-c", LIBVIRT, *args], timeout=timeout, check=False)


def domain_listed(runner, name):
    """Whether `virsh list --all --name` lists the domain; None when that command fails (unknown).
    No error message is interpreted: virsh reports any lookup failure the same way."""
    result = virsh(runner, "list", "--all", "--name")
    if result.returncode:
        return None
    return name in {line.strip() for line in (result.stdout or b"").decode(errors="replace").splitlines()}


def domain_state(runner, name):
    """Read-only libvirt view: (id, state) of a domain, or None when it does not exist."""
    result = virsh(runner, "dominfo", name)
    if result.returncode:
        return None
    fields = dict(line.split(":", 1) for line in result.stdout.decode().splitlines() if ":" in line)
    return (fields.get("Id", "").strip(), fields.get("State", "").strip())


def pipe_password(runner, source_argv, ssh_target, destination):
    """Decision #95: the producer's stdout feeds the consumer's stdin directly, so the password is
    never in this process, an argument, a log, the receipt or anywhere but the two 0600 files."""
    directory = str(Path(destination).parent)
    consumer = ssh_argv(ssh_target, f"sudo install -d -m 700 -o {paths.VM_USER} -g {paths.VM_GROUP} {directory} && "
                                    f"sudo install -m 600 -o {paths.VM_USER} -g {paths.VM_GROUP} /dev/stdin {destination}")
    if not runner.pipe(list(source_argv), consumer, timeout=300):
        raise BackupError("Could not move the repository password into anj-qual", "password-move-failed")


class QualVM:
    """One anj-qual per run (#89 (6)), owned through spec #21's run id (PR #40), never a second tag.

    `ensure_free()` refuses (qual-busy) when any anj-qual object exists, before anything is
    touched. `create()` runs inside the caller's try and passes `--run-id`; halo-vm.sh writes the
    run id into its tag file and the domain description before defining anything, and exits 3
    when another run's anj-qual is there. `destroy()` runs `--qual-destroy --run-id` (never
    --force) only after positively reading this run's id from the description or the tag file;
    otherwise it leaves anj-qual and reports who owns it. Nothing here retitles or retags."""

    def __init__(self, runner, halo_vm, qual_args, run_id, tag_file=None):
        self.runner = runner
        self.halo_vm = str(halo_vm)
        self.qual_args = list(qual_args)
        self.run_id = run_id
        self.tag_file = Path(tag_file or QUAL_TAG_FILE)
        self.invoked = False
        self.qual_exit = None

    def present(self):
        """Any anj-qual libvirt object (a partial create may leave only the network or pool); a
        domain list that fails counts as present."""
        listed = domain_listed(self.runner, QUAL_DOMAIN)
        if listed is None or listed:
            return True
        return any(virsh(self.runner, kind, QUAL_DOMAIN).returncode == 0 for kind in ("net-info", "pool-info"))

    def owner(self):
        """The run id halo-vm.sh recorded. While a domain named anj-qual is defined, only its
        description counts (a stale or concurrent tag file never makes a defined domain ours);
        the tag file counts only when no domain is defined (a partial create that left only the
        network or pool). Absent means `virsh list --all --name` succeeded without anj-qual; any
        virsh failure leaves ownership unknown."""
        listed = domain_listed(self.runner, QUAL_DOMAIN)
        if listed is None:
            return OWNER_UNKNOWN
        if listed:
            result = virsh(self.runner, "dumpxml", "--inactive", QUAL_DOMAIN)
            if result.returncode:
                return OWNER_UNKNOWN
            found = QUAL_DESCRIPTION.search((result.stdout or b"").decode(errors="replace"))
            return (found.group(1).strip() or None) if found else None
        try:
            return self.tag_file.read_text().strip() or None
        except OSError:
            return None

    def ensure_free(self):
        if self.present():
            owner = self.owner()
            raise BackupError(f"anj-qual already exists (run-id {owner if isinstance(owner, str) else 'unknown'}); "
                              "nothing was touched",
                              "qual-busy")

    def create(self):
        """Call after ensure_free(), inside the try whose finally calls destroy()."""
        self.invoked = True
        result = self.runner.run([self.halo_vm, "--qual", "--run-id", self.run_id, *self.qual_args],
                                 timeout=1800, check=False)
        self.qual_exit = result.returncode
        if result.returncode == QUAL_BUSY_EXIT:
            raise BackupError("anj-qual was created by another run first (qual-busy)", "qual-busy")
        if result.returncode:
            raise BackupError("halo-vm.sh --qual failed", "qual-create-failed")

    def destroy(self):
        if not self.invoked:
            return {"destroyed": False, "reason": "not created by this run"}
        if self.qual_exit == QUAL_BUSY_EXIT:
            owner = self.owner()
            return {"destroyed": False, "reason": "qual-busy: anj-qual is another run's",
                    "owner": owner if isinstance(owner, str) else None}
        owner = self.owner()
        if owner is OWNER_UNKNOWN:
            return {"destroyed": False, "reason": "anj-qual ownership unknown (virsh error); nothing destroyed"}
        if owner != self.run_id:
            if not self.present():
                return {"destroyed": True, "note": "nothing was created"}
            return {"destroyed": False, "owner": owner,
                    "reason": f"anj-qual belongs to run-id {owner}" if owner else "anj-qual carries no run id"}
        try:
            result = self.runner.run([self.halo_vm, "--qual-destroy", "--run-id", self.run_id], timeout=1800, check=False)
        except (subprocess.TimeoutExpired, OSError) as error:
            return {"destroyed": False, "reason": type(error).__name__}
        if result.returncode == QUAL_BUSY_EXIT:
            owner = self.owner()
            return {"destroyed": False, "reason": "qual-tag-mismatch (halo-vm.sh refused)",
                    "owner": owner if isinstance(owner, str) else None}
        return {"destroyed": not self.present()}


class Drill:
    """The VM host side, unattended (decision #95). Command shapes of spec #21's tools are parameters,
    recorded in the receipt."""

    def __init__(self, runner, *, halo_vm, ssh_target="anj-qual", source=paths.RELEASE_CURRENT, host=None,
                 evidence_base=QUALIFICATION, clock=time.time, qual_args=("--share-readonly",),
                 password_source=None, stager=None, sleep=time.sleep, clock_sync_timeout=CLOCK_SYNC_TIMEOUT):
        self.runner = runner
        self.sleep = sleep
        self.clock_sync_timeout = clock_sync_timeout
        # Spec #21 (B2): a fresh anj-qual has no release/current yet; the bootstrap is staged from
        # this checkout's HEAD and installs the restored release itself.
        self.stager = stager or stage_bootstrap
        self.halo_vm = str(halo_vm)
        self.ssh_target = ssh_target
        self.source = str(source)
        self.host = host
        self.evidence_base = Path(evidence_base)
        self.clock = clock
        self.qual_args = list(qual_args)
        # Decision #95: anj-prod's 0600 password file straight into anj-qual over an SSH pipe.
        self.password_source = list(password_source or ssh_argv("anj-prod", f"sudo cat {paths.RESTIC_PASSWORD}"))

    def now(self):
        return utcnow(self.clock)

    def ssh(self, command, *, data=None, timeout=3600, check=True):
        return self.runner.run(ssh_argv(self.ssh_target, command), data=data, timeout=timeout, check=check)

    def wait_clock_synchronized(self):
        """Polls the drill VM's NTPSynchronized every CLOCK_SYNC_INTERVAL s, at most
        clock_sync_timeout s; returns the polls taken, or fails with reason clock-unsynced."""
        polls = max(1, -(-self.clock_sync_timeout // CLOCK_SYNC_INTERVAL)) + 1
        for poll in range(polls):
            result = self.ssh(CLOCK_SYNC_COMMAND, timeout=30, check=False)
            if not result.returncode and (result.stdout or b"").strip() == b"yes":
                return poll + 1
            if poll + 1 < polls:
                self.sleep(CLOCK_SYNC_INTERVAL)
        raise BackupError(f"anj-qual's clock was not synchronized within {self.clock_sync_timeout} s "
                          "(timedatectl NTPSynchronized); the bootstrap would refuse it", "clock-unsynced")

    def mount_share_read_only(self):
        if self.ssh(DRILL_SHARE_MOUNT, timeout=120, check=False).returncode:
            raise BackupError(f"Could not mount the backup share read-only at {paths.BACKUP_MOUNT} in anj-qual",
                              "share-mount-failed")

    def run(self):
        started = self.now()
        receipt = {"drill": "f15-restore-drill", "spec": 22, "revision": "rev7", "vm": "anj-qual",
                   "started_at": iso(started), "checks": {}, "result": "failed", "qual_args": self.qual_args,
                   "apps": list(DRILL_APPS), "commands": {"halo_vm": self.halo_vm, "ssh_target": self.ssh_target,
                                                          "source": self.source}}
        if in_blackout(started):
            raise BackupError("The drill never runs between 03:20 and 05:00", "blackout")
        run_id = stamp(started) + "-" + secrets.token_hex(3)
        receipt["run_id"] = run_id
        qual = QualVM(self.runner, self.halo_vm, self.qual_args, run_id)
        prod_before = self.domain_state("anj-prod")
        qual.ensure_free()  # qual-busy refuses here, before anything is touched
        try:
            qual.create()  # inside the try: a partial create is destroyed and a receipt written
            receipt["clock_sync_polls"] = self.wait_clock_synchronized()
            self.mount_share_read_only()
            receipt["share_mounted_read_only"] = True
            answers = "/tmp/anj-drill-answers.toml"
            self.ssh(f"umask 077 && cat > {answers}", data=DRILL_ANSWERS.encode(), timeout=60)
            pipe_password(self.runner, self.password_source, self.ssh_target, DRILL_PASSWORD)
            setup = self.stager(self.runner, self.ssh_target)
            receipt["commands"]["staged_commit"] = setup["commit"][:12]
            restore = self.ssh(f"sudo {setup['setup']} --restore-from {paths.BACKUP_MOUNT} "
                               f"--answers {answers}", timeout=6 * 3600, check=False)
            if restore.returncode:
                raise BackupError("Bootstrap restore mode failed in the drill VM", "restore-failed")
            command = f"python3 -I {self.source}/deploy/backup.py drill-checks"
            if self.host:
                command += f" --host {self.host}"
            output = self.ssh(command, timeout=3600, check=False)
            result = json.loads(output.stdout or b"{}")
            receipt["checks"] = result.get("checks", {})
            receipt["snapshot"] = result.get("snapshot")
            if result.get("error"):
                receipt["error"] = result["error"]
            failed = [key for key, value in receipt["checks"].items() if value is False]
            receipt["result"] = "pass" if receipt["checks"] and not failed and not result.get("error") else "failed"
            if failed:
                receipt["failed_checks"] = failed
        except BackupError as error:
            receipt["error"], receipt["reason"] = str(error), error.reason
        except (subprocess.TimeoutExpired, OSError, ValueError) as error:
            receipt["error"], receipt["reason"] = type(error).__name__, "failed"
        finally:
            # The anj-qual this run created (with its restored keys and the password copy) never
            # outlives the drill; another run's is never touched.
            outcome = qual.destroy()
            receipt["qual_destroyed"] = outcome["destroyed"]
            if not outcome["destroyed"]:
                receipt["qual_destroy_issue"] = outcome.get("reason")
                if outcome.get("owner"):
                    receipt["qual_owner"] = outcome["owner"]
            receipt["prod_untouched"] = self.domain_state("anj-prod") == prod_before
        if not receipt.get("qual_destroyed") or not receipt["prod_untouched"]:
            receipt["result"] = "failed"
        receipt["finished_at"] = iso(self.now())
        evidence = self.evidence_base / f"f15-restore-drill-{stamp(started)}"
        evidence.mkdir(mode=0o700, parents=True, exist_ok=True)
        write_json(evidence / "receipt.json", receipt)
        receipt["receipt"] = str(evidence / "receipt.json")
        return receipt

    def domain_state(self, name):
        return domain_state(self.runner, name)


class DrillChecks:
    """Inside the drill VM, after the bootstrap's restore: start the five stack apps (never
    haproxy), then the spec #22 Restore and Drill 3 checks, all through the gateway socket."""

    def __init__(self, backup, *, host=None, image=None, ready_timeout=600):
        self.backup = backup
        self.runner = backup.runner
        stack = read_json(backup.state_root / paths.STACK_CONFIG.name, {}) or {}
        self.host = host or stack.get("host")
        self.release = stack.get("release")
        self.image = image or (f"{stack.get('image_repository') or paths.IMAGE_REPOSITORY}:{self.release[:12]}"
                               if self.release else None)
        self.ready_timeout = ready_timeout

    def run(self):
        result = {"checks": {}}
        with restore_window(self.backup.state_root, self.backup.project, "drill", self.backup.now):
            try:
                if not (self.host and self.image):
                    raise BackupError("The restored stack records no host or release")
                last = read_json(self.backup.run_dir / LAST_RESTORE, {}) or {}
                result["snapshot"] = last.get("snapshot")
                checks = result["checks"]
                checks.update({"restore_" + key: value for key, value in (last.get("checks") or {}).items()})
                if not last:
                    checks["restore_recorded"] = False
                checks["issuer_matches_key"] = self.issuer_matches_key()
                checks["stack_started_without_haproxy"] = self.start_stack()
                containers = self.backup.containers()
                health = self.backup.exec("access", ["python", "-m", "access.health"], timeout=60, containers=containers)
                checks["production_healthcheck"] = json.loads(health.stdout) == {"status": "ready"}
                checks["nextcloud_pgsql"] = self.backup.occ("config:system:get", "dbtype", containers=containers) == "pgsql"
                checks["nextcloud_redis_locking"] = (self.backup.occ("config:system:get", "memcache.locking",
                                                                     containers=containers) == "\\OC\\Memcache\\Redis")
                checks["ddns_absent"] = paths.DDNS_APP not in self.pm2_apps()
                checks.update(self.synthetic_device())
            except BackupError as error:
                result["error"] = str(error)
            except (subprocess.TimeoutExpired, OSError, ValueError, KeyError) as error:
                result["error"] = type(error).__name__
        return result

    def pm2_apps(self):
        output = self.runner.run(["pm2", "jlist"], timeout=60, check=False).stdout
        try:
            return {app.get("name"): (app.get("pm2_env") or {}).get("status") for app in jlist_rows(output)}
        except ValueError:
            return {}

    def container_ready(self, service):
        output = self.runner.run(["docker", "inspect", "--format", "{{json .State}}", f"{paths.PROJECT}-{service}-1"],
                                 timeout=30, check=False)
        try:
            state = json.loads(output.stdout) if not output.returncode else {}
        except ValueError:
            return False
        return bool(state.get("Running")) and (state.get("Health") or {}).get("Status") in (None, "healthy")

    def start_stack(self):
        """The five apps through spec #20's own PM2 ecosystem, in dependency order; haproxy is
        never started, so the drill VM has no ingress."""
        ecosystem = self.backup.state_root / paths.RELEASE_DIR.name / self.release[:12] / "ecosystem.config.js"
        running = self.pm2_apps()
        for app in DRILL_APPS:
            if running.get(app) != "online":
                self.runner.run(["pm2", "start", str(ecosystem), "--only", app], timeout=120)
        deadline = time.monotonic() + self.ready_timeout
        for app in DRILL_APPS:
            while not self.container_ready(paths.COMPOSE_SERVICE[app]):
                if time.monotonic() > deadline:
                    raise BackupError(f"Stack app did not become ready: {app}")
                self.runner.sleep(2)
        haproxy = paths.COMPOSE_SERVICE["haproxy"]
        return "haproxy" not in self.pm2_apps() and not self.container_ready(haproxy)

    def issuer_matches_key(self):
        operator = self.backup.state_root / paths.OPERATOR_DIR.name
        certificate = openssl_pubkey(["x509", "-in", str(operator / "issuer.crt"), "-noout", "-pubkey"])
        key = openssl_pubkey(["pkey", "-in", str(operator / "issuer.key"), "-pubout"])
        return certificate == key

    def client(self, *args, state):
        directory = Path(tempfile.mkdtemp(prefix="anj-drill-client-"))
        directory.chmod(0o755)
        shutil.copyfile(Path(__file__).resolve().parent / "backup_drill_client.py", directory / "client.py")
        shutil.copyfile(self.backup.state_root / paths.OPERATOR_DIR.name / "issuer.crt", directory / "issuer.crt")
        for name in ("client.py", "issuer.crt"):
            (directory / name).chmod(0o644)
        try:
            # Straight to the gateway socket with a PROXY v2 LOCAL header (no HAProxy in the drill VM),
            # as the gateway user with the socket group.
            output = self.runner.run(
                ["docker", "run", "--rm", *LIMITS, "--network", "none", "--cap-drop", "ALL",
                 "--security-opt", "no-new-privileges", "--user", f"{paths.GATEWAY_UID}:{paths.GATEWAY_GID}",
                 "--volume", f"{paths.GATEWAY_SOCKET_DIR}:{paths.GATEWAY_SOCKET_DIR}",
                 "--volume", f"{directory}:/drill:ro", "--volume", f"{state}:/state", self.image,
                 "python", "/drill/client.py", "--socket", str(paths.GATEWAY_SOCKET),
                 "--host", self.host, "--cafile", "/drill/issuer.crt", "--state", "/state", *args], timeout=300)
            return json.loads(output.stdout)
        finally:
            shutil.rmtree(directory, ignore_errors=True)

    def synthetic_device(self):
        """A drill-only account and device: 1-day leaf, enrolled and used over the socket."""
        from deploy.access_operator import Operator  # spec #20 operator tooling in the release source
        from deploy.prod import ProdStack
        operator = Operator(ProdStack(paths.PROJECT, self.backup.state_root))
        uid = "drill-" + secrets.token_hex(4)
        operator.user_add(uid, "Restore drill")
        invitation = operator.call("invite", uid=uid, rights="write")
        state = Path(tempfile.mkdtemp(prefix="anj-drill-device-"))
        try:
            self.runner.run(["docker", "run", "--rm", *LIMITS, "--network", "none", "--cap-drop", "ALL",
                             "--cap-add", "CHOWN", "--user", "0:0", "--volume", f"{state}:/x", "--entrypoint", "sh",
                             self.image, "-c", f"chown {GATEWAY_USER} /x"], timeout=120)
            pending = self.client("enroll", "--code", invitation["code"], state=state)
            real_sign = operator.sign

            def one_day(csr, target, identity, usage="clientAuth", days=None):
                return real_sign(csr, target, identity, usage, days=1 if usage == "clientAuth" else days)

            operator.sign = one_day
            operator.approve(pending["pairing_id"], pending["fingerprint"])
            used = self.client("dav", "--code", invitation["code"], state=state)
        finally:
            self.runner.run(["docker", "run", "--rm", *LIMITS, "--network", "none", "--cap-drop", "ALL",
                             "--cap-add", "DAC_OVERRIDE", "--user", "0:0", "--volume", f"{state}:/x",
                             "--entrypoint", "sh", self.image, "-c", "rm -rf /x/*"], timeout=120, check=False)
            shutil.rmtree(state, ignore_errors=True)
        return {"enroll_without_certificate_401": pending.get("dav_without_certificate") == 401,
                "device_leaf_one_day": 0 < used.get("leaf_hours", 0) <= 24.5,
                "mtls_dav_write": used.get("put") in (201, 204),
                "mtls_dav_read": used.get("get") == 200 and used.get("sha256_match") is True}


# CLI ------------------------------------------------------------------------------------

def terminate(signum, frame):
    """systemd stop, a hang-up or Ctrl-C: unwind through every finally path (maintenance off,
    marker cleared). A dropped ssh session SIGHUPs a backup started from a terminal (PR #58
    delta review D2)."""
    raise KeyboardInterrupt


TERMINATING_SIGNALS = (signal.SIGTERM, signal.SIGHUP, signal.SIGINT)


def release_switch_running(run_dir):
    """prod.py redeploy holds the operations lock and has written run/release-switch (its pid)."""
    try:
        pid = int(json.loads((Path(run_dir) / paths.RELEASE_SWITCH.name).read_text())["pid"])
        os.kill(pid, 0)
    except (OSError, ValueError, KeyError, TypeError):
        return False
    return True

def emit(result, out=None):
    out = out or sys.stdout
    out.write(json.dumps(result, indent=2, sort_keys=True) + "\n")
    out.flush()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--project", default=PROJECT, help="anj-cloud-prod (default) or a review/test project")
    parser.add_argument("--state-root", help=f"State root (production: {DEFAULT_STATE_ROOT})")
    sub = parser.add_subparsers(dest="command", required=True)
    init = sub.add_parser("init", help="Create restic/ in the backup share and record its ID")
    init.add_argument("--show-escrow", action="store_true", help="Show the repository password on this terminal")
    init.add_argument("--mount", help="Review/test projects only: scratch share mount point")
    init.add_argument("--tag", help="Review/test projects only: scratch virtiofs tag")
    init.add_argument("--alert-command", nargs="+", help="Dispatcher command (default: spec #21's anj-alert)")
    init.add_argument("--adopt", action="store_true", help="Record the existing repository (rebuilt VM, escrowed password)")
    init.add_argument("--password-file", help="With --adopt: the escrowed password, copied into secrets/ (0600)")
    sub.add_parser("show-password", help="Show the repository password again on this terminal (read-only)")
    run = sub.add_parser("run", help="Nightly backup (30-minute hard cap on the maintenance window)")
    run.add_argument("--cap-seconds", type=int, help="Review/test projects only: shortened cap")
    run.add_argument("--limit-upload", type=int, help="Review/test projects only: restic upload limit, KiB/s")
    seed = sub.add_parser("seed", help="One-off first full backup at a time the operator schedules")
    seed.add_argument("--cap", type=int, required=True, help="Maintenance cap in minutes, set by the operator")
    check = sub.add_parser("check", help="restic check")
    check.add_argument("--read-data-subset", action="store_true", help="Also read a 5%% subset of the data")
    status = sub.add_parser("status", help="JSON status")
    status.add_argument("--alert-stale", action="store_true", help="Alert once after 36 h without success, or on a stale marker")
    window = sub.add_parser("window", help="Window coordination for spec #21's update run and reboot guard")
    window.add_argument("--check", action="store_true", required=True,
                        help="Read-only, root-capable. Exit 0 clear, 1 busy (marker or process), 2 error (alerts daily)")
    restore = sub.add_parser("restore", help="Restore a snapshot into a fresh project")
    restore.add_argument("--snapshot", default="latest")
    restore.add_argument("--target", required=True, help="Empty working directory")
    restore.add_argument("--project", dest="restore_project", required=True, help="Project to restore into")
    restore.add_argument("--state-root", dest="restore_state_root", required=True,
                         help="State root for the restored operator material, secrets and release")
    restore.add_argument("--source-project", help="Snapshot host (default: the backup project)")
    restore.add_argument("--password-file", help="Repository password (default: the backup state root's copy)")
    restore.add_argument("--replace-production", action="store_true")
    restore.add_argument("--confirm")
    checks = sub.add_parser("drill-checks", help="Inside a drill VM after its restore: the drill checks")
    checks.add_argument("--host", help="Production hostname (default: the restored stack.json)")
    drill = sub.add_parser("drill", help="On the VM host: rebuild anj-qual, restore into it, check, destroy (unattended)")
    drill.add_argument("--halo-vm", default=str(Path(__file__).resolve().parent / "host" / "halo-vm.sh"))
    drill.add_argument("--ssh-target", default="anj-qual")
    drill.add_argument("--host", help="Production hostname, passed to drill-checks")
    drill.add_argument("--evidence-base", default=str(QUALIFICATION))
    units = sub.add_parser("units", help="Render the VM system units for spec #21's bootstrap")
    units.add_argument("--source", default=str(paths.RELEASE_CURRENT),
                       help=f"Release source directory in the VM (default {paths.RELEASE_CURRENT})")
    units.add_argument("--out", help="Write the units into this directory (default: print JSON)")
    args = parser.parse_args(argv)
    if args.command == "window":
        # Read-only and root-capable: apt-daily-upgrade's ExecCondition and the reboot guard run as root.
        if args.project != PROJECT and not args.state_root:
            print(json.dumps({"clear": False, "error": "--state-root is required for a review project"}))
            return WINDOW_ERROR
        return window_command(args.state_root or DEFAULT_STATE_ROOT)
    try:
        if os.geteuid() == 0:
            raise BackupError(f"Run as {paths.VM_USER} (or the VM host user for the drill), not root")
        code = 0
        if args.command == "units":
            rendered = render_units(args.source)
            if args.out:
                out = Path(args.out)
                out.mkdir(parents=True, exist_ok=True)
                for name, text in rendered.items():
                    atomic_write(out / name, text, mode=0o644)
                result = {"written": sorted(rendered)}
            else:
                result = {"units": rendered}
            emit(result)
            return 0
        if args.command == "drill":
            result = Drill(Runner(), halo_vm=args.halo_vm, ssh_target=args.ssh_target, host=args.host,
                           evidence_base=args.evidence_base).run()
            emit(result)
            return 0 if result["result"] == "pass" else 1
        if args.project == PROJECT and args.state_root not in (None, str(DEFAULT_STATE_ROOT)):
            raise BackupError("anj-cloud-prod uses its fixed state root")
        backup = Backup(args.project, args.state_root)
        if args.command == "init":
            if args.project == PROJECT and (args.mount or args.tag):
                raise BackupError("Production uses the anj-backup virtiofs share only")
            result = backup.init(mount=args.mount, tag=args.tag, alert_command=args.alert_command,
                                 show_escrow=args.show_escrow, adopt=args.adopt, password_file=args.password_file)
        elif args.command == "run":
            if args.project == PROJECT and (args.cap_seconds or args.limit_upload) and not qualification_vm():
                raise BackupError("Nightly production runs keep the 30-minute cap and no throttle")
            result = backup.run("nightly", cap_seconds=args.cap_seconds, limit_upload=args.limit_upload)
            code = 0 if result["result"] in ("success", "skipped") else 1
        elif args.command == "seed":
            if args.cap < 1:
                raise BackupError("--cap must be at least one minute")
            result = backup.run("seed", cap_seconds=args.cap * 60)
            code = 0 if result["result"] == "success" else 1
        elif args.command == "check":
            result = backup.check(args.read_data_subset)
        elif args.command == "show-password":
            result = backup.show_password()
        elif args.command == "status":
            result = backup.report(alert_stale=args.alert_stale)
        elif args.command == "restore":
            result = Restore(backup, args.restore_project, args.restore_state_root, args.target,
                             replace_production=args.replace_production, confirm=args.confirm,
                             password_file=args.password_file).run(
                                 args.snapshot, args.source_project or backup.project)
        else:
            result = DrillChecks(backup, host=args.host).run()
            code = 0 if result["checks"] and not result.get("error") and all(
                value is not False for value in result["checks"].values()) else 1
        emit(result)
        return code
    except BackupError as error:
        print(json.dumps({"error": str(error), "reason": error.reason}), file=sys.stderr)
        return 1
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        print(json.dumps({"error": type(error).__name__ + "; diagnostic content withheld"}), file=sys.stderr)
        return 1


def install_signal_handlers():
    for number in TERMINATING_SIGNALS:
        signal.signal(number, terminate)


if __name__ == "__main__":
    install_signal_handlers()
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
