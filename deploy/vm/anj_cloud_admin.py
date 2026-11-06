"""anj-cloud-admin: the recovery CLI (spec #27 Recovery CLI, decisions #87, #89 (5)).

A text console for emergencies, including a lost last admin. In the VM it runs as `anj`,
reached by SSH from the VM host only. Every action goes through the gateway's operator socket
(`admin` action), so the last-admin rule and the audit (actor `recovery-cli`) are exactly the
app's. `health` asks the console backend directly and still answers while the gateway is down.
Destructive actions ask for the target typed back; `--yes` is for scripted tests only. When the
gateway cannot be reached, a mutating attempt is appended to `operator/recovery-audit.jsonl`
(0600), which the console backend imports into the audit on its next pass.

Lost last admin: `anj-cloud-admin invite --user sam` and type the code on the new device; it pairs at
once (decision #151). Only if the gateway could not approve it (`pending` shows it waiting) approve it
with `anj-cloud-admin approve INVITATION_ID --fingerprint FP`, the fingerprint shown on that device. Or
`anj-cloud-admin admin-grant OTHER_UID`.
"""

import argparse
import json
import os
from pathlib import Path
import socket
import sys
import time
import uuid

from deploy.access_operator import Operator, stack_for
from deploy.vm import guide, paths
from deploy.vm.console_backend import DEFAULT_SOCKET, short_address

REJECTED = "Operator action rejected: "
DESTRUCTIVE = {"user-disable", "admin-grant", "admin-remove", "revoke", "reissue", "deny"}


class CliError(Exception):
    pass


def backend_call(path, action, **data):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(300)
        address, directory = short_address(path)
        try:
            connection.connect(address)
        finally:
            if directory is not None:
                os.close(directory)
        connection.sendall(json.dumps({"action": action, **data}).encode())
        connection.shutdown(socket.SHUT_WR)
        chunks = []
        while chunk := connection.recv(65536):
            chunks.append(chunk)
    reply = json.loads(b"".join(chunks))
    if "error" in reply:
        raise CliError(reply["error"] + ": " + reply.get("message", ""))
    return reply


class Cli:
    def __init__(self, operator, backend_socket, *, yes=False, stdin=None, stdout=None, clock=time.time):
        self.operator, self.backend_socket, self.yes = operator, Path(backend_socket), yes
        self.stdin, self.stdout, self.clock = stdin or sys.stdin, stdout or sys.stdout, clock

    def gateway(self, op, audit=None, **data):
        """One `admin` operation over the operator socket; records the attempt locally if unreachable."""
        try:
            return self.operator.call("admin", op=op, **data)
        except RuntimeError as error:
            message = str(error)
            if message.startswith(REJECTED):
                raise CliError(message[len(REJECTED):]) from None
            if audit is not None:
                self.local_audit(audit[0], "gateway-unavailable", **audit[1])
            raise CliError("The gateway is not reachable: " + message) from None

    def local_audit(self, action, result, **targets):
        path = self.operator.directory / "recovery-audit.jsonl"
        line = json.dumps({"id": uuid.uuid4().hex, "time": self.clock(), "action": action, "result": result,
                           **{key: value for key, value in targets.items() if value is not None}}, sort_keys=True)
        fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        try:
            os.write(fd, (line + "\n").encode())
        finally:
            os.close(fd)

    def confirm(self, command, target, effect):
        if self.yes:
            return
        self.stdout.write(effect + "\nType %s to confirm: " % target)
        self.stdout.flush()
        if self.stdin.readline().strip() != target:
            raise CliError("Not confirmed; nothing was changed")

    def run(self, args):
        command = args.command
        if command == "users":
            return self.gateway("users")
        if command == "admins":
            return [row["uid"] for row in self.gateway("users")["users"] if row["admin"] and row["enabled"]]
        if command == "user-add":
            return self.gateway("user-add", ("user-add", {"target_uid": args.uid}), uid=args.uid, display_name=args.name)
        if command in ("user-enable", "user-disable"):
            enabled = command == "user-enable"
            if not enabled:
                self.confirm(command, args.uid, "Disable %s: their devices stop syncing until enabled again." % args.uid)
            return self.gateway("user-enabled", ("user-enabled", {"target_uid": args.uid}), uid=args.uid, enabled=enabled)
        if command in ("admin-grant", "admin-remove"):
            grant = command == "admin-grant"
            self.confirm(command, args.uid, ("Make %s an admin." if grant else "Remove %s's admin role.") % args.uid)
            return self.gateway("user-admin", ("user-admin", {"target_uid": args.uid}), uid=args.uid, admin=grant)
        if command == "devices":
            return self.gateway("devices")
        if command == "pending":
            return self.gateway("invitations")
        if command == "invite":
            return self.gateway("invite", ("invitation-create", {"target_uid": args.user}), uid=args.user, grant=args.grant,
                                label=args.label)
        if command == "approve":
            return self.gateway("approve", ("invitation-approve", {"target_invitation": args.invitation_id}),
                                invitation_id=args.invitation_id, fingerprint=args.fingerprint.strip().lower())
        if command == "deny":
            self.confirm(command, args.invitation_id[:8], "Deny or cancel invitation %s." % args.invitation_id)
            return self.gateway("deny", ("invitation-deny", {"target_invitation": args.invitation_id}), invitation_id=args.invitation_id)
        if command in ("revoke", "reissue"):
            row = next((row for row in self.gateway("devices")["devices"] if row["id"] == args.device_id), None)
            if row is None:
                raise CliError("No such device")
            if command == "revoke":
                self.confirm(command, row["uid"], "Revoke %s of %s: it stops syncing at once and must pair again."
                             % (row.get("label") or args.device_id[:8], row["uid"]))
            else:
                self.confirm(command, row["uid"], "Reissue the certificate of %s (%s)." % (row.get("label") or args.device_id[:8], row["uid"]))
            return self.gateway(command, ("device-" + command, {"target_uid": row["uid"], "target_device": args.device_id}),
                                device_id=args.device_id)
        if command == "health":
            try:
                return backend_call(self.backend_socket, "health")
            except OSError:
                return self.gateway("health")
        if command == "audit":
            return self.gateway("audit")
        raise CliError("Unknown command")


def parser():
    root = argparse.ArgumentParser(prog="anj-cloud-admin", description=__doc__.split("\n\n")[0])
    root.add_argument("--project", default=paths.PROJECT)
    root.add_argument("--port", type=int)
    root.add_argument("--state-root")
    root.add_argument("--backend-socket", default=str(DEFAULT_SOCKET))
    root.add_argument("--yes", action="store_true", help="Skip typed confirmation (scripted tests only)")
    sub = root.add_subparsers(dest="command", required=True)
    for name in ("users", "admins", "devices", "pending", "health", "audit"):
        sub.add_parser(name)
    add = sub.add_parser("user-add")
    add.add_argument("uid")
    add.add_argument("--name", required=True)
    for name in ("user-enable", "user-disable", "admin-grant", "admin-remove"):
        sub.add_parser(name).add_argument("uid")
    invite = sub.add_parser("invite")
    invite.add_argument("--user", required=True)
    invite.add_argument("--grant", choices=("read", "write"), default="write")
    invite.add_argument("--label")
    approve = sub.add_parser("approve")
    approve.add_argument("invitation_id")
    approve.add_argument("--fingerprint", required=True)
    sub.add_parser("deny").add_argument("invitation_id")
    sub.add_parser("revoke").add_argument("device_id")
    sub.add_parser("reissue").add_argument("device_id")
    return root


def main(argv=None):
    args = parser().parse_args(argv)
    state_root = args.state_root
    if state_root is None and args.project == paths.PROJECT:
        state_root = str(paths.STATE_ROOT)
    try:
        cli = Cli(Operator(stack_for(args.project, args.port, state_root)), args.backend_socket, yes=args.yes)
        result = cli.run(args)
    except (CliError, RuntimeError, ValueError, OSError) as error:
        print("ERROR " + str(error), file=sys.stderr)
        return 1
    # `invite` prints its one-time code for the person at the terminal; never pipe it into logs.
    print(json.dumps(result, indent=2))
    if args.command == "invite" and isinstance(result, dict) and result.get("code") and sys.stdout.isatty():
        # The same code as a QR code for the app's Scan QR code (a terminal only, never a pipe).
        qr = guide.qr_text(result["code"])
        if qr:
            print("Or scan it in the app (Pair device, Scan QR code):")
            sys.stdout.write(qr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
