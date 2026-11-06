#!/bin/zsh
# Onboarding parity on macOS (spec #31 M8, decision #164). Runs ON mac-test
# from the client directory tool/macos/mac_test.sh sent over. Without sudo.
#
#   tool/macos/check_m8.sh [--evidence <dir>] [--skip-build]
#
# 1. test/macos_root_placement_test.dart over the Darwin dylib on APFS:
#    P1-P3 with a temporary HOME (no picker, ~/anj-cloud/{Music,Videos,
#    Documents}, the Desktop link once, staging inside the profile, a
#    refused Desktop recorded once, an existing anj-cloud refused).
# 2. The real app, launched through LaunchServices with a disposable
#    profile and the guest's real HOME, records what macOS shows for the
#    privacy-protected ~/Desktop: screenshots while the root is set up, the
#    profile's desktopShortcut outcome, the root folders, staging and the
#    link. Precondition: no ~/anj-cloud and no ~/Desktop/AnJ Cloud on the
#    guest (a run never adopts or deletes one it did not make).
# 3. Cleanup: the app quit, and only what this run made is removed: the
#    profile, ~/anj-cloud, the Desktop link, and the bundle's Desktop
#    permission (tccutil, so the next run asks afresh).
# Exit 0 only when every step passes. Evidence goes to <dir> (default
# build/macos-m8).
set -u
cd "${0:A:h}/../.."
evidence=build/macos-m8
build=1
while (( $# )); do
  case $1 in
    --evidence) evidence=$2; shift 2 ;;
    --skip-build) build=0; shift ;;
    *) echo "usage: check_m8.sh [--evidence <dir>] [--skip-build]" >&2; exit 64 ;;
  esac
done
mkdir -p "$evidence"; evidence=${evidence:A}
export FLUTTER_SUPPRESS_ANALYTICS=true DART_SUPPRESS_ANALYTICS=true
mkdir -p build/tmp
export TMPDIR=${PWD:A}/build/tmp
failed=0
pass() { print -r -- "pass  $*"; }
fail() { print -r -- "FAIL  $*"; failed=1; }
info() { print -r -- "info  $*"; }
step() { # name, log, command...
  local name=$1 log=$2; shift 2
  print -r -- "== $name"
  if "$@" > "$evidence/$log" 2>&1; then pass "$name"
  else fail "$name (see $log)"; tail -25 "$evidence/$log"; fi
}

lib=$PWD/.dart_tool/libanj_rootfs.dylib
step "build test dylib" native.log tool/macos/build_native.sh --out "$lib"
step "P1-P3 with a temporary HOME (test/macos_root_placement_test.dart)" placement-test.log \
  env ANJ_ROOTFS_LIBRARY=$lib ANJ_MACOS_ROOTFS_LIBRARY=$lib \
  flutter --suppress-analytics test --reporter expanded --concurrency=1 \
    test/macos_root_placement_test.dart test/macos_platform_adapters_test.dart

# 2. The real app with the real HOME.
app=${PWD:A}/build/macos/Build/Products/Debug/AnJ\ Cloud.app
exe="$app/Contents/MacOS/AnJ Cloud"
root=$HOME/anj-cloud
link=$HOME/Desktop/AnJ\ Cloud
profile=${PWD:A}/build/m8-profile-$$
made_root=0 made_link=0 pid=
cleanup() {
  [[ -n $pid ]] && { kill -TERM $pid 2>/dev/null; for i in {1..40}; do kill -0 $pid 2>/dev/null || break; sleep 0.5; done; kill -KILL $pid 2>/dev/null; }
  (( made_link )) && [[ -L $link ]] && rm -f -- "$link"
  (( made_root )) && [[ -d $root && ! -L $root ]] && rm -rf -- "$root"
  rm -rf -- "$profile"
  tccutil reset SystemPolicyDesktopFolder cloud.anj.anj-cloud >/dev/null 2>&1
  true
}
trap cleanup EXIT
if [[ -e $root || -L $root || -e $link || -L $link ]]; then
  fail "precondition: the guest already has ~/anj-cloud or ~/Desktop/AnJ Cloud (left alone)"
else
  if (( build )); then
    step "flutter build macos --debug" build-debug.log flutter --suppress-analytics build macos --debug
  fi
  # Again right before the launch (delta review L2): the build takes
  # minutes, and only what this launch makes may be removed.
  if [[ -e $root || -L $root || -e $link || -L $link ]]; then
    fail "precondition: ~/anj-cloud or ~/Desktop/AnJ Cloud appeared during the build (left alone)"
    print -r -- "check_m8: FAILED"; trap - EXIT; rm -rf -- "$profile"; exit 1
  fi
  made_root=1 made_link=1   # only ever paths that did not exist before
  open -n -F --stdout "$evidence/app-stdout.log" --stderr "$evidence/app-stderr.log" "$app" --args --profile-dir "$profile"
  for i in {1..60}; do
    pid=$(pgrep -n -f "^$exe --profile-dir $profile\$"); [[ -n $pid ]] && break; sleep 0.5
  done
  [[ -n $pid ]] && pass "app started through LaunchServices (pid $pid)" || fail "app started"
  outcome=
  for i in {1..40}; do
    (( i == 6 )) && screencapture -x "$evidence/screen-3s.png" 2>/dev/null
    outcome=$(sqlite3 -readonly "$profile/manifest.sqlite" "SELECT value FROM settings WHERE key='desktopShortcut'" 2>/dev/null)
    [[ -n $outcome ]] && break; sleep 0.5
  done
  screencapture -x "$evidence/screen-after.png" 2>/dev/null
  if [[ -n $outcome ]]; then
    pass "desktop shortcut outcome recorded: $outcome"
  else
    fail "no desktop shortcut outcome after 20 s (a pending privacy prompt? see screen-*.png)"
  fi
  print -r -- "$outcome" > "$evidence/desktop-shortcut.txt"
  if [[ -L $link ]]; then
    info "~/Desktop/AnJ Cloud -> $(readlink "$link")"
  else
    info "no ~/Desktop/AnJ Cloud link (outcome '$outcome')"
  fi
  r=$(sqlite3 -readonly "$profile/manifest.sqlite" "SELECT value FROM settings WHERE key='root'" 2>/dev/null)
  s=$(sqlite3 -readonly "$profile/manifest.sqlite" "SELECT value FROM settings WHERE key='staging'" 2>/dev/null)
  if [[ $r == ${root:A} && -d $root/Music && -d $root/Videos && -d $root/Documents ]]; then
    pass "automatic root with no picker: $r/{Music,Videos,Documents}"
  else
    fail "automatic root: root='$r'"
  fi
  if [[ $s == ${profile:A}/staging ]]; then pass "staging inside the profile: $s"; else fail "staging inside the profile: '$s'"; fi
  [[ -n $pid ]] && kill -0 $pid 2>/dev/null && pass "app still running (sync unaffected by the Desktop outcome)" || fail "app still running"
  tccutil reset SystemPolicyDesktopFolder cloud.anj.anj-cloud >/dev/null 2>&1 || true
fi
cleanup; trap - EXIT; pid=
[[ ! -e $profile && ( $made_root == 0 || ! -e $root ) ]] && pass "cleanup: app quit, profile and ~/anj-cloud removed" || fail "cleanup"

if (( failed )); then echo "check_m8: FAILED"; else echo "check_m8: all steps passed"; fi
exit $failed
