"""Windows pairing and two-way sync on a review stack.

    ANJ_WIN_OWNER=w4 deploy/.local/access-venv/bin/python -m deploy.windows_sync_fixture \\
        --project anj-cloud-review-w4 --port 18871 --evidence <dir>

Needs a started W10C-Testing lease of this lane (tool/windows_seat.sh start) with the client
pushed and anj_rootfs.dll built (tool/windows/native_test.ps1 -Dart), and an `up` review stack.
It owns, for this run only:
  - three invitations for anj-fixture-alice (one denied) and the QR image of one;
  - a second HTTPS server on <port + 1> with a CA of its own, which answers only `GET /v1/ca`:
    a real, unused code tried there must be refused by the device because the code pins the
    stack's CA, and that server must see no other request;
  - remote names Windows cannot hold, written straight to Nextcloud (the gateway refuses them);
  - three moves made straight in Nextcloud when the guest asks for them (signal/moves-wanted.json),
    as another device's renames would arrive: to a name Windows refuses, onto a case sibling,
    and into a folder the device holds back as a clash loser. The guest must keep each item
    where it is; afterwards the driver checks the server still has every item where the moves
    put it;
  - an SSH reverse forward so the guest reaches both at https://127.0.0.1:<port> and <port + 1>;
  - the operator approvals of the guest's two devices by fingerprint (a wrong fingerprint first,
    refused). The stack runs no console backend, so the server does not approve by itself;
and runs test/windows_sync_e2e_test.dart in the console session, unelevated. Afterwards it
checks the server bytes the guest expects, revokes both devices, deletes the fixture folders
and removes its files from the guest. Codes and keys never enter the evidence.
"""

import argparse
import hashlib
import http.server
import json
import os
from pathlib import Path
import secrets
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse

from deploy.access_operator import Operator
from deploy.dev import FIXTURE_USERS, Stack

CLIENT = Path(__file__).resolve().parent.parent / "apps/client"
SEAT = CLIENT / "tool/windows_seat.sh"
GUEST = r"C:\anj\work\w4"
UID = FIXTURE_USERS[0]
# Devices see the account's files/<uid>/anj-cloud/ tree (access protocol backend_root).
BACKEND = "anj-cloud/"
LONG_NAME = "n" * 252 + ".txt"
# Synced to the guest first, then moved in Nextcloud: (from, to), relative to the names folder.
CLOUD_MOVES = (("move-refused.txt", "moved."), ("move-clash.txt", "OK.txt"), ("move-into.txt", "docs/move-into.txt"))
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


def other_server(work, port):
    """An HTTPS server with its own CA that serves that CA at /v1/ca and nothing else. Returns the
    server and the list of request lines it received."""
    subprocess.run(["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256", "-nodes",
                    "-keyout", str(work / "other.key"), "-out", str(work / "other-ca.crt"), "-days", "2",
                    "-subj", "/CN=Not this stack's issuer", "-addext", "subjectAltName=IP:127.0.0.1"],
                   check=True, capture_output=True)
    pem = (work / "other-ca.crt").read_bytes()
    seen = []

    class Handler(http.server.BaseHTTPRequestHandler):
        def answer(self):
            seen.append(f"{self.command} {self.path}")
            found = self.command == "GET" and self.path == "/v1/ca"
            body = pem if found else b""
            self.send_response(200 if found else 404)
            self.send_header("Content-Type", "application/x-pem-file")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        do_GET = do_POST = do_PUT = do_DELETE = do_HEAD = answer

        def log_message(self, *args):
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(work / "other-ca.crt", work / "other.key")
    server.socket = context.wrap_socket(server.socket, server_side=True)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, seen


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
    devices, forward, prefix, other = [], None, None, None
    other_port = args.port + 1
    work = Path(tempfile.mkdtemp(prefix="anj-w4-"))
    try:
        # Invitations: typed (A), QR image (B), and one denied before use.
        invites = {label: operator.call("invite", uid=UID, rights="write") for label in ("a", "b", "denied")}
        operator.call("deny", pairing_id=invites["denied"]["id"])
        subprocess.run(["qrencode", "-o", str(work / "invite-b.png"), "-s", "8", invites["b"]["code"]], check=True)
        # A server whose CA is not the one the codes pin. Invitation A is tried there first: the
        # stack would accept that code, so only the device's check of the pin can refuse it.
        other, other_seen = other_server(work, other_port)
        # Names Windows cannot hold, straight into Nextcloud (the gateway refuses them).
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
                           ("PUT", "a:b"), ("PUT", LONG_NAME), *DEEP,
                           *(("PUT", source) for source, _ in CLOUD_MOVES)):
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

        config = {"origin": stack.origin, "ca": GUEST + r"\issuer.crt",
                  "other_origin": f"https://127.0.0.1:{other_port}",
                  "code_a": invites["a"]["code"], "qr_b": GUEST + r"\invite-b.png",
                  "denied_code": invites["denied"]["code"], "names_folder": names_folder,
                  "cloud_moves": [list(pair) for pair in CLOUD_MOVES],
                  "work": GUEST + r"\run", "signal": GUEST + r"\signal"}
        (work / "config.json").write_text(json.dumps(config))
        seat("ssh", f"if exist {GUEST} rmdir /s /q {GUEST}")
        seat("ssh", f"mkdir {GUEST}\\signal")
        for name in ("config.json", "invite-b.png"):
            copy_to_guest(work / name, name)
        copy_to_guest(stack.local / "operator/issuer.crt", "issuer.crt")
        for name in ("config.json", "invite-b.png"):
            (work / name).unlink()  # The codes stay off this host's disk too.

        # The guest's 127.0.0.1:<port> is this stack, so the dev certificate's name verifies;
        # <port + 1> is the other server.
        forward = subprocess.Popen(["ssh", *SSH, "-N", "-o", "ExitOnForwardFailure=yes",
                                    "-R", f"127.0.0.1:{args.port}:127.0.0.1:{args.port}",
                                    "-R", f"127.0.0.1:{other_port}:127.0.0.1:{other_port}", f"{USER}@{HOST}"])
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
        # The moves the guest asks for, made in Nextcloud as another device's would arrive.
        moved = False
        deadline = time.time() + 900
        while runner.poll() is None and time.time() < deadline:
            if not moved and guest_file("moves-wanted.json"):
                for source, target in CLOUD_MOVES:
                    destination = "/remote.php/dav/files/" + UID + "/" + urllib.parse.quote(
                        f"{BACKEND}{names_folder}/{target}", safe="/")
                    stack.dav("MOVE", UID, f"{BACKEND}{names_folder}/{source}",
                              headers={"Destination": destination, "Overwrite": "F"}, expected=(201, 204))
                (work / "moves-done.json").write_text(json.dumps({"moved": len(CLOUD_MOVES)}))
                copy_to_guest(work / "moves-done.json", "signal/moves-done.json")
                step("cloud moves made in Nextcloud", moves=[f"{s} -> {t}" for s, t in CLOUD_MOVES])
                moved = True
            time.sleep(2)
        code = runner.wait(timeout=60)
        # Windows tools mix OEM bytes into the log.
        log = (args.evidence / "guest-run.txt").read_text(encoding="utf-8", errors="replace")
        progress = guest_file("progress.json")
        (args.evidence / "progress.json").write_text(progress or "[]")
        step("the Windows test ran", ok=code == 0 and "All tests passed" in log,
             tail=log.strip().splitlines()[-3:] if log.strip() else [])
        # The other server was asked for its CA, and for nothing else: no enrolment, no code.
        step("the other server saw only the request for its CA",
             ok=bool(other_seen) and set(other_seen) == {"GET /v1/ca"}, requests=sorted(set(other_seen)))
        # After the guest's passes the server is as the moves left it: nothing was deleted,
        # moved back or uploaded over because the device could not follow.
        step("the guest asked for the cloud moves", ok=moved)
        for source, target in CLOUD_MOVES:
            body = stack.dav("GET", UID, f"{BACKEND}{names_folder}/{target}")
            step(f"server keeps the moved item: {target}", ok=body == f"server {source}".encode())
            stack.dav("GET", UID, f"{BACKEND}{names_folder}/{source}", expected=(404,))
        for kept, content in (("Docs/x.txt", b"server Docs/x.txt"), ("docs/y.txt", b"server docs/y.txt"),
                              ("ok.txt", b"server ok.txt")):
            step(f"server keeps the untouched item: {kept}",
                 ok=stack.dav("GET", UID, f"{BACKEND}{names_folder}/{kept}") == content)
        expected = json.loads(guest_file("expect.json") or "{}")
        prefix = expected.get("prefix")
        for path, digest in expected.get("files", {}).items():
            body = stack.dav("GET", UID, BACKEND + path)
            step(f"server bytes match the Windows device: {path}", ok=hashlib.sha256(body).hexdigest() == digest)
    finally:
        if forward is not None:
            forward.terminate()
            forward.wait(timeout=10)
        if other is not None:
            other.shutdown()
            other.server_close()
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
