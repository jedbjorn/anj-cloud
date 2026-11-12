"""Spec #20 production tooling: state root, trust profiles, user-add, releases, stack config.

Offline: real OpenSSL and a temporary git repository; no Docker and no host state.
"""

import contextlib
from datetime import datetime, timezone
import io
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from cryptography import x509
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID

from deploy import dev, prod
from deploy.vm import paths, render
from deploy.access_operator import Operator, main as operator_main, stack_for
from services.access import install_tls

ROOT = Path(__file__).resolve().parent.parent
HOST = "gateway.f15a.test"


def run_operator(*argv):
    with patch.object(sys, "argv", ["access_operator", *argv]), contextlib.redirect_stderr(io.StringIO()) as error, \
            contextlib.redirect_stdout(io.StringIO()) as output:
        code = operator_main()
    return code, output.getvalue(), error.getvalue()


class StateRootTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.base = Path(self.temporary.name)

    def tearDown(self):
        self.temporary.cleanup()

    def test_inside_any_git_worktree_is_refused(self):
        repository = self.base / "repo"
        (repository / ".git").mkdir(parents=True)
        worktree = self.base / "worktree"
        worktree.mkdir()
        (worktree / ".git").write_text("gitdir: elsewhere\n")
        for path in (repository / "state", repository / "deep" / "er" / "state", worktree / "state", ROOT / "deploy" / ".local" / "prod"):
            with self.subTest(path=str(path)), self.assertRaisesRegex(ValueError, "worktree"):
                prod.checked_state_root(path)
        # Through a symlinked parent too.
        (self.base / "link").symlink_to(repository)
        with self.assertRaisesRegex(ValueError, "worktree"):
            prod.checked_state_root(self.base / "link" / "state")

    def test_symlink_and_loose_modes_are_refused(self):
        target = self.base / "real"
        target.mkdir(mode=0o700)
        (self.base / "alias").symlink_to(target)
        with self.assertRaisesRegex(ValueError, "symlink"):
            prod.checked_state_root(self.base / "alias")
        loose = self.base / "loose"
        loose.mkdir()
        loose.chmod(0o755)
        with self.assertRaisesRegex(ValueError, "0700"):
            prod.checked_state_root(loose)
        root = self.base / "state"
        prod.checked_state_root(root)
        self.assertEqual(0o700, stat.S_IMODE(root.stat().st_mode))
        (root / "secrets").mkdir(mode=0o700)
        secret = root / "secrets" / "admin"
        secret.write_text("x")
        secret.chmod(0o644)
        with self.assertRaisesRegex(ValueError, "0600"):
            prod.checked_state_root(root)
        secret.chmod(0o600)
        (root / "secrets" / "link").symlink_to(secret)
        with self.assertRaisesRegex(ValueError, "symlink"):
            prod.checked_state_root(root)
        (root / "secrets" / "link").unlink()
        self.assertEqual(root, prod.checked_state_root(root))
        with self.assertRaisesRegex(ValueError, "absolute"):
            prod.checked_state_root("relative/state")

    def test_public_state_exemptions_are_exact_paths(self):
        root = self.base / "state"
        prod.checked_state_root(root)
        for directory in ("haproxy", "secrets", "run", "release", "release/aaaaaaaaaaaa"):
            (root / directory).mkdir(mode=0o700)
        (root / "haproxy").chmod(0o755)
        public = {"haproxy/household.acl", "haproxy/haproxy.cfg", "release/aaaaaaaaaaaa/haproxy.cfg"}
        for name in public:
            (root / name).write_text("public")
            (root / name).chmod(0o644)
        self.assertEqual(root, prod.checked_state_root(root))
        loose = {"secrets/household.acl": 0o644, "secrets/haproxy.cfg": 0o644, "run/haproxy.cfg": 0o644,
                 "release/aaaaaaaaaaaa/compose.json": 0o644, "haproxy/other.txt": 0o644, "haproxy/household.acl.bak": 0o644,
                 "release/notacommit12/haproxy.cfg": 0o644, "haproxy/household.acl": 0o666}
        for name, mode in loose.items():
            with self.subTest(name):
                path = root / name
                path.parent.mkdir(mode=0o700, exist_ok=True)
                existed = path.exists()
                path.write_text("x")
                path.chmod(mode)
                with self.assertRaisesRegex(ValueError, "0600"):
                    prod.check_private_tree(root)
                if existed:
                    path.chmod(0o644)
                else:
                    path.unlink()
        for name in ("run/haproxy", "secrets/haproxy", "release/haproxy"):
            with self.subTest(name):
                (root / name).mkdir(mode=0o755)
                (root / name).chmod(0o755)
                with self.assertRaisesRegex(ValueError, "0700"):
                    prod.check_private_tree(root)
                (root / name).rmdir()
        (root / "haproxy").chmod(0o775)
        with self.assertRaisesRegex(ValueError, "0700"):
            prod.check_private_tree(root)
        (root / "haproxy").chmod(0o755)
        prod.check_private_tree(root)

    def test_operator_state_root_rules_and_dev_defaults(self):
        code, _, error = run_operator("--state-root", str(self.base / "state"), "devices")
        self.assertEqual((1, True), (code, "--project" in error))
        code, _, error = run_operator("--project", "anj-cloud-prod", "devices")
        self.assertEqual((1, True), (code, "--state-root" in error))
        (self.base / "repo" / ".git").mkdir(parents=True)
        code, _, error = run_operator("--project", "anj-cloud-restore", "--state-root", str(self.base / "repo" / "state"), "devices")
        self.assertEqual((1, True), (code, "worktree" in error))
        code, _, error = run_operator("--project", "anj-cloud-restore", "--state-root", str(self.base / "empty"), "devices")
        self.assertEqual((1, True), (code, "setup" in error))
        # Without --state-root: the unchanged dev default, only for dev and review/test projects.
        stack = stack_for(None, 8834)
        self.assertEqual(("anj-cloud-dev", dev.ROOT / ".local" / "anj-cloud-dev"), (stack.project, stack.local))
        self.assertEqual(("anj-cloud Dev issuer", 365, "localhost", ("DNS:localhost", "IP:127.0.0.1"), 364),
                         tuple(stack.profile[key] for key in ("issuer_cn", "issuer_days", "server_cn", "server_san", "server_days")))
        self.assertEqual(("anj-dev-admin", "localhost 127.0.0.1 nextcloud"),
                         (stack.environment["ANJ_ADMIN_USER"], stack.environment["ANJ_TRUSTED_DOMAINS"]))
        for project in ("anj-cloud-review", "anj-cloud-review-2", "anj-cloud-test"):
            dev.Stack(project, 18834)
        for project in ("anj-cloud-prod", "anj-cloud-restore", "anj-cloud-qual"):
            with self.subTest(project), self.assertRaisesRegex(ValueError, "--state-root"):
                dev.Stack(project, 18834)

    def test_dev_compose_defaults_equal_the_previous_literals(self):
        compose = json.loads((ROOT / "deploy" / "compose.json").read_text())
        environment = compose["services"]["nextcloud"]["environment"]
        self.assertEqual("${ANJ_ADMIN_USER:-anj-dev-admin}", environment["NEXTCLOUD_ADMIN_USER"])
        self.assertEqual("${ANJ_TRUSTED_DOMAINS:-localhost 127.0.0.1 nextcloud}", environment["NEXTCLOUD_TRUSTED_DOMAINS"])
        access = compose["services"]["access"]
        self.assertEqual(["127.0.0.1:${SC_DEV_PORT:-8834}:8443"], access["ports"])
        self.assertEqual("0:0", access["user"])  # the existing dev volume keeps its owner
        self.assertNotIn("ANJ_LISTENER", access["environment"])
        self.assertIn("127.0.0.1:8443/health", " ".join(access["healthcheck"]["test"]))


class ProductionTrustTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name) / "state"
        self.stack = prod.ProdStack("anj-cloud-test-prod", self.root, socket_dir="/run/anj-cloud-test-gw")
        self.commit = "a" * 40

    def tearDown(self):
        self.temporary.cleanup()

    def test_setup_creates_household_issuer_and_host_only_server_certificate(self):
        with patch.object(self.stack, "resolve_commit", return_value=self.commit):
            result = self.stack.setup(HOST)
        self.assertEqual(("https://" + HOST, "aaaaaaaaaaaa"), (result["origin"], result["release"]))
        operator = self.root / "operator"
        issuer = x509.load_pem_x509_certificate((operator / "issuer.crt").read_bytes())
        server = x509.load_pem_x509_certificate((operator / "server.crt").read_bytes())
        self.assertEqual("anj-cloud Household issuer", issuer.subject.get_attributes_for_oid(NameOID.COMMON_NAME)[0].value)
        start, end = issuer.not_valid_before_utc, issuer.not_valid_after_utc
        self.assertEqual((start.year + 10, start.month, start.day), (end.year, end.month, end.day))
        constraints = issuer.extensions.get_extension_for_class(x509.BasicConstraints).value
        self.assertEqual((True, 0), (constraints.ca, constraints.path_length))
        self.assertIsInstance(issuer.public_key().curve, ec.SECP256R1)
        names = server.extensions.get_extension_for_class(x509.SubjectAlternativeName).value
        self.assertEqual([x509.DNSName(HOST)], list(names))
        self.assertEqual([ExtendedKeyUsageOID.SERVER_AUTH], list(server.extensions.get_extension_for_class(x509.ExtendedKeyUsage).value))
        self.assertAlmostEqual(365, (server.not_valid_after_utc - server.not_valid_before_utc).days, delta=1)
        server.verify_directly_issued_by(issuer)
        for path in [self.root, *self.root.rglob("*")]:
            mode = stat.S_IMODE(path.stat().st_mode)
            public = path.name in ("household.acl", "haproxy")
            expected = (0o755 if public else 0o700) if path.is_dir() else (0o644 if public else 0o600)
            self.assertEqual(expected, mode, str(path))
        self.assertEqual("", (self.root / "haproxy" / "household.acl").read_text())
        config = json.loads((self.root / "stack.json").read_text())
        self.assertEqual({"host": HOST, "release": self.commit, "socket_dir": "/run/anj-cloud-test-gw",
                          "image_repository": "anj-cloud-test-prod-access", "bind_address": "10.77.10.10",
                          "household_lan": "192.168.0.0/24", "vm_gid": os.getgid()}, config)
        prod.check_private_tree(self.root)
        self.assertEqual({"database", "admin"}, {path.name for path in (self.root / "secrets").iterdir()})
        # A restored state root opened under another project starts the recorded release image.
        restored = prod.ProdStack("anj-cloud-restore", self.root)
        self.assertEqual(("anj-cloud-test-prod-access:aaaaaaaaaaaa", HOST),
                         (restored.environment["ANJ_ACCESS_IMAGE"], restored.environment["ANJ_HOST"]))
        self.assertEqual(self.root / "release" / "aaaaaaaaaaaa" / "compose.json", restored.compose_file)
        # Idempotent; another host is refused; invalid hosts and ingress parameters are refused.
        self.stack.setup(HOST)
        for options in ({"bind_address": "0.0.0.0"}, {"bind_address": "::1"}, {"household_lan": "8.8.8.0/24"},
                        {"household_lan": "192.168.0.1/24"}):
            with self.subTest(options), self.assertRaises(ValueError):
                prod.ProdStack("anj-cloud-test-prod", Path(self.temporary.name) / "other").setup(HOST, **options)
        with self.assertRaisesRegex(RuntimeError, "already set up"):
            self.stack.setup("other.f15a.test")
        for bad in ("Family.Example.dev", "localhost", "127.0.0.1", "a..b", "-x.example.dev"):
            with self.subTest(bad), self.assertRaisesRegex(RuntimeError, "--host"):
                prod.ProdStack("anj-cloud-test-prod", Path(self.temporary.name) / ("s-" + str(abs(hash(bad))))).setup(bad)

    def test_user_add_writes_only_the_secret_file_and_refuses_fixture_accounts(self):
        with patch.object(self.stack, "resolve_commit", return_value=self.commit):
            self.stack.setup(HOST)
        accounts, calls = [], []

        def occ(*args):
            return json.dumps({name: name for name in accounts})

        def compose(*args, data=None):
            calls.append((args, data))
            accounts.append(args[-2])
            return ""
        with patch.object(self.stack, "occ", side_effect=occ), patch.object(self.stack, "compose", side_effect=compose):
            operator = Operator(self.stack)
            result = operator.user_add("sam", "Sam")
            password = (self.root / "secrets" / "sam").read_text().strip()
            self.assertRegex(password, r"^[0-9a-f]{64}$")
            self.assertEqual(0o600, stat.S_IMODE((self.root / "secrets" / "sam").stat().st_mode))
            self.assertEqual({"uid": "sam", "state": "created", "password_file": str(self.root / "secrets" / "sam")}, result)
            self.assertNotIn(password, json.dumps(result))
            args, data = calls[0]
            self.assertEqual(password + "\n", data)
            self.assertNotIn(password, " ".join(args))
            self.assertEqual(("sam", "Sam"), args[-2:])
            self.assertEqual({"uid": "sam", "state": "exists"}, operator.user_add("sam"))
            self.assertEqual(1, len(calls))
            self.assertEqual("created", operator.user_add("alex", "Alex")["state"])
            for bad in ("anj-fixture-alice", "Sam", "../x", "", "a b"):
                with self.subTest(bad), self.assertRaises(RuntimeError):
                    operator.user_add(bad)


class ReleaseTests(unittest.TestCase):
    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.repository), *args], capture_output=True, text=True, check=True,
                              env={**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.invalid",
                                   "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.invalid"}).stdout.strip()

    def commit(self, name):
        (self.repository / name).write_text(name)
        self.git("add", name)
        self.git("commit", "-q", "-m", name)
        return self.git("rev-parse", "HEAD")

    def test_release_commit_must_be_merged_and_carry_required_fixes(self):
        with tempfile.TemporaryDirectory() as directory:
            self.repository = Path(directory) / "repo"
            self.repository.mkdir()
            self.git("init", "-q", "-b", "main")
            spec19 = self.commit("spec19")
            before = self.commit("between")
            fixes = self.commit("fixes")
            merged = self.commit("merged")
            self.git("update-ref", "refs/remotes/origin/main", merged)
            self.git("checkout", "-q", "-b", "side")
            unmerged = self.commit("unmerged")
            self.git("checkout", "-q", "--orphan", "wrong")
            self.git("rm", "-q", "-rf", "--ignore-unmatch", ".")
            wrong = self.commit("wrong-history")
            stack = prod.ProdStack("anj-cloud-test-prod", Path(directory) / "state", checkout=self.repository)
            with patch.object(prod, "REQUIRED_COMMITS", {spec19[:7]: "spec 19", fixes[:7]: "fixes"}):
                self.assertEqual(merged, stack.resolve_commit(merged))
                self.assertEqual(merged, stack.resolve_commit(merged[:12]))
                self.assertEqual(merged, stack.resolve_commit("origin/main"))
                with self.assertRaisesRegex(RuntimeError, "not merged"):
                    stack.resolve_commit(unmerged[:12])
                self.assertEqual(unmerged, stack.resolve_commit(unmerged[:12], require_merged=False))
                with self.assertRaisesRegex(RuntimeError, "does not contain"):
                    stack.resolve_commit(before[:12])
                with self.assertRaisesRegex(RuntimeError, "does not contain"):
                    stack.resolve_commit(wrong, require_merged=False)
                for bad in ("main", "HEAD~1", "zzzzzzz", "abc", "d" * 40):
                    with self.subTest(bad), self.assertRaises(RuntimeError):
                        stack.resolve_commit(bad)

    def test_public_history_is_an_alternative_to_the_legacy_required_commits(self):
        with tempfile.TemporaryDirectory() as directory:
            self.repository = Path(directory) / "repo"
            self.repository.mkdir()
            self.git("init", "-q", "-b", "main")
            spec19 = self.commit("legacy-spec19")
            fixes = self.commit("legacy-fixes")
            self.git("checkout", "-q", "--orphan", "public")
            self.git("rm", "-q", "-rf", "--ignore-unmatch", ".")
            public = self.commit("initial-public-release")
            merged = self.commit("public-release")
            self.git("update-ref", "refs/remotes/origin/main", merged)
            self.git("checkout", "-q", "-b", "side")
            unmerged = self.commit("unmerged-public-release")
            self.git("checkout", "-q", "--orphan", "wrong")
            self.git("rm", "-q", "-rf", "--ignore-unmatch", ".")
            wrong = self.commit("wrong-history")
            stack = prod.ProdStack("anj-cloud-test-prod", Path(directory) / "state", checkout=self.repository)
            with patch.object(prod, "PUBLIC_HISTORY_COMMIT", public), \
                    patch.object(prod, "REQUIRED_COMMITS", {spec19[:7]: "spec 19", fixes[:7]: "fixes"}):
                self.assertEqual(public, stack.resolve_commit(public[:7]))
                self.assertEqual(merged, stack.resolve_commit(merged))
                self.assertEqual(merged, stack.resolve_commit(merged[:12]))
                self.assertEqual(merged, stack.resolve_commit("origin/main"))
                with self.assertRaisesRegex(RuntimeError, "not merged"):
                    stack.resolve_commit(unmerged[:12])
                self.assertEqual(unmerged, stack.resolve_commit(unmerged, require_merged=False))
                with self.assertRaisesRegex(RuntimeError, "does not contain"):
                    stack.resolve_commit(wrong, require_merged=False)
                with self.assertRaisesRegex(RuntimeError, "Unknown commit"):
                    stack.resolve_commit("d" * 40)

    def test_required_commits_are_the_spec_19_and_dev_fix_merges(self):
        self.assertEqual({"4c3bb82", "f554e13"}, set(prod.REQUIRED_COMMITS))
        self.assertEqual("cf8994f416bdc9d1f8c8bcc6710932f80221d608", prod.PUBLIC_HISTORY_COMMIT)

    def test_vm_defaults_and_root_refusal(self):
        self.assertEqual(Path("/srv/anj-cloud/state"), prod.DEFAULT_STATE_ROOT)
        self.assertFalse(hasattr(prod, "container_subuid"))
        with patch.object(prod.os, "geteuid", return_value=0), self.assertRaisesRegex(RuntimeError, "not root"):
            prod.refuse_root()
        with patch.object(prod.os, "geteuid", return_value=0), contextlib.redirect_stderr(io.StringIO()) as error:
            self.assertEqual(1, prod.main(["status"]))
        self.assertIn("not root", error.getvalue())
        self.assertEqual(paths.PROD_SUBCOMMANDS, tuple(prod.subcommands()))

    def test_outside_the_vm_a_command_says_where_it_runs_and_creates_nothing(self):
        """SC-110: `prod.py check` from the VM host's checkout tried to create /srv/anj-cloud and
        ended in a bare "PermissionError; diagnostic content withheld"."""
        with tempfile.TemporaryDirectory() as directory:
            missing = Path(directory) / "srv" / "anj-cloud" / "state"
            for command in ("check", "status"):
                with patch.object(prod, "DEFAULT_STATE_ROOT", missing), patch.object(prod, "refuse_root"), \
                        contextlib.redirect_stderr(io.StringIO()) as error:
                    self.assertEqual(1, prod.main([command]))
                self.assertIn(f"No production state root at {missing}: deploy/prod.py runs inside the production VM",
                              error.getvalue())
            self.assertFalse((Path(directory) / "srv").exists())


class CheckTests(unittest.TestCase):
    """`prod.py check`: PM2 online, restart policy no, limits, no ports, non-root, health, fresh TLS."""

    def container(self, service, **overrides):
        networks = {"access": {"anj-cloud-test-prod_proxy": {}}, "fetch-net": {"anj-cloud-test-prod_fetch": {}}}.get(service, {})
        mode = {"haproxy": "host", "fetch": "container:" + "f" * 64}.get(service, "bridge")
        image = "anj-cloud-test-prod-%s:aaaaaaaaaaaa" % ("fetch" if service in ("fetch", "fetch-net") else "access")
        container = {"Config": {"Labels": {"com.docker.compose.project": "anj-cloud-test-prod", "com.docker.compose.service": service},
                                "User": "0:0", "Image": image},
                     "NetworkSettings": {"Ports": {}, "Networks": networks},
                     "HostConfig": {"PortBindings": {}, "RestartPolicy": {"Name": "no"}, "LogConfig": {"Type": "journald"},
                                    "Memory": 268435456, "PidsLimit": 64, "NetworkMode": mode},
                     "Mounts": [{"Type": "bind", "Source": "/run/anj-cloud-gw"}],
                     "State": {"Running": True, "Status": "running", "Pid": 4242, "ExitCode": 0, "Health": {"Status": "healthy"}}}
        for path, value in overrides.items():
            target = container
            keys = path.split(".")
            for key in keys[:-1]:
                target = target[key]
            target[keys[-1]] = value
        return container

    def check(self, broken=None, identities=None, stale=(), apps=None, emergency=False, **overrides):
        with tempfile.TemporaryDirectory() as directory:
            stack = prod.ProdStack("anj-cloud-test-prod", Path(directory) / "state")
            stack.save_config(host=HOST, release="a" * 40, bind_address="10.77.10.10", household_lan="192.168.0.0/24", vm_gid=1000)
            if emergency:
                (stack.local / "run").mkdir(mode=0o700)
                (stack.local / "run" / "emergency-stop").write_text("{}")
                (stack.local / "run" / "emergency-stop").chmod(0o600)
            stopped = paths.EMERGENCY_APPS if emergency else ()
            services = [paths.COMPOSE_SERVICE[app] for app in paths.STACK_APPS if app not in stopped]
            containers = [self.container(service, **(overrides if service == broken else {})) for service in services]
            outputs = {"dbtype": "pgsql\n", "memcache.locking": "\\OC\\Memcache\\Redis\n", "user:list": json.dumps({"sam": "Sam", "alex": "Alex"})}
            identities = {"fetch": (10003, 0), **(identities or {"access": (10001, 0), "haproxy": (99, 0)})}
            states = apps or {app: {"status": "stopped" if app in stopped else "online", "restarts": 0, "pid": 1} for app in paths.STACK_APPS}
            with patch.object(stack, "containers", return_value=containers), \
                    patch.object(stack, "pm2_apps", return_value=states), \
                    patch.object(stack, "compose", return_value='{"status": "ready"}'), \
                    patch.object(stack, "occ", side_effect=lambda *args: outputs[args[-1] if args[0] != "user:list" else "user:list"]), \
                    patch.object(stack, "image_revision", return_value="a" * 40), \
                    patch.object(stack, "process_identity", side_effect=lambda c: identities[c["Config"]["Labels"]["com.docker.compose.service"]]), \
                    patch.object(stack, "tls_stale", return_value=list(stale)), \
                    patch.object(stack, "haproxy_ready", return_value=True), \
                    patch.object(stack, "verify_trust", return_value={}):
                return stack.check()

    def test_healthy_stack_passes_and_each_violation_is_refused(self):
        result = self.check()
        self.assertEqual((["alex", "sam"], "pm2", {"access": 10001, "haproxy": 99, "fetch": 10003}),
                         (result["accounts"], result["supervisor"], result["process_uids"]))
        violations = {
            ("access", "NetworkSettings.Ports"): {"8443/tcp": [{"HostIp": "127.0.0.1", "HostPort": "8834"}]},
            ("haproxy", "HostConfig.PortBindings"): {"443/tcp": [{"HostPort": "443"}]},
            ("db", "Mounts"): [{"Type": "bind", "Source": str(ROOT / "deploy")}],
            ("access", "NetworkSettings.Networks"): {"anj-cloud-test-prod_proxy": {}, "anj-cloud-test-prod_frontend": {}},
            ("nextcloud", "HostConfig.RestartPolicy"): {"Name": "unless-stopped"},
            ("redis", "HostConfig.RestartPolicy"): {"Name": "always"},
            ("cron", "HostConfig.Memory"): 0,
            ("haproxy", "HostConfig.PidsLimit"): 0,
            ("haproxy", "HostConfig.NetworkMode"): "bridge",
            ("access", "Config.Image"): "anj-cloud-test-prod-access:bbbbbbbbbbbb",
            ("access", "State.Running"): False,
            # The media fetch worker (spec #42): in fetch-net's namespace, fetch-net on the fetch network only.
            ("fetch", "HostConfig.NetworkMode"): "bridge",
            ("fetch-net", "NetworkSettings.Networks"): {"anj-cloud-test-prod_fetch": {}, "anj-cloud-test-prod_proxy": {}},
            ("fetch", "Config.Image"): "anj-cloud-test-prod-fetch:bbbbbbbbbbbb",
        }
        for (service, path), value in violations.items():
            with self.subTest(service=service, path=path), self.assertRaises(RuntimeError):
                self.check(service, **{path: value})
        for identities in ({"access": (0, 0), "haproxy": (99, 0)}, {"access": (10001, 0x2000), "haproxy": (99, 0)},
                           {"access": (10001, 0), "haproxy": (0, 0)}, {"access": (10001, 0), "haproxy": (99, 0x400)},
                           {"access": (1000, 0), "haproxy": (99, 0)}):
            with self.subTest(identities=identities), self.assertRaisesRegex(RuntimeError, "non-root|10001"):
                self.check(identities=identities)
        for worker in ((0, 0), (10003, 0x1000), (10001, 0)):
            with self.subTest(worker=worker), self.assertRaisesRegex(RuntimeError, "fetch process"):
                self.check(identities={"access": (10001, 0), "haproxy": (99, 0), "fetch": worker})
        with self.assertRaisesRegex(RuntimeError, "stale TLS"):
            self.check(stale=["server_crt", "server_key"])
        offline = {app: {"status": "errored" if app == "db" else "online"} for app in paths.STACK_APPS}
        with self.assertRaisesRegex(RuntimeError, "not online: db"):
            self.check(apps=offline)

    def test_emergency_stop_keeps_ingress_apps_out_of_the_expected_set(self):
        result = self.check(emergency=True)
        self.assertTrue(result["emergency_stop"])
        self.assertEqual(set(paths.STACK_APPS) - set(paths.EMERGENCY_APPS), set(result["apps"]))
        self.assertEqual({}, result["process_uids"])  # the media fetch worker is held stopped too

    def test_tls_refresh_is_a_pm2_restart_of_the_gateway(self):
        with tempfile.TemporaryDirectory() as directory:
            stack = prod.ProdStack("anj-cloud-test-prod", Path(directory) / "state")
            stack.save_config(host=HOST, release="a" * 40)
            calls = []
            outcomes = iter([["server_crt"], []])
            with patch.object(stack, "tls_stale", side_effect=lambda: next(outcomes)), \
                    patch.object(stack, "pm2", side_effect=lambda *args: calls.append(args) or ""), \
                    patch.object(stack, "wait_ready", side_effect=lambda apps: calls.append(("wait", tuple(apps)))):
                self.assertTrue(stack.ensure_tls_fresh())
            self.assertEqual([("restart", "gateway"), ("wait", ("gateway", "haproxy"))], calls)
            calls.clear()
            with patch.object(stack, "tls_stale", return_value=[]), patch.object(stack, "pm2", side_effect=lambda *a: calls.append(a)):
                self.assertFalse(stack.ensure_tls_fresh())
            self.assertEqual([], calls)
            with patch.object(stack, "tls_stale", return_value=["server_key"]), patch.object(stack, "pm2", return_value=""), \
                    patch.object(stack, "wait_ready"), self.assertRaisesRegex(RuntimeError, "still differ"):
                stack.ensure_tls_fresh()

    def test_tls_stale_compares_operator_files_with_the_loaded_copies(self):
        import hashlib
        with tempfile.TemporaryDirectory() as directory:
            stack = prod.ProdStack("anj-cloud-test-prod", Path(directory) / "state")
            stack.save_config(host=HOST, release="a" * 40)
            stack.operator_dir.mkdir(mode=0o700)
            loaded = {}
            for name, source in prod.TLS_SOURCES.items():
                (stack.operator_dir / source).write_text("material " + name)
                loaded[name] = hashlib.sha256(("material " + name).encode()).hexdigest()
            with patch.object(stack, "compose", return_value=json.dumps(loaded)):
                self.assertEqual([], stack.tls_stale())
            (stack.operator_dir / "server.crt").write_text("renewed")
            (stack.operator_dir / "server.key").write_text("renewed key")
            with patch.object(stack, "compose", return_value=json.dumps(loaded)):
                self.assertEqual(["server_crt", "server_key"], stack.tls_stale())


class StackConfigurationTests(unittest.TestCase):
    def setUp(self):
        self.compose = json.loads((ROOT / "deploy" / "compose.prod.json").read_text())
        self.template = (ROOT / "deploy" / "prod" / "haproxy.cfg.tmpl").read_text()
        self.haproxy = render.haproxy(self.template, vm_gid=1000)

    def test_production_compose(self):
        services = self.compose["services"]
        self.assertEqual(set(prod.SERVICES), set(services))
        self.assertEqual({"access", "nextcloud", "db", "redis", "cron", "haproxy", "fetch-net", "fetch"}, set(services))
        limits = {"db": ("512m", 128), "redis": ("256m", 64), "nextcloud": ("1536m", 256), "cron": ("384m", 64),
                  "access": ("256m", 64), "haproxy": ("128m", 64), "fetch-net": ("32m", 16), "fetch": ("512m", 128)}
        for name, service in services.items():
            self.assertNotIn("ports", service, name)
            self.assertNotIn("build", service, name)
            self.assertEqual("no", service["restart"], name)  # PM2 is the only supervisor (#85)
            self.assertEqual(limits[name], (service["mem_limit"], service["pids_limit"]), name)
            self.assertNotIn("privileged", service, name)
        # 3 GiB of limits for the file stack plus 544 MiB for the media fetch worker (spec #42) and its
        # guard; the 4 GiB VM relies on them not all peaking at once (see docs/self-hosting/requirements.md).
        self.assertLessEqual(sum(int(memory[:-1]) for memory, _ in limits.values()), 3616)
        access = services["access"]
        self.assertEqual(["proxy"], access["networks"])
        self.assertTrue(self.compose["networks"]["proxy"]["internal"] and self.compose["networks"]["backend"]["internal"])
        self.assertNotIn("frontend", self.compose["networks"])
        # DAC_READ_SEARCH: under the VM's rootful Docker container root is not the secrets' owner
        # (anj, 0600); it reads them once at start, then drops every capability (anj-qual b2dev-3).
        self.assertEqual(("0:0", ["python", "-m", "access.start"], ["CHOWN", "DAC_READ_SEARCH", "SETGID", "SETUID"]),
                         (access["user"], access["command"], access["cap_add"]))
        environment = access["environment"]
        self.assertEqual({"ANJ_ORIGIN": "https://${ANJ_HOST:?Run deploy/prod.py setup}", "ANJ_LISTENER": "proxy-unix", "ANJ_RUN_AS": "10001",
                          "ANJ_RUN_GROUPS": "10002,10004", "ANJ_SOCKET": "/run/anj-cloud-gw/gateway.sock", "ANJ_TLS_DIR": "/run/anj-tls",
                          "ANJ_MAX_TRANSFER_BYTES": str(64 * 2 ** 20), "ANJ_STAGING_BYTES": str(128 * 2 ** 20),
                          "ANJ_FETCH_SPOOL": "/var/lib/anj-fetch"}, environment)
        self.assertEqual(["CMD", "python", "-m", "access.health"], access["healthcheck"]["test"])
        self.assertEqual("journald", access["logging"]["driver"])
        self.assertTrue(access["read_only"])
        self.assertEqual(["ALL"], access["cap_drop"])
        self.assertEqual(["/tmp:size=16m,mode=1777", "/run/anj-tls:size=64k,mode=0700"], access["tmpfs"])
        bind = [volume for volume in access["volumes"] if isinstance(volume, dict)]
        self.assertEqual([("/run/anj-cloud-gw", False, False), ("/run/anj-console", False, True)],
                         [(volume["target"], volume["bind"]["create_host_path"], volume.get("read_only", False))
                          for volume in bind])
        # Decision #112 (1): the console backend's socket directory, private (2750 anj:anj-gw).
        self.assertEqual("${ANJ_CONSOLE_DIR:?Run deploy/prod.py setup}", bind[1]["source"])
        self.assertEqual(str(paths.CONSOLE_DIR), bind[1]["target"])
        self.assertNotIn("issuer.key", json.dumps(self.compose))
        nextcloud = services["nextcloud"]["environment"]
        self.assertEqual("${ANJ_ADMIN_USER:?Run deploy/prod.py setup}", nextcloud["NEXTCLOUD_ADMIN_USER"])
        self.assertEqual(("anj-admin", ("localhost", "nextcloud")),
                         (prod.production_profile(HOST)["admin_user"], prod.production_profile(HOST)["trusted_domains"]))
        self.assertNotIn("ANJ_DEV_STREAM_DELAY", json.dumps(self.compose))

    def test_haproxy_service(self):
        haproxy = self.compose["services"]["haproxy"]
        self.assertRegex(haproxy["image"], r"^haproxy:3\.4@sha256:[0-9a-f]{64}$")
        self.assertEqual(("host", ["ALL"], ["CHOWN", "NET_BIND_SERVICE", "SETGID", "SETUID"], True),
                         (haproxy["network_mode"], haproxy["cap_drop"], haproxy["cap_add"], haproxy["read_only"]))
        self.assertIn("no-new-privileges:true", haproxy["security_opt"])
        # Single process: HAProxy itself is PID 1 (the image entrypoint would add master-worker -W,
        # whose master keeps uid 0 and its capabilities). It drops to uid 99 after binding.
        self.assertEqual(["haproxy"], haproxy["entrypoint"])
        self.assertEqual(["-db", "-f", "/usr/local/etc/haproxy/haproxy.cfg"], haproxy["command"])
        self.assertNotIn("-W", haproxy["entrypoint"] + haproxy["command"])
        self.assertNotIn("master-worker", json.dumps(haproxy) + self.haproxy)
        mounts = {volume["target"]: (volume["source"], volume.get("read_only", False)) for volume in haproxy["volumes"]}
        self.assertEqual({"/usr/local/etc/haproxy/haproxy.cfg": True, str(paths.HAPROXY_STATE_DIR): True,
                          str(paths.GATEWAY_SOCKET_DIR): True, str(paths.HAPROXY_RUN_DIR): False},
                         {target: read_only for target, (source, read_only) in mounts.items()})
        for volume in haproxy["volumes"]:
            self.assertFalse(volume["bind"]["create_host_path"])
        self.assertNotIn("secrets", haproxy)

    def test_haproxy_template_renders_vm_values(self):
        lines = [line.strip() for line in self.haproxy.splitlines() if line.strip() and not line.strip().startswith("#")]
        self.assertNotIn("{{", self.haproxy)
        self.assertEqual(["bind 10.77.10.10:443"], [line for line in lines if line.startswith("bind")])
        self.assertIn("stats socket /run/anj-haproxy/admin.sock mode 660 gid 1000 level admin", lines)
        self.assertIn("log stdout format raw local0 info", lines)
        self.assertEqual(["user haproxy", "gid 10002"], [line for line in lines if line.startswith(("user ", "gid "))])
        self.assertIn("maxconn 256", lines)
        self.assertNotIn("chroot", self.haproxy.replace("No chroot", ""))
        self.assertEqual(["acl household src 192.168.0.0/24", "acl household src -f /srv/anj-cloud/state/haproxy/household.acl"],
                         [line for line in lines if line.startswith("acl ")])
        rules = [line for line in lines if line.startswith("tcp-request content")]
        self.assertEqual(["tcp-request content reject if household { sc0_conn_cur gt 64 }",
                          "tcp-request content reject if !household { sc0_conn_cur gt 20 }",
                          "tcp-request content reject if !household { sc0_conn_rate gt 60 }",
                          "tcp-request content accept if { req.ssl_hello_type 1 }",
                          "tcp-request content reject"], rules)
        for expected in ("tcp-request inspect-delay 10s", "timeout connect 5s", "timeout client 120s", "timeout server 120s",
                         "mode tcp", "tcp-request connection track-sc0 src"):
            self.assertIn(expected, lines)
        self.assertEqual(["server gateway unix@/run/anj-cloud-gw/gateway.sock send-proxy-v2 maxconn 128"],
                         [line for line in lines if line.startswith("server ")])
        self.assertNotIn("ssl", " ".join(line for line in lines if line.startswith(("bind", "server"))))
        other = render.haproxy(self.template, bind_address="10.77.11.10", household_lan="10.0.0.0/24", vm_gid=1001)
        self.assertIn("bind 10.77.11.10:443", other)
        self.assertIn("acl household src 10.0.0.0/24", other)
        for options in ({"bind_address": "0.0.0.0"}, {"bind_address": "127.0.0.1"}, {"household_lan": "1.2.3.0/24"},
                        {"vm_gid": 0}):
            with self.subTest(options), self.assertRaises(ValueError):
                render.haproxy(self.template, **{"vm_gid": 1000, **options})
        with self.assertRaisesRegex(ValueError, "placeholders"):
            render.haproxy(self.template + "{{UNKNOWN}}", vm_gid=1000)


class InstallTlsTests(unittest.TestCase):
    def test_installs_private_copies_for_the_gateway_user(self):
        with tempfile.TemporaryDirectory() as directory:
            source, target = Path(directory) / "secrets", Path(directory) / "tls"
            source.mkdir()
            target.mkdir()
            for name in install_tls.NAMES:
                (source / name).write_text("material " + name)
                (source / name).chmod(0o600)
            for _ in range(2):  # re-run replaces copies (renewal)
                install_tls.install(source, target, uid=os.getuid(), gid=os.getgid(), root=os.getuid())
            self.assertEqual(0o500, stat.S_IMODE(target.stat().st_mode))
            for name in install_tls.NAMES:
                self.assertEqual(0o400, stat.S_IMODE((target / name).stat().st_mode))
                self.assertEqual("material " + name, (target / name).read_text())
            self.assertEqual(set(install_tls.NAMES), {path.name for path in target.iterdir()})
            self.assertEqual(set(install_tls.NAMES), set(install_tls.digests(target)))
            target.chmod(0o700)

    def test_state_volume_is_handed_over_only_while_root_owns_it(self):
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "state"
            (state / "nested").mkdir(parents=True)
            (state / "nested" / "registry.sqlite").write_text("x")
            calls = []
            with patch.object(install_tls.os, "lchown", side_effect=lambda path, uid, gid: calls.append(Path(path).name)), \
                    patch.object(install_tls.os, "chown", side_effect=lambda path, uid, gid: calls.append(Path(path).name)):
                self.assertTrue(install_tls.own_state(state, root=os.getuid()))
                self.assertEqual({"nested", "registry.sqlite", "state"}, set(calls))
                calls.clear()
                self.assertFalse(install_tls.own_state(state, root=os.getuid() + 1))
                self.assertEqual([], calls)

    def test_image_keeps_dev_state_root_owned_and_runs_as_10001(self):
        dockerfile = (ROOT / "services" / "access" / "Dockerfile").read_text()
        self.assertIn("install -d -o 0 -g 0 -m 0700 /var/lib/anj", dockerfile)
        self.assertEqual("USER 10001:10001", [line for line in dockerfile.splitlines() if line.startswith("USER")][-1])
        access = json.loads((ROOT / "deploy" / "compose.prod.json").read_text())["services"]["access"]
        self.assertIn("access:/var/lib/anj", access["volumes"])

    def test_start_refreshes_copies_then_drops_and_execs_the_server(self):
        from services.access import privileges, start
        events = []
        with patch.dict(os.environ, {"ANJ_RUN_AS": "10001"}), patch.object(start.os, "getuid", return_value=0), \
                patch.object(start, "own_state", side_effect=lambda **kw: events.append(("own_state", kw))), \
                patch.object(start, "install", side_effect=lambda **kw: events.append(("install", kw))), \
                patch.object(start, "digests", return_value={"server_crt": "d"}), \
                patch.object(start, "verify", side_effect=lambda expected: events.append(("verify", expected))), \
                patch.object(start, "drop", side_effect=lambda: events.append(("drop",))), \
                patch.object(start.os, "execv", side_effect=lambda path, argv: events.append(("exec", argv[1:]))):
            start.main()
        self.assertEqual([("own_state", {"uid": 10001, "gid": 10001}), ("install", {"uid": 10001, "gid": 10001}), ("drop",),
                          ("verify", {"server_crt": "d"}), ("exec", ["-m", "access.server"])], events)
        with patch.object(start.os, "getuid", return_value=10001), self.assertRaises(SystemExit):
            start.main()
        with tempfile.TemporaryDirectory() as directory:
            source, target = Path(directory) / "secrets", Path(directory) / "tls"
            source.mkdir()
            target.mkdir()
            for name in install_tls.NAMES:
                (source / name).write_text("current " + name)
                (target / name).write_text("current " + name)
            self.assertTrue(start.verify(install_tls.digests(source), target))
            (source / "server_crt").write_text("renewed")
            with self.assertRaisesRegex(RuntimeError, "refusing to start"):
                start.verify(install_tls.digests(source), target)
        calls = []
        with patch.dict(os.environ, {"ANJ_RUN_AS": "10001"}), patch.object(privileges.os, "getuid", side_effect=[0, 10001]), \
                patch.object(privileges.os, "geteuid", return_value=10001), \
                patch.object(privileges.os, "setgroups", side_effect=lambda groups: calls.append(("groups", groups))), \
                patch.object(privileges.os, "setgid", side_effect=lambda gid: calls.append(("gid", gid))), \
                patch.object(privileges.os, "setuid", side_effect=lambda uid: calls.append(("uid", uid))):
            self.assertTrue(privileges.drop())
        self.assertEqual([("groups", []), ("gid", 10001), ("uid", 10001)], calls)
        calls.clear()
        # Production (decision #112 (1)): the one supplementary group anj-gw, for the console socket.
        with patch.dict(os.environ, {"ANJ_RUN_AS": "10001", "ANJ_RUN_GROUPS": "10002"}), \
                patch.object(privileges.os, "getuid", side_effect=[0, 10001]), \
                patch.object(privileges.os, "geteuid", return_value=10001), \
                patch.object(privileges.os, "setgroups", side_effect=lambda groups: calls.append(("groups", groups))), \
                patch.object(privileges.os, "setgid", side_effect=lambda gid: calls.append(("gid", gid))), \
                patch.object(privileges.os, "setuid", side_effect=lambda uid: calls.append(("uid", uid))):
            self.assertTrue(privileges.drop())
        self.assertEqual([("groups", [10002]), ("gid", 10001), ("uid", 10001)], calls)
        for value in ("0", "10002,0", "abc", "-5"):
            with patch.dict(os.environ, {"ANJ_RUN_AS": "10001", "ANJ_RUN_GROUPS": value}), \
                    patch.object(privileges.os, "getuid", return_value=0), \
                    patch.object(privileges.os, "setgroups") as setgroups:
                with self.assertRaises(ValueError, msg=value):
                    privileges.drop()
                setgroups.assert_not_called()
        with patch.dict(os.environ, {}, clear=True):
            self.assertFalse(privileges.drop())  # dev: no ANJ_RUN_AS, nothing changes


if __name__ == "__main__":
    unittest.main()
