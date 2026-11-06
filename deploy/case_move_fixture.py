"""Case- and normalization-only renames end to end on a review stack (SC-054): how Nextcloud answers
a MOVE to another spelling of the same name through the gateway, and what a real Linux client does.

    deploy/.local/access-venv/bin/python -m deploy.case_move_fixture --project anj-cloud-review-sc054 --port 18954 \
        --evidence <dir>

Pairs one synthetic device, works only in a fresh Documents/anj-case-<nonce> folder, then deletes that
folder and revokes the device. Prints PASS and INFO lines; no credential or code is printed.
"""

import argparse
import asyncio
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
from urllib.parse import unquote
from xml.etree import ElementTree as ET

from deploy.access_fixture import pair
from deploy.access_operator import Operator
from deploy.dev import FIXTURE_USERS, Stack, private_directory
from deploy.name_fixture import CLIENT, FLUTTER, href

PROPS = (b'<?xml version="1.0"?><d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns"><d:prop>'
         b'<d:getetag/><oc:fileid/><d:resourcetype/></d:prop></d:propfind>')


async def listing(actor, folder):
    """{name: (etag, fileid)} directly inside `folder` (the folder itself excluded)."""
    body, _ = await actor.request("PROPFIND", href(folder) + "/", data=PROPS, headers={"Depth": "1"}, expected=(207,))
    items = {}
    for node in ET.fromstring(body).iter("{DAV:}response"):
        path = unquote(node.findtext("{DAV:}href")).rstrip("/")
        if path.endswith("/" + folder.rsplit("/", 1)[-1]):
            continue
        items[path.rsplit("/", 1)[-1]] = (node.findtext(".//{DAV:}getetag"), node.findtext(".//{http://owncloud.org/ns}fileid"))
    return items


async def move(actor, source, target, etag):
    headers = {"If-Match": etag, "Overwrite": "F", "Destination": actor.stack.origin + href(target)}
    async with actor.session.request("MOVE", actor.stack.origin + href(source), headers=headers, allow_redirects=False) as response:
        body = await response.read()
        return response.status, body


async def gateway_proofs(actor, folder):
    create = {"If-None-Match": "*"}
    await actor.request("MKCOL", href(folder + "/Photos"), headers=create, expected=(201,))
    await actor.request("PUT", href(folder + "/Photos/a.jpg"), data=b"a", headers=create, expected=(201,))
    for name in ("Report.txt", "Other.txt", "café.txt"):
        await actor.request("PUT", href(folder + "/" + name), data=name.encode(), headers=create, expected=(201,))
    before = await listing(actor, folder)
    inner = await listing(actor, folder + "/Photos")

    status, _ = await move(actor, folder + "/Photos", folder + "/photos", before["Photos"][0])
    after = await listing(actor, folder)
    if status != 201 or "Photos" in after or after.get("photos") != before["Photos"] \
            or (await listing(actor, folder + "/photos")).get("a.jpg") != inner["a.jpg"]:
        raise RuntimeError(f"Case-only folder MOVE: {status} {sorted(after)}")
    print("PASS Nextcloud takes a case-only folder MOVE directly (201); folder and child keep file ID and ETag", flush=True)

    status, _ = await move(actor, folder + "/Report.txt", folder + "/report.txt", before["Report.txt"][0])
    after = await listing(actor, folder)
    if status != 201 or "Report.txt" in after or after.get("report.txt") != before["Report.txt"]:
        raise RuntimeError(f"Case-only file MOVE: {status}")
    print("PASS a case-only file MOVE is direct (201), same file ID and ETag: no two-step move is needed", flush=True)

    body, _ = await actor.request("MOVE", href(folder + "/Other.txt"), headers={
        "If-Match": before["Other.txt"][0], "Overwrite": "F", "Destination": actor.stack.origin + href(folder + "/REPORT.txt")},
        expected=(422,))
    if json.loads(body).get("reason") != "clash":
        raise RuntimeError("A MOVE onto a different item's spelling was not refused as a clash")
    print("PASS a MOVE of a different item to a case variant of an existing name is still refused (422 clash, #120)", flush=True)

    nfc, nfd = "café.txt", "café.txt"
    status, _ = await move(actor, folder + "/" + nfc, folder + "/" + nfd, before[nfc][0])
    after = await listing(actor, folder)
    if status != 412 or after.get(nfc) != before[nfc] or nfd in after:
        raise RuntimeError(f"NFC->NFD MOVE: {status} {[n.encode('unicode_escape') for n in after]}")
    print("INFO a MOVE from an NFC name to its NFD spelling answers 412: Nextcloud normalizes the destination "
          "to NFC, finds the item itself there (Overwrite: F); the item is unchanged", flush=True)
    status, _ = await move(actor, folder + "/" + nfc, folder + "/case-tmp.txt", before[nfc][0])
    if status != 201:
        raise RuntimeError(f"Temp MOVE: {status}")
    tmp = (await listing(actor, folder))["case-tmp.txt"]
    status, _ = await move(actor, folder + "/case-tmp.txt", folder + "/" + nfd, tmp[0])
    after = await listing(actor, folder)
    stored = [name for name in after if name.startswith("caf")]
    if status != 201 or stored != [nfc]:
        raise RuntimeError(f"Two-step MOVE to NFD: {status} {[n.encode('unicode_escape') for n in stored]}")
    print("INFO a two-step MOVE via a temporary name also ends as the NFC spelling (201, stored NFC): Nextcloud "
          "cannot hold a normalization-only rename at all: clients treat it as the same name (decision #138)", flush=True)
    for name, (etag, _) in (await listing(actor, folder)).items():
        await actor.request("DELETE", href(folder + "/" + name), headers={"If-Match": etag}, expected=(204,))


async def scenario(stack, run):
    stack.check()
    stack.accounts()
    operator = Operator(stack)
    nonce = secrets.token_hex(4)
    clients = stack.local / "operator/clients" / ("case-" + nonce)
    private_directory(clients)
    folder = "Documents/anj-case-" + nonce
    actor = None
    try:
        actor = await pair(stack, operator, FIXTURE_USERS[0], clients / "alice")
        await actor.request("MKCOL", href(folder), headers={"If-None-Match": "*"}, expected=(201,))
        await gateway_proofs(actor, folder)
        client_folder = folder + "/client"
        await actor.request("MKCOL", href(client_folder), headers={"If-None-Match": "*"}, expected=(201,))
        config = clients / "client.json"
        config.write_text(json.dumps({"origin": stack.origin, "ca": str(stack.local / "operator/issuer.crt"),
                                      "certificate": str(clients / "alice/device.crt"), "key": str(clients / "alice/device.key"),
                                      "work": str(run / "client"), "folder": client_folder}))
        config.chmod(0o600)
        result = subprocess.run([str(FLUTTER / "bin/dart"), "run", "tool/case_move_fixture.dart", str(config)], cwd=CLIENT,
                                capture_output=True, text=True, timeout=600,
                                env={**os.environ, "ANJ_ROOTFS_LIBRARY": str(CLIENT / ".dart_tool/libanj_rootfs.so")})
        line = (result.stdout.strip().splitlines() or ["{}"])[-1]
        (run / "client-result.json").write_text(line + "\n")
        if result.returncode != 0:
            raise RuntimeError("Linux client claims failed: " + line[:2000])
        print("PASS Linux client: " + "; ".join(json.loads(line)["claims"]), flush=True)
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
