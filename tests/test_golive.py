"""Spec #23 go-live tooling: fingerprint, line check, hairpin/health, full scan and emergency stop.

Everything runs locally: a test CA and TLS server on 127.0.0.1, fake dig, nmap and docker.
"""

import contextlib
import io
import json
from pathlib import Path
import shlex
import socket
import ssl
import subprocess
import tempfile
import threading
import unittest
from types import SimpleNamespace
from unittest.mock import patch

from deploy import ddns, golive

HOST = "gateway.example.com"
HOME_IP = "5.6.7.20"


def openssl(*args, cwd):
    subprocess.run(["openssl", *args], cwd=cwd, check=True, capture_output=True, timeout=60)


def make_pki(directory, name=HOST):
    directory = Path(directory)
    openssl("req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256", "-nodes", "-keyout", "ca.key",
            "-out", "ca.crt", "-subj", "/CN=test household issuer", "-days", "2",
            "-addext", "basicConstraints=critical,CA:TRUE,pathlen:0", "-addext", "keyUsage=critical,keyCertSign,cRLSign",
            cwd=directory)
    openssl("req", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256", "-nodes", "-keyout", "server.key",
            "-out", "server.csr", "-subj", f"/CN={name}", cwd=directory)
    (directory / "ext.cnf").write_text(f"subjectAltName=DNS:{name}\nextendedKeyUsage=serverAuth\n"
                                       "keyUsage=critical,digitalSignature\nbasicConstraints=critical,CA:FALSE\n"
                                       "subjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid\n")
    openssl("x509", "-req", "-in", "server.csr", "-CA", "ca.crt", "-CAkey", "ca.key", "-CAcreateserial",
            "-out", "server.crt", "-days", "2", "-extfile", "ext.cnf", cwd=directory)
    return directory / "ca.crt", directory / "server.crt", directory / "server.key"


class TlsServer:
    """Answers GET /health with {"status":"ready"}; refuses (closes before TLS) beyond `limit` concurrent."""

    def __init__(self, cert, key, limit=None, body=b'{"status":"ready"}'):
        self.context = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
        self.context.load_cert_chain(cert, key)
        self.listener = socket.create_server(("127.0.0.1", 0), backlog=128)
        self.port = self.listener.getsockname()[1]
        self.limit, self.body, self.active, self.lock = limit, body, 0, threading.Lock()
        self.running = True
        threading.Thread(target=self.serve, daemon=True).start()

    def serve(self):
        while self.running:
            try:
                connection, _ = self.listener.accept()
            except OSError:
                return
            with self.lock:
                if self.limit is not None and self.active >= self.limit:
                    connection.close()
                    continue
                self.active += 1
            threading.Thread(target=self.handle, args=(connection,), daemon=True).start()

    def handle(self, connection):
        try:
            with self.context.wrap_socket(connection, server_side=True) as tls:
                tls.settimeout(5)
                request = b""
                while b"\r\n\r\n" not in request:
                    chunk = tls.recv(4096)
                    if not chunk:
                        return
                    request += chunk
                tls.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: "
                            + str(len(self.body)).encode() + b"\r\nConnection: close\r\n\r\n" + self.body)
        except (OSError, ssl.SSLError):
            pass
        finally:
            with self.lock:
                self.active -= 1

    def close(self):
        self.running = False
        self.listener.close()


def dig_output(record, values, status="NOERROR"):
    """What `dig +noall +comments +answer` prints."""
    lines = [";; Got answer:", f";; ->>HEADER<<- opcode: QUERY, status: {status}, id: 4242",
             ";; flags: qr rd ra; QUERY: 1, ANSWER: 1, AUTHORITY: 0, ADDITIONAL: 1", ""]
    lines += [f"{HOST}.\t300\tIN\t{record}\t{value}" for value in values]
    return "\n".join(lines) + "\n"


def dig_args(argv):
    if argv[0] != "dig" or "+noall" not in argv:
        raise AssertionError(argv)
    record = next(arg for arg in argv if arg in ("A", "AAAA"))
    resolver = next(arg for arg in argv if arg.startswith("@"))[1:]
    return record, resolver


def fake_dig(answers, status="NOERROR"):
    """answers: {(record, resolver): [values]}; any other argv is an error."""
    def runner(argv, **kwargs):
        record, resolver = dig_args(argv)
        return SimpleNamespace(returncode=0, stdout=dig_output(record, answers.get((record, resolver), []), status), stderr="")
    return runner


class Pki(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="anj-golive-")
        cls.directory = Path(cls.temporary.name)
        cls.ca, cls.cert, cls.key = make_pki(cls.directory)
        other = cls.directory / "other"
        other.mkdir()
        cls.wrong_ca, cls.wrong_cert, cls.wrong_key = make_pki(other, name="cloud.example.net")

    @classmethod
    def tearDownClass(cls):
        cls.temporary.cleanup()


class Fingerprint(Pki):
    def test_matches_openssl(self):
        expected = subprocess.run(["openssl", "x509", "-in", str(self.ca), "-noout", "-fingerprint", "-sha256"],
                                  capture_output=True, text=True, check=True).stdout.strip().split("=", 1)[1]
        self.assertEqual(golive.fingerprint(self.ca)["sha256"], expected)

    def test_refuses_bundle(self):
        bundle = self.directory / "bundle.pem"
        bundle.write_text(self.ca.read_text() + self.cert.read_text())
        with self.assertRaises(golive.CheckFailed):
            golive.fingerprint(bundle)


class Health(Pki):
    def setUp(self):
        self.server = TlsServer(self.cert, self.key)
        self.hosts = self.directory / "hosts"
        self.hosts.write_text("127.0.0.1 localhost\n# 192.168.0.10 gateway.example.com commented\n")
        self.public = fake_dig({("A", "1.1.1.1"): ["127.0.0.1"], ("A", "8.8.8.8"): ["127.0.0.1"]})

    def tearDown(self):
        self.server.close()

    def check(self, **options):
        defaults = dict(resolver="public", runner=self.public, hosts=self.hosts, port=self.server.port,
                        no_hosts_entry=True, expect_ip="127.0.0.1")
        defaults.update(options)
        return golive.health(HOST, self.ca, **defaults)

    def test_hairpin_ready_with_hostname_verification_through_public_dns(self):
        result = self.check()
        self.assertTrue(result["pass"])
        self.assertEqual(result["address"], "127.0.0.1")
        self.assertFalse(result["hosts_entry"])
        self.assertIn(result["health"]["tls"], ("TLSv1.2", "TLSv1.3"))

    def test_hosts_entry_on_a_roaming_device_fails(self):
        self.hosts.write_text("127.0.0.1 localhost\n192.168.0.10 gateway.example.com # anj-baseline\n")
        with self.assertRaisesRegex(golive.CheckFailed, "hosts entry"):
            self.check()
        self.assertTrue(self.check(no_hosts_entry=False)["pass"])  # The VM host keeps its line (#69 (c))

    def test_wrong_issuer_or_wrong_name_fails(self):
        with self.assertRaisesRegex(golive.CheckFailed, "unreachable"):
            golive.health(HOST, self.wrong_ca, resolver="public", runner=self.public, hosts=self.hosts,
                          port=self.server.port, expect_ip="127.0.0.1")
        wrong = TlsServer(self.wrong_cert, self.wrong_key)
        try:
            with self.assertRaisesRegex(golive.CheckFailed, "unreachable"):
                self.check(port=wrong.port)
        finally:
            wrong.close()

    def test_dns_disagreement_or_unexpected_address_fails(self):
        split = fake_dig({("A", "1.1.1.1"): ["127.0.0.1"], ("A", "8.8.8.8"): ["127.0.0.2"]})
        with self.assertRaisesRegex(golive.CheckFailed, "disagree"):
            self.check(runner=split)
        with self.assertRaisesRegex(golive.CheckFailed, "expected"):
            self.check(expect_ip=HOME_IP)

    def test_public_resolver_requires_the_expected_home_address(self):
        with self.assertRaisesRegex(golive.CheckFailed, "expect-ip"):
            self.check(expect_ip=None)

    def test_resolver_failure_is_not_an_empty_answer(self):
        for status in ("SERVFAIL", "NXDOMAIN", "REFUSED"):
            with self.subTest(status), self.assertRaisesRegex(golive.CheckFailed, status):
                self.check(runner=fake_dig({("A", "1.1.1.1"): ["127.0.0.1"]}, status=status))
        def silent(argv, **kwargs):
            return SimpleNamespace(returncode=9, stdout=";; communications error\n", stderr="")
        with self.assertRaisesRegex(golive.CheckFailed, "no reply"):
            self.check(runner=silent)

    def hosts_line(self, address):
        real = socket.getaddrinfo

        def resolve(host, *args, **kwargs):
            if host == HOST:
                return [(socket.AF_INET, socket.SOCK_STREAM, 6, "", (address, 443))]
            return real(host, *args, **kwargs)
        return patch.object(golive.socket, "getaddrinfo", side_effect=resolve)

    def test_halo_path_resolves_through_the_hosts_line_and_output_dnat(self):
        with self.hosts_line("127.0.0.1"):
            result = self.check(resolver="system", no_hosts_entry=False)
        self.assertIn("output DNAT", result["path"])
        with self.hosts_line("10.77.10.10"):
            with self.assertRaisesRegex(golive.CheckFailed, "bypassing"):
                self.check(resolver="system", no_hosts_entry=False, expect_ip="10.77.10.10")
        with self.assertRaisesRegex(golive.CheckFailed, golive.HALO_LAN_ADDRESS):
            self.check(resolver="system", no_hosts_entry=False, expect_ip=None)

    def test_not_ready_fails(self):
        self.server.body = b'{"status":"starting"}'
        with self.assertRaises(golive.CheckFailed):
            self.check()

    def test_concurrent_household_connections_all_accepted(self):
        result = self.check(concurrent=25)
        self.assertEqual(result["concurrent"], {"opened": 25, "accepted": 25, "refused": 0})
        self.assertTrue(result["pass"])

    def test_concurrent_limit_detected(self):
        limited = TlsServer(self.cert, self.key, limit=20)
        try:
            result = self.check(port=limited.port, concurrent=21, expect="some-refused")
            self.assertGreaterEqual(result["concurrent"]["refused"], 1)
            with self.assertRaises(golive.CheckFailed):
                self.check(port=limited.port, concurrent=25)
        finally:
            limited.close()


class LineCheck(unittest.TestCase):
    class Http:
        def __init__(self, answers):
            self.answers = list(answers)

        def request(self, method, url, **kwargs):
            return 200, self.answers.pop(0).encode()

    def test_agreeing_public_endpoints_and_router(self):
        result = golive.line_check(HOME_IP, http=self.Http([HOME_IP, HOME_IP]), endpoints=("http://a", "http://b"))
        self.assertTrue(result["pass"] and result["router_matches"])

    def test_router_mismatch_cgnat_or_disagreement_fails(self):
        with self.assertRaises(golive.CheckFailed):
            golive.line_check("5.6.7.99", http=self.Http([HOME_IP, HOME_IP]), endpoints=("http://a", "http://b"))
        for answers in ([HOME_IP, "5.6.7.21"], ["100.70.1.2", "100.70.1.2"], ["192.168.0.1", "192.168.0.1"]):
            with self.assertRaises(ddns.Failure):
                golive.line_check(None, http=self.Http(answers), endpoints=("http://a", "http://b"))


def nmap_xml(ports, extra, *, finished=True, timedout=False):
    rows = "".join(f'<port protocol="tcp" portid="{p}"><state state="{s}"/></port>' for p, s in ports.items())
    extras = "".join(f'<extraports state="{s}" count="{c}"/>' for s, c in extra.items())
    host = f'<host{" timedout=\"true\"" if timedout else ""}><status state="up"/><ports>{extras}{rows}</ports></host>'
    end = '<runstats><finished exit="success"/></runstats>' if finished else ""
    return f'<?xml version="1.0"?><nmaprun>{host}{end}</nmaprun>'


class Scan(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="anj-scan-")
        self.evidence = Path(self.temporary.name) / "evidence"
        self.calls = []
        self.dig_status = "NOERROR"
        self.nmap_timeout = False

    def tearDown(self):
        self.temporary.cleanup()

    def runner(self, first, second=None, aaaa=()):
        def run(argv, **kwargs):
            self.calls.append(argv)
            if argv[0] == "dig":
                record, _ = dig_args(argv)
                if self.dig_status != "NOERROR":
                    return SimpleNamespace(returncode=0, stdout=dig_output(record, [], self.dig_status), stderr="")
                return SimpleNamespace(returncode=0, stdout=dig_output(record, list(aaaa) if record == "AAAA" else []), stderr="")
            if self.nmap_timeout and "-p-" in argv:
                Path(argv[argv.index("-oX") + 1]).write_text(first[: len(first) // 2])
                raise subprocess.TimeoutExpired(argv, 1)
            output = Path(argv[argv.index("-oX") + 1])
            text = first if "-p-" in argv else second
            if text is not None:
                output.write_text(text)
            return SimpleNamespace(returncode=0, stdout="", stderr="")
        return run

    def scan(self, *args, **kwargs):
        return golive.scan(HOME_IP, HOST, self.evidence, runner=self.runner(*args, **kwargs))

    def test_only_443_open_passes_and_closed_ports_count_as_safe(self):
        result = self.scan(nmap_xml({443: "open"}, {"filtered": 65434, "closed": 100}))
        self.assertTrue(result["pass"])
        first = self.calls[0]
        self.assertEqual(first[:9], ["nmap", "-Pn", "-p-", "-T4", "--max-retries", "3", "--host-timeout", "60m", "-oX"])
        self.assertEqual(first[-1], HOME_IP)
        self.assertEqual(sum(1 for c in self.calls if c[0] == "nmap"), 1)  # nothing to confirm
        summary = json.loads(next(self.evidence.glob("*-summary.json")).read_text())
        self.assertTrue(summary["pass"])
        self.assertNotIn(HOME_IP, summary["pass1"]["command"])

    def test_suspect_port_is_reprobed_and_passes_when_not_confirmed(self):
        result = self.scan(nmap_xml({443: "open", 22: "open", 8080: "open|filtered"}, {"filtered": 65532}),
                           nmap_xml({22: "filtered", 8080: "closed"}, {}))
        self.assertTrue(result["pass"])
        second = [c for c in self.calls if c[0] == "nmap"][1]
        self.assertEqual(second[:6], ["nmap", "-Pn", "-p", "22,8080", "--max-retries", "3"])
        self.assertNotIn("-p-", second)

    def test_confirmed_open_port_fails(self):
        with self.assertRaises(golive.CheckFailed) as caught:
            self.scan(nmap_xml({443: "open", 22: "open"}, {"filtered": 65533}), nmap_xml({22: "open"}, {}))
        self.assertEqual(json.loads(str(caught.exception))["confirmed_open_other_than_443"], [22])

    def test_unfinished_confirming_pass_never_waves_a_suspect_through(self):
        with self.assertRaises(golive.CheckFailed):
            self.scan(nmap_xml({443: "open", 22: "open"}, {"filtered": 65533}), None)

    def test_timed_out_partial_or_missing_first_pass_fails(self):
        for label, xml in (("timed out", nmap_xml({443: "open"}, {"filtered": 65534}, timedout=True)),
                           ("partial", nmap_xml({443: "open"}, {"filtered": 60000})),
                           ("unfinished", nmap_xml({443: "open"}, {"filtered": 65534}, finished=False)),
                           ("missing", None)):
            with self.subTest(label), self.assertRaises(golive.CheckFailed) as caught:
                self.scan(xml)
            result = json.loads(str(caught.exception))
            self.assertFalse(result["pass1_complete"])
            self.assertIn("rerun", result["note"])

    def test_443_not_open_or_aaaa_present_fails(self):
        with self.assertRaises(golive.CheckFailed):
            self.scan(nmap_xml({443: "filtered"}, {"filtered": 65534}))
        with self.assertRaises(golive.CheckFailed) as caught:
            self.scan(nmap_xml({443: "open"}, {"filtered": 65534}), aaaa=["2001:db8::1"])
        self.assertFalse(json.loads(str(caught.exception))["aaaa_empty"])

    def test_aaaa_resolver_failure_is_not_an_empty_answer(self):
        self.dig_status = "SERVFAIL"
        with self.assertRaises(golive.CheckFailed) as caught:
            self.scan(nmap_xml({443: "open"}, {"filtered": 65534}))
        result = json.loads(str(caught.exception))
        self.assertFalse(result["aaaa_empty"])
        self.assertIn("SERVFAIL", result["aaaa_error"])

    def test_nmap_timeout_or_truncated_xml_fails_with_a_summary(self):
        self.nmap_timeout = True
        with self.assertRaises(golive.CheckFailed) as caught:
            self.scan(nmap_xml({443: "open"}, {"filtered": 65534}))
        self.assertFalse(json.loads(str(caught.exception))["pass1_complete"])
        self.assertTrue(list(self.evidence.glob("*-summary.json")))
        self.nmap_timeout = False
        with self.assertRaises(golive.CheckFailed):
            self.scan('<?xml version="1.0"?><nmaprun><host><ports><port protocol="tcp" portid="443">')

    def test_target_must_be_public(self):
        with self.assertRaises(golive.CheckFailed):
            golive.scan("192.168.0.10", HOST, self.evidence, runner=self.runner(None))


class EmergencyStop(unittest.TestCase):
    """Spec #23 rev7: the stop runs in the VM over SSH and is verified through prod.py status."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="anj-stop-")
        root = Path(self.temporary.name)
        self.alerts = root / "alerts.log"
        self.alert_command = root / "anj-alert"
        self.alert_command.write_text(
            "#!/bin/sh\n"  # anj-alert contract: --key K [--every S] [--title T] [--priority P] -- MESSAGE
            f"printf '%s\\n' \"$*\" >> '{self.alerts}.argv'\n"
            "case \" $* \" in *\" -- \"*) ;; *) exit 64;; esac\n"
            "[ \"$1\" = --key ] || exit 64\n"
            "for a; do last=$a; done\n"
            f"printf '%s\\n' \"$last\" >> '{self.alerts}'\n")
        self.alert_command.chmod(0o700)
        self.calls = []
        # A hermetic home holding halo-vm.sh's ssh_config (SC-065): golive resolves it from $HOME.
        self.home = root / "home"
        self.ssh_config = self.home / ".local" / "share" / "anj-cloud" / "prod-vm" / "ssh_config"
        self.ssh_config.parent.mkdir(parents=True)
        self.ssh_config.write_text("Host anj-prod\n    HostName 10.77.10.10\n    User anj\n")
        home = patch.dict(golive.os.environ, {"HOME": str(self.home)})
        home.start()
        self.addCleanup(home.stop)

    def tearDown(self):
        self.temporary.cleanup()

    @staticmethod
    def status(gateway="stopped", haproxy="stopped", flag=True):
        """A's published `prod.py status` shape (paths.py 9a80b54)."""
        from deploy.vm import paths
        apps = {app: {"status": "online", "restarts": 0, "pid": 100 + i, "service": {"health": "healthy"}}
                for i, app in enumerate(paths.STACK_APPS)}
        apps["gateway"].update(status=gateway, pid=None, service=None)
        apps["haproxy"].update(status=haproxy, pid=None, service=None)
        for app in ("fetch", "fetch-net"):  # the media fetch worker stops with ingress (spec #42 review)
            apps[app].update(status="stopped", pid=None, service=None)
        return {"project": "anj-cloud-prod", "host": "gateway.example.com", "release": "0123456789ab",
                "emergency_stop": flag, "apps": apps, "healthcheck": {"ready": False}}

    def ssh(self, *, stop_code=0, status=None):
        status = self.status() if status is None else status
        def run(argv, **kwargs):
            self.calls.append(argv)
            if argv[-1].endswith(" status"):
                return SimpleNamespace(returncode=0, stdout=status if isinstance(status, str) else json.dumps(status), stderr="")
            return SimpleNamespace(returncode=stop_code, stdout="", stderr="")
        return run

    def stop(self, reason="port 22 answered from outside", **kwargs):
        with contextlib.redirect_stderr(io.StringIO()):
            return golive.emergency_stop(reason, alert_command=str(self.alert_command), runner=self.ssh(**kwargs))

    def test_command_construction_runs_prod_py_emergency_stop_over_ssh_then_status(self):
        result = self.stop()
        self.assertTrue(result["stopped"])
        stop, status = self.calls
        self.assertEqual(stop[:8], ["ssh", "-F", str(self.ssh_config), "-o", "BatchMode=yes", "-o",
                                    "ConnectTimeout=15", "anj-prod"])
        self.assertEqual(stop[8], "--")
        prod = "python3 -I /srv/anj-cloud/release/current/deploy/prod.py"  # 0644 in the release: never exec'd directly
        self.assertEqual(stop[9], f"{prod} emergency-stop --reason 'port 22 answered from outside'")
        self.assertEqual(status[-1], f"{prod} status")
        self.assertIn("not observable from the VM host", result["alert"])
        self.assertIs(result["emergency_stop_flag"], True)
        self.assertFalse(any(word in call[-1] for call in self.calls for word in ("resume", "start", "restart", "docker")))
        self.assertEqual(result["app_states"], {"haproxy": "stopped", "gateway": "stopped", "fetch": "stopped", "fetch-net": "stopped"})
        self.assertIn("halo-vm.sh --forward off", result["root_stop"])
        self.assertFalse(self.alerts.exists())  # the VM's prod.py sends the ntfy message

    def test_default_uses_halo_vm_ssh_config_for_every_ssh_call(self):
        # SC-065: on the VM host anj-prod resolves only through halo-vm.sh's ssh_config.
        result = self.stop()
        self.assertEqual(len(self.calls), 2)
        for call in self.calls:
            self.assertEqual(call[:3], ["ssh", "-F", str(self.ssh_config)])
            self.assertIn("BatchMode=yes", call)
            self.assertIn("ConnectTimeout=15", call)
        self.assertEqual(result["ssh_config"], str(self.ssh_config))
        self.assertEqual(result["ssh_config_source"], "halo-vm.sh default")

    def test_ssh_config_override_and_ssh_host(self):
        other = Path(self.temporary.name) / "other_ssh_config"
        other.write_text("Host vm\n    HostName 10.77.10.10\n")
        with contextlib.redirect_stderr(io.StringIO()):
            result = golive.emergency_stop("seen", ssh_host="vm", ssh_config=str(other),
                                           alert_command=str(self.alert_command), runner=self.ssh())
        for call in self.calls:
            self.assertEqual(call[:3], ["ssh", "-F", str(other)])
            self.assertEqual(call[call.index("--") - 1], "vm")
        self.assertEqual((result["ssh_config"], result["ssh_config_source"]), (str(other), "--ssh-config"))
        # A missing explicit file is refused before any ssh call.
        self.calls.clear()
        with self.assertRaisesRegex(golive.CheckFailed, "--ssh-config .* does not exist"):
            golive.emergency_stop("seen", ssh_config=str(other) + ".missing", runner=self.ssh())
        self.assertEqual(self.calls, [])

    def test_cli_passes_ssh_config_and_ssh_host(self):
        other = Path(self.temporary.name) / "cli_ssh_config"
        other.write_text("")
        seen = {}
        def fake(reason, **kwargs):
            seen.update(kwargs, reason=reason)
            return {"pass": True}
        with patch.object(golive, "emergency_stop", fake), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(golive.main(["stop", "--reason", "x", "--ssh-config", str(other), "--ssh-host", "vm"]), 0)
            self.assertEqual((seen["ssh_config"], seen["ssh_host"]), (str(other), "vm"))
            self.assertEqual(golive.main(["stop", "--reason", "x"]), 0)
            self.assertEqual((seen["ssh_config"], seen["ssh_host"]), (None, "anj-prod"))

    def test_missing_halo_ssh_config_falls_back_to_plain_ssh_and_says_so(self):
        self.ssh_config.unlink()
        result = self.stop()
        for call in self.calls:
            self.assertNotIn("-F", call)
            self.assertEqual(call[:6], ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "anj-prod"])
        self.assertIsNone(result["ssh_config"])
        self.assertIn("not found at " + str(self.ssh_config), result["ssh_config_source"])
        self.assertIn("plain ssh", result["ssh_config_source"])

    def test_ssh_failure_with_halo_ssh_config_still_alerts_from_halo(self):
        # The 2026-11-05 drill: ssh exited 255. With the config in use, a failure still alerts.
        with self.assertRaises(golive.CheckFailed) as caught:
            self.stop(stop_code=255)
        result = json.loads(str(caught.exception))
        self.assertEqual(result["exit"], 255)
        self.assertEqual(result["ssh_config"], str(self.ssh_config))
        self.assertEqual(result["alert"], "fallback sent from the VM host")
        self.assertIn("root stop", self.alerts.read_text())
        self.assertEqual(self.calls[0][:3], ["ssh", "-F", str(self.ssh_config)])

    def test_reason_is_quoted_for_the_remote_shell_and_bounded(self):
        self.stop(reason="seen; rm -rf / $(id) `x` 'q'\nX-Injected: 1\t" + "a" * 500)
        remote = self.calls[0][-1]
        self.assertEqual(shlex.split(remote)[:5], ["python3", "-I", "/srv/anj-cloud/release/current/deploy/prod.py",
                                                    "emergency-stop", "--reason"])
        reason = shlex.split(remote)[5]
        self.assertEqual(len(shlex.split(remote)), 6)
        self.assertTrue(reason.startswith("seen; rm -rf / $(id) `x` 'q' X-Injected: 1"))
        self.assertLessEqual(len(reason), 200)
        with self.assertRaises(golive.CheckFailed):
            self.stop(reason=" \n ")

    def test_only_the_published_status_shape_is_accepted(self):
        good = self.status()
        legacy = {"apps": {"haproxy": "stopped", "gateway": "stopped"}, "emergency_stop": True}
        missing_app = self.status()
        del missing_app["apps"]["cron"]
        extra_app = self.status()
        extra_app["apps"]["ddns"] = dict(extra_app["apps"]["db"])
        extra_key = dict(self.status(), note="x")
        bad_status = self.status()
        bad_status["apps"]["gateway"]["status"] = "running"
        not_a_string = self.status()
        not_a_string["apps"]["db"]["status"] = None
        flag_not_bool = self.status(flag="yes")
        app_missing_field = self.status()
        del app_missing_field["apps"]["gateway"]["pid"]
        flag_absent = self.status()
        del flag_absent["emergency_stop"]
        self.assertTrue(self.stop(status=good)["stopped"])
        cases = {"legacy shape": legacy, "missing app": missing_app, "extra app": extra_app,
                 "extra top-level key": extra_key, "unknown gateway status": bad_status,
                 "other app status not a string": not_a_string,
                 "flag not bool": flag_not_bool, "flag absent": flag_absent,
                 "app entry missing a field": app_missing_field, "a list": [good]}
        for label, status in cases.items():
            with self.subTest(label), self.assertRaises(golive.CheckFailed) as caught:
                self.stop(status=status)
            expected = "exactly the stack apps" if label in ("missing app", "extra app") else "published shape"
            self.assertIn(expected, json.loads(str(caught.exception))["status_error"])

    def test_other_apps_may_report_any_pm2_status(self):
        status = self.status()
        for app, value in (("db", "waiting restart"), ("redis", "one-launch-status"), ("nextcloud", "errored"),
                           ("cron", "launching")):
            status["apps"][app]["status"] = value
        result = self.stop(status=status)
        self.assertTrue(result["stopped"])
        self.assertFalse(self.alerts.exists())
        for app in ("gateway", "haproxy"):
            for value in ("waiting restart", "one-launch-status"):
                with self.subTest(app=app, value=value), self.assertRaises(golive.CheckFailed):
                    self.stop(status=self.status(**{app: value}))

    def test_unconfirmed_stop_fails_and_alerts_from_halo(self):
        cases = {
            "ssh failed": dict(stop_code=255),
            "gateway online": dict(status=self.status(gateway="online")),
            "gateway stopping": dict(status=self.status(gateway="stopping")),
            "haproxy errored": dict(status=self.status(haproxy="errored")),
            "haproxy missing": dict(status=self.status(haproxy="missing")),
            "flag false": dict(status=self.status(flag=False)),
            "status unreadable": dict(status="not json"),
            "apps empty": dict(status=dict(self.status(), apps={})),
        }
        for label, options in cases.items():
            with self.subTest(label), self.assertRaises(golive.CheckFailed):
                self.stop(**options)
        alerts = self.alerts.read_text().splitlines()
        self.assertEqual(len(alerts), len(cases))
        self.assertIn("root stop", alerts[0])

    def test_halo_fallback_uses_the_anj_alert_contract_and_needs_an_explicit_dispatcher(self):
        with self.assertRaises(golive.CheckFailed):
            self.stop(stop_code=255)
        [argv] = Path(str(self.alerts) + ".argv").read_text().splitlines()
        self.assertTrue(argv.startswith("--key emergency-stop --every 0 --title anj-cloud emergency stop --priority urgent -- "
                                        "anj-cloud EMERGENCY STOP "), argv)
        calls = []
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(golive.CheckFailed) as caught:
            golive.emergency_stop("seen", runner=self.ssh(stop_code=255), alert_runner=lambda *a, **k: calls.append(a))
        self.assertEqual(calls, [])  # no dispatcher given: no alert attempted, nothing else tried
        self.assertEqual(json.loads(str(caught.exception))["alert"], "fallback not delivered")
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(golive.main(["stop", "--reason", "x", "--alert-command", "relative/anj-alert"]), 1)

    def test_halo_root_only_dispatcher_runs_through_sudo_n_and_never_prompts(self):
        for code, expected in ((1, "fallback not delivered"), (0, "fallback sent from the VM host")):
            calls = []

            def alert_runner(argv, **kwargs):
                calls.append((argv, kwargs))
                return SimpleNamespace(returncode=code, stdout=b"", stderr=b"sudo: a password is required\n" if code else b"")
            with self.subTest(sudo_exit=code), contextlib.redirect_stderr(io.StringIO()), \
                    self.assertRaises(golive.CheckFailed) as caught:
                golive.emergency_stop("seen", runner=self.ssh(stop_code=255), alert_command=golive.HALO_DISPATCHER,
                                      alert_runner=alert_runner)
            [(argv, kwargs)] = calls
            self.assertEqual(argv[:3], ["sudo", "-n", "/usr/local/lib/anj-cloud-host/anj-alert"])
            self.assertEqual(argv[3:9], ["--key", "emergency-stop", "--every", "0", "--title", "anj-cloud emergency stop"])
            self.assertEqual(argv[9:12], ["--priority", "urgent", "--"])
            self.assertIs(kwargs["stdin"], subprocess.DEVNULL)  # -n plus no stdin: never a prompt
            self.assertEqual(json.loads(str(caught.exception))["alert"], expected)

    def test_other_dispatchers_run_without_sudo(self):
        calls = []
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(golive.CheckFailed):
            golive.emergency_stop("seen", runner=self.ssh(stop_code=255), alert_command="/opt/anj/anj-alert",
                                  alert_runner=lambda argv, **kw: calls.append(argv) or SimpleNamespace(returncode=0))
        self.assertEqual(calls[0][0], "/opt/anj/anj-alert")

    def test_relative_alert_command_is_refused_programmatically(self):
        with self.assertRaisesRegex(golive.CheckFailed, "absolute"):
            golive.emergency_stop("seen", runner=self.ssh(), alert_command="relative/anj-alert")
        self.assertEqual(self.calls, [])

    def test_refuses_root(self):
        with patch.object(golive.os, "geteuid", return_value=0), self.assertRaises(golive.CheckFailed):
            self.stop()
        self.assertEqual(self.calls, [])

    def test_there_is_no_re_enable_command(self):
        for action in ("start", "up", "enable", "restart", "resume"):
            with self.subTest(action), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                golive.main([action])


class HairpinSource(unittest.TestCase):
    def test_household_lan_or_published_address_passes(self):
        self.assertEqual(golive.source_check("192.168.0.20", HOME_IP)["kind"], "household-lan")
        self.assertEqual(golive.source_check(HOME_IP, HOME_IP)["kind"], "published-ipv4")

    def test_halo_source_nat_and_other_sources_fail(self):
        for source, kind in (("10.77.10.1", "source-nat"), ("10.77.10.10", "source-nat"),
                             ("5.6.7.99", "other"), ("172.17.0.1", "other")):
            with self.subTest(source), self.assertRaises(golive.CheckFailed) as caught:
                golive.source_check(source, HOME_IP)
            self.assertEqual(json.loads(str(caught.exception))["kind"], kind)
        with self.assertRaises(golive.CheckFailed):
            golive.source_check(HOME_IP, "192.168.0.1")  # a non-public published value never matches

    def test_vm_network_comes_from_the_interface(self):
        from deploy.vm import paths
        self.assertIn(golive.ipaddress.ip_address("10.77.10.1"), golive.VM_NETWORK)
        self.assertEqual(str(golive.VM_NETWORK), "10.77.10.0/24")
        self.assertEqual(paths.DEFAULT_HOUSEHOLD_LAN, "192.168.0.0/24")

if __name__ == "__main__":
    unittest.main()
