#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${FLUTTER_SDK:=$HOME/.local/share/anj-cloud/toolchains/flutter-3.47.9}"
python3 tool/apply_profile.py > /dev/null   # this deployment's release key and origin (untracked outputs)
export FLUTTER_SUPPRESS_ANALYTICS=true DART_SUPPRESS_ANALYTICS=true
./tool/build_rootfs.sh
./tool/check_exports.sh
./tool/native_test.sh .dart_tool/native-probe.json >/dev/null
export ANJ_ROOTFS_LIBRARY="$PWD/.dart_tool/libanj_rootfs.so"
./tool/check_layers.sh
./tool/test_windows_seat.sh
./tool/test_windows_watch.sh
bash ./tool/macos/test_manager.sh
"$FLUTTER_SDK/bin/flutter" --suppress-analytics analyze
# Crash fixtures invoke dart run, whose native-asset publication recreates the
# shared .dart_tool/lib SQLite DSO. Concurrent fixture commands can dlopen a
# partially copied DSO (observed loader SIGBUS); keep test files sequential.
if [ -n "${ANJ_TEST_EXCLUDE:-}" ]; then
  # CI: skip the test files written against the maintainer's seat (see .github/workflows/ci.yml).
  mapfile -t selected < <(ls test/*_test.dart | grep -Ev "$ANJ_TEST_EXCLUDE")
  "$FLUTTER_SDK/bin/flutter" --suppress-analytics test --concurrency=1 "${selected[@]}"
else
  "$FLUTTER_SDK/bin/flutter" --suppress-analytics test --concurrency=1
fi
./tool/android_variant_suites.sh
