"""Drop container root to the gateway user (ANJ_RUN_AS) for production processes.

The production container starts as root only to refresh its TLS copies (access.start).
`docker exec` helpers (access.health, access.admin) inherit that root user, which holds no
CAP_DAC_OVERRIDE and cannot open the gateway's 10001-owned files and sockets, so they drop
first. Without ANJ_RUN_AS (dev) nothing changes.

ANJ_RUN_GROUPS (comma-separated gids) are the only supplementary groups kept: in production the
group anj-gw (10002), so the gateway reaches the console backend's 0660 socket in the 2750
anj:anj-gw directory (spec #27, decision #112 (1)). A group is not a capability: the process
still holds none.
"""

import os


def drop():
    target = os.environ.get("ANJ_RUN_AS")
    if not target or os.getuid() != 0:
        return False
    uid = int(target)
    if uid <= 0:
        raise ValueError("ANJ_RUN_AS must be a non-root uid")
    os.setgroups(run_groups())
    os.setgid(uid)
    os.setuid(uid)
    if os.getuid() != uid or os.geteuid() != uid:
        raise OSError("privilege drop failed")
    return True


def run_groups():
    """The supplementary gids from ANJ_RUN_GROUPS; never root's group, never a malformed value."""
    groups = []
    for text in os.environ.get("ANJ_RUN_GROUPS", "").split(","):
        text = text.strip()
        if not text:
            continue
        if not text.isdigit() or int(text) <= 0:
            raise ValueError("ANJ_RUN_GROUPS must list non-root gids")
        groups.append(int(text))
    return groups
