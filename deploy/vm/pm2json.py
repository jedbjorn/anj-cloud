"""`pm2 jlist` output as JSON (spec #20/#21; anj-qual run b2dev-4).

The first `pm2` command of a user spawns its daemon and prints PM2's banner on stdout before the
JSON (an empty line, then "                        -------------" ...), so `json.loads(stdout)`
fails exactly on a fresh machine. jlist prints its JSON array on one line: take the last line
that parses as a list. Standard library only.
"""

import json


def jlist_rows(text):
    """The rows of `pm2 jlist` stdout; ValueError when no line is a JSON array."""
    if isinstance(text, bytes):
        text = text.decode("utf-8", "replace")
    if not (text or "").strip():
        return []
    for line in reversed(text.splitlines()):
        line = line.strip()
        if line.startswith("["):
            try:
                rows = json.loads(line)
            except ValueError:
                continue
            if isinstance(rows, list):
                return rows
    raise ValueError("pm2 jlist printed no JSON array")
