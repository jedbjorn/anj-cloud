#!/usr/bin/env bash
# Emulator payload (run by anj-emu-run): CPU of the QA app open and idle with a local
# library (decision #130 (3)). For each APK given: install, start once (the Android entry
# creates the root), stop, write ANJ_IDLE_MIB MiB of files into the root through run-as,
# start again, let the start-up verification finish (ANJ_IDLE_SETTLE s), then read the
# process's utime+stime over ANJ_IDLE_SPAN s of idleness.
#   OUT=<dir> anj-emu-run a2 <n> tool/android/emu_idle.sh <label>=<apk> [<label>=<apk> ...]
set -uo pipefail
: "${OUT:?}" "${ADB:?}"
PKG=cloud.anj.anj_cloud.qa
MIB=${ANJ_IDLE_MIB:-1000}; SETTLE=${ANJ_IDLE_SETTLE:-60}; SPAN=${ANJ_IDLE_SPAN:-120}
mkdir -p "$OUT"
ticks() { "$ADB" shell run-as "$PKG" cat /proc/"$1"/stat | awk '{print $14+$15}'; }
for spec in "$@"; do
  label=${spec%%=*}; apk=${spec#*=}
  "$ADB" install -r -t "$apk" > "$OUT/$label-install.txt" 2>&1 || { cat "$OUT/$label-install.txt"; exit 10; }
  "$ADB" shell am start -W -n "$PKG/cloud.anj.anj_cloud.MainActivity" > /dev/null 2>&1
  sleep 15
  "$ADB" shell am force-stop "$PKG"
  # One string for the device shell, so run-as gets the whole script as sh -c's argument.
  "$ADB" shell "run-as $PKG sh -c 'mkdir -p files/anj-cloud/Pictures; i=0; while [ \$i -lt $((MIB / 5)) ]; do dd if=/dev/urandom of=files/anj-cloud/Pictures/p\$i.bin bs=1048576 count=5 2>/dev/null; i=\$((i+1)); done; du -sm files/anj-cloud'" > "$OUT/$label-fixture.txt" 2>&1
  "$ADB" shell am start -W -n "$PKG/cloud.anj.anj_cloud.MainActivity" > /dev/null 2>&1
  sleep "$SETTLE"
  pid=$("$ADB" shell pidof "$PKG" | tr -d '\r')
  t0=$(ticks "$pid"); s0=$(date +%s%3N)
  sleep "$SPAN"
  t1=$(ticks "$pid"); s1=$(date +%s%3N)
  awk -v a="$t0" -v b="$t1" -v w0="$s0" -v w1="$s1" -v l="$label" -v m="$MIB" \
    'BEGIN { cpu=(b-a)/100; wall=(w1-w0)/1000; printf "%s library_mib=%d cpu_before_idle_s=%.2f idle_wall_s=%.1f cpu_s=%.2f cpu_pct=%.1f\n", l, m, a/100, wall, cpu, 100*cpu/wall }' \
    | tee -a "$OUT/idle.txt"
  "$ADB" shell dumpsys cpuinfo | grep -i "$PKG" > "$OUT/$label-cpuinfo.txt" 2>&1
  grep -q "^[0-9]" "$OUT/$label-fixture.txt" || { echo "fixture not written" >&2; exit 11; }
  "$ADB" uninstall "$PKG" > /dev/null 2>&1 || true
done
