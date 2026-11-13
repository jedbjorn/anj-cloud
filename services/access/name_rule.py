"""The name rule (spec #49, decision #193): names just work on every device.

One rule set, applied to a single path segment, with a Dart twin in
apps/client/lib/core/sync/name_rule.dart. Both run the `rule` section of
tests/name_policy_vectors.json, so they cannot drift. RULE_VERSION moves when the rule changes.

- `cleanup(name, siblings, folder)` (R1 + R2): the name every client gives an item in the cloud.
  Leading and trailing whitespace is trimmed, an empty result becomes `Untitled`, `\\`, C0
  controls and DEL get lookalikes, a name over MAX_BYTES has its stem cut, and a folder ending in
  `.part` or `.filepart` gets `_` appended (decision #195). A changed name that meets a
  sibling by case or accents gets ` (2)`, ` (3)`, ... before the extension.
- `cloud_check(name)` (R2): why the cloud cannot or must not hold `name`, else None. MAX_BYTES and
  the forbidden names and extensions were measured on Nextcloud 33.0.10 through the gateway path
  (task D1). A file still reported `forbiddenExtension` is a local temporary that clients do not
  upload; anything else reported after cleanup is the residual error row.
- `local_names(entries, os)` (R3): the name each cloud item of one folder has on this device.
  Windows maps characters, trailing dots and device names, then resolves case and normalization
  clashes by `oc:fileid` (oldest keeps its name). macOS resolves clashes only. Linux and Android
  keep cloud names. It depends only on the folder's listing, so it is recomputed, never stored.
- `cloud_name(local, entries, os)`: the reverse. A local name is a known item's only when that
  item's local name is exactly it; otherwise the local name is literal.

"Extension" is the text after the last `.` when it and the stem before it are non-empty. Folders
have none. The rule never edits an extension; a length cut keeps it whole.
"""

from collections import namedtuple

from .portable_names import RESERVED, fold_key

RULE_VERSION = 1
# Nextcloud 33 refuses a name over 250 UTF-8 bytes (FilenameValidator; measured in task D1).
MAX_BYTES = 250
# Unicode White_Space: trimmed from both ends of every name (R1).
WHITESPACE = frozenset([*range(0x09, 0x0E), 0x20, 0x85, 0xA0, 0x1680, *range(0x2000, 0x200B),
                        0x2028, 0x2029, 0x202F, 0x205F, 0x3000])
UNTITLED = "Untitled"
# Lookalikes: Windows characters to their fullwidth forms, C0 controls to Control Pictures (R3 step 1).
WINDOWS_LOOKALIKES = {**{ord(c): ord(c) + 0xFEE0 for c in '<>:"\\|?*'}, **{cp: 0x2400 + cp for cp in range(0x01, 0x20)}}
# What the cloud cannot store but a lookalike fixes, for every client (R2): `\`, C0 controls, and DEL
# (refused by the gateway path check; decision #195) mapped to its Control Picture.
CLOUD_LOOKALIKES = {**{cp: WINDOWS_LOOKALIKES[cp] for cp in [ord("\\"), *range(0x01, 0x20)]}, 0x7F: 0x2421}
# Refused by Nextcloud or the gateway's path check.
FORBIDDEN_CHARACTERS = frozenset([0x00, 0x2F, 0x5C, *range(0x01, 0x20), 0x7F])
FORBIDDEN_NAMES = frozenset([".", "..", ".htaccess"])  # compared in ASCII lower case
# Compared in ASCII lower case. A file with one is a local temporary (decision #195): it is never
# uploaded. A folder with one gets `_` appended.
FORBIDDEN_EXTENSIONS = (".part", ".filepart")
OPERATING_SYSTEMS = ("windows", "macos", "linux", "android")
REASONS = ("empty", "untrimmed", "forbiddenCharacter", "forbiddenName", "forbiddenExtension", "tooLong")

Entry = namedtuple("Entry", "name fileid folder", defaults=(None, False))

__all__ = ["CLOUD_LOOKALIKES", "Entry", "MAX_BYTES", "OPERATING_SYSTEMS", "REASONS", "RULE_VERSION", "UNTITLED",
           "WHITESPACE", "WINDOWS_LOOKALIKES", "cleanup", "cloud_check", "cloud_name", "local_name", "local_names", "split"]


def split(name, folder=False):
    """(stem, extension); the extension is '' for a folder or a name without one."""
    dot = name.rfind(".")
    if folder or dot <= 0 or dot == len(name) - 1:
        return name, ""
    return name[:dot], name[dot + 1:]


def _join(stem, extension):
    return stem + "." + extension if extension else stem


def _strip(text):
    start, end = 0, len(text)
    while start < end and ord(text[start]) in WHITESPACE:
        start += 1
    while end > start and ord(text[end - 1]) in WHITESPACE:
        end -= 1
    return text[start:end]


def _lower(name):
    return "".join(char.lower() if char.isascii() else char for char in name)


def _size(text):
    return len(text.encode("utf-8"))


def _fit(stem, extension, tail=""):
    """`stem + tail` before the extension, the stem cut at a code point boundary so the name fits
    MAX_BYTES; a cut leaves no whitespace at the stem's end. None when no stem would be left."""
    budget = MAX_BYTES - _size(tail) - (_size(extension) + 1 if extension else 0)
    if _size(stem) > budget:
        while stem and _size(stem) > budget:
            stem = stem[:-1]
        stem = _strip(stem)
    return _join(stem + tail, extension) if stem else None


def _suffixed(name, folder, taken):
    """`name` with the first ` (n)`, n >= 2, whose fold key is not in `taken`."""
    stem, extension = split(name, folder)
    n = 2
    while True:
        candidate = _fit(stem, extension, " (%d)" % n)
        if candidate is None:
            return name
        if fold_key(candidate) not in taken:
            return candidate
        n += 1


def cleanup(name, siblings=(), folder=False):
    """The cloud name for an item named `name` (R1, R2): unchanged when nothing needs fixing.
    `siblings` are the other names in its folder; a changed name that meets one by case or accents
    gets the next free ` (n)`."""
    trimmed = _strip(name)
    stem, extension = split(name, folder)
    if not trimmed:
        result = UNTITLED
    elif extension and not _strip(stem) and _strip(extension):
        result = UNTITLED + "." + _strip(extension)
    else:
        result = trimmed
    result = result.translate(CLOUD_LOOKALIKES)
    if _size(result) > MAX_BYTES:
        stem, extension = split(result, folder)
        result = _fit(stem, extension) or result
    if folder and _lower(result).endswith(FORBIDDEN_EXTENSIONS):
        result = _fit(result, "", "_") or result
    if result == name:
        return name
    taken = {fold_key(sibling) for sibling in siblings}
    return _suffixed(result, folder, taken) if fold_key(result) in taken else result


def cloud_check(name):
    """The reason the cloud cannot or must not hold `name`, else None."""
    if not name:
        return "empty"
    if _strip(name) != name:
        return "untrimmed"
    if any(ord(char) in FORBIDDEN_CHARACTERS for char in name):
        return "forbiddenCharacter"
    lower = _lower(name)
    if lower in FORBIDDEN_NAMES:
        return "forbiddenName"
    if lower.endswith(FORBIDDEN_EXTENSIONS):
        return "forbiddenExtension"
    if _size(name) > MAX_BYTES:
        return "tooLong"
    return None


def _windows(name):
    """R3 steps 1-3: characters, trailing dots, device names."""
    result = name.translate(WINDOWS_LOOKALIKES)
    # Windows drops trailing dots, and with them any space they leave at the end.
    result = result.rstrip(". ") or UNTITLED
    first = result.split(".", 1)[0]
    device = first.rstrip(" ")
    if device.isascii() and device.upper() in RESERVED:
        result = device + "_" + result[len(device):]
    return result


def _order(entry):
    return (entry.fileid is None, entry.fileid or 0, entry.name)


def local_names(entries, os):
    """{cloud name: local name} for the cloud items of one folder on `os` (R3).
    `entries` are Entry(name, fileid, folder); the result does not depend on their order."""
    if os not in OPERATING_SYSTEMS:
        raise ValueError("Unknown operating system: %r" % os)
    entries = sorted(entries, key=_order)
    if os in ("linux", "android"):
        return {entry.name: entry.name for entry in entries}
    base = {entry.name: _windows(entry.name) if os == "windows" else entry.name for entry in entries}
    groups = {}
    for entry in entries:
        groups.setdefault(fold_key(base[entry.name]), []).append(entry)
    result, later = {}, []
    for members in groups.values():
        # Step 4: the oldest keeps its result. Step 5: unless its name changed into the exact name of
        # an item whose name did not change; that item keeps it.
        keeper = next((m for m in members if base[members[0].name] != members[0].name and m.name == base[members[0].name]),
                      members[0])
        result[keeper.name] = base[keeper.name]
        later += [member for member in members if member is not keeper]
    taken = {fold_key(name) for name in result.values()}
    for entry in sorted(later, key=_order):  # Oldest first, the next ` (n)` free of every other name.
        local = _suffixed(base[entry.name], entry.folder, taken)
        taken.add(fold_key(local))
        result[entry.name] = local
    return result


def local_name(cloud_name, entries, os, folder=False):
    """The local name of the item `cloud_name` among `entries`, its folder's cloud items. An item
    missing from `entries` is placed after them, as the newest."""
    entries = list(entries)
    if all(entry.name != cloud_name for entry in entries):
        entries.append(Entry(cloud_name, None, folder))
    return local_names(entries, os)[cloud_name]


def cloud_name(local, entries, os):
    """The cloud name for the local name `local` in a folder whose cloud items are `entries`."""
    for name, mapped in local_names(entries, os).items():
        if mapped == local:
            return name
    return local
