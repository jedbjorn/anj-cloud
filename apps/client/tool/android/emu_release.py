#!/usr/bin/env python3
"""Spec #40 R1 acceptance row "Android signed release and feed update" on the emulator, run by
anj-emu-run as its payload:

  APKS=<dir with N.apk, N1.apk, other.apk> OUT=<evidence dir> \\
  anj-emu-run <tag> <n> python3 tool/android/emu_release.py --repo <checkout> \\
      --project anj-cloud-review-<tag> --port <p> --source-ref <ref>

N.apk and N1.apk: release builds (cloud.anj.anj_cloud, R8) of two commits by
tool/android/release_android.py build, signed with the release key; other.apk: N1.apk re-signed
with a throwaway key. The stack's console backend must run (pairing by code is approved through
it). Release N is installed as from its GitHub release and paired; N+1 is published with
`deploy/release.py publish --target android-arm64 --local-project` (which refuses other.apk).
The app offers N+1 and asks for "Install unknown apps"; granted while a large file downloads into a
kept folder, the install waits for sync; then Android's confirmation, and N+1 runs, still paired. other.apk,
published through the operator with its own certificate, is offered and discarded ("different
key") before any install session. The release app is not debuggable: everything is read from the
screen, the package manager and the server, never from the app's storage.
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

u.PKG = "cloud.anj.anj_cloud"  # the helpers read it at call time
UID = u.UID


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True)
    parser.add_argument("--project", required=True)
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--source-ref", required=True)
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
    apks = {name: u.APKS / f"{name}.apk" for name in ("N", "N1", "other")}

    def op(*argv):
        result = subprocess.run([*operator, *argv], capture_output=True, text=True, cwd=repo, env=host)
        if result.returncode:
            raise RuntimeError(f"operator {argv[0]} failed: {result.stdout[-300:]} {result.stderr[-300:]}")
        return json.loads(result.stdout) if result.stdout.strip().startswith(("{", "[")) else result.stdout

    def release_publish(apk):
        done = subprocess.run([python, "deploy/release.py", "publish", "--target", "android-arm64",
                               "--artifact", str(apk), "--local-project", args.project, "--port", str(args.port),
                               "--source-ref", args.source_ref], capture_output=True, text=True, cwd=repo, env=host)
        return done.returncode, (json.loads(done.stdout) if done.returncode == 0 else done.stderr.strip()[-400:])

    facts = {}
    for name, apk in apks.items():
        out = subprocess.run([python, "-c", "import json,sys; sys.path.insert(0,'.'); from deploy import release; "
                              "print(json.dumps(release.android_facts(sys.argv[1])))", str(apk)],
                             capture_output=True, text=True, cwd=repo, env=host, check=True)
        facts[name] = json.loads(out.stdout)
    (u.OUT / "apks.json").write_text(json.dumps(facts, indent=2) + "\n")
    code_n, code_n1 = facts["N"]["version_code"], facts["N1"]["version_code"]

    for folder in ("anj-cloud", "anj-cloud/Notes"):
        stack.dav("MKCOL", UID, folder, expected=(201, 405))
    stack.dav("PUT", UID, "anj-cloud/Notes/before.txt", data=b"before the update", headers=u.OCTETS,
              expected=(201, 204))

    # Release N, installed as from its GitHub release (#131), paired by code.
    u.adb("reverse", f"tcp:{args.port}", f"tcp:{args.port}")
    u.adb("uninstall", u.PKG, check=False)
    u.adb("install", "-g", str(apks["N"]), timeout=300)
    u.step("release N installed (release app, release key)", u.version_code() == code_n,
           version_code=u.version_code(), signer=facts["N"]["signers"])
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
    u.step("N paired by code: the first-sync screen", u.find(r"Choose what stays on this device", timeout=90) is not None)
    u.scroll_tap(r"^Notes")
    u.scroll_tap(r"^Start sync")
    u.step("N paired and up to date", u.find(r"^Up to date", timeout=120) is not None)

    # Publish: release.py refuses the APK signed with another key, then publishes N+1.
    status, refused = release_publish(apks["other"])
    u.step("release.py refuses an APK not signed with the pinned certificate",
           status != 0 and "pinned release certificate" in refused, refused=refused)
    status, published = release_publish(apks["N1"])
    u.step("release.py publishes N+1 to the review stack", status == 0, result=published)

    u.check_for_updates()
    offer = u.find(r"Version " + re.escape(facts["N1"]["version"]) + r" \(", timeout=30)
    u.step("N offers N+1 with version and size", offer is not None, shown=u.label(offer) if offer else None)

    # The package is fetched and checked while sync is idle; this first update then asks for
    # "Install unknown apps" and holds the checked file.
    u.tap(r"^Download and install$", timeout=30)
    allow = u.find(r"Allow AnJ Cloud to install its updates", timeout=300)
    u.step("after the download finished: Install unknown apps", allow is not None and not u.installer_in_front())

    # Sync busy: a large file the app keeps (Notes is ticked). Reopening the app lists the cloud
    # (decision #130 (3)) and keeps the update at the permission. Racing the update's own download
    # against the large one is left out: which finishes first is not under the run's control.
    df = u.adb("shell", "df", "-k", "/data", check=False).splitlines()[-1].split()
    size = max(1024, min(3072, int(df[3]) // 1024 - 1200))
    path = f"/var/www/html/data/{UID}/files/anj-cloud/Notes/large.bin"
    stack.compose("exec", "-T", "--user", "www-data", "nextcloud", "sh", "-c",
                  f"dd if=/dev/urandom of={path} bs=1M count={size} status=none")
    stack.occ("files:scan", f"--path={UID}/files/anj-cloud/Notes")
    u.adb("shell", "input", "keyevent", "KEYCODE_HOME")
    time.sleep(1)
    u.launch()
    syncing = u.find(r"^Syncing", timeout=90)
    u.step("a large file is downloading", syncing is not None, shown=u.label(syncing) if syncing else None,
           large_mib=size)

    # The permission is granted while the file still downloads: back in the app the checked
    # update would install now, and waits for sync instead.
    u.tap(r"^Open settings$")
    toggle = u.find(r"Allow from this source", timeout=20)
    u.step("system Install unknown apps screen for AnJ Cloud", toggle is not None)
    u.tap_node(toggle)
    u.adb("shell", "input", "keyevent", "KEYCODE_BACK")
    waiting = u.find(r"starts when files finish syncing", timeout=60)
    u.step("the install waits for sync (desktop rule, review M3)", waiting is not None and not u.installer_in_front()
           and u.version_code() == code_n, shown=u.label(waiting) if waiting else None)
    confirm = u.find(r"update this app|Do you want to update", timeout=900)
    if confirm is None and u.find(r"Update available", timeout=10) is not None:
        u.tap(r"^Download and install$")
        confirm = u.find(r"update this app|Do you want to update", timeout=900)
    u.step("Android's confirmation (user action required)", confirm is not None and u.installer_in_front(),
           focus=u.focused())
    u.tap(r"^Update$", pkg="packageinstaller")
    deadline = time.time() + 180
    while time.time() < deadline and u.version_code() != code_n1:
        time.sleep(3)
    u.step("N+1 installed over N (same certificate)", u.version_code() == code_n1, version_code=u.version_code())

    time.sleep(3)
    u.launch()
    running = u.find(r"^Up to date|^Syncing", timeout=120)
    dump = u.adb("shell", "dumpsys", "package", u.PKG, check=False)
    u.step("N+1 runs and is still paired", running is not None and u.find(r"^Pair device", timeout=3) is None
           and f"versionName={facts['N1']['version']}" in dump, shown=u.label(running) if running else None)

    # A differently signed APK through the feed: offered, discarded before any install session.
    u.adb("logcat", "-c")
    other = facts["other"]
    manifest = {"target": "android-arm64", "version": "9999.0.0", "version_code": code_n1 + 1,
                "size": other["size"], "sha256": other["sha256"], "signer_sha256": other["signers"][0]}
    path = u.OUT / "manifest-other.json"
    path.write_text(json.dumps(manifest) + "\n")
    op("release-publish", "android-arm64", str(apks["other"]), "--manifest", str(path))
    u.check_for_updates()
    if u.find(r"Update available", timeout=30) is None:
        u.step("other-signed: offered", False, screen=u.screen_text()[:600])
    u.tap(r"^Download and install$")
    front, shown = False, None
    deadline = time.time() + 300
    while time.time() < deadline:
        front = front or u.installer_in_front()
        shown = u.find(r"Update discarded", timeout=2)
        if shown is not None:
            break
    text = u.screen_text()
    u.step("differently signed APK discarded before the installer opens",
           shown is not None and re.search(r"different key", text, re.I) is not None and not front
           and not u.session_lines() and u.version_code() == code_n1,
           reason=[line for line in text.splitlines() if re.search(r"different key", line, re.I)],
           installer_seen=front, sessions=u.session_lines(), version_code=u.version_code())

    log = u.adb("logcat", "-d", check=False)
    u.step("no key, certificate or pairing code in logcat", "BEGIN CERTIFICATE" not in log
           and "PRIVATE KEY" not in log and invite["code"] not in log)


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
            log = u.adb("logcat", "-d", "-v", "brief", check=False)
            keep = [line for line in log.splitlines()
                    if re.search(r"FATAL|AndroidRuntime|E/flutter|Exception|AnjUpdater|PackageInstaller", line)]
            (u.OUT / "errors.txt").write_text("\n".join(keep[-200:]) + "\n")
            (u.OUT / "logcat-failure.txt").write_text(log)  # whole: a crash's cause comes first
        u.adb("uninstall", u.PKG, check=False)
        (u.OUT / "steps.json").write_text(json.dumps(u.STEPS, indent=2) + "\n")
    sys.exit(status)
