"""Upgrade this VM's anj-cloud installation from a reviewed local checkout.

Run from the root of the checkout after fast-forwarding it:

    python3 deploy/vm/local_upgrade.py [--no-backup]
"""

import argparse
from pathlib import Path
import subprocess
import sys
import tempfile

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent))

from deploy.prod import FULL_COMMIT  # noqa: E402
from deploy.vm import stage  # noqa: E402

CHECKOUT = Path(__file__).resolve().parent.parent.parent
SETUP = "/usr/local/bin/anj-cloud-setup"


def upgrade(checkout, *, no_backup=False, run=None):
    checkout = Path(checkout)
    run = subprocess.run if run is None else run
    full = stage.resolve("HEAD", checkout)
    if not FULL_COMMIT.fullmatch(full):
        raise RuntimeError("HEAD did not resolve to a full commit id")
    fetched = stage.git_ok(checkout, "fetch", "origin", "main", run=run)
    if fetched.returncode:
        raise RuntimeError("git fetch origin main failed")
    stage.check_upgrade("anj-prod", full, checkout, run=run)
    with tempfile.TemporaryDirectory(prefix="anj-local-upgrade-") as directory:
        source = Path(directory) / "source.tar"
        with source.open("wb") as output:
            archived = run(["git", "-C", str(checkout), "archive", "--format=tar", full],
                           stdout=output, stderr=subprocess.PIPE, check=False)
        if archived.returncode:
            raise RuntimeError("git archive failed")
        argv = ["sudo", SETUP, "upgrade", "--source", str(source), "--expect", full]
        if no_backup:
            argv.append("--no-backup")
        return run(argv, check=False).returncode


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--no-backup", action="store_true", help="Skip the backup before the switch (the setup warns)")
    args = parser.parse_args(argv)
    try:
        checkout = Path.cwd().resolve()
        if checkout != CHECKOUT:
            raise RuntimeError("run from the root of the anj-cloud checkout")
        return upgrade(checkout, no_backup=args.no_backup)
    except (OSError, subprocess.SubprocessError, RuntimeError) as error:
        print(f"local-upgrade: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
