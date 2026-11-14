"""Permanent device credentials (spec #19): long-lived leaves, operator reissue, pickup endpoint.

Every CA here is a temporary fixture generated per test; no operator secret is read.
"""

import asyncio
from collections import defaultdict
from datetime import datetime, timedelta, timezone
import ipaddress
import json
from pathlib import Path
import re
import socket
import ssl
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import aiohttp
from aiohttp import web
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID

from deploy import dev
from deploy.access_operator import Operator, main as operator_main
from services.access.protocol import Rejection, key_fingerprint
from services.access.registry import Registry
from services.access.mutations import Mutations
from services.access.server import Gateway, safe_errors

ROOT = Path(__file__).resolve().parent.parent
NOW = datetime.now(timezone.utc)


def name(common):
    return x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, common)])


def pem(certificate):
    return certificate.public_bytes(serialization.Encoding.PEM).decode()


def leaf_id(certificate):
    return certificate.fingerprint(hashes.SHA256()).hex()


class Authority:
    """A temporary issuer with the same profile `access_operator trust` creates."""

    def __init__(self, directory, days=365, common="fixture issuer"):
        self.directory = Path(directory)
        self.key = ec.generate_private_key(ec.SECP256R1())
        start = NOW - timedelta(minutes=5)
        self.certificate = (x509.CertificateBuilder().subject_name(name(common)).issuer_name(name(common))
                            .public_key(self.key.public_key()).serial_number(x509.random_serial_number())
                            .not_valid_before(start).not_valid_after((start + timedelta(days=days)).replace(microsecond=0))
                            .add_extension(x509.BasicConstraints(ca=True, path_length=0), critical=True)
                            .add_extension(x509.KeyUsage(digital_signature=False, content_commitment=False, key_encipherment=False,
                                                         data_encipherment=False, key_agreement=False, key_cert_sign=True,
                                                         crl_sign=True, encipher_only=False, decipher_only=False), critical=True)
                            .add_extension(x509.SubjectKeyIdentifier.from_public_key(self.key.public_key()), critical=False)
                            .sign(self.key, hashes.SHA256()))
        self.crt = self.directory / (common.replace(" ", "-") + ".crt")
        self.key_path = self.directory / (common.replace(" ", "-") + ".key")
        self.crt.write_text(pem(self.certificate))
        self.key_path.write_bytes(self.key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                                         serialization.NoEncryption()))
        self.key_path.chmod(0o600)

    def leaf(self, public_key, common, *, usage=ExtendedKeyUsageOID.CLIENT_AUTH, not_after=None, not_before=None, ca=False, san=None):
        builder = (x509.CertificateBuilder().subject_name(name(common)).issuer_name(self.certificate.subject)
                   .public_key(public_key).serial_number(x509.random_serial_number())
                   .not_valid_before(not_before or NOW - timedelta(minutes=1))
                   .not_valid_after(not_after or self.certificate.not_valid_after_utc)
                   .add_extension(x509.BasicConstraints(ca=ca, path_length=None), critical=True)
                   .add_extension(x509.KeyUsage(digital_signature=True, content_commitment=False, key_encipherment=False,
                                                data_encipherment=False, key_agreement=False, key_cert_sign=False,
                                                crl_sign=False, encipher_only=False, decipher_only=False), critical=True)
                   .add_extension(x509.ExtendedKeyUsage([usage]), critical=False)
                   .add_extension(x509.AuthorityKeyIdentifier.from_issuer_public_key(self.key.public_key()), critical=False))
        if san:
            builder = builder.add_extension(x509.SubjectAlternativeName(san), critical=False)
        return builder.sign(self.key, hashes.SHA256())


class Device:
    def __init__(self):
        self.key = ec.generate_private_key(ec.SECP256R1())
        self.fingerprint = key_fingerprint(self.key.public_key())
        self.csr = pem_csr(self.key)


def pem_csr(key):
    request = x509.CertificateSigningRequestBuilder().subject_name(name("untrusted label")).sign(key, hashes.SHA256())
    return request.public_bytes(serialization.Encoding.PEM).decode()


def pair(registry, authority, device, uid="alice", leaf=None):
    """Enroll and activate exactly as approve does, with a fixture-signed leaf."""
    invitation = registry.invite(uid, "write")
    pending = registry.enroll(invitation["code"], device.csr)
    registry.begin(pending["pairing_id"], pending["fingerprint"])
    certificate = leaf or authority.leaf(device.key.public_key(), pending["device_id"])
    registry.activate(pending["pairing_id"], pending["fingerprint"], "token-" + uid, "1", pem(certificate),
                      certificate.not_valid_after_utc.timestamp(), leaf_id(certificate))
    return pending["device_id"], certificate


class FakeRequest:
    def __init__(self, body):
        self.body = body

    async def json(self):
        return self.body


def gateway_for(directory, authority, clock=None):
    gateway = Gateway.__new__(Gateway)
    gateway.registry = Registry(directory, clock=clock) if clock else Registry(directory)
    gateway.issuer = authority.certificate
    gateway.active, gateway.transports = defaultdict(set), defaultdict(set)
    gateway.mutations = Mutations(gateway)
    return gateway


async def admin(gateway, action, **data):
    """The private operator handler, with the CLI's curated rejection envelope."""
    try:
        response = await gateway._admin(FakeRequest({"action": action, **data}))
    except Rejection as error:
        raise RuntimeError("Operator action rejected: " + str(error)) from None
    return json.loads(response.text)


def operator_call(gateway):
    """Route Operator.call to the in-process private operator handler (no Docker)."""
    return lambda action, **data: asyncio.run(admin(gateway, action, **data))


class OperatorStack:
    """Local signing authority only: real OpenSSL, no Compose."""

    def __init__(self, directory):
        self.local = Path(directory)

    def run(self, argv, *, data=None):
        result = subprocess.run(argv, input=data, text=True, capture_output=True, timeout=60, check=False)
        if result.returncode:
            raise RuntimeError("Command failed; output withheld")
        return result.stdout


def assert_strict_leaf(test, path, issuer_path):
    """The leaf names its own key and its issuer's, and passes X509_STRICT verification (which
    Python 3.13+ `ssl.create_default_context`, and so the gateway, applies)."""
    leaf = x509.load_pem_x509_certificate(path.read_bytes())
    issuer = x509.load_pem_x509_certificate(issuer_path.read_bytes())
    test.assertEqual(x509.SubjectKeyIdentifier.from_public_key(leaf.public_key()),
                     leaf.extensions.get_extension_for_class(x509.SubjectKeyIdentifier).value)
    test.assertEqual(issuer.extensions.get_extension_for_class(x509.SubjectKeyIdentifier).value.digest,
                     leaf.extensions.get_extension_for_class(x509.AuthorityKeyIdentifier).value.key_identifier)
    verified = subprocess.run(["openssl", "verify", "-x509_strict", "-CAfile", str(issuer_path), str(path)],
                              capture_output=True, text=True, timeout=60, check=False)
    test.assertEqual(0, verified.returncode, verified.stdout + verified.stderr)


def operator_with_issuer(directory, authority):
    operator = Operator(OperatorStack(directory))
    dev.private_directory(operator.directory)
    (operator.directory / "issuer.crt").write_text(authority.crt.read_text())
    (operator.directory / "issuer.key").write_bytes(authority.key_path.read_bytes())
    return operator


class RegistryTransitionTests(unittest.TestCase):
    def test_reissue_accepts_previous_and_current_until_current_is_used(self):
        with tempfile.TemporaryDirectory() as directory:
            authority = Authority(directory)
            registry = Registry(Path(directory) / "state")
            device = Device()
            identity, first = pair(registry, authority, device)
            second = authority.leaf(device.key.public_key(), identity)
            registry.reissue(identity, device.fingerprint, pem(second), second.not_valid_after_utc.timestamp(), leaf_id(second))
            self.assertEqual(identity, registry.admit(device.fingerprint, leaf_id(first), observe=True)["id"])
            self.assertEqual(pem(second), registry.device(identity)["certificate"])
            # Fetching (or any request) with the previous leaf keeps it; first use of the current retires it.
            self.assertEqual(identity, registry.admit(device.fingerprint, leaf_id(first), observe=True)["id"])
            self.assertEqual(identity, registry.admit(device.fingerprint, leaf_id(second), observe=False)["id"])
            self.assertEqual(identity, registry.admit(device.fingerprint, leaf_id(first))["id"])
            registry.admit(device.fingerprint, leaf_id(second), observe=True)
            with self.assertRaises(ValueError):
                registry.admit(device.fingerprint, leaf_id(first))
            registry.db.close()

    def test_repeated_reissue_before_pickup_keeps_the_leaf_the_device_holds(self):
        with tempfile.TemporaryDirectory() as directory:
            authority = Authority(directory)
            registry = Registry(Path(directory) / "state")
            device = Device()
            identity, held = pair(registry, authority, device)
            leaves = [authority.leaf(device.key.public_key(), identity) for _ in range(2)]
            for leaf in leaves:
                registry.reissue(identity, device.fingerprint, pem(leaf), leaf.not_valid_after_utc.timestamp(), leaf_id(leaf))
            for leaf in (held, *leaves):
                registry.admit(device.fingerprint, leaf_id(leaf))
            self.assertEqual(2, registry.public_devices()[0]["transition_leaves"])
            # Idempotent retry of the committed leaf adds nothing.
            again = registry.reissue(identity, device.fingerprint, pem(leaves[-1]), leaves[-1].not_valid_after_utc.timestamp(), leaf_id(leaves[-1]))
            self.assertEqual("current", again["state"])
            with self.assertRaises(ValueError):  # A superseded leaf never becomes current again.
                registry.reissue(identity, device.fingerprint, pem(leaves[0]), leaves[0].not_valid_after_utc.timestamp(), leaf_id(leaves[0]))
            registry.db.close()

    def test_revocation_refuses_every_leaf_and_reissue(self):
        with tempfile.TemporaryDirectory() as directory:
            authority = Authority(directory)
            registry = Registry(Path(directory) / "state")
            device = Device()
            identity, first = pair(registry, authority, device)
            second = authority.leaf(device.key.public_key(), identity)
            registry.reissue(identity, device.fingerprint, pem(second), second.not_valid_after_utc.timestamp(), leaf_id(second))
            registry.disable(identity)
            for leaf in (first, second):
                with self.assertRaises(ValueError):
                    registry.admit(device.fingerprint, leaf_id(leaf))
            third = authority.leaf(device.key.public_key(), identity)
            with self.assertRaises(ValueError):
                registry.reissue_target(identity)
            with self.assertRaises(ValueError):
                registry.reissue(identity, device.fingerprint, pem(third), third.not_valid_after_utc.timestamp(), leaf_id(third))
            self.assertEqual(0, registry.db.execute("SELECT count(*) FROM device_leaves").fetchone()[0])
            registry.db.close()

    def test_expired_leaves_are_refused_and_expired_devices_cannot_be_reissued(self):
        with tempfile.TemporaryDirectory() as directory:
            authority = Authority(directory)
            now = [NOW.timestamp()]
            registry = Registry(Path(directory) / "state", clock=lambda: now[0])
            device = Device()
            short = authority.leaf(device.key.public_key(), "pending", not_after=NOW + timedelta(days=7))
            identity, first = pair(registry, authority, device, leaf=short)
            second = authority.leaf(device.key.public_key(), identity)
            registry.reissue(identity, device.fingerprint, pem(second), second.not_valid_after_utc.timestamp(), leaf_id(second))
            now[0] += 8 * 86400
            with self.assertRaises(ValueError):
                registry.admit(device.fingerprint, leaf_id(first))
            self.assertEqual(identity, registry.admit(device.fingerprint, leaf_id(second))["id"])
            now[0] = second.not_valid_after_utc.timestamp()
            with self.assertRaises(ValueError):
                registry.admit(device.fingerprint, leaf_id(second))
            with self.assertRaises(ValueError):
                registry.reissue_target(identity)
            registry.db.close()

    def test_transition_table_survives_restart_and_legacy_upgrade(self):
        with tempfile.TemporaryDirectory() as directory:
            authority = Authority(directory)
            state = Path(directory) / "state"
            registry = Registry(state)
            device = Device()
            identity, first = pair(registry, authority, device)
            second = authority.leaf(device.key.public_key(), identity)
            registry.reissue(identity, device.fingerprint, pem(second), second.not_valid_after_utc.timestamp(), leaf_id(second))
            registry.db.close()
            registry = Registry(state)
            self.assertEqual(identity, registry.admit(device.fingerprint, leaf_id(first))["id"])
            self.assertEqual(2, registry.db.execute("PRAGMA user_version").fetchone()[0])
            registry.db.close()


class GatewayProfileTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.authority = Authority(self.temporary.name)
        self.gateway = gateway_for(Path(self.temporary.name) / "state", self.authority)
        self.device = Device()
        self.identity, self.first = pair(self.gateway.registry, self.authority, self.device)
        self.call = operator_call(self.gateway)

    def tearDown(self):
        self.gateway.registry.db.close()
        self.temporary.cleanup()

    def test_leaf_valid_until_issuer_expiry_is_accepted_and_beyond_is_refused(self):
        certificate, expires, _ = self.gateway.client_leaf(pem(self.first), self.device.fingerprint)
        self.assertEqual(self.authority.certificate.not_valid_after_utc.timestamp(), expires)
        self.assertGreater(expires - NOW.timestamp(), 300 * 86400)
        beyond = self.authority.leaf(self.device.key.public_key(), self.identity,
                                     not_after=self.authority.certificate.not_valid_after_utc + timedelta(seconds=1))
        future = self.authority.leaf(self.device.key.public_key(), self.identity, not_before=NOW + timedelta(hours=1))
        for leaf in (beyond, future):
            with self.assertRaisesRegex(ValueError, "validity"):
                self.gateway.client_leaf(pem(leaf), self.device.fingerprint)

    def test_reissue_commit_requires_issuer_key_profile_and_identity(self):
        other = Authority(self.temporary.name, common="other issuer")
        stranger = Device()
        cases = {
            "foreign issuer": other.leaf(self.device.key.public_key(), self.identity),
            "other key": self.authority.leaf(stranger.key.public_key(), self.identity),
            "other identity": self.authority.leaf(self.device.key.public_key(), "another-device"),
            "server profile": self.authority.leaf(self.device.key.public_key(), self.identity, usage=ExtendedKeyUsageOID.SERVER_AUTH),
            "issuer profile": self.authority.leaf(self.device.key.public_key(), self.identity, ca=True),
        }
        for label, leaf in cases.items():
            with self.subTest(label):
                with self.assertRaises(RuntimeError):
                    self.call("reissue-commit", device_id=self.identity, certificate=pem(leaf))
                self.assertEqual(leaf_id(self.first), self.gateway.registry.device(self.identity)["certificate_id"])
        good = self.authority.leaf(self.device.key.public_key(), self.identity)
        result = self.call("reissue-commit", device_id=self.identity, certificate=pem(good))
        self.assertEqual(("reissued", leaf_id(good)), (result["state"], result["certificate_id"]))

    def test_reissue_begin_exposes_only_public_inputs_and_refuses_revoked(self):
        target = self.call("reissue-begin", device_id=self.identity)
        self.assertEqual({"device", "uid", "fingerprint", "csr", "certificate", "certificate_id", "expires"}, set(target))
        self.assertNotIn("token", json.dumps(target))
        self.gateway.registry.disable(self.identity)
        with self.assertRaisesRegex(RuntimeError, "active"):
            self.call("reissue-begin", device_id=self.identity)


def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


class EndpointTests(unittest.IsolatedAsyncioTestCase):
    """Real TLS 1.2+ mutual authentication against the gateway's public routes."""

    async def asyncSetUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        directory = Path(self.temporary.name)
        self.authority = Authority(directory)
        server_key = ec.generate_private_key(ec.SECP256R1())
        server = self.authority.leaf(server_key.public_key(), "localhost", usage=ExtendedKeyUsageOID.SERVER_AUTH,
                                     san=[x509.IPAddress(ipaddress.ip_address("127.0.0.1"))])
        (directory / "server.crt").write_text(pem(server))
        (directory / "server.key").write_bytes(server_key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                                                        serialization.NoEncryption()))
        self.gateway = gateway_for(directory / "state", self.authority)
        app = web.Application(middlewares=[safe_errors])
        app.router.add_get("/v1/device/certificate", self.gateway.device_certificate)
        context = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(directory / "server.crt", directory / "server.key")
        context.load_verify_locations(self.authority.crt)
        context.verify_mode = ssl.CERT_OPTIONAL
        self.runner = web.AppRunner(app, access_log=None)
        await self.runner.setup()
        self.port = free_port()
        await web.TCPSite(self.runner, "127.0.0.1", self.port, ssl_context=context).start()
        self.directory = directory

    async def asyncTearDown(self):
        await self.runner.cleanup()
        self.gateway.registry.db.close()
        self.temporary.cleanup()

    async def fetch(self, device=None, certificate=None):
        context = ssl.create_default_context(cafile=str(self.authority.crt))
        if device:
            prefix = self.directory / ("client-" + leaf_id(certificate)[:12])
            prefix.with_suffix(".crt").write_text(pem(certificate))
            prefix.with_suffix(".key").write_bytes(device.key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                                                            serialization.NoEncryption()))
            context.load_cert_chain(prefix.with_suffix(".crt"), prefix.with_suffix(".key"))
        async with aiohttp.ClientSession(connector=aiohttp.TCPConnector(ssl=context), trust_env=False) as session:
            async with session.get(f"https://127.0.0.1:{self.port}/v1/device/certificate", allow_redirects=False) as response:
                return response.status, (await response.json(content_type=None) if response.status == 200 else None), response.headers

    async def test_device_fetches_only_its_own_current_leaf_and_old_leaf_works_until_new_is_used(self):
        alice, bob = Device(), Device()
        alice_id, alice_first = pair(self.gateway.registry, self.authority, alice, "alice")
        bob_id, bob_first = pair(self.gateway.registry, self.authority, bob, "bob")
        status, body, headers = await self.fetch(alice, alice_first)
        self.assertEqual(200, status)
        self.assertEqual({"device_id": alice_id, "certificate": pem(alice_first), "expires_at": alice_first.not_valid_after_utc.timestamp()}, body)
        self.assertEqual("no-store", headers["Cache-Control"])
        renewed = self.authority.leaf(alice.key.public_key(), alice_id)
        await admin(self.gateway, "reissue-commit", device_id=alice_id, certificate=pem(renewed))
        # The pickup itself uses the previous leaf; a lost response leaves it working.
        for _ in range(2):
            status, body, _ = await self.fetch(alice, alice_first)
            self.assertEqual((200, pem(renewed)), (status, body["certificate"]))
        status, body, _ = await self.fetch(bob, bob_first)
        self.assertEqual((200, bob_id, pem(bob_first)), (status, body["device_id"], body["certificate"]))
        status, body, _ = await self.fetch(alice, renewed)
        self.assertEqual((200, pem(renewed)), (status, body["certificate"]))
        status, _, _ = await self.fetch(alice, alice_first)
        self.assertEqual(403, status)

    async def test_no_client_certificate_is_401_and_revoked_device_is_refused_for_both_leaves(self):
        status, body, _ = await self.fetch()
        self.assertEqual((401, None), (status, body))
        device = Device()
        identity, first = pair(self.gateway.registry, self.authority, device)
        renewed = self.authority.leaf(device.key.public_key(), identity)
        await admin(self.gateway, "reissue-commit", device_id=identity, certificate=pem(renewed))
        await admin(self.gateway, "revoke", device_id=identity)
        for leaf in (first, renewed):
            status, body, _ = await self.fetch(device, leaf)
            self.assertEqual((403, None), (status, body))

    async def test_expired_leaf_is_refused(self):
        # The server-side handshake failure is expected; keep it out of the test log.
        asyncio.get_running_loop().set_exception_handler(lambda loop, context: None)
        device = Device()
        expired = self.authority.leaf(device.key.public_key(), "expired", not_before=NOW - timedelta(days=2), not_after=NOW - timedelta(days=1))
        try:
            status, _, _ = await self.fetch(device, expired)
        except aiohttp.ClientError:
            status = "handshake refused"
        self.assertIn(status, (401, "handshake refused"))


class OperatorReissueTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        directory = Path(self.temporary.name)
        self.authority = Authority(directory)
        self.gateway = gateway_for(directory / "state", self.authority)
        self.operator = operator_with_issuer(directory / "operator-local", self.authority)

    def tearDown(self):
        self.gateway.registry.db.close()
        self.temporary.cleanup()

    def short_device(self, uid="alice"):
        device = Device()
        # A pre-migration seven-day leaf, as approve issued before this change.
        identity, leaf = pair(self.gateway.registry, self.authority, device, uid,
                              leaf=self.authority.leaf(device.key.public_key(), "placeholder", not_after=NOW + timedelta(days=6)))
        # The subject must be the device ID, as approve signs it.
        leaf = self.authority.leaf(device.key.public_key(), identity, not_after=NOW + timedelta(days=6))
        with self.gateway.registry.db:
            self.gateway.registry.db.execute("UPDATE devices SET certificate=?,certificate_id=?,expires=? WHERE id=?",
                                             (pem(leaf), leaf_id(leaf), leaf.not_valid_after_utc.timestamp(), identity))
        return device, identity, leaf

    def test_approve_signs_a_fixed_profile_leaf_to_issuer_expiry(self):
        device = Device()
        csr = self.operator.directory / "device.csr"
        target = self.operator.directory / "device.crt"
        csr.write_text(device.csr)
        self.operator.sign(csr, target, "00000000-0000-0000-0000-000000000001")
        leaf = x509.load_pem_x509_certificate(target.read_bytes())
        self.assertEqual(self.authority.certificate.not_valid_after_utc, leaf.not_valid_after_utc)
        self.assertEqual(name("00000000-0000-0000-0000-000000000001"), leaf.subject)
        self.gateway.client_leaf(target.read_text(), device.fingerprint)  # Gateway activation profile accepts it.
        server = self.operator.directory / "server.crt"
        self.operator.sign(csr, server, "server", "serverAuth", days=364)
        bounded = x509.load_pem_x509_certificate(server.read_bytes())
        self.assertLess(bounded.not_valid_after_utc, NOW + timedelta(days=365))
        for issued in (target, server):
            assert_strict_leaf(self, issued, self.operator.directory / "issuer.crt")

    def test_trust_issuer_and_server_leaf_carry_key_identifiers(self):
        # SC-213: OpenSSL 4 adds no key identifiers unless asked; the issuer and both leaves must
        # carry them whichever OpenSSL the operator host runs.
        with tempfile.TemporaryDirectory() as directory:
            stack = OperatorStack(directory)
            stack.origin = "https://localhost"
            operator = Operator(stack)
            operator.init_trust()
            issuer_path = operator.directory / "issuer.crt"
            issuer = x509.load_pem_x509_certificate(issuer_path.read_bytes())
            subject_key = issuer.extensions.get_extension_for_class(x509.SubjectKeyIdentifier).value
            self.assertEqual(x509.SubjectKeyIdentifier.from_public_key(issuer.public_key()), subject_key)
            self.assertEqual(subject_key.digest, issuer.extensions.get_extension_for_class(x509.AuthorityKeyIdentifier).value.key_identifier)
            assert_strict_leaf(self, operator.directory / "server.crt", issuer_path)
            device = Device()
            csr = operator.directory / "device.csr"
            csr.write_text(device.csr)
            operator.sign(csr, operator.directory / "device.crt", "00000000-0000-0000-0000-000000000001")
            assert_strict_leaf(self, operator.directory / "device.crt", issuer_path)

    def test_reissue_signs_same_key_and_identity_to_issuer_expiry_and_journals_intent(self):
        device, identity, old = self.short_device()
        with patch.object(self.operator, "call", side_effect=operator_call(self.gateway)):
            result = self.operator.reissue(identity)
            row = self.gateway.registry.device(identity)
            new = x509.load_pem_x509_certificate(row["certificate"].encode())
            self.assertEqual(("reissued", leaf_id(new)), (result["state"], result["certificate_id"]))
            self.assertEqual(self.authority.certificate.not_valid_after_utc, new.not_valid_after_utc)
            self.assertEqual(key_fingerprint(new.public_key()), device.fingerprint)
            self.assertEqual(old.subject, new.subject)
            self.gateway.registry.admit(device.fingerprint, leaf_id(old))
            self.gateway.registry.admit(device.fingerprint, leaf_id(new))
            journal = json.loads((self.operator.journals / "reissue" / (identity + ".json")).read_text())
            self.assertEqual({"device": identity, "uid": "alice", "state": "active", "previous_certificate_id": leaf_id(old),
                              "certificate_id": leaf_id(new)}, journal)
            self.assertEqual("current", self.operator.reissue(identity)["state"])
            self.assertEqual("reissued", self.operator.reissue(identity, force=True)["state"])
        for path in (self.operator.journals / "reissue").iterdir():
            self.assertNotIn("PRIVATE", path.read_text())
            self.assertEqual(0o600, path.stat().st_mode & 0o777)

    def test_reissue_active_covers_active_devices_and_refuses_revoked_and_expired(self):
        first, first_id, _ = self.short_device("alice")
        second, second_id, _ = self.short_device("bob")
        revoked, revoked_id, _ = self.short_device("carol")
        self.gateway.registry.disable(revoked_id)
        expired, expired_id, _ = self.short_device("dave")
        with self.gateway.registry.db:
            self.gateway.registry.db.execute("UPDATE devices SET expires=? WHERE id=?", (NOW.timestamp() - 1, expired_id))
        with patch.object(self.operator, "call", side_effect=operator_call(self.gateway)):
            results = {row["device_id"]: row["state"] for row in self.operator.reissue_active()}
            self.assertEqual({first_id: "reissued", second_id: "reissued", expired_id: "skipped"}, results)
            with self.assertRaisesRegex(RuntimeError, "active"):
                self.operator.reissue(revoked_id)
            with self.assertRaisesRegex(RuntimeError, "expired"):
                self.operator.reissue(expired_id)
            self.assertEqual({first_id: "current", second_id: "current", expired_id: "skipped"},
                             {row["device_id"]: row["state"] for row in self.operator.reissue_active()})
        for identity in (first_id, second_id):
            self.assertEqual(self.authority.certificate.not_valid_after_utc.timestamp(), self.gateway.registry.device(identity)["expires"])

    def test_lost_commit_response_is_recovered_and_rejected_commit_keeps_working_leaf(self):
        device, identity, old = self.short_device()
        real = operator_call(self.gateway)
        def lose_receipt(action, **data):
            result = real(action, **data)
            if action == "reissue-commit":
                raise RuntimeError("Command failed (exit 1); output withheld: docker")
            return result
        with patch.object(self.operator, "call", side_effect=lose_receipt):
            self.assertEqual("reissued", self.operator.reissue(identity)["state"])
        device, identity, old = self.short_device("bob")
        def reject(action, **data):
            if action == "reissue-commit":
                raise RuntimeError("Operator action rejected: Device changed during reissue")
            return real(action, **data)
        with patch.object(self.operator, "call", side_effect=reject):
            with self.assertRaisesRegex(RuntimeError, "keeps its working certificate"):
                self.operator.reissue(identity)
        self.assertEqual(leaf_id(old), self.gateway.registry.device(identity)["certificate_id"])
        self.assertEqual("abandoned", json.loads((self.operator.journals / "reissue" / (identity + ".json")).read_text())["state"])

    def test_reconcile_resolves_interrupted_reissue_journals(self):
        device, identity, old = self.short_device()
        real = operator_call(self.gateway)
        def crash(action, **data):
            if action == "reissue-commit":
                real(action, **data)
                raise KeyboardInterrupt  # Operator process lost after the registry committed.
            return real(action, **data)
        with patch.object(self.operator, "call", side_effect=crash):
            with self.assertRaises(KeyboardInterrupt):
                self.operator.reissue(identity)
        journal = self.operator.journals / "reissue" / (identity + ".json")
        self.assertEqual("signed", json.loads(journal.read_text())["state"])
        with patch.object(self.operator, "call", side_effect=real):
            self.assertEqual([{"device_id": identity, "reissue": "active"}], self.operator._reconcile_reissues())
        self.assertEqual("active", json.loads(journal.read_text())["state"])

    def test_cli_requires_exactly_one_target_and_reports_partial_failure(self):
        with patch("sys.argv", ["access_operator", "reissue"]), patch("sys.stderr") as stderr:
            self.assertEqual(1, operator_main())
        with patch("sys.argv", ["access_operator", "reissue", "--active"]), \
                patch.object(Operator, "reissue_active", return_value=[{"device_id": "x", "state": "failed", "reason": "r"}]), \
                patch("sys.stdout"), patch("sys.stderr"):
            self.assertEqual(1, operator_main())
        with patch("sys.argv", ["access_operator", "reissue", "../escape"]), patch("sys.stderr"):
            self.assertEqual(1, operator_main())


class CustodyTests(unittest.TestCase):
    def test_issuer_key_and_signing_never_enter_the_gateway_image_or_mounts(self):
        dockerfile = (ROOT / "services/access/Dockerfile").read_text()
        sources = [line.split()[1] for line in dockerfile.splitlines() if line.startswith("COPY")]
        self.assertEqual(["services/access/requirements.txt", "services/access"], sources)
        ignore = (ROOT / ".dockerignore").read_text().split()
        self.assertEqual("**", ignore[0])
        self.assertTrue(all(line.startswith(("!services/access", "!services/", "services/access/__pycache__",
                                             "services/fetch/__pycache__")) for line in ignore[1:]))
        compose = json.loads((ROOT / "deploy/compose.json").read_text())
        access = compose["services"]["access"]
        # Spec #27: only the console backend's socket directory is bind-mounted, never operator state.
        # Spec #42: plus the media fetch spool shared with the worker (never operator state).
        self.assertEqual(["access:/var/lib/anj", "fetch-spool:/var/lib/anj-fetch", "${ANJ_CONSOLE_DIR:?Run deploy/dev.py setup}:/run/anj-console"],
                         access["volumes"])
        self.assertNotIn("ANJ_OPERATOR_DIR", json.dumps(access["volumes"]))
        files = {secret: compose["secrets"][secret]["file"] for secret in access["secrets"]}
        self.assertTrue(files["issuer_crt"].endswith("/issuer.crt"))
        self.assertFalse(any("issuer.key" in value for value in files.values()))
        self.assertNotIn("issuer.key", json.dumps(access))
        for path in (ROOT / "services/access").glob("*.py"):
            text = path.read_text()
            self.assertNotIn("issuer.key", text)
            self.assertNotIn("-CAkey", text)
            self.assertIsNone(re.search(r"CertificateBuilder|\.sign\(", text), path.name)

    def test_redeploy_access_rebuilds_and_restarts_only_the_access_service(self):
        stack = dev.Stack("anj-cloud-test", 18834)
        with patch.object(stack, "compose", return_value="") as compose, patch.object(stack, "check") as check, \
                patch("builtins.print"):
            stack.redeploy_access()
        calls = [call.args for call in compose.call_args_list]
        self.assertEqual([("up", "--detach", "--build", "--no-deps", "--wait", "--wait-timeout", "180", "access")], calls)
        check.assert_called_once()


if __name__ == "__main__":
    unittest.main()
