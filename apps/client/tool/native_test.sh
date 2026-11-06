#!/bin/sh
# Native boundary test and capability probe (spec #31 M1): builds
# native/posix/test/boundary_test.cc (which compiles rootfs.cc in) on this
# host, Linux (The VM host) or macOS (mac-test), runs it in a private scratch
# directory and writes one JSON row per mapping. Exit 0 = every row passes
# and the build exports exactly native/posix/exports.txt.
#
#   tool/native_test.sh [<probe.json>]     default .dart_tool/native-probe.json
set -eu
cd "$(dirname "$0")/.."
out=${1:-.dart_tool/native-probe.json}
mkdir -p "$(dirname "$out")"
# Every durability call goes through barrier_sync or full_sync (compat_<os>.h,
# decision #129), so the Darwin mapping covers every Linux fsync site.
if grep -n 'fsync(' native/posix/rootfs.cc native/posix/*.inc; then
  echo "native_test: raw fsync outside compat_<os>.h" >&2; exit 1
fi
work=$(mktemp -d "${TMPDIR:-/tmp}/anj-native-test.XXXXXX")
trap 'rm -rf "$work"' EXIT
want=$(grep -v -e '^#' -e '^[[:space:]]*$' native/posix/exports.txt | sort)
case $(uname -s) in
  Darwin)
    cxx="xcrun clang++ -arch arm64 -mmacosx-version-min=26.0"
    lib="$work/libanj_rootfs.dylib"
    $cxx -std=c++17 -Wall -Wextra -Werror -O2 -fPIC -dynamiclib native/posix/rootfs.cc -framework CoreServices -o "$lib"
    got=$(nm -gU "$lib" | awk '$3 ~ /^_anj_/ { sub(/^_/, "", $3); print $3 }' | sort) ;;
  *)
    cxx=clang++
    lib="$work/libanj_rootfs.so"
    $cxx -std=c++17 -Wall -Wextra -Werror -O2 -fPIC -shared native/posix/rootfs.cc -o "$lib"
    got=$(nm -D --defined-only "$lib" | awk '$3 ~ /^anj_/ { print $3 }' | sort) ;;
esac
if [ "$got" != "$want" ]; then
  echo "native_test: exports differ from native/posix/exports.txt" >&2
  printf '%s\n' "$want" > "$work/want"; printf '%s\n' "$got" > "$work/got"
  diff "$work/want" "$work/got" >&2 || true
  exit 1
fi
# The library above is the shipped form; only the test program carries the
# seams (sync counts and order).
case $(uname -s) in Darwin) frameworks="-framework CoreServices" ;; *) frameworks= ;; esac
$cxx -std=c++17 -Wall -Wextra -Werror -O1 -DANJ_TEST_SEAMS native/posix/test/boundary_test.cc $frameworks -o "$work/boundary_test"
mkdir "$work/scratch"
status=0
"$work/boundary_test" "$work/scratch" > "$out" || status=$?
# One line per row (portable awk: BSD sed has no \| alternation).
awk -F'"' '/^ \{"row":/ { print ($7 ~ /^:true/ ? "pass  " : "FAIL  ") "\"" $4 "\"" }' "$out"
tail -1 "$out"
exit $status
