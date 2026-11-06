"""Serialized, bounded mutations with a durable fence for uncertain backend work."""

import asyncio
import io
import json
import logging
import os
from pathlib import Path
import re
import shutil
import tempfile
from urllib.parse import unquote, urlsplit

from aiohttp import BasicAuth, web
from defusedxml import ElementTree as SafeET

from . import portable_names
from .protocol import (MAX_XML, UPLOAD_LIMIT, UPLOAD_LIMIT_HEADER, UPLOAD_LIMIT_MAX, UPLOAD_LIMIT_MIN, Rejection, backend_root,
                       size_label, gateway_reference, rewrite_multistatus)

CONCRETE_ETAG = re.compile(r'"[^"\r\n]{1,256}"\Z')
# Nextcloud's OC-FileId: the zero-padded numeric file ID followed by the instance ID.
OC_FILE_ID = re.compile(r"([0-9]{1,19})oc[0-9a-z]{1,64}\Z")
FILE_ID = re.compile(r"([0-9]{1,19})\Z")
# The sibling listing a create or rename is checked against (decision #120): resource types only,
# streamed through a bounded parse. About 37,000 entries fit; a larger folder refuses with 503.
SIBLING_XML = 8 * 1024 * 1024
SIBLINGS_PROPFIND = b'<d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>'
log = logging.getLogger(__name__)


def split_leaf(relative):
    """(encoded parent ending in '/' or '', decoded final name) of an encoded relative DAV path."""
    parent, _, leaf = relative.rstrip("/").rpartition("/")
    return (parent + "/" if parent else ""), unquote(leaf)


def name_refusal(reason):
    """422 `name-not-portable` (decision #120): the name, never the path, is the problem."""
    return web.json_response({"error": portable_names.ERROR, "reason": reason,
                              "message": "Name not allowed on other devices. " + portable_names.TEXT[reason]},
                             status=422, headers={"Cache-Control": "no-store"})


def file_id(value, pattern=FILE_ID):
    """The positive numeric file ID in `value` (an oc:fileid, or OC-FileId with OC_FILE_ID), else None."""
    match = pattern.fullmatch(value or "")
    number = int(match.group(1)) if match else 0
    return number if 0 < number < 2 ** 63 else None


async def bounded_body(response, limit=MAX_XML):
    parts, size = [], 0
    async for chunk in response.content.iter_chunked(16384):
        size += len(chunk)
        if size > limit:
            raise ValueError("Backend metadata exceeds development limit")
        parts.append(chunk)
    return b"".join(parts)


class Mutations:
    def __init__(self, gateway):
        self.gateway = gateway
        self.lock = asyncio.Lock()
        self.tasks = set()
        self.owners = {}
        self.dispatched = set()
        self.added_failures = 0
        # A limit set at runtime by the owner console (spec #27) is persisted in the registry and
        # wins over the startup environment, which stays the default until one is set.
        stored = gateway.registry.setting(self.LIMIT_SETTING)
        self.limit = int(stored) if stored is not None else int(os.environ.get("ANJ_MAX_TRANSFER_BYTES", UPLOAD_LIMIT))
        self.capacity = int(os.environ.get("ANJ_STAGING_BYTES", 128 * 1024 * 1024))
        if self.limit <= 0 or self.capacity < self.limit:
            raise ValueError("Invalid development staging budget")
        self.directory = gateway.registry.directory / "uploads"
        self.directory.mkdir(mode=0o700, exist_ok=True)
        self.directory.chmod(0o700)
        # Staging files were never committed authority; an in-flight backend fence survives restart.
        for path in self.directory.glob("stage-*"):
            path.unlink()

    LIMIT_SETTING = "upload_limit_bytes"

    def set_limit(self, value):
        """Apply and persist a new per-request upload limit (spec #27).

        Requests that already started keep the limit they were admitted under; requests that
        start afterwards, and every DAV response's advertised limit, use the new one at once.
        """
        if type(value) is not int or value < UPLOAD_LIMIT_MIN:
            raise Rejection("Upload limit must be a whole number of bytes from 1 MiB to 64 MiB")
        if value > UPLOAD_LIMIT_MAX:
            raise Rejection("Above 64 MiB needs large-transfer support (Feature #6)")
        if value > self.capacity:
            raise Rejection("Upload limit exceeds the staging budget")
        self.gateway.registry.set_setting(self.LIMIT_SETTING, value)
        self.limit = value
        return value

    def too_large(self, length, limit=None):
        """413 for a declared length over the limit, with the limit in a header and the body."""
        limit = self.limit if limit is None else limit
        message = "Upload is too large for this server (limit " + size_label(limit) + ")."
        return web.HTTPRequestEntityTooLarge(
            max_size=limit, actual_size=length, content_type="application/json",
            headers={UPLOAD_LIMIT_HEADER: str(limit), "Connection": "close"},
            text=json.dumps({"error": "transfer_limit", "message": message, "actual_bytes": length, "max_bytes": limit}))

    def ready(self):
        if not self.gateway.registry.mutation_ready():
            raise web.HTTPServiceUnavailable(text="Writes require scoped operator recovery")

    def register(self, task, device):
        self.tasks.add(task)
        self.owners[task] = device

    def finished(self, task):
        self.tasks.discard(task)
        self.owners.pop(task, None)
        self.dispatched.discard(task)
        if not task.cancelled():
            task.exception()

    def cancel_unsubmitted(self, device):
        tasks = [task for task, owner in self.owners.items() if owner == device and task not in self.dispatched]
        for task in tasks:
            task.cancel()
        return tasks

    async def current(self, device, relative):
        url = self.gateway.backend + backend_root(device["uid"]) + relative
        body = (b'<d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">'
                b'<d:prop><d:getetag/><d:resourcetype/><oc:fileid/></d:prop></d:propfind>')
        async with self.gateway.session.request("PROPFIND", url, data=body, headers={"Depth": "0", "Content-Type": "application/xml", "Accept-Encoding": "identity"},
                                                auth=BasicAuth(device["uid"], device["token"]), allow_redirects=False) as response:
            if response.status == 404:
                return None
            if response.status != 207:
                raise web.HTTPBadGateway(text="Could not read authoritative resource version")
            root = SafeET.fromstring(await bounded_body(response), forbid_dtd=True)
            etag = root.findtext(".//{DAV:}getetag")
            if not etag or not CONCRETE_ETAG.fullmatch(etag):
                raise web.HTTPBadGateway(text="Resource version unavailable")
            return {"etag": etag, "collection": root.find(".//{DAV:}resourcetype/{DAV:}collection") is not None,
                    "fileid": file_id(root.findtext(".//{http://owncloud.org/ns}fileid"))}

    async def compare(self, request, device, relative, headers):
        current = await self.current(device, relative)
        if request.method in {"PUT", "MKCOL"} and current is None:
            if request.headers.get("If-None-Match") != "*" or "If-Match" in request.headers:
                raise web.HTTPPreconditionRequired(text="New resources require If-None-Match: *")
            return
        if request.method == "MKCOL":
            raise web.HTTPPreconditionFailed(text="Collection already exists")
        baseline = request.headers.get("If-Match", "")
        if not baseline:
            raise web.HTTPPreconditionRequired(text="Existing mutations require a concrete If-Match")
        if not CONCRETE_ETAG.fullmatch(baseline) or "If-None-Match" in request.headers:
            raise web.HTTPBadRequest(text="A single concrete resource version is required")
        if current is None or current["etag"] != baseline:
            raise web.HTTPPreconditionFailed(text="Resource changed")
        if request.method == "PUT" and current["collection"]:
            raise web.HTTPConflict(text="Cannot replace a collection with file bytes")
        if request.method == "MOVE" and request.headers.get("Overwrite") != "F":
            raise web.HTTPBadRequest(text="MOVE requires Overwrite: F")
        # Nextcloud rejects concrete collection If-Match. The comparison above is authoritative
        # under this one-worker lock, held through the backend's completed response.
        if current["collection"]:
            headers.pop("If-Match", None)
        return current

    async def siblings(self, device, parent):
        """Decoded names directly inside the encoded folder `parent`; empty when it is missing."""
        url = self.gateway.backend + backend_root(device["uid"]) + parent
        async with self.gateway.session.request("PROPFIND", url, data=SIBLINGS_PROPFIND,
                                                headers={"Depth": "1", "Content-Type": "application/xml", "Accept-Encoding": "identity"},
                                                auth=BasicAuth(device["uid"], device["token"]), allow_redirects=False) as response:
            if response.status == 404:
                return []
            if response.status != 207:
                raise web.HTTPBadGateway(text="Could not read the target folder")
            try:
                content = await bounded_body(response, SIBLING_XML)
            except ValueError:
                raise web.HTTPServiceUnavailable(text="Folder too large to check names") from None
        base = unquote(urlsplit(url).path)
        names = []
        for _, node in SafeET.iterparse(io.BytesIO(content), events=("end",), forbid_dtd=True):
            if node.tag == "{DAV:}href":
                path = unquote(urlsplit(node.text or "").path)
                rest = path[len(base):].rstrip("/") if path.startswith(base) else ""
                if rest and "/" not in rest:
                    names.append(rest)
            elif node.tag == "{DAV:}response":
                node.clear()
        return names

    async def portable(self, device, target, source=None):
        """Why creating `target` (or renaming `source` to it) is refused, or None.

        Gateway.dav refuses a blocked name before queueing; it is checked again here for every
        caller, then the name is compared with its siblings.

        Runs under the mutation lock with the backend's completed listing: every create and
        rename through this gateway, for any account or share alias, is serialized behind it, so
        no other writer can add a clashing sibling between this check and the mutation.
        """
        parent, name = split_leaf(target)
        reason = portable_names.check(name)
        if reason is not None:
            return reason
        siblings = await self.siblings(device, parent)
        if source is not None:
            source_parent, source_name = split_leaf(source)
            if source_parent == parent:
                # The item being renamed leaves this folder: a case-only rename is allowed.
                siblings = [sibling for sibling in siblings if sibling != source_name]
        return "clash" if portable_names.clash(name, siblings) is not None else None

    async def run(self, request, device, relative, headers, limit=None, destination=None):
        """`limit` is the upload limit in force when the request started (spec #27). `destination`
        is a MOVE's encoded relative target."""
        gateway = self.gateway
        limit = self.limit if limit is None else limit
        staged = None
        async with self.lock:
            self.ready()
            gateway.registry.admit(device["fingerprint"], device["certificate_id"])
            try:
                if request.method == "PUT":
                    # The gateway refuses a missing or oversized length before queueing
                    # (Gateway.dav); this repeats the check for any other caller.
                    length = request.content_length
                    if length is None:
                        raise web.HTTPLengthRequired(text="Declare upload Content-Length")
                    if length > limit:
                        raise self.too_large(length, limit)
                    if shutil.disk_usage(self.directory).free < length + 32 * 1024 * 1024 or length > self.capacity:
                        raise web.HTTPInsufficientStorage(text="Development staging capacity unavailable")
                    staged = tempfile.TemporaryFile(prefix="stage-", dir=self.directory)
                    if length:
                        try:
                            os.posix_fallocate(staged.fileno(), 0, length)
                        except OSError:
                            raise web.HTTPInsufficientStorage(text="Cannot reserve development upload staging") from None
                    size = 0
                    async for chunk in request.content.iter_chunked(16384):
                        gateway.registry.admit(device["fingerprint"], device["certificate_id"])
                        size += len(chunk)
                        if size > length:
                            raise web.HTTPBadRequest(text="Upload exceeded declared length")
                        if gateway.throttle:
                            await asyncio.sleep(gateway.throttle)
                        staged.write(chunk)
                    if size != length:
                        raise web.HTTPBadRequest(text="Upload was incomplete")
                    staged.seek(0)
                elif request.can_read_body and await request.read():
                    raise web.HTTPBadRequest(text="This mutation does not accept a body")
                gateway.registry.admit(device["fingerprint"], device["certificate_id"])
                current = await self.compare(request, device, relative, headers)
                # A new name must not clash with a sibling (decision #120); overwriting or deleting
                # an existing item, whatever its name, is never refused for its name.
                if request.method == "MOVE":
                    if destination is None:
                        # A caller that only forwarded the backend Destination (Gateway.dav passes it).
                        prefix = gateway.backend + backend_root(device["uid"])
                        target = headers.get("Destination", "")
                        if not target.startswith(prefix) or not target[len(prefix):]:
                            raise Rejection("MOVE destination must stay beneath the enrolled root")
                        destination = target[len(prefix):]
                    refused = await self.portable(device, destination, source=relative)
                elif request.method in {"PUT", "MKCOL"} and current is None:
                    refused = await self.portable(device, relative)
                else:
                    refused = None
                if refused is not None:
                    return name_refusal(refused)
                # Re-check after awaits: revoke/maintenance may have landed during staging/version read.
                self.ready()
                gateway.registry.admit(device["fingerprint"], device["certificate_id"])
                gateway.registry.mutation_begin(device["id"], relative)
                self.dispatched.add(asyncio.current_task())
                # No cancellation propagation from the request handler after this boundary. Timeout,
                # service crash or unknown result leaves the durable fence closed for operator recovery.
                url = gateway.backend + backend_root(device["uid"]) + relative
                async with gateway.session.request(request.method, url, data=staged, headers=headers,
                                                    auth=BasicAuth(device["uid"], device["token"]), allow_redirects=False) as response:
                    content = await bounded_body(response)
                    status = response.status
                    outgoing = {key: value for key, value in response.headers.items()
                                if key.lower() in {"content-type", "etag", "last-modified", "dav", "allow"}}
                    if "Location" in response.headers:
                        outgoing["Location"] = gateway_reference(response.headers["Location"], device["uid"], gateway.origin, gateway.backend)
                    if response.headers.get("Content-Encoding", "identity") != "identity":
                        raise ValueError("Unexpected backend encoding")
                    if status == 207:
                        content = rewrite_multistatus(content, device["uid"], gateway.origin, gateway.backend)
                    elif status >= 400 or (300 <= status < 400):
                        content = b""
                    # Receipt of the completed backend response establishes this operation finished.
                    gateway.registry.mutation_finish()
                    if request.method == "PUT" and status == 201:
                        self.note_added(device["uid"], response.headers.get("OC-FileId"))
                    elif request.method == "DELETE" and status in (200, 204) and current and current["fileid"]:
                        self.note_deleted(device["uid"], current["fileid"])
                    gateway.registry.admit(device["fingerprint"], device["certificate_id"])
                    outgoing["Cache-Control"] = "no-store"
                    return web.Response(status=status, headers=outgoing, body=content)
            finally:
                if staged is not None:
                    staged.close()

    def note_added(self, uid, header):
        """Record a new file's added time (decision #56). Never changes, delays or fails the
        upload response: a missing header or a failed write only leaves the file undated."""
        try:
            fileid = file_id(header, OC_FILE_ID)
            if fileid is None:
                raise ValueError("Created upload response has no usable OC-FileId")
            self.gateway.registry.record_added(uid, fileid)
        except Exception as error:  # noqa: BLE001 - recording is best effort by contract
            self.added_failures += 1
            log.warning("Added-time record skipped (%s)", type(error).__name__)

    def note_deleted(self, uid, fileid):
        try:
            self.gateway.registry.prune_added(uid, fileid)
        except Exception as error:  # noqa: BLE001 - a stale row is harmless; clients look up listed IDs only
            log.warning("Added-time prune skipped (%s)", type(error).__name__)

    async def operator_operation(self, device, path, operation):
        async with self.lock:
            self.ready()
            self.gateway.registry.mutation_begin(device, path)
            result = await operation()
            self.gateway.registry.mutation_finish()
            return result
