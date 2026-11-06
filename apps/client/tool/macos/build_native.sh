#!/bin/sh
# Builds the Darwin libanj_rootfs.dylib (spec #31). Runs on macOS only.
#
#   build_native.sh --xcode       from the Runner's "Build anj native library"
#                                 phase: writes Contents/Frameworks/ and signs
#                                 the dylib before Xcode seals the app
#   build_native.sh --out <path>  a standalone copy for tests (unsigned is
#                                 fine for flutter_tester; ad-hoc signed here)
#
# The dylib is built inside the Xcode build, never copied in afterwards: a
# copy after the build breaks the bundle seal (doc #14 probe).
set -eu
here=$(cd "$(dirname "$0")/../.." && pwd)
sources="$here/native/posix/rootfs.cc"
# Exactly the shared C ABI (native/posix/exports.txt). Test seams exist only
# in tool/native_test.sh's -DANJ_TEST_SEAMS build, never in the app.
exports=$(grep -v -e '^#' -e '^[[:space:]]*$' "$here/native/posix/exports.txt" |
  sed 's/^/_/' | sort | tr '\n' ' ' | sed 's/ $//')
target=${MACOSX_DEPLOYMENT_TARGET:-26.0}

case "${1:-}" in
  --xcode)
    : "${TARGET_BUILD_DIR:?run from Xcode}" "${FRAMEWORKS_FOLDER_PATH:?run from Xcode}"
    out="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH/libanj_rootfs.dylib"
    identity=${EXPANDED_CODE_SIGN_IDENTITY:--}
    ;;
  --out)
    out=${2:?usage: build_native.sh --out <path>}
    identity=-
    ;;
  *)
    echo "usage: build_native.sh --xcode | --out <path>" >&2
    exit 64
    ;;
esac

mkdir -p "$(dirname "$out")"
tmp="$out.tmp.$$"
trap 'rm -f "$tmp"' EXIT
xcrun clang++ -std=c++17 -Wall -Wextra -Werror -O2 -fPIC \
  -arch arm64 -mmacosx-version-min="$target" \
  -dynamiclib -install_name @rpath/libanj_rootfs.dylib \
  "$sources" -framework CoreServices -o "$tmp"

# Exactly the shared exports; anything else means the source drifted.
actual=$(nm -gU "$tmp" | awk '$2 == "T" { print $3 }' | sort | tr '\n' ' ' | sed 's/ $//')
if [ "$actual" != "$exports" ]; then
  echo "build_native.sh: unexpected exports: $actual" >&2
  exit 1
fi

if [ "${CODE_SIGNING_ALLOWED:-YES}" != NO ]; then
  # Hardened runtime, no timestamp (ad-hoc). Xcode then seals the app over it.
  codesign --force --sign "$identity" --options runtime --timestamp=none "$tmp"
fi
mv -f "$tmp" "$out"
trap - EXIT
echo "build_native.sh: $out"
