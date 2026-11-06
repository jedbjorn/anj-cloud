#!/usr/bin/env python3
"""Build a clean committed Linux x86_64 runtime bundle with integrity receipts."""
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tarfile
import tempfile

from inspect_linux import inspect_bundle
from linux_install import ICON_PAYLOAD

ROOT = Path(__file__).resolve().parent.parent
REPO = ROOT.parent.parent


def run(*arguments, capture=False):
    return subprocess.run(arguments, cwd=REPO, check=True, text=True, capture_output=capture)


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def main():
    if len(sys.argv) != 2:
        sys.exit("Usage: python3 apps/client/tool/package_linux.py /absolute/absent/output-directory")
    destination = Path(sys.argv[1])
    if not destination.is_absolute() or destination.exists() or destination.is_symlink():
        sys.exit("Output must be an absolute, absent user-owned directory.")
    if platform.system() != "Linux" or platform.machine() != "x86_64":
        sys.exit("Only Linux x86_64 packaging is qualified.")
    if run("git", "status", "--porcelain", capture=True).stdout.strip():
        sys.exit("Commit the checkout before packaging so the receipt names its exact source.")
    head = run("git", "rev-parse", "HEAD", capture=True).stdout.strip()
    version_code, version = release_version(head)
    sdk = Path(os.environ.get("FLUTTER_SDK", os.path.expanduser("~/.local/share/anj-cloud/toolchains/flutter-3.47.9"))).resolve()
    if not (sdk / "bin/flutter").is_file():
        sys.exit("Set FLUTTER_SDK to the pinned Flutter 3.47.9 SDK.")
    # No host compiler, CRT, pub cache, build output, or environment is mounted.
    # A fresh git archive also excludes ignored native assets and stale objects.
    image_tag = "anj-cloud-linux-builder:debian12"
    run("docker", "build", "--platform", "linux/amd64", "-t", image_tag,
        "-f", "apps/client/tool/linux_builder.Dockerfile", "apps/client/tool")
    image_id = run("docker", "image", "inspect", "--format", "{{.Id}}", image_tag, capture=True).stdout.strip()
    with tempfile.TemporaryDirectory(prefix="anj-linux-build-") as temporary:
        staging = Path(temporary)
        with (staging / "source.tar").open("wb") as archive_stream:
            subprocess.run(["git", "archive", "--format=tar", head], cwd=REPO, stdout=archive_stream, check=True)
        # The deployment profile's release key and origin are untracked, so the archive lacks them:
        # add them to the archive (never to the checkout) before the isolated build reads it.
        sys.path.insert(0, str(REPO / "apps/client/tool"))
        import apply_profile
        with tarfile.open(staging / "source.tar", "a") as archive:
            for relative, text in apply_profile.render(apply_profile.deployment_profile.load()).items():
                data = text.encode()
                member = tarfile.TarInfo(f"apps/client/{relative}")
                member.size, member.mode, member.mtime = len(data), 0o644, 0
                archive.addfile(member, io.BytesIO(data))
        output = staging / "result"
        output.mkdir()
        run("docker", "run", "--rm", "--platform", "linux/amd64",
            "--mount", f"type=bind,source={staging},target=/input,readonly",
            "--mount", f"type=bind,source={output},target=/output",
            "--mount", f"type=bind,source={sdk},target=/sdk-source,readonly",
            image_id, "bash", "-c",
            "tar -xOf /input/source.tar apps/client/tool/build_portable_linux.sh | bash")
        audit = inspect_bundle(output / "bundle")
        _package(destination, head, output, audit, image_id, version_code, version)


def release_version(head):
    """(version_code, version) of a commit (spec #37 U-publish). The version code is the number
    of commits reachable from it (`git rev-list --count`): every commit on main is an ancestor of
    every later one, so along main it only grows, and deploy/release.py recomputes it from git
    before publishing. The version shown to people is the commit's UTC date and that code,
    e.g. 2026.11.05.612. A shallow clone would count wrong: package from a full checkout."""
    if run("git", "rev-parse", "--is-shallow-repository", capture=True).stdout.strip() == "true":
        sys.exit("Package from a full (not shallow) clone: the version code counts the commit's history.")
    code = int(run("git", "rev-list", "--count", head, capture=True).stdout.strip())
    date = subprocess.run(["git", "show", "-s", "--format=%cd", "--date=format-local:%Y.%m.%d", head], cwd=REPO,
                          check=True, text=True, capture_output=True, env={**os.environ, "TZ": "UTC"}).stdout.strip()
    return code, f"{date}.{code}"


def _package(destination, head, output, audit, image_id, version_code=None, version=None):
    # The runner/menu icon must be present even when packaging a headless build.
    # Compare it to the captured commit, never a mutable shared asset directory.
    icon = subprocess.run(["git", "show", f"{head}:apps/client/assets/branding/harbor/icon-512.png"],
                          cwd=REPO, check=True, capture_output=True).stdout
    if (output / "bundle" / ICON_PAYLOAD).read_bytes() != icon:
        raise ValueError("Bundled Harbor icon does not match the committed asset.")
    destination.mkdir(mode=0o700)
    name = f"anj-cloud-linux-x86_64-{head[:12]}"
    bundle = destination / name
    shutil.copytree(output / "bundle", bundle)
    for evidence in ("elf-audit.json", "dependency-resolution.json", "build-toolchain.txt"):
        shutil.copyfile(output / evidence, bundle / evidence)
    # Every executable byte must come from the captured commit, including the
    # manager added after the container build. Never reread mutable worktree code.
    manager = subprocess.run(["git", "show", f"{head}:apps/client/tool/linux_install.py"],
                             cwd=REPO, check=True, capture_output=True).stdout
    (bundle / "linux_install.py").write_bytes(manager)
    files = {str(path.relative_to(bundle)): digest(path) for path in sorted(bundle.rglob("*")) if path.is_file()}
    if version_code is None:
        version_code, version = release_version(head)
    receipt = {"profile_lifetime_protocol": 1, "source_head": head, "version_code": version_code, "version": version, "platform": "Linux x86_64", "flutter": "3.47.9", "dart": "3.13.7", "builder": {"image_id": image_id, "recipe": "apps/client/tool/linux_builder.Dockerfile", "target_cpu": "x86-64 baseline", "abi_ceiling": "Debian 12 (GLIBC 2.36, GLIBCXX 3.4.30, CXXABI 1.3.13)"}, "elf_audit": audit, "files_sha256": files, "scope": "User-owned runtime extraction. The VM host validation does not establish laptop acceptance; no credentials or profiles included."}
    (bundle / "bundle-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    archive = destination / f"{name}.tar.gz"
    def normalized(info):
        info.uid = info.gid = 0
        info.uname = info.gname = ""
        info.mtime = 0
        return info
    with archive.open("xb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as compressed:
            with tarfile.open(fileobj=compressed, mode="w") as tar:
                tar.add(bundle, arcname=name, filter=normalized)
    archive_hash = digest(archive)
    (destination / f"{archive.name}.sha256").write_text(f"{archive_hash}  {archive.name}\n")
    receipt.update(archive=archive.name, archive_sha256=archive_hash)
    (destination / "artifact.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps({"source_head": head, "archive": str(archive), "sha256": archive_hash}))


if __name__ == "__main__":
    main()
