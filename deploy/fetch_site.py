"""Deterministic fixture site for the media fetch worker (spec #42 acceptance; dev and review only).

Runs inside the `fetch-fixture` container of `deploy/compose.fetch-fixture.json` (the fetch image:
Python and ffmpeg). It generates short synthetic media with ffmpeg into its data directory once,
then serves pages yt-dlp's generic extractor reads: a JSON-LD VideoObject (title, uploader,
duration, cover) whose content is a DASH manifest listing H.264, VP9, AAC and Opus streams.
Nothing here is real media or a real site.

    fetch_site.py serve [--port 8080]       generate missing media, then serve
    fetch_site.py make-huge BYTES           an H.264+AAC MP4 padded to BYTES (the large-import case)

Items (/item/<name>.html):
    song     H.264 1080p and 720p, VP9 1080p, AAC, Opus
    low      H.264 480p and AAC only (a 1080p job obtains 480p)
    vp9      VP9 and Opus only (no fitting stream: rejected)
    long     metadata says 5 hours (rejected before download)
    big      metadata says about 11 GB (rejected before download)
    fake     the manifest claims H.264 but serves VP9 (the ffprobe check rejects it)
    slow     H.264+AAC 720p in one file, served at about 256 KiB/s (restart and revoke cases)
    long1080 two minutes of 1080p H.264 plus AAC (the memory measurement)
    huge     H.264+AAC 720p in one file padded by make-huge
    escape   a title that tries to leave its folder
    con      a title that is a Windows device name
Playlists (/list/<n>.rss): an RSS feed of n items, all pointing at `song` (?i=k).
"""

import argparse
import hashlib
import http.server
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import time
from urllib.parse import parse_qs, urlsplit

DATA = Path(os.environ.get("ANJ_FIXTURE_DATA", "/data"))
FFMPEG = shutil.which("ffmpeg") or "/usr/local/bin/ffmpeg"
SLOW_RATE = 256 * 1024

MEDIA = {
    "v1080.mp4": ["-f", "lavfi", "-i", "testsrc2=size=1920x1080:rate=25", "-t", "4", "-c:v", "libx264", "-preset", "ultrafast",
                  "-pix_fmt", "yuv420p", "-an"],
    "v720.mp4": ["-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=25", "-t", "4", "-c:v", "libx264", "-preset", "ultrafast",
                 "-pix_fmt", "yuv420p", "-an"],
    "v480.mp4": ["-f", "lavfi", "-i", "testsrc2=size=854x480:rate=25", "-t", "4", "-c:v", "libx264", "-preset", "ultrafast",
                 "-pix_fmt", "yuv420p", "-an"],
    "vvp9.webm": ["-f", "lavfi", "-i", "testsrc2=size=1920x1080:rate=25", "-t", "4", "-c:v", "libvpx-vp9", "-deadline", "realtime",
                  "-cpu-used", "8", "-an"],
    "a.m4a": ["-f", "lavfi", "-i", "sine=frequency=440:duration=4", "-c:a", "aac", "-b:a", "96k", "-vn"],
    "a.webm": ["-f", "lavfi", "-i", "sine=frequency=440:duration=4", "-c:a", "libopus", "-vn"],
    "cover.png": ["-f", "lavfi", "-i", "testsrc2=size=320x320", "-frames:v", "1"],
    "muxed720.mp4": ["-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=25", "-f", "lavfi", "-i", "sine=frequency=330:duration=60",
                     "-t", "60", "-c:v", "libx264", "-preset", "ultrafast", "-b:v", "2M", "-pix_fmt", "yuv420p", "-c:a", "aac",
                     "-movflags", "+faststart"],
    "p1080.mp4": ["-f", "lavfi", "-i", "testsrc2=size=1080x1920:rate=25", "-t", "4", "-c:v", "libx264", "-preset", "ultrafast",
                  "-pix_fmt", "yuv420p", "-an"],
    "p720.mp4": ["-f", "lavfi", "-i", "testsrc2=size=720x1280:rate=25", "-t", "4", "-c:v", "libx264", "-preset", "ultrafast",
                 "-pix_fmt", "yuv420p", "-an"],
    "l1080.mp4": ["-f", "lavfi", "-i", "testsrc2=size=1920x1080:rate=25", "-t", "120", "-c:v", "libx264", "-preset", "ultrafast",
                  "-pix_fmt", "yuv420p", "-an"],
    "l1080.m4a": ["-f", "lavfi", "-i", "sine=frequency=220:duration=120", "-c:a", "aac", "-b:a", "128k", "-vn"],
}

# name -> (title, duration seconds, [(id, mime, codecs, height, bandwidth, file)])
ITEMS = {
    "song": ("Fixture Song: One", 4, [("v1080", "video/mp4", "avc1.640028", 1080, 14800000, "v1080.mp4"),
                                      ("v720", "video/mp4", "avc1.64001f", 720, 6500000, "v720.mp4"),
                                      ("vp9", "video/webm", "vp9", 1080, 7500000, "vvp9.webm"),
                                      ("aac", "audio/mp4", "mp4a.40.2", None, 100000, "a.m4a"),
                                      ("opus", "audio/webm", "opus", None, 80000, "a.webm")]),
    "low": ("Fixture Low", 4, [("v480", "video/mp4", "avc1.64001e", 480, 3000000, "v480.mp4"),
                               ("aac", "audio/mp4", "mp4a.40.2", None, 100000, "a.m4a")]),
    "vp9": ("Fixture Webm Only", 4, [("vp9", "video/webm", "vp9", 1080, 7500000, "vvp9.webm"),
                                     ("opus", "audio/webm", "opus", None, 80000, "a.webm")]),
    "long": ("Fixture Five Hours", 18000, [("v720", "video/mp4", "avc1.64001f", 720, 1000, "v720.mp4"),
                                           ("aac", "audio/mp4", "mp4a.40.2", None, 100, "a.m4a")]),
    "big": ("Fixture Too Big", 3600, [("v1080", "video/mp4", "avc1.640028", 1080, 25000000, "v1080.mp4"),
                                      ("aac", "audio/mp4", "mp4a.40.2", None, 100000, "a.m4a")]),
    "fake": ("Fixture Pretender", 4, [("v1080", "video/mp4", "avc1.640028", 1080, 7500000, "vvp9.webm"),
                                      ("aac", "audio/mp4", "mp4a.40.2", None, 100000, "a.m4a")]),
    "slow": ("Fixture Slow", 60, [("mux", "video/mp4", "avc1.64001f,mp4a.40.2", 720, 2200000, "slow/muxed720.mp4")]),
    "long1080": ("Fixture Long 1080", 120, [("v1080", "video/mp4", "avc1.640028", 1080, 20000000, "l1080.mp4"),
                                            ("aac", "audio/mp4", "mp4a.40.2", None, 128000, "l1080.m4a")]),
    "huge": ("Fixture Huge", 60, [("mux", "video/mp4", "avc1.64001f,mp4a.40.2", 720, 2200000, "huge.mp4")]),
    "escape": ("../../Escape: <try>/x\\y?.", 4, [("v720", "video/mp4", "avc1.64001f", 720, 6500000, "v720.mp4"),
                                                  ("aac", "audio/mp4", "mp4a.40.2", None, 100000, "a.m4a")]),
    "con": ("CON", 4, [("aac", "audio/mp4", "mp4a.40.2", None, 100000, "a.m4a")]),
    "portrait": ("Fixture Portrait", 4, [("p1080", "video/mp4", "avc1.640028", (1080, 1920), 14800000, "p1080.mp4"),
                                         ("p720", "video/mp4", "avc1.64001f", (720, 1280), 6500000, "p720.mp4"),
                                         ("aac", "audio/mp4", "mp4a.40.2", None, 100000, "a.m4a")]),
    # Non-Latin titles: Persian with a zero-width non-joiner, and a family emoji joined by ZWJ.
    "persian": ("\u0645\u06cc\u200c\u062e\u0648\u0627\u0647\u0645 \u0622\u0647\u0646\u06af", 4,
                [("aac", "audio/mp4", "mp4a.40.2", None, 100000, "a.m4a")]),
    "emoji": ("Family \U0001f468\u200d\U0001f469\u200d\U0001f467 song", 4, [("aac", "audio/mp4", "mp4a.40.2", None, 100000, "a.m4a")]),
}


def generate():
    (DATA / "media").mkdir(parents=True, exist_ok=True)
    for name, args in MEDIA.items():
        target = DATA / "media" / name
        if not target.exists():
            temporary = target.with_name(".tmp-" + name)
            # Few encoder threads: the container's process limit is small.
            subprocess.run([FFMPEG, "-v", "error", "-y", *args, "-threads", "2", "-f", "webm" if name.endswith(".webm") else "image2" if name.endswith(".png")
                            else "mp4", str(temporary)], check=True, timeout=1200)
            os.replace(temporary, target)


def make_huge(size):
    """muxed720.mp4 followed by one top-level `free` box (64-bit size): ffprobe and yt-dlp take the
    MP4 as is, the file is `size` bytes, and its SHA-256 is printed."""
    source = (DATA / "media" / "muxed720.mp4").read_bytes()
    pad = size - len(source)
    if pad < 16:
        raise SystemExit("size too small")
    target = DATA / "media" / "huge.mp4"
    digest = hashlib.sha256()
    block = bytes(1 << 20)
    with open(target.with_name(".tmp-huge"), "wb") as stream:
        for part in (source, struct.pack(">I4sQ", 1, b"free", pad)):
            stream.write(part)
            digest.update(part)
        left = pad - 16
        while left:
            chunk = block[:min(len(block), left)]
            stream.write(chunk)
            digest.update(chunk)
            left -= len(chunk)
    os.replace(target.with_name(".tmp-huge"), target)
    print(json.dumps({"size": target.stat().st_size, "sha256": digest.hexdigest()}))


def mpd(name):
    title, duration, streams = ITEMS[name]
    sets = {}
    for ident, mime, codecs, height, bandwidth, path in streams:
        attributes = 'id="%s" codecs="%s" bandwidth="%d"' % (ident, codecs, bandwidth)
        if isinstance(height, tuple):
            attributes += ' width="%d" height="%d"' % height
        elif height:
            attributes += ' width="%d" height="%d"' % (height * 16 // 9, height)
        else:
            attributes += ' audioSamplingRate="44100"'
        sets.setdefault(mime, []).append('<Representation %s><BaseURL>/media/%s</BaseURL></Representation>' % (attributes, path))
    body = "".join('<AdaptationSet mimeType="%s">%s</AdaptationSet>' % (mime, "".join(rows)) for mime, rows in sets.items())
    return ('<?xml version="1.0"?><MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" mediaPresentationDuration="PT%dS" '
            'minBufferTime="PT2S" profiles="urn:mpeg:dash:profile:isoff-on-demand:2011"><Period>%s</Period></MPD>' % (duration, body))


def page(base, name):
    title, duration, _ = ITEMS[name]
    data = {"@context": "https://schema.org", "@type": "VideoObject", "name": title, "description": "Synthetic fixture.",
            "thumbnailUrl": base + "/media/cover.png", "uploadDate": "2026-11-01", "duration": "PT%dS" % duration,
            "contentUrl": base + "/dash/" + name + ".mpd", "author": {"@type": "Person", "name": "Fixture Artist"}}
    return ('<!DOCTYPE html><html><head><meta charset="utf-8"><title>fixture</title><script type="application/ld+json">%s'
            '</script></head><body><p>fixture</p></body></html>' % json.dumps(data))


def feed(base, count):
    items = "".join('<item><title>Item %d</title><link>%s/item/song.html?i=%d</link><guid>i%d</guid></item>' % (n, base, n, n)
                    for n in range(1, count + 1))
    return ('<?xml version="1.0"?><rss version="2.0"><channel><title>Fixture Mix: Vol/1</title><link>%s/</link>'
            '<description>fixture</description>%s</channel></rss>' % (base, items))


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send(self, body, kind, status=200):
        data = body.encode() if isinstance(body, str) else body
        self.send_response(status)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        parts = urlsplit(self.path)
        path = parts.path
        base = "http://" + (self.headers.get("Host") or "fetch-fixture:8080")
        if path.startswith("/item/") and path.endswith(".html") and path[6:-5] in ITEMS:
            return self.send(page(base, path[6:-5]), "text/html; charset=utf-8")
        if path.startswith("/dash/") and path.endswith(".mpd") and path[6:-4] in ITEMS:
            return self.send(mpd(path[6:-4]), "application/dash+xml")
        if path.startswith("/list/") and path.endswith(".rss") and path[6:-4].isdigit():
            return self.send(feed(base, int(path[6:-4])), "application/rss+xml")
        if path.startswith("/media/"):
            slow = path.startswith("/media/slow/")
            name = path[len("/media/slow/" if slow else "/media/"):]
            target = DATA / "media" / name
            if "/" not in name and target.is_file():
                return self.file(target, slow)
        self.send("not found", "text/plain", 404)

    def file(self, target, slow):
        size = target.stat().st_size
        start, end = 0, size - 1
        header = self.headers.get("Range", "")
        if header.startswith("bytes="):
            first, _, last = header[6:].partition("-")
            start = int(first or 0)
            end = min(int(last), size - 1) if last else size - 1
            self.send_response(206)
            self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, size))
        else:
            self.send_response(200)
        self.send_header("Content-Type", "video/mp4" if target.suffix == ".mp4" else "audio/mp4" if target.suffix == ".m4a"
                         else "video/webm" if target.suffix == ".webm" else "image/png")
        self.send_header("Content-Length", str(end - start + 1))
        self.send_header("Accept-Ranges", "bytes")
        self.end_headers()
        if self.command == "HEAD":
            return
        with open(target, "rb") as stream:
            stream.seek(start)
            left = end - start + 1
            while left:
                chunk = stream.read(min(1 << 20 if not slow else SLOW_RATE // 4, left))
                if not chunk:
                    break
                try:
                    self.wfile.write(chunk)
                except OSError:
                    return
                left -= len(chunk)
                if slow:
                    time.sleep(0.25)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=("serve", "make-huge", "generate"))
    parser.add_argument("value", nargs="?", type=int)
    parser.add_argument("--port", type=int, default=8080)
    args = parser.parse_args(argv)
    generate()
    if args.command == "make-huge":
        make_huge(args.value)
        return 0
    if args.command == "generate":
        return 0
    print("fixture site ready", flush=True)
    http.server.ThreadingHTTPServer(("0.0.0.0", args.port), Handler).serve_forever()


if __name__ == "__main__":
    sys.exit(main())
