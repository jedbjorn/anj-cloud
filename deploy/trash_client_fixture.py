"""Trash in a real Linux client against a review stack (spec #44 AC1, AC2).

    deploy/.local/access-venv/bin/python -m deploy.trash_client_fixture --project anj-cloud-review-<tag> --port <port> \
        --evidence <dir>

Needs a gateway with the /trash/ routes. Pairs one synthetic device for Alice, works only in a fresh
`Documents/anj-trash-client-<nonce>` folder, runs `apps/client/tool/trash_fixture.dart` (one-step delete, the
server and device trash, Undo before and after the server acknowledged, a taken name), then deletes the
folder, removes its items from Alice's trash and revokes the device. Prints PASS lines and writes
`client-result.json`; no credential or code is printed.
"""

import argparse
import asyncio
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
from urllib.parse import quote

from deploy.access_fixture import pair
from deploy.access_operator import Operator
from deploy.dev import FIXTURE_USERS, Stack, private_directory

CLIENT = Path(__file__).resolve().parent.parent / "apps/client"
FLUTTER = Path(os.environ.get("FLUTTER_SDK", os.path.expanduser("~/.local/share/anj-cloud/toolchains/flutter-3.47.9")))


def href(relative):
    return "/dav/" + "/".join(quote(part, safe="-._~") for part in relative.split("/"))


async def scenario(stack, run):
    stack.check()
    stack.accounts()
    operator = Operator(stack)
    nonce = secrets.token_hex(4)
    clients = stack.local / "operator/clients" / ("trash-client-" + nonce)
    private_directory(clients)
    folder = "Documents/anj-trash-client-" + nonce
    actor = None
    try:
        actor = await pair(stack, operator, FIXTURE_USERS[0], clients / "alice")
        await actor.request("GET", "/trash/", expected=(200,))
        await actor.request("MKCOL", href(folder), headers={"If-None-Match": "*"}, expected=(201,))
        config = clients / "client.json"
        config.write_text(json.dumps({"origin": stack.origin, "ca": str(stack.local / "operator/issuer.crt"),
                                      "certificate": str(clients / "alice/device.crt"), "key": str(clients / "alice/device.key"),
                                      "work": str(run / ("client-" + nonce)), "folder": folder}))
        config.chmod(0o600)
        result = subprocess.run([str(FLUTTER / "bin/dart"), "run", "tool/trash_fixture.dart", str(config)], cwd=CLIENT,
                                capture_output=True, text=True, timeout=900,
                                env={**os.environ, "ANJ_ROOTFS_LIBRARY": str(CLIENT / ".dart_tool/libanj_rootfs.so")})
        line = (result.stdout.strip().splitlines() or ["{}"])[-1]
        (run / "client-result.json").write_text(line + "\n")
        if result.returncode != 0:
            raise RuntimeError("Linux client claims failed: " + line[:2000])
        for name in json.loads(line)["claims"]:
            print("PASS " + name, flush=True)
    finally:
        if actor is not None:
            try:
                try:
                    etag = await actor.etag(folder + "/")
                    await actor.request("DELETE", href(folder), headers={"If-Match": etag}, expected=(204,))
                except RuntimeError:
                    pass
                body, _ = await actor.request("GET", "/trash/", expected=(200,))
                for item in json.loads(body)["items"]:
                    if item["path"] == folder or item["path"].startswith(folder + "/"):
                        await actor.request("DELETE", "/trash/" + item["id"], expected=(204, 404))
            finally:
                await actor.close()
                await asyncio.to_thread(operator.revoke, actor.identity)
                await asyncio.to_thread(operator.reconcile)
        print("Fixture folder and its trash items deleted and device revoked", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--project", required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    args = parser.parse_args()
    args.evidence.mkdir(parents=True, exist_ok=True)
    asyncio.run(scenario(Stack(args.project, args.port), args.evidence))


if __name__ == "__main__":
    sys.exit(main())
