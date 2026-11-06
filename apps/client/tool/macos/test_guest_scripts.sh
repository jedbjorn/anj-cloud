#!/usr/bin/env bash
# Fake-HOME tests for mac_test_cleanup.sh and mac_test_inventory.sh (PR #51
# review F1-F3). Runs on the VM host or the guest; touches only a mktemp HOME, with
# tccutil, defaults, launchctl and sqlite3 stubbed. Exit 0 = all pass.
#
#   bash tool/macos/test_guest_scripts.sh
set -u
T=$(cd "$(dirname "$0")" && pwd)
base=$(mktemp -d)
trap 'rm -rf -- "$base"' EXIT
C="$T/mac_test_cleanup.sh"; I="$T/mac_test_inventory.sh"
pass=0; fail=0
ok() { echo "pass  $1"; pass=$((pass+1)); }
bad() { echo "FAIL  $1"; fail=$((fail+1)); }
expect() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
B=cloud.anj.anj-cloud
setup() {
  H="$base/home"; rm -rf -- "$base/home" "$base/bin"; mkdir -p "$H" "$base/bin"
  for s in tccutil defaults launchctl sqlite3; do
    printf '#!/bin/sh\necho "%s $*" >> "%s/calls"\n[ "%s" = launchctl ] && exit 1\nexit 0\n' "$s" "$base" "$s" > "$base/bin/$s"; chmod +x "$base/bin/$s"
  done
  : > "$base/calls"
  mkdir -p "$H/Documents/precious" "$H/work/LANE1/m0-1" "$H/work/LANE1/m0" "$H/work/RVW1/m0rev-1" \
    "$H/work/DEV2/m1-darwin" "$H/work/LANE1/macos-probe" \
    "$H/Library/Application Support/$B" "$H/Library/Application Support/other" \
    "$H/Library/Application Support/$B-other" "$H/Library/Caches/$B" "$H/Library/Caches/keep" \
    "$H/Library/Preferences"
  touch "$H/Library/Preferences/$B.plist" "$H/Library/Preferences/keep.plist"
  ln -s "$H/Documents" "$H/work/LANE1/m0-link"
}
run() { HOME="$H" PATH="$base/bin:$PATH" ${SH:-sh} "$@" >"$base/out" 2>&1; echo $?; }

echo "## F1: --bundle-id is gone; empty and odd owners are refused"
setup
for args in "--owner m0 --bundle-id ''" "--owner m0 --bundle-id ../../Documents" "--owner ''" "--owner ../.." "--owner m0-x" "--owner m/0" "--owner"; do
  rc=$(eval run "$C" $args)
  expect "cleanup $args exits 64" "[ $rc = 64 ]"
done
expect "nothing removed by refused calls" "[ -d '$H/Documents/precious' ] && [ -d '$H/Library/Application Support/$B' ] && [ -d '$H/work/LANE1/m0-1' ]"
for args in "--owner ''" "--owner m0-x" "--bundle-id x --owner m0"; do
  rc=$(eval run "$I" $args)
  expect "inventory $args exits 64" "[ $rc = 64 ]"
done

echo "## F2: exact owner match"
setup
rc=$(run "$C" --owner m)
expect "owner m: exit 0" "[ $rc = 0 ]"
expect "owner m: removes nothing of m0, m0rev, m1" "[ -d '$H/work/LANE1/m0-1' ] && [ -d '$H/work/RVW1/m0rev-1' ] && [ -d '$H/work/DEV2/m1-darwin' ]"
rc=$(run "$C" --owner m0)
expect "owner m0: exit 0" "[ $rc = 0 ]"
expect "owner m0: removes LANE1/m0 and LANE1/m0-1" "[ ! -e '$H/work/LANE1/m0' ] && [ ! -e '$H/work/LANE1/m0-1' ]"
expect "owner m0: keeps RVW1/m0rev-1, DEV2/m1-darwin, macos-probe" "[ -d '$H/work/RVW1/m0rev-1' ] && [ -d '$H/work/DEV2/m1-darwin' ] && [ -d '$H/work/LANE1/macos-probe' ]"
expect "owner m0: symlinked m0-link not followed, Documents kept" "[ -d '$H/Documents/precious' ]"
expect "default cleanup leaves shared bundle state" "[ -d '$H/Library/Application Support/$B' ] && [ -e '$H/Library/Preferences/$B.plist' ]"
expect "default cleanup calls no tccutil/defaults" "! grep -qE '^(tccutil|defaults)' '$base/calls'"

echo "## F3: --reset-bundle-state"
setup
mkdir -p "$H/work/DEV2/m1-darwin/build/macos/Build/Products/Release/AnJ Cloud.app"
rc=$(run "$C" --owner m0 --reset-bundle-state)
expect "refused (exit 1) while another lane has a build" "[ $rc = 1 ] && grep -q 'refused' '$base/out'"
expect "refusal changes no shared state" "[ -d '$H/Library/Application Support/$B' ] && [ -e '$H/Library/Preferences/$B.plist' ] && ! grep -qE '^(tccutil|defaults)' '$base/calls'"
rm -rf -- "$H/work/DEV2/m1-darwin/build"
mkdir -p "$H/work/LANE1/m0-1/build/macos/Build/Products/Release/AnJ Cloud.app"
rc=$(run "$C" --owner m0 --reset-bundle-state)
expect "own build does not block the reset (exit 0)" "[ $rc = 0 ]"
expect "reset removes exact bundle paths" "[ ! -e '$H/Library/Application Support/$B' ] && [ ! -e '$H/Library/Caches/$B' ] && [ ! -e '$H/Library/Preferences/$B.plist' ]"
expect "reset keeps siblings" "[ -d '$H/Library/Application Support/other' ] && [ -d '$H/Library/Application Support/$B-other' ] && [ -d '$H/Library/Caches/keep' ] && [ -e '$H/Library/Preferences/keep.plist' ]"
expect "reset calls tccutil and defaults for the bundle only" "grep -qx 'tccutil reset All $B' '$base/calls' && grep -qx 'defaults delete $B' '$base/calls'"
expect "reset keeps other lanes' dirs" "[ -d '$H/work/DEV2/m1-darwin' ] && [ -d '$H/work/RVW1/m0rev-1' ]"

echo "## inventory: owner decides, shared reported"
setup
rc=$(run "$I" --owner m0)
expect "owner dirs present: exit 1" "[ $rc = 1 ] && grep -q 'LEFT    workdir: $H/work/LANE1/m0-1' '$base/out'"
expect "owner m0 does not list m0rev-1" "! grep -q 'm0rev-1' '$base/out'"
rm -rf -- "$H/work/LANE1/m0" "$H/work/LANE1/m0-1"; rm -f -- "$H/work/LANE1/m0-link"
rc=$(run "$I" --owner m0)
expect "only shared state left: exit 0, listed as shared" "[ $rc = 0 ] && grep -q 'shared  library: $H/Library/Application Support/$B' '$base/out'"
rc=$(run "$I" --owner m0 --strict)
expect "--strict counts shared state: exit 1" "[ $rc = 1 ]"
rm -rf -- "$H/Library/Application Support/$B" "$H/Library/Caches/$B" "$H/Library/Preferences/$B.plist"
rc=$(run "$I" --owner m0 --strict)
expect "--strict with nothing left: exit 0" "[ $rc = 0 ]"

echo "harness: $pass passed, $fail failed"
[ $fail -eq 0 ]
