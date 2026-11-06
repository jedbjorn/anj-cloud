"""Restore-drill device client (spec #22): PROXY v2 LOCAL, then TLS, over the gateway Unix socket.

Runs inside a one-off container from the restored release image (Python and `cryptography`
are already there), as the gateway's container user, with the drill's socket directory
mounted. It never prints keys, codes, tokens or file contents; output is one JSON object.

    client.py --socket S --host H --cafile C --state D enroll --code <code>
    client.py --socket S --host H --cafile C --state D dav --code <code>
"""

import argparse
from datetime import datetime, timezone
import hashlib
import http.client
import json
import os
import secrets
import socket
import ssl
import sys

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID

PROXY_SIGNATURE = b"\r\n\r\n\x00\r\nQUIT\n"


def local_header():
    """PROXY protocol v2, command LOCAL, family UNSPEC, no addresses (16 bytes)."""
    return PROXY_SIGNATURE + bytes((0x20, 0x00, 0x00, 0x00))


class GatewayConnection(http.client.HTTPConnection):
    def __init__(self, socket_path, host, context, timeout=60):
        super().__init__(host, 443, timeout=timeout)
        self.socket_path = socket_path
        self.context = context

    def connect(self):
        raw = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        raw.settimeout(self.timeout)
        raw.connect(self.socket_path)
        raw.sendall(local_header())
        self.sock = self.context.wrap_socket(raw, server_hostname=self.host)


def context(args, certificate=False):
    value = ssl.create_default_context(cafile=args.cafile)
    value.minimum_version = ssl.TLSVersion.TLSv1_2
    if certificate:
        value.load_cert_chain(os.path.join(args.state, "device.crt"), os.path.join(args.state, "device.key"))
    return value


def request(args, method, path, body=None, headers=None, certificate=False):
    connection = GatewayConnection(args.socket, args.host, context(args, certificate))
    try:
        connection.request(method, path, body=body, headers=dict(headers or {}, Host=args.host))
        response = connection.getresponse()
        return response.status, response.read(1 << 22)
    finally:
        connection.close()


def enroll(args):
    key = ec.generate_private_key(ec.SECP256R1())
    csr = (x509.CertificateSigningRequestBuilder()
           .subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "restore drill")]))
           .sign(key, hashes.SHA256()))
    path = os.path.join(args.state, "device.key")
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as stream:
        stream.write(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                       serialization.NoEncryption()))
    csr_pem = csr.public_bytes(serialization.Encoding.PEM).decode()
    with open(os.path.join(args.state, "device.csr"), "w") as stream:
        stream.write(csr_pem)
    unauthenticated, _ = request(args, "GET", "/dav/")
    status, body = request(args, "POST", "/v1/enroll", json.dumps({"code": args.code, "csr": csr_pem,
                                                                     "label": "restore drill"}).encode(),
                           {"Content-Type": "application/json"})
    if status != 200:
        return {"enroll": status}
    pending = json.loads(body)
    return {"enroll": status, "pairing_id": pending["pairing_id"], "fingerprint": pending["fingerprint"],
            "state": pending.get("state"), "dav_without_certificate": unauthenticated}


def dav(args):
    with open(os.path.join(args.state, "device.csr")) as stream:
        csr_pem = stream.read()
    status, body = request(args, "POST", "/v1/enroll/status", json.dumps({"code": args.code, "csr": csr_pem}).encode(),
                           {"Content-Type": "application/json"})
    approved = json.loads(body) if status == 200 else {}
    if approved.get("state") != "approved":
        return {"status": status, "state": approved.get("state")}
    with open(os.path.join(args.state, "device.crt"), "w") as stream:
        stream.write(approved["certificate"])
    leaf = x509.load_pem_x509_certificate(approved["certificate"].encode())
    hours = (leaf.not_valid_after_utc - datetime.now(timezone.utc)).total_seconds() / 3600
    payload = secrets.token_bytes(256 * 1024)
    name = "/dav/restore-drill-" + secrets.token_hex(6) + ".bin"
    put, _ = request(args, "PUT", name, payload, {"If-None-Match": "*", "Content-Type": "application/octet-stream"},
                     certificate=True)
    get, data = request(args, "GET", name, certificate=True)
    return {"leaf_hours": round(hours, 2), "put": put, "get": get,
            "sha256_match": hashlib.sha256(data).digest() == hashlib.sha256(payload).digest()}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--socket", required=True)
    parser.add_argument("--host", required=True)
    parser.add_argument("--cafile", required=True)
    parser.add_argument("--state", required=True)
    parser.add_argument("command", choices=("enroll", "dav"))
    parser.add_argument("--code", required=True)
    args = parser.parse_args(argv)
    try:
        result = enroll(args) if args.command == "enroll" else dav(args)
    except Exception as error:  # noqa: BLE001 - status only, never content
        result = {"error": type(error).__name__}
    print(json.dumps(result))
    return 0 if "error" not in result else 1


if __name__ == "__main__":
    sys.exit(main())
