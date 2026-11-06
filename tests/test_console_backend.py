"""Spec #27 console backend (VM socket service) and the recovery CLI."""

from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import ast
import io
import json
import os
from pathlib import Path
import re
import shlex
import socket
import stat
import sys
import tempfile
import threading
import time
import unittest
from types import SimpleNamespace
from unittest.mock import patch

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID

from deploy.access_operator import Operator
from deploy.vm import anj_cloud_admin as cli_module
from deploy.vm import console_backend as backend_module
from deploy.vm.anj_cloud_admin import Cli, CliError
from deploy.vm.console_backend import ACTIONS, Backend, Server

FINGERPRINT = "ab" * 32
PAIRING = "22222222-2222-4222-8222-222222222222"
DEVICE = "11111111-1111-4111-8111-111111111111"


class FakeStack(SimpleNamespace):
    def __init__(self, root):
        root = Path(root)
        super().__init__(local=root / "stack", secret_dir=root / "stack" / "secrets", occ_calls=[], tokens={"alex": [{"id": 7, "name": "anj-device-x"}]},
                         users={"sam": "Sam", "alex": "Alex"}, compose_calls=[], profile=None)
        self.local.mkdir(mode=0o700)

    def occ(self, *args):
        self.occ_calls.append(args)
        if args[0] == "user:list":
            return json.dumps(self.users)
        if args[0] == "user:auth-tokens:list":
            return json.dumps(self.tokens.get(args[-1], []))
        if args[0] == "user:auth-tokens:delete":
            uid, token = args[-2], args[-1]
            self.tokens[uid] = [row for row in self.tokens.get(uid, []) if str(row["id"]) != token]
        return ""

    def compose(self, *args, data=None):
        self.compose_calls.append(args)
        if args[:1] == ("ps",):
            return '{"Service":"access","State":"running","Health":"healthy"}\n{"Service":"db","State":"running","Health":""}\n'
        return ""


class FakeOperator(Operator):
    """Real operator flock and journals; signing, gateway and Nextcloud faked."""

    def __init__(self, stack):
        super().__init__(stack)
        self.calls = []

    def call(self, action, **data):
        self.calls.append((action, data))
        if getattr(self, "gateway_down", False):
            raise RuntimeError("Command failed (exit 1); output withheld: docker")
        if action == "admin" and data.get("op") == "user-admin" and data.get("admin") is False and data.get("uid") == "sam":
            raise RuntimeError("Operator action rejected: last-admin: Make another user an admin first.")
        if action == "admin" and data.get("op") == "devices":
            return {"devices": [{"id": "11111111-1111-4111-8111-111111111111", "uid": "alex", "label": "Phone"}]}
        if action == "admin" and data.get("op") == "users":
            return {"users": [{"uid": "sam", "admin": True, "enabled": True}, {"uid": "alex", "admin": False, "enabled": True}]}
        return {"state": "ok"}

    def approve(self, identity, fingerprint):
        with self.lock():
            if fingerprint != FINGERPRINT:
                raise RuntimeError("Operator action rejected: Fingerprint mismatch")
            return {"state": "active", "device_id": "dev-1"}

    def reissue(self, identity, force=False):
        with self.lock():
            return {"device_id": identity, "state": "reissued", "expires_at": 2.0, "certificate_id": "c" * 64}

    def account_set(self, uid, display_name=None, enabled=None):
        self.calls.append(("account_set", {"uid": uid, "enabled": enabled}))
        failure = getattr(self, "disable_failure", None)
        if failure:
            raise RuntimeError(failure)
        return {"account": {"uid": uid, "enabled": False}, "changed": True, "nextcloud": "disabled"}

    def user_add(self, uid, display_name=None):
        with self.lock():
            return {"uid": uid, "state": "created", "password_file": "/srv/anj-cloud/state/secrets/" + uid}


def certificate(path, days):
    key = ec.generate_private_key(ec.SECP256R1())
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "fixture")])
    now = datetime.now(timezone.utc)
    cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(key.public_key()).serial_number(1)
            .not_valid_before(now - timedelta(days=1)).not_valid_after(now + timedelta(days=days)).sign(key, hashes.SHA256()))
    path.write_bytes(cert.public_bytes(serialization.Encoding.PEM))


class BackendCase(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.stack = FakeStack(self.root)
        self.operator = FakeOperator(self.stack)
        self.backend = Backend(self.operator, production=False)

    def tearDown(self):
        self.temporary.cleanup()


class ActionTests(BackendCase):
    def test_only_the_fixed_allowlist_is_served(self):
        self.assertEqual(("approve", "reissue", "user-add", "nextcloud-enabled", "token-cleanup", "health", "test-alert",
                          "admin-alert", "account-disable"), ACTIONS)
        for request in ({"action": "revoke", "device_id": "x"}, {"action": "invite"}, {"action": "accounts-import"}, [], {"no": 1}):
            self.assertEqual("refused", self.backend.handle(request)["error"])
        self.assertEqual("refused", self.backend.handle({"action": "approve", "pairing_id": "p", "fingerprint": FINGERPRINT, "x": 1})["error"])
        self.assertEqual([], self.operator.calls)

    def test_approve_reissue_and_user_add_never_return_secrets(self):
        self.assertEqual({"state": "active", "device_id": "dev-1"},
                         self.backend.handle({"action": "approve", "pairing_id": PAIRING, "fingerprint": FINGERPRINT}))
        self.assertEqual("fingerprint-mismatch", self.backend.handle({"action": "approve", "pairing_id": PAIRING, "fingerprint": "cd" * 32})["error"])
        self.assertEqual({"device_id": DEVICE, "state": "reissued", "expires_at": 2.0}, self.backend.handle({"action": "reissue", "device_id": DEVICE}))
        reply = self.backend.handle({"action": "user-add", "uid": "zoe", "display_name": "Zoe"})
        self.assertEqual({"uid": "zoe", "state": "created"}, reply)
        self.assertNotIn("secrets", json.dumps(reply))

    def test_nextcloud_enabled_and_token_cleanup(self):
        self.assertEqual({"uid": "alex", "enabled": False}, self.backend.handle({"action": "nextcloud-enabled", "uid": "alex", "enabled": False}))
        self.assertIn(("user:disable", "--", "alex"), self.stack.occ_calls)
        self.assertEqual("refused", self.backend.handle({"action": "nextcloud-enabled", "uid": "alex", "enabled": "no"})["error"])
        self.assertEqual({"state": "done"}, self.backend.handle({"action": "token-cleanup", "uid": "alex", "token_id": "7"}))
        self.assertEqual([], self.stack.tokens["alex"])
        self.assertEqual({"state": "done"}, self.backend.handle({"action": "token-cleanup", "uid": "alex", "token_id": "7"}), "idempotent")
        self.stack.occ = lambda *args: json.dumps([{"id": 8}]) if args[0] == "user:auth-tokens:list" else ""
        self.assertEqual("token-cleanup-pending", self.backend.handle({"action": "token-cleanup", "uid": "alex", "token_id": "8"})["error"])

    def test_failures_are_curated(self):
        self.operator.reissue = lambda *a, **k: (_ for _ in ()).throw(KeyError("/srv/anj-cloud/state/operator/issuer.key"))
        reply = self.backend.handle({"action": "reissue", "device_id": DEVICE})
        self.assertEqual({"error": "failed", "message": "The admin service could not complete this; details withheld."}, reply)


class AccountDisableTests(BackendCase):
    def test_runs_the_operator_cli_disable_path(self):
        self.assertEqual({"uid": "alex", "enabled": False, "nextcloud": "disabled"},
                         self.backend.handle({"action": "account-disable", "uid": "alex"}))
        self.assertEqual([("account_set", {"uid": "alex", "enabled": False})], self.operator.calls)

    def test_refusals_keep_their_class_and_text(self):
        text = ("Could not read this account's shares to record where recipients mount them; the account was not disabled. "
                "Retry the disable.")
        for failure, reason, message in (("Operator action rejected: " + text, "share-mounts-unrecorded", text),
                                         ("Operator action rejected: Make another user an admin first.", "last-admin",
                                          "Make another user an admin first.")):
            self.operator.disable_failure = failure
            self.assertEqual({"error": reason, "message": message}, self.backend.handle({"action": "account-disable", "uid": "alex"}))
        self.assertEqual("refused", self.backend.handle({"action": "account-disable", "uid": "Alex!"})["error"])
        self.assertEqual("refused", self.backend.handle({"action": "account-disable", "uid": "alex", "token": "x"})["error"])

    def test_the_owner_token_is_journaled_and_removed_even_when_the_gateway_refuses(self):
        """The real Operator.account_set path: mint, journal, call, delete in finally."""
        operator = Operator(self.stack)
        tokens = []

        def occ(*args):
            self.stack.occ_calls.append(args)
            if args[0] == "user:auth-tokens:add":
                tokens.append({"id": 99, "name": args[3]})
                return "app password:\n\nsecret-owner-token-123\n"
            if args[0] == "user:auth-tokens:list":
                return json.dumps(tokens)
            if args[0] == "user:auth-tokens:delete":
                tokens.clear()
            return ""
        self.stack.occ = occ
        seen = {}

        def call(action, **data):
            if action == "accounts":
                return [{"uid": "alex", "display_name": "Alex", "enabled": True}]
            seen.update(data)
            assert (operator.directory / "reconciliation-token.json").exists(), "journaled before use"
            raise RuntimeError("Operator action rejected: Could not read this account's shares to record where recipients "
                               "mount them; the account was not disabled. Retry the disable.")
        operator.call = call
        backend = Backend(operator, production=False)
        with patch("deploy.access_operator.token_from_output", lambda output: "secret-owner-token-123"):
            reply = backend.handle({"action": "account-disable", "uid": "alex"})
        self.assertEqual("share-mounts-unrecorded", reply["error"])
        self.assertEqual("secret-owner-token-123", seen["token"])
        self.assertEqual([], tokens, "the temporary token is deleted")
        self.assertFalse((operator.directory / "reconciliation-token.json").exists())
        self.assertNotIn(("user:disable", "alex"), self.stack.occ_calls, "Nextcloud is never disabled after a refusal")
        self.assertNotIn("secret-owner-token", json.dumps(reply))


class AdminAlertTests(BackendCase):
    def dispatcher(self, ntfy_port):
        path = self.root / "anj-alert"
        # Test stand-in for spec #21's dispatcher: posts MESSAGE with its title to the local mock ntfy.
        path.write_text("#!%s\nimport sys,urllib.request\na=sys.argv[1:];m=a[a.index('--')+1]\n"
                        "urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:%d/topic',data=m.encode(),"
                        "headers={'Title':a[a.index('--title')+1],'X-Key':a[a.index('--key')+1],'X-Every':a[a.index('--every')+1]},"
                        "method='POST'),timeout=5).read()\n" % (sys.executable, ntfy_port))
        path.chmod(0o700)
        return path

    def test_schema_is_strict_and_takes_no_free_text(self):
        for request in ({"event": "role-grant", "actor_uid": "sam", "target_uid": "alex", "message": "free text"},
                        {"event": "anything", "actor_uid": "sam", "target_uid": "alex"},
                        {"event": "role-grant", "actor_uid": "Sam Smith", "target_uid": "alex"},
                        {"event": "role-grant", "actor_uid": "sam", "target_uid": "../alex"},
                        {"event": "device-revoke", "actor_uid": "sam", "target_uid": "alex"},
                        {"event": "role-grant", "actor_uid": "sam", "target_uid": "alex", "device_id": "11111111-1111-4111-8111-111111111111"},
                        {"event": "device-revoke", "actor_uid": "sam", "target_uid": "alex", "device_id": "not-an-id"},
                        {"event": "role-grant", "actor_uid": "sam"},
                        {"event": "device-approve-other", "actor_uid": "sam", "target_uid": "alex"},
                        {"event": "device-invite-other", "actor_uid": "sam", "target_uid": "alex", "device_id": "11111111-1111-4111-8111-111111111111"}):
            with self.subTest(request=request):
                self.assertEqual("refused", self.backend.handle({"action": "admin-alert", **request})["error"])

    def test_one_message_per_event_from_the_fixed_templates_to_a_local_mock_ntfy(self):
        received = []

        class Ntfy(BaseHTTPRequestHandler):
            def do_POST(self):
                received.append((self.headers["Title"], self.headers["X-Key"], self.headers["X-Every"],
                                 self.rfile.read(int(self.headers["Content-Length"])).decode()))
                self.send_response(200)
                self.end_headers()

            def log_message(self, *args):
                pass

        server = ThreadingHTTPServer(("127.0.0.1", 0), Ntfy)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            backend = Backend(self.operator, production=False, alert_command=self.dispatcher(server.server_port))
            device = "11111111-1111-4111-8111-111111111111"
            for request in ({"event": "role-grant", "actor_uid": "sam", "target_uid": "alex"},
                            {"event": "role-remove", "actor_uid": "recovery-cli", "target_uid": "alex"},
                            {"event": "user-disable", "actor_uid": "sam", "target_uid": "alex"},
                            {"event": "device-revoke", "actor_uid": "sam", "target_uid": "alex", "device_id": device},
                            {"event": "device-invite-other", "actor_uid": "sam", "target_uid": "alex"},
                            {"event": "device-approve-other", "actor_uid": "sam", "target_uid": "alex", "device_id": device}):
                self.assertEqual({"state": "sent"}, backend.handle({"action": "admin-alert", **request}))
        finally:
            server.shutdown()
            server.server_close()
        self.assertEqual([("anj-cloud admin", "admin", "0", "anj-cloud admin: sam made alex an admin"),
                          ("anj-cloud admin", "admin", "0", "anj-cloud admin: recovery-cli removed the admin role of alex"),
                          ("anj-cloud admin", "admin", "0", "anj-cloud admin: sam disabled alex"),
                          ("anj-cloud admin", "admin", "0", "anj-cloud admin: sam revoked a device of alex"),
                          ("anj-cloud admin", "admin", "0", "anj-cloud admin: sam created a pairing code for a device of alex"),
                          ("anj-cloud admin", "admin", "0", "anj-cloud admin: sam approved a new device for alex")], received)

    def test_without_a_dispatcher_the_alert_is_spooled(self):
        reply = self.backend.handle({"action": "admin-alert", "event": "role-grant", "actor_uid": "sam", "target_uid": "alex"})
        self.assertEqual({"state": "spooled"}, reply)
        [record] = list((self.stack.local / "run" / "alerts").glob("*-admin.json"))
        self.assertEqual(0o600, stat.S_IMODE(record.stat().st_mode))
        data = json.loads(record.read_text())
        self.assertEqual(set(backend_module.paths.ALERT_SPOOL_FIELDS), set(data))
        self.assertEqual(("admin", "anj-cloud admin", "anj-cloud admin: sam made alex an admin"), (data["key"], data["title"], data["message"]))


class ArgumentTests(BackendCase):
    """M3 probes: nothing from a request is ever read as an occ option (decision #103)."""

    def test_option_like_and_invalid_values_never_reach_occ(self):
        probes = [{"action": "nextcloud-enabled", "uid": uid, "enabled": False}
                  for uid in ("--help", "-x", "--all", "", "Alex", "a b", 7, "a" * 33, "a;b")]
        probes += [{"action": "token-cleanup", "uid": uid, "token_id": "7"} for uid in ("--help", "-q", "Alex", "")]
        probes += [{"action": "token-cleanup", "uid": "alex", "token_id": token} for token in ("--all", "-1", "7 8", "x", 7, "")]
        probes += [{"action": "user-add", "uid": uid, "display_name": "X"} for uid in ("--help", "-x", "1amy", "admin", "anj-admin")]
        probes += [{"action": "user-add", "uid": "zoe", "display_name": name} for name in ("\u202ex", " Zoe", "")]
        probes += [{"action": "account-disable", "uid": "--help"}, {"action": "reissue", "device_id": "--help"},
                   {"action": "approve", "pairing_id": "--help", "fingerprint": FINGERPRINT}]
        for probe in probes:
            with self.subTest(probe=probe):
                self.assertEqual("refused", self.backend.handle(probe)["error"])
        self.assertEqual([], self.stack.occ_calls)
        self.assertEqual([], self.operator.calls)

    def test_valid_values_follow_a_double_dash_even_when_they_look_like_options(self):
        for uid in ("alex", "1amy", "a-b"):
            self.stack.occ_calls.clear()
            self.backend.handle({"action": "nextcloud-enabled", "uid": uid, "enabled": True})
            self.backend.handle({"action": "token-cleanup", "uid": uid, "token_id": "7"})
            self.assertTrue(self.stack.occ_calls)
            for call in self.stack.occ_calls:
                self.assertEqual(uid, call[call.index("--") + 1], call)
                self.assertNotIn(uid, call[:call.index("--")], "never before the end of options")

    def test_user_add_creates_new_accounts_only(self):
        self.operator.user_add = lambda uid, name=None: {"uid": uid, "state": "exists"}
        reply = self.backend.handle({"action": "user-add", "uid": "sam", "display_name": "Sam"})
        self.assertEqual("exists", reply["error"])
        # SC-041: `resume` never adopts a server account this tooling did not create (no
        # secrets/<uid>, which Operator.user_add writes before it creates an account).
        reply = self.backend.handle({"action": "user-add", "uid": "sam", "display_name": "Sam", "resume": True})
        self.assertEqual("exists", reply["error"])
        self.stack.secret_dir.mkdir(mode=0o700)
        (self.stack.secret_dir / "sam").write_text("x")
        self.assertEqual({"uid": "sam", "state": "exists"},
                         self.backend.handle({"action": "user-add", "uid": "sam", "display_name": "Sam", "resume": True}))

    def test_the_operator_refuses_reserved_and_invalid_ids_and_passes_the_id_after_double_dash(self):
        for uid in ("admin", "anj-admin", "recovery-cli", "1amy", "-x", "sam.smith"):
            with self.assertRaises(RuntimeError, msg=uid):
                Operator(self.stack).user_add(uid, "X")
        import inspect
        self.assertIn('-- "$1"', inspect.getsource(Operator.user_add))

    def test_technical_operator_text_is_not_returned(self):
        def broken(*args, **kwargs):
            raise RuntimeError("Command failed (exit 1); output withheld: docker")
        self.operator.reissue = broken
        self.assertEqual({"error": "failed", "message": backend_module.GENERIC}, self.backend.handle({"action": "reissue", "device_id": DEVICE}))


# Review L1 (PR #43, 46dfe40): every way the code invokes Nextcloud's occ, checked statically.
# Decision #103: (1) a value that is not a literal goes after "--" (an option's own value,
# "--name NAME" or "--opt=" + value, excepted); (2) no uid starts with '-' (the one id rule in
# services/access/naming.py, asserted below; runtime refusals are tested in ArgumentTests and
# test_console_admin). Forms scanned in deploy/ and services/:
#   - a call to occ or an occ wrapper: x.occ(...), occ(...), run_occ(...);
#   - an argv sequence holding "occ" or ".../occ": ["php", "occ", ...], compose(..., "php", "occ", ...);
#   - shell text running "php [path/]occ", "./occ" or "/path/occ": every command in it, in Python
#     strings and in the non-Python files (*.sh, compose and unit files);
#   - shell text built by formatting (f-string, %, +, .format): always refused, since an
#     interpolated value cannot be shown to sit behind "--"; pass it as "$1" instead.
# A site that cannot meet rule (1) by construction is listed here with the reason it was reviewed.
OCC_ALLOWLIST = {
    ("deploy/dev.py", "Stack.occ"): "The occ wrapper forwards *args unchanged; every .occ( call site is checked by this scan.",
    ("deploy/backup.py", "Backup.occ"): "The backup tool's occ wrapper forwards *args unchanged; every .occ( call site is checked.",
    ("deploy/dev.py", "Stack.trusted_domains"): "Positional values are str(index) of enumerate/range integers, which never start "
                                                 "with '-'; the domain only travels inside --value=.",
}

OCC_IN_TEXT = re.compile(r"(?:\bphp\s+(?:-\S+\s+)*(?:[\w.-]*/)*occ|(?<![\w.-])\.?(?:/[\w.-]+)*/occ)(?![\w.-])")
OCC_CALLABLE = re.compile(r"(?:\w+_)?occ(?:_\w+)?")
OCC_TEXT_SUFFIXES = (".sh", ".bash", ".json", ".yml", ".yaml", ".service", ".timer", ".conf", ".env", ".php")


def _literal(node):
    if isinstance(node, ast.Constant):
        return True
    if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Add) and isinstance(node.left, ast.Constant) \
            and isinstance(node.left.value, str) and node.left.value.startswith("--") and node.left.value.endswith("="):
        return True  # "--opt=" + value is always read as that option's value
    return isinstance(node, ast.IfExp) and _literal(node.body) and _literal(node.orelse)


def _check_arguments(args):
    """None when safe, else the index of the first non-literal value not behind '--'."""
    dash = next((index for index, arg in enumerate(args) if isinstance(arg, ast.Constant) and arg.value == "--"), None)
    for index, arg in enumerate(args):
        if _literal(arg):
            continue
        before = args[index - 1] if index else None
        option_value = (before is not None and isinstance(before, ast.Constant) and isinstance(before.value, str)
                        and before.value.startswith("--") and before.value != "--" and "=" not in before.value)
        if option_value and dash is not None and index < dash:
            continue
        if dash is None or index < dash:
            return index
    return None


def _script_offends(text):
    """True when an occ command in shell text has an expansion ($ or `) before '--', bar --opt=$x.

    Every occ command in the text is read, each up to its own end (; & | ( ) or a newline).
    Unreadable quoting is not proven safe, so it offends."""
    for match in OCC_IN_TEXT.finditer(text):
        lexer = shlex.shlex(text[match.end():].replace("\n", ";"), posix=True, punctuation_chars=";&|()")
        lexer.whitespace_split = True
        seen_dash = False
        try:
            for token in lexer:
                if token and all(char in ";&|()" for char in token):
                    break
                expands = "$" in token or "`" in token
                if token == "--":
                    seen_dash = True
                elif expands and not seen_dash:
                    name, equals, _ = token.partition("=")
                    if not (token.startswith("--") and equals and "$" not in name and "`" not in name):
                        return True
        except ValueError:
            return True
    return False


def _formatted_occ_text(node):
    """Shell text running occ that is assembled from a non-literal value."""
    def occ_constant(part):
        return isinstance(part, ast.Constant) and isinstance(part.value, str) and OCC_IN_TEXT.search(part.value)

    if isinstance(node, ast.JoinedStr):
        return any(occ_constant(part) for part in node.values) and not all(isinstance(part, ast.Constant) for part in node.values)
    if isinstance(node, ast.BinOp) and isinstance(node.op, (ast.Add, ast.Mod)):
        operands, stack = [], [node]
        while stack:
            item = stack.pop()
            if isinstance(item, ast.BinOp) and isinstance(item.op, (ast.Add, ast.Mod)):
                stack += [item.left, item.right]
            else:
                operands.append(item)
        return any(occ_constant(part) for part in operands) and not all(isinstance(part, ast.Constant) for part in operands)
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr in ("format", "format_map"):
        return bool(occ_constant(node.func.value))
    return False


def occ_sites_in(tree, path):
    sites, offenders = [], []

    def offend(node):
        location = "%s:%d" % (path, node.lineno)
        if location not in offenders:
            offenders.append(location)

    def visit(node, qualname):
        name = qualname
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            name = node.name if not qualname else qualname + "." + node.name
        arguments = None
        if isinstance(node, ast.Call) and OCC_CALLABLE.fullmatch(str(getattr(node.func, "attr", getattr(node.func, "id", "")))):
            arguments = node.args
        elif isinstance(node, (ast.Call, ast.List, ast.Tuple)):
            items = node.args if isinstance(node, ast.Call) else node.elts
            for index, item in enumerate(items):
                if isinstance(item, ast.Constant) and isinstance(item.value, str) and (item.value == "occ" or item.value.endswith("/occ")):
                    arguments = items[index + 1:]
                    break
        if arguments is not None:
            key = (path, qualname)
            unsafe = _check_arguments(list(arguments)) is not None
            site = {"path": path, "line": node.lineno, "key": key, "allowlisted": unsafe and key in OCC_ALLOWLIST}
            sites.append(site)
            if unsafe and not site["allowlisted"]:
                offend(node)
        if isinstance(node, ast.Constant) and isinstance(node.value, str) and OCC_IN_TEXT.search(node.value):
            sites.append({"path": path, "line": node.lineno, "key": (path, qualname), "allowlisted": False})
            if _script_offends(node.value):
                offend(node)
        if _formatted_occ_text(node):
            sites.append({"path": path, "line": node.lineno, "key": (path, qualname), "allowlisted": False})
            offend(node)
        for child in ast.iter_child_nodes(node):
            visit(child, name)

    visit(tree, "")
    return sites, offenders


def occ_sites_in_text(text, path):
    """Shell text outside Python (scripts, compose and unit files): each line running occ."""
    sites, offenders = [], []
    for number, line in enumerate(text.splitlines(), 1):
        if OCC_IN_TEXT.search(line):
            sites.append({"path": path, "line": number, "key": (path, ""), "allowlisted": False})
            if _script_offends(line):
                offenders.append("%s:%d" % (path, number))
    return sites, offenders


def occ_sites(root):
    sites, offenders = [], []
    for path in sorted(path for top in ("deploy", "services") for path in (root / top).rglob("*") if path.is_file()):
        relative = path.relative_to(root)
        if any(part.startswith(".") or part == "__pycache__" for part in relative.parts):
            continue  # deploy/.local holds the local venv and stack state, not source
        relative = str(relative)
        if path.suffix == ".py":
            found, bad = occ_sites_in(ast.parse(path.read_text()), relative)
        elif path.suffix in OCC_TEXT_SUFFIXES or path.name.startswith("Dockerfile") or path.parent.name == "bin":
            found, bad = occ_sites_in_text(path.read_text(errors="replace"), relative)
        else:
            continue
        sites += found
        offenders += bad
    return sites, offenders


class OccArgvTests(BackendCase):
    """Review N1 and L1: every occ invocation puts a uid or token id after '--'; no uid starts with '-'."""

    def test_every_occ_invocation_form_places_non_literal_values_after_double_dash(self):
        root = Path(__file__).resolve().parent.parent
        sites, offenders = occ_sites(root)
        self.assertGreater(len(sites), 20, "the scan sees the occ call sites")
        self.assertEqual([], offenders)
        used = {site["key"] for site in sites if site["allowlisted"]}
        self.assertEqual(set(OCC_ALLOWLIST), used, "every allowlist entry names a live site, and no other is exempt")
        self.assertTrue(all(len(reason) > 20 for reason in OCC_ALLOWLIST.values()))
        named = {(site["path"], site["line"]) for site in sites}
        for path, needle in (("deploy/vm/console_backend.py", '"user:enable" if enabled else "user:disable", "--", uid'),
                             ("deploy/access_operator.py", 'exec php occ user:add --password-from-env --display-name="$2" -- "$1"'),
                             ("deploy/dev.py", 'exec php occ user:add --password-from-env -- "$1"'),
                             ("deploy/backup.py", '["php", "occ", *args]'),
                             ("deploy/dev.py", '"nextcloud", "php", "occ", *args')):
            line = next(number for number, text in enumerate((root / path).read_text().splitlines(), 1) if needle in text)
            self.assertIn((path, line), named, "%s:%d is checked" % (path, line))

    def test_no_uid_rule_admits_a_leading_dash(self):
        from services.access import naming
        for value in ("-", "-x", "--help", "--all", "-a-b"):
            with self.subTest(uid=value):
                self.assertFalse(naming.valid_uid(value))
                self.assertFalse(naming.valid_new_uid(value))
                self.assertIsNone(naming.ACCOUNT_UID.fullmatch(value))

    def test_the_occ_scan_flags_every_unsafe_form(self):
        bad = {
            "non-literal value": 'self.occ("user:disable", uid)\n',
            "group command": 'self.occ("group:adduser", group, uid)\n',
            "files:scan": 'self.occ("files:scan", user)\n',
            "non-literal command": 'self.occ(command, "--", uid)\n',
            "conditional on a value": 'self.occ("user:enable" if on else command, uid)\n',
            "starred": 'self.occ("files:scan", *users)\n',
            "bare occ function": 'occ("user:delete", uid)\n',
            "occ wrapper name": 'self.run_occ("user:delete", uid)\n',
            "option value without dash": 'self.occ("user:auth-tokens:add", "--name", name, uid)\n',
            "value before dash": 'self.occ("user:auth-tokens:delete", uid, "--", token)\n',
            "compose php occ": 'self.compose("exec", "nextcloud", "php", "occ", "user:info", uid)\n',
            "argv list": 'run(["php", "occ", "user:delete", uid])\n',
            "argv tuple": 'run(("php", "occ", "user:delete", uid))\n',
            "occ by path": 'run(["php", "/var/www/html/occ", "user:delete", uid])\n',
            "dot-slash occ": 'run(["./occ", "user:delete", uid])\n',
            "sh script": "script = 'exec php occ user:add --password-from-env \"$1\"'\n",
            "sh script, second command": "script = 'php occ user:list -- \"$1\"; php occ user:delete \"$1\"'\n",
            "sh script, next line": "script = 'php occ user:list -- x\\nphp occ user:delete \"$1\"'\n",
            "sh script, backticks": "script = 'php occ user:delete `cat uid`'\n",
            "sh script, option without =": "script = 'php occ user:add --display-name \"$2\" -- \"$1\"'\n",
            "sh script, ./occ": "script = 'cd /var/www/html && ./occ user:delete \"$1\"'\n",
            "sh script, unreadable quoting": "script = 'php occ user:delete \"$1'\n",
            "f-string": 'script = f"php occ user:delete {uid}"\n',
            "f-string after dash": 'script = f"php occ user:delete -- {uid}"\n',
            "percent format": 'script = "php occ user:delete %s" % uid\n',
            "concatenation": 'script = "php occ user:delete " + uid\n',
            "str.format": 'script = "php occ user:delete {}".format(uid)\n',
        }
        for name, source in bad.items():
            with self.subTest(form=name):
                _, offenders = occ_sites_in(ast.parse(source), "snippet.py")
                self.assertEqual(["snippet.py:1"], offenders, name)
        good = ('self.occ("user:enable" if on else "user:disable", "--", uid)\n'
                'self.occ("user:auth-tokens:add", "--no-interaction", "--name", name, "--", uid)\n'
                'self.occ("config:system:set", "share_folder", "--value=" + folder)\n'
                'run(["php", "occ", "user:delete", "--", uid])\n'
                "script = 'exec php occ user:add --display-name=\"$2\" -- \"$1\"'\n"
                "script = 'php occ user:list --output=json; php occ user:delete -- \"$1\"'\n"
                'note = "Nextcloud occ or PM2: %s" % reason\n')
        sites, offenders = occ_sites_in(ast.parse(good), "snippet.py")
        self.assertEqual([], offenders)
        self.assertEqual(6, len({site["line"] for site in sites}), "the safe forms are still seen")
        for name, text in {"script": 'docker compose exec nextcloud php occ user:delete "$UID"\n',
                           "unit": "ExecStart=/usr/bin/php /var/www/html/occ files:scan $USER\n"}.items():
            with self.subTest(text=name):
                self.assertEqual(["x.sh:1"], occ_sites_in_text(text, "x.sh")[1])
        self.assertEqual([], occ_sites_in_text('php occ user:delete -- "$UID"\nphp occ background:cron\n', "x.sh")[1])

    def test_the_scan_fails_on_a_violation_planted_in_the_real_sources(self):
        root = Path(__file__).resolve().parent.parent
        plants = (
            ("deploy/vm/console_backend.py", '"user:enable" if enabled else "user:disable", "--", uid',
             '"user:enable" if enabled else "user:disable", uid'),
            ("deploy/access_operator.py", '--display-name="$2" -- "$1"', '--display-name="$2" "$1"'),
            ("deploy/dev.py", 'user:add --password-from-env -- "$1"', 'user:add --password-from-env "$1"'),
            ("deploy/access_operator.py", 'self.stack.occ("user:disable", "--", uid)', 'self.stack.occ("user:disable", uid)'),
            ("deploy/dev.py", 'self.occ("background:cron")', 'self.occ("files:scan", self.profile["admin_user"])'),
        )
        for path, safe, planted in plants:
            with self.subTest(path=path, planted=planted):
                text = (root / path).read_text()
                self.assertEqual(1, text.count(safe))
                line = text[:text.index(safe)].count("\n") + 1
                self.assertEqual([], occ_sites_in(ast.parse(text), path)[1])
                self.assertEqual(["%s:%d" % (path, line)], occ_sites_in(ast.parse(text.replace(safe, planted)), path)[1])

    def assert_after_dash(self, calls, *values):
        relevant = [call for call in calls if any(value in call for value in values)]
        self.assertTrue(relevant)
        for call in relevant:
            self.assertIn("--", call, call)
            for value in values:
                if value in call:
                    self.assertGreater(call.index(value), call.index("--"), call)

    def recording_operator(self, tokens):
        calls = []

        def occ(*args):
            calls.append(args)
            if args[0] == "user:auth-tokens:list":
                return json.dumps(tokens)
            if args[0] == "user:auth-tokens:add":
                tokens.append({"id": 41, "name": args[args.index("--name") + 1]})
                return "app password:\n\nsecret\n"
            if args[0] == "user:auth-tokens:delete":
                tokens[:] = [row for row in tokens if str(row["id"]) != args[-1]]
            return ""
        self.stack.occ = occ
        return Operator(self.stack), calls

    def test_operator_paths_put_the_uid_after_double_dash(self):
        operator, calls = self.recording_operator([{"id": 5, "name": "anj-device-x"}])
        operator.delete_named_tokens("1amy", "anj-device-x")
        operator.call = lambda action, **data: ({"state": "revoked", "token_id": "41", "uid": "1amy"} if action == "revoke"
                                                else [{"uid": "1amy", "display_name": "One", "enabled": True}] if action == "accounts"
                                                else {"account": {}, "changed": True})
        with patch("deploy.access_operator.token_from_output", lambda output: "secret"):
            operator.account_set("1amy", enabled=False)
            operator.account_set("1amy", enabled=True)
            operator.revoke("33333333-3333-4333-8333-333333333333")
        self.assert_after_dash(calls, "1amy")
        self.assert_after_dash([call for call in calls if call[0] == "user:auth-tokens:delete"], "1amy", "5")

    def test_approve_puts_the_uid_after_double_dash(self):
        operator, calls = self.recording_operator([])
        device = "44444444-4444-4444-8444-444444444444"

        def call(action, **data):
            if action == "begin":
                return {"device": device, "uid": "1amy", "csr": "-----CSR-----"}
            if action == "activate":
                return {"state": "active", "device_id": device}
            return {}
        operator.call = call
        operator.sign = lambda csr, target, identity, usage="clientAuth", days=None: target.write_text("CERT")
        with patch("deploy.access_operator.token_from_output", lambda output: "secret"):
            self.assertEqual("active", operator.approve("55555555-5555-4555-8555-555555555555", FINGERPRINT)["state"])
        self.assertIn("user:auth-tokens:add", [call[0] for call in calls])
        self.assert_after_dash(calls, "1amy")


class HealthTests(BackendCase):
    def test_dev_health_never_reads_pm2_backup_or_ddns(self):
        operator_dir = self.stack.local / "operator"
        operator_dir.mkdir(mode=0o700)
        certificate(operator_dir / "issuer.crt", 3650)
        certificate(operator_dir / "server.crt", 10)
        with patch.object(backend_module.subprocess, "run", side_effect=AssertionError("no subprocess on dev")):
            health = self.backend.handle({"action": "health"})
        for key in ("pm2", "backup", "ddns", "reboot_pending", "emergency_stop"):
            self.assertEqual({"state": "not-configured"}, health[key], key)
        states = {row["name"]: row["state"] for row in health["certificates"]["certificates"]}
        self.assertEqual({"issuer": "ok", "server": "expiring"}, states)
        self.assertEqual([{"service": "access", "state": "running", "health": "healthy"}, {"service": "db", "state": "running", "health": None}],
                         health["containers"]["services"])
        self.assertEqual("ok", health["data_disk"]["state"])


class ProductionPm2Tests(BackendCase):
    def test_pm2_jlist_with_the_first_spawn_banner_is_read(self):
        """Decision #112 (2): the shared tolerant parser, not json.loads (PM2's banner on a fresh VM)."""
        backend = Backend(self.operator, production=True, data_root=self.root)
        banner = ("\n                        -------------\n\n__/\\\\\\ PM2 banner\n"
                  + json.dumps([{"name": "console", "pm2_env": {"status": "online", "restart_time": 2}}]) + "\n")

        def run(argv, **_options):
            if argv[:2] == ["pm2", "jlist"]:
                return SimpleNamespace(stdout=banner, returncode=0)
            raise AssertionError(argv)
        with patch.object(backend_module.shutil, "which", return_value="/usr/local/bin/pm2"), \
                patch.object(backend_module.subprocess, "run", side_effect=run):
            self.assertEqual({"state": "ok", "apps": [{"name": "console", "status": "online", "restarts": 2}]}, backend.pm2())
        self.assertNotIn('json.loads(subprocess.run(["pm2"', Path(backend_module.__file__).read_text())


class AlertTests(BackendCase):
    def test_not_configured_without_topic_or_dispatcher(self):
        self.assertEqual("not-configured", self.backend.handle({"action": "test-alert"})["error"])
        self.stack.secret_dir.mkdir(mode=0o700)
        (self.stack.secret_dir / "ntfy-topic").write_text("topic")
        self.assertEqual("not-configured", self.backend.handle({"action": "test-alert"})["error"])

    def test_test_alert_reaches_a_local_mock_ntfy_server(self):
        received = []

        class Ntfy(BaseHTTPRequestHandler):
            def do_POST(self):
                received.append((self.path, self.headers.get("Title"), self.rfile.read(int(self.headers["Content-Length"])).decode()))
                self.send_response(200)
                self.end_headers()

            def log_message(self, *args):
                pass

        server = ThreadingHTTPServer(("127.0.0.1", 0), Ntfy)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            self.stack.secret_dir.mkdir(mode=0o700)
            (self.stack.secret_dir / "ntfy-topic").write_text("unguessable-topic-42\n")
            dispatcher = self.root / "anj-alert"
            # Test stand-in for spec #21's dispatcher interface: [--key K] [--title T] -- MESSAGE.
            dispatcher.write_text("#!%s\nimport os,sys,urllib.request\na=sys.argv[1:];m=a[a.index('--')+1];t=a[a.index('--title')+1]\n"
                                  "topic=open(os.environ['ANJ_NTFY_TOPIC_FILE']).read().strip()\n"
                                  "urllib.request.urlopen(urllib.request.Request(os.environ['MOCK_NTFY']+'/'+topic,data=m.encode(),"
                                  "headers={'Title':t},method='POST'),timeout=5).read()\n" % sys.executable)
            dispatcher.chmod(0o700)
            backend = Backend(self.operator, production=False, alert_command=dispatcher, clock=lambda: 1793600000.0)
            with patch.dict(os.environ, {"MOCK_NTFY": "http://127.0.0.1:%d" % server.server_port}):
                reply = backend.handle({"action": "test-alert"})
        finally:
            server.shutdown()
            server.server_close()
        self.assertEqual({"state": "sent"}, reply)
        self.assertEqual([("/unguessable-topic-42", "anj-cloud", "anj-cloud console test, 2026-11-02 06:13 UTC")], received)


class ImportTests(BackendCase):
    def test_first_admin_import_once_with_display_names_then_renamed(self):
        accounts = self.root / "accounts.json"
        accounts.write_text(json.dumps({"admins": ["sam"]}))
        backend = Backend(self.operator, production=False, accounts_file=accounts)
        self.assertTrue(backend.import_first_admins())
        self.assertEqual([("admin", {"op": "accounts-import", "accounts": [{"uid": "sam", "display_name": "Sam"}], "admins": ["sam"]})],
                         self.operator.calls)
        self.assertFalse(accounts.exists())
        self.assertTrue((self.root / "accounts.json.imported").exists())
        self.assertTrue(backend.import_first_admins(), "no file: no-op")
        self.assertEqual(1, len(self.operator.calls))

    def test_unknown_uid_is_refused_and_the_file_kept(self):
        accounts = self.root / "accounts.json"
        accounts.write_text(json.dumps({"admins": ["ghost"]}))
        backend = Backend(self.operator, production=False, accounts_file=accounts)
        alerts = []
        backend.safe_alert = lambda key, message: alerts.append(message)
        backend.import_first_admins()
        self.assertEqual([], self.operator.calls)
        self.assertTrue(accounts.exists())
        self.assertEqual(["anj-cloud: first-admin import refused (unknown account)"], alerts)

    def test_gateway_down_import_is_retried(self):
        accounts = self.root / "accounts.json"
        accounts.write_text(json.dumps({"admins": ["sam"]}))
        self.operator.gateway_down = True
        backend = Backend(self.operator, production=False, accounts_file=accounts)
        stop = threading.Event()
        with patch.object(backend_module, "IMPORT_RETRY_SECONDS", 0.05):
            thread = threading.Thread(target=backend.run_imports, args=(stop,))
            thread.start()
            time.sleep(0.2)
            self.assertTrue(accounts.exists())
            self.operator.gateway_down = False
            thread.join(5)
        stop.set()
        self.assertFalse(accounts.exists())

    def test_a_bad_recovery_line_is_quarantined_alerted_once_and_never_blocks_the_rest(self):
        path = self.operator.directory
        path.mkdir(mode=0o700, parents=True, exist_ok=True)
        good = '{"action":"user-admin","result":"gateway-unavailable","time":1.0,"target_uid":"alex"}'
        (path / "recovery-audit.jsonl").write_text(good + "\nnot json at all\n" + '{"action":"bad action!","result":"x","time":2}' + "\n")
        sent = []

        def call(action, **data):
            sent.append(data)
            return {"imported": 1, "skipped": 0, "rejected": [1] if len(data["entries"]) > 1 else []}
        self.operator.call = call
        alerts = []
        self.backend.safe_alert = lambda key, message: alerts.append((key, message))
        self.backend.import_recovery_audit()
        [batch] = sent
        self.assertEqual(2, len(batch["entries"]))
        self.assertTrue(all(len(entry["id"]) == 64 for entry in batch["entries"]), "entries without an id get a stable digest")
        rejected = (path / "recovery-audit.jsonl.rejected").read_text().splitlines()
        self.assertEqual(["not json at all", '{"action":"bad action!","result":"x","time":2}'], rejected)
        self.assertEqual(0o600, stat.S_IMODE((path / "recovery-audit.jsonl.rejected").stat().st_mode))
        self.assertEqual([("recovery-audit", "anj-cloud: 2 recovery audit line(s) were set aside as invalid")], alerts)
        self.assertFalse((path / "recovery-audit.jsonl").exists())
        (path / "recovery-audit.jsonl").write_text(good + "\n")
        self.backend.import_recovery_audit()
        self.assertEqual(batch["entries"][0]["id"], sent[1]["entries"][0]["id"], "the same line keeps its id, so a retry never duplicates")

    def test_recovery_audit_entries_are_imported_then_removed(self):
        path = self.operator.directory
        path.mkdir(mode=0o700, parents=True, exist_ok=True)
        (path / "recovery-audit.jsonl").write_text('{"action":"user-admin","result":"gateway-unavailable","time":1.0,"target_uid":"alex"}\n')
        self.backend.import_recovery_audit()
        self.assertEqual("audit-import", self.operator.calls[-1][1]["op"])
        self.assertFalse((path / "recovery-audit.jsonl").exists())


class SocketTests(BackendCase):
    def serve(self, allowed):
        path = self.root / "run" / "backend.sock"
        server = Server(path, self.backend, allowed)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(lambda: (server.shutdown(), server.server_close()))
        return path, server

    def request(self, path, payload):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(5)
            connection.connect(str(path))
            connection.sendall(json.dumps(payload).encode())
            connection.shutdown(socket.SHUT_WR)
            return connection.recv(65536)

    def test_unix_socket_only_with_private_mode(self):
        path, server = self.serve({os.getuid()})
        self.assertEqual(socket.AF_UNIX, server.socket.family)
        self.assertEqual(0o660, stat.S_IMODE(path.stat().st_mode))
        self.assertEqual({"uid": "alex", "enabled": True}, json.loads(self.request(path, {"action": "nextcloud-enabled", "uid": "alex", "enabled": True})))

    def test_a_peer_with_another_uid_gets_nothing_and_nothing_happens(self):
        path, _ = self.serve({10001})
        try:
            reply = self.request(path, {"action": "nextcloud-enabled", "uid": "alex", "enabled": False})
        except ConnectionResetError:
            reply = b""
        self.assertEqual(b"", reply)
        self.assertEqual([], self.stack.occ_calls)

    def test_a_socket_path_beyond_the_unix_limit_still_binds(self):
        deep = self.root / ("d" * 60) / ("e" * 60)
        deep.mkdir(parents=True)
        path = deep / "backend.sock"
        server = Server(path, self.backend, {os.getuid()})
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(lambda: (server.shutdown(), server.server_close()))
        self.assertTrue(path.is_socket())
        self.assertEqual({"uid": "alex", "enabled": True},
                         cli_module.backend_call(path, "nextcloud-enabled", uid="alex", enabled=True))

    def test_the_watchdog_probe_sees_a_serving_backend_and_changes_nothing(self):
        """Decision #112 (1): vmops.console_answers (the watchdog's check) against the real server."""
        sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "deploy" / "vm" / "ops"))
        try:
            import vmops
        finally:
            sys.path.pop(0)
        path, _ = self.serve({os.getuid()})
        self.assertTrue(vmops.console_answers(path, timeout=5))
        self.assertEqual(([], [], []), (self.stack.occ_calls, self.stack.compose_calls, self.operator.calls))
        self.assertFalse(vmops.console_answers(self.root / "missing.sock", timeout=5))
        other = self.root / "other" / "backend.sock"
        server = Server(other, self.backend, {10001})          # this uid is not allowed: no reply
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(lambda: (server.shutdown(), server.server_close()))
        self.assertFalse(vmops.console_answers(other, timeout=5))

    def test_production_start_refuses_a_socket_directory_with_the_wrong_owner_or_mode(self):
        directory = self.root / "anj-console"
        directory.mkdir(mode=0o750)
        directory.chmod(0o750)
        with self.assertRaisesRegex(RuntimeError, "mode 0o2750"):
            backend_module.check_socket_directory(directory)
        own = os.lstat(directory)
        directory.chmod(0o2750)
        backend_module.check_socket_directory(directory, gid=own.st_gid)
        with self.assertRaisesRegex(RuntimeError, "must be a directory"):
            backend_module.check_socket_directory(directory, gid=own.st_gid, uid=own.st_uid + 1)
        link = self.root / "link"
        link.symlink_to(directory)
        with self.assertRaisesRegex(RuntimeError, "must be a directory"):
            backend_module.check_socket_directory(link, gid=own.st_gid)
        directory.chmod(0o2770)
        with self.assertRaisesRegex(RuntimeError, "mode 0o2750"):
            backend_module.check_socket_directory(directory, gid=own.st_gid)

    def test_refuses_to_replace_a_regular_file(self):
        target = self.root / "run" / "backend.sock"
        target.parent.mkdir()
        target.write_text("not a socket")
        with self.assertRaises(RuntimeError):
            Server(target, self.backend, {os.getuid()})


class CliTests(BackendCase):
    def cli(self, answer="", yes=False):
        self.out = io.StringIO()
        return Cli(self.operator, self.root / "missing.sock", yes=yes, stdin=io.StringIO(answer), stdout=self.out, clock=lambda: 5.0)

    def run_cli(self, cli, *argv):
        return cli.run(cli_module.parser().parse_args(list(argv)))

    def test_destructive_commands_need_the_target_typed(self):
        with self.assertRaises(CliError):
            self.run_cli(self.cli("amyy\n"), "user-disable", "alex")
        self.assertEqual([], self.operator.calls)
        self.run_cli(self.cli("alex\n"), "user-disable", "alex")
        self.assertEqual(("admin", {"op": "user-enabled", "uid": "alex", "enabled": False}), self.operator.calls[-1])
        self.run_cli(self.cli(yes=True), "revoke", "11111111-1111-4111-8111-111111111111")
        self.assertEqual({"op": "revoke", "device_id": "11111111-1111-4111-8111-111111111111"}, self.operator.calls[-1][1])

    def test_last_admin_refusal_is_shown(self):
        with self.assertRaises(CliError) as caught:
            self.run_cli(self.cli("sam\n"), "admin-remove", "sam")
        self.assertIn("last-admin", str(caught.exception))
        self.assertEqual(["sam"], self.run_cli(self.cli(), "admins"))

    def test_gateway_down_records_the_attempt_locally(self):
        self.operator.gateway_down = True
        self.operator.directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        with self.assertRaises(CliError):
            self.run_cli(self.cli(yes=True), "admin-grant", "alex")
        path = self.operator.directory / "recovery-audit.jsonl"
        self.assertEqual(0o600, stat.S_IMODE(path.stat().st_mode))
        entry = json.loads(path.read_text())
        self.assertRegex(entry.pop("id"), "^[0-9a-f]{32}$")
        self.assertEqual({"action": "user-admin", "result": "gateway-unavailable", "target_uid": "alex", "time": 5.0}, entry)

    def test_lost_last_admin_recovery_commands(self):
        self.run_cli(self.cli(), "invite", "--user", "sam")
        self.assertEqual({"op": "invite", "uid": "sam", "grant": "write", "label": None}, self.operator.calls[-1][1])
        self.run_cli(self.cli(), "approve", "22222222-2222-4222-8222-222222222222", "--fingerprint", FINGERPRINT.upper())
        self.assertEqual({"op": "approve", "invitation_id": "22222222-2222-4222-8222-222222222222", "fingerprint": FINGERPRINT},
                         self.operator.calls[-1][1])

    def test_health_falls_back_to_the_gateway_when_the_backend_is_down(self):
        self.run_cli(self.cli(), "health")
        self.assertEqual({"op": "health"}, self.operator.calls[-1][1])


if __name__ == "__main__":
    unittest.main()
