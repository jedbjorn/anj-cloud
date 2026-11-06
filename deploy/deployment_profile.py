"""The per-deployment profile: every value that belongs to one household rather than to the product.

Lookup order (first file found wins; a missing key falls back to the placeholder):
    1. $ANJ_PROFILE
    2. ~/.local/share/anj-cloud/profile.toml   (the real profile; keep it 0600, beside the keys)
    3. deploy/.local/profile.toml              (a checkout-local profile; untracked)
With no file the committed placeholders (deploy/profile.example.toml) apply and `placeholder` is True.

Standard library only (tomllib). Command line, for shell tools:
    python3 -I deploy/deployment_profile.py get gateway.host
    python3 -I deploy/deployment_profile.py --json
"""

import json
import os
from pathlib import Path
import sys
import tomllib

HERE = Path(__file__).resolve().parent
EXAMPLE = HERE / "profile.example.toml"
PLACEHOLDER_HOST = "gateway.example.com"


def search_paths(environ=None):
    environ = os.environ if environ is None else environ
    paths = []
    if environ.get("ANJ_PROFILE"):
        paths.append(Path(environ["ANJ_PROFILE"]).expanduser())
    home = Path(environ.get("HOME") or Path.home())
    paths.append(home / ".local/share/anj-cloud/profile.toml")
    paths.append(HERE / ".local/profile.toml")
    return paths


def _merge(base, over):
    out = dict(base)
    for key, value in over.items():
        out[key] = _merge(out[key], value) if isinstance(value, dict) and isinstance(out.get(key), dict) else value
    return out


def load(environ=None):
    """The profile as a dict, with `placeholder` (True when no real profile was found) and `source`."""
    environ = os.environ if environ is None else environ
    values = tomllib.loads(EXAMPLE.read_text())
    values["placeholder"], values["source"] = True, str(EXAMPLE)
    explicit = environ.get("ANJ_PROFILE")
    for path in search_paths(environ):
        if path.is_file():
            values = _merge(values, tomllib.loads(path.read_text()))
            values["placeholder"], values["source"] = path.resolve() == EXAMPLE.resolve(), str(path)
            break
        if explicit and path == Path(explicit).expanduser():
            raise FileNotFoundError(f"ANJ_PROFILE points at a missing file: {path}")
    return values


def get(dotted, environ=None):
    value = load(environ)
    for part in dotted.split("."):
        value = value[part]
    return value


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv == ["--json"]:
        print(json.dumps(load(), indent=2, sort_keys=True))
    elif len(argv) == 2 and argv[0] == "get":
        value = get(argv[1])
        print(",".join(map(str, value)) if isinstance(value, list) else value)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
