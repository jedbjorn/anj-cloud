"""The one account-id and display-name rule (spec #27, decision #103). Standard library only, so
the gateway, the registry, the console backend and the operator CLI share it.

An account id is 1-32 characters of lowercase letters, digits and '-', never starting with '-'
(the registry's rule); every action on an existing account accepts it. A NEW account's id must
also start with a letter (user-add only). Every occ call also places ids after '--'.
"""

import re


ACCOUNT_UID = re.compile(r"[a-z0-9][a-z0-9-]{0,31}")
NEW_ACCOUNT_UID = re.compile(r"[a-z][a-z0-9-]{0,31}")
# Never household accounts: Nextcloud's administrators and the audit's non-account actors.
RESERVED_UIDS = frozenset({"anj-admin", "admin", "recovery-cli", "system", "bootstrap"})
UID_TEXT = "User id: 1-32 lowercase letters, digits or '-', not starting with '-'"
NEW_UID_TEXT = "User id: 1-32 lowercase letters, digits or '-', starting with a letter"
NAME_TEXT = "Display name must be 1-64 printable characters"


def valid_uid(value):
    return isinstance(value, str) and ACCOUNT_UID.fullmatch(value) is not None


def valid_new_uid(value):
    """For user-add only (decision on PR #43): a new account's id starts with a letter."""
    return isinstance(value, str) and NEW_ACCOUNT_UID.fullmatch(value) is not None


def clean_display_name(value):
    """The display name with whitespace collapsed, or None unless it is 1-64 printable characters
    (bidi overrides, C1 controls and zero-width format characters are not printable)."""
    if not isinstance(value, str):
        return None
    value = " ".join(value.split())
    return value if 1 <= len(value) <= 64 and value.isprintable() else None


# A device's own computer name, as the alerts and the Admin device list show it (spec #35, PR #92
# review H1). The redeeming device chooses it, and the gateway (Python 3.14) and the VM's console
# backend (Debian's Python 3.13) carry different Unicode databases, so "printable" is not one rule
# across them. The shown name is therefore printable ASCII only, which every Python agrees on:
# compatibility-decomposed (NFKD), combining marks dropped, every other non-ASCII character and the
# quote that delimits it in an alert replaced by '?', whitespace collapsed, capped with "...".
# Whatever the Unicode version, the result is the same kind of string, and cleaning it again
# leaves it unchanged.
DEVICE_NAME_MAX = 40
UNNAMED = "unnamed"


def clean_device_name(value, limit=DEVICE_NAME_MAX):
    import unicodedata
    if not isinstance(value, str):
        return UNNAMED
    out = []
    for char in unicodedata.normalize("NFKD", value[:256]):
        if unicodedata.combining(char):
            continue
        if char.isspace():
            out.append(" ")
        elif " " <= char <= "~" and char != "'":
            out.append(char)
        else:
            out.append("?")
    name = " ".join("".join(out).split())
    if len(name) > limit:
        name = name[:limit - 3].rstrip() + "..."
    return name or UNNAMED


def valid_device_name(value):
    """What the console backend accepts in a pairing alert: exactly a cleaned name."""
    return isinstance(value, str) and clean_device_name(value) == value
