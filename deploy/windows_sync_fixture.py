"""Windows pairing and sync on a review stack (spec #32 W4, Acceptance rows 8 and 12).

    ANJ_WIN_OWNER=w4 deploy/.local/access-venv/bin/python -m deploy.windows_sync_fixture \\
        --project anj-cloud-review-w4 --port 18871 --evidence <dir>

Needs a started W10C-Testing lease of this lane (tool/windows_seat.sh start) with the client
pushed and anj_rootfs.dll built (tool/windows/native_test.ps1 -Dart), and an `up` review stack.
It owns, for this run only:
  - three invitations for anj-fixture-alice (one denied), the QR image of one, and a
    well-formed code pinned to another server's CA;
  - remote names Windows cannot hold, written straight to Nextcloud (the gateway refuses them);
  - an SSH reverse forward so the guest reaches https://127.0.0.1:<port> (the dev certificate);
  - the operator approvals of the guest's two devices (a wrong fingerprint first, refused);
and runs test/windows_sync_e2e_test.dart in the console session, unelevated. Afterwards it
checks the server bytes the guest expects, revokes both devices, deletes the fixture folders
and removes its files from the guest. Codes and keys never enter the evidence.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
import tempfile
import time

from deploy.access_operator import Operator
from deploy.dev import FIXTURE_USERS, Stack
from services.access.codes import CA_PIN_BYTES, PINNED_SECRET_BYTES, pinned_code

CLIENT = Path(__file__).resolve().parent.parent / "apps/client"
SEAT = CLIENT / "tool/windows_seat.sh"
GUEST = r"C:\anj\work\w4"
UID = FIXTURE_USERS[0]
# Devices see the account's files/<uid>/anj-cloud/ tree (access protocol backend_root).
BACKEND = "anj-cloud/"
LONG_NAME = "n" * 252 + ".txt"
SEGMENTS = [f"segment-{i}-" + "d" * 65 for i in range(3)]
DEEP = [("MKCOL", "/".join(SEGMENTS[:i + 1])) for i in range(3)] + [("PUT", "/".join(SEGMENTS) + "/deep.txt")]
HOST = os.environ.get("ANJ_WIN_HOST", "192.168.122.100")
USER = os.environ.get("ANJ_WIN_USER", "Public")
KEY = os.environ.get("ANJ_WIN_KEY", str(Path.home() / ".ssh/sc_win_test"))
KNOWN = os.environ.get("ANJ_WIN_KNOWN_HOSTS",
                       str(Path.home() / "Repos/rst-c/.sc-state/local/vm/W10C-Testing.known_hosts"))
SSH = ["-i", KEY, "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
       "-o", f"UserKnownHostsFile={KNOWN}", "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=15"]


def seat(*args, check=True, timeout=600):
    """A guest command through the lease-checked seat script."""
    result = subprocess.run([str(SEAT), *args], capture_output=True, text=True, timeout=timeout)
    if check and result.returncode:
        raise RuntimeError(f"seat {args[0]} failed: {result.stderr[-500:]}")
    return result.stdout


def copy_to_guest(local, name):
    subprocess.run(["scp", "-q", *SSH, str(local), f"{USER}@{HOST}:{GUEST.replace(chr(92), '/')}/{name}"],
                   check=True, timeout=120)


def guest_file(name):
    out = seat("ssh", f'if exist {GUEST}\\signal\\{name} type {GUEST}\\signal\\{name}', check=False)
    text = "\n".join(line for line in out.splitlines() if not line.startswith("**"))
    return text.strip() or None


def step(name, ok=True, **facts):
    print(("PASS " if ok else "FAIL ") + name + (f" {json.dumps(facts)}" if facts else ""), flush=True)
    if not ok:
        raise SystemExit(f"step failed: {name}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    args = parser.parse_args()
    if not args.project.startswith("anj-cloud-review-"):
        raise SystemExit("Use a disposable anj-cloud-review-<tag> stack.")
    args.evidence.mkdir(parents=True, exist_ok=True)
    stack = Stack(args.project, args.port)
    stack.check()
    stack.accounts()
    operator = Operator(stack)
    nonce = secrets.token_hex(4)
    names_folder = f"Documents/w4-names-{nonce}"
    devices, forward, prefix = [], None, None
    work = Path(tempfile.mkdtemp(prefix="anj-w4-"))
    try:
        # Invitations: typed (A), QR image (B), and one denied before use.
        invites = {label: operator.call("invite", uid=UID, rights="write") for label in ("a", "b", "denied")}
        operator.call("deny", pairing_id=invites["denied"]["id"])
        subprocess.run(["qrencode", "-o", str(work / "invite-b.png"), "-s", "8", invites["b"]["code"]], check=True)
        # A code of the right shape whose CA pin is not this stack's: the client must refuse it
        # before it stores or sends anything.
        other_server = pinned_code(secrets.token_bytes(PINNED_SECRET_BYTES), secrets.token_bytes(CA_PIN_BYTES))
        # Names Windows cannot hold, straight into Nextcloud (the gateway refuses them, #120).
        for parent in (BACKEND, BACKEND + "Documents"):  # A fresh stack has neither yet.
            stack.dav("MKCOL", UID, parent, expected=(201, 405))
        stack.dav("MKCOL", UID, BACKEND + names_folder, expected=(201,))
        created = []
        # Files Windows cannot hold, a clash pair of files and of folders (with a
        # file in each), and a folder whose own name is not portable.
        for kind, name in (("PUT", "CON"), ("PUT", "nul.txt"), ("PUT", "x."), ("PUT", "trailing "),
                           ("PUT", "A.txt"), ("PUT", "a.txt"), ("PUT", "ok.txt"),
                           ("MKCOL", "Docs"), ("MKCOL", "docs"), ("MKCOL", "bad."),
                           ("PUT", "Docs/x.txt"), ("PUT", "docs/y.txt"), ("PUT", "bad./inside.txt"),
                           # Row 8: an invalid character, a 256-unit name, and a full path
                           # over 300 characters on the guest (synced, with the note).
                           ("PUT", "a:b"), ("PUT", LONG_NAME), *DEEP):
            try:
                if kind == "MKCOL":
                    stack.dav("MKCOL", UID, f"{BACKEND}{names_folder}/{name}", expected=(201,))
                else:
                    stack.dav("PUT", UID, f"{BACKEND}{names_folder}/{name}", data=f"server {name}".encode(),
                              headers={"Content-Type": "application/octet-stream"}, expected=(201, 204))
                created.append(name)
            except RuntimeError as error:
                print(f"INFO Nextcloud refused {name!r}: {error}", flush=True)
        step("remote names written to Nextcloud", created=created)

        config = {"origin": stack.origin, "ca": GUEST + r"\issuer.crt", "other_server_code": other_server,
                  "code_a": invites["a"]["code"], "qr_b": GUEST + r"\invite-b.png",
                  "denied_code": invites["denied"]["code"], "names_folder": names_folder,
                  "work": GUEST + r"\run", "signal": GUEST + r"\signal"}
        (work / "config.json").write_text(json.dumps(config))
        seat("ssh", f"if exist {GUEST} rmdir /s /q {GUEST}")
        seat("ssh", f"mkdir {GUEST}\\signal")
        for name in ("config.json", "invite-b.png"):
            copy_to_guest(work / name, name)
        copy_to_guest(stack.local / "operator/issuer.crt", "issuer.crt")
        for name in ("config.json", "invite-b.png"):
            (work / name).unlink()  # The codes stay off this host's disk too.

        # The guest's 127.0.0.1:<port> is this stack, so the dev certificate's name verifies.
        forward = subprocess.Popen(["ssh", *SSH, "-N", "-o", "ExitOnForwardFailure=yes",
                                    "-R", f"127.0.0.1:{args.port}:127.0.0.1:{args.port}", f"{USER}@{HOST}"])
        time.sleep(3)
        if forward.poll() is not None:
            raise RuntimeError("reverse forward did not start")
        runner = subprocess.Popen([str(SEAT), "ps", str(CLIENT / "tool/windows/w4_run.ps1")],
                                  stdout=(args.evidence / "guest-run.txt").open("w"), stderr=subprocess.STDOUT)

        # Approvals: each device's fingerprint as the guest shows it.
        deadline = time.time() + 600
        pending = {"a": invites["a"], "b": invites["b"]}
        while pending and time.time() < deadline and runner.poll() is None:
            for label in list(pending):
                shown = guest_file(f"fingerprint-{label}.json")
                if not shown:
                    continue
                fingerprint = json.loads(shown)["fingerprint"]
                try:
                    operator.approve(pending[label]["id"], "0" * 64)
                    step(f"approval with a wrong fingerprint is refused ({label})", ok=False)
                except RuntimeError:
                    step(f"approval with a wrong fingerprint is refused ({label})")
                approved = operator.approve(pending[label]["id"], fingerprint)
                devices.append(approved["device_id"])
                step(f"device {label} approved", fingerprint=fingerprint)
                del pending[label]
            time.sleep(2)
        code = runner.wait(timeout=900)
        log = (args.evidence / "guest-run.txt").read_text()
        progress = guest_file("progress.json")
        (args.evidence / "progress.json").write_text(progress or "[]")
        step("the Windows test ran", ok=code == 0 and "All tests passed" in log,
             tail=log.strip().splitlines()[-3:] if log.strip() else [])
        expected = json.loads(guest_file("expect.json") or "{}")
        prefix = expected.get("prefix")
        for path, digest in expected.get("files", {}).items():
            body = stack.dav("GET", UID, BACKEND + path)
            step(f"server bytes match the Windows device: {path}", ok=hashlib.sha256(body).hexdigest() == digest)
    finally:
        if forward is not None:
            forward.terminate()
            forward.wait(timeout=10)
        for device in devices:
            try:
                operator.revoke(device)
            except Exception as error:  # Report, keep cleaning.
                print(f"WARN revoke {device}: {error}", flush=True)
        operator.reconcile()
        for folder in (names_folder, prefix):
            if not folder:
                continue
            try:
                stack.dav("DELETE", UID, BACKEND + folder, expected=(204, 404))
            except RuntimeError as error:
                print(f"WARN delete {folder}: {error}", flush=True)
        seat("ssh", f"if exist {GUEST} rmdir /s /q {GUEST}", check=False)
        for item in work.iterdir():
            item.unlink()
        work.rmdir()
        print("Devices revoked, fixture folders deleted, guest files removed", flush=True)


if __name__ == "__main__":
    sys.exit(main())
