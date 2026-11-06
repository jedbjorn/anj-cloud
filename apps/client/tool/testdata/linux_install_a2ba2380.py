#!/usr/bin/env python3
"""Trusted, local-only Linux installer/launcher. Python 3.11+, no network/feed.

Obtain this script from reviewed source. An archive checksum cannot establish the
trustworthiness of the program which checks it. Never run a downloaded script
merely because it is alongside the archive.
"""
import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
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


class Refused(Exception):
    pass


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
            message = ("This profile is already running. Close its app normally before launching or updating."
                       if profile else "Another installation transaction is running; retry after it finishes.")
            raise Refused(message) from error
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


def install(installation, archive, expected, profile=None, legacy_closed=False):
    private_dir(installation.config)
    with exclusive(installation.lock_file):
        installation.initialize()
        previous = installation.active() if installation.state_file.exists() else None
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
            return state


def launch(installation):
    installation.load()
    with exclusive(installation.lock_file):
        state = installation.active()
        installation.check_selected_manager(state)
        root = installation.releases / state["release"]
        profile = Path(state["profile"])
        profile_directory = profile.stat()
        with exclusive(profile / ".instance.lock", profile=True) as fd:
            runtime_check(root, graphical=True)
            revalidate_profile(profile, fd, profile_directory)
            log_path = Path(installation.layout["state"]) / "client.log"
            if log_path.exists() or log_path.is_symlink():
                owned_file(log_path)
            log_fd = os.open(log_path, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
            try:
                installation.log("launch_prepared", source=state["source"], profile=state["profile"], log=str(log_path))
                child = subprocess.Popen([str(root / "anj_cloud"), "--profile-dir", state["profile"],
                                          "--profile-lock-fd", str(fd)], pass_fds=(fd,),
                                         stdout=log_fd, stderr=subprocess.STDOUT, start_new_session=True)
            finally:
                os.close(log_fd)
            # The child now owns a duplicate of the SAME locked open description.
            # Parent close below cannot introduce a window before native adoption.
            return {"pid": child.pid, "source": state["source"], "profile": state["profile"], "log": str(log_path)}, child


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
    sub.add_parser("run")
    sub.add_parser("status")
    args = parser.parse_args()
    child = None
    try:
        installation = Installation(args.installation)
        if args.action in ("install", "update"):
            if args.action == "update" and not installation.state_file.exists():
                raise Refused("No active installation to update. Use install for first adoption.")
            result = install(installation, args.archive, args.sha256, args.profile_dir, args.legacy_app_closed)
        elif args.action == "status":
            installation.load()
            with exclusive(installation.lock_file):
                result = installation.active()
                result["log_directory"] = installation.layout["state"]
                result["rollback"] = "No automatic downgrade or database restore; retained binaries require explicit compatibility qualification."
        else:
            result, child = launch(installation)
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
