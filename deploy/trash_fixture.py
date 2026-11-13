"""Trash end to end on a review stack (spec #44): the gateway's /trash/ routes against real Nextcloud 33.

    deploy/.local/access-venv/bin/python -m deploy.trash_fixture --project anj-cloud-review-<tag> --port <port> \
        --evidence <dir> [--case list,restore,empty,expiry,share,read]

Pairs synthetic devices for the fixture accounts (Alice writes, a second Alice device can only view, Bob
writes), works only in fresh `Documents/anj-trash-<nonce>` and `anj-trash-<nonce>` folders, and places
one item in Alice's Nextcloud trash outside anj-cloud/ through the operator's backend path. At the end it
deletes what it made (also from the trash), revokes its devices and reconciles. Prints PASS lines and writes
`trash-fixture.json` to the evidence directory; no credential or code is printed.

Cases: `list` and `restore` and `empty` (AC3), `expiry` (AC4: the retention setting and Nextcloud's expiry
with backdated items), `share` (AC6: a delete inside someone else's share), `read` (AC7).
"""

import argparse
import asyncio
import json
from pathlib import Path
import secrets
import sys
from urllib.parse import quote

from deploy.access_fixture import pair
from deploy.access_operator import Operator
from deploy.dev import FIXTURE_USERS, Stack, private_directory

CASES = ("list", "restore", "empty", "expiry", "share", "read", "fixes")
DAY = 86400

# Runs inside the Nextcloud container as www-data: moves one trash item's deletion time back by the given
# seconds, the way it would be had it been deleted then (file name suffix, oc_files_trash and file cache).
BACKDATE = r'''
chdir('/var/www/html'); require_once 'lib/base.php';
$r = json_decode(stream_get_contents(STDIN), true);
$u = $r['user']; $id = $r['id']; $old = (string)$r['old']; $new = (string)$r['new'];
$db = \OC::$server->getDatabaseConnection();
$data = \OC::$server->getConfig()->getSystemValue('datadirectory');
if (!rename("$data/$u/files_trashbin/files/$id.d$old", "$data/$u/files_trashbin/files/$id.d$new")) { exit(2); }
$q = $db->getQueryBuilder();
$q->update('files_trash')->set('timestamp', $q->createNamedParameter($new))
  ->where($q->expr()->eq('user', $q->createNamedParameter($u)))
  ->andWhere($q->expr()->eq('id', $q->createNamedParameter($id)))
  ->andWhere($q->expr()->eq('timestamp', $q->createNamedParameter($old)));
if ($q->executeStatement() !== 1) { exit(3); }
$oldPath = "files_trashbin/files/$id.d$old"; $newPath = "files_trashbin/files/$id.d$new";
$q = $db->getQueryBuilder();
$q->update('filecache')->set('name', $q->createNamedParameter("$id.d$new"))
  ->set('path', $q->createNamedParameter($newPath))->set('path_hash', $q->createNamedParameter(md5($newPath)))
  ->where($q->expr()->eq('path_hash', $q->createNamedParameter(md5($oldPath))));
if ($q->executeStatement() < 1) { exit(4); }
echo "ok";
'''


def href(relative):
    return "/dav/" + "/".join(quote(part, safe="-._~") for part in relative.split("/"))


class Run:
    def __init__(self, stack, evidence):
        self.stack, self.evidence = stack, evidence
        self.facts = {}

    def passed(self, case, text, **facts):
        self.facts[case] = {"result": "PASS", "claim": text, **facts}
        print(f"PASS {case}: {text}", flush=True)

    async def trash(self, actor, expected=(200,)):
        body, _ = await actor.request("GET", "/trash/", expected=expected)
        return json.loads(body) if body else None

    async def put(self, actor, relative, data):
        await actor.request("PUT", href(relative), data=data, headers={"If-None-Match": "*"}, expected=(201,))

    async def mkcol(self, actor, relative):
        await actor.request("MKCOL", href(relative), headers={"If-None-Match": "*"}, expected=(201,))

    async def delete(self, actor, relative):
        etag = await actor.etag(href(relative)[len("/dav/"):])
        await actor.request("DELETE", href(relative), headers={"If-Match": etag}, expected=(204,))

    async def read(self, actor, relative):
        body, _ = await actor.request("GET", href(relative), expected=(200,))
        return body

    async def item(self, actor, path):
        listed = await self.trash(actor)
        rows = [row for row in listed["items"] if row["path"] == path]
        if not rows:
            raise RuntimeError("Expected trash item is not listed")
        return rows[0]

    def occ(self, *args):
        return self.stack.occ(*args).strip()

    # AC3 -----------------------------------------------------------------------------------------

    async def list_case(self, alice, folder, outside):
        await self.mkcol(alice, folder + "/Trip")
        await self.mkcol(alice, folder + "/Trip/Day 1")
        await self.put(alice, folder + "/Trip/Day 1/photo.jpg", b"photo bytes")
        await self.put(alice, folder + "/notes.txt", b"notes v1")
        await self.delete(alice, folder + "/notes.txt")
        listed = await self.trash(alice)
        paths = [row["path"] for row in listed["items"]]
        if folder + "/notes.txt" not in paths:
            raise RuntimeError("A deleted file is not listed in Trash")
        if any(outside in row["path"] for row in listed["items"]):
            raise RuntimeError("An item deleted outside anj-cloud/ is listed")
        row = await self.item(alice, folder + "/notes.txt")
        if row["expires"] - row["deleted"] != listed["trash_days"] * DAY or row["kind"] != "file" or row["size"] != 8:
            raise RuntimeError("Trash row fields differ")
        self.passed("list", "Trash lists items deleted under anj-cloud/ (id, path, kind, size, deleted, expires) and never "
                    "the item deleted outside it", trash_days=listed["trash_days"], rows=len(listed["items"]))

    async def restore_case(self, alice, folder):
        # Missing parents: the file, then its folders, are deleted; restoring the file recreates them.
        await self.delete(alice, folder + "/Trip/Day 1/photo.jpg")
        photo = await self.item(alice, folder + "/Trip/Day 1/photo.jpg")
        await self.delete(alice, folder + "/Trip")
        body, _ = await alice.request("POST", "/trash/%s/restore" % photo["id"], expected=(200,))
        result = json.loads(body)
        if result["path"] != folder + "/Trip/Day 1/photo.jpg" or await self.read(alice, result["path"]) != b"photo bytes":
            raise RuntimeError("Restore did not recreate the missing parents at the original path")
        top, _ = self.stack.backend_http("PROPFIND", "/remote.php/dav/files/%s/photo.jpg" % FIXTURE_USERS[0], FIXTURE_USERS[0],
                                         headers={"Depth": "0"})
        if top != 404:
            raise RuntimeError("A restore landed at the account's top level, outside anj-cloud/")
        # A taken name: the original path holds a new file; the restore never overwrites it.
        notes = await self.item(alice, folder + "/notes.txt")
        await self.put(alice, folder + "/notes.txt", b"notes v2")
        body, _ = await alice.request("POST", "/trash/%s/restore" % notes["id"], expected=(200,))
        taken = json.loads(body)
        if taken["path"] != folder + "/notes (restored).txt" or not taken["renamed"]:
            raise RuntimeError("A taken name was not restored as (restored)")
        if (await self.read(alice, folder + "/notes.txt"), await self.read(alice, taken["path"])) != (b"notes v2", b"notes v1"):
            raise RuntimeError("Restore changed the file at the taken name")
        # Taken apart from case: Nextcloud would put it beside; the gateway gives the next free name.
        await self.put(alice, folder + "/Report.TXT", b"report")
        await self.delete(alice, folder + "/Report.TXT")
        report = await self.item(alice, folder + "/Report.TXT")
        await self.put(alice, folder + "/report.txt", b"other")
        body, _ = await alice.request("POST", "/trash/%s/restore" % report["id"], expected=(200,))
        clash = json.loads(body)
        if clash["path"] != folder + "/Report (restored).TXT" or await self.read(alice, clash["path"]) != b"report":
            raise RuntimeError("A case-only clash was not restored as (restored)")
        fence = Operator(self.stack).call("fence")
        if fence["state"] != "clear":
            raise RuntimeError("A restore left writes fenced")
        self.passed("restore", "Restore recreates missing parent folders inside anj-cloud/, restores a taken name "
                    "(exactly or apart from case) as `name (restored).ext` without touching the file there, and leaves the fence clear",
                    paths=[result["path"], taken["path"], clash["path"]])

    async def empty_case(self, alice, folder, outside):
        for name in ("a.txt", "b.txt"):
            await self.put(alice, folder + "/" + name, name.encode())
            await self.delete(alice, folder + "/" + name)
        first = await self.item(alice, folder + "/a.txt")
        await alice.request("DELETE", "/trash/%s" % first["id"], expected=(204,))
        if any(row["id"] == first["id"] for row in (await self.trash(alice))["items"]):
            raise RuntimeError("Delete now left the item in Trash")
        body, _ = await alice.request("DELETE", "/trash/", expected=(200,))
        emptied = json.loads(body)
        if (await self.trash(alice))["items"]:
            raise RuntimeError("Empty Trash left anj-cloud/ items")
        if outside not in self.backend_trash(FIXTURE_USERS[0]):
            raise RuntimeError("Empty Trash removed an item deleted outside anj-cloud/")
        self.passed("empty", "Delete now removes one item; Empty Trash removes every anj-cloud/ item and leaves the item "
                    "deleted outside anj-cloud/ in the Nextcloud trash", emptied=emptied["deleted"])

    def backend_trash(self, user):
        body = self.stack.backend_http("PROPFIND", "/remote.php/dav/trashbin/%s/trash/" % user, user,
                                       b'<d:propfind xmlns:d="DAV:" xmlns:nc="http://nextcloud.org/ns"><d:prop>'
                                       b'<nc:trashbin-original-location/></d:prop></d:propfind>',
                                       {"Depth": "1", "Content-Type": "application/xml"})[1].decode()
        return body

    # AC4 -----------------------------------------------------------------------------------------

    async def expiry_case(self, alice, folder):
        setting = self.occ("config:system:get", "trashbin_retention_obligation")
        if setting != "7, 7":
            raise RuntimeError("trashbin_retention_obligation is not 7, 7: " + setting[:40])
        if (await self.trash(alice))["trash_days"] != 7:
            raise RuntimeError("The gateway does not advertise 7 trash days")
        for name in ("eight-days.txt", "six-days.txt"):
            await self.put(alice, folder + "/" + name, name.encode())
            await self.delete(alice, folder + "/" + name)
        rows = {name: await self.item(alice, folder + "/" + name) for name in ("eight-days.txt", "six-days.txt")}
        for name, days in (("eight-days.txt", 8), ("six-days.txt", 6)):
            old = rows[name]["deleted"]
            output = self.stack.compose("exec", "-T", "--user", "www-data", "nextcloud", "php", "-r", BACKDATE,
                                        data=json.dumps({"user": FIXTURE_USERS[0], "id": name, "old": old, "new": old - days * DAY}))
            if output.strip() != "ok":
                raise RuntimeError("Backdating a trash item failed")
        self.occ("trashbin:expire", FIXTURE_USERS[0])
        paths = [row["path"] for row in (await self.trash(alice))["items"]]
        if folder + "/eight-days.txt" in paths or folder + "/six-days.txt" not in paths:
            raise RuntimeError("Expiry did not remove exactly the item older than 7 days")
        self.passed("expiry", "occ config:system:get trashbin_retention_obligation prints `7, 7`, the gateway advertises "
                    "7 days, and Nextcloud's expiry removes an item deleted 8 days ago and keeps one deleted 6 days ago",
                    retention=setting)

    # AC6 -----------------------------------------------------------------------------------------

    async def share_case(self, alice, bob, shared):
        await self.mkcol(alice, shared)
        await self.put(alice, shared + "/f.txt", b"shared file")
        body, _ = await alice.request("POST", "/v1/shares", data=json.dumps({"path": shared, "recipient_id": FIXTURE_USERS[1],
                                                                              "permission": "edit"}),
                                      headers={"Content-Type": "application/json"}, expected=(201,))
        share_id = json.loads(body)["share_id"]
        incoming, _ = await bob.request("GET", "/v1/shares/incoming", expected=(200,))
        mount = [row for row in json.loads(incoming) if row["share_id"] == share_id][0]["path"]
        await self.delete(bob, mount + "/f.txt")
        owner = [row for row in (await self.trash(alice))["items"] if row["path"] == shared + "/f.txt"]
        recipient = [row for row in (await self.trash(bob))["items"] if row["path"] == mount + "/f.txt"]
        landed = "both" if owner and recipient else "owner" if owner else "recipient" if recipient else "neither"
        if landed == "neither":
            raise RuntimeError("A recipient's delete inside a share reached neither trash")
        restorer, row, where = (bob, recipient[0], mount) if recipient else (alice, owner[0], shared)
        body, _ = await restorer.request("POST", "/trash/%s/restore" % row["id"], expected=(200,))
        if json.loads(body)["path"] != where + "/f.txt" or await self.read(alice, shared + "/f.txt") != b"shared file":
            raise RuntimeError("Restore did not put the file back in the share")
        after_owner = [row["id"] for row in (await self.trash(alice))["items"] if row["path"] == shared + "/f.txt"]
        # S1: the share turned View only (straight through Nextcloud; the gateway makes only full-access shares):
        # the recipient's restore would land at the top level of the recipient's account, so it is refused.
        await self.put(alice, shared + "/g.txt", b"view only")
        await self.delete(bob, mount + "/g.txt")
        view = await self.item(bob, mount + "/g.txt")
        status, _ = self.stack.backend_http("PUT", "/ocs/v2.php/apps/files_sharing/api/v1/shares/%s?format=json" % share_id,
                                            FIXTURE_USERS[0], b"permissions=1",
                                            {"OCS-APIRequest": "true", "Content-Type": "application/x-www-form-urlencoded"})
        if status != 200:
            raise RuntimeError("Could not turn the share View only")
        await bob.request("POST", "/trash/%s/restore" % view["id"], expected=(403,))
        top, _ = self.stack.backend_http("PROPFIND", "/remote.php/dav/files/%s/g.txt" % FIXTURE_USERS[1], FIXTURE_USERS[1],
                                         headers={"Depth": "0"})
        await self.item(bob, mount + "/g.txt")
        if top != 404 or Operator(self.stack).call("fence")["state"] != "clear":
            raise RuntimeError("A View only restore landed outside anj-cloud/ or fenced writes")
        # S5: the share is gone; the recipient's item under Shared/ is never recreated as a folder of its own.
        await alice.request("DELETE", "/v1/shares/%s" % share_id, expected=(200,))
        await bob.request("POST", "/trash/%s/restore" % view["id"], expected=(409,))
        status, _ = self.stack.backend_http("PROPFIND", "/remote.php/dav/files/%s/anj-cloud/%s" % (FIXTURE_USERS[1], quote(mount)),
                                            FIXTURE_USERS[1], headers={"Depth": "0"})
        if status != 404:
            raise RuntimeError("A restore recreated a folder under Shared/")
        await bob.request("DELETE", "/trash/", expected=(200,))
        self.passed("share", f"A recipient's delete inside the owner's share lands in {landed} trash(es); each side's Trash "
                    "shows only its own item; the recipient's restore puts the file back in the share for the owner, and the "
                    "owner's own trash item stays until it expires" if landed == "both" else f"lands in the {landed}'s trash",
                    landed=landed, owner_item_after_recipient_restore=bool(after_owner))
        self.passed("share-fixes", "A restore into a share turned View only answers 403, stays in Trash and lands nowhere "
                    "(S1); once the share is gone the item is not recreated under Shared/ (409, S5)")

    # AC7 -----------------------------------------------------------------------------------------

    async def read_case(self, alice, reader, folder):
        await self.put(alice, folder + "/kept.txt", b"kept")
        await self.delete(alice, folder + "/kept.txt")
        row = await self.item(reader, folder + "/kept.txt")
        for method, path in (("POST", "/trash/%s/restore" % row["id"]), ("DELETE", "/trash/%s" % row["id"]), ("DELETE", "/trash/")):
            await reader.request(method, path, expected=(403,))
        await self.item(alice, folder + "/kept.txt")
        self.passed("read", "A read-grant device lists Trash; restore, delete and empty answer 403 and change nothing")

    # Review fixes S4, S6 ---------------------------------------------------------------------------

    async def fixes_case(self, alice, folder):
        await self.mkcol(alice, folder + "/Trip")
        await self.put(alice, folder + "/Trip/photo.jpg", b"photo")
        await self.delete(alice, folder + "/Trip/photo.jpg")
        photo = await self.item(alice, folder + "/Trip/photo.jpg")
        await self.delete(alice, folder + "/Trip")
        await self.mkcol(alice, folder + "/trip")
        await alice.request("POST", "/trash/%s/restore" % photo["id"], expected=(409,))
        listing, _ = await alice.request("PROPFIND", href(folder) + "/", headers={"Depth": "1"}, expected=(207,))
        if b"/Trip/" in listing:
            raise RuntimeError("A folder was recreated beside its case twin")
        ids = []
        for name in ("u1.txt", "u2.txt", "u3.txt"):
            await self.put(alice, folder + "/" + name, name.encode())
            await self.delete(alice, folder + "/" + name)
            ids.append((await self.item(alice, folder + "/" + name))["id"])
        await self.put(alice, folder + "/u3.txt", b"taken")
        body, _ = await alice.request("POST", "/trash/restore", data=json.dumps({"ids": ids + ["1"]}),
                                      headers={"Content-Type": "application/json"}, expected=(200,))
        results = json.loads(body)["results"]
        paths = [row.get("path") for row in results]
        if (paths[:3] != [folder + "/u1.txt", folder + "/u2.txt", folder + "/u3 (restored).txt"] or results[3].get("status") != 404
                or await self.read(alice, folder + "/u3 (restored).txt") != b"u3.txt"):
            raise RuntimeError("Batch restore results differ: %r" % results)
        if Operator(self.stack).call("fence")["state"] != "clear":
            raise RuntimeError("Batch restore left writes fenced")
        self.passed("fixes", "A missing folder is not recreated beside a case twin (409, S4); one batch restore brings back "
                    "three items with a per-item result, a taken name as (restored), an unknown id as 404 (S6)",
                    batch=results)


async def scenario(stack, evidence, cases):
    stack.check()
    stack.accounts()
    operator = Operator(stack)
    run = Run(stack, evidence)
    nonce = secrets.token_hex(4)
    clients = stack.local / "operator/clients" / ("trash-" + nonce)
    private_directory(clients)
    folder, shared, outside = "Documents/anj-trash-" + nonce, "anj-trash-" + nonce, "outside-trash-" + nonce + ".txt"
    actors = []
    try:
        alice = await pair(stack, operator, FIXTURE_USERS[0], clients / "alice")
        actors.append(alice)
        await run.mkcol(alice, folder)
        # The item outside anj-cloud/, placed and deleted through the operator's backend path.
        stack.dav("PUT", FIXTURE_USERS[0], outside, data=b"outside", headers={"Content-Type": "application/octet-stream"},
                  expected=(201,))
        stack.dav("DELETE", FIXTURE_USERS[0], outside, expected=(204,))
        if "list" in cases:
            await run.list_case(alice, folder, outside)
        if "restore" in cases:
            await run.restore_case(alice, folder)
        if "read" in cases:
            reader = await pair(stack, operator, FIXTURE_USERS[0], clients / "reader", rights="read")
            actors.append(reader)
            await run.read_case(alice, reader, folder)
        if "expiry" in cases:
            await run.expiry_case(alice, folder)
        if "share" in cases:
            bob = await pair(stack, operator, FIXTURE_USERS[1], clients / "bob")
            actors.append(bob)
            await run.share_case(alice, bob, shared)
        if "fixes" in cases:
            await run.fixes_case(alice, folder)
        if "empty" in cases:
            await run.empty_case(alice, folder, outside)
    finally:
        (evidence / "trash-fixture.json").write_text(json.dumps(run.facts, indent=2) + "\n")
        try:
            if actors:
                for path in (folder, shared):
                    try:
                        await run.delete(actors[0], path)
                    except RuntimeError:
                        pass
                for actor in actors:
                    try:
                        await actor.request("DELETE", "/trash/", expected=(200, 403))
                    except RuntimeError:
                        pass
            body = run.backend_trash(FIXTURE_USERS[0])
            for name in [part.split("<")[0] for part in body.split("trash/")[1:]]:
                if name.startswith(outside):
                    stack.backend_http("DELETE", "/remote.php/dav/trashbin/%s/trash/%s" % (FIXTURE_USERS[0], quote(name)),
                                       FIXTURE_USERS[0])
        finally:
            for actor in actors:
                await actor.close()
                await asyncio.to_thread(operator.revoke, actor.identity)
            await asyncio.to_thread(operator.reconcile)
        print("Fixture folders and trash items deleted and devices revoked", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--project", required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--case", default=",".join(CASES), help="Comma-separated: " + ", ".join(CASES))
    args = parser.parse_args()
    cases = set(args.case.split(","))
    if cases - set(CASES):
        parser.error("Unknown case: " + ", ".join(sorted(cases - set(CASES))))
    args.evidence.mkdir(parents=True, exist_ok=True)
    asyncio.run(scenario(Stack(args.project, args.port), args.evidence, cases))


if __name__ == "__main__":
    sys.exit(main())
