#!/usr/bin/env python3
"""Spec #52 (phone folders) acceptance rows 2 to 6 on the emulator (seat E), run by anj-emu-run:

  APKS=<dir with app.apk [and main.apk]> OUT=<evidence dir> \\
  anj-emu-run <tag> <n> <checkout>/deploy/.local/access-venv/bin/python \\
      tool/android/emu_phone_folders.py --repo <checkout> --project anj-cloud-review-<tag> \\
      --port <p> --phase phone|move

app.apk: tool/android/build_apk.sh on this branch; main.apk: the same from origin/main (the
install before this feature, phase `move`). The review stack must be up (deploy/dev.py ... up);
this script starts and stops its console backend. The review stack's DAV is the other side (the
Linux client's place, spec #52 Seats): what it puts there the phone must get, and the reverse.

phase `phone` (a fresh install of app.apk, All files access granted with appops):
  AC3  before pairing, the phone's Music and Documents hold a unique file, one identical to a
       cloud file at the same path and one that differs: the unique one is uploaded, the identical
       one links (its cloud version unchanged: no upload), the different one keeps both (a
       conflict row; neither side overwritten); no phone file deleted or changed.
  AC2  an mp3 adb-pushed into Music/<run>/Test reaches the cloud; `Live: 1999?.mp3` added in the
       cloud arrives as `Live： 1999？.mp3` and the cloud keeps its name; a video added under
       Videos lands in Movies and in the media library; renames and deletes propagate both ways;
       a delete through Android's trash (MediaStore is_trashed) reaches the household trash; no
       `.pending-`, `.trashed-` or staging name ever appears on either side.
  AC6  a 70 MiB file in Movies stays on the phone and its row says "Too large to upload yet".
  AC5  access revoked (appops deny): the explanation screen, then the attention line; no cloud
       deletion, a root-level cloud file still arrives; access back: nothing deleted. Revoked
       again, a phone file deleted by adb meanwhile: deleted in the cloud only after access
       returns.
phase `move` (AC4): main.apk paired with Local music in its private root, one file opened (a
  working copy) and one unsynced edit (sync paused); then app.apk installed over it with access
  granted, killed while it moves the folders, started again: every file in the phone folders once
  by hash, the private top folders gone, nothing downloaded again (the gateway's request log),
  and the edit uploaded once sync resumes.
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
import urllib.parse
import xml.etree.ElementTree as ET

sys.path.insert(0, str(Path(__file__).resolve().parent))
import emu_updater as u  # noqa: E402  (shared adb and uiautomator helpers)

PKG = u.PKG
UID = u.UID
MIB = 1024 * 1024
SD = "/storage/emulated/0"


def sha(data):
    return hashlib.sha256(data).hexdigest()


def wait(predicate, timeout=180, every=3):
    deadline = time.time() + timeout
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(every)
    return predicate()


def dump(name):
    (u.OUT / f"screen-{name}.txt").write_text(u.screen_text() + "\n")


def ffmpeg(*argv):
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", *argv], check=True)


def fixtures(scratch):
    """A playable mp3, a playable mp4 and two distinct songs (real encodes, so the media
    library indexes them as audio and video)."""
    out = {}
    for name, args in {
        "song.mp3": ["-f", "lavfi", "-i", "sine=f=440:d=4", "-c:a", "libmp3lame", "-q:a", "9"],
        "other.mp3": ["-f", "lavfi", "-i", "sine=f=660:d=5", "-c:a", "libmp3lame", "-q:a", "9"],
        "live.mp3": ["-f", "lavfi", "-i", "sine=f=330:d=3", "-c:a", "libmp3lame", "-q:a", "9"],
        "clip.mp4": ["-f", "lavfi", "-i", "testsrc=d=2:s=160x120:r=10", "-c:v", "mpeg4",
                     "-pix_fmt", "yuv420p"],
    }.items():
        path = Path(scratch) / name
        ffmpeg(*args, str(path))
        out[name] = path.read_bytes()
    return out


class Phone:
    """The phone's shared storage through adb shell (uid shell: another app's stand-in)."""

    @staticmethod
    def sh(*command):
        return u.adb("shell", *command, check=False)

    def sha(self, path):
        out = self.sh("sha256sum", f"'{SD}/{path}'")
        match = re.match(r"([0-9a-f]{64})\s", out)
        return match.group(1) if match else None

    def exists(self, path):
        return "yes" in self.sh(f"[ -e '{SD}/{path}' ] && echo yes")

    def size(self, path):
        out = self.sh("stat", "-c", "%s", f"'{SD}/{path}'").strip()
        return int(out) if out.isdigit() else None

    def push(self, data, path):
        """adb push (uid shell, another app's stand-in) into shared storage, verified."""
        with tempfile.NamedTemporaryFile() as tmp:
            tmp.write(data)
            tmp.flush()
            self.sh("mkdir", "-p", f"'{SD}/{os.path.dirname(path)}'")
            u.adb("push", tmp.name, f"{SD}/{path}")
        if self.sha(path) != sha(data):
            raise RuntimeError(f"push did not land: {path}")

    def ready(self, timeout=180):
        """Shared storage takes a while after boot before the shell may write there."""
        probe = f"{SD}/Music/.f27-ready-probe"
        deadline = time.time() + timeout
        while time.time() < deadline:
            self.sh(f"echo ok > '{probe}'")
            if "ok" in self.sh("cat", f"'{probe}'"):
                self.sh("rm", f"'{probe}'")
                time.sleep(5)
                return
            time.sleep(3)
        raise RuntimeError("shared storage never became writable")

    def listing(self, *folders):
        return self.sh("ls", "-laR", *[f"'{SD}/{f}'" for f in folders])

    def media(self, uri, path):
        return self.sh("content", "query", "--uri", uri, "--projection", "_id:_data",
                       "--where", f"\"_data='{SD}/{path}'\"")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True)
    parser.add_argument("--project", required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--phase", choices=("phone", "move"), required=True)
    parser.add_argument("--only", default="ac3,ac2,ac6,ac5",
                        help="phase phone: the rows to run, comma-separated (default all)")
    args = parser.parse_args()
    only = set(args.only.split(","))
    if not args.project.startswith("anj-cloud-review-"):
        raise SystemExit("Use a disposable anj-cloud-review-<tag> stack.")
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
    run = "f27-" + time.strftime("%H%M%S")
    phone = Phone()
    socket = stack.local / "console/backend.sock"

    def op(*argv):
        result = subprocess.run([*cli, *argv], capture_output=True, text=True, cwd=repo, env=host)
        if result.returncode:
            raise RuntimeError(f"operator {argv[0]} failed: {result.stdout[-300:]} {result.stderr[-300:]}")
        return json.loads(result.stdout) if result.stdout.strip().startswith(("{", "[")) else result.stdout

    def put(path, data):
        parts = path.split("/")[:-1]
        stack.dav("MKCOL", UID, "anj-cloud", expected=(201, 405))
        for i in range(1, len(parts) + 1):
            stack.dav("MKCOL", UID, "anj-cloud/" + "/".join(parts[:i]), expected=(201, 405))
        stack.dav("PUT", UID, f"anj-cloud/{path}", data=data, headers=u.OCTETS, expected=(201, 204))

    def get(path):
        try:
            return stack.dav("GET", UID, f"anj-cloud/{path}", expected=(200,))
        except RuntimeError:
            return None

    def server_sha(path):
        body = get(path)
        return None if body is None else sha(body)

    def etag(path):
        try:
            body = stack.dav("PROPFIND", UID, f"anj-cloud/{path}", headers={"Depth": "0"},
                             expected=(207,))
        except RuntimeError:
            return None
        match = re.search(rb"<d:getetag>([^<]*)</d:getetag>", body)
        return match.group(1).decode() if match else None

    def server_names(folder):
        """Every path beneath anj-cloud/<folder> on the server (Depth: infinity)."""
        try:
            body = stack.dav("PROPFIND", UID, f"anj-cloud/{folder}", headers={"Depth": "infinity"},
                             expected=(207,))
        except RuntimeError:
            return []
        prefix = f"/remote.php/dav/files/{UID}/anj-cloud/"
        return sorted(urllib.parse.unquote(h.decode()).split(prefix, 1)[-1]
                      for h in re.findall(rb"<d:href>([^<]*)</d:href>", body))

    def trash_names():
        status, body = stack.backend_http("PROPFIND", f"/remote.php/dav/trashbin/{UID}/trash", UID,
                                          None, {"Depth": "1"})
        if status != 207:
            return []
        root = ET.fromstring(body)
        names = [e.text or "" for e in root.iter("{http://nextcloud.org/ns}trashbin-filename")]
        hrefs = [urllib.parse.unquote(e.text or "") for e in root.iter("{DAV:}href")]
        return names + hrefs

    def delete(path):
        stack.dav("DELETE", UID, f"anj-cloud/{path}", expected=(204, 404))

    def move(source, target):
        # backend_http speaks to Nextcloud inside its container, as http://127.0.0.1.
        destination = f"http://127.0.0.1/remote.php/dav/files/{UID}/anj-cloud/" + \
            urllib.parse.quote(target, safe="/")
        stack.dav("MOVE", UID, f"anj-cloud/{source}", headers={"Destination": destination},
                  expected=(201, 204))

    def poke():
        """The app to the front again: it lists the cloud and verifies every file (#130 (3))."""
        u.adb("shell", "input", "keyevent", "KEYCODE_HOME")
        time.sleep(1)
        u.launch()

    def search(text):
        field = u.find("Search name or path", timeout=30, cls="EditText")
        if field is None:
            raise RuntimeError("no search field")
        u.tap_node(field)
        u.adb("shell", "input", "keyevent", "KEYCODE_MOVE_END")
        for _ in range(60):
            u.adb("shell", "input", "keyevent", "KEYCODE_DEL")
        if text:
            u.type_text(text)
        u.hide_keyboard()
        time.sleep(2)
        return u.screen_text()

    def pair(apk, grant=True):
        u.adb("reverse", f"tcp:{args.port}", f"tcp:{args.port}")
        u.adb("install", "-r", "-t", str(apk), timeout=300)
        u.adb("shell", "pm", "grant", PKG, "android.permission.POST_NOTIFICATIONS", check=False)
        if grant:
            u.adb("shell", "appops", "set", PKG, "MANAGE_EXTERNAL_STORAGE", "allow")
        for setting in ("window_animation_scale", "transition_animation_scale", "animator_duration_scale"):
            u.adb("shell", "settings", "put", "global", setting, "0")
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
               u.find(r"Choose what stays on this device", timeout=120) is not None)
        # Keep everything on this device (the user's choice on this screen; spec #52 Open
        # question: Android's default leaves the folders Cloud-only).
        for _ in range(10):
            boxes = [n for n in u.nodes() if "CheckBox" in n["class"] and not n["checked"]
                     and len(n["bounds"]) == 4 and n["bounds"][3] < 2100]
            if boxes:
                u.tap_node(boxes[0])
                continue
            u.adb("shell", "input", "swipe", "540", "1600", "540", "1000", "300")
            time.sleep(1)
            if not [n for n in u.nodes() if "CheckBox" in n["class"] and not n["checked"]]:
                break
        dump("first-sync-choices")
        u.scroll_tap(r"^Start sync")
        u.step("paired and running", u.find(r"^(Up to date|Syncing|Needs attention)", timeout=120) is not None)
        return invite

    def backend_up():
        process = subprocess.Popen([python, "-m", "deploy.vm.console_backend", "--project", args.project,
                                    "--port", str(args.port), "--socket", str(socket)],
                                   cwd=repo, env=host, stdout=(u.OUT / "console-backend.txt").open("w"),
                                   stderr=subprocess.STDOUT)
        deadline = time.time() + 60
        while Operator(stack).call("status").get("backend") != "ready":
            if time.time() > deadline or process.poll() is not None:
                raise RuntimeError("console backend not ready")
            time.sleep(1)
        return process

    def diagnose(name):
        """Evidence for a failed step: both sides' listings and the app's rows for this run."""
        rows = u.run_as("sqlite3", "files/anj-profile/default/manifest.sqlite",
                        f"\"select path, body from entries where path like '%{run}%'\"")
        ops = u.run_as("sqlite3", "files/anj-profile/default/manifest.sqlite",
                       f"\"select body from operations where body like '%{run}%'\"")
        (u.OUT / f"diagnose-{name}.txt").write_text(
            "# server\n" + "\n".join(server_names("")) + "\n# phone\n"
            + phone.listing(f"Music/{run}", f"Movies/{run}", f"Documents/{run}")
            + "\n# rows\n" + rows + "\n# operations\n" + ops + "\n# screen\n" + u.screen_text())

    def check(name, ok, **facts):
        if not ok:
            diagnose(re.sub("[^a-z0-9]+", "-", name.lower())[:30])
        u.step(name, ok, **facts)

    def no_odd_names(where):
        """No `.pending-`/`.trashed-` or staging name reaches the other side or the app's own
        listing; on the phone only staging names would be wrong (Android's own trash and
        pending entries belong there)."""
        server = "\n".join(server_names(""))
        local = phone.listing(f"Music/{run}", f"Movies/{run}", f"Documents/{run}")
        app = search(".trashed") + search(".pending") + search("phone-") + search(".anj-install")
        search("")
        odd = {"server": [line for line in server.splitlines()
                          if re.search(r"\.pending-|\.trashed-|\.anj-install-|phone-[a-z]|anj-staging", line)],
               "phone": [line for line in local.splitlines()
                         if re.search(r"\.anj-install-|phone-[a-z]|anj-staging", line)],
               "app": [line for line in app.splitlines()
                       if re.search(r"\.pending-|\.trashed-|\.anj-install-|phone-[a-z]", line)
                       and "Search" not in line]}
        u.step(f"no .pending-, .trashed- or staging name in the app's listing or the cloud ({where})",
               not any(odd.values()), odd=odd)

    def gateway_log(since):
        """The review gateway's log since [since] (UTC), from its own compose project."""
        try:
            return stack.compose("logs", "--no-color", "--since", since, "access")
        except RuntimeError as error:
            return f"(no log: {error})"

    backend = None
    invite = None
    scratch = tempfile.TemporaryDirectory(prefix="f27-fixtures-")
    media = fixtures(scratch.name)
    facts = {"run": run}
    try:
        phone.ready()
        backend = backend_up()
        # Leftovers of earlier storage probes on this AVD (not this run's): gone from both sides.
        phone.sh("rm", "-rf", f"'{SD}/Music/pp-1'", f"'{SD}/Music/pp-2'")
        for leftover in ("Music/pp-1", "Music/pp-2"):
            delete(leftover)
        if args.phase == "phone":
            # --- AC3: what the phone already has, before pairing -----------------------------
            if "ac3" in only:
                unique = f"Music/{run}/ac3-unique.mp3"
                same = f"Music/{run}/ac3-same.mp3"
                diff = f"Documents/{run}/ac3-diff.txt"
                phone.push(media["other.mp3"], unique)
                phone.push(media["song.mp3"], same)
                phone.push(b"the phone's version\n", diff)
                put(same, media["song.mp3"])
                put(diff, b"the cloud's version\n")
                same_etag = etag(same)
                before = {p: phone.sha(p) for p in (unique, same, diff)}
                invite = pair(u.APKS / "app.apk")
                check("AC3: the unique phone file is uploaded with the same bytes",
                       wait(lambda: server_sha(unique) == sha(media["other.mp3"])) is True)
                time.sleep(20)
                poke()
                time.sleep(20)
                text = search("ac3-diff")
                dump("ac3-diff")
                check("AC3: the identical file links: its cloud version is unchanged (no upload)",
                       etag(same) == same_etag and server_sha(same) == sha(media["song.mp3"]),
                       etag_before=same_etag, etag_after=etag(same))
                check("AC3: the different file keeps both: the cloud keeps its bytes, the phone its own, "
                       "and the row is a conflict",
                       server_sha(diff) == sha(b"the cloud's version\n")
                       and phone.sha(diff) == before[diff]
                       and re.search(r"(?i)both versions|conflict|review", text) is not None,
                       row=text[:400])
                check("AC3: nothing on the phone was deleted or changed",
                       {p: phone.sha(p) for p in before} == before)
                server = server_names("")
                check("AC3: no conflict copy was made for the identical file",
                       not [n for n in server if "ac3-same" in n and n != same], server=server)

            if invite is None:
                invite = pair(u.APKS / "app.apk")
            # --- AC2: two-way sync ----------------------------------------------------------
            if "ac2" in only:
                pushed = f"Music/{run}/Test/pushed.mp3"
                phone.push(media["song.mp3"], pushed)
                check("AC2: an mp3 adb-pushed into Music/<run>/Test reaches the other side",
                       wait(lambda: server_sha(pushed) == sha(media["song.mp3"])) is True)
                live = f"Music/{run}/Live: 1999?.mp3"
                put(live, media["live.mp3"])
                poke()
                local_live = f"Music/{run}/Live： 1999？.mp3"
                check("AC2: 'Live: 1999?.mp3' added on the other side arrives as 'Live： 1999？.mp3'",
                       wait(lambda: phone.sha(local_live) == sha(media["live.mp3"])) is True)
                check("AC2: the other side keeps the cloud name",
                       server_sha(live) == sha(media["live.mp3"])
                       and not [n for n in server_names("") if "１" in n or "？" in n or "：" in n])
                clip = f"Videos/{run}/clip.mp4"
                put(clip, media["clip.mp4"])
                poke()
                check("AC2: a video added under Videos lands in /storage/emulated/0/Movies",
                       wait(lambda: phone.sha(f"Movies/{run}/clip.mp4") == sha(media["clip.mp4"])) is True)
                row = wait(lambda: "_data=" in phone.media("content://media/external/video/media",
                                                           f"Movies/{run}/clip.mp4") and
                           phone.media("content://media/external/video/media", f"Movies/{run}/clip.mp4"),
                           timeout=60)
                (u.OUT / "media-video.txt").write_text(str(row))
                check("AC2: the media library lists the downloaded video", bool(row), row=str(row)[:200])
                # Renames, both ways.
                phone.sh("mv", f"'{SD}/{pushed}'", f"'{SD}/Music/{run}/Test/renamed on phone.mp3'")
                check("AC2: a rename on the phone reaches the other side",
                       wait(lambda: server_sha(f"Music/{run}/Test/renamed on phone.mp3") == sha(media["song.mp3"])
                            and get(pushed) is None) is True)
                move(clip, f"Videos/{run}/renamed in cloud.mp4")
                poke()
                check("AC2: a rename on the other side reaches the phone",
                       wait(lambda: phone.sha(f"Movies/{run}/renamed in cloud.mp4") == sha(media["clip.mp4"])
                            and not phone.exists(f"Movies/{run}/clip.mp4")) is True)
                # Deletes, both ways.
                phone.sh("rm", f"'{SD}/Music/{run}/Test/renamed on phone.mp3'")
                check("AC2: a delete on the phone reaches the other side",
                       wait(lambda: get(f"Music/{run}/Test/renamed on phone.mp3") is None) is True)
                delete(f"Videos/{run}/renamed in cloud.mp4")
                poke()
                check("AC2: a delete on the other side reaches the phone",
                       wait(lambda: not phone.exists(f"Movies/{run}/renamed in cloud.mp4")) is True)
                # Android's trash (what the Files app does): MediaStore's is_trashed.
                trashed = f"Music/{run}/to trash.mp3"
                phone.push(media["other.mp3"], trashed)
                wait(lambda: server_sha(trashed) == sha(media["other.mp3"]))
                phone.sh("content", "call", "--uri", "content://media/external/file", "--method", "scan_file",
                         "--arg", f"'{SD}/{trashed}'")
                time.sleep(3)
                found = re.search(r"_id=(\d+)", phone.media("content://media/external/file", trashed))
                how = "MediaStore is_trashed"
                if found:
                    phone.sh("content", "update", "--uri", f"content://media/external/file/{found.group(1)}",
                             "--bind", "is_trashed:i:1")
                time.sleep(3)
                if phone.exists(trashed):  # the shell may not trash another app's file: rename as it does
                    how = "rename to .trashed-<expiry>-name (the on-disk effect of the Files app trash)"
                    phone.sh("mv", f"'{SD}/{trashed}'", f"'{SD}/Music/{run}/.trashed-1900000000-to trash.mp3'")
                check("AC2: a delete through Android's trash reaches the household trash",
                       wait(lambda: get(trashed) is None and any("to trash.mp3" in n for n in trash_names()))
                       is True, how=how, trash=[n for n in trash_names() if "trash" in n][:5])
                no_odd_names("after AC2")

            # --- AC6: a large phone file -------------------------------------------------------
            if "ac6" in only:
                big = f"Movies/{run}/big.mkv"
                data = os.urandom(70 * MIB)
                phone.push(data, big)
                time.sleep(30)
                poke()
                text = wait(lambda: (lambda t: t if "Too large to upload yet" in t else None)(search("big.mkv")),
                            timeout=120)
                dump("ac6-big")
                check("AC6: the 70 MiB phone file's row says 'Too large to upload yet'", bool(text),
                       row=(text or u.screen_text())[:300])
                check("AC6: it stays on the phone, unchanged, and is never uploaded or moved",
                       phone.sha(big) == sha(data) and get(big.replace("Movies/", "Videos/", 1)) is None)
                search("")

            # --- AC5: paused, never deleted ------------------------------------------------------
            if "ac5" in only:
                phone.push(media["other.mp3"], f"Music/{run}/ac5-gone.mp3")
                check("AC5: setup: a phone file is in the cloud",
                      wait(lambda: server_sha(f"Music/{run}/ac5-gone.mp3") == sha(media["other.mp3"])) is True)
                ours = sorted(n for n in server_names("") if run in n and not n.endswith("/"))
                u.adb("shell", "appops", "set", PKG, "MANAGE_EXTERNAL_STORAGE", "deny")
                time.sleep(3)
                killed = not u.adb("shell", "pidof", PKG, check=False).strip()
                u.launch()
                screen = u.find(r"Android calls this All files access", timeout=60)
                check("AC5: without access the explanation screen shows (Android stopped the app on revoke)",
                       screen is not None, killed_on_revoke=killed)
                u.tap(r"^Not now$", timeout=20)
                check("AC5: the attention line: 'Music, Videos and Documents are paused: allow All files "
                       "access'", u.find(r"Music, Videos and Documents are paused: allow All files access",
                                         timeout=60) is not None)
                loose = f"{run}-loose.txt"
                put(loose, b"other folders keep syncing\n")
                poke()
                check("AC5: other folders keep syncing (a root-level cloud file arrives)",
                       wait(lambda: "other folders" in u.run_as("cat", f"files/anj-cloud/{loose}")) is True)
                time.sleep(20)
                after = sorted(n for n in server_names("") if run in n and not n.endswith("/"))
                check("AC5: no cloud deletion while paused", set(ours) <= set(after), missing=sorted(set(ours) - set(after)))
                u.adb("shell", "appops", "set", PKG, "MANAGE_EXTERNAL_STORAGE", "allow")
                time.sleep(3)
                u.launch()
                check("AC5: access back: the attention line is gone",
                       wait(lambda: u.find(r"are paused: allow All files access", timeout=2) is None, timeout=60)
                       is True)
                time.sleep(30)
                again = sorted(n for n in server_names("") if run in n and not n.endswith("/"))
                check("AC5: after the full verification nothing was deleted", set(ours) <= set(again),
                       missing=sorted(set(ours) - set(again)))
                gone = f"Music/{run}/ac5-gone.mp3"
                u.adb("shell", "appops", "set", PKG, "MANAGE_EXTERNAL_STORAGE", "deny")
                time.sleep(3)
                phone.sh("rm", f"'{SD}/{gone}'")
                u.launch()
                u.tap(r"^Not now$", timeout=20) if u.find(r"^Not now$", timeout=10) else None
                time.sleep(40)
                check("AC5: a phone file deleted by adb while access was missing stays in the cloud",
                       get(gone) is not None)
                u.adb("shell", "appops", "set", PKG, "MANAGE_EXTERNAL_STORAGE", "allow")
                time.sleep(3)
                u.launch()
                check("AC5: once access is back it syncs as a normal deletion",
                       wait(lambda: get(gone) is None, timeout=240) is True)
                no_odd_names("after AC5")
                log = u.adb("logcat", "-d", check=False)
                (u.OUT / "logcat.txt").write_text(log)
                u.step("no pairing code or key material in logcat",
                       invite["code"] not in log and "PRIVATE KEY" not in log)
        else:
            # --- AC4: moving an existing install ------------------------------------------------
            songs = {f"Music/{run}/Album/song{i:02d}.wav": os.urandom(4 * MIB) for i in range(20)}
            files = {**songs,
                     f"Music/{run}/play.mp3": media["song.mp3"],
                     f"Videos/{run}/clip.mp4": media["clip.mp4"],
                     f"Documents/{run}/edit.txt": b"before the edit\n"}
            phase_start = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime())
            for path, data in files.items():
                put(path, data)
            invite = pair(u.APKS / "main.apk", grant=False)
            check("AC4: main: everything downloaded into the private root",
                   wait(lambda: all(f"{p}" in "\n".join(u.local_files()) for p in files), timeout=300) is True)
            # One opened file: a working copy in private staging.
            search("play.mp3")
            rows = [n for n in u.nodes() if "play.mp3" in u.label(n) and "EditText" not in n["class"]
                    and len(n["bounds"]) == 4]
            u.tap_node(rows[-1])
            time.sleep(6)
            u.adb("shell", "input", "keyevent", "KEYCODE_BACK")
            time.sleep(2)
            staged = u.run_as("sh", "-c", "'ls files/.anj-cloud-*/ files/anj-profile/default/staging/ 2>/dev/null'")
            check("AC4: main: an opened working copy is in private staging", "play.mp3" in staged,
                   staging=staged[:400])
            search("")
            # Pause sync, then one local edit that cannot be uploaded yet.
            u.tap(r"AnJ Cloud menu|Show menu", timeout=30)
            u.tap(r"^Pause sync$")
            time.sleep(3)
            edited = b"the unsynced local edit\n"
            u.run_as("sh", "-c", f"'printf \"the unsynced local edit\\n\" > files/anj-cloud/Documents/{run}/edit.txt'")
            time.sleep(10)
            check("AC4: main: the edit is unsynced (sync paused)",
                   server_sha(f"Documents/{run}/edit.txt") == sha(b"before the edit\n"))
            private_before = {p: u.run_as("sha256sum", f"files/anj-cloud/{p}").split(" ")[0] for p in files}
            since = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime())
            # The update, with access granted, killed mid-move.
            u.adb("install", "-r", "-t", str(u.APKS / "app.apk"), timeout=300)
            u.adb("shell", "appops", "set", PKG, "MANAGE_EXTERNAL_STORAGE", "allow")
            u.adb("logcat", "-c")
            u.adb("shell", "am", "start", "-n", f"{PKG}/cloud.anj.anj_cloud.MainActivity")
            first = wait(lambda: phone.sh("ls", f"'{SD}/Music/{run}/Album'").count("song") >= 1, timeout=120,
                         every=0.2)
            u.adb("shell", "am", "force-stop", PKG)
            moved = phone.sh("ls", f"'{SD}/Music/{run}/Album'").count("song")
            left = u.run_as("ls", f"files/anj-cloud/Music/{run}/Album").count("song")
            check("AC4: killed while moving: some files moved, the rest still private",
                   bool(first) and 0 < moved and left > 0, moved=moved, still_private=left)
            u.launch()
            check("AC4: started again, the move finishes: private Music, Videos and Documents are gone",
                   wait(lambda: not u.run_as("ls", "files/anj-cloud").strip()
                        or all(t not in u.run_as("ls", "files/anj-cloud").split()
                               for t in ("Music", "Videos", "Documents")), timeout=300) is True,
                   root=u.run_as("ls", "files/anj-cloud"))
            phone_paths = {p: p.replace("Videos/", "Movies/", 1) for p in files}
            hashes = {p: phone.sha(phone_paths[p]) for p in files}
            check("AC4: every file is in the phone folders exactly once, by hash",
                   all(hashes[p] == private_before[p] for p in files)
                   and phone.sh("ls", f"'{SD}/Music/{run}/Album'").count("song") == len(songs),
                   mismatched=[p for p in files if hashes[p] != private_before[p]])
            notice = u.find(r"now in your phone's folders", timeout=60)
            check("AC4: the status line says once that the folders moved", notice is not None)
            u.tap(r"AnJ Cloud menu|Show menu", timeout=30)
            u.tap(r"^Resume sync$")
            check("AC4: the unsynced edit is uploaded afterwards",
                   wait(lambda: server_sha(f"Documents/{run}/edit.txt") == sha(edited), timeout=180) is True)
            time.sleep(20)
            log = gateway_log(since)
            (u.OUT / "gateway-since-update.txt").write_text(log)
            control = gateway_log(phase_start)
            (u.OUT / "gateway-whole-phase.txt").write_text(control)

            def gets(text):
                return [line for line in text.splitlines() if re.search(r"\bGET\b", line)
                        and re.search(r"song\d\d\.wav|play\.mp3|clip\.mp4|edit\.txt", line)]
            check("AC4: the gateway log names file downloads (control: main's first sync)",
                   bool(gets(control)), control=gets(control)[:3])
            check("AC4: no re-download: the gateway served none of the moved files after the update",
                   not gets(log), downloads=gets(log)[:5])
            staged = u.run_as("sh", "-c", "'ls files/.anj-cloud-*/ files/anj-profile/default/staging/ 2>/dev/null'")
            check("AC4: the opened working copy is kept", "play.mp3" in staged, staging=staged[:400])
            log = u.adb("logcat", "-d", check=False)
            (u.OUT / "logcat.txt").write_text(log)
        (u.OUT / "facts.json").write_text(json.dumps(facts, indent=2) + "\n")
    finally:
        try:
            for folder in (f"Music/{run}", f"Videos/{run}", f"Documents/{run}", f"{run}-loose.txt"):
                delete(folder)
            phone.sh("rm", "-rf", f"'{SD}/Music/{run}'", f"'{SD}/Movies/{run}'", f"'{SD}/Documents/{run}'")
        finally:
            devices = op("devices") if invite is not None else []
            for device in devices if isinstance(devices, list) else []:
                if device.get("uid") == UID and device.get("state") == "active":
                    op("revoke", device["id"])
            if backend is not None:
                backend.terminate()
                backend.wait(timeout=30)
            scratch.cleanup()


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
