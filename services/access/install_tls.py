"""TLS copies and state ownership for the non-root gateway; called by access.start.

Compose file secrets are bind mounts that keep their host owner and 0600 mode (uid, gid and
mode are ignored outside Swarm), so the gateway's user 10001 cannot read them. As container
root with only CAP_CHOWN (and CAP_DAC_READ_SEARCH to read the host-owned sources under rootful Docker), `install` copies the issuer certificate, server certificate and server
key into a tmpfs as 0400 files owned by 10001; it runs on every container start. The issuer key
is never mounted into any container. `own_state` hands a state volume still owned by container
root (fresh, or restored) to 10001 and leaves an owned one alone.
"""

import hashlib
import json
import os
from pathlib import Path

SOURCE = Path("/run/secrets")
NAMES = ("issuer_crt", "server_crt", "server_key")
UID = GID = 10001


def install(source=SOURCE, target=None, uid=UID, gid=GID, root=0):
    target = Path(target or os.environ.get("ANJ_TLS_DIR", "/run/anj-tls"))
    # Take the directory back so root (owner) can write without CAP_DAC_OVERRIDE.
    os.chown(target, root, root)
    os.chmod(target, 0o700)
    for name in NAMES:
        data = (source / name).read_bytes()
        temporary = target / ("." + name + ".tmp")
        temporary.unlink(missing_ok=True)
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o400)
        try:
            os.write(fd, data)
            os.fsync(fd)
        finally:
            os.close(fd)
        os.chown(temporary, uid, gid)
        os.replace(temporary, target / name)
    os.chmod(target, 0o500)
    os.chown(target, uid, gid)


def digests(target=None):
    """SHA-256 of each installed copy, for the operator's freshness comparison (never logged)."""
    target = Path(target or os.environ.get("ANJ_TLS_DIR", "/run/anj-tls"))
    return {name: hashlib.sha256((target / name).read_bytes()).hexdigest() for name in NAMES}


def own_state(state=None, uid=UID, gid=GID, root=0):
    state = Path(state or os.environ.get("ANJ_STATE", "/var/lib/anj"))
    if state.stat().st_uid != root:
        return False
    for directory, names, files in os.walk(state):
        for name in names + files:
            os.lchown(os.path.join(directory, name), uid, gid)
    os.chown(state, uid, gid)
    return True


def own_spool(spool=None, uid=UID, gid=10004, root=0):
    """Hand the media fetch spool (spec #42), created root-owned by Docker, to the gateway user and
    the spool group shared with the worker; the gateway lays out the rest (access.fetch). Only the
    top directory: anything below it is the gateway's own or swept."""
    spool = spool or os.environ.get("ANJ_FETCH_SPOOL")
    if not spool:
        return False
    spool = Path(spool)
    if spool.stat().st_uid != root:
        return False
    os.chmod(spool, 0o2750)  # while root still owns it: no CAP_FOWNER is held
    os.chown(spool, uid, gid)
    return True


if __name__ == "__main__":
    # `docker exec … python -m access.install_tls`: report the loaded copies' digests.
    from .privileges import drop
    drop()
    print(json.dumps(digests()))
