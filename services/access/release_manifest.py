"""Client release targets and the manifest rule (spec #28 G1, spec #37 U-core). Standard library
only, so the gateway and the operator CLI (which runs on the VM's system Python) share one rule.

Android packages are trusted through their APK signing certificate (`signer_sha256`, decision
#108). Desktop packages are trusted through the household release key (decision #159): the
manifest carries an Ed25519 `signature` by that key over `signed_message(manifest)`, and `key_id`
names the key. The gateway never signs and never verifies a signature; it checks the shape here,
stores what the operator published and serves it. Clients verify against the public key built
into the running app.
"""

import re


class ManifestError(ValueError):
    """A curated reason a release manifest is refused."""


# `<os>-<arch>` -> the package's Content-Type. Adding a client platform is one row here and one
# in SIGNED (desktop) if it is trusted through the household release key.
TARGETS = {
    "android-arm64": "application/vnd.android.package-archive",
    "linux-x86_64": "application/gzip",
    "macos-arm64": "application/octet-stream",
    "windows-x64": "application/octet-stream",
}
# Desktop targets: signed by the household release key (spec #37 U-core).
SIGNED = frozenset({"linux-x86_64", "macos-arm64", "windows-x64"})
MAX_PACKAGE = 512 * 1024 * 1024
MAX_VERSION_CODE = 2_100_000_000          # Android's ceiling for versionCode
VERSION = re.compile(r"[0-9A-Za-z][0-9A-Za-z.+_-]{0,63}")
SHA256 = re.compile(r"[0-9a-f]{64}")
KEY_ID = re.compile(r"[0-9a-f]{16}")
# Base64 (standard alphabet, padded) of the 64-byte Ed25519 signature.
SIGNATURE = re.compile(r"[A-Za-z0-9+/]{86}==")
ANDROID_FIELDS = ("version", "version_code", "size", "sha256", "signer_sha256")
DESKTOP_FIELDS = ("version", "version_code", "size", "sha256", "key_id", "signature")
# Optional, desktop only, never signed: the lowest version code the operator still supports. A
# client below it shows "Update required"; it only changes that label, never what is installed.
DESKTOP_OPTIONAL = ("min_client_version_code",)
# Kept for callers that list the Android fields.
MANIFEST_FIELDS = ANDROID_FIELDS
STORED = re.compile(r"([0-9]{1,10})\.(pkg|json)")
SIGNED_HEADER = "anj-cloud release v1"
SIGNED_FIELDS = ("target", "version", "version_code", "size", "sha256", "key_id")


def fields_for(target):
    return DESKTOP_FIELDS if target in SIGNED else ANDROID_FIELDS


def signed_message(manifest):
    """The exact bytes the household release key signs (spec #37 U-core): one `name value` line
    per field in SIGNED_FIELDS order after a fixed header, each ending in a newline, UTF-8. Every
    value is constrained by the manifest rule (no spaces or newlines), so the encoding is
    unambiguous. Clients (Dart, the Linux manager) build the same bytes."""
    lines = [SIGNED_HEADER] + [f"{name} {manifest[name]}" for name in SIGNED_FIELDS]
    return ("\n".join(lines) + "\n").encode()


def manifest_from(data, target):
    """A validated manifest for `target`; raises ManifestError naming the first bad field."""
    if not isinstance(data, dict):
        raise ManifestError("Release manifest must be a JSON object")
    required = fields_for(target)
    optional = DESKTOP_OPTIONAL if target in SIGNED else ()
    extra = set(data) - set(required) - set(optional) - {"target"}
    if extra:
        raise ManifestError("Unexpected release manifest field: " + sorted(extra)[0])
    if "target" in data and data["target"] != target:
        raise ManifestError("Release manifest is for another target")
    missing = [name for name in required if name not in data]
    if missing:
        raise ManifestError("Release manifest lacks " + missing[0])
    if not isinstance(data["version"], str) or not VERSION.fullmatch(data["version"]):
        raise ManifestError("Release version must be 1-64 letters, digits or . + _ -")
    for name, ceiling in (("version_code", MAX_VERSION_CODE), ("size", MAX_PACKAGE)):
        if type(data[name]) is not int or not 1 <= data[name] <= ceiling:
            raise ManifestError(f"Release {name} must be a whole number from 1 to {ceiling}")
    for name in ("sha256", "signer_sha256"):
        if name in required and (not isinstance(data[name], str) or not SHA256.fullmatch(data[name])):
            raise ManifestError(f"Release {name} must be 64 lowercase hex characters")
    if target in SIGNED:
        if not isinstance(data["key_id"], str) or not KEY_ID.fullmatch(data["key_id"]):
            raise ManifestError("Release key_id must be 16 lowercase hex characters")
        if not isinstance(data["signature"], str) or not SIGNATURE.fullmatch(data["signature"]):
            raise ManifestError("Release signature must be the base64 of a 64-byte Ed25519 signature")
        floor = data.get("min_client_version_code")
        if floor is not None and (type(floor) is not int or not 1 <= floor <= data["version_code"]):
            raise ManifestError("Release min_client_version_code must be a whole number from 1 to its version_code")
    result = {"target": target, **{name: data[name] for name in required}}
    for name in optional:
        if data.get(name) is not None:
            result[name] = data[name]
    return result
