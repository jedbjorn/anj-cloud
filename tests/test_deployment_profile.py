"""The per-deployment profile: lookup order, placeholder fallback, and its application to a client tree."""

import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "apps/client/tool"))

from deploy import deployment_profile as dp, release  # noqa: E402
import apply_profile  # noqa: E402

KEY = "ed25519 " + "A" * 43 + "="


class ProfileTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(lambda: __import__("shutil").rmtree(self.tmp, True))
        self.home = self.tmp / "home"
        (self.home / ".local/share/anj-cloud").mkdir(parents=True)

    def env(self, **extra):
        return {"HOME": str(self.home), **extra}

    def write(self, path, body):
        Path(path).parent.mkdir(parents=True, exist_ok=True)
        Path(path).write_text(body)
        return path

    def test_example_is_complete_and_placeholder(self):
        profile = dp.load({"HOME": str(self.tmp / "none"), "ANJ_PROFILE": str(dp.EXAMPLE)})
        self.assertEqual(profile["gateway"]["host"], "gateway.example.com")
        self.assertEqual(profile["release"]["public_key"], "")
        for section in ("gateway", "host", "network", "dns", "household", "release", "repo"):
            self.assertIn(section, profile)

    def test_no_file_gives_placeholders(self):
        profile = dp.load({"HOME": str(self.tmp / "none")})
        self.assertTrue(profile["placeholder"] or profile["source"].endswith("profile.toml"))
        self.assertEqual(profile["dns"]["provider"], "cloudflare")

    def test_lookup_order(self):
        self.write(self.home / ".local/share/anj-cloud/profile.toml", '[gateway]\nhost = "home.example.org"\n')
        self.assertEqual(dp.get("gateway.host", self.env()), "home.example.org")
        explicit = self.write(self.tmp / "x.toml", '[gateway]\nhost = "env.example.org"\n')
        self.assertEqual(dp.get("gateway.host", self.env(ANJ_PROFILE=str(explicit))), "env.example.org")

    def test_partial_profile_falls_back_per_key(self):
        explicit = self.write(self.tmp / "x.toml", '[gateway]\nhost = "env.example.org"\n')
        profile = dp.load(self.env(ANJ_PROFILE=str(explicit)))
        self.assertEqual(profile["network"]["router"], "192.168.0.1")
        self.assertFalse(profile["placeholder"])

    def test_missing_explicit_profile_is_an_error(self):
        with self.assertRaises(FileNotFoundError):
            dp.load(self.env(ANJ_PROFILE=str(self.tmp / "absent.toml")))

    def test_apply_writes_key_and_origin(self):
        explicit = self.write(self.tmp / "x.toml", f'[gateway]\norigin = "https://home.example.org"\n[release]\npublic_key = "{KEY}"\n')
        root = self.tmp / "tree"
        written = apply_profile.apply(root, dp.load(self.env(ANJ_PROFILE=str(explicit))))
        self.assertEqual(written, ["anj-defines.env", "assets/release/household-release-key.pub"])
        client = root / "apps/client"
        self.assertIn(KEY, (client / "assets/release/household-release-key.pub").read_text())
        self.assertEqual((client / "anj-defines.env").read_text(), "ANJ_HOUSEHOLD_ORIGIN=https://home.example.org\n")

    def test_apply_with_placeholder_profile_writes_a_keyless_file_and_no_origin(self):
        root = self.tmp / "tree"
        apply_profile.apply(root, dp.load({"HOME": str(self.tmp / "none"), "ANJ_PROFILE": str(dp.EXAMPLE)}))
        client = root / "apps/client"
        text = (client / "assets/release/household-release-key.pub").read_text()
        self.assertFalse([line for line in text.splitlines() if not line.startswith("#") and line.strip()])
        self.assertFalse((client / "anj-defines.env").exists())

    # The production release guards -----------------------------------------------------------

    def test_android_pin_comes_from_the_profile_and_is_validated(self):
        good = "ab" * 32
        explicit = self.write(self.tmp / "x.toml", f'[release]\nandroid_signer_sha256 = "{good}"\n')
        self.assertEqual(good, release.android_pin(profile=dp.load(self.env(ANJ_PROFILE=str(explicit)))))
        bad = self.write(self.tmp / "y.toml", '[release]\nandroid_signer_sha256 = "ABC"\n')
        with self.assertRaisesRegex(release.Refused, "one lowercase SHA-256"):
            release.android_pin(profile=dp.load(self.env(ANJ_PROFILE=str(bad))))

    def test_android_pin_refuses_when_nothing_is_configured(self):
        with patch.object(release, "ANDROID_PIN_FILE", self.tmp / "absent.sha256"), \
                self.assertRaisesRegex(release.Refused, "No Android signer pin"):
            release.android_pin(profile=dp.load({"HOME": str(self.tmp / "none"), "ANJ_PROFILE": str(dp.EXAMPLE)}))

    def test_desktop_publish_refuses_a_key_the_profile_does_not_name(self):
        raw = bytes(range(32))
        facts = ({"source_head": "x", "version_code": 5, "version": "v"}, raw, 10, "0" * 64)
        with patch.dict(release.ARTIFACT_FACTS, {"linux-x86_64": lambda artifact: facts}), \
                patch.object(release, "check_source"), patch.object(release, "private_key_path", lambda d: Path("k")), \
                patch.object(release, "public_from_private", lambda path, runner=None: raw):
            with self.assertRaisesRegex(release.Refused, "not the deployment profile's"):
                release.publish("linux-x86_64", Path("a"), None, expected_key_id="0" * 16)
            with self.assertRaisesRegex(release.Refused, "not the deployment profile's"):
                release.publish("linux-x86_64", Path("a"), None, expected_key_id="")


if __name__ == "__main__":
    unittest.main()
