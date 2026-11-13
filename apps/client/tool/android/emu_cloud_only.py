#!/usr/bin/env python3
"""Spec #45 acceptance row F4 (per-file Cloud-only) on the emulator, run by anj-emu-run:

  APKS=<dir with app.apk> OUT=<evidence dir> \\
  anj-emu-run <tag> <n> python3 tool/android/emu_cloud_only.py --repo <checkout> \\
      --project anj-cloud-review-<tag> --port <p>

The stack's console backend must run (deploy.vm.console_backend on
deploy/.local/<project>/console/backend.sock): the gateway approves the pinned code through it.

A fixture song is placed in the server's Music. The QA app is paired by code with the review stack
(adb reverse) and keeps the Android default (nothing kept, so Music's loose files are Cloud-only).
From the song's ⋮ menu: Keep on this device downloads it (same bytes); Cloud-only / free up space
releases it (its bytes leave the app's storage). Then the same both ways from Select mode, with
no confirmation. Last, Open downloads the song again (a working copy with the same bytes) and hands
it to Android. The song is deleted from the server and the device revoked at the end.
"""
import argparse
import hashlib
import io
import json
import math
import os
from pathlib import Path
import pwd
import re
import shlex
import subprocess
import sys
import time
import traceback
import wave

sys.path.insert(0, str(Path(__file__).resolve().parent))
import emu_updater as u  # noqa: E402  (shared adb and uiautomator helpers)

PKG = u.PKG
UID = u.UID


def wait(predicate, timeout=120):
    deadline = time.time() + timeout
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(2)
    return predicate()


def tone(seconds=30, rate=8000):
    """A playable song: an 8-bit mono WAV of a 440 Hz tone with a little noise."""
    out = io.BytesIO()
    with wave.open(out, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(1)
        w.setframerate(rate)
        noise = os.urandom(seconds * rate)
        w.writeframes(bytes(int(128 + 90 * math.sin(2 * math.pi * 440 * i / rate)) + noise[i] % 8
                            for i in range(seconds * rate)))
    return out.getvalue()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True)
    parser.add_argument("--project", required=True)
    parser.add_argument("--port", type=int, required=True)
    args = parser.parse_args()
    if not args.project.startswith("anj-cloud-review-"):
        raise SystemExit("Use a disposable anj-cloud-review-<tag> stack.")
    repo = Path(args.repo)
    sys.path.insert(0, str(repo))
    from deploy.dev import Stack
    host = {**os.environ, "HOME": pwd.getpwuid(os.getuid()).pw_dir}
    stack = Stack(args.project, args.port)
    stack.environment["HOME"] = host["HOME"]
    python = str(repo / "deploy/.local/access-venv/bin/python")
    operator = [python, "-m", "deploy.access_operator", "--project", args.project, "--port", str(args.port)]
    u.OUT.mkdir(parents=True, exist_ok=True)
    song = f"f25-{time.strftime('%H%M%S')}-song.wav"
    path = f"Music/{song}"
    body = tone()
    digest = hashlib.sha256(body).hexdigest()
    facts = {"song": path, "sha256": digest, "size": len(body)}

    def op(*argv):
        result = subprocess.run([*operator, *argv], capture_output=True, text=True, cwd=repo, env=host)
        if result.returncode:
            raise RuntimeError(f"operator {argv[0]} failed: {result.stdout[-300:]} {result.stderr[-300:]}")
        return json.loads(result.stdout) if result.stdout.strip().startswith(("{", "[")) else result.stdout

    def on_device():
        """The song's sha256 in the app's root, or None when it is not there."""
        out = u.run_as("sha256sum", f"files/anj-cloud/{path}")
        match = re.match(r"([0-9a-f]{64})\s", out)
        return match.group(1) if match else None

    def staged():
        """sha256 of every app-private file outside the root (staging, working copies), by name."""
        # adb shell joins its arguments into one remote command line: quote the script.
        script = "find files -type f ! -path 'files/anj-cloud/*' -exec sha256sum {} +"
        out = u.run_as("sh", "-c", shlex.quote(script))
        return {line.split()[1]: line.split()[0] for line in out.splitlines() if re.match(r"[0-9a-f]{64}\s", line)}

    def menu():
        """Opens the song's ⋮ menu (search shows the song alone)."""
        u.tap(r"^File actions$", timeout=30)
        cloud = u.find(r"^Cloud-only / free up space", timeout=10)
        keep = u.find(r"^Keep on this device", timeout=10)
        return cloud, keep

    def tap_row():
        """Taps the song's row, never the search field that also holds its name."""
        deadline = time.time() + 20
        while time.time() < deadline:
            rows = [n for n in u.nodes() if song in u.label(n) and "EditText" not in n["class"]
                    and len(n["bounds"]) == 4]
            if rows:
                u.tap_node(rows[-1])
                return
            time.sleep(1)
        raise RuntimeError("the song's row is not on screen")

    def select_and(action):
        # Select mode stays on after an action (its button then reads Cancel).
        if u.find(r"^Cancel$", timeout=2) is None:
            u.tap(r"^Select$", timeout=20)
        tap_row()
        u.find(r"^1 selected$|1 items selected", timeout=10)
        u.tap(action, timeout=10)
        time.sleep(2)

    for folder in ("anj-cloud", "anj-cloud/Music"):
        stack.dav("MKCOL", UID, folder, expected=(201, 405))
    stack.dav("PUT", UID, f"anj-cloud/{path}", data=body, headers=u.OCTETS, expected=(201, 204))
    invite = None
    try:
        u.adb("reverse", f"tcp:{args.port}", f"tcp:{args.port}")
        u.adb("install", "-r", "-t", "-g", str(u.APKS / "app.apk"), timeout=300)
        for setting in ("window_animation_scale", "transition_animation_scale", "animator_duration_scale"):
            u.adb("shell", "settings", "put", "global", setting, "0")
        u.adb("logcat", "-c")
        u.launch()
        u.tap(r"^Pair device", timeout=90)
        u.tap("Server", cls="EditText")
        u.adb("shell", "input", "keyevent", "KEYCODE_MOVE_END")
        for _ in range(60):
            u.adb("shell", "input", "keyevent", "KEYCODE_DEL")
        u.type_text(f"https://127.0.0.1:{args.port}")
        invite = op("invite", UID, "--rights", "write")
        u.tap("Pairing code", cls="EditText")
        u.type_text(invite["code"])
        u.hide_keyboard()
        u.tap(r"^Pair$")
        u.step("paired by code: the first-sync screen",
               u.find(r"Choose what stays on this device", timeout=90) is not None)
        u.scroll_tap(r"^Start sync")  # Android's default: nothing kept locally (#163)
        u.step("paired and running", u.find(r"^(Up to date|Syncing)", timeout=90) is not None)

        # The song alone in the list.
        u.tap("Search name or path", cls="EditText", timeout=30)
        u.type_text(song)
        u.hide_keyboard()
        u.step("the fixture song is listed, Cloud-only and not on the device",
               u.find(re.escape(song), timeout=90) is not None and on_device() is None, **facts)

        # ⋮ menu: Keep on this device, then Cloud-only / free up space.
        cloud, keep = menu()
        u.step("its menu offers both choices, Cloud-only checked as its folder's",
               cloud is not None and keep is not None and "(as folder)" in u.label(cloud),
               cloud=cloud and u.label(cloud), cloud_checked=cloud and cloud["checked"],
               keep=keep and u.label(keep))
        u.tap_node(keep)
        u.step("Keep on this device downloads the song with the same bytes",
               wait(lambda: on_device() == digest) and on_device() == digest)
        cloud, keep = menu()
        u.step("its menu now shows its own choice", keep is not None and "(as folder)" not in u.label(keep),
               keep=keep and u.label(keep), keep_checked=keep and keep["checked"])
        u.tap_node(cloud)
        u.step("Cloud-only / free up space releases it: its bytes leave the device",
               wait(lambda: on_device() is None) and on_device() is None)
        u.step("the row says Cloud", u.find(r"^Cloud$", timeout=10) is not None, screen=u.screen_text()[:600])

        # Select mode, both ways, no confirmation.
        select_and(r"^Local and Cloud$")
        u.step("Select mode: Local and Cloud downloads it, no confirmation",
               wait(lambda: on_device() == digest) and on_device() == digest
               and u.find(r"Delete selected items everywhere", timeout=1) is None)
        select_and(r"^Cloud Only$")
        u.step("Select mode: Cloud Only releases it, no confirmation",
               wait(lambda: on_device() is None) and on_device() is None)

        # Open downloads it again into a working copy and hands it to Android.
        u.tap(r"^Cancel$", timeout=10)
        before = staged()
        u.adb("logcat", "-c")
        tap_row()
        copies = wait(lambda: [name for name, value in staged().items()
                               if value == digest and name not in before], timeout=120)
        player = wait(lambda: "AudioPreview" in u.focused(), timeout=30)
        time.sleep(5)
        log = u.adb("logcat", "-d", check=False)
        (u.OUT / "open-logcat.txt").write_text(log)
        views = [line for line in log.splitlines() if "android.intent.action.VIEW" in line]
        errors = [line for line in log.splitlines() if re.search(r"MediaPlayer\w*: [Ee]rror", line)]
        u.step("Open downloads the song (same bytes) and hands it to Android",
               bool(copies) and bool(views), copies=copies, views=views[:1])
        u.step("the song plays: the player is in front and reports no error",
               bool(player) and "AudioPreview" in u.focused() and not errors,
               focused=u.focused(), errors=errors[:3])
        u.adb("shell", "input", "keyevent", "KEYCODE_BACK")
        log = u.adb("logcat", "-d", check=False)
        u.step("no pairing code or key material in logcat", invite["code"] not in log
               and "PRIVATE KEY" not in log and "BEGIN CERTIFICATE" not in log)
    finally:
        try:
            stack.dav("DELETE", UID, f"anj-cloud/{path}", expected=(204, 404))
        finally:
            # This run's device: the stack is this lane's own, its devices this run's.
            devices = op("devices") if invite is not None else []
            for device in devices if isinstance(devices, list) else []:
                if device.get("uid") == UID and device.get("state") == "active":
                    op("revoke", device["id"])


if __name__ == "__main__":
    status = 1
    try:
        main()
        status = 0
    except SystemExit as error:
        print(error, flush=True)
    except Exception as error:  # evidence first, then the failure
        u.STEPS.append({"step": "driver error", "ok": False, "error": f"{type(error).__name__}: {error}"[:400]})
        print(f"ERROR {type(error).__name__}: {error}", flush=True)
        traceback.print_exc()
    finally:
        if status:
            (u.OUT / "screen.txt").write_text(u.screen_text() + "\n")
            (u.OUT / "logcat-failure.txt").write_text(u.adb("logcat", "-d", check=False))
        u.adb("uninstall", PKG, check=False)
        (u.OUT / "steps.json").write_text(json.dumps(u.STEPS, indent=2) + "\n")
    sys.exit(status)
