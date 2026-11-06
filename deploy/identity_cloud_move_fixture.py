"""Cloud moves by file ID end to end on a review stack (spec #33 I2, acceptance rows 2 and 3): two real
Linux sync engines on two paired devices. Device B renames a file into a new folder, moves a folder with a
deep subtree, renames an item device A renamed to another name meanwhile, and moves an item device A
deleted meanwhile. Device A (The VM host client) then applies each as one local rename (the cloud name wins;
the delete follows the item), and the gateway's own request log shows that A fetched no file bytes.

    deploy/.local/access-venv/bin/python -m deploy.identity_cloud_move_fixture \
        --project anj-cloud-review-i2 --port 18962 --evidence <dir>

Pairs two synthetic devices for one fixture user, works only in a fresh Documents/anj-cloud-move-<nonce>
folder, then deletes that folder and revokes both devices. Writes client-result.json (both devices'
request logs, local identities before and after) and gateway-device-a.jsonl (the gateway's request
records for device A during its pass) to the evidence directory. Prints PASS and INFO lines; no
credential or code is printed.
"""

import argparse
import asyncio
from collections import Counter
from datetime import datetime
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys

import aiohttp

from deploy.access_fixture import pair
from deploy.access_operator import Operator
from deploy.dev import FIXTURE_USERS, Stack, private_directory
from deploy.name_fixture import CLIENT, FLUTTER, href


def moment(text):
    return datetime.fromisoformat(text.replace("Z", "+00:00"))


def gateway_records(stack, since, device, start, end):
    """The gateway's request records for `device` between `start` and `end` (UTC ISO strings)."""
    log = stack.compose("logs", "--no-color", "--no-log-prefix", "--since", since, "access")
    records = []
    for line in log.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            record = json.loads(line)
        except ValueError:
            continue
        if (record.get("event") == "request" and record.get("device") == device
                and moment(start) <= moment(record["time"]) <= moment(end)):
            records.append(record)
    return records


async def scenario(stack, run, client=CLIENT):
    stack.check()
    stack.accounts()
    operator = Operator(stack)
    nonce = secrets.token_hex(4)
    clients = stack.local / "operator/clients" / ("cloud-move-" + nonce)
    private_directory(clients)
    folder = "Documents/anj-cloud-move-" + nonce
    user = FIXTURE_USERS[0]
    a = b = None
    since = subprocess.run(["date", "-u", "+%Y-%m-%dT%H:%M:%SZ"], capture_output=True, text=True,
                           check=True).stdout.strip()
    try:
        a = await pair(stack, operator, user, clients / "a")
        b = await pair(stack, operator, user, clients / "b")
        await a.request("MKCOL", href(folder), headers={"If-None-Match": "*"}, expected=(201,))
        config = clients / "client.json"
        config.write_text(json.dumps({
            "origin": stack.origin, "ca": str(stack.local / "operator/issuer.crt"),
            "a": {"certificate": str(clients / "a/device.crt"), "key": str(clients / "a/device.key")},
            "b": {"certificate": str(clients / "b/device.crt"), "key": str(clients / "b/device.key")},
            "work": str(run / "client"), "folder": folder}))
        config.chmod(0o600)
        result = subprocess.run([str(FLUTTER / "bin/dart"), "run", "tool/identity_cloud_move_fixture.dart", str(config)],
                                cwd=client, capture_output=True, text=True, timeout=900,
                                env={**os.environ, "ANJ_ROOTFS_LIBRARY": str(client / ".dart_tool/libanj_rootfs.so")})
        line = (result.stdout.strip().splitlines() or ["{}"])[-1]
        (run / "client-result.json").write_text(line + "\n")
        if result.returncode != 0:
            raise RuntimeError("Linux client claims failed: " + line[:2000])
        outcome = json.loads(line)
        for name in outcome["claims"]:
            print("PASS Linux clients: " + name, flush=True)
        for row, deletes, what in (("row2", 0, "nothing deleted"),
                                   ("row3", 1, "one DELETE: the item it deleted, at its new cloud path")):
            part = outcome[row]
            print(f"INFO {row}: device B sent: " + "; ".join(part["requestsB"]), flush=True)
            print(f"INFO {row}: device A sent (listings omitted, {part['listingsA']} listings): "
                  + ("; ".join(part["requestsA"]) or "nothing") + "; local renames: " + "; ".join(part["renamesA"]),
                  flush=True)
            records = gateway_records(stack, since, a.identity, outcome[row + "Start"], outcome[row + "End"])
            with open(run / f"gateway-device-a-{row}.jsonl", "w") as out:
                for record in records:
                    out.write(json.dumps(record, sort_keys=True) + "\n")
            if not records:
                raise RuntimeError(f"No gateway request records for device A in its {row} pass")
            methods = Counter(r["method"] + " " + r["route"] for r in records)
            print(f"INFO {row}: gateway records for device A (method route): "
                  + json.dumps(dict(sorted(methods.items()))), flush=True)
            # File bytes and namespace writes go through the DAV routes; the added-dates query
            # (GET files-added, spec #24) carries no file content.
            dav = Counter(r["method"] for r in records if r["route"].startswith("dav"))
            if dav.get("GET", 0) or dav.get("PUT", 0) or dav.get("MOVE", 0) or dav.get("MKCOL", 0):
                raise RuntimeError(f"Device A fetched, sent or moved something in {row}: " + json.dumps(dict(dav)))
            if dav.get("DELETE", 0) != deletes:
                raise RuntimeError(f"Device A sent {dav.get('DELETE', 0)} DELETEs in {row}, expected {deletes}")
            print(f"PASS gateway log, {row}: device A made no DAV GET (no file bytes fetched), no PUT, MOVE or "
                  f"MKCOL; {what}", flush=True)
    finally:
        try:
            if a is not None:
                await remove_folder(stack, a, folder)
        finally:
            for actor in (a, b):
                if actor is not None:
                    try:
                        await actor.close()
                    finally:
                        await asyncio.to_thread(operator.revoke, actor.identity)
            await asyncio.to_thread(operator.reconcile)
        print("Fixture folder deleted and devices revoked", flush=True)


async def remove_folder(stack, actor, folder):
    """Deletes the fixture folder; one retry, since the gateway may have closed the idle connection."""
    for attempt in (1, 2):
        try:
            etag = await actor.etag(folder + "/")
            await actor.request("DELETE", href(folder), headers={"If-Match": etag}, expected=(204,))
            return
        except aiohttp.ClientConnectionError:
            if attempt == 2:
                raise
            await actor.close()
            await actor.open()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--client", type=Path, default=CLIENT,
                        help="apps/client checkout to run (default: this one), e.g. a merge with another unit")
    args = parser.parse_args()
    args.evidence.mkdir(parents=True, exist_ok=True)
    asyncio.run(scenario(Stack(args.project, args.port), args.evidence, args.client.resolve()))


if __name__ == "__main__":
    sys.exit(main())
