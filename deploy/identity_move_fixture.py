"""Local moves by identity end to end on a review stack (spec #33 I1, acceptance row 1): a real Linux
client renames a file into another folder, moves a deep subtree to another parent and renames a folder;
each is one MOVE through the gateway, nothing is uploaded, downloaded or deleted, file IDs are kept and
the moved file's Nextcloud version history stays attached to it.

    deploy/.local/access-venv/bin/python -m deploy.identity_move_fixture --project anj-cloud-review-i1 \
        --port 18961 --evidence <dir>

Pairs one synthetic device, works only in a fresh Documents/anj-identity-<nonce> folder, then deletes
that folder and revokes the device. Writes client-result.json (the client's request log and file IDs)
and versions.json to the evidence directory. Prints PASS and INFO lines; no credential or code is
printed.
"""

import argparse
import asyncio
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
from xml.etree import ElementTree as ET

from deploy.access_fixture import pair
from deploy.access_operator import Operator
from deploy.dev import FIXTURE_USERS, Stack, private_directory
from deploy.name_fixture import CLIENT, FLUTTER, href

VERSIONS = (b'<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:getetag/><d:getcontentlength/>'
            b'</d:prop></d:propfind>')


def versions(stack, user, file_id):
    """Nextcloud's stored versions of `file_id` (its history, not the current content), read inside
    Nextcloud through the fixture helper; the gateway does not serve the versions endpoint."""
    status, body = stack.backend_http("PROPFIND", f"/remote.php/dav/versions/{user}/versions/{int(file_id)}",
                                      user, VERSIONS, {"Depth": "1", "Content-Type": "application/xml"})
    if status != 207:
        raise RuntimeError(f"Versions PROPFIND returned {status}")
    hrefs = [node.findtext("{DAV:}href") for node in ET.fromstring(body).iter("{DAV:}response")]
    return [h for h in hrefs if not h.rstrip("/").endswith(f"/versions/{int(file_id)}")]


async def scenario(stack, run):
    stack.check()
    stack.accounts()
    operator = Operator(stack)
    nonce = secrets.token_hex(4)
    clients = stack.local / "operator/clients" / ("identity-" + nonce)
    private_directory(clients)
    folder = "Documents/anj-identity-" + nonce
    user = FIXTURE_USERS[0]
    actor = None
    try:
        actor = await pair(stack, operator, user, clients / "alice")
        await actor.request("MKCOL", href(folder), headers={"If-None-Match": "*"}, expected=(201,))
        client_folder = folder + "/client"
        await actor.request("MKCOL", href(client_folder), headers={"If-None-Match": "*"}, expected=(201,))
        config = clients / "client.json"
        config.write_text(json.dumps({"origin": stack.origin, "ca": str(stack.local / "operator/issuer.crt"),
                                      "certificate": str(clients / "alice/device.crt"), "key": str(clients / "alice/device.key"),
                                      "work": str(run / "client"), "folder": client_folder}))
        config.chmod(0o600)
        result = subprocess.run([str(FLUTTER / "bin/dart"), "run", "tool/identity_move_fixture.dart", str(config)], cwd=CLIENT,
                                capture_output=True, text=True, timeout=900,
                                env={**os.environ, "ANJ_ROOTFS_LIBRARY": str(CLIENT / ".dart_tool/libanj_rootfs.so")})
        line = (result.stdout.strip().splitlines() or ["{}"])[-1]
        (run / "client-result.json").write_text(line + "\n")
        if result.returncode != 0:
            raise RuntimeError("Linux client claims failed: " + line[:2000])
        outcome = json.loads(line)
        for name in outcome["claims"]:
            print("PASS Linux client: " + name, flush=True)
        print("INFO request log after the renames (listings omitted, " + str(outcome["listings"]) + " listings): "
              + "; ".join(outcome["requests"]), flush=True)
        kept = versions(stack, user, outcome["reportFileId"])
        (run / "versions.json").write_text(json.dumps({"fileId": outcome["reportFileId"], "versions": kept}) + "\n")
        if not kept:
            raise RuntimeError("The moved file has no stored version: its history did not follow it")
        print(f"PASS the moved file (same file ID) keeps its Nextcloud version history: {len(kept)} stored version(s)",
              flush=True)
    finally:
        if actor is not None:
            try:
                etag = await actor.etag(folder + "/")
                await actor.request("DELETE", href(folder), headers={"If-Match": etag}, expected=(204,))
            finally:
                await actor.close()
                await asyncio.to_thread(operator.revoke, actor.identity)
                await asyncio.to_thread(operator.reconcile)
        print("Fixture folder deleted and device revoked", flush=True)


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
