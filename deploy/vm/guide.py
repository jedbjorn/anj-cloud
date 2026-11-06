"""Plain-language pieces of anj-cloud-setup's guided flow (spec #21; bootstrap UX audit M1-M9).

The copy blocks (what a secret is, why it matters, where to keep it, what happens if it is lost),
the terminal QR code, the progress heartbeat, the SSH lockout guard's source address, the ntfy
test alert, the read-only Cloudflare check and the VM host secret hand-off (decision #109) live here,
so bootstrap.py keeps the steps. Nothing here writes a secret to a file, an argument or a log:
QR codes go through qrencode's stdin, and secrets are only ever shown on the terminal.
"""

import datetime
import json
import os
from pathlib import Path
import re
import socket
import stat
import subprocess
import threading
import time
import urllib.error
import urllib.request

HEARTBEAT_SECONDS = 30
HALO_GATEWAY = "10.77.10.1"       # anj-prod's default gateway: setup is running inside the VM host's VM
HALO_ALERT = "/usr/local/lib/anj-cloud-host/anj-alert"
TOKEN = re.compile(r"[A-Za-z0-9_-]{20,200}")
TOPIC = re.compile(r"[A-Za-z0-9_-]{24,64}")
# The remote end of `stage.py --with-secrets`: sshd creates it as the login user (anj) with
# StreamLocalBindMask 0177 (0600); the name carries 64 random bits so it never collides.
STAGED_SOCKET = re.compile(r"/home/[a-z_][a-z0-9_-]{0,31}/\.anj-cloud-setup-[0-9a-f]{16}\.sock")
STAGED_MAX = 8192
# Cloudflare API error codes (errors[].code) that name the cause; anything else is reported as
# "the token or the zone ID". 7000/7003: no route or invalid zone identifier; 6003/6111/1000/
# 9106/9109/10000: missing, malformed, invalid or unauthorised token.
ZONE_ERRORS = {7000, 7003}
TOKEN_ERRORS = {1000, 6003, 6111, 9106, 9109, 10000}


# Formatting ------------------------------------------------------------------------------------

def group(value, size=4, separator="-"):
    """ABCD-EFGH-…: the gateway accepts the code with or without separators (normalize_code)."""
    return separator.join(value[i:i + size] for i in range(0, len(value), size))


def duration(seconds):
    seconds = int(max(0, seconds))
    return f"{seconds // 60}m{seconds % 60:02d}s" if seconds >= 60 else f"{seconds}s"


def clock(epoch):
    """Local wall-clock time of an epoch (the machine's time zone, re-read: setup may have set it)."""
    time.tzset()
    return datetime.datetime.fromtimestamp(float(epoch)).astimezone().strftime("%H:%M %Z").strip()


def short(value):
    """First 4 and last 4 characters, for telling two topics apart on the screen."""
    return f"{value[:4]}…{value[-4:]}" if len(value) > 8 else "…"


# Secret notes (M8: what it is, why it matters, where to keep it, what happens if it is lost) -----

def token_note(token_path):
    return ("What it is: the key that lets this server update your DNS record. Create it in Cloudflare:\n"
            "  My Profile → API Tokens → Create Token → \"Edit zone DNS\" → limit it to your domain.\n"
            f"Where it lives: only on this server ({token_path}); only the setup account can read it.\n"
            "Save it in your password manager? Optional — if lost, create a new token in Cloudflare\n"
            "  and run setup again; nothing else depends on it.")


def topic_note(topic_path):
    return ("What it is: a private channel name on ntfy.sh. Anyone who knows it can read your server's alerts\n"
            "            and send fake ones, so treat it like a password.\n"
            "Where to keep it: your password manager, as \"anj-cloud ntfy topic\".\n"
            "If lost:    alerts still reach phones already subscribed; to subscribe a new phone, read it back\n"
            f"            with `sudo cat {topic_path}` on this server.")


def topic_entry_note(topic_path, halo=False):
    where = " (on the VM host also in /etc/anj-cloud-host/ntfy-topic,\nroot-only)" if halo else ""
    return ("Type the topic your phone already follows (24-64 letters, digits, '-' or '_'). It is in your\n"
            f"password manager as \"anj-cloud ntfy topic\"{where}. Typed twice: a typo here would silently send\n"
            "alerts where no phone listens.\n" + topic_note(topic_path))


def code_note(uid, expires_at, command):
    return (f"What it is: a one-time code that lets ONE device join as {uid}. Valid until {expires_at} (10 minutes),\n"
            "            one use only.\n"
            f"Why it matters: until it is used, anyone holding it can pair a device as {uid}. Every new device\n"
            "            sends one alert to your phone; revoke one you do not expect in the app's Admin section.\n"
            "Where to keep it: nowhere — type or paste it into the app now; do NOT save it.\n"
            f"If lost or expired: {command} pair --new-code (the old code stops working).")


# Terminal QR code (S1) -----------------------------------------------------------------------------

def qr_text(value, runner=None):
    """qrencode's ANSI/UTF-8 rendering of `value`, or None without qrencode. The value goes in on
    stdin, never as an argument; the result is meant for the terminal only."""
    try:
        result = (runner or subprocess.run)(["qrencode", "-t", "ANSIUTF8", "-m", "2"], input=value.encode(), capture_output=True,
                        timeout=30, check=False)
    except (OSError, subprocess.SubprocessError):
        return None
    if result.returncode != 0 or not result.stdout:
        return None
    return result.stdout.decode("utf-8", "replace")


def ntfy_link(server, topic):
    """The deep link the Android ntfy app subscribes from (ntfy docs: only ntfy:// links do)."""
    host = (server or "https://ntfy.sh").split("://", 1)[1].rstrip("/")
    return f"ntfy://{host}/{topic}?display=anj-cloud"


# Progress (M9) --------------------------------------------------------------------------------------

class Heartbeat:
    """Prints "still working … 1m30s" every `interval` seconds while a step runs, so a long apt run
    or a health wait never looks hung."""

    def __init__(self, say, indent="        ", interval=None, clock=time.monotonic):
        self.say, self.indent, self.clock = say, indent, clock
        self.interval = HEARTBEAT_SECONDS if interval is None else interval
        self.stop = threading.Event()
        self.thread = None
        self.started = None

    def __enter__(self):
        self.started = self.clock()
        self.thread = threading.Thread(target=self.beat, daemon=True)
        self.thread.start()
        return self

    def beat(self):
        while not self.stop.wait(self.interval):
            self.say(f"{self.indent}still working … {duration(self.clock() - self.started)}")

    def elapsed(self):
        return self.clock() - self.started

    def __exit__(self, *exc):
        self.stop.set()
        self.thread.join(timeout=5)
        return False


PLAIN_ERRORS = (
    ("TimeoutExpired", "a command took too long and was stopped"),
    ("CalledProcessError", "a command it ran failed"),
    ("FileNotFoundError", "a file or program it needs is missing"),
    ("PermissionError", "it was not allowed to read or change a file"),
    ("JSONDecodeError", "a program answered with output setup could not read"),
    ("UnicodeDecodeError", "a program answered with output setup could not read"),
    ("ConnectionError", "a network connection failed"),
    ("OSError", "a system operation failed (disk, file or device)"),
    ("SubprocessError", "a command it ran failed"),
    ("ValueError", "a program answered with output setup could not read"),
    ("KeyError", "setup met a state it did not expect (please report it with the details file)"),
    ("TypeError", "setup met a state it did not expect (please report it with the details file)"),
)


def plain_error(error):
    """A household-readable cause for an unexpected exception (never its message, which could
    carry a value): the first matching class in its method resolution order."""
    names = [klass.__name__ for klass in type(error).__mro__]
    for name, text in PLAIN_ERRORS:
        if name in names:
            return text
    return "something unexpected happened"


# SSH lockout guard (M4) -----------------------------------------------------------------------------

def ssh_client_info(environ=None, proc=Path("/proc"), pid=None):
    """(address, live) of the SSH session this command runs in. The address is $SSH_CONNECTION's
    client, from this process or (sudo resets the environment) the nearest ancestor that has it;
    `live` is True when an sshd process is an ancestor of that one, so the address belongs to a
    connection that is open now. Inside tmux or screen started from an earlier session it may be
    stale (live False). (None, False) on a local console or when unreadable."""
    environ = os.environ if environ is None else environ
    current = os.getpid() if pid is None else pid
    value = environ.get("SSH_CONNECTION")
    found = value is not None
    live = False
    for _ in range(32):
        if not current or current <= 1:
            break
        try:
            comm = (proc / str(current) / "comm").read_text().strip() if (proc / str(current) / "comm").exists() else ""
            if found and comm.startswith("sshd"):
                live = True
                break
            if not found:
                raw = (proc / str(current) / "environ").read_bytes()
                value = next((item.split(b"=", 1)[1].decode("ascii", "replace") for item in raw.split(b"\0")
                              if item.startswith(b"SSH_CONNECTION=")), None)
                found = value is not None
            fields = (proc / str(current) / "stat").read_text().rsplit(")", 1)[1].split()
            current = int(fields[1])
        except (OSError, ValueError, IndexError):
            break
    parts = (value or "").split()
    return (parts[0], live) if len(parts) == 4 else (None, False)


def ssh_client_address(environ=None, proc=Path("/proc"), pid=None):
    return ssh_client_info(environ, proc, pid)[0]


def no_share_text(halo, command):
    """The backup drive is missing: what to do, in the VM host's words only on the VM host."""
    attach = "Attach it (VM host: DOS_BACKUP) and restart the VM" if halo else "Attach the backup drive and restart"
    return (f"The backup drive is not attached to this server, so backups cannot run yet. {attach}, then: "
            f"sudo {command} backup.")


def ipv4_for(address):
    """An address the firewall's IPv4 rule can use: the address itself, or the IPv4 inside an
    IPv4-mapped IPv6 address (::ffff:a.b.c.d); None for a real IPv6 address."""
    import ipaddress
    try:
        parsed = ipaddress.ip_address(address)
    except ValueError:
        return None
    if parsed.version == 4:
        return str(parsed)
    return str(parsed.ipv4_mapped) if parsed.ipv4_mapped else None


# ntfy test alert (M1) ------------------------------------------------------------------------------

class NoRedirect(urllib.request.HTTPRedirectHandler):
    """A redirect would carry the topic (in the URL) to another host: never follow one."""

    def redirect_request(self, request, fp, code, msg, headers, newurl):
        raise urllib.error.HTTPError(request.full_url, code, "redirect refused", headers, fp)


def send_test_alert(server, topic, opener=None, timeout=15):
    """POST one test message to <server>/<topic>. Returns (sent, plain detail); the detail never
    holds the topic."""
    url = (server or "https://ntfy.sh").rstrip("/") + "/" + topic
    request = urllib.request.Request(url, data="anj-cloud setup: test alert — alerts work.".encode(), method="POST",
                                     headers={"Title": "anj-cloud setup: test alert", "Tags": "white_check_mark",
                                              "Content-Type": "text/plain; charset=utf-8"})
    try:
        with (opener or urllib.request.build_opener(NoRedirect)).open(request, timeout=timeout) as response:
            return 200 <= response.status < 300, f"HTTP {response.status}"
    except urllib.error.HTTPError as error:
        with error:
            return False, f"the ntfy server answered HTTP {error.code}"
    except (urllib.error.URLError, OSError, ValueError):
        return False, "the ntfy server could not be reached (network)"


# Cloudflare read-only check (M5) --------------------------------------------------------------------

def cloudflare_check(token, zone_id, host, http=None):
    """One read-only GET of the A record (spec #23's ddns.Cloudflare.record), proving the token,
    the zone ID and the hostname together. Returns (ok, plain message); nothing is changed and no
    message names the token."""
    from deploy import ddns
    try:
        record = ddns.Cloudflare(http or ddns.Http(), token, zone_id).record(host)
    except ddns.Failure as failure:
        text = ddns.redact(failure, token)
        status = re.search(r"HTTP (\d{3})", text)
        if failure.category == "network":
            return False, "Cloudflare could not be reached (network). Check this machine's internet connection."
        if failure.category == "dns-record":
            return False, (f"Cloudflare has no single A record named {host} in this zone. Create exactly one A record "
                           f"for {host} (DNS only, any address) in Cloudflare; DDNS keeps it up to date.")
        code = status.group(1) if status else None
        listed = re.search(r"errors \[([^\]]*)\]", text)
        errors = {int(number) for number in re.findall(r"\d+", listed.group(1))} if listed else set()
        if errors & ZONE_ERRORS:
            return False, (f"Cloudflare does not know the zone ID {short(zone_id)} (HTTP {code}). Copy it again from "
                           "the domain's Overview page.")
        if errors & TOKEN_ERRORS or code in ("401", "403"):
            return False, (f"Cloudflare refused the token (HTTP {code}). Check it has \"Zone → DNS → Edit\" for this "
                           "domain, and that the zone ID is that domain's.")
        if code:
            return False, (f"Cloudflare did not accept the token or the zone ID (HTTP {code}). Check both: the token "
                           "needs \"Zone → DNS → Edit\" for this domain, and the zone ID is on its Overview page.")
        return False, f"Cloudflare answered unexpectedly ({text[:120]})."
    proxied = record.get("proxied")
    return True, (f"token works, zone found, record {host} found (A, " +
                  ("not proxied)." if proxied is False else
                   "PROXIED — turn the orange cloud off in Cloudflare: devices need DNS only)."))


# The VM host secret hand-off (decision #109) --------------------------------------------------------------

def read_staged(path, expected_owner=None, connect=None, seen=None):
    """The secrets `stage.py --with-secrets` serves over the forwarded socket: {"token", "topic"},
    each optional, validated. Read once into memory; the socket is removed afterwards. Raises
    ValueError with a plain reason (never a value)."""
    path = str(path)
    if not STAGED_SOCKET.fullmatch(path):
        raise ValueError("the secrets socket path is not one stage.py makes")
    info = os.lstat(path)
    if not stat.S_ISSOCK(info.st_mode) or (expected_owner is not None and info.st_uid != expected_owner):
        raise ValueError("the secrets socket is not a socket of the login user")
    if info.st_mode & 0o077:      # sshd's StreamLocalBindMask (default 0177) makes it owner-only
        raise ValueError("the secrets socket is open to other users (check sshd's StreamLocalBindMask)")
    if seen is not None:
        seen["mode"] = oct(stat.S_IMODE(info.st_mode))
    chunks = []
    with (connect or _connect)(path) as stream:
        while sum(len(chunk) for chunk in chunks) <= STAGED_MAX:
            chunk = stream.recv(4096)
            if not chunk:
                break
            chunks.append(chunk)
    try:
        os.unlink(path)
    except OSError:
        pass
    raw = b"".join(chunks)
    if len(raw) > STAGED_MAX:
        raise ValueError("the secrets hand-off is too large")
    try:
        payload = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        raise ValueError("the secrets hand-off is not readable") from None
    if not isinstance(payload, dict) or set(payload) - {"token", "topic"}:
        raise ValueError("the secrets hand-off has an unexpected shape")
    result = {}
    if payload.get("token") is not None:
        if not isinstance(payload["token"], str) or not TOKEN.fullmatch(payload["token"]):
            raise ValueError("the Cloudflare token copied from the VM host does not look like a token")
        result["token"] = payload["token"]
    if payload.get("topic") is not None:
        if not isinstance(payload["topic"], str) or not TOPIC.fullmatch(payload["topic"]):
            raise ValueError("the ntfy topic copied from the VM host is not 24-64 letters, digits, '-' or '_'")
        result["topic"] = payload["topic"]
    return result


def _connect(path):
    stream = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    stream.settimeout(30)
    stream.connect(path)
    return stream
