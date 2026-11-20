"""Spec #55 A: count real gateway requests across separate killed client processes.

Run on an owned, disposable review stack. The quiet phases read only; changes and
full reference walks have separate observation windows.
"""

import argparse
import asyncio
from collections import Counter
import json
import os
from pathlib import Path
import secrets
import signal

from deploy.access_fixture import pair
from deploy.access_operator import Operator
from deploy.dev import FIXTURE_USERS, Stack, private_directory
from deploy.incremental_listing_fixture import populate
from deploy.name_fixture import CLIENT, FLUTTER, href


def gateway_events(stack, device):
    log = stack.compose("logs", "--no-color", "--no-log-prefix", "access")
    result = []
    for line in log.splitlines():
        if not line.startswith("{"):
            continue
        event = json.loads(line)
        if event.get("event") == "request" and event.get("device") == device:
            result.append(event)
    return result


async def client_check(stack, run, config, device, phase, name):
    offset = len(gateway_events(stack, device))
    with (run / f"{name}.stderr").open("wb") as stderr:
        process = await asyncio.create_subprocess_exec(
            str(FLUTTER / "bin/dart"), "run", "tool/reconnect_listing_fixture.dart",
            str(config), phase, cwd=CLIENT, start_new_session=True,
            stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, stderr=stderr,
        )
        try:
            async with asyncio.timeout(180):
                while line := await process.stdout.readline():
                    if line.startswith(b"{"):
                        receipt = json.loads(line)
                        break
                else:
                    raise RuntimeError(f"{name} exited before its client receipt")
        finally:
            if process.returncode is None:
                os.killpg(process.pid, signal.SIGKILL)
            await process.wait()
    if process.returncode != -signal.SIGKILL:
        raise RuntimeError(f"{name} was not stopped by SIGKILL")
    requests = gateway_events(stack, device)[offset:]
    methods = Counter(event["method"] for event in requests if event["route"].startswith("dav-"))
    share_statuses = [event["status"] for event in requests if event["route"] == "share"]
    if any(event["status"] != 207 for event in requests if event["method"] == "PROPFIND"):
        raise RuntimeError(f"{name} contained a failed folder read")
    report = {
        **receipt,
        "dav_methods": dict(methods),
        "file_body_bytes": sum(e["bytes"] for e in requests if e["method"] == "GET"
                               and e["route"] == "dav-read" and e["status"] in (200, 206)),
        "incoming_statuses": share_statuses,
    }
    (run / f"{name}.json").write_text(json.dumps(report, indent=2) + "\n")
    if phase not in ("fresh", "interrupt") and share_statuses != [200]:
        raise RuntimeError(f"{name} did not validate current incoming-share state")
    if methods - Counter({"PROPFIND": methods["PROPFIND"]}):
        raise RuntimeError(f"{name} issued unexpected DAV requests")
    print(f"{name}: {methods['PROPFIND']} gateway PROPFINDs, {report['file_body_bytes']} file bytes", flush=True)
    return report


async def run_fixture(stack, run):
    if not stack.project.startswith("anj-cloud-review-"):
        raise RuntimeError("Use an owned, disposable review stack")
    stack.check()
    stack.accounts()
    operator = Operator(stack)
    uid = FIXTURE_USERS[0]
    nonce = secrets.token_hex(4)
    clients = stack.local / "operator/clients" / ("reconnect-" + nonce)
    folder = "Reconnect-" + nonce
    deep = f"{folder}/T0/A0/B0/C0/D0"
    reader = writer = None
    try:
        reader = await pair(stack, operator, uid, clients / "reader")
        writer = await pair(stack, operator, uid, clients / "writer")
        await writer.request("MKCOL", href(folder), headers={"If-None-Match": "*"}, expected=(201,))
        populate(stack, uid, folder)
        config = clients / "reconnect.json"
        config.write_text(json.dumps({
            "origin": stack.origin, "ca": str(stack.local / "operator/issuer.crt"),
            "certificate": str(clients / "reader/device.crt"),
            "key": str(clients / "reader/device.key"),
            "profile": str(run / "profile"), "account": uid, "device": reader.identity,
            "deep": deep,
        }))
        config.chmod(0o600)

        async def check(phase, name):
            return await client_check(stack, run, config, reader.identity, phase, name)

        prime = await check("prime", "prime")
        if prime["full_walks"] != 1 or prime["dav_methods"]["PROPFIND"] < 501:
            raise RuntimeError("The initial read did not walk the 500-folder fixture")
        quiet = [await check("cached", f"quiet-{i}") for i in range(1, 4)]
        fresh = await check("fresh", "fresh-quiet")
        if len({r["pid"] for r in [prime, *quiet, fresh]}) != 5:
            raise RuntimeError("Checks did not have distinct processes")
        for row in quiet:
            if (not 1 <= row["dav_methods"].get("PROPFIND", 0) <= 3 or row["full_walks"]
                    or row["file_body_bytes"] or row["sha256"] != fresh["sha256"]):
                raise RuntimeError("A quiet restart failed request, bytes or full-view agreement")

        interrupted = await check("interrupt", "interrupted-publish")
        recovered = await check("cached", "after-interrupt")
        if (not interrupted["uncommitted"] or recovered["full_walks"]
                or recovered["sha256"] != fresh["sha256"]):
            raise RuntimeError("An interrupted transaction displaced the complete generation")

        replace, move, remove = (f"{deep}/f{i}.txt" for i in range(3))
        add, moved = f"{deep}/added.txt", f"{deep}/moved.txt"
        versions = fresh["deep"]
        await writer.request("PUT", href(replace), data=b"replacement",
                             headers={"If-Match": versions[replace]}, expected=(204,))
        await writer.request("PUT", href(add), data=b"new",
                             headers={"If-None-Match": "*"}, expected=(201,))
        await writer.request("MOVE", href(move), headers={
            "If-Match": versions[move], "Overwrite": "F",
            "Destination": stack.origin + href(moved),
        }, expected=(201,))
        await writer.request("DELETE", href(remove), headers={"If-Match": versions[remove]}, expected=(204,))
        changed = await check("cached", "deep-changes")
        reference = await check("fresh", "fresh-changed")
        after = changed["deep"]
        if (changed["sha256"] != reference["sha256"] or changed["full_walks"]
                or changed["folders_reused"] == 0 or replace not in after
                or versions[replace] == after[replace] or move in after
                or moved not in after or remove in after or add not in after):
            raise RuntimeError("The first restart missed a deep change or reused no unaffected folders")
        print("PASS three quiet restarts, interrupted publish, and four deep changes agree with fresh walks",
              flush=True)
    finally:
        if writer is not None:
            try:
                tag = await writer.etag(folder + "/")
                await writer.request("DELETE", href(folder), headers={"If-Match": tag}, expected=(204,))
            finally:
                await writer.close()
                await asyncio.to_thread(operator.revoke, writer.identity)
        if reader is not None:
            await reader.close()
            await asyncio.to_thread(operator.revoke, reader.identity)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", required=True)
    parser.add_argument("--port", required=True, type=int)
    parser.add_argument("--evidence", required=True, type=Path)
    args = parser.parse_args()
    run = args.evidence.resolve()
    private_directory(run)
    asyncio.run(run_fixture(Stack(args.project, args.port), run))


if __name__ == "__main__":
    main()
