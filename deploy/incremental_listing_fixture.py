"""Incremental cloud listing end to end on a review stack (spec #33 I4, rows 8, 9 and 10).

    deploy/.local/access-venv/bin/python -m deploy.incremental_listing_fixture --project anj-cloud-review-i4 \
        --port 18904 --evidence <dir>

Pairs one synthetic device for each fixture user. Builds a 5,000-file, 500-folder tree in a fresh
`Listing-<nonce>` folder of Alice's root directly in Nextcloud's data directory (then `occ files:scan`), and
runs tool/incremental_listing_fixture.dart: quiet checks, a change six folders down, Bob's share probe and a
fresh device's first pass over 10,000 files. PROPFINDs are counted in Nextcloud's access log between the
client's HEAD markers. Deletes both fixture folders and revokes both devices at the end. Prints PASS and INFO
lines; no credential or code is printed.
"""

import argparse
import asyncio
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import sys
from datetime import datetime, timezone

from deploy.access_fixture import pair
from deploy.access_operator import Operator
from deploy.dev import FIXTURE_USERS, Stack, private_directory
from deploy.name_fixture import CLIENT, FLUTTER, href

DATA = "/var/www/html/data"


def build_script(base, prefix, folders):
    """A POSIX sh script making `folders` folders of 10 files each under `base` (inside the container)."""
    lines = ["set -eu", f"cd '{base}'"]
    for folder in folders:
        lines.append(f"mkdir -p '{prefix}{folder}'")
        lines.append(f"for n in 0 1 2 3 4 5 6 7 8 9; do printf 'x%s' \"$n\" > '{prefix}{folder}/f'\"$n\"'.txt'; done")
    return "\n".join(lines) + "\n"


def tree_folders():
    """500 folders: T0..T9, each with A0..A6 and six B folders under each A, plus T0/A0/B0/C0/D0; minus
    T9/A6/B4 and T9/A6/B5 so the count is exact."""
    folders = []
    for t in range(10):
        folders.append(f"T{t}")
        for a in range(7):
            folders.append(f"T{t}/A{a}")
            for b in range(6):
                if (t, a) == (9, 6) and b >= 4:
                    continue
                folders.append(f"T{t}/A{a}/B{b}")
    folders += ["T0/A0/B0/C0", "T0/A0/B0/C0/D0"]
    assert len(folders) == 500, len(folders)
    return folders


def populate(stack, uid, relative, prefix=""):
    base = f"{DATA}/{uid}/files/anj-cloud/{relative}"
    script = build_script(base, prefix, tree_folders())
    stack.compose("exec", "-T", "--user", "www-data", "nextcloud", "sh", "-s", data=script)
    stack.occ("files:scan", "--quiet", f"--path=/{uid}/files/anj-cloud/{relative}")


def count(log, uid, marks):
    """PROPFINDs on `uid`'s files between each pair of markers, in log order."""
    dav = f"/remote.php/dav/files/{uid}/"
    windows, current = {}, None
    for line in log.splitlines():
        marker = re.search(r'"HEAD [^ ]*zz-marker-([a-z0-9-]+)-(begin|end) ', line)
        if marker:
            name, edge = marker.groups()
            current = name if edge == "begin" else None
            if edge == "begin":
                windows[name] = {"propfind": 0, "other": 0}
            continue
        if current is None or dav not in line:
            continue
        windows[current]["propfind" if '"PROPFIND ' in line else "other"] += 1
    missing = [name for name in marks if name.rsplit("-", 1)[0] not in windows]
    if missing:
        raise RuntimeError(f"Markers missing from the Nextcloud log: {missing}")
    return windows


async def scenario(stack, run):
    stack.check()
    stack.accounts()
    operator = Operator(stack)
    nonce = secrets.token_hex(4)
    clients = stack.local / "operator/clients" / ("listing-" + nonce)
    private_directory(clients)
    folder, probe = "Listing-" + nonce, "Probe-" + nonce
    alice = bob = None
    since = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    try:
        alice = await pair(stack, operator, FIXTURE_USERS[0], clients / "alice")
        bob = await pair(stack, operator, FIXTURE_USERS[1], clients / "bob")
        await alice.request("MKCOL", href(folder), headers={"If-None-Match": "*"}, expected=(201,))
        config = clients / "client.json"
        config.write_text(json.dumps({
            "origin": stack.origin, "ca": str(stack.local / "operator/issuer.crt"),
            "alice": {"certificate": str(clients / "alice/device.crt"), "key": str(clients / "alice/device.key")},
            "bob": {"certificate": str(clients / "bob/device.crt"), "key": str(clients / "bob/device.key")},
            "aliceUid": FIXTURE_USERS[0], "work": str(run / "client"), "folder": folder, "probe": probe}))
        config.chmod(0o600)
        process = subprocess.Popen(
            [str(FLUTTER / "bin/dart"), "run", "tool/incremental_listing_fixture.dart", str(config)], cwd=CLIENT,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            env={**os.environ, "ANJ_ROOTFS_LIBRARY": str(CLIENT / ".dart_tool/libanj_rootfs.so")})
        result = None
        for line in process.stdout:
            if "{" not in line:
                continue
            message = json.loads(line[line.index("{"):])
            if message.get("await") == "populate":
                populate(stack, FIXTURE_USERS[0], folder)
                print("INFO built 5,000 files in 500 folders on the server", flush=True)
            elif message.get("await") == "grow":
                populate(stack, FIXTURE_USERS[0], folder, prefix="More/")
                print("INFO grew the tree to 10,000 files in 1,001 folders", flush=True)
            else:
                result = message
                break
            process.stdin.write("go\n")
            process.stdin.flush()
        process.stdin.close()
        stderr = process.stderr.read()
        code = process.wait(timeout=600)
        (run / "client-result.json").write_text(json.dumps(result) + "\n")
        if code != 0 or result is None or "failed" in result:
            (run / "client-stderr.txt").write_text(stderr[-20000:])
            raise RuntimeError("Linux client claims failed: " + json.dumps(result)[:3000])
        claims = result["claims"]
        log = stack.compose("logs", "--no-color", "--no-log-prefix", "--since", since, "nextcloud")
        (run / "nextcloud-access.log").write_text(
            "\n".join(line for line in log.splitlines() if '"' in line and "/remote.php/" in line) + "\n")
        windows = count(log, FIXTURE_USERS[0], result["marks"])
        (run / "server-counts.json").write_text(json.dumps(windows, indent=2) + "\n")
        for name, value in windows.items():
            print(f"INFO server PROPFINDs in check {name}: {value['propfind']} (other Alice DAV requests: "
                  f"{value['other']})", flush=True)
        quiet = [windows[f"quiet{i}"]["propfind"] for i in (1, 2, 3)]
        if any(n > 3 for n in quiet):
            raise RuntimeError(f"Row 8: quiet checks cost {quiet} PROPFINDs")
        print(f"PASS row 8: quiet checks of the 5,000-file, 500-folder tree cost {quiet} PROPFINDs on the server "
              f"(first full walk {windows['first']['propfind']})", flush=True)
        print(f"PASS row 9: the change six folders down was seen on the next check "
              f"({windows['deep']['propfind']} PROPFINDs); the owner's deep change in the incoming share too "
              f"({windows['share-deep']['propfind']})", flush=True)
        print("INFO share propagation: " + json.dumps(claims["share propagation"]), flush=True)
        print("INFO row 10 on the stack: " + json.dumps(claims["row 10: 10,000 Cloud-only files on a fresh device"]),
              flush=True)
        print("PASS Linux client: " + "; ".join(claims), flush=True)
    finally:
        for actor, name in ((alice, folder), (bob, probe)):
            if actor is None:
                continue
            try:
                try:
                    etag = await actor.etag(name + "/")
                    await actor.request("DELETE", href(name), headers={"If-Match": etag}, expected=(204,))
                except RuntimeError:
                    pass  # Never created, or already gone.
            finally:
                await actor.close()
                await asyncio.to_thread(operator.revoke, actor.identity)
        await asyncio.to_thread(operator.reconcile)
        print("Fixture folders deleted and devices revoked", flush=True)


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
