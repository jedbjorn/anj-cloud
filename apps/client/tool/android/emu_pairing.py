#!/usr/bin/env python3
"""Spec #28 A3 emulator proof (acceptance rows 7 and 8), run by anj-emu-run as its payload:

  ANJ_APK=<debug apk> OUT=<evidence dir> QR=<png the emulator camera shows> \\
  ANJ_EMU_ARGS="-camera-back imagefile:$QR" \\
  anj-emu-run a3 <n> python3 tool/android/emu_pairing.py --repo <checkout> --project anj-cloud-review-<tag> --port <p>

The stack's console backend must run (deploy/README.md, spec #27: deploy.vm.console_backend on
deploy/.local/<project>/console/backend.sock): the gateway approves a pinned code through it.

Drives the real QA app through uiautomator against a review stack reached with adb reverse,
with code-only pairing (spec #35, decision #151): the household server prefilled and replaced
by the stack's origin, a code pinned to another CA (refused: "not for this server", nothing
stored), CAMERA declined then allowed on Scan, a non-code QR refused and the pairing code
scanned live through the emulator's image-file camera, automatic approval with no CA file,
fingerprint or Check approval, then the first-sync folder screen: nothing downloads before
confirming, the screen returns after the app is killed, only the ticked folder and the root
files download, and a folder created later on the server downloads (#29).

The pairing code never enters the evidence: it lives in memory and in the QR file, which this
script deletes. Every step writes a screenshot and the UI tree to OUT.
"""
import argparse
import json
import os
import pwd
from pathlib import Path
import re
import subprocess
import sys
import time
import traceback
import xml.etree.ElementTree as ET

PKG = "cloud.anj.anj_cloud.qa"
UID = "anj-fixture-alice"
ADB = os.environ["ADB"]
OUT = Path(os.environ["OUT"])
QR = Path(os.environ["QR"])
STEPS = []
# The stack's backend fixture helper needs a Content-Type on bodies (PHP warns otherwise).
OCTETS = {"Content-Type": "application/octet-stream"}


def adb(*args, check=True, data=None, timeout=60):
    result = subprocess.run([ADB, *args], input=data, capture_output=True, timeout=timeout)
    if check and result.returncode:
        raise RuntimeError(f"adb {args[0]} failed: {result.stderr.decode(errors='replace')[:300]}")
    return result.stdout.decode(errors="replace")


def step(name, ok=True, **facts):
    STEPS.append({"step": name, "ok": ok, **facts})
    print(("PASS " if ok else "FAIL ") + name + (f" {facts}" if facts else ""), flush=True)
    shot = OUT / f"{len(STEPS):02d}-{re.sub('[^a-z0-9]+', '-', name.lower())[:40]}.png"
    shot.write_bytes(subprocess.run([ADB, "exec-out", "screencap", "-p"], capture_output=True).stdout)
    if not ok:
        raise SystemExit(f"step failed: {name}")


def nodes():
    raw = adb("exec-out", "uiautomator", "dump", "/dev/tty", check=False)
    raw = raw[raw.find("<?xml"):raw.rfind(">") + 1] if "<?xml" in raw else ""
    if not raw:
        return []
    found = []
    for node in ET.fromstring(raw).iter("node"):
        a = node.attrib
        bounds = [int(v) for v in re.findall(r"\d+", a.get("bounds", ""))]
        found.append({"text": a.get("text", ""), "desc": a.get("content-desc", ""),
                      "hint": a.get("hint", ""), "class": a.get("class", ""), "pkg": a.get("package", ""),
                      "checked": a.get("checked") == "true", "enabled": a.get("enabled") == "true",
                      "bounds": bounds})
    return found


def label(n):
    return " ".join(v for v in (n["text"], n["desc"], n["hint"]) if v)


def find(pattern, timeout=20, cls=None):
    deadline = time.time() + timeout
    regex = re.compile(pattern, re.S | re.I)
    while time.time() < deadline:
        for n in nodes():
            if regex.search(label(n)) and (cls is None or cls in n["class"]) and len(n["bounds"]) == 4:
                return n
        time.sleep(1)
    return None


def scroll_find(pattern, cls=None):
    """Find an element on a scrolled page: look, then swipe down the page, then back up."""
    for swipe in [None] + ["up"] * 3 + ["down"] * 6:
        if swipe == "up":
            adb("shell", "input", "swipe", "540", "1700", "540", "900", "300")
        elif swipe == "down":
            adb("shell", "input", "swipe", "540", "900", "540", "1700", "300")
        n = find(pattern, 3, cls)
        if n is not None:
            return n
    return None


def hide_keyboard():
    if "mInputShown=true" in adb("shell", "dumpsys", "input_method", check=False):
        adb("shell", "input", "keyevent", "KEYCODE_BACK")
        time.sleep(1)


def tap(pattern, timeout=20, cls=None, scroll=False):
    n = find(pattern, timeout, cls)
    if n is None and scroll:
        hide_keyboard()
        n = scroll_find(pattern, cls)
    if n is None:
        raise RuntimeError(f"no element matching {pattern!r}")
    x1, y1, x2, y2 = n["bounds"]
    adb("shell", "input", "tap", str((x1 + x2) // 2), str((y1 + y2) // 2))
    time.sleep(1.5)
    return n


def screen_text():
    return "\n".join(label(n) for n in nodes())


def type_text(text):
    adb("shell", "input", "text", text.replace(" ", "%s"))
    time.sleep(1)


def run_as(*command):
    return adb("shell", "run-as", PKG, *command, check=False)


def local_files():
    out = run_as("find", "files/anj-cloud", "-type", "f")
    return sorted(line.strip()[len("files/anj-cloud/"):] for line in out.splitlines() if line.startswith("files/anj-cloud/"))


def camera_granted():
    dump = adb("shell", "dumpsys", "package", PKG)
    match = re.search(r"android\.permission\.CAMERA: granted=(true|false)", dump)
    return match.group(1) == "true" if match else False


def write_qr(text):
    # A wide quiet zone: the emulator's image-file camera scales the picture up and crops it.
    temporary = QR.with_suffix(".tmp.png")
    subprocess.run(["qrencode", "-o", str(temporary), "-s", "8", "-m", "36"], input=text.encode(), check=True)
    os.chmod(temporary, 0o600)
    temporary.replace(QR)


ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"


def other_ca_code(code):
    """The same pinned code with one CA-pin bit flipped: a code for another household."""
    code = code.replace("-", "").replace(" ", "").upper()
    number = 0
    for char in code:
        number = number * 32 + ALPHABET.index(char)
    number ^= 1  # the last byte of the 10-byte CA pin (decision #153)
    chars = []
    for _ in range(len(code)):
        chars.append(ALPHABET[number % 32])
        number //= 32
    return "".join(reversed(chars))


def replace_text(pattern, text):
    tap(pattern, cls="EditText", scroll=True)
    adb("shell", "input", "keyevent", "KEYCODE_MOVE_END")
    for _ in range(60):
        adb("shell", "input", "keyevent", "KEYCODE_DEL")
    type_text(text)
    hide_keyboard()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True)
    parser.add_argument("--project", required=True)
    parser.add_argument("--port", type=int, required=True)
    args = parser.parse_args()
    repo = Path(args.repo)
    sys.path.insert(0, str(repo))
    from deploy.dev import Stack  # the review stack's own fixture helpers
    # anj-emu-run points HOME at the Android toolchain; host tools (the rootless Docker
    # context, the operator CLI) need the user's own.
    host = {**os.environ, "HOME": pwd.getpwuid(os.getuid()).pw_dir}
    stack = Stack(args.project, args.port)
    stack.environment["HOME"] = host["HOME"]
    python = str(repo / "deploy/.local/access-venv/bin/python")
    operator = [python, "-m", "deploy.access_operator", "--project", args.project, "--port", str(args.port)]
    OUT.mkdir(parents=True, exist_ok=True)

    # Account data on R: two top-level folders and a root file.
    for folder in ("anj-cloud", "anj-cloud/Music", "anj-cloud/Photos"):
        stack.dav("MKCOL", UID, folder, expected=(201, 405))
    stack.dav("PUT", UID, "anj-cloud/Music/song.flac", data=b"m" * 300 * 1024, headers=OCTETS, expected=(201, 204))
    stack.dav("PUT", UID, "anj-cloud/Photos/beach.jpg", data=b"p" * 2 * 1024 * 1024, headers=OCTETS, expected=(201, 204))
    stack.dav("PUT", UID, "anj-cloud/notes.txt", data=b"notes", headers=OCTETS, expected=(201, 204))

    adb("reverse", f"tcp:{args.port}", f"tcp:{args.port}")
    adb("install", "-r", "-t", os.environ["ANJ_APK"], timeout=180)
    adb("shell", "pm", "revoke", PKG, "android.permission.CAMERA", check=False)
    adb("logcat", "-c")
    adb("shell", "am", "start", "-W", "-n", f"{PKG}/cloud.anj.anj_cloud.MainActivity")

    tap(r"^Pair device", timeout=60)
    server = find("Server", cls="EditText")
    no_ca = find(r"CA file|fingerprint", timeout=2)
    step("pairing page: household server prefilled, code field, no CA file or fingerprint",
         server is not None and server["text"].startswith("https://") and no_ca is None
         and find("Pairing code", cls="EditText") is not None and find(r"Check approval", timeout=2) is None,
         prefilled=server["text"] if server else None, camera_granted=camera_granted())
    replace_text("Server", f"https://127.0.0.1:{args.port}")

    invite = json.loads(subprocess.run([*operator, "invite", UID, "--rights", "write"], capture_output=True,
                                       text=True, check=True, cwd=repo, env=host).stdout)
    code = invite["code"].replace("-", "")
    step("the stack issued a pinned code", len(code) == 28, length=len(code))

    # A code for another household's CA: refused before any trust is stored.
    replace_text("Pairing code", other_ca_code(code))
    tap(r"^Pair$", scroll=True)
    refused = find(r"not for this server", timeout=40)
    step("a code pinned to another CA is refused", refused is not None
         and scroll_find("Status: unpaired") is not None and "household-ca.crt" not in run_as("ls", "files/anj-profile/default"))

    # Scan: CAMERA ungranted until the tap; declined first, typed entry stays.
    before = camera_granted()
    tap(r"Scan QR code", scroll=True)
    deny = find(r"^Don.t allow", timeout=20)
    step("CAMERA requested only on Scan", not before and deny is not None and deny["pkg"].endswith("permissioncontroller"))
    tap(r"^Don.t allow")
    declined = find(r"Camera permission was declined", timeout=20)
    step("declined camera keeps typed entry", declined is not None and not camera_granted())
    tap(r"Back to pairing")
    step("back on the form after declining", find("Pairing code", cls="EditText") is not None)

    # Allowed: a QR that is not a pairing code is refused, then the code is read live.
    write_qr("https://example.invalid/not-a-pairing-code")
    tap(r"Scan QR code", scroll=True)
    tap(r"While using the app", timeout=20)
    preview = find(r"Point the camera at the QR code", timeout=20)
    notice = find(r"not an AnJ Cloud pairing code", timeout=60)
    # The camera opening after the grant is required; decoding the emulator's image-file
    # camera is recorded, not required (#121: live decoding is Pixel acceptance).
    step("camera opens after the grant (preview streaming)", preview is not None and camera_granted(),
         non_code_refused_live=notice is not None)
    write_qr(invite["code"])
    left = None
    deadline = time.time() + (90 if notice is not None else 20)
    while time.time() < deadline:
        if find(r"Scan pairing code", timeout=2) is None:
            left = True
            break
        time.sleep(2)
    live = bool(left) and find(r"^Pair$", timeout=10) is not None
    if not live:
        if find(r"Scan pairing code", timeout=2) is not None:
            adb("shell", "input", "keyevent", "KEYCODE_BACK")
        replace_text("Pairing code", code)
    else:
        field = find("Pairing code", cls="EditText")
        live = field is not None and field["text"].replace("-", "") == code
    step("live camera scan read the pairing code" if live else "live scan did not return; typed entry used",
         ok=True, live=live)

    # Automatic approval: no fingerprint, no operator step, no Check approval.
    tap(r"^Pair$", scroll=True)
    screen = find(r"Choose what stays on this device", timeout=60)
    text = screen_text()
    devices = json.loads(subprocess.run([*operator, "devices"], capture_output=True, text=True, check=True,
                                        cwd=repo, env=host).stdout)
    device_label = next((d.get("device_label") for d in devices if d.get("uid") == UID), None)
    step("first-sync screen after automatic approval with sizes and total", screen is not None and "Music" in text
         and "300 KiB" in text and "2.0 MiB" in text and "Total in the cloud" in text,
         listed=[line for line in text.splitlines() if re.search(r"KiB|MiB|bytes|Total|Downloads", line)])
    step("nothing downloaded before confirming", local_files() == [], files=local_files())

    # Killed before confirming: the screen returns and still nothing downloaded.
    adb("shell", "am", "force-stop", PKG)
    time.sleep(2)
    adb("shell", "am", "start", "-W", "-n", f"{PKG}/cloud.anj.anj_cloud.MainActivity")
    again = find(r"Choose what stays on this device", timeout=60)
    time.sleep(5)
    step("screen returns after the app is killed; nothing downloaded", again is not None and local_files() == [],
         files=local_files())

    tap(r"New and loose files in Music", scroll=True)  # the row label since #97 (decision #163)
    tap(r"^Start sync", scroll=True)
    deadline = time.time() + 120
    while time.time() < deadline and not {"Music/song.flac", "notes.txt"} <= set(local_files()):
        time.sleep(3)
    files = local_files()
    step("only the ticked folder and root files downloaded", {"Music/song.flac", "notes.txt"} <= set(files)
         and not any(f.startswith("Photos/") for f in files), files=files)

    stack.dav("MKCOL", UID, "anj-cloud/Later", expected=(201,))
    stack.dav("PUT", UID, "anj-cloud/Later/new.txt", data=b"later", headers=OCTETS, expected=(201, 204))
    adb("shell", "input", "keyevent", "KEYCODE_HOME")
    adb("shell", "am", "start", "-W", "-n", f"{PKG}/cloud.anj.anj_cloud.MainActivity")
    deadline = time.time() + 120
    while time.time() < deadline and "Later/new.txt" not in local_files():
        time.sleep(3)
    files = local_files()
    step("a folder created later on the server downloads (#29)", "Later/new.txt" in files
         and not any(f.startswith("Photos/") for f in files), files=files)

    log = adb("logcat", "-d", check=False)
    step("no pairing code, CA or key material in logcat", code not in log and invite["code"] not in log
         and "BEGIN CERTIFICATE" not in log
         and "PRIVATE KEY" not in log)
    # PR #60 review F5: the secure-storage plugin cannot unwrap its key at start-up (its
    # wrapped key is overwritten), so every call fails. The app offers the reset, which
    # wipes the store natively, restarts and leaves the device ready to pair again.
    prefs = run_as("ls", "shared_prefs")
    key_file = next((n for n in prefs.split() if n.startswith("FlutterSecureKeyStorage")), None)
    if key_file:
        xml = run_as("cat", f"shared_prefs/{key_file}")
        broken = re.sub(r'(<string name="[^"]*">)[^<]*(</string>)', r"\1AAAA\2", xml)
        adb("shell", f"run-as {PKG} sh -c 'cat > shared_prefs/{key_file}'", data=broken.encode())
    adb("shell", "am", "force-stop", PKG)
    adb("shell", "am", "start", "-W", "-n", f"{PKG}/cloud.anj.anj_cloud.MainActivity")
    notice = find(r"This device.s key is unavailable", timeout=60)
    step("unreadable key: the reset is offered", key_file is not None and notice is not None, prefs=prefs.split())
    tap(r"Reset this device.s pairing$")
    tap(r"^Reset pairing$", timeout=10)
    time.sleep(8)
    back = find(r"Pair device", timeout=60)
    gone = find(r"This device.s key is unavailable", timeout=3)
    files = local_files()
    step("reset wiped the store natively and the app restarted ready to pair",
         back is not None and gone is None and "Music/song.flac" in files,
         prefs=run_as("ls", "shared_prefs").split(), files_kept="Music/song.flac" in files)
    step("device label is the Android device name", bool(device_label) and device_label != "localhost",
         label=device_label)


if __name__ == "__main__":
    status = 1
    try:
        main()
        status = 0
    except SystemExit as error:
        print(error, flush=True)
    except Exception as error:  # evidence first, then the failure
        STEPS.append({"step": "driver error", "ok": False, "error": f"{type(error).__name__}: {error}"[:400]})
        print(f"ERROR {type(error).__name__}: {error}", flush=True)
        traceback.print_exc()
    finally:
        if status:
            # Crash and Flutter error lines only (never the whole log).
            log = adb("logcat", "-d", "-v", "brief", check=False)
            keep = [line for line in log.splitlines()
                    if re.search(r"FATAL|AndroidRuntime|E/flutter|Exception|CameraX|camerax", line)]
            (OUT / "errors.txt").write_text("\n".join(keep[-200:]) + "\n")
        try:
            QR.unlink()
        except FileNotFoundError:
            pass
        adb("uninstall", PKG, check=False)
        (OUT / "steps.json").write_text(json.dumps(STEPS, indent=2) + "\n")
    sys.exit(status)
