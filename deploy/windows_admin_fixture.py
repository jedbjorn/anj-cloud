"""Admin and layout on Windows against a review stack.

    ANJ_WIN_OWNER=w6 deploy/.local/access-venv/bin/python -m deploy.windows_admin_fixture \\
        --project anj-cloud-review-w6 --port 18872 --evidence <dir> [--scales 100 150]

Needs a started W10C-Testing lease of this lane with the client pushed, and an `up` review
stack. It starts the stack's console backend and checks that the gateway reaches it, and stops
it afterwards: with it running, the server itself approves a device that redeems a pairing code
(code-only pairing), so this driver never approves by fingerprint. For each display scale it
sets the console session's scaling (display_scale.ps1) and issues a code for Alice. The guest
pairs Alice's device with that code alone; the driver then reads the invitation back, requires
that the server approved it for the fingerprint the device shows, and makes Alice admin (the
recovery CLI over the console socket, as the Linux admin test does). The guest then runs
integration_test/windows_admin_test.dart in the real app window: Bob is invited in the Admin
section, his device pairs with the code alone, he is refused Admin (403), given and denied the
admin role, and his device is revoked, all through the Admin section. A desktop screenshot is taken while
the home screen shows. Each run first withdraws what an earlier run left of Bob (pending
invitations, active devices, the admin role). A run passes only if the guest task ran with
result 0, its log says "All tests passed" and progress.json ends with "done". If the run
outlives its deadline or the driver stops early, the guest task is ended before any cleanup.
Afterwards, each cleanup step runs on its own: the scale is set back to 100 % and read back
as 96 DPI, the devices are revoked, Alice's role is removed, Bob is reset and the guest files
deleted; any failed step fails the run. Codes never enter the evidence.
"""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time

from deploy.dev import FIXTURE_USERS

ROOT = Path(__file__).resolve().parent.parent
CLIENT = ROOT / "apps/client"
SEAT = CLIENT / "tool/windows_seat.sh"
GUEST = r"C:\anj\work\w6"
ALICE, BOB = FIXTURE_USERS
# The guest task's own limit (w6_run.ps1 -Timeout); the driver waits longer, for pub get and
# the build, before it ends the task itself.
RUN_TIMEOUT = 1500
DRIVER_SLACK = 600
TASK = r"\anj\anj-w6-admin"
PENDING = ("issued", "reserved", "provisioning")
HOST = os.environ.get("ANJ_WIN_HOST", "192.168.122.100")
USER = os.environ.get("ANJ_WIN_USER", "Public")
KEY = os.environ.get("ANJ_WIN_KEY", str(Path.home() / ".ssh/sc_win_test"))
KNOWN = os.environ.get("ANJ_WIN_KNOWN_HOSTS",
                       str(Path.home() / "Repos/rst-c/.sc-state/local/vm/W10C-Testing.known_hosts"))
SSH = ["-i", KEY, "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
       "-o", f"UserKnownHostsFile={KNOWN}", "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15"]


def seat(*args, check=True, timeout=600):
    result = subprocess.run([str(SEAT), *args], capture_output=True, text=True, timeout=timeout)
    if check and result.returncode:
        raise RuntimeError(f"seat {args[0]} failed: {result.stdout[-300:]} {result.stderr[-300:]}")
    return result.stdout


def guest_file(name):
    out = seat("ssh", f"if exist {GUEST}\\signal\\{name} type {GUEST}\\signal\\{name}", check=False)
    text = "\n".join(line for line in out.splitlines() if not line.startswith("**"))
    return text.strip() or None


def step(name, ok=True, **facts):
    print(("PASS " if ok else "FAIL ") + name + (f" {json.dumps(facts)}" if facts else ""), flush=True)
    if not ok:
        raise SystemExit(f"step failed: {name}")


def admin_cli(stack, *args):
    socket = stack.local / "console/backend.sock"
    return subprocess.run([str(ROOT / "deploy/.local/access-venv/bin/python"), "-m", "deploy.vm.anj_cloud_admin",
                           "--project", stack.project, "--port", str(stack.port),
                           "--backend-socket", str(socket), "--yes", *args],
                          cwd=ROOT, capture_output=True, text=True, timeout=120)


def run_verdict(code, log, progress):
    """Why a guest run did not pass ([] when it did). The log alone never passes a run: it
    must carry this run's task result 0, and this run's progress.json must end with done."""
    reasons = []
    if code != 0:
        reasons.append(f"guest run exit {code}")
    results = re.findall(r"^W6 TASK RESULT (-?\d+)\s*$", log, re.MULTILINE)
    if not results:
        reasons.append("no task result: the task did not run to completion")
    elif results[-1] != "0":
        reasons.append(f"task result {results[-1]}")
    if "All tests passed" not in log:
        reasons.append("the log does not say All tests passed")
    try:
        events = json.loads(progress) if progress else None
    except ValueError:
        events = None
    last = events[-1].get("claim") if isinstance(events, list) and events and isinstance(events[-1], dict) else None
    if last != "done":
        reasons.append(f"progress.json ends with {last!r}, not 'done'")
    return reasons


def wait_backend(operator, process, timeout=60, clock=time.monotonic, sleep=time.sleep):
    """Wait until the gateway reports the console backend this run started as ready."""
    deadline = clock() + timeout
    while clock() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"console backend exited ({process.returncode})")
        if operator.call("status").get("backend") == "ready":
            print("PASS console backend ready behind the gateway", flush=True)
            return
        sleep(1)
    raise RuntimeError("the gateway does not reach the console backend")


def stop_console_backend(process, socket, timeout=15):
    """Stop the console backend this run started and prove it: the process has exited and its
    socket is gone (the backend removes it on SIGTERM). Raises otherwise."""
    process.terminate()
    try:
        process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=10)
    if process.poll() is None:
        raise RuntimeError("console backend still running")
    if socket.exists() or socket.is_symlink():
        raise RuntimeError(f"console backend socket left behind (exit {process.returncode})")
    print(f"console backend stopped (exit {process.returncode}), socket removed", flush=True)


def paired_device(operator, invitation, fingerprint):
    """The device the server approved for this invitation when its code was redeemed. Raises unless
    the invitation is approved, for the fingerprint the device itself shows, with a device."""
    row = next((row for row in operator.call("pending") if row.get("id") == invitation), None)
    if row is None:
        raise RuntimeError("the invitation is not listed")
    if row.get("state") != "approved":
        raise RuntimeError(f"the server has not approved the device (invitation {row.get('state')})")
    if not fingerprint or row.get("fingerprint") != fingerprint:
        raise RuntimeError("the approved device is not the one the guest shows")
    if not row.get("device"):
        raise RuntimeError("the approved invitation names no device")
    return row["device"]


def stop_guest_task():
    """End the guest test task and its app before the driver cleans up behind it."""
    out = seat("ssh", f'schtasks /End /TN "{TASK}" & taskkill /F /T /IM anj_cloud.exe', check=False)
    print("guest task ended: " + " ".join(out.split())[-200:], flush=True)


def reset_user(operator, cli, uid):
    """Withdraw what an earlier run left of `uid` on the stack: its pending invitations are
    denied, its active devices revoked and its admin role removed. Raises unless the stack
    then shows none of them."""
    for row in operator.call("pending"):
        if row.get("uid") == uid and row.get("state") in PENDING:
            operator.call("deny", pairing_id=row["id"])
    for row in operator.call("devices"):
        if row.get("uid") == uid and row.get("state") == "active":
            operator.revoke(row["id"])
    cli("admin-remove", uid)  # Fails harmlessly when not an admin; checked below.
    admins = cli("admins")
    left = [row["id"] for row in operator.call("pending") if row.get("uid") == uid and row.get("state") in PENDING]
    left += [row["id"] for row in operator.call("devices") if row.get("uid") == uid and row.get("state") == "active"]
    if admins.returncode or uid in json.loads(admins.stdout or "[]") or left:
        raise RuntimeError(f"{uid} not reset: admin listing exit {admins.returncode}, {len(left)} rows left")
    print(f"{uid} reset: no pending invitation, no active device, not an admin", flush=True)


def remove_admin(cli, uid):
    """Remove `uid`'s admin role. The server keeps the last admin (409 last-admin): then `uid`
    stays the only admin of the disposable stack, which is torn down after the run."""
    removed = cli("admin-remove", uid)
    admins = cli("admins")
    listed = json.loads(admins.stdout or "[]") if not admins.returncode else None
    if listed is None or uid in listed and listed != [uid]:
        raise RuntimeError(f"{uid} still an admin (remove exit {removed.returncode})")
    print(f"{uid}: " + ("kept as the stack's last admin" if uid in listed else "admin role removed"), flush=True)


def restore_scale(run=None):
    """Set the console scale back to 100 % and read it back: passes only at 96 DPI."""
    run = run or (lambda: subprocess.run([str(SEAT), "ps", str(CLIENT / "tool/windows/display_scale.ps1"),
                                          "-Percent", "100"], capture_output=True, text=True, timeout=180))
    result = run()
    found = re.findall(r"effective dpi (\d+)", result.stdout)
    if result.returncode or not found or found[-1] != "96":
        raise RuntimeError(f"scale not restored: exit {result.returncode}, effective dpi {found[-1] if found else 'unread'}")
    print("Scale restored to 100 % (effective DPI 96)", flush=True)


def cleanup(steps):
    """Run every step on its own; one that raises never skips the rest. Returns the failed names."""
    failed = []
    for name, action in steps:
        try:
            action()
            print(f"PASS cleanup: {name}", flush=True)
        except BaseException as error:  # Report, keep cleaning; SystemExit too.
            failed.append(name)
            print(f"FAIL cleanup: {name}: {type(error).__name__}: {str(error)[-200:]}", flush=True)
    return failed


def run_scale(stack, operator, scale, evidence, devices):
    out = evidence / f"scale-{scale}"
    out.mkdir(parents=True, exist_ok=True)
    # An earlier, failed run may have left Bob invited, paired or admin.
    reset_user(operator, lambda *args: admin_cli(stack, *args), BOB)
    print(seat("ps", str(CLIENT / "tool/windows/display_scale.ps1"), "-Percent", str(scale)).strip(), flush=True)
    invite = operator.call("invite", uid=ALICE, rights="write")
    config = {"origin": stack.origin, "ca": GUEST + r"\issuer.crt", "code_alice": invite["code"],
              "work": GUEST + r"\run", "signal": GUEST + r"\signal", "scale": scale}
    work = Path(tempfile.mkdtemp(prefix="anj-w6-"))
    try:
        (work / "config.json").write_text(json.dumps(config))
        seat("ssh", f"if exist {GUEST} rmdir /s /q {GUEST}")
        seat("ssh", f"mkdir {GUEST}\\signal")
        for local, name in ((work / "config.json", "config.json"), (stack.local / "operator/issuer.crt", "issuer.crt")):
            subprocess.run(["scp", "-q", *SSH, str(local), f"{USER}@{HOST}:{GUEST.replace(chr(92), '/')}/{name}"],
                           check=True, timeout=120)
    finally:
        for item in work.iterdir():
            item.unlink()
        work.rmdir()
    runner = subprocess.Popen([str(SEAT), "ps", str(CLIENT / "tool/windows/w6_run.ps1"), "-Timeout", str(RUN_TIMEOUT)],
                              stdout=(out / "guest-run.txt").open("w"), stderr=subprocess.STDOUT)
    deadline = time.monotonic() + RUN_TIMEOUT + DRIVER_SLACK
    paired = shot = False
    try:
        while runner.poll() is None and time.monotonic() < deadline:
            if not paired and (shown := guest_file("fingerprint-alice.json")):
                # The guest writes this once its device is paired by the code alone.
                devices.append(paired_device(operator, invite["id"], json.loads(shown)["fingerprint"]))
                step(f"{scale}%: the server approved Alice's device for the code")
                granted = admin_cli(stack, "admin-grant", ALICE)
                step(f"{scale}%: Alice made admin", ok=granted.returncode == 0 or "already" in granted.stderr,
                     cli=granted.returncode)
                paired = True
            if paired and not shot and "home shown" in (guest_file("progress.json") or ""):
                # Evidence only: a failed desktop capture must not end the run.
                taken = subprocess.run([str(SEAT), "screenshot", str(out / f"desktop-{scale}.png")],
                                       capture_output=True, text=True, timeout=120)
                if taken.returncode:
                    print(f"WARN desktop screenshot failed ({taken.returncode}): {taken.stderr.strip()[-200:]}", flush=True)
                shot = True
            time.sleep(2)
    finally:
        if runner.poll() is None:
            # Past the deadline, or the driver stopped early: end the guest test before any
            # cleanup runs behind it.
            print(f"WARN {scale}%: the guest run is still going; ending it", flush=True)
            stop_guest_task()
            runner.terminate()
            try:
                runner.wait(timeout=60)
            except subprocess.TimeoutExpired:
                runner.kill()
                runner.wait(timeout=10)
    code = runner.returncode
    log = (out / "guest-run.txt").read_text(encoding="utf-8", errors="replace")  # Windows tools mix in OEM bytes
    print(seat("pull", GUEST + r"\signal", str(out / "signal"), check=False).strip()[-300:], flush=True)
    (out / "signal" / "config.json").unlink(missing_ok=True)
    progress = out / "signal" / "progress.json"
    reasons = run_verdict(code, log, progress.read_text(encoding="utf-8", errors="replace") if progress.exists() else None)
    step(f"{scale}%: the Windows Admin test ran", ok=not reasons, why=reasons,
         tail=log.strip().splitlines()[-3:] if log.strip() else [])

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--scales", type=int, nargs="+", default=[100, 150])
    args = parser.parse_args()
    if not args.project.startswith("anj-cloud-review-"):
        raise SystemExit("Use a disposable anj-cloud-review-<tag> stack.")
    from deploy.access_operator import Operator  # The issuer's crypto: the access venv only.
    from deploy.dev import Stack
    args.evidence.mkdir(parents=True, exist_ok=True)
    stack = Stack(args.project, args.port)
    stack.check()
    stack.accounts()
    operator = Operator(stack)
    devices, forward = [], None

    backend = None

    def start_backend():
        # Approve and the Nextcloud-side work behind the Admin section run in the console
        # backend; the gateway reaches it through deploy/.local/<project>/console.
        nonlocal backend
        socket = stack.local / "console/backend.sock"
        backend = subprocess.Popen([str(ROOT / "deploy/.local/access-venv/bin/python"), "-m", "deploy.vm.console_backend",
                                    "--project", stack.project, "--port", str(stack.port), "--socket", str(socket)],
                                   cwd=ROOT, stdout=(args.evidence / "console-backend.txt").open("w"),
                                   stderr=subprocess.STDOUT)
        wait_backend(operator, backend)

    def stop_backend():
        if backend is not None:
            stop_console_backend(backend, stack.local / "console/backend.sock")

    def stop_forward():
        if forward is None:
            return
        forward.terminate()
        try:
            forward.wait(timeout=10)
        except subprocess.TimeoutExpired:
            forward.kill()
            forward.wait(timeout=10)

    def revoke_devices():
        errors = []
        for device in devices:
            try:
                operator.revoke(device)
            except Exception as error:  # Report, keep revoking.
                errors.append(f"{device[:8]}: {error}")
        if errors:
            raise RuntimeError("; ".join(errors))

    def remove_alice_admin():
        remove_admin(lambda *a: admin_cli(stack, *a), ALICE)

    def remove_guest_files():
        seat("ssh", f"if exist {GUEST} rmdir /s /q {GUEST}")

    completed = False
    try:
        start_backend()
        forward = subprocess.Popen(["ssh", *SSH, "-N", "-o", "ExitOnForwardFailure=yes",
                                    "-R", f"127.0.0.1:{args.port}:127.0.0.1:{args.port}", f"{USER}@{HOST}"])
        time.sleep(3)
        if forward.poll() is not None:
            raise RuntimeError("reverse forward did not start")
        for scale in args.scales:
            run_scale(stack, operator, scale, args.evidence, devices)
        completed = True
    finally:
        failed = cleanup([
            ("scale restored to 100 % (96 DPI)", restore_scale),
            ("reverse forward stopped", stop_forward),
            ("devices revoked", revoke_devices),
            (f"{ALICE} admin role removed (or the last admin)", remove_alice_admin),
            (f"{BOB} reset", lambda: reset_user(operator, lambda *a: admin_cli(stack, *a), BOB)),
            ("operator journals reconciled", operator.reconcile),
            ("console backend stopped", stop_backend),
            ("guest files removed", remove_guest_files),
        ])
        if failed and completed:
            raise SystemExit("cleanup incomplete: " + ", ".join(failed))

if __name__ == "__main__":
    sys.exit(main())
