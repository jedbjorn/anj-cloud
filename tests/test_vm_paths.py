"""Spec #20 rev7 interface constants shared by specs #21-#23 (deploy/vm/paths.py)."""

import json
from pathlib import Path
import subprocess
import sys
import unittest

from deploy.vm import paths

ROOT = Path(__file__).resolve().parent.parent


class InterfaceConstantsTests(unittest.TestCase):
    def test_state_layout_lives_on_the_data_disk(self):
        self.assertEqual(Path("/srv/anj-cloud/state"), paths.STATE_ROOT)
        for name in ("OPERATOR_DIR", "SECRETS_DIR", "RELEASE_DIR", "RUN_DIR", "HAPROXY_STATE_DIR", "HOUSEHOLD_ACL",
                     "EMERGENCY_STOP", "BACKUP_IN_PROGRESS", "RESTORE_IN_PROGRESS", "ALERT_SPOOL", "CLOUDFLARE_TOKEN",
                     "NTFY_TOPIC", "RESTIC_PASSWORD", "FIRST_PAIRING_CODE", "STACK_CONFIG"):
            self.assertTrue(getattr(paths, name).is_relative_to(paths.STATE_ROOT), name)
        self.assertEqual(Path("/srv/anj-cloud/state/haproxy/household.acl"), paths.HOUSEHOLD_ACL)
        self.assertEqual(Path("/run/anj-haproxy/admin.sock"), paths.HAPROXY_ADMIN_SOCKET)
        self.assertEqual(Path("/run/anj-cloud-gw/gateway.sock"), paths.GATEWAY_SOCKET)
        self.assertEqual(Path("/srv/anj-cloud/release/current"), paths.RELEASE_CURRENT)
        self.assertFalse(paths.RELEASE_CURRENT.is_relative_to(paths.STATE_ROOT))
        self.assertEqual(Path("/srv/anj-cloud/state/run/ddns-state.json"), paths.DDNS_STATE)
        self.assertEqual(paths.HAPROXY_STATE_DIR, paths.HOUSEHOLD_ACL.parent)

    def test_pm2_apps_dependencies_and_emergency_set_are_consistent(self):
        self.assertEqual(set(paths.STACK_APPS), set(paths.DEPENDENCIES))
        self.assertEqual(set(paths.STACK_APPS), set(paths.COMPOSE_SERVICE))
        for app, needs in paths.DEPENDENCIES.items():
            for need in needs:
                self.assertLess(paths.STACK_APPS.index(need), paths.STACK_APPS.index(app), (app, need))
        self.assertLessEqual(set(paths.EMERGENCY_APPS) | set(paths.QUIET_APPS), set(paths.STACK_APPS))
        self.assertEqual("access", paths.COMPOSE_SERVICE["gateway"])

    def test_json_view_for_shell_tools(self):
        output = subprocess.run([sys.executable, "-I", str(ROOT / "deploy" / "vm" / "paths.py"), "--json"],
                                capture_output=True, text=True, check=True).stdout
        data = json.loads(output)
        self.assertEqual("/srv/anj-cloud/state/run/emergency-stop", data["EMERGENCY_STOP"])
        self.assertEqual(list(paths.PROD_SUBCOMMANDS), data["PROD_SUBCOMMANDS"])


if __name__ == "__main__":
    unittest.main()
