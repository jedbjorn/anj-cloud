"""Production gateway start (spec #20; decision #81): fresh TLS copies on every container start.

Runs as the container's first process on every start, whatever starts the container (compose
up, a supervisor such as PM2 running it attached, dockerd's restart policy after a reboot or
crash, docker start/restart), so freshness never depends on a restart policy. As container root holding only
CAP_CHOWN, CAP_DAC_READ_SEARCH, CAP_SETUID and CAP_SETGID (under the VM's rootful Docker container root
is not the owner of the 0600 secrets, so it reads them with CAP_DAC_READ_SEARCH; it never writes them):

1. hands a root-owned state volume (fresh or restored) to the gateway user, and the media fetch
   spool (spec #42) to the gateway user and the spool group;
2. copies the issuer certificate, server certificate and server key from the compose secrets
   (0600, host-owned; Compose ignores secret uid/mode outside Swarm) into a tmpfs as 0400
   copies for the gateway user, so a renewed certificate is always loaded and no second copy
   of the key exists at rest;
3. drops to ANJ_RUN_AS (10001) with no capabilities;
4. verifies, as that user, each copy against its source's digest and refuses to start on any
   mismatch, then execs the gateway server.

The issuer key is never mounted. Nothing here logs file contents.
"""

import os
import sys

from .install_tls import NAMES, SOURCE, digests, install, own_spool, own_state
from .privileges import drop


def verify(expected, target=None):
    """The copies the server is about to load equal the sources' digests, or the start fails."""
    if digests(target) != expected:
        raise RuntimeError("TLS copies differ from the mounted sources; refusing to start")
    return True


def main():
    if os.getuid() != 0:
        raise SystemExit("access.start must run as container root to refresh the TLS copies")
    uid = int(os.environ["ANJ_RUN_AS"])
    own_state(uid=uid, gid=uid)
    own_spool(uid=uid)
    expected = digests(SOURCE)  # sources are readable only by container root
    install(uid=uid, gid=uid)
    drop()
    verify(expected)  # copies are readable only by the gateway user
    os.execv(sys.executable, [sys.executable, "-m", "access.server"])


if __name__ == "__main__":
    try:
        main()
    except (OSError, KeyError, ValueError, RuntimeError) as error:
        print("Gateway start failed: " + type(error).__name__, file=sys.stderr)
        sys.exit(1)
