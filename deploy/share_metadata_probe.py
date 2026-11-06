"""Do share changes made outside the client change folder ETags? (spec #33 I4, #79 review item 4)

    deploy/.local/access-venv/bin/python -m deploy.share_metadata_probe --project anj-cloud-review-i4 \
        --port 18904 --evidence <dir>

The incremental listing reuses `oc:permissions` and `oc:share-types` from a stored subtree while the
folder's ETag is unchanged. This probe changes shares the way the web interface does (the OCS sharing API,
inside the Nextcloud container), then reads the affected folders and their ancestors over WebDAV:

1. Alice shares a folder five levels deep with Bob, then unshares it (Alice's share-types).
2. Bob shares a folder with Alice, changes the permission to read-only, then back (Alice's permissions).

For each step it records whether the folder's own ETag and each ancestor's ETag changed, and whether the
gateway's incoming-share list (which the client fingerprints every listing) changed. Synthetic fixture
accounts only; both fixture folders are deleted at the end. Prints INFO lines and writes probe.json.
"""

import argparse
import asyncio
import json
from pathlib import Path
import secrets
import sys
from urllib.parse import unquote, urlencode
from xml.etree import ElementTree as ET

from deploy.access_fixture import pair
from deploy.access_operator import Operator
from deploy.dev import FIXTURE_USERS, Stack, private_directory
from deploy.name_fixture import href

ALICE, BOB = FIXTURE_USERS
PROPS = (b'<?xml version="1.0"?><d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns"><d:prop>'
         b'<d:getetag/><oc:permissions/><oc:share-types/></d:prop></d:propfind>')
OC = "{http://owncloud.org/ns}"


async def state(actor, path):
    """{'etag', 'permissions', 'shared'} of `path` as the client reads it through the gateway (Depth:0)."""
    body, _ = await actor.request("PROPFIND", href(path) + "/" if path else "/dav/", data=PROPS,
                                  headers={"Depth": "0"}, expected=(207,))
    node = ET.fromstring(body).find("{DAV:}response")
    types = node.find(f".//{OC}share-types")
    return {"etag": node.findtext(".//{DAV:}getetag"), "permissions": node.findtext(f".//{OC}permissions"),
            "shared": types is not None and len(types) > 0}


def chain(path):
    """`path` and each ancestor up to the anj-cloud root ('')."""
    parts = path.split("/")
    return ["/".join(parts[:n]) for n in range(len(parts), -1, -1)]


def ocs(stack, user, method, route, fields=None):
    # The web interface's sharing API; parameters in the query (Nextcloud reads both).
    query = urlencode({"format": "json", **(fields or {})})
    status, data = stack.backend_http(method, "/ocs/v2.php/apps/files_sharing/api/v1/shares" + route + "?" + query,
                                      user, None, {"OCS-APIRequest": "true"})
    if status not in (200, 201):
        raise RuntimeError(f"OCS {method} {route or '/'} returned {status}")
    return json.loads(data)["ocs"]["data"]


async def incoming(actor):
    """The gateway's incoming-share list, which the client fingerprints on every listing pass."""
    body, _ = await actor.request("GET", "/v1/shares/incoming")
    return json.loads(body)


def compare(before, after, paths):
    return {path or "(root)": {"etag_changed": before[path]["etag"] != after[path]["etag"],
                               "permissions": [before[path]["permissions"], after[path]["permissions"]],
                               "shared": [before[path]["shared"], after[path]["shared"]]} for path in paths}


async def probe(args):
    stack = Stack(args.project, args.port)
    stack.check()
    stack.accounts()
    operator = Operator(stack)
    clients = stack.local / "operator/clients" / ("meta-" + secrets.token_hex(4))
    private_directory(clients)
    alice = bob = None
    nonce = secrets.token_hex(4)
    own, theirs = f"Meta-{nonce}", f"MetaShare-{nonce}"
    deep = own + "/M1/M2/M3/M4"
    results = {}
    try:
        alice = await pair(stack, operator, ALICE, clients / "alice")
        bob = await pair(stack, operator, BOB, clients / "bob")
        for actor, path in ((alice, deep), (bob, theirs + "/N1")):
            for folder in chain(path)[::-1][1:]:
                await actor.request("MKCOL", href(folder), headers={"If-None-Match": "*"}, expected=(201,))
        # 1. Alice shares a deep folder of her own from the web, then unshares it.
        paths = chain(deep)
        before = {p: await state(alice, p) for p in paths}
        share = ocs(stack, ALICE, "POST", "", {"path": f"/anj-cloud/{deep}", "shareType": 0, "shareWith": BOB,
                                               "permissions": 1})
        after = {p: await state(alice, p) for p in paths}
        results["outgoing share created"] = compare(before, after, paths)
        ocs(stack, ALICE, "DELETE", "/" + str(share["id"]))
        gone = {p: await state(alice, p) for p in paths}
        results["outgoing share removed"] = compare(after, gone, paths)
        # 2. Bob shares with Alice; Bob then changes her permission.
        share = ocs(stack, BOB, "POST", "", {"path": f"/anj-cloud/{theirs}", "shareType": 0, "shareWith": ALICE,
                                             "permissions": 31})
        mount = "Shared/" + theirs
        paths = [mount + "/N1", mount, "Shared", ""]
        listed = await incoming(alice)
        before = {p: await state(alice, p) for p in paths}
        ocs(stack, BOB, "PUT", "/" + str(share["id"]), {"permissions": 1})
        after = {p: await state(alice, p) for p in paths}
        results["incoming permission edit to read-only"] = compare(before, after, paths)
        results["incoming permission edit to read-only"]["incoming list changed"] = await incoming(alice) != listed
        listed = await incoming(alice)
        ocs(stack, BOB, "PUT", "/" + str(share["id"]), {"permissions": 31})
        back = {p: await state(alice, p) for p in paths}
        results["incoming permission edit back to edit"] = compare(after, back, paths)
        results["incoming permission edit back to edit"]["incoming list changed"] = await incoming(alice) != listed
        ocs(stack, BOB, "DELETE", "/" + str(share["id"]))
    finally:
        for actor, top in ((alice, own), (bob, theirs)):
            if actor is None:
                continue
            try:
                etag = await actor.etag(top + "/")
                await actor.request("DELETE", href(top), headers={"If-Match": etag}, expected=(204,))
            except RuntimeError:
                pass
            finally:
                await actor.close()
                await asyncio.to_thread(operator.revoke, actor.identity)
        await asyncio.to_thread(operator.reconcile)
    (args.evidence / "probe.json").write_text(json.dumps(results, indent=2) + "\n")
    for step, value in results.items():
        print(f"INFO {step}: {json.dumps(value)}", flush=True)
    print("Fixture folders deleted and devices revoked", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    args = parser.parse_args()
    args.evidence.mkdir(parents=True, exist_ok=True)
    asyncio.run(probe(args))
    return 0


if __name__ == "__main__":
    sys.exit(main())
