#!/usr/bin/env python3
"""Spec #28 acceptance row 10 (Background Sync, review M1) on the emulator, run by anj-emu-run:

  APKS=<dir with app.apk and grantee-g1.apk> OUT=<evidence dir> \\
  anj-emu-run <tag> <n> python3 tool/android/emu_provider_upload.py --repo <checkout> \\
      --project anj-cloud-review-<tag> --port <p>

A provider edit uploads without the activity: the QA app is paired by code with a review stack
(adb reverse; its console backend approves the pinned code), Music is approved read-write for
grantee 1 in Apps with access and picked in Android's folder picker. The app then goes to the
background and is left there until Android caches it. Grantee 1 writes two files into Music
through the provider; each change asks for expedited one-time work (A4's prompt), whose run
uploads them. Pass: both files are on the server with their content, the prompt work ran
(AnjSyncWorker logs tags=[anj-sync-prompt]) and our activity was never resumed meanwhile.
"""
import argparse
import json
import os
from pathlib import Path
import pwd
import re
import subprocess
import sys
import time
import traceback

sys.path.insert(0, str(Path(__file__).resolve().parent))
import emu_updater as u  # noqa: E402  (shared adb and uiautomator helpers)

PKG = u.PKG
G1 = PKG + ".grantee1"
UID = u.UID
ROOT_TITLE = "AnJ Cloud QA"


def grantee(command, out, **extras):
    """Starts a grantee command and waits for its files/out/<out>.json."""
    u.adb("shell", "run-as", G1, "rm", "-f", f"files/out/{out}.json", check=False)
    argv = ["shell", "am", "start", "-W", "-n", f"{G1}/cloud.anj.grantee.GranteeActivity",
            "--es", "cmd", command, "--es", "out", out]
    for key, value in extras.items():
        argv += ["--es", key, value]
    u.adb(*argv)
    deadline = time.time() + 60
    while time.time() < deadline:
        text = u.adb("shell", "run-as", G1, "cat", f"files/out/{out}.json", check=False).strip()
        if text.startswith("{"):
            (u.OUT / f"{out}.json").write_text(text + "\n")
            return json.loads(text)
        time.sleep(0.5)
    return {"error": "no result"}


def resumes():
    """How often MainActivity was resumed, from the activity manager's event log."""
    log = u.adb("logcat", "-d", "-b", "events", "-s", "wm_on_resume_called:I", check=False)
    return len([line for line in log.splitlines() if "cloud.anj.anj_cloud.MainActivity" in line])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True)
    parser.add_argument("--project", required=True)
    parser.add_argument("--port", type=int, required=True)
    args = parser.parse_args()
    repo = Path(args.repo)
    sys.path.insert(0, str(repo))
    from deploy.dev import Stack
    host = {**os.environ, "HOME": pwd.getpwuid(os.getuid()).pw_dir}
    stack = Stack(args.project, args.port)
    stack.environment["HOME"] = host["HOME"]
    python = str(repo / "deploy/.local/access-venv/bin/python")
    operator = [python, "-m", "deploy.access_operator", "--project", args.project, "--port", str(args.port)]
    u.OUT.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%H%M%S")
    names = [f"m1-{stamp}-created.txt", f"m1-{stamp}-second.txt"]

    def op(*argv):
        result = subprocess.run([*operator, *argv], capture_output=True, text=True, cwd=repo, env=host)
        if result.returncode:
            raise RuntimeError(f"operator {argv[0]} failed: {result.stdout[-300:]} {result.stderr[-300:]}")
        return json.loads(result.stdout) if result.stdout.strip().startswith(("{", "[")) else result.stdout

    def on_server(name):
        try:
            return stack.dav("GET", UID, f"anj-cloud/Music/{name}", expected=(200,))
        except RuntimeError:
            return None

    for folder in ("anj-cloud", "anj-cloud/Music"):
        stack.dav("MKCOL", UID, folder, expected=(201, 405))

    u.adb("reverse", f"tcp:{args.port}", f"tcp:{args.port}")
    u.adb("install", "-r", "-t", "-g", str(u.APKS / "app.apk"), timeout=300)
    u.adb("install", "-r", "-t", str(u.APKS / "grantee-g1.apk"), timeout=300)
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
    first = u.find(r"Choose what stays on this device", timeout=90)
    u.step("paired by code: the first-sync screen", first is not None)
    u.scroll_tap(r"^Start sync")  # Android's default: nothing kept locally (#163)
    u.step("paired and running", u.find(r"^(Up to date|Syncing)|^Device pairing$", timeout=90) is not None)

    # Approve grantee 1 for Music, read and write, in Apps with access.
    u.tap(r"AnJ Cloud menu|Show menu", timeout=45)
    u.tap(r"^Apps with access$")
    u.tap(r"^Approve an app")
    u.tap(r"^AnJ Grantee 1", timeout=30)
    u.scroll_tap(r"^Music$")
    u.scroll_tap(r"^Read and write")
    u.tap(r"^Approve$")
    u.tap(r"^Later$")
    approved = u.find(r"AnJ Grantee 1", timeout=10)
    u.step("grantee 1 approved for Music (read and write)", approved is not None
           and "Read and write" in u.screen_text(), screen=u.screen_text()[:400])

    # Grantee 1 adds Music in Android's folder picker.
    u.adb("shell", "run-as", G1, "rm", "-f", "files/out/pick-music.json", check=False)
    u.adb("shell", "am", "start", "-W", "-n", f"{G1}/cloud.anj.grantee.GranteeActivity",
          "--es", "cmd", "pick", "--es", "slot", "music")
    u.tap(r"Show roots", timeout=30)
    u.tap(re.escape(ROOT_TITLE))
    u.tap(r"^Music$")
    u.tap(r"(?i)use this folder")
    u.tap(r"(?i)^allow$")
    picked = ""
    deadline = time.time() + 20
    while time.time() < deadline and "content://" not in picked:
        picked = u.adb("shell", "run-as", G1, "cat", "files/out/pick-music.json", check=False)
        time.sleep(0.5)
    (u.OUT / "pick-music.json").write_text(picked)
    u.step("grantee 1 picked Music in AnJ Cloud", f"content://{PKG}.documents/tree/" in picked, pick=picked.strip())

    # The app leaves the screen and is left until Android caches it.
    u.adb("shell", "input", "keyevent", "KEYCODE_HOME")
    time.sleep(25)
    u.adb("logcat", "-c")
    u.adb("logcat", "-b", "events", "-c", check=False)
    before = u.adb("shell", "dumpsys", "activity", "processes", PKG, check=False)
    (u.OUT / "process-before-edit.txt").write_text(before)
    u.step("before the edit the app is in the background, not on screen", PKG not in u.focused(),
           focused=u.focused())

    # Grantee 1 writes through the provider: create one file, then a second (create + write +
    # close each); nothing of ours comes to the front.
    first_write = grantee("write", "m1-write-1", slot="music", name=names[0], text=names[0])
    second_write = grantee("write", "m1-write-2", slot="music", name=names[1], text=names[1])
    u.adb("shell", "input", "keyevent", "KEYCODE_HOME")
    u.step("grantee 1 wrote two files through the provider",
           first_write.get("ok") is True and second_write.get("ok") is True,
           first=first_write, second=second_write)

    deadline = time.time() + 240
    found = {}
    while time.time() < deadline and len(found) < len(names):
        for name in names:
            if name not in found:
                body = on_server(name)
                if body is not None:
                    found[name] = body.decode(errors="replace")
        time.sleep(3)
    worker = u.adb("logcat", "-d", "-s", "AnjSyncWorker:I", check=False)
    (u.OUT / "worker.log").write_text(worker)
    prompt_runs = [line for line in worker.splitlines() if "anj-sync-prompt" in line]
    (u.OUT / "logcat.txt").write_text(u.adb("logcat", "-d", check=False))
    u.step("both files uploaded without the activity (row 10)",
           all(found.get(name) == name for name in names), uploaded=found)
    u.step("the provider change asked for prompt work, which ran", bool(prompt_runs), runs=prompt_runs[:4])
    u.step("our activity was not resumed meanwhile", resumes() == 0 and PKG not in u.focused(),
           resumes=resumes(), focused=u.focused())
    log = u.adb("logcat", "-d", check=False)
    u.step("no pairing code or key material in logcat", invite["code"] not in log
           and "PRIVATE KEY" not in log and "BEGIN CERTIFICATE" not in log)


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
        for pkg in (PKG, G1):
            u.adb("uninstall", pkg, check=False)
        (u.OUT / "steps.json").write_text(json.dumps(u.STEPS, indent=2) + "\n")
    sys.exit(status)
