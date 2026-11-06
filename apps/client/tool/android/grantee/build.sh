#!/usr/bin/env bash
# Builds the three grantee test APKs (debug, x86_64 emulator) in a bounded scope, no daemon.
#   tool/android/grantee/build.sh <n>   -> scope anj-test-${ANJ_TAG:-a5}-<n>; APKs in build/apks/
set -euo pipefail
N="${1:?usage: build.sh <n>}"; TAG="${ANJ_TAG:-a5}"
P="$(cd "$(dirname "$0")" && pwd)"
T=$HOME/.local/share/anj-cloud/toolchains/android
exec systemd-run --user --scope --quiet --unit="anj-test-$TAG-$N" -p MemoryMax=6G -p TasksMax=2048 \
  "$T/bin/anj-android" bash -c '
    set -euo pipefail; cd "$1"
    trap "./gradlew --stop >/dev/null 2>&1 || true" EXIT
    timeout 1200 ./gradlew --no-daemon --console=plain :app:assembleDebug
    mkdir -p build/apks
    for g in g1 g2 g3; do cp app/build/outputs/apk/$g/debug/app-$g-debug.apk build/apks/grantee-$g.apk; done
    sha256sum build/apks/*.apk' _ "$P"
