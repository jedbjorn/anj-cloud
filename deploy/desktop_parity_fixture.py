"""macOS and Linux pairing and two-way sync on a review stack (spec #31 M7, acceptance row 10).

    deploy/.local/access-venv/bin/python -m deploy.desktop_parity_fixture \\
        --project anj-cloud-review-<tag> --port <port> --task <shell>/<tag>-<n> --evidence <dir>

Needs an `up` review stack and mac-test online; run it inside a bounded scope
(anj-test-<tag>-<n>). It sends the client source to mac-test (mac_test.sh send <task>),
builds the Darwin test dylib there and the Linux library here, and owns, for this run only:
  - four pinned invitations for anj-fixture-alice (code-only pairing, spec #35): one that
    expires (issued first, used last), one typed by the Mac, one typed by the Linux device
    (the Mac then tries it again, used), one denied;
  - two codes the stack never issued: one pinned to another CA (its secret is the denied
    invitation's, so only the app's CA check can refuse it) and one with this CA's pin;
  - an SSH reverse forward so mac-test reaches https://127.0.0.1:<port> (the dev
    certificate names 127.0.0.1), with the guest's host key taken from the tailnet;
  - the relay of each device's signal files to the other.
The devices pair by the code alone: the app fetches /v1/ca, keeps it only if it matches the
code's pin, and the gateway approves at once (no operator approval, no CA file). It runs
test/desktop_parity_e2e_test.dart as the macOS device on mac-test and as the Linux device
here, then checks the server bytes the devices expect, revokes every device this run paired,
deletes the fixture folder on the server and the run's files on both sides, and denies every
invitation it did not use. Codes and keys never enter the evidence. Guest cleanup of the
task directory stays with `mac_test.sh clean <tag> --reset-bundle-state` after the run.

--rehearse runs both devices on the VM host (the mac role over the Linux library); it proves the
harness, not macOS. With it, --break <negative> removes one negative's condition so the run
must FAIL at that negative, proving the check is not vacuous:
  foreign      the "foreign" code carries this CA's pin: the server, not the app, refuses it;
  used         the "used" code is a fresh invitation: the Mac's second device pairs;
  expiry       the "expired" invitation is a fresh one, used at once (scripted cases
               skipped): the expired code pairs.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import secrets
import shlex
import subprocess
import sys
import tempfile
import time

from deploy import deployment_profile
from deploy.access_operator import Operator
from deploy.dev import FIXTURE_USERS, Stack
from deploy.macos_admin_fixture import stop_console_backend, wait_backend
from services.access.codes import (CA_PIN_BYTES, PINNED_CODE_LENGTH, PINNED_SECRET_BYTES, code_ca_pin,
                                   decode_code, normalize_code, pinned_code)

CLIENT = Path(__file__).resolve().parent.parent / "apps/client"
MAC_TEST = CLIENT / "tool/macos/mac_test.sh"
FLUTTER = Path(os.environ.get("FLUTTER_SDK", str(Path.home() / ".local/share/anj-cloud/toolchains/flutter-3.47.9"))) / "bin/flutter"
UID = FIXTURE_USERS[0]
BACKEND = "anj-cloud/"  # Devices see files/<uid>/anj-cloud/ (access protocol backend_root).
TEST = "test/desktop_parity_e2e_test.dart"
BREAKS = ("foreign", "used", "expiry")


def pinned(code):
    """The normalized pinned code; a legacy (unpinned) code fails the run: code-only pairing."""
    normalized = normalize_code(code)
    if len(normalized) != PINNED_CODE_LENGTH:
        raise RuntimeError("the stack issued a legacy (unpinned) code; code-only pairing needs a pinned one")
    return normalized


def repinned(code, pin):
    """`code`'s one-time secret with another CA pin: a code for another server."""
    secret = decode_code(pinned(code), PINNED_SECRET_BYTES + CA_PIN_BYTES)[:PINNED_SECRET_BYTES]
    return pinned_code(secret, pin)


def active_devices(operator):
    return {row["id"] for row in operator.call("devices") if row.get("uid") == UID and row.get("state") == "active"}


def step(name, ok=True, **facts):
    print(("PASS " if ok else "FAIL ") + name + (f" {json.dumps(facts)}" if facts else ""), flush=True)
    if not ok:
        raise SystemExit(f"step failed: {name}")


class Guest:
    """mac-test over Tailscale SSH (decision #1). `tailscale ssh` always exits 0, so every
    command that must succeed prints a marker that is checked here."""

    def __init__(self, host):
        self.host = host

    def run(self, command, data=None, timeout=120):
        marked = f"{command}; printf '\\n__ANJ_RC=%s\\n' \"$?\""
        result = subprocess.run(["tailscale", "ssh", self.host, marked], input=data, capture_output=True,
                                timeout=timeout, check=False)
        out = result.stdout.decode(errors="replace")
        head, _, tail = out.rpartition("__ANJ_RC=")
        if not tail.strip().isdigit():
            raise RuntimeError(f"mac-test gave no exit status for: {command.split()[0]}")
        return int(tail.strip()), head.rstrip("\n")

    def need(self, command, data=None, timeout=120):
        code, out = self.run(command, data, timeout)
        if code:
            raise RuntimeError(f"mac-test command failed ({code}): {command.split()[0]}")
        return out

    def write(self, path, data):
        self.need(f"cat > {shlex.quote(path)}", data=data)

    def read(self, path):
        code, out = self.run(f"cat {shlex.quote(path)}")
        return out if code == 0 else None


class LocalGuest(Guest):
    """--rehearse: the "mac" device's side on the VM host itself, same interface."""

    def run(self, command, data=None, timeout=120):
        result = subprocess.run(["bash", "-c", command], input=data, capture_output=True, timeout=timeout,
                                check=False)
        return result.returncode, result.stdout.decode(errors="replace").rstrip("\n")


def known_hosts(host, path):
    """A private known_hosts for the guest from the tailnet's own record of its SSH host
    keys, so the reverse forward keeps strict host key checking."""
    status = json.loads(subprocess.run(["tailscale", "status", "--json"], capture_output=True, check=True,
                                       timeout=30).stdout)
    name = host.split("@")[-1]
    for peer in status.get("Peer", {}).values():
        dns = peer.get("DNSName", "").rstrip(".")
        if dns.split(".")[0] == name.split(".")[0]:
            keys = peer.get("sshHostKeys") or []
            if not keys:
                raise RuntimeError(f"the tailnet lists no SSH host keys for {dns}")
            names = ",".join([dns, *peer.get("TailscaleIPs", [])])
            path.write_text("".join(f"{names} {key}\n" for key in keys))
            return dns
    raise RuntimeError(f"{name} is not in the tailnet")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--project", required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--task", required=True, help="mac-test task directory <shell>/<tag>-<n>")
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--host", default=os.environ.get("MAC_TEST_HOST") or deployment_profile.load()["lab"]["mac_test_host"])
    parser.add_argument("--minutes", type=int, default=25, help="bound for the two device runs")
    parser.add_argument("--rehearse", action="store_true",
                        help="run both devices on the VM host (the mac role over the Linux library): proves the harness only")
    parser.add_argument("--break", dest="breaks", choices=BREAKS,
                        help="--rehearse only: remove one negative's condition; the run must fail there")
    args = parser.parse_args()
    if args.breaks and not args.rehearse:
        raise SystemExit("--break is for --rehearse only.")
    if not args.project.startswith("anj-cloud-review-"):
        raise SystemExit("Use a disposable anj-cloud-review-<tag> stack.")
    args.evidence.mkdir(parents=True, exist_ok=True)
    stack = Stack(args.project, args.port)
    stack.check()
    stack.accounts()
    operator = Operator(stack)
    guest = LocalGuest(args.host) if args.rehearse else Guest(args.host)
    nonce = secrets.token_hex(4)
    prefix = f"Documents/m7-parity-{nonce}"
    work = Path(tempfile.mkdtemp(prefix="anj-m7-parity-"))
    halo_signal = work / "signal"
    halo_signal.mkdir()
    devices, forward, mac_run, linux_run, mac_dir, invites = [], None, None, None, None, {}
    before = backend = None
    socket = stack.local / "console/backend.sock"
    budget = args.minutes * 60
    try:
        # A pinned code is approved by the gateway through the console backend's approve path
        # (spec #35 rule 3): without it every pairing stays pending.
        backend = subprocess.Popen([sys.executable, "-m", "deploy.vm.console_backend", "--project", stack.project,
                                    "--port", str(stack.port), "--socket", str(socket)],
                                   cwd=CLIENT.parent.parent, stdout=(args.evidence / "console-backend.txt").open("w"),
                                   stderr=subprocess.STDOUT)
        wait_backend(operator, backend)
        before = active_devices(operator)  # Every device this run pairs is revoked at the end.
        # The expiring invitation first: it is used last, after its 600 s.
        for label in ("expired", "mac", "linux", "denied"):
            invites[label] = operator.call("invite", uid=UID, rights="write")
            pinned(invites[label]["code"])
        operator.call("deny", pairing_id=invites["denied"]["id"])
        if args.breaks == "expiry":
            # A valid code in the expired slot, used without waiting: it must be refused, and pairs.
            invites["expired"] = dict(operator.call("invite", uid=UID, rights="write"), expires=time.time() - 10)
        if args.breaks == "used":
            invites["used"] = operator.call("invite", uid=UID, rights="write")
        pin = code_ca_pin(pinned(invites["mac"]["code"]))
        other_pin = bytes(byte ^ 0x5A for byte in pin)  # Any pin but this CA's: another server's.
        foreign = repinned(invites["denied"]["code"], pin if args.breaks == "foreign" else other_pin)
        unknown = pinned_code(secrets.token_bytes(PINNED_SECRET_BYTES), pin)
        step("pinned invitations and never-issued codes prepared",
             expires_after_s=int(invites["expired"]["expires"] - time.time()))

        # mac-test: source, Darwin test dylib, and the run's files.
        if args.rehearse:
            task = str(work / "mac-task")
            mac_dir = f"{task}/parity"
            guest.need(f"mkdir -p {shlex.quote(mac_dir)}/signal")
        else:
            subprocess.run([str(MAC_TEST), "send", args.task], check=True, timeout=300)
            home = guest.need("printf %s \"$HOME\"").strip()
            task = f"{home}/work/{args.task}"
            mac_dir = f"{task}/parity"
            guest.need(f"cd {shlex.quote(task)} && mkdir -p tmp parity/signal && "
                       "zsh -l tool/macos/build_native.sh --out .dart_tool/libanj_rootfs.dylib > parity/native.log 2>&1",
                       timeout=600)
            step("Darwin test dylib built on mac-test")
        used = invites["used"] if args.breaks == "used" else invites["linux"]
        mac_config = {"role": "mac", "origin": stack.origin, "code": invites["mac"]["code"],
                      "foreign_code": foreign, "unknown_code": unknown,
                      "denied_code": invites["denied"]["code"], "used_code": used["code"],
                      "expired_code": invites["expired"]["code"],
                      "expired_after": invites["expired"]["expires"], "work": f"{mac_dir}/run",
                      "signal": f"{mac_dir}/signal", "prefix": prefix}
        if args.breaks == "expiry":
            mac_config["cases"] = False  # Honoured only in a rehearsal (ANJ_PARITY_REHEARSAL=1).
        guest.need(f"umask 077 && : > {shlex.quote(mac_dir)}/config.json")
        guest.write(f"{mac_dir}/config.json", json.dumps(mac_config).encode())

        # VM host: the Linux library and the Linux device's config.
        subprocess.run([str(CLIENT / "tool/build_rootfs.sh")], cwd=CLIENT, check=True, timeout=600,
                       capture_output=True)
        linux_config = {"role": "linux", "origin": stack.origin,
                        "code": invites["linux"]["code"], "work": str(work / "run"),
                        "signal": str(halo_signal), "prefix": prefix, "cases": mac_config.get("cases", True)}
        (work / "config.json").touch(0o600)
        (work / "config.json").write_text(json.dumps(linux_config))

        # The guest's 127.0.0.1:<port> is this stack, so the dev certificate's name verifies.
        if not args.rehearse:
            hosts = work / "known_hosts"
            dns = known_hosts(args.host, hosts)
            user = args.host.split("@")[0] if "@" in args.host else os.environ.get("USER", "user")
            forward = subprocess.Popen(["ssh", "-N", "-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes",
                                        "-o", "StrictHostKeyChecking=yes", "-o", f"UserKnownHostsFile={hosts}",
                                        "-o", "ServerAliveInterval=15", "-o", "ConnectTimeout=15",
                                        "-R", f"127.0.0.1:{args.port}:127.0.0.1:{args.port}", f"{user}@{dns}"],
                                       stdout=subprocess.DEVNULL, stderr=(args.evidence / "forward.txt").open("w"))
            time.sleep(4)
            if forward.poll() is not None:
                raise RuntimeError("reverse forward did not start (see forward.txt)")
            step("reverse forward to mac-test", host=dns)

        # Both devices, each bounded on its own seat as well as here.
        mac_cmd = (f"export TMPDIR=$PWD/tmp ANJ_PARITY_CONFIG={shlex.quote(mac_dir)}/config.json "
                   "ANJ_ROOTFS_LIBRARY=$PWD/.dart_tool/libanj_rootfs.dylib FLUTTER_SUPPRESS_ANALYTICS=true; "
                   f"perl -e 'alarm shift; exec @ARGV' {budget} flutter --suppress-analytics test --reporter expanded {TEST}")
        env = dict(os.environ, ANJ_PARITY_CONFIG=str(work / "config.json"),
                   ANJ_ROOTFS_LIBRARY=str(CLIENT / ".dart_tool/libanj_rootfs.so"), FLUTTER_SUPPRESS_ANALYTICS="true")
        if args.rehearse:
            # Two flutter test runs in one package: let the first compile alone.
            mac_run = subprocess.Popen(["timeout", str(budget), str(FLUTTER), "--suppress-analytics", "test",
                                        "--reporter", "expanded", TEST], cwd=CLIENT,
                                       env=dict(env, ANJ_PARITY_CONFIG=f"{mac_dir}/config.json",
                                                ANJ_PARITY_REHEARSAL="1"),
                                       stdout=(args.evidence / "mac-run.txt").open("w"), stderr=subprocess.STDOUT)
        else:
            mac_run = subprocess.Popen([str(MAC_TEST), "run", args.task, mac_cmd],
                                       stdout=(args.evidence / "mac-run.txt").open("w"), stderr=subprocess.STDOUT)
        if args.rehearse:
            time.sleep(60)
        linux_run = subprocess.Popen(["timeout", str(budget), str(FLUTTER), "--suppress-analytics", "test",
                                      "--reporter", "expanded", TEST], cwd=CLIENT, env=env,
                                     stdout=(args.evidence / "linux-run.txt").open("w"), stderr=subprocess.STDOUT)

        # Relay until both device runs end.
        copied_in, copied_out = set(), set()
        deadline = time.time() + budget + 120
        while (mac_run.poll() is None or linux_run.poll() is None) and time.time() < deadline:
            code, listing = guest.run(f"ls -1 {shlex.quote(mac_dir)}/signal")
            names = set(listing.split()) if code == 0 else set()
            for name in sorted(names - copied_in):
                if not name.startswith("mac-") or name.endswith("-progress.json"):
                    continue
                body = guest.read(f"{mac_dir}/signal/{name}") or ""
                (halo_signal / name).write_text(body)
                copied_in.add(name)
            for path in sorted(halo_signal.iterdir()):
                name = path.name
                if name.startswith("linux-") and not name.endswith("-progress.json") and name not in copied_out:
                    guest.write(f"{mac_dir}/signal/{name}", path.read_bytes())
                    copied_out.add(name)
            time.sleep(1)
        results = {}
        for label, run in (("mac", mac_run), ("linux", linux_run)):
            if run.poll() is None:
                run.kill()
            results[label] = run.wait(timeout=60)
        (args.evidence / "mac-progress.json").write_text(guest.read(f"{mac_dir}/signal/mac-progress.json") or "[]")
        progress = halo_signal / "linux-progress.json"
        (args.evidence / "linux-progress.json").write_text(progress.read_text() if progress.exists() else "[]")
        for label in ("mac", "linux"):
            log = (args.evidence / f"{label}-run.txt").read_text(errors="replace")
            step(f"the {label} device run passed", ok=results[label] == 0 and "All tests passed" in log,
                 tail=log.strip().splitlines()[-3:] if log.strip() else [])
        paired = active_devices(operator) - before
        devices.extend(sorted(paired))
        step("each device paired by its code alone, approved by the server", ok=len(paired) == 2,
             devices=len(paired))
        expected = json.loads(guest.read(f"{mac_dir}/signal/mac-expect.json") or "{}")
        for path, digest in expected.get("files", {}).items():
            body = stack.dav("GET", UID, BACKEND + path)
            step(f"server bytes match the devices: {path}", ok=hashlib.sha256(body).hexdigest() == digest)
    finally:
        if forward is not None:
            forward.terminate()
            forward.wait(timeout=10)
        for run in (mac_run, linux_run):
            if run is not None and run.poll() is None:
                run.kill()
                run.wait(timeout=30)
        try:
            if before is not None:
                devices.extend(sorted(active_devices(operator) - before - set(devices)))
        except Exception as error:  # Report, keep cleaning.
            print(f"WARN device listing: {error}", flush=True)
        for device in devices:
            try:
                operator.revoke(device)
            except Exception as error:  # Report, keep cleaning.
                print(f"WARN revoke {device}: {error}", flush=True)
        # Every invitation still open; a revoked device's invitation keeps its state.
        for label, invite in invites.items():
            try:
                if operator.call("inspect", pairing_id=invite["id"])["state"] in ("issued", "reserved", "provisioning"):
                    operator.call("deny", pairing_id=invite["id"])
            except Exception as error:
                print(f"WARN deny {label} invitation: {error}", flush=True)
        try:
            operator.reconcile()
        except Exception as error:
            print(f"WARN reconcile: {error}", flush=True)
        try:
            stack.dav("DELETE", UID, BACKEND + prefix, expected=(204, 404))
        except RuntimeError as error:
            print(f"WARN delete {prefix}: {error}", flush=True)
        try:
            if mac_dir is not None:
                guest.run(f"rm -rf {shlex.quote(mac_dir)}")
        except Exception as error:
            print(f"WARN guest files: {error}", flush=True)
        subprocess.run(["rm", "-rf", "--", str(work)], check=False)
        if backend is not None:
            try:
                stop_console_backend(backend, socket)
            except RuntimeError as error:
                print(f"WARN console backend: {error}", flush=True)
        print("Devices revoked, fixture folder deleted, run files removed on both sides", flush=True)


if __name__ == "__main__":
    sys.exit(main())
