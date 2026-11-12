"""The Downloader's presets and the checks around them (spec #42 Presets, decision #179).

One table: a later preset is a new row. Every rule copies streams, never re-encodes: a source
without a fitting stream is rejected, not converted. Standard library only, so the gateway's test
suite can exercise it without the worker image.
"""

import ipaddress
import json
import re
import socket
from urllib.parse import urlsplit

GIB = 1024 ** 3
MAX_BYTES = 8 * GIB          # decision #180
MAX_SECONDS = 4 * 3600       # decision #180
H264 = "~='^(avc|h264)'"
AAC = "~='^(mp4a|aac)'"

# kind -> extension, yt-dlp format selector (height filled in), post-processing arguments.
PRESETS = {
    # The source's AAC stream, copied: an audio-only AAC format, else the AAC track of an H.264+AAC
    # file (extracted by copy). Title/artist tags and the cover embedded.
    "audio": {"ext": "m4a",
              "format": "bestaudio[acodec%s][vcodec=none]/best[acodec%s][vcodec%s]" % (AAC, AAC, H264),
              "args": ["-x", "--audio-format", "m4a", "--embed-metadata", "--embed-thumbnail", "--convert-thumbnails", "png"]},
    # The best H.264 stream at or below the height plus AAC audio, merged without re-encoding; else
    # one file already holding both.
    "video": {"ext": "mp4",
              "format": "bestvideo[vcodec%s][height<={height}]+bestaudio[acodec%s]/best[vcodec%s][acodec%s][height<={height}]"
                        % (H264, AAC, H264, AAC),
              "args": ["--merge-output-format", "mp4", "--remux-video", "mp4"]},
}


def selector(kind, height=None):
    return PRESETS[kind]["format"].replace("{height}", str(int(height or 0)))


def estimated_bytes(info):
    """Expected size from the site's metadata (filesize, filesize_approx, else bitrate x duration);
    None when the site gives nothing to go on."""
    formats = info.get("requested_formats") or [info]
    total, known = 0, False
    for item in formats:
        size = item.get("filesize") or item.get("filesize_approx")
        if not size and item.get("tbr") and info.get("duration"):
            size = float(item["tbr"]) * 1000 / 8 * float(info["duration"])
        if size:
            total += int(size)
            known = True
    if not known:
        size = info.get("filesize") or info.get("filesize_approx")
        return int(size) if size else None
    return total


def limits(info):
    """The rejection code for an item whose metadata breaks a limit, else None."""
    if info.get("is_live") or info.get("live_status") in ("is_live", "is_upcoming"):
        return "live"
    duration = info.get("duration")
    if isinstance(duration, (int, float)) and duration > MAX_SECONDS:
        return "too-long"
    size = estimated_bytes(info)
    if size is not None and size > MAX_BYTES:
        return "too-large"
    return None


def verdict(probe, kind, height=None):
    """(ok, obtained height) from `ffprobe -show_format -show_streams -of json` of a staged file:
    the container, codecs and height the preset promises, and nothing else."""
    try:
        data = json.loads(probe)
        name = data["format"]["format_name"]
        streams = data["streams"]
    except (ValueError, KeyError, TypeError):
        return False, None
    if "mp4" not in str(name).split(","):
        return False, None
    audio = [s for s in streams if s.get("codec_type") == "audio"]
    pictures = [s for s in streams if s.get("codec_type") == "video" and (s.get("disposition") or {}).get("attached_pic") == 1]
    video = [s for s in streams if s.get("codec_type") == "video" and s not in pictures]
    other = [s for s in streams if s.get("codec_type") not in ("audio", "video", "data")]
    if other or len(audio) != 1 or audio[0].get("codec_name") != "aac":
        return False, None
    if kind == "audio":
        return (not video), None
    if len(video) != 1 or video[0].get("codec_name") != "h264" or not isinstance(video[0].get("height"), int):
        return False, None
    obtained = video[0]["height"]
    return obtained <= int(height), obtained


# yt-dlp's error lines, mapped to a fixed code; the text itself never leaves the worker.
ERRORS = (
    ("unsupported-format", r"requested format is not available|no video formats found"),
    ("live", r"live event|is live|premieres in|this live"),
    ("login-required", r"sign in|log ?in|login required|cookies|members[- ]only|join this channel|requires payment|purchase|subscriber|age[- ]restricted|confirm your age"),
    ("geo-blocked", r"available in your (country|region)|geo[- ]?restrict|from your location"),
    ("unavailable", r"video unavailable|is not available|has been removed|private video|does not exist|http error 404|no longer available|been terminated"),
    ("unsupported-link", r"unsupported url|is not a valid url"),
    ("network", r"unable to download webpage|getaddrinfo|name or service not known|temporary failure in name resolution|timed out|connection refused|network is unreachable|operation not permitted|connection reset|ssl"),
    ("site-error", r"http error (403|429|5\d\d)|forbidden|too many requests"),
)
EXTRACTOR = re.compile(r"unable to extract|extractor|please report this issue|unable to (download|parse) .*json|signature|nsig|player", re.I)


def classify(stderr):
    """(code, whether an updated yt-dlp might fix it) for a failed yt-dlp run."""
    lines = [line for line in stderr.splitlines() if line.startswith("ERROR:")] or stderr.splitlines()[-3:]
    text = " ".join(lines).lower()
    for code, pattern in ERRORS:
        if re.search(pattern, text):
            return code, False
    return "site-error", bool(EXTRACTOR.search(text))


def public_address(address):
    """False for loopback, private, link-local, carrier-grade NAT, multicast, reserved and any
    IPv6 form that carries such an IPv4 address."""
    try:
        ip = ipaddress.ip_address(address.split("%", 1)[0])
    except ValueError:
        return False
    if ip.version == 6:
        for embedded in (ip.ipv4_mapped, ip.sixtofour, (ip.teredo or (None, None))[1]):
            if embedded is not None and not public_address(str(embedded)):
                return False
        if ip in ipaddress.ip_network("64:ff9b::/96") and not public_address(str(ipaddress.ip_address(int(ip) & 0xFFFFFFFF))):
            return False
    return ip.is_global and not ip.is_multicast and not ip.is_reserved


def reach(url, allowed_host=None, resolve=socket.getaddrinfo):
    """None when the link may be fetched, else a rejection code. Only http(s); every address the
    host resolves to must be public (the test-only fixture host excepted)."""
    try:
        parts = urlsplit(url)
        host = parts.hostname
        parts.port  # noqa: B018 - raises on a malformed port
    except ValueError:
        return "unsupported-link"
    if parts.scheme.lower() not in ("http", "https") or not host:
        return "unsupported-link"
    if allowed_host and host.lower() == allowed_host.lower():
        return None
    try:
        addresses = {row[4][0] for row in resolve(host, parts.port or (443 if parts.scheme.lower() == "https" else 80),
                                                 proto=socket.IPPROTO_TCP)}
    except (OSError, UnicodeError):
        return "network"
    if not addresses or not all(public_address(address) for address in addresses):
        return "private-address"
    return None
