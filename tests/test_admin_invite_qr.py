"""#97 review M3: `anj-cloud-admin invite` shows the code as a terminal QR code too, for the app's
Scan QR code; never when its output goes to a pipe or a file."""

import io
import json
import unittest
from unittest import mock

from deploy.vm import anj_cloud_admin as cli_module


class Tty(io.StringIO):
    def isatty(self):
        return True


class InviteQr(unittest.TestCase):
    def run_main(self, out, argv):
        seen = []

        def qr(value, runner=None):
            seen.append(value)
            return "<qr>\n"

        class FakeCli:
            def __init__(self, *args, **kwargs):
                pass

            def run(self, args):
                return {"id": "inv-1", "code": "0BCDEFGHJKMNPQRSTVWXYZ012345"} if args.command == "invite" \
                    else {"ok": True}

        with mock.patch.object(cli_module, "Cli", FakeCli), \
                mock.patch.object(cli_module, "Operator", lambda *a, **k: None), \
                mock.patch.object(cli_module, "stack_for", lambda *a, **k: None), \
                mock.patch.object(cli_module.guide, "qr_text", qr), \
                mock.patch("sys.stdout", out):
            self.assertEqual(cli_module.main(["--state-root", "/tmp/anj-none", *argv]), 0)
        return seen

    def test_terminal_invite_prints_the_code_and_its_qr_code(self):
        out = Tty()
        seen = self.run_main(out, ["invite", "--user", "alex"])
        self.assertEqual(seen, ["0BCDEFGHJKMNPQRSTVWXYZ012345"])
        text = out.getvalue()
        self.assertEqual(json.loads(text[:text.index("}") + 1])["code"], "0BCDEFGHJKMNPQRSTVWXYZ012345")
        self.assertIn("<qr>", text)

    def test_piped_invite_prints_json_only(self):
        out = io.StringIO()
        self.assertEqual(self.run_main(out, ["invite", "--user", "alex"]), [])
        self.assertEqual(json.loads(out.getvalue())["code"], "0BCDEFGHJKMNPQRSTVWXYZ012345")

    def test_other_commands_never_print_a_qr_code(self):
        out = Tty()
        self.assertEqual(self.run_main(out, ["users"]), [])


if __name__ == "__main__":
    unittest.main()
