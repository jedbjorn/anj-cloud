"""Source-controlled client release numbers, independent of repository history."""
import json
import os
import re
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


def check_github_version(repository, code, runner=subprocess.run):
    """Refuse reused/older allocations across all published and draft GitHub releases.

    This is publication bookkeeping, not client trust: devices still verify signatures.
    Recognize the original unified vDATE.CODE and Android-only DATE.CODE tags/assets.
    Read every page; a query/parse failure must never look like an empty repository.
    """
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        raise ValueError("Invalid GitHub repository")
    if type(code) is not int or not 1 <= code <= MAX_VERSION_CODE:
        raise ValueError("Invalid release number")
    result = runner(["gh", "api", "--paginate", "--slurp",
                     f"repos/{repository}/releases?per_page=100"], capture_output=True, text=True)
    if result.returncode:
        raise ValueError("Cannot verify GitHub release numbers; nothing was published")
    try:
        pages = json.loads(result.stdout)
        if not isinstance(pages, list) or any(not isinstance(page, list) for page in pages):
            raise ValueError()
        records = [record for page in pages for record in page]
        seen = []
        for record in records:
            tag = record["tag_name"]
            assets = record["assets"]
            if not isinstance(tag, str) or not isinstance(assets, list):
                raise ValueError()
            match = re.fullmatch(r"(?:v|android-)(?:[0-9]{4}\.[0-9]{1,2}\.[0-9]{1,2}\.)?([0-9]+)", tag)
            codes = [int(match[1])] if match else []
            client_asset = False
            for asset in assets:
                name = asset["name"]
                if not isinstance(name, str):
                    raise ValueError()
                if name.startswith("anj-cloud-") and name.endswith((".apk", ".zip", ".tar.gz")):
                    client_asset = True
                apk = re.fullmatch(r"anj-cloud-[0-9]{4}\.[0-9]{1,2}\.[0-9]{1,2}\.([0-9]+)\.apk", name)
                mac = re.fullmatch(r"anj-cloud-macos-arm64-.+\+([0-9]+)-[0-9a-f]{12}\.zip", name)
                if apk or mac:
                    codes.append(int((apk or mac)[1]))
            if (client_asset or tag.startswith("android-")) and not codes:
                raise ValueError()
            if codes and (len(set(codes)) != 1 or not 1 <= codes[0] <= MAX_VERSION_CODE):
                raise ValueError()
            seen.extend(codes)
    except (ValueError, TypeError, KeyError):
        raise ValueError("Cannot determine GitHub client release numbers; nothing was published") from None
    highest = max(seen, default=0)
    if code <= highest:
        raise ValueError(f"version_code {code} is not above GitHub's allocated release ({highest}); "
                         "releases are never replaced or reused")
    return highest


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("commit")
    parser.add_argument("--check-github", metavar="OWNER/REPO")
    args = parser.parse_args()
    code, version = release_version(Path(__file__).resolve().parent.parent, args.commit)
    if args.check_github:
        check_github_version(args.check_github, code)
    print(code, version)
