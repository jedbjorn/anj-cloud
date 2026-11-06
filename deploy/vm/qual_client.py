"""Synthetic device for anj-qual (spec #21 "Bootstrap via answers file"; the VM host side, qualify.py).

Enrols with a pairing code and does an mTLS DAV write and read over TCP to the VM's HAProxy
(<bind address>:443, SNI <host>, pinned to the household issuer), so the path is the one a real
device takes: HAProxy, PROXY v2, the gateway. Reuses spec #22's drill client (CSR, enrol, DAV);
only the connection differs (TCP to HAProxy instead of the gateway's Unix socket). Needs
`cryptography` (the access venv). The code is a function argument, never a command-line argument,
and nothing secret is printed.
"""

import argparse
import http.client
import json
from pathlib import Path
import re
import socket
import sys
import time

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from deploy import backup_drill_client as drill  # noqa: E402


class HaproxyConnection(http.client.HTTPConnection):
    """Drop-in for the drill client's GatewayConnection: `socket_path` carries the TCP address."""

    def __init__(self, address, host, context, timeout=60):
        super().__init__(host, 443, timeout=timeout)
        self.address = address
        self.context = context

    def connect(self):
        raw = socket.create_connection((self.address, 443), timeout=self.timeout)
        self.sock = self.context.wrap_socket(raw, server_hostname=self.host)


class Client:
    def __init__(self, address, host, cafile, state):
        self.args = argparse.Namespace(socket=address, host=host, cafile=str(cafile), state=str(state), code=None)

    def call(self, function, code):
        original = drill.GatewayConnection
        drill.GatewayConnection = HaproxyConnection
        try:
            self.args.code = code
            return function(self.args)
        except Exception as error:  # noqa: BLE001 - status only, never content
            return {"error": type(error).__name__}
        finally:
            self.args.code = None
            drill.GatewayConnection = original

    def enroll(self, code):
        """{"enroll": status, "pairing_id", "fingerprint", ...} (the fingerprint the app shows)."""
        return self.call(drill.enroll, code)

    def dav(self, code):
        """After approval: certificate pickup, then PUT and GET of 256 KiB with mTLS."""
        return self.call(drill.dav, code)

    def admin(self, method, path, body=None, timeout=70):
        """One mTLS request to /v1/account or /v1/admin/... through HAProxy, as the app makes it:
        (status, decoded JSON or None, seconds). Never prints a body."""
        connection = HaproxyConnection(self.args.socket, self.args.host, drill.context(self.args, certificate=True),
                                       timeout=timeout)
        started = time.monotonic()
        try:
            data = json.dumps(body).encode() if body is not None else None
            headers = {"Host": self.args.host, **({"Content-Type": "application/json"} if data is not None else {})}
            connection.request(method, path, body=data, headers=headers)
            response = connection.getresponse()
            raw = response.read(1 << 20)
        finally:
            connection.close()
        try:
            parsed = json.loads(raw)
        except ValueError:
            parsed = None
        return response.status, parsed, time.monotonic() - started

    def admin_action(self, method, path, body=None, deadline=345):
        """The app's AdminClient: one request, then GET /v1/admin/operations/<id> while the gateway
        answers 202 (SC-041). (final status, body, [(status, seconds) per HTTP exchange])."""
        status, reply, seconds = self.admin(method, path, body)
        exchanges, end = [(status, round(seconds, 1))], time.monotonic() + deadline
        while status == 202 and isinstance(reply, dict) and re.fullmatch(r"[0-9a-f]{32}", str(reply.get("operation"))) \
                and time.monotonic() < end:
            status, reply, seconds = self.admin("GET", "/v1/admin/operations/" + reply["operation"])
            exchanges.append((status, round(seconds, 1)))
        return status, reply, exchanges

    def confirmed(self, method, path, body):
        """A destructive action: the gateway's 428 confirmation, then the resend with its token."""
        status, reply, exchanges = self.admin_action(method, path, body)
        if status != 428 or not isinstance(reply, dict):
            return status, reply, exchanges
        status, reply, more = self.admin_action(method, path, {**body, "confirm": reply.get("confirm_token")})
        return status, reply, exchanges + more
