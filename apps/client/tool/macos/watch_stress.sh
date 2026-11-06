#!/bin/sh
# FSEvents watcher open/close stress under event churn, with
# AddressSanitizer (spec #31 M2, review of #62 F2). Runs on mac-test from
# the client directory; also builds on Linux (inotify) as a smoke check.
#
#   tool/macos/watch_stress.sh [<cycles>]     default 500; exit 0 = clean
set -eu
cd "$(dirname "$0")/../.."
cycles=${1:-500}
# Resolved: the root open refuses a symlink anywhere in its path (ELOOP),
# and macOS's default temporary directory sits under /var -> /private/var.
work=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/anj-watch-stress.XXXXXX")" && pwd -P)
trap 'rm -rf "$work"' EXIT
case $(uname -s) in
  Darwin) cxx="xcrun clang++ -arch arm64 -mmacosx-version-min=26.0"; frameworks="-framework CoreServices" ;;
  *) cxx=clang++; frameworks= ;;
esac
$cxx -std=c++17 -Wall -Wextra -Werror -O1 -g -fsanitize=address -fno-omit-frame-pointer \
  native/posix/test/watch_stress_test.cc $frameworks -o "$work/stress"
mkdir "$work/scratch"
# The target is a use after free in a late stream callback; leaks are not
# checked here.
ASAN_OPTIONS=abort_on_error=1:halt_on_error=1 "$work/stress" "$work/scratch" "$cycles"
