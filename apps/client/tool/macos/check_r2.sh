#!/bin/zsh
# The macOS update verifier on mac-test (spec #40 R2). Runs ON the guest from
# the client directory tool/macos/mac_test.sh sent over; no sudo.
#
#   tool/macos/check_r2.sh [--evidence <dir>] [--skip-build]
#
# 1. flutter build macos --debug (the Debug build accepts a throwaway key
#    and installed version for these cases, ANJ_TEST_SEAMS; Release ignores
#    them).
# 2. A throwaway Ed25519 key (OpenSSL 3+), an archive and manifests signed
#    with it. The app's CryptoKit verifier (`AnJ Cloud --verify-update`)
#    must accept the good one and refuse each tampered one with its reason:
#    signature, hash, size, key_id, another key, downgrade, wrong target,
#    unexpected field. Where a Python 3.11+ exists,
#    tool/macos/verify_update_reference.py must give the same verdicts (one
#    contract, two implementations); base macOS has 3.9, and the VM host's
#    test_manager.sh runs the reference against the same cases.
# 3. A Release build ignores the test overrides (no key from outside).
# Exit 0 only when every case passes. Evidence in <dir> (default
# build/macos-r2); the throwaway key never leaves its temporary folder.
set -u
cd "${0:A:h}/../.."
evidence=build/macos-r2
build=1
while (( $# )); do
  case $1 in
    --evidence) evidence=$2; shift 2 ;;
    --skip-build) build=0; shift ;;
    *) echo "usage: check_r2.sh [--evidence <dir>] [--skip-build]" >&2; exit 64 ;;
  esac
done
mkdir -p "$evidence" build/tmp; evidence=${evidence:A}
export TMPDIR=${PWD:A}/build/tmp FLUTTER_SUPPRESS_ANALYTICS=true DART_SUPPRESS_ANALYTICS=true
failed=0
pass() { print -r -- "pass  $*"; }
fail() { print -r -- "FAIL  $*"; failed=1; }
openssl=
for c in /opt/homebrew/opt/openssl@*/bin/openssl(N) /opt/homebrew/bin/openssl(N); do
  "$c" version 2>/dev/null | grep -qE '^OpenSSL ([3-9]|[1-9][0-9]+)\.' && { openssl=$c; break; }
done
[[ -n $openssl ]] || { fail "no OpenSSL 3+ for the throwaway key"; exit 1; }

app=${PWD:A}/build/macos/Build/Products/Debug/AnJ\ Cloud.app
if (( build )); then
  flutter --suppress-analytics build macos --debug > "$evidence/build-debug.log" 2>&1 &&
    pass "flutter build macos --debug" || { fail "flutter build macos --debug"; tail -30 "$evidence/build-debug.log"; exit 1; }
fi
exe="$app/Contents/MacOS/AnJ Cloud"

work=$(mktemp -d "$TMPDIR/anj-r2.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
$openssl genpkey -algorithm ed25519 -out "$work/k.pem" 2>/dev/null
$openssl genpkey -algorithm ed25519 -out "$work/other.pem" 2>/dev/null
raw() { $openssl pkey -in "$1" -pubout -outform DER 2>/dev/null | tail -c 32; }
printf '# throwaway\ned25519 %s\n' "$(raw "$work/k.pem" | base64)" > "$work/k.pub"
kid=$(raw "$work/k.pem" | shasum -a 256 | cut -c1-16)
head -c 300000 /dev/urandom > "$work/update.zip"
# A bundle layout for the reference (key and receipt where the app has them).
ref="$work/ref/AnJ Cloud.app"
mkdir -p "$ref/Contents/MacOS" "$ref/Contents/Resources" "$ref/Contents/Frameworks/App.framework/Resources/flutter_assets/assets/release"
cp "$work/k.pub" "$ref/Contents/Frameworks/App.framework/Resources/flutter_assets/assets/release/household-release-key.pub"
print -r -- '{"version_code": 100, "target": "macos-arm64"}' > "$ref/Contents/Resources/bundle-receipt.json"

# sign <pem> <target> <version> <code> [size] [sha] [key_id] [extra json]
sign() {
  local size=${5:-$(wc -c < "$work/update.zip" | tr -d ' ')} sha=${6:-$(shasum -a 256 "$work/update.zip" | cut -d' ' -f1)} key=${7:-$kid}
  printf 'anj-cloud release v1\ntarget %s\nversion %s\nversion_code %s\nsize %s\nsha256 %s\nkey_id %s\n' \
    "$2" "$3" "$4" "$size" "$sha" "$key" > "$work/msg"
  $openssl pkeyutl -sign -inkey "$1" -rawin -in "$work/msg" -out "$work/sig" 2>/dev/null
  printf '{"target": "%s", "version": "%s", "version_code": %s, "size": %s, "sha256": "%s", "key_id": "%s", "signature": "%s"%s}\n' \
    "$2" "$3" "$4" "$size" "$sha" "$key" "$(base64 < "$work/sig" | tr -d '\n')" "${8:-}" > "$work/manifest.json"
}
python=
for c in python3.14 python3.13 python3.12 python3.11 python3; do
  command -v $c >/dev/null && $c -c 'import sys; sys.exit(sys.version_info < (3, 11))' 2>/dev/null && { python=$c; break; }
done
[[ -n $python ]] && pass "reference verifier: $($python --version)" ||
  print -r -- "note  no Python 3.11+ here: CryptoKit verdicts checked against the expected reasons only"
verdict() { # app and reference verdicts for the current manifest
  app_out=$("$exe" --verify-update "$work/update.zip" --manifest "$work/manifest.json" \
    --release-key "$work/k.pub" --installed-version-code 100 2>/dev/null); app_rc=$?
  if [[ -n $python ]]; then
    ref_out=$($python tool/macos/verify_update_reference.py "$ref/Contents/MacOS/AnJ Cloud" --verify-update \
      "$work/update.zip" --manifest "$work/manifest.json"); ref_rc=$?
  else
    ref_out=$app_out ref_rc=$app_rc
  fi
  print -r -- "$1 app=$app_rc $app_out ref=$ref_rc $ref_out" >> "$evidence/verdicts.txt"
}
: > "$evidence/verdicts.txt"
sign "$work/k.pem" macos-arm64 2026.11.06.101 101
verdict good
[[ $app_rc == 0 && $app_out == *'"ok":true'* && $app_out == *'"version_code":101'* && $ref_rc == 0 ]] &&
  pass "a signed, newer release verifies: $app_out" || fail "good release: $app_out / $ref_out"

for case_ in "signature|signature does not verify" "hash|size and SHA-256" "size|size and SHA-256" \
    "key_id|different key" "otherkey|signature does not verify" "downgrade|not newer" \
    "target|another platform" "field|unexpected fields" "minimum|min_client_version_code"; do
  kind=${case_%%|*} why=${case_#*|}
  case $kind in
    signature) sign "$work/k.pem" macos-arm64 2026.11.06.101 101
      sed -i '' 's/"version": "2026.11.06.101"/"version": "2026.11.06.109"/' "$work/manifest.json" ;;
    hash) sign "$work/k.pem" macos-arm64 2026.11.06.101 101 "" "$(printf '0%.0s' {1..64})" ;;
    size) sign "$work/k.pem" macos-arm64 2026.11.06.101 101 7 ;;
    key_id) sign "$work/k.pem" macos-arm64 2026.11.06.101 101 "" "" 0123456789abcdef ;;
    otherkey) sign "$work/other.pem" macos-arm64 2026.11.06.101 101 ;;
    downgrade) sign "$work/k.pem" macos-arm64 2026.11.06.100 100 ;;
    target) sign "$work/k.pem" linux-x86_64 2026.11.06.101 101 ;;
    field) sign "$work/k.pem" macos-arm64 2026.11.06.101 101 "" "" "" ', "extra": 1' ;;
    minimum) sign "$work/k.pem" macos-arm64 2026.11.06.101 101 "" "" "" ', "min_client_version_code": "1"' ;;
  esac
  verdict "$kind"
  if [[ $app_rc == 1 && $app_out == *"$why"* && $ref_rc == 1 && $ref_out == *"$why"* ]]; then
    pass "refused: $kind: $app_out"
  else
    fail "$kind: app=$app_rc $app_out | ref=$ref_rc $ref_out"
  fi
done

# Without a receipt (a Debug build has none) and no test override: refused.
sign "$work/k.pem" macos-arm64 2026.11.06.101 101
out=$("$exe" --verify-update "$work/update.zip" --manifest "$work/manifest.json" 2>/dev/null); rc=$?
[[ $rc == 1 && $out == *'no '* ]] && pass "this build itself (no receipt or no key of its own) vouches for nothing: $out" ||
  fail "a build without a receipt: $rc $out"
# Usage: no window, no AppKit, exit 64.
out=$("$exe" --verify-update 2>/dev/null); rc=$?
[[ $rc == 64 ]] && pass "usage error exits 64 without starting the app" || fail "usage: $rc $out"

if (( failed )); then echo "check_r2: FAILED"; else echo "check_r2: all steps passed"; fi
exit $failed
