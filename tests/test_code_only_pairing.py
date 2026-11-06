"""Code-only pairing (spec #35, decision #151): pinned codes, GET /v1/ca, automatic approval,
one alert and one audit entry per new device, generic refusals, legacy compatibility, revoke."""

import asyncio
import hashlib
import json
import os
import sys
import unittest
from unittest import mock

from cryptography import x509
from cryptography.hazmat.primitives import serialization

sys.path.insert(0, os.path.dirname(__file__))

from test_console_admin import AdminCase
from test_permanent_credentials import Device, leaf_id, pem
from services.access.registry import Registry
from pathlib import Path
import re

from services.access import codes
from services.access.protocol import (ALPHABET, CA_PIN_BYTES, CODE_LENGTH, CODE_NOT_VALID, PINNED_CODE_LENGTH,
                                      PINNED_SECRET_BYTES, ca_pin, code_ca_pin, normalize_code, pinned_code)

ROOT = Path(__file__).resolve().parent.parent
from deploy.vm.console_backend import ADMIN_EVENTS, Backend


def issuer_pin(authority):
    return hashlib.sha256(authority.certificate.public_bytes(serialization.Encoding.DER)).digest()[:CA_PIN_BYTES]


class CodeFormatTests(unittest.TestCase):
    """Sizes come only from services/access/codes.py (and their Dart twins); see its docstring."""

    def test_the_pinned_code_is_the_secret_and_the_ca_pin_in_the_same_grouped_alphabet(self):
        secret, pin = bytes(range(PINNED_SECRET_BYTES)), bytes(range(200, 200 + CA_PIN_BYTES))
        code = pinned_code(secret, pin)
        self.assertEqual(PINNED_CODE_LENGTH, len(code))
        self.assertEqual(codes.code_length(PINNED_SECRET_BYTES + CA_PIN_BYTES), PINNED_CODE_LENGTH)
        self.assertTrue(set(code) <= set(ALPHABET))
        self.assertEqual(pin, code_ca_pin(code))
        # Separators and case never matter (rule 1).
        self.assertEqual(code, normalize_code(codes.group(code).lower()))
        self.assertRegex(codes.group(code), "^" + codes.grouped_pattern() + "$")
        self.assertIsNone(code_ca_pin("0" * CODE_LENGTH))
        for bad in ("0" * (PINNED_CODE_LENGTH - 1), "0" * (PINNED_CODE_LENGTH + 1), "I" * CODE_LENGTH, "x" * 200):
            with self.assertRaisesRegex(ValueError, CODE_NOT_VALID):
                normalize_code(bad)
        # Spare top bits must be zero: a first character beyond them is no code.
        spare = 5 * PINNED_CODE_LENGTH - 8 * (PINNED_SECRET_BYTES + CA_PIN_BYTES)
        if spare:
            with self.assertRaisesRegex(ValueError, CODE_NOT_VALID):
                code_ca_pin(ALPHABET[1 << (5 - spare)] + code[1:])

    def test_a_pinned_code_can_never_have_the_legacy_length(self):
        self.assertEqual(32, CODE_LENGTH)                                 # codes issued before decision #151
        self.assertNotEqual(CODE_LENGTH, PINNED_CODE_LENGTH)
        # Sizes summing to 20 bytes would encode to 32 characters: codes.py refuses to load.
        source = (ROOT / "services/access/codes.py").read_text()
        clash = re.sub(r"(?m)^PINNED_SECRET_BYTES = \d+$", "PINNED_SECRET_BYTES = 8", source)
        clash = re.sub(r"(?m)^CA_PIN_BYTES = \d+$", "CA_PIN_BYTES = 12", clash)
        self.assertNotEqual(source, clash)
        with self.assertRaisesRegex(ImportError, "legacy code's length"):
            exec(compile(clash, "codes-clash", "exec"), {"__name__": "codes_clash"})

    def test_the_cross_language_vector_matches_these_sizes_and_the_client_constants(self):
        vector = json.loads((ROOT / "tests/pairing_code_vector.json").read_text())
        self.assertEqual(codes.vector(), vector,
                         "sizes changed: python3 -m services.access.codes --vector > tests/pairing_code_vector.json")
        dart = (ROOT / "apps/client/lib/core/gateway/dav_api.dart").read_text()
        constants = {name: int(value) for name, value in re.findall(r"const (\w+Bytes) = (\d+);", dart)}
        self.assertEqual({"pinnedSecretBytes": PINNED_SECRET_BYTES, "caPinBytes": CA_PIN_BYTES,
                          "legacySecretBytes": codes.LEGACY_SECRET_BYTES}, constants,
                         "dav_api.dart must use the same sizes as services/access/codes.py")


class PinnedPairingTests(AdminCase):
    async def asyncSetUp(self):
        await super().asyncSetUp()
        self.signed = []

        def approve(request):
            # What the console backend's approve does through the operator socket: begin, sign
            # the stored CSR with the issuer, activate. Here the fixture issuer signs directly.
            row = self.registry.begin(request["pairing_id"], request["fingerprint"])
            if row.get("already_active"):
                return {"state": "active", "device_id": row["device"]}
            csr = x509.load_pem_x509_csr(row["csr"].encode())
            leaf = self.authority.leaf(csr.public_key(), row["device"])
            self.registry.activate(row["id"], request["fingerprint"], "token", "7", pem(leaf),
                                   leaf.not_valid_after_utc.timestamp(), leaf_id(leaf))
            self.signed.append(row["id"])
            return {"state": "active", "device_id": row["device"]}

        self.backend.replies["approve"] = approve

    async def invite(self, uid="alex", label=None):
        status, created = await self.call("POST", "/v1/admin/invitations", "sam",
                                          {"uid": uid, "grant": "write", **({"label": label} if label else {})})
        self.assertEqual(201, status, created)
        return created

    async def enroll(self, code, device, path="/v1/enroll", label="Alex's laptop"):
        body = {"code": code, "csr": device.csr, **({"label": label} if path == "/v1/enroll" else {})}
        return await self.call("POST", path, None, body)

    async def alerts(self):
        """Every console alert and every pairing alert the gateway has in flight."""
        await asyncio.gather(*list(self.gateway.console.alert_tasks), *list(self.gateway.alerts_sending.values()),
                             return_exceptions=True)

    def reused_alerts(self):
        return [call for call in self.backend.calls if call["action"] == "admin-alert" and call["event"] == "code-reused"]

    def paired_audit(self):
        return [row for row in self.audit() if row["action"] == "device-paired"]

    def paired_alerts(self):
        return [call for call in self.backend.calls if call["action"] == "admin-alert" and call["event"] == "device-paired"]

    async def test_every_new_code_carries_this_servers_ca_pin(self):
        created = await self.invite()
        self.assertEqual(PINNED_CODE_LENGTH, len(created["code"]))
        self.assertEqual(issuer_pin(self.authority), code_ca_pin(created["code"]))
        self.assertEqual(issuer_pin(self.authority), ca_pin(self.authority.certificate))
        # The operator socket's invite (access_operator invite, anj-cloud-setup pair) too.
        response = await self.gateway._admin(_Request({"action": "invite", "uid": "alex", "rights": "write"}))
        self.assertEqual(issuer_pin(self.authority), code_ca_pin(json.loads(response.text)["code"]))
        # And the recovery CLI's (anj-cloud-admin invite).
        cli = await self.gateway.console.operator({"op": "invite", "uid": "alex", "grant": "write"})
        self.assertEqual(issuer_pin(self.authority), code_ca_pin(cli["code"]))

    async def test_the_ca_route_serves_only_the_public_issuer_certificate_without_a_device_certificate(self):
        status, text = await self.call("GET", "/v1/ca", None)
        self.assertEqual(200, status)
        self.assertEqual(pem(self.authority.certificate), text)
        self.assertNotIn("PRIVATE", text)
        served = x509.load_pem_x509_certificate(text.encode())
        self.assertEqual(issuer_pin(self.authority), hashlib.sha256(served.public_bytes(serialization.Encoding.DER)).digest()[:CA_PIN_BYTES])
        self.assertEqual(400, (await self.call("GET", "/v1/ca?x=1", None))[0])
        self.assertEqual(405, (await self.call("POST", "/v1/ca", None, {}))[0])

    async def test_redeeming_a_pinned_code_approves_the_device_in_the_same_exchange(self):
        created = await self.invite(label=None)
        device = Device()
        status, reply = await self.enroll(created["code"], device)
        self.assertEqual(200, status, reply)
        self.assertEqual(("approved", "alex", "write", device.fingerprint), (reply["state"], reply["uid"], reply["rights"], reply["fingerprint"]))
        leaf = x509.load_pem_x509_certificate(reply["certificate"].encode())
        leaf.verify_directly_issued_by(self.authority.certificate)
        approvals = [call for call in self.backend.calls if call["action"] == "approve"]
        self.assertEqual([{"action": "approve", "pairing_id": created["id"], "fingerprint": device.fingerprint}], approvals,
                         "the fingerprint comes from the CSR the device sent")
        await self.alerts()
        self.assertEqual(1, len(self.paired_audit()))
        audit = self.paired_audit()[0]
        self.assertEqual(("system", "alex", reply["device_id"], created["id"], "ok"),
                         (audit["actor_uid"], audit["target_uid"], audit["target_device"], audit["target_invitation"], audit["result"]))
        self.assertEqual([{"action": "admin-alert", "event": "device-paired", "actor_uid": "system", "target_uid": "alex",
                           "device_id": reply["device_id"], "label": "Alex?s laptop", "fingerprint": device.fingerprint[:8]}],
                         self.paired_alerts())
        # The device's retry (lost response) collects the same certificate: no second alert or audit.
        status, again = await self.enroll(created["code"], device, "/v1/enroll/status")
        self.assertEqual((200, reply["certificate"]), (status, again["certificate"]))
        await self.alerts()
        self.assertEqual((1, 1, 1), (len(self.paired_audit()), len(self.paired_alerts()), len(self.signed)))
        # The paired device reaches DAV with its new certificate.
        self.amy_paired = (device, leaf)
        context_status = await self.dav_status(device, leaf)
        self.assertEqual(200, context_status)

    async def dav_status(self, device, leaf):
        import aiohttp
        from gateway_harness import HOST
        context = self.harness.client_context(device, leaf)
        async with aiohttp.ClientSession(connector=aiohttp.TCPConnector(ssl=context), trust_env=False) as session:
            async with session.get("https://127.0.0.1:%d/dav/file.txt" % self.port, server_hostname=HOST) as response:
                await response.read()
                return response.status

    async def test_revoke_ends_an_automatically_paired_devices_access_at_once(self):
        created = await self.invite()
        device = Device()
        _, reply = await self.enroll(created["code"], device)
        leaf = x509.load_pem_x509_certificate(reply["certificate"].encode())
        self.assertEqual(200, await self.dav_status(device, leaf))
        expect = await self.revision_of("devices", "id", reply["device_id"])
        status, body = await self.confirmed("POST", "/v1/admin/devices/%s/revoke" % reply["device_id"], {"expect": expect})
        self.assertEqual((200, "revoked"), (status, body["state"]), body)
        self.assertEqual(403, await self.dav_status(device, leaf))
        # A revoked device's code stays dead, with the same generic refusal.
        self.assertEqual((400, {"error": CODE_NOT_VALID}), await self.enroll(created["code"], device, "/v1/enroll/status"))

    async def test_used_expired_unknown_and_foreign_codes_get_the_same_refusal(self):
        created = await self.invite()
        await self.enroll(created["code"], Device())
        refusal = (400, {"error": CODE_NOT_VALID})
        self.assertEqual(refusal, await self.enroll(created["code"], Device()), "used: another key")
        unknown = pinned_code(os.urandom(PINNED_SECRET_BYTES), issuer_pin(self.authority))
        self.assertEqual(refusal, await self.enroll(unknown, Device()), "unknown secret")
        fresh = await self.invite()
        foreign = pinned_code(_secret(fresh["code"]), bytes(CA_PIN_BYTES))
        self.assertEqual(refusal, await self.enroll(foreign, Device()), "right secret, another server's CA")
        self.assertEqual(refusal, await self.enroll(fresh["code"][:-1], Device()), "a character short is not a code")
        self.assertEqual(refusal, await self.enroll("not a code", Device()))
        late = await self.invite()
        self.gateway.registry.clock = lambda: 10 ** 12
        self.assertEqual(refusal, await self.enroll(late["code"], Device()), "expired")
        # Each refusal counts toward the source's enrollment block (rule 5, decision #69 (a)).
        self.assertEqual(6, len(self.harness.guard.failures.get("127.0.0.1", ())))
        self.assertEqual([], [call for call in self.backend.calls if call["action"] == "approve" and call["pairing_id"] != created["id"]])

    async def test_a_denied_pinned_code_is_refused(self):
        created = await self.invite()
        expect = await self.revision_of("invitations", "id", created["id"])
        status, _ = await self.confirmed("POST", "/v1/admin/invitations/%s/deny" % created["id"], {"expect": expect})
        self.assertEqual(200, status)
        self.assertEqual((400, {"error": CODE_NOT_VALID}), await self.enroll(created["code"], Device()))

    async def test_an_unreachable_backend_leaves_the_device_pending_and_a_status_request_retries(self):
        created = await self.invite()
        await self.backend.stop()
        device = Device()
        status, reply = await self.enroll(created["code"], device)
        self.assertEqual((200, "pending", "automatic"), (status, reply["state"], reply["approval"]))
        self.assertEqual(device.fingerprint, reply["fingerprint"])
        await self.backend.start()
        # A failed attempt is retried only after APPROVAL_RETRY: each one mints an app token.
        status, reply = await self.enroll(created["code"], device, "/v1/enroll/status")
        self.assertEqual((200, "pending"), (status, reply["state"]))
        self.assertEqual([], [call for call in self.backend.calls if call["action"] == "approve"])
        self.gateway.approval_retry = 0
        status, reply = await self.enroll(created["code"], device, "/v1/enroll/status")
        self.assertEqual((200, "approved"), (status, reply["state"]))
        await self.alerts()
        self.assertEqual((1, 1), (len(self.paired_audit()), len(self.paired_alerts())))

    async def test_a_slow_approval_answers_pending_and_finishes_without_the_device(self):
        created = await self.invite()
        self.gateway.approval_hold = 0.2
        self.backend.delays["approve"] = 1.0
        device = Device()
        status, reply = await self.enroll(created["code"], device)
        self.assertEqual((200, "pending"), (status, reply["state"]))
        # The approval keeps running after the exchange ended; a status request then waits for it.
        self.gateway.approval_hold = 5
        status, reply = await self.enroll(created["code"], device, "/v1/enroll/status")
        self.assertEqual((200, "approved"), (status, reply["state"]))
        self.assertEqual(1, len([call for call in self.backend.calls if call["action"] == "approve"]), "one approval per pairing")
        await self.alerts()
        self.assertEqual((1, 1), (len(self.paired_audit()), len(self.paired_alerts())))

    async def test_an_alert_lost_to_a_restart_is_sent_on_the_next_approved_answer_exactly_once(self):
        created = await self.invite()
        device = Device()
        pending = self.registry.enroll(created["code"], device.csr, "Tablet")
        self.backend.replies["approve"](  # approved while no exchange watched it (e.g. a restart)
            {"pairing_id": pending["pairing_id"], "fingerprint": pending["fingerprint"]})
        status, reply = await self.enroll(created["code"], device, "/v1/enroll/status")
        self.assertEqual((200, "approved"), (status, reply["state"]))
        await self.enroll(created["code"], device, "/v1/enroll/status")
        await self.alerts()
        self.assertEqual((1, 1), (len(self.paired_audit()), len(self.paired_alerts())))
        self.assertEqual("Tablet", self.paired_alerts()[0]["label"])

    async def test_a_legacy_code_keeps_the_fingerprint_approval_until_it_expires(self):
        legacy = self.registry.invite("alex", "write")             # issued before this release: no pin
        self.assertEqual(32, len(legacy["code"]))
        device = Device()
        status, reply = await self.enroll(legacy["code"], device)
        self.assertEqual((200, "pending"), (status, reply["state"]))
        self.assertNotIn("approval", reply)
        self.assertEqual([], [call for call in self.backend.calls if call["action"] == "approve"], "never approved automatically")
        # The admin approves by fingerprint as before; the device collects its certificate.
        expect = await self.revision_of("invitations", "id", legacy["id"])
        status, approved = await self.call("POST", "/v1/admin/invitations/%s/approve" % legacy["id"], "sam",
                                           {"fingerprint": device.fingerprint, "expect": expect})
        self.assertEqual(200, status, approved)
        status, reply = await self.enroll(legacy["code"], device, "/v1/enroll/status")
        self.assertEqual((200, "approved"), (status, reply["state"]))
        await self.alerts()
        self.assertEqual(([], []), (self.paired_audit(), self.paired_alerts()))

    async def test_an_admin_fingerprint_approval_of_a_pinned_code_is_never_announced_twice(self):
        created = await self.invite()
        await self.backend.stop()
        device = Device()
        await self.enroll(created["code"], device)
        await self.backend.start()
        self.backend.calls.clear()
        self.gateway.approval_retry = 3600                  # no automatic retry before the admin acts
        expect = await self.revision_of("invitations", "id", created["id"])
        status, _ = await self.call("POST", "/v1/admin/invitations/%s/approve" % created["id"], "sam",
                                    {"fingerprint": device.fingerprint, "expect": expect})
        self.assertEqual(200, status)
        status, reply = await self.enroll(created["code"], device, "/v1/enroll/status")
        self.assertEqual((200, "approved"), (status, reply["state"]))
        await self.alerts()
        events = [call["event"] for call in self.backend.calls if call["action"] == "admin-alert"]
        self.assertEqual(["device-paired"], events, "one new-device alert, never a second for the admin's approval")
        self.assertEqual(1, len(self.paired_audit()))

    async def test_an_admin_approval_racing_the_automatic_one_alerts_once(self):          # review L1
        created = await self.invite()
        self.gateway.approval_hold = 0.1
        self.backend.delays["approve"] = 0.6
        device = Device()
        status, reply = await self.enroll(created["code"], device)
        self.assertEqual("pending", reply["state"])                       # the automatic approval is in flight
        expect = await self.revision_of("invitations", "id", created["id"])
        status, _ = await self.call("POST", "/v1/admin/invitations/%s/approve" % created["id"], "sam",
                                    {"fingerprint": device.fingerprint, "expect": expect})
        self.assertEqual(200, status)
        await asyncio.gather(*list(self.gateway.approvals.values()), return_exceptions=True)
        await self.alerts()
        self.assertEqual(2, len([c for c in self.backend.calls if c["action"] == "approve"]))   # the second is idempotent
        self.assertEqual(1, len(self.signed))
        events = [call["event"] for call in self.backend.calls if call["action"] == "admin-alert"]
        self.assertEqual(["device-invite-other", "device-paired"], events, "the invitation's alert, then one for the device")
        self.assertEqual(1, len(self.paired_audit()))

    async def test_an_alert_the_backend_did_not_confirm_is_sent_again(self):                 # review M1
        created = await self.invite()
        self.backend.replies["admin-alert"] = {"error": "failed", "message": "dispatcher down"}
        device = Device()
        status, reply = await self.enroll(created["code"], device)
        self.assertEqual((200, "approved"), (status, reply["state"]))
        await self.alerts()
        self.assertEqual(1, len(self.paired_alerts()), "tried once")
        self.assertEqual(0, self.registry.invitation(created["id"])["alerted"], "not confirmed: still due")
        self.gateway.alert_pass_once()                                    # the periodic pass, backend still failing
        await self.alerts()
        self.assertEqual(2, len(self.paired_alerts()))
        del self.backend.replies["admin-alert"]                           # the backend recovers
        self.gateway.alert_pass_once()
        await self.alerts()
        self.assertEqual(3, len(self.paired_alerts()))
        self.assertEqual(1, self.registry.invitation(created["id"])["alerted"])
        self.gateway.alert_pass_once()
        await self.enroll(created["code"], device, "/v1/enroll/status")
        await self.alerts()
        self.assertEqual(3, len(self.paired_alerts()), "confirmed: never again")
        self.assertEqual(1, len(self.paired_audit()), "the audit entry is written once")

    async def test_an_unreachable_backend_at_alert_time_leaves_the_alert_due(self):           # review M1
        created = await self.invite()
        device = Device()
        pending = self.registry.enroll(created["code"], device.csr, "Phone")
        self.backend.replies["approve"]({"pairing_id": pending["pairing_id"], "fingerprint": pending["fingerprint"]})
        await self.backend.stop()
        self.gateway.alert_pass_once()                                    # audits it, cannot alert
        await self.alerts()
        self.assertEqual(1, len(self.paired_audit()))
        self.assertEqual(0, self.registry.invitation(created["id"])["alerted"])
        await self.backend.start()
        self.gateway.alert_pass_once()
        await self.alerts()
        self.assertEqual(1, len(self.paired_alerts()))
        self.assertEqual("Phone", self.paired_alerts()[0]["label"])
        self.assertEqual(1, self.registry.invitation(created["id"])["alerted"])

    async def test_a_restart_between_the_audit_and_the_alert_still_alerts(self):             # review M1
        created = await self.invite()
        device = Device()
        pending = self.registry.enroll(created["code"], device.csr)
        self.backend.replies["approve"]({"pairing_id": pending["pairing_id"], "fingerprint": pending["fingerprint"]})
        self.assertIsNotNone(self.registry.announce(created["id"]))       # claimed and audited, then the process died
        restarted = Registry(self.harness.directory / "state")            # a new process reads the same state
        self.assertEqual([("paired", created["id"])], [(kind, row["id"]) for kind, row in restarted.alerts_due()])
        restarted.db.close()
        self.gateway.alert_pass_once()
        await self.alerts()
        self.assertEqual((1, 1), (len(self.paired_audit()), len(self.paired_alerts())))

    async def test_setups_operator_fallback_approval_is_audited_and_alerted_by_the_pass(self):  # review M1
        created = await self.invite()
        device = Device()
        pending = self.registry.enroll(created["code"], device.csr, "Laptop")
        # access_operator approve (setup's 45 s fallback) goes straight to begin/activate.
        self.backend.replies["approve"]({"pairing_id": pending["pairing_id"], "fingerprint": pending["fingerprint"]})
        self.assertEqual([], self.paired_audit())
        self.gateway.alert_pass_once()
        await self.alerts()
        self.assertEqual((1, 1), (len(self.paired_audit()), len(self.paired_alerts())))

    async def test_the_alert_names_the_reported_computer_name_never_the_admins_label(self):  # operator 2026-11-05
        created = await self.invite(label="Alex laptop")
        device = Device()
        status, reply = await self.enroll(created["code"], device, label="laptop")
        self.assertEqual((200, "approved"), (status, reply["state"]))
        long = await self.invite()
        other = Device()
        await self.enroll(long["code"], other, label="\u202ex" * 10 + "it's-a-very-long-hostname-" + "y" * 30)
        await self.alerts()
        labels = [(call["label"], call["fingerprint"]) for call in self.paired_alerts()]
        self.assertEqual(("laptop", device.fingerprint[:8]), labels[0])
        self.assertEqual(40, len(labels[1][0]))
        self.assertTrue(labels[1][0].endswith("...") and labels[1][0].isascii() and "'" not in labels[1][0])
        self.assertEqual(other.fingerprint[:8], labels[1][1])
        # The Admin device list shows the same name and short fingerprint, to find the device to revoke.
        _, listing = await self.call("GET", "/v1/admin/devices", "sam")
        row = next(row for row in listing["devices"] if row["id"] == reply["device_id"])
        self.assertEqual(("laptop", device.fingerprint[:8], "Alex laptop"), (row["computer_name"], row["fingerprint_short"], row["label"]))
        stored = self.registry.invitation(long["id"])
        self.assertTrue(stored["device_label"].isascii() and stored["label"] == stored["device_label"], "stored cleaned")

    async def test_a_name_the_backends_unicode_does_not_know_still_alerts(self):          # PR #92 review H1
        created = await self.invite()
        device = Device()
        await self.enroll(created["code"], device, label="laptop\U0001FAE9")      # new in Unicode 16
        await self.alerts()
        self.assertEqual([("laptop?", device.fingerprint[:8])], [(c["label"], c["fingerprint"]) for c in self.paired_alerts()])
        # The real backend accepts exactly that request, also with a Unicode database that knows less.
        backend = BackendAlertTests.backend(None)
        request = {key: value for key, value in self.paired_alerts()[0].items()}
        with mock.patch.dict(sys.modules, {"unicodedata": _OlderUnicode()}):
            self.assertEqual({"state": "sent"}, backend.handle(dict(request)))
            self.assertEqual({"state": "sent"}, backend.handle({**request, "label": "laptop\U0001FAE9"}))
        self.assertEqual(["anj-cloud: new device 'laptop?' (fp %s) for alex" % device.fingerprint[:8]] * 2,
                         [message for _, message in backend.sent])

    async def test_a_backend_that_refuses_the_name_still_gets_the_alert_out(self):        # PR #92 review H1
        created = await self.invite()
        self.backend.replies["admin-alert"] = lambda request: (
            {"error": "refused", "message": "Invalid admin alert"} if request.get("label") not in (None, "unnamed")
            else {"state": "sent"})
        device = Device()
        await self.enroll(created["code"], device, label="laptop")
        await self.alerts()
        self.assertEqual(["laptop", "unnamed"], [call["label"] for call in self.paired_alerts()])
        self.assertEqual(1, self.registry.invitation(created["id"])["alerted"])
        self.assertEqual([], [row for row in self.audit() if row["action"] == "pairing-alert"])

    async def test_the_first_failure_of_each_alert_episode_is_audited(self):              # PR #92 review H1
        created = await self.invite()
        self.backend.replies["admin-alert"] = {"error": "failed", "message": "down"}
        await self.enroll(created["code"], Device())
        await self.alerts()
        for _ in range(3):
            self.gateway.alert_pass_once()
            await self.alerts()
        self.assertEqual(4, len(self.paired_alerts()))                       # retried every pass
        failures = [row for row in self.audit() if row["action"] == "pairing-alert"]
        self.assertEqual([("system", "alex", created["id"], "alert-failed:backend-failed")],
                         [(row["actor_uid"], row["target_uid"], row["target_invitation"], row["result"]) for row in failures])
        del self.backend.replies["admin-alert"]
        self.gateway.alert_pass_once()
        await self.alerts()
        self.assertEqual(1, self.registry.invitation(created["id"])["alerted"])
        self.assertEqual(1, len([row for row in self.audit() if row["action"] == "pairing-alert"]), "audited once per episode")

    async def test_a_used_code_tried_by_another_key_alerts_the_admin_once(self):             # review M2
        created = await self.invite()
        await self.enroll(created["code"], Device())
        self.backend.replies["admin-alert"] = lambda request: (
            {"error": "failed", "message": "down"} if request["event"] == "code-reused" and len(self.reused_alerts()) == 1
            else {"state": "sent"})
        refusal = (400, {"error": CODE_NOT_VALID})
        intruder = Device()
        self.assertEqual(refusal, await self.enroll(created["code"], intruder, label="kali"), "the requester learns nothing more")
        await self.alerts()
        self.assertEqual(1, len(self.reused_alerts()))
        self.assertEqual({"action": "admin-alert", "event": "code-reused", "actor_uid": "system", "target_uid": "alex",
                          "label": "kali", "fingerprint": intruder.fingerprint[:8]}, self.reused_alerts()[0])
        self.gateway.alert_pass_once()                                    # the first try failed: sent again
        await self.alerts()
        self.assertEqual(2, len(self.reused_alerts()))
        self.assertEqual(refusal, await self.enroll(created["code"], Device()))
        self.gateway.alert_pass_once()
        await self.alerts()
        self.assertEqual(2, len(self.reused_alerts()), "one confirmed alert per code")
        self.assertEqual("kali", self.reused_alerts()[1]["label"], "it names the first other device")
        # An unknown code, or the holder's own retry, is no reuse.
        await self.enroll(pinned_code(os.urandom(PINNED_SECRET_BYTES), issuer_pin(self.authority)), Device())
        await self.alerts()
        self.assertEqual(2, len(self.reused_alerts()))


class BackendAlertTests(unittest.TestCase):
    def backend(self):
        backend = Backend.__new__(Backend)
        backend.sent = []
        backend.dispatch = lambda options, message: backend.sent.append((options, message)) or 0
        return backend

    def test_pairing_alerts_name_the_computer_and_a_short_fingerprint(self):         # operator 2026-11-05
        backend = self.backend()
        device = "0" * 8 + "-0000-4000-8000-" + "0" * 12
        self.assertEqual({"state": "sent"}, backend.handle({"action": "admin-alert", "event": "device-paired", "actor_uid": "system",
                                                            "target_uid": "sam", "device_id": device, "label": "laptop",
                                                            "fingerprint": "6150cf05"}))
        self.assertEqual("anj-cloud: new device 'laptop' (fp 6150cf05) for sam", backend.sent[0][1])
        self.assertEqual({"state": "sent"}, backend.handle({"action": "admin-alert", "event": "code-reused", "actor_uid": "system",
                                                            "target_uid": "alex", "label": "kali", "fingerprint": "0badf00d"}))
        self.assertEqual("anj-cloud: someone tried a used pairing code for alex: device 'kali' (fp 0badf00d)", backend.sent[1][1])

    def test_the_backend_cleans_a_pairing_alert_instead_of_refusing_it(self):         # PR #92 review H1
        backend = self.backend()
        device = "0" * 8 + "-0000-4000-8000-" + "0" * 12
        base = {"action": "admin-alert", "event": "device-paired", "actor_uid": "system", "target_uid": "alex", "device_id": device}
        cases = [("", "6150cf05", "unnamed", "6150cf05"), ("x" * 81, "6150cf05", "x" * 37 + "...", "6150cf05"),
                 ("bad\nline", "6150cf05", "bad line", "6150cf05"), ("it's", "6150cf05", "it?s", "6150cf05"),
                 ("laptop\U0001FAE9", "6150cf05", "laptop?", "6150cf05"), ("\u202eevil", "6150CF05", "?evil", "unknown"),
                 ("laptop", "6150cf0g", "laptop", "unknown")]
        for label, fingerprint, shown, fp in cases:
            self.assertEqual({"state": "sent"}, backend.handle({**base, "label": label, "fingerprint": fingerprint}), label)
            self.assertEqual("anj-cloud: new device '%s' (fp %s) for alex" % (shown, fp), backend.sent[-1][1])
        for broken in ({}, {"label": "laptop"}, {"fingerprint": "6150cf05"}, {"label": 5, "fingerprint": "6150cf05"}):
            self.assertEqual("refused", backend.handle({**base, **broken}).get("error"), broken)
        reply = backend.handle({"action": "admin-alert", "event": "device-revoke", "actor_uid": "sam", "target_uid": "alex",
                                "device_id": device, "label": "x", "fingerprint": "6150cf05"})
        self.assertEqual("refused", reply.get("error"), "only pairing alerts quote a device")
        self.assertEqual(len(cases), len(backend.sent))


class _OlderUnicode:
    """A Unicode database that knows nothing beyond ASCII: no decompositions, no combining marks."""

    @staticmethod
    def normalize(form, value):
        return value

    @staticmethod
    def combining(char):
        return 0


def _secret(code):
    """The secret bytes of a pinned code."""
    return codes.decode_code(code, PINNED_SECRET_BYTES + CA_PIN_BYTES)[:PINNED_SECRET_BYTES]


class _Request:
    def __init__(self, body):
        self.body = body

    async def json(self):
        return self.body


if __name__ == "__main__":
    unittest.main()
