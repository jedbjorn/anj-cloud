"""deploy/release.py publish --target android-arm64 (spec #40 R1): the release APK's identity,
pinned signer, source commit and version rules. Real git in a temporary repository; aapt2 and
apksigner are recorded fakes (their real output shapes); the destination is a fake."""

import importlib.util
import io
import os
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from deploy import release
from services.access.release_manifest import manifest_from

_TOOL = Path(__file__).resolve().parent.parent / "apps/client/tool/android/release_android.py"
_spec = importlib.util.spec_from_file_location("release_android_for_tests", _TOOL)
tool = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(tool)

ORIGINAL_FACTS = release.android_facts
PIN = "e6" * 32
OTHER = "b2" * 32


def git(repo, *argv):
    return subprocess.run(["git", "-C", str(repo), *argv], check=True, capture_output=True, text=True).stdout.strip()


class FakeDestination:
    def __init__(self, current=None):
        self.current, self.published = current, []

    def releases(self):
        return {"android-arm64": {"current": self.current, "kept": []}}

    def publish(self, target, artifact, manifest):
        self.published.append((target, Path(artifact).read_bytes(), manifest))
        return {"state": "published"}


def badging(package, code, name):
    return (f"package: name='{package}' versionCode='{code}' versionName='{name}' platformBuildVersionName='16' "
            f"platformBuildVersionCode='36' compileSdkVersion='36' compileSdkVersionCodename='16'\n"
            f"sdkVersion:'31'\ntargetSdkVersion:'36'\n")


def xmltree(head):
    lines = ["N: android=http://schemas.android.com/apk/res/android (line=2)", "  E: manifest (line=2)",
             "      E: meta-data (line=40)",
             '        A: http://schemas.android.com/apk/res/android:name(0x01010003)="flutterEmbedding" (Raw: "flutterEmbedding")',
             '        A: http://schemas.android.com/apk/res/android:value(0x01010024)="2" (Raw: "2")']
    if head is not None:
        lines += ["      E: meta-data (line=36)",
                  '        A: http://schemas.android.com/apk/res/android:name(0x01010003)="cloud.anj.source_head" (Raw: "cloud.anj.source_head")',
                  f'        A: http://schemas.android.com/apk/res/android:value(0x01010024)="{head}" (Raw: "{head}")']
    return "\n".join(lines) + "\n"


def certs(*digests):
    return "".join(f"Signer #{i} certificate DN: CN=AnJ Cloud Android release, O=AnJ household\n"
                   f"Signer #{i} certificate SHA-256 digest: {d}\n"
                   f"Signer #{i} certificate SHA-1 digest: {'00' * 20}\n" for i, d in enumerate(digests, 1))


class AndroidPublishTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="anj-release-android-")
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
        pin = self.root / "release-signer.sha256"
        pin.write_text(f"# pin\n{PIN}\n")
        self.patches = [patch.object(release, "REPO", self.repo), patch.object(release, "ANDROID_PIN_FILE", pin),
                        patch.object(release, "android_tools", lambda: ("aapt2", "apksigner", {}))]
        for item in self.patches:
            item.start()
        self.apk = self.root / "anj-cloud.apk"
        self.apk.write_bytes(b"PK\x03\x04 release apk bytes")
        self.facts = {}

    def tearDown(self):
        for item in self.patches:
            item.stop()
        self.temporary.cleanup()

    def describe(self, *, package="cloud.anj.anj_cloud", commit=None, code=None, name=None, signers=(PIN,),
                 verified=True, stamp=True):
        commit = commit or self.commits[1]
        code = int(git(self.repo, "rev-list", "--count", commit)) if code is None else code
        self.facts = {"badging": badging(package, code, name or f"2026.11.06.{code}"),
                      "xmltree": xmltree(commit if stamp else None), "certs": certs(*signers), "verified": verified}

    def runner(self, argv, **kwargs):
        tool = argv[0]
        if tool == "aapt2":
            output = self.facts["badging"] if argv[2] == "badging" else self.facts["xmltree"]
            return subprocess.CompletedProcess(argv, 0, output.encode(), b"")
        if tool == "apksigner":
            if not self.facts["verified"]:
                return subprocess.CompletedProcess(argv, 1, b"", b"DOES NOT VERIFY")
            return subprocess.CompletedProcess(argv, 0, self.facts["certs"].encode(), b"")
        return subprocess.run(argv, **kwargs)

    def publish(self, destination=None, **kwargs):
        return release.publish("android-arm64", self.apk, destination or FakeDestination(), fetch=False,
                               runner=self.runner, **kwargs)

    def test_publish_sends_the_unsigned_android_manifest(self):
        self.describe()
        destination = FakeDestination(current={"version_code": 1, "signer_sha256": PIN})
        result = self.publish(destination)
        (target, data, manifest), = destination.published
        self.assertEqual(("android-arm64", self.apk.read_bytes()), (target, data))
        self.assertEqual(manifest, manifest_from(manifest, "android-arm64"))
        self.assertEqual((2, "2026.11.06.2", PIN, len(data)),
                         (manifest["version_code"], manifest["version"], manifest["signer_sha256"], manifest["size"]))
        self.assertNotIn("signature", manifest)
        self.assertNotIn("key_id", manifest)
        self.assertEqual((self.commits[1], 1), (result["source_head"], result["replaces"]))

    def test_dry_run_checks_but_publishes_nothing(self):
        self.describe()
        destination = FakeDestination()
        result = self.publish(destination, dry_run=True)
        self.assertEqual([], destination.published)
        self.assertIn("dry-run", result["state"])

    def test_refusals_publish_nothing(self):
        cases = {
            "not the release app": dict(package="cloud.anj.anj_cloud.qa"),
            "no source commit stamp": dict(stamp=False),
            "exactly one signing certificate (it has 2)": dict(signers=(PIN, OTHER)),
            "not the pinned release certificate": dict(signers=(OTHER,)),
            "does not verify": dict(verified=False),
            "not in origin/main": dict(commit=self.commits[2]),
            "is not its commit's": dict(code=7),
        }
        for reason, arrange in cases.items():
            with self.subTest(reason=reason):
                self.describe(**arrange)
                destination = FakeDestination()
                with self.assertRaises(release.Refused) as caught:
                    self.publish(destination)
                self.assertIn(reason, str(caught.exception))
                self.assertEqual([], destination.published)
        self.describe()
        for reason, current in ((r"not above the served release's \(2\)", {"version_code": 2, "signer_sha256": PIN}),):
            with self.subTest(reason=reason):
                destination = FakeDestination(current)
                with self.assertRaisesRegex(release.Refused, reason):
                    self.publish(destination)
                self.assertEqual([], destination.published)
        with self.assertRaisesRegex(release.Refused, "desktop releases only"):
            self.publish(min_client_version_code=1)

    def test_a_test_certificate_is_pinned_only_when_named(self):
        self.describe(signers=(OTHER,))
        destination = FakeDestination()
        self.publish(destination, signer_sha256=OTHER)
        self.assertEqual(OTHER, destination.published[0][2]["signer_sha256"])
        with self.assertRaisesRegex(release.Refused, "android-arm64 only"):
            release.publish("linux-x86_64", self.apk, FakeDestination(), fetch=False, signer_sha256=OTHER)

    def test_cli_keeps_the_test_certificate_to_local_stacks(self):
        with patch("sys.stderr", io.StringIO()) as stderr:
            self.assertEqual(1, release.main(["publish", "--target", "android-arm64", "--artifact", str(self.apk),
                                              "--signer-sha256", OTHER]))
        self.assertIn("only to --local-project", stderr.getvalue())

    def test_the_example_pin_is_one_sha256(self):
        committed = Path(__file__).resolve().parent.parent / "apps/client/android/release-signer.sha256.example"
        self.assertEqual(64, len(release.android_pin(committed)))
        bad = self.root / "bad.sha256"
        for text in ("", f"{PIN}\n{PIN}\n", PIN.upper() + "\n", "abc\n"):
            bad.write_text(text)
            with self.subTest(text=text), self.assertRaisesRegex(release.Refused, "one lowercase SHA-256"):
                release.android_pin(bad)

    # The first-install GitHub release (#131) -------------------------------------------------

    def github(self, **kwargs):
        with patch.object(release, "android_facts", lambda path, runner=None, tools=None: self.android_facts(path)):
            return tool.github_release(self.apk, fetch=False, **kwargs)

    def android_facts(self, path):
        return ORIGINAL_FACTS(path, self.runner, ("aapt2", "apksigner", {}))

    def test_github_release_is_a_dry_run_unless_asked(self):
        self.describe()
        calls = []
        plan = self.github(runner=lambda argv, **kw: calls.append(argv))
        self.assertEqual([], calls)
        self.assertIn("dry-run", plan["state"])
        self.assertEqual(("android-2026.11.06.2", self.commits[1]), (plan["tag"], plan["target_commit"]))
        self.assertEqual(["anj-cloud-2026.11.06.2.apk", "anj-cloud-2026.11.06.2.apk.sha256"], plan["assets"])

    def test_github_release_create_tags_the_commit_with_the_apk_and_its_sha256(self):
        self.describe()
        calls = []

        def runner(argv, **kwargs):
            calls.append(argv)
            if argv[:3] == ["gh", "release", "view"]:
                return subprocess.CompletedProcess(argv, 1, "", "release not found")
            assets = [Path(a) for a in argv[4:6]]
            self.assertEqual(self.apk.read_bytes(), assets[0].read_bytes())
            self.assertEqual(f"{ORIGINAL_FACTS(self.apk, self.runner, ('aapt2', 'apksigner', {}))['sha256']}  "
                             "anj-cloud-2026.11.06.2.apk\n", assets[1].read_text())
            return subprocess.CompletedProcess(argv, 0, "https://github.com/x/y/releases/tag/t\n", "")

        plan = self.github(create=True, runner=runner)
        self.assertEqual("created", plan["state"])
        create = calls[1]
        self.assertEqual(["gh", "release", "create", "android-2026.11.06.2"], create[:4])
        self.assertEqual(self.commits[1], create[create.index("--target") + 1])
        calls.clear()
        with self.assertRaisesRegex(release.Refused, "already exists"):
            self.github(create=True, runner=lambda argv, **kw: subprocess.CompletedProcess(argv, 0, "", ""))

    def test_github_release_rehearses_a_branch_only_as_a_dry_run(self):
        self.describe(commit=self.commits[2])
        plan = self.github(source_ref="main", runner=lambda argv, **kw: self.fail("gh must not run"))
        self.assertIn("dry-run", plan["state"])
        with self.assertRaisesRegex(release.Refused, "for dry runs"):
            self.github(create=True, source_ref="main", runner=lambda argv, **kw: self.fail("gh must not run"))

    def test_github_release_refuses_what_publish_refuses(self):
        for arrange, reason in ((dict(signers=(OTHER,)), "pinned release certificate"),
                                (dict(commit=self.commits[2]), "not in origin/main")):
            with self.subTest(reason=reason):
                self.describe(**arrange)
                with self.assertRaisesRegex(release.Refused, reason):
                    self.github(create=True, runner=lambda argv, **kw: self.fail("gh must not run"))


class AndroidKeygenTests(unittest.TestCase):
    @unittest.skipUnless(tool.keytool().is_file(), "no JDK keytool on this host")
    def test_keygen_writes_a_private_keystore_once_and_prints_no_password(self):
        with tempfile.TemporaryDirectory(prefix="anj-android-keygen-") as temporary:
            directory = Path(temporary) / "signing/android"
            result = tool.keygen(directory)
            store, properties = directory / tool.KEYSTORE, directory / tool.PROPERTIES
            self.assertEqual((0o700, 0o600, 0o600), (directory.stat().st_mode & 0o777, store.stat().st_mode & 0o777,
                                                     properties.stat().st_mode & 0o777))
            password = dict(line.split("=", 1) for line in properties.read_text().splitlines())["storePassword"]
            self.assertNotIn(password, json.dumps(result))
            self.assertRegex(result["certificate_sha256"], "^[0-9a-f]{64}$")
            self.assertEqual(sorted([str(store), str(properties)]), sorted(result["offline_copy"]))
            self.assertEqual({tool.KEYSTORE, tool.PROPERTIES}, {p.name for p in directory.iterdir()})
            self.assertNotIn("ANJ_ANDROID_KEYSTORE_PASSWORD", os.environ)
            with self.assertRaisesRegex(tool.Refused, "already exists"):
                tool.keygen(directory)


if __name__ == "__main__":
    unittest.main()
