"""Trash (spec #44): the calling device's own Nextcloud trash, limited to what was deleted under anj-cloud/.

Every route is authenticated by the device certificate exactly like /dav/ and acts with that device's own
Nextcloud credential on `/remote.php/dav/trashbin/<uid>/`. Items whose original location is outside the
enrolled root are never listed, restored or deleted. Restore and deletion run under the single mutation
lock and write fence: a restore records its intent, creates missing parent folders first (Nextcloud would
otherwise put the item at the account's top level, outside anj-cloud/), never overwrites, and reads an
unknown outcome back; the fence stays closed only when that read-back is inconclusive.

Nextcloud 33 (checked on the review stack): a restore always goes to the original location, whatever
name the MOVE names, and an exact name already there gives Nextcloud's own `name (restored).ext`. A
recipient's delete inside someone else's share lands in both trashes: the owner's (original location
`/anj-cloud/...`, with a leading slash) and the recipient's own (under its mount). Each side restores
its own item back into the share; the other side's item stays until it expires.
"""

import json
import posixpath
from urllib.parse import quote, unquote, urlsplit

from aiohttp import BasicAuth, web
from defusedxml import ElementTree as SafeET

from . import portable_names
from .mutations import SIBLING_XML, bounded_body, split_leaf
from .protocol import backend_root, encode_filename_path
from .sharing import ShareError

ROOT = "anj-cloud/"
DAYS_SETTING = "trash_days"
DEFAULT_DAYS = 7
MAX_DAYS = 3650
DAY = 86400
TRASH_PROPFIND = (b'<d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns" xmlns:nc="http://nextcloud.org/ns">'
                  b'<d:prop><nc:trashbin-filename/><nc:trashbin-original-location/><nc:trashbin-deletion-time/>'
                  b'<oc:size/><d:getcontentlength/><d:resourcetype/><oc:fileid/></d:prop></d:propfind>')
NC = "{http://nextcloud.org/ns}"
OC = "{http://owncloud.org/ns}"
# Known refusals of a dispatched trash request: nothing changed.
KNOWN_FAILURES = (400, 401, 403, 404, 409, 412, 423)


class TrashError(ShareError):
    """A curated trash refusal: an HTTP status and a message that never carries a path."""


def valid_days(value):
    if type(value) is not int or not 1 <= value <= MAX_DAYS:
        raise TrashError(400, "Trash days must be a whole number from 1 to %d" % MAX_DAYS)
    return value


def restored_name(name, folder, n):
    """`name (restored).ext`, then `(restored 2)` and so on; a folder keeps no extension."""
    base, extension = (name, "") if folder else posixpath.splitext(name)
    if not base:
        base, extension = name, ""
    return "%s (restored%s)%s" % (base, "" if n == 1 else " %d" % n, extension)


def root_relative(location):
    """The decoded path below anj-cloud/ of a trash item's original location, else None.

    Nextcloud reports an owner's item deleted by a share recipient with a leading slash."""
    if not isinstance(location, str):
        return None
    location = location.lstrip("/")
    if not location.startswith(ROOT):
        return None
    relative = location[len(ROOT):].rstrip("/")
    parts = relative.split("/")
    if not relative or any(part in ("", ".", "..") for part in parts):
        return None
    return relative


class Trash:
    def __init__(self, gateway):
        self.gateway = gateway

    @property
    def registry(self):
        return self.gateway.registry

    # Settings.

    @property
    def days(self):
        """The retention the deployment read back from Nextcloud (decision: `trash_days`), else 7."""
        try:
            stored = self.registry.setting(DAYS_SETTING)
            return int(stored) if stored is not None else DEFAULT_DAYS
        except (TypeError, ValueError):
            return DEFAULT_DAYS

    def set_days(self, value):
        self.registry.set_setting(DAYS_SETTING, valid_days(value))
        return self.days

    # Routes.

    def add_routes(self, router):
        router.add_get("/trash/", self.list_route)
        router.add_delete("/trash/", self.empty_route)
        router.add_post("/trash/{item_id}/restore", self.restore_route)
        router.add_delete("/trash/{item_id}", self.delete_route)

    def caller(self, request, write=False):
        device = self.gateway.identity(request)
        if request.query_string:
            raise TrashError(400, "Queries are unsupported")
        if write and device["rights"] != "write":
            raise TrashError(403, "This device can only view")
        return device

    @staticmethod
    def item_id(request):
        value = request.match_info["item_id"]
        if not value.isascii() or not value.isdigit() or len(value) > 19:
            raise TrashError(404, "Not in Trash")
        return value

    async def list_route(self, request):
        device = self.caller(request)
        items = await self.items(device)
        return web.json_response({"trash_days": self.days, "items": [self.public(item) for item in items]},
                                 headers={"Cache-Control": "no-store"})

    async def restore_route(self, request):
        device = self.caller(request, write=True)
        item_id = self.item_id(request)
        return web.json_response(await self.restore(device, item_id), headers={"Cache-Control": "no-store"})

    async def delete_route(self, request):
        device = self.caller(request, write=True)
        item_id = self.item_id(request)
        async with self.gateway.mutations.lock:
            self.ready(device)
            item = await self.find(device, item_id)
            await self.remove(device, item)
        return web.Response(status=204, headers={"Cache-Control": "no-store"})

    async def empty_route(self, request):
        device = self.caller(request, write=True)
        removed = 0
        async with self.gateway.mutations.lock:
            self.ready(device)
            for item in await self.items(device):
                await self.remove(device, item)
                removed += 1
        return web.json_response({"deleted": removed}, headers={"Cache-Control": "no-store"})

    def public(self, item):
        return {"id": item["id"], "path": item["path"], "kind": item["kind"], "size": item["size"],
                "deleted": item["deleted"], "expires": item["deleted"] + self.days * DAY}

    # Backend.

    def trash_url(self, device, href_name=""):
        return self.gateway.backend + "/remote.php/dav/trashbin/" + quote(device["uid"], safe="") + "/trash/" + href_name

    def auth(self, device):
        return BasicAuth(device["uid"], device["token"])

    async def items(self, device):
        """The caller's trash items deleted from under anj-cloud/, newest first."""
        url = self.trash_url(device)
        async with self.gateway.session.request("PROPFIND", url, data=TRASH_PROPFIND, auth=self.auth(device), allow_redirects=False,
                                                headers={"Depth": "1", "Content-Type": "application/xml",
                                                         "Accept-Encoding": "identity"}) as response:
            if response.status != 207:
                raise TrashError(502, "Trash is unavailable")
            try:
                content = await bounded_body(response, SIBLING_XML)
            except ValueError:
                raise TrashError(503, "Trash is too large to list") from None
        base = unquote(urlsplit(url).path)
        items = []
        for node in SafeET.fromstring(content, forbid_dtd=True).findall("{DAV:}response"):
            href = unquote(urlsplit(node.findtext("{DAV:}href") or "").path)
            name = href[len(base):].rstrip("/") if href.startswith(base) else ""
            if not name or "/" in name:
                continue
            path = root_relative(node.findtext(".//" + NC + "trashbin-original-location"))
            fileid = (node.findtext(".//" + OC + "fileid") or "").strip()
            try:
                deleted = int(node.findtext(".//" + NC + "trashbin-deletion-time") or "")
                size = int(node.findtext(".//" + OC + "size") or node.findtext(".//{DAV:}getcontentlength") or "0")
            except ValueError:
                continue
            if path is None or not fileid.isdigit():
                continue
            folder = node.find(".//{DAV:}resourcetype/{DAV:}collection") is not None
            items.append({"id": fileid, "name": name, "path": path, "kind": "folder" if folder else "file",
                          "size": size, "deleted": deleted})
        items.sort(key=lambda item: (-item["deleted"], item["path"]))
        return items

    async def find(self, device, item_id):
        for item in await self.items(device):
            if item["id"] == item_id:
                return item
        raise TrashError(404, "Not in Trash")

    async def in_trash(self, device, item):
        """True, False or None (unreadable): the item is still in the caller's trash."""
        try:
            return any(other["name"] == item["name"] for other in await self.items(device))
        except Exception:  # noqa: BLE001 - an unreadable trash is an unknown answer
            return None

    def ready(self, device):
        """Under the lock: writes are not fenced and the device is still admitted."""
        if not self.registry.mutation_ready():
            raise TrashError(503, "Writes are paused pending operator recovery")
        self.registry.admit(device["fingerprint"], device["certificate_id"])

    def begin(self, device, intent):
        self.registry.mutation_begin(device["id"], json.dumps(intent, separators=(",", ":")))

    async def request(self, method, url, device, headers=None):
        """One dispatched backend request: its status, or None when the outcome is unknown."""
        try:
            async with self.gateway.session.request(method, url, auth=self.auth(device), allow_redirects=False,
                                                    headers=headers or {}) as response:
                await response.read()
                return response.status
        except Exception:  # noqa: BLE001 - a lost answer: the backend may have applied it
            return None

    async def remove(self, device, item):
        """Deletes one trash item permanently, recorded like any other mutation."""
        self.begin(device, {"kind": "trash-delete", "id": item["id"]})
        status = await self.request("DELETE", self.trash_url(device, quote(item["name"], safe="")), device)
        if status in (200, 204, 404):
            self.registry.mutation_finish()
            return
        if status in KNOWN_FAILURES:
            self.registry.mutation_finish()
            raise TrashError(502, "The server did not delete this item")
        present = await self.in_trash(device, item)
        if present is None:
            # The fence stays closed with the recorded intent for operator recovery.
            raise TrashError(503, "The outcome is unknown; writes are paused until the operator checks it")
        self.registry.mutation_finish()
        if present:
            raise TrashError(502, "The server did not delete this item")

    async def exists(self, device, encoded):
        """(present, folder) of an encoded path below the root."""
        current = await self.gateway.mutations.current(device, encoded)
        return (current is not None, bool(current and current["collection"]))

    async def make_parents(self, device, relative):
        """Creates each missing folder above `relative`, top first; a file in the way refuses."""
        parts = relative.split("/")[:-1]
        for depth in range(1, len(parts) + 1):
            encoded = encode_filename_path("/".join(parts[:depth])) + "/"
            present, folder = await self.exists(device, encoded)
            if present and folder:
                continue
            if present:
                raise TrashError(409, "A file is where the item's folder was")
            status = await self.request("MKCOL", self.gateway.backend + backend_root(device["uid"]) + encoded, device)
            if status not in (201, 405):
                present, folder = await self.exists(device, encoded)
                if not (present and folder):
                    raise TrashError(502, "Could not recreate the item's folder")

    async def restore(self, device, item_id):
        """Restores one item to its original path, under the lock and fence. Returns the final path."""
        mutations = self.gateway.mutations
        async with mutations.lock:
            self.ready(device)
            item = await self.find(device, item_id)
            relative = item["path"]
            folder = item["kind"] == "folder"
            parent, name = split_leaf(encode_filename_path(relative))
            decoded_parent = posixpath.dirname(relative)
            self.begin(device, {"kind": "trash-restore", "id": item["id"], "path": relative})
            try:
                await self.make_parents(device, relative)
                before = await mutations.siblings(device, parent)
            except TrashError:
                self.registry.mutation_finish()
                raise
            except Exception:
                self.registry.mutation_finish()
                raise TrashError(502, "Could not prepare the restore") from None
            # Restore never overwrites (decision #120 names too): the original name when nothing there has
            # it, also apart from case and accents, else `name (restored).ext`, `(restored 2)`, ...
            target, n = name, 0
            while target in before or portable_names.clash(target, before) is not None:
                n += 1
                target = restored_name(name, folder, n)
                if n > 1000:
                    self.registry.mutation_finish()
                    raise TrashError(409, "No free name to restore to")
            restore_url = (self.gateway.backend + "/remote.php/dav/trashbin/" + quote(device["uid"], safe="")
                           + "/restore/" + quote(item["name"], safe=""))
            status = await self.request("MOVE", self.trash_url(device, quote(item["name"], safe="")), device,
                                        headers={"Destination": restore_url})
            if status in KNOWN_FAILURES:
                self.registry.mutation_finish()
                raise TrashError(404 if status == 404 else 502, "Not in Trash" if status == 404 else "The server did not restore this item")
            try:
                after = await mutations.siblings(device, parent)
            except Exception:  # noqa: BLE001
                after = None
            if status not in (200, 201, 204):
                # Unknown outcome: read back. Gone from the trash and a new name in the folder means applied;
                # still in the trash means not; anything else leaves the fence closed.
                present = await self.in_trash(device, item)
                if present is None or after is None or (not present and not set(after) - set(before)):
                    raise TrashError(503, "The outcome is unknown; writes are paused until the operator checks it")
                if present:
                    self.registry.mutation_finish()
                    raise TrashError(502, "The server did not restore this item")
            new = sorted(set(after or ()) - set(before))
            landed = new[0] if len(new) == 1 else (name if name in (after or ()) and name not in before else None)
            final = landed or name
            if landed is not None and landed != target:
                # Nextcloud chose the name (it compares exact names only): rename to ours, never replacing.
                source = self.gateway.backend + backend_root(device["uid"]) + parent + quote(landed, safe="-._~")
                destination = self.gateway.backend + backend_root(device["uid"]) + parent + quote(target, safe="-._~")
                moved = await self.request("MOVE", source, device, headers={"Destination": destination, "Overwrite": "F"})
                if moved in (201, 204):
                    final = target
            self.registry.mutation_finish()
            path = (decoded_parent + "/" if decoded_parent else "") + final
            return {"path": path, "renamed": final != name}
