"""Media fetch (spec #42 F2): the job routes, the one-at-a-time queue and the import.

The gateway records jobs and hands them, one at a time for the whole server, to the fetch worker
(services/fetch/) through a spool volume, the only state the two share. The worker downloads,
checks the result with ffprobe and leaves it in the spool; the gateway imports it into the
submitting account's Music or Videos with the submitting device's own credential, under the single
mutation lock, as a new file, with the portable-name rule and an added-time record (decisions
#120, #56), exactly like a client upload except that the 64 MiB client limit does not apply.

Spool protocol (version 1). The gateway owns every directory; the worker can only write inside
`worker/` and inside the job directory it was handed. Everything read back is untrusted: sizes are
bounded, JSON is validated field by field, the gateway opens only names it chose itself, never
follows a link, and derives the final file name from the reported title.

    <spool>/                     gateway, group SPOOL_GID, 2750
      jobs/                      2750: the worker lists it, cannot create in it
        <dispatch>/              2770: one run of one job (a fresh random name per run)
          request.json           gateway: {"v": 1, "url", "kind", "height", "expand"}
          cancel                 gateway: present means stop now
          status.json            worker, replaced by rename: {"v": 1, "boot", "state", ...}
          media.m4a|media.mp4    worker: the checked result, the only file the gateway imports
      worker/                    2770
        heartbeat.json           worker, every 2 s: {"v": 1, "boot", "seq", "job", "version"}

The gateway removes a job's directory once its row is terminal (or the run is abandoned) and
sweeps anything else, so the spool never keeps a file for a terminal job. Logs never carry a
link, a title or a path; request lines carry only the route class `fetch`.
"""

import asyncio
import errno
import json
import logging
import os
from pathlib import Path
import re
import secrets
import shutil
import stat
import time
import unicodedata
from urllib.parse import quote, unquote, urlsplit
import io

from aiohttp import BasicAuth, ClientTimeout, web
from defusedxml import ElementTree as SafeET

from . import portable_names
from .mutations import OC_FILE_ID, bounded_body, file_id
from .protocol import Rejection, backend_root
from .registry import AccountDisabled, FetchCap
from .sharing import ShareError

log = logging.getLogger(__name__)

SPOOL_GID = 10004                 # group shared by the gateway user and the worker user (10003)
KINDS = {"audio": ("Music", ".m4a"), "video": ("Videos", ".mp4")}
HEIGHTS = (1080, 720)
MAX_LINKS = 50                    # per submit (planner bound)
MAX_UNFINISHED = 500              # per account (planner bound): 429 beyond
MAX_PLAYLIST = 200                # items queued from one playlist (decision #179)
MAX_URL = 2048
MAX_ITEM_BYTES = 8 * 1024 ** 3    # decision #180; the worker checks it before and while downloading
STALL_SECONDS = 5 * 60            # no progress for this long: failed
RUN_SECONDS = 3 * 60 * 60         # a run (checking and downloading) longer than this: failed
RETENTION_SECONDS = 7 * 24 * 3600
DISK_FLOOR = 0.10                 # submits refused, head jobs failed, under 10% free
WORKER_STALE = 30.0               # heartbeat unchanged this long (gateway clock): worker not running
STOP_GRACE = 60.0                 # a stopped run's directory is removed after this even if the worker is silent
TITLE_CHARS = 150
NAME_BYTES = 200                  # UTF-8 bytes of a stem, leaving room for " (n)" and the extension (Nextcloud: 250)
MAX_STATUS = 1024 * 1024
MAX_HEARTBEAT = 4096
MAX_BODY = 160 * 1024             # a submit: 50 links of 2 KiB with JSON overhead
TICK = 1.0
IMPORT_ATTEMPTS = 3
UNFINISHED = ("waiting", "checking", "downloading", "placing")
WORKER_STATES = {"checking", "downloading", "staged", "playlist", "rejected", "failed", "cancelled"}
BOOT = re.compile(r"[0-9a-f]{16}")
DISPATCH = re.compile(r"[0-9a-f]{24}")
MEDIA_ID = re.compile(r"[A-Za-z0-9_-][A-Za-z0-9_.-]{0,63}")
INVALID = frozenset('<>:"/\\|?*')

STORAGE_FULL = "Server storage is almost full."
NO_ACCESS = "This device no longer has access."
STALLED = "The download stopped making progress."
TOO_SLOW = "The download took longer than 3 hours."
INTERRUPTED = "The download was interrupted twice."
SAVE_FAILED = "The file could not be saved to the cloud."
CANCELLED = "Cancelled."
# The worker reports a code from this table; the sentence is the gateway's (never tool output).
OUTCOMES = {
    "unsupported-format": ("rejected", "This link has no format the Downloader supports yet."),
    "too-long": ("rejected", "This item is longer than 4 hours, the Downloader's limit."),
    "too-large": ("rejected", "This item is larger than 8 GiB, the Downloader's limit."),
    "private-address": ("rejected", "This link points to a private or local network address."),
    "unsupported-link": ("rejected", "The Downloader can't read this link."),
    "live": ("rejected", "Live streams can't be downloaded."),
    "empty-playlist": ("rejected", "This playlist has no items."),
    "mismatch": ("rejected", "The downloaded file was not in the promised format."),
    "login-required": ("failed", "This site requires signing in, which the Downloader doesn't support."),
    "unavailable": ("failed", "This item is unavailable or private on the site."),
    "geo-blocked": ("failed", "This item isn't available where the server is."),
    "site-error": ("failed", "The site refused the download."),
    "network": ("failed", "The site could not be reached."),
    "worker-error": ("failed", "The Downloader stopped unexpectedly."),
}


class FetchError(ShareError):
    """A curated refusal: an HTTP status and one plain sentence, never a link or path."""


def check_link(text):
    """The link as stored, or None when it is not one absolute http(s) link."""
    if not isinstance(text, str):
        return None
    link = text.strip()
    if not link or len(link) > MAX_URL or any(ord(c) < 33 or ord(c) == 127 for c in link):
        return None
    try:
        parts = urlsplit(link)
        parts.port  # noqa: B018 - raises on a malformed port
    except ValueError:
        return None
    if parts.scheme.lower() not in ("http", "https") or not parts.hostname or "@" in parts.netloc:
        return None
    return link


def portable_stem(text, fallback, limit=TITLE_CHARS):
    """A title made a portable single name (decision #120): blocked characters replaced, controls
    removed, whitespace collapsed, leading and trailing dots and spaces removed, cut to `limit`
    characters (and NAME_BYTES of UTF-8), a reserved device name avoided. Empty: `fallback`."""
    text = unicodedata.normalize("NFC", text) if isinstance(text, str) else ""
    text = "".join("_" if c in INVALID else " " if c.isspace() else c for c in text
                   if c.isspace() or not (ord(c) < 32 or 127 <= ord(c) < 160 or unicodedata.category(c) in ("Cf", "Cs", "Co")))
    text = " ".join(text.split()).strip(". ")
    text = text[:limit]
    while len(text.encode()) > NAME_BYTES:
        text = text[:-1]
    text = text.rstrip(". ")
    if not text:
        text = fallback
    if portable_names.check(text) == "reserved":
        head, dot, tail = text.partition(".")
        text = head + "_" + dot + tail
    return text


def unique_name(stem, extension, siblings):
    """`stem + extension`, or with " (2)", " (3)"… when a sibling has that name exactly or apart
    from case and accents. Nothing is ever overwritten."""
    taken = set(siblings)
    for number in range(1, 10000):
        name = stem + ("" if number == 1 else " (%d)" % number) + extension
        if name not in taken and portable_names.clash(name, siblings) is None and portable_names.check(name) is None:
            return name
    raise FetchError(409, SAVE_FAILED)


def public_row(row):
    """One row of the route contract: `path` once placed, `percent` (integer) only while
    downloading, `height` the obtained height once known (video), else the requested one."""
    result = {"id": row["id"], "state": row["state"], "kind": row["kind"], "url": row["url"], "title": row["title"],
              "path": row["destination"], "message": row["message"], "submitted": row["submitted"], "finished": row["finished"],
              "height": (row["obtained"] or row["height"]) if row["kind"] == "video" else None}
    if row["state"] == "downloading":
        result["percent"] = max(0, min(100, int(row["percent"] or 0)))
    return result


class Fetch:
    """Job routes, queue runner and import for one gateway; configured by its spool directory."""

    def __init__(self, gateway, spool, *, clock=None, disk=shutil.disk_usage, tick=TICK):
        self.gateway = gateway
        self.registry = gateway.registry
        self.clock = clock or gateway.registry.clock
        self.disk = disk
        self.tick_seconds = tick
        self.root = Path(spool)
        self.jobs = self.root / "jobs"
        self.worker_dir = self.root / "worker"
        self.heartbeat = None            # (seq, boot, job, version) last read
        self.heartbeat_seen = None       # gateway clock when it last changed
        self.progress = None             # (dispatch, signature, since)
        self.stopping = {}               # dispatch -> deadline: runs told to stop, removed once the worker leaves them
        self.import_task = None
        self.task = None
        self.failures = 0
        self.prepare()

    # Spool ---------------------------------------------------------------------------------

    def prepare(self):
        """Directory modes and group (decision: the gateway owns the layout; see the docstring)."""
        self.root.mkdir(parents=True, exist_ok=True)
        for path, mode in ((self.root, 0o2750), (self.jobs, 0o2750), (self.worker_dir, 0o2770)):
            path.mkdir(exist_ok=True)
            info = path.lstat()
            if not stat.S_ISDIR(info.st_mode):
                raise RuntimeError("Fetch spool layout is not plain directories")
            if info.st_gid != SPOOL_GID:
                try:
                    os.chown(path, -1, SPOOL_GID)
                except OSError:
                    pass  # the worker then cannot write; it reports nothing and submits answer 503
            os.chmod(path, mode)

    def worker_alive(self):
        """The worker's heartbeat changed within WORKER_STALE seconds of the gateway's clock."""
        return self.heartbeat_seen is not None and self.clock() - self.heartbeat_seen <= WORKER_STALE

    def read_json(self, path, limit):
        """A bounded, validated JSON object from a spool file the gateway names; None otherwise."""
        try:
            fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        except OSError:
            return None
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_size > limit:
                return None
            with os.fdopen(os.dup(fd), "rb") as stream:
                data = stream.read(limit + 1)
        except OSError:
            return None
        finally:
            os.close(fd)
        if len(data) > limit:
            return None
        try:
            value = json.loads(data)
        except ValueError:
            return None
        return value if isinstance(value, dict) else None

    def read_heartbeat(self):
        value = self.read_json(self.worker_dir / "heartbeat.json", MAX_HEARTBEAT)
        if (value is None or value.get("v") != 1 or not isinstance(value.get("boot"), str) or not BOOT.fullmatch(value["boot"])
                or type(value.get("seq")) is not int or not (value.get("job") is None or (isinstance(value["job"], str) and DISPATCH.fullmatch(value["job"])))):
            return
        version = value.get("version") if isinstance(value.get("version"), str) and len(value["version"]) <= 64 else None
        current = (value["seq"], value["boot"], value["job"], version)
        if current != self.heartbeat:
            self.heartbeat = current
            self.heartbeat_seen = self.clock()

    def read_status(self, dispatch):
        """The worker's status for a run, validated; None when absent. Invalid: {"state": "invalid"}."""
        path = self.jobs / dispatch / "status.json"
        if not os.path.lexists(path):
            return None
        value = self.read_json(path, MAX_STATUS)
        if value is None or value.get("v") != 1 or value.get("state") not in WORKER_STATES or not isinstance(value.get("boot"), str) \
                or not BOOT.fullmatch(value["boot"]):
            return {"state": "invalid"}
        status = {"state": value["state"], "boot": value["boot"]}
        for name in ("bytes", "size", "height"):
            number = value.get(name)
            if number is not None:
                if type(number) is not int or not 0 <= number <= 2 ** 62:
                    return {"state": "invalid"}
                status[name] = number
        percent = value.get("percent")
        if percent is not None:
            if type(percent) not in (int, float) or not 0 <= percent <= 100:
                return {"state": "invalid"}
            status["percent"] = float(percent)
        title = value.get("title")
        if title is not None:
            if not isinstance(title, str) or len(title) > 2048:
                return {"state": "invalid"}
            status["title"] = title
        media = value.get("id")
        status["id"] = media if isinstance(media, str) and MEDIA_ID.fullmatch(media) else None
        code = value.get("code")
        status["code"] = code if code in OUTCOMES else "worker-error"
        if value["state"] == "playlist":
            items = value.get("items")
            if not isinstance(items, list) or len(items) > MAX_PLAYLIST + 1 or not isinstance(value.get("more", False), bool):
                return {"state": "invalid"}
            status["items"] = [check_link(item.get("url")) if isinstance(item, dict) else None for item in items]
            status["more"] = value.get("more", False) or len(items) > MAX_PLAYLIST
        return status

    def remove_run(self, dispatch):
        """Remove a run's directory (never following a link inside it)."""
        if not dispatch or not DISPATCH.fullmatch(dispatch):
            return True
        path = self.jobs / dispatch
        try:
            if path.is_symlink() or not path.is_dir():
                path.unlink(missing_ok=True)
            else:
                shutil.rmtree(path)
        except FileNotFoundError:
            pass
        except OSError as error:
            log.warning("Fetch spool cleanup deferred (%s)", errno.errorcode.get(error.errno, "error"))
            return False
        return True

    def sweep(self, keep):
        """Remove every run directory and worker stray that no running job owns."""
        try:
            names = os.listdir(self.jobs)
        except OSError:
            names = []
        for name in names[:256]:
            if name not in keep:
                if DISPATCH.fullmatch(name):
                    self.remove_run(name)
                else:
                    try:
                        path = self.jobs / name
                        shutil.rmtree(path) if path.is_dir() and not path.is_symlink() else path.unlink()
                    except OSError:
                        pass
        try:
            strays = [name for name in os.listdir(self.worker_dir) if name not in ("heartbeat.json", "heartbeat.tmp")]
        except OSError:
            strays = []
        for name in strays[:256]:
            path = self.worker_dir / name
            try:
                shutil.rmtree(path) if path.is_dir() and not path.is_symlink() else path.unlink()
            except OSError:
                pass

    def write_file(self, path, data):
        """Create a spool file the worker may read (0640, group SPOOL_GID), atomically."""
        temporary = path.with_name(path.name + ".tmp")
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o640)
        try:
            os.write(fd, data)
            os.fchmod(fd, 0o640)
        finally:
            os.close(fd)
        os.replace(temporary, path)

    def disk_low(self):
        try:
            usage = self.disk(self.root)
        except OSError:
            return True
        return usage.total <= 0 or usage.free < usage.total * DISK_FLOOR

    # Routes --------------------------------------------------------------------------------

    def add_routes(self, router):
        router.add_get("/v1/fetch/jobs", self.list_route)
        router.add_post("/v1/fetch/jobs", self.submit_route)
        router.add_post("/v1/fetch/jobs/clear", self.clear_route)
        router.add_delete("/v1/fetch/jobs/{job_id}", self.delete_route)

    def caller(self, request, write=False):
        device = self.gateway.identity(request)
        if request.query_string:
            raise FetchError(400, "Queries are unsupported")
        if write and device["rights"] != "write":
            raise FetchError(403, "This device can only view")
        return device

    async def list_route(self, request):
        device = self.caller(request)
        return web.json_response({"jobs": [public_row(row) for row in self.registry.fetch_jobs(device["uid"])]},
                                 headers={"Cache-Control": "no-store"})

    async def body(self, request):
        if request.content_length is not None and request.content_length > MAX_BODY:
            raise FetchError(400, "At most %d links can be sent at once." % MAX_LINKS)
        data, size = [], 0
        async for chunk in request.content.iter_chunked(16384):
            size += len(chunk)
            if size > MAX_BODY:
                raise FetchError(400, "At most %d links can be sent at once." % MAX_LINKS)
            data.append(chunk)
        try:
            body = json.loads(b"".join(data))
        except ValueError:
            raise FetchError(400, "A JSON object is required") from None
        if not isinstance(body, dict) or not {"urls", "kind"} <= set(body) <= {"urls", "kind", "height"}:
            raise FetchError(400, "Expected urls, kind and height")
        return body

    async def submit_route(self, request):
        device = self.caller(request, write=True)
        body = await self.body(request)
        urls, kind, height = body["urls"], body["kind"], body.get("height")
        if kind not in KINDS:
            raise FetchError(400, "Choose audio or video")
        if kind == "video" and (type(height) is not int or height not in HEIGHTS):
            raise FetchError(400, "Choose 1080 or 720")
        if kind == "audio":
            if height is not None and (type(height) is not int or height not in HEIGHTS):
                raise FetchError(400, "Audio takes no resolution")
            height = None
        if not isinstance(urls, list) or not urls:
            raise FetchError(400, "Paste at least one link")
        if len(urls) > MAX_LINKS:
            raise FetchError(400, "At most %d links can be sent at once." % MAX_LINKS)
        links = [check_link(url) for url in urls]
        if None in links:
            raise FetchError(400, "Only http and https links can be downloaded.")
        if not self.registry.mutation_ready():
            raise FetchError(503, "The server is paused for maintenance. Try again later.")
        if not self.worker_alive():
            raise FetchError(503, "The Downloader is not running. Try again later.")
        if self.disk_low():
            raise FetchError(507, STORAGE_FULL)
        try:
            rows = self.registry.fetch_add(device["uid"], device["id"], kind, height, links, cap=MAX_UNFINISHED)
        except FetchCap:
            raise FetchError(429, "Too many downloads are waiting (at most %d). Wait for some to finish." % MAX_UNFINISHED) from None
        self.wake()
        return web.json_response({"jobs": [public_row(row) for row in reversed(rows)]}, status=202, headers={"Cache-Control": "no-store"})

    async def delete_route(self, request):
        device = self.caller(request, write=True)
        row = self.registry.fetch_job(request.match_info["job_id"])
        if row is None or row["uid"] != device["uid"]:
            raise FetchError(404, "No such download")
        if row["state"] in UNFINISHED:
            if row["state"] == "placing":
                raise FetchError(409, "This item is already being saved.")
            self.finish(row, "cancelled", CANCELLED)
        else:
            self.registry.fetch_remove(device["uid"], row["id"])
        return web.Response(status=204, headers={"Cache-Control": "no-store"})

    async def clear_route(self, request):
        device = self.caller(request, write=True)
        if request.can_read_body and await request.read():
            raise FetchError(400, "Clear takes no body")
        self.registry.fetch_clear(device["uid"])
        return web.Response(status=204, headers={"Cache-Control": "no-store"})

    # Queue ---------------------------------------------------------------------------------

    def start(self):
        self.recover()
        self.wakeup = asyncio.Event()
        self.task = asyncio.get_running_loop().create_task(self.run())

    async def close(self):
        for task in (self.task, self.import_task):
            if task is not None:
                task.cancel()
        for task in (self.task, self.import_task):
            if task is not None:
                try:
                    await task
                except (asyncio.CancelledError, Exception):  # noqa: BLE001 - closing
                    pass

    def wake(self):
        event = self.__dict__.get("wakeup")
        if event is not None:
            event.set()

    async def run(self):
        while True:
            try:
                await self.tick()
                self.failures = 0
            except asyncio.CancelledError:
                raise
            except Exception as error:  # noqa: BLE001 - the queue never stops; no detail is logged
                self.failures += 1
                if self.failures in (1, 10, 100):
                    log.warning("Fetch queue pass failed (%s)", type(error).__name__)
            try:
                await asyncio.wait_for(self.wakeup.wait(), self.tick_seconds)
            except asyncio.TimeoutError:
                pass
            self.wakeup.clear()

    def recover(self):
        """After a gateway restart: a run that was checking or downloading returns to waiting once
        (then fails); an import in flight resumes from its staged file and reads its target back."""
        for row in self.registry.fetch_running():
            if row["state"] == "placing" and row["dispatch"] and self.staged_path(row).exists():
                continue
            self.interrupted(row)

    def interrupted(self, row):
        """A run cut off by a gateway or worker restart: back to waiting once, then failed."""
        if row["interrupted"]:
            return self.finish(row, "failed", INTERRUPTED)
        if row["dispatch"]:
            self.stop_run(row["dispatch"])
        self.registry.fetch_update(row["id"], state="waiting", interrupted=row["interrupted"] + 1, dispatch=None, percent=None,
                                   target=None, target_size=None)
        self.progress = None
        return None

    def finish(self, row, state, message, *, stop=True, destination=None):
        """Settle a row as terminal; its run (if any) is told to stop and its directory goes."""
        now = self.clock()
        if row["dispatch"]:
            if stop:
                self.stop_run(row["dispatch"])
            else:
                self.remove_run(row["dispatch"])
        if row["state"] in ("checking", "downloading", "placing"):
            self.registry.fetch_served(row["uid"], now)
        if self.progress and self.progress[0] == row["dispatch"]:
            self.progress = None
        self.wake()
        fields = dict(state=state, message=message, finished=now, percent=None, dispatch=None, target=None, target_size=None)
        if destination is not None:
            fields["destination"] = destination
        return self.registry.fetch_update(row["id"], **fields)

    def stop_run(self, dispatch):
        try:
            self.write_file(self.jobs / dispatch / "cancel", b"")
        except OSError:
            pass
        self.stopping[dispatch] = self.clock() + STOP_GRACE

    def staged_path(self, row):
        return self.jobs / row["dispatch"] / ("media" + KINDS[row["kind"]][1])

    async def tick(self):
        """One queue pass: read the worker, advance the running job, start the next, tidy up."""
        now = self.clock()
        self.read_heartbeat()
        job = self.heartbeat[2] if self.heartbeat else None
        for dispatch, deadline in list(self.stopping.items()):
            # Removed once the worker has left the run (or is silent past the grace).
            # Past the grace the queue moves on even if the directory resists; the sweep retries it.
            if job != dispatch or now >= deadline:
                if self.remove_run(dispatch) or now >= deadline:
                    del self.stopping[dispatch]
        running = self.registry.fetch_running()
        for extra in running[1:]:
            self.interrupted(extra)  # never more than one: a second is returned to waiting
        row = running[0] if running else None
        if row is not None:
            if row["state"] == "placing":
                if self.import_task is None or self.import_task.done():
                    self.import_task = asyncio.get_running_loop().create_task(self.place(row["id"]))
            else:
                self.advance(row, now)
        elif not self.stopping and self.worker_alive():
            self.dispatch_next(now)
        running = self.registry.fetch_running()
        self.sweep({row["dispatch"] for row in running if row["dispatch"]} | set(self.stopping))
        self.registry.fetch_prune(now - RETENTION_SECONDS)

    def dispatch_next(self, now):
        for _ in range(64):
            row = self.registry.fetch_next()
            if row is None:
                return None
            if self.disk_low():
                self.finish(row, "failed", STORAGE_FULL, stop=False)
                continue
            device = self.device(row)
            if device is None:
                self.finish(row, "failed", NO_ACCESS, stop=False)
                continue
            dispatch = secrets.token_hex(12)
            directory = self.jobs / dispatch
            directory.mkdir(mode=0o700)
            try:
                os.chown(directory, -1, SPOOL_GID)
            except OSError:
                pass
            os.chmod(directory, 0o2770)
            request = {"v": 1, "url": row["url"], "kind": row["kind"], "height": row["height"], "expand": bool(row["expand"])}
            self.write_file(directory / "request.json", json.dumps(request, separators=(",", ":")).encode())
            self.progress = (dispatch, None, now)
            return self.registry.fetch_update(row["id"], state="checking", dispatch=dispatch, started=now, percent=None)
        return None

    def device(self, row):
        """The submitting device's current row while it may still act for the account, else None."""
        try:
            device = self.registry.device(row["device"])
            if device["uid"] != row["uid"]:
                return None
            return self.registry.admit(device["fingerprint"], device["certificate_id"])
        except (AccountDisabled, ValueError, KeyError):
            return None

    def advance(self, row, now):
        """Checking or downloading: follow the worker's status; enforce access, stall and run time."""
        if self.device(row) is None:
            return self.finish(row, "failed", NO_ACCESS)
        status = self.read_status(row["dispatch"])
        if status is not None and status["state"] == "invalid":
            return self.finish(row, "failed", OUTCOMES["worker-error"][1])
        boot = self.heartbeat[1] if self.heartbeat else None
        if status is not None and boot is not None and status["boot"] != boot and status["state"] in ("checking", "downloading"):
            return self.interrupted(row)  # the worker restarted under this run
        signature = None if status is None else (status["state"], status.get("bytes"), status.get("percent"))
        if self.progress is None or self.progress[0] != row["dispatch"] or self.progress[1] != signature:
            self.progress = (row["dispatch"], signature, now)
        if status is None or status["state"] in ("checking", "downloading"):
            if now - self.progress[2] >= STALL_SECONDS:
                return self.finish(row, "failed", STALLED)
            if now - (row["started"] or now) >= RUN_SECONDS:
                return self.finish(row, "failed", TOO_SLOW)
            if status is not None:
                fields = {"state": status["state"]}
                if status.get("title") and not row["title"]:
                    fields["title"] = status["title"][:1024]
                if status["state"] == "downloading":
                    fields["percent"] = round(status.get("percent", 0.0), 1)
                if any(row.get(key) != value for key, value in fields.items()):
                    self.registry.fetch_update(row["id"], **fields)
            return None
        if status["state"] == "cancelled":
            return self.finish(row, "failed", OUTCOMES["worker-error"][1])  # only the gateway cancels
        if status["state"] in ("rejected", "failed"):
            state, message = OUTCOMES[status["code"]]
            return self.finish(row, state, message)
        if status["state"] == "playlist":
            return self.expand(row, status)
        # staged
        title = status.get("title") or row["title"]
        size = status.get("size")
        if size is None or not 0 < size <= MAX_ITEM_BYTES:
            return self.finish(row, "rejected" if size else "failed", OUTCOMES["too-large" if size else "worker-error"][1])
        obtained = status.get("height") if row["kind"] == "video" else None
        if row["kind"] == "video" and (obtained is None or obtained > row["height"]):
            return self.finish(row, "rejected", OUTCOMES["mismatch"][1])
        self.progress = None
        return self.registry.fetch_update(row["id"], state="placing", title=(title or None) and title[:1024], media_id=status.get("id"),
                                          obtained=obtained, percent=None, target_size=size)

    def expand(self, row, status):
        """A submitted link turned out to be a playlist: one waiting row per item (at most 200, and
        within the account's cap), placed in a folder named after the playlist."""
        if not row["expand"]:
            return self.finish(row, "rejected", OUTCOMES["unsupported-link"][1])
        links = [link for link in status["items"][:MAX_PLAYLIST] if link]
        if not links:
            return self.finish(row, "rejected", OUTCOMES["empty-playlist"][1])
        folder = portable_stem(status.get("title"), status.get("id") or "Playlist")
        room = MAX_UNFINISHED - (self.registry.fetch_unfinished(row["uid"]) - 1)
        queued = links[:max(0, room)]
        if queued:
            self.registry.fetch_add(row["uid"], row["device"], row["kind"], row["height"], queued, cap=MAX_UNFINISHED + 1,
                                    folder=folder, expand=False)
        if len(queued) < len(links):
            message = "Added %d items from this playlist; the rest were not added because too many downloads are waiting." % len(queued)
        elif status["more"]:
            message = "Added %d items from this playlist; the rest were not added (at most %d)." % (len(queued), MAX_PLAYLIST)
        else:
            message = "Added %d items from this playlist." % len(queued)
        title = (status.get("title") or "")[:1024] or None
        if title:
            self.registry.fetch_update(row["id"], title=title)
        return self.finish(self.registry.fetch_job(row["id"]), "done", message, destination=KINDS[row["kind"]][0] + "/" + folder)

    # Import --------------------------------------------------------------------------------

    async def place(self, identity):
        """Import a staged file as the submitting device's account (spec #42 Import). Waits while
        writes are fenced; an unknown outcome is read back before the row settles."""
        row = self.registry.fetch_job(identity)
        if row is None or row["state"] != "placing":
            return
        attempts = 0
        while True:
            row = self.registry.fetch_job(identity)
            if row is None or row["state"] != "placing":
                return
            try:
                outcome = await self.import_once(row)
            except asyncio.CancelledError:
                raise
            except Exception as error:  # noqa: BLE001 - a failed import attempt; no detail logged
                log.warning("Fetch import attempt failed (%s)", type(error).__name__)
                outcome = "retry"
            if outcome == "wait":
                await asyncio.sleep(self.tick_seconds * 5)
                continue
            if outcome != "retry":
                return
            attempts += 1
            if attempts >= IMPORT_ATTEMPTS:
                row = self.registry.fetch_job(identity)
                if row is not None and row["state"] == "placing":
                    self.finish(row, "failed", SAVE_FAILED, stop=False)
                return
            await asyncio.sleep(self.tick_seconds)

    def open_staged(self, row):
        """The staged file, opened without following a link: (fd, size). None when unusable."""
        try:
            fd = os.open(self.staged_path(row), os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        except OSError:
            return None
        info = os.fstat(fd)
        head = os.pread(fd, 12, 0)
        # An MP4 family file starts with an `ftyp` box; the worker's ffprobe check is the real one.
        if (not stat.S_ISREG(info.st_mode) or not 0 < info.st_size <= MAX_ITEM_BYTES or info.st_size != row["target_size"]
                or head[4:8] != b"ftyp"):
            os.close(fd)
            return None
        return fd, info.st_size

    async def import_once(self, row):
        """'done', 'failed', 'wait' (writes fenced) or 'retry'."""
        mutations = self.gateway.mutations
        opened = self.open_staged(row)
        if opened is None:
            self.finish(row, "rejected", OUTCOMES["mismatch"][1], stop=False)
            return "failed"
        fd, size = opened
        try:
            async with mutations.lock:
                if not self.registry.mutation_ready():
                    return "wait"
                device = self.device(row)
                if device is None:
                    self.finish(row, "failed", NO_ACCESS, stop=False)
                    return "failed"
                top, extension = KINDS[row["kind"]]
                if row["target"]:
                    # An earlier attempt's outcome was unknown: read its target back first.
                    found = await self.stat(device, row["target"])
                    if found is None:
                        return "retry"
                    if found and found[0] == size:
                        return self.placed(row, row["target"], found[1])
                parent = top + "/"
                await self.make_folder(device, top)
                if row["folder"]:
                    parent += await self.playlist_folder(device, top, row["folder"]) + "/"
                children = await self.children(device, parent)
                name = unique_name(portable_stem(row["title"], row["media_id"] or "download"), extension, list(children))
                target = parent + name
                self.registry.fetch_update(row["id"], target=target, target_size=size)
                if self.device(row) is None:
                    self.finish(row, "failed", NO_ACCESS, stop=False)
                    return "failed"
                return await self.put(row, device, target, fd, size)
        finally:
            os.close(fd)

    def url(self, device, relative):
        return self.gateway.backend + backend_root(device["uid"]) + "/".join(quote(part, safe="") for part in relative.strip("/").split("/"))

    async def put(self, row, device, target, fd, size):
        """One new-file PUT under the write fence; a lost answer is read back, never assumed."""
        registry = self.registry
        registry.mutation_begin(device["id"], target)
        headers = {"If-None-Match": "*", "Content-Length": str(size), "Content-Type": "application/octet-stream"}

        async def body():
            offset = 0
            while offset < size:
                chunk = os.pread(fd, min(1 << 20, size - offset), offset)
                if not chunk:
                    raise OSError("Staged file shrank")
                offset += len(chunk)
                yield chunk

        try:
            async with self.gateway.session.request("PUT", self.url(device, target), data=body(), headers=headers,
                                                    auth=BasicAuth(device["uid"], device["token"]), allow_redirects=False,
                                                    timeout=ClientTimeout(total=None, sock_connect=10, sock_read=900)) as response:
                await response.read()
                status, header = response.status, response.headers.get("OC-FileId")
        except asyncio.CancelledError:
            raise
        except Exception:  # noqa: BLE001 - outcome unknown: read back below
            status, header = None, None
        if status == 201:
            registry.mutation_finish()
            self.gateway.mutations.note_added(device["uid"], header)
            return self.placed(row, target, None, noted=True)
        if status is not None and status < 500:
            registry.mutation_finish()
            if status == 412:
                return "retry"  # created meanwhile outside the gateway: another name next time
            self.finish(row, "failed", SAVE_FAILED, stop=False)
            return "failed"
        found = await self.stat(device, target)
        if found is None:
            return "retry"  # the fence stays closed: operator recovery, then this read back again
        registry.mutation_finish()
        if found and found[0] == size:
            return self.placed(row, target, found[1])
        return "retry"

    def placed(self, row, target, fileid, noted=False):
        if not noted and fileid:
            try:
                self.registry.record_added(row["uid"], fileid)
            except Exception:  # noqa: BLE001 - best effort, as for an upload
                pass
        top = KINDS[row["kind"]][0]
        message = "Saved to %s." % top
        if row["kind"] == "video" and row["obtained"] and row["obtained"] < row["height"]:
            message = "Saved to %s at %dp; %dp was not available." % (top, row["obtained"], row["height"])
        self.finish(row, "done", message, stop=False, destination=target)
        return "done"

    async def stat(self, device, relative):
        """(size, fileid) of an existing file, False when absent, None when unknown."""
        body = (b'<d:propfind xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns"><d:prop><d:getcontentlength/>'
                b'<d:resourcetype/><oc:fileid/></d:prop></d:propfind>')
        try:
            async with self.gateway.session.request("PROPFIND", self.url(device, relative), data=body,
                                                    headers={"Depth": "0", "Content-Type": "application/xml"},
                                                    auth=BasicAuth(device["uid"], device["token"]), allow_redirects=False) as response:
                if response.status == 404:
                    return False
                if response.status != 207:
                    return None
                root = SafeET.fromstring(await bounded_body(response), forbid_dtd=True)
        except asyncio.CancelledError:
            raise
        except Exception:  # noqa: BLE001 - unknown
            return None
        if root.find(".//{DAV:}resourcetype/{DAV:}collection") is not None:
            return (-1, None)
        length = root.findtext(".//{DAV:}getcontentlength") or ""
        return (int(length) if length.isdigit() else -1, file_id(root.findtext(".//{http://owncloud.org/ns}fileid")))

    async def children(self, device, parent):
        """{decoded name: is a folder} directly inside `parent`; empty when it is missing."""
        url = self.url(device, parent) + "/"
        body = b'<d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>'
        async with self.gateway.session.request("PROPFIND", url, data=body, headers={"Depth": "1", "Content-Type": "application/xml"},
                                                auth=BasicAuth(device["uid"], device["token"]), allow_redirects=False) as response:
            if response.status == 404:
                return {}
            if response.status != 207:
                raise web.HTTPBadGateway(text="Could not read the target folder")
            content = await bounded_body(response, 8 * 1024 * 1024)
        base = unquote(urlsplit(url).path).rstrip("/") + "/"
        found = {}
        for _, node in SafeET.iterparse(io.BytesIO(content), events=("end",), forbid_dtd=True):
            if node.tag == "{DAV:}response":
                path = unquote(urlsplit(node.findtext("{DAV:}href") or "").path)
                rest = path[len(base):].rstrip("/") if path.startswith(base) else ""
                if rest and "/" not in rest:
                    found[rest] = node.find(".//{DAV:}resourcetype/{DAV:}collection") is not None
                node.clear()
        return found

    async def make_folder(self, device, relative):
        """Create a folder that does not exist yet (the top folder, a playlist folder)."""
        found = await self.stat(device, relative)
        if found is None:
            raise web.HTTPBadGateway(text="Could not read the target folder")
        if found:
            return
        self.registry.mutation_begin(device["id"], relative)
        async with self.gateway.session.request("MKCOL", self.url(device, relative), auth=BasicAuth(device["uid"], device["token"]),
                                                allow_redirects=False) as response:
            await response.read()
            status = response.status
        self.registry.mutation_finish()
        if status not in (201, 405):
            raise web.HTTPBadGateway(text="Could not create the folder")

    async def playlist_folder(self, device, top, name):
        """The playlist's folder in `top`: an existing folder of that name (or the same apart from
        case and accents) is reused; a file in the way gets the folder a " (n)" name."""
        children = await self.children(device, top + "/")
        for child, folder in children.items():
            if folder and (child == name or portable_names.fold_key(child) == portable_names.fold_key(name)):
                return child
        chosen = unique_name(name, "", list(children))
        await self.make_folder(device, top + "/" + chosen)
        return chosen
