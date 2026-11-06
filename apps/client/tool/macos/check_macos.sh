#!/bin/zsh
# macOS check (spec #31 M0). Runs ON mac-test from the client directory that
# tool/macos/mac_test.sh sent over; the Linux counterpart is tool/check.sh.
#
#   tool/macos/check_macos.sh [--evidence <dir>] [--no-launch] [--modes "<modes>"]
#
# 0. source: the commit and dirty-file count mac_test.sh send recorded
# 1. toolchain: macOS arm64, Flutter 3.47.9 (decision #102)
# 2. flutter analyze
# 3. native boundary test and capability probe (native-probe.json), then the
#    mac-side tests (test_macos/) and the shared watcher suites
#    (test/local_watch*_test.dart, FSEvents here) against a freshly built
#    Darwin dylib; an AddressSanitizer open/close stress of the FSEvents
#    watcher (watch_stress.sh)
# 4. flutter build macos for each mode (default "debug profile release")
# 5. bundle checks (verify_bundle.sh) for each build
# 6. launch checks (launch_check.sh) for each build, unless --no-launch
#    (skip them while another lane uses the same bundle id on the guest)
# Exit 0 only when every step passes. Evidence goes to <dir> (default
# build/macos-check).
set -u
cd "${0:A:h}/../.."
evidence=build/macos-check
launch=1
modes=(debug profile release)
while (( $# )); do
  case $1 in
    --evidence) evidence=$2; shift 2 ;;
    --no-launch) launch=0; shift ;;
    --modes) modes=(${=2}); shift 2 ;;
    *) echo "usage: check_macos.sh [--evidence <dir>] [--no-launch] [--modes \"<modes>\"]" >&2; exit 64 ;;
  esac
done
for mode in $modes; do
  [[ $mode == (debug|profile|release) ]] || { echo "check_macos.sh: unknown mode $mode" >&2; exit 64; }
done
mkdir -p "$evidence"
evidence=${evidence:A}
export FLUTTER_SUPPRESS_ANALYTICS=true DART_SUPPRESS_ANALYTICS=true
failed=0
step() { # name, log file, command...
  local name=$1 log=$2; shift 2
  print -r -- "== $name"
  if "$@" > "$evidence/$log" 2>&1; then
    print -r -- "pass  $name"
  else
    print -r -- "FAIL  $name (see $log)"; tail -20 "$evidence/$log"; failed=1
  fi
}

[[ $(uname -m) == arm64 ]] || { echo "FAIL  not arm64"; exit 1; }
if [[ -r .anj-source ]]; then
  source_line=$(head -1 .anj-source)
else
  source_line="unknown (not sent by tool/macos/mac_test.sh send)"
fi
print -r -- "info  source: $source_line"
{ print -r -- "source: $source_line"; sw_vers; xcodebuild -version; flutter --version; } > "$evidence/toolchain.txt" 2>&1
grep -q '^Flutter 3\.47\.9 ' "$evidence/toolchain.txt" || { echo "FAIL  Flutter is not 3.47.9 (decision #102)"; exit 1; }
print -r -- "pass  toolchain: $(sw_vers -productVersion) arm64, Flutter 3.47.9"

step "flutter pub get" pub-get.log flutter --suppress-analytics pub get
step "flutter analyze" analyze.log flutter --suppress-analytics analyze

lib=$PWD/.dart_tool/libanj_rootfs.dylib
step "build test dylib" native.log tool/macos/build_native.sh --out "$lib"
step "native boundary test and capability probe (tool/native_test.sh)" native-test.log \
  sh tool/native_test.sh "$evidence/native-probe.json"
step "FSEvents watcher open/close stress, AddressSanitizer (tool/macos/watch_stress.sh)" watch-stress.log \
  sh tool/macos/watch_stress.sh 500
# A temporary directory with no symlink in its path: the root opens refuse
# one with ELOOP, and both /tmp and /var/folders sit under /private here
# (top_folders_test failed on /tmp/... at #96's head).
mkdir -p build/tmp
export TMPDIR=${PWD:A}/build/tmp
export ANJ_MACOS_ROOTFS_LIBRARY=$lib ANJ_ROOTFS_LIBRARY=$lib
step "mac-side tests (test_macos/)" test-macos.log \
  flutter --suppress-analytics test --reporter expanded --concurrency=1 test_macos test/macos_platform_adapters_test.dart test/macos_desktop_session_test.dart test/secrets_unavailable_test.dart test/platform_selectors_test.dart test/native_portability_test.dart test/local_watch_test.dart test/local_watch_adversarial_test.dart test/top_folders_test.dart test/top_folder_hold_deferral_test.dart
unset ANJ_MACOS_ROOTFS_LIBRARY ANJ_ROOTFS_LIBRARY

for mode in $modes; do
  step "flutter build macos --$mode" build-$mode.log flutter --suppress-analytics build macos --$mode
  app="build/macos/Build/Products/${(C)mode}/AnJ Cloud.app"
  step "bundle checks ($mode)" bundle-$mode.log tool/macos/verify_bundle.sh "$app" $mode
  cat "$evidence/bundle-$mode.log"
  if (( launch )); then
    step "launch check ($mode)" launch-$mode.log tool/macos/launch_check.sh "${app:A}" "$evidence/launch-$mode" $mode
    cat "$evidence/launch-$mode.log"
  fi
done

if (( failed )); then echo "check_macos: FAILED"; else echo "check_macos: all steps passed"; fi
exit $failed
