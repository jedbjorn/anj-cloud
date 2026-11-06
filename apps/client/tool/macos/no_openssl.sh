#!/bin/zsh
# Spec #31 acceptance row 9 on mac-test: the identity, pairing and renewal
# suites pass with `openssl` on PATH replaced by a recorder that only fails
# and notes the call. Runs ON the guest from the client directory.
#
#   tool/macos/no_openssl.sh <out dir>
#
# macOS cannot hide /usr/bin/openssl (SIP; no mount namespaces as on Linux,
# test/no_openssl_cli_test.dart), so a call by absolute path is not caught
# here: the static half of that test (client sources never name the OpenSSL
# CLI and launch processes only at allowlisted sites, Swift included) runs
# in the same suite list and covers it. Fixture operator calls reach a real
# OpenSSL 3 or later through ANJ_TEST_OPENSSL (Homebrew's openssl@3,
# openssl@4, ...; the stock LibreSSL 3.3.6 lacks options the fixtures use).
# Exit 77 (skip, with the reason on the last line) when there is none. Exit 0 only when every suite passes and
# the recorder was never called.
set -u
out=${1:?usage: no_openssl.sh <out dir>}
mkdir -p "$out"; out=${out:A}
cd "${0:A:h}/../.."
real=
for candidate in /opt/homebrew/opt/openssl@*/bin/openssl(N) /opt/homebrew/opt/openssl/bin/openssl(N) /opt/homebrew/bin/openssl(N) /usr/local/bin/openssl(N); do
  [[ -x $candidate ]] && "$candidate" version 2>/dev/null | grep -qE '^OpenSSL ([3-9]|[1-9][0-9]+)\.' && { real=$candidate; break; }
done
if [[ -z $real ]]; then
  echo "no_openssl.sh: skipped: no OpenSSL 3 or later for the test fixtures (Homebrew openssl@3 or later)"
  exit 77
fi
rm -rf "$out/bin"; mkdir -p "$out/bin"
marker=$out/openssl-called
rm -f "$marker"
print -r -- "#!/bin/sh
echo \"\$*\" >> ${(q)marker}
exit 1" > "$out/bin/openssl"
chmod 755 "$out/bin/openssl"
export PATH="$out/bin:$PATH" ANJ_TEST_OPENSSL=$real
# Controller tests open the root through the test dylib (test_platform.dart's
# testNativeLibrary); check_macos.sh builds it into .dart_tool.
lib=$PWD/.dart_tool/libanj_rootfs.dylib
[[ -f $lib ]] || tool/macos/build_native.sh --out "$lib" > "$out/native.log" 2>&1 ||
  { echo "no_openssl.sh: could not build the test dylib (see native.log)" >&2; exit 1; }
export ANJ_ROOTFS_LIBRARY=$lib ANJ_MACOS_ROOTFS_LIBRARY=$lib
[[ $(command -v openssl) == $out/bin/openssl ]] || { echo "no_openssl.sh: the recorder is not first on PATH" >&2; exit 1; }
flutter --suppress-analytics test --concurrency=1 --reporter expanded \
  --plain-name 'client sources never name the OpenSSL CLI or launch processes' \
  test/no_openssl_cli_test.dart || exit 1
flutter --suppress-analytics test --concurrency=1 \
  test/identity_test.dart test/pairing_flow_test.dart test/certificate_renewal_test.dart \
  test/dav_test.dart test/device_crypto_test.dart
code=$?
if [[ -s $marker ]]; then
  echo "no_openssl.sh: client code ran openssl:"; cat "$marker"; exit 1
fi
(( code == 0 )) && echo "no_openssl.sh: all suites passed; the recorder was never called (fixtures used $real)"
exit $code
