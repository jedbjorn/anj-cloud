#!/bin/sh
# Checks a built "AnJ Cloud.app" against spec #31's build settings. Runs on
# macOS. Prints one line per check; exit 0 only when every check passes.
#
#   verify_bundle.sh <path/to/AnJ Cloud.app> debug|profile|release
set -u
app=${1:?usage: verify_bundle.sh <AnJ Cloud.app> debug|release}
mode=${2:?usage: verify_bundle.sh <AnJ Cloud.app> debug|profile|release}
exe="$app/Contents/MacOS/AnJ Cloud"
dylib="$app/Contents/Frameworks/libanj_rootfs.dylib"
plist="$app/Contents/Info.plist"
failed=0
check() { # name, then a command that must succeed
  name=$1; shift
  if "$@" >/dev/null 2>&1; then echo "pass  $name"; else echo "FAIL  $name"; failed=1; fi
}
info() { /usr/libexec/PlistBuddy -c "Print :$1" "$plist" 2>/dev/null; }
sig() { codesign -dvvv "$1" 2>&1; }
ents() { codesign -d --entitlements - --xml "$1" 2>/dev/null; }
is() { [ "$1" = "$2" ]; }
has() { printf '%s\n' "$1" | grep -qE "$2"; }
lacks() { ! printf '%s\n' "$1" | grep -qE "$2"; }

check "bundle exists" test -x "$exe"
check "CFBundleIdentifier is cloud.anj.anj-cloud" is "$(info CFBundleIdentifier)" cloud.anj.anj-cloud
check "CFBundleName is AnJ Cloud" is "$(info CFBundleName)" "AnJ Cloud"
check "LSMinimumSystemVersion is 26.0" is "$(info LSMinimumSystemVersion)" 26.0
check "executable is arm64 only" is "$(lipo -archs "$exe" 2>/dev/null)" arm64
check "native dylib is embedded in Contents/Frameworks" test -f "$dylib"
check "native dylib is arm64 only" is "$(lipo -archs "$dylib" 2>/dev/null)" arm64
abi="$(dirname "$0")/../../native/posix/exports.txt"
want=$(grep -v -e '^#' -e '^[[:space:]]*$' "$abi" | sed 's/^/_/' | sort | tr '\n' ' ')
# Every defined _anj_* symbol, data and weak too: no test seam ships.
got=$(nm -gU "$dylib" 2>/dev/null | awk '$3 ~ /^_anj_/ { print $3 }' | sort | tr '\n' ' ')
check "native dylib exports exactly the shared anj_* boundary" is "$got" "$want"
check "native dylib minimum OS is 26.0" has "$(otool -l "$dylib" 2>/dev/null)" 'minos 26\.0'
check "bundle seal verifies (codesign --verify --deep --strict)" codesign --verify --deep --strict "$app"
# The install manager (M6) is embedded before signing, byte-identical to
# the reviewed source, so the app's Start at login toggle runs that copy.
manager="$app/Contents/Resources/anj-cloud-macos-install.sh"
check "install manager is embedded and executable" test -x "$manager"
check "embedded install manager matches tool/macos/anj-cloud-macos-install.sh" \
  cmp -s "$manager" "$(dirname "$0")/anj-cloud-macos-install.sh"

s=$(sig "$app")
check "app is ad-hoc signed" has "$s" '^Signature=adhoc$'
check "app has no team identifier" has "$s" '^TeamIdentifier=not set$'
case "$mode" in
  release|profile) check "app runs with the hardened runtime" has "$s" 'flags=0x[0-9a-f]*\(.*runtime.*\)' ;;
  # Xcode's debug-dylib mode signs Debug without the runtime flag.
  *) echo "info  debug signature $(printf '%s\n' "$s" | grep -E '^CodeDirectory' | sed 's/ hashes.*//')" ;;
esac
check "app identifier is the bundle id" has "$s" '^Identifier=cloud\.anj\.anj-cloud$'
d=$(sig "$dylib")
check "dylib is ad-hoc signed" has "$d" '^Signature=adhoc$'
check "dylib has the hardened runtime" has "$d" 'flags=0x[0-9a-f]*\(.*runtime.*\)'

e=$(ents "$app")
check "not sandboxed" lacks "$e" 'com\.apple\.security\.app-sandbox'
check "no restricted entitlements" lacks "$e" 'application-identifier|team-identifier|keychain-access-groups|com\.apple\.developer\.'
check "no DYLD environment entitlement" lacks "$e" 'allow-dyld-environment-variables'
keys=$(printf '%s\n' "$e" | grep -oE '<key>[^<]+</key>' | sed 's/<[^>]*>//g' | sort | tr '\n' ' ' | sed 's/ $//')
echo "info  entitlements: ${keys:-none}"
case "$mode" in
  # Xcode adds get-task-allow to Debug so a debugger can attach.
  debug) check "debug entitlements are allow-jit and get-task-allow" is "$keys" "com.apple.security.cs.allow-jit com.apple.security.get-task-allow" ;;
  # Library validation is off because it refuses every ad-hoc framework
  # under the hardened runtime (M0 finding); nothing else, no get-task-allow.
  release) check "release entitlements are disable-library-validation only" is "$keys" "com.apple.security.cs.disable-library-validation" ;;
  # Profile is hardened too, so it needs the same exception; Xcode adds
  # get-task-allow so a profiler can attach. Never handed out.
  profile) check "profile entitlements are disable-library-validation and get-task-allow" is "$keys" "com.apple.security.cs.disable-library-validation com.apple.security.get-task-allow" ;;
  *) echo "FAIL  unknown mode $mode"; failed=1 ;;
esac

# Every nested Mach-O is signed (the seal check covers this; listed for
# the evidence).
find "$app/Contents/Frameworks" -maxdepth 1 \( -name '*.framework' -o -name '*.dylib' \) | sort | while read -r nested; do
  echo "info  nested $(basename "$nested"): $(sig "$nested" | grep -E '^Signature=' | head -1)"
done
echo "info  cdhash $(sig "$app" | sed -n 's/^CDHash=//p')"
# The runner's test seams (ANJ_TEST_SEAMS: the test keychain override) are
# compiled into Debug only.
case "$mode" in
  release|profile)
    check "no Swift test seam in the executable" lacks "$(strings "$exe" 2>/dev/null)" 'The test keychain could not be opened' ;;
esac
exit $failed
