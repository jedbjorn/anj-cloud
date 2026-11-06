"""Portable file names (decision #120, seam S1): a name Windows or macOS cannot hold is blocked
for every writer. The client's NamePolicy (apps/client/lib/core/sync/name_policy.dart) is the
same rule; both run tests/name_policy_vectors.json and share generated Unicode tables, so they
cannot drift.

Blocked, per path component:
- `reserved`: the Windows device names CON, PRN, AUX, NUL, COM1-9 and LPT1-9, in any ASCII case,
  alone or with any extension (`nul.txt`, `CON .txt`);
- `trailingDotOrSpace`: a name ending in '.' or ' ';
- `invalidCharacter`: any of < > : " / \\ | ? * or a C0 control character (U+0000-U+001F);
- `clash`: a name that differs from a sibling only by case or Unicode normalization, compared
  by fold key (canonical caseless matching, Unicode D145: NFD(casefold(NFD(name)))).

Existing names are never changed: the rule applies when a name is created or renamed.
"""

from .name_tables import CASEFOLD, COMBINING, DECOMPOSITION, UNICODE_VERSION

RESERVED = frozenset({"CON", "PRN", "AUX", "NUL", *("COM%d" % n for n in range(1, 10)), *("LPT%d" % n for n in range(1, 10))})
INVALID = frozenset('<>:"/\\|?*')
REASONS = ("empty", "invalidCharacter", "reserved", "trailingDotOrSpace", "clash")
ERROR = "name-not-portable"
TEXT = {
    "empty": "A name is required.",
    "invalidCharacter": "Names cannot contain < > : \" / \\ | ? * or control characters on other devices.",
    "reserved": "Windows reserves this name (CON, PRN, AUX, NUL, COM1-9, LPT1-9).",
    "trailingDotOrSpace": "Names cannot end with a dot or a space on other devices.",
    "clash": "Another item in this folder has the same name apart from upper/lower case or accents.",
}

_S_BASE, _L_BASE, _V_BASE, _T_BASE = 0xAC00, 0x1100, 0x1161, 0x11A7
_V_COUNT, _T_COUNT = 21, 28
_N_COUNT = _V_COUNT * _T_COUNT
_S_COUNT = 19 * _N_COUNT

__all__ = ["ERROR", "REASONS", "TEXT", "UNICODE_VERSION", "check", "clash", "fold_key"]


def check(name):
    """The reason `name` cannot exist on Windows or macOS, or None when it is portable."""
    if not name:
        return "empty"
    if any(char in INVALID or ord(char) < 0x20 for char in name):
        return "invalidCharacter"
    stem = name.split(".", 1)[0].rstrip(" ")
    if stem.isascii() and stem.upper() in RESERVED:
        return "reserved"
    if name[-1] in ". ":
        return "trailingDotOrSpace"
    return None


def _decompose(name):
    result = []
    for char in name:
        cp = ord(char)
        index = cp - _S_BASE
        if 0 <= index < _S_COUNT:
            result.append(_L_BASE + index // _N_COUNT)
            result.append(_V_BASE + (index % _N_COUNT) // _T_COUNT)
            if index % _T_COUNT:
                result.append(_T_BASE + index % _T_COUNT)
        else:
            result.extend(DECOMPOSITION.get(cp, (cp,)))
    # Canonical ordering: a stable sort of each run of non-starters by combining class.
    start = 0
    while start < len(result):
        if COMBINING.get(result[start], 0) == 0:
            start += 1
            continue
        end = start
        while end < len(result) and COMBINING.get(result[end], 0) != 0:
            end += 1
        result[start:end] = sorted(result[start:end], key=lambda cp: COMBINING[cp])
        start = end
    return result


def fold_key(name):
    """Names with equal fold keys differ only by case or Unicode normalization."""
    folded = []
    for cp in _decompose(name):
        folded.extend(CASEFOLD.get(cp, (cp,)))
    return "".join(map(chr, _decompose("".join(map(chr, folded)))))


def clash(name, siblings):
    """The first sibling that differs from `name` only by case or normalization, else None.
    A sibling with exactly the same name is the same item, not a clash."""
    key = None
    for sibling in siblings:
        if sibling == name:
            continue
        key = fold_key(name) if key is None else key
        if fold_key(sibling) == key:
            return sibling
    return None
