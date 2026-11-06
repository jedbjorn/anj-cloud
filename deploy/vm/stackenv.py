"""Compose invocation for the production stack, shared by prod.py and run-service (stdlib only).

Both build the same `docker compose` command and environment from the state root's stack.json,
so a PM2-started service and an operator command always address the same release.
"""

import json
import os
from pathlib import Path

try:
    from . import paths
except ImportError:  # run from state/bin as a plain script directory
    import paths

ADMIN_USER = "anj-admin"
TRUSTED_DOMAINS = ("localhost", "nextcloud")


def load_config(state_root):
    path = Path(state_root) / "stack.json"
    return json.loads(path.read_text()) if path.exists() else {}


def release_dir(state_root, config):
    return Path(state_root) / "release" / config["release"][:12]


def compose_file(state_root, config):
    return release_dir(state_root, config) / "compose.json"


def image(config, project=paths.PROJECT):
    return f"{config.get('image_repository') or project + '-access'}:{config['release'][:12]}"


def environment(state_root, config, project=paths.PROJECT, base=None):
    """The variables compose.prod.json interpolates; inherited ANJ_/COMPOSE_ values are dropped."""
    state_root = Path(state_root)
    base = os.environ if base is None else base
    result = {key: value for key, value in base.items() if not key.startswith(("ANJ_", "COMPOSE_")) and key != "SC_DEV_PORT"}
    result.update(ANJ_SECRETS_DIR=str(state_root / "secrets"), ANJ_OPERATOR_DIR=str(state_root / "operator"),
                  ANJ_SOCKET_DIR=str(config.get("socket_dir") or paths.GATEWAY_SOCKET_DIR),
                  ANJ_HAPROXY_RUN_DIR=str(config.get("haproxy_run_dir") or paths.HAPROXY_RUN_DIR),
                  ANJ_CONSOLE_DIR=str(config.get("console_dir") or paths.CONSOLE_DIR),
                  ANJ_HAPROXY_STATE=str(state_root / "haproxy"))
    if config.get("host"):
        result.update(ANJ_HOST=config["host"], ANJ_ADMIN_USER=ADMIN_USER, ANJ_TRUSTED_DOMAINS=" ".join(TRUSTED_DOMAINS))
    if config.get("release"):
        result.update(ANJ_ACCESS_IMAGE=image(config, project),
                      ANJ_HAPROXY_CFG=str(release_dir(state_root, config) / "haproxy.cfg"))
    return result


def compose_command(state_root, config, project=paths.PROJECT):
    return ["docker", "compose", "--env-file", "/dev/null", "--project-name", project,
            "--file", str(compose_file(state_root, config))]
