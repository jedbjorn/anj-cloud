"""The name rule end to end on a review stack (spec #49 AC2, AC3, AC8): two real Linux clients,
two devices of one account, over real TLS. The stack must carry the spec #49 gateway (D4).

    deploy/.local/access-venv/bin/python -m deploy.name_fixture --project anj-cloud-review-s1 --port 18891

Pairs two synthetic devices, works only in a fresh Documents/anj-names-<nonce> folder, then deletes
that folder and revokes both devices. Prints PASS lines; no credential or code is printed.
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
    clients = stack.local / "operator/clients" / ("names-" + nonce)
    private_directory(clients)
    folder = "Documents/anj-names-" + nonce
    actors = []
    try:
        for label in ("alice-a", "alice-b"):
            actors.append(await pair(stack, operator, FIXTURE_USERS[0], clients / label))
        await actors[0].request("MKCOL", href(folder), headers={"If-None-Match": "*"}, expected=(201,))
        config = clients / "client.json"
        config.write_text(json.dumps({"origin": stack.origin, "ca": str(stack.local / "operator/issuer.crt"),
                                      "devices": [{"certificate": str(clients / label / "device.crt"),
                                                   "key": str(clients / label / "device.key")}
                                                  for label in ("alice-a", "alice-b")],
                                      "work": str(run / "client"), "folder": folder}))
        config.chmod(0o600)
        result = subprocess.run([str(FLUTTER / "bin/dart"), "run", "tool/name_policy_fixture.dart", str(config)], cwd=CLIENT,
                                capture_output=True, text=True, timeout=600,
                                env={**os.environ, "ANJ_ROOTFS_LIBRARY": str(CLIENT / ".dart_tool/libanj_rootfs.so")})
        line = (result.stdout.strip().splitlines() or ["{}"])[-1]
        (run / "client-result.json").write_text(line + "\n")
        if result.returncode != 0:
            raise RuntimeError("Linux client claims failed: " + line[:2000] + "\n" + result.stderr[-2000:])
        print("PASS two Linux clients: the untrimmed folder is renamed in place and uploaded once under its clean name, "
              "every AC3 name syncs verbatim, .htaccess is the one residual row, old holds resolve: "
              + ", ".join(json.loads(line)["claims"]), flush=True)
    finally:
        if actors:
            try:
                etag = await actors[0].etag(folder + "/")
                await actors[0].request("DELETE", href(folder), headers={"If-Match": etag}, expected=(204,))
            finally:
                for actor in actors:
                    await actor.close()
                    await asyncio.to_thread(operator.revoke, actor.identity)
                await asyncio.to_thread(operator.reconcile)
        print("Fixture folder deleted and devices revoked", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    args = parser.parse_args()
    args.evidence.mkdir(parents=True, exist_ok=True)
    asyncio.run(scenario(Stack(args.project, args.port), args.evidence))


if __name__ == "__main__":
    sys.exit(main())
