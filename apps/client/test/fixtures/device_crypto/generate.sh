#!/usr/bin/env bash
# Regenerates the OpenSSL golden vectors that device_crypto_test.dart compares
# the in-process device crypto against (spec #28 U1). Everything here is
# synthetic test material made for these tests; no device or household key.
# The commands are the ones the client and deploy/access_operator.py ran.
# The device and issuer private keys stay in a temporary directory: the repo
# never holds private keys (*.key/*.pem are ignored), so key loading is
# compared live in device_crypto_test.dart instead.
set -euo pipefail
cd "$(dirname "$0")"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
profile=0123456789abcdef0123456789abcdef
device=11111111-2222-4333-8444-555555555555
fp() { sha256sum | cut -d' ' -f1; }

# The pre-U1 client: identity.dart's genpkey and req -new.
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 > "$tmp/device.key"
openssl req -new -sha256 -key /dev/stdin -subj "/CN=$profile" < "$tmp/device.key" > legacy_device.csr

# The operator issuer and clientAuth leaves (access_operator.py setup/sign).
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -noenc \
  -not_after 20991231235959Z -subj "/CN=anj-cloud Fixture issuer" \
  -keyout "$tmp/issuer.key" -out issuer.crt \
  -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
printf '[leaf]\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=clientAuth\n' > "$tmp/leaf.ext"
for spec in leaf_utc:20491231235959Z leaf_generalized:20990101000000Z; do
  openssl x509 -req -in legacy_device.csr -CA issuer.crt -CAkey "$tmp/issuer.key" \
    -set_serial "0x$(openssl rand -hex 16)" -not_after "${spec#*:}" -subj "/CN=$device" \
    -extfile "$tmp/leaf.ext" -extensions leaf -out "${spec%%:*}.crt" 2>/dev/null
done

cert() {
  printf '    "%s": {"fingerprint": "%s", "not_after": "%s", "subject": "%s"}' "$1" \
    "$(openssl x509 -pubkey -noout -in "$1.crt" | openssl pkey -pubin -outform DER | fp)" \
    "$(openssl x509 -enddate -noout -dateopt iso_8601 -in "$1.crt" | sed 's/^notAfter=//')" \
    "$(openssl x509 -noout -subject -nameopt RFC2253 -in "$1.crt" | sed 's/^subject=//')"
}
{
  printf '{\n  "profile": "%s",\n  "device": "%s",\n' "$profile" "$device"
  printf '  "key_fingerprint": "%s",\n' "$(openssl pkey -pubout -outform DER < "$tmp/device.key" | fp)"
  printf '  "csr_fingerprint": "%s",\n' "$(openssl req -pubkey -noout < legacy_device.csr | openssl pkey -pubin -outform DER | fp)"
  printf '  "certificates": {\n'
  cert issuer; printf ',\n'; cert leaf_utc; printf ',\n'; cert leaf_generalized; printf '\n'
  printf '  }\n}\n'
} > expected.json
