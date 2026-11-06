"""Wire validation shared by enrollment and DAV confinement."""

import hashlib
import re
from urllib.parse import quote, unquote, urlsplit

from cryptography import x509
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec
from defusedxml import ElementTree as SafeET
from xml.etree import ElementTree as ET

# Invitation codes and the curated rejection live in the standard-library-only codes module
# (decision #151: the one place the code's sizes are set); re-exported here for existing callers.
from .codes import (ALPHABET, CA_PIN_BYTES, CODE_LENGTH, CODE_NOT_VALID, LEGACY_SECRET_BYTES, PINNED_CODE_LENGTH,  # noqa: F401,E402
                    PINNED_SECRET_BYTES, SECRET_BYTES, Rejection, code_ca_pin, code_from_bytes, encode_code,
                    normalize_code, pinned_code)

METHODS = {"GET", "HEAD", "OPTIONS", "PROPFIND", "PUT", "MKCOL", "DELETE", "MOVE"}
READ_METHODS = {"GET", "HEAD", "OPTIONS", "PROPFIND"}
MAX_XML = 2 * 1024 * 1024
# The one upload size limit (SC-028). ANJ_MAX_TRANSFER_BYTES may override it per
# deployment; every DAV response reports the effective value in UPLOAD_LIMIT_HEADER
# so clients can refuse an oversized file locally instead of sending it.
UPLOAD_LIMIT = 64 * 1024 * 1024
UPLOAD_LIMIT_HEADER = "X-Anj-Upload-Limit"
# The owner console may change the limit at runtime within these bounds (spec #27, decision #78
# C5). Larger values need Feature #6's large-transfer qualification.
UPLOAD_LIMIT_MIN = 1024 * 1024
UPLOAD_LIMIT_MAX = 64 * 1024 * 1024


def size_label(size):
    """A short human size for messages: 67108864 -> '64 MB'."""
    for unit, scale in (("GB", 1024 ** 3), ("MB", 1024 ** 2), ("KB", 1024)):
        if size >= scale:
            return "{:g} {}".format(round(size / scale, 1), unit)
    return "%d bytes" % size


def ca_pin(certificate):
    """The first CA_PIN_BYTES of SHA-256 over the CA certificate's DER (the openssl fingerprint's prefix)."""
    return hashlib.sha256(certificate.public_bytes(serialization.Encoding.DER)).digest()[:CA_PIN_BYTES]


def key_fingerprint(key):
    raw = key.public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)
    return hashlib.sha256(raw).hexdigest()


def parse_csr(pem):
    if not isinstance(pem, str) or len(pem) > 8192:
        raise Rejection("Invalid CSR")
    csr = x509.load_pem_x509_csr(pem.encode("ascii"))
    key = csr.public_key()
    if not csr.is_signature_valid or not isinstance(key, ec.EllipticCurvePublicKey) or not isinstance(key.curve, ec.SECP256R1):
        raise Rejection("A valid P-256 signed CSR is required")
    # The signed request is the durable retry identity; arbitrary CSR extensions are never copied.
    return csr.public_bytes(serialization.Encoding.PEM).decode(), key_fingerprint(key)


def canonical_path(raw):
    """Validate a raw URI path, decode once, then encode its filename segments."""
    if not isinstance(raw, str) or len(raw) > 4096 or re.search(r"%(?![0-9A-Fa-f]{2})", raw):
        raise Rejection("Invalid path encoding")
    if "?" in raw or "#" in raw:
        raise Rejection("Query and fragment delimiters must be encoded as filename data")
    if re.search(r"%(?:2f|5c|00)", raw, re.I):
        raise Rejection("Encoded path separators are unsupported")
    decoded = unquote(raw, encoding="utf-8", errors="strict")
    return encode_filename_path(decoded)


def encode_filename_path(decoded):
    """Encode an already decoded local/JSON filename path without decoding it again."""
    if not isinstance(decoded, str) or len(decoded) > 4096:
        raise Rejection("Invalid filename path")
    if any(ord(c) < 32 or ord(c) == 127 for c in decoded):
        raise Rejection("Control characters are unsupported")
    if "\\" in decoded or decoded.startswith("/"):
        raise Rejection("Invalid relative path")
    parts = decoded.split("/")
    if parts[-1:] == [""]:
        parts.pop()
    if any(part in ("", ".", "..") for part in parts):
        raise Rejection("Path must stay beneath the enrolled root")
    return "/".join(quote(part, safe="-._~") for part in parts) + ("/" if decoded.endswith("/") and parts else "")


def backend_root(uid):
    return "/remote.php/dav/files/" + quote(uid, safe="") + "/anj-cloud/"


def move_destination(value, origin):
    if "?" in value or "#" in value:
        raise Rejection("MOVE destination cannot contain query or fragment delimiters")
    parsed = urlsplit(value)
    expected = urlsplit(origin)
    if parsed.scheme != expected.scheme or parsed.netloc != expected.netloc or parsed.query or parsed.fragment or not parsed.path.startswith("/dav/"):
        raise Rejection("MOVE destination must use this gateway and enrolled root")
    return canonical_path(parsed.path[len("/dav/"):])


def gateway_reference(value, uid, origin, backend):
    if "?" in value or "#" in value:
        raise Rejection("DAV response cannot contain query or fragment delimiters")
    parsed = urlsplit(value)
    if parsed.scheme or parsed.netloc:
        target = urlsplit(backend)
        if (parsed.scheme, parsed.netloc) != (target.scheme, target.netloc):
            raise Rejection("Foreign DAV response reference")
    if parsed.query or parsed.fragment or not parsed.path.startswith(backend_root(uid)):
        raise Rejection("DAV response reference is outside the enrolled root")
    relative = canonical_path(parsed.path[len(backend_root(uid)):])
    return origin + "/dav/" + relative


def rewrite_multistatus(body, uid, origin, backend):
    if len(body) > MAX_XML:
        raise Rejection("DAV XML exceeds development limit")
    root = SafeET.fromstring(body, forbid_dtd=True)
    if root.tag != "{DAV:}multistatus":
        raise Rejection("Expected DAV multistatus")
    for node in root.iter("{DAV:}href"):
        if node.text is None:
            raise Rejection("Empty DAV reference")
        node.text = gateway_reference(node.text, uid, origin, backend)
    return ET.tostring(root, encoding="utf-8", xml_declaration=True)
