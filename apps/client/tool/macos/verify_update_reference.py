#!/usr/bin/env python3
"""The reference for the macOS app's `--verify-update` (spec #40 R2), for the VM host.

macos/Runner/DesktopIntegration.swift ReleaseVerifier is the verifier the
manager runs on a Mac (CryptoKit). This script implements the same contract
with linux_install.py's Ed25519 and signed message, so tool/macos/
test_manager.sh exercises apply-update end to end without a Mac: the fake
app executable there runs it for `--verify-update`.

    verify_update_reference.py <app executable> --verify-update <archive> --manifest <file>

The key is the bundle's flutter_assets/assets/release/household-release-key.pub
and the installed version is the bundle's Contents/Resources/bundle-receipt.json,
both found from the executable's path, as in the app. One JSON line; exit 0
verified, 1 refused, 64 usage.
"""

import hashlib
import importlib.util
import json
from pathlib import Path
import sys

_SOURCE = Path(__file__).resolve().parent.parent / "linux_install.py"
_spec = importlib.util.spec_from_file_location("anj_linux_install_reference", _SOURCE)
_li = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_li)

TARGET = "macos-arm64"


class Refusal(Exception):
    pass


def integer(value):
    return value if type(value) is int else None


def verify(bundle, archive, manifest_path):
    key_file = bundle / "Contents/Frameworks/App.framework/Resources/flutter_assets/assets/release/household-release-key.pub"
    try:
        key = _li.release_key(key_file)
    except _li.Refused:
        raise Refusal("The built-in release key file is malformed.") from None
    if key is None:
        raise Refusal("This release has no built-in release key; install updates with the manager's update command.")
    try:
        receipt = json.loads((bundle / "Contents/Resources/bundle-receipt.json").read_text())
        installed = integer(receipt.get("version_code"))
        if installed is None or installed < 0:
            raise ValueError
    except (OSError, ValueError, AttributeError):
        raise Refusal("This release has no release receipt; install updates with the manager's update command.") from None
    try:
        record = json.loads(Path(manifest_path).read_text())
    except (OSError, ValueError):
        raise Refusal("The update record is not JSON.") from None
    fields = set(_li.SIGNED_FIELDS) | {"signature"}
    if not isinstance(record, dict) or not fields <= record.keys() or record.keys() - fields - {"min_client_version_code"}:
        raise Refusal("The update record is incomplete or has unexpected fields.")
    if record["target"] != TARGET:
        raise Refusal("The update is for another platform.")
    if not isinstance(record["version"], str) or not _li.re.fullmatch(r"[0-9A-Za-z][0-9A-Za-z.+_-]{0,63}", record["version"]):
        raise Refusal("The update record has an invalid version.")
    for name, ceiling in (("version_code", _li.MAX_VERSION_CODE), ("size", _li.MAX_PACKAGE)):
        if integer(record[name]) is None or not 1 <= record[name] <= ceiling:
            raise Refusal(f"The update record has an invalid {name}.")
    if not isinstance(record["sha256"], str) or not _li.re.fullmatch(r"[0-9a-f]{64}", record["sha256"]):
        raise Refusal("The update record has an invalid SHA-256.")
    if "min_client_version_code" in record and integer(record["min_client_version_code"]) is None:
        raise Refusal("The update record has an invalid min_client_version_code.")
    if record["key_id"] != key[1]:
        raise Refusal("The update is signed with a different key than this app's.")
    import base64
    import binascii
    try:
        signature = base64.b64decode(record["signature"], validate=True) if isinstance(record["signature"], str) else b""
    except (binascii.Error, ValueError):
        signature = b""
    if not _li.ed25519_verify(key[0], _li.signed_message(record), signature):
        raise Refusal("The update's signature does not verify.")
    if record["version_code"] <= installed:
        raise Refusal(f"The update ({record['version_code']}) is not newer than the installed release ({installed}).")
    checksum, size = hashlib.sha256(), 0
    try:
        with open(archive, "rb") as stream:
            while chunk := stream.read(1 << 20):
                size += len(chunk)
                if size > record["size"]:
                    break
                checksum.update(chunk)
    except OSError:
        raise Refusal("The update archive cannot be read.") from None
    if size != record["size"] or checksum.hexdigest() != record["sha256"]:
        raise Refusal("The downloaded update does not match its signed size and SHA-256.")
    return {"ok": True, "version": record["version"], "version_code": record["version_code"],
            "size": record["size"], "sha256": record["sha256"]}


def main(argv):
    if len(argv) != 6 or argv[2] != "--verify-update" or argv[4] != "--manifest":
        print(json.dumps({"ok": False, "message": "usage: --verify-update <archive> --manifest <file>"}))
        return 64
    executable = Path(argv[1])
    bundle = executable.parent.parent.parent
    try:
        print(json.dumps(verify(bundle, argv[3], argv[5]), sort_keys=True))
        return 0
    except Refusal as refusal:
        print(json.dumps({"ok": False, "message": str(refusal)}, sort_keys=True))
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
