#!/usr/bin/env bash
# Emulator payload for spec #28 A2 (run by anj-emu-run, which boots the AVD in scope
# anj-test-<TAG>-<n> and tears it down). Installs an APK built by build_apk.sh with
# -t integration_test/android_engine_test.dart, starts it (the integration binding runs
# the suites on start-up), waits for the result in logcat and copies the evidence:
#   ANJ_APK=<apk> OUT=<dir> anj-emu-run a2 <n> tool/android/emu_engine.sh
# Also records the manifest's backup posture (acceptance row 15) and a bmgr attempt.
set -uo pipefail
: "${ANJ_APK:?}" "${OUT:?}" "${ADB:?}"
PKG=cloud.anj.anj_cloud.qa
mkdir -p "$OUT"
"$ADB" logcat -c
"$ADB" shell df -h /data > "$OUT/df.txt"
"$ADB" install -r -t "$ANJ_APK" > "$OUT/install.txt" 2>&1 || { cat "$OUT/install.txt"; exit 10; }
"$ADB" shell am start -W -n "$PKG/cloud.anj.anj_cloud.MainActivity" > "$OUT/start.txt" 2>&1
deadline=$(( $(date +%s) + ${ANJ_RUN_TIMEOUT:-840} ))
status=timeout
while [ "$(date +%s)" -lt "$deadline" ]; do
  "$ADB" logcat -d -s flutter:I > "$OUT/flutter.log" 2>/dev/null
  if grep -q 'All tests passed!' "$OUT/flutter.log"; then status=passed; break; fi
  if grep -q 'Some tests failed' "$OUT/flutter.log"; then status=failed; break; fi
  "$ADB" shell pidof "$PKG" >/dev/null 2>&1 || { status=died; break; }
  sleep 10
done
"$ADB" logcat -d > "$OUT/logcat.txt" 2>/dev/null
grep -E 'avc: denied|SIGSYS|seccomp' "$OUT/logcat.txt" | grep -i "$PKG\|anj" > "$OUT/denials.txt" || true
"$ADB" shell dumpsys package "$PKG" | grep -E 'flags=|privateFlags=|versionName|dataDir' > "$OUT/package.txt"
"$ADB" shell bmgr backupnow "$PKG" > "$OUT/bmgr.txt" 2>&1 || true
"$ADB" shell run-as "$PKG" ls -laR /data/user/0/$PKG > "$OUT/data-tree.txt" 2>&1 || true
"$ADB" uninstall "$PKG" > /dev/null 2>&1 || true
echo "status=$status" | tee "$OUT/status.txt"
[ "$status" = passed ]
