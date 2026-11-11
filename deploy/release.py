#!/usr/bin/env python3
"""Desktop client releases (spec #37 U-core, U-publish; decision #159). Runs on the VM host, standard
library plus the `openssl` command (3.0+); never builds anything.

    release.py keygen [--key-dir DIR] [--public-out FILE]
        Once per household: create the Ed25519 release key. The private key goes to
        ~/.local/share/anj-cloud/release-key/release-key.pem (directory 0700, file 0600) and never
        leaves the VM host; the public key is written to the client's built-in key file
        (apps/client/assets/release/household-release-key.pub) for a reviewed commit. Refuses
        when a key already exists. Prints the key id and the public key's SHA-256 fingerprint
        (for the decision log), never the private key.

    release.py publish --target linux-x86_64 --artifact <anj-cloud-linux-x86_64-*.tar.gz>
    release.py publish --target macos-arm64 --artifact <anj-cloud-macos-arm64-*.zip>
    release.py publish --target windows-x64 --artifact <anj-cloud-*-windows-x86_64.zip>
                       [--min-client-version-code N] [--dry-run]
                       [--ssh-host anj-prod] [--ssh-config FILE]
                       | --local-project NAME [--port N] [--source-ref REF]
        Takes an artifact apps/client/tool/package_linux.py built (macOS: tool/macos/release_macos.sh;
        Windows: tool/windows/package.ps1 with -VersionCode and -Version) and publishes it signed:
          - its receipt's source commit must be in origin/main (fetched first) and its
            version_code must be that commit's apps/client/release-version.json;
          - its built-in release key must be the key that signs it (a release that trusts another
            key could never update itself again);
          - its version_code must be above the release the target serves now;
          - the manifest {version, version_code, size, sha256, key_id, signature} is signed with
            the VM host key over services/access/release_manifest.py signed_message;
          - it is published through the operator's release-publish: by default over
            `ssh -F ~/.local/share/anj-cloud/prod-vm/ssh_config anj-prod` in the production VM
            (the files are copied to a private temporary directory there and removed after);
            with --local-project, against a dev or review stack on this host (only there may
            --source-ref name another ref than origin/main, for disposable test builds).
        --dry-run checks and signs but publishes nothing.

    release.py publish --target android-arm64 --artifact <anj-cloud-android-*.apk> [--dry-run]
                       [--ssh-host anj-prod] [--ssh-config FILE]
                       | --local-project NAME [--port N] [--source-ref REF] [--signer-sha256 HEX]
        Publishes a signed release APK apps/client/tool/android/release_android.py built (spec #40
        R1). The same rules, with Android's own trust (decision #108 Q6): no household key; the
        APK must be cloud.anj.anj_cloud signed by exactly one certificate, the one pinned in
        apps/client/android/release-signer.sha256 (a rotated key is a reviewed change there); its
        cloud.anj.source_head commit must be in origin/main and its versionCode that commit's
        committed release number, above the served release's. The manifest {version, version_code,
        size, sha256, signer_sha256} is not signed: Android trusts the APK's certificate.
        --signer-sha256 (local stacks only) pins another certificate, for test keys.
"""

import argparse
import base64
import hashlib
import importlib.util
import json
import os
import re
from pathlib import Path, PurePosixPath
import shlex
import stat
import struct
import subprocess
import sys
import tarfile
import tempfile

REPO = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO))
from deploy import deployment_profile, client_version  # noqa: E402
from services.access.release_manifest import SIGNED, ManifestError, manifest_from, signed_message  # noqa: E402

# The Linux manager's standard-library Ed25519 (one implementation of the curve checks).
_MANAGER_SOURCE = Path(__file__).resolve().parent.parent / "apps/client/tool/linux_install.py"
_spec = importlib.util.spec_from_file_location("anj_linux_install_for_release", _MANAGER_SOURCE)
_manager = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_manager)

KEY_DIR = Path.home() / ".local/share/anj-cloud/release-key"
KEY_NAME = "release-key.pem"
PUBLIC_KEY_FILE = REPO / "apps/client/assets/release/household-release-key.pub"
KEY_PAYLOAD = "data/flutter_assets/assets/release/household-release-key.pub"
PUBLIC_HEADER = ("# AnJ Cloud household release key (spec #37 U-core, decision #159).\n"
                 "# The Ed25519 public key desktop builds trust for in-app updates. The private key lives on\n"
                 "# The VM host only (~/.local/share/anj-cloud/release-key/). Written by `deploy/release.py keygen`.\n")
SSH_HOST = "anj-prod"
SSH_CONFIG = Path.home() / ".local/share/anj-cloud/prod-vm/ssh_config"
PROD_OPERATOR = ("cd /srv/anj-cloud/release/current && python3 -m deploy.access_operator "
                 "--project anj-cloud-prod --state-root /srv/anj-cloud/state")
# The production ssh target is the one VM; a local stack is a dev or review stack on this host.
SOURCE_REF = "origin/main"
# Ed25519 SubjectPublicKeyInfo DER: this fixed prefix, then the 32-byte key.
SPKI_PREFIX = bytes.fromhex("302a300506032b6570032100")


class Refused(Exception):
    pass


def run(argv, runner=subprocess.run, **kwargs):
    kwargs.setdefault("check", False)
    kwargs.setdefault("capture_output", True)
    return runner(argv, **kwargs)


# Keys ------------------------------------------------------------------------------------------

def key_id(raw):
    return hashlib.sha256(raw).hexdigest()[:16]


def public_line(raw):
    return "ed25519 " + base64.b64encode(raw).decode()


def parse_public(text):
    """The raw 32-byte key from a built-in key file's text, or None when it holds no key."""
    lines = [line.strip() for line in text.splitlines() if line.strip() and not line.strip().startswith("#")]
    if not lines:
        return None
    if len(lines) != 1 or not lines[0].startswith("ed25519 "):
        raise Refused("Malformed release key file")
    try:
        raw = base64.b64decode(lines[0][len("ed25519 "):], validate=True)
    except ValueError:
        raise Refused("Malformed release key file") from None
    if not _manager.usable_public_key(raw):
        raise Refused("Malformed release key file (not a usable Ed25519 public key)")
    return raw


def private_key_path(key_dir):
    """The private key, after checking it is ours and private (directory 0700, file 0600)."""
    directory = Path(key_dir)
    path = directory / KEY_NAME
    try:
        info, file_info = directory.lstat(), path.lstat()
    except FileNotFoundError:
        raise Refused(f"No release key at {path}. Create it once with: deploy/release.py keygen") from None
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid() or info.st_mode & 0o077:
        raise Refused(f"{directory} must be a private directory (0700) owned by you")
    if not stat.S_ISREG(file_info.st_mode) or file_info.st_uid != os.geteuid() or file_info.st_mode & 0o077:
        raise Refused(f"{path} must be a private file (0600) owned by you")
    return path


def public_from_private(path, runner=subprocess.run):
    done = run(["openssl", "pkey", "-in", str(path), "-pubout", "-outform", "DER"], runner)
    if done.returncode or not done.stdout.startswith(SPKI_PREFIX) or len(done.stdout) != len(SPKI_PREFIX) + 32:
        raise Refused("The release key is not an Ed25519 key openssl can read")
    return done.stdout[len(SPKI_PREFIX):]


def keygen(key_dir=KEY_DIR, public_out=PUBLIC_KEY_FILE, runner=subprocess.run):
    key_dir = Path(key_dir)
    path = key_dir / KEY_NAME
    # Nothing is created or written through a symlink (review L6): the key must land where named.
    if key_dir.is_symlink() or (key_dir.exists() and not key_dir.is_dir()):
        raise Refused(f"{key_dir} is a symlink or not a directory; nothing was written.")
    if path.exists() or path.is_symlink():
        raise Refused(f"A release key already exists at {path}; nothing was changed. Rotation is a new key and a manual reinstall (spec #37 rule 2).")
    public_out = Path(public_out)
    if public_out.exists() and parse_public(public_out.read_text()) is not None:
        raise Refused(f"{public_out} already holds a key; nothing was changed.")
    previous = os.umask(0o077)
    try:
        key_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        key_dir.chmod(0o700)
        done = run(["openssl", "genpkey", "-algorithm", "ed25519", "-out", str(path)], runner)
        if done.returncode:
            path.unlink(missing_ok=True)
            raise Refused("openssl could not create the key: " + done.stderr.decode(errors="replace").strip())
        path.chmod(0o600)
    finally:
        os.umask(previous)
    raw = public_from_private(private_key_path(key_dir), runner)
    public_out.parent.mkdir(parents=True, exist_ok=True)
    public_out.write_text(PUBLIC_HEADER + public_line(raw) + "\n")
    return {"private_key": str(path), "public_key_file": str(public_out), "key_id": key_id(raw),
            "public_key_sha256": hashlib.sha256(raw).hexdigest(), "public_key": public_line(raw),
            "next": "Put public_key and key_id in your deployment profile ([release] in profile.toml; the public "
                    "key file is generated from it by apps/client/tool/apply_profile.py); keep an offline copy of "
                    "the private key."}


def sign(path, message, runner=subprocess.run):
    with tempfile.TemporaryDirectory(prefix="anj-release-sign-") as temporary:
        source, target = Path(temporary) / "message", Path(temporary) / "signature"
        source.write_bytes(message)
        done = run(["openssl", "pkeyutl", "-sign", "-inkey", str(path), "-rawin", "-in", str(source), "-out", str(target)], runner)
        if done.returncode or not target.exists() or target.stat().st_size != 64:
            raise Refused("openssl could not sign the release manifest")
        signature = target.read_bytes()
        verify = run(["openssl", "pkeyutl", "-verify", "-inkey", str(path), "-rawin", "-in", str(source), "-sigfile", str(target)], runner)
        if verify.returncode:
            raise Refused("The signature did not verify with the release key")
    return signature


# Artifacts -------------------------------------------------------------------------------------

def artifact_facts(path):
    """(receipt, built-in public key or None, size, sha256) of a Linux release archive."""
    path = Path(path)
    if path.is_symlink() or not path.is_file():
        raise Refused("The artifact must be a regular file")
    checksum, size = hashlib.sha256(), 0
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            checksum.update(chunk)
            size += len(chunk)
    receipt = key = None
    tops = set()
    try:
        with tarfile.open(path, "r:gz") as tar:
            for member in tar:
                parts = PurePosixPath(member.name).parts
                if not parts:
                    continue
                tops.add(parts[0])
                relative = "/".join(parts[1:])
                if member.isreg() and relative == "bundle-receipt.json" and member.size < 4 << 20:
                    receipt = json.loads(tar.extractfile(member).read())
                elif member.isreg() and relative == KEY_PAYLOAD and member.size < 64 << 10:
                    key = parse_public(tar.extractfile(member).read().decode())
    except (tarfile.TarError, OSError, ValueError, UnicodeError) as error:
        raise Refused(f"The artifact is not a readable release archive ({error})") from None
    if not isinstance(receipt, dict) or len(tops) != 1:
        raise Refused("The artifact has no release receipt (build it with apps/client/tool/package_linux.py)")
    source, code = receipt.get("source_head"), receipt.get("version_code")
    if (receipt.get("platform") != "Linux x86_64" or not isinstance(source, str) or len(source) != 40
            or type(code) is not int or code < 1 or not isinstance(receipt.get("version"), str)):
        raise Refused("The artifact's receipt has no source commit, version or version_code "
                      "(package it with a package_linux.py that stamps them)")
    if tops.pop() != f"anj-cloud-linux-x86_64-{source[:12]}":
        raise Refused("The artifact's directory does not match its source commit")
    return receipt, key, size, checksum.hexdigest()


MACOS_APP = "AnJ Cloud.app"
MACOS_RECEIPT = MACOS_APP + "/Contents/Resources/bundle-receipt.json"
MACOS_KEY = MACOS_APP + "/Contents/Frameworks/App.framework/Versions/A/Resources/flutter_assets/assets/release/household-release-key.pub"


def macos_artifact_facts(path):
    """(receipt, built-in public key or None, size, sha256) of a macOS release archive (spec #40
    R2): the zip apps/client/tool/macos/release_macos.sh fetches, holding one AnJ Cloud.app whose
    Contents/Resources/bundle-receipt.json package_release.sh stamped."""
    import zipfile
    path = Path(path)
    if path.is_symlink() or not path.is_file():
        raise Refused("The artifact must be a regular file")
    checksum, size = hashlib.sha256(), 0
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            checksum.update(chunk)
            size += len(chunk)
    try:
        with zipfile.ZipFile(path) as archive:
            names = archive.namelist()
            tops = {PurePosixPath(name).parts[0] for name in names if PurePosixPath(name).parts} - {"__MACOSX"}
            receipt = json.loads(archive.read(MACOS_RECEIPT)) if MACOS_RECEIPT in names else None
            key = parse_public(archive.read(MACOS_KEY).decode()) if MACOS_KEY in names else None
    except (zipfile.BadZipFile, OSError, ValueError, UnicodeError, KeyError) as error:
        raise Refused(f"The artifact is not a readable macOS release archive ({error})") from None
    if tops != {MACOS_APP} or not isinstance(receipt, dict):
        raise Refused("The artifact has no release receipt (build it with apps/client/tool/macos/release_macos.sh)")
    source, code = receipt.get("source_head"), receipt.get("version_code")
    if (receipt.get("target") != "macos-arm64" or not isinstance(source, str) or len(source) != 40
            or type(code) is not int or code < 1 or not isinstance(receipt.get("version"), str)):
        raise Refused("The artifact's receipt has no source commit, version or version_code "
                      "(package it with tool/macos/release_macos.sh)")
    if not path.name.endswith(f"-{source[:12]}.zip"):
        raise Refused("The artifact's name does not match its source commit")
    return receipt, key, size, checksum.hexdigest()


# What the Windows manager's own ZIP reader and release check refuse (apps/client/tool/windows_manager/zip.dart,
# manager.dart `validRelative`): an archive published past these would be downloaded by every client and
# refused by each of them, on every check.
WINDOWS_MAX_MEMBERS = 10000
WINDOWS_MAX_UNPACKED = 2 * 1024 * 1024 * 1024
# manager.dart `requiredFiles`: what every Windows release must carry (tests/test_release_tool.py
# reads the Dart list and compares).
WINDOWS_REQUIRED = frozenset({
    "anj_cloud.exe", "flutter_windows.dll", "anj_rootfs.dll", "anj-cloud-manager.exe", "data/app.so",
    "data/icudtl.dat", "msvcp140.dll", "vcruntime140.dll", "vcruntime140_1.dll"})
WINDOWS_RESERVED = re.compile(r"(CON|PRN|AUX|NUL|COM[0-9¹²³]|LPT[0-9¹²³]|CONIN\$|CONOUT\$)")


def windows_member_refusal(info):
    """Why the Windows manager would refuse this ZIP member; None when it would not."""
    import stat as stat_module
    import zipfile
    if info.flag_bits & 0x1:
        return "is encrypted"
    if info.compress_type not in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED):
        return "uses a compression other than stored or deflate"
    if info.file_size >= 0xFFFFFFFF or info.compress_size >= 0xFFFFFFFF or info.header_offset >= 0xFFFFFFFF:
        return "needs ZIP64"
    extra = info.extra
    while len(extra) >= 4:   # the manager reads sizes from the fixed fields only
        kind, length = struct.unpack("<HH", extra[:4])
        if kind == 0x0001:
            return "carries a ZIP64 extra field"
        extra = extra[4 + length:]
    kind = stat_module.S_IFMT(info.external_attr >> 16)
    if info.create_system == 3 and kind not in (0, stat_module.S_IFREG, stat_module.S_IFDIR):
        return "is a link or special file"
    name = info.orig_filename
    if not info.flag_bits & 0x800 and not name.isascii():
        return "has a name that is not UTF-8"
    directory = name.endswith("/")
    if directory and info.file_size:
        return "is a directory with data"
    name = name[:-1] if directory else name
    if not name or name.startswith("/") or "\\" in name:
        return "has an absolute or backslash name"
    for part in name.split("/"):
        if (not part or part in (".", "..") or len(part) > 255 or part.endswith((".", " "))
                or any(ord(c) < 0x20 or c in '<>:"|?*' for c in part)
                or WINDOWS_RESERVED.fullmatch(part.split(".")[0].rstrip().upper())):
            return "has a name Windows cannot hold"
    return None


def windows_payload_refusal(archive, members, top, receipt):
    """Why the manager's release check (manager.dart `_validate`) would refuse this payload; None when it
    would not: the files are exactly those the receipt lists, each with its hash, and the required ones
    are there. Reading every member also checks its CRC-32, as the manager's extraction does."""
    hashes = receipt.get("files_sha256")
    if not isinstance(hashes, dict) or not WINDOWS_REQUIRED <= hashes.keys():
        return "its receipt does not list every file a release must carry"
    files = {info.orig_filename[len(top) + 1:]: info for info in members if not info.orig_filename.endswith("/")}
    if files.keys() != hashes.keys() | {"bundle-receipt.json"}:
        return "its files are not exactly those its receipt lists"
    for name, expected in hashes.items():
        if not isinstance(expected, str) or not re.fullmatch(r"[a-f0-9]{64}", expected):
            return "its receipt has an invalid hash"
        if hashlib.sha256(archive.read(files[name])).hexdigest() != expected:
            return f"{name} does not match its receipt hash"
    return None


def windows_artifact_facts(path):
    """(receipt, built-in public key or None, size, sha256) of a Windows release archive:
    the zip apps/client/tool/windows/package.ps1 writes, holding one
    anj-cloud-windows-x86_64-<source12> directory whose bundle-receipt.json carries the version
    (-VersionCode, -Version)."""
    import zipfile
    path = Path(path)
    if path.is_symlink() or not path.is_file():
        raise Refused("The artifact must be a regular file")
    checksum, size = hashlib.sha256(), 0
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            checksum.update(chunk)
            size += len(chunk)
    try:
        with zipfile.ZipFile(path) as archive:
            members = archive.infolist()
            names = archive.namelist()
            if len(members) > WINDOWS_MAX_MEMBERS or sum(info.file_size for info in members) > WINDOWS_MAX_UNPACKED:
                raise Refused("The artifact has more members or bytes than the Windows manager accepts")
            # Python tolerates bytes in front of an archive and adjusts every offset; the manager does not.
            if members and min(info.header_offset for info in members) != 0:
                raise Refused("The Windows manager would refuse this artifact: bytes precede the archive")
            seen = set()
            for info in members:
                refusal = windows_member_refusal(info)
                folded = info.orig_filename.rstrip("/").lower()
                if refusal is None and folded in seen:
                    refusal = "repeats a name (Windows names ignore case)"
                if refusal:
                    raise Refused(f"The Windows manager would refuse this artifact: a member {refusal}")
                seen.add(folded)
            tops = {PurePosixPath(name).parts[0] for name in names if PurePosixPath(name).parts}
            top = next(iter(tops)) if len(tops) == 1 else ""
            receipt = json.loads(archive.read(f"{top}/bundle-receipt.json")) if f"{top}/bundle-receipt.json" in names else None
            key = parse_public(archive.read(f"{top}/{KEY_PAYLOAD}").decode()) if f"{top}/{KEY_PAYLOAD}" in names else None
            payload = windows_payload_refusal(archive, members, top, receipt) if isinstance(receipt, dict) else None
    except (zipfile.BadZipFile, OSError, ValueError, UnicodeError, KeyError) as error:
        raise Refused(f"The artifact is not a readable Windows release archive ({error})") from None
    if not isinstance(receipt, dict):
        raise Refused("The artifact has no release receipt (build it with apps/client/tool/windows/package.ps1)")
    if payload:
        raise Refused(f"The Windows manager would refuse this artifact: {payload}")
    source, code = receipt.get("source_head"), receipt.get("version_code")
    if (receipt.get("platform") != "Windows x86_64" or not isinstance(source, str) or len(source) != 40
            or type(code) is not int or code < 1 or not isinstance(receipt.get("version"), str)):
        raise Refused("The artifact's receipt has no source commit, version or version_code "
                      "(package it with tool/windows/package.ps1 -VersionCode <n> -Version <v>)")
    if top != f"anj-cloud-windows-x86_64-{source[:12]}":
        raise Refused("The artifact's directory does not match its source commit")
    return receipt, key, size, checksum.hexdigest()


# Desktop targets this tool publishes, and how each artifact is read.
ARTIFACT_FACTS = {"linux-x86_64": artifact_facts, "macos-arm64": macos_artifact_facts,
                  "windows-x64": windows_artifact_facts}


# The files whose code decides what is signed and how (review L5): a local edit could sign bytes
# no client accepts.
SIGNING_PATHS = ("deploy/release.py", "deploy/client_version.py", "apps/client/release-version.json", "services/access/release_manifest.py", "apps/client/tool/linux_install.py")


def check_checkout(runner=subprocess.run):
    """A full clone for ancestry verification, with the signing code as committed."""
    git = ["git", "-C", str(REPO)]
    shallow = run([*git, "rev-parse", "--is-shallow-repository"], runner)
    if shallow.returncode or shallow.stdout.decode().strip() != "false":
        raise Refused("Publish from a full clone: this checkout is shallow (or not a git checkout), so source ancestry "
                      "cannot be verified. Run `git fetch --unshallow` or use the main checkout.")
    dirty = run([*git, "status", "--porcelain", "--", *SIGNING_PATHS], runner)
    if dirty.returncode or dirty.stdout.strip():
        raise Refused("The signing code has local changes (" + ", ".join(SIGNING_PATHS) + "); commit or discard them "
                      "before publishing.")


def check_source(receipt, ref=SOURCE_REF, *, fetch=True, runner=subprocess.run):
    """The receipt's commit is in `ref` and carries the allocated release number."""
    check_checkout(runner)
    git = ["git", "-C", str(REPO)]
    if fetch:
        done = run([*git, "fetch", "--quiet", "origin", "main"], runner)
        if done.returncode:
            raise Refused("git fetch origin main failed: " + done.stderr.decode(errors="replace").strip())
    source = receipt["source_head"]
    if run([*git, "cat-file", "-e", source + "^{commit}"], runner).returncode:
        raise Refused(f"Commit {source[:12]} is not known to this checkout")
    if run([*git, "merge-base", "--is-ancestor", source, ref], runner).returncode:
        raise Refused(f"Commit {source[:12]} is not in {ref}; only merged commits are published")
    try:
        expected = client_version.version_code(REPO, source, runner)
    except ValueError as error:
        raise Refused(str(error)) from error
    if expected != receipt["version_code"]:
        raise Refused(f"The artifact's version_code {receipt['version_code']} is not its commit's "
                      f"allocated release number ({expected})")



# Targets ---------------------------------------------------------------------------------------

class SshTarget:
    """The production VM through halo-vm.sh's ssh_config; the operator CLI runs there as anj."""

    def __init__(self, host=SSH_HOST, config=None, runner=subprocess.run):
        self.host, self.runner = host, runner
        config = Path(config).expanduser() if config is not None else SSH_CONFIG
        if not config.is_file():
            raise Refused(f"ssh_config not found: {config}")
        self.config = config

    def ssh(self, command, **kwargs):
        argv = ["ssh", "-F", str(self.config), "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", self.host, "--", command]
        return run(argv, self.runner, **kwargs)

    def releases(self):
        done = self.ssh(PROD_OPERATOR + " releases")
        if done.returncode:
            raise Refused("Could not read the served releases: " + done.stderr.decode(errors="replace").strip()[-300:])
        return json.loads(done.stdout)

    def publish(self, target, artifact, manifest):
        made = self.ssh("umask 077 && mktemp -d /var/tmp/anj-release.XXXXXXXX")
        directory = made.stdout.decode().strip()
        if made.returncode or not directory.startswith("/var/tmp/anj-release."):
            raise Refused("Could not create a private directory in the VM")
        remote_dir = shlex.quote(directory)
        try:
            with Path(artifact).open("rb") as stream:
                copied = self.ssh(f"cat > {remote_dir}/package", stdin=stream)
            if copied.returncode:
                raise Refused("Copying the package into the VM failed")
            written = self.ssh(f"cat > {remote_dir}/manifest.json", input=json.dumps(manifest).encode())
            if written.returncode:
                raise Refused("Copying the manifest into the VM failed")
            done = self.ssh(f"{PROD_OPERATOR} release-publish {shlex.quote(target)} {remote_dir}/package "
                            f"--manifest {remote_dir}/manifest.json")
        finally:
            self.ssh(f"rm -rf -- {remote_dir}")
        if done.returncode:
            raise Refused("release-publish refused: " + done.stderr.decode(errors="replace").strip()[-500:])
        return json.loads(done.stdout)


class LocalTarget:
    """A dev or review stack on this host (deploy/dev.py), through the same operator CLI."""

    def __init__(self, project, port=None, runner=subprocess.run, python=sys.executable):
        self.runner = runner
        self.base = [python, "-m", "deploy.access_operator", "--project", project, *(["--port", str(port)] if port else [])]

    def operator(self, *argv):
        return run([*self.base, *argv], self.runner, cwd=REPO)

    def releases(self):
        done = self.operator("releases")
        if done.returncode:
            raise Refused("Could not read the served releases: " + done.stderr.decode(errors="replace").strip()[-300:])
        return json.loads(done.stdout)

    def publish(self, target, artifact, manifest):
        with tempfile.TemporaryDirectory(prefix="anj-release-") as temporary:
            path = Path(temporary) / "manifest.json"
            path.write_text(json.dumps(manifest))
            done = self.operator("release-publish", target, str(artifact), "--manifest", str(path))
        if done.returncode:
            raise Refused("release-publish refused: " + done.stderr.decode(errors="replace").strip()[-500:])
        return json.loads(done.stdout)


# Android (spec #40 R1) ---------------------------------------------------------------------------

ANDROID_TARGET = "android-arm64"
ANDROID_PACKAGE = "cloud.anj.anj_cloud"
ANDROID_PIN_FILE = REPO / "apps/client/android/release-signer.sha256"
# The files that decide what an Android release is checked against.
ANDROID_PATHS = ("apps/client/android/release-signer.sha256",)
ANDROID_TOOLCHAIN = Path.home() / ".local/share/anj-cloud/toolchains/android"


def android_pin(path=None, profile=None):
    """The pinned release certificate SHA-256 (lowercase hex): the named pin file, else the deployment
    profile's [release] android_signer_sha256, else the untracked pin file next to the sources."""
    if path is None:
        profile = profile or deployment_profile.load()
        value = (profile["release"].get("android_signer_sha256") or "").strip()
        if value:
            return _checked_pin(value)
        if not Path(ANDROID_PIN_FILE).is_file():
            raise Refused("No Android signer pin: set [release] android_signer_sha256 in the deployment profile "
                          "(deploy/profile.example.toml) or provide apps/client/android/release-signer.sha256")
    lines = [line.strip() for line in Path(path or ANDROID_PIN_FILE).read_text().splitlines()
             if line.strip() and not line.lstrip().startswith("#")]
    if len(lines) != 1:
        raise Refused("The Android signer pin file must hold one lowercase SHA-256")
    return _checked_pin(lines[0])


def _checked_pin(value):
    if len(value) != 64 or any(c not in "0123456789abcdef" for c in value):
        raise Refused("The Android signer pin file must hold one lowercase SHA-256")
    return value


def android_tools():
    """(aapt2, apksigner, environment) from the Android SDK's newest build-tools."""
    sdk = Path(os.environ.get("ANDROID_HOME") or ANDROID_TOOLCHAIN / "sdk")
    versions = sorted((sdk / "build-tools").glob("*"), key=lambda p: [int(x) if x.isdigit() else x for x in p.name.split(".")])
    if not versions:
        raise Refused(f"No Android build-tools under {sdk}")
    env = dict(os.environ)
    if not env.get("JAVA_HOME") and (ANDROID_TOOLCHAIN / "jdk-21").is_dir():
        env["JAVA_HOME"] = str(ANDROID_TOOLCHAIN / "jdk-21")
    if env.get("JAVA_HOME"):  # apksigner runs the `java` it finds on PATH
        env["PATH"] = str(Path(env["JAVA_HOME"]) / "bin") + os.pathsep + env.get("PATH", "")
    return versions[-1] / "aapt2", versions[-1] / "apksigner", env


def android_facts(path, runner=subprocess.run, tools=None):
    """{package, version_code, version, source_head, signers, size, sha256} of a release APK, read
    with the SDK's aapt2 and apksigner (which also verifies the APK's signatures)."""
    path = Path(path)
    if path.is_symlink() or not path.is_file():
        raise Refused("The artifact must be a regular file")
    checksum, size = hashlib.sha256(), 0
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1 << 20), b""):
            checksum.update(chunk)
            size += len(chunk)
    aapt2, apksigner, env = tools or android_tools()
    badging = run([str(aapt2), "dump", "badging", str(path)], runner, env=env)
    if badging.returncode:
        raise Refused("The artifact is not a readable Android package")
    head = badging.stdout.decode(errors="replace").splitlines()[0] if badging.stdout else ""
    fields = dict(re.findall(r"(\w+)='([^']*)'", head)) if head.startswith("package:") else {}
    tree = run([str(aapt2), "dump", "xmltree", "--file", "AndroidManifest.xml", str(path)], runner, env=env)
    text = tree.stdout.decode(errors="replace") if not tree.returncode else ""
    stamp = re.search(r'A: http://schemas.android.com/apk/res/android:name\(0x[0-9a-f]+\)="cloud\.anj\.source_head"'
                      r'[^\n]*\n\s*A: http://schemas.android.com/apk/res/android:value\(0x[0-9a-f]+\)="([0-9a-f]*)"', text)
    certs = run([str(apksigner), "verify", "--print-certs", str(path)], runner, env=env)
    if certs.returncode:
        raise Refused("apksigner does not verify the artifact's signature")
    signers = re.findall(r"Signer #\d+ certificate SHA-256 digest: ([0-9a-f]{64})", certs.stdout.decode(errors="replace"))
    try:
        code = int(fields.get("versionCode", ""))
    except ValueError:
        code = None
    return {"package": fields.get("name"), "version_code": code, "version": fields.get("versionName"),
            "source_head": stamp.group(1) if stamp else None, "signers": signers, "size": size,
            "sha256": checksum.hexdigest()}


def check_android(facts, pin):
    """The release-APK rules that need no git or server: identity, one signer, the pin."""
    if facts["package"] != ANDROID_PACKAGE:
        raise Refused(f"The APK is {facts['package']!r}, not the release app {ANDROID_PACKAGE}")
    source, code = facts["source_head"], facts["version_code"]
    if not source or len(source) != 40 or not isinstance(code, int) or code < 1 or not facts["version"]:
        raise Refused("The APK has no source commit stamp, version or versionCode "
                      "(build it with apps/client/tool/android/release_android.py build)")
    if len(facts["signers"]) != 1:
        raise Refused(f"The APK must have exactly one signing certificate (it has {len(facts['signers'])})")
    if facts["signers"][0] != pin:
        raise Refused(f"The APK is signed by {facts['signers'][0][:16]}…, not the pinned release certificate "
                      f"{pin[:16]}…; installed apps would refuse it")


def publish_android(artifact, destination, *, source_ref=SOURCE_REF, fetch=True, signer_sha256=None,
                    dry_run=False, runner=subprocess.run, tools=None):
    if signer_sha256 is None:
        dirty = run(["git", "-C", str(REPO), "status", "--porcelain", "--", *ANDROID_PATHS], runner)
        if dirty.returncode or dirty.stdout.strip():
            raise Refused("The Android signer pin has local changes; commit or discard them before publishing.")
    pin = (signer_sha256 or android_pin()).lower()
    facts = android_facts(artifact, runner, tools)
    check_android(facts, pin)
    check_source(facts, source_ref, fetch=fetch, runner=runner)
    current = (destination.releases().get(ANDROID_TARGET) or {}).get("current")
    if current and facts["version_code"] <= current["version_code"]:
        raise Refused(f"version_code {facts['version_code']} is not above the served release's ({current['version_code']})")
    try:
        manifest = manifest_from({"target": ANDROID_TARGET, "version": facts["version"],
                                  "version_code": facts["version_code"], "size": facts["size"],
                                  "sha256": facts["sha256"], "signer_sha256": pin}, ANDROID_TARGET)
    except ManifestError as error:
        raise Refused(str(error)) from None
    result = {"manifest": manifest, "source_head": facts["source_head"],
              "replaces": current["version_code"] if current else None}
    if dry_run:
        return {**result, "state": "dry-run: nothing published"}
    return {**result, "published": destination.publish(ANDROID_TARGET, artifact, manifest)}


def publish(target, artifact, destination, *, key_dir=KEY_DIR, source_ref=SOURCE_REF, fetch=True,
            min_client_version_code=None, dry_run=False, runner=subprocess.run, signer_sha256=None,
            expected_key_id=None):
    if target == ANDROID_TARGET:
        if min_client_version_code is not None:
            raise Refused("--min-client-version-code applies to desktop releases only")
        return publish_android(artifact, destination, source_ref=source_ref, fetch=fetch,
                               signer_sha256=signer_sha256, dry_run=dry_run, runner=runner)
    if signer_sha256 is not None:
        raise Refused("--signer-sha256 applies to android-arm64 only")
    if target not in ARTIFACT_FACTS:
        raise Refused(f"Only {', '.join(sorted(ARTIFACT_FACTS))} artifacts can be published by this tool yet"
                      if target in SIGNED
                      else "Not a desktop target; Android releases use release-publish with their APK signer")
    receipt, built_in, size, sha256 = ARTIFACT_FACTS[target](artifact)
    check_source(receipt, source_ref, fetch=fetch, runner=runner)
    key_path = private_key_path(key_dir)
    public = public_from_private(key_path, runner)
    if expected_key_id is not None and key_id(public) != expected_key_id:
        raise Refused(f"The release key is {key_id(public)}, not the deployment profile's [release] key_id "
                      f"({expected_key_id or 'empty'}); nothing was published")
    if built_in != public:
        raise Refused("The artifact's built-in release key is not the VM host release key "
                      + ("(it has none)" if built_in is None else f"(it trusts {key_id(built_in)})")
                      + "; a release must trust the key that signs it")
    current = (destination.releases().get(target) or {}).get("current")
    if current and receipt["version_code"] <= current["version_code"]:
        raise Refused(f"version_code {receipt['version_code']} is not above the served release's ({current['version_code']})")
    manifest = {"target": target, "version": receipt["version"], "version_code": receipt["version_code"],
                "size": size, "sha256": sha256, "key_id": key_id(public)}
    manifest["signature"] = base64.b64encode(sign(key_path, signed_message(manifest), runner)).decode()
    if min_client_version_code is not None:
        manifest["min_client_version_code"] = min_client_version_code
    try:
        manifest = manifest_from(manifest, target)
    except ManifestError as error:
        raise Refused(str(error)) from None
    result = {"manifest": manifest, "source_head": receipt["source_head"],
              "replaces": current["version_code"] if current else None}
    if dry_run:
        return {**result, "state": "dry-run: nothing published"}
    return {**result, "published": destination.publish(target, artifact, manifest)}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    keys = sub.add_parser("keygen", help="Create the household release key (once)")
    keys.add_argument("--key-dir", type=Path, default=KEY_DIR)
    keys.add_argument("--public-out", type=Path, default=PUBLIC_KEY_FILE)
    out = sub.add_parser("publish", help="Sign and publish a packaged desktop release")
    out.add_argument("--target", required=True)
    out.add_argument("--artifact", type=Path, required=True)
    out.add_argument("--key-dir", type=Path, default=KEY_DIR)
    out.add_argument("--min-client-version-code", type=int)
    out.add_argument("--dry-run", action="store_true")
    out.add_argument("--ssh-host", default=SSH_HOST)
    out.add_argument("--ssh-config", type=Path)
    out.add_argument("--local-project", help="A dev or review stack on this host instead of production")
    out.add_argument("--port", type=int)
    out.add_argument("--source-ref", help="With --local-project only: the ref the commit must be in (default origin/main)")
    out.add_argument("--signer-sha256", help="android-arm64 with --local-project only: the test certificate to pin")
    args = parser.parse_args(argv)
    try:
        if args.command == "keygen":
            result = keygen(args.key_dir, args.public_out)
        else:
            if args.local_project:
                destination = LocalTarget(args.local_project, args.port)
            elif args.source_ref or args.port or args.signer_sha256:
                raise Refused("--source-ref, --port and --signer-sha256 apply only to --local-project "
                              "(production publishes origin/main with the pinned certificate)")
            else:
                destination = SshTarget(args.ssh_host, args.ssh_config)
            # Production publishes only with the key the deployment profile names (a missing or wrong
            # profile is a refusal, never a release under another key); a local stack uses test keys.
            expected = None if args.local_project else deployment_profile.load()["release"].get("key_id", "")
            result = publish(args.target, args.artifact, destination, key_dir=args.key_dir,
                             source_ref=args.source_ref or SOURCE_REF,
                             min_client_version_code=args.min_client_version_code, dry_run=args.dry_run,
                             signer_sha256=args.signer_sha256, expected_key_id=expected)
    except (Refused, OSError, ValueError) as error:
        print(f"ERROR {error}", file=sys.stderr)
        return 1
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
