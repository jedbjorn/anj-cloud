"""Production healthcheck client (spec #20, Production Stack 8).

Connects to the gateway's Unix socket, sends a PROXY v2 LOCAL header, then TLS with
``server_hostname`` set to the production host and verification pinned to the issuer, and
requires ``GET /health`` to answer ready. Exit status 0 means ready.

Reused by the compose healthcheck, spec B's self-check and watchdog
(``docker compose exec -T access python -m access.health``) and spec C's restore drill
(a one-off container with ``--socket``, ``--host`` and ``--cafile``).
"""

import argparse
import json
import os
import socket
import ssl
import sys
from urllib.parse import urlsplit

from .edge import local_header
from .privileges import drop

MAX_RESPONSE = 16384


def default_host():
    return urlsplit(os.environ.get("ANJ_ORIGIN", "")).hostname or ""


def check(socket_path, host, cafile, timeout=5.0):
    """Return the decoded /health body; raise on any transport, TLS or status failure."""
    if not host:
        raise ValueError("No production host: set ANJ_ORIGIN or pass --host")
    context = ssl.create_default_context(cafile=cafile)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as raw:
        raw.settimeout(timeout)
        raw.connect(socket_path)
        raw.sendall(local_header())
        with context.wrap_socket(raw, server_hostname=host) as tls:
            tls.sendall(b"GET /health HTTP/1.1\r\nHost: " + host.encode("idna") + b"\r\nConnection: close\r\n\r\n")
            data = b""
            while len(data) <= MAX_RESPONSE:
                chunk = tls.recv(4096)
                if not chunk:
                    break
                data += chunk
    head, _, body = data.partition(b"\r\n\r\n")
    status_line = head.split(b"\r\n", 1)[0].split()
    if len(status_line) < 2 or status_line[1] != b"200":
        raise RuntimeError("Gateway health status " + (status_line[1].decode("ascii", "replace") if len(status_line) > 1 else "missing"))
    state = json.loads(body)
    if state != {"status": "ready"}:
        raise RuntimeError("Gateway is not ready")
    return state


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--socket", default=os.environ.get("ANJ_SOCKET", "/run/anj-cloud-gw/gateway.sock"))
    parser.add_argument("--host", default=default_host())
    parser.add_argument("--cafile", default=os.path.join(os.environ.get("ANJ_TLS_DIR", "/run/secrets"), "issuer_crt"))
    parser.add_argument("--timeout", type=float, default=5.0)
    args = parser.parse_args(argv)
    try:
        drop()
        check(args.socket, args.host, args.cafile, args.timeout)
    except Exception as error:
        # Status only; no response body, path or certificate detail.
        print(json.dumps({"status": "unhealthy", "error": type(error).__name__}))
        return 1
    print(json.dumps({"status": "ready"}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
