#!/usr/bin/env bash
# Emulator payload for spec #28 A6 (run by anj-emu-run, which boots the AVD in scope
# anj-test-<TAG>-<n> and tears it down): the phone layout screenshot session. Installs an
# APK built by build_apk.sh with -t integration_test/phone_layout_screens_test.dart, then
# for each display configuration sets size, density, font scale and rotation, starts the
# app, captures the screen at every `ANJ-A6 SHOT <name>` line and acknowledges it with
# files/ack-<name>. The AVD's display and font settings are restored afterwards, even on
# failure, and the app is uninstalled. The headless (-no-window) emulator does not rotate
# its display (user-rotation lock is accepted but the display stays 1080x2400), so landscape
# is the Pixel 7's landscape viewport from a swapped display size, 2400x1080 at 420 dpi.
#   ANJ_APK=<apk> OUT=<dir> [ANJ_LAYOUT_ONLY=<name part>] anj-emu-run a6 <n> tool/android/emu_layout.sh
set -uo pipefail
: "${ANJ_APK:?}" "${OUT:?}" "${ADB:?}"
PKG=cloud.anj.anj_cloud.qa
mkdir -p "$OUT"
# stdin from /dev/null: adb would otherwise read the configuration list below.
sh() { "$ADB" shell "$@" < /dev/null | tr -d '\r'; }
orig_font=$(sh settings get system font_scale)
orig_rot=$(sh settings get system user_rotation)
orig_acc=$(sh settings get system accelerometer_rotation)
restore() {
  set +e
  sh wm size reset; sh wm density reset
  sh settings put system font_scale "${orig_font/null/1.0}"
  sh settings put system user_rotation "${orig_rot/null/0}"
  sh settings put system accelerometer_rotation "${orig_acc/null/1}"
  sh wm user-rotation free
  "$ADB" uninstall "$PKG" > /dev/null 2>&1
  { echo "restored: font_scale=$(sh settings get system font_scale)" \
      "user_rotation=$(sh settings get system user_rotation)"; sh wm size; sh wm density; } \
    > "$OUT/restored.txt"
}
trap restore EXIT
"$ADB" install -r -t "$ANJ_APK" > "$OUT/install.txt" 2>&1 || { cat "$OUT/install.txt"; exit 10; }
sh settings put system accelerometer_rotation 0
overall=0
# name  size(px or reset)  density(dpi or reset)  font_scale  rotation
while read -r name size density font rot; do
  case "$name" in *"${ANJ_LAYOUT_ONLY:-}"*) ;; *) continue;; esac
  dir="$OUT/$name"; mkdir -p "$dir"
  sh am force-stop "$PKG"
  sh wm size "$size"; sh wm density "$density"
  sh settings put system font_scale "$font"
  sh settings put system user_rotation "$rot"
  sh wm user-rotation lock "$rot"   # Android 16 honours this, not the setting alone
  sleep 3
  { sh wm size; sh wm density; echo "font_scale=$(sh settings get system font_scale) rotation=$rot"; } \
    > "$dir/display.txt"
  sh dumpsys window displays < /dev/null | grep -m1 -o 'cur=[0-9x]*' >> "$dir/display.txt"
  "$ADB" logcat -c < /dev/null
  sh am start -W -n "$PKG/cloud.anj.anj_cloud.MainActivity" > "$dir/start.txt" 2>&1
  deadline=$(( $(date +%s) + ${ANJ_RUN_TIMEOUT:-300} ))
  status=timeout; seen=" "
  while [ "$(date +%s)" -lt "$deadline" ]; do
    log=$("$ADB" logcat -d -s flutter:I < /dev/null 2>/dev/null)
    for label in $(printf '%s\n' "$log" | sed -n 's/.*ANJ-A6 SHOT \([0-9a-z-]*\).*/\1/p'); do
      case "$seen" in *" $label "*) continue;; esac
      "$ADB" exec-out screencap -p < /dev/null > "$dir/$label.png"
      sh run-as "$PKG" touch "files/ack-$label"
      seen="$seen$label "
    done
    if printf '%s' "$log" | grep -q 'All tests passed!'; then status=passed; break; fi
    if printf '%s' "$log" | grep -q 'Some tests failed'; then status=failed; break; fi
    sh pidof "$PKG" > /dev/null || { status=died; break; }
    sleep 0.5
  done
  "$ADB" logcat -d < /dev/null > "$dir/logcat.txt" 2>/dev/null
  echo "$name status=$status shots=$(ls "$dir"/*.png 2>/dev/null | wc -l)" | tee -a "$OUT/status.txt"
  [ "$status" = passed ] || overall=1
done <<'CONFIGS'
pixel7-411x914 reset reset 1.0 0
phone-360x800 1080x2400 480 1.0 0
phone-360x800-font1.3 1080x2400 480 1.3 0
pixel7-landscape-914x411 2400x1080 reset 1.0 0
CONFIGS
exit "$overall"
