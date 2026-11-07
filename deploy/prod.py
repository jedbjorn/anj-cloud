#!/usr/bin/env python3
"""Manage only the anj-cloud production stack inside the anj-prod VM (spec #20 rev7).

Runs as the VM user `anj` (never root) under PM2, the single supervisor (decision #85): one PM2
app per service runs deploy/vm/run-service attached; every container's restart policy is `no`.
State lives in /srv/anj-cloud/state (0700) on the data disk. Images are built from an exact
commit merged into origin/main, from the release's own source.tar (so an OS-disk rebuild needs
no new push), tagged anj-cloud-prod-access:<commit12>. The hostname is a recorded setup
parameter, never hard-coded (decision #64).

    python3 deploy/prod.py setup --host gateway.example.com [--commit C] [--bind-address A] [--household-lan N]
    python3 deploy/prod.py up | check | status | stop
    python3 deploy/prod.py redeploy <commit12>
    python3 deploy/prod.py redeploy [<commit>] --source <git-archive tar>   # no git needed (decision #122)
    python3 deploy/prod.py emergency-stop --reason "<text>"
    python3 deploy/prod.py resume            # only on the operator's instruction (decision #68 (9))

OS-level steps (Docker, PM2, tmpfiles for the sockets, firewall) belong to spec #21's bootstrap.
"""

import argparse
import contextlib
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import socket
import ssl
import stat
import subprocess
import sys
import tarfile
import time

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from deploy.dev import PROJECT as PROJECT_NAME, ROOT, Stack, private_directory, secret_file  # noqa: E402
from deploy.vm import paths, render, stackenv  # noqa: E402
from deploy.vm.pm2json import jlist_rows  # noqa: E402

PROJECT = paths.PROJECT
DEFAULT_STATE_ROOT = paths.STATE_ROOT
DEFAULT_SOCKET_DIR = str(paths.GATEWAY_SOCKET_DIR)
CHECKOUT = ROOT.parent
CONTAINER_UID = paths.GATEWAY_UID
SERVICES = {paths.COMPOSE_SERVICE[app] for app in paths.STACK_APPS}
# Files copied from the release source into state/bin for PM2 (stable script path).
BIN_FILES = {"deploy/vm/run-service": "run-service", "deploy/vm/paths.py": "paths.py", "deploy/vm/stackenv.py": "stackenv.py"}
PM2 = os.environ.get("ANJ_PM2", "pm2")
# Operations apps that run the live release's code (release/current/deploy/vm/ops/<app>) and so
# must restart onto a new release once redeploy switched release/current (decision #114; watchers
# added with #122: no app keeps running old release code). Not ddns: it is a cron_restart app with
# autorestart off whose script is release/current/deploy/ddns.py, so its next 5-minute run starts
# the new release by itself. Not alerts: it runs state/bin/anj-alert (setup's upgrade refreshes it).
RELEASE_OPS_APPS = (paths.CONSOLE_APP, "watchdog", "watchers")
# PM2's own process states -> the documented `status` values (online, stopped, stopping,
# launching, errored, missing). "waiting restart" is PM2 holding a crashed app for its backoff
# restart; "one-launch-status" is an app that ran once and will not be restarted. Anything
# unknown reports "errored". An ingress app held down by the emergency flag reports "stopped".
PM2_STATUS = {"online": "online", "stopped": "stopped", "stopping": "stopping", "launching": "launching",
              "errored": "errored", "waiting restart": "launching", "one-launch-status": "stopped"}
STATUS_VALUES = ("online", "stopped", "stopping", "launching", "errored", "missing")
REASON = re.compile(r"[^\x00-\x1f\x7f]{1,200}")
# Operator file -> the gateway's copy (services/access/install_tls.py NAMES).
TLS_SOURCES = {"issuer_crt": "issuer.crt", "server_crt": "server.crt", "server_key": "server.key"}
# The production image must carry permanent credentials (spec #19, PR #25) and the dev fixes
# (SC-028 up-front 413, GET /v1/files/added).
REQUIRED_COMMITS = {"4c3bb82": "spec #19 permanent credentials (PR #25)",
                    "f554e13": "SC-028 up-front 413 and /v1/files/added"}
# The squashed public history carries those fixes from its exact, known root onwards.
PUBLIC_HISTORY_COMMIT = "cf8994f416bdc9d1f8c8bcc6710932f80221d608"
HOST = re.compile(r"(?=.{4,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]")
COMMIT = re.compile(r"[0-9a-f]{7,40}")
FULL_COMMIT = re.compile(r"[0-9a-f]{40}")


def missing_required_commit(commit, has_commit, is_ancestor):
    """The first missing legacy fix, or None for either supported release history."""
    if has_commit(PUBLIC_HISTORY_COMMIT) and is_ancestor(PUBLIC_HISTORY_COMMIT, commit):
        return None
    for required, purpose in REQUIRED_COMMITS.items():
        if not is_ancestor(required, commit):
            return required, purpose
    return None


class Interrupted(Exception):
    """SIGTERM or SIGHUP while a redeploy runs (setup's timeout, a dropped session): handled like a
    failure, so the fallback runs (decision #122 review H1)."""


@contextlib.contextmanager
def signals_as_interrupts():
    """SIGTERM and SIGHUP raise Interrupted, SIGINT KeyboardInterrupt. The first one also ignores
    every further one at once, before it raises, so a second signal (a forwarded copy) can never
    land between it and the fallback (delta review D1)."""
    def handler(number, _frame):
        for other in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            signal.signal(other, signal.SIG_IGN)
        if number == signal.SIGINT:
            raise KeyboardInterrupt
        raise Interrupted(signal.Signals(number).name)
    previous = {number: signal.signal(number, handler) for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)}
    try:
        yield
    finally:
        for number, action in previous.items():
            signal.signal(number, action)


@contextlib.contextmanager
def signals_ignored():
    """While the fallback restores the previous release nothing may interrupt it."""
    numbers = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)
    previous = {number: signal.signal(number, signal.SIG_IGN) for number in numbers}
    try:
        yield
    finally:
        for number, action in previous.items():
            signal.signal(number, action)


def lock_held(path):
    """True while another process holds an flock on `path`."""
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


def production_profile(host):
    return {
        "issuer_cn": "anj-cloud Household issuer",
        "issuer_years": 10,
        "issuer_days": 3653,
        "server_cn": host,
        "server_san": ("DNS:" + host,),
        "server_days": 365,
        "admin_user": stackenv.ADMIN_USER,
        "trusted_domains": stackenv.TRUSTED_DOMAINS,
        "production": True,
    }


def inside_git_worktree(path):
    """A `.git` file or directory in the path or any parent."""
    path = Path(path)
    return any(os.path.lexists(candidate / ".git") for candidate in (path, *path.parents))


PUBLIC_STATE = re.compile("|".join(re.escape(pattern).replace(re.escape("<commit12>"), "[0-9a-f]{12}")
                                   for pattern in paths.PUBLIC_STATE_PATHS))


def public_state_path(root, path):
    """True only for the exact public paths of paths.PUBLIC_STATE_PATHS under the state root."""
    relative = os.path.relpath(path, root)
    return relative != "." and PUBLIC_STATE.fullmatch(relative.replace(os.sep, "/")) is not None


def check_private_tree(root):
    """Refuse symlinks, foreign owners and modes looser than 0700 (dirs) / 0600 (files).

    Exactly the paths in paths.PUBLIC_STATE_PATHS (HAProxy's state directory, household ACL and
    rendered config, read by a capability-less container root) may be 0755/0644, never
    group/other-writable. A same-named file anywhere else is held to 0600.
    """
    uid = os.getuid()
    for directory, names, files in os.walk(root, followlinks=False):
        info = os.lstat(directory)
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != uid:
            raise ValueError(f"State directory must be a directory owned by this user: {directory}")
        if info.st_mode & (0o022 if public_state_path(root, directory) else 0o077):
            raise ValueError(f"State directory mode is looser than 0700: {directory}")
        for name in names + files:
            path = os.path.join(directory, name)
            entry = os.lstat(path)
            if stat.S_ISLNK(entry.st_mode):
                raise ValueError(f"State root contains a symlink: {path}")
            loose = entry.st_mode & (0o022 if public_state_path(root, path) else 0o077)
            if name in files and (entry.st_uid != uid or loose):
                raise ValueError(f"State file must be owned by this user with mode 0600 or tighter: {path}")


def checked_state_root(path, create=True):
    """Validate --state-root: absolute, not a symlink, outside any git worktree, private."""
    path = Path(path).expanduser()
    if not path.is_absolute():
        raise ValueError("--state-root must be an absolute path")
    path = Path(os.path.normpath(path))
    if path.is_symlink():
        raise ValueError("--state-root must not be a symlink")
    if inside_git_worktree(path) or inside_git_worktree(path.resolve()):
        raise ValueError("--state-root must be outside every git worktree")
    if path.exists():
        check_private_tree(path)
    elif create:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.mkdir(mode=0o700)
        path.chmod(0o700)
    else:
        raise ValueError("--state-root does not exist")
    return path


def atomic_write(path, data, mode=0o600):
    temporary = path.with_name("." + path.name + ".tmp")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, mode)
    with os.fdopen(fd, "wb" if isinstance(data, bytes) else "w") as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)


def refuse_root():
    if os.geteuid() == 0:
        raise RuntimeError("Run production tooling as the VM user anj, not root")


class ProdStack(Stack):
    """A production-profile stack rooted in an explicit state root (not the checkout)."""

    def __init__(self, project, state_root, *, socket_dir=None, checkout=CHECKOUT):
        if not PROJECT_NAME.fullmatch(project):
            raise ValueError("Project must start anj-cloud- and contain lowercase letters/digits/hyphens")
        refuse_root()
        self.project = project
        self.port = None
        self.local = checked_state_root(state_root)
        self.secret_dir = self.local / "secrets"
        self.operator_dir = self.local / "operator"
        self.config_path = self.local / "stack.json"
        self.config = json.loads(self.config_path.read_text()) if self.config_path.exists() else {}
        self.socket_dir = str(socket_dir or self.config.get("socket_dir") or DEFAULT_SOCKET_DIR)
        self.checkout = Path(checkout)
        self.venv_python = ROOT / ".local" / "access-venv" / "bin" / "python"
        self._configure()

    def _configure(self):
        self.host = self.config.get("host")
        self.profile = production_profile(self.host) if self.host else None
        self.origin = "https://" + self.host if self.host else None
        self.base = self.origin
        self.release = self.config.get("release")
        # Recorded at setup, so a restored state root (spec C drill, another project) starts the
        # production release image without building.
        self.image_repository = self.config.get("image_repository") or self.project + "-access"
        config = dict(self.config, socket_dir=self.socket_dir, image_repository=self.image_repository)
        self.environment = stackenv.environment(self.local, config, self.project)

    @property
    def compose_file(self):
        if not self.release:
            raise RuntimeError("No release recorded; run deploy/prod.py setup")
        return self.local / "release" / self.release[:12] / "compose.json"

    def image(self, commit):
        return f"{self.image_repository}:{commit[:12]}"

    def require_setup(self):
        if not self.host or not self.release:
            raise RuntimeError("State root has no recorded production setup; run deploy/prod.py setup --host <host>")
        return self

    def save_config(self, **changes):
        self.config.update(changes)
        atomic_write(self.config_path, json.dumps(self.config, indent=2, sort_keys=True) + "\n")
        self._configure()

    # Source and image -------------------------------------------------------------------

    def git(self, *args):
        return self.run(["git", "-C", str(self.checkout), *args]).strip()

    def has_commit(self, commit):
        try:
            self.git("rev-parse", "--verify", "--quiet", commit + "^{commit}")
        except RuntimeError:
            return False
        return True

    def is_ancestor(self, ancestor, commit):
        result = subprocess.run(["git", "-C", str(self.checkout), "merge-base", "--is-ancestor", ancestor, commit],
                                capture_output=True, timeout=60, check=False)
        if result.returncode not in (0, 1):
            raise RuntimeError("Cannot compare commits in the checkout")
        return result.returncode == 0

    def resolve_commit(self, commit, *, require_merged=True):
        """An exact commit, merged into origin/main and carrying the required fixes."""
        if commit == "origin/main":
            full = self.git("rev-parse", "--verify", "origin/main^{commit}")
        else:
            if not COMMIT.fullmatch(commit):
                raise RuntimeError("Commit must be 7-40 lowercase hex characters")
            try:
                full = self.git("rev-parse", "--verify", "--quiet", commit + "^{commit}")
            except RuntimeError:
                raise RuntimeError("Unknown commit in this checkout; fetch origin first") from None
        if require_merged and not self.is_ancestor(full, "origin/main"):
            raise RuntimeError("Commit is not merged into origin/main")
        missing = missing_required_commit(full, self.has_commit, self.is_ancestor)
        if missing:
            required, purpose = missing
            raise RuntimeError(f"Commit does not contain {required} ({purpose})")
        return full

    def run_bytes(self, argv, data=None, timeout=1800):
        result = subprocess.run(argv, input=data, capture_output=True, env=self.environment, cwd=self.checkout,
                                timeout=timeout, check=False)
        if result.returncode:
            raise RuntimeError(f"Command failed (exit {result.returncode}); output withheld: {argv[0]} {argv[1]}")
        return result.stdout

    def image_revision(self, commit):
        try:
            output = self.run(["docker", "image", "inspect", "--format",
                               '{{ index .Config.Labels "org.opencontainers.image.revision" }}', self.image(commit)])
        except RuntimeError:
            return None
        return output.strip()

    def release_dir(self, commit):
        return self.local / "release" / commit[:12]

    def source_tar(self, commit):
        """release/<commit12>/source.tar: the release's source, kept on the data disk so an
        OS-disk rebuild builds without a new push. Created once from `git archive`."""
        for directory in (self.local / "release", self.release_dir(commit)):
            private_directory(directory)
        path = self.release_dir(commit) / "source.tar"
        if not path.exists():
            atomic_write(path, self.run_bytes(["git", "-C", str(self.checkout), "archive", "--format=tar", commit]))
        return path

    @staticmethod
    def tar_commit(path):
        """The full commit `git archive` records in its pax global header, or None."""
        try:
            with tarfile.open(path) as archive:
                comment = (archive.pax_headers.get("comment") or "").strip()
        except (OSError, tarfile.TarError):
            return None
        return comment if FULL_COMMIT.fullmatch(comment) else None

    def adopt_source(self, commit, source):
        """Decision #122: the release comes from a `git archive` tar, not a git lookup (the VM has
        no git). The tar names its own commit; `commit`, when given, must name the same one. The tar
        becomes release/<commit12>/source.tar (0600) unless one for that commit is already there.
        Merged-into-main and the required fixes are checked on the VM host before staging (stage.py)."""
        full = self.tar_commit(source)
        if full is None:
            raise RuntimeError("--source is not a tar made with `git archive <commit>` (no commit id in it)")
        if commit and not (COMMIT.fullmatch(commit) and full.startswith(commit)):
            raise RuntimeError(f"--source is release {full[:12]}, not {commit}")
        for directory in (self.local / "release", self.release_dir(full)):
            private_directory(directory)
        target = self.release_dir(full) / "source.tar"
        if target.exists():
            if self.tar_commit(target) != full:
                raise RuntimeError(f"release/{full[:12]}/source.tar is not release {full[:12]}")
        else:
            atomic_write(target, Path(source).read_bytes())
        return full

    def live_release(self):
        """The commit release/current points at (its release.json), or None."""
        link = self.source_root / "current"
        try:
            name = os.readlink(link)
            record = json.loads((self.release_dir(name) / "release.json").read_text())
        except (OSError, ValueError):
            return None
        commit = record.get("commit") if isinstance(record, dict) else None
        return commit if isinstance(commit, str) and FULL_COMMIT.fullmatch(commit) and commit[:12] == name else None

    def source_file(self, commit, name):
        with tarfile.open(self.source_tar(commit)) as archive:
            member = archive.getmember(name)
            if not member.isfile():
                raise RuntimeError("Release source member is not a regular file: " + name)
            return archive.extractfile(member).read()

    @property
    def source_root(self):
        """Extracted release sources beside the state root (/srv/anj-cloud/release in the VM)."""
        return self.local.parent / "release"

    def extract_source(self, commit):
        """Extract source.tar to <data root>/release/<commit12>/ (once; nothing switches)."""
        root = self.source_root
        root.mkdir(mode=0o755, exist_ok=True)
        if root.is_symlink() or not root.is_dir() or inside_git_worktree(root):
            raise RuntimeError(f"Release source directory {root} must be a plain directory outside any git worktree")
        target = root / commit[:12]
        if not target.is_dir():
            staging = root / (".extract-" + commit[:12])
            if staging.exists():
                import shutil
                shutil.rmtree(staging)
            staging.mkdir(mode=0o755)
            with tarfile.open(self.source_tar(commit)) as archive:
                archive.extractall(staging, filter="data")
            os.replace(staging, target)
        return target

    def activate_release(self, commit):
        """Make `commit` the live release: state/bin gets its run-service, and release/current
        points at its extracted source atomically, so `<data root>/release/current/deploy/prod.py`
        always addresses the release that passed its health check."""
        target = self.extract_source(commit)
        private_directory(self.local / "bin")
        for member, name in BIN_FILES.items():
            atomic_write(self.local / "bin" / name, self.source_file(commit, member))
        link = self.source_root / ".current.tmp"
        link.unlink(missing_ok=True)
        link.symlink_to(commit[:12])
        os.replace(link, self.source_root / "current")
        return target

    def verify_release(self, commit):
        """A release is complete before anything restarts onto it."""
        target = self.release_dir(commit)
        for name in ("source.tar", "compose.json", "haproxy.cfg", "ecosystem.config.js", "release.json"):
            if not (target / name).is_file():
                raise RuntimeError(f"Release {commit[:12]} is missing {name}")
        if "{{" in (target / "haproxy.cfg").read_text():
            raise RuntimeError(f"Release {commit[:12]} has an unrendered HAProxy config")
        record = json.loads((target / "release.json").read_text())
        if record.get("commit") != commit or record.get("source_sha256") != hashlib.sha256(
                (target / "source.tar").read_bytes()).hexdigest():
            raise RuntimeError(f"Release {commit[:12]} record does not match its source")
        for member in BIN_FILES:
            if not (self.source_root / commit[:12] / member).is_file():
                raise RuntimeError(f"Release {commit[:12]} source lacks {member}")
        if self.image_revision(commit) != commit:
            raise RuntimeError(f"Release {commit[:12]} image is not built")
        config = dict(self.config, release=commit, socket_dir=self.socket_dir, image_repository=self.image_repository)
        self.run([*stackenv.compose_command(self.local, config, self.project), "config", "--quiet"])
        return True

    def build(self, commit):
        """Build the gateway image from the release's source.tar; nothing is mounted."""
        if self.image_revision(commit) == commit:
            return self.image(commit)
        archive = self.source_tar(commit).read_bytes()
        self.run_bytes(["docker", "build", "--quiet", "--label", "org.opencontainers.image.revision=" + commit,
                        "--tag", self.image(commit), "--file", "services/access/Dockerfile", "-"], data=archive)
        if self.image_revision(commit) != commit:
            raise RuntimeError("Built image does not carry the requested commit")
        return self.image(commit)

    def export_release(self, commit):
        """release/<commit12>/: source.tar, compose file, rendered HAProxy config and PM2
        ecosystem, release record; the source extracted beside it. Switches nothing live."""
        target = self.release_dir(commit)
        source = self.source_tar(commit)
        atomic_write(target / "compose.json", self.source_file(commit, "deploy/compose.prod.json"))
        template = self.source_file(commit, "deploy/prod/haproxy.cfg.tmpl").decode()
        atomic_write(target / "haproxy.cfg", render.haproxy(template, bind_address=self.config["bind_address"],
                                                            household_lan=self.config["household_lan"],
                                                            vm_gid=self.config["vm_gid"]), mode=0o644)
        (target / "haproxy.cfg").chmod(0o644)
        atomic_write(target / "ecosystem.config.js", render.ecosystem(state_root=self.local, bin_dir=self.local / "bin",
                                                                      project=self.project))
        self.extract_source(commit)
        record = {"commit": commit, "image": self.image(commit), "host": self.host, "project": self.project,
                  "source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
                  "exported_at": datetime.now(timezone.utc).isoformat(timespec="seconds")}
        atomic_write(target / "release.json", json.dumps(record, indent=2, sort_keys=True) + "\n")
        return target

    # Lifecycle ----------------------------------------------------------------------------

    def setup(self, host, commit=None, *, require_merged=True, bind_address=None, household_lan=None):
        from deploy.access_operator import Operator
        if not HOST.fullmatch(host or ""):
            raise RuntimeError("--host must be a lowercase DNS name such as gateway.example.com")
        if self.host and self.host != host:
            raise RuntimeError(f"State root is already set up for {self.host}; a different host needs a new server certificate")
        for directory in ("operator", "secrets", "release", "run", "haproxy"):
            private_directory(self.local / directory)
        (self.local / "haproxy").chmod(0o755)  # HAProxy's read-only mount (public content)
        acl = self.local / "haproxy" / "household.acl"
        if not acl.exists():
            atomic_write(acl, "", mode=0o644)
            acl.chmod(0o644)
        bind_address = bind_address or self.config.get("bind_address") or paths.DEFAULT_BIND_ADDRESS
        household_lan = household_lan or self.config.get("household_lan") or paths.DEFAULT_HOUSEHOLD_LAN
        render.haproxy("", bind_address=bind_address, household_lan=household_lan, vm_gid=os.getgid() or 1)
        for name in ("database", "admin"):
            secret_file(self.secret_dir / name)
        if commit is None and self.release:
            full = self.release
        else:
            full = self.resolve_commit(commit or "origin/main", require_merged=require_merged)
        self.save_config(host=host, socket_dir=self.socket_dir, release=full, image_repository=self.image_repository,
                         bind_address=bind_address, household_lan=household_lan, vm_gid=os.getgid())
        trust = Operator(self).init_trust()
        self.verify_trust()
        return {"project": self.project, "host": host, "origin": self.origin, "release": full[:12],
                "state_root": str(self.local), "trust_anchor": trust["trust_anchor"]}

    def verify_trust(self):
        from cryptography import x509
        from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID
        issuer = x509.load_pem_x509_certificate((self.operator_dir / "issuer.crt").read_bytes())
        server = x509.load_pem_x509_certificate((self.operator_dir / "server.crt").read_bytes())
        names = server.extensions.get_extension_for_class(x509.SubjectAlternativeName).value
        if (names.get_values_for_type(x509.DNSName) != [self.host] or names.get_values_for_type(x509.IPAddress)
                or len(list(names)) != 1):
            raise RuntimeError("Server certificate SAN is not exactly the production host")
        if list(server.extensions.get_extension_for_class(x509.ExtendedKeyUsage).value) != [ExtendedKeyUsageOID.SERVER_AUTH]:
            raise RuntimeError("Server certificate is not serverAuth only")
        if issuer.subject.get_attributes_for_oid(NameOID.COMMON_NAME)[0].value != self.profile["issuer_cn"]:
            raise RuntimeError("Issuer is not the production household issuer")
        server.verify_directly_issued_by(issuer)
        return {"issuer_cn": self.profile["issuer_cn"], "issuer_not_after": issuer.not_valid_after_utc.isoformat(),
                "server_san": self.host, "server_not_after": server.not_valid_after_utc.isoformat()}

    # VM preflight -------------------------------------------------------------------------

    def preflight_runtime_dirs(self):
        """Spec #21's tmpfiles create these; never create or chown them here."""
        expected = {Path(self.socket_dir): (CONTAINER_UID, paths.GATEWAY_GID, paths.GATEWAY_SOCKET_DIR_MODE),
                    Path(self.config.get("haproxy_run_dir") or paths.HAPROXY_RUN_DIR): (0, self.config.get("vm_gid"),
                                                                                       paths.HAPROXY_RUN_DIR_MODE),
                    # The console backend's socket directory (spec #27, decision #112 (1)): this
                    # account (the backend runs as it), group anj-gw, setgid 2750.
                    Path(self.config.get("console_dir") or paths.CONSOLE_DIR): (os.getuid(), paths.GATEWAY_GID,
                                                                                paths.CONSOLE_DIR_MODE)}
        for path, (uid, gid, mode) in expected.items():
            try:
                info = path.lstat()
            except FileNotFoundError:
                raise RuntimeError(f"Runtime directory {path} is missing; spec #21's tmpfiles create it") from None
            if not stat.S_ISDIR(info.st_mode):
                raise RuntimeError(f"Runtime directory {path} is not a directory")
            if (info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode)) != (uid, gid, mode):
                raise RuntimeError(f"Runtime directory {path} must be {uid}:{gid} mode {oct(mode)}")
            if inside_git_worktree(path) or inside_git_worktree(path.resolve()):
                raise RuntimeError("Runtime directories must be outside every git worktree")

    def configure_nextcloud(self):
        self.trusted_domains()
        self.occ("background:cron")
        self.occ("config:system:set", "shareapi_allow_links", "--type=boolean", "--value=false")
        self.occ("config:system:set", "share_folder", "--value=/anj-cloud/Shared")
        self.occ("config:system:set", "sharing.allow_custom_share_folder", "--type=boolean", "--value=false")

    # PM2 ----------------------------------------------------------------------------------

    def pm2(self, *args):
        return self.run([PM2, *args])

    def pm2_apps(self):
        """PM2 state of the stack apps: {app: {"status", "restarts", "pid"}}."""
        rows = jlist_rows(self.pm2("jlist"))
        return {row["name"]: {"status": row.get("pm2_env", {}).get("status"),
                              "restarts": row.get("pm2_env", {}).get("restart_time", 0), "pid": row.get("pid")}
                for row in rows if row.get("name") in paths.STACK_APPS}

    def emergency(self):
        return (self.local / "run" / "emergency-stop").exists()

    def ecosystem_file(self):
        return self.release_dir(self.release) / "ecosystem.config.js"

    def start_apps(self, apps):
        """Start stack apps that are missing or not online, in dependency order."""
        current = self.pm2_apps()
        for app in apps:
            state = current.get(app)
            if state is None:
                self.pm2("start", str(self.ecosystem_file()), "--only", app)
            elif state["status"] != "online":
                self.pm2("restart", app)

    def service_ready(self, app):
        container = self.container(paths.COMPOSE_SERVICE[app])
        if container is None or not container["State"]["Running"]:
            return False
        health = (container["State"].get("Health") or {}).get("Status")
        if health not in (None, "healthy"):
            return False
        if app == "haproxy":
            return self.haproxy_ready()
        return True

    def wait_ready(self, apps, timeout=600, interval=3.0, sleep=time.sleep, clock=time.monotonic):
        deadline = clock() + timeout
        pending = list(apps)
        while True:
            pending = [app for app in pending if not self.service_ready(app)]
            if not pending:
                return
            if clock() >= deadline:
                raise RuntimeError("Services not healthy in time: " + ", ".join(pending))
            sleep(interval)

    def haproxy_ready(self, timeout=5.0):
        """The HAProxy path: TLS to the bind address with SNI host, issuer-pinned, GET /health."""
        context = ssl.create_default_context(cafile=str(self.operator_dir / "issuer.crt"))
        try:
            with socket.create_connection((self.config["bind_address"], paths.BIND_PORT), timeout=timeout) as raw, \
                    context.wrap_socket(raw, server_hostname=self.host) as tls:
                tls.sendall(b"GET /health HTTP/1.1\r\nHost: " + self.host.encode() + b"\r\nConnection: close\r\n\r\n")
                data = b""
                while len(data) < 16384:
                    chunk = tls.recv(4096)
                    if not chunk:
                        break
                    data += chunk
        except (OSError, ssl.SSLError):
            return False
        return data.startswith(b"HTTP/1.1 200") and data.rstrip().endswith(b'{"status": "ready"}')

    def active_apps(self):
        """Stack apps expected online: the emergency set is held stopped by the flag."""
        return [app for app in paths.STACK_APPS if not (self.emergency() and app in paths.EMERGENCY_APPS)]

    # Lifecycle ----------------------------------------------------------------------------

    def up(self):
        """Build if needed, start the PM2 apps, wait for health, pm2 save."""
        self.require_setup()
        self.preflight_runtime_dirs()
        self.build(self.release)
        self.export_release(self.release)
        self.activate_release(self.release)
        backend = ["db", "redis", "nextcloud"]
        self.start_apps(backend)
        self.wait_ready(backend)
        self.configure_nextcloud()
        apps = self.active_apps()
        self.start_apps(apps)
        self.wait_ready(apps)
        if "gateway" in apps:
            self.ensure_tls_fresh()
        self.pm2("save")
        return self.check()

    def tls_stale(self):
        """Names whose gateway copy differs from the operator file (renewal not yet loaded)."""
        loaded = json.loads(self.compose("exec", "-T", "access", "python", "-m", "access.install_tls"))
        return sorted(name for name, source in TLS_SOURCES.items()
                      if loaded.get(name) != hashlib.sha256((self.operator_dir / source).read_bytes()).hexdigest())

    def ensure_tls_fresh(self):
        """A running gateway keeps its copy; a PM2 restart is a container start, which re-copies."""
        if not self.tls_stale():
            return False
        self.pm2("restart", "gateway")
        self.wait_ready(["gateway"] + (["haproxy"] if "haproxy" in self.active_apps() else []))
        if self.tls_stale():
            raise RuntimeError("Gateway TLS copies still differ from the operator files after a restart")
        return True

    def process_identity(self, container):
        """VM uid and effective capabilities of the container's main process (rootful Docker)."""
        status = Path(f"/proc/{container['State']['Pid']}/status").read_text()
        fields = dict(line.split(":", 1) for line in status.splitlines() if ":" in line)
        return int(fields["Uid"].split()[1]), int(fields["CapEff"].strip(), 16)

    def restart_stack(self):
        """pm2 restart (or start) every active app in dependency order, each waited healthy."""
        known = self.pm2_apps()
        for app in self.active_apps():
            if app in known:
                self.pm2("restart", app)
            else:
                self.pm2("start", str(self.ecosystem_file()), "--only", app)
            self.wait_ready([app])

    def redeploy(self, commit, *, require_merged=True, source=None):
        """Build, export and verify another merged commit, restart onto it, and switch the live
        release (state/bin, release/current, previous_release) only after a healthy check.

        With `source` (a `git archive` tar, decision #122) the release comes from that tar and no
        git checkout is needed; without it the commit is looked up in this checkout.

        Held under the operations lock (no backup, restore or second redeploy meanwhile). The new
        release's state/bin (run-service, paths.py, stackenv.py) is installed before the restarts,
        so the health check covers the wrapper that keeps running (review M2). stack.json's
        `release` names the new commit during the restarts, because run-service starts what it
        names. Any failure, Ctrl-C, SIGTERM or SIGHUP before the switch completes restores
        state/bin and stack.json, restarts the previous release, leaves release/current on it and
        sends one `redeploy-failed` alert; the fallback itself ignores those signals (review H1).
        """
        self.require_setup()
        self.preflight_runtime_dirs()
        with self.ops_lock(), signals_as_interrupts():
            return self._redeploy(commit, require_merged, source)

    def _redeploy(self, commit, require_merged, source):
        if source is not None:
            full = self.adopt_source(commit, source)
        else:
            full = self.resolve_commit(commit, require_merged=require_merged)
        # An interrupted earlier run can leave stack.json naming a release that never went live;
        # the release to fall back to is the live one.
        previous = self.live_release() or self.release
        try:
            self.build(full)
            self.export_release(full)
            self.verify_release(full)
        except BaseException as error:
            detail = self.failure_detail(error)
            via = self.redeploy_failed(full, previous, f"{detail}; nothing was restarted")
            if isinstance(error, Exception) and not isinstance(error, Interrupted):
                raise
            raise RuntimeError(f"Redeploy of {full[:12]} {detail}; nothing was restarted (alert: {via})") from None
        old_bin = self.read_bin()
        try:
            self.install_bin(full)
            self.save_config(release=full)
            self.restart_stack()
            if "gateway" in self.active_apps():
                self.ensure_tls_fresh()
            result = self.check()
            self.activate_release(full)
            self.save_config(previous_release=previous)
        except BaseException as error:
            detail = self.failure_detail(error)
            with signals_ignored():
                rollback = self.fall_back(previous, old_bin)
                via = self.redeploy_failed(full, previous, f"{detail}; {rollback}")
            raise RuntimeError(f"Redeploy of {full[:12]} failed ({detail}); release/current stays on "
                               f"{previous[:12]}, {rollback} (alert: {via})") from None
        result["operations"] = self.restart_release_ops()
        self.pm2("save")
        result["previous_release"] = previous[:12] if previous else None
        return result

    @staticmethod
    def failure_detail(error):
        if isinstance(error, KeyboardInterrupt):
            return "interrupted (SIGINT)"
        if isinstance(error, Interrupted):
            return f"interrupted ({error})"
        return str(error) if isinstance(error, RuntimeError) else type(error).__name__

    def fall_back(self, previous, old_bin):
        """Back onto the previous release: state/bin, stack.json and release/current name it again
        (activate_release replaces release/current last, so a failure there leaves it), then its
        apps restart."""
        try:
            self.restore_bin(old_bin)
            self.save_config(release=previous)
            link = self.source_root / "current"
            if previous and link.is_symlink() and os.readlink(link) != previous[:12] and \
                    (self.source_root / previous[:12]).is_dir():
                temporary = self.source_root / ".current.tmp"
                temporary.unlink(missing_ok=True)
                temporary.symlink_to(previous[:12])
                os.replace(temporary, link)
        except (OSError, RuntimeError, ValueError):
            return f"restoring the previous release's files failed; run prod.py redeploy {previous[:12]}"
        try:
            self.restart_stack()
            self.pm2("save")
            return f"restarted on {previous[:12]}"
        except Exception:
            return f"restart onto {previous[:12]} failed; run prod.py up"

    def read_bin(self):
        """{name: bytes or None} of state/bin's release files (the fallback puts them back)."""
        result = {}
        for name in BIN_FILES.values():
            try:
                result[name] = (self.local / "bin" / name).read_bytes()
            except FileNotFoundError:
                result[name] = None
        return result

    def install_bin(self, commit):
        private_directory(self.local / "bin")
        for member, name in BIN_FILES.items():
            atomic_write(self.local / "bin" / name, self.source_file(commit, member))

    def restore_bin(self, saved):
        for name, data in (saved or {}).items():
            if data is not None:
                atomic_write(self.local / "bin" / name, data)

    @contextlib.contextmanager
    def ops_lock(self):
        """The operations lock spec #22's backup holds (state/run/backup.lock): a redeploy never
        runs during a backup, a restore or another redeploy (review M3). Nothing waits: a backup
        timer run during a switch finds run/release-switch and skips quietly (the next night's
        run takes it); a second redeploy, an upgrade or a setup re-run is refused."""
        run = self.local / "run"
        private_directory(run)
        restore = run / paths.RESTORE_LOCK.name
        if restore.exists() and lock_held(restore):
            raise RuntimeError("A restore is running (restore.lock); redeploy after it finishes")
        fd = os.open(run / paths.OPS_LOCK.name, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise RuntimeError("A backup or another redeploy holds the operations lock (backup.lock); "
                                   "redeploy after it finishes") from None
            marker = run / paths.RELEASE_SWITCH.name
            atomic_write(marker, json.dumps({"pid": os.getpid(), "started": datetime.now(timezone.utc).isoformat(
                timespec="seconds")}) + "\n")
            try:
                yield
            finally:
                marker.unlink(missing_ok=True)
        finally:
            os.close(fd)

    def redeploy_failed(self, full, previous, detail):
        """One alert: the redeploy did not switch (decision #122). Never raises; returns how it
        went out (dispatcher, spool or none) and says so on stderr for anj-cloud-setup (review L3)."""
        via = self.alert("redeploy-failed", "anj-cloud update failed",
                         f"Updating {self.host} to release {full[:12]} failed ({detail}). The live release stays "
                         f"{(previous or '-')[:12]}.", priority="high")
        print(f"ALERT: redeploy-failed {via}", file=sys.stderr, flush=True)
        return via

    def restart_release_ops(self):
        """Decision #114: after release/current names the new release, `pm2 restart` the
        operations apps that run its code (console, watchdog, watchers), so none keeps the old one. Still
        inside this redeploy run, which the watchdog treats as maintenance (decision #113). An app
        PM2 does not run (a restore drill) is left alone. The release is already live and healthy,
        so a failed restart is reported and alerted, never rolled back: the watchdog then handles
        the app like any other failure."""
        try:
            running = {row.get("name") for row in jlist_rows(self.pm2("jlist")) if isinstance(row, dict)}
        except (RuntimeError, ValueError, OSError, subprocess.TimeoutExpired):
            running = None
        result = {}
        for app in RELEASE_OPS_APPS:
            if running is not None and app not in running:
                result[app] = "not running"
                continue
            try:
                self.pm2("restart", app)
                result[app] = "restarted"
            except (RuntimeError, OSError, subprocess.TimeoutExpired):
                result[app] = "restart failed"
        failed = sorted(app for app, state in result.items() if state == "restart failed")
        if failed:
            self.alert("redeploy-ops", "anj-cloud redeploy",
                       "Redeploy switched the release, but restarting " + ", ".join(failed) + " failed; "
                       "they may still run the previous release.", priority="high")
        return result

    def stop(self):
        """pm2 stop every stack app, front to back. Not saved: a VM reboot resurrects the stack."""
        self.require_setup()
        for app in reversed(paths.STACK_APPS):
            self.pm2("stop", app)
        return {"project": self.project, "state": "stopped",
                "note": "PM2 resurrects the saved stack at the next boot; use emergency-stop to keep ingress down"}

    def alert(self, key, title, message, priority="urgent"):
        """One alert through the in-VM dispatcher (spec #21 anj-alert); never raises.

        A missing or failing dispatcher falls back to a spool record in state/run/alerts/, so
        the operation that alerts never fails because alerting failed. Returns how it went out.
        """
        command = self.local / "bin" / paths.ALERT_COMMAND.name
        if command.is_file():
            try:
                result = subprocess.run([str(command), "--key", key, "--every", "0", "--title", title, "--priority",
                                         priority, "--", message], capture_output=True, timeout=60, check=False)
                if result.returncode == 0:
                    return "dispatcher"
            except (OSError, subprocess.TimeoutExpired):
                pass
        try:
            spool = self.local / "run" / paths.ALERT_SPOOL.name
            private_directory(spool.parent)
            private_directory(spool)
            now = datetime.now(timezone.utc)
            record = {"key": key, "title": title, "priority": priority, "message": message,
                      "created": now.isoformat(timespec="seconds")}
            atomic_write(spool / (now.strftime("%Y%m%dT%H%M%S.%fZ") + "-" + key + ".json"), json.dumps(record) + "\n")
            return "spool"
        except (OSError, RuntimeError):
            return "none"

    def emergency_stop(self, reason):
        """Stop haproxy and gateway, keep them stopped across PM2 restarts and reboots, and alert
        the operator at once (decision #90 (9)); the alert goes out even if a PM2 call fails."""
        self.require_setup()
        if not REASON.fullmatch(reason or ""):
            raise RuntimeError("--reason must be 1-200 printable characters")
        flag = self.local / "run" / "emergency-stop"
        private_directory(flag.parent)
        atomic_write(flag, json.dumps({"reason": reason, "at": datetime.now(timezone.utc).isoformat(timespec="seconds")}) + "\n")
        # Alert at once (#68 (9), #90 (9)): right after the flag, before the stops, which can each
        # take up to PM2's kill_timeout. The flag already makes run-service refuse both apps.
        via = self.alert("emergency-stop", "anj-cloud emergency stop",
                         f"Public access to {self.host} is being stopped (haproxy and gateway). Reason: {reason}. "
                         "It stays stopped until the operator re-enables it with prod.py resume.")
        for app in paths.EMERGENCY_APPS:
            self.pm2("stop", app)
        self.pm2("save")
        return {"state": "emergency-stop", "stopped": list(paths.EMERGENCY_APPS), "flag": str(flag), "alert": via,
                "note": "only `prod.py resume`, on the operator's instruction, re-enables ingress"}

    def resume(self):
        """Clear the emergency flag and start gateway then haproxy (operator instruction only)."""
        self.require_setup()
        flag = self.local / "run" / "emergency-stop"
        flag.unlink(missing_ok=True)
        self.start_apps([app for app in paths.STACK_APPS if app in paths.EMERGENCY_APPS])
        self.wait_ready(["gateway", "haproxy"])
        self.ensure_tls_fresh()
        self.pm2("save")
        via = self.alert("emergency-resume", "anj-cloud public access re-enabled",
                         f"Public access to {self.host} is re-enabled (prod.py resume): haproxy and gateway are running.",
                         priority="default")
        return {"state": "resumed", "alert": via, "status": self.status()}

    def containers(self):
        ids = self.compose("ps", "--all", "--quiet").split()
        return json.loads(self.run(["docker", "inspect", *ids])) if ids else []

    def container(self, service):
        try:
            return json.loads(self.run(["docker", "inspect", f"{self.project}-{service}-1"]))[0]
        except (RuntimeError, ValueError, IndexError):
            return None

    def status(self):
        """PM2 states, container health and the production healthcheck as JSON.

        Shape (stable; spec #23's golive.py and spec #21's tooling read it):
            {"project": "anj-cloud-prod", "host": "<host>", "release": "<commit12>",
             "emergency_stop": bool,
             "apps": {"<app>": {"status": "online|stopped|stopping|launching|errored|missing" (PM2_STATUS mapping;
                                          "stopped" for an ingress app held down by the emergency flag),
                                "restarts": int, "pid": int|null,
                                "service": {"status": "<docker state>", "health": "healthy|starting|unhealthy|null"}|null}
                      for every app in paths.STACK_APPS (db, redis, nextcloud, cron, gateway, haproxy)},
             "healthcheck": "ready|unhealthy|unavailable"}
        """
        self.require_setup()
        apps = self.pm2_apps()
        services = {}
        for container in self.containers():
            state = container["State"]
            services[container["Config"]["Labels"].get("com.docker.compose.service")] = {
                "status": state["Status"], "health": (state.get("Health") or {}).get("Status")}
        try:
            health = json.loads(self.compose("exec", "-T", "access", "python", "-m", "access.health"))["status"]
        except RuntimeError:
            health = "unhealthy" if services.get("access", {}).get("status") == "running" else "unavailable"
        except (ValueError, KeyError):
            health = "unavailable"
        flagged = self.emergency()
        rows = {}
        for app in paths.STACK_APPS:
            row = dict(apps.get(app, {"status": None, "restarts": 0, "pid": None}))
            row["status"] = self.app_status(app, row["status"], flagged)
            row["service"] = services.get(paths.COMPOSE_SERVICE[app])
            rows[app] = row
        return {"project": self.project, "host": self.host, "release": self.release[:12],
                "emergency_stop": flagged, "apps": rows, "healthcheck": health}

    @staticmethod
    def app_status(app, raw, flagged):
        """One documented status value for PM2's raw state (see PM2_STATUS)."""
        if raw is None:
            return "missing"
        status = PM2_STATUS.get(raw, "errored")
        if flagged and app in paths.EMERGENCY_APPS and status != "online":
            return "stopped"
        return status

    def check(self):
        """Read-only verification of the running production stack (spec #20 rows)."""
        self.require_setup()
        expected = self.active_apps()
        apps = self.pm2_apps()
        offline = [app for app in expected if apps.get(app, {}).get("status") != "online"]
        if offline:
            raise RuntimeError("PM2 apps not online: " + ", ".join(offline))
        services = {}
        for container in self.containers():
            labels = container["Config"]["Labels"]
            if labels.get("com.docker.compose.project") != self.project:
                raise RuntimeError("Unexpected container project")
            service = labels["com.docker.compose.service"]
            services[service] = container
            host = container["HostConfig"]
            if any(values for values in (container["NetworkSettings"]["Ports"] or {}).values()) or host.get("PortBindings"):
                raise RuntimeError(f"Production service publishes a port: {service}")
            if host["RestartPolicy"]["Name"] not in ("no", ""):
                raise RuntimeError(f"Service has a Docker restart policy; PM2 is the only supervisor: {service}")
            if not host.get("Memory") or not host.get("PidsLimit"):
                raise RuntimeError(f"Service has no memory or pids limit: {service}")
            for mount in container.get("Mounts", []):
                if mount.get("Type") == "bind" and inside_git_worktree(mount["Source"]):
                    raise RuntimeError(f"Production service mounts a path inside a git worktree: {service}")
            state = container["State"]
            if service in {paths.COMPOSE_SERVICE[app] for app in expected}:
                if not state["Running"]:
                    raise RuntimeError(f"Service is not running: {service}")
                if state.get("Health") and state["Health"]["Status"] != "healthy":
                    raise RuntimeError(f"Service is not healthy: {service}")
        running = {paths.COMPOSE_SERVICE[app] for app in expected}
        if not running <= set(services):
            raise RuntimeError("Production service set is incomplete")
        identities = {}
        for service in ("access", "haproxy"):
            if service in running:
                uid, capabilities = self.process_identity(services[service])
                if uid == 0 or capabilities != 0:
                    raise RuntimeError(f"{service} process is not a non-root user without capabilities")
                identities[service] = uid
        if "access" in running:
            access = services["access"]
            if identities["access"] != CONTAINER_UID:
                raise RuntimeError("Gateway process is not uid 10001")
            if set(access["NetworkSettings"]["Networks"]) != {self.project + "_proxy"}:
                raise RuntimeError("Gateway must join only the internal proxy network")
            if access["HostConfig"]["LogConfig"]["Type"] != "journald":
                raise RuntimeError("Gateway must log to journald")
            if self.image_revision(self.release) != self.release or access["Config"]["Image"] != self.image(self.release):
                raise RuntimeError("Gateway image does not match the recorded release")
            health = json.loads(self.compose("exec", "-T", "access", "python", "-m", "access.health"))
            if health != {"status": "ready"}:
                raise RuntimeError("Gateway healthcheck is not ready")
            stale = self.tls_stale()
            if stale:
                raise RuntimeError("Gateway serves stale TLS material (" + ", ".join(stale) + "); run deploy/prod.py up")
        if "haproxy" in running:
            if services["haproxy"]["HostConfig"]["NetworkMode"] != "host":
                raise RuntimeError("HAProxy must use the VM's host network")
            if not self.haproxy_ready():
                raise RuntimeError("HAProxy path to the gateway is not ready")
        if self.occ("config:system:get", "dbtype").strip() != "pgsql":
            raise RuntimeError("Nextcloud is not configured for PostgreSQL")
        if self.occ("config:system:get", "memcache.locking").strip() != "\\OC\\Memcache\\Redis":
            raise RuntimeError("Nextcloud Redis file locking is not configured")
        accounts = sorted(json.loads(self.occ("user:list", "--output=json")))
        if any(account.startswith("anj-fixture-") for account in accounts):
            raise RuntimeError("Fixture accounts exist in production")
        check_private_tree(self.local)
        return {"project": self.project, "host": self.host, "release": self.release[:12], "origin": self.origin,
                "supervisor": "pm2", "apps": {app: apps[app]["status"] for app in expected},
                "emergency_stop": self.emergency(), "process_uids": identities, "tls": "current" if "access" in running else None,
                "listener": "proxy-unix", "socket_dir": self.socket_dir, "accounts": accounts, "trust": self.verify_trust()}


def parser():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    setup = sub.add_parser("setup", help="State root, secrets, production issuer and server certificate")
    setup.add_argument("--host", required=True, help="Production hostname, e.g. gateway.example.com")
    setup.add_argument("--commit", help="Merged commit to release (default: origin/main, resolved and recorded)")
    setup.add_argument("--bind-address", help=f"VM address HAProxy binds on 443 (default {paths.DEFAULT_BIND_ADDRESS})")
    setup.add_argument("--household-lan", help=f"Household LAN for the HAProxy ACL (default {paths.DEFAULT_HOUSEHOLD_LAN})")
    sub.add_parser("up", help="Build if needed, start the PM2 apps, wait for health, pm2 save")
    sub.add_parser("check", help="Read-only verification")
    sub.add_parser("status", help="PM2 states, container health and the healthcheck as JSON")
    sub.add_parser("stop", help="pm2 stop every stack app (a reboot resurrects them)")
    redeploy = sub.add_parser("redeploy", help="Build another merged commit and restart in dependency order")
    redeploy.add_argument("commit", nargs="?", help="Commit (7-40 hex); optional with --source, which names its own")
    redeploy.add_argument("--source", help="A `git archive` tar of the release (no git checkout needed, decision #122)")
    emergency = sub.add_parser("emergency-stop", help="Stop haproxy and gateway until resume, across reboots")
    emergency.add_argument("--reason", required=True)
    sub.add_parser("resume", help="Clear the emergency stop (only on the operator's instruction)")
    return parser


def subcommands():
    return [action for action in parser()._subparsers._group_actions][0].choices.keys()


def main(argv=None):
    args = parser().parse_args(argv)
    try:
        refuse_root()
        stack = ProdStack(PROJECT, DEFAULT_STATE_ROOT)
        if args.command == "setup":
            result = stack.setup(args.host, args.commit, bind_address=args.bind_address, household_lan=args.household_lan)
        elif args.command == "redeploy":
            if not args.commit and not args.source:
                raise RuntimeError("redeploy needs a commit, or --source <git-archive tar>")
            result = stack.redeploy(args.commit, source=args.source)
        elif args.command == "emergency-stop":
            result = stack.emergency_stop(args.reason)
        else:
            result = getattr(stack, args.command)()
        print(json.dumps(result, indent=2))
    except (RuntimeError, ValueError, OSError, subprocess.TimeoutExpired) as error:
        if isinstance(error, (RuntimeError, ValueError)):
            print(f"ERROR: {error}", file=sys.stderr)
        else:
            print(f"ERROR: {type(error).__name__}; diagnostic content withheld", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
