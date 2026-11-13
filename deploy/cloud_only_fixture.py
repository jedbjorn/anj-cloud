"""Per-file Cloud-only end to end on a review stack (spec #45 F1).

    deploy/.local/access-venv/bin/python -m deploy.cloud_only_fixture --project anj-cloud-review-<tag> \
        --port <port> --evidence <dir>

Pairs one synthetic device for the first fixture user and runs tool/cloud_only_fixture.dart: a real Linux sync
engine syncs two loose 1 MiB files into Music (Local), sets one Cloud-only (released; the server's version and
bytes unchanged), leaves the other untouched and keeps the first on the device again (same hash). Deletes both
files on the server and revokes the device at the end. Prints PASS or raises; no credential or code is printed.
"""

import argparse
import asyncio
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys

from deploy.access_fixture import pair
from deploy.access_operator import Operator
from deploy.dev import FIXTURE_USERS, Stack, private_directory
from deploy.name_fixture import CLIENT, FLUTTER, href


async def scenario(stack, run):
    stack.check()
    stack.accounts()
    operator = Operator(stack)
    nonce = secrets.token_hex(4)
    clients = stack.local / "operator/clients" / ("cloud-only-" + nonce)
    private_directory(clients)
    names = [f"f25-{nonce}-one.bin", f"f25-{nonce}-two.bin"]
    device = None
    try:
        device = await pair(stack, operator, FIXTURE_USERS[0], clients / "device")
        config = clients / "client.json"
        config.write_text(json.dumps({
            "origin": stack.origin, "ca": str(stack.local / "operator/issuer.crt"),
            "certificate": str(clients / "device/device.crt"), "key": str(clients / "device/device.key"),
            "work": str(run / "client"), "names": names}))
        config.chmod(0o600)
        result = subprocess.run(
            [str(FLUTTER / "bin/dart"), "run", "tool/cloud_only_fixture.dart", str(config)], cwd=CLIENT,
            capture_output=True, text=True, timeout=900,
            env={**os.environ, "ANJ_ROOTFS_LIBRARY": str(CLIENT / ".dart_tool/libanj_rootfs.so")})
        lines = [line for line in result.stdout.splitlines() if line.startswith("{")]
        outcome = json.loads(lines[-1]) if lines else None
        (run / "client-result.json").write_text(json.dumps(outcome, indent=2) + "\n")
        if result.returncode != 0 or outcome is None or "failed" in outcome:
            (run / "client-stderr.txt").write_text(result.stderr[-20000:])
            raise RuntimeError("Linux client claims failed: " + json.dumps(outcome)[:3000])
        print("PASS F1: " + "; ".join(outcome["claims"]), flush=True)
    finally:
        if device is not None:
            try:
                for name in names:
                    try:
                        etag = await device.etag("Music/" + name)
                        await device.request("DELETE", href("Music/" + name), headers={"If-Match": etag},
                                             expected=(204,))
                    except RuntimeError:
                        pass  # Never uploaded, or already gone.
            finally:
                await device.close()
                await asyncio.to_thread(operator.revoke, device.identity)
        await asyncio.to_thread(operator.reconcile)
        print("Fixture files deleted and device revoked", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    args = parser.parse_args()
    if not args.project.startswith("anj-cloud-review-"):
        sys.exit("Use a disposable anj-cloud-review-<tag> stack.")
    args.evidence.mkdir(parents=True, exist_ok=True)
    if (args.evidence / "client").exists():
        sys.exit("Evidence directory already holds a client run; use a fresh one.")
    asyncio.run(scenario(Stack(args.project, args.port), args.evidence))


if __name__ == "__main__":
    sys.exit(main())
