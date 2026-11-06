"""Invitation codes (decision #151, spec #35): the one place their sizes are set (server side).

Standard library only, so the gateway, the operator tooling, setup and qualify.py share it. The
client's twin is `apps/client/lib/core/gateway/dav_api.dart` (`pinnedSecretBytes`,
`caPinBytes`); `tests/pairing_code_vector.json` holds one vector both sides decode and must be
regenerated with `python3 -m services.access.codes --vector > tests/pairing_code_vector.json`
whenever the sizes change.

A pinned code is a one-time secret followed by the first CA_PIN_BYTES of the household CA
certificate's SHA-256 (DER), encoded most significant bits first in the alphabet below (5 bits per
character, ceil(bits/5) characters; the first character carries the leftover bits). The gateway
looks a code up only by the HMAC of all its characters, so a code whose CA part is wrong is simply
unknown, refused exactly like any other invalid code.

Changing the code's size is a two-constant change: PINNED_SECRET_BYTES and CA_PIN_BYTES here and
their twins in dav_api.dart (then regenerate the vector). Every length is derived from them. A
pinned code must never have the legacy code's length: the two formats are told apart by length.
"""

import json
import sys

ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
CODE_NOT_VALID = "Code not valid"

# The two sizes (bytes). Whole bytes keep the encoder and its top-bits check exact.
PINNED_SECRET_BYTES = 7
CA_PIN_BYTES = 10
# Codes issued before decision #151 (fingerprint approval, rule 6): a 20-byte secret, unchanged.
LEGACY_SECRET_BYTES = 20


class Rejection(ValueError):
    """A deliberately curated message safe for a request rejection."""


def code_length(size):
    """Characters for `size` bytes: ceil(bits / 5)."""
    return -(-size * 8 // 5)


CODE_LENGTH = code_length(LEGACY_SECRET_BYTES)
PINNED_CODE_LENGTH = code_length(PINNED_SECRET_BYTES + CA_PIN_BYTES)
if PINNED_CODE_LENGTH == CODE_LENGTH:
    raise ImportError("A pinned code must not have the legacy code's length; change PINNED_SECRET_BYTES or CA_PIN_BYTES")
# The secret part alone has the legacy length only by accident: it is never a code by itself.
SECRET_BYTES = PINNED_SECRET_BYTES


def encode_code(raw):
    """Bytes -> the alphabet, most significant bits first, ceil(bits/5) characters."""
    chars = code_length(len(raw))
    number = int.from_bytes(raw, "big")
    return "".join(ALPHABET[(number >> shift) & 31] for shift in range(5 * (chars - 1), -1, -5))


def decode_code(code, size):
    """The `size` bytes a normalized code of code_length(size) characters carries."""
    number = 0
    for char in code:
        number = number * 32 + ALPHABET.index(char)
    if number >> (size * 8):
        raise Rejection(CODE_NOT_VALID)
    return number.to_bytes(size, "big")


def code_from_bytes(raw):
    """A legacy code (tests and codes issued before decision #151 only)."""
    if len(raw) != LEGACY_SECRET_BYTES:
        raise Rejection("Invitation requires %d random bytes" % LEGACY_SECRET_BYTES)
    return encode_code(raw)


def pinned_code(secret, pin):
    if len(secret) != PINNED_SECRET_BYTES or len(pin) != CA_PIN_BYTES:
        raise Rejection("A pinned invitation needs the secret and the CA pin")
    return encode_code(secret + pin)


def code_ca_pin(code):
    """The CA pin a normalized pinned code carries, or None for a legacy code."""
    if len(code) != PINNED_CODE_LENGTH:
        return None
    return decode_code(code, PINNED_SECRET_BYTES + CA_PIN_BYTES)[PINNED_SECRET_BYTES:]


def normalize_code(value):
    if not isinstance(value, str) or len(value) > 128:
        raise Rejection(CODE_NOT_VALID)
    value = value.replace("-", "").replace(" ", "").upper()
    if len(value) not in (CODE_LENGTH, PINNED_CODE_LENGTH) or any(char not in ALPHABET for char in value):
        raise Rejection(CODE_NOT_VALID)
    return value


def group(code, size=4, separator="-"):
    return separator.join(code[i:i + size] for i in range(0, len(code), size))


def grouped_pattern(length=PINNED_CODE_LENGTH, size=4):
    """A regex for a code of `length` characters shown in groups of `size` (qualify.py)."""
    full, rest = divmod(length, size)
    pattern = "[0-9A-Z]{%d}" % size + ("(?:-[0-9A-Z]{%d}){%d}" % (size, full - 1) if full > 1 else "")
    return pattern + ("-[0-9A-Z]{%d}" % rest if rest else "")


def vector():
    """The cross-language vector: fixed secret and pin bytes and the code they encode to."""
    secret = bytes(range(PINNED_SECRET_BYTES))
    pin = bytes(range(200, 200 + CA_PIN_BYTES))
    return {"secret_bytes": PINNED_SECRET_BYTES, "ca_pin_bytes": CA_PIN_BYTES, "legacy_length": CODE_LENGTH,
            "length": PINNED_CODE_LENGTH, "secret_hex": secret.hex(), "pin_hex": pin.hex(), "code": pinned_code(secret, pin)}


if __name__ == "__main__":
    if sys.argv[1:] != ["--vector"]:
        raise SystemExit("usage: python3 -m services.access.codes --vector > tests/pairing_code_vector.json")
    print(json.dumps(vector(), indent=2))
