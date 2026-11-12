"""Offline checks for boundaries that must hold before starting any containers."""

import contextlib
import io
import json
from pathlib import Path
import stat
import subprocess
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest.mock import patch

from deploy import dev


class FoundationTests(unittest.TestCase):
    def test_foreign_namespace_root_may_be_empty_but_must_not_list_children(self):
        root = "/remote.php/dav/files/alice/"
        empty = '<d:multistatus xmlns:d="DAV:"><d:response><d:href>' + root + '</d:href></d:response></d:multistatus>'
        dev.no_foreign_children(207, empty.encode(), root)
        dev.no_foreign_children(404, b"not found", root)
        children = empty.replace('</d:multistatus>', '<d:response><d:href>' + root + 'private.txt</d:href></d:response></d:multistatus>')
        with self.assertRaises(RuntimeError):
            dev.no_foreign_children(207, children.encode(), root)
        with self.assertRaises(RuntimeError):
            dev.no_foreign_children(200, b"unexpected content", root)

    def test_setup_is_private_and_preserves_existing_passwords(self):
        with tempfile.TemporaryDirectory() as root, patch.object(dev, "ROOT", Path(root)):
            stack = dev.Stack("anj-cloud-test", 18834)
            stack.venv_python.parent.mkdir(parents=True)
            stack.venv_python.touch()
            with contextlib.redirect_stdout(io.StringIO()) as output, patch.object(stack, "run", return_value=""):
                stack.setup()
                before = {p.name: p.read_bytes() for p in stack.secret_dir.iterdir()}
                stack.setup()
            self.assertEqual(before, {p.name: p.read_bytes() for p in stack.secret_dir.iterdir()})
            self.assertEqual(4, len(set(before.values())))
            for content in before.values():
                self.assertNotIn(content.decode().strip(), output.getvalue())
            for path in (stack.local, stack.secret_dir):
                self.assertEqual(0o700, stat.S_IMODE(path.stat().st_mode))
            for path in stack.secret_dir.iterdir():
                self.assertEqual(0o600, stat.S_IMODE(path.stat().st_mode))

    def test_setup_refuses_symlink_directory_and_permissive_secret(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            (root / "outside").mkdir()
            (root / "link").symlink_to(root / "outside")
            with self.assertRaises(RuntimeError):
                dev.private_directory(root / "link")
            path = root / "password"
            path.write_text("a" * 64)
            path.chmod(0o644)
            with self.assertRaises(RuntimeError):
                dev.secret_file(path)
            path.unlink()
            path.symlink_to(root / "outside" / "other")
            with self.assertRaises(RuntimeError):
                dev.secret_file(path)

    def test_project_and_port_cannot_escape_boundaries(self):
        for project in ("other-project", "anj-cloud-../escape", "anj-cloud-", "anj-cloud-A"):
            with self.assertRaises(ValueError):
                dev.Stack(project, 8834)
        for port in (80, -1, 65536):
            with self.assertRaises(ValueError):
                dev.Stack("anj-cloud-test", port)

    def test_compose_contains_no_host_storage_or_backend_ports(self):
        config = json.loads((dev.ROOT / "compose.json").read_text())
        services = config["services"]
        self.assertTrue(config["networks"]["backend"]["internal"])
        for name, service in services.items():
            if "build" not in service:
                self.assertRegex(service["image"], r":\d+\.\d+(?:\.\d+)?[^@]*@sha256:[a-f0-9]{64}$")
            self.assertNotIn("privileged", service)
            if name == "fetch":
                # Spec #42: the worker joins only fetch-net's namespace, where the network guard lives.
                self.assertEqual("service:fetch-net", service["network_mode"])
            else:
                self.assertNotIn("network_mode", service)
            self.assertNotIn("container_name", service)
            self.assertGreater(service["pids_limit"], 0)
            self.assertIn("mem_limit", service)
            self.assertIn("cpus", service)
            self.assertNotIn("restart", service)  # Explicit opt-in development lifecycle.
            for volume in service.get("volumes", []):
                if name == "access" and volume == "${ANJ_CONSOLE_DIR:?Run deploy/dev.py setup}:/run/anj-console":
                    continue  # spec #27: the console backend's socket directory only
                self.assertIn(volume.split(":")[0], config["volumes"])
            if name != "access":
                self.assertNotIn("ports", service)
                self.assertNotIn("frontend", service.get("networks", []))
        self.assertEqual(["127.0.0.1:${SC_DEV_PORT:-8834}:8443"], services["access"]["ports"])
        self.assertEqual({"issuer_crt", "server_crt", "server_key"}, set(services["access"]["secrets"]))
        self.assertNotIn("issuer.key", json.dumps(services["access"]))
        self.assertEqual("redis", services["nextcloud"]["environment"]["REDIS_HOST"])
        self.assertIn("POSTGRES_PASSWORD_FILE", services["nextcloud"]["environment"])

    def test_runtime_port_check_rejects_external_binding(self):
        stack = dev.Stack("anj-cloud-test", 18834)
        containers = []
        for service in ("access", "nextcloud", "db", "redis", "cron"):
            containers.append({"Config": {"Labels": {"com.docker.compose.project": stack.project,
                               "com.docker.compose.service": service}}, "State": {"Running": True},
                               "NetworkSettings": {"Ports": {"8443/tcp": [{"HostIp": "0.0.0.0", "HostPort": "18834"}]}
                                                   if service == "access" else {}}})
        with patch.object(stack, "compose", return_value="id"), patch.object(stack, "run", return_value=json.dumps(containers)):
            with self.assertRaisesRegex(RuntimeError, "Unexpected published ports"):
                stack.validate_ports()

    def test_subprocess_failure_does_not_echo_secret_output_or_input(self):
        stack = dev.Stack("anj-cloud-test", 18834)
        result = subprocess.CompletedProcess(["docker"], 1, "secret-stdout", "secret-stderr")
        with patch.object(dev.subprocess, "run", return_value=result):
            with self.assertRaises(RuntimeError) as error:
                stack.run(["docker", "compose"], data="secret-input")
            self.assertNotIn("secret", str(error.exception))

    def test_http_does_not_follow_redirects_with_credentials(self):
        requests = []
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                requests.append((self.path, self.headers.get("Authorization")))
                self.send_response(302 if self.path == "/redirect" else 200)
                self.send_header("Location", "/destination")
                self.end_headers()

            def log_message(self, *_):
                pass

        with tempfile.TemporaryDirectory() as root, patch.object(dev, "ROOT", Path(root)):
            server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                stack = dev.Stack("anj-cloud-test", server.server_port)
                stack.secret_dir.mkdir(parents=True)
                dev.secret_file(stack.secret_dir / dev.FIXTURE_USERS[0])
                with contextlib.redirect_stdout(io.StringIO()):
                    pass
                status, _ = stack.http("GET", "/redirect", dev.FIXTURE_USERS[0])
                self.assertEqual(302, status)
                self.assertEqual(1, len(requests))
                self.assertEqual("/redirect", requests[0][0])
                self.assertTrue(requests[0][1].startswith("Basic "))
            finally:
                server.shutdown()
                thread.join()
                server.server_close()


if __name__ == "__main__":
    unittest.main()
