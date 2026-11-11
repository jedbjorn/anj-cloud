"""deploy/release.py (spec #37 U-core, U-publish): the household release key and the signed
publish of a packaged Linux client. Real openssl, real git in a temporary repository, throwaway
keys only; the destination (VM or local stack) is a fake or a recorded ssh runner."""

import base64
import hashlib
import importlib.util
import io
import json
import os
import re
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

from deploy import release
from services.access.release_manifest import manifest_from, signed_message

ROOT = Path(__file__).resolve().parent.parent
_spec = importlib.util.spec_from_file_location("linux_install_for_release_tests", ROOT / "apps/client/tool/linux_install.py")
manager = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(manager)


def git(repo, *argv):
    return subprocess.run(["git", "-C", str(repo), *argv], check=True, capture_output=True, text=True).stdout.strip()


class FakeDestination:
    def __init__(self, current=None):
        self.current, self.published = current, []

    def releases(self):
        return {"linux-x86_64": {"current": self.current, "kept": []}}

    def publish(self, target, artifact, manifest):
        self.published.append((target, Path(artifact).read_bytes(), manifest))
        return {"state": "published"}


class ReleaseToolTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="anj-release-tool-")
        self.root = Path(self.temporary.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        git(self.repo, "init", "-q", "-b", "main")
        (self.repo / "apps/client").mkdir(parents=True)
        self.commits = []
        for index in range(3):
            (self.repo / "file").write_text(str(index))
            (self.repo / "apps/client/release-version.json").write_text(json.dumps({"version_code": index + 1}))
            git(self.repo, "add", ".")
            git(self.repo, "-c", "user.name=Fixture", "-c", "user.email=f@example.invalid", "commit", "-qm", f"c{index}")
            self.commits.append(git(self.repo, "rev-parse", "HEAD"))
        git(self.repo, "update-ref", "refs/remotes/origin/main", self.commits[1])
        self.patches = [patch.object(release, "REPO", self.repo)]
        for item in self.patches:
            item.start()
        self.keys = self.root / "keys"
        self.public = self.root / "household-release-key.pub"
        self.public.write_text("# placeholder: no key yet\n")
        self.generated = release.keygen(self.keys, self.public)

    def tearDown(self):
        for item in self.patches:
            item.stop()
        self.temporary.cleanup()

    def artifact(self, commit=None, *, code=None, key_text=None, name=None):
        commit = commit or self.commits[1]
        code = int(git(self.repo, "rev-list", "--count", commit)) if code is None else code
        top = name or f"anj-cloud-linux-x86_64-{commit[:12]}"
        receipt = {"source_head": commit, "platform": "Linux x86_64", "profile_lifetime_protocol": 1,
                   "version_code": code, "version": f"2026.11.05.{code}", "files_sha256": {}}
        self.made = getattr(self, "made", 0) + 1
        path = self.root / f"{top}-{self.made}.tar.gz"
        with tarfile.open(path, "w:gz") as tar:
            for relative, data in (("bundle-receipt.json", json.dumps(receipt).encode()),
                                   (release.KEY_PAYLOAD, (self.public.read_text() if key_text is None else key_text).encode()),
                                   ("anj_cloud", b"client")):
                info = tarfile.TarInfo(f"{top}/{relative}")
                info.size = len(data)
                tar.addfile(info, io.BytesIO(data))
        return path

    def macos_artifact(self, commit=None, *, code=None, key_text=None, name=None, target="macos-arm64", extra=()):
        """A zip as tool/macos/release_macos.sh fetches it: one AnJ Cloud.app with its receipt."""
        import zipfile
        commit = commit or self.commits[1]
        code = int(git(self.repo, "rev-list", "--count", commit)) if code is None else code
        receipt = {"platform": "macOS arm64", "target": target, "version": f"2026.11.06.{code}",
                   "version_code": code, "source_head": commit}
        self.made = getattr(self, "made", 0) + 1
        path = self.root / f"{self.made}" / (name or f"anj-cloud-macos-arm64-0.1.0+{code}-{commit[:12]}.zip")
        path.parent.mkdir()
        with zipfile.ZipFile(path, "w") as archive:
            archive.writestr(release.MACOS_RECEIPT, json.dumps(receipt))
            archive.writestr(release.MACOS_KEY, self.public.read_text() if key_text is None else key_text)
            archive.writestr("AnJ Cloud.app/Contents/MacOS/AnJ Cloud", b"client")
            for member in extra:
                archive.writestr(member, b"x")
        return path

    def windows_artifact(self, commit=None, *, code=None, key_text=None, top=None, platform="Windows x86_64",
                         stamped=True, extra=(), drop=(), hashes=None, stored=False):
        """A zip as tool/windows/package.ps1 writes it: one release directory holding every file a
        release must carry and the receipt that lists each with its hash."""
        import zipfile
        commit = commit or self.commits[1]
        code = int(git(self.repo, "rev-list", "--count", commit)) if code is None else code
        files = {name: f"{name} payload".encode() * 20 for name in release.WINDOWS_REQUIRED if name not in drop}
        files[release.KEY_PAYLOAD] = (self.public.read_text() if key_text is None else key_text).encode()
        receipt = {"platform": platform, "source_head": commit,
                   "files_sha256": {name: hashlib.sha256(data).hexdigest() for name, data in files.items()}
                   if hashes is None else hashes}
        if stamped:
            receipt.update(version=f"2026.11.11.{code}", version_code=code)
        top = top or f"anj-cloud-windows-x86_64-{commit[:12]}"
        self.made = getattr(self, "made", 0) + 1
        path = self.root / f"{self.made}" / f"anj-cloud-{commit[:12]}-windows-x86_64.zip"
        path.parent.mkdir()
        with zipfile.ZipFile(path, "w", zipfile.ZIP_STORED if stored else zipfile.ZIP_DEFLATED) as archive:
            for name, data in files.items():
                archive.writestr(f"{top}/{name}", data)
            archive.writestr(f"{top}/bundle-receipt.json", json.dumps(receipt))
            for member in extra:
                archive.writestr(member, b"x")
        return path

    def publish(self, artifact, destination=None, **kwargs):
        return release.publish("linux-x86_64", artifact, destination or FakeDestination(), key_dir=self.keys, fetch=False, **kwargs)

    # Keys --------------------------------------------------------------------------------------

    def test_keygen_writes_a_private_key_and_the_public_key_file_once(self):
        key = self.keys / release.KEY_NAME
        self.assertEqual((0o700, 0o600), (self.keys.stat().st_mode & 0o777, key.stat().st_mode & 0o777))
        raw = release.parse_public(self.public.read_text())
        self.assertEqual(32, len(raw))
        self.assertEqual(release.key_id(raw), self.generated["key_id"])
        self.assertNotIn("PRIVATE", json.dumps(self.generated))
        self.assertEqual(manager.release_key(self.public), (raw, self.generated["key_id"]))
        with self.assertRaisesRegex(release.Refused, "already exists"):
            release.keygen(self.keys, self.root / "other.pub")
        with self.assertRaisesRegex(release.Refused, "already holds a key"):
            release.keygen(self.root / "keys2", self.public)

    def test_low_order_and_malformed_public_keys_are_refused(self):
        for raw in (bytes(32), b"\x01" + bytes(31)):
            with self.assertRaisesRegex(release.Refused, "not a usable"):
                release.parse_public(release.public_line(raw))
        with self.assertRaisesRegex(release.Refused, "Malformed"):
            release.parse_public("ed25519 !!\n")

    def test_a_key_that_is_not_private_is_refused(self):
        (self.keys / release.KEY_NAME).chmod(0o644)
        with self.assertRaisesRegex(release.Refused, "0600"):
            self.publish(self.artifact())
        (self.keys / release.KEY_NAME).chmod(0o600)
        self.keys.chmod(0o755)
        with self.assertRaisesRegex(release.Refused, "0700"):
            self.publish(self.artifact())

    # Publish -----------------------------------------------------------------------------------

    def test_publish_signs_a_manifest_the_linux_manager_accepts(self):
        artifact = self.artifact()
        destination = FakeDestination(current={"version_code": 1})
        result = self.publish(artifact, destination, min_client_version_code=1)
        (target, data, manifest), = destination.published
        self.assertEqual(("linux-x86_64", artifact.read_bytes()), (target, data))
        self.assertEqual(manifest, result["manifest"])
        self.assertEqual(manifest, manifest_from(manifest, "linux-x86_64"))
        self.assertEqual((2, "2026.11.05.2", 1, self.generated["key_id"]),
                         (manifest["version_code"], manifest["version"], manifest["min_client_version_code"], manifest["key_id"]))
        raw = release.parse_public(self.public.read_text())
        self.assertTrue(manager.ed25519_verify(raw, signed_message(manifest), base64.b64decode(manifest["signature"])))
        self.assertEqual(manifest, manager.verified_update(manifest, manager.release_key(self.public), 1))
        self.assertEqual(1, result["replaces"])

    def test_dry_run_signs_but_publishes_nothing(self):
        destination = FakeDestination()
        result = self.publish(self.artifact(), destination, dry_run=True)
        self.assertEqual([], destination.published)
        self.assertIn("dry-run", result["state"])

    def test_refusals_publish_nothing(self):
        other = self.root / "other.pub"
        release.keygen(self.root / "other-keys", other)
        cases = {
            "not in origin/main": (self.artifact(self.commits[2]), None),
            "is not its commit's": (self.artifact(code=7), None),
            "not above the served release's (2)": (self.artifact(), {"version_code": 2}),
            "(it has none)": (self.artifact(key_text="# none\n"), None),
            "it trusts": (self.artifact(key_text=other.read_text()), None),
            "does not match its source commit": (self.artifact(name="anj-cloud-linux-x86_64-000000000000"), None),
        }
        for reason, (artifact, current) in cases.items():
            with self.subTest(reason=reason):
                destination = FakeDestination(current)
                with self.assertRaises(release.Refused) as caught:
                    self.publish(artifact, destination)
                self.assertIn(reason, str(caught.exception))
                self.assertEqual([], destination.published)
        # android-arm64 has its own branch (tests/test_release_android.py).
        with self.assertRaisesRegex(release.Refused, "Not a desktop target"):
            release.publish("ios", self.artifact(), FakeDestination(), key_dir=self.keys, fetch=False)
        # Every signed target has a reader: none falls through to "cannot be published yet".
        self.assertEqual(set(release.SIGNED), set(release.ARTIFACT_FACTS))

    def test_publish_macos_signs_a_manifest_for_macos_arm64(self):
        artifact = self.macos_artifact()
        destination = FakeDestination()
        result = release.publish("macos-arm64", artifact, destination, key_dir=self.keys, fetch=False)
        (target, data, manifest), = destination.published
        self.assertEqual(("macos-arm64", artifact.read_bytes()), (target, data))
        self.assertEqual(manifest, manifest_from(manifest, "macos-arm64"))
        self.assertEqual(("macos-arm64", 2, "2026.11.06.2", self.generated["key_id"]),
                         (manifest["target"], manifest["version_code"], manifest["version"], manifest["key_id"]))
        raw = release.parse_public(self.public.read_text())
        self.assertTrue(manager.ed25519_verify(raw, signed_message(manifest), base64.b64decode(manifest["signature"])))
        self.assertEqual(self.commits[1], result["source_head"])

    def test_publish_macos_refuses_what_could_not_update_itself(self):
        other = self.root / "other.pub"
        release.keygen(self.root / "other-keys", other)
        cases = {
            "not in origin/main": self.macos_artifact(self.commits[2]),
            "is not its commit's": self.macos_artifact(code=7),
            "(it has none)": self.macos_artifact(key_text="# none\n"),
            "it trusts": self.macos_artifact(key_text=other.read_text()),
            "does not match its source commit": self.macos_artifact(name="anj-cloud-macos-arm64-x-000000000000.zip"),
            "has no source commit, version or version_code": self.macos_artifact(target="linux-x86_64"),
            "has no release receipt": self.macos_artifact(extra=("Other.app/x",)),
        }
        for reason, artifact in cases.items():
            with self.subTest(reason=reason):
                destination = FakeDestination()
                with self.assertRaises(release.Refused) as caught:
                    release.publish("macos-arm64", artifact, destination, key_dir=self.keys, fetch=False)
                self.assertIn(reason, str(caught.exception))
                self.assertEqual([], destination.published)
        with self.assertRaisesRegex(release.Refused, "not a readable macOS release archive"):
            release.publish("macos-arm64", self.artifact(), FakeDestination(), key_dir=self.keys, fetch=False)

    def test_publish_windows_signs_a_manifest_for_windows_x64(self):
        artifact = self.windows_artifact()
        destination = FakeDestination()
        result = release.publish("windows-x64", artifact, destination, key_dir=self.keys, fetch=False)
        (target, data, manifest), = destination.published
        self.assertEqual(("windows-x64", artifact.read_bytes()), (target, data))
        self.assertEqual(manifest, manifest_from(manifest, "windows-x64"))
        self.assertEqual(("windows-x64", 2, "2026.11.11.2", self.generated["key_id"], artifact.stat().st_size),
                         (manifest["target"], manifest["version_code"], manifest["version"], manifest["key_id"],
                          manifest["size"]))
        raw = release.parse_public(self.public.read_text())
        self.assertTrue(manager.ed25519_verify(raw, signed_message(manifest), base64.b64decode(manifest["signature"])))
        self.assertEqual(self.commits[1], result["source_head"])

    def test_publish_windows_refuses_what_could_not_update_itself(self):
        other = self.root / "other.pub"
        release.keygen(self.root / "other-keys", other)
        cases = {
            "not in origin/main": self.windows_artifact(self.commits[2]),
            "is not its commit's": self.windows_artifact(code=7),
            "(it has none)": self.windows_artifact(key_text="# none\n"),
            "it trusts": self.windows_artifact(key_text=other.read_text()),
            "does not match its source commit": self.windows_artifact(top="anj-cloud-windows-x86_64-000000000000"),
            # A package made without -VersionCode and -Version installs by hand only.
            "has no source commit, version or version_code": self.windows_artifact(stamped=False),
            "has no source commit, version or version_code ": self.windows_artifact(platform="Linux x86_64"),
            "has no release receipt": self.windows_artifact(extra=("other/x",)),
        }
        for reason, artifact in cases.items():
            with self.subTest(reason=reason):
                destination = FakeDestination()
                with self.assertRaises(release.Refused) as caught:
                    release.publish("windows-x64", artifact, destination, key_dir=self.keys, fetch=False)
                self.assertIn(reason.strip(), str(caught.exception))
                self.assertEqual([], destination.published)
        with self.assertRaisesRegex(release.Refused, "not a readable Windows release archive"):
            release.publish("windows-x64", self.artifact(), FakeDestination(), key_dir=self.keys, fetch=False)
        # What the Windows manager's ZIP reader refuses is never published: every client would
        # download it and refuse it on each check.
        import zipfile

        def crafted(change):
            source = self.windows_artifact()
            self.made += 1
            target = self.root / f"{self.made}" / source.name
            target.parent.mkdir()
            with zipfile.ZipFile(source) as old, zipfile.ZipFile(target, "w") as new:
                for info in old.infolist():
                    new.writestr(info, old.read(info))
                change(new, old.namelist()[0].split("/")[0])
            return target

        def link(archive, top):
            info = zipfile.ZipInfo(f"{top}/link")
            info.create_system = 3
            info.external_attr = 0o120777 << 16
            archive.writestr(info, "anj_cloud.exe")

        def bzip(archive, top):
            archive.writestr(zipfile.ZipInfo(f"{top}/packed.bin"), b"x" * 64, compress_type=zipfile.ZIP_BZIP2)

        crafts = {
            "a member is a link or special file": link,
            "a member uses a compression other than stored or deflate": bzip,
            "a member has an absolute or backslash name": lambda a, top: a.writestr(f"{top}\\evil.dll", b"x"),
            "a member has a name Windows cannot hold": lambda a, top: a.writestr(f"{top}/aux.txt", b"x"),
            "a member has a name Windows cannot hold ": lambda a, top: a.writestr(f"{top}/trailing.", b"x"),
            "a member repeats a name": lambda a, top: a.writestr(f"{top}/ANJ_CLOUD.EXE", b"x"),
        }
        for reason, change in crafts.items():
            with self.subTest(reason=reason):
                destination = FakeDestination()
                with self.assertRaises(release.Refused) as caught:
                    release.publish("windows-x64", crafted(change), destination, key_dir=self.keys, fetch=False)
                self.assertIn(reason.strip(), str(caught.exception))
                self.assertEqual([], destination.published)
        # The manager's own release check, done before publishing: the receipt against the payload.
        import struct

        def rewritten(change, **kwargs):
            source = self.windows_artifact(**kwargs)
            source.write_bytes(change(source.read_bytes()))
            return source

        def bad_crc(data):
            at = data.find(b"anj_cloud.exe payload")
            return data[:at] + b"X" + data[at + 1:]

        def zip64_central(data):
            # The first central-directory entry's sizes moved into a ZIP64 extra field.
            end = data.rfind(b"PK\x05\x06")
            _count, cd_size, cd_offset = struct.unpack("<HII", data[end + 10:end + 20])
            cd = data[cd_offset:cd_offset + cd_size]
            compressed, size = struct.unpack("<II", cd[20:28])
            name_len, extra_len, comment_len = struct.unpack("<HHH", cd[28:34])
            first_end = 46 + name_len + extra_len + comment_len
            extra = cd[46 + name_len:46 + name_len + extra_len] + struct.pack("<HHQQ", 1, 16, size, compressed)
            first = (cd[:6] + struct.pack("<H", 45) + cd[8:20] + struct.pack("<II", 0xFFFFFFFF, 0xFFFFFFFF)
                     + struct.pack("<HHH", name_len, len(extra), comment_len) + cd[34:46 + name_len] + extra
                     + cd[46 + name_len + extra_len:first_end])
            new_cd = first + cd[first_end:]
            return (data[:cd_offset] + new_cd + data[end:end + 12] + struct.pack("<II", len(new_cd), cd_offset)
                    + data[end + 20:])

        payloads = {
            "its receipt does not list every file a release must carry": self.windows_artifact(hashes={}),
            "its receipt does not list every file a release must carry ": self.windows_artifact(drop=("flutter_windows.dll",)),
            "does not match its receipt hash": self.windows_artifact(
                hashes={name: "0" * 64 for name in [*release.WINDOWS_REQUIRED, release.KEY_PAYLOAD]}),
            "its files are not exactly those its receipt lists": self.windows_artifact(
                extra=(f"anj-cloud-windows-x86_64-{self.commits[1][:12]}/unlisted.dll",)),
            "not a readable Windows release archive": rewritten(bad_crc, stored=True),
            "bytes precede the archive": rewritten(lambda data: b"MZ-stub-" * 64 + data),
            "a member carries a ZIP64 extra field": rewritten(zip64_central),
        }
        for reason, artifact in payloads.items():
            with self.subTest(reason=reason):
                destination = FakeDestination()
                with self.assertRaises(release.Refused) as caught:
                    release.publish("windows-x64", artifact, destination, key_dir=self.keys, fetch=False)
                self.assertIn(reason.strip(), str(caught.exception))
                self.assertEqual([], destination.published)
        # A macOS zip is not a Windows release.
        with self.assertRaisesRegex(release.Refused, "has no release receipt"):
            release.publish("windows-x64", self.macos_artifact(), FakeDestination(), key_dir=self.keys, fetch=False)

    def test_the_publisher_requires_the_files_the_windows_manager_requires(self):
        source = (Path(__file__).resolve().parent.parent / "apps/client/tool/windows_manager/manager.dart").read_text()
        block = re.search(r"const requiredFiles = \{(.*?)\};", source, re.S).group(1)
        self.assertEqual(set(re.findall(r"'([^']+)'", block)), set(release.WINDOWS_REQUIRED))

    def test_production_goes_through_the_vm_operator_over_ssh(self):
        config = self.root / "ssh_config"
        config.write_text("Host anj-prod\n")
        calls = []

        def runner(argv, **kwargs):
            command = argv[-1]
            calls.append((argv[:-1], command, kwargs.get("stdin") is not None or kwargs.get("input") is not None))
            output = b""
            if command.endswith(" releases"):
                output = json.dumps({"linux-x86_64": {"current": {"version_code": 1}, "kept": [1]}}).encode()
            elif command.startswith("umask 077 && mktemp"):
                output = b"/var/tmp/anj-release.AbCd1234\n"
            elif "release-publish" in command:
                output = b'{"state": "published"}'
            return subprocess.CompletedProcess(argv, 0, output, b"")

        destination = release.SshTarget(config=config, runner=runner)
        result = self.publish(self.artifact(), destination)
        self.assertEqual({"state": "published"}, result["published"])
        for prefix, _command, _streamed in calls:
            self.assertEqual(["ssh", "-F", str(config), "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "anj-prod", "--"], prefix)
        commands = [command for _prefix, command, _streamed in calls]
        operator = "cd /srv/anj-cloud/release/current && python3 -m deploy.access_operator --project anj-cloud-prod --state-root /srv/anj-cloud/state"
        self.assertEqual([operator + " releases", "umask 077 && mktemp -d /var/tmp/anj-release.XXXXXXXX",
                          "cat > /var/tmp/anj-release.AbCd1234/package", "cat > /var/tmp/anj-release.AbCd1234/manifest.json",
                          operator + " release-publish linux-x86_64 /var/tmp/anj-release.AbCd1234/package --manifest /var/tmp/anj-release.AbCd1234/manifest.json",
                          "rm -rf -- /var/tmp/anj-release.AbCd1234"], commands)
        self.assertEqual([False, False, True, True, False, False], [streamed for *_rest, streamed in calls])

    def test_shallow_or_dirty_checkouts_are_refused(self):
        """Review L5."""
        (self.repo / "services/access").mkdir(parents=True)
        (self.repo / "services/access/release_manifest.py").write_text("# edited\n")
        with self.assertRaisesRegex(release.Refused, "signing code has local changes"):
            self.publish(self.artifact())
        (self.repo / "services/access/release_manifest.py").unlink()
        shallow = self.root / "shallow"
        git(self.root, "clone", "-q", "--depth", "1", "file://" + str(self.repo), str(shallow))
        with patch.object(release, "REPO", shallow), self.assertRaisesRegex(release.Refused, "shallow"):
            self.publish(self.artifact())

    def test_keygen_refuses_a_symlinked_key_dir_before_writing(self):
        """Review L6."""
        target = self.root / "elsewhere"
        target.mkdir(mode=0o700)
        link = self.root / "linked-keys"
        link.symlink_to(target)
        with self.assertRaisesRegex(release.Refused, "symlink"):
            release.keygen(link, self.root / "linked.pub")
        self.assertEqual([], list(target.iterdir()))
        self.assertFalse((self.root / "linked.pub").exists())

    def test_cli_keeps_source_ref_to_local_stacks(self):
        with patch("sys.stderr", io.StringIO()) as stderr:
            self.assertEqual(1, release.main(["publish", "--target", "linux-x86_64", "--artifact", str(self.artifact()),
                                              "--source-ref", "HEAD"]))
        self.assertIn("only to --local-project", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
