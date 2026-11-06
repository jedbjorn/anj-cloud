#!/usr/bin/env bash
# Builds the debug (QA, cloud.anj.anj_cloud.qa) x86_64 APK for the VM host emulator in a
# bounded scope (spec #28 Build, Sign, Install; anj_test_seats). No Gradle daemon
# outlives it.
#   [ANJ_TAG=<lane>] tool/android/build_apk.sh <n> [extra flutter build args, e.g. -t integration_test/android_engine_test.dart]
# Then checks the APK's permission set (tool/android/check_permissions.sh).
set -euo pipefail
[ $# -ge 1 ] || { echo "usage: $0 <n> [flutter build apk args]" >&2; exit 2; }
N="$1"; shift
cd "$(dirname "$0")/../.."
systemd-run --user --scope --unit="anj-test-${ANJ_TAG:-a2}-$N" -p MemoryMax=6G -p TasksMax=1024 \
  timeout 1500 $HOME/.local/share/anj-cloud/toolchains/android/bin/anj-android \
  flutter --suppress-analytics build apk --debug --target-platform android-x64 "$@"
# The permission set never drifts (PR #63 review F6).
tool/android/check_permissions.sh build/app/outputs/flutter-apk/app-debug.apk
