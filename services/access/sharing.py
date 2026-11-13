"""Directory sharing between household users (spec #26): one component, one writer.

Every share create, permission change and removal, from a device route or from the private
operator socket (operator CLI and owner console), runs here under the gateway's single mutation
lock and write fence (decision #78 C3). The owner always comes from the caller: a device
certificate, or an operator-supplied short-lived per-owner token whose identity is verified.

Fencing (decision #80 (1)): an UNKNOWN Nextcloud outcome leaves the household-wide write fence
closed with the recorded intent until the operator runs sharing reconciliation. A KNOWN failure
after dispatch fences only that share's scope (`share:<id>`, or `path:<uid>:<path>` for a create).
"""

import asyncio
import contextlib
import json
import posixpath
import re
import time
from urllib.parse import unquote, urlencode, urlsplit

from aiohttp import BasicAuth
from defusedxml import ElementTree as SafeET

from . import name_rule, portable_names
from .mutations import NAME_ERROR, bounded_body
from .protocol import Rejection, backend_root, encode_filename_path

OCS_SHARES = "/ocs/v2.php/apps/files_sharing/api/v1/shares"
ROOT = "/anj-cloud/"
# Top-level folders that can never be shared themselves (spec #34 P4).
PRIVATE_FOLDERS = frozenset({"Documents", "Music", "Videos"})
INCOMING = ROOT + "Shared/"
# Nextcloud permission bits: read 1, update 2, create 4, delete 8, share 16. The share bit is
# never granted, so a recipient cannot reshare (decision #78 N2).
PERMISSIONS = {"edit": 15, "view": 1}
OPERATOR_RIGHTS = {"write": "edit", "read": "view"}
EDIT_BITS = 2 | 4 | 8
KNOWN_FAILURES = (400, 401, 403, 404, 409, 412)
SHARE_ID = re.compile(r"[0-9]{1,19}")
# Reading the owner's list during a disable happens under the single mutation lock: a slow or
# hung backend refuses the disable after this many seconds so the lock is released promptly.
DISABLE_READ_TIMEOUT = 30.0
# A placement that cannot be decided (a 5xx, a lost answer, an unreadable folder) is retried at the
# recipient's later incoming reads after 30 s, 60 s, 120 s… (at most an hour), at most this many
# times; then the share stays in Shared/ (spec #34 P6 review L4).
PLACEMENT_ATTEMPTS = 6
PLACEMENT_BACKOFF = 30.0
PLACEMENT_BACKOFF_CAP = 3600.0


class ShareError(Rejection):
    """A curated sharing refusal: an HTTP status and a message that never carries a path."""

    def __init__(self, status, message, **detail):
        super().__init__(message)
        self.status = status
        self.message = message
        # Extra machine-readable fields for the error body, such as a name refusal's reason.
        self.detail = detail


class Unknown(Exception):
    """The backend may or may not have applied a dispatched mutation."""


def permission_of(value):
    return "edit" if int(value) & EDIT_BITS else "view"


def placement_folder(path):
    """The owner's top-level private folder a shared Nextcloud path lies in, else None.

    A share of a folder inside `Documents`, `Music` or `Videos` is mounted in the recipient's same
    folder (spec #34 P6, decision #149). The three folders themselves are never shared (P4).
    """
    if not isinstance(path, str) or not path.startswith(ROOT):
        return None
    parts = path[len(ROOT):].rstrip("/").split("/")
    return parts[0] if len(parts) > 1 and parts[0] in PRIVATE_FOLDERS else None


def confined(target, folder=None):
    """The recipient's mount path relative to the root when `target` is an allowed place, else None.

    Allowed: a direct child of `Shared/`, or of `folder` when the share was recorded for placement
    there (spec #34 P6). Anything else, deeper paths included, is not a place a share may be
    mounted: the gateway removes a new share that lands there and never lists one as incoming.
    """
    if not isinstance(target, str):
        return None
    target = target.rstrip("/")
    for parent in ("Shared",) + ((folder,) if folder in PRIVATE_FOLDERS else ()):
        prefix = ROOT + parent + "/"
        name = target[len(prefix):] if target.startswith(prefix) else ""
        if name and "/" not in name and name not in (".", ".."):
            return parent + "/" + name
    return None


class Principal:
    """The account a sharing call acts as, with the credential used for Nextcloud."""

    def __init__(self, uid, token, device=None):
        self.uid, self.token, self.device = uid, token, device

    @property
    def reference(self):
        """Fence and cleanup bookkeeping: the device ID, or `uid:<uid>` for an operator token."""
        return self.device or "uid:" + self.uid

    @property
    def auth(self):
        return BasicAuth(self.uid, self.token)


class Sharing:
    def __init__(self, gateway):
        self.gateway = gateway

    @property
    def registry(self):
        return self.gateway.registry

    # Principals.

    def device_principal(self, device):
        return Principal(device["uid"], device["token"], device["id"])

    async def token_principal(self, uid, token):
        """An operator-minted per-owner token; its canonical account must be exactly `uid`."""
        if not isinstance(uid, str) or not isinstance(token, str) or not token or len(token) > 256:
            raise Rejection("Owner and temporary token are required")
        if not self.registry.account_enabled(uid):
            raise Rejection("Owner account is disabled")
        async with self.gateway.session.get(self.gateway.backend + "/ocs/v2.php/cloud/user?format=json", auth=BasicAuth(uid, token),
                                            headers={"OCS-APIRequest": "true"}, allow_redirects=False) as response:
            body = await response.json(content_type=None) if response.status == 200 else None
        if not isinstance(body, dict) or (body.get("ocs", {}).get("data") or {}).get("id") != uid:
            raise Rejection("Temporary owner token does not match the owner")
        return Principal(uid, token)

    async def operator_principal(self, body):
        if "device_id" in body:
            if "owner_uid" in body or "token" in body:
                raise Rejection("Name a device or an owner token, not both")
            device = self.registry.device(body["device_id"])
            if device["state"] != "active":
                raise Rejection("Share operator requires an active owner's device")
            # Re-admits the exact current leaf: refused for a disabled account.
            self.registry.admit(device["fingerprint"], device["certificate_id"])
            return self.device_principal(device)
        return await self.token_principal(body.get("owner_uid"), body.get("token"))

    # Backend calls.

    async def _ocs(self, method, suffix, principal, query=None, form=None):
        """One OCS sharing call: (HTTP status, OCS status code or None, data or None)."""
        url = self.gateway.backend + OCS_SHARES + suffix + "?" + urlencode({**(query or {}), "format": "json"})
        headers = {"OCS-APIRequest": "true"}
        if form is not None:
            headers["Content-Type"] = "application/x-www-form-urlencoded"
        async with self.gateway.session.request(method, url, data=urlencode(form) if form is not None else None,
                                                auth=principal.auth, headers=headers, allow_redirects=False) as response:
            try:
                body = await response.json(content_type=None)
                code, data = body["ocs"]["meta"]["statuscode"], body["ocs"]["data"]
            except (ValueError, KeyError, TypeError):
                code, data = None, None
            return response.status, code, data

    async def _read(self, method, suffix, principal, query=None):
        status, code, data = await self._ocs(method, suffix, principal, query)
        if status == 200 and code in (100, 200):
            return data
        if status == 404 or code == 404:
            return None
        raise ShareError(502, "The sharing service is unavailable")

    async def _dispatch(self, method, suffix, principal, form=None):
        """A mutation: data on success, ShareError on a known failure, Unknown otherwise."""
        try:
            status, code, data = await self._ocs(method, suffix, principal, form=form)
        except Exception as error:  # Lost connection or timeout: the backend may have committed.
            raise Unknown() from error
        if status == 200 and code in (100, 200):
            return data
        if status in KNOWN_FAILURES or (status == 200 and code in KNOWN_FAILURES):
            raise ShareError(502, "The server refused this sharing change")
        raise Unknown()

    async def _collection(self, principal, encoded):
        """True for a folder, False for a file, None when missing."""
        url = self.gateway.backend + backend_root(principal.uid) + encoded
        body = b'<d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>'
        async with self.gateway.session.request("PROPFIND", url, data=body, auth=principal.auth, allow_redirects=False,
                                                headers={"Depth": "0", "Content-Type": "application/xml"}) as response:
            if response.status == 404:
                return None
            if response.status != 207:
                raise ShareError(502, "The sharing service is unavailable")
            root = SafeET.fromstring(await bounded_body(response), forbid_dtd=True)
        return root.find(".//{DAV:}resourcetype/{DAV:}collection") is not None

    # Validation.

    @staticmethod
    def permission(value):
        if value not in PERMISSIONS:
            raise ShareError(400, "Permission must be edit or view")
        # One access level (decision #155): a share is created or changed only to full access.
        # `view` stays a known wire value so a legacy View only share still reads correctly.
        if value != "edit":
            raise ShareError(422, "Sharing has one level: full access")
        return value

    @staticmethod
    def share_id(value):
        if not isinstance(value, str) or not SHARE_ID.fullmatch(value):
            raise ShareError(404, "Share not found")
        return value

    @staticmethod
    def directory(raw):
        """(Nextcloud path, encoded DAV path) for a folder the caller may share."""
        if not isinstance(raw, str):
            raise ShareError(400, "Path must be a string")
        try:
            encoded = encode_filename_path(raw)
        except Rejection:
            raise ShareError(400, "Invalid path") from None
        decoded = raw[:-1] if raw.endswith("/") else raw
        if not decoded:
            raise ShareError(422, "The root folder cannot be shared")
        if decoded.split("/")[0] == "Shared":
            raise ShareError(422, "Folders in Shared cannot be shared")
        # The three top-level folders every root starts with stay private; folders inside them can
        # be shared (spec #34 P4, decision #148, operator ruling B). New shares only: an existing share
        # keeps working and can still be changed or removed.
        if decoded in PRIVATE_FOLDERS:
            raise ShareError(422, "Documents, Music and Videos are private")
        # The recipient's mount is named after the folder: a name the cloud must not hold (spec #49
        # Gateway: untrimmed or unstorable) is not shared. Nextcloud chooses the mount name itself
        # when it collides with an exact name ("Photos (2)").
        reason = name_rule.cloud_check(decoded.rsplit("/", 1)[-1])
        if reason is not None:
            raise ShareError(422, "This folder's name is not allowed in the cloud. Rename it to share it.",
                             code=NAME_ERROR, reason=reason)
        return ROOT + decoded, encoded

    def recipient(self, principal, value):
        account = self.registry.account(value) if isinstance(value, str) else None
        if account is None or not account["enabled"] or account["uid"] == principal.uid:
            raise ShareError(422, "Choose someone on the household list")
        return account

    async def _not_incoming(self, principal, target):
        """Refuses a folder that is, or is inside, a share made to the caller (no reshares).

        Nextcloud refuses those too, but as a known failure after dispatch, which would fence the
        caller's path until an operator clears it; the caller's own incoming list decides here.
        """
        data = await self._read("GET", "", principal, {"shared_with_me": "true"}) or []
        for item in data if isinstance(data, list) else []:
            mount = item.get("file_target") if isinstance(item, dict) else None
            if isinstance(mount, str) and mount.rstrip("/") and (target == mount.rstrip("/") or target.startswith(mount.rstrip("/") + "/")):
                raise ShareError(422, "Folders shared with you cannot be shared")

    def _owned(self, principal, data):
        """The share row when the caller owns it as a user share of a folder in its own root."""
        if isinstance(data, list):
            data = data[0] if len(data) == 1 else None
        if (not isinstance(data, dict) or data.get("uid_owner") != principal.uid or str(data.get("share_type")) != "0"
                or not isinstance(data.get("path"), str) or not data["path"].startswith(ROOT)
                or data["path"] == ROOT + "Shared" or data["path"].startswith(INCOMING)):
            raise ShareError(404, "Share not found")
        return data

    def outgoing_row(self, data):
        recipient = self.registry.account(data["share_with"])
        return {"share_id": str(data["id"]), "path": data["path"][len(ROOT):], "recipient_id": data["share_with"],
                "recipient_display_name": recipient["display_name"] if recipient else data["share_with"],
                "permission": permission_of(data["permissions"])}

    # Fences.

    def _ready(self, principal, *scopes):
        # Re-checked under the lock: a request admitted just before its owner was disabled must
        # not create or change a share after the disable recorded the owner's mounts.
        if not self.registry.account_enabled(principal.uid):
            raise ShareError(403, "Account is disabled")
        if not self.registry.mutation_ready():
            raise ShareError(503, "Writes are paused pending operator recovery")
        if self.registry.share_fenced(*scopes):
            raise ShareError(503, "Sharing for this folder is paused pending operator recovery")

    def _begin(self, principal, intent):
        self.registry.mutation_begin(principal.reference, json.dumps({**intent, "owner": principal.uid}, separators=(",", ":")))

    # Reads.

    async def outgoing(self, principal):
        data = await self._read("GET", "", principal) or []
        rows = []
        for item in data if isinstance(data, list) else []:
            try:
                rows.append(self.outgoing_row(self._owned(principal, item)))
            except ShareError:
                continue
        return sorted(rows, key=lambda row: (row["path"], row["recipient_display_name"].lower()))

    def _placed_in(self, share_id):
        row = self.registry.placement(str(share_id))
        return row["folder"] if row else None

    async def incoming(self, principal):
        """Shares made to the caller, each mounted as a direct child of Shared/ or, for a share
        recorded for placement, of the owner's same top folder (spec #34 P6); a disabled owner's
        are marked. Pending placements are completed first, so the list names final places."""
        await self.place_pending(principal)
        await self.rename_pending(principal)
        data = await self._read("GET", "", principal, {"shared_with_me": "true"}) or []
        seen = []
        for item in data if isinstance(data, list) else []:
            if not isinstance(item, dict) or str(item.get("share_type")) != "0" or item.get("item_type") != "folder":
                continue
            path = confined(item.get("file_target"), self._placed_in(item.get("id")))
            if path is None:
                continue
            seen.append({"share_id": str(item["id"]), "owner_uid": item["uid_owner"], "path": path,
                         "permissions": int(item["permissions"])})
        self.registry.remember_incoming(principal.uid, seen)
        rows = [{**row, "owner_unavailable": False} for row in seen]
        rows += [{"share_id": row["share_id"], "owner_uid": row["owner_uid"], "path": row["path"], "permissions": row["permissions"],
                  "owner_unavailable": True}
                 for row in self.registry.unavailable_incoming(principal.uid) if row["share_id"] not in {item["share_id"] for item in seen}]
        result = []
        for row in sorted(rows, key=lambda row: row["path"]):
            owner = self.registry.account(row["owner_uid"])
            result.append({"share_id": row["share_id"], "path": row["path"],
                           "owner_display_name": owner["display_name"] if owner else row["owner_uid"],
                           "permission": permission_of(row["permissions"]), "owner_unavailable": row["owner_unavailable"]})
        return result

    async def remember_before_disable(self, owner_uid, token=None):
        """Record where every recipient mounts the owner's shares, from ONE read of the owner's list.

        Nextcloud's owner-side listing carries each share's recipient and recipient-side target
        (`file_target`): checked on Nextcloud 33 to reflect first-mount name collisions and a
        recipient's later rename, and to be readable while the recipient is disabled. So no
        recipient's own list has to be readable. The owner is read with the operator's temporary
        owner token when given, else one of the owner's active devices. False when the owner's
        list cannot be read: the caller then refuses the disable.
        """
        async def read():
            if token is not None:
                principal = await self.token_principal(owner_uid, token)
            else:
                devices = self.registry.active_devices(owner_uid)
                if not devices:
                    return None
                principal = self.device_principal(devices[0])
            return principal, await self._ocs("GET", "", principal)

        try:
            result = await asyncio.wait_for(read(), DISABLE_READ_TIMEOUT)
        except Exception:  # Includes the timeout: refuse, never guess.
            return False
        if result is None:
            return False
        principal, (status, code, data) = result
        # Only a complete, successful owner list may replace the recorded mounts: a 404, any other
        # failure or a non-list reply refuses the disable and keeps what is on record.
        if status != 200 or code not in (100, 200) or not isinstance(data, list):
            return False
        rows = []
        for item in data if isinstance(data, list) else []:
            try:
                share = self._owned(principal, item)
            except ShareError:
                continue
            mount = confined(share.get("file_target"), self._placed_in(share.get("id")))
            if share.get("item_type") != "folder" or mount is None or not isinstance(share.get("share_with"), str):
                continue
            rows.append({"share_id": str(share["id"]), "recipient_uid": share["share_with"],
                         "path": mount, "permissions": int(share["permissions"])})
        self.registry.record_owner_mounts(owner_uid, rows)
        return True

    # Mutations.

    async def create(self, principal, path, recipient_id, permission):
        permission = self.permission(permission)
        target, encoded = self.directory(path)
        recipient = self.recipient(principal, recipient_id)
        scope = "path:" + principal.uid + ":" + target
        folder = placement_folder(target)
        async with self.gateway.mutations.lock:
            self._ready(principal, scope)
            kind = await self._collection(principal, encoded)
            if kind is None:
                raise ShareError(404, "Folder not found")
            if not kind:
                raise ShareError(422, "Only folders can be shared")
            await self._not_incoming(principal, target)
            existing = await self._read("GET", "", principal, {"path": target, "reshares": "false"}) or []
            existing = existing if isinstance(existing, list) else []
            if any(str(item.get("share_type")) == "0" and item.get("share_with") == recipient["uid"] for item in existing):
                raise ShareError(409, "This person already has access; change their permission instead")
            intent = {"kind": "share", "path": target, "recipient": recipient["uid"], "permissions": PERMISSIONS[permission],
                      "prior_ids": [str(item["id"]) for item in existing]}
            self._begin(principal, intent)
            try:
                data = await self._dispatch("POST", "", principal, {"path": target, "shareType": "0", "shareWith": recipient["uid"],
                                                                     "permissions": str(PERMISSIONS[permission])})
            except ShareError:
                self.registry.mutation_finish()
                self.registry.share_fence(scope, "share", principal.uid)
                raise
            except Unknown:
                raise ShareError(503, "The sharing outcome is unknown; writes are paused until the operator reconciles") from None
            if not isinstance(data, dict) or not SHARE_ID.fullmatch(str(data.get("id", ""))) or not isinstance(data.get("file_target"), str):
                raise ShareError(503, "The sharing outcome is unknown; writes are paused until the operator reconciles")
            share_id = str(data["id"])
            # Nextcloud mounts a new share in the recipient's Shared/; a recorded placement may move
            # it into the owner's same top folder, the only other allowed place (spec #34 P6).
            if confined(data["file_target"], folder) is not None:
                if folder is not None:
                    self.registry.placement_add(share_id, principal.uid, recipient["uid"], folder, target.rsplit("/", 1)[-1])
                self.registry.mutation_finish()
                row = self.outgoing_row({**data, "path": target, "share_with": recipient["uid"], "permissions": PERMISSIONS[permission]})
                if folder is not None:
                    # At once when the recipient has a device to act as, so their next listing
                    # already shows the final place; otherwise at the recipient's next incoming read.
                    # Only a write-grant device's credential moves the recipient's mount (review L2).
                    devices = [device for device in self.registry.active_devices(recipient["uid"]) if device["rights"] == "write"]
                    if devices:
                        removed = await self._place(self.device_principal(devices[0]), self.registry.placement(share_id), locked=True)
                        if removed is not None:
                            raise removed
                return row
            await self._remove_unconfined(principal, share_id)

    async def _remove_unconfined(self, principal, share_id, owner_uid=None):
        """A share whose recipient mount escaped its allowed places is removed at once (spec #26,
        Gateway API 1; spec #34 P6). `principal` is the owner, or the recipient after a placement:
        then the cleanup, its fence and any write fence are recorded under the share's owner
        (`owner_uid`), so `repair-share OWNER ID` resolves it in one step (review M3)."""
        reference = "uid:" + owner_uid if owner_uid else principal.reference
        self.registry.note_share_cleanup_and_finish(share_id, reference)
        self.registry.mutation_begin(reference, "cleanup-unconfined-share-" + share_id)
        try:
            await self._dispatch("DELETE", "/" + share_id, principal)
        except ShareError:
            self.registry.mutation_finish()
            with self.registry.db:
                self.registry.db.execute("UPDATE share_cleanup SET state='failed' WHERE share_id=?", (share_id,))
            self.registry.share_fence("share:" + share_id, "cleanup", owner_uid or principal.uid, share_id)
            raise ShareError(502, "The new share was not confined and its removal failed; operator repair is required for share "
                             + share_id) from None
        except Unknown:
            raise ShareError(503, "Unconfined share cleanup outcome is unknown; writes remain paused") from None
        self.registry.mutation_finish()
        with self.registry.db:
            self.registry.db.execute("DELETE FROM share_cleanup WHERE share_id=?", (share_id,))
        raise ShareError(502, "The recipient's mount was not confined; the new share was removed")

    async def _owned_share(self, principal, share_id):
        return self._owned(principal, await self._read("GET", "/" + share_id, principal))

    async def update(self, principal, share_id, permission):
        share_id, permission = self.share_id(share_id), self.permission(permission)
        scope = "share:" + share_id
        async with self.gateway.mutations.lock:
            self._ready(principal, scope)
            data = await self._owned_share(principal, share_id)
            if permission_of(data["permissions"]) == permission and int(data["permissions"]) == PERMISSIONS[permission]:
                return self.outgoing_row(data)
            self._begin(principal, {"kind": "share-update", "share_id": share_id, "path": data["path"],
                                    "recipient": data["share_with"], "from": int(data["permissions"]), "permissions": PERMISSIONS[permission]})
            try:
                result = await self._dispatch("PUT", "/" + share_id, principal, {"permissions": str(PERMISSIONS[permission])})
            except ShareError:
                self.registry.mutation_finish()
                self.registry.share_fence(scope, "share-update", principal.uid, share_id)
                raise
            except Unknown:
                raise ShareError(503, "The sharing outcome is unknown; writes are paused until the operator reconciles") from None
            if not isinstance(result, dict) or str(result.get("permissions")) != str(PERMISSIONS[permission]):
                raise ShareError(503, "The sharing outcome is unknown; writes are paused until the operator reconciles")
            self.registry.mutation_finish()
            return self.outgoing_row({**data, "permissions": PERMISSIONS[permission]})

    async def remove(self, principal, share_id):
        share_id = self.share_id(share_id)
        scope = "share:" + share_id
        async with self.gateway.mutations.lock:
            self._ready(principal, scope)
            data = await self._owned_share(principal, share_id)
            self._begin(principal, {"kind": "unshare", "share_id": share_id, "path": data["path"], "recipient": data["share_with"]})
            try:
                await self._dispatch("DELETE", "/" + share_id, principal)
            except ShareError:
                self.registry.mutation_finish()
                self.registry.share_fence(scope, "unshare", principal.uid, share_id)
                raise
            except Unknown:
                raise ShareError(503, "The sharing outcome is unknown; writes are paused until the operator reconciles") from None
            self.registry.mutation_finish()
            with self.registry.db:
                self.registry.db.execute("DELETE FROM share_cleanup WHERE share_id=?", (share_id,))
            self.registry.placement_forget(share_id)
            return {"state": "removed"}

    # Recipient side (spec #34 P6, decision #149).

    def _writer(self, principal):
        """A device principal with the write grant; operator tokens are not recipients here."""
        if principal.device is None:
            return False
        try:
            return self.registry.device(principal.device)["rights"] == "write"
        except ValueError:
            return False

    async def place_pending(self, principal):
        """Completes the caller's due placements, as the recipient.

        Only a write-grant device places: the move changes the recipient's own tree, which a
        read-grant device may not write through the gateway either. A read-grant device's list
        then still names the share in Shared/ until a write-grant device of the account reads.
        """
        if not self._writer(principal):
            return
        now = time.time()
        for row in self.registry.placements_pending(principal.uid):
            if row["next_try"] <= now:
                await self._place(principal, row)

    async def _children(self, principal, folder):
        """Names directly in the recipient's top `folder` (none when it is missing: the move is then
        refused and the share kept in Shared/), or None when it cannot be listed now."""
        url = self.gateway.backend + backend_root(principal.uid) + encode_filename_path(folder) + "/"
        async with self.gateway.session.request("PROPFIND", url, auth=principal.auth, allow_redirects=False,
                                                data=b'<d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>',
                                                headers={"Depth": "1", "Content-Type": "application/xml"}) as response:
            if response.status == 404:
                return []
            if response.status != 207:
                return None
            root = SafeET.fromstring(await bounded_body(response), forbid_dtd=True)
        own = posixpath.normpath(unquote(urlsplit(url).path))
        names = []
        for href in root.iter("{DAV:}href"):
            path = posixpath.normpath(unquote(urlsplit(href.text or "").path))
            if path != own and posixpath.dirname(path) == own:
                names.append(posixpath.basename(path))
        return names

    async def _is_mount_of(self, principal, mount, item):
        """True when the recipient's folder at `mount` is this share's mount: its file ID is the
        shared folder's and its owner is the share's owner (review L5)."""
        url = self.gateway.backend + backend_root(principal.uid) + encode_filename_path(mount)
        body = (b'<d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns"><d:prop><oc:fileid/><oc:owner-id/>'
                b'</d:prop></d:propfind>')
        async with self.gateway.session.request("PROPFIND", url, data=body, auth=principal.auth, allow_redirects=False,
                                                headers={"Depth": "0", "Content-Type": "application/xml"}) as response:
            if response.status != 207:
                return False
            root = SafeET.fromstring(await bounded_body(response), forbid_dtd=True)
        fileid = root.find(".//{http://owncloud.org/ns}fileid")
        owner = root.find(".//{http://owncloud.org/ns}owner-id")
        return (fileid is not None and owner is not None and str(item.get("file_source")) == (fileid.text or "").strip()
                and item.get("uid_owner") == (owner.text or "").strip())

    def _candidates(self, row):
        """The mount names to try: the folder's own, then `<name> (<Owner>)` (decision #149)."""
        owner = self.registry.account(row["owner_uid"])
        suffixed = "%s (%s)" % (row["name"], owner["display_name"] if owner else row["owner_uid"])
        if name_rule.cloud_check(suffixed) is not None:
            suffixed = "%s (%s)" % (row["name"], row["owner_uid"])
        return [row["name"], suffixed]

    def _placeable(self, principal, row):
        return (self.registry.mutation_ready() and not self.registry.share_fenced("share:" + row["share_id"])
                and self.registry.account_enabled(principal.uid) and self.registry.account_enabled(row["owner_uid"]))

    def _retry_later(self, row):
        """An inconclusive attempt: retried with a growing delay, at most PLACEMENT_ATTEMPTS times;
        then the share stays in Shared/ (`kept`) and is not tried again (review L4)."""
        attempts = row["attempts"] + 1
        if attempts >= PLACEMENT_ATTEMPTS:
            self.registry.placement_set(row["share_id"], "kept")
        else:
            self.registry.placement_retry(row["share_id"], attempts,
                                          time.time() + min(PLACEMENT_BACKOFF * 2 ** (attempts - 1), PLACEMENT_BACKOFF_CAP))

    async def _place(self, principal, row, locked=False):
        """Moves a new share's mount from the recipient's Shared/ into the same top folder it was
        shared from (spec #34 P6, decision #149), acting as the recipient.

        Reads (the share's current target, the folder's names, the mount's identity) run outside
        the single mutation lock; only the move and its check run under it (`locked`: the caller
        already holds it). Nextcloud keeps a moved mount as the recipient's share target. Both
        outcomes of the move (still in Shared/, or in the folder) are allowed places, so an unknown
        outcome needs no fence: the share stays pending, retried later with a bounded backoff. A
        name taken in the folder, exactly or apart from case and accents, gets the owner's name as
        a suffix; when that is taken too, or Nextcloud refuses the move, the share stays in Shared/
        (`kept`). A mount found anywhere else is removed (fail closed): the removal's refusal is
        returned, for the create to answer with. Never raises.
        """
        if row is None or row["state"] != "pending" or row["recipient_uid"] != principal.uid:
            return None
        share_id, folder = row["share_id"], row["folder"]
        try:
            if not self._placeable(principal, row):
                return None
            found = await self._recipient_mount(principal, row, remove=locked)
            if found is False:
                self.registry.placement_forget(share_id)  # The share is gone.
                return None
            if found is None:
                self._retry_later(row)
                return None
            mount, item = found
            if mount is None:  # Escaped: removed under the lock (fail closed).
                async with (contextlib.nullcontext() if locked else self.gateway.mutations.lock):
                    await self._recipient_mount(principal, row, remove=True)
                return None
            if mount.startswith(folder + "/"):
                self.registry.placement_set(share_id, "placed")
                return None
            children = await self._children(principal, folder)
            if children is None:
                self._retry_later(row)
                return None
            free = [name for name in self._candidates(row)
                    if name not in children and portable_names.clash(name, children) is None]
            if not free:
                self.registry.placement_set(share_id, "kept")
                return None
            # Never move anything but this share's own mount (review L5).
            if not await self._is_mount_of(principal, mount, item):
                self._retry_later(row)
                return None
            source = self.gateway.backend + backend_root(principal.uid) + encode_filename_path(mount)
            destination = self.gateway.backend + backend_root(principal.uid) + encode_filename_path(folder + "/" + free[0])
            async with (contextlib.nullcontext() if locked else self.gateway.mutations.lock):
                if not self._placeable(principal, row):
                    return None
                again = await self._recipient_mount(principal, row, remove=True)
                if not again or again[0] != mount:
                    return None  # Changed meanwhile: looked at again on the next read.
                async with self.gateway.session.request("MOVE", source, auth=principal.auth, allow_redirects=False,
                                                        headers={"Destination": destination, "Overwrite": "F"}) as response:
                    status = response.status
                if status in (400, 403, 409, 412, 415):
                    self.registry.placement_set(share_id, "kept")
                    return None
                after = await self._recipient_mount(principal, row, remove=True)
            if after and after[0].startswith(folder + "/"):
                self.registry.placement_set(share_id, "placed")
            else:
                self._retry_later(row)
        except ShareError as error:
            return error
        except Exception:  # Lost connection or timeout: either outcome is allowed; looked at again later.
            try:
                self._retry_later(row)
            except Exception:
                pass
        return None

    async def _recipient_mount(self, principal, row, remove):
        """(mount path, share row) as the recipient sees it; False when the share is gone; None when
        it cannot be read. A mount outside the allowed places has the path None, and with `remove`
        (only under the mutation lock) is removed (raises ShareError); the cleanup is recorded
        under the share's owner, so operator repair names the owner (review M3)."""
        share_id = row["share_id"]
        status, code, data = await self._ocs("GET", "/" + share_id, principal)
        if status == 404 or code == 404:
            return False
        if status != 200 or code not in (100, 200):
            return None
        item = data[0] if isinstance(data, list) and len(data) == 1 else data
        if (not isinstance(item, dict) or str(item.get("id")) != share_id or item.get("share_with") != principal.uid
                or str(item.get("share_type")) != "0" or item.get("uid_owner") != row["owner_uid"]):
            return None
        mount = confined(item.get("file_target"), row["folder"])
        if mount is None and remove:
            await self._remove_unconfined(principal, share_id, owner_uid=row["owner_uid"])
        return mount, item

    async def leave(self, principal, share_id):
        """The recipient leaves a share made to them (decision #157): Nextcloud removes the share for
        this recipient only and never touches the owner's folder. Reached when the recipient deletes
        the shared folder on a device (in Shared/ or placed).

        An unknown outcome is read back at once as the recipient: gone means left, still there means
        not left; either failure fences this share only, never the household (review F-M1)."""
        share_id = self.share_id(share_id)
        scope = "share:" + share_id
        async with self.gateway.mutations.lock:
            self._ready(principal, scope)
            data = await self._read("GET", "/" + share_id, principal)
            item = data[0] if isinstance(data, list) and len(data) == 1 else data
            if (not isinstance(item, dict) or str(item.get("id")) != share_id or item.get("share_with") != principal.uid
                    or str(item.get("share_type")) != "0" or item.get("item_type") != "folder"
                    or confined(item.get("file_target"), self._placed_in(share_id)) is None):
                raise ShareError(404, "Share not found")

            async def request():
                status, code, _ = await self._ocs("DELETE", "/" + share_id, principal)
                if status == 200 and code in (100, 200):
                    return 200
                if code in KNOWN_FAILURES:
                    return code
                # HTTP 200 without a success status, or anything unexpected: read back (G-L1).
                return None if status == 200 else status

            async def read_back():
                status, code, _ = await self._ocs("GET", "/" + share_id, principal)
                if status == 404 or code == 404:
                    return True
                return False if status == 200 and code in (100, 200) else None

            await self._journaled(principal, share_id, "leave",
                                  {"kind": "leave", "share_id": share_id, "share_owner": item.get("uid_owner")},
                                  request, read_back)
            self.registry.forget_incoming(principal.uid, share_id)
            self.registry.placement_forget(share_id)
            return {"state": "left"}

    # Rename for everyone (decision #155).

    # Delete and rename for everyone (decisions #154, #155).

    async def _shared_source(self, principal, share_id):
        """For a share made to the caller with full access: (recipient row, owner principal, owner's
        source path). The owner side runs with the owner's own write-grant device credential; without
        one the request is refused (409), never with a minted token (operator 2026-11-05). Used by rename
        for everyone; a recipient's delete is a leave (decision #157)."""
        data = await self._read("GET", "/" + share_id, principal)
        item = data[0] if isinstance(data, list) and len(data) == 1 else data
        if (not isinstance(item, dict) or str(item.get("id")) != share_id or item.get("share_with") != principal.uid
                or str(item.get("share_type")) != "0" or item.get("item_type") != "folder"
                or confined(item.get("file_target"), self._placed_in(share_id)) is None):
            raise ShareError(404, "Share not found")
        if int(item.get("permissions", 0)) & PERMISSIONS["edit"] != PERMISSIONS["edit"]:
            raise ShareError(403, "This shared folder is View only")
        owner = item.get("uid_owner")
        if not isinstance(owner, str) or not self.registry.account_enabled(owner):
            raise ShareError(404, "Share not found")
        devices = [device for device in self.registry.active_devices(owner) if device["rights"] == "write"]
        if not devices:
            raise ShareError(409, "The owner's device is needed")
        owner_principal = self.device_principal(devices[0])
        source = self._owned(owner_principal, await self._read("GET", "/" + share_id, owner_principal))
        path = source["path"].rstrip("/")
        relative = path[len(ROOT):]
        if not relative or relative in PRIVATE_FOLDERS or relative == "Shared" or relative.startswith("Shared/"):
            raise ShareError(404, "Share not found")
        return item, owner_principal, relative

    async def _exists(self, principal, relative):
        """True, False or None (unreadable) for the principal's path below the root."""
        url = self.gateway.backend + backend_root(principal.uid) + encode_filename_path(relative)
        try:
            async with self.gateway.session.request("PROPFIND", url, auth=principal.auth, allow_redirects=False,
                                                    data=b'<d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>',
                                                    headers={"Depth": "0", "Content-Type": "application/xml"}) as response:
                return True if response.status == 207 else False if response.status == 404 else None
        except Exception:
            return None

    async def _journaled(self, principal, share_id, kind, intent, request, read_back):
        """One recorded share change (a leave, or an owner-side rename): always finished, and on any failure or unknown
        outcome fenced on this share only, never household-wide (review F-M1). `request()` returns
        the HTTP status (or raises); `read_back()` says True (applied), False (not), None (unknown).
        Returns True when applied."""
        scope = "share:" + share_id
        self._begin(principal, intent)
        try:
            try:
                status = await request()
            except Exception:
                status = None
            if status in (200, 201, 204):
                applied = True
            elif status in KNOWN_FAILURES or status == 423:
                applied = False
            else:
                applied = await read_back()
        except Exception:
            applied = None
        self.registry.mutation_finish()
        if applied is True:
            return True
        self.registry.share_fence(scope, kind, principal.uid, share_id)
        if applied is False:
            raise ShareError(502, "The server did not change this shared folder")
        raise ShareError(503, "The outcome is unknown; this shared folder is paused until the operator checks it")

    # Nextcloud's file name limit, in bytes of UTF-8 (review F-M1).
    NAME_BYTES = 250

    async def rename_for_all(self, principal, share_id, name):
        """The recipient renames a folder shared with them for everyone (decision #155): the owner's
        source folder is renamed in place on the owner's side, then this recipient's mount; other
        recipients' mounts follow at their next incoming read. A name the owner already has there
        is refused (409), never suffixed; a name differing only by case or accents is another name
        (spec #49 Gateway), except a top folder's at the root."""
        share_id = self.share_id(share_id)
        if not isinstance(name, str) or not name or "/" in name or name in (".", ".."):
            raise ShareError(400, "A folder name is required")
        if len(name.encode("utf-8")) > self.NAME_BYTES:
            raise ShareError(422, "This folder name is too long")
        reason = name_rule.cloud_check(name)
        if reason is not None:
            raise ShareError(422, "This folder's name is not allowed in the cloud.", code=NAME_ERROR, reason=reason)
        scope = "share:" + share_id
        async with self.gateway.mutations.lock:
            self._ready(principal, scope)
            item, owner, relative = await self._shared_source(principal, share_id)
            parent = posixpath.dirname(relative)
            target = (parent + "/" if parent else "") + name
            if target == relative:
                # Already renamed (a retry after a partial failure): finish the follow-ups (F-L2).
                return {"state": "renamed", "path": await self._after_rename(principal, owner, share_id, item, target, name)}
            if not parent and (name in PRIVATE_FOLDERS or name == "Shared"
                               or portable_names.clash(name, [*PRIVATE_FOLDERS, "Shared"]) is not None):
                raise ShareError(409, "The owner already has a folder with this name")
            siblings = await self._children(owner, parent) if parent else await self._root_children(owner)
            if siblings is None:
                raise ShareError(502, "The sharing service is unavailable")
            others = [sibling for sibling in siblings if sibling != posixpath.basename(relative)]
            if name in others:
                raise ShareError(409, "The owner already has a folder with this name")
            # Every path is built before anything is recorded (review F-M1).
            try:
                source = self.gateway.backend + backend_root(owner.uid) + encode_filename_path(relative)
                destination = self.gateway.backend + backend_root(owner.uid) + encode_filename_path(target)
            except Rejection:
                raise ShareError(422, "This folder name is not allowed") from None
            taken = False

            async def request():
                nonlocal taken
                async with self.gateway.session.request("MOVE", source, auth=owner.auth, allow_redirects=False,
                                                        headers={"Destination": destination, "Overwrite": "F"}) as response:
                    if response.status == 412:
                        taken = True
                        return 201  # Nothing changed: handled below, no fence.
                    return response.status

            async def read_back():
                old, new = await self._exists(owner, relative), await self._exists(owner, target)
                return True if (old is False and new is True) else False if (old is True and new is False) else None

            await self._journaled(principal, share_id, "share-rename",
                                     {"kind": "share-rename", "share_id": share_id, "path": ROOT + relative,
                                      "to": ROOT + target, "share_owner": owner.uid}, request, read_back)
            if taken:
                raise ShareError(409, "The owner already has a folder with this name")
            return {"state": "renamed", "path": await self._after_rename(principal, owner, share_id, item, target, name)}

    async def _after_rename(self, principal, owner, share_id, item, target, name):
        """After the owner's folder took `name`: this recipient's mount follows at once, every other
        recipient's at its next incoming read. Returns the caller's mount path. When the other
        recipients cannot be read, answers 502 so the client asks again; the retry finds the
        folder already renamed and finishes here (review F-L2)."""
        mount = confined(item["file_target"], self._placed_in(share_id))
        try:
            renamed = await self._rename_mount(principal, share_id, mount, name)
        except Exception:
            renamed = mount
        try:
            others = await self._read("GET", "", owner, {"path": ROOT + target, "reshares": "false"}) or []
        except Exception:
            raise ShareError(502, "The folder was renamed; the other recipients follow when you try again") from None
        for other in others if isinstance(others, list) else []:
            if (isinstance(other, dict) and str(other.get("share_type")) == "0" and str(other.get("id")) != share_id
                    and isinstance(other.get("share_with"), str)):
                self.registry.mount_rename_add(str(other["id"]), other["share_with"], owner.uid, name)
        return renamed

    async def _root_children(self, principal):
        url = self.gateway.backend + backend_root(principal.uid)
        async with self.gateway.session.request("PROPFIND", url, auth=principal.auth, allow_redirects=False,
                                                data=b'<d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>',
                                                headers={"Depth": "1", "Content-Type": "application/xml"}) as response:
            if response.status != 207:
                return None
            root = SafeET.fromstring(await bounded_body(response), forbid_dtd=True)
        own = posixpath.normpath(unquote(urlsplit(url).path))
        return [posixpath.basename(path) for path in (posixpath.normpath(unquote(urlsplit(href.text or "").path))
                                                       for href in root.iter("{DAV:}href"))
                if path != own and posixpath.dirname(path) == own]

    async def _rename_mount(self, principal, share_id, mount, name):
        """Moves the recipient's mount to `name` beside it (same place, still confined); keeps the old
        name when that one is taken there. Returns the mount path afterwards."""
        if mount is None or posixpath.basename(mount) == name:
            return mount
        destination = posixpath.dirname(mount) + "/" + name
        siblings = await self._children(principal, posixpath.dirname(mount))
        if siblings is None or name in siblings or portable_names.clash(name, [v for v in siblings if v != posixpath.basename(mount)]):
            return mount
        try:
            async with self.gateway.session.request(
                    "MOVE", self.gateway.backend + backend_root(principal.uid) + encode_filename_path(mount), auth=principal.auth,
                    allow_redirects=False, headers={"Destination": self.gateway.backend + backend_root(principal.uid)
                                                    + encode_filename_path(destination), "Overwrite": "F"}) as response:
                status = response.status
        except Exception:
            return mount
        return destination if status in (201, 204) else mount

    async def rename_pending(self, principal):
        """Another recipient renamed a shared folder for everyone: this recipient's mount follows at
        its next incoming read (write-grant devices only, like placement)."""
        if not self._writer(principal):
            return
        for row in self.registry.mount_renames(principal.uid):
            async with self.gateway.mutations.lock:
                status, code, data = await self._ocs("GET", "/" + row["share_id"], principal)
                item = data[0] if isinstance(data, list) and len(data) == 1 else data
                if status == 404 or code == 404:
                    self.registry.mount_rename_done(row["share_id"])
                    continue
                if (status != 200 or not isinstance(item, dict) or item.get("share_with") != principal.uid
                        or item.get("uid_owner") != row["owner_uid"]):
                    continue
                mount = confined(item.get("file_target"), self._placed_in(row["share_id"]))
                await self._rename_mount(principal, row["share_id"], mount, row["name"])
                self.registry.mount_rename_done(row["share_id"])


def owner_of(registry, reference):
    """The owner UID behind a fence or cleanup reference (a device ID or `uid:<uid>`)."""
    if isinstance(reference, str) and reference.startswith("uid:"):
        return reference[4:]
    try:
        return registry.device(reference)["uid"]
    except ValueError:
        return None

