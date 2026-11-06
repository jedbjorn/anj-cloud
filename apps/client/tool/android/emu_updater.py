#!/usr/bin/env python3
"""Spec #28 A7 emulator proof (acceptance row 17, client half), run by anj-emu-run as its payload:

  APKS=<dir with v1 v2 v3-other v5 .apk> OUT=<evidence dir> \\
  anj-emu-run a7 <n> python3 tool/android/emu_updater.py --repo <checkout> \\
      --project anj-cloud-review-<tag> --port <p>

The stack's console backend must run (deploy.vm.console_backend on
deploy/.local/<project>/console/backend.sock): the gateway approves the pinned code through it.

v1, v2, v5: QA builds (cloud.anj.anj_cloud.qa, versionCode 1, 2, 5) signed with the debug key;
v3-other: versionCode 3 re-signed with a second test key. Drives the real QA app through
uiautomator against a review stack reached with adb reverse: install v1 and pair it by code
(spec #35: server and pinned code, automatic approval; the first-sync screen keeps Notes,
decision #163), publish v2 on R with the operator CLI, Check for
updates, Download and install, the "Install unknown apps" screen, decline Android's confirmation
(v1 stays), then approve it (v2 installs, still paired and syncing). Negatives on v2: a different
signer (v3-other), a lower real versionCode behind a higher manifest (v1's bytes announced as 4)
and a wrong SHA-256 (v5 published, then one byte of the stored package flipped on R). Each must be
discarded with a visible reason before any install session exists: no AnjUpdater session line in
logcat, the system installer never in front, versionCode still 2, the download directory empty.
Every step writes a screenshot to OUT.
"""
import argparse
import hashlib
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
TARGET = "android-arm64"
UID = "anj-fixture-alice"
ADB = os.environ["ADB"]
OUT = Path(os.environ["OUT"])
APKS = Path(os.environ["APKS"])
STEPS = []
OCTETS = {"Content-Type": "application/octet-stream"}
FILES = f"/data/user/0/{PKG}/files"


def adb(*args, check=True, data=None, timeout=120):
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
        found.append({"text": a.get("text", ""), "desc": a.get("content-desc", ""), "hint": a.get("hint", ""),
                      "class": a.get("class", ""), "pkg": a.get("package", ""), "res": a.get("resource-id", ""),
                      "checked": a.get("checked") == "true", "bounds": bounds})
    return found


def label(n):
    return " ".join(v for v in (n["text"], n["desc"], n["hint"]) if v)


def find(pattern, timeout=20, cls=None, pkg=None):
    deadline = time.time() + timeout
    regex = re.compile(pattern, re.S | re.I)
    while True:
        for n in nodes():
            if regex.search(label(n)) and (cls is None or cls in n["class"]) \
                    and (pkg is None or re.search(pkg, n["pkg"])) and len(n["bounds"]) == 4:
                return n
        if time.time() >= deadline:
            return None
        time.sleep(1)


def tap_node(n):
    x1, y1, x2, y2 = n["bounds"]
    adb("shell", "input", "tap", str((x1 + x2) // 2), str((y1 + y2) // 2))
    time.sleep(1.5)


def tap(pattern, timeout=20, cls=None, pkg=None):
    n = find(pattern, timeout, cls, pkg)
    if n is None:
        raise RuntimeError(f"no element matching {pattern!r}")
    tap_node(n)
    return n


def scroll_tap(pattern, tries=8):
    """Taps the first match, scrolling the page up between tries (long screens on a phone)."""
    for _ in range(tries):
        n = find(pattern, timeout=3)
        if n is not None:
            tap_node(n)
            return n
        adb("shell", "input", "swipe", "540", "1700", "540", "900", "300")
        time.sleep(1)
    raise RuntimeError(f"no element matching {pattern!r}")


def screen_text():
    return "\n".join(label(n) for n in nodes())


def type_text(text):
    adb("shell", "input", "text", text.replace(" ", "%s"))
    time.sleep(1)


def hide_keyboard():
    if "mInputShown=true" in adb("shell", "dumpsys", "input_method", check=False):
        adb("shell", "input", "keyevent", "KEYCODE_BACK")
        time.sleep(1)


def run_as(*command):
    return adb("shell", "run-as", PKG, *command, check=False)


def local_files():
    out = run_as("find", "files/anj-cloud", "-type", "f")
    return sorted(line.strip()[len("files/anj-cloud/"):] for line in out.splitlines()
                  if line.startswith("files/anj-cloud/"))


def update_downloads():
    return [line for line in run_as("ls", "-a", "cache/anj-updates").split() if line not in (".", "..")]


def version_code():
    dump = adb("shell", "dumpsys", "package", PKG, check=False)
    match = re.search(r"versionCode=(\d+)", dump)
    return int(match.group(1)) if match else None


def focused():
    dump = adb("shell", "dumpsys", "window", check=False)
    match = re.search(r"mCurrentFocus=Window\{[^}]*\}", dump)
    return match.group(0) if match else ""


def installer_in_front():
    return "packageinstaller" in focused()


def session_lines():
    return [line for line in adb("logcat", "-d", "-s", "AnjUpdater:I", check=False).splitlines()
            if "install session" in line]


def launch():
    adb("shell", "am", "start", "-W", "-n", f"{PKG}/cloud.anj.anj_cloud.MainActivity")


def check_for_updates():
    tap(r"AnJ Cloud menu|Show menu", timeout=45)
    tap(r"^Check for updates$")


def apk_facts(apk):
    data = apk.read_bytes()
    build_tools = sorted(Path(os.environ["ANDROID_HOME"], "build-tools").iterdir())[-1]
    certs = subprocess.run([str(build_tools / "apksigner"), "verify", "--print-certs", str(apk)],
                           capture_output=True, text=True, check=True).stdout
    signer = re.search(r"Signer #1 certificate SHA-256 digest: ([0-9a-f]{64})", certs).group(1)
    return {"size": len(data), "sha256": hashlib.sha256(data).hexdigest(), "signer_sha256": signer}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True)
    parser.add_argument("--project", required=True)
    parser.add_argument("--port", type=int, required=True)
    args = parser.parse_args()
    repo = Path(args.repo)
    sys.path.insert(0, str(repo))
    from deploy.dev import Stack  # the review stack's own fixture helpers
    host = {**os.environ, "HOME": pwd.getpwuid(os.getuid()).pw_dir}
    stack = Stack(args.project, args.port)
    stack.environment["HOME"] = host["HOME"]
    python = str(repo / "deploy/.local/access-venv/bin/python")
    operator = [python, "-m", "deploy.access_operator", "--project", args.project, "--port", str(args.port)]
    OUT.mkdir(parents=True, exist_ok=True)

    def op(*argv):
        result = subprocess.run([*operator, *argv], capture_output=True, text=True, cwd=repo, env=host)
        if result.returncode:
            raise RuntimeError(f"operator {argv[0]} failed: {result.stdout[-300:]} {result.stderr[-300:]}")
        return json.loads(result.stdout) if result.stdout.strip().startswith(("{", "[")) else result.stdout

    def publish(apk, version, code):
        manifest = {"version": version, "version_code": code, **apk_facts(apk)}
        path = OUT / f"manifest-{code}.json"
        path.write_text(json.dumps(manifest) + "\n")
        result = op("release-publish", TARGET, str(apk), "--manifest", str(path))
        return manifest, result

    facts = {name: apk_facts(APKS / f"{name}.apk") for name in ("v1", "v2", "v3-other", "v5")}
    (OUT / "apks.json").write_text(json.dumps(facts, indent=2) + "\n")

    for folder in ("anj-cloud", "anj-cloud/Notes"):
        stack.dav("MKCOL", UID, folder, expected=(201, 405))
    stack.dav("PUT", UID, "anj-cloud/Notes/before.txt", data=b"before the update", headers=OCTETS,
              expected=(201, 204))

    # v1, paired by code through main's spec #35 dialog: the stack's pinned code, the CA
    # fetched and checked by the app, approval by the server (no CA file, no fingerprint).
    adb("reverse", f"tcp:{args.port}", f"tcp:{args.port}")
    # -g: A4 asks for POST_NOTIFICATIONS at the first open; granted, no dialog covers pairing.
    adb("install", "-r", "-t", "-g", str(APKS / "v1.apk"), timeout=300)
    adb("logcat", "-c")
    launch()
    tap(r"^Pair device", timeout=90)
    tap("Server", cls="EditText")
    adb("shell", "input", "keyevent", "KEYCODE_MOVE_END")
    for _ in range(60):
        adb("shell", "input", "keyevent", "KEYCODE_DEL")
    type_text(f"https://127.0.0.1:{args.port}")
    invite = op("invite", UID, "--rights", "write")
    tap("Pairing code", cls="EditText")
    type_text(invite["code"])
    hide_keyboard()
    tap(r"^Pair$")
    # Decision #163: the first-sync screen follows pairing; Android keeps nothing by default,
    # so Notes (the fixture's folder) is ticked to stay on this device.
    first = find(r"Choose what stays on this device", timeout=90)
    step("v1 paired by code: the first-sync screen", first is not None, version_code=version_code())
    scroll_tap(r"^Notes")
    scroll_tap(r"^Start sync")
    paired = find(r"^(Up to date|Syncing)|^Device pairing$", timeout=90)  # the phone status line
    deadline = time.time() + 120
    while time.time() < deadline and "Notes/before.txt" not in local_files():
        time.sleep(3)
    step("v1 paired and syncing", paired is not None and "Notes/before.txt" in local_files(),
         version_code=version_code(), files=local_files())

    # Nothing published: a check says up to date.
    check_for_updates()
    step("no release: up to date", find("AnJ Cloud is up to date", timeout=30) is not None)
    tap(r"^Dismiss$")

    v2, published = publish(APKS / "v2.apk", "0.2.0", 2)
    step("v2 published on R", True, manifest=v2, served=published if isinstance(published, dict) else None)
    check_for_updates()
    offer = find(r"Version 0\.2\.0 \(", timeout=30)
    step("update available with version and size", find("Update available", timeout=5) is not None
         and offer is not None, shown=label(offer) if offer else None, downloads=update_downloads())
    step("nothing downloaded before the user approves", update_downloads() == [] and not session_lines())

    tap(r"^Download and install$")
    allow = find(r"Allow AnJ Cloud to install its updates", timeout=180)
    step("first update asks for Install unknown apps, after verification", allow is not None
         and update_downloads() != [] and not session_lines() and not installer_in_front(),
         downloads=update_downloads())
    tap(r"^Open settings$")
    toggle = find(r"Allow from this source", timeout=20)
    step("system Install unknown apps screen for AnJ Cloud", toggle is not None)
    tap_node(toggle)
    adb("shell", "input", "keyevent", "KEYCODE_BACK")
    confirm = find(r"update this app|Do you want to update", timeout=30)
    restarted = False
    if confirm is None and find(r"Update available", timeout=10) is not None:
        # Android may restart the app when the permission changes: the offer is shown again
        # and Download and install continues with the permission in place.
        restarted = True
        tap(r"^Download and install$")
        confirm = find(r"update this app|Do you want to update", timeout=180)
    step("Android's confirmation opens after the permission (user action required)",
         confirm is not None and installer_in_front(), focus=focused(), sessions=session_lines(),
         app_restarted_by_permission=restarted)
    # The confirmation runs in AnJ Cloud's own task: leaving the app and opening it again
    # brings it back in front instead of leaving the panel waiting.
    adb("shell", "input", "keyevent", "KEYCODE_HOME")
    time.sleep(2)
    launch()
    back = find(r"update this app|Do you want to update", timeout=20)
    step("leaving and reopening the app brings the confirmation back", back is not None
         and installer_in_front(), focus=focused())
    tap(r"^Cancel$", pkg="packageinstaller")
    declined = find(r"Update not installed", timeout=30)
    step("declined: v1 stays, the app says so", declined is not None and version_code() == 1,
         version_code=version_code(), sessions=session_lines())

    tap(r"^Install$")
    confirm = find(r"update this app|Do you want to update", timeout=60)
    step("Install again opens Android's confirmation", confirm is not None and installer_in_front())
    tap(r"^Update$", pkg="packageinstaller")
    deadline = time.time() + 180
    while time.time() < deadline and version_code() != 2:
        time.sleep(3)
    step("approved: v2 installed with the same signer", version_code() == 2, version_code=version_code())

    stack.dav("PUT", UID, "anj-cloud/Notes/after.txt", data=b"after the update", headers=OCTETS,
              expected=(201, 204))
    time.sleep(3)
    launch()
    deadline = time.time() + 120
    while time.time() < deadline and "Notes/after.txt" not in local_files():
        time.sleep(3)
    still = find(r"^Device pairing$", timeout=30)
    step("v2 still paired and syncing; the download was removed",
         still is not None and "Notes/after.txt" in local_files() and update_downloads() == [],
         files=local_files(), downloads=update_downloads())

    def negative(name, reason, publish_it):
        adb("logcat", "-c")
        manifest = publish_it()
        check_for_updates()
        offer = find(r"Update available", timeout=30)
        if offer is None:
            step(f"{name}: offered", False, screen=screen_text()[:600])
        tap(r"^Download and install$")
        front = False
        shown = None
        deadline = time.time() + 240
        while time.time() < deadline:
            front = front or installer_in_front()
            shown = find(r"Update discarded", timeout=2)
            if shown is not None:
                break
        text = screen_text()
        step(f"{name}: discarded before the installer opens",
             shown is not None and re.search(reason, text, re.I) is not None and not front
             and not session_lines() and version_code() == 2 and update_downloads() == [],
             manifest=manifest, reason=[line for line in text.splitlines() if re.search(reason, line, re.I)],
             installer_seen=front, sessions=session_lines(), version_code=version_code(),
             downloads=update_downloads())
        tap(r"^Dismiss$")

    negative("different signer", r"different key",
             lambda: publish(APKS / "v3-other.apk", "0.3.0", 3)[0])
    negative("lower versionCode", r"not newer than the installed",
             lambda: publish(APKS / "v1.apk", "0.4.0", 4)[0])

    def tampered():
        manifest = publish(APKS / "v5.apk", "0.5.0", 5)[0]
        # One byte of the stored package, same size: storage the gateway trusted went bad.
        flip = ("import pathlib,sys\n"
                "p=next(pathlib.Path('/var/lib/anj').rglob('releases/android-arm64/5.pkg'))\n"
                "f=open(p,'r+b'); f.seek(4096); b=f.read(1); f.seek(4096); f.write(bytes([b[0]^255])); f.close()\n"
                "print(p.stat().st_size)\n")
        size = stack.compose("exec", "-T", "access", "python", "-c", flip).strip()
        return {**manifest, "stored_size_after_flip": int(size)}

    negative("wrong SHA-256", r"SHA-256", tampered)

    log = adb("logcat", "-d", check=False)
    step("no key or certificate material in logcat", "BEGIN CERTIFICATE" not in log and "PRIVATE KEY" not in log
         and invite["code"] not in log)


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
            log = adb("logcat", "-d", "-v", "brief", check=False)
            keep = [line for line in log.splitlines()
                    if re.search(r"FATAL|AndroidRuntime|E/flutter|Exception|AnjUpdater|PackageInstaller", line)]
            (OUT / "errors.txt").write_text("\n".join(keep[-200:]) + "\n")
            (OUT / "screen.txt").write_text(screen_text() + "\n")
        adb("uninstall", PKG, check=False)
        (OUT / "steps.json").write_text(json.dumps(STEPS, indent=2) + "\n")
    sys.exit(status)
