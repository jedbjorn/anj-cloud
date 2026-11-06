#!/usr/bin/env python3
"""Android release builds (spec #40 R1 = spec #28 A8; decisions #108 Q6, #131). Runs on the VM host.

    release_android.py keygen
        Once: create the release keystore in ~/.local/share/anj-cloud/signing/android/ (directory
        0700, files 0600): anj-cloud-release.p12 (RSA 4096, PKCS12) and key.properties (its
        random password, for Gradle). Refuses when either exists. Prints only the certificate
        SHA-256 (for the decision log and apps/client/android/release-signer.sha256), never the
        password. The operator copies both files offline before the first install on a phone: a lost
        key means every phone must uninstall and pair again.

    release_android.py build OUT [--commit REF]
        A reproducible signed release APK (cloud.anj.anj_cloud, R8) of a committed source: `git
        archive` of the commit (default HEAD; nothing uncommitted or ignored can enter) extracted
        to a fixed path, built with the pinned Flutter and Android toolchains for arm64 phones and
        the x86_64 emulator. versionCode is the commit's `git rev-list --count` and versionName
        its UTC date and that count, as for Linux; the commit is stamped into the manifest
        (cloud.anj.source_head). OUT (absolute, absent) receives anj-cloud-<version>.apk, its
        .sha256 and build-receipt.json. The signer must be the pinned certificate.

    release_android.py github-release --apk APK [--create | --source-ref REF]
        The first-install path (#131): a GitHub release tagged android-<version> on the APK's
        commit, with the APK and its .sha256 as assets. The APK passes the publish checks first
        (pinned signer, commit on origin/main, versionCode). Without --create it only prints
        what it would run; --create needs the operator's go-ahead.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import sys
import tarfile
import tempfile

REPO = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(REPO))
from deploy import deployment_profile, release  # noqa: E402

SIGNING_DIR = Path.home() / ".local/share/anj-cloud/signing/android"
KEYSTORE = "anj-cloud-release.p12"
PROPERTIES = "key.properties"
ALIAS = "anj-cloud-release"
TOOLCHAIN = Path.home() / ".local/share/anj-cloud/toolchains/android"
FLUTTER = Path.home() / ".local/share/anj-cloud/toolchains/flutter-3.47.9"
# A fixed source path: build outputs never depend on where a temporary directory happened to be.
BUILD_ROOT = Path.home() / ".cache/anj-cloud/android-release"
TARGET_PLATFORMS = "android-arm64,android-x64"
REPOSITORY = deployment_profile.load()["repo"]["github"]


Refused = release.Refused


def git(*argv, cwd=REPO):
    done = subprocess.run(["git", "-C", str(cwd), *argv], capture_output=True, text=True)
    if done.returncode:
        raise Refused(f"git {argv[0]} failed: {done.stderr.strip()[-300:]}")
    return done.stdout.strip()


def keytool():
    java = Path(os.environ.get("JAVA_HOME") or TOOLCHAIN / "jdk-21")
    return java / "bin/keytool"


def certificate_sha256(store, password_env):
    """The keystore certificate's SHA-256, lowercase hex, read with keytool (password via env)."""
    done = subprocess.run([str(keytool()), "-exportcert", "-rfc", "-keystore", str(store), "-alias", ALIAS,
                           "-storepass:env", password_env, f"-J-Duser.home={store.parent}"],
                          capture_output=True, text=True, env=os.environ)
    if done.returncode or "BEGIN CERTIFICATE" not in done.stdout:
        raise Refused("keytool could not read the keystore certificate")
    body = "".join(line for line in done.stdout.splitlines() if line and not line.startswith("-----"))
    import base64
    return hashlib.sha256(base64.b64decode(body)).hexdigest()


def keygen(directory=SIGNING_DIR):
    directory = Path(directory)
    store, properties = directory / KEYSTORE, directory / PROPERTIES
    if store.exists() or properties.exists():
        raise Refused(f"A release keystore already exists in {directory}; it is never replaced here")
    old = os.umask(0o077)
    try:
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        directory.chmod(0o700)
        password = secrets.token_urlsafe(32)
        env_name = "ANJ_ANDROID_KEYSTORE_PASSWORD"
        os.environ[env_name] = password
        try:
            done = subprocess.run([str(keytool()), "-genkeypair", "-keystore", str(store), "-storetype", "PKCS12",
                                   "-storepass:env", env_name, "-alias", ALIAS, "-keyalg", "RSA", "-keysize", "4096",
                                   "-validity", "36500", "-dname", "CN=AnJ Cloud Android release, O=AnJ household",
                                   f"-J-Duser.home={directory}"], capture_output=True, text=True)
            if done.returncode:
                raise Refused("keytool -genkeypair failed")
            properties.write_text(f"storeFile={store}\nstorePassword={password}\nkeyAlias={ALIAS}\n"
                                  f"keyPassword={password}\n")
            for path in (store, properties):
                path.chmod(0o600)
            digest = certificate_sha256(store, env_name)
        finally:
            os.environ.pop(env_name, None)
    finally:
        os.umask(old)
    return {"keystore": str(store), "properties": str(properties), "certificate_sha256": digest,
            "offline_copy": [str(store), str(properties)]}


def release_version(commit):
    """(versionCode, versionName): as package_linux.py, the commit's rev-list count and date."""
    if git("rev-parse", "--is-shallow-repository") == "true":
        raise Refused("Build from a full (not shallow) clone: the version code counts the commit's history.")
    code = int(git("rev-list", "--count", commit))
    date = subprocess.run(["git", "-C", str(REPO), "show", "-s", "--format=%cd", "--date=format-local:%Y.%m.%d", commit],
                          capture_output=True, text=True, check=True, env={**os.environ, "TZ": "UTC"}).stdout.strip()
    return code, f"{date}.{code}"


def digest(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def build(out, commit="HEAD", signing=SIGNING_DIR / PROPERTIES, scope="anj-release-android"):
    out = Path(out)
    if not out.is_absolute() or out.exists() or out.is_symlink():
        raise Refused("OUT must be an absolute directory that does not exist yet")
    if not Path(signing).is_file():
        raise Refused(f"No signing properties at {signing} (run `release_android.py keygen` once)")
    head = git("rev-parse", "--verify", f"{commit}^{{commit}}")
    code, version = release_version(head)
    source = BUILD_ROOT / "src"
    if source.exists():
        shutil.rmtree(source)
    source.mkdir(parents=True)
    with tempfile.TemporaryDirectory(prefix="anj-android-archive-") as temporary:
        archive = Path(temporary) / "source.tar"
        with archive.open("wb") as stream:
            subprocess.run(["git", "-C", str(REPO), "archive", "--format=tar", head], stdout=stream, check=True)
        with tarfile.open(archive) as tar:
            tar.extractall(source, filter="data")
    client = source / "apps/client"
    # The deployment profile's origin (and key file) are untracked, so the archive lacks them.
    sys.path.insert(0, str(REPO / "apps/client/tool"))
    import apply_profile
    apply_profile.apply(source)
    defines = " --dart-define-from-file=anj-defines.env" if (client / "anj-defines.env").is_file() else ""
    env = {**os.environ, "ANJ_SOURCE_HEAD": head, "ANJ_ANDROID_SIGNING": str(signing),
           "FLUTTER_SUPPRESS_ANALYTICS": "true", "DART_SUPPRESS_ANALYTICS": "true"}
    command = [str(TOOLCHAIN / "bin/anj-android"), "bash", "-c",
               f"{FLUTTER}/bin/flutter --suppress-analytics pub get && "
               f"{FLUTTER}/bin/flutter --suppress-analytics build apk --release "
               f"--target-platform {TARGET_PLATFORMS} --build-number={code} --build-name={version}{defines}"]
    done = subprocess.run(["systemd-run", "--user", "--scope", "--quiet", f"--unit={scope}-{head[:12]}",
                           "-p", "MemoryMax=8G", "-p", "TasksMax=2048", "timeout", "2400", *command],
                          cwd=client, env=env)
    if done.returncode:
        raise Refused(f"flutter build apk --release failed ({done.returncode})")
    built = client / "build/app/outputs/flutter-apk/app-release.apk"
    facts = release.android_facts(built)
    release.check_android(facts, release.android_pin())
    if (facts["source_head"], facts["version_code"], facts["version"]) != (head, code, version):
        raise Refused("The built APK does not carry the commit, versionCode and versionName it was built with")
    out.mkdir(mode=0o700, parents=True)
    name = f"anj-cloud-{version}.apk"
    shutil.copyfile(built, out / name)
    (out / f"{name}.sha256").write_text(f"{facts['sha256']}  {name}\n")
    receipt = {"source_head": head, "version": version, "version_code": code, "package": facts["package"],
               "signer_sha256": facts["signers"][0], "sha256": facts["sha256"], "size": facts["size"],
               "target_platforms": TARGET_PLATFORMS, "flutter": "3.47.9", "build_root": str(source)}
    (out / "build-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    return {"apk": str(out / name), **receipt}


def github_release(apk, *, create=False, runner=subprocess.run, fetch=True, source_ref=None):
    """Checks the APK as publish does, then creates (or, by default, only shows) the release.
    source_ref (dry runs only) checks the commit against another ref, to rehearse with a branch."""
    if create and source_ref:
        raise Refused("--source-ref is for dry runs; a GitHub release is made only from origin/main")
    apk = Path(apk)
    facts = release.android_facts(apk)
    release.check_android(facts, release.android_pin())
    release.check_source(facts, source_ref or release.SOURCE_REF, fetch=fetch)
    version, head = facts["version"], facts["source_head"]
    tag, name = f"android-{version}", f"anj-cloud-{version}.apk"
    notes = (f"AnJ Cloud for Android {version} (versionCode {facts['version_code']}), built from {head}.\n\n"
             f"First install only (decision #131): download {name} on the phone, check its SHA-256 against "
             f"{name}.sha256, then install it. Later updates come from the household server in the app.\n\n"
             f"SHA-256: {facts['sha256']}\nSigning certificate SHA-256: {facts['signers'][0]}\n")
    with tempfile.TemporaryDirectory(prefix="anj-github-release-") as temporary:
        staged = Path(temporary) / name
        shutil.copyfile(apk, staged)
        checksum = Path(temporary) / f"{name}.sha256"
        checksum.write_text(f"{facts['sha256']}  {name}\n")
        argv = ["gh", "release", "create", tag, str(staged), str(checksum), "--repo", REPOSITORY,
                "--target", head, "--title", f"AnJ Cloud for Android {version}", "--notes", notes]
        plan = {"tag": tag, "target_commit": head, "assets": [name, f"{name}.sha256"], "sha256": facts["sha256"],
                "signer_sha256": facts["signers"][0], "version_code": facts["version_code"],
                "command": ["gh", "release", "create", tag, name, f"{name}.sha256", "--repo", REPOSITORY,
                            "--target", head, "--title", f"AnJ Cloud for Android {version}", "--notes", "…"]}
        if not create:
            return {**plan, "state": "dry-run: no GitHub release created"}
        exists = runner(["gh", "release", "view", tag, "--repo", REPOSITORY], capture_output=True)
        if exists.returncode == 0:
            raise Refused(f"GitHub release {tag} already exists; releases are never replaced")
        done = runner(argv, capture_output=True, text=True)
        if done.returncode:
            raise Refused("gh release create failed: " + (done.stderr or "")[-300:])
        return {**plan, "state": "created", "url": (done.stdout or "").strip()}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("keygen", help="Create the Android release keystore (once)")
    made = sub.add_parser("build", help="Build a signed release APK of a committed source")
    made.add_argument("out", type=Path)
    made.add_argument("--commit", default="HEAD")
    gh = sub.add_parser("github-release", help="Create the GitHub release for first installs (operator go-ahead)")
    gh.add_argument("--apk", type=Path, required=True)
    gh.add_argument("--create", action="store_true", help="Really create it (default: show what would run)")
    gh.add_argument("--source-ref", help="Dry runs only: check the commit against this ref instead of origin/main")
    args = parser.parse_args(argv)
    try:
        if args.command == "keygen":
            result = keygen()
        elif args.command == "build":
            result = build(args.out, args.commit)
        else:
            result = github_release(args.apk, create=args.create, source_ref=args.source_ref)
    except (Refused, OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"ERROR {error}", file=sys.stderr)
        return 1
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
