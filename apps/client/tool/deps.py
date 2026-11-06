#!/usr/bin/env python3
"""Check the pinned Linux build seat and resolve only locked app packages."""
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
SDK = Path(os.environ.get("FLUTTER_SDK", os.path.expanduser("~/.local/share/anj-cloud/toolchains/flutter-3.47.9")))
EXPECTED_FLUTTER = "3.47.9"
EXPECTED_DART = "3.13.7"


def main():
    if platform.system() != "Linux" or platform.machine() != "x86_64":
        sys.exit("Client checks require the qualified Linux x86_64 seat; other targets are pending.")
    missing = [name for name in ("clang++", "cmake", "ninja", "pkg-config", "openssl") if not shutil.which(name)]
    flutter = SDK / "bin/flutter"
    if not flutter.is_file():
        missing.append(f"Flutter {EXPECTED_FLUTTER} SDK (set FLUTTER_SDK to its directory)")
    if missing:
        sys.exit("Missing required client build tooling: " + ", ".join(missing) + ". No system packages were installed.")
    packages = subprocess.run(["pkg-config", "--exists", "gtk+-3.0", "libsecret-1"], check=False)
    if packages.returncode:
        sys.exit("Missing required Linux development packages: GTK3 and/or libsecret (pkg-config). No system packages were installed.")
    environment = os.environ.copy()
    environment.update(FLUTTER_SUPPRESS_ANALYTICS="true", DART_SUPPRESS_ANALYTICS="true")
    version = subprocess.run([str(flutter), "--suppress-analytics", "--version", "--machine"], check=True, text=True, capture_output=True, env=environment)
    metadata = json.loads(version.stdout)
    if metadata.get("frameworkVersion") != EXPECTED_FLUTTER or metadata.get("dartSdkVersion", "").split()[0] != EXPECTED_DART:
        sys.exit(f"Client SDK pin mismatch: require Flutter {EXPECTED_FLUTTER} / Dart {EXPECTED_DART}; set FLUTTER_SDK to the verified SDK.")
    subprocess.run([str(flutter), "--suppress-analytics", "pub", "get", "--enforce-lockfile"], cwd=ROOT, env=environment, check=True)
    print(f"PASS Linux client build prerequisites and locked packages; Flutter {EXPECTED_FLUTTER} / Dart {EXPECTED_DART}")


if __name__ == "__main__":
    main()
