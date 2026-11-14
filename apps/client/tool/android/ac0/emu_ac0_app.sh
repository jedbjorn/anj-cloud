#!/usr/bin/env bash
# Spec #52 AC0 on the emulator, in the app (task #44). Payload of anj-emu-run:
#   ANJ_APK=<apk built with -t integration_test/android_phone_folders_ac0_test.dart> OUT=<dir> \
#     anj-emu-run <TAG> <n> tool/android/ac0/emu_ac0_app.sh
# Grants All files access, starts the probe, answers its hand-offs (media-library
# queries before and after a scan request, changes by another uid through adb shell,
# revocation while it runs), starts a fresh install without access, and compares the
# phone folders' st_dev and inode across a reboot. Evidence: $OUT/ac0.txt (the ANJ-AC0
# lines), $OUT/media.txt, $OUT/reboot.txt, $OUT/logcat-*.txt.
# The media library is read as adb shell (another uid) through `content query`, the
# view other apps get; a scan request is MediaStore's `scan_file` call, which is what
# MediaScannerConnection.scanFile sends.
set -uo pipefail
: "${ANJ_APK:?}" "${OUT:?}" "${ADB:?}"
PKG=cloud.anj.anj_cloud.qa
mkdir -p "$OUT"
sh() { "$ADB" shell "$@" | tr -d '\r'; }
scan() { sh content call --uri content://media/external/file --method scan_file --arg "$1" > /dev/null 2>&1; }
q() { sh content query --uri "$1" --projection "$2" --where "\"_data LIKE '$3'\""; }
lines() { "$ADB" logcat -d -s flutter:I 2>/dev/null | tr -d '\r' | sed -n 's/.*ANJ-AC0 //p'; }
wait_line() { # wait_line <prefix> <seconds>: prints the detail of the first matching line
  local end=$(( $(date +%s) + $2 ))
  while [ "$(date +%s)" -lt "$end" ]; do
    local hit; hit="$(lines | grep -m1 "^$1 " || true)"
    [ -n "$hit" ] && { echo "${hit#* * }"; return 0; }
    sh pidof "$PKG" > /dev/null || { echo "app died"; return 1; }
    sleep 1
  done
  return 1
}
{
  sh getprop ro.build.fingerprint
  echo "sdk $(sh getprop ro.build.version.sdk)"
  sh "grep -E ' /storage/emulated| /mnt/user/0/emulated| /data/media' /proc/mounts"
  echo "casefold=$(sh getprop external_storage.casefold.enabled) sdcardfs=$(sh getprop external_storage.sdcardfs.enabled) passthrough=$(sh getprop persist.sys.fuse.passthrough.enable) fuse_bpf=$(sh getprop ro.fuse.bpf.is_running)"
} > "$OUT/device.txt" 2>&1
: > "$OUT/media.txt"
run() { # run <label> <appops mode>: a fresh install each time
  "$ADB" uninstall "$PKG" > /dev/null 2>&1
  "$ADB" install -r -t "$ANJ_APK" > "$OUT/install.txt" 2>&1 || { cat "$OUT/install.txt"; exit 10; }
  sh pm grant "$PKG" android.permission.POST_NOTIFICATIONS
  sh "mkdir -p /storage/emulated/0/Music/anj-ac0-seen; echo s > /storage/emulated/0/Music/anj-ac0-seen/other.txt; cp /storage/emulated/0/Music/anj-ac0-seen/other.txt /storage/emulated/0/Music/anj-ac0-seen/song.mp3"
  "$ADB" logcat -c
  sh appops set "$PKG" MANAGE_EXTERNAL_STORAGE "$2"
  echo "== $1: $(sh appops get "$PKG" MANAGE_EXTERNAL_STORAGE)" >> "$OUT/ac0.txt"
  sh am start -W -n "$PKG/cloud.anj.anj_cloud.MainActivity" >> "$OUT/ac0.txt" 2>&1
  if [ "$2" = allow ]; then
    if work_stage="$(wait_line wait-media 240)"; then
      work="${work_stage%% *}"; stage="${work_stage#* }"
      sleep 4
      { echo "# the app's path write of a WAV, 4 s after close, as another app sees it"
        q content://media/external/audio/media _id:_data "$work/probe-indexed.wav"
        scan "$work/probe-indexed.wav"; sleep 2
        echo "# after a scan request for exactly that path"
        q content://media/external/audio/media _id:_data "$work/probe-indexed.wav"
        echo "# staged under .nomedia: $stage (expect no audio row)"
        q content://media/external/audio/media _id:_data "$stage/%"
      } >> "$OUT/media.txt" 2>&1
      sh touch "$work/.go-media1"
      wait_line wait-media2 60 > /dev/null; sleep 4
      { echo "# renamed from .nomedia staging into $work (renameat2 NOREPLACE), 4 s later"
        q content://media/external/audio/media _id:_data "$work/renamed-in.wav"
        scan "$work/renamed-in.wav"; sleep 2
        echo "# after a scan request for the new path"
        q content://media/external/audio/media _id:_data "$work/renamed-in.wav"
      } >> "$OUT/media.txt" 2>&1
      sh touch "$work/.go-media2"
      wait_line wait-other 60 > /dev/null
      sh "echo other > '$work/by-shell.txt'"; sleep 1
      sh "echo more >> '$work/by-shell.txt'"
      sh "mv '$work/by-shell.txt' '$work/by-shell-renamed.txt'"
      sh "rm '$work/by-shell-renamed.txt'"
      sh "echo kept > '$work/kept-by-shell.txt'"
      sh "mkdir '$work/shell-dir'"
      sh touch "$work/.go-other"
      wait_line wait-revoke 60 > /dev/null
      sh appops set "$PKG" MANAGE_EXTERNAL_STORAGE deny
      sleep 2
      echo "app alive after revoke: $(sh pidof "$PKG" || echo no)" >> "$OUT/ac0.txt"
      wait_line done 60 > /dev/null
      { echo "# a phone file deleted by path, then a scan request for the gone path"
        sh "rm '$work/renamed-in.wav'"; sleep 2
        q content://media/external/audio/media _id:_data "$work/renamed-in.wav"
        scan "$work/renamed-in.wav"; sleep 2
        echo "# after the scan request"
        q content://media/external/audio/media _id:_data "$work/renamed-in.wav"
        echo "# owners and modes as adb shell sees them"; sh "ls -lan '$work' | head -8"
      } >> "$OUT/media.txt" 2>&1
    else
      echo "never reached wait-media" >> "$OUT/ac0.txt"
    fi
  else
    wait_line symlink 120 > /dev/null || true
    sleep 5
  fi
  lines >> "$OUT/ac0.txt"
  "$ADB" logcat -d > "$OUT/logcat-$1.txt" 2>/dev/null
  sh am force-stop "$PKG"
}
run with-access allow
sleep 3
run without-access deny
# Identity of the phone folders across a reboot: the FUSE volume has no on-disk fsid,
# so the boundary keys it by st_dev; do st_dev and the inode survive a reboot?
{
  echo "# identity before reboot (st_dev inode)"
  sh "stat -c '%d %i %n' /storage/emulated/0/Music /storage/emulated/0/Movies /storage/emulated/0/Documents"
  "$ADB" reboot
  "$ADB" wait-for-device
  until [ "$(sh getprop sys.boot_completed)" = 1 ]; do sleep 2; done
  sleep 5
  echo "# identity after reboot"
  sh "stat -c '%d %i %n' /storage/emulated/0/Music /storage/emulated/0/Movies /storage/emulated/0/Documents"
} > "$OUT/reboot.txt" 2>&1
grep -E 'avc: denied|SIGSYS' "$OUT"/logcat-*.txt | grep -i "$PKG\|anj\|untrusted" > "$OUT/denials.txt" || true
sh "rm -rf /storage/emulated/0/Music/anj-ac0-* /storage/emulated/0/Music/anj-ac0-seen /storage/emulated/0/Documents/anj-ac0-* /storage/emulated/0/.anj-cloud-staging /storage/emulated/0/Android/media/$PKG"
"$ADB" uninstall "$PKG" > /dev/null 2>&1 || true
cat "$OUT/ac0.txt" "$OUT/media.txt" "$OUT/reboot.txt"
