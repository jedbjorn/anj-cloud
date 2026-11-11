"""Structured gateway events and per-source enrollment limits (spec #20, Gateway Hardening 2, 4).

One JSON line per served request goes to stdout (the journald driver in production). Rejected
connections and limit hits are counted and written as one summary line per source per minute.
An enrollment block writes one dedicated ``enroll-block`` line at block start.

Never written: file paths or names, credentials (codes, CSRs, tokens, keys), headers, query
values. Source, status, bytes and duration are allowed (decisions #68, #69 (g)).
"""

from collections import Counter, deque
from datetime import datetime, timezone
import json
import math
import sys
import time

from .protocol import METHODS, READ_METHODS

KNOWN_METHODS = METHODS | {"POST", "PATCH"}
MAX_SOURCES_PER_MINUTE = 4096
REASONS = {400: "rejected", 401: "unauthenticated", 403: "forbidden", 404: "not-found", 405: "method",
           408: "timeout", 409: "conflict", 411: "length-required", 412: "precondition", 413: "too-large",
           415: "unsupported", 416: "range", 423: "locked", 428: "precondition", 429: "limit",
           431: "headers-too-large", 500: "error", 502: "backend", 503: "unavailable", 504: "backend"}


def iso(timestamp):
    return datetime.fromtimestamp(timestamp, timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")[:-4] + "Z"


def route_class(request):
    path, method = request.path, request.method
    if path == "/health":
        return "health"
    if path == "/v1/ca":
        return "ca"
    if path == "/v1/enroll":
        return "enroll"
    if path == "/v1/enroll/status":
        return "enroll-status"
    if path == "/v1/device/certificate":
        return "device-certificate"
    if path == "/v1/files/added":
        return "files-added"
    if path == "/v1/account" or path.startswith("/v1/admin/"):
        # Household administration (spec #27): never codes, fingerprints or bodies.
        return "admin"
    if path == "/v1/household/users" or path == "/v1/shares" or path.startswith("/v1/shares/"):
        # Directory sharing (spec #26): never the path, folder or display name.
        return "share"
    if path.startswith("/v1/client/releases/"):
        # Client update feed (spec #28 G1): never a package or file name.
        return "release"
    if path.startswith("/dav/"):
        return "dav-read" if method in READ_METHODS else "dav-write"
    return "other"


def reason_class(status):
    if status < 400:
        return None
    return REASONS.get(status, "client-error" if status < 500 else "error")


class Events:
    """JSON event lines with per-source, per-minute aggregation of rejects and limit hits."""

    def __init__(self, stream=None, clock=time.time):
        self.stream = stream if stream is not None else sys.stdout
        self.clock = clock
        self.buckets = {}  # minute -> {source: Counter}

    def emit(self, record):
        try:
            self.stream.write(json.dumps(record, separators=(",", ":")) + "\n")
            self.stream.flush()
        except (OSError, ValueError):
            pass

    def request(self, request, response, duration):
        status = response.status
        record = {"time": iso(self.clock()), "event": "request", "source": request.get("anj.source", "unknown"),
                  "route": route_class(request),
                  "method": request.method if request.method in KNOWN_METHODS else "OTHER",
                  "status": status, "bytes": int(getattr(response, "body_length", 0) or 0),
                  "duration_ms": round(duration * 1000, 1)}
        if request.method == "PUT" and request.content_length is not None:
            record["bytes_in"] = int(request.content_length)
        if "anj.device" in request:
            record["device"] = request["anj.device"]
            record["cert_sha256"] = request["anj.cert"]
        reason = request.get("anj.reason") or reason_class(status)
        if reason:
            record["reason"] = reason
        self.emit(record)
        self.flush()

    def count(self, source, kind):
        now = self.clock()
        minute = int(now // 60)
        sources = self.buckets.setdefault(minute, {})
        if source not in sources and len(sources) >= MAX_SOURCES_PER_MINUTE:
            source = "other"
        sources.setdefault(source, Counter())[kind] += 1
        self.flush()

    def flush(self, force=False):
        current = int(self.clock() // 60)
        for minute in sorted(self.buckets):
            if minute >= current and not force:
                continue
            for source, counts in self.buckets.pop(minute).items():
                self.emit({"time": iso((minute + 1) * 60), "event": "summary", "minute": iso(minute * 60),
                           "source": source, "counts": dict(sorted(counts.items())), "total": sum(counts.values())})

    def enroll_block(self, source, failures, start, end):
        self.emit({"time": iso(start), "event": "enroll-block", "source": source, "failures": failures,
                   "block_start": iso(start), "block_end": iso(end)})


class EnrollmentGuard:
    """Per-source enrollment rate, failure counting and temporary block, plus a global backstop.

    - per source at most ``rate`` admitted requests per ``window`` seconds across /v1/enroll*;
    - ``failures`` failed attempts within ``failure_window`` seconds block that source's
      enrollment for ``block`` seconds (decision #69 (a)); paired DAV is never affected;
    - a global window of ``global_rate`` per ``window`` that one source cannot exhaust.
    """

    def __init__(self, events, *, clock=time.monotonic, wall=time.time, rate=10, window=60.0,
                 failures=8, failure_window=600.0, block=900.0, global_rate=120, max_sources=10000):
        if global_rate <= rate:
            raise ValueError("The global enrollment window must exceed one source's limit")
        self.events, self.clock, self.wall = events, clock, wall
        self.rate, self.window = rate, window
        self.threshold, self.failure_window, self.block_seconds = failures, failure_window, block
        self.global_rate, self.max_sources = global_rate, max_sources
        self.requests = {}
        self.failures = {}
        self.blocks = {}
        self.recent = deque()
        # Block start times (wall clock) for the Admin Health count (spec #27).
        self.history = deque(maxlen=1000)

    @staticmethod
    def _trim(times, horizon):
        while times and times[0] <= horizon:
            times.popleft()

    def _prune(self, now):
        if len(self.requests) + len(self.failures) + len(self.blocks) < self.max_sources:
            return
        for table, horizon in ((self.requests, now - self.window), (self.failures, now - self.failure_window)):
            for source in list(table):
                self._trim(table[source], horizon)
                if not table[source]:
                    del table[source]
        for source, until in list(self.blocks.items()):
            if until <= now:
                del self.blocks[source]

    def blocked(self, source):
        until = self.blocks.get(source)
        if until is None:
            return False
        if until <= self.clock():
            del self.blocks[source]
            return False
        return True

    def admit(self, source):
        """Return None when admitted, otherwise the limit reason for a 429."""
        now = self.clock()
        self._prune(now)
        if self.blocked(source):
            return "enroll-blocked"
        times = self.requests.setdefault(source, deque())
        self._trim(times, now - self.window)
        if len(times) >= self.rate:
            return "enroll-rate"
        self._trim(self.recent, now - self.window)
        if len(self.recent) >= self.global_rate:
            return "enroll-global"
        times.append(now)
        self.recent.append(now)
        return None

    def retry_after(self, source, reason):
        """Whole seconds (at least 1) until a request refused with `reason` could be admitted.

        Call right after the `admit` that returned `reason`. It states only the wait: never a
        count of attempts or failures left (the limits themselves are unchanged).
        """
        now = self.clock()
        if reason == "enroll-blocked":
            until = self.blocks.get(source, now)
        elif reason == "enroll-rate":
            times = self.requests.get(source)
            until = (times[0] + self.window) if times else now
        else:
            until = (self.recent[0] + self.window) if self.recent else now
        return max(1, math.ceil(until - now))

    def failed(self, source):
        """Record one rejected enrollment attempt; start a block at the threshold."""
        now = self.clock()
        if self.blocked(source):
            return False
        times = self.failures.setdefault(source, deque())
        self._trim(times, now - self.failure_window)
        times.append(now)
        if len(times) < self.threshold:
            return False
        count = len(times)
        del self.failures[source]
        self.blocks[source] = now + self.block_seconds
        start = self.wall()
        self.history.append(start)
        self.events.enroll_block(source, count, start, start + self.block_seconds)
        return True
