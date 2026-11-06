"""Spec #22 rev7 VM rows on the throwaway anj-qual VM: hard cap, encryption at rest, restore drill.

Run on the VM host by the VM host parent (agent-runnable: `halo-vm.sh --qual`/`--qual-destroy` touch only
anj-qual through qemu:///system, spec #21). Nothing here starts a container on the VM host.

    python3 deploy/backup_qualify.py halo --scratch-share <the VM host directory shared to anj-qual> --evidence <dir>

Scratch share (decision #115): the production ownership model. Create it once with
`python3 -I deploy/host/anjvm.py scratch-share create ~/.local/share/anj-cloud/qualification/<name>`:
owned by one of your subordinate uids, mode 0700, so you cannot enter it on the VM host and the VM's anj
reaches it only through the virtiofsd wrapper's uid mapping (halo-vm.sh refuses any other owner).
The VM host-side search below enters it through `anjvm.py share-exec` (an unprivileged user namespace);
`anjvm.py scratch-share remove <dir>` deletes it afterwards.

Phase 1, writable scratch share:
  1. `halo-vm.sh --qual --scratch-share <dir>`;
  2. bootstrap with a qualification answers file (`ddns = "off"`);
  3. in the VM, `backup.py init`, `seed`, then synthetic household files and a paired device;
  4. a nightly run, a capped run (shortened cap and throttle, allowed only on anj-qual), and the
     next run reusing the uploaded data;
  5. from the VM host, an encryption-at-rest search of the scratch repository for the plaintext sentinel,
     file name and app token. The patterns come from the VM over ssh and are never printed.

Phase 2: `backup.py drill` restores the scratch repository into a rebuilt anj-qual, from a
read-only share, with only db, redis, nextcloud, cron and gateway.

Password (decision #95): each phase pipes anj-prod's restic password straight into its own
anj-qual (phase 1 before `init`, so the scratch repository uses it; phase 2 through the drill's
own pipe). It is never read by this process, printed, or written to evidence.

anj-qual: refused (`qual-busy`) when one already exists; each phase's VM is tagged with its run id
and destroyed only by the run that created it.

In-VM commands run from spec #20's release/current (paths.RELEASE_CURRENT), except the first
bootstrap: a fresh anj-qual has no release yet, so spec #21's deploy/vm/stage.py stages this
checkout's HEAD at /var/lib/anj-cloud-setup/src and its anj-cloud-setup installs it.

The flags of B1's `halo-vm.sh` and B2's `anj-cloud-setup` are parameters, recorded in the
evidence; they are spec #21 interfaces that B1 and B2 publish.
"""

import argparse
import contextlib
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import secrets
import sys
import tempfile

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from deploy import backup as B  # noqa: E402
from deploy.vm import paths  # noqa: E402

ANJVM = Path(__file__).resolve().parent / "host" / "anjvm.py"

QUAL_ANSWERS = """# anj-qual backup qualification (spec #22 rev7): never acts as production.
ddns = "off"
alerts_tag = "qualification"
data_disk_init = true
"""


class Halo:
    """The VM host side: create anj-qual, drive the in-VM steps over ssh, search the share, destroy."""

    def __init__(self, runner, *, halo_vm, scratch_share, evidence, ssh_target="anj-qual", stager=None):
        self.runner = runner
        self.stager = stager or B.stage_bootstrap
        self.halo_vm = str(halo_vm)
        self.source = str(paths.RELEASE_CURRENT)
        self.scratch_share = Path(scratch_share)
        self.evidence = Path(evidence)
        self.ssh_target = ssh_target
        self.results = []
        self.password_source = B.ssh_argv("anj-prod", f"sudo cat {paths.RESTIC_PASSWORD}")

    def record(self, name, passed, **detail):
        self.results.append({"check": name, "pass": bool(passed), **detail})
        print(("PASS " if passed else "FAIL ") + name, flush=True)

    def ssh(self, command, *, data=None, timeout=3600):
        # halo-vm.sh's aliases live in its own ssh_config: always through B.ssh_argv (-F).
        return self.runner.run(B.ssh_argv(self.ssh_target, command), data=data, timeout=timeout, check=False)

    def step(self, name, *args):
        result = self.ssh(f"python3 -I {self.source}/deploy/backup_qualify.py vm-step {name} "
                          + " ".join(args), timeout=6 * 3600)
        try:
            return json.loads(result.stdout or b"{}")
        except ValueError:
            return {"error": "unparseable"}

    def phase_one(self):
        run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + secrets.token_hex(3)
        qual = B.QualVM(self.runner, self.halo_vm, ("--scratch-share", str(self.scratch_share)), run_id)
        qual.ensure_free()  # qual-busy: refused before anything is touched
        try:
            qual.create()  # inside the try: a partial create is still destroyed (this run's tag only)
            answers = "/tmp/anj-qual-answers.toml"
            self.ssh(f"umask 077 && cat > {answers}", data=QUAL_ANSWERS.encode(), timeout=60)
            staged = self.stager(self.runner, self.ssh_target)  # spec #21: a fresh VM has no release/current yet
            setup = self.ssh(f"sudo {staged['setup']} --answers {answers}", timeout=3600)
            self.record("bootstrap on anj-qual (ddns off)", setup.returncode == 0)
            B.pipe_password(self.runner, self.password_source, self.ssh_target, paths.RESTIC_PASSWORD)
            prepared = self.step("prepare")
            self.record("init and seed within the cap", prepared.get("seed") == "success", **prepared)
            nightly = self.step("nightly")
            self.record("nightly run: snapshot, size, duration", nightly.get("result") == "success", **nightly)
            capped = self.step("cap")
            self.record("hard cap: restic stopped, maintenance off, marker cleared, one alert",
                        capped.get("result") == "capped" and capped.get("maintenance_off")
                        and capped.get("marker_absent") and capped.get("alerts") == ["backup-cap"], **capped)
            resumed = self.step("resume")
            self.record("next run reuses the uploaded data", resumed.get("result") == "success"
                        and resumed.get("reused") is True, **resumed)
            self.record_encryption()
        finally:
            outcome = qual.destroy()
            self.record("anj-qual destroyed after phase 1", outcome["destroyed"], **outcome)

    def record_encryption(self):
        """Patterns travel VM -> the VM host through a 0600 file in a 0700 directory; never printed."""
        directory = Path(tempfile.mkdtemp(prefix="anj-qual-patterns-"))
        patterns = directory / "patterns"
        try:
            output = self.ssh(f"python3 -I {self.source}/deploy/backup_qualify.py vm-step patterns")
            fd = os.open(patterns, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "wb") as stream:
                stream.write(output.stdout or b"")
            count = len([line for line in patterns.read_bytes().splitlines() if line.strip()])
            # The scratch share belongs to one of the caller's subuids (decision #115): the search
            # runs in a user namespace that maps it (anjvm.py share-exec), never as root.
            # grep: 0 found, 1 searched and not found; anything else (no access) is not a pass.
            code = self.runner.run([sys.executable, "-I", str(ANJVM), "share-exec", str(self.scratch_share), "--",
                                    "grep", "-r", "-a", "-q", "-F", "-f", str(patterns),
                                    str(self.scratch_share / paths.RESTIC_REPOSITORY.name)],
                                   timeout=1800, check=False).returncode
            found, searched = code == 0, code in (0, 1)
            self.record("encryption at rest: no plaintext sentinel, file name or app token in the repository",
                        count == 3 and searched and not found, patterns=count, found=found, searched=searched)
        finally:
            with contextlib.suppress(FileNotFoundError):
                patterns.unlink()
            directory.rmdir()

    def phase_two(self):
        receipt = B.Drill(self.runner, halo_vm=self.halo_vm, ssh_target=self.ssh_target,
                          evidence_base=self.evidence / "drill",
                          qual_args=("--share-readonly", "--scratch-share", str(self.scratch_share)),
                          password_source=self.password_source, stager=self.stager).run()
        self.record("restore drill (rebuild + restore) passes every check; anj-qual destroyed",
                    receipt["result"] == "pass", checks=receipt.get("checks"), receipt=receipt.get("receipt"),
                    error=receipt.get("error"))


# In-VM steps (run over ssh inside anj-qual; print one JSON object) ------------------------

def vm_backup():
    return B.Backup(paths.PROJECT, paths.STATE_ROOT)


def alert_keys(backup, since):
    return [alert["key"] for alert in backup.status.get("alerts", [])[since:]]


def vm_prepare():
    if not B.qualification_vm():
        raise SystemExit("vm-step runs only inside anj-qual")
    backup = vm_backup()
    backup.init()
    seed = backup.run("seed", cap_seconds=20 * 60)
    checks = B.DrillChecks(backup)
    containers = backup.containers()
    sentinel = "ANJ-PLAINTEXT-SENTINEL-" + secrets.token_hex(12)
    name = "anj-plaintext-name-" + secrets.token_hex(6) + ".txt"
    script = ('set -e; d=/var/www/html/data/qual/files/Documents; mkdir -p "$d"; IFS= read -r name; '
              'IFS= read -r text; printf "%s\\n" "$text" > "$d/$name"; '
              'head -c 8388608 /dev/urandom > "$d/random-8m.bin"')
    from deploy.access_operator import Operator
    from deploy.prod import ProdStack
    Operator(ProdStack(paths.PROJECT, paths.STATE_ROOT)).user_add("qual", "Qualification")
    backup.exec("nextcloud", ["sh", "-c", script], user="www-data", data=f"{name}\n{sentinel}\n".encode(),
                containers=containers)
    backup.occ("files:scan", "qual", containers=containers)
    device = checks.synthetic_device()
    patterns = backup.run_dir / "qual-patterns"
    B.atomic_write(patterns, f"{sentinel}\n{name}\n")
    return {"seed": seed["result"], "device": all(device.values())}


def vm_nightly():
    record = vm_backup().run("nightly")
    return B.summary_of(record)


def vm_cap():
    backup = vm_backup()
    containers = backup.containers()
    backup.exec("nextcloud", ["sh", "-c", "head -c 314572800 /dev/urandom > "
                              "/var/www/html/data/qual/files/Documents/random-300m.bin"], user="www-data",
                containers=containers)
    backup.occ("files:scan", "qual", containers=containers)
    since = len(backup.status.get("alerts", []))
    record = backup.run("nightly", cap_seconds=40, limit_upload=4096)
    return dict(B.summary_of(record), alerts=alert_keys(backup, since),
                maintenance_off="disabled" in backup.occ("maintenance:mode", containers=containers),
                marker_absent=not backup.marker_path.exists())


def vm_resume():
    record = vm_backup().run("nightly")
    return dict(B.summary_of(record), reused=record.get("bytes_added") is not None
                and record["bytes_added"] < 0.9 * 314572800)


def vm_patterns():
    """Sentinel, file name and the synthetic device's app token, for the VM host-side search only."""
    backup = vm_backup()
    token = backup.exec("access", ["python", "-c", "import sqlite3;print(sqlite3.connect("
                                   "'file:/var/lib/anj/registry.sqlite?mode=ro',uri=True).execute("
                                   "\"select token from devices where token is not null limit 1\").fetchone()[0])"],
                        user=B.GATEWAY_USER).stdout.decode().strip()
    sys.stdout.write((backup.run_dir / "qual-patterns").read_text() + token + "\n")
    return None


VM_STEPS = {"prepare": vm_prepare, "nightly": vm_nightly, "cap": vm_cap, "resume": vm_resume,
            "patterns": vm_patterns}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    halo = sub.add_parser("halo", help="On the VM host: both phases on anj-qual")
    halo.add_argument("--scratch-share", required=True, help="The VM host directory shared to anj-qual (never DOS_BACKUP)")
    halo.add_argument("--halo-vm", default=str(Path(__file__).resolve().parent / "host" / "halo-vm.sh"))
    halo.add_argument("--evidence", required=True)
    step = sub.add_parser("vm-step", help="Inside anj-qual: one qualification step")
    step.add_argument("name", choices=sorted(VM_STEPS))
    args = parser.parse_args(argv)
    if args.command == "vm-step":
        if not B.qualification_vm():
            raise SystemExit("vm-step runs only inside anj-qual")
        result = VM_STEPS[args.name]()
        if result is not None:
            print(json.dumps(result, sort_keys=True))
        return 0
    if B.in_blackout(datetime.now(timezone.utc)):
        raise SystemExit("Qualification never runs between 03:20 and 05:00")
    if Path(args.scratch_share).resolve() == paths.BACKUP_MOUNT or "DOS_BACKUP" in str(Path(args.scratch_share).resolve()):
        raise SystemExit("--scratch-share must be a scratch directory, never the production share")
    halo = Halo(B.Runner(), halo_vm=args.halo_vm, scratch_share=args.scratch_share, evidence=args.evidence)
    started = datetime.now(timezone.utc).isoformat(timespec="seconds")
    error = None
    try:
        halo.phase_one()
        halo.phase_two()
    except Exception as failure:  # noqa: BLE001
        error = type(failure).__name__
    summary = {"spec": 22, "revision": "rev7", "seat": "anj-qual", "started_at": started, "error": error,
               "results": halo.results, "passed": error is None and all(r["pass"] for r in halo.results),
               "interfaces": {"halo_vm": args.halo_vm, "source": str(paths.RELEASE_CURRENT)}}
    Path(args.evidence).mkdir(parents=True, exist_ok=True)
    (Path(args.evidence) / "summary.json").write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n")
    print(json.dumps({"passed": summary["passed"], "failed": [r["check"] for r in halo.results if not r["pass"]]}))
    return 0 if summary["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
