#!/usr/bin/env bash
# Emulator payload for spec #28 A4 (run by anj-emu-run, which boots the AVD in scope
# anj-test-<TAG>-<n> and tears it down):
#   ANJ_APK_TEST=<apk built with -t integration_test/android_background_test.dart> \
#   ANJ_APK_APP=<plain debug apk> OUT=<dir> [ANJ_PHASES=123] anj-emu-run a4 <n> tool/android/emu_background.sh
#
# 1. Integration APK, POST_NOTIFICATIONS granted: progress through the dataSync service and
#    attention notifications (dumpsys), the drained queue clears them, files waiting for
#    Wi-Fi enqueue the unmetered follow-up work; then "Wi-Fi only" with real svc wifi
#    toggles (cellular stays on).
# 2. Integration APK reinstalled without the grant: the service still runs, nothing posted.
# 3. The app itself: the unique periodic WorkManager job (15 min, connectivity constraint),
#    then a forced run after the process was killed in the background: a cold start
#    answered by the engine with a full verification pass (decision #130 (3)).
set -uo pipefail
: "${ANJ_APK_TEST:?}" "${ANJ_APK_APP:?}" "${OUT:?}" "${ADB:?}"
PKG=cloud.anj.anj_cloud.qa
mkdir -p "$OUT"
dsh() { "$ADB" shell "$@"; }

marker() { # marker <text> [seconds]
  local deadline=$(( $(date +%s) + ${2:-240} ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    "$ADB" logcat -d -s flutter:I > "$OUT/flutter.tmp" 2>/dev/null
    grep -q "ANJ-A4 $1" "$OUT/flutter.tmp" && return 0
    grep -qE 'Some tests failed|All tests passed' "$OUT/flutter.tmp" && return 1
    sleep 1
  done
  echo "missed marker: $1" >&2
  return 1
}
go() { dsh run-as "$PKG" touch "files/a4-go-$1"; }
finish() { # finish <phase>: wait for the suite result, keep its log
  local deadline=$(( $(date +%s) + 300 )) status=timeout
  while [ "$(date +%s)" -lt "$deadline" ]; do
    "$ADB" logcat -d -s flutter:I > "$OUT/$1-flutter.log" 2>/dev/null
    grep -q 'All tests passed!' "$OUT/$1-flutter.log" && { status=passed; break; }
    grep -q 'Some tests failed' "$OUT/$1-flutter.log" && { status=failed; break; }
    sleep 2
  done
  "$ADB" logcat -d > "$OUT/$1-logcat.txt" 2>/dev/null
  echo "$1=$status" | tee -a "$OUT/status.txt"
}
notify_phase() { # notify_phase <phase>
  marker notify-posted || return 1
  sleep 2
  dsh dumpsys notification --noredact > "$OUT/$1-notification-posted.txt"
  dsh dumpsys activity services "$PKG" > "$OUT/$1-services-posted.txt"
  go notify
  marker notify-cleared || return 1
  sleep 3
  dsh dumpsys notification --noredact > "$OUT/$1-notification-cleared.txt"
  dsh dumpsys activity services "$PKG" > "$OUT/$1-services-cleared.txt"
  dsh dumpsys jobscheduler "$PKG" > "$OUT/$1-jobs.txt"
  go cleared
}

: > "$OUT/status.txt"
PHASES="${ANJ_PHASES:-123}"
dsh svc data enable; dsh svc wifi enable; sleep 3
dsh dumpsys connectivity | grep -E 'Active default network|NetworkAgentInfo' | head -5 > "$OUT/connectivity-start.txt"

if [[ $PHASES == *1* ]]; then
# 1. granted
"$ADB" install -r -t -g "$ANJ_APK_TEST" > "$OUT/install-test.txt" 2>&1 || { cat "$OUT/install-test.txt"; exit 10; }
"$ADB" logcat -c
dsh am start -n "$PKG/cloud.anj.anj_cloud.MainActivity" > /dev/null
notify_phase granted
if marker net-ready; then
  dsh svc wifi disable
  marker net-held && { dsh dumpsys connectivity | grep -E 'Active default network' > "$OUT/connectivity-cellular.txt"; dsh svc wifi enable; }
  marker net-released && dsh svc wifi disable
  marker net-any && dsh svc wifi enable
fi
finish granted
"$ADB" uninstall "$PKG" > /dev/null 2>&1

fi
if [[ $PHASES == *2* ]]; then
# 2. denied (fresh install without -g; the first-open request stays unanswered)
"$ADB" install -r -t "$ANJ_APK_TEST" > /dev/null 2>&1 || exit 11
"$ADB" logcat -c
dsh am start -n "$PKG/cloud.anj.anj_cloud.MainActivity" > /dev/null
notify_phase denied
finish denied
dsh dumpsys package "$PKG" | grep -E 'POST_NOTIFICATIONS' > "$OUT/denied-permission.txt"
"$ADB" uninstall "$PKG" > /dev/null 2>&1

fi
if [[ $PHASES == *3* ]]; then
# 3. the app: periodic work, forced cold-start run
"$ADB" install -r -t -g "$ANJ_APK_APP" > /dev/null 2>&1 || exit 12
"$ADB" logcat -c
dsh am start -W -n "$PKG/cloud.anj.anj_cloud.MainActivity" > "$OUT/app-start.txt" 2>&1
sleep 20
"$ADB" logcat -d > "$OUT/app-start-logcat.txt" 2>/dev/null   # the periodic work's first run
dsh dumpsys jobscheduler "$PKG" > "$OUT/app-jobs.txt"
dsh input keyevent KEYCODE_HOME; sleep 3
# SIGKILL as the app's own uid, as the OS reclaims a cached process. Not `am kill`: API 36
# records that as a user request, which WorkManager's ForceStopRunnable treats as a force
# stop, cancelling and re-creating every job (observed: the forced run never started).
dsh run-as "$PKG" kill -9 "$(dsh pidof "$PKG" | tr -d '\r')"; sleep 3
echo "pid-after-kill=$(dsh pidof "$PKG" | tr -d '\r')" | tee -a "$OUT/status.txt"
dsh dumpsys jobscheduler "$PKG" > "$OUT/app-jobs-after-kill.txt"
# API 34+: WorkManager's jobs live in namespace androidx.work.systemjobscheduler.
line=$(grep -E "^  JOB [^ ]*u0a[0-9]+/[0-9]+: .*$PKG/androidx.work" "$OUT/app-jobs-after-kill.txt" | head -1)
job=$(sed -E 's|^  JOB [^ ]*u0a[0-9]+/([0-9]+):.*|\1|' <<<"$line")
ns=$(sed -nE 's|^  JOB ([^ :]+):u0a.*|\1|p' <<<"$line")
echo "job=$job namespace=${ns:-none}" | tee -a "$OUT/status.txt"
# WorkManager refuses a periodic run forced before its period ("executed before schedule"):
# move the wall clock past it first.
dsh settings put global auto_time 0
dsh cmd alarm set-time "$(( ($(date +%s) + 17 * 60) * 1000 ))" > "$OUT/app-set-time.txt" 2>&1
"$ADB" logcat -c
if [ -n "$job" ]; then
  dsh cmd jobscheduler run -f ${ns:+-n "$ns"} "$PKG" "$job" > "$OUT/app-run.txt" 2>&1
  deadline=$(( $(date +%s) + 180 )); run=missing
  while [ "$(date +%s)" -lt "$deadline" ]; do
    "$ADB" logcat -d -s AnjSyncWorker:I > "$OUT/app-worker.log" 2>/dev/null
    grep -q 'AnjSyncWorker: run' "$OUT/app-worker.log" && { run=answered; break; }
    sleep 2
  done
  echo "forced-run=$run" | tee -a "$OUT/status.txt"
  "$ADB" logcat -d > "$OUT/app-logcat.txt" 2>/dev/null
fi
"$ADB" uninstall "$PKG" > /dev/null 2>&1
fi
cat "$OUT/status.txt"
ok=0
[[ $PHASES != *1* ]] || grep -q 'granted=passed' "$OUT/status.txt" || ok=1
[[ $PHASES != *2* ]] || grep -q 'denied=passed' "$OUT/status.txt" || ok=1
[[ $PHASES != *3* ]] || grep -q 'forced-run=answered' "$OUT/status.txt" || ok=1
exit $ok
