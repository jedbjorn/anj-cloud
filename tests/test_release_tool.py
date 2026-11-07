"""deploy/release.py (spec #37 U-core, U-publish): the household release key and the signed
publish of a packaged Linux client. Real openssl, real git in a temporary repository, throwaway
keys only; the destination (VM or local stack) is a fake or a recorded ssh runner."""

import base64
import importlib.util
import io
import json
import os
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
        for target, reason in (("ios", "Not a desktop target"), ("windows-x64", "Only linux-x86_64, macos-arm64")):
            with self.subTest(target=target), self.assertRaisesRegex(release.Refused, reason):
                release.publish(target, self.artifact(), FakeDestination(), key_dir=self.keys, fetch=False)

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
