#!/usr/bin/env bash
# The Windows watcher's notification translation (native/windows/
# watch_translate.h, spec #32 File Watching) on this host. The watch itself
# runs on the seat (tool/windows/native_test.ps1).
set -euo pipefail
cd "$(dirname "$0")/.."
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
clang++ -std=c++17 -Wall -Wextra -Werror -O1 native/windows/test/watch_translate_test.cc -o "$work/watch_translate_test"
"$work/watch_translate_test"
