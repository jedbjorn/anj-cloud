"""Spec #22 rev7 backup tooling: refusals, run sequence, hard cap, alerts, markers, units and the
drill orchestration (no Docker, no VM needed).

A fake command runner stands in for docker, restic and findmnt; it keeps the order of
maintenance, capture and restic calls so the window's guarantees can be asserted. The live
proof against a synthetic stack is deploy/backup_qualify.py.
"""

import contextlib
from datetime import datetime, timedelta, timezone
import io
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

from deploy import backup as B

REPO_ID = "a" * 64
TAG = "anj-qual-scratch"


class Clock:
    def __init__(self):
        self.now = datetime(2026, 11, 3, 3, 30, tzinfo=timezone.utc).timestamp()

    def __call__(self):
        return self.now

    def advance(self, seconds):
        self.now += seconds


class Result:
    def __init__(self, stdout=b"", returncode=0, stderr=b""):
        self.stdout, self.returncode, self.stderr = stdout, returncode, stderr


class FakeProcess:
    def __init__(self, runner, hang):
        self.runner, self.hang, self.returncode = runner, hang, None
        self.stopped = False
        self.killed = False

    def kill(self):
        self.killed = True

    def communicate(self, timeout=None):
        if self.hang and self.runner.stop_hangs and not self.killed:
            self.runner.clock.advance(timeout or 0)
            raise subprocess.TimeoutExpired("restic", timeout)
        if self.killed:
            self.returncode = -9
            return b"", b""
        if self.hang and not self.stopped:
            self.runner.clock.advance(timeout or 0)
            raise subprocess.TimeoutExpired("restic", timeout)
        self.returncode = 1 if self.stopped else self.runner.restic_exit
        summary = {"message_type": "summary", "snapshot_id": "b" * 64, "data_added": 1234,
                   "data_added_packed": 1000, "total_bytes_processed": 99999, "total_files_processed": 7}
        return (json.dumps(summary).encode() + b"\n" if not self.stopped else b""), b""


class FakeRunner:
    """docker/restic/findmnt/systemctl stand-ins that log the calls the backup makes."""

    def __init__(self, clock, drive):
        self.clock = clock
        self.drive = drive
        self.calls = []
        self.events = []
        self.maintenance = False
        self.mounts = [{"target": str(drive), "source": TAG, "fstype": "virtiofs", "options": "rw,relatime"}]
        self.repository_id = REPO_ID
        self.fail = set()
        self.hang = False
        self.restic_exit = 0
        self.services = {"db": "running", "nextcloud": "running", "access": "running", "redis": "running",
                         "cron": "running", "access-tls": "exited"}
        self.volumes = []
        self.processes = []
        self.marker_during_window = None
        self.marker_path = None
        self.stop_hangs = False
        self.hang_housekeeping = False
        self.restore_marker = None
        self.marker_seen = []
        self.du_bytes = 100 * 1024
        self.password_seen = []
        self.removed_volumes = []
        self.created_volumes = []

    def sleep(self, seconds):
        self.clock.advance(seconds)

    def pipe(self, producer, consumer, *, timeout=300):
        self.calls.append(["PIPE", producer, consumer])
        return True

    def popen(self, argv):
        self.calls.append(argv)
        command = argv[argv.index(B.RESTIC_IMAGE) + 1]
        if command != "backup":
            self.events.append("restic " + command)
            process = FakeProcess(self, self.hang_housekeeping)
            self.processes.append(process)
            return process
        self.events.append("restic-backup")
        process = FakeProcess(self, self.hang)
        self.processes.append(process)
        return process

    def run(self, argv, *, data=None, timeout=600, stdout=None, check=True):
        self.calls.append(argv)
        result = self.dispatch(argv, data, stdout)
        if check and result.returncode:
            raise B.CommandFailed(argv, result.returncode, result.stderr)
        return result

    def dispatch(self, argv, data, stdout):
        if argv[0] == "findmnt":
            return Result(json.dumps({"filesystems": self.mounts}).encode(), 0 if self.mounts else 1)
        if argv[0] == "systemctl" or argv[0] == "/alert":
            self.events.append(" ".join(argv[:3]))
            return Result()
        if argv[:2] == ["docker", "kill"]:
            self.events.append("docker-kill")
            for process in self.processes:
                process.killed = True
            return Result()
        if argv[:2] == ["docker", "stop"] and self.stop_hangs:
            self.events.append("docker-stop")
            return Result()
        if argv[:2] == ["docker", "stop"] and any("restore-db" in a for a in argv):
            return Result()
        if argv[:2] == ["docker", "stop"]:
            self.events.append("docker-stop")
            for process in self.processes:
                process.stopped = True
            return Result()
        if argv[:2] == ["docker", "ps"]:
            project = argv[argv.index("--filter") + 1].split("=", 2)[2]
            lines = [json.dumps({"ID": f"{project}-{name}", "State": state,
                                 "Labels": f"com.docker.compose.project={project},com.docker.compose.service={name}"})
                     for name, state in self.services.items()] if project.endswith(("prod", "-bk")) else []
            return Result("\n".join(lines).encode())
        if argv[:3] == ["docker", "volume", "ls"]:
            return Result("\n".join(self.volumes).encode())
        if argv[:3] == ["docker", "volume", "rm"]:
            self.removed_volumes.append(argv[-1])
            return Result()
        if argv[:3] == ["docker", "volume", "create"]:
            self.created_volumes.append(argv[-1])
            return Result()
        if argv[:2] == ["docker", "rm"]:
            self.events.append("docker-rm")
            return Result()
        if argv[:3] == ["docker", "image", "inspect"]:
            return Result(returncode=1)
        if argv[:2] == ["docker", "exec"] and "restore-db" in " ".join(argv):
            if "pg_restore" in argv:
                self.events.append("pg_restore")
            if "ON_ERROR_STOP=1" in argv:
                self.events.append("roles " + (data or b"").decode().strip())
            return Result(b"5\n" if "count(*)" in argv[-1] else b"")
        if argv[:2] == ["docker", "run"] and B.RESTIC_IMAGE not in argv:
            self.events.append("run " + argv[argv.index("--entrypoint") + 1] if "--entrypoint" in argv else "run detached")
            return Result(b"{}")
        if argv[:2] == ["docker", "inspect"]:
            return Result(json.dumps([{"Config": {"Env": ["POSTGRES_USER=anj", "POSTGRES_DB=anj"]}}]).encode())
        if argv[:2] == ["docker", "exec"]:
            return self.exec(argv, data, stdout)
        if argv[:2] == ["docker", "run"]:
            image = argv.index(B.RESTIC_IMAGE)
            args = argv[image + 1:]
            entrypoint = argv[argv.index("--entrypoint") + 1] if "--entrypoint" in argv else None
            if entrypoint == "du":
                return Result(f"{self.du_bytes // 1024}\t/v\n".encode())
            if entrypoint == "sh":
                self.events.append("helper " + args[1][:12])
                return Result(b"c" * 64 if "sha256sum" in args[1] else b"")
            password = next(v.split(":")[0] for v in argv if v.endswith(":/run/restic/password:ro"))
            self.password_seen.append(Path(password).exists())
            if args[0] == "snapshots":
                return Result(json.dumps([{"id": "e" * 64}]).encode())
            if args[0] == "restore":
                self.populate(args[1].split(":/backup/")[1], next(v for v in argv if v.endswith(":/target:rw")))
            self.events.append("restic " + args[0])
            if "restic " + args[0] in self.fail:
                return Result(returncode=1, stderr=b"Fatal: something")
            if args[:2] == ["cat", "config"]:
                if self.repository_id is None:
                    return Result(returncode=1, stderr=b"Fatal: wrong password or no key found")
                return Result(json.dumps({"id": self.repository_id, "version": 2}).encode())
            if args[0] == "init":
                (Path(argv[argv.index("--volume") + 1].split(":")[0]) / "config").write_text("x")
            return Result(b"{}")
        raise AssertionError(f"unexpected command {argv}")

    def populate(self, subfolder, mount):
        self.events.append("restore " + subfolder)
        if self.restore_marker is not None:
            self.marker_seen.append(self.restore_marker.exists())
        host = mount.split(":")[0]
        if not host.startswith("/"):
            return  # a Docker volume
        root = Path(host)
        if subfolder == "staging":
            (root / "manifest.json").write_text(json.dumps({
                "version": B.MANIFEST_VERSION, "release": "0123456789ab", "host": "gateway.example.com",
                "table_prefix": "oc_", "datadir": "/var/www/html/data", "filecache_rows": 5,
                "sentinels": {"config_sha256": "c" * 64, "user_file": None}, "captured_at": "2026-11-03T03:31:00Z",
                "registry": {"devices": 1, "digest": "d", "integrity": True}}))
            (root / "database.dump").write_bytes(b"PGDMP")
            (root / "roles.sql").write_text('CREATE ROLE anj;\nALTER ROLE anj WITH SUPERUSER;\nCREATE ROLE "oc_admin";\n')
        if subfolder == "state":
            for directory in ("operator", "secrets", "release/0123456789ab"):
                (root / directory).mkdir(parents=True, mode=0o700, exist_ok=True)
            (root / "operator" / "issuer.crt").write_text("restored issuer")
            (root / "secrets" / "database").write_text("restored db")
            (root / "stack.json").write_text(json.dumps({"release": "0123456789ab" + "0" * 28,
                                                         "host": "gateway.example.com",
                                                         "image_repository": "anj-cloud-prod-access"}))
            (root / "release" / "0123456789ab" / "compose.json").write_text(json.dumps({"services": {
                "db": {"image": "postgres-image", "environment": {"POSTGRES_USER": "anj", "POSTGRES_DB": "anj"}},
                "nextcloud": {"image": "nextcloud-image"}}}))

    def exec(self, argv, data, stdout):
        command = argv[argv.index(next(a for a in argv if a.endswith(("-db", "-nextcloud", "-access")))) + 1:]
        joined = " ".join(command)
        for failure in self.fail:
            if failure in joined:
                self.events.append("failed " + failure)
                return Result(returncode=1)
        if command[:3] == ["php", "occ", "maintenance:mode"]:
            if len(command) == 4:
                self.maintenance = command[3] == "--on"
                self.events.append("maintenance " + command[3])
                if self.maintenance and self.marker_path and self.marker_path.exists():
                    self.marker_during_window = json.loads(self.marker_path.read_text())
                return Result()
            return Result(b"Maintenance mode is currently " + (b"enabled" if self.maintenance else b"disabled"))
        if command[:3] == ["php", "occ", "config:system:get"]:
            return Result({"dbtableprefix": b"oc_", "datadirectory": b"/var/www/html/data"}[command[3]])
        if command[:3] == ["python", "-m", "access.health"]:
            return Result(b'{"status": "ready"}')
        if command[0] == "psql":
            return Result(b"5\n" if "count(*)" in command[-1] else b"")
        if command[0] == "sh":
            return Result(b"c" * 64)
        if command[0] == "pg_dumpall":
            self.events.append("pg_dumpall")
            stdout.write(b"CREATE ROLE anj;\n")
            return Result()
        if command[0] == "pg_dump":
            self.events.append("pg_dump")
            stdout.write(b"PGDMP synthetic")
            return Result()
        if command[:2] == ["python", "-c"]:
            mode = command[3]
            self.events.append("registry " + mode)
            return Result(b"{}" if mode == "clean" else json.dumps(
                {"integrity": True, "devices": 1, "device_leaves": 0, "files_added": 0, "digest": "d"}).encode())
        raise AssertionError(f"unexpected exec {command}")


class BackupTestCase(unittest.TestCase):
    def setUp(self):
        self.temp = Path(tempfile.mkdtemp(prefix="anj-backup-test-"))
        self.state = self.temp / "state"
        self.state.mkdir(mode=0o700)
        self.drive = self.temp / "drive"
        self.drive.mkdir()
        self.clock = Clock()
        self.runner = FakeRunner(self.clock, self.drive)
        self.root_device = mock.patch.object(B.Backup, "root_device", staticmethod(lambda: -1))
        self.root_device.start()
        self.backup = self.make()
        self.backup.init(mount=str(self.drive), tag=TAG, alert_command=["/alert"])
        self.backup.config["margin_bytes"] = 0
        self.backup.save_config()
        self.runner.marker_path = self.backup.marker_path
        self.runner.events.clear()

    def tearDown(self):
        self.root_device.stop()
        shutil.rmtree(self.temp, ignore_errors=True)

    def make(self, project="anj-cloud-review-bk"):
        return B.Backup(project, self.state, runner=self.runner, clock=self.clock, cache_home=self.temp / "cache",
                        out=io.StringIO(), tz=timezone.utc)

    def alerts(self):
        return [entry["key"] for entry in self.backup.status.get("alerts", [])]

    def seed(self):
        record = self.backup.run("seed", cap_seconds=3600)
        self.assertEqual(record["result"], "success", record)
        self.runner.events.clear()
        return record


class ProjectAndPathRefusals(BackupTestCase):
    def test_project_names(self):
        for name in ("anj-cloud-dev", "anj-cloud-dev-2", "other", "anj-cloud-"):
            with self.assertRaises(B.BackupError):
                B.validate_project(name, purpose="restore")
        with self.assertRaises(B.BackupError):
            B.validate_project("anj-cloud-staging", purpose="backup")
        self.assertEqual(B.validate_project("anj-cloud-restore", purpose="drill"), "anj-cloud-restore")
        with self.assertRaises(B.BackupError):
            B.validate_project("anj-cloud-prod", purpose="drill")

    def test_state_root_inside_a_worktree_is_refused(self):
        inside = Path(__file__).resolve().parent / "not-here"
        with self.assertRaisesRegex(B.BackupError, "outside every git worktree"):
            B.checked_directory(inside, "--state-root", must_exist=False)

    def test_state_root_symlink_and_loose_modes_are_refused(self):
        link = self.temp / "link"
        link.symlink_to(self.state)
        with self.assertRaisesRegex(B.BackupError, "symlink"):
            B.checked_directory(link, "--state-root")
        loose = self.temp / "loose"
        loose.mkdir(mode=0o755)
        loose.chmod(0o755)
        with self.assertRaisesRegex(B.BackupError, "looser"):
            B.checked_directory(loose, "--state-root")

    def test_review_projects_never_name_the_production_share(self):
        other = self.temp / "other-state"
        other.mkdir(mode=0o700)
        backup = B.Backup("anj-cloud-review-x", other, runner=self.runner, cache_home=self.temp / "c")
        with self.assertRaisesRegex(B.BackupError, "production backup share"):
            backup.init(mount=str(B.paths.BACKUP_MOUNT), tag=TAG)
        with self.assertRaisesRegex(B.BackupError, "production backup share"):
            backup.init(mount=str(self.drive), tag=B.paths.BACKUP_TAG)
        with self.assertRaisesRegex(B.BackupError, "explicit scratch"):
            backup.init()

    def test_production_init_accepts_only_the_anj_backup_share(self):
        with mock.patch.object(B, "DEFAULT_STATE_ROOT", self.state):
            backup = B.Backup(B.PROJECT, None, runner=self.runner, cache_home=self.temp / "c")
        with self.assertRaisesRegex(B.BackupError, "anj-backup virtiofs share"):
            backup.init(mount=str(self.drive), tag=TAG)
        with mock.patch.object(B, "DEFAULT_STATE_ROOT", self.state), mock.patch("sys.stderr", io.StringIO()):
            self.assertEqual(B.main(["init", "--mount", "/tmp/x"]), 1)

    def test_production_run_keeps_the_30_minute_cap_and_no_throttle(self):
        with mock.patch.object(B, "DEFAULT_STATE_ROOT", self.state):
            backup = B.Backup(B.PROJECT, None, runner=self.runner, cache_home=self.temp / "c")
        with self.assertRaisesRegex(B.BackupError, "30-minute"):
            backup.run("nightly", cap_seconds=60)
        with self.assertRaisesRegex(B.BackupError, "review-project"):
            backup.run("nightly", limit_upload=10)

    def test_init_records_repository_and_creates_only_its_directory(self):
        self.assertEqual(self.backup.target["repository_id"], REPO_ID)
        # Only restic/ inside the share (on the VM host the share is DOS_BACKUP/anj-cloud-prod/).
        self.assertEqual(sorted(p.name for p in self.drive.iterdir()), ["restic"])
        self.assertEqual((self.drive / "restic").stat().st_mode & 0o777, 0o700)
        self.assertEqual(self.backup.password_file.stat().st_mode & 0o777, 0o600)
        again = self.make().init(mount=str(self.drive), tag=TAG)
        self.assertEqual(again["state"], "exists")


class Restores(BackupTestCase):
    def restore(self, project, **options):
        options.setdefault("state_root", self.temp / "restored-state")
        options.setdefault("target", self.temp / "restore-target")
        return B.Restore(self.backup, project, options.pop("state_root"), options.pop("target"), **options)

    def test_refuses_production_while_its_volumes_exist(self):
        self.runner.volumes = ["anj-cloud-prod_nextcloud", "anj-cloud-dev_nextcloud"]
        with self.assertRaisesRegex(B.BackupError, "--replace-production --confirm anj-cloud-prod"):
            self.restore("anj-cloud-prod")
        with self.assertRaisesRegex(B.BackupError, "--confirm anj-cloud-prod"):
            self.restore("anj-cloud-prod", replace_production=True, confirm="anj-cloud-pr0d")
        self.restore("anj-cloud-prod", replace_production=True, confirm="anj-cloud-prod")

    def test_replace_flag_applies_only_to_production(self):
        with self.assertRaises(B.BackupError):
            self.restore("anj-cloud-review-rs", replace_production=True, confirm="anj-cloud-prod")

    def test_refuses_non_empty_target_dev_projects_and_existing_projects(self):
        target = self.temp / "full"
        target.mkdir(mode=0o700)
        (target / "x").write_text("x")
        with self.assertRaisesRegex(B.BackupError, "empty directory"):
            self.restore("anj-cloud-review-rs", target=target)
        with self.assertRaisesRegex(B.BackupError, "Development"):
            self.restore("anj-cloud-dev")
        self.runner.volumes = ["anj-cloud-review-rs_access"]
        with self.assertRaisesRegex(B.BackupError, "fresh project"):
            self.restore("anj-cloud-review-rs")

    def test_non_production_restore_needs_its_own_state_root(self):
        with self.assertRaisesRegex(B.BackupError, "its own --state-root"):
            self.restore("anj-cloud-review-rs", state_root=self.state)

    def test_missing_state_root_is_a_usage_error(self):
        with mock.patch("sys.stderr", io.StringIO()), self.assertRaises(SystemExit) as raised:
            B.main(["--project", "anj-cloud-review-bk", "--state-root", str(self.state), "restore",
                    "--target", str(self.temp / "t"), "--project", "anj-cloud-review-rs"])
        self.assertEqual(raised.exception.code, 2)

    def test_exclusive_lock_is_reported_as_its_reason(self):
        error = B.restic_error(B.CommandFailed(["docker", "run"], 1,
                                               b"unable to create lock in backend: repository is already locked exclusively"))
        self.assertIsInstance(error, B.RepositoryLocked)
        self.assertEqual(error.reason, "repository-locked")


class Preflights(BackupTestCase):
    def setUp(self):
        super().setUp()
        self.seed()

    def assert_refused(self, reason):
        record = self.backup.run("nightly")
        self.assertEqual((record["result"], record["reason"]), ("preflight-failed", reason))
        self.assertNotIn("maintenance --on", self.runner.events)
        self.assertFalse(self.backup.marker_path.exists())
        self.assertEqual(self.alerts(), ["backup-preflight"])

    def test_share_absent(self):
        """Decision #89 (2): production keeps serving; the run stops before maintenance and alerts once."""
        self.runner.mounts = []
        self.assert_refused("share-absent")
        self.assertFalse(any(call[:2] in (["docker", "stop"], ["docker", "rm"], ["pm2", "stop"])
                             for call in self.runner.calls))

    def test_autofs_alone_is_not_a_mount(self):
        self.runner.mounts = [dict(self.runner.mounts[0], fstype="autofs")]
        self.assert_refused("share-absent")

    def test_non_virtiofs_mount(self):
        self.runner.mounts[0]["fstype"] = "ext4"
        self.assert_refused("not-virtiofs")

    def test_wrong_tag(self):
        self.runner.mounts[0]["source"] = "something-else"
        self.assert_refused("wrong-tag")

    def test_read_only_share_refused_for_backups(self):
        self.runner.mounts[0]["options"] = "ro,relatime"
        self.assert_refused("share-read-only")

    def test_backups_never_probe_and_keep_their_lock(self):
        """SC-067's write probe is for read paths only: a backup's share check is unchanged."""
        self.seed()
        with mock.patch.object(B.Backup, "writable", side_effect=AssertionError("backup probed")):
            self.assertFalse(self.backup.check_share(self.backup.target))
            self.backup.run("nightly")
        backup = [call for call in self.runner.calls if B.RESTIC_IMAGE in call and "backup" in call]
        self.assertTrue(backup)
        for call in backup:
            self.assertNotIn("--no-lock", call)

    def test_write_probe_on_a_real_directory(self):
        directory = self.temp / "probe"
        directory.mkdir(mode=0o700)
        self.assertTrue(B.Backup.writable(directory))
        self.assertEqual(list(directory.iterdir()), [])
        if os.geteuid() != 0:  # root ignores the mode
            directory.chmod(0o500)
            try:
                self.assertFalse(B.Backup.writable(directory))
            finally:
                directory.chmod(0o700)
        self.assertFalse(B.Backup.writable(self.temp / "missing"))

    def test_read_paths_report_a_share_refusing_writes_as_read_only(self):
        with mock.patch.object(B.Backup, "writable", staticmethod(lambda directory: False)):
            self.assertTrue(self.backup.check_share(self.backup.target, writable=False, probe=True))
            self.assertTrue(self.backup.check_share(self.backup.target, repository=False, writable=False, probe=True))
        self.assertFalse(self.backup.check_share(self.backup.target, writable=False, probe=True))

    def test_only_an_explicit_probe_writes_to_the_share(self):
        """PR #90 review L2: a read path that asks for no probe (init --adopt) writes nothing."""
        with mock.patch.object(B.Backup, "writable", side_effect=AssertionError("probed")):
            self.assertFalse(self.backup.check_share(self.backup.target, writable=False))
            self.assertFalse(self.backup.check_share(self.backup.target, repository=False, writable=False))

    def test_probe_removal_survives_an_interruption_and_a_failed_removal_is_reported(self):
        """PR #90 review L3: once created, the probe is removed whatever happens; a removal that
        fails is reported on stderr and counts as not writable."""
        directory = self.temp / "probe-l3"
        directory.mkdir(mode=0o700)
        real_close = os.close

        def interrupted(descriptor):
            real_close(descriptor)
            raise KeyboardInterrupt  # e.g. a signal landing between open and unlink

        with mock.patch.object(B.os, "close", interrupted), self.assertRaises(KeyboardInterrupt):
            B.Backup.writable(directory)
        self.assertEqual(list(directory.iterdir()), [])
        with mock.patch.object(B.Path, "unlink", side_effect=PermissionError(13, "Permission denied")), \
                mock.patch("sys.stderr", io.StringIO()) as stderr:
            self.assertFalse(B.Backup.writable(directory))
        event = json.loads(stderr.getvalue())
        self.assertEqual((event["event"], event["error"]), ("write-probe-left", "Permission denied"))
        self.assertTrue(event["file"].startswith(".anj-write-probe-"))
        self.assertNotIn("/", event["file"])
        for left in directory.iterdir():
            left.unlink()

    def test_directory_on_the_vm_disk(self):
        with mock.patch.object(B.Backup, "root_device", staticmethod(lambda: os.stat(self.drive).st_dev)):
            self.assert_refused("share-absent")

    def test_wrong_repository(self):
        self.runner.repository_id = "f" * 64
        self.assert_refused("wrong-repository")

    def test_another_repository_that_rejects_our_password(self):
        self.runner.repository_id = None
        self.assert_refused("wrong-repository")

    def test_low_space(self):
        self.backup.config["margin_bytes"] = 10**18
        self.backup.save_config()
        self.assert_refused("low-space")

    def test_unhealthy_stack(self):
        self.runner.services["access"] = "exited"
        self.assert_refused("stack-unhealthy")

    def test_existing_maintenance_is_not_taken_over(self):
        self.runner.maintenance = True
        record = self.backup.run("nightly")
        self.assertEqual(record["reason"], "stack-unhealthy")
        self.assertTrue(self.runner.maintenance)


class Window(BackupTestCase):
    def test_nightly_waits_for_the_seed(self):
        record = self.backup.run("nightly")
        self.assertEqual(record["reason"], "not-seeded")
        self.assertEqual(self.alerts(), ["backup-failed"])

    def test_success_sequence(self):
        self.seed()
        record = self.backup.run("nightly")
        self.assertEqual(record["result"], "success")
        events = self.runner.events
        self.assertLess(events.index("restic cat"), events.index("maintenance --on"))
        self.assertLess(events.index("maintenance --on"), events.index("pg_dump"))
        self.assertLess(events.index("pg_dump"), events.index("restic-backup"))
        self.assertLess(events.index("pg_dumpall"), events.index("restic-backup"))
        self.assertLess(events.index("restic-backup"), events.index("maintenance --off"))
        self.assertLess(events.index("maintenance --off"), events.index("restic forget"))
        self.assertFalse(self.backup.marker_path.exists())
        self.assertFalse((self.backup.run_dir / "staging").exists())
        self.assertEqual(record["snapshot"], "b" * 64)
        self.assertEqual(self.alerts(), [])
        marker = self.runner.marker_during_window
        self.assertEqual(marker["deadline_epoch"] - int(self.clock.now - record["duration_s"]), 30 * 60)
        report = self.backup.report()
        self.assertEqual(report["last_success"]["snapshot"], "b" * 64)
        self.assertIn("snapshot_bytes", report["last_success"])

    def test_restic_runs_isolated_with_read_only_sources(self):
        self.seed()
        self.backup.run("nightly")
        argv = next(call for call in self.runner.calls if "backup" in call and "--json" in call)
        self.assertIn("--network", argv)
        self.assertEqual(argv[argv.index("--network") + 1], "none")
        self.assertIn(B.RESTIC_IMAGE, argv)
        for source in ("/backup/state:ro", "/backup/nextcloud:ro", "/backup/access:ro", "/backup/staging:ro"):
            self.assertTrue(any(value.endswith(source) for value in argv), source)
        self.assertIn("/backup/state/secrets/restic-password", argv)
        self.assertNotIn("--one-file-system", argv)
        self.assertIn("TMPDIR=/cache/tmp", argv)  # packs are staged on disk, not the small tmpfs
        self.assertEqual(argv[argv.index("--memory") + 1], "2g")
        self.assertIn("--pids-limit", argv)

    def test_failure_inside_the_window_clears_maintenance_and_marker(self):
        self.seed()
        self.runner.fail = {"pg_dump"}
        record = self.backup.run("nightly")
        self.assertEqual(record["result"], "failed")
        self.assertFalse(self.runner.maintenance)
        self.assertIn("maintenance --off", self.runner.events)
        self.assertFalse(self.backup.marker_path.exists())
        self.assertEqual(self.alerts(), ["backup-failed"])
        self.assertFalse(self.backup.status.get("needs_index_repair"))

    def test_hard_cap_stops_restic_and_next_run_adopts_uploaded_packs(self):
        self.seed()
        self.runner.hang = True
        record = self.backup.run("nightly")
        self.assertEqual(record["result"], "capped")
        self.assertIn("docker-stop", self.runner.events)
        self.assertLess(self.runner.events.index("docker-stop"), self.runner.events.index("maintenance --off"))
        self.assertFalse(self.runner.maintenance)
        self.assertFalse(self.backup.marker_path.exists())
        self.assertEqual(self.alerts(), ["backup-cap"])
        self.assertIsNotNone(record.get("maintenance_s"))
        self.assertTrue(self.backup.status["needs_index_repair"])
        self.runner.hang = False
        self.runner.events.clear()
        self.clock.advance(86400)
        record = self.backup.run("nightly")
        self.assertEqual(record["result"], "success")
        self.assertLess(self.runner.events.index("restic repair"), self.runner.events.index("maintenance --on"))
        self.assertFalse(self.backup.status["needs_index_repair"])

    def test_capture_that_outlasts_the_cap_is_capped(self):
        self.seed()
        original = self.runner.exec

        def slow(argv, data, stdout):
            if "pg_dump" in argv:
                self.clock.advance(31 * 60)
            return original(argv, data, stdout)

        self.runner.exec = slow
        record = self.backup.run("nightly")
        self.assertEqual(record["result"], "capped")
        self.assertFalse(self.runner.maintenance)
        self.assertNotIn("restic-backup", self.runner.events)

    def test_maintenance_off_failure_is_retried_then_alerted(self):
        self.seed()
        self.runner.fail = {"maintenance:mode --off"}
        self.backup.run("nightly")
        self.assertIn("backup-maintenance-stuck", self.alerts())

    def test_concurrent_run_is_refused(self):
        self.seed()
        with self.backup.lock():
            record = self.make().run("nightly")
        self.assertEqual(record["reason"], "busy")

    def test_a_run_during_a_release_switch_is_skipped_quietly(self):
        """PR #58 delta D3: prod.py redeploy holds the lock and wrote run/release-switch."""
        self.seed()
        before = list(self.alerts())
        with self.backup.lock(), contextlib.redirect_stderr(io.StringIO()) as err:
            (self.backup.run_dir / "release-switch").write_text(json.dumps({"pid": os.getpid()}))
            record = self.make().run("nightly")
        self.assertEqual((record["result"], record["reason"]), ("skipped", "release-switch"))
        self.assertIn("release switch", err.getvalue())
        self.assertEqual(before, self.alerts())                 # no backup-failed

    def test_hangup_and_ctrl_c_unwind_like_sigterm(self):
        """PR #58 delta D2: SIGHUP (a dropped session) and SIGINT run the finally paths."""
        root = Path(__file__).resolve().parent.parent
        for number in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
            with self.subTest(signal=number.name), tempfile.TemporaryDirectory() as directory:
                log = Path(directory) / "log"
                script = (f"import sys,time; sys.path.insert(0, {str(root)!r})\n"
                          "from deploy import backup\n"
                          "backup.install_signal_handlers()\n"
                          f"log = open({str(log)!r}, 'w', buffering=1)\n"
                          "try:\n"
                          "    log.write('maintenance on\\n')\n"
                          "    try:\n        time.sleep(30)\n"
                          "    finally:\n        log.write('maintenance off\\n')\n"
                          "except KeyboardInterrupt:\n    sys.exit(130)\n")
                child = subprocess.Popen([sys.executable, "-I", "-c", script])
                deadline = time.monotonic() + 10
                while "on" not in (log.read_text() if log.exists() else "") and time.monotonic() < deadline:
                    time.sleep(0.05)
                child.send_signal(number)
                self.assertEqual(130, child.wait(timeout=10))
                self.assertEqual("maintenance on\nmaintenance off\n", log.read_text())

    def test_crash_marker_is_recovered_once(self):
        self.seed()
        self.backup.write_marker("nightly", "crashed", self.backup.now() - timedelta(minutes=1))
        self.runner.maintenance = True  # a crashed run left maintenance on
        record = self.backup.run("nightly")
        self.assertEqual(record["result"], "success")
        self.assertEqual(self.alerts(), ["backup-marker-stale"])
        self.assertIn("restic repair", self.runner.events)

    def test_incomplete_snapshot_is_a_failure(self):
        self.seed()
        self.runner.restic_exit = 3
        record = self.backup.run("nightly")
        self.assertEqual(record["reason"], "incomplete-snapshot")

    def test_weekly_prune_and_monthly_read_check(self):
        self.seed()
        self.assertIsNotNone(self.backup.status.get("last_prune"))
        self.assertIsNotNone(self.backup.status.get("last_read_check"))
        self.clock.advance(86400)
        self.backup.run("nightly")
        forget = [call for call in self.runner.calls if "forget" in call]
        self.assertNotIn("--prune", forget[-1])
        self.assertIn("--keep-daily", forget[-1])
        self.clock.advance(7 * 86400)
        self.backup.run("nightly")
        forget = [call for call in self.runner.calls if "forget" in call]
        self.assertIn("--prune", forget[-1])


class StaleAlerts(BackupTestCase):
    def test_no_alert_before_the_seed(self):
        self.clock.advance(100 * 3600)
        self.backup.report(alert_stale=True)
        self.assertEqual(self.alerts(), [])

    def test_36_hours_without_success_alerts_once_and_resets(self):
        self.seed()
        self.clock.advance(35 * 3600)
        self.backup.report(alert_stale=True)
        self.assertEqual(self.alerts(), [])
        self.clock.advance(2 * 3600)
        self.backup.report(alert_stale=True)
        self.backup.report(alert_stale=True)
        self.assertEqual(self.alerts(), ["backup-stale"])
        self.backup.run("nightly")
        self.clock.advance(37 * 3600)
        self.backup.report(alert_stale=True)
        self.assertEqual(self.alerts(), ["backup-stale", "backup-stale"])

    def test_missed_night_runs_next_night(self):
        """The VM host off at 03:30: nothing at boot; the next 03:30 run succeeds; no alert inside 36 h."""
        self.seed()
        self.clock.advance(24 * 3600 + 8 * 3600)  # booted at 11:30 the next day; no catch-up run
        self.backup.report(alert_stale=True)
        self.clock.advance(16 * 3600)  # 03:30 on the following night: 48 h after the seed
        self.backup.report(alert_stale=True)
        self.assertEqual(self.alerts(), ["backup-stale"])
        record = self.backup.run("nightly")
        self.assertEqual(record["result"], "success")

    def test_marker_past_deadline_alerts_once(self):
        self.backup.write_marker("nightly", "r1", self.backup.now() + timedelta(minutes=30))
        self.backup.report(alert_stale=True)
        self.assertEqual(self.alerts(), [])
        self.assertTrue(self.backup.report()["marker"]["active"])
        self.runner.maintenance = True  # the crashed run left production in maintenance
        self.clock.advance(31 * 60)
        self.backup.report(alert_stale=True)
        self.backup.report(alert_stale=True)
        self.assertEqual(self.alerts(), ["backup-marker-stale"])
        # Recovered by the hourly check itself (lock free): no 503 until the next 03:30.
        self.assertIsNone(self.backup.report()["marker"])
        self.assertFalse(self.runner.maintenance)
        self.assertTrue(self.backup.status["needs_index_repair"])

    def test_marker_past_deadline_while_a_run_holds_the_lock_is_not_touched(self):
        self.backup.write_marker("nightly", "r2", self.backup.now() + timedelta(minutes=30))
        self.runner.maintenance = True
        self.clock.advance(31 * 60)
        with self.make().lock():
            self.backup.report(alert_stale=True)
        self.assertEqual(self.alerts(), ["backup-marker-stale"])
        self.assertTrue(self.runner.maintenance)
        self.assertTrue(self.backup.marker_path.exists())

    def test_alert_without_dispatcher_is_recorded_undelivered(self):
        self.backup.alerter.command = None
        with mock.patch("sys.stderr", io.StringIO()) as stderr:
            self.backup.alerter.send("backup-failed", "x")
        self.assertFalse(self.backup.status["alerts"][-1]["delivered"])
        self.assertIn('"event": "alert"', stderr.getvalue())

    def test_alert_messages_carry_no_paths(self):
        self.seed()
        self.runner.mounts = []
        self.backup.run("nightly")
        for alert in self.backup.status["alerts"]:
            self.assertNotIn("/", alert["message"])


class InPlaceRestore(BackupTestCase):
    """B1: a restore into the backup's own (production) state root, as the runbook does."""

    def setUp(self):
        super().setUp()
        self.prod_state = self.temp / "prod-state"
        self.prod_state.mkdir(mode=0o700)
        self.patch = mock.patch.object(B, "DEFAULT_STATE_ROOT", self.prod_state)
        self.patch.start()
        self.prod = B.Backup(B.PROJECT, None, runner=self.runner, clock=self.clock, cache_home=self.temp / "cache",
                             out=io.StringIO())
        # The production backup shares the review repository fixture: same drive, same ID.
        self.prod.config = json.loads(json.dumps(self.backup.config))
        self.prod.save_config()
        (self.prod_state / "secrets").mkdir(mode=0o700)
        B.atomic_write(self.prod.password_file, "escrowed\n")
        self.runner.services = {name: "exited" for name in self.runner.services}

    def tearDown(self):
        self.patch.stop()
        super().tearDown()

    def restore(self, **options):
        return B.Restore(self.prod, B.PROJECT, self.prod_state, self.temp / "work", **options).run("latest")

    def test_new_host_restore_into_a_root_holding_only_the_password_and_config(self):
        result = self.restore()
        self.assertTrue(all(self.runner.password_seen))
        self.assertEqual((self.prod_state / "secrets" / "restic-password").read_text(), "escrowed\n")
        self.assertEqual((self.prod_state / "secrets" / "database").read_text(), "restored db")
        self.assertTrue((self.prod_state / "operator" / "issuer.crt").exists())
        self.assertTrue((self.prod_state / "backup.json").exists())
        self.assertIn("secrets/database", result["state_entries"])
        self.assertNotIn("secrets/restic-password", result["state_entries"])
        self.assertIn('roles CREATE ROLE "oc_admin";', [e.replace("ALTER ROLE anj WITH SUPERUSER;\n", "") for e in self.runner.events])
        self.assertFalse(any(e.startswith("roles CREATE ROLE anj;") for e in self.runner.events))
        self.assertEqual(sorted((self.temp / "work").rglob("*")), [self.temp / "work" / "staging",
                                                                   self.temp / "work" / "staging" / "manifest.json"])

    def test_existing_production_state_is_refused_before_anything_destructive(self):
        (self.prod_state / "operator").mkdir(mode=0o700)
        self.runner.volumes = ["anj-cloud-prod_nextcloud"]
        with self.assertRaisesRegex(B.BackupError, "--replace-production"):
            self.restore()
        self.runner.volumes = []
        with self.assertRaisesRegex(B.BackupError, "already holds entries"):
            self.restore()
        self.assertEqual(self.runner.removed_volumes, [])
        self.assertEqual(self.runner.created_volumes, [])
        self.assertFalse((self.temp / "work" / ".restic-password").exists())

    def test_replace_production_in_place_keeps_the_password_throughout(self):
        (self.prod_state / "operator").mkdir(mode=0o700)
        (self.prod_state / "operator" / "issuer.crt").write_text("old issuer")
        B.atomic_write(self.prod_state / "secrets" / "database", "old db")
        self.runner.volumes = [f"anj-cloud-prod_{name}" for name in ("nextcloud", "access", "database", "redis")]
        self.restore(replace_production=True, confirm=B.PROJECT)
        self.assertTrue(self.runner.password_seen and all(self.runner.password_seen))
        events = self.runner.events
        # Production volumes are removed only after the snapshot's host pieces are staged.
        self.assertLess(events.index("restore state"), events.index("docker-rm"))
        self.assertEqual(sorted(self.runner.removed_volumes), sorted(self.runner.volumes))
        self.assertEqual((self.prod_state / "secrets" / "restic-password").read_text(), "escrowed\n")
        self.assertEqual((self.prod_state / "operator" / "issuer.crt").read_text(), "restored issuer")
        aside = next(self.prod_state.glob("replaced-*"))
        self.assertEqual((aside / "operator" / "issuer.crt").read_text(), "old issuer")
        self.assertEqual((aside / "secrets" / "database").read_text(), "old db")
        self.assertFalse((aside / "secrets" / "restic-password").exists())

    def test_restore_holds_the_restore_marker_and_records_its_result(self):
        self.runner.restore_marker = self.prod_state / "run" / B.paths.RESTORE_IN_PROGRESS.name
        self.restore()
        self.assertTrue(self.runner.marker_seen and all(self.runner.marker_seen))
        self.assertFalse(self.runner.restore_marker.exists())
        recorded = json.loads((self.prod_state / "run" / B.LAST_RESTORE).read_text())
        self.assertEqual(recorded["checks"]["config_sentinel"], True)
        self.assertNotIn("restic-password", json.dumps(recorded))

    def test_read_only_share_restores_without_a_lock(self):
        self.runner.mounts[0]["options"] = "ro,relatime"
        self.runner.calls.clear()
        self.restore()
        restic = [call for call in self.runner.calls if B.RESTIC_IMAGE in call and call[:2] == ["docker", "run"]
                  and "--entrypoint" not in call]
        self.assertTrue(restic)
        for call in restic:
            self.assertIn("--no-lock", call)
            self.assertTrue(any(value.endswith(":/repo:ro") for value in call))

    def restic_calls(self):
        return [call for call in self.runner.calls if B.RESTIC_IMAGE in call and call[:2] == ["docker", "run"]
                and "--entrypoint" not in call]

    def test_rw_mounted_share_refusing_writes_restores_without_a_lock(self):
        """SC-067: the VM host serves the drill's share read-only (libvirt <readonly/>) while the guest
        mounts it rw; the write probe, not the mount options, decides: every restic call reads
        with --no-lock and the repository mounted :ro."""
        self.assertEqual(self.runner.mounts[0]["options"], "rw,relatime")
        self.runner.calls.clear()
        with mock.patch.object(B.Backup, "writable", staticmethod(lambda directory: False)):
            self.restore()
        restic = self.restic_calls()
        self.assertTrue(any("snapshots" in call for call in restic))
        for call in restic:
            self.assertIn("--no-lock", call)
            self.assertTrue(any(value.endswith(":/repo:ro") for value in call))

    def test_writable_share_restore_keeps_locking(self):
        self.runner.calls.clear()
        probed = []
        real = B.Backup.writable
        with mock.patch.object(B.Backup, "writable", staticmethod(lambda d: probed.append(d) or real(d))):
            self.restore()
        self.assertEqual(probed, [self.prod.repository_path(self.prod.target)])
        self.assertEqual(list(Path(probed[0]).glob(".anj-write-probe-*")), [])  # the probe leaves nothing
        for call in self.restic_calls():
            if "cat" in call:
                continue  # repository_id always reads the config with --no-lock
            self.assertNotIn("--no-lock", call)
            self.assertTrue(any(value.endswith(":/repo") for value in call))

    def test_running_production_is_refused(self):
        self.runner.services["nextcloud"] = "running"
        self.runner.volumes = ["anj-cloud-prod_nextcloud"]
        with self.assertRaisesRegex(B.BackupError, "Stop production first"):
            self.restore(replace_production=True, confirm=B.PROJECT)
        self.assertEqual(self.runner.removed_volumes, [])

    def test_escrowed_password_file_for_a_new_host(self):
        self.prod.password_file.unlink()
        escrow = self.temp / "escrow"
        B.atomic_write(escrow, "escrowed\n")
        B.Restore(self.prod, B.PROJECT, self.prod_state, self.temp / "work", password_file=escrow).run("latest")
        self.assertTrue(all(self.runner.password_seen))
        self.assertFalse((self.temp / "work" / ".restic-password").exists())

    def test_adopt_records_the_existing_repository(self):
        fresh = self.temp / "fresh-state"
        fresh.mkdir(mode=0o700)
        escrow = self.temp / "escrow"
        B.atomic_write(escrow, "escrowed\n")
        adopter = B.Backup("anj-cloud-review-bk", fresh, runner=self.runner, cache_home=self.temp / "c2")
        result = adopter.init(mount=str(self.drive), tag=TAG, adopt=True, password_file=str(escrow),
                              alert_command=["/alert"])
        self.assertEqual((result["state"], result["repository_id"]), ("adopted", REPO_ID))
        self.assertEqual((fresh / "secrets" / "restic-password").stat().st_mode & 0o777, 0o600)
        self.assertNotIn("init", " ".join(self.runner.events[-3:]))

    def test_adopt_writes_nothing_to_the_share_not_even_a_probe(self):
        """PR #90 review L2: init --adopt keeps its 'nothing written' contract."""
        fresh = self.temp / "fresh-state"
        fresh.mkdir(mode=0o700)
        escrow = self.temp / "escrow"
        B.atomic_write(escrow, "escrowed\n")
        adopter = B.Backup("anj-cloud-review-bk", fresh, runner=self.runner, cache_home=self.temp / "c2")
        before = sorted(path.name for path in self.drive.rglob("*"))
        with mock.patch.object(B.Backup, "writable", side_effect=AssertionError("adopt probed the share")):
            result = adopter.init(mount=str(self.drive), tag=TAG, adopt=True, password_file=str(escrow),
                                  alert_command=["/alert"])
        self.assertEqual(result["state"], "adopted")
        self.assertEqual(sorted(path.name for path in self.drive.rglob("*")), before)


class SpaceAndGateway(BackupTestCase):
    def test_growth_after_the_seed_is_measured_and_refused_when_it_does_not_fit(self):
        self.seed()
        self.runner.du_bytes = 50 * 1000**3  # a large day of uploads after the seed
        with mock.patch.object(B.Backup, "space", lambda self, target: {"free_bytes": 30 * 1000**3,
                                                                         "total_bytes": 100 * 1000**3,
                                                                         "used_fraction": 0.7}):
            record = self.backup.run("nightly")
        self.assertEqual((record["result"], record["reason"]), ("preflight-failed", "low-space"))
        self.assertNotIn("maintenance --on", self.runner.events)

    def test_source_size_is_re_measured_every_run(self):
        self.seed()
        self.runner.du_bytes = 7 * 1024**2
        self.clock.advance(86400)
        record = self.backup.run("nightly")
        self.assertEqual(record["source_bytes"], 7 * 1024**2)
        self.assertEqual(self.backup.status["last_success"]["source_bytes"], 7 * 1024**2)

    def test_prune_night_adds_repository_headroom(self):
        self.seed()
        data = self.drive / "restic" / "data"
        data.mkdir(parents=True, exist_ok=True)
        (data / "pack").write_bytes(b"x" * 1000)
        self.clock.advance(7 * 86400)
        record = self.backup.run("nightly")
        self.assertEqual(record["prune_headroom_bytes"], 100)

    def test_registry_snapshot_runs_as_the_gateway_user(self):
        self.seed()
        self.backup.run("nightly")
        execs = [call for call in self.runner.calls if call[:2] == ["docker", "exec"] and "-c" in call
                 and any("registry.sqlite" in part for part in call)]
        self.assertTrue(execs)
        for call in execs:
            self.assertEqual(call[call.index("--user") + 1], "10001:10001")

    def test_stop_that_hangs_is_killed_within_bounds(self):
        self.seed()
        self.runner.hang = True
        self.runner.stop_hangs = True
        record = self.backup.run("nightly")
        self.assertEqual(record["result"], "capped")
        self.assertIn("docker-kill", self.runner.events)
        self.assertFalse(self.runner.maintenance)


class VmInterfaces(BackupTestCase):
    def test_production_paths_are_spec_20s(self):
        with mock.patch.object(B, "DEFAULT_STATE_ROOT", self.state):
            prod = B.Backup(B.PROJECT, None, runner=self.runner, cache_home=self.temp / "c")
        self.assertEqual(prod.marker_path.relative_to(self.state), B.paths.BACKUP_IN_PROGRESS.relative_to(B.paths.STATE_ROOT))
        self.assertEqual(prod.restore_marker_path.relative_to(self.state),
                         B.paths.RESTORE_IN_PROGRESS.relative_to(B.paths.STATE_ROOT))
        self.assertEqual(prod.password_file.relative_to(self.state), B.paths.RESTIC_PASSWORD.relative_to(B.paths.STATE_ROOT))
        self.assertEqual(prod.config_path.relative_to(self.state), B.paths.BACKUP_RECORD.relative_to(B.paths.STATE_ROOT))
        self.assertEqual(B.paths.STATE_ROOT, Path("/srv/anj-cloud/state"))
        self.assertEqual(prod.repository_path({"mount": str(B.paths.BACKUP_MOUNT)}), B.paths.RESTIC_REPOSITORY)
        self.assertEqual(B.CONTAINER_UID, B.paths.GATEWAY_UID)

    def test_backup_py_redefines_no_paths_value(self):
        source = Path(B.__file__).read_text()
        for literal in ("/srv/anj-cloud", "/mnt/anj-backup\"", "backup-in-progress\"", "restore-in-progress\"",
                        "anj-backup\"", "10001"):
            self.assertNotIn(literal, source, literal)

    def test_shortened_cap_only_on_the_qualification_vm(self):
        with mock.patch.object(B, "DEFAULT_STATE_ROOT", self.state):
            prod = B.Backup(B.PROJECT, None, runner=self.runner, cache_home=self.temp / "c")
        with mock.patch("socket.gethostname", return_value="anj-prod"), \
                self.assertRaisesRegex(B.BackupError, "30-minute"):
            prod.run("nightly", cap_seconds=40)
        with mock.patch("socket.gethostname", return_value="anj-qual"):
            record = prod.run("nightly", cap_seconds=40, limit_upload=10)
        self.assertNotIn("30-minute", record.get("error", ""))


class HaloVmModel:
    """Spec #21's halo-vm.sh qualification contract (PR #40, 3725fb9) and the virsh reads around it.

    --qual --run-id ID: exit 3 (qual-busy) when any anj-qual object exists; else writes ID to the
    tag file, then defines network, pool and domain (description "anj-qual run-id=ID").
    --qual-destroy --run-id ID: exit 3 when the recorded run id differs (no --force here); else
    removes every object and the tag file."""

    def __init__(self, tag_file, calls):
        self.tag_file = Path(tag_file)
        self.calls = calls
        self.objects = set()       # subset of {"domain", "net", "pool"}
        self.description = None    # run id in the domain description
        self.fail_after_tag = False   # partial create: tag written, network defined, then failure
        self.foreign_appears = None   # a run id that creates anj-qual right before our --qual
        self.list_error = False       # `virsh list --all --name` fails
        self.dumpxml_error = False    # dumpxml of a listed domain fails
        self.raw = []                 # every argv as issued (to check the LC_ALL=C prefix)

    def owner(self):
        if self.description:
            return self.description
        return self.tag_file.read_text().strip() if self.tag_file.exists() else None

    def qual(self, run_id):
        if self.foreign_appears is not None:
            self.objects = {"domain", "net", "pool"}
            self.description = self.foreign_appears or None   # "" models an untitled foreign VM
            if self.foreign_appears:
                self.tag_file.write_text(self.foreign_appears + "\n")
        if self.objects:
            return Result(returncode=3)
        self.tag_file.parent.mkdir(parents=True, exist_ok=True)
        self.tag_file.write_text(run_id + "\n")
        self.objects = {"net"}
        if self.fail_after_tag:
            return Result(returncode=1)
        self.objects = {"domain", "net", "pool"}
        self.description = run_id
        return Result()

    def qual_destroy(self, run_id):
        tag = self.owner()
        if tag and tag != "none" and tag != run_id:
            return Result(returncode=3)
        self.objects = set()
        self.description = None
        if self.tag_file.exists():
            self.tag_file.unlink()
        return Result()

    def virsh(self, argv):
        command, name = argv[3], argv[-1]
        if name == "anj-prod" and command == "dominfo":
            return Result(b"Id: 3\nState: running\n")
        present = {"dominfo": "domain", "net-info": "net", "pool-info": "pool"}.get(command)
        if present:
            return Result(b"Id: 9\nState: running\n" if present in self.objects else b"",
                          0 if present in self.objects else 1)
        if command == "list":
            if self.list_error:
                return Result(returncode=1, stderr=b"error: failed to connect to the hypervisor")
            names = ["anj-prod"] + (["anj-qual"] if "domain" in self.objects else [])
            return Result(("\n".join(names) + "\n").encode())
        if command == "dumpxml":
            if self.dumpxml_error or "domain" not in self.objects:
                return Result(returncode=1, stderr=b"error: failed to get domain 'anj-qual'")
            text = f"<description>anj-qual run-id={self.description}</description>" if self.description else ""
            return Result(f"<domain><name>anj-qual</name>{text}</domain>".encode())
        if command == "desc":
            raise AssertionError("nothing may retitle or retag anj-qual")
        raise AssertionError(argv)

    @staticmethod
    def strip(argv):
        return argv[2:] if argv[:2] == ["env", "LC_ALL=C"] else argv

    def run(self, argv):
        self.raw.append(argv)
        argv = self.strip(argv)
        if argv[0] == "virsh":
            return self.virsh(argv)
        if argv[1:2] == ["--qual"]:
            assert "--force" not in argv
            return self.qual(argv[argv.index("--run-id") + 1])
        if argv[1:2] == ["--qual-destroy"]:
            assert "--force" not in argv
            return self.qual_destroy(argv[argv.index("--run-id") + 1])
        return None


class Qualification(unittest.TestCase):
    def setUp(self):
        self.temp = Path(tempfile.mkdtemp(prefix="anj-qual-test-"))
        self.calls = []
        self.vm = HaloVmModel(self.temp / "run-id", self.calls)
        self.patch = mock.patch.object(B, "QUAL_TAG_FILE", self.vm.tag_file)
        self.patch.start()
        # Spec #21's stage.py resolves the staged commit with git; a fixed one keeps this hermetic.
        from deploy.vm import stage
        resolve = mock.patch.object(stage, "resolve", lambda commit, checkout=None: "f" * 40)
        resolve.start()
        self.addCleanup(resolve.stop)

    def tearDown(self):
        self.patch.stop()
        shutil.rmtree(self.temp, ignore_errors=True)

    def runner(self, *, fail_step=False):
        test = self

        class Runner:
            def run(self, argv, *, data=None, timeout=600, stdout=None, check=True):
                modelled = test.vm.run(argv)
                test.calls.append(HaloVmModel.strip(argv))
                if modelled is not None:
                    return modelled
                if argv[0] == "ssh" and argv[-1] == B.CLOCK_SYNC_COMMAND:
                    return Result(b"yes\n")
                if argv[0] == "ssh" and "vm-step patterns" in argv[-1]:
                    return Result(b"S\nN\nT\n")
                if argv[0] == "ssh" and "vm-step" in argv[-1] and fail_step:
                    raise subprocess.TimeoutExpired("ssh", 1)
                if "grep" in argv:
                    return Result(returncode=1)
                return Result(b"{}")

            def pipe(self, producer, consumer, *, timeout=300):
                test.calls.append(["PIPE", producer, consumer])
                return True

        return Runner()

    def halo(self, **options):
        from deploy import backup_qualify as Q
        return Q.Halo(self.runner(**options), halo_vm="/opt/halo-vm.sh", scratch_share=self.temp / "share",
                      evidence=self.temp / "evidence")

    def test_phase_one_pipes_the_password_from_anj_prod_and_destroys_its_own_vm(self):
        from deploy import backup_qualify as Q
        halo = self.halo(fail_step=True)
        with mock.patch("sys.stdout", io.StringIO()), self.assertRaises(subprocess.TimeoutExpired):
            halo.phase_one()
        commands = [call for call in self.calls if call[0] not in ("virsh", "PIPE")]
        self.assertEqual(commands[0][:2], ["/opt/halo-vm.sh", "--qual"])
        run_id = commands[0][commands[0].index("--run-id") + 1]
        self.assertEqual(commands[0][-2:], ["--scratch-share", str(self.temp / "share")])
        pipes = [call for call in self.calls if call[0] == "PIPE"]
        # Spec #21: the bootstrap is staged into the fresh VM (git archive | ssh) before it runs.
        self.assertEqual(pipes[0][1][:3], ["git", "-C", str(Path(B.__file__).resolve().parent.parent)])
        self.assertIn("/var/lib/anj-cloud-setup/src", pipes[0][2][-1])
        setup = next(call for call in commands if call[0] == "ssh" and "anj-cloud-setup" in call[-1])
        self.assertIn("sudo /var/lib/anj-cloud-setup/src/deploy/vm/anj-cloud-setup --answers", setup[-1])
        pipe = pipes[1]
        self.assertEqual(pipe[1][-2:], ["anj-prod", f"sudo cat {B.paths.RESTIC_PASSWORD}"])
        self.assertEqual(pipe[1][1:3], ["-F", str(B.HALO_SSH_CONFIG)])
        self.assertIn(f"/dev/stdin {B.paths.RESTIC_PASSWORD}", pipe[2][-1])
        self.assertEqual(commands[-1], ["/opt/halo-vm.sh", "--qual-destroy", "--run-id", run_id])
        self.assertEqual(self.vm.objects, set())
        self.assertIn('ddns = "off"', Q.QUAL_ANSWERS)
        self.assert_ssh_uses_halo_config()

    def assert_ssh_uses_halo_config(self):
        invocations = [call for call in self.calls if call[0] in ("ssh", "scp")]
        invocations += [argv for call in self.calls if call[0] == "PIPE" for argv in call[1:] if argv[0] in ("ssh", "scp")]
        self.assertTrue(invocations)
        for argv in invocations:
            self.assertEqual(argv[1:3], ["-F", str(B.HALO_SSH_CONFIG)], argv)

    def test_every_in_vm_step_and_the_encryption_patterns_use_halo_config(self):
        halo = self.halo()
        with mock.patch("sys.stdout", io.StringIO()):
            halo.phase_one()
        self.assertTrue([call for call in self.calls if call[0] == "ssh" and "vm-step patterns" in call[-1]])
        self.assertTrue([call for call in self.calls if call[0] == "ssh" and "vm-step prepare" in call[-1]])
        self.assert_ssh_uses_halo_config()

    def test_no_bare_ssh_or_scp_in_the_sources(self):
        """Every ssh/scp argv in backup.py and backup_qualify.py is built by B.ssh_argv (-F)."""
        import ast
        root = Path(B.__file__).resolve().parent
        found = []
        for name in ("backup.py", "backup_qualify.py"):
            tree = ast.parse((root / name).read_text())
            for node in ast.walk(tree):
                if isinstance(node, ast.List) and node.elts and isinstance(node.elts[0], ast.Constant) \
                        and node.elts[0].value in ("ssh", "scp"):
                    second = node.elts[1].value if len(node.elts) > 1 and isinstance(node.elts[1], ast.Constant) else None
                    found.append((name, node.lineno, node.elts[0].value, second))
        self.assertEqual([(name, tool, second) for name, _, tool, second in found], [("backup.py", "ssh", "-F")], found)

    def test_phase_two_drill_pipes_from_anj_prod_too(self):
        halo = self.halo()
        with mock.patch("sys.stdout", io.StringIO()), mock.patch.object(B, "in_blackout", lambda moment: False):
            halo.phase_two()
        pipe = next(call for call in self.calls if call[0] == "PIPE")
        self.assertEqual(pipe[1][-2:], ["anj-prod", f"sudo cat {B.paths.RESTIC_PASSWORD}"])
        self.assertIn(f"/dev/stdin {B.DRILL_PASSWORD}", pipe[2][-1])
        self.assert_ssh_uses_halo_config()

    def test_phase_one_partial_create_is_cleaned_up_by_run_id(self):
        self.vm.fail_after_tag = True
        halo = self.halo()
        with mock.patch("sys.stdout", io.StringIO()), self.assertRaises(B.BackupError):
            halo.phase_one()
        destroy = [call for call in self.calls if call[1:2] == ["--qual-destroy"]]
        self.assertEqual(len(destroy), 1)
        self.assertEqual(self.vm.objects, set())
        self.assertTrue(halo.results[-1]["pass"])

    def test_existing_anj_qual_is_refused_and_untouched(self):
        self.vm.objects = {"domain", "net", "pool"}
        self.vm.description = "someone-else"
        with self.assertRaises(B.BackupError) as raised:
            self.halo().phase_one()
        self.assertEqual(raised.exception.reason, "qual-busy")
        self.assertEqual(self.vm.objects, {"domain", "net", "pool"})
        self.assertFalse([call for call in self.calls if call[0] != "virsh"])

    def test_encryption_search_keeps_patterns_private(self):
        from deploy import backup_qualify as Q
        seen = {}

        class Runner:
            def run(self, argv, *, data=None, timeout=600, stdout=None, check=True):
                if argv[0] == "ssh":
                    return Result(b"S\nN\nT\n")
                seen["argv"] = argv
                pattern_file = Path(argv[argv.index("-f") + 1])
                seen["mode"] = pattern_file.stat().st_mode & 0o777
                return Result(returncode=1)

        halo = Q.Halo(Runner(), halo_vm="h", scratch_share=self.temp, evidence=self.temp / "e")
        with mock.patch("sys.stdout", io.StringIO()):
            halo.record_encryption()
        self.assertEqual(seen["mode"], 0o600)
        self.assertTrue(halo.results[-1]["pass"])
        self.assertFalse(Path(seen["argv"][seen["argv"].index("-f") + 1]).exists())
        self.assertNotIn("S", json.dumps(halo.results))


class ResticContainers(BackupTestCase):
    """Decision #119: restic (the container's root) gets DAC_READ_SEARCH, DAC_OVERRIDE and FOWNER
    and nothing else, and its only writable mounts are the repository and the cache."""

    def restic_runs(self):
        return [argv for argv in self.runner.calls if argv[:2] == ["docker", "run"] and B.RESTIC_IMAGE in argv
                and "--entrypoint" not in argv]

    def test_capabilities_and_writable_mounts_are_pinned(self):
        self.assertEqual(B.RESTIC_CAPS, ("DAC_READ_SEARCH", "DAC_OVERRIDE", "FOWNER"))
        self.seed()
        self.backup.check(False)
        runs = self.restic_runs()
        self.assertTrue(any("backup" in argv for argv in runs), runs)
        repository, cache = str(self.backup.repository_path()), str(self.backup.cache_dir)
        for argv in runs:
            caps = [argv[i + 1] for i, a in enumerate(argv) if a == "--cap-add"]
            self.assertEqual(caps, list(B.RESTIC_CAPS), argv)
            self.assertIn("--cap-drop", argv)
            self.assertEqual(argv[argv.index("--cap-drop") + 1], "ALL")
            self.assertIn("--read-only", argv)
            self.assertIn("no-new-privileges", argv)
            volumes = [argv[i + 1] for i, a in enumerate(argv) if a == "--volume"]
            writable = sorted(v.split(":")[0] for v in volumes if not v.endswith(":ro"))
            self.assertEqual(writable, sorted([repository, cache]), argv)


class Units(BackupTestCase):
    def test_system_units_render_for_the_bootstrap(self):
        units = B.render_units("/srv/anj-cloud/state/release/0123456789ab/source")
        self.assertEqual(sorted(units), ["anj-cloud-backup-stale.service", "anj-cloud-backup-stale.timer",
                                         "anj-cloud-backup.service", "anj-cloud-backup.timer"])
        timer = units["anj-cloud-backup.timer"]
        self.assertIn("OnCalendar=*-*-* 03:30:00\n", timer)
        self.assertIn("Persistent=false\n", timer)
        self.assertIn("Persistent=false\n", units["anj-cloud-backup-stale.timer"])
        service = units["anj-cloud-backup.service"]
        self.assertIn("ExecStart=/usr/bin/python3 -I /srv/anj-cloud/state/release/0123456789ab/source/deploy/backup.py run\n",
                      service)
        self.assertIn(f"User={B.paths.VM_USER}\n", service)
        self.assertIn("status --alert-stale", units["anj-cloud-backup-stale.service"])
        for text in units.values():
            directives = [line for line in text.splitlines() if line and not line.startswith("#")]
            self.assertFalse([line for line in directives if "@" in line or "pm2" in line.lower()])
        with self.assertRaises(B.BackupError):
            B.render_units("relative/path")

    def test_units_command_writes_files(self):
        out = self.temp / "rendered"
        with mock.patch("sys.stdout", io.StringIO()):
            self.assertEqual(B.main(["units", "--source", "/opt/src", "--out", str(out)]), 0)
        self.assertTrue((out / "anj-cloud-backup.timer").exists())

    def test_seed_installs_no_timer(self):
        self.seed()
        self.assertFalse(any(call and call[0] == "systemctl" for call in self.runner.calls))


class WindowCoordination(BackupTestCase):
    """Rev7 Run Sequence 7, decision #86 and the PR #38 review ruling: `backup.py window --check` is
    read-only and root-capable; 0 clear, 1 busy, 2 error (busy, alerting once a day)."""

    def window(self, *extra):
        with mock.patch("sys.stdout", io.StringIO()) as out:
            code = B.main(["--project", "anj-cloud-review-bk", "--state-root", str(self.state), "window", "--check",
                           *extra])
        return code, json.loads(out.getvalue())

    def test_clear_when_idle(self):
        self.assertEqual(self.window(), (B.WINDOW_CLEAR, mock.ANY))

    def test_backup_marker_before_its_deadline_blocks(self):
        self.backup.write_marker("nightly", "r", B.utcnow() + timedelta(minutes=20))
        code, result = self.window()
        self.assertEqual((code, result["busy"]), (B.WINDOW_BUSY, ["backup-marker"]))

    def test_past_deadline_marker_does_not_block_forever(self):
        self.backup.write_marker("nightly", "r", B.utcnow() - timedelta(minutes=1))
        self.assertEqual(self.window()[0], B.WINDOW_CLEAR)

    def test_unreadable_marker_blocks(self):
        self.backup.run_dir.mkdir(exist_ok=True)
        self.backup.marker_path.write_text("{not json")
        self.assertEqual(self.window(), (B.WINDOW_BUSY, mock.ANY))

    def test_running_backup_blocks_even_without_a_marker(self):
        with self.make().lock():
            code, result = self.window()
        self.assertEqual((code, result["busy"]), (B.WINDOW_BUSY, ["backup-running"]))

    def test_housekeeping_after_the_window_keeps_it_busy(self):
        """Forget/prune/check run under the backup lock after maintenance: the guard still waits."""
        self.seed()
        observed = []
        original = self.runner.popen

        def popen(argv):
            if "forget" in argv:
                observed.append(B.window_check(self.state)["busy"])
            return original(argv)

        self.runner.popen = popen
        self.backup.run("nightly")
        self.assertEqual(observed, [["backup-running"]])

    def test_restore_marker_and_process_block(self):
        with B.restore_window(self.state, "anj-cloud-review-bk", "restore", B.utcnow) as marker:
            code, result = self.window()
            self.assertEqual(marker.name, B.paths.RESTORE_IN_PROGRESS.name)
        self.assertEqual((code, sorted(result["busy"])), (B.WINDOW_BUSY, ["restore-marker", "restore-running"]))
        self.assertEqual(self.window()[0], B.WINDOW_CLEAR)

    def test_second_restore_is_refused_while_one_runs(self):
        with B.restore_window(self.state, "p", "restore", B.utcnow):
            with self.assertRaisesRegex(B.BackupError, "Another restore"):
                with B.restore_window(self.state, "p", "drill", B.utcnow):
                    pass

    def test_root_reads_without_ownership_refusal_or_writes(self):
        """As apt-daily-upgrade and the reboot guard call it: euid 0, a state root owned by anj."""
        self.backup.write_marker("nightly", "r", B.utcnow() + timedelta(minutes=20))
        before = sorted((p.name, p.stat().st_mtime_ns) for p in self.state.rglob("*"))
        with mock.patch("os.geteuid", return_value=0), mock.patch("os.getuid", return_value=0):
            code, result = self.window()
        self.assertEqual((code, result["busy"]), (B.WINDOW_BUSY, ["backup-marker"]))
        self.assertEqual(sorted((p.name, p.stat().st_mtime_ns) for p in self.state.rglob("*")), before)
        self.backup.clear_marker()
        with mock.patch("os.geteuid", return_value=0):
            self.assertEqual(self.window()[0], B.WINDOW_CLEAR)

    def test_error_is_exit_2_busy_and_alerts_once_a_day(self):
        missing = self.temp / "no-state-root"
        stamp = self.temp / "window-alert"
        sent = []

        class Runner:
            def run(self, argv, **kwargs):
                sent.append(argv)
                return Result()

        config = {"alert_command": ["/alert"]}
        for day in (datetime(2026, 11, 4, 4, 15), datetime(2026, 11, 4, 4, 20), datetime(2026, 11, 5, 4, 15)):
            with mock.patch("sys.stdout", io.StringIO()) as out:
                code = B.window_command(missing, now=day.astimezone(), runner=Runner(), stamp_path=stamp)
            self.assertEqual(code, B.WINDOW_ERROR)
            self.assertFalse(json.loads(out.getvalue())["clear"])
        self.assertEqual(len(sent), 0)  # no backup.json readable and no anj-alert on PATH: nothing to call
        self.state.joinpath("backup.json").write_text(json.dumps(config))
        stamp.unlink()
        with mock.patch.object(B, "window_check", side_effect=PermissionError):
            for day in (datetime(2026, 11, 6, 4, 15), datetime(2026, 11, 6, 4, 20), datetime(2026, 11, 7, 4, 15)):
                with mock.patch("sys.stdout", io.StringIO()):
                    self.assertEqual(B.window_command(self.state, now=day.astimezone(), runner=Runner(),
                                                      stamp_path=stamp), B.WINDOW_ERROR)
        self.assertEqual([argv[2] for argv in sent], ["backup-window-check", "backup-window-check"])
        self.assertIn("update window check failing", sent[0][-1])

    def test_exit_codes_for_systemd_execcondition(self):
        """ExecCondition skips on 1-254: busy (1) and error (2) both skip; only clear (0) runs."""
        condition = [sys.executable, "-I", str(Path(B.__file__)), "--project", "anj-cloud-review-bk",
                     "--state-root", str(self.state), "window", "--check"]
        run = lambda: subprocess.run(condition, capture_output=True, timeout=60).returncode
        self.assertEqual(run(), 0)
        self.backup.write_marker("nightly", "r", B.utcnow() + timedelta(minutes=20))
        self.assertEqual(run(), 1)
        self.backup.clear_marker()
        condition[condition.index(str(self.state))] = str(self.temp / "absent")
        env = dict(os.environ, XDG_RUNTIME_DIR=str(self.temp))
        self.assertEqual(subprocess.run(condition, capture_output=True, timeout=60, env=env).returncode, 2)

    def test_stub_guard_waits_on_busy_and_error(self):
        guard = self.temp / "guard.sh"
        guard.write_text(
            "#!/bin/sh\n"
            f'"{sys.executable}" -I "{Path(B.__file__)}" --project anj-cloud-review-bk --state-root "$1" '
            "window --check >/dev/null; case $? in 0) echo reboot;; *) echo wait;; esac\n")
        run = lambda root: subprocess.run(["sh", str(guard), str(root)], capture_output=True, text=True, timeout=60,
                                          env=dict(os.environ, XDG_RUNTIME_DIR=str(self.temp))).stdout.strip()
        self.assertEqual(run(self.state), "reboot")
        with B.restore_window(self.state, "anj-cloud-review-bk", "restore", B.utcnow):
            self.assertEqual(run(self.state), "wait")
        self.assertEqual(run(self.temp / "absent"), "wait")


class HousekeepingWindow(BackupTestCase):
    """Forget, prune and check run after maintenance, under the backup lock, until 04:10 local."""

    def test_runs_after_maintenance_until_0410(self):
        self.seed()
        record = self.backup.run("nightly")
        events = self.runner.events
        self.assertLess(events.index("maintenance --off"), events.index("restic forget"))
        self.assertEqual(record["housekeeping"]["forget"], "ok")
        self.assertIsNotNone(self.backup.status["last_forget"])
        deadline = self.backup.housekeeping_deadline(self.backup.now())
        self.assertEqual((deadline.astimezone(timezone.utc).hour, deadline.astimezone(timezone.utc).minute), (4, 10))

    def test_deadline_for_runs_at_other_hours_is_bounded(self):
        moment = datetime(2026, 11, 4, 14, 0, tzinfo=timezone.utc)
        self.assertEqual(self.backup.housekeeping_deadline(moment), moment + B.HOUSEKEEPING_MAX)
        late = datetime(2026, 11, 4, 4, 9, tzinfo=timezone.utc)
        self.assertEqual(self.backup.housekeeping_deadline(late), late.replace(minute=10))

    def test_prune_overrunning_0410_is_stopped_and_deferred(self):
        self.seed()
        self.clock.advance(7 * 86400)
        self.runner.hang_housekeeping = True
        record = self.backup.run("nightly")
        self.assertEqual(record["housekeeping"]["forget"], "deferred")
        self.assertIn("docker-stop", self.runner.events)

    def night(self, window_minutes):
        """One 03:30 run whose window takes `window_minutes` of the clock."""
        original = self.runner.exec

        def slow(argv, data, stdout):
            if "pg_dump" in argv:
                self.clock.advance(window_minutes * 60)
            return original(argv, data, stdout)

        self.runner.exec = slow
        try:
            return self.backup.run("nightly")
        finally:
            self.runner.exec = original

    def to_next_0330(self):
        now = datetime.fromtimestamp(self.clock.now, timezone.utc)
        target = now.replace(hour=3, minute=30, second=0, microsecond=0)
        if target <= now:
            target += timedelta(days=1)
        self.clock.now = target.timestamp()

    def test_35_night_probe_housekeeping_runs(self):
        """The reviewer's starvation probe: 35 nights with a 29-minute window. Retention runs every
        night, prune and the check weekly, the read check monthly, and no overdue alert fires."""
        self.seed()
        self.runner.calls.clear()
        for _ in range(35):
            self.to_next_0330()
            record = self.night(29)
            self.assertEqual(record["result"], "success")
        forgets = [call for call in self.runner.calls if B.RESTIC_IMAGE in call and "forget" in call]
        prunes = [call for call in forgets if "--prune" in call]
        checks = [call for call in self.runner.calls if B.RESTIC_IMAGE in call and "check" in call]
        self.assertEqual(len(forgets), 35)
        self.assertGreaterEqual(len(prunes), 5)
        self.assertGreaterEqual(len(checks), 5)
        self.assertNotIn("backup-housekeeping-overdue", self.alerts())
        self.assertEqual(self.backup.overdue(), [])

    def test_35_night_probe_alerts_once_when_housekeeping_cannot_run(self):
        self.seed()
        self.runner.hang_housekeeping = True  # every forget/prune/check is stopped at 04:10
        for night in range(35):
            self.to_next_0330()
            self.night(29)
        self.assertEqual(self.alerts().count("backup-housekeeping-overdue"), 1)
        self.assertIn("forget", self.backup.overdue())
        self.assertIn("forget", self.backup.report()["housekeeping"]["overdue"])
        # Once it runs again, the episode closes and a later one alerts again.
        self.runner.hang_housekeeping = False
        self.to_next_0330()
        self.night(5)
        self.assertNotIn("overdue_alerted", self.backup.status)


class Drills(unittest.TestCase):
    """The VM host-side rebuild-and-restore orchestration against a model of spec #21's halo-vm.sh."""

    def setUp(self):
        self.temp = Path(tempfile.mkdtemp(prefix="anj-drill-test-"))
        self.calls = []
        self.vm = HaloVmModel(self.temp / "state" / "run-id", self.calls)
        self.patch = mock.patch.object(B, "QUAL_TAG_FILE", self.vm.tag_file)
        self.patch.start()
        # Spec #21's stage.py resolves the staged commit with git; a fixed one keeps this hermetic.
        from deploy.vm import stage
        resolve = mock.patch.object(stage, "resolve", lambda commit, checkout=None: "f" * 40)
        resolve.start()
        self.addCleanup(resolve.stop)
        self.checks = {"restore_config_sentinel": True, "production_healthcheck": True, "ddns_absent": True,
                       "stack_started_without_haproxy": True}
        test = self

        class Runner:
            def run(self, argv, *, data=None, timeout=600, stdout=None, check=True):
                modelled = test.vm.run(argv)
                test.calls.append(HaloVmModel.strip(argv))
                if modelled is not None:
                    return modelled
                if argv[0] == "ssh" and "drill-checks" in argv[-1]:
                    return Result(json.dumps({"checks": test.checks, "snapshot": "e" * 12}).encode())
                if argv[0] == "ssh" and argv[-1] == B.CLOCK_SYNC_COMMAND:
                    synced = test.clock_answers.pop(0) if test.clock_answers else "yes"
                    return Result(synced.encode() + b"\n")
                if argv[0] == "ssh" and argv[-1] == B.DRILL_SHARE_MOUNT:
                    return Result(returncode=test.mount_exit)
                return Result()

            def pipe(self, producer, consumer, *, timeout=300):
                test.calls.append(["PIPE", producer, consumer])
                return True

        self.runner = Runner()
        self.clock_answers = []
        self.mount_exit = 0
        self.slept = []

    def tearDown(self):
        self.patch.stop()
        shutil.rmtree(self.temp, ignore_errors=True)

    def drill(self, hour=10, minute=0, **options):
        moment = datetime(2026, 11, 4, hour, minute).astimezone().timestamp()
        options.setdefault("sleep", self.slept.append)
        return B.Drill(self.runner, halo_vm="/opt/halo-vm.sh", evidence_base=self.temp, clock=lambda: moment,
                       **options).run()

    def ssh_commands(self):
        return [call[-1] for call in self.calls if call[0] == "ssh"]

    def test_waits_for_clock_sync_then_mounts_the_share_read_only_before_setup(self):
        """SC-067: the bootstrap's preflight refuses an unsynchronized clock, and the guest's fstab
        mounts the read-only export rw; the drill waits for NTP and mounts the share ro first."""
        self.clock_answers = ["no", "no", "yes"]
        receipt = self.drill()
        self.assertEqual(receipt["result"], "pass")
        self.assertEqual(receipt["clock_sync_polls"], 3)
        self.assertTrue(receipt["share_mounted_read_only"])
        self.assertEqual(self.slept, [B.CLOCK_SYNC_INTERVAL] * 2)
        commands = self.ssh_commands()
        setup = next(i for i, c in enumerate(commands) if "--restore-from" in c)
        clock = [i for i, c in enumerate(commands) if c == B.CLOCK_SYNC_COMMAND]
        mount = commands.index(B.DRILL_SHARE_MOUNT)
        self.assertEqual(len(clock), 3)
        self.assertLess(clock[-1], mount)
        self.assertLess(mount, setup)
        self.assertIn("mount -t virtiofs -o ro,", B.DRILL_SHARE_MOUNT)
        self.assertIn("remount,ro", B.DRILL_SHARE_MOUNT)
        self.assertIn("grep -qx ro", B.DRILL_SHARE_MOUNT)

    def share_mount_world(self, *, mounted, directory_exists):
        """DRILL_SHARE_MOUNT run by a real shell against stand-in sudo/findmnt/mount/install that
        log their calls (PR #90 review L1)."""
        root = Path(tempfile.mkdtemp(prefix="anj-mount-", dir=self.temp))
        bin_dir, mount, state, log = root / "bin", root / "mnt" / "anj-backup", root / "state", root / "log"
        bin_dir.mkdir()
        if directory_exists:
            mount.mkdir(parents=True)
        if mounted:
            state.write_text("rw,nosuid,nodev,noexec\n")
        scripts = {
            "sudo": 'exec "$@"',
            "findmnt": f'echo "findmnt $*" >> {log}; [ -f {state} ] || exit 1; '
                       f'case "$*" in *OPTIONS*) cat {state};; esac',
            "mount": f'echo "mount $*" >> {log}; echo "ro,nosuid,nodev,noexec" > {state}',
            "install": f'echo "install $*" >> {log}; mkdir -p "$4"',
        }
        for name, body in scripts.items():
            (bin_dir / name).write_text("#!/bin/sh\n" + body + "\n")
            (bin_dir / name).chmod(0o755)
        command = B.drill_share_mount(mount=mount)
        result = subprocess.run(["bash", "-c", command], env={"PATH": f"{bin_dir}:/usr/bin:/bin"},
                                capture_output=True, timeout=30, check=False)
        calls = log.read_text().splitlines() if log.exists() else []
        return result.returncode, calls, mount

    def test_drill_share_mount_never_chmods_a_mounted_share_root(self):
        code, calls, mount = self.share_mount_world(mounted=True, directory_exists=True)
        self.assertEqual(code, 0)
        self.assertFalse([call for call in calls if call.startswith("install")])
        self.assertIn(f"mount -o remount,ro {mount}", calls)
        code, calls, mount = self.share_mount_world(mounted=False, directory_exists=True)
        self.assertEqual(code, 0)
        self.assertFalse([call for call in calls if call.startswith("install")])
        self.assertIn(f"mount -t virtiofs -o ro,nodev,nosuid,noexec {B.paths.BACKUP_TAG} {mount}", calls)
        code, calls, mount = self.share_mount_world(mounted=False, directory_exists=False)
        self.assertEqual(code, 0)
        self.assertEqual([call for call in calls if call.startswith("install")], [f"install -d -m 0755 {mount}"])
        self.assertLess(calls.index(f"install -d -m 0755 {mount}"),
                        next(i for i, call in enumerate(calls) if call.startswith("mount -t virtiofs")))

    def test_drill_share_mount_fails_when_ro_is_not_in_effect(self):
        root = Path(tempfile.mkdtemp(prefix="anj-mount-", dir=self.temp))
        bin_dir = root / "bin"
        bin_dir.mkdir()
        for name, body in {"sudo": 'exec "$@"', "findmnt": 'case "$*" in *OPTIONS*) echo rw,relatime;; esac',
                           "mount": "true", "install": "true"}.items():
            (bin_dir / name).write_text("#!/bin/sh\n" + body + "\n")
            (bin_dir / name).chmod(0o755)
        result = subprocess.run(["bash", "-c", B.drill_share_mount(mount=root / "m")],
                                env={"PATH": f"{bin_dir}:/usr/bin:/bin"}, capture_output=True, timeout=30)
        self.assertNotEqual(result.returncode, 0)

    def test_clock_that_never_syncs_fails_clearly_bounded_and_destroys(self):
        self.clock_answers = ["no"] * 1000
        receipt = self.drill(clock_sync_timeout=60)
        self.assertEqual((receipt["result"], receipt["reason"]), ("failed", "clock-unsynced"))
        self.assertIn("not synchronized within 60 s", receipt["error"])
        self.assertEqual(sum(1 for c in self.ssh_commands() if c == B.CLOCK_SYNC_COMMAND), 60 // B.CLOCK_SYNC_INTERVAL + 1)
        self.assertEqual(sum(self.slept), 60)
        self.assertFalse(any("--restore-from" in c for c in self.ssh_commands()))
        self.assertFalse(any(call[0] == "PIPE" for call in self.calls))  # the password never moved
        self.assertTrue(receipt["qual_destroyed"])
        self.assertEqual(self.vm.objects, set())

    def test_share_that_will_not_mount_read_only_stops_before_setup(self):
        self.mount_exit = 1
        receipt = self.drill()
        self.assertEqual((receipt["result"], receipt["reason"]), ("failed", "share-mount-failed"))
        self.assertFalse(any("--restore-from" in c for c in self.ssh_commands()))
        self.assertTrue(receipt["qual_destroyed"])

    def halo_calls(self, flag):
        return [call for call in self.calls if call[0] == "/opt/halo-vm.sh" and call[1] == flag]

    def test_rebuild_restore_check_destroy_unattended(self):
        receipt = self.drill()
        self.assertEqual(receipt["result"], "pass")
        run_id = receipt["run_id"]
        self.assertEqual(self.halo_calls("--qual"), [["/opt/halo-vm.sh", "--qual", "--run-id", run_id, "--share-readonly"]])
        self.assertEqual(self.halo_calls("--qual-destroy"), [["/opt/halo-vm.sh", "--qual-destroy", "--run-id", run_id]])
        commands = [" ".join(call) if call[0] != "PIPE" else "PIPE" for call in self.calls if call[0] != "virsh"]
        self.assertIn("sudo /var/lib/anj-cloud-setup/src/deploy/vm/anj-cloud-setup --restore-from /mnt/anj-backup "
                      "--answers", " ".join(commands))  # spec #21's staged bootstrap (deploy/vm/stage.py)
        self.assertEqual(receipt["commands"]["staged_commit"], "f" * 12)
        self.assertIn(f"python3 -I {B.paths.RELEASE_CURRENT}/deploy/backup.py drill-checks", " ".join(commands))
        self.assertLess(commands.index("PIPE"), next(i for i, c in enumerate(commands) if "--restore-from" in c))
        for call in self.calls:
            self.assertNotIn("-t", call)      # unattended: no TTY anywhere
            self.assertNotIn("--force", call)  # never an operator override
        for call in self.calls:
            if call[0] == "ssh":
                self.assertEqual(call[1:3], ["-F", str(B.HALO_SSH_CONFIG)])  # B1's aliases
        self.assertIn('ddns = "off"', B.DRILL_ANSWERS)
        self.assertIn("start_stack = false", B.DRILL_ANSWERS)
        self.assertIn("data_disk_init = true", B.DRILL_ANSWERS)  # the blank drill data disk (spec #21 no-format rule)
        self.assertEqual(B.DRILL_APPS, ("db", "redis", "nextcloud", "cron", "gateway"))
        self.assertTrue(receipt["qual_destroyed"] and receipt["prod_untouched"])
        self.assertEqual(self.vm.objects, set())

    def test_password_moves_by_pipe_from_anj_prod(self):
        self.drill()
        pipe = next(call for call in self.calls if call[0] == "PIPE")
        self.assertEqual(pipe[1], ["ssh", "-F", str(B.HALO_SSH_CONFIG), "-T", "-o", "BatchMode=yes", "anj-prod",
                                   f"sudo cat {B.paths.RESTIC_PASSWORD}"])
        self.assertEqual(pipe[2][:7], ["ssh", "-F", str(B.HALO_SSH_CONFIG), "-T", "-o", "BatchMode=yes", "anj-qual"])
        self.assertIn(f"install -m 600 -o {B.paths.VM_USER} -g {B.paths.VM_GROUP} /dev/stdin {B.DRILL_PASSWORD}",
                      pipe[2][-1])

    def test_real_pipe_never_surfaces_the_password(self):
        """Runner.pipe with real processes: the secret reaches the destination file only, not this
        process's stdout or stderr, an argument, or the receipt."""
        secret = "drill-secret-" + "q" * 32
        source = self.temp / "source"
        source.write_text(secret + "\n")
        source.chmod(0o600)
        destination = self.temp / "destination"
        captured = self.temp / "captured"
        with open(captured, "w+") as sink:
            saved = os.dup(1), os.dup(2)
            os.dup2(sink.fileno(), 1)
            os.dup2(sink.fileno(), 2)
            try:
                ok = B.Runner().pipe(["cat", str(source)], ["sh", "-c", f"umask 077; cat > {destination}"])
            finally:
                os.dup2(saved[0], 1)
                os.dup2(saved[1], 2)
        self.assertTrue(ok)
        self.assertEqual(destination.read_text().strip(), secret)
        self.assertNotIn(secret, captured.read_text())
        receipt = self.drill(password_source=["cat", str(source)])
        self.assertNotIn(secret, Path(receipt["receipt"]).read_text())
        self.assertFalse(any(secret in " ".join(map(str, call)) for call in self.calls))

    def test_failed_check_fails_and_still_destroys(self):
        self.checks["production_healthcheck"] = False
        receipt = self.drill()
        self.assertEqual((receipt["result"], receipt["failed_checks"]), ("failed", ["production_healthcheck"]))
        self.assertEqual(self.vm.objects, set())

    def test_existing_anj_qual_is_refused_before_anything_is_touched(self):
        for description in ("someone-else", None):  # another run's VM, and an untagged one
            with self.subTest(description=description):
                self.vm.objects = {"domain", "net", "pool"}
                self.vm.description = description
                self.calls.clear()
                with self.assertRaises(B.BackupError) as raised:
                    self.drill()
                self.assertEqual(raised.exception.reason, "qual-busy")
                self.assertEqual(self.vm.objects, {"domain", "net", "pool"})
                self.assertFalse([call for call in self.calls if call[0] != "virsh"])

    def test_a_qual_exit_3_with_a_foreign_untagged_vm_destroys_nothing(self):
        """(a) Another run defines anj-qual between our check and our --qual; halo-vm.sh exits 3."""
        self.vm.foreign_appears = ""  # untitled, no tag file: as a concurrent run mid-create
        receipt = self.drill()
        self.assertEqual(self.halo_calls("--qual-destroy"), [])
        self.assertEqual(self.vm.objects, {"domain", "net", "pool"})
        self.assertFalse(receipt["qual_destroyed"])
        self.assertIn("qual-busy", receipt["qual_destroy_issue"])
        self.assertEqual((receipt["result"], receipt["reason"]), ("failed", "qual-busy"))
        self.assertTrue(Path(receipt["receipt"]).exists())

    def test_b_another_runs_id_is_never_destroyed(self):
        """(b) Our --qual exits 3 because a VM with another run's id appeared: it is reported, not touched."""
        self.vm.foreign_appears = "drill-other-run"
        receipt = self.drill()
        self.assertEqual(self.halo_calls("--qual-destroy"), [])
        self.assertEqual(receipt["qual_owner"], "drill-other-run")
        self.assertEqual(self.vm.objects, {"domain", "net", "pool"})

    def test_c_untagged_vm_present_after_our_create_is_left(self):
        """(c) Our --qual fails before writing a tag, and an untagged anj-qual is present."""
        original = self.runner.run

        def refused(argv, **kwargs):
            if argv[1:2] == ["--qual"]:
                self.calls.append(argv)
                self.vm.objects = {"domain"}  # someone else's, untitled
                return Result(returncode=1)
            return original(argv, **kwargs)

        self.runner.run = refused
        receipt = self.drill()
        self.assertEqual(self.halo_calls("--qual-destroy"), [])
        self.assertEqual(receipt["qual_destroy_issue"], "anj-qual carries no run id")
        self.assertEqual(self.vm.objects, {"domain"})
        self.assertEqual(receipt["result"], "failed")

    def test_our_partial_create_is_cleaned_up_by_run_id(self):
        """--qual wrote our tag and the network, then failed: destroyed through --run-id, receipt written."""
        self.vm.fail_after_tag = True
        receipt = self.drill()
        run_id = receipt["run_id"]
        self.assertEqual(self.halo_calls("--qual-destroy"), [["/opt/halo-vm.sh", "--qual-destroy", "--run-id", run_id]])
        self.assertEqual(self.vm.objects, set())
        self.assertFalse(self.vm.tag_file.exists())
        self.assertTrue(receipt["qual_destroyed"])
        self.assertEqual((receipt["result"], receipt["reason"]), ("failed", "qual-create-failed"))
        self.assertTrue(Path(receipt["receipt"]).exists())
        self.vm.fail_after_tag = False
        self.assertEqual(self.drill()["result"], "pass")  # the next drill is not refused

    def test_our_create_that_times_out_is_cleaned_up_by_run_id(self):
        original = self.runner.run

        def slow(argv, **kwargs):
            if argv[1:2] == ["--qual"]:
                original(argv, **kwargs)  # the VM was fully created...
                raise subprocess.TimeoutExpired("halo-vm.sh", 1800)  # ...but --qual did not return in time
            return original(argv, **kwargs)

        self.runner.run = slow
        receipt = self.drill()
        self.assertTrue(receipt["qual_destroyed"])
        self.assertEqual(self.vm.objects, set())

    def test_destroy_refused_by_halo_vm_is_recorded(self):
        original = self.runner.run

        def swapped(argv, **kwargs):
            if argv[0] == "ssh" and "drill-checks" in argv[-1]:
                self.vm.tag_file.write_text("drill-other-run\n")  # halo-vm.sh's record changed mid-run
                self.vm.description = "drill-other-run"
            return original(argv, **kwargs)

        self.runner.run = swapped
        receipt = self.drill()
        self.assertFalse(receipt["qual_destroyed"])
        self.assertEqual(receipt["qual_owner"], "drill-other-run")
        self.assertEqual(self.halo_calls("--qual-destroy"), [])
        self.assertEqual(receipt["result"], "failed")

    def qual_vm(self):
        qual = B.QualVM(self.runner, "/opt/halo-vm.sh", (), "run-1")
        qual.invoked, qual.qual_exit = True, 0
        return qual

    def test_defined_domain_without_our_description_is_never_ours_even_with_our_tag_file(self):
        """A stale or concurrent tag file naming our run id never makes a defined domain ours."""
        self.vm.objects = {"domain", "net", "pool"}
        self.vm.description = None
        self.vm.tag_file.parent.mkdir(parents=True, exist_ok=True)
        self.vm.tag_file.write_text("run-1\n")
        outcome = self.qual_vm().destroy()
        self.assertEqual((outcome["destroyed"], outcome["reason"]), (False, "anj-qual carries no run id"))
        self.assertEqual(self.halo_calls("--qual-destroy"), [])
        self.vm.description = "someone-else"
        outcome = self.qual_vm().destroy()
        self.assertEqual((outcome["destroyed"], outcome["owner"]), (False, "someone-else"))
        self.assertEqual(self.halo_calls("--qual-destroy"), [])

    def test_description_decides_over_the_tag_file_when_a_domain_exists(self):
        self.vm.objects = {"domain", "net", "pool"}
        self.vm.description = "run-1"
        self.vm.tag_file.parent.mkdir(parents=True, exist_ok=True)
        self.vm.tag_file.write_text("run-1\n")
        self.assertTrue(self.qual_vm().destroy()["destroyed"])

    def test_failing_domain_list_leaves_ownership_unknown_and_destroys_nothing(self):
        """`virsh list --all --name` fails while our tag file names us: no fallback, no destroy."""
        self.vm.objects = {"net", "pool"}  # what a fallback would treat as our partial create
        self.vm.tag_file.parent.mkdir(parents=True, exist_ok=True)
        self.vm.tag_file.write_text("run-1\n")
        self.vm.list_error = True
        outcome = self.qual_vm().destroy()
        self.assertEqual((outcome["destroyed"], outcome["reason"]),
                         (False, "anj-qual ownership unknown (virsh error); nothing destroyed"))
        self.assertEqual(self.halo_calls("--qual-destroy"), [])
        self.assertEqual(self.vm.objects, {"net", "pool"})
        self.vm.list_error = False
        self.assertTrue(self.qual_vm().destroy()["destroyed"])  # once the list succeeds without anj-qual

    def test_failing_dumpxml_of_a_listed_domain_leaves_ownership_unknown(self):
        """A listed domain whose description cannot be read is never ours, whatever the tag file says."""
        self.vm.objects = {"domain", "net", "pool"}
        self.vm.description = "run-1"
        self.vm.tag_file.parent.mkdir(parents=True, exist_ok=True)
        self.vm.tag_file.write_text("run-1\n")
        self.vm.dumpxml_error = True
        outcome = self.qual_vm().destroy()
        self.assertEqual(outcome["destroyed"], False)
        self.assertEqual(self.halo_calls("--qual-destroy"), [])

    def test_a_failing_list_counts_as_present_for_qual_busy(self):
        self.vm.list_error = True
        with self.assertRaises(B.BackupError) as raised:
            self.drill()
        self.assertEqual(raised.exception.reason, "qual-busy")
        self.assertEqual(self.halo_calls("--qual"), [])

    def test_every_virsh_call_runs_in_the_c_locale(self):
        self.drill()
        virsh_calls = [argv for argv in self.vm.raw if "virsh" in argv]
        self.assertTrue(virsh_calls)
        for argv in virsh_calls:
            self.assertEqual(argv[:3], ["env", "LC_ALL=C", "virsh"], argv)

    def test_tag_file_counts_only_without_a_domain(self):
        self.vm.objects = {"net", "pool"}  # partial create: no domain defined
        self.vm.tag_file.parent.mkdir(parents=True, exist_ok=True)
        self.vm.tag_file.write_text("run-1\n")
        self.assertTrue(self.qual_vm().destroy()["destroyed"])
        self.assertEqual(self.halo_calls("--qual-destroy"), [["/opt/halo-vm.sh", "--qual-destroy", "--run-id", "run-1"]])
        self.vm.objects = {"net"}
        self.vm.tag_file.write_text("someone-else\n")
        outcome = self.qual_vm().destroy()
        self.assertEqual((outcome["destroyed"], outcome["owner"]), (False, "someone-else"))

    def test_destroy_that_times_out_is_recorded_not_raised(self):
        original = self.runner.run

        def stuck(argv, **kwargs):
            if argv[1:2] == ["--qual-destroy"]:
                raise subprocess.TimeoutExpired("halo-vm.sh", 1800)
            return original(argv, **kwargs)

        self.runner.run = stuck
        receipt = self.drill()
        self.assertEqual((receipt["qual_destroyed"], receipt["qual_destroy_issue"]), (False, "TimeoutExpired"))
        self.assertTrue(Path(receipt["receipt"]).exists())

    def test_blackout_window_is_refused_before_anything_starts(self):
        for hour, minute in ((3, 20), (3, 45), (4, 59)):
            with self.assertRaisesRegex(B.BackupError, "03:20 and 05:00"):
                self.drill(hour=hour, minute=minute)
        self.assertFalse(any(call[0] == "/opt/halo-vm.sh" for call in self.calls))
        self.assertFalse(B.in_blackout(datetime(2026, 11, 4, 3, 19).astimezone()))
        self.assertTrue(B.in_blackout(datetime(2026, 11, 4, 3, 20).astimezone()))
        self.assertFalse(B.in_blackout(datetime(2026, 11, 4, 5, 0).astimezone()))


class DrillChecksInVm(BackupTestCase):
    """Inside the drill VM: five apps through spec #20's ecosystem (never haproxy), socket client."""

    def test_starts_five_apps_never_haproxy_and_uses_the_socket(self):
        (self.state / "stack.json").write_text(json.dumps({"host": "gateway.example.com",
                                                           "release": "0123456789ab" + "0" * 28}))
        (self.state / "operator").mkdir(mode=0o700)
        (self.state / "operator" / "issuer.crt").write_text("public issuer")
        checks = B.DrillChecks(self.backup)
        started, ready = [], set()

        def run(argv, **kwargs):
            if argv[:2] == ["pm2", "jlist"]:
                return Result(json.dumps([{"name": app, "pm2_env": {"status": "online"}} for app in started]).encode())
            if argv[:2] == ["pm2", "start"]:
                started.append(argv[-1])
                ready.add(B.paths.COMPOSE_SERVICE[argv[-1]])
                return Result()
            if argv[:2] == ["docker", "inspect"]:
                service = argv[-1][len(B.paths.PROJECT) + 1:-2]
                return Result(json.dumps({"Running": service in ready}).encode())
            raise AssertionError(argv)

        with mock.patch.object(self.runner, "run", side_effect=run):
            self.assertTrue(checks.start_stack())
        self.assertEqual(started, list(B.DRILL_APPS))
        self.assertNotIn("haproxy", started)
        ecosystem = self.state / "release" / "0123456789ab" / "ecosystem.config.js"
        client = []
        with mock.patch.object(self.runner, "run", side_effect=lambda argv, **kw: client.append(argv) or Result(b"{}")):
            checks.client("enroll", "--code", "x", state=self.temp)
        argv = client[0]
        self.assertIn("--socket", argv)
        self.assertEqual(argv[argv.index("--socket") + 1], str(B.paths.GATEWAY_SOCKET))
        self.assertNotIn("--connect", argv)
        self.assertEqual(argv[argv.index("--network") + 1], "none")
        self.assertEqual(argv[argv.index("--user") + 1], f"{B.paths.GATEWAY_UID}:{B.paths.GATEWAY_GID}")
        self.assertTrue(str(ecosystem).endswith("release/0123456789ab/ecosystem.config.js"))


class Manifest(BackupTestCase):
    def test_release_config_reads_spec_a_layout(self):
        root = self.temp / "restored"
        (root / "release" / "0123456789ab").mkdir(parents=True)
        (root / "stack.json").write_text(json.dumps({"release": "0123456789ab" + "c" * 28, "host": "gateway.example.com",
                                                     "image_repository": "anj-cloud-prod-access"}))
        (root / "release" / "0123456789ab" / "compose.json").write_text(json.dumps({"services": {"db": {"image": "pg"}}}))
        release = B.release_config(root)
        self.assertEqual(release["host"], "gateway.example.com")
        self.assertEqual(release["access_image"], "anj-cloud-prod-access:0123456789ab")

    def test_capture_records_counts_without_paths(self):
        self.seed()
        self.backup.run("nightly")
        record = self.backup.status["last_success"]
        self.assertEqual(record["filecache_rows"], 5)
        self.assertEqual(record["registry_devices"], 1)
        text = json.dumps(self.backup.report())
        self.assertNotIn("/var/www", text)


if __name__ == "__main__":
    unittest.main()
