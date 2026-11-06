"""The macOS UI and Admin checks on mac-test against a review stack (spec #31 M5, acceptance row 16).

    deploy/.local/access-venv/bin/python -m deploy.macos_admin_fixture \\
        --project anj-cloud-review-m5 --port 18876 --task LANE1/m5-1 --evidence <dir>

Needs an `up` review stack and the client source already sent to mac-test:~/work/<task>
(tool/macos/mac_test.sh send). It starts the stack's console backend (approve needs it) and checks
that the gateway reaches it, opens the reverse forward with plain `ssh -R` (mac-test
127.0.0.1:<port> -> this stack;
the dev certificate names 127.0.0.1, so hostname verification stays on) and checks it from the
guest, then resets the fixture users (Bob: no pending invitation, no active device, not an admin;
Alice: no pending invitation and no active device) and invites Alice. tool/macos/check_m5.sh then
runs integration_test/macos_ui_test.dart in the real app from a gui/<uid> job: the macOS
conventions, then the Admin flow. Alice's code is a pinned one (spec #35): the app fetches the CA,
checks it against the code and the gateway approves the device at once (through the console
backend). When the app reports Alice paired, this driver makes her admin through the recovery CLI
over the console socket, as the Linux and Windows Admin tests do.

A run passes only if the guest command returned 0, its log carries this run's "M5 GUI RESULT 0"
and "All tests passed", and both progress files end with "done". If the run outlives its deadline
or the driver stops early, the guest test is ended before any cleanup. Afterwards each cleanup step
runs on its own and any failure fails the run: the guest test is stopped, the reverse forward is
closed, the devices are revoked, Alice's role is removed (or she stays the stack's last admin),
Bob is reset, the operator journals are reconciled, the console backend is stopped and the guest's
run files (with the configuration) are deleted. Pairing codes never enter the evidence: the
configuration is never fetched and the test redacts its progress files.
"""

import argparse
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import time

from deploy import deployment_profile
from deploy.dev import FIXTURE_USERS

ROOT = Path(__file__).resolve().parent.parent
CLIENT = ROOT / "apps/client"
ALICE, BOB = FIXTURE_USERS
HOST = os.environ.get("MAC_TEST_HOST") or deployment_profile.load()["lab"]["mac_test_host"]
# The guest's own limit for the gui job (check_m5.sh --timeout); the driver waits longer, for the
# build, before it ends the run itself. Decision #121: no test run of an hour or more.
RUN_TIMEOUT = 1500
DRIVER_SLACK = 600
PENDING = ("issued", "reserved", "provisioning")
RUN_DIR = "build/m5"  # inside the guest task directory
PINNED_CODE_LENGTH = 28  # 7-byte secret + 10-byte CA pin (decision #153); a legacy code is 32
RC = re.compile(r"^__ANJ_RC=(\d+)$", re.MULTILINE)


def task_dir(task):
    if not re.fullmatch(r"[A-Za-z0-9_-]+/m5(-[A-Za-z0-9._-]+)?", task) or "/." in task:
        raise SystemExit("--task must be <shell>/m5 or <shell>/m5-<name> (owner m5)")
    return f"work/{task}"


def guest(command, *, data=None, timeout=120):
    """Runs `command` on mac-test; returns (status, output). tailscale ssh always exits 0, so the
    remote status travels as a last-line marker (as in tool/macos/mac_test.sh)."""
    result = subprocess.run(["tailscale", "ssh", HOST, command + '; printf "\\n__ANJ_RC=%s\\n" "$?"'],
                            input=data, capture_output=True, text=True, timeout=timeout)
    found = RC.findall(result.stdout)
    output = RC.sub("", result.stdout).strip()
    return (int(found[-1]) if found else 255), output


def known_hosts_lines(status, host):
    """known_hosts lines for `host` from `tailscale status --json`: the SSH host keys the
    coordination server advertises for that node, the check the `tailscale ssh` wrapper makes."""
    name = host.split("@")[-1]
    for peer in (status.get("Peer") or {}).values():
        dns = peer.get("DNSName", "").rstrip(".")
        if dns.split(".")[0] == name or dns == name:
            names = ",".join([name, dns, *peer.get("TailscaleIPs", [])])
            keys = peer.get("sshHostKeys") or []
            if keys:
                return [f"{names} {key}" for key in keys]
    raise RuntimeError(f"no advertised SSH host key for {name}")


def forward_command(port, known_hosts):
    """The reverse forward: a plain ssh client to the guest's Tailscale SSH server, which accepts
    -R (spec #31, mac-test facts; the `tailscale ssh` wrapper rejects options). The host key is
    checked strictly against the keys Tailscale advertises (a run-private known_hosts)."""
    return ["ssh", "-N", "-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=15",
            "-o", "StrictHostKeyChecking=yes", "-o", f"UserKnownHostsFile={known_hosts}",
            "-R", f"127.0.0.1:{port}:127.0.0.1:{port}", HOST]


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


def last_claim(progress):
    try:
        events = json.loads(progress) if progress else None
    except ValueError:
        return None
    if isinstance(events, list) and events and isinstance(events[-1], dict):
        return events[-1].get("claim")
    return None


def run_verdict(code, log, progress, *, admin=True):
    """Why a guest run did not pass ([] when it did). The log alone never passes a run: it must
    carry this run's result line, 0, and this run's progress files must end with done."""
    reasons = []
    if code != 0:
        reasons.append(f"guest run exit {code}")
    results = re.findall(r"^M5 GUI RESULT (-?\d+)\s*$", log, re.MULTILINE)
    if not results:
        reasons.append("no result line: the gui job did not run to completion")
    elif results[-1] != "0":
        reasons.append(f"gui job result {results[-1]}")
    if "All tests passed" not in log:
        reasons.append("the log does not say All tests passed")
    for name in ("ui", "admin") if admin else ("ui",):
        last = last_claim(progress.get(name))
        if last != "done":
            reasons.append(f"{name}-progress.json ends with {last!r}, not 'done'")
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


def stop_process(process, timeout=15):
    if process is None:
        return
    process.terminate()
    try:
        process.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=10)


def stop_console_backend(process, socket, timeout=15):
    """Stop the console backend this run started and prove it: the process has exited and its
    socket is gone (the backend removes it on SIGTERM). Raises otherwise."""
    stop_process(process, timeout)
    if process.poll() is None:
        raise RuntimeError("console backend still running")
    if socket.exists() or socket.is_symlink():
        raise RuntimeError(f"console backend socket left behind (exit {process.returncode})")
    print(f"console backend stopped (exit {process.returncode}), socket removed", flush=True)


def reset_user(operator, cli, uid, *, role=True):
    """Withdraw what an earlier run left of `uid` on the stack: its pending invitations are denied
    and its active devices revoked; with `role`, its admin role is removed. Raises unless the stack
    then shows none of them."""
    for row in operator.call("pending"):
        if row.get("uid") == uid and row.get("state") in PENDING:
            operator.call("deny", pairing_id=row["id"])
    for row in operator.call("devices"):
        if row.get("uid") == uid and row.get("state") == "active":
            operator.revoke(row["id"])
    left = [row["id"] for row in operator.call("pending") if row.get("uid") == uid and row.get("state") in PENDING]
    left += [row["id"] for row in operator.call("devices") if row.get("uid") == uid and row.get("state") == "active"]
    admin = False
    if role:
        cli("admin-remove", uid)  # Fails harmlessly when not an admin; checked below.
        admins = cli("admins")
        admin = bool(admins.returncode) or uid in json.loads(admins.stdout or "[]")
    if left or admin:
        raise RuntimeError(f"{uid} not reset: {len(left)} rows left" + (", still an admin" if admin else ""))
    print(f"{uid} reset: no pending invitation, no active device" + (", not an admin" if role else ""), flush=True)


def remove_admin(cli, uid):
    """Remove `uid`'s admin role. The server keeps the last admin (409 last-admin): then `uid`
    stays the only admin of the disposable stack, which is torn down after the run."""
    removed = cli("admin-remove", uid)
    admins = cli("admins")
    listed = json.loads(admins.stdout or "[]") if not admins.returncode else None
    if listed is None or uid in listed and listed != [uid]:
        raise RuntimeError(f"{uid} still an admin (remove exit {removed.returncode})")
    print(f"{uid}: " + ("kept as the stack's last admin" if uid in listed else "admin role removed"), flush=True)


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


def stop_guest_run(directory):
    """End this run's gui job and its app (only this task directory's), before any cleanup runs
    behind them. check_m5.sh records its job label in build/m5/gui.label."""
    run = shlex.quote(f"{directory}/{RUN_DIR}")
    app = shlex.quote(f"/Users/{HOST.split('@')[0]}/{directory}/build/macos/")
    code, out = guest(
        f'label=$(cat ~/{run}/gui.label 2>/dev/null); '
        f'case "$label" in local.anj-test.gui.[0-9]*) launchctl bootout "gui/$(id -u)/$label" 2>/dev/null ;; esac; '
        f'pkill -f {app} 2>/dev/null; sleep 1; '
        f'! pgrep -f {app} >/dev/null')
    if code != 0:
        raise RuntimeError(f"guest run still going: {out[-200:]}")
    print("guest run stopped (gui job booted out, no app process from this task)", flush=True)


def remove_guest_run_files(directory):
    """Delete the run's files on the guest, the configuration (with Alice's code) first."""
    run = shlex.quote(f"{directory}/{RUN_DIR}")
    code, out = guest(f"rm -f ~/{run}/config.json && rm -rf ~/{run} && ! test -e ~/{run}")
    if code != 0:
        raise RuntimeError(f"guest run files left: {out[-200:]}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--task", required=True, help="guest task directory <shell>/m5[-name]")
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--halo-only", action="store_true",
                        help="only the stack side (backend, forward-free reset and invite, cleanup)")
    args = parser.parse_args()
    if not args.project.startswith("anj-cloud-review-"):
        raise SystemExit("Use a disposable anj-cloud-review-<tag> stack.")
    directory = task_dir(args.task)
    from deploy.access_operator import Operator  # The issuer's crypto: the access venv only.
    from deploy.dev import Stack
    args.evidence.mkdir(parents=True, exist_ok=True)
    stack = Stack(args.project, args.port)
    stack.check()
    stack.accounts()
    operator = Operator(stack)
    cli = lambda *a: admin_cli(stack, *a)  # noqa: E731
    devices = []
    backend = forward = runner = None

    def start_backend():
        # Approve and the Nextcloud-side work behind the Admin section run in the console backend;
        # the gateway reaches it through deploy/.local/<project>/console.
        nonlocal backend
        socket = stack.local / "console/backend.sock"
        backend = subprocess.Popen([str(ROOT / "deploy/.local/access-venv/bin/python"), "-m", "deploy.vm.console_backend",
                                    "--project", stack.project, "--port", str(stack.port), "--socket", str(socket)],
                                   cwd=ROOT, stdout=(args.evidence / "console-backend.txt").open("w"),
                                   stderr=subprocess.STDOUT)
        wait_backend(operator, backend)

    def start_forward():
        nonlocal forward
        status = json.loads(subprocess.run(["tailscale", "status", "--json"], capture_output=True, text=True,
                                           check=True, timeout=30).stdout)
        known = args.evidence / "known_hosts"
        known.write_text("\n".join(known_hosts_lines(status, HOST)) + "\n")
        forward = subprocess.Popen(forward_command(args.port, known),
                                   stdout=(args.evidence / "forward.txt").open("w"), stderr=subprocess.STDOUT)
        for _ in range(10):
            time.sleep(2)
            if forward.poll() is not None:
                raise RuntimeError(f"reverse forward exited ({forward.returncode}); see forward.txt")
            code, _ = guest(f"nc -z -G 3 127.0.0.1 {args.port}")
            if code == 0:
                step("reverse forward: mac-test reaches the stack at 127.0.0.1", port=args.port)
                return
        raise RuntimeError("mac-test does not reach the stack through the reverse forward")

    def send_config(invite):
        run = f"{directory}/{RUN_DIR}"
        # Code-only pairing (spec #35): no CA file; the app fetches /v1/ca and checks the code's pin.
        if len(invite["code"].replace("-", "")) != PINNED_CODE_LENGTH:
            raise RuntimeError("the stack issued a legacy (unpinned) code; code-only pairing needs a pinned one")
        code, out = guest(f"umask 077 && rm -rf ~/{run} && mkdir -p ~/{run}")
        if code:
            raise RuntimeError(f"run directory not made: {out[-200:]}")
        home = f"/Users/{HOST.split('@')[0]}"
        config = {"origin": stack.origin, "code_alice": invite["code"], "work": f"{home}/{run}/work"}
        code, out = guest(f"umask 077 && cat > ~/{run}/config.json", data=json.dumps(config))
        if code:
            raise RuntimeError(f"configuration not sent: {out[-200:]}")

    def run_guest():
        nonlocal runner
        run = f"{RUN_DIR}"
        command = (f"cd ~/{directory} && zsh -l tool/macos/check_m5.sh --config {run}/config.json "
                   f"--out {run}/out --timeout {RUN_TIMEOUT}")
        runner = subprocess.Popen(["tailscale", "ssh", HOST, command + '; printf "\\n__ANJ_RC=%s\\n" "$?"'],
                                  stdout=(args.evidence / "guest-run.txt").open("w"), stderr=subprocess.STDOUT)
        deadline = time.monotonic() + RUN_TIMEOUT + DRIVER_SLACK
        approved = False
        try:
            while runner.poll() is None and time.monotonic() < deadline:
                if not approved:
                    code, shown = guest(f"cat ~/{directory}/{run}/out/alice-paired.json 2>/dev/null")
                    if code == 0 and shown:
                        # Alice had no active device at the start (reset_user), so hers are this run's.
                        mine = [row["id"] for row in operator.call("devices")
                                if row.get("uid") == ALICE and row.get("state") == "active"]
                        devices.extend(mine)
                        granted = cli("admin-grant", ALICE)
                        step("Alice paired by code alone and made admin", ok=bool(mine) and (
                            granted.returncode == 0 or "already" in granted.stderr), cli=granted.returncode)
                        approved = True
                time.sleep(3)
        finally:
            if runner.poll() is None:
                # Past the deadline, or the driver stopped early: end the guest test before any
                # cleanup runs behind it.
                print("WARN the guest run is still going; ending it", flush=True)
                try:
                    stop_guest_run(directory)
                finally:
                    stop_process(runner, 60)
        log = (args.evidence / "guest-run.txt").read_text(errors="replace")
        found = RC.findall(log)
        code = int(found[-1]) if found else 255
        fetched = subprocess.run([str(CLIENT / "tool/macos/mac_test.sh"), "fetch", args.task, f"{run}/out",
                                  str(args.evidence)], capture_output=True, text=True, timeout=300)
        out = args.evidence / run / "out"
        progress = {name: (out / f"{name}-progress.json").read_text(errors="replace")
                    if (out / f"{name}-progress.json").exists() else None for name in ("ui", "admin")}
        reasons = run_verdict(code, log, progress)
        if fetched.returncode:
            reasons.append(f"evidence not fetched ({fetched.returncode})")
        step("the macOS UI and Admin test ran", ok=not reasons, why=reasons,
             tail=[line for line in log.strip().splitlines() if line and not line.startswith("__ANJ_RC")][-3:])

    def revoke_devices():
        errors = []
        for device in devices:
            try:
                operator.revoke(device)
            except Exception as error:  # Report, keep revoking.
                errors.append(f"{device[:8]}: {error}")
        if errors:
            raise RuntimeError("; ".join(errors))

    completed = False
    invite_alice = None
    try:
        start_backend()
        if not args.halo_only:
            start_forward()
        reset_user(operator, cli, BOB)
        reset_user(operator, cli, ALICE, role=False)
        invite_alice = operator.call("invite", uid=ALICE, rights="write")
        if args.halo_only:
            operator.call("deny", pairing_id=invite_alice["id"])
            step("halo-only: backend, user reset and invitation work")
        else:
            send_config(invite_alice)
            run_guest()
        completed = True
    finally:
        steps = []
        if not args.halo_only:
            steps.append(("guest run stopped", lambda: stop_guest_run(directory)))
            steps.append(("reverse forward stopped", lambda: stop_process(forward, 10)))
        steps += [
            ("devices revoked", revoke_devices),
            (f"{ALICE} admin role removed (or the last admin)", lambda: remove_admin(cli, ALICE)),
            (f"{BOB} reset", lambda: reset_user(operator, cli, BOB)),
            (f"{ALICE} reset (devices, invitations)", lambda: reset_user(operator, cli, ALICE, role=False)),
            ("operator journals reconciled", operator.reconcile),
            ("console backend stopped",
             lambda: backend is None or stop_console_backend(backend, stack.local / "console/backend.sock")),
        ]
        if not args.halo_only:
            steps.append(("guest run files removed", lambda: remove_guest_run_files(directory)))
        failed = cleanup(steps)
        if failed and completed:
            raise SystemExit("cleanup incomplete: " + ", ".join(failed))


if __name__ == "__main__":
    sys.exit(main())
