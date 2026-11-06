#!/usr/bin/env python3
"""Trusted, local-only Linux installer/launcher. Python 3.11+, no network/feed.

Obtain this script from reviewed source. An archive checksum cannot establish the
trustworthiness of the program which checks it. Never run a downloaded script
merely because it is alongside the archive.
"""
import argparse
from contextlib import ExitStack, contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import shutil
import sqlite3
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.parse
from datetime import datetime, timezone

if sys.version_info < (3, 11):
    sys.exit("anj-cloud: Python 3.11 or newer is required; no OS changes were made.")

OWNER = "anj-cloud-linux-install-v1"
PROTOCOL = 1
MAX_BYTES = 2 * 1024**3
MAX_MEMBERS = 10000
ICON_PAYLOAD = "data/flutter_assets/assets/branding/harbor/icon-512.png"
ICON_NAME = "harbor-cloud-seal-512.png"
REQUIRED = {"anj_cloud", "lib/libflutter_linux_gtk.so", "lib/libapp.so", "lib/libanj_rootfs.so",
            "elf-audit.json", "dependency-resolution.json", "build-toolchain.txt", "linux_install.py", ICON_PAYLOAD}
AUTOSTART_NAME = "anj-cloud.desktop"
AUTOSTART_KEYS = {"owner", "enabled", "source", "path", "sha256", "problem"}
# Login start waits this long for the session bus and Secret Service.
LOGIN_WAIT_SECONDS = 120
LOGIN_POLL_SECONDS = 1.0
ACTIVATION_PATH = "/cloud/anj/AnjCloud"
ACTIVATION_METHOD = "cloud.anj.AnjCloud1.Activate"
BUSY = "This profile is already running. Quit AnJ Cloud from its tray or app menu before updating."


class Refused(Exception):
    pass


class Busy(Refused):
    """The profile lifetime lock is held by a running client."""


def digest(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def safe_path(path):
    path = Path(os.path.abspath(path))
    if any(ord(char) < 32 for char in str(path)):
        raise Refused("Control characters in installation/profile paths are unsupported.")
    # Never follow an unexpected symlink in a program-owned path. An explicitly
    # supplied profile is resolved separately, by reference, before this check.
    for part in (path, *path.parents):
        if part.is_symlink():
            raise Refused(f"Unexpected symlink: {part}")
    return path


def private_dir(path, *, create=True):
    path = safe_path(path)
    if not path.exists():
        if not create:
            raise Refused(f"Selected installation/profile directory is unavailable: {path}. It was not recreated.")
        path.mkdir(mode=0o700, parents=True)
    info = path.stat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077:
        raise Refused(f"Need a private user-owned directory: {path}. No permissions were changed.")
    return path


def owned_file(path):
    path = safe_path(path)
    info = path.stat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_nlink != 1 or info.st_mode & 0o022:
        raise Refused(f"Unexpected ownership/type/permissions: {path}")
    return info


def sync_dir(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def atomic_bytes(path, data, mode=0o600):
    if path.exists() or path.is_symlink():
        owned_file(path)
    fd, temporary = tempfile.mkstemp(prefix=".publish-", dir=path.parent)
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        sync_dir(path.parent)
    finally:
        Path(temporary).unlink(missing_ok=True)


def atomic_json(path, data):
    atomic_bytes(path, (json.dumps(data, indent=2, sort_keys=True) + "\n").encode())


def read_json(path):
    owned_file(path)
    try:
        value = json.loads(path.read_text())
        if not isinstance(value, dict):
            raise Refused(f"Expected a JSON object: {path}")
        return value
    except (ValueError, UnicodeError) as error:
        raise Refused(f"Invalid installation JSON: {path}") from error


@contextmanager
def exclusive(path, *, profile=False):
    safe_path(path)
    directory = path.parent.stat() if profile else None
    fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    try:
        info = owned_file(path)
        held = os.fstat(fd)
        if (info.st_dev, info.st_ino) != (held.st_dev, held.st_ino) or held.st_mode & 0o077:
            raise Refused(f"Lock path changed or is not private: {path}")
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            if profile:
                raise Busy(BUSY) from error
            raise Refused("Another installation transaction is running; retry after it finishes.") from error
        current = owned_file(path)
        if (current.st_dev, current.st_ino) != (held.st_dev, held.st_ino) or current.st_mode & 0o077:
            raise Refused(f"Lock path changed during acquisition: {path}")
        if profile:
            revalidate_profile(path.parent, fd, directory)
        yield fd
    finally:
        # Do not LOCK_UN: a child may have inherited this same open description.
        os.close(fd)


def revalidate_profile(profile, fd, expected_directory):
    directory = private_dir(profile, create=False).stat()
    entry = owned_file(profile / ".instance.lock")
    held = os.fstat(fd)
    if ((directory.st_dev, directory.st_ino) != (expected_directory.st_dev, expected_directory.st_ino)
            or (held.st_dev, held.st_ino) != (entry.st_dev, entry.st_ino)):
        raise Refused("Profile directory/lock identity changed; activation/launch refused.")


def environment_path(variable, fallback):
    value = os.environ.get(variable)
    if value and not Path(value).is_absolute():
        raise Refused(f"{variable} must be absolute when set.")
    return safe_path(value or fallback)


class Installation:
    def __init__(self, config=None):
        home = Path.home().resolve()
        if config and not Path(config).is_absolute():
            raise Refused("--installation must name an absolute config directory.")
        self.config = safe_path(config) if config else environment_path("XDG_CONFIG_HOME", home / ".config") / "anj-cloud"
        self.layout_file = self.config / "installation.json"
        self.state_file = self.config / "active.json"
        self.lock_file = self.config / ".transaction.lock"
        # Separate file: older managers reject unknown installation.json keys.
        self.autostart_file = self.config / "autostart.json"
        self.layout = None

    def initialize(self):
        private_dir(self.config)
        if self.layout_file.exists():
            self.load()
            return
        home = Path.home().resolve()
        data = environment_path("XDG_DATA_HOME", home / ".local/share")
        state = environment_path("XDG_STATE_HOME", home / ".local/state")
        self.layout = {"owner": OWNER, "data": str(data / "anj-cloud"),
                       "state": str(state / "anj-cloud"), "command": str(home / ".local/bin/anj-cloud"),
                       "desktop": str(data / "applications/anj-cloud.desktop")}
        # Do not appropriate existing launchers. A complete marker is written
        # before integration, allowing an interrupted first install to resume.
        for key in ("command", "desktop"):
            path = safe_path(self.layout[key])
            if path.exists() or path.is_symlink():
                raise Refused(f"Existing {key} collision: {path}")
        private_dir(Path(self.layout["data"]) / "releases")
        private_dir(Path(self.layout["data"]) / "managers")
        private_dir(Path(self.layout["state"]))
        atomic_json(self.layout_file, self.layout)

    def load(self):
        private_dir(self.config, create=False)
        self.layout = read_json(self.layout_file)
        if set(self.layout) != {"owner", "data", "state", "command", "desktop"} or self.layout["owner"] != OWNER:
            raise Refused("Unknown installation layout; refusing to repair or overwrite it.")
        for key in ("data", "state", "command", "desktop"):
            if not isinstance(self.layout[key], str) or not Path(self.layout[key]).is_absolute():
                raise Refused("Installation layout paths must be absolute strings.")
            safe_path(self.layout[key])
        private_dir(Path(self.layout["data"]) / "releases", create=False)
        private_dir(Path(self.layout["data"]) / "managers", create=False)
        private_dir(Path(self.layout["state"]), create=False)

    @property
    def releases(self):
        return Path(self.layout["data"]) / "releases"

    def active(self):
        state = read_json(self.state_file)
        if (set(state) != {"owner", "source", "archive_sha256", "release", "profile", "previous", "manager_sha256"}
                or state["owner"] != OWNER
                or not all(isinstance(state[key], str) for key in ("source", "archive_sha256", "manager_sha256", "release", "profile"))
                or (state["previous"] is not None and (not isinstance(state["previous"], str) or not re.fullmatch(r"[a-f0-9]{40}-[a-f0-9]{64}", state["previous"])))
                or not re.fullmatch(r"[a-f0-9]{40}", state["source"])
                or not re.fullmatch(r"[a-f0-9]{64}", state["archive_sha256"])
                or not re.fullmatch(r"[a-f0-9]{64}", state["manager_sha256"])
                or state["release"] != f"{state['source']}-{state['archive_sha256']}"):
            raise Refused("Invalid activation record; refusing to select a different release/profile.")
        profile = private_dir(state["profile"], create=False)
        if str(profile.resolve()) != state["profile"]:
            raise Refused("Selected profile is no longer canonical.")
        return state

    def check_selected_manager(self, state, *, bootstrap=False):
        executing = Path(__file__).resolve()
        if bootstrap and executing.parent != Path(self.layout["data"]) / "managers":
            return  # an explicitly invoked, trusted source/bootstrap checker
        if digest(executing) != state["manager_sha256"]:
            raise Refused("Installation changed while this manager was starting. Retry through the stable anj-cloud command.")

    def log(self, event, **fields):
        path = Path(self.layout["state"]) / "manager.jsonl"
        if path.exists() or path.is_symlink():
            owned_file(path)
        fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
        with os.fdopen(fd, "a") as stream:
            stream.write(json.dumps({"utc": datetime.now(timezone.utc).isoformat(), "event": event, **fields}) + "\n")
            stream.flush()
            os.fsync(stream.fileno())

    def integration(self, source):
        # Initial checker is trusted reviewed source. Subsequent manager code is
        # authenticated with the archive's expected digest + exact payload hash.
        # Derive the slot and write from the SAME code snapshot.
        code = source.read_bytes()
        checksum = hashlib.sha256(code).hexdigest()
        try:
            compile(code, "bundled linux_install.py", "exec")
        except (SyntaxError, ValueError) as error:
            raise Refused("Bundled manager is not valid Python code.") from error
        manager = Path(self.layout["data"]) / "managers" / f"{checksum}.py"
        if manager.exists():
            owned_file(manager)
            if digest(manager) != checksum:
                raise Refused("Installed manager collision.")
        else:
            atomic_bytes(manager, code, 0o400)
        command = Path(self.layout["command"])
        desktop = Path(self.layout["desktop"])
        # Branding belongs to the installation, rather than a release which has
        # not committed activation yet. Never overwrite a different icon at this
        # reserved path, nor publish into a shared desktop icon theme.
        icon = private_dir(Path(self.layout["data"]) / "icons") / ICON_NAME
        icon_bytes = (source.parent / ICON_PAYLOAD).read_bytes()
        if icon.exists() or icon.is_symlink():
            owned_file(icon)
            if icon.read_bytes() != icon_bytes:
                raise Refused(f"Installed icon collision: {icon}")
        for path in (command, desktop):
            safe_path(path)
            path.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
        # This small stable bootstrap selects its trusted manager through the
        # SAME atomic record as the release. Publishing new manager code cannot
        # switch the active entry point before activation succeeds.
        launcher = ("#!/usr/bin/env python3\n# " + OWNER + "\n"
                    + "import hashlib, json, os, pathlib, re, stat, sys\n"
                    + f"config = pathlib.Path({str(self.config)!r})\n"
                    + f"managers = pathlib.Path({str(manager.parent)!r})\n"
                    + "state = json.loads((config / 'active.json').read_text())\n"
                    + "checksum = state.get('manager_sha256', '')\n"
                    + "if not isinstance(checksum, str) or not re.fullmatch('[a-f0-9]{64}', checksum): sys.exit('anj-cloud: invalid active manager')\n"
                    + "program = managers / (checksum + '.py')\n"
                    + "info = program.lstat()\n"
                    + "if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or info.st_nlink != 1 or info.st_mode & 0o022: sys.exit('anj-cloud: manager ownership refused')\n"
                    + "if hashlib.sha256(program.read_bytes()).hexdigest() != checksum: sys.exit('anj-cloud: manager checksum mismatch')\n"
                    + f"os.execv({sys.executable!r}, [{sys.executable!r}, str(program), '--installation', str(config), *sys.argv[1:]])\n")
        if "=" in sys.executable:
            raise Refused("Python executable paths containing '=' are unsupported by the desktop specification.")
        if "%" in sys.executable:
            raise Refused("Use a Python interpreter whose executable path contains no percent character (GIO desktop executable lookup limitation). Installation/profile paths may contain percent characters.")
        legacy_entry = ("[Desktop Entry]\nType=Application\nName=anj-cloud\nComment=Household file synchronization\n"
                        + f"Exec={desktop_quote(sys.executable)} {desktop_quote(str(command))} run\nTerminal=false\nCategories=Network;FileTransfer;\nStartupNotify=false\n"
                        + f"X-Anj-Cloud-Owner={OWNER}\n")
        entry = legacy_entry.replace("Name=anj-cloud\n", "Name=AnJ Cloud\n", 1)
        entry += (f"Icon={desktop_value(str(icon))}\n"
                  "StartupWMClass=cloud.anj.anj_cloud\n")
        for path in (command, desktop):
            if path.exists() or path.is_symlink():
                owned_file(path)
                old = path.read_text()
                if (path == command and f"# {OWNER}\n" not in old) or (path == desktop and f"X-Anj-Cloud-Owner={OWNER}\n" not in old):
                    raise Refused(f"Unrelated integration file: {path}")
        # Check every existing integration file before publishing any. Only the
        # exact desktop entry produced by the previous manager is upgradeable;
        # an owner marker alone does not authorize replacing edited content.
        for path, content, mode in ((command, launcher, 0o755), (desktop, entry, 0o644)):
            if path.exists():
                old = path.read_bytes()
                if old != content.encode() and not (path == desktop and old == legacy_entry.encode()):
                    raise Refused(f"Managed integration changed; refusing replacement: {path}")
        if not icon.exists():
            atomic_bytes(icon, icon_bytes, 0o400)
        for path, content, mode in ((command, launcher, 0o755), (desktop, entry, 0o644)):
            if not path.exists() or path.read_bytes() != content.encode():
                atomic_bytes(path, content.encode(), mode)
        return manager.stem


def desktop_value(value):
    # Icon is a desktop-entry string, not an Exec argument: '%' is literal and
    # quoting characters must not be added around the absolute filename.
    return value.replace("\\", "\\\\")


def desktop_quote(value):
    # Desktop entry parsing first unescapes general backslashes, then Exec quoting.
    value = value.replace("%", "%%")
    for old, new in (("\\", "\\\\\\\\"), ('"', '\\\\"'), ("$", "\\\\$"), ("`", "\\\\`")):
        value = value.replace(old, new)
    return '"' + value + '"'


def validate_payload(root):
    receipt = read_json(root / "bundle-receipt.json")
    if not isinstance(receipt, dict):
        raise Refused("Invalid release receipt object.")
    source = receipt.get("source_head", "")
    hashes = receipt.get("files_sha256")
    if (receipt.get("platform") != "Linux x86_64" or not isinstance(source, str) or not re.fullmatch(r"[a-f0-9]{40}", source)
            or (type(receipt.get("profile_lifetime_protocol")) is not int or receipt["profile_lifetime_protocol"] != PROTOCOL) or not isinstance(hashes, dict)
            or not REQUIRED <= hashes.keys()):
        raise Refused("Unsupported/invalid release receipt (a profile-lifetime-protocol-1 bundle with the Harbor icon is required).")
    actual = set()
    directories = set()
    for path in root.rglob("*"):
        if path.is_symlink() or not (path.is_file() or path.is_dir()):
            raise Refused(f"Unsupported payload object: {path}")
        info = path.stat()
        if info.st_uid != os.geteuid() or info.st_mode & 0o022:
            raise Refused(f"Unexpected payload ownership/permissions: {path}")
        if path.is_dir():
            directories.add(path.relative_to(root).as_posix())
        if path.is_file():
            owned_file(path)
            actual.add(path.relative_to(root).as_posix())
    if actual != set(hashes) | {"bundle-receipt.json"}:
        raise Refused("Missing/unexpected payload files.")
    expected_directories = {str(parent) for name in actual for parent in PurePosixPath(name).parents if str(parent) != "."}
    if directories != expected_directories:
        raise Refused("Unexpected payload directories.")
    for relative, expected in hashes.items():
        if (not isinstance(relative, str) or not valid_relative(relative) or not isinstance(expected, str)
                or not re.fullmatch(r"[a-f0-9]{64}", expected) or digest(root / relative) != expected):
            raise Refused(f"Payload hash mismatch: {relative}")
    if not os.access(root / "anj_cloud", os.X_OK):
        raise Refused("Client executable permission is missing.")
    return receipt


def valid_relative(value):
    return (bool(value) and not value.startswith("/") and "\\" not in value
            and all(part not in ("", ".", "..") for part in value.split("/"))
            and not any(ord(char) < 32 for char in value))


def extract(archive, expected, staging):
    if not re.fullmatch(r"[a-fA-F0-9]{64}", expected):
        raise Refused("Expected SHA-256 must contain exactly 64 hexadecimal characters.")
    # Authenticate the exact private bytes subsequently parsed, not a pathname
    # reopened after hashing. A concurrently replaced/edited input cannot switch
    # the archive between digest verification and extraction.
    copied = staging / ".verified-input.tar.gz"
    checksum, compressed = hashlib.sha256(), 0
    with Path(archive).open("rb") as incoming, copied.open("xb") as snapshot:
        while chunk := incoming.read(1024 * 1024):
            compressed += len(chunk)
            if compressed > MAX_BYTES:
                raise Refused("Archive exceeds the compressed size limit.")
            checksum.update(chunk)
            snapshot.write(chunk)
    if checksum.hexdigest() != expected.lower():
        raise Refused("Archive SHA-256 does not match the independently supplied expected digest.")
    seen, roots, total = set(), set(), 0
    with tarfile.open(copied, "r:gz") as tar:
        members = []
        for member in tar:
            members.append(member)
            if len(members) > MAX_MEMBERS:
                raise Refused("Archive has too many members.")
            name = member.name
            if (not valid_relative(name) or name in seen or member.type not in (tarfile.REGTYPE, tarfile.AREGTYPE, tarfile.DIRTYPE)
                    or member.mode & 0o7000 or member.size < 0 or (member.isdir() and member.size)):
                raise Refused(f"Unsafe/duplicate archive member: {name}")
            seen.add(name)
            roots.add(PurePosixPath(name).parts[0])
            total += member.size
            if total > MAX_BYTES:
                raise Refused("Archive exceeds the unpacked size limit.")
        if len(roots) != 1:
            raise Refused("Archive must contain exactly one release directory.")
        top = roots.pop()
        root = staging / top
        root.mkdir(mode=0o700)
        # Explicit extraction: no tar metadata ownership, links, special objects,
        # filters or accidental writes outside this private, absent staging tree.
        for member in sorted(members, key=lambda item: (len(PurePosixPath(item.name).parts), item.name)):
            destination = staging / member.name
            if member.isdir():
                destination.mkdir(mode=0o700, parents=True, exist_ok=True)
            else:
                destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                with destination.open("xb") as stream, tar.extractfile(member) as incoming:
                    shutil.copyfileobj(incoming, stream)
                    stream.flush()
                    os.fsync(stream.fileno())
                destination.chmod(0o700 if member.mode & 0o111 else 0o600)
        receipt = validate_payload(root)
        if top != f"anj-cloud-linux-x86_64-{receipt['source_head'][:12]}":
            raise Refused("Archive directory does not match the release source identity.")
        # Durability must include directory entries, not only file bytes.
        for directory in sorted((p for p in root.rglob("*") if p.is_dir()), key=lambda p: len(p.parts), reverse=True):
            sync_dir(directory)
        sync_dir(root)
        return root, receipt


def runtime_check(root, *, graphical=False):
    if platform.system() != "Linux" or platform.machine() != "x86_64":
        raise Refused("Only Linux x86_64 glibc is qualified by this release.")
    version = re.match(r"(\d+)\.(\d+)", platform.release())
    if not version or tuple(map(int, version.groups())) < (5, 6):
        raise Refused("Linux kernel 5.6+ with openat2 support is required; no OS changes were made.")
    if not shutil.which("ldd") or not os.access("/usr/bin/openssl", os.X_OK):
        raise Refused("Missing ldd or /usr/bin/openssl. Install glibc runtime tools and OpenSSL 3; no OS changes were made.")
    version = subprocess.run(["/usr/bin/openssl", "version"], capture_output=True, text=True, timeout=10, check=True).stdout
    if not re.match(r"OpenSSL [3-9]\.", version):
        raise Refused("OpenSSL 3 or newer is required for client identity operations.")
    receipt = validate_payload(root)
    audit = receipt.get("elf_audit", {})
    if not isinstance(audit, dict) or not {"anj_cloud", "lib/libapp.so", "lib/libflutter_linux_gtk.so", "lib/libanj_rootfs.so"} <= audit.keys():
        raise Refused("Missing runtime ELF dependency receipt.")
    actual_elf = set()
    for relative in receipt["files_sha256"]:
        with (root / relative).open("rb") as stream:
            if stream.read(4) == b"\x7fELF":
                actual_elf.add(relative)
    if actual_elf != set(audit):
        raise Refused("ELF dependency receipt does not cover the exact payload ELFs.")
    for relative in audit:
        if not valid_relative(relative) or relative not in receipt["files_sha256"]:
            raise Refused("Invalid ELF dependency receipt path.")
        check = subprocess.run(["ldd", str(root / relative)], capture_output=True, text=True, timeout=20,
                               env={**os.environ, "LC_ALL": "C"})
        if check.returncode or "not found" in check.stdout + check.stderr:
            raise Refused(f"Runtime dependencies unavailable for {relative}. Install GTK3, GLib/GIO, libsecret, graphics/font libraries and compatible glibc/C++ runtime. ldd: {(check.stdout + check.stderr).strip()}")
    if graphical:
        if not (os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY")) or not os.environ.get("DBUS_SESSION_BUS_ADDRESS"):
            raise Refused("Launch from your graphical desktop session with its session bus and unlocked Secret Service keyring.")
        if not shutil.which("gdbus"):
            raise Refused("Missing gdbus (GLib tools); required to check the desktop Secret Service without reading secrets.")
        check = subprocess.run(["gdbus", "call", "--session", "--dest", "org.freedesktop.secrets", "--object-path", "/org/freedesktop/secrets", "--method", "org.freedesktop.DBus.Peer.Ping"], capture_output=True, timeout=10)
        if check.returncode:
            raise Refused("Desktop Secret Service is unavailable. Start/unlock your usual desktop keyring and retry; no keyring settings were changed.")


def activation_name(profile):
    """Per-profile D-Bus name owned by the running client (lib/src/desktop_bus.dart)."""
    return "cloud.anj.AnjCloud.p" + hashlib.sha256(os.fsencode(profile)).hexdigest()[:32]


def activate_running(profile):
    """Ask the client already holding this profile to show its window."""
    if not os.environ.get("DBUS_SESSION_BUS_ADDRESS") or not shutil.which("gdbus"):
        return False
    try:
        check = subprocess.run(["gdbus", "call", "--session", "--dest", activation_name(profile),
                                "--object-path", ACTIVATION_PATH, "--method", ACTIVATION_METHOD],
                               capture_output=True, timeout=10)
    except subprocess.TimeoutExpired:
        return False
    return check.returncode == 0


def session_ready(*, secrets):
    """Session bus reachable and, when asked, the Secret Service answering."""
    if not (os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY")) or not os.environ.get("DBUS_SESSION_BUS_ADDRESS"):
        return False
    if not shutil.which("gdbus"):
        return False
    destinations = [("org.freedesktop.DBus", "/org/freedesktop/DBus")]
    if secrets:
        destinations.append(("org.freedesktop.secrets", "/org/freedesktop/secrets"))
    for destination, path in destinations:
        try:
            check = subprocess.run(["gdbus", "call", "--session", "--dest", destination, "--object-path", path,
                                    "--method", "org.freedesktop.DBus.Peer.Ping"], capture_output=True, timeout=10)
        except subprocess.TimeoutExpired:
            return False
        if check.returncode:
            return False
    return True


def wait_for_session(*, secrets, timeout=None):
    """At login the bus and keyring may start after the autostart entry."""
    deadline = time.monotonic() + (LOGIN_WAIT_SECONDS if timeout is None else timeout)
    while True:
        if session_ready(secrets=secrets):
            return True
        if time.monotonic() >= deadline:
            return False
        time.sleep(LOGIN_POLL_SECONDS)


def default_autostart_path():
    home = Path.home().resolve()
    return environment_path("XDG_CONFIG_HOME", home / ".config") / "autostart" / AUTOSTART_NAME


def autostart_entry(installation):
    """Exact owner-marked XDG autostart entry: the stable command in background mode."""
    command = installation.layout["command"]
    icon = Path(installation.layout["data"]) / "icons" / ICON_NAME
    if "=" in sys.executable or "%" in sys.executable:
        raise Refused("Use a Python interpreter whose executable path contains no '=' or '%' character.")
    return ("[Desktop Entry]\nType=Application\nName=AnJ Cloud\n"
            "Comment=Keep household files in sync; starts hidden in the system tray\n"
            f"Exec={desktop_quote(sys.executable)} {desktop_quote(str(command))} run --background\n"
            f"Icon={desktop_value(str(icon))}\n"
            "Terminal=false\nStartupNotify=false\nX-GNOME-Autostart-enabled=true\n"
            f"X-Anj-Cloud-Owner={OWNER}\n").encode()


def read_autostart(installation):
    if not installation.autostart_file.exists() and not installation.autostart_file.is_symlink():
        return None
    state = read_json(installation.autostart_file)
    if (set(state) != AUTOSTART_KEYS or state["owner"] != OWNER or not isinstance(state["enabled"], bool)
            or state["source"] not in ("default", "user") or not isinstance(state["path"], str)
            or not Path(state["path"]).is_absolute() or Path(state["path"]).name != AUTOSTART_NAME
            or (state["sha256"] is not None and (not isinstance(state["sha256"], str) or not re.fullmatch(r"[a-f0-9]{64}", state["sha256"])))
            or (state["problem"] is not None and not isinstance(state["problem"], str))):
        raise Refused("Unknown autostart settings; refusing to change login start.")
    safe_path(state["path"])
    return state


def autostart_file_state(path, expected, recorded):
    """absent, exact (current content), ours (a previous exact write), changed or foreign."""
    if not path.exists() and not path.is_symlink():
        return "absent"
    try:
        owned_file(path)
    except Refused:
        return "foreign"
    data = path.read_bytes()
    if data == expected:
        return "exact"
    if recorded is not None and hashlib.sha256(data).hexdigest() == recorded:
        return "ours"
    return "changed" if f"X-Anj-Cloud-Owner={OWNER}\n".encode() in data else "foreign"


AUTOSTART_PROBLEMS = {
    "foreign": "another file already exists at {path}; it was left untouched",
    "changed": "the login entry at {path} was changed outside AnJ Cloud; it was left untouched",
}


def set_autostart(installation, enabled, source, *, interactive=True):
    """Caller holds the transaction lock. The manager is the only writer of
    the entry; it writes or removes exactly its own bytes, never a foreign
    or edited file. Non-interactive (default-on) problems are recorded, not raised."""
    previous = read_autostart(installation)
    path = safe_path(previous["path"]) if previous else default_autostart_path()
    expected = autostart_entry(installation)
    recorded = previous["sha256"] if previous else None
    current = autostart_file_state(path, expected, recorded)
    problem = None
    if current in AUTOSTART_PROBLEMS:
        problem = AUTOSTART_PROBLEMS[current].format(path=path)
        if interactive:
            raise Refused(f"Start at login not changed: {problem}.")
    sha = recorded
    if problem is None and enabled:
        if current != "exact":
            path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            safe_path(path.parent)
            atomic_bytes(path, expected, 0o644)
        sha = hashlib.sha256(expected).hexdigest()
    elif problem is None and current in ("exact", "ours"):
        path.unlink()
        sync_dir(path.parent)
        sha = None
    state = {"owner": OWNER, "enabled": enabled and problem is None, "source": source, "path": str(path),
             "sha256": sha if enabled and problem is None else None, "problem": problem}
    atomic_json(installation.autostart_file, state)
    installation.log("autostart", enabled=state["enabled"], source=source, path=str(path), problem=problem)
    return autostart_status(installation)


def ensure_default_autostart(installation):
    """Start at login is on by default for managed installs, including
    existing installs at the first run of a manager that supports it. Never
    re-enabled once settings exist; never blocks install or launch."""
    try:
        if read_autostart(installation) is None:
            set_autostart(installation, True, "default", interactive=False)
    except (Refused, OSError) as error:
        try:
            installation.log("autostart_default_failed", error=str(error))
        except OSError:
            pass


def autostart_status(installation):
    state = read_autostart(installation)
    if state is None:
        return {"enabled": False, "source": None, "path": str(default_autostart_path()), "problem": None,
                "file": autostart_file_state(default_autostart_path(), autostart_entry(installation), None),
                "default_pending": True}
    path = safe_path(state["path"])
    current = autostart_file_state(path, autostart_entry(installation), state["sha256"])
    # Judge the file as it is now: a recorded problem (a foreign file) that
    # has since been removed no longer applies.
    problem = None
    if current in AUTOSTART_PROBLEMS:
        problem = AUTOSTART_PROBLEMS[current].format(path=path)
    elif state["enabled"] and current == "absent":
        problem = f"the login entry at {path} was removed outside AnJ Cloud"
    return {"enabled": current in ("exact", "ours"), "source": state["source"], "path": str(path),
            "problem": problem, "file": current, "default_pending": False}


def select_profile(installation, explicit, previous, legacy_closed):
    if previous:
        if explicit and str(Path(explicit).resolve()) != previous["profile"]:
            raise Refused("An update cannot change the selected profile. Keep the existing pairing/root by reference.")
        return private_dir(previous["profile"], create=False)
    if explicit:
        requested = Path(explicit).absolute()
        existed = requested.exists()
        profile = private_dir(requested.resolve())
        if existed and not legacy_closed:
            raise Refused("Existing profile adoption requires --legacy-app-closed after normally closing the known old app and observing its exit. Process-list absence alone is insufficient.")
        return profile
    data_home = Path(installation.layout["data"]).parent
    for legacy_name in ("cloud.anj.anj_cloud", "anj_cloud"):
        legacy = data_home / legacy_name / "anj-cloud/default"
        if (legacy / "manifest.sqlite").exists():
            raise Refused(f"An existing raw-bundle profile was found at {legacy}. Adopt it explicitly with --profile-dir and --legacy-app-closed; it was not moved or selected implicitly.")
    selected = private_dir(Path(installation.layout["data"]) / "profiles/default")
    if (selected / "manifest.sqlite").exists() and not legacy_closed:
        raise Refused("Existing default profile adoption requires --legacy-app-closed after observing the old app exit.")
    return selected


PROFILES_KEYS = {"owner", "profiles"}
# The client syncs <chosen root>/anj-cloud/ (lib/src/root_tree.dart RootTree.setup).
SYNCED_FOLDER = "anj-cloud"


def read_profiles(installation):
    """Known profiles: {canonical profile path: reserved root or None}. Separate file, because
    older managers reject unknown active.json/installation.json keys."""
    path = installation.config / "profiles.json"
    if not path.exists() and not path.is_symlink():
        return {}
    state = read_json(path)
    profiles = state.get("profiles")
    if (set(state) != PROFILES_KEYS or state["owner"] != OWNER or not isinstance(profiles, dict)
            or not all(isinstance(k, str) and Path(k).is_absolute() and (v is None or (isinstance(v, str) and Path(v).is_absolute()))
                       for k, v in profiles.items())):
        raise Refused("Unknown profiles record; refusing to change the selected profile.")
    return dict(profiles)


def profile_settings(profile):
    """The client's own root and staging settings, read without writing (immutable snapshot).
    Only called while the profile is closed (lock held or never launched)."""
    manifest = Path(profile) / "manifest.sqlite"
    if not manifest.is_file() or manifest.is_symlink():
        return {}
    uri = "file:" + urllib.parse.quote(str(manifest)) + "?mode=ro&immutable=1"
    try:
        connection = sqlite3.connect(uri, uri=True)
        try:
            rows = connection.execute("SELECT key, value FROM settings WHERE key IN ('root', 'staging')").fetchall()
        finally:
            connection.close()
    except sqlite3.Error as error:
        raise Refused(f"Cannot read the profile's root setting: {profile}. Nothing was changed.") from error
    return {key: value for key, value in rows if isinstance(value, str) and Path(value).is_absolute()}


def occupied_paths(installation, active):
    """Every path a known profile owns: the profile itself, its client synced folder and staging
    (manifest settings `root` and `staging`), and the synced folder of a root reserved for it by
    select-profile. The dev profile is always known (it is, or was, active)."""
    known = read_profiles(installation)
    known.setdefault(active["profile"], None)
    profiles_dir = Path(installation.layout["data"]) / "profiles"
    if profiles_dir.is_dir():
        for entry in profiles_dir.iterdir():
            if entry.is_dir() and not entry.is_symlink():
                known.setdefault(str(entry.resolve()), None)
    occupied = []
    for profile, reserved in known.items():
        paths = [("profile", profile)]
        if reserved:
            paths.append(("reserved synced folder", str(Path(reserved) / SYNCED_FOLDER)))
        if Path(profile).is_dir():
            paths += [(key, value) for key, value in profile_settings(profile).items()]
        occupied += [(profile, kind, Path(os.path.realpath(value))) for kind, value in paths]
    return known, occupied


def reserved_root(installation, profile):
    """The root select-profile reserved for a profile that has not created its root yet (the app
    then creates <root>/anj-cloud/ there without a picker, spec #34 P1); None otherwise."""
    try:
        reserved = read_profiles(installation).get(profile)
        if not reserved or profile_settings(profile).get("root"):
            return None
    except Refused:
        return None
    return reserved


def overlaps(a, b):
    return a == b or a.is_relative_to(b) or b.is_relative_to(a)


def root_target(path):
    """The chosen root (for example the home folder, #82): a directory owned by this user, or a
    path that does not exist yet. It may hold other files; its anj-cloud/ folder must not exist,
    so dev or synthetic data is never adopted. Its mode is never changed."""
    path = safe_path(Path(path).absolute())
    if path.exists():
        if not path.is_dir():
            raise Refused(f"The new root is not a directory: {path}")
        if path.stat().st_uid != os.geteuid():
            raise Refused(f"The new root is not owned by this user: {path}")
    synced = path / SYNCED_FOLDER
    if os.path.lexists(synced):
        raise Refused(f"{synced} already exists. The app creates this folder for the new profile; it must not exist "
                      "yet, so dev or synthetic data is never adopted (decision #82). Choose another root.")
    return path


def empty_private_target(path, what):
    """A path that does not exist yet, or an empty directory owned by this user. Never symlinks."""
    path = safe_path(Path(path).absolute())
    if path.exists():
        if not path.is_dir():
            raise Refused(f"The new {what} is not a directory: {path}")
        if any(path.iterdir()):
            raise Refused(f"The new {what} is not empty: {path}. A production {what} must start empty; "
                          "dev or synthetic data is never adopted.")
        if path.stat().st_uid != os.geteuid():
            raise Refused(f"The new {what} is not owned by this user: {path}")
    return path


@contextmanager
def closed_profile(profile):
    """Hold a profile's lifetime lock if it has one (refuses while its app runs). A profile with
    no lock file has never run under the lifetime protocol; nothing is created inside it."""
    profile = Path(profile)
    if (profile / ".instance.lock").exists():
        with exclusive(profile / ".instance.lock", profile=True) as fd:
            yield fd
    else:
        yield None


def select_new_profile(installation, profile, root):
    """Point the installation at a new, unpaired profile. The root may be the home folder (#82);
    the app will sync <root>/anj-cloud/, which must not exist and must not be, contain or lie
    inside another known profile's synced folder, staging or profile directory.
    The previous profile is never modified; switching back is select_existing_profile."""
    installation.load()
    with exclusive(installation.lock_file):
        state = installation.active()
        installation.check_selected_manager(state, bootstrap=True)
        profile = empty_private_target(profile, "profile")
        root = root_target(root)
        real_profile = Path(os.path.realpath(profile))
        real_synced = Path(os.path.realpath(root)) / SYNCED_FOLDER
        if overlaps(real_profile, real_synced):
            raise Refused(f"The new profile and the new synced folder {real_synced} must not contain each other.")
        for internal in (installation.config, Path(installation.layout["data"]) / "releases",
                         Path(installation.layout["data"]) / "managers", Path(installation.layout["state"])):
            for candidate in (real_profile, real_synced):
                if overlaps(candidate, Path(os.path.realpath(internal))):
                    raise Refused(f"{candidate} overlaps the installation's own files ({internal}).")
        with closed_profile(state["profile"]):
            known, occupied = occupied_paths(installation, state)
            for owner, kind, path in occupied:
                for label, candidate in (("profile", real_profile), ("synced folder", real_synced)):
                    if overlaps(candidate, path):
                        raise Refused(f"The new {label} {candidate} overlaps the {kind} of known profile {owner} ({path}). "
                                      "Choose paths used by no other profile.")
            # Check an existing profile directory's ownership and mode before creating anything.
            if profile.exists():
                private_dir(profile, create=False)
            if not profile.exists():
                profile.mkdir(mode=0o700, parents=True)
            if not root.exists():
                root.mkdir(mode=0o700, parents=True)
            private_dir(profile, create=False)
            canonical = str(profile.resolve())
            known[canonical] = str(root.resolve())
            installation.log("profile_selected", profile=canonical, previous=state["profile"], root=known[canonical], new=True)
            atomic_json(installation.config / "profiles.json", {"owner": OWNER, "profiles": known})
            updated = dict(state, profile=canonical)
            atomic_json(installation.state_file, updated)
        roots = sorted({str(path) for _, kind, path in occupied if kind != "profile"})
        return {"profile": canonical, "previous_profile": state["profile"], "root": known[canonical],
                "synced_folder": str(Path(known[canonical]) / SYNCED_FOLDER),
                "next": "Start AnJ Cloud: it creates anj-cloud/ in this root by itself (no folder to choose), "
                        "then enter the production invitation.",
                "known_roots": roots}


def select_existing_profile(installation, profile, legacy_closed):
    """Switch back to an existing profile (rollback), under the adoption guard of install()."""
    installation.load()
    with exclusive(installation.lock_file):
        state = installation.active()
        installation.check_selected_manager(state, bootstrap=True)
        requested = Path(profile).absolute()
        if not requested.exists():
            raise Refused(f"Profile {requested} does not exist; use --new to create one.")
        target = private_dir(requested.resolve(), create=False)
        canonical = str(target)
        if canonical == state["profile"]:
            return {"profile": canonical, "previous_profile": state["profile"], "changed": False}
        known = read_profiles(installation)
        if canonical not in known and not (target / "manifest.sqlite").is_file():
            raise Refused(f"{target} is not a known AnJ Cloud profile.")
        if not legacy_closed:
            raise Refused("Existing profile adoption requires --legacy-app-closed after normally closing the known old app and observing its exit. Process-list absence alone is insufficient.")
        with closed_profile(state["profile"]), closed_profile(target):
            known.setdefault(state["profile"], None)
            known.setdefault(canonical, None)
            installation.log("profile_selected", profile=canonical, previous=state["profile"], new=False)
            atomic_json(installation.config / "profiles.json", {"owner": OWNER, "profiles": known})
            atomic_json(installation.state_file, dict(state, profile=canonical))
        return {"profile": canonical, "previous_profile": state["profile"], "changed": True}


MOVE_ROOT_TIMEOUT = 120
MOVE_ROOT_BUSY = ("AnJ Cloud is running for this profile. Quit it from its tray or app menu (Quit; closing the "
                  "window only hides it), then run move-root again. Nothing was changed.")


def _run_move_root(installation, state, fd, profile_directory, target, timeout):
    """Run the active client's `--move-root` on the held profile lock `fd`."""
    profile = Path(state["profile"])
    _, occupied = occupied_paths(installation, state)
    others = sorted({str(path) for owner, _, path in occupied if owner != state["profile"]})
    revalidate_profile(profile, fd, profile_directory)
    release = installation.releases / state["release"]
    arguments = [str(release / "anj_cloud"), "--profile-dir", state["profile"],
                 "--profile-lock-fd", str(fd), "--move-root", str(target)]
    for other in others:
        arguments += ["--known-root", other]
    log_path = Path(installation.layout["state"]) / "client.log"
    if log_path.exists() or log_path.is_symlink():
        owned_file(log_path)
    log_fd = os.open(log_path, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    try:
        installation.log("root_move_started", profile=state["profile"], target=str(target), known_roots=others)
        try:
            child = subprocess.run(arguments, pass_fds=(fd,), stdin=subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=log_fd, timeout=timeout)
        except subprocess.TimeoutExpired:
            installation.log("root_move_timeout", profile=state["profile"])
            raise Refused(f"The app did not finish move-root within {timeout} seconds (a release older than "
                          "move-root ignores it: update AnJ Cloud first). If it was interrupted, run "
                          "move-root again: the profile records an unfinished move.") from None
    finally:
        os.close(log_fd)
    return child, log_path


def move_root(installation, target=None, *, timeout=MOVE_ROOT_TIMEOUT):
    """Move the selected profile's synced folder to `target` (default `$HOME/anj-cloud`) by rename only.

    The client owns the profile's manifest, so the manager only guards and delegates: it holds the
    installation lock and the profile lifetime lock (refusing while the app runs), collects every
    other known profile's paths for the overlap check, and runs the active release's client with
    `--move-root` on the inherited lock (no window, no sync). The client journals the move in the
    profile, renames with RENAME_NOREPLACE on the same filesystem only and prints one JSON line."""
    installation.load()
    with exclusive(installation.lock_file):
        state = installation.active()
        installation.check_selected_manager(state, bootstrap=True)
        target = Path(os.path.abspath(Path(target).expanduser())) if target else Path.home() / SYNCED_FOLDER
        if any(ord(char) < 32 for char in str(target)):
            raise Refused("Control characters in the target path are unsupported.")
        if not (os.environ.get("WAYLAND_DISPLAY") or os.environ.get("DISPLAY")):
            raise Refused("move-root starts the installed app without a window, which still needs the desktop "
                          "session. Run it from a terminal in your desktop session. Nothing was changed.")
        profile = Path(state["profile"])
        profile_directory = profile.stat()
        try:
            with exclusive(profile / ".instance.lock", profile=True) as fd:
                child, log_path = _run_move_root(installation, state, fd, profile_directory, target, timeout)
        except Busy:
            raise Refused(MOVE_ROOT_BUSY) from None
        outcome = None
        for line in reversed(child.stdout.decode(errors="replace").splitlines()):
            try:
                value = json.loads(line)
            except ValueError:
                continue
            if isinstance(value, dict):
                outcome = value
                break
        installation.log("root_move_finished", profile=state["profile"], code=child.returncode, outcome=outcome)
        if child.returncode == 0 and outcome is not None:
            if outcome.get("moved"):
                outcome["next"] = "Start AnJ Cloud: it syncs the folder at its new place; nothing is transferred again."
                shortcut = outcome.get("desktopShortcut")
                if isinstance(shortcut, str) and shortcut.startswith("stale:"):
                    outcome["next"] += (f" The desktop link {shortcut[len('stale:'):]} still points at the old place and "
                                        "could not be updated; remove it if you like (AnJ Cloud does not make it again).")
            else:
                outcome["next"] = f"The synced folder is already at {outcome.get('root')}; nothing was changed."
            return outcome
        if child.returncode == 2 and outcome is not None and isinstance(outcome.get("refused"), str):
            raise Refused(outcome["refused"])
        detail = (outcome or {}).get("error") or f"exit status {child.returncode}; see {log_path}"
        raise Refused(f"move-root failed ({detail}). If it was interrupted, run move-root again: the profile "
                      "records an unfinished move.")


def install(installation, archive, expected, profile=None, legacy_closed=False, *, replacing=None):
    """`replacing`: the release an in-app update was verified against; refused if another
    release became active meanwhile (spec #37 U-linux)."""
    private_dir(installation.config)
    with exclusive(installation.lock_file):
        installation.initialize()
        previous = installation.active() if installation.state_file.exists() else None
        if replacing is not None and (previous or {}).get("release") != replacing:
            raise Refused("Another release became active while this update waited; nothing was changed.")
        if previous:
            installation.check_selected_manager(previous, bootstrap=True)
        selected = select_profile(installation, profile, previous, legacy_closed)
        profile_directory = selected.stat()
        with exclusive(selected / ".instance.lock", profile=True) as profile_fd:
            with tempfile.TemporaryDirectory(prefix=".stage-", dir=installation.releases) as temporary:
                staged, receipt = extract(Path(archive), expected, Path(temporary))
                runtime_check(staged)
                source = receipt["source_head"]
                release = f"{source}-{expected.lower()}"
                destination = installation.releases / release
                if destination.exists() or destination.is_symlink():
                    if destination.is_symlink() or validate_payload(destination) != receipt:
                        raise Refused("Release destination collision; no existing payload was replaced.")
                else:
                    # No supported operation modifies a published release.
                    for item in staged.rglob("*"):
                        if item.is_file():
                            item.chmod(0o500 if os.access(item, os.X_OK) else 0o400)
                    for item in sorted((p for p in staged.rglob("*") if p.is_dir()), key=lambda p: len(p.parts), reverse=True):
                        item.chmod(0o500)
                        sync_dir(item)
                    sync_dir(staged)
                    os.rename(staged, destination)
                    destination.chmod(0o500)
                    sync_dir(destination)
                    sync_dir(installation.releases)
            # Integration is deterministic trusted code. A failure here leaves
            # activation unchanged; the complete inactive payload can be retried.
            manager_checksum = installation.integration(destination / "linux_install.py")
            state = {"owner": OWNER, "source": source, "archive_sha256": expected.lower(),
                     "release": release, "profile": str(selected), "manager_sha256": manager_checksum,
                     "previous": previous["release"] if previous and previous["release"] != release else (previous or {}).get("previous")}
            revalidate_profile(selected, profile_fd, profile_directory)
            installation.log("activation_prepared", source=source, archive_sha256=expected.lower(), profile=str(selected))
            # The atomic record is the commit point and the final fallible work.
            # A diagnostic log failure must never follow a successful activation.
            atomic_json(installation.state_file, state)
        # After the commit: login start defaults on for this managed install.
        ensure_default_autostart(installation)
        return state


def launch(installation, *, background=False):
    installation.load()
    keyring_ready = True
    if background and not wait_for_session(secrets=True):
        # The bus is required; a keyring that never unlocked is reported by
        # the visible app rather than leaving login start silently absent.
        if not wait_for_session(secrets=False, timeout=0):
            raise Refused("Login start: no graphical session bus appeared; AnJ Cloud was not started.")
        keyring_ready = False
    with exclusive(installation.lock_file):
        state = installation.active()
        installation.check_selected_manager(state)
        ensure_default_autostart(installation)
        root = installation.releases / state["release"]
        profile = Path(state["profile"])
        profile_directory = profile.stat()
        with ExitStack() as stack:
            try:
                fd = stack.enter_context(exclusive(profile / ".instance.lock", profile=True))
            except Busy:
                # Never a second process on the profile: show the running one.
                if background:
                    return {"already_running": True, "profile": state["profile"]}, None
                if activate_running(state["profile"]):
                    return {"already_running": True, "activated": True, "profile": state["profile"]}, None
                raise Refused("This profile is already running, but its window could not be shown "
                              "(an older client or no session bus). Use its tray or quit it first.") from None
            if keyring_ready:
                runtime_check(root, graphical=True)
            else:
                runtime_check(root)
                installation.log("login_keyring_unavailable", profile=state["profile"])
            revalidate_profile(profile, fd, profile_directory)
            log_path = Path(installation.layout["state"]) / "client.log"
            if log_path.exists() or log_path.is_symlink():
                owned_file(log_path)
            log_fd = os.open(log_path, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
            try:
                installation.log("launch_prepared", source=state["source"], profile=state["profile"], log=str(log_path))
                arguments = [str(root / "anj_cloud"), "--profile-dir", state["profile"],
                             "--profile-lock-fd", str(fd), "--manager-command", installation.layout["command"]]
                reserved = reserved_root(installation, state["profile"])
                if reserved:
                    arguments += ["--default-root", reserved]
                if background and keyring_ready:
                    arguments.append("--background")
                child = subprocess.Popen(arguments, pass_fds=(fd,),
                                         stdout=log_fd, stderr=subprocess.STDOUT, start_new_session=True)
            finally:
                os.close(log_fd)
            # The child now owns a duplicate of the SAME locked open description.
            # Parent close below cannot introduce a window before native adoption.
            return {"pid": child.pid, "source": state["source"], "profile": state["profile"], "log": str(log_path),
                    "background": background}, child


# In-app self-update (spec #37 U-core, U-linux; decision #159) ----------------------------------
#
# The running app downloads a release from the household server into its profile's private
# `updates/` folder, verifies it and, after the user's "Update now", quits and starts
# `apply-update` detached. This manager verifies everything again against the release key built
# into the ACTIVE release (never a key from the download), waits for the app to exit, installs
# through the same transaction as `update`, writes the outcome for the app and relaunches it.

RELEASE_TARGET = "linux-x86_64"
RELEASE_KEY_PAYLOAD = "data/flutter_assets/assets/release/household-release-key.pub"
UPDATES_DIRECTORY = "updates"
UPDATE_RESULT = "result.json"
UPDATE_WAIT_SECONDS = 120
# After the install deadline, how much longer a slow-quitting app is waited for to restart it.
UPDATE_RELAUNCH_GRACE_SECONDS = 300
SIGNED_HEADER = "anj-cloud release v1"
SIGNED_FIELDS = ("target", "version", "version_code", "size", "sha256", "key_id")
UPDATE_FIELDS = frozenset(SIGNED_FIELDS + ("signature",))
MAX_PACKAGE = 512 * 1024 * 1024
MAX_VERSION_CODE = 2_100_000_000

# Ed25519 verification (RFC 8032 section 5.1.7) in plain integers: the manager runs on the
# system Python with the standard library only. Verification handles public data only.
_P = 2 ** 255 - 19
_L = 2 ** 252 + 27742317777372353535851937790883648493
_D = -121665 * pow(121666, _P - 2, _P) % _P
_SQRT_M1 = pow(2, (_P - 1) // 4, _P)


def _point_add(a, b):
    x1, y1, z1, t1 = a
    x2, y2, z2, t2 = b
    first = (y1 - x1) * (y2 - x2) % _P
    second = (y1 + x1) * (y2 + x2) % _P
    third = 2 * t1 * t2 * _D % _P
    fourth = 2 * z1 * z2 % _P
    e, f, g, h = second - first, fourth - third, fourth + third, second + first
    return (e * f % _P, g * h % _P, f * g % _P, e * h % _P)


def _point_mul(scalar, point):
    result = (0, 1, 1, 0)
    while scalar:
        if scalar & 1:
            result = _point_add(result, point)
        point = _point_add(point, point)
        scalar >>= 1
    return result


def _point_decode(data):
    y = int.from_bytes(data, "little")
    sign = y >> 255
    y &= (1 << 255) - 1
    if y >= _P:
        return None
    x2 = (y * y - 1) * pow(_D * y * y + 1, _P - 2, _P) % _P
    if x2 == 0:
        return None if sign else (0, y, 1, 0)
    x = pow(x2, (_P + 3) // 8, _P)
    if (x * x - x2) % _P:
        x = x * _SQRT_M1 % _P
    if (x * x - x2) % _P:
        return None
    if x & 1 != sign:
        x = _P - x
    return (x, y, 1, x * y % _P)


_BASE = _point_decode((4 * pow(5, _P - 2, _P) % _P).to_bytes(32, "little"))


def _small_order(point):
    """[8]P is the identity: P is one of the 8 low-order points (the identity among them)."""
    x, y, z, _t = _point_mul(8, point)
    return x % _P == 0 and (y - z) % _P == 0


def usable_public_key(raw):
    """A 32-byte encoding of a curve point outside the small-order subgroup. A low-order key (the
    identity, or 32 zero bytes, an order-4 point) would make forged signatures verify."""
    if len(raw) != 32:
        return False
    point = _point_decode(raw)
    return point is not None and not _small_order(point)


def ed25519_verify(public, message, signature):
    """True only for a valid Ed25519 signature of `message` by the 32-byte `public` key."""
    if len(public) != 32 or len(signature) != 64 or not usable_public_key(public):
        return False
    key, commitment = _point_decode(public), _point_decode(signature[:32])
    if key is None or commitment is None:
        return False
    scalar = int.from_bytes(signature[32:], "little")
    if scalar >= _L:
        return False
    challenge = int.from_bytes(hashlib.sha512(signature[:32] + public + message).digest(), "little") % _L
    left, right = _point_mul(scalar, _BASE), _point_add(commitment, _point_mul(challenge, key))
    return (left[0] * right[2] - right[0] * left[2]) % _P == 0 and (left[1] * right[2] - right[1] * left[2]) % _P == 0


def release_key(path):
    """(raw 32-byte key, key id) from a release key file, or None when it holds no key. The file
    has `#` comments and at most one `ed25519 <base64 of the 32-byte key>` line; the key id is
    the first 16 hex characters of the key's SHA-256."""
    import base64
    import binascii
    try:
        text = Path(path).read_text()
    except FileNotFoundError:
        return None
    lines = [line.strip() for line in text.splitlines() if line.strip() and not line.strip().startswith("#")]
    if not lines:
        return None
    if len(lines) != 1 or not lines[0].startswith("ed25519 "):
        raise Refused("The built-in release key file is malformed.")
    try:
        raw = base64.b64decode(lines[0][len("ed25519 "):].strip(), validate=True)
    except (binascii.Error, ValueError) as error:
        raise Refused("The built-in release key file is malformed.") from error
    if not usable_public_key(raw):
        raise Refused("The built-in release key file is malformed.")
    return raw, hashlib.sha256(raw).hexdigest()[:16]


def signed_message(manifest):
    """Byte-for-byte services/access/release_manifest.py signed_message."""
    return ("\n".join([SIGNED_HEADER] + [f"{name} {manifest[name]}" for name in SIGNED_FIELDS]) + "\n").encode()


def verified_update(data, key, installed_code):
    """The manifest when it is a signed, newer Linux release for this key; Refused otherwise."""
    import base64
    import binascii
    if not isinstance(data, dict) or not UPDATE_FIELDS <= data.keys() or data.keys() - UPDATE_FIELDS - {"min_client_version_code"}:
        raise Refused("The update record is incomplete or has unexpected fields.")
    if data["target"] != RELEASE_TARGET:
        raise Refused("The update is for another platform.")
    if not isinstance(data["version"], str) or not re.fullmatch(r"[0-9A-Za-z][0-9A-Za-z.+_-]{0,63}", data["version"]):
        raise Refused("The update record has an invalid version.")
    for name, ceiling in (("version_code", MAX_VERSION_CODE), ("size", MAX_PACKAGE)):
        if type(data[name]) is not int or not 1 <= data[name] <= ceiling:
            raise Refused(f"The update record has an invalid {name}.")
    if not isinstance(data["sha256"], str) or not re.fullmatch(r"[0-9a-f]{64}", data["sha256"]):
        raise Refused("The update record has an invalid SHA-256.")
    if not isinstance(data["key_id"], str) or data["key_id"] != key[1]:
        raise Refused("The update is signed with a different key than this app's.")
    try:
        signature = base64.b64decode(data["signature"], validate=True) if isinstance(data["signature"], str) else b""
    except (binascii.Error, ValueError):
        signature = b""
    if not ed25519_verify(key[0], signed_message(data), signature):
        raise Refused("The update's signature does not verify.")
    if data["version_code"] <= installed_code:
        raise Refused(f"The update ({data['version_code']}) is not newer than the installed release ({installed_code}).")
    return data


def archive_receipt(path):
    """bundle-receipt.json from inside a release archive (its single top directory)."""
    with tarfile.open(path, "r:gz") as tar:
        for member in tar:
            parts = PurePosixPath(member.name).parts
            if len(parts) == 2 and parts[1] == "bundle-receipt.json" and member.isreg() and member.size <= 4 * 1024 * 1024:
                with tar.extractfile(member) as stream:
                    try:
                        receipt = json.loads(stream.read())
                    except (ValueError, UnicodeError) as error:
                        raise Refused("The update's receipt is not JSON.") from error
                if isinstance(receipt, dict):
                    return receipt
                break
    raise Refused("The update has no release receipt.")


def installed_version_code(receipt):
    code = receipt.get("version_code", 0)
    return code if type(code) is int and code >= 0 else 0


def wait_closed(profile, deadline, *, clock=time.monotonic, sleep=time.sleep):
    """True once nothing holds the profile's lifetime lock (the app has exited)."""
    while True:
        try:
            with exclusive(profile / ".instance.lock", profile=True):
                return True
        except Busy:
            if clock() >= deadline:
                return False
            sleep(0.25)


def _verify_download(installation, state, archive, manifest_path, snapshot):
    """The signed manifest when `archive` (copied to the private `snapshot` while hashed) is the
    newer release it names for the active release's built-in key; Refused otherwise."""
    active = installation.releases / state["release"]
    installed = installed_version_code(read_json(active / "bundle-receipt.json"))
    key = release_key(active / RELEASE_KEY_PAYLOAD)
    if key is None:
        raise Refused("This release has no built-in release key; install updates with `anj-cloud update`.")
    manifest = verified_update(read_json(manifest_path), key, installed)
    checksum, size = hashlib.sha256(), 0
    owned_file(archive)
    with archive.open("rb") as incoming, snapshot.open("xb") as copy:
        while chunk := incoming.read(1024 * 1024):
            size += len(chunk)
            if size > manifest["size"]:
                break
            checksum.update(chunk)
            copy.write(chunk)
    if size != manifest["size"] or checksum.hexdigest() != manifest["sha256"]:
        raise Refused("The downloaded update does not match its signed size and SHA-256.")
    receipt = archive_receipt(snapshot)
    if receipt.get("version_code") != manifest["version_code"] or receipt.get("platform") != "Linux x86_64":
        raise Refused("The update's receipt does not match its signed version.")
    return manifest


def _update_files(state, archive, manifest_path, result_path):
    """The three paths, refused unless each is absolute and directly in the active profile's
    private updates/ folder."""
    updates = private_dir(Path(state["profile"]) / UPDATES_DIRECTORY, create=False)
    for path in (archive, manifest_path, result_path):
        if path is not None and (not Path(path).is_absolute() or safe_path(path).parent != updates):
            raise Refused("Update files must be in the selected profile's private updates folder.")
    return Path(archive), Path(manifest_path), (Path(result_path) if result_path is not None else None)


def _process_gone(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return True
    except PermissionError:
        return False
    return False


def wait_app_exit(profile, app_pid, deadline, *, clock=time.monotonic, sleep=time.sleep):
    """True once the app is gone: its profile lock is free (or, without a known profile, its
    process has exited)."""
    if profile is not None:
        return wait_closed(profile, deadline, clock=clock, sleep=sleep)
    while app_pid is not None and not _process_gone(app_pid):
        if clock() >= deadline:
            return False
        sleep(0.25)
    return True


def apply_update(installation, archive, manifest_path, result_path=None, *, check=False, relaunch=True,
                 app_pid=None, wait=UPDATE_WAIT_SECONDS, grace=UPDATE_RELAUNCH_GRACE_SECONDS,
                 clock=time.monotonic, sleep=time.sleep):
    """Verify (and unless `check`, install) an update the app downloaded. The archive, manifest
    and result must be in the active profile's private `updates/` folder.

    `check` raises on any refusal and changes nothing. Otherwise every failure, whatever its kind,
    becomes an outcome: it is written to `result_path` (once that path is known to be the
    profile's), the download is discarded, and the app (which quit for this) is waited for and
    started again: the update is installed only if the app exits within `wait`; it is relaunched
    if it exits within `wait + grace`. A second concurrent run changes nothing and writes nothing."""
    if check:
        installation.load()
        state = installation.active()
        installation.check_selected_manager(state)
        archive, manifest_path, _result = _update_files(state, archive, manifest_path, result_path)
        private_dir(Path(installation.layout["state"]), create=False)
        with tempfile.TemporaryDirectory(prefix=".update-", dir=installation.layout["state"]) as temporary:
            manifest = _verify_download(installation, state, archive, manifest_path, Path(temporary) / "update.tar.gz")
        return {"ok": True, "check": True, "version": manifest["version"], "version_code": manifest["version_code"]}
    started = clock()
    deadline, relaunch_deadline = started + wait, started + wait + grace
    outcome, closed, profile, files, lock = None, None, None, None, None
    try:
        installation.load()
        lock = _apply_lock(installation)
        if lock is None:
            # Another apply-update owns this hand-over: it writes the result and relaunches.
            return {"ok": False, "message": "Another update is already being applied.", "concurrent": True}
        state = installation.active()
        profile = Path(state["profile"])
        installation.check_selected_manager(state)
        files = _update_files(state, archive, manifest_path, result_path)
        private_dir(Path(installation.layout["state"]), create=False)
        with tempfile.TemporaryDirectory(prefix=".update-", dir=installation.layout["state"]) as temporary:
            snapshot = Path(temporary) / "update.tar.gz"
            manifest = _verify_download(installation, state, files[0], files[1], snapshot)
            installation.log("update_waiting", version_code=manifest["version_code"], profile=state["profile"])
            while True:
                try:
                    applied = install(installation, snapshot, manifest["sha256"], replacing=state["release"])
                    closed = True
                    break
                except Busy:
                    if clock() >= deadline:
                        closed = False
                        raise Refused("AnJ Cloud did not quit in time; the update was not installed.") from None
                    sleep(0.25)
        outcome = {"ok": True, "version": manifest["version"], "version_code": manifest["version_code"],
                   "source": applied["source"]}
        _log(installation, "update_applied", version_code=manifest["version_code"], source=applied["source"])
    except Exception as error:  # noqa: BLE001 - the app has quit for this: always answer and restart it
        message = str(error) if isinstance(error, Refused) else f"The update could not be installed ({type(error).__name__}: {error})."
        outcome = {"ok": False, "message": message}
        _log(installation, "update_refused", reason=message)
    finally:
        if files is not None:
            # Installed or refused, the download is discarded (spec #37 rule 4).
            for path in files[:2]:
                try:
                    if path.is_file() and not path.is_symlink():
                        path.unlink()
                except OSError:
                    pass
    try:
        if files is not None and files[2] is not None:
            try:
                atomic_json(safe_path(files[2]), outcome)
            except (OSError, Refused) as error:
                _log(installation, "update_result_unwritten", reason=str(error))
        if relaunch:
            if not closed:
                closed = wait_app_exit(profile, app_pid, relaunch_deadline, clock=clock, sleep=sleep)
            outcome["relaunched"] = relaunch_app(installation) if closed else False
    finally:
        if lock is not None:
            os.close(lock)
    return outcome


def _apply_lock(installation):
    """An exclusive, non-blocking lock for one apply-update at a time; None when held."""
    path = Path(installation.layout["state"]) / ".apply-update.lock"
    private_dir(path.parent, create=False)
    fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        os.close(fd)
        return None
    return fd


def _log(installation, event, **fields):
    try:
        installation.log(event, **fields)
    except (OSError, Refused, TypeError, ValueError):
        pass


def relaunch_app(installation, timeout=180):
    """Start the app again, window shown, through the stable command: after an update that is
    the NEW manager (this one is no longer the active manager and may not launch)."""
    try:
        done = subprocess.run([installation.layout["command"], "run", "--detach"],
                              stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                              start_new_session=True, timeout=timeout, check=False)
    except (OSError, subprocess.SubprocessError) as error:
        installation.log("update_relaunch_failed", reason=str(error))
        return False
    if done.returncode:
        installation.log("update_relaunch_failed", reason=done.stderr.decode(errors="replace").strip()[-500:])
    return done.returncode == 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--installation", help="Existing installation's absolute config directory")
    sub = parser.add_subparsers(dest="action")
    for name in ("install", "update"):
        command = sub.add_parser(name)
        command.add_argument("archive", type=Path)
        command.add_argument("--sha256", required=True)
        command.add_argument("--profile-dir")
        command.add_argument("--legacy-app-closed", action="store_true")
    run = sub.add_parser("run")
    run.add_argument("--background", action="store_true",
                     help="Login start: wait for the session, start hidden in the tray and return at once")
    run.add_argument("--detach", action="store_true",
                     help="Start with the window shown and return at once (relaunch after an in-app update)")
    sub.add_parser("status")
    apply = sub.add_parser("apply-update", help="In-app update: verify, wait for the app to quit, install and relaunch")
    apply.add_argument("archive", type=Path)
    apply.add_argument("--manifest", type=Path, required=True)
    apply.add_argument("--result", type=Path)
    apply.add_argument("--check", action="store_true", help="Only verify; change nothing")
    apply.add_argument("--no-relaunch", dest="relaunch", action="store_false")
    apply.add_argument("--app-pid", type=int, help="The app that quit for this update (waited for if the profile is unknown)")
    autostart = sub.add_parser("autostart", help="Start AnJ Cloud at login (on by default for managed installs)")
    autostart.add_argument("autostart_action", choices=("enable", "disable", "status"))
    choose = sub.add_parser("select-profile", help="Switch the installation to a new or an existing profile")
    choose.add_argument("profile_dir", nargs="?", help="Existing profile to switch back to")
    choose.add_argument("--new", dest="new_profile", help="New, empty profile directory")
    choose.add_argument("--root", help="With --new: the folder the app creates anj-cloud/ in (default: the home folder)")
    choose.add_argument("--legacy-app-closed", action="store_true")
    mover = sub.add_parser("move-root", help="Move the synced folder (quit AnJ Cloud first); rename only, never copies")
    mover.add_argument("--to", help="The new synced folder, named anj-cloud (default: $HOME/anj-cloud)")
    args = parser.parse_args()
    child = None
    try:
        installation = Installation(args.installation)
        if args.action in ("install", "update"):
            if args.action == "update" and not installation.state_file.exists():
                raise Refused("No active installation to update. Use install for first adoption.")
            result = install(installation, args.archive, args.sha256, args.profile_dir, args.legacy_app_closed)
        elif args.action == "apply-update":
            result = apply_update(installation, args.archive, args.manifest, args.result,
                                  check=args.check, relaunch=args.relaunch, app_pid=args.app_pid)
            if not result["ok"]:
                print(json.dumps(result, indent=2), flush=True)
                return 1
        elif args.action == "status":
            installation.load()
            with exclusive(installation.lock_file):
                result = installation.active()
                result["log_directory"] = installation.layout["state"]
                result["rollback"] = "No automatic downgrade or database restore; retained binaries require explicit compatibility qualification."
                try:
                    result["autostart"] = autostart_status(installation)
                except Refused as error:
                    result["autostart"] = {"enabled": False, "problem": str(error)}
        elif args.action == "select-profile":
            if args.new_profile:
                if args.profile_dir:
                    raise Refused("Use either --new <profile dir> [--root <dir>], or <existing profile dir>.")
                # Spec #34 P1: the root defaults to the home folder, as the app's automatic root.
                result = select_new_profile(installation, args.new_profile, args.root or Path.home())
            else:
                if not args.profile_dir or args.root:
                    raise Refused("Use either --new <profile dir> [--root <dir>], or <existing profile dir>.")
                result = select_existing_profile(installation, args.profile_dir, args.legacy_app_closed)
        elif args.action == "move-root":
            result = move_root(installation, args.to)
        elif args.action == "autostart":
            installation.load()
            with exclusive(installation.lock_file):
                installation.check_selected_manager(installation.active())
                if args.autostart_action == "status":
                    result = autostart_status(installation)
                else:
                    result = set_autostart(installation, args.autostart_action == "enable", "user")
        else:
            background = args.action == "run" and args.background
            result, child = launch(installation, background=background)
            if background or (args.action == "run" and args.detach):
                # Detached: the client runs in its own session; no resident manager.
                child = None
        print(json.dumps(result, indent=2), flush=True)
        if child is not None:
            code = child.wait()
            if code:
                print(f"anj-cloud: client exited with status {code}; see {result['log']}", file=sys.stderr)
            return code if code >= 0 else 128 - code
    except (Refused, OSError, ValueError, tarfile.TarError, subprocess.SubprocessError) as error:
        print(f"anj-cloud: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
