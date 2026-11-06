"""Portable names end to end on a review stack (decision #120): the gateway refuses blocked
creates and renames over real TLS, and a real Linux client shows the row and syncs after Rename.

    deploy/.local/access-venv/bin/python -m deploy.name_fixture --project anj-cloud-review-s1 --port 18891

Pairs one synthetic device, works only in a fresh Documents/anj-names-<nonce> folder, then deletes
that folder and revokes the device. Prints PASS lines; no credential or code is printed.
"""

import argparse
import asyncio
import json
import os
from pathlib import Path
import secrets
import subprocess
import sys
from urllib.parse import quote, unquote
from xml.etree import ElementTree as ET

from deploy.access_fixture import pair
from deploy.access_operator import Operator
from deploy.dev import FIXTURE_USERS, Stack, private_directory

CLIENT = Path(__file__).resolve().parent.parent / "apps/client"
FLUTTER = Path(os.environ.get("FLUTTER_SDK", os.path.expanduser("~/.local/share/anj-cloud/toolchains/flutter-3.47.9")))


def href(relative):
    return "/dav/" + "/".join(quote(part, safe="-._~") for part in relative.split("/"))


async def refused(actor, method, relative, reason, **headers):
    body, _ = await actor.request(method, href(relative), data=b"x" if method == "PUT" else None, headers=headers, expected=(422,))
    answer = json.loads(body)
    if (answer.get("error"), answer.get("reason")) != ("name-not-portable", reason):
        raise RuntimeError(f"{method} refusal reason differs: {answer.get('reason')}")


async def gateway_proofs(actor, folder):
    create = {"If-None-Match": "*"}
    for name, reason in (("CON.txt", "reserved"), ("nul", "reserved"), ("draft.", "trailingDotOrSpace"),
                         ("draft ", "trailingDotOrSpace"), ("a:b.txt", "invalidCharacter"), ("star*.txt", "invalidCharacter")):
        await refused(actor, "PUT", folder + "/" + name, reason, **create)
    await refused(actor, "MKCOL", folder + "/AUX", "reserved", **create)
    for name in ("notes.txt", "caf\u00e9.txt", ".bashrc"):
        await actor.request("PUT", href(folder + "/" + name), data=b"server " + name.encode(), headers=create, expected=(201,))
    await refused(actor, "PUT", folder + "/NOTES.TXT", "clash", **create)
    # Nextcloud resolves an NFD path to the existing NFC item, so the gateway sees an overwrite
    # without If-Match and refuses it (428) before the name check; either way nothing is written.
    await actor.request("PUT", href(folder + "/cafe\u0301.txt"), data=b"x", headers=create, expected=(422, 428))
    await refused(actor, "MKCOL", folder + "/Notes.txt", "clash", **create)
    etag = await actor.etag(folder + "/.bashrc")
    move = {"If-Match": etag, "Overwrite": "F"}
    await refused(actor, "MOVE", folder + "/.bashrc", "reserved", Destination=actor.stack.origin + href(folder + "/prn.rc"), **move)
    await refused(actor, "MOVE", folder + "/.bashrc", "clash", Destination=actor.stack.origin + href(folder + "/Notes.txt"), **move)
    # How Nextcloud stores a new NFD name (informational: decides whether NFC/NFD can be siblings).
    await actor.request("PUT", href(folder + "/probe-e\u0301.txt"), data=b"p", headers=create, expected=(201,))
    listing, _ = await actor.request("PROPFIND", href(folder) + "/", headers={"Depth": "1"}, expected=(207,))
    stored = [unquote(node.text.rstrip("/").rsplit("/", 1)[-1]) for node in ET.fromstring(listing).iter("{DAV:}href")]
    probe = next((name for name in stored if name.startswith("probe-")), None)
    print("INFO Nextcloud stores a new NFD name as " + ("NFD (byte-exact)" if probe == "probe-e\u0301.txt" else
          "NFC (normalized)" if probe == "probe-\u00e9.txt" else repr(probe)), flush=True)
    etag = await actor.etag(href(folder + "/" + probe)[len("/dav/"):])
    await actor.request("DELETE", href(folder + "/" + probe), headers={"If-Match": etag}, expected=(204,))
    listing, _ = await actor.request("PROPFIND", href(folder) + "/", headers={"Depth": "1"}, expected=(207,))
    names = sorted(ET.fromstring(listing).itertext())
    if any("CON" in text or "NOTES" in text for text in names):
        raise RuntimeError("A refused name reached the server")
    print("PASS gateway refuses reserved, trailing, invalid-character and case/normalization-clash creates and renames (422 name-not-portable)", flush=True)


async def scenario(stack, run):
    stack.check()
    stack.accounts()
    operator = Operator(stack)
    nonce = secrets.token_hex(4)
    clients = stack.local / "operator/clients" / ("names-" + nonce)
    private_directory(clients)
    folder = "Documents/anj-names-" + nonce
    actor = None
    try:
        actor = await pair(stack, operator, FIXTURE_USERS[0], clients / "alice")
        await actor.request("MKCOL", href(folder), headers={"If-None-Match": "*"}, expected=(201,))
        await gateway_proofs(actor, folder)
        config = clients / "client.json"
        config.write_text(json.dumps({"origin": stack.origin, "ca": str(stack.local / "operator/issuer.crt"),
                                      "certificate": str(clients / "alice/device.crt"), "key": str(clients / "alice/device.key"),
                                      "work": str(run / "client"), "folder": folder}))
        config.chmod(0o600)
        result = subprocess.run([str(FLUTTER / "bin/dart"), "run", "tool/name_policy_fixture.dart", str(config)], cwd=CLIENT,
                                capture_output=True, text=True, timeout=600,
                                env={**os.environ, "ANJ_ROOTFS_LIBRARY": str(CLIENT / ".dart_tool/libanj_rootfs.so")})
        line = (result.stdout.strip().splitlines() or ["{}"])[-1]
        (run / "client-result.json").write_text(line + "\n")
        if result.returncode != 0:
            raise RuntimeError("Linux client claims failed: " + line[:2000])
        print("PASS Linux client keeps blocked and clashing names local with the row, the gateway's race refusal shows it too, "
              "and Rename syncs the file: " + ", ".join(json.loads(line)["claims"]), flush=True)
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
