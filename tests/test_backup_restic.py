"""Spec #22 rev7 preflight and restore paths against real findmnt and real restic (opt-in).

ANJ_DOCKER_TESTS=1: every container is restic's one-off with --rm, --memory 2g, --pids-limit 256,
--network none and --cap-drop ALL (no privileged, no systemd). Scratch repositories only; the real
DOS_BACKUP drive and /mnt/anj-backup are never touched.
"""

import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock

from deploy import backup as B

ENABLED = os.environ.get("ANJ_DOCKER_TESTS") == "1"


class ShareStub(B.Runner):
    """Real commands, except findmnt for the scratch share, which reports a virtiofs mount."""

    def __init__(self, share, tag, options="rw,relatime"):
        self.share, self.tag, self.options = str(share), tag, options
        self.containers = []

    def run(self, argv, **kwargs):
        if argv[0] == "findmnt" and argv[3] == self.share:
            entry = {"target": self.share, "source": self.tag, "fstype": "virtiofs", "options": self.options}
            return subprocess.CompletedProcess(argv, 0, json.dumps({"filesystems": [entry]}).encode(), b"")
        if argv[:2] == ["docker", "run"]:
            self.containers.append(argv)
        return super().run(argv, **kwargs)


@unittest.skipUnless(ENABLED, "set ANJ_DOCKER_TESTS=1 (runs bounded restic containers)")
class RealRestic(unittest.TestCase):
    def setUp(self):
        base = Path.home() / ".cache" / "anj-cloud-f15c"
        base.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.temp = Path(tempfile.mkdtemp(prefix="restic-test-", dir=base))
        self.state = self.temp / "state"
        self.state.mkdir(mode=0o700)
        self.share = self.temp / "share"
        self.share.mkdir(mode=0o700)
        self.runner = ShareStub(self.share, "anj-qual-scratch")
        self.root = mock.patch.object(B.Backup, "root_device", staticmethod(lambda: -1))
        self.root.start()

    def tearDown(self):
        self.root.stop()
        # restic writes as container root (the host user under rootless Docker): removable here.
        shutil.rmtree(self.temp, ignore_errors=True)
        shutil.rmtree(B.CACHE_HOME / "anj-cloud-review-restic", ignore_errors=True)
        leftovers = subprocess.run(["docker", "ps", "-aq", "--filter", "label=anj-cloud.backup=anj-cloud-review-restic"],
                                   capture_output=True, text=True).stdout.split()
        self.assertEqual(leftovers, [])

    def backup(self, state=None, runner=None):
        return B.Backup("anj-cloud-review-restic", state or self.state, runner=runner or self.runner,
                        out=io.StringIO())

    def test_real_tmpfs_mount_is_refused_as_not_virtiofs(self):
        backup = B.Backup("anj-cloud-review-restic", self.state, runner=B.Runner(), out=io.StringIO())
        with mock.patch.object(B.Backup, "root_device", staticmethod(lambda: -1)):
            with self.assertRaises(B.Preflight) as raised:
                backup.check_share({"mount": "/dev/shm", "tag": "anj-qual-scratch"}, repository=False)
        self.assertEqual(raised.exception.reason, "not-virtiofs")
        with self.assertRaises(B.Preflight) as raised:
            backup.check_share({"mount": str(self.share), "tag": "anj-qual-scratch"}, repository=False)
        self.assertEqual(raised.exception.reason, "share-absent")  # a plain directory, not a mount

    def test_init_wrong_repository_adopt_and_read_only_no_lock(self):
        backup = self.backup()
        result = backup.init(mount=str(self.share), tag="anj-qual-scratch", alert_command=["true"])
        self.assertEqual(result["state"], "initialized")
        self.assertEqual(sorted(p.name for p in self.share.iterdir()), ["restic"])
        recorded = result["repository_id"]
        for argv in self.runner.containers:
            self.assertIn("--rm", argv)
            self.assertEqual(argv[argv.index("--memory") + 1], "2g")
            self.assertEqual(argv[argv.index("--pids-limit") + 1], "256")
            self.assertNotIn("--privileged", argv)
            self.assertEqual(argv[argv.index("--network") + 1], "none")
        # A snapshot to read back later (a tiny scratch source).
        source = self.temp / "source"
        source.mkdir()
        (source / "f").write_text("scratch")
        backup.restic(["backup", "--host", "anj-cloud-review-restic", "/backup"], mounts=[(str(source), "/backup", "ro")])
        # Wrong repository: swap in another real repository at the recorded path.
        other_state = self.temp / "other-state"
        other_state.mkdir(mode=0o700)
        other_share = self.temp / "other-share"
        other_share.mkdir(mode=0o700)
        (other_state / "secrets").mkdir(mode=0o700)
        B.atomic_write(other_state / "secrets" / "restic-password", backup.password_file.read_bytes())
        other = self.backup(other_state, ShareStub(other_share, "anj-qual-scratch"))
        other.init(mount=str(other_share), tag="anj-qual-scratch", alert_command=["true"])  # same password
        stranger_state = self.temp / "stranger-state"
        stranger_state.mkdir(mode=0o700)
        stranger_share = self.temp / "stranger-share"
        stranger_share.mkdir(mode=0o700)
        self.backup(stranger_state, ShareStub(stranger_share, "anj-qual-scratch")).init(
            mount=str(stranger_share), tag="anj-qual-scratch", alert_command=["true"])  # its own password
        os.rename(self.share / "restic", self.temp / "kept")
        for imposter in (other_share, stranger_share):
            os.rename(imposter / "restic", self.share / "restic")
            with self.assertRaises(B.Preflight) as raised:
                backup._run_locked("nightly", "r", backup.now(), 60, None)
            self.assertEqual(raised.exception.reason, "wrong-repository")
            os.rename(self.share / "restic", imposter / "restic")
        os.rename(self.temp / "kept", self.share / "restic")
        # Adopt on a rebuilt VM: the escrowed password opens the repository; the ID is read, not written.
        adopted_state = self.temp / "adopted-state"
        adopted_state.mkdir(mode=0o700)
        reader = ShareStub(self.share, "anj-qual-scratch", options="ro,relatime")
        adopted = self.backup(adopted_state, reader).init(mount=str(self.share), tag="anj-qual-scratch",
                                                          adopt=True, password_file=str(backup.password_file),
                                                          alert_command=["true"])
        self.assertEqual((adopted["state"], adopted["repository_id"]), ("adopted", recorded))
        # Read-only share (the drill): restic reads with --no-lock from a :ro repository mount.
        readonly = self.backup(adopted_state, reader)
        rows = json.loads(readonly.restic(["snapshots", "--json"], read_only=True).stdout)
        self.assertEqual(len(rows), 1)
        self.assertTrue(any(value.endswith(":/repo:ro") for value in reader.containers[-1]))
        self.assertIn("--no-lock", reader.containers[-1])


if __name__ == "__main__":
    unittest.main()
