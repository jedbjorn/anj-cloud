#!/usr/bin/env python3
"""Spec #44 AC8 on the emulator: delete, Undo and Trash restore on the phone layout, run by anj-emu-run:

  APKS=<dir with app.apk> OUT=<evidence dir> \\
  anj-emu-run <tag> <n> python3 tool/android/emu_trash.py --repo <checkout> --project anj-cloud-review-<tag> --port <p>

The stack needs the /trash/ routes and its console backend (deploy.vm.console_backend on
deploy/.local/<project>/console/backend.sock): the gateway approves the pinned code through it. The QA app
is paired by code with the review stack (adb reverse). Three files are put on the server at the top of
anj-cloud/ through the operator's backend path; the app lists them. Then, through the real UI:

1. Delete (row menu) is one step: no dialog, the row goes, "Moved to Trash" with Undo and View; the
   server item is in Alice's Nextcloud trash.
2. Undo after the server applied the delete: the file is back on the server with the same bytes and the
   row returns.
3. Delete, then View: the Trash view lists it with "Deleted permanently in 7 days"; Restore (no
   confirmation) brings it back on the server.
4. Sync paused (the delete cannot be sent), Delete, Undo: the delete is cancelled; after Resume the file
   was never deleted on the server and is not in its trash.

Every step writes a screenshot and the UI text to OUT; the pairing code never enters the evidence.
"""
import argparse
import hashlib
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

UID = u.UID
PKG = u.PKG


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
    names = {key: f"trash-{stamp}-{key}.txt" for key in ("undo", "view", "paused")}
    content = {name: (f"AC8 {name} bytes\n" * 40).encode() for name in names.values()}

    def op(*argv):
        result = subprocess.run([*operator, *argv], capture_output=True, text=True, cwd=repo, env=host)
        if result.returncode:
            raise RuntimeError(f"operator {argv[0]} failed: {result.stdout[-300:]} {result.stderr[-300:]}")
        return json.loads(result.stdout) if result.stdout.strip().startswith(("{", "[")) else result.stdout

    def on_server(name):
        status, body = stack.backend_http("GET", f"/remote.php/dav/files/{UID}/anj-cloud/{name}", UID)
        return body if status == 200 else None

    def in_trash(name):
        status, body = stack.backend_http("PROPFIND", f"/remote.php/dav/trashbin/{UID}/trash/", UID,
                                          b'<d:propfind xmlns:d="DAV:" xmlns:nc="http://nextcloud.org/ns"><d:prop>'
                                          b'<nc:trashbin-original-location/></d:prop></d:propfind>',
                                          {"Depth": "1", "Content-Type": "application/xml"})
        return f"anj-cloud/{name}<" in body.decode(errors="replace")

    def wait(predicate, timeout=90):
        deadline = time.time() + timeout
        while time.time() < deadline:
            value = predicate()
            if value:
                return value
            time.sleep(2)
        return predicate()

    def row(name, timeout=60):
        return u.find(re.escape(name), timeout=timeout)

    def row_menu(name):
        """Opens the File actions menu of the row showing `name`."""
        target = row(name)
        if target is None:
            raise RuntimeError(f"no row for {name}")
        y1, y2 = target["bounds"][1], target["bounds"][3]
        for n in u.nodes():
            if re.fullmatch(r"File actions", u.label(n)) and len(n["bounds"]) == 4 and y1 <= (n["bounds"][1] + n["bounds"][3]) // 2 <= y2:
                u.tap_node(n)
                return
        raise RuntimeError(f"no File actions on the row for {name}")

    def delete(name):
        row_menu(name)
        u.tap(exact("Delete everywhere"))

    def text():
        return u.screen_text()

    def snackbar_tap(words, timeout=4):
        """Taps the snackbar's `words`. It stays only about 8 seconds and a UI dump can wait out an animation,
        so after `timeout` seconds of dumps the button is tapped where the phone layout puts it (the
        screenshots show it there); the caller checks the outcome either way."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            for n in u.nodes():
                if re.fullmatch(exact(words), u.label(n)) and len(n["bounds"]) == 4:
                    u.tap_node(n)
                    return n
        size = re.search(r"(\d+)x(\d+)", u.adb("shell", "wm", "size"))
        width, height = (int(size.group(1)), int(size.group(2))) if size else (1080, 2400)
        x = {"View": 720, "Undo": 940}[words] * width // 1080
        u.adb("shell", "input", "tap", str(x), str(2174 * height // 2400))
        time.sleep(1.5)
        return None

    def exact(words):
        """A node whose text or description is exactly `words` (Flutter may set both, which the label joins)."""
        word = re.escape(words)
        return rf"^{word}( {word})?$"

    for name, data in content.items():
        stack.dav("PUT", UID, f"anj-cloud/{name}", data=data, headers=u.OCTETS, expected=(201, 204))

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
    first = u.find(r"Choose what stays on this device", timeout=90)
    u.step("paired by code: the first-sync screen", first is not None)
    u.scroll_tap(r"^Start sync")
    u.step("paired and running", u.find(r"^(Up to date|Syncing)|^Device pairing$", timeout=90) is not None)
    u.launch()
    listed = all(row(name, timeout=90) is not None for name in content)
    u.step("the three server files are listed", listed, screen=text()[:600])

    # 1. Delete is one step; 2. Undo after the server applied it.
    name = names["undo"]
    delete(name)
    # The snackbar stays about 8 seconds and a UI dump takes one or two: one dump serves every check.
    deadline, dump, undo = time.time() + 20, [], None

    def first(words):
        return next((n for n in dump if re.fullmatch(exact(words), u.label(n)) and len(n["bounds"]) == 4), None)
    while undo is None and time.time() < deadline:
        dump = u.nodes()
        undo = first("Undo")
    snack, view = first("Moved to Trash"), first("View")
    shown = "\n".join(u.label(n) for n in dump)
    applied = in_trash(name)
    if undo is None:
        (u.OUT / "delete-screen.txt").write_text(shown)
        raise RuntimeError("no Undo on the snackbar")
    u.tap_node(undo)
    (u.OUT / "delete-screen.txt").write_text(shown)
    u.step("Delete: no dialog, the row went, Moved to Trash with Undo and View",
           snack is not None and view is not None and "Delete everywhere?" not in shown and name not in shown)
    u.step("the server had deleted it into Alice's trash before Undo", bool(applied))
    back = wait(lambda: on_server(name), timeout=90)
    u.step("Undo: back on the server with the same bytes",
           back is not None and hashlib.sha256(back).hexdigest() == hashlib.sha256(content[name]).hexdigest()
           and not in_trash(name))
    u.step("Undo: the row returns", row(name, timeout=90) is not None, screen=text()[:600])

    # 3. Delete, then View: Trash lists it; Restore.
    name = names["view"]
    delete(name)
    snackbar_tap("View")
    listed = u.find(re.escape(name), timeout=10)
    if listed is None:  # Opened before the server applied it: pull to refresh.
        wait(lambda: in_trash(name), timeout=60)
        u.adb("shell", "input", "swipe", "540", "700", "540", "1600", "400")
        listed = u.find(re.escape(name), timeout=30)
    shown = text()
    u.step("View opens Trash: the item with its expiry", listed is not None and "Deleted permanently in 7 days" in shown
           and "Empty Trash" in shown, screen=shown[:800])
    y1, y2 = listed["bounds"][1], listed["bounds"][3]
    restore = [n for n in u.nodes() if re.fullmatch(exact("Restore"), u.label(n)) and len(n["bounds"]) == 4
               and y1 <= (n["bounds"][1] + n["bounds"][3]) // 2 <= y2]
    if not restore:
        raise RuntimeError("no Restore on the Trash row")
    u.tap_node(restore[0])
    restored = u.find(r"^Restored ", timeout=30)
    back = wait(lambda: on_server(name), timeout=60)
    u.step("Trash Restore (no confirmation): back on the server with the same bytes",
           restored is not None and back is not None and back == content[name] and "Delete permanently" not in text(),
           screen=text()[:400])
    u.adb("shell", "input", "keyevent", "KEYCODE_BACK")
    time.sleep(2)
    u.step("the restored row is back in the library", row(name, timeout=90) is not None)

    # 4. Paused (offline for the app): Delete, Undo cancels the pending delete.
    name = names["paused"]
    u.tap(r"AnJ Cloud menu|Show menu", timeout=30)
    u.tap(exact("Pause sync"))
    delete(name)
    snackbar_tap("Undo")
    u.find(exact("Restored."), timeout=20)
    u.step("paused: Undo of the pending delete answers Restored and the row returns", row(name, timeout=20) is not None,
           screen=text()[:400])
    u.tap(r"AnJ Cloud menu|Show menu", timeout=30)
    u.tap(exact("Resume sync"))
    time.sleep(20)
    data = on_server(name)
    u.step("after Resume the file was never deleted on the server",
           data == content[name] and not in_trash(name))
    log = u.adb("logcat", "-d", check=False)
    (u.OUT / "logcat.txt").write_text(log)
    u.step("no pairing code or key material in logcat", invite["code"] not in log
           and "PRIVATE KEY" not in log and "BEGIN CERTIFICATE" not in log)
    for name in content:
        stack.dav("DELETE", UID, f"anj-cloud/{name}", expected=(204, 404))


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
        try:
            u.step("failure screen", True, screen=u.screen_text()[:800])
        except Exception:  # noqa: BLE001
            pass
    finally:
        (u.OUT / "steps.json").write_text(json.dumps(u.STEPS, indent=2) + "\n")
        u.adb("uninstall", PKG, check=False)
    sys.exit(status)
