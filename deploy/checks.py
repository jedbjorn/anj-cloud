"""Run declared server and Linux-client development checks in this checkout."""

import argparse
import os
from pathlib import Path
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--deps", action="store_true", help="Resolve pinned user-owned dependencies and check required host tooling")
    options, test_arguments = parser.parse_known_args()
    root = Path(__file__).resolve().parent.parent
    if options.deps:
        if test_arguments:
            parser.error("--deps does not accept test arguments")
        subprocess.run([sys.executable, "deploy/dev.py", "deps"], cwd=root, check=True)
        subprocess.run([sys.executable, "apps/client/tool/deps.py"], cwd=root, check=True)
        return
    python = root / "deploy/.local/access-venv/bin/python"
    if not python.exists():
        sys.exit("Run python3 deploy/checks.py --deps before tests")
    # Tests never read a real deployment profile: they run against the committed placeholders.
    environment = {**os.environ, "ANJ_PROFILE": str(root / "deploy/profile.example.toml")}
    subprocess.run([str(python), "-W", "error::ResourceWarning", "-m", "unittest", "discover", "-s", "tests", "-v", *test_arguments], cwd=root, check=True, env=environment)
    subprocess.run(["bash", "apps/client/tool/check.sh"], cwd=root, check=True)
    print("PASS combined server and Linux client checks; live gateway, desktop/keyring and laptop acceptance remain separate")


if __name__ == "__main__":
    main()
