"""Spec #49 Gateway and D4 end to end on a review stack (AC9): the gateway accepts every name the
cloud can store and refuses untrimmed ones over real TLS, and the name migration renames seeded
whitespace names once while a second run changes nothing.

    deploy/.local/access-venv/bin/python -m deploy.name_acceptance_fixture --project anj-cloud-review-<tag> --port <port> --evidence <dir>

Pairs one synthetic device, works only in a fresh Documents/anj-names-<nonce> folder, then deletes
that folder and revokes the device. Prints PASS lines; no credential or code is printed. The
migration's counts and event lines go to the evidence directory (they carry no name).
"""

import argparse
import asyncio
import json
from pathlib import Path
import secrets
import sys
from urllib.parse import quote, unquote
from xml.etree import ElementTree as ET

from deploy.access_fixture import pair
from deploy.access_operator import Operator
from deploy.dev import FIXTURE_USERS, Stack, private_directory

CREATE = {"If-None-Match": "*"}
ACCEPTED = ("a:b?.txt", "CON.txt", "x.", "Report.pdf", "report.pdf", "star*.txt", "café.txt")
SEEDED = (" lead.txt", "trail.txt ", " report.pdf", " Trip ", " Trip /photo.jpg ")
MIGRATED = ["Trip", "Trip/photo.jpg", "lead.txt", "report (2).pdf", "trail.txt"]


def href(relative):
    return "/dav/" + "/".join(quote(part, safe="-._~") for part in relative.split("/"))


async def refused(actor, method, relative, reason, **headers):
    body, _ = await actor.request(method, href(relative), data=b"x" if method == "PUT" else None, headers=headers, expected=(422,))
    answer = json.loads(body)
    if (answer.get("error"), answer.get("reason")) != ("name-not-portable", reason):
        raise RuntimeError(f"{method} refusal reason differs: {answer.get('reason')}")


async def names(actor, folder):
    """Every name below `folder`, relative to it (Depth 1, walked)."""
    found, pending = [], [folder]
    while pending:
        current = pending.pop()
        listing, _ = await actor.request("PROPFIND", href(current) + "/", headers={"Depth": "1"}, expected=(207,))
        for node in ET.fromstring(listing).iter("{DAV:}response"):
            path = unquote(node.findtext("{DAV:}href")).rstrip("/")
            relative = path.split("/dav/", 1)[1]
            if relative == current:
                continue
            found.append(relative[len(folder) + 1:])
            if node.find(".//{DAV:}collection") is not None:
                pending.append(relative)
    return sorted(found)


async def acceptance(actor, folder):
    for name in (" lead.txt", "trail.txt ", "\tTab.txt"):
        await refused(actor, "PUT", folder + "/" + name, "untrimmed", **CREATE)
    await refused(actor, "MKCOL", folder + "/ Trip", "untrimmed", **CREATE)
    await refused(actor, "PUT", folder + "/" + "x" * 300 + ".txt", "tooLong", **CREATE)
    await refused(actor, "PUT", folder + "/.htaccess", "forbiddenName", **CREATE)
    for name in ACCEPTED:
        await actor.request("PUT", href(folder + "/" + name), data=b"server " + name.encode(), headers=CREATE, expected=(201,))
    await actor.request("MKCOL", href(folder + "/AUX"), headers=CREATE, expected=(201,))
    etag = await actor.etag(folder + "/star*.txt")
    move = {"If-Match": etag, "Overwrite": "F"}
    await refused(actor, "MOVE", folder + "/star*.txt", "untrimmed", Destination=actor.stack.origin + href(folder + "/star.txt "), **move)
    await actor.request("MOVE", href(folder + "/star*.txt"), headers={"Destination": actor.stack.origin + href(folder + "/prn"), **move},
                        expected=(201,))
    stored = await names(actor, folder)
    expected = sorted(set(ACCEPTED) - {"star*.txt"} | {"AUX", "prn"})
    if stored != expected:
        raise RuntimeError("Stored names differ: " + json.dumps(stored))
    print("PASS gateway refuses untrimmed (422 untrimmed), over-long and .htaccess names and accepts "
          "a:b?.txt, CON.txt, x., Report.pdf beside report.pdf, star*.txt, AUX and a MOVE to prn", flush=True)
    return stored


def event_lines(stack):
    logs = stack.compose("logs", "--no-color", "--no-log-prefix", "access")
    lines = []
    for line in logs.splitlines():
        try:
            record = json.loads(line)
        except ValueError:
            continue
        if isinstance(record, dict) and record.get("event") == "name-migration":
            lines.append(record)
    return lines


async def migration(stack, operator, actor, folder, before, run):
    # Seeded straight into Nextcloud: the gateway now refuses these names, as it should.
    user = FIXTURE_USERS[0]
    base = "anj-cloud/" + folder + "/"
    for name in SEEDED:
        if name == " Trip ":
            stack.dav("MKCOL", user, base + name, expected=(201,))
        else:
            stack.dav("PUT", user, base + name, data=b"seeded", expected=(201,))
    seeded = await names(actor, folder)
    if sorted(set(seeded) - set(before)) != sorted(SEEDED):
        raise RuntimeError("Seeded names differ: " + json.dumps(seeded))
    first = await asyncio.to_thread(operator.migrate_names)
    after_first = await names(actor, folder)
    second = await asyncio.to_thread(operator.migrate_names)
    after_second = await names(actor, folder)
    events = event_lines(stack)
    (run / "migration.json").write_text(json.dumps({"first": first, "second": second, "events": events}, indent=2) + "\n")
    if sorted(set(after_first) - set(before)) != MIGRATED:
        raise RuntimeError("Migrated names differ: " + json.dumps(after_first))
    if first["renamed"] < 4 or first["failed"] or first["accounts_failed"]:
        raise RuntimeError("First migration counts differ: " + json.dumps(first))
    if second["renamed"] or second["failed"] or second["accounts_failed"] or after_second != after_first:
        raise RuntimeError("Second migration changed something: " + json.dumps(second))
    if len(events) < 2 * first["accounts"] or not all(event["complete"] for event in events):
        raise RuntimeError("Migration event lines differ")
    print("PASS migration renamed the seeded whitespace names once (" + json.dumps(first, separators=(",", ":")) +
          "); a second run renamed nothing (" + json.dumps(second, separators=(",", ":")) + "); "
          f"{len(events)} counts-only name-migration event lines", flush=True)


async def scenario(stack, run):
    stack.check()
    stack.accounts()
    operator = Operator(stack)
    nonce = secrets.token_hex(4)
    clients = stack.local / "operator/clients" / ("accept-" + nonce)
    private_directory(clients)
    folder = "Documents/anj-names-" + nonce
    actor = None
    try:
        actor = await pair(stack, operator, FIXTURE_USERS[0], clients / "alice")
        await actor.request("MKCOL", href(folder), headers=CREATE, expected=(201,))
        before = await acceptance(actor, folder)
        await migration(stack, operator, actor, folder, before, run)
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
