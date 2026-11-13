"""One-time name migration (spec #49 Gateway, D4): existing cloud names meet the name rule.

The gateway now refuses a new untrimmed name (name_rule.cloud_check), so the names that predate
that refusal are fixed once, at deploy: every item of an account's own tree whose name has
leading or trailing whitespace (R1, including the ` (n)` suffix) or is over the cloud's length
limit (R2) is renamed to name_rule.cleanup's result. Clients see ordinary cloud renames: the
same item (same file ID) under a new name.

- Own tree only: an item another account owns (a share mounted here) is neither renamed nor
  entered; its owner's own pass renames it.
- Each folder is listed and renamed under the single mutation lock, so no client write lands
  between the listing and the renames; the lock is released between folders.
- Every rename is recorded in the write fence like any other mutation. A rename whose outcome
  stays unknown after re-reading the folder leaves the fence closed for operator recovery and
  ends the pass.
- Idempotent: a second pass finds nothing to rename. Each pass writes one `name-migration`
  event line (observe.Events: stdout, journald in production) and returns counts only, never a
  name or an account.
"""

from urllib.parse import quote, unquote, urlsplit

from aiohttp import BasicAuth
from defusedxml import ElementTree as SafeET

from . import name_rule
from .observe import iso
from .mutations import SIBLING_XML, bounded_body
from .protocol import Rejection, backend_root

LISTING = (b'<d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns"><d:prop>'
           b'<d:resourcetype/><oc:fileid/><oc:owner-id/></d:prop></d:propfind>')
OC = "{http://owncloud.org/ns}"
# Answers after which the backend has certainly not renamed the item.
REFUSED = (400, 401, 403, 404, 409, 412, 415, 423)
# The problems a pass fixes; other cloud_check reasons cannot exist in the cloud (Nextcloud refuses them).
FIXED = ("untrimmed", "tooLong")


def encoded(relative):
    return "/".join(quote(part, safe="-._~") for part in relative.split("/")) if relative else ""


class Pass:
    def __init__(self, gateway, principal):
        self.gateway, self.principal = gateway, principal
        self.counts = {"folders": 0, "renamed": 0, "unresolved": 0, "failed": 0}

    def url(self, relative):
        return self.gateway.backend + backend_root(self.principal.uid) + encoded(relative)

    async def listing(self, folder):
        """[{name, folder, fileid, own}] directly inside `folder`, or None when it is gone."""
        url = self.url(folder)
        async with self.gateway.session.request("PROPFIND", url, data=LISTING, auth=BasicAuth(self.principal.uid, self.principal.token),
                                                headers={"Depth": "1", "Content-Type": "application/xml", "Accept-Encoding": "identity"},
                                                allow_redirects=False) as response:
            if response.status == 404:
                return None
            if response.status != 207:
                raise Rejection("Could not read a folder for the name migration")
            try:
                content = await bounded_body(response, SIBLING_XML)
            except ValueError:
                raise Rejection("A folder is too large for the name migration") from None
        base = unquote(urlsplit(url).path).rstrip("/") + "/"
        children = []
        for node in SafeET.fromstring(content, forbid_dtd=True).findall("{DAV:}response"):
            path = unquote(urlsplit(node.findtext("{DAV:}href") or "").path).rstrip("/")
            name = path[len(base):] if path.startswith(base) else ""
            if not name or "/" in name:
                continue
            fileid = (node.findtext(".//" + OC + "fileid") or "").strip()
            children.append({"name": name, "folder": node.find(".//{DAV:}resourcetype/{DAV:}collection") is not None,
                             "fileid": int(fileid) if fileid.isdigit() else None,
                             "own": (node.findtext(".//" + OC + "owner-id") or "").strip() == self.principal.uid})
        # Oldest first: of two names that clean up to the same one, the older item keeps it (R1).
        children.sort(key=lambda child: (child["fileid"] is None, child["fileid"] or 0, child["name"]))
        return children

    async def move(self, source, target):
        """The backend status of one MOVE, or None when no answer arrived."""
        try:
            async with self.gateway.session.request("MOVE", self.url(source), auth=BasicAuth(self.principal.uid, self.principal.token),
                                                    headers={"Destination": self.url(target), "Overwrite": "F"},
                                                    allow_redirects=False) as response:
                await response.read()
                return response.status
        except Exception:  # noqa: BLE001 - a lost answer: the backend may have applied it
            return None

    async def rename(self, folder, name, new):
        """True once the item is under `new`, False when the backend certainly did not rename it."""
        prefix = folder + "/" if folder else ""
        self.gateway.registry.mutation_begin(self.principal.reference, "name-migration")
        status = await self.move(prefix + name, prefix + new)
        if status in (201, 204) or status in REFUSED:
            self.gateway.registry.mutation_finish()
            return status in (201, 204)
        try:
            after = {child["name"] for child in await self.listing(folder) or []}
        except Exception:  # noqa: BLE001 - an unreadable folder is an unknown outcome
            after = None
        if after is None or (name in after) == (new in after):
            # The fence stays closed for operator recovery, as for any write whose outcome is unknown.
            raise Rejection("A name migration rename has an unknown outcome; writes are paused until the operator checks it")
        self.gateway.registry.mutation_finish()
        return new in after

    async def folder(self, folder):
        """Renames what needs it directly inside `folder`; returns the own subfolders to enter."""
        async with self.gateway.mutations.lock:
            if not self.gateway.registry.mutation_ready():
                raise Rejection("Writes are fenced pending scoped operator recovery")
            children = await self.listing(folder)
            if children is None:
                return []
            self.counts["folders"] += 1
            names = [child["name"] for child in children]
            subfolders = []
            for child in children:
                if not child["own"]:
                    continue
                name = child["name"]
                if name_rule.cloud_check(name) in FIXED:
                    new = name_rule.cleanup(name, [other for other in names if other != name], child["folder"])
                    if new == name:
                        self.counts["unresolved"] += 1
                    elif await self.rename(folder, name, new):
                        self.counts["renamed"] += 1
                        names[names.index(name)] = name = new
                    else:
                        self.counts["failed"] += 1
                if child["folder"]:
                    subfolders.append((folder + "/" if folder else "") + name)
            return subfolders

    async def run(self):
        pending = [""]
        while pending:
            pending[:0] = await self.folder(pending.pop(0))
        return self.counts


async def migrate(gateway, principal):
    """One pass over `principal`'s own tree; the counts. A pass that stops early still writes its
    event line, with `"complete": false`, and raises."""
    migration, complete = Pass(gateway, principal), False
    try:
        counts = await migration.run()
        complete = True
        return counts
    finally:
        gateway.events.emit({"time": iso(gateway.events.clock()), "event": "name-migration", "complete": complete, **migration.counts})
