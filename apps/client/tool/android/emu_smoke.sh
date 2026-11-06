#!/usr/bin/env bash
# Emulator payload (run by anj-emu-run): installs the QA app (tool/android/build_apk.sh),
# starts it, and records what the Android entry created in app-private storage: the
# profile (lock, manifest), the root and its staging (spec #28 Storage and Access), the
# process list (one process) and the app's flutter log lines.
#   ANJ_APK=<apk> OUT=<dir> anj-emu-run a2 <n> tool/android/emu_smoke.sh
set -uo pipefail
: "${ANJ_APK:?}" "${OUT:?}" "${ADB:?}"
PKG=cloud.anj.anj_cloud.qa
mkdir -p "$OUT"
"$ADB" logcat -c
"$ADB" install -r -t "$ANJ_APK" > "$OUT/install.txt" 2>&1 || { cat "$OUT/install.txt"; exit 10; }
"$ADB" shell am start -W -n "$PKG/cloud.anj.anj_cloud.MainActivity" > "$OUT/start.txt" 2>&1
sleep "${ANJ_SMOKE_WAIT:-20}"
"$ADB" shell run-as "$PKG" ls -la files files/anj-cloud files/anj-profile/default > "$OUT/files.txt" 2>&1
"$ADB" shell run-as "$PKG" sh -c 'ls -d files/.anj-cloud-*' >> "$OUT/files.txt" 2>&1
"$ADB" shell ps -A -o PID,NAME | grep "$PKG" > "$OUT/ps.txt" 2>&1
"$ADB" logcat -d -s flutter:* AndroidRuntime:E > "$OUT/flutter.log" 2>&1
"$ADB" logcat -d | grep -E 'avc: denied' | grep -E "$PKG|untrusted_app" > "$OUT/denials.txt" || true
# Going home does not end the process; the one engine keeps running.
"$ADB" shell input keyevent KEYCODE_HOME; sleep 3
"$ADB" shell pidof "$PKG" > "$OUT/after-home.txt" 2>&1
"$ADB" uninstall "$PKG" > /dev/null 2>&1 || true
grep -q 'anj-cloud' "$OUT/files.txt" && ! grep -q 'FATAL EXCEPTION' "$OUT/flutter.log"
