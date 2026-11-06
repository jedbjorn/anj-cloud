#!/bin/zsh
# macOS adapter checks of spec #31 M3 (acceptance rows 8, 9, 11, 12, 13).
# Runs ON mac-test from the client directory tool/macos/mac_test.sh sent
# over, after tool/macos/check_macos.sh (analyze, native, mac-side tests,
# builds). Without sudo.
#
#   tool/macos/check_m3.sh [--evidence <dir>] [--idle <minutes>] [--skip-build]
#
# 1. flutter build macos --debug, then tool/macos/session_check.sh (menu-bar
#    item, Close/reopen/Dock icon, Quit sources and the lock, --background,
#    Keychain unavailable from a direct launch; --idle adds the idle sample)
#    then tool/macos/keychain_probe.sh (what SSH and the GUI session see of
#    the login keychain)
# 2. a FAT disk image (hdiutil, no sudo) for the non-APFS refusal, and a
#    keychain item created by /usr/bin/security (an item this build does not
#    own, as after an update)
# 3. integration_test/macos_adapters_test.dart inside the real app, twice:
#    from a gui/<uid> job (login keychain, custody, a locked dedicated
#    keychain through the Debug-only override, menu bar, window, label,
#    root location, ~/anj-cloud) and straight from SSH (no login
#    keychain: unavailable)
# 4. no OpenSSL dependence (row 9): tool/macos/no_openssl.sh
# 5. cleanup: the image is detached and deleted, every test keychain item
#    is deleted, and the foreign item is shown unchanged first
# Exit 0 only when every step passes. Evidence goes to <dir> (default
# build/macos-m3).
set -u
cd "${0:A:h}/../.."
evidence=build/macos-m3
idle=0
build=1
while (( $# )); do
  case $1 in
    --evidence) evidence=$2; shift 2 ;;
    --idle) idle=$2; shift 2 ;;
    --skip-build) build=0; shift ;;
    *) echo "usage: check_m3.sh [--evidence <dir>] [--idle <minutes>] [--skip-build]" >&2; exit 64 ;;
  esac
done
mkdir -p "$evidence"; evidence=${evidence:A}
export FLUTTER_SUPPRESS_ANALYTICS=true DART_SUPPRESS_ANALYTICS=true
# A temporary directory with no symlink in its path: macOS's default
# (/var/folders, under /var -> /private/var) makes the root opens refuse
# with ELOOP. gui_run.sh hands it to the GUI-session job as well.
mkdir -p build/tmp
export TMPDIR=${PWD:A}/build/tmp
failed=0
step() { # name, log, command...
  local name=$1 log=$2; shift 2
  print -r -- "== $name"
  if "$@" > "$evidence/$log" 2>&1; then print -r -- "pass  $name"
  else print -r -- "FAIL  $name (see $log)"; tail -25 "$evidence/$log"; failed=1; fi
}
run=$(date +%s)
foreign="anj-test-m3-foreign-$run"
image="$PWD/build/anj-m3-fat-$run.dmg"
volume=
cleanup() {
  if [[ -n $volume ]]; then hdiutil detach "$volume" -quiet || hdiutil detach "$volume" -force -quiet; fi
  rm -f -- "$image"
  tool/macos/keychain_items.sh clean anj-test-m3 || failed=1
}
trap cleanup EXIT

print -r -- "info  source: $(head -1 .anj-source 2>/dev/null || echo unknown)"
app="build/macos/Build/Products/Debug/AnJ Cloud.app"
if (( build )); then
  step "flutter build macos --debug" build-debug.log flutter --suppress-analytics build macos --debug
fi
if (( idle > 0 )); then
  step "desktop session (tool/macos/session_check.sh, idle $idle min)" session.log \
    tool/macos/session_check.sh "$app" "$evidence/session" --idle "$idle"
else
  step "desktop session (tool/macos/session_check.sh)" session.log \
    tool/macos/session_check.sh "$app" "$evidence/session"
fi
cat "$evidence/session.log"

# Keychain reachability from SSH and from the GUI session (facts only).
step "keychain reachability probe (tool/macos/keychain_probe.sh)" keychain-probe.log \
  tool/macos/keychain_probe.sh "$evidence/probe"

# Fixtures: a FAT volume and an item another program owns. FAT32 needs
# more than 16 MB on macOS 26 (16m: "create failed - Operation not permitted").
mkdir -p build
if hdiutil create -quiet -size 40m -fs "MS-DOS FAT32" -volname ANJM3 "$image" 2> "$evidence/fat.log" &&
  volume=$(hdiutil attach -nobrowse "$image" 2>> "$evidence/fat.log" | awk -F'\t' '/\/Volumes\// { print $NF }' | tail -1) &&
  [[ -d $volume ]]; then
  print -r -- "info  FAT volume at $volume"
else
  print -r -- "FAIL  FAT volume fixture (hdiutil, fat.log): $(tr '\n' ' ' < "$evidence/fat.log")"
  failed=1; volume=
fi
tool/macos/keychain_items.sh add "$foreign" "unchanged-$run" > /dev/null ||
  { print -r -- "FAIL  foreign keychain item"; failed=1; }

defines=(--dart-define=ANJ_M3_FOREIGN=$foreign --dart-define=ANJ_M3_HOME_ROOT=1)
[[ -n $volume ]] && defines+=(--dart-define=ANJ_M3_FAT=$volume)
step "macOS adapters in the GUI session (integration_test, gui/<uid>)" integration-gui.log \
  tool/macos/gui_run.sh "$evidence/gui" 900 flutter --suppress-analytics test \
    integration_test/macos_adapters_test.dart -d macos --reporter expanded \
    --dart-define=ANJ_M3_SESSION=gui $defines
step "macOS adapters from SSH (integration_test, no login keychain)" integration-ssh.log \
  flutter --suppress-analytics test integration_test/macos_adapters_test.dart -d macos \
    --reporter expanded --dart-define=ANJ_M3_SESSION=ssh $defines
value=$(tool/macos/keychain_items.sh value "$foreign" 2>/dev/null)
if [[ $value == "unchanged-$run" ]]; then
  print -r -- "pass  the item the build could not read is unchanged"
else
  print -r -- "FAIL  the item the build could not read is unchanged (got '$value')"; failed=1
fi

# Item labels name the kind and the profile (PR #72 review L4). The test
# items of this run (accounts anj-cloud:anj-test-m3-...) are still there;
# attributes are readable while the keychain is locked.
labels=$(security dump-keychain 2>/dev/null | awk '
  /^keychain: / { if (svc == "\"cloud.anj.anj-cloud\"" && acct ~ /^"anj-cloud:anj-test-m3-/) print acct " " lab; svc = acct = lab = "" }
  /"svce"<blob>=/ { svc = $0; sub(/.*"svce"<blob>=/, "", svc) }
  /"acct"<blob>=/ { acct = $0; sub(/.*"acct"<blob>=/, "", acct) }
  /^ *0x00000007 <blob>=/ { lab = $0; sub(/.*0x00000007 <blob>=/, "", lab) }
  END { if (svc == "\"cloud.anj.anj-cloud\"" && acct ~ /^"anj-cloud:anj-test-m3-/) print acct " " lab }')
print -r -- "$labels" > "$evidence/keychain-labels.txt"
if [[ -z $labels ]]; then
  print -r -- "info  keychain labels: no test item left to read (recorded only)"
elif print -r -- "$labels" | awk '
    # security prints a non-ASCII label (the dash) as hex plus an escaped
    # string, so only its ASCII tail is compared.
    /:device-key" / && $0 !~ /AnJ Cloud .* device key, profile anj-test"$/ { bad = 1 }
    /:invitation" / && $0 !~ /AnJ Cloud .* pairing code, profile anj-test"$/ { bad = 1 }
    END { exit bad }'; then
  print -r -- "pass  keychain items are labelled with their kind and profile: $(print -r -- "$labels" | head -2 | tr '\n' ';')"
else
  print -r -- "FAIL  keychain item labels: $labels"; failed=1
fi

# Row 9: no OpenSSL dependence.
print -r -- "== no OpenSSL CLI on PATH (tool/macos/no_openssl.sh)"
tool/macos/no_openssl.sh "$evidence/no-openssl" > "$evidence/no-openssl.log" 2>&1
case $? in
  0) print -r -- "pass  no OpenSSL CLI on PATH" ;;
  77) print -r -- "skip  no OpenSSL CLI on PATH: $(tail -1 "$evidence/no-openssl.log")" ;;
  *) print -r -- "FAIL  no OpenSSL CLI on PATH (see no-openssl.log)"; tail -25 "$evidence/no-openssl.log"; failed=1 ;;
esac
tail -3 "$evidence/no-openssl.log"

if (( failed )); then echo "check_m3: FAILED"; else echo "check_m3: all steps passed"; fi
exit $failed
