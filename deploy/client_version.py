"""Source-controlled client release numbers, independent of repository history."""
import json
import os
from pathlib import Path
import subprocess

VERSION_PATH = "apps/client/release-version.json"
MAX_VERSION_CODE = 2100000000


def version_code(repo, commit, runner=subprocess.run):
    result = runner(["git", "-C", str(repo), "show", f"{commit}:{VERSION_PATH}"], capture_output=True)
    if result.returncode:
        raise ValueError(f"Commit {commit[:12]} has no {VERSION_PATH}; allocate a release number first")
    try:
        record = json.loads(result.stdout)
        code = record["version_code"]
        if set(record) != {"version_code"} or type(code) is not int or not 1 <= code <= MAX_VERSION_CODE:
            raise ValueError()
    except (ValueError, KeyError, TypeError):
        raise ValueError(f"{VERSION_PATH} must contain one integer version_code between 1 and {MAX_VERSION_CODE}") from None
    return code


def release_version(repo, commit):
    code = version_code(repo, commit)
    date = subprocess.run(["git", "-C", str(repo), "show", "-s", "--format=%cd",
                           "--date=format-local:%Y.%m.%d", commit], check=True, capture_output=True,
                          text=True, env={**os.environ, "TZ": "UTC"}).stdout.strip()
    return code, f"{date}.{code}"


if __name__ == "__main__":
    import sys
    code, version = release_version(Path(__file__).resolve().parent.parent, sys.argv[1])
    print(code, version)
