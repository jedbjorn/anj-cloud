"""Client update feed (spec #28 G1, decision #108 Q6): the household server hands every paired
device the latest client package the operator published, plus its manifest.

The gateway never signs anything. It stores exactly the bytes and manifest the operator
published, after checking that the bytes match the manifest's size and SHA-256; the client
verifies the hash, the signer certificate and the version before it installs anything.

Storage, on the gateway's state volume (production: the data disk, inside nightly backups):

    releases/<target>/current.json     the manifest being served (replaced atomically)
    releases/<target>/<code>.pkg       package bytes, one file per version_code
    releases/<target>/<code>.json      that release's manifest
    releases/.incoming/<random>.part   an upload in progress (same filesystem, so the rename is atomic)

Retention is the current release and the one it replaced, per target. A download that already
opened a pruned file keeps reading it (the open descriptor holds the inode).

Routes (device certificate exactly like /dav/; reads, so read-grant devices may use them and
they are served while writes are fenced):

    GET /v1/client/releases/{target}            the current manifest, Cache-Control: no-store
    GET /v1/client/releases/{target}/package    its bytes: Content-Length, one byte Range, ETag

No answer, header or log line names a file or a filesystem path.
"""

import asyncio
from collections import defaultdict, deque
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import time

from aiohttp import web

from .observe import iso
from .protocol import Rejection
from .release_manifest import STORED, TARGETS, ManifestError, manifest_from as checked_manifest

CHUNK = 256 * 1024
MANIFEST_HEADER = "X-Anj-Release-Manifest"
# Per device, across both routes: a client checks on open and from Settings, and a resumed
# download is a handful of Range requests. Two package streams at once at most.
RELEASE_RATE, RELEASE_WINDOW = 30, 60.0
RELEASE_STREAMS = 2
# A download may not stall: each chunk must drain within WRITE_TIMEOUT (the ingress's own idle
# limit), and the whole download ends after STREAM_LIMIT (a 512 MiB package at about 75 KiB/s).
# A reader that drips just fast enough to keep the connection alive cannot hold its slot forever.
WRITE_TIMEOUT = 120.0
STREAM_LIMIT = 2 * 60 * 60.0
NO_STORE = {"Cache-Control": "no-store"}


def refuse(status, error):
    return web.json_response({"error": error}, status=status, headers=NO_STORE)


def manifest_from(data, target):
    try:
        return checked_manifest(data, target)
    except ManifestError as error:
        raise Rejection(str(error)) from None


def parse_range(header, size):
    """(start, end) inclusive for one satisfiable byte range; None to send the whole package;
    "unsatisfiable" for 416. Several ranges or a malformed header send the whole package."""
    if header is None:
        return None
    match = re.fullmatch(r"\s*bytes\s*=\s*([0-9]*)\s*-\s*([0-9]*)\s*", header)
    if not match or not (match.group(1) or match.group(2)) or len(header) > 64:
        return None
    first, last = match.group(1), match.group(2)
    if first:
        start = int(first)
        end = min(int(last), size - 1) if last else size - 1
        if last and int(last) < start:
            return None
        if start >= size:
            return "unsatisfiable"
        return start, end
    suffix = int(last)
    if suffix == 0:
        return "unsatisfiable"
    return max(size - suffix, 0), size - 1


class StorageError(OSError):
    """Release storage is not what the gateway created (a symlink or a file in its place)."""


def fsync_directory(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def write_atomic(path, data):
    """Temp file in the same directory, fsync, rename, fsync the directory."""
    temporary = path.with_name("." + path.name + "." + secrets.token_hex(4) + ".tmp")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise
    fsync_directory(path.parent)


class Releases:
    def __init__(self, gateway, root=None, monotonic=time.monotonic):
        self.gateway = gateway
        self.root = Path(root) if root is not None else Path(gateway.registry.directory) / "releases"
        self.monotonic = monotonic
        self.publishing = asyncio.Lock()
        self.windows = {}
        self.streams = defaultdict(int)
        self.write_timeout, self.stream_limit = WRITE_TIMEOUT, STREAM_LIMIT

    # Storage ---------------------------------------------------------------------------------

    @staticmethod
    def plain(path, create=False):
        """`path` as a real directory, never through a symlink; refuses otherwise."""
        if create:
            try:
                path.mkdir(mode=0o700)
            except FileExistsError:
                pass
        if path.is_symlink() or (path.exists() and not path.is_dir()):
            raise StorageError("release storage is not a plain directory")
        return path

    def directory(self, target, create=False):
        self.plain(self.root, create)
        return self.plain(self.root / target, create)

    def incoming(self, create=False):
        self.plain(self.root, create)
        return self.plain(self.root / ".incoming", create)

    def clear_incoming(self):
        """Remove uploads a crashed or stopped gateway left behind (run at start and after a
        publish, under the publish lock or before any publish can run). Returns how many."""
        incoming = self.incoming()
        removed = 0
        if incoming.is_dir():
            for entry in incoming.iterdir():
                if entry.name.endswith(".part") and not entry.is_symlink():
                    entry.unlink(missing_ok=True)
                    removed += 1
        return removed

    def current(self, target):
        """The manifest being served for `target`, or None."""
        try:
            data = json.loads((self.directory(target) / "current.json").read_bytes())
        except FileNotFoundError:
            return None
        try:
            return manifest_from(data, target)
        except ValueError:
            # Never a device-facing 400: the stored state is wrong, not the request (503).
            raise OSError("stored release manifest is invalid") from None

    def stored(self, target):
        codes = set()
        directory = self.directory(target)
        if directory.is_dir():
            for entry in directory.iterdir():
                match = STORED.fullmatch(entry.name)
                if match:
                    codes.add(int(match.group(1)))
        return codes

    def status(self):
        """Operator view: per known target, the served manifest and the version codes kept."""
        return {target: {"current": self.current(target), "kept": sorted(self.stored(target), reverse=True)}
                for target in TARGETS}

    def prune(self, target, keep):
        removed = []
        directory = self.directory(target)
        for entry in directory.iterdir():
            match = STORED.fullmatch(entry.name)
            stale = match and int(match.group(1)) not in keep
            leftover = entry.name.startswith(".") and entry.name.endswith(".tmp")
            if stale or leftover:
                entry.unlink(missing_ok=True)
                if stale and match.group(2) == "pkg":
                    removed.append(int(match.group(1)))
        self.clear_incoming()
        fsync_directory(directory)
        return sorted(removed)

    # Publish (operator socket) ---------------------------------------------------------------

    async def publish(self, request):
        """PUT /operator/release/{target} on the private socket: the body is the package, the
        manifest is the X-Anj-Release-Manifest header. One publish at a time."""
        target = request.match_info["target"]
        if target not in TARGETS:
            raise Rejection("Unknown release target")
        try:
            data = json.loads(request.headers.get(MANIFEST_HEADER, ""))
        except ValueError:
            raise Rejection("Release manifest header must be JSON") from None
        manifest = manifest_from(data, target)
        if request.content_length is not None and request.content_length != manifest["size"]:
            raise Rejection("Package size differs from the manifest")
        if self.publishing.locked():
            raise Rejection("Another release publish is in progress")
        async with self.publishing:
            try:
                directory = self.directory(target, create=True)
                incoming = self.incoming(create=True)
            except StorageError:
                raise Rejection("Release storage on the gateway is not a plain directory (a symlink?); nothing was published") from None
            current = self.current(target)
            self.newer(manifest, current)
            part = incoming / (secrets.token_hex(16) + ".part")
            try:
                await self.receive(request, part, manifest)
                code = manifest["version_code"]
                os.replace(part, directory / f"{code}.pkg")
                await asyncio.to_thread(write_atomic, directory / f"{code}.json", json.dumps(manifest).encode())
                # The swap: from here on every request sees the new release.
                await asyncio.to_thread(write_atomic, directory / "current.json", json.dumps(manifest).encode())
            finally:
                part.unlink(missing_ok=True)
            # The release is live from the swap on: whatever pruning does, the publish succeeded.
            previous = current["version_code"] if current else None
            self.gateway.events.emit({"time": iso(self.gateway.events.clock()), "event": "release-publish", "target": target,
                                      "version_code": code, "size": manifest["size"], "sha256": manifest["sha256"]})
            try:
                removed, prune = await asyncio.to_thread(self.prune, target, {code, previous}), "done"
            except Exception:  # noqa: BLE001 - retried by the next publish, which keeps only its own two
                removed, prune = [], "failed"
                self.gateway.events.emit({"time": iso(self.gateway.events.clock()), "event": "release-prune-failed",
                                          "target": target, "version_code": code})
        return web.json_response({"state": "published", "release": manifest, "previous_version_code": previous,
                                  "pruned_version_codes": removed, "prune": prune})

    @staticmethod
    def newer(manifest, current):
        if current is not None and manifest["version_code"] <= current["version_code"]:
            raise Rejection(f"version_code must be greater than the current release's ({current['version_code']})")

    async def receive(self, request, part, manifest):
        """Stream the body to `part`, hashing as it goes; never more than the declared size."""
        digest, size = hashlib.sha256(), 0
        fd = os.open(part, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "wb") as stream:
            async for chunk in request.content.iter_chunked(CHUNK):
                size += len(chunk)
                if size > manifest["size"]:
                    raise Rejection("Package is larger than the manifest's size")
                digest.update(chunk)
                await asyncio.to_thread(stream.write, chunk)
            if size != manifest["size"]:
                raise Rejection("Package size differs from the manifest")
            if digest.hexdigest() != manifest["sha256"]:
                raise Rejection("Package SHA-256 differs from the manifest")
            stream.flush()
            await asyncio.to_thread(os.fsync, fd)

    # Device routes ---------------------------------------------------------------------------

    def admit(self, request):
        """Authenticate exactly like /dav/ (401/403), then the per-device request window."""
        device = self.gateway.identity(request)
        window = self.windows.setdefault(device["id"], deque())
        now = self.monotonic()
        while window and window[0] <= now - RELEASE_WINDOW:
            window.popleft()
        if len(window) >= RELEASE_RATE:
            request["anj.reason"] = "release-rate"
            raise web.HTTPTooManyRequests(text="Too many release requests; wait a minute")
        window.append(now)
        if len(self.windows) > 4096:
            for key in [key for key, times in self.windows.items() if not times or times[-1] <= now - RELEASE_WINDOW]:
                del self.windows[key]
        if request.query_string:
            raise Rejection("Queries are unsupported")
        return device

    def served(self, request):
        device = self.admit(request)
        target = request.match_info["target"]
        if target not in TARGETS:
            return device, target, None, refuse(404, "unknown_target")
        manifest = self.current(target)
        if manifest is None:
            return device, target, None, refuse(404, "no_release")
        return device, target, manifest, None

    async def manifest(self, request):
        _device, _target, manifest, refusal = self.served(request)
        return refusal or web.json_response(manifest, headers=NO_STORE)

    async def package(self, request):
        device, target, manifest, refusal = self.served(request)
        if refusal:
            return refusal
        if self.streams[device["id"]] >= RELEASE_STREAMS:
            request["anj.reason"] = "release-streams"
            raise web.HTTPTooManyRequests(text="Too many release downloads at once")
        path = self.directory(target) / f"{manifest['version_code']}.pkg"
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        stream = os.fdopen(fd, "rb", buffering=0)
        reading = [None]
        task, transport = asyncio.current_task(), request.transport
        # Registered like DAV, so revoking the device or disabling its account aborts the download.
        self.streams[device["id"]] += 1
        self.gateway.active[device["id"]].add(task)
        self.gateway.transports[device["id"]].add(transport)
        try:
            size = os.fstat(fd).st_size
            if size != manifest["size"]:
                raise OSError("stored package does not match its manifest")
            etag = '"' + manifest["sha256"] + '"'
            headers = {"Accept-Ranges": "bytes", "ETag": etag, **NO_STORE}
            wanted = request.headers.get("Range")
            if wanted is not None and request.headers.get("If-Range", etag) != etag:
                wanted = None                    # a changed release: send it whole
            span = parse_range(wanted, size)
            if span == "unsatisfiable":
                request["anj.reason"] = "range"
                return web.Response(status=416, headers={**headers, "Content-Range": f"bytes */{size}"})
            start, end = span or (0, size - 1)
            status = 206 if span else 200
            if span:
                headers["Content-Range"] = f"bytes {start}-{end}/{size}"
            headers.update({"Content-Type": TARGETS[target], "X-Content-Type-Options": "nosniff",
                            "Content-Length": str(end - start + 1)})
            response = web.StreamResponse(status=status, headers=headers)
            await response.prepare(request)
            if request.method != "HEAD":
                try:
                    await self.send(response, stream, start, end - start + 1, reading)
                except Exception as error:  # noqa: BLE001
                    # The headers are out: a second response would land inside this body, so the
                    # connection is cut instead. The client sees a short body and resumes or retries.
                    request["anj.reason"] = "stream-timeout" if isinstance(error, TimeoutError) else "stream-failed"
                    if transport is not None:
                        transport.abort()
                    return response
            await response.write_eof()
            return response
        except asyncio.CancelledError:
            if transport is not None:
                transport.abort()
            raise
        finally:
            if reading[0] is not None and not reading[0].done():
                # A cancelled read may still be in its thread: close the file once it returns, so the
                # descriptor is never closed (and reused) under it.
                reading[0].add_done_callback(lambda _future: stream.close())
            else:
                stream.close()
            self.streams[device["id"]] -= 1
            if not self.streams[device["id"]]:
                del self.streams[device["id"]]
            self.gateway.active[device["id"]].discard(task)
            self.gateway.transports[device["id"]].discard(transport)

    async def send(self, response, stream, start, remaining, reading):
        """Chunk by chunk, each write waiting for the transport to drain: memory stays at a chunk
        whatever the package size or the link speed, and a link that is moving data is never idle
        for the ingress's 120 s limit. A chunk that does not drain within `write_timeout`, or a
        download still running after `stream_limit`, raises TimeoutError."""
        loop = asyncio.get_running_loop()
        deadline = self.monotonic() + self.stream_limit
        stream.seek(start)
        while remaining:
            left = deadline - self.monotonic()
            if left <= 0:
                raise TimeoutError("release download time limit")
            reading[0] = loop.run_in_executor(None, stream.read, min(CHUNK, remaining))
            chunk = await asyncio.shield(reading[0])
            if not chunk:
                raise OSError("stored package ended early")
            remaining -= len(chunk)
            await asyncio.wait_for(response.write(chunk), min(self.write_timeout, left))

    def add_routes(self, router):
        router.add_get("/v1/client/releases/{target}", self.manifest)
        router.add_get("/v1/client/releases/{target}/package", self.package)
