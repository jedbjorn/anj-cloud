#!/usr/bin/env bash
# Emulator payload for spec #28 A5 (decision #127), run by anj-emu-run, which boots the AVD in
# scope anj-test-<TAG>-<n> and tears it down:
#   ANJ_APK=<qa apk> GRANTEES=<dir with grantee-g{1,2,3}.apk> OUT=<dir> \
#     anj-emu-run a5 <n> tool/android/emu_provider.sh
# The QA app (cloud.anj.anj_cloud.qa, unpaired: its root lists local files) and three grantee test
# apps. Folder grants are taken in Android's own picker and approvals are given and revoked in the
# app's "Apps with access" screen, both driven by uiautomator. Checks, in order:
#   1. an app that picked a folder but is not approved is refused;
#   2. an approved read-write app lists, reads, appends, creates, renames (same id) and deletes;
#      a read-only app reads but cannot write;
#   3. revoking one app leaves another app's access to the same folder intact, and a descriptor
#      the revoked app already holds keeps reading until it closes it (A1 R2);
#   4. a subfolder approval is separate from its parent's: revoking the parent keeps it;
#   5. the platform grants a revoked app can no longer use are withdrawn (a parent tree that
#      still leads to an approved subfolder stays);
#   6. a single file an unapproved app picked and kept (R1) opens for it, is listed under Single
#      files in Apps with access with the app's name, and Revoke there withdraws the grant
#      (review M2).
# Each step's JSON lands in $OUT; verdicts go to $OUT/verdicts.txt; exit 0 only if all pass.
set -uo pipefail
: "${ANJ_APK:?}" "${GRANTEES:?}" "${OUT:?}" "${ADB:?}"
HERE="$(cd "$(dirname "$0")" && pwd)"
PKG=cloud.anj.anj_cloud.qa
G1=cloud.anj.anj_cloud.qa.grantee1; G2=cloud.anj.anj_cloud.qa.grantee2; G3=cloud.anj.anj_cloud.qa.grantee3
ROOT_TITLE='AnJ Cloud QA'
mkdir -p "$OUT"
: > "$OUT/verdicts.txt"
log() { printf '[%s] %s\n' "$(date +%T)" "$*" | tee -a "$OUT/session.log" >&2; }
fails=0
verdict() { # verdict <name> <python expression over j (the step JSON)> <step>
  local name="$1" expr="$2" step="$3"
  if python3 -Ic "import json,sys; j=json.load(open(sys.argv[1])); sys.exit(0 if ($expr) else 1)" "$OUT/$step.json" 2>/dev/null; then
    echo "PASS $name" | tee -a "$OUT/verdicts.txt" >&2
  else
    echo "FAIL $name ($step: $(head -c 400 "$OUT/$step.json" 2>/dev/null))" | tee -a "$OUT/verdicts.txt" >&2
    fails=$((fails + 1))
  fi
}
act() { echo "$1/cloud.anj.grantee.GranteeActivity"; }
# run <pkg> <cmd> <out> [am extras...]: start the grantee command, wait for files/out/<out>.json
run() {
  local pkg="$1" cmd="$2" save="$3"; shift 3
  $ADB shell run-as "$pkg" rm -f "files/out/$save.json" >/dev/null 2>&1
  $ADB shell am start -W -n "$(act "$pkg")" --es cmd "$cmd" --es out "$save" "$@" >/dev/null
  for _ in $(seq 1 60); do
    if $ADB shell run-as "$pkg" cat "files/out/$save.json" > "$OUT/$save.json" 2>/dev/null && [ -s "$OUT/$save.json" ]; then
      log "$save: $(head -c 700 "$OUT/$save.json")"; return 0; fi
    sleep 0.5
  done
  log "$save: NO RESULT"; echo '{"error":"no result"}' > "$OUT/$save.json"; return 1
}
dump_ui() { $ADB shell uiautomator dump /data/local/tmp/ui.xml >/dev/null 2>&1; $ADB shell cat /data/local/tmp/ui.xml 2>/dev/null; }
# tap <regex> [nth] [tries]; with SCROLL=1 it scrolls the page up between tries.
tap() {
  local re="$1" nth="${2:-0}" tries="${3:-15}" xy
  for _ in $(seq 1 "$tries"); do
    if xy=$(dump_ui | python3 -I "$HERE/ui.py" "$re" "$nth"); then $ADB shell input tap $xy; log "tapped '$re' at $xy"; return 0; fi
    if [ -n "${SCROLL:-}" ]; then $ADB shell input swipe 540 1700 540 900 300; fi
    sleep 1
  done
  dump_ui > "$OUT/ui-fail-$(date +%s).xml"; log "could not find '$re' (UI saved)"; return 1
}
ui_text() { dump_ui | python3 -I "$HERE/ui.py" --text > "$OUT/$1.txt"; log "$1: $(tr '\n' ';' < "$OUT/$1.txt" | head -c 900)"; }
# pick <grantee> <slot> <folder path, e.g. Music/Album>: the grantee opens Android's tree picker;
# uiautomator opens the roots drawer, AnJ Cloud QA, the folder, then Use this folder and Allow.
pick() {
  local g="$1" slot="$2" path="$3" try ui part
  $ADB shell run-as "$g" rm -f "files/out/pick-$slot.json" >/dev/null 2>&1
  $ADB shell am start -W -n "$(act "$g")" --es cmd pick --es slot "$slot" >/dev/null
  for try in 1 2 3; do
    tap 'Show roots' && sleep 1.5 && tap "$ROOT_TITLE" && sleep 1.5
    ui=$(dump_ui)
    # Our root shows Music, Videos and Documents; shared storage has a Music folder too.
    echo "$ui" | python3 -I "$HERE/ui.py" 'Documents' >/dev/null &&
      echo "$ui" | python3 -I "$HERE/ui.py" 'Videos' >/dev/null &&
      ! echo "$ui" | python3 -I "$HERE/ui.py" '(Download|Pictures|Alarms)' >/dev/null && break
    log "not at the AnJ Cloud root yet (try $try)"
  done
  for part in $(echo "$path" | tr '/' ' '); do tap "$part" && sleep 1; done
  tap '(?i)use this folder' && sleep 1 && tap '(?i)allow'
  for _ in $(seq 1 20); do
    if $ADB shell run-as "$g" cat "files/out/pick-$slot.json" > "$OUT/pick-$g-$slot.json" 2>/dev/null && [ -s "$OUT/pick-$g-$slot.json" ]; then
      log "pick $g $slot: $(cat "$OUT/pick-$g-$slot.json")"
      grep -q "content://$PKG.documents/tree/" "$OUT/pick-$g-$slot.json" && return 0
      log "PICK MISMATCH: $g $slot is not an AnJ Cloud tree"; return 1; fi
    sleep 0.5
  done
  log "pick $g $slot: NO RESULT"; return 1
}
# pickfile <grantee> <slot> <path, e.g. Music/loose.txt>: the grantee opens Android's document
# picker (ACTION_OPEN_DOCUMENT) at the AnJ Cloud root (EXTRA_INITIAL_URI); should the picker open
# elsewhere, uiautomator goes there through the roots drawer. Then it taps down to the file.
pickfile() {
  local g="$1" slot="$2" path="$3" part try ui
  $ADB shell run-as "$g" rm -f "files/out/pickfile-$slot.json" >/dev/null 2>&1
  $ADB shell am start -W -n "$(act "$g")" --es cmd pickfile --es slot "$slot" \
    --es initial "content://$PKG.documents/document/root" >/dev/null
  sleep 2
  for try in 1 2 3; do
    ui=$(dump_ui)
    echo "$ui" | python3 -I "$HERE/ui.py" 'Music' >/dev/null &&
      ! echo "$ui" | python3 -I "$HERE/ui.py" '(Recent files|Images|Audio)' >/dev/null && break
    log "picker not at the AnJ Cloud root yet (try $try)"
    tap 'Show roots' && sleep 2 && tap "$ROOT_TITLE" && sleep 2
  done
  for part in $(echo "$path" | tr '/' ' '); do SCROLL=1 tap "${part//./\\.}" && sleep 1; done
  for _ in $(seq 1 20); do
    if $ADB shell run-as "$g" cat "files/out/pickfile-$slot.json" > "$OUT/pickfile-$g-$slot.json" 2>/dev/null && [ -s "$OUT/pickfile-$g-$slot.json" ]; then
      log "pickfile $g $slot: $(cat "$OUT/pickfile-$g-$slot.json")"
      grep -q "content://$PKG.documents/document/" "$OUT/pickfile-$g-$slot.json" && return 0
      log "PICK MISMATCH: $g $slot is not an AnJ Cloud document"; return 1; fi
    sleep 0.5
  done
  log "pickfile $g $slot: NO RESULT"; return 1
}
open_settings() {
  $ADB shell am start -W -n "$PKG/cloud.anj.anj_cloud.MainActivity" >/dev/null
  sleep 2
  tap 'Apps with access' 0 2 && return 0 # already there
  tap 'AnJ Cloud menu' && sleep 1 && tap 'Apps with access' && sleep 1.5
}
# approve <app label> <folder label> <read|write>
approve() {
  open_settings
  tap 'Approve an app' && sleep 2
  tap "$1(\n.*)?" && sleep 1
  SCROLL=1 tap "$2" && sleep 0.5
  if [ "$3" = write ]; then SCROLL=1 tap 'Read and write(\n.*)?'; else SCROLL=1 tap 'Read only(\n.*)?'; fi
  sleep 0.5
  tap 'Approve' && sleep 1.5 && tap 'Later' && sleep 1
  log "approved $1 for $2 ($3)"
}
revoke() { # revoke <app label> <folder label>
  open_settings
  tap "Revoke $1 for $2" && sleep 1 && tap 'Revoke' && sleep 2
  log "revoked $1 for $2"
}

log "boot ${ANJ_EMU_BOOT_S:-?}s serial=${ANDROID_SERIAL:-?}"
$ADB logcat -c
# A fresh start: an earlier session cut short can leave the apps and their data on the AVD.
for p in $PKG $G1 $G2 $G3; do $ADB uninstall "$p" >/dev/null 2>&1; done
$ADB install -r -t -g "$ANJ_APK" > "$OUT/install.txt" 2>&1 || { cat "$OUT/install.txt"; exit 10; }
for g in g1 g2 g3; do $ADB install -r -t "$GRANTEES/grantee-$g.apk" >> "$OUT/install.txt" 2>&1 || exit 10; done
$ADB shell settings put global window_animation_scale 0; $ADB shell settings put global transition_animation_scale 0
$ADB shell settings put global animator_duration_scale 0
$ADB shell am start -W -n "$PKG/cloud.anj.anj_cloud.MainActivity" > "$OUT/start.txt" 2>&1
sleep 12
sleep 3
ui_text app-home
# 1. g1 picks Music in Android's picker; nothing is approved yet. (The root holds the default
#    Music, Videos and Documents folders; files are added through the provider below, since
#    run-as cannot write the app's root.)
pick $G1 music Music
run $G1 access g1-music-unapproved --es slot music
verdict 'picked but not approved: refused' "j['list']['ok'] is False and j['list']['error']=='SecurityException'" g1-music-unapproved

# 2. Approvals in Apps with access; g1 (read-write) adds the fixtures through the provider.
approve 'AnJ Grantee 1' 'Music' write
run $G1 seed g1-seed --es slot music
verdict 'approved rw app creates a folder and files' "j['ok']" g1-seed
sleep 4
pick $G2 music Music
pick $G2 album Music/Album
pick $G2 videos Videos
pick $G3 music Music
run $G3 access g3-music-unapproved --es slot music
verdict 'never-approved app that picked the folder is refused' "j['list']['ok'] is False and j['list']['error']=='SecurityException'" g3-music-unapproved
approve 'AnJ Grantee 2' 'Music' read
approve 'AnJ Grantee 2' 'Music/Album' read
ui_text settings-approved
run $G1 access g1-music-rw --es slot music --ez write true --ez create true
run $G2 access g2-music-r --es slot music --ez write true
run $G2 access g2-album-r --es slot album
run $G2 access g2-videos-not-approved --es slot videos
run $G3 access g3-music-still-unapproved --es slot music
verdict 'approved rw app lists and reads' "j['list']['ok'] and j['read']['ok'] and 'Album' in j['list']['children']" g1-music-rw
verdict 'approved rw app appends' "j['append']['ok']" g1-music-rw
verdict 'approved rw app creates, renames (stable id) and deletes' "j['create_rename_delete']['ok'] and j['create_rename_delete']['same_id']" g1-music-rw
verdict 'read-only app reads' "j['list']['ok'] and j['read']['ok']" g2-music-r
verdict 'read-only app cannot write' "j['append']['ok'] is False" g2-music-r
verdict 'approved for Music, picked Videos: Videos refused' "j['list']['ok'] is False" g2-videos-not-approved
verdict 'unapproved app still refused' "j['list']['ok'] is False" g3-music-still-unapproved
ui_text settings-connected

# 3. Revoke g1 (it holds an open descriptor); g2 keeps Music.
$ADB shell run-as $G1 rm -f files/release files/out/g1-hold.json files/out/g1-hold-held.json
$ADB shell am start -n "$(act $G1)" --es cmd hold --es slot music --es out g1-hold >/dev/null
for _ in $(seq 1 30); do $ADB shell run-as $G1 cat files/out/g1-hold-held.json > "$OUT/g1-hold-held.json" 2>/dev/null && [ -s "$OUT/g1-hold-held.json" ] && break; sleep 0.5; done
log "g1 holds: $(cat "$OUT/g1-hold-held.json" 2>/dev/null)"
revoke 'AnJ Grantee 1' 'Music'
ui_text settings-after-revoke-g1
$ADB shell run-as $G1 touch files/release
for _ in $(seq 1 30); do $ADB shell run-as $G1 cat files/out/g1-hold.json > "$OUT/g1-hold.json" 2>/dev/null && [ -s "$OUT/g1-hold.json" ] && break; sleep 0.5; done
log "g1 hold result: $(cat "$OUT/g1-hold.json" 2>/dev/null)"
run $G1 access g1-music-revoked --es slot music
run $G2 access g2-music-after-g1-revoke --es slot music
run $G1 persisted g1-persisted-after-revoke
verdict 'revoked app refused' "j['list']['ok'] is False" g1-music-revoked
verdict 'other app on the same folder keeps access' "j['list']['ok'] and j['read']['ok']" g2-music-after-g1-revoke
verdict 'open descriptor survives revoke; a new open is refused' "j['read_held_descriptor']['ok'] and j['reopen']['ok'] is False" g1-hold
cp "$OUT/pick-$G1-music.json" "$OUT/g1-pick-music.json" 2>/dev/null; cp "$OUT/pick-$G2-album.json" "$OUT/g2-pick-album.json" 2>/dev/null
cp "$OUT/pick-$G2-music.json" "$OUT/g2-pick-music.json" 2>/dev/null
uri() { python3 -Ic "import json,sys; print(json.load(open(sys.argv[1])).get('uri'))" "$OUT/$1.json" 2>/dev/null; }
G1_MUSIC=$(uri g1-pick-music); G2_MUSIC=$(uri g2-pick-music); G2_ALBUM=$(uri g2-pick-album)
log "tree URIs: g1 Music $G1_MUSIC, g2 Music $G2_MUSIC, g2 Album $G2_ALBUM"
verdict 'revoked app platform grant withdrawn' "'$G1_MUSIC' != 'None' and all(p['uri'] != '$G1_MUSIC' for p in j['persisted'])" g1-persisted-after-revoke
python3 -Ic "import sys; t=open(sys.argv[1]).read(); sys.exit(0 if ('Revoked' in t) else 1)" "$OUT/settings-after-revoke-g1.txt" \
  && echo "PASS settings shows Revoked" | tee -a "$OUT/verdicts.txt" >&2 || { echo "FAIL settings shows Revoked" | tee -a "$OUT/verdicts.txt" >&2; fails=$((fails+1)); }

# 4. Subfolder: revoking g2's Music approval keeps its separate Music/Album approval.
run $G2 persisted g2-persisted-before
revoke 'AnJ Grantee 2' 'Music'
run $G2 access g2-music-revoked --es slot music
run $G2 access g2-album-kept --es slot album
run $G2 persisted g2-persisted-after
verdict 'parent revoked: parent refused' "j['list']['ok'] is False" g2-music-revoked
verdict 'subfolder approval kept' "j['list']['ok'] and j['read']['ok']" g2-album-kept
# g2's Music tree still leads to its approved Album, so that platform grant stays as well.
verdict 'subfolder platform grant kept' "any(p['uri'] == '$G2_ALBUM' for p in j['persisted'])" g2-persisted-after

# 6. A single file kept by an app that has no folder approval (R1, review M2).
pickfile $G3 loose Music/loose.txt
run $G3 readfile g3-file-kept --es slot loose
run $G3 persisted g3-persisted-file
G3_FILE=$(python3 -Ic "import json,sys; print(json.load(open(sys.argv[1])).get('uri'))" "$OUT/pickfile-$G3-loose.json" 2>/dev/null)
log "g3 file URI: $G3_FILE"
verdict 'single file kept by an unapproved app opens (R1)' "j['read']['ok']" g3-file-kept
verdict 'the kept file grant is persisted' "'$G3_FILE' != 'None' and any(p['uri'] == '$G3_FILE' for p in j['persisted'])" g3-persisted-file
$ADB shell input keyevent BACK; sleep 1
open_settings
SCROLL=1 tap 'Single files' 0 6 || true
ui_text settings-single-files
python3 -Ic "import sys; t=open(sys.argv[1]).read(); sys.exit(0 if ('Music/loose.txt' in t and 'AnJ Grantee 3' in t) else 1)" "$OUT/settings-single-files.txt" \
  && echo "PASS kept file listed with its app" | tee -a "$OUT/verdicts.txt" >&2 || { echo "FAIL kept file listed with its app" | tee -a "$OUT/verdicts.txt" >&2; fails=$((fails+1)); }
SCROLL=1 tap 'Revoke file Music/loose\.txt' && sleep 1 && tap 'Revoke' && sleep 2
log "revoked the kept file"
run $G3 readfile g3-file-revoked --es slot loose
run $G3 persisted g3-persisted-file-after
verdict 'revoked kept file refused' "j['read']['ok'] is False" g3-file-revoked
verdict 'kept file platform grant withdrawn' "all(p['uri'] != '$G3_FILE' for p in j['persisted'])" g3-persisted-file-after
ui_text settings-after-file-revoke
python3 -Ic "import sys; t=open(sys.argv[1]).read(); sys.exit(0 if 'Music/loose.txt' not in t else 1)" "$OUT/settings-after-file-revoke.txt" \
  && echo "PASS revoked file no longer listed" | tee -a "$OUT/verdicts.txt" >&2 || { echo "FAIL revoked file no longer listed" | tee -a "$OUT/verdicts.txt" >&2; fails=$((fails+1)); }

ui_text settings-final
$ADB shell screencap -p /data/local/tmp/settings.png && $ADB pull /data/local/tmp/settings.png "$OUT/settings-final.png" >/dev/null 2>&1

$ADB logcat -d > "$OUT/logcat.txt" 2>/dev/null
grep -E 'FATAL EXCEPTION|AndroidRuntime' "$OUT/logcat.txt" | grep -i 'anj' > "$OUT/crashes.txt" || true
grep -E 'avc: +denied' "$OUT/logcat.txt" | grep -E 'cloud\.anj\.anj_cloud\.qa' > "$OUT/denials.txt" || true
for p in $PKG $G1 $G2 $G3; do $ADB uninstall "$p" >/dev/null 2>&1; done
log "verdicts: $(grep -c PASS "$OUT/verdicts.txt") pass, $fails fail; crashes $(wc -l < "$OUT/crashes.txt"), denials $(wc -l < "$OUT/denials.txt")"
[ "$fails" -eq 0 ] && [ ! -s "$OUT/crashes.txt" ]
