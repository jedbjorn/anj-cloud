#!/usr/bin/env python3
"""In-app self-update in the Linux manager (spec #37 U-core, U-linux): Ed25519 verification
against the key built into the ACTIVE release, `apply-update` refusals, the wait for the app to
quit and the relaunch. Real files, locks and openssl; throwaway keys only."""
import base64
import fcntl
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

import linux_install as manager
import test_linux_install

VECTOR = json.loads((Path(__file__).resolve().parent / "testdata/release_signature_vector.json").read_text())


class Ed25519Tests(unittest.TestCase):
    # RFC 8032 section 7.1, tests 1-3.
    RFC = [("d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a", "",
            "e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b"),
           ("3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c", "72",
            "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00"),
           ("fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025", "af82",
            "6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a")]

    def test_rfc_8032_vectors_verify_and_any_change_is_refused(self):
        for public, message, signature in self.RFC:
            public, message, signature = bytes.fromhex(public), bytes.fromhex(message), bytes.fromhex(signature)
            self.assertTrue(manager.ed25519_verify(public, message, signature))
            self.assertFalse(manager.ed25519_verify(public, message + b"x", signature))
            self.assertFalse(manager.ed25519_verify(public, message, signature[:63] + bytes([signature[63] ^ 1])))
            self.assertFalse(manager.ed25519_verify(bytes([public[0] ^ 1]) + public[1:], message, signature))
            self.assertFalse(manager.ed25519_verify(public, message, signature[:32] + (2 ** 253).to_bytes(32, "little")))
            self.assertFalse(manager.ed25519_verify(public[:31], message, signature))

    def test_a_low_order_key_verifies_nothing(self):
        """Review L1: with the identity as the key, R = B and S = 1 'verify' in a bare RFC 8032
        check; a usable key is required, so it does not."""
        base = (4 * pow(5, manager._P - 2, manager._P) % manager._P).to_bytes(32, "little")
        forged = base + (1).to_bytes(32, "little")
        for key in (b"\x01" + bytes(31), bytes(32)):
            self.assertFalse(manager.usable_public_key(key))
            self.assertFalse(manager.ed25519_verify(key, b"any manifest", forged))

    def test_the_shared_vector_and_every_tampered_field(self):
        with tempfile.NamedTemporaryFile("w", suffix=".pub") as key_file:
            key_file.write(VECTOR["public_key_file"])
            key_file.flush()
            key = manager.release_key(key_file.name)
        manifest = VECTOR["manifest"]
        self.assertEqual(VECTOR["key_id"], key[1])
        self.assertEqual(VECTOR["signed_message"].encode(), manager.signed_message(manifest))
        self.assertEqual(manifest, manager.verified_update(manifest, key, 611))
        tampered = {"version": "2026.11.05.613", "version_code": 613, "size": 1, "sha256": "6f" * 32,
                    "target": "macos-arm64", "key_id": "0" * 16, "signature": "A" * 86 + "=="}
        for name, value in tampered.items():
            with self.subTest(field=name), self.assertRaises(manager.Refused):
                manager.verified_update({**manifest, name: value}, key, 1)
        for installed in (612, 700):
            with self.subTest(installed=installed), self.assertRaisesRegex(manager.Refused, "not newer"):
                manager.verified_update(manifest, key, installed)
        with self.assertRaisesRegex(manager.Refused, "unexpected fields"):
            manager.verified_update({**manifest, "path": "/x"}, key, 1)

    def test_key_files(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "key.pub"
            path.write_text("# no key yet\n")
            self.assertIsNone(manager.release_key(path))
            self.assertIsNone(manager.release_key(Path(directory) / "absent.pub"))
            for text in ("ed25519 AAAA\n", "ed25519 !!\n", "rsa " + "A" * 44 + "\n", VECTOR["public_key_file"] * 2,
                         # Low-order keys (review L1): 32 zero bytes (order 4) and the identity.
                         "ed25519 " + base64.b64encode(bytes(32)).decode() + "\n",
                         "ed25519 " + base64.b64encode(b"\x01" + bytes(31)).decode() + "\n"):
                path.write_text(text)
                with self.subTest(text=text), self.assertRaises(manager.Refused):
                    manager.release_key(path)


class ApplyUpdate(unittest.TestCase):
    # test_linux_install.ManagerFiles' private installation fixture, without inheriting its tests.
    archive = test_linux_install.ManagerFiles.archive
    install = test_linux_install.ManagerFiles.install
    tearDown = test_linux_install.ManagerFiles.tearDown

    def setUp(self):
        test_linux_install.ManagerFiles.setUp(self)
        keys = self.home / "keys"
        keys.mkdir(mode=0o700)
        self.private = keys / "release.pem"
        subprocess.run(["openssl", "genpkey", "-algorithm", "ed25519", "-out", str(self.private)], check=True, capture_output=True)
        der = subprocess.run(["openssl", "pkey", "-in", str(self.private), "-pubout", "-outform", "DER"], check=True, capture_output=True).stdout
        self.raw = der[-32:]
        self.key_text = "# test key\ned25519 " + base64.b64encode(self.raw).decode() + "\n"
        self.key_id = hashlib.sha256(self.raw).hexdigest()[:16]
        self.state = self.install(*self.release(10))
        (Path(self.state["profile"]) / "sentinel").write_bytes(b"paired data\n")
        self.updates = Path(self.state["profile"]) / manager.UPDATES_DIRECTORY
        self.updates.mkdir(mode=0o700)

    def release(self, code, key_text=None, receipt_code=None):
        key_text = self.key_text if key_text is None else key_text

        def mutate(root):
            path = root / manager.RELEASE_KEY_PAYLOAD
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(key_text)
            path.chmod(0o600)

        def change(receipt):
            receipt["version_code"] = code if receipt_code is None else receipt_code
            receipt["version"] = f"2026.11.05.{code}"
            receipt["files_sha256"][manager.RELEASE_KEY_PAYLOAD] = hashlib.sha256(key_text.encode()).hexdigest()
        return self.archive(mutate=mutate, receipt_change=change)

    def sign(self, manifest, private=None):
        message = self.home / "message"
        signature = self.home / "signature"
        message.write_bytes(manager.signed_message(manifest))
        subprocess.run(["openssl", "pkeyutl", "-sign", "-inkey", str(private or self.private), "-rawin", "-in", str(message),
                        "-out", str(signature)], check=True, capture_output=True)
        return base64.b64encode(signature.read_bytes()).decode()

    def download(self, code=11, *, archive=None, change=None, private=None):
        """An update as the app leaves it in the profile's updates/ folder."""
        if archive is None:
            archive, _digest = self.release(code)
        data = archive.read_bytes()
        target = self.updates / f"{code}.tar.gz"
        target.write_bytes(data)
        manifest = {"target": "linux-x86_64", "version": f"2026.11.05.{code}", "version_code": code, "size": len(data),
                    "sha256": hashlib.sha256(data).hexdigest(), "key_id": self.key_id}
        if change:
            change(manifest)
        manifest.setdefault("signature", self.sign(manifest, private))
        path = self.updates / f"{code}.json"
        path.write_text(json.dumps(manifest))
        return target, path

    def apply(self, archive, manifest, **kwargs):
        kwargs.setdefault("relaunch", False)
        kwargs.setdefault("wait", 0)
        kwargs.setdefault("grace", 0.5)
        return manager.apply_update(manager.Installation(), archive, manifest, self.updates / manager.UPDATE_RESULT, **kwargs)

    def test_a_signed_newer_release_is_installed_and_the_download_discarded(self):
        archive, manifest = self.download(11)
        checked = self.apply(archive, manifest, check=True)
        self.assertEqual((True, 11), (checked["ok"], checked["version_code"]))
        self.assertTrue(archive.exists())
        outcome = self.apply(archive, manifest)
        self.assertTrue(outcome["ok"], outcome)
        active = manager.read_json(self.installation.state_file)
        self.assertEqual(active["source"], outcome["source"])
        self.assertEqual(active["previous"], self.state["release"])
        self.assertEqual(active["profile"], self.state["profile"])
        self.assertEqual(11, manager.read_json(self.installation.releases / active["release"] / "bundle-receipt.json")["version_code"])
        self.assertEqual(outcome, json.loads((self.updates / manager.UPDATE_RESULT).read_text()))
        self.assertEqual(0o600, (self.updates / manager.UPDATE_RESULT).stat().st_mode & 0o777)
        self.assertEqual([manager.UPDATE_RESULT], sorted(path.name for path in self.updates.iterdir()))
        self.assertEqual((Path(self.state["profile"]) / "sentinel").read_bytes(), b"paired data\n")
        events = [json.loads(line)["event"] for line in (Path(self.installation.layout["state"]) / "manager.jsonl").read_text().splitlines()]
        self.assertIn("update_applied", events)

    def test_every_tampered_or_stale_update_is_refused_and_nothing_changes(self):
        other = self.home / "keys" / "other.pem"
        subprocess.run(["openssl", "genpkey", "-algorithm", "ed25519", "-out", str(other)], check=True, capture_output=True)
        before = manager.read_json(self.installation.state_file)

        def flip(path):
            data = bytearray(path.read_bytes())
            data[len(data) // 2] ^= 1
            path.write_bytes(bytes(data))

        cases = {
            "signature does not verify": dict(change=lambda m: m.update(signature=self.sign({**m, "version_code": 99}))),
            "different key": dict(private=other, change=lambda m: m.update(key_id=hashlib.sha256(b"x").hexdigest()[:16])),
            "other key, same id": dict(private=other),
            "another platform": dict(change=lambda m: m.update(target="macos-arm64")),
            "not newer (equal)": dict(code=10),
            "not newer (downgrade)": dict(code=9),
            "receipt does not match": dict(archive=self.release(12, receipt_code=13)[0], code=12),
            "size and SHA-256 (size)": dict(change=lambda m: m.update(size=m["size"] + 1)),
            "size and SHA-256 (hash)": dict(change=lambda m: m.update(sha256="0" * 64)),
        }
        reasons = {"signature does not verify": "signature does not verify", "different key": "different key",
                   "other key, same id": "signature does not verify", "another platform": "another platform",
                   "not newer (equal)": "not newer", "not newer (downgrade)": "not newer",
                   "receipt does not match": "receipt does not match", "size and SHA-256 (size)": "size and SHA-256",
                   "size and SHA-256 (hash)": "size and SHA-256"}
        for name, options in cases.items():
            with self.subTest(case=name):
                archive, manifest = self.download(options.pop("code", 11), **options)
                outcome = self.apply(archive, manifest)
                self.assertFalse(outcome["ok"])
                self.assertIn(reasons[name], outcome["message"])
                self.assertEqual(before, manager.read_json(self.installation.state_file))
                self.assertFalse(archive.exists())
                self.assertFalse(manifest.exists())
        # A package changed after the manifest was signed (the bytes, not the record).
        archive, manifest = self.download(11)
        flip(archive)
        outcome = self.apply(archive, manifest)
        self.assertIn("size and SHA-256", outcome["message"])
        self.assertEqual(before, manager.read_json(self.installation.state_file))

    def test_files_outside_the_profile_updates_folder_are_refused(self):
        archive, manifest = self.download(11)
        outside = self.home / "outside.tar.gz"
        outside.write_bytes(archive.read_bytes())
        before = manager.read_json(self.installation.state_file)
        for arguments in ((outside, manifest), (archive, self.home / "m.json"), (Path("relative.tar.gz"), manifest)):
            with self.subTest(arguments=arguments):
                with self.assertRaisesRegex(manager.Refused, "updates folder"):
                    manager.apply_update(manager.Installation(), *arguments, check=True)
                outcome = manager.apply_update(manager.Installation(), *arguments, relaunch=False)
                self.assertIn("updates folder", outcome["message"])
        outcome = manager.apply_update(manager.Installation(), archive, manifest, self.home / "result.json", relaunch=False)
        self.assertIn("updates folder", outcome["message"])
        self.assertFalse((self.home / "result.json").exists())
        self.assertTrue(archive.exists() and outside.exists())
        self.assertEqual(before, manager.read_json(self.installation.state_file))

    def test_a_release_without_a_built_in_key_installs_no_update(self):
        self.install(*self.release(20, key_text="# none\n"))
        archive, manifest = self.download(21)
        outcome = self.apply(archive, manifest)
        self.assertIn("no built-in release key", outcome["message"])

    def test_waits_for_the_app_to_quit_then_installs(self):
        lock = os.open(Path(self.state["profile"]) / ".instance.lock", os.O_RDWR)
        fcntl.flock(lock, fcntl.LOCK_EX)
        timer = threading.Timer(1.0, os.close, (lock,))
        timer.start()
        started = time.monotonic()
        try:
            archive, manifest = self.download(11)
            outcome = self.apply(archive, manifest, wait=30)
        finally:
            timer.join()
        self.assertTrue(outcome["ok"], outcome)
        self.assertGreaterEqual(time.monotonic() - started, 0.9)

    def test_any_failure_is_answered_and_the_app_restarted(self):
        """Review M1: a missing download, a full disk or a broken installation still writes the
        outcome (where the result path is known) and restarts the app; nothing is installed."""
        before = manager.read_json(self.installation.state_file)
        missing_archive, missing_manifest = self.download(11)
        missing_archive.unlink()
        cases = {"missing archive": (missing_archive, missing_manifest, None, "FileNotFoundError")}
        full_archive, full_manifest = self.download(12)
        cases["disk full"] = (full_archive, full_manifest,
                              patch.object(manager, "extract", side_effect=OSError(28, "No space left on device")), "No space left")
        for name, (archive, manifest, failure, reason) in cases.items():
            with self.subTest(case=name), patch.object(manager, "relaunch_app", return_value=True) as relaunch:
                if failure:
                    with failure:
                        outcome = self.apply(archive, manifest, relaunch=True)
                else:
                    outcome = self.apply(archive, manifest, relaunch=True)
                self.assertFalse(outcome["ok"])
                self.assertIn(reason, outcome["message"])
                self.assertTrue(outcome["relaunched"])
                relaunch.assert_called_once()
                written = json.loads((self.updates / manager.UPDATE_RESULT).read_text())
                self.assertEqual((False, outcome["message"]), (written["ok"], written["message"]))
                self.assertFalse(archive.exists() or manifest.exists())
                self.assertEqual(before, manager.read_json(self.installation.state_file))
        # Before anything is known: an unreadable activation record. No result path can be
        # trusted, but the app (gone: its pid no longer exists) is still started again.
        archive, manifest = self.download(13)
        self.installation.state_file.chmod(0o666)
        try:
            with patch.object(manager, "relaunch_app", return_value=True) as relaunch:
                outcome = self.apply(archive, manifest, relaunch=True, app_pid=2 ** 22 + 12345)
        finally:
            self.installation.state_file.chmod(0o600)
        self.assertFalse(outcome["ok"])
        relaunch.assert_called_once()

    def test_a_second_concurrent_apply_changes_nothing_and_writes_nothing(self):
        """Review L3: the loser never overwrites the winner's result."""
        archive, manifest = self.download(11)
        winner = {"ok": True, "version": "2026.11.05.11"}
        (self.updates / manager.UPDATE_RESULT).write_text(json.dumps(winner))
        self.installation.load()
        held = manager._apply_lock(self.installation)
        try:
            with patch.object(manager, "relaunch_app") as relaunch:
                outcome = self.apply(archive, manifest, relaunch=True)
            relaunch.assert_not_called()
        finally:
            os.close(held)
        self.assertTrue(outcome["concurrent"])
        self.assertEqual(winner, json.loads((self.updates / manager.UPDATE_RESULT).read_text()))
        self.assertTrue(archive.exists() and manifest.exists())

    def test_an_app_quitting_after_the_deadline_is_restarted_on_its_release(self):
        """Review L4: not installed after the deadline, but restarted once it does quit."""
        lock = os.open(Path(self.state["profile"]) / ".instance.lock", os.O_RDWR)
        fcntl.flock(lock, fcntl.LOCK_EX)
        timer = threading.Timer(1.0, os.close, (lock,))
        timer.start()
        try:
            archive, manifest = self.download(11)
            with patch.object(manager, "relaunch_app", return_value=True) as relaunch:
                outcome = self.apply(archive, manifest, wait=0.3, grace=10, relaunch=True)
        finally:
            timer.join()
        self.assertIn("did not quit", outcome["message"])
        self.assertTrue(outcome["relaunched"])
        relaunch.assert_called_once()
        self.assertEqual(self.state["release"], manager.read_json(self.installation.state_file)["release"])

    def test_an_app_that_never_quits_keeps_its_release_and_is_not_relaunched(self):
        lock = os.open(Path(self.state["profile"]) / ".instance.lock", os.O_RDWR)
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            archive, manifest = self.download(11)
            with patch.object(manager, "relaunch_app") as relaunch:
                outcome = self.apply(archive, manifest, wait=0.5, relaunch=True)
            relaunch.assert_not_called()
        finally:
            os.close(lock)
        self.assertIn("did not quit", outcome["message"])
        self.assertEqual(self.state["release"], manager.read_json(self.installation.state_file)["release"])

    def test_the_app_is_relaunched_through_the_stable_command_after_success_or_refusal(self):
        for code in (11, 10):
            archive, manifest = self.download(code)
            with self.subTest(code=code), patch.object(manager.subprocess, "run",
                                                      return_value=subprocess.CompletedProcess([], 0, b"", b"")) as run:
                outcome = self.apply(archive, manifest, relaunch=True)
            self.assertEqual(code == 11, outcome["ok"])
            self.assertTrue(outcome["relaunched"])
            argv = run.call_args.args[0]
            self.assertEqual([self.installation.layout["command"], "run", "--detach"], argv)
            self.assertTrue(run.call_args.kwargs["start_new_session"])

    def test_cli_apply_update_reports_a_refusal(self):
        archive, manifest = self.download(10)
        done = subprocess.run([self.installation.layout["command"], "apply-update", str(archive), "--manifest", str(manifest),
                               "--result", str(self.updates / manager.UPDATE_RESULT), "--app-pid", str(os.getpid()),
                               "--no-relaunch"], capture_output=True, text=True)
        self.assertEqual(1, done.returncode)
        self.assertIn("not newer", json.loads(done.stdout)["message"])
        self.assertIn("not newer", json.loads((self.updates / manager.UPDATE_RESULT).read_text())["message"])


if __name__ == "__main__":
    unittest.main()
