#!/usr/bin/env python3
"""The export gate: refuse a public tree that holds a secret, a household identifier or a Subfloor path.

    python3 tool/export_gate.py <dir>

Exit 0 only when all three checks pass; every hit is printed as path:line (never the secret itself).

1. Secret scan: gitleaks over the directory, with tool/gitleaks.toml (reviewed false positives). gitleaks is
   required: PATH, or GITLEAKS=/path/to/binary. Missing gitleaks is a failure, not a skip.
2. Identifier scan: the household identifiers to refuse come from the deployment profile, so this tree
   never contains them. They are the profile's own values (gateway host, zone id, LAN address, release key
   id, Android signer, account names) plus its `[export] deny_regex` list. Lines named in
   tool/gate_allowlist.txt are exempt (`<path regex><TAB><line regex>`).
3. Engine files: no Subfloor or agent path may exist.
"""

import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

from deploy import deployment_profile  # noqa: E402

ENGINE_PATHS = ("sc", "CLAUDE.md", "AGENTS.md", "opencode.json", ".sc-state", ".subfloor", ".super-coder", ".claude",
                ".agents", ".opencode", "shared", "specs_sc", "docs_sc")


def profile_patterns(profile):
    """[(label, compiled regex)] of this deployment's identifiers."""
    values = {
        "gateway host": profile["gateway"].get("host"), "gateway origin": profile["gateway"].get("origin"),
        "dns zone id": profile["dns"].get("zone_id"),
        "host interface": profile["host"].get("interface"), "backup drive uuid": profile["host"].get("backup_uuid"),
        "LAN address": profile["network"].get("lan_addr"), "router": profile["network"].get("router"),
        "release key id": profile["release"].get("key_id"),
        "release public key": (profile["release"].get("public_key") or "").split(" ")[-1],
        "android signer": profile["release"].get("android_signer_sha256"),
    }
    patterns = []
    example = deployment_profile.load({"ANJ_PROFILE": str(deployment_profile.EXAMPLE)})
    for label, value in values.items():
        placeholder_values = {example["gateway"]["host"], example["gateway"]["origin"], example["dns"]["zone_id"],
                              example["host"]["name"], example["host"]["interface"], example["host"]["backup_uuid"],
                              example["network"]["lan_addr"], example["network"]["router"], ""}
        if value and value not in placeholder_values:
            patterns.append((label, re.compile(re.escape(value), re.I)))
    for account in profile["household"].get("accounts", []):
        if account not in example["household"]["accounts"]:
            patterns.append(("household account", re.compile(rf"\b{re.escape(account)}\b", re.I)))
    for expression in profile.get("export", {}).get("deny_regex", []):
        patterns.append(("deny_regex", re.compile(expression)))
    return patterns


def load_allowlist(path):
    rules = []
    if path.is_file():
        for line in path.read_text().splitlines():
            if line.strip() and not line.startswith("#"):
                file_re, _, line_re = line.partition("\t")
                rules.append((re.compile(file_re), re.compile(line_re or ".")))
    return rules


def text_files(root):
    for path in sorted(Path(root).rglob("*")):
        if path.is_file() and not path.is_symlink():
            data = path.read_bytes()
            if b"\0" not in data[:4096]:
                yield path, data.decode("utf-8", "replace")


def identifier_scan(root, patterns, allowlist):
    hits = []
    for path, text in text_files(root):
        relative = path.relative_to(root).as_posix()
        if relative in ("tool/gate_allowlist.txt", "EXPORT-MANIFEST.txt"):   # both name what they exempt or exclude
            continue
        for number, line in enumerate(text.splitlines(), 1):
            for label, pattern in patterns:
                if pattern.search(line) and not any(f.search(relative) and l.search(line) for f, l in allowlist):
                    hits.append(f"{relative}:{number}: {label}")
    return hits


def secret_scan(root):
    binary = os.environ.get("GITLEAKS") or shutil.which("gitleaks")
    if not binary:
        return ["gitleaks not found (install it, or set GITLEAKS=/path/to/gitleaks)"]
    report = Path(root).parent / (Path(root).name + ".gitleaks.json")
    config = HERE / "gitleaks.toml"
    done = subprocess.run([binary, "dir", str(root), "--no-banner", "--redact", "-c", str(config),
                           "-r", str(report), "-f", "json"], capture_output=True, text=True)
    if done.returncode == 0:
        report.unlink(missing_ok=True)
        return []
    if done.returncode == 1 and report.is_file():
        findings = json.loads(report.read_text())
        report.unlink(missing_ok=True)
        return [f"{Path(f['File']).relative_to(root).as_posix()}:{f['StartLine']}: gitleaks {f['RuleID']}" for f in findings]
    return [f"gitleaks failed ({done.returncode}): {done.stderr.strip()[-200:]}"]


def engine_scan(root):
    return [f"{name}: Subfloor or agent path present" for name in ENGINE_PATHS if (Path(root) / name).exists()]


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if len(argv) != 1 or not Path(argv[0]).is_dir():
        sys.exit(__doc__)
    root = Path(argv[0]).resolve()
    profile = deployment_profile.load()
    patterns = profile_patterns(profile)
    failures = {
        "secret scan": secret_scan(root),
        "identifier scan": identifier_scan(root, patterns, load_allowlist(HERE / "gate_allowlist.txt")),
        "engine paths": engine_scan(root),
    }
    note = ""
    if profile["placeholder"] or not patterns:
        note = ("\nWARNING: no household identifiers were checked (no real deployment profile found). "
                "Run with ANJ_PROFILE or ~/.local/share/anj-cloud/profile.toml to refuse them.")
    bad = False
    for name, hits in failures.items():
        print(f"{'FAIL' if hits else 'pass'}  {name}" + (f" ({len(hits)})" if hits else ""))
        for hit in hits[:100]:
            print("   ", hit)
        bad = bad or bool(hits)
    print(f"identifier patterns checked: {len(patterns)}{note}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
