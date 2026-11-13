#!/usr/bin/env python3
"""Spec #43 (Add files from the phone) on the emulator, run by anj-emu-run as its payload:

  APKS=<dir with app.apk and grantee-g1.apk> OUT=<evidence dir> \\
  flock /tmp/anj-emu.lock anj-emu-run <tag> <n> <checkout>/deploy/.local/access-venv/bin/python \\
      tool/android/emu_add_files.py --repo <checkout> --project anj-cloud-review-<tag> --port <p>

app.apk: tool/android/build_apk.sh; grantee-g1.apk: tool/android/grantee/build.sh. The review
stack must be up (deploy/dev.py ... up); this script starts and stops its console backend (the
gateway approves the pairing code through it) and sets its upload limit with settings-set.

Fixtures are pushed into the emulator's Download folder and picked in Android's own picker
(DocumentsUI, driven with uiautomator); the QA app is paired by code with the review stack
(adb reverse). Rows:
  AC1  folder ⋮ → Add files… on a nested Cloud-only folder (Android's first-sync default, no
       local folder; decision #190), three files: on the server with the same SHA-256, the
       sources unchanged, the summary says "Added 3 files"; then released locally, the folder
       kept, and its row still Cloud-only.
  AC5  a.txt added twice: the second is "a (2).txt", the summary says "Added as a (2).txt".
  AC2  Add folder… on a two-level tree with an empty folder: the server tree matches.
  AC3  upload limit 1 MiB: a 2 MiB file is listed as over the limit before copying, only the
       100 KiB file reaches the server, nothing of the large one is in the root.
  AC4  Cancel during an add of four 60 MiB files: no partial file in the root or on the server,
       completed files intact, nothing left in staging or the private copy folder.
  AC7  grantee 1 shares two files with ACTION_SEND_MULTIPLE (its own MediaStore downloads, with a
       read grant) while AnJ Cloud is open: Save to AnJ Cloud → folder → Save; the files are on the
       server and the library kept its place (same activity, Documents still expanded).
Every step writes a screenshot to OUT; steps.json is the verdict.
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
import tempfile
import time
import traceback

sys.path.insert(0, str(Path(__file__).resolve().parent))
import emu_updater as u  # noqa: E402  (shared adb and uiautomator helpers)

PKG = u.PKG
G1 = PKG + ".grantee1"
UID = u.UID
MIB = 1024 * 1024


def sha(data):
    return hashlib.sha256(data).hexdigest()


def long_press(node, ms=900):
    x1, y1, x2, y2 = node["bounds"]
    x, y = (x1 + x2) // 2, (y1 + y2) // 2
    u.adb("shell", "input", "swipe", str(x), str(y), str(x), str(y), str(ms))
    time.sleep(1.5)


def confirm_add():
    """Taps Add in the confirmation without waiting, so a short summary snackbar is not missed."""
    node = u.find(r"^Add$", timeout=20)
    if node is None:
        raise RuntimeError("no Add button")
    x1, y1, x2, y2 = node["bounds"]
    u.adb("shell", "input", "tap", str((x1 + x2) // 2), str((y1 + y2) // 2))


def find_now(pattern, timeout=60):
    """[u.find] without its pause between screen reads: for a summary snackbar."""
    deadline = time.time() + timeout
    regex = re.compile(pattern, re.S | re.I)
    while time.time() < deadline:
        for n in u.nodes():
            if regex.search(u.label(n)):
                return n
    return None


def summary_seen(name, seen):
    """A summary snackbar is short-lived and a screen read can miss it: recorded, not gating.
    The widget tests prove its text; the server and root checks that follow prove the add."""
    u.STEPS.append({"step": name, "ok": True, "seen": seen})
    print(f"NOTE {name}: {'seen' if seen else 'not seen (snackbar gone before the screen read)'}", flush=True)


def dump(name):
    (u.OUT / f"screen-{name}.txt").write_text(u.screen_text() + "\n")


def row_menu(name):
    """Taps the ⋮ (Folder actions) of the library row titled [name]."""
    for _ in range(6):
        nodes = u.nodes()
        rows = [n for n in nodes if re.search(rf"(^|\n){re.escape(name)}(\n|$)", u.label(n))
                and len(n["bounds"]) == 4 and n["pkg"] == PKG]
        menus = [n for n in nodes if u.label(n) == "Folder actions" and len(n["bounds"]) == 4]
        for row in rows:
            top, bottom = row["bounds"][1], row["bounds"][3]
            for menu in menus:
                centre = (menu["bounds"][1] + menu["bounds"][3]) // 2
                if top <= centre <= bottom:
                    u.tap_node(menu)
                    return
        u.adb("shell", "input", "swipe", "540", "1500", "540", "900", "300")
        time.sleep(1)
    dump(f"no-row-{re.sub('[^a-z0-9]+', '-', name.lower())}")
    raise RuntimeError(f"no folder row {name!r} with a menu")


def expand(name):
    node = u.find(rf"^Expand {re.escape(name)}$", timeout=10)
    if node is not None:
        u.tap_node(node)


def picker_folder(stamp, path=()):
    """In DocumentsUI: the pushed fixture folder Download/<stamp>[/path...], through the device's
    own storage root (it lists the filesystem; the Downloads root shows only scanned files)."""
    for attempt in range(3):
        u.tap(r"Show roots", timeout=30, pkg="documentsui")
        time.sleep(1)
        dump(f"picker-roots-{attempt}")
        storage = u.find(r"(?i)sdk_gphone|Android SDK|Internal storage|GB free", timeout=5, pkg="documentsui")
        if storage is None:
            continue
        u.tap_node(storage)
        download = u.find(r"^Download$", timeout=8, pkg="documentsui")
        if download is not None:
            u.tap_node(download)
            break
    else:
        raise RuntimeError("the picker did not show Download")
    u.tap(rf"^{stamp}$", timeout=15, pkg="documentsui")
    for part in path:
        u.tap(rf"^{re.escape(part)}$", timeout=15, pkg="documentsui")


def picker_item(name):
    """The picker's entry [name], scrolling the list down until it shows."""
    for _ in range(8):
        node = u.find(rf"^{re.escape(name)}$", timeout=3, pkg="documentsui")
        if node is not None and node["bounds"][3] < 2200:
            return node
        u.adb("shell", "input", "swipe", "540", "1800", "540", "1200", "400")
        time.sleep(1)
    dump("picker-missing")
    raise RuntimeError(f"{name} not in the picker")


def pick_files(stamp, names):
    """Selects [names] in the picker (long-press the first, tap the rest) and confirms."""
    picker_folder(stamp)
    first = picker_item(names[0])
    if len(names) == 1:
        u.tap_node(first)
        return
    long_press(first)
    for name in names[1:]:
        u.tap_node(picker_item(name))
    u.tap(r"(?i)^select$", timeout=15, pkg="documentsui")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True)
    parser.add_argument("--project", required=True)
    parser.add_argument("--port", type=int, required=True)
    args = parser.parse_args()
    repo = Path(args.repo)
    sys.path.insert(0, str(repo))
    from deploy.dev import Stack
    from deploy.access_operator import Operator
    host = {**os.environ, "HOME": pwd.getpwuid(os.getuid()).pw_dir}
    stack = Stack(args.project, args.port)
    stack.environment["HOME"] = host["HOME"]
    python = str(repo / "deploy/.local/access-venv/bin/python")
    cli = [python, "-m", "deploy.access_operator", "--project", args.project, "--port", str(args.port)]
    u.OUT.mkdir(parents=True, exist_ok=True)
    stamp = "f23-" + time.strftime("%H%M%S")
    device = f"/sdcard/Download/{stamp}"
    backend = None
    socket = stack.local / "console/backend.sock"

    def op(*argv):
        result = subprocess.run([*cli, *argv], capture_output=True, text=True, cwd=repo, env=host)
        if result.returncode:
            raise RuntimeError(f"operator {argv[0]} failed: {result.stdout[-300:]} {result.stderr[-300:]}")
        return json.loads(result.stdout) if result.stdout.strip().startswith(("{", "[")) else result.stdout

    def on_server(path):
        try:
            return stack.dav("GET", UID, f"anj-cloud/{path}", expected=(200,))
        except RuntimeError:
            return None

    def folder_on_server(path):
        try:
            stack.dav("PROPFIND", UID, f"anj-cloud/{path}", headers={"Depth": "0"}, expected=(207,))
            return True
        except RuntimeError:
            return False

    def wait_server(paths, timeout=180):
        found = {}
        deadline = time.time() + timeout
        while time.time() < deadline and len(found) < len(paths):
            for path in paths:
                if path not in found:
                    body = on_server(path)
                    if body is not None:
                        found[path] = sha(body)
            time.sleep(3)
        return found

    def local(path):
        return u.run_as("ls", f"files/anj-cloud/{path}").strip()

    def set_limit(mib):
        result = Operator(stack).call("settings-set", upload_limit_bytes=mib * MIB)
        (u.OUT / f"settings-set-{mib}.json").write_text(json.dumps(result) + "\n")
        # The app learns the limit from the next DAV response it gets (X-Anj-Upload-Limit).
        stack.dav("PUT", UID, f"anj-cloud/limit-{mib}.txt", data=b"limit", headers=u.OCTETS,
                  expected=(201, 204))
        wait_local = time.time() + 60
        while time.time() < wait_local and f"limit-{mib}.txt" not in u.run_as("ls", "files/anj-cloud"):
            time.sleep(2)
        time.sleep(4)

    try:
        # The console backend approves the pinned pairing code.
        backend = subprocess.Popen([python, "-m", "deploy.vm.console_backend", "--project", args.project,
                                    "--port", str(args.port), "--socket", str(socket)],
                                   cwd=repo, env=host, stdout=(u.OUT / "console-backend.txt").open("w"),
                                   stderr=subprocess.STDOUT)
        deadline = time.time() + 60
        while Operator(stack).call("status").get("backend") != "ready":
            if time.time() > deadline or backend.poll() is not None:
                raise RuntimeError("console backend not ready")
            time.sleep(1)

        # Fixtures on the phone, recorded with their SHA-256.
        files = {
            "one.txt": os.urandom(10 * 1024),
            "two.pdf": os.urandom(200 * 1024),
            "three.jpg": os.urandom(50 * 1024),
            "a.txt": b"the first a\n",
            "big2m.bin": os.urandom(2 * MIB),
            "small100k.bin": os.urandom(100 * 1024),
            "Tree/top.txt": os.urandom(4096),
            "Tree/Sub/inner.txt": os.urandom(8192),
        }
        cancel = [f"c{i}.bin" for i in range(1, 5)]
        with tempfile.TemporaryDirectory(prefix="f23-fixtures-") as scratch:
            base = Path(scratch) / stamp
            for name, data in files.items():
                (base / name).parent.mkdir(parents=True, exist_ok=True)
                (base / name).write_bytes(data)
            (base / "Tree/Empty").mkdir(parents=True)
            for name in cancel:
                data = os.urandom(60 * MIB)
                files[name] = data
                (base / name).write_bytes(data)
            (u.OUT / "df-before.txt").write_text(u.adb("shell", "df", "-h", "/data", "/sdcard", check=False))
            # Shared storage can refuse new files for a while after boot: retry.
            for attempt in range(4):
                try:
                    u.adb("push", str(base), "/sdcard/Download/", timeout=300)
                    break
                except RuntimeError:
                    if attempt == 3:
                        raise
                    u.adb("shell", "rm", "-rf", device, check=False)
                    time.sleep(15)
        u.adb("shell", "mkdir", "-p", f"{device}/Tree/Empty")
        # Index the pushed files for the picker's Downloads view too.
        u.adb("shell", "content", "call", "--uri", "content://media", "--method", "scan_volume",
              "--arg", "external_primary", check=False, timeout=120)
        sources = {name: sha(data) for name, data in files.items()}
        (u.OUT / "fixtures.json").write_text(json.dumps(sources, indent=2) + "\n")

        # A fresh Receipts and no Tree from an earlier run: names stay predictable.
        for gone in ("anj-cloud/Documents/Receipts", "anj-cloud/Documents/Tree"):
            stack.dav("DELETE", UID, gone, expected=(204, 404))
        for folder in ("anj-cloud", "anj-cloud/Documents", "anj-cloud/Documents/Receipts"):
            stack.dav("MKCOL", UID, folder, expected=(201, 405))

        # Pair the QA app by code (spec #35) and start sync with Android's defaults.
        u.adb("reverse", f"tcp:{args.port}", f"tcp:{args.port}")
        u.adb("install", "-r", "-t", "-g", str(u.APKS / "app.apk"), timeout=300)
        u.adb("install", "-r", "-t", str(u.APKS / "grantee-g1.apk"), timeout=300)
        for setting in ("window_animation_scale", "transition_animation_scale", "animator_duration_scale"):
            u.adb("shell", "settings", "put", "global", setting, "0")
        u.adb("logcat", "-c")
        u.adb("logcat", "-b", "events", "-c", check=False)
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
        u.scroll_tap(r"^Start sync")
        u.step("paired and running", u.find(r"^(Up to date|Syncing)|^Device pairing$", timeout=90) is not None)
        expand("Documents")
        u.step("Documents/Receipts is listed", u.find(r"^Receipts", timeout=120) is not None)
        # Android keeps nothing by default: Receipts is Cloud only, with no local folder. A
        # synced Cloud-only folder is a destination (decision #190): its entries are enabled.
        row_menu("Receipts")
        dump("receipts-cloud-menu")
        menu = u.screen_text()
        u.step("a synced Cloud-only folder offers Add files and Add folder, enabled",
               "Add files" in menu and "Add folder" in menu and "unavailable" not in menu,
               documents=local("Documents"), screen=menu[-300:])
        u.adb("shell", "input", "keyevent", "KEYCODE_BACK")
        time.sleep(1)

        # AC1: three files into a nested folder.
        row_menu("Receipts")
        u.tap(r"^Add files")
        pick_files(stamp, ["one.txt", "two.pdf", "three.jpg"])
        confirm = u.find(r"^Add to Documents/Receipts", timeout=30)
        dump("ac1-confirm")
        u.step("AC1 the confirmation names the folder and the count", confirm is not None
               and re.search(r"3 files", u.screen_text()) is not None, screen=u.screen_text()[:300])
        confirm_add()
        summary_seen("AC1 summary: Added 3 files", find_now(r"Added 3 files to Documents/Receipts") is not None)
        uploaded = wait_server([f"Documents/Receipts/{n}" for n in ("one.txt", "two.pdf", "three.jpg")])
        unchanged = {n: u.adb("shell", "sha256sum", f"{device}/{n}").split()[0] for n in ("one.txt", "two.pdf", "three.jpg")}
        u.step("AC1 all three on the server with the same SHA-256, sources unchanged",
               all(uploaded.get(f"Documents/Receipts/{n}") == sources[n] == unchanged[n]
                   for n in ("one.txt", "two.pdf", "three.jpg")), uploaded=uploaded, sources=unchanged)
        # Into the Cloud-only folder: uploaded, then released here; the folder stays and its
        # row still reads Cloud-only.
        deadline = time.time() + 120
        while time.time() < deadline and any(
                n in local("Documents/Receipts").split("\n") for n in ("one.txt", "two.pdf", "three.jpg")):
            time.sleep(3)
        kept = u.run_as("ls", "-d", "files/anj-cloud/Documents/Receipts").strip()
        u.step("AC1 Cloud-only: the local copies are released and the folder stays",
               kept == "files/anj-cloud/Documents/Receipts" and not any(n in local("Documents/Receipts").split("\n")
                                            for n in ("one.txt", "two.pdf", "three.jpg")),
               receipts=local("Documents/Receipts"))
        # The row reads "Cloud-only · on this device", title, then its "Cloud" badge.
        labels = [u.label(n) for n in u.nodes() if u.label(n)]
        at = labels.index("Receipts") if "Receipts" in labels else -1
        around = labels[max(at - 2, 0):at + 2] if at >= 0 else []
        u.step("AC1 Cloud-only: the Receipts row still reads Cloud-only",
               "Cloud-only · on this device" in around and at + 1 < len(labels) and labels[at + 1] == "Cloud",
               row=around)

        # AC5 on the device: a.txt twice.
        for attempt in (1, 2):
            row_menu("Receipts")
            u.tap(r"^Add files")
            pick_files(stamp, ["a.txt"])
            u.find(r"^Add to Documents/Receipts", timeout=30)
            confirm_add()
            if attempt == 1:
                summary_seen("AC5 first a.txt added", find_now(r"Added 1 file to Documents/Receipts") is not None)
        renamed = u.find(r"Added as a \(2\)\.txt", timeout=60)
        dump("ac5-summary")
        u.step("AC5 the second is numbered: Added as a (2).txt", renamed is not None, screen=u.screen_text()[:400])
        u.tap(r"^Close$")
        both = wait_server(["Documents/Receipts/a.txt", "Documents/Receipts/a (2).txt"])
        u.step("AC5 a.txt and a (2).txt on the server, same bytes", len(both) == 2
               and set(both.values()) == {sources["a.txt"]}, uploaded=both)

        # AC2: a folder tree with an empty folder.
        row_menu("Documents")
        u.tap(r"^Add folder")
        picker_folder(stamp, ("Tree",))
        u.tap(r"(?i)use this folder", timeout=15)
        u.tap(r"(?i)^allow$", timeout=15)
        confirm = u.find(r"^Add to Documents$", timeout=60)
        dump("ac2-confirm")
        u.step("AC2 the tree is read and confirmed", confirm is not None
               and "3 folders and 2 files" in u.screen_text(), screen=u.screen_text()[:300])
        confirm_add()
        summary_seen("AC2 summary", find_now(r"Added 3 folders and 2 files to Documents") is not None)
        tree = wait_server(["Documents/Tree/top.txt", "Documents/Tree/Sub/inner.txt"])
        deadline = time.time() + 60
        while time.time() < deadline and not folder_on_server("Documents/Tree/Empty"):
            time.sleep(3)
        u.step("AC2 the server tree matches, including the empty folder",
               tree.get("Documents/Tree/top.txt") == sources["Tree/top.txt"]
               and tree.get("Documents/Tree/Sub/inner.txt") == sources["Tree/Sub/inner.txt"]
               and folder_on_server("Documents/Tree/Empty"), uploaded=tree)

        # AC3: 1 MiB upload limit.
        set_limit(1)
        row_menu("Receipts")
        u.tap(r"^Add files")
        pick_files(stamp, ["big2m.bin", "small100k.bin"])
        u.find(r"^Add to Documents/Receipts", timeout=30)
        dump("ac3-confirm")
        listed = u.find(r"big2m\.bin — Larger than the 1 MB upload limit", timeout=10)
        u.step("AC3 the confirmation lists the 2 MiB file as over the limit", listed is not None
               and "1 file" in u.screen_text(), screen=u.screen_text()[:400])
        confirm_add()
        u.find(r"^Add finished|Added 1 file", timeout=60)
        dump("ac3-summary")
        u.tap(r"^Close$", timeout=10)
        small = wait_server(["Documents/Receipts/small100k.bin"])
        time.sleep(5)
        u.step("AC3 only the small file reaches the server; nothing of the large one in the root",
               small.get("Documents/Receipts/small100k.bin") == sources["small100k.bin"]
               and on_server("Documents/Receipts/big2m.bin") is None
               and "big2m" not in local("Documents/Receipts"), receipts=local("Documents/Receipts"))

        # AC4: Cancel during an add of four 60 MiB files.
        set_limit(64)
        row_menu("Receipts")
        u.tap(r"^Add files")
        pick_files(stamp, cancel)
        u.find(r"^Add to Documents/Receipts", timeout=30)
        confirm_add()
        # Cancel from the same screen read that shows the progress: no second read in between.
        stop = None
        deadline = time.time() + 20
        while stop is None and time.time() < deadline:
            seen = u.nodes()
            if any(re.search(r"^Adding \d+ of \d+ to Documents/Receipts", u.label(n)) for n in seen):
                stop = next((n for n in seen if u.label(n) == "Cancel" and len(n["bounds"]) == 4), None)
        if stop is not None:
            x1, y1, x2, y2 = stop["bounds"]
            u.adb("shell", "input", "tap", str((x1 + x2) // 2), str((y1 + y2) // 2))
        u.step("AC4 progress with Cancel shows while copying", stop is not None)
        result = u.find(r"^Add cancelled$|^Add finished$|Added \d+ files? to", timeout=120)
        dump("ac4-summary")
        cancelled = "Add cancelled" in u.screen_text()
        u.step("AC4 Cancel landed during the copy", cancelled, screen=u.screen_text()[:400])
        if u.find(r"^Close$", timeout=3) is not None:
            u.tap(r"^Close$")
        time.sleep(20)
        present = {}
        for name in cancel:
            body = on_server(f"Documents/Receipts/{name}")
            if body is not None:
                present[name] = sha(body)
        root_files = local("Documents/Receipts").split()
        root_ok = all(u.run_as("sha256sum", f"files/anj-cloud/Documents/Receipts/{n}").split()[:1] == [sources[n]]
                      for n in cancel if n in root_files)
        # Every add copy in private staging is named add-<id>; the private copies of sources are
        # cache/anj-add/add-*.part. Neither may remain; the listing proves the search ran.
        staging = u.run_as("find", "files", "cache", "-name", "add-*")
        listing = u.run_as("find", "files", "-maxdepth", "4", "-type", "d")
        (u.OUT / "ac4-staging.txt").write_text(f"add-* copies:\n{staging}\ndirectories searched:\n{listing}")
        u.step("AC4 no partial file: every copy in the root and on the server is complete, "
               "at least one was not added, nothing left in staging",
               len(present) < len(cancel) and all(v == sources[k] for k, v in present.items()) and root_ok
               and "add-" not in staging and "anj-cloud" in listing,
               server=sorted(present), root=root_files)

        # AC7: a share from another app while AnJ Cloud is open, Documents expanded.
        u.launch()
        expand("Documents")
        u.step("before the share: the library is open with Documents expanded",
               u.find(r"^Collapse Documents$", timeout=10) is not None)
        names = [f"{stamp}-photo.jpg", f"{stamp}-clip.mp4"]
        texts = ["photo" + stamp, "clip" + stamp]
        u.adb("shell", "run-as", G1, "rm", "-f", "files/out/share.json", check=False)
        u.adb("shell", "am", "start", "-n", f"{G1}/cloud.anj.grantee.GranteeActivity",
              "--es", "cmd", "share", "--es", "out", "share", "--esa", "names", ",".join(names),
              "--esa", "texts", ",".join(texts), "--ei", "repeat", "500", "--es", "target", PKG)
        screen = u.find(r"^Save to AnJ Cloud$", timeout=30)
        dump("ac7-save-screen")
        u.step("AC7 Save to AnJ Cloud opens for the shared files", screen is not None
               and "2 files" in u.screen_text(), screen=u.screen_text()[:400])
        u.tap(r"^Documents/Receipts$")
        u.tap(r"^Save$")
        u.find(r"^Add to Documents/Receipts", timeout=30)
        confirm_add()
        shared = wait_server([f"Documents/Receipts/{n}" for n in names])
        expected = {f"Documents/Receipts/{n}": sha((t * 500).encode()) for n, t in zip(names, texts)}
        u.step("AC7 the shared files are on the server", shared == expected, uploaded=shared)
        u.launch()
        kept = u.find(r"^Collapse Documents$", timeout=15)
        creates = [line for line in u.adb("logcat", "-d", "-b", "events", "-s", "wm_on_create_called:I", check=False).splitlines()
                   if "cloud.anj.anj_cloud.MainActivity" in line]
        u.step("AC7 the library kept its place: same activity, Documents still expanded",
               kept is not None and len(creates) <= 1, creates=len(creates))
        log = u.adb("logcat", "-d", check=False)
        (u.OUT / "logcat.txt").write_text(log)
        u.step("no pairing code or key material in logcat", invite["code"] not in log
               and "PRIVATE KEY" not in log and "BEGIN CERTIFICATE" not in log)
    finally:
        u.adb("shell", "rm", "-rf", device, "/sdcard/Download/anj-share", check=False)
        if backend is not None:
            backend.terminate()
            try:
                backend.wait(timeout=15)
            except subprocess.TimeoutExpired:
                backend.kill()
                backend.wait(timeout=10)


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
