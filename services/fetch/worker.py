"""Media fetch worker (spec #42 F1): one job at a time from the spool, with yt-dlp and ffmpeg.

The gateway (services/access/fetch.py) hands a job over as `jobs/<dispatch>/request.json`; this
process claims it by writing `status.json`, downloads with the preset's format selector, checks the
result with ffprobe and leaves `media.m4a` or `media.mp4` in the same directory. It reports only
fixed codes; yt-dlp's own output never leaves this process, and nothing here logs a link, a title
or a path. A `cancel` file, or the directory disappearing, stops the job at once.

yt-dlp runs from the tools volume. The image's baseline is copied there first; yt-dlp's updater
(stable channel, which verifies the release's SHA2-256SUMS) refreshes a copy once a day and once
after an extraction error, and the copy replaces the working one only after it runs. A failed or
blocked update leaves the working copy as it was.
"""

import contextlib
import json
import os
import re
from pathlib import Path
import secrets
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
import presets  # noqa: E402

SPOOL = Path(os.environ.get("ANJ_FETCH_SPOOL_DIR", "/spool"))
TOOLS = Path(os.environ.get("ANJ_FETCH_TOOLS", "/var/lib/anj-fetch-tools"))
BASELINE = Path(os.environ.get("ANJ_FETCH_BASELINE", "/opt/anj-fetch/baseline/yt-dlp"))
FIXTURE_HOST = os.environ.get("ANJ_FETCH_FIXTURE_HOST", "")  # dev/review only
DENO = os.environ.get("ANJ_FETCH_DENO", "/usr/local/bin/deno")
FFMPEG_DIR = os.environ.get("ANJ_FETCH_FFMPEG_DIR", "/usr/local/bin")
UPDATE_EVERY = 24 * 3600
UPDATE_AFTER_ERROR_EVERY = 3600
CHECK_TIMEOUT = 15 * 60
MAX_INFO = 64 * 1024 * 1024
KEEPALIVE = 20.0  # while merging, checking or updating there is no byte progress: `tick` moves instead
# yt-dlp's post-processing steps, announced on stdout once the download itself is over.
PROCESSING = re.compile(r"\[(Merger|ExtractAudio|VideoRemuxer|VideoConvertor|EmbedThumbnail|ThumbnailsConvertor|Metadata|Fixup\w*)\]")
DISPATCH_LENGTH = 24


def log(message):
    print("fetch-worker: " + message, flush=True)


def atomic_json(path, value):
    temporary = path.with_name(path.name.replace(".json", ".tmp"))
    with open(temporary, "w") as stream:
        json.dump(value, stream, separators=(",", ":"))
    os.replace(temporary, path)


def version_key(text):
    try:
        return tuple(int(part) for part in text.strip().split("."))
    except (AttributeError, ValueError):
        return ()


class Tools:
    """The working yt-dlp on the tools volume and its updates."""

    def __init__(self, tools=TOOLS, baseline=BASELINE, run=subprocess.run, clock=time.time):
        self.dir, self.baseline, self.run, self.clock = Path(tools), Path(baseline), run, clock
        self.path = self.dir / "yt-dlp"
        self.state = self.dir / "update.json"
        self.last_error_update = 0.0

    def version(self, path=None):
        try:
            result = self.run([sys.executable, "-I", str(path or self.path), "--ignore-config", "--version"],
                              capture_output=True, text=True, timeout=60)
        except (OSError, subprocess.TimeoutExpired):
            return None
        text = result.stdout.strip()
        return text if result.returncode == 0 and version_key(text) else None

    def install(self):
        """Start from the image's baseline when the volume has no working copy or an older one."""
        (self.dir / "cache").mkdir(mode=0o700, exist_ok=True)
        current, baseline = self.version(), self.version(self.baseline)
        if baseline and (current is None or version_key(current) < version_key(baseline)):
            temporary = self.dir / "yt-dlp.baseline"
            shutil.copyfile(self.baseline, temporary)
            os.replace(temporary, self.path)
            current = baseline
        return current

    def due(self):
        try:
            last = json.loads(self.state.read_text()).get("checked", 0)
        except (OSError, ValueError, AttributeError):
            last = 0
        return self.clock() - last >= UPDATE_EVERY

    def update(self, reason="daily"):
        """yt-dlp's own updater on a copy; the copy becomes the working one only if it runs.
        Returns the working version afterwards."""
        current = self.version()
        candidate = self.dir / "yt-dlp.next"
        try:
            shutil.copyfile(self.path, candidate)
            result = self.run([sys.executable, "-I", str(candidate), "--ignore-config", "--no-warnings", "--update-to", "stable"],
                              capture_output=True, text=True, timeout=600)
            updated = self.version(candidate) if result.returncode == 0 else None
            if updated and version_key(updated) >= version_key(current or ""):
                os.replace(candidate, self.path)
                current = updated
                outcome = "ok"
            else:
                outcome = "failed"
        except (OSError, subprocess.TimeoutExpired):
            outcome = "failed"
        finally:
            try:
                candidate.unlink()
            except OSError:
                pass
        try:
            atomic_json(self.state, {"checked": self.clock(), "outcome": outcome, "reason": reason, "version": current})
        except OSError:
            pass
        log("yt-dlp update %s (%s), version %s" % (outcome, reason, current))
        return current


def guarded():
    """True when the network guard drops this namespace's traffic to its default gateway (the
    Docker host): a dropped datagram is refused at once with EPERM, which an unguarded namespace
    never returns. No default route also counts (nothing to reach)."""
    try:
        with open("/proc/net/route") as routes:
            for line in routes.readlines()[1:]:
                fields = line.split()
                if fields[1] == "00000000" and int(fields[3], 16) & 2:
                    gateway = socket.inet_ntoa(struct.pack("<L", int(fields[2], 16)))
                    break
            else:
                return True
    except (OSError, IndexError, ValueError):
        return False
    probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        probe.sendto(b"\0", (gateway, 9))
    except PermissionError:
        return True
    except OSError:
        return False
    finally:
        probe.close()
    return False


class Stopped(Exception):
    def __init__(self, reason):
        super().__init__(reason)
        self.reason = reason


class Job:
    def __init__(self, worker, directory, request):
        self.worker, self.dir, self.request = worker, directory, request
        self.kind, self.height = request["kind"], request.get("height")
        self.status = {"v": 1, "boot": worker.boot, "state": "checking", "bytes": 0, "tick": 0}
        self.lock = threading.Lock()
        self.busy = 0  # > 0 while merging, probing or updating: the keepalive moves `tick`

    def report(self, **fields):
        with self.lock:
            self.status.update(fields)
            if (self.dir / "request.json").exists():
                atomic_json(self.dir / "status.json", self.status)

    @contextlib.contextmanager
    def keepalive(self):
        """Keep the status moving (`tick`) while work without byte progress runs, so the gateway's
        5-minute stall rule only ever sees a real stall."""
        self.busy += 1
        try:
            yield
        finally:
            self.busy -= 1

    def ticker(self, done):
        while not done.wait(KEEPALIVE):
            if self.busy:
                try:
                    self.report(tick=self.status["tick"] + 1)
                except OSError:
                    pass

    def stopped(self):
        return (self.dir / "cancel").exists() or not (self.dir / "request.json").exists()

    def tool(self, args, *, on_line=None, limit=None, timeout=None):
        """Run yt-dlp; stdout lines go to `on_line` (or are collected). Raises Stopped on cancel,
        too-large or timeout. Returns (exit code, stdout, stderr)."""
        # Warnings stay in the captured stderr (never logged): they tell a site change from a link
        # that never had a fitting format.
        argv = [sys.executable, "-I", str(self.worker.tools.path), "--ignore-config", "--no-color",
                "--no-playlist", "--cache-dir", str(self.worker.tools.dir / "cache"), "--socket-timeout", "30",
                "--retries", "3", "--fragment-retries", "3", "--js-runtimes", "deno:" + DENO, "--ffmpeg-location", FFMPEG_DIR, *args]
        with tempfile.TemporaryFile(dir="/tmp") as errors:
            process = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=errors, stdin=subprocess.DEVNULL,
                                       cwd=self.dir, start_new_session=True)
            reason, started = [], time.monotonic()

            def watch():
                while process.poll() is None:
                    why = ("cancelled" if self.stopped() else "timeout" if timeout and time.monotonic() - started > timeout
                           else "too-large" if limit and limit() else None)
                    if why:
                        reason.append(why)
                        try:
                            os.killpg(process.pid, signal.SIGKILL)
                        except OSError:
                            pass
                        return
                    time.sleep(0.5)

            watcher = threading.Thread(target=watch, daemon=True)
            watcher.start()
            output, size = [], 0
            for line in process.stdout:
                if on_line is not None:
                    on_line(line.decode("utf-8", "replace"))
                else:
                    size += len(line)
                    if size > MAX_INFO:
                        reason.append("too-large")
                        os.killpg(process.pid, signal.SIGKILL)
                        break
                    output.append(line)
            process.wait()
            watcher.join(2)
            errors.seek(0)
            stderr = errors.read()[-65536:].decode("utf-8", "replace")
        if reason:
            raise Stopped(reason[0])
        return process.returncode, b"".join(output), stderr

    def run(self):
        url = self.request["url"]
        self.report(state="checking")
        refused = presets.reach(url, FIXTURE_HOST)
        if refused:
            return self.report(state="rejected", code=refused)
        selector = presets.selector(self.kind, self.height)
        info = self.check(url, selector)
        if info is None:
            return
        if info.get("_type") == "playlist":
            entries = [entry for entry in (info.get("entries") or []) if isinstance(entry, dict)]
            items = [{"url": entry.get("url") or entry.get("webpage_url")} for entry in entries[:201]]
            items = [item for item in items if isinstance(item["url"], str)]
            title = info.get("title") if isinstance(info.get("title"), str) else None
            return self.report(state="playlist", title=title and title[:1024], id=self.media_id(info), items=items,
                               more=len(entries) > 200)
        refused = presets.limits(info)
        if refused:
            return self.report(state="rejected", code=refused)
        title = info.get("track") if self.kind == "audio" and isinstance(info.get("track"), str) else info.get("title")
        self.report(state="downloading", percent=0.0, title=title[:1024] if isinstance(title, str) else None,
                    id=self.media_id(info))
        self.download(info, selector)

    @staticmethod
    def media_id(info):
        value = info.get("id")
        return value[:64] if isinstance(value, str) and value and all(c.isalnum() or c in "_-." for c in value) \
            and value[0] not in ".-" else None

    def check(self, url, selector):
        """The item's (or playlist's) metadata with the preset's format already selected."""
        for attempt in (1, 2):
            code, output, stderr = self.tool(["--flat-playlist", "--playlist-items", "1:201", "-J", "-f", selector, url],
                                             timeout=CHECK_TIMEOUT)
            if code == 0:
                try:
                    info = json.loads(output)
                except ValueError:
                    info = None
                if isinstance(info, dict):
                    return info
                reason, retry = "worker-error", False
            else:
                reason, retry = presets.classify(stderr)
            if attempt == 1 and retry:
                with self.keepalive():
                    updated = self.worker.update_after_error()
                if updated:
                    continue
            if reason == "unsupported-format" and retry:
                # The site normally offers fitting formats, or yt-dlp warned of a challenge it could
                # not solve: a site change, not an unsupported link. It may work after an update.
                reason = "site-changed"
            self.report(state=presets_state(reason), code=reason)
            return None
        return None

    def download(self, info, selector):
        extension = presets.PRESETS[self.kind]["ext"]
        expected = {}
        for item in info.get("requested_formats") or [info]:
            size = presets.estimated_bytes({**item, "duration": info.get("duration")}) if item is not info else presets.estimated_bytes(info)
            expected[str(item.get("format_id"))] = size or 0
        seen, processing = {}, []

        def on_line(line):
            if PROCESSING.match(line) and not processing:
                processing.append(True)
                self.busy += 1  # the download is over; merging and fixing have no byte progress
            if not line.startswith("ANJ "):
                return
            parts = line.split()
            if len(parts) < 5:
                return
            done = int(parts[1]) if parts[1].isdigit() else 0
            total = int(parts[2]) if parts[2].isdigit() else int(float(parts[3])) if parts[3].replace(".", "", 1).isdigit() else 0
            seen[parts[4]] = (done, total or expected.get(parts[4], 0))
            got = sum(value[0] for value in seen.values())
            whole = sum(max(seen.get(key, (0, 0))[1], size) for key, size in expected.items()) or sum(v[1] for v in seen.values())
            percent = min(99.0, 100.0 * got / whole) if whole else 0.0
            if got != self.status["bytes"]:
                self.report(bytes=got, percent=round(percent, 1))

        def too_large():
            if sum(value[0] for value in seen.values()) > presets.MAX_BYTES:
                return True
            return directory_bytes(self.dir) > 2 * presets.MAX_BYTES + presets.GIB

        info_file = Path(tempfile.mkdtemp(dir="/tmp")) / "info.json"
        try:
            info_file.write_text(json.dumps(info))
            args = ["--load-info-json", str(info_file), "-f", selector, *presets.PRESETS[self.kind]["args"],
                    "-P", str(self.dir), "-P", "temp:" + str(self.dir), "-o", "media.%(ext)s", "--no-mtime", "--newline",
                    "--progress-template",
                    "download:ANJ %(progress.downloaded_bytes)s %(progress.total_bytes)s %(progress.total_bytes_estimate)s %(info.format_id)s"]
            try:
                code, _, stderr = self.tool(args, on_line=on_line, limit=too_large, timeout=3 * 3600)
                if processing:
                    self.busy -= 1
            except Stopped as stop:
                if stop.reason == "too-large":
                    self.clean(keep=())
                    return self.report(state="rejected", code="too-large")
                raise
        finally:
            shutil.rmtree(info_file.parent, ignore_errors=True)
        staged = self.dir / ("media." + extension)
        if code != 0 or not staged.is_file() or staged.is_symlink():
            reason = presets.classify(stderr)[0] if code != 0 else "worker-error"
            self.clean(keep=())
            return self.report(state=presets_state(reason), code=reason)
        self.clean(keep=(staged.name,))
        size = staged.stat().st_size
        if size > presets.MAX_BYTES:
            staged.unlink()
            return self.report(state="rejected", code="too-large")
        with self.keepalive():
            probe = subprocess.run([os.path.join(FFMPEG_DIR, "ffprobe"), "-v", "error", "-show_format", "-show_streams",
                                    "-of", "json", str(staged)], capture_output=True, timeout=300)
        ok, obtained = presets.verdict(probe.stdout if probe.returncode == 0 else b"", self.kind, self.height)
        if not ok or size <= 0:
            staged.unlink()
            return self.report(state="rejected", code="mismatch")
        self.report(state="staged", size=size, height=obtained, percent=100.0, bytes=size)

    def clean(self, keep):
        """Remove the job's scratch files, keeping the protocol files and `keep`."""
        for entry in os.scandir(self.dir):
            if entry.name in ("request.json", "status.json", "cancel", *keep):
                continue
            try:
                shutil.rmtree(entry.path) if entry.is_dir(follow_symlinks=False) else os.unlink(entry.path)
            except OSError:
                pass


def presets_state(code):
    # "site-changed" is a failure (Couldn't download, may work later), never "Not supported".
    return "rejected" if code in ("unsupported-format", "too-long", "too-large", "private-address", "unsupported-link",
                                  "live", "empty-playlist", "mismatch") else "failed"


def directory_bytes(path):
    total = 0
    try:
        for entry in os.scandir(path):
            if entry.is_file(follow_symlinks=False):
                total += entry.stat(follow_symlinks=False).st_blocks * 512
    except OSError:
        pass
    return total


class Worker:
    def __init__(self, spool=SPOOL, tools=None):
        self.spool = Path(spool)
        self.tools = tools or Tools()
        self.boot = secrets.token_hex(8)
        self.seq = 0
        self.job = None
        self.version = None
        self.updating = False
        self.beat_lock = threading.Lock()
        self.stop = threading.Event()

    def beat(self):
        with self.beat_lock:
            self.seq += 1
            try:
                atomic_json(self.spool / "worker" / "heartbeat.json",
                            {"v": 1, "boot": self.boot, "seq": self.seq, "job": self.job, "version": self.version,
                             "updating": self.updating})
            except OSError:
                pass  # the gateway has not prepared the spool yet

    def heartbeat(self):
        while not self.stop.wait(2.0):
            self.beat()

    def update_after_error(self):
        """At most once an hour, so a run of failing items does not hammer the release server."""
        if time.monotonic() - self.tools.last_error_update < UPDATE_AFTER_ERROR_EVERY and self.tools.last_error_update:
            return False
        self.tools.last_error_update = time.monotonic()
        before = self.version
        self.version = self.tools.update("after-error")
        return bool(self.version and self.version != before)

    def next_request(self):
        try:
            names = os.listdir(self.spool / "jobs")
        except OSError:
            return None
        candidates = []
        for name in names:
            directory = self.spool / "jobs" / name
            if len(name) != DISPATCH_LENGTH or (directory / "status.json").exists() or (directory / "cancel").exists():
                continue
            try:
                candidates.append(((directory / "request.json").stat().st_mtime, name))
            except OSError:
                continue
        for _, name in sorted(candidates):
            directory = self.spool / "jobs" / name
            try:
                if (directory / "request.json").stat().st_size > 16384:
                    continue
                request = json.loads((directory / "request.json").read_text())
            except (OSError, ValueError):
                continue
            if (isinstance(request, dict) and request.get("v") == 1 and isinstance(request.get("url"), str)
                    and request.get("kind") in presets.PRESETS and (request["kind"] == "audio" or request.get("height") in (1080, 720))):
                return name, directory, request
        return None

    def serve_one(self):
        found = self.next_request()
        if found is None:
            return False
        name, directory, request = found
        self.job = name
        self.beat()
        job = Job(self, directory, request)
        log("job %s started" % name[:8])
        done = threading.Event()
        threading.Thread(target=job.ticker, args=(done,), daemon=True).start()
        try:
            if not guarded():
                job.report(state="failed", code="worker-error")
                log("network guard missing: refusing to work")
                raise SystemExit(3)
            job.run()
        except Stopped:
            job.clean(keep=())
            job.report(state="cancelled")
        except SystemExit:
            raise
        except Exception as error:  # noqa: BLE001 - any fault fails this job only
            log("job %s fault (%s)" % (name[:8], type(error).__name__))
            try:
                job.clean(keep=())
                job.report(state="failed", code="worker-error")
            except OSError:
                pass
        finally:
            done.set()
        log("job %s %s%s" % (name[:8], job.status.get("state"), " " + job.status["code"] if job.status.get("code") else ""))
        self.job = None
        self.beat()
        return True

    def main(self):
        os.umask(0o007)
        self.version = self.tools.install()
        log("started, yt-dlp %s" % self.version)
        threading.Thread(target=self.heartbeat, daemon=True).start()
        signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
        while True:
            if self.tools.due():
                # Said in the heartbeat: a job handed over meanwhile is waiting, not stalled.
                self.updating = True
                self.beat()
                try:
                    self.version = self.tools.update("daily")
                finally:
                    self.updating = False
                    self.beat()
            if not self.serve_one():
                time.sleep(1.0)


if __name__ == "__main__":
    if sys.argv[1:] == ["update"]:
        tools = Tools()
        tools.install()
        print(tools.update("manual"))
        sys.exit(0)
    if sys.argv[1:] == ["version"]:
        print(Tools().version())
        sys.exit(0)
    Worker().main()
