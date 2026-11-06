"""Spec #27 gateway admin API: authorization, roles, last-admin, confirmations, stale views, audit."""

import asyncio
import json
import os
import sys
import tempfile
import unittest

import aiohttp

sys.path.insert(0, os.path.dirname(__file__))

from gateway_harness import HOST, Harness
from test_permanent_credentials import Device, pair
from services.access import console as console_module
from services.access.console import RECOVERY, RESTARTING, BackendClient
from services.access.protocol import PINNED_CODE_LENGTH, UPLOAD_LIMIT_HEADER
from services.access.registry import Registry

MIB = 1024 * 1024


class FakeBackend:
    """The console backend's socket protocol: one JSON request, one JSON reply."""

    def __init__(self, path):
        self.path, self.calls, self.replies, self.server = path, [], {}, None
        self.delays = {}                         # action -> seconds before the reply (a slow backend)

    async def start(self):
        self.server = await asyncio.start_unix_server(self.handle, self.path)

    async def stop(self):
        if self.server is not None:
            self.server.close()
            await self.server.wait_closed()
            self.server = None
        if os.path.exists(self.path):
            os.unlink(self.path)

    async def handle(self, reader, writer):
        request = json.loads(await reader.read())
        self.calls.append(request)
        await asyncio.sleep(self.delays.get(request["action"], 0))
        reply = self.replies.get(request["action"], {"state": "ok"})
        if callable(reply):
            reply = reply(request)
        writer.write(json.dumps(reply).encode())
        await writer.drain()
        writer.close()


class AdminCase(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.harness = Harness(listener="tcp")
        await self.harness.start()
        self.gateway, self.authority, self.port = self.harness.gateway, self.harness.authority, self.harness.port
        self.registry = self.gateway.registry
        for uid, name in (("sam", "Sam"), ("alex", "Alex"), ("kid", "Kid")):
            self.registry.account_set(uid, name)
        self.registry.set_account_flags("sam", admin=True)
        self.sam, self.jed2, self.alex, self.kid = Device(), Device(), Device(), Device()
        self.jed_id, self.jed_leaf = pair(self.registry, self.authority, self.sam, "sam")
        self.jed2_id, self.jed2_leaf = pair(self.registry, self.authority, self.jed2, "sam")
        self.amy_id, self.amy_leaf = pair(self.registry, self.authority, self.alex, "alex")
        self.kid_id, self.kid_leaf = pair(self.registry, self.authority, self.kid, "kid")
        self.socket_dir = tempfile.TemporaryDirectory()
        self.backend = FakeBackend(os.path.join(self.socket_dir.name, "backend.sock"))
        await self.backend.start()
        self.gateway.console.backend = BackendClient(self.backend.path, timeout=10)
        self.now = [1000.0]
        self.gateway.console.monotonic = lambda: self.now[0]

    async def asyncTearDown(self):
        await self.backend.stop()
        self.socket_dir.cleanup()
        await self.harness.stop()

    def who(self, name):
        return {"sam": (self.sam, self.jed_leaf), "jed2": (self.jed2, self.jed2_leaf), "alex": (self.alex, self.amy_leaf),
                "kid": (self.kid, self.kid_leaf)}[name]

    async def call(self, method, path, who="sam", body=None):
        context = self.harness.client_context(*(self.who(who) if who else ()))
        data = json.dumps(body).encode() if body is not None else None
        async with aiohttp.ClientSession(connector=aiohttp.TCPConnector(ssl=context), trust_env=False) as session:
            async with session.request(method, "https://127.0.0.1:%d%s" % (self.port, path), data=data, server_hostname=HOST,
                                       headers={"Content-Type": "application/json"} if data is not None else {}) as response:
                text = await response.text()
                try:
                    parsed = json.loads(text)
                except ValueError:
                    parsed = text
                return response.status, parsed

    async def confirmed(self, method, path, body, who="sam", typed=None):
        """Request, receive the 428 confirmation, then resend with its token."""
        status, prompt = await self.call(method, path, who, body)
        self.assertEqual(428, status, prompt)
        return await self.call(method, path, who, {**body, "confirm": prompt["confirm_token"], **({"typed": typed} if typed else {})})

    async def revision_of(self, kind, key, value, who="sam"):
        _, listing = await self.call("GET", "/v1/admin/" + kind, who)
        rows = listing[kind] if kind != "invitations" else listing["pending"] + listing["codes"]
        return next(row["revision"] for row in rows if row[key] == value)

    async def alerts(self):
        await asyncio.gather(*list(self.gateway.console.alert_tasks), return_exceptions=True)

    def audit(self):
        return [dict(row) for row in self.registry.db.execute("SELECT * FROM admin_audit ORDER BY seq")]


class AuthorizationTests(AdminCase):
    async def test_account_route_shows_only_the_callers_role(self):
        self.assertEqual((200, {"uid": "sam", "display_name": "Sam", "admin": True}), await self.call("GET", "/v1/account", "sam"))
        self.assertEqual((200, {"uid": "alex", "display_name": "Alex", "admin": False}), await self.call("GET", "/v1/account", "alex"))
        self.assertEqual(401, (await self.call("GET", "/v1/account", None))[0])

    async def test_non_admin_and_disabled_accounts_are_refused_on_every_admin_route(self):
        routes = [("GET", "/v1/admin/users"), ("POST", "/v1/admin/users"), ("POST", "/v1/admin/users/alex/enabled"),
                  ("POST", "/v1/admin/users/alex/admin"), ("GET", "/v1/admin/devices"),
                  ("POST", "/v1/admin/devices/%s/revoke" % self.jed_id), ("POST", "/v1/admin/devices/%s/reissue" % self.jed_id),
                  ("GET", "/v1/admin/invitations"), ("POST", "/v1/admin/invitations"),
                  ("POST", "/v1/admin/invitations/00000000-0000-4000-8000-000000000001/approve"),
                  ("POST", "/v1/admin/invitations/00000000-0000-4000-8000-000000000001/deny"),
                  ("GET", "/v1/admin/settings"), ("PUT", "/v1/admin/settings"), ("GET", "/v1/admin/health"),
                  ("POST", "/v1/admin/test-alert"), ("GET", "/v1/admin/audit")]
        for method, path in routes:
            with self.subTest(path=path, method=method):
                status, body = await self.call(method, path, "alex", {} if method != "GET" else None)
                self.assertEqual((403, "not-admin"), (status, body["error"]))
        self.registry.set_account_flags("alex", admin=True)
        self.registry.set_account_flags("alex", enabled=False)
        for method, path in routes:
            with self.subTest(path=path, method=method, disabled=True):
                status, body = await self.call(method, path, "alex", {} if method != "GET" else None)
                self.assertEqual((403, "account-disabled"), (status, body["error"]))
        self.assertEqual([], self.backend.calls)

    async def test_role_is_on_the_account_and_removal_applies_on_the_next_call(self):
        self.assertEqual(200, (await self.call("GET", "/v1/admin/users", "sam"))[0])
        self.assertEqual(200, (await self.call("GET", "/v1/admin/users", "jed2"))[0])
        self.registry.set_account_flags("alex", admin=True)
        expect = await self.revision_of("users", "uid", "sam", "alex")
        status, body = await self.confirmed("POST", "/v1/admin/users/sam/admin", {"admin": False, "expect": expect}, "alex")
        self.assertEqual((200, False), (status, body["admin"]))
        for who in ("sam", "jed2"):
            self.assertEqual("not-admin", (await self.call("GET", "/v1/admin/users", who))[1]["error"])
        self.assertEqual([], [column for column in self.registry.db.execute("PRAGMA table_info(devices)") if "admin" in column[1]])

    async def test_read_grant_admin_device_can_view_but_not_change(self):
        reader = Device()
        invitation = self.registry.invite("sam", "read")
        pending = self.registry.enroll(invitation["code"], reader.csr)
        self.registry.begin(pending["pairing_id"], pending["fingerprint"])
        leaf = self.authority.leaf(reader.key.public_key(), pending["device_id"])
        from test_permanent_credentials import leaf_id, pem
        self.registry.activate(pending["pairing_id"], pending["fingerprint"], "t", "9", pem(leaf), leaf.not_valid_after_utc.timestamp(), leaf_id(leaf))
        context = self.harness.client_context(reader, leaf)
        async with aiohttp.ClientSession(connector=aiohttp.TCPConnector(ssl=context), trust_env=False) as session:
            for method, path in (("GET", "/v1/admin/users"), ("GET", "/v1/admin/health"), ("POST", "/v1/admin/test-alert"),
                                 ("POST", "/v1/admin/invitations")):
                async with session.request(method, "https://127.0.0.1:%d%s" % (self.port, path), server_hostname=HOST,
                                           json={} if method == "POST" else None) as response:
                    body = await response.json()
                    if method == "GET":
                        self.assertEqual(200, response.status, path)
                    else:
                        self.assertEqual((403, "read-grant"), (response.status, body["error"]), path)

    async def test_admin_requests_are_rate_limited_per_device(self):
        for _ in range(60):
            self.assertEqual(200, (await self.call("GET", "/v1/admin/settings"))[0])
        self.assertEqual((429, "rate-limited"), ((r := await self.call("GET", "/v1/admin/settings"))[0], r[1]["error"]))
        self.assertEqual(200, (await self.call("GET", "/v1/admin/settings", "jed2"))[0], "per device")
        self.now[0] += 61
        self.assertEqual(200, (await self.call("GET", "/v1/admin/settings"))[0])


class LastAdminTests(AdminCase):
    async def test_last_admin_cannot_lose_the_role_or_be_disabled(self):
        expect = await self.revision_of("users", "uid", "sam")
        for path, body in (("/v1/admin/users/sam/admin", {"admin": False}), ("/v1/admin/users/sam/enabled", {"enabled": False})):
            status, reply = await self.call("POST", path, "sam", {**body, "expect": expect})
            self.assertEqual((409, "last-admin", "Make another user an admin first."), (status, reply["error"], reply["message"]))
        self.assertTrue(self.registry.role("sam")["admin"])
        with self.assertRaises(Exception):
            self.registry.account_set("sam", enabled=False)
        self.assertTrue(self.registry.role("sam")["enabled"], "the operator account-set path is guarded too")

    async def test_two_admins_removing_each_other_at_once_exactly_one_succeeds(self):
        self.registry.set_account_flags("alex", admin=True)
        jed_rev = await self.revision_of("users", "uid", "sam")
        amy_rev = await self.revision_of("users", "uid", "alex")
        _, amy_prompt = await self.call("POST", "/v1/admin/users/sam/admin", "alex", {"admin": False, "expect": jed_rev})
        _, jed_prompt = await self.call("POST", "/v1/admin/users/alex/admin", "sam", {"admin": False, "expect": amy_rev})
        results = await asyncio.gather(
            self.call("POST", "/v1/admin/users/sam/admin", "alex", {"admin": False, "expect": jed_rev, "confirm": amy_prompt["confirm_token"]}),
            self.call("POST", "/v1/admin/users/alex/admin", "sam", {"admin": False, "expect": amy_rev, "confirm": jed_prompt["confirm_token"]}))
        statuses = sorted(status for status, _ in results)
        self.assertEqual([200, 403 if 403 in statuses else 409], statuses)
        self.assertEqual(1, len(self.registry.enabled_admins()))

    async def test_recovery_cli_is_refused_the_same_way_and_audited(self):
        from test_permanent_credentials import admin
        with self.assertRaises(Exception) as caught:
            await self.gateway.console.operator({"action": "admin", "op": "user-admin", "uid": "sam", "admin": False})
        self.assertIn("last-admin", str(caught.exception))
        result = await self.gateway.console.operator({"action": "admin", "op": "user-admin", "uid": "alex", "admin": True})
        self.assertEqual({"uid": "alex", "admin": True}, result)
        entries = [(row["actor_uid"], row["action"], row["result"]) for row in self.audit()]
        self.assertEqual([("recovery-cli", "user-admin", "last-admin"), ("recovery-cli", "user-admin", "ok")], entries)

    async def test_revoking_the_last_admins_only_device_or_ones_own_needs_the_typed_id(self):
        self.registry.disable(self.jed2_id)
        expect = await self.revision_of("devices", "id", self.jed_id)
        status, prompt = await self.call("POST", "/v1/admin/devices/%s/revoke" % self.jed_id, "sam", {"expect": expect})
        self.assertEqual((428, "sam"), (status, prompt["second_factor_typed"]))
        self.assertIn(RECOVERY, prompt["effect"])
        self.assertIn("This is the device you are using", prompt["effect"])
        status, reply = await self.call("POST", "/v1/admin/devices/%s/revoke" % self.jed_id, "sam",
                                        {"expect": expect, "confirm": prompt["confirm_token"], "typed": "jde"})
        self.assertEqual((409, "confirmation-invalid"), (status, reply["error"]))
        self.assertEqual("active", self.registry.device(self.jed_id)["state"], "wrong typing changes nothing")
        status, reply = await self.confirmed("POST", "/v1/admin/devices/%s/revoke" % self.jed_id, {"expect": expect}, "sam", typed="sam")
        self.assertEqual((200, "revoked"), (status, reply["state"]))
        self.assertEqual("revoked", self.registry.device(self.jed_id)["state"])

    async def test_revoking_another_users_device_needs_one_confirmation(self):
        expect = await self.revision_of("devices", "id", self.amy_id)
        status, prompt = await self.call("POST", "/v1/admin/devices/%s/revoke" % self.amy_id, "sam", {"expect": expect})
        self.assertIsNone(prompt["second_factor_typed"])
        self.assertIn("stops syncing at once", prompt["effect"])


class ConfirmationTests(AdminCase):
    async def test_tokens_are_single_use_bound_and_expire(self):
        expect = await self.revision_of("devices", "id", self.amy_id)
        path = "/v1/admin/devices/%s/revoke" % self.amy_id
        status, prompt = await self.call("POST", path, "sam", {"expect": expect})
        self.assertEqual(428, status)
        self.assertEqual({"error", "message", "title", "effect", "confirm_token", "second_factor_typed"}, set(prompt))
        foreign = await self.call("POST", path, "jed2", {"expect": expect, "confirm": prompt["confirm_token"]})
        self.assertEqual("confirmation-invalid", foreign[1]["error"], "bound to the acting device")
        _, prompt = await self.call("POST", path, "sam", {"expect": expect})
        self.now[0] += 121
        expired = await self.call("POST", path, "sam", {"expect": expect, "confirm": prompt["confirm_token"]})
        self.assertEqual("confirmation-invalid", expired[1]["error"])
        _, prompt = await self.call("POST", "/v1/admin/devices/%s/revoke" % self.kid_id, "sam",
                                    {"expect": await self.revision_of("devices", "id", self.kid_id)})
        other = await self.call("POST", path, "sam", {"expect": expect, "confirm": prompt["confirm_token"]})
        self.assertEqual("confirmation-invalid", other[1]["error"], "bound to the target")
        self.assertEqual("active", self.registry.device(self.amy_id)["state"])
        status, reply = await self.confirmed("POST", path, {"expect": expect})
        self.assertEqual(200, status)
        _, prompt2 = await self.call("POST", "/v1/admin/devices/%s/reissue" % self.kid_id, "sam",
                                     {"expect": await self.revision_of("devices", "id", self.kid_id)})
        await self.call("POST", "/v1/admin/devices/%s/reissue" % self.kid_id, "sam",
                        {"expect": await self.revision_of("devices", "id", self.kid_id), "confirm": prompt2["confirm_token"]})
        reused = await self.call("POST", "/v1/admin/devices/%s/reissue" % self.kid_id, "sam",
                                 {"expect": await self.revision_of("devices", "id", self.kid_id), "confirm": prompt2["confirm_token"]})
        self.assertEqual("confirmation-invalid", reused[1]["error"], "single use")

    async def test_every_destructive_route_asks_first(self):
        cases = [("POST", "/v1/admin/users/alex/enabled", {"enabled": False, "expect": await self.revision_of("users", "uid", "alex")}),
                 ("POST", "/v1/admin/users/alex/admin", {"admin": True, "expect": await self.revision_of("users", "uid", "alex")}),
                 ("POST", "/v1/admin/devices/%s/revoke" % self.amy_id, {"expect": await self.revision_of("devices", "id", self.amy_id)}),
                 ("POST", "/v1/admin/devices/%s/reissue" % self.amy_id, {"expect": await self.revision_of("devices", "id", self.amy_id)}),
                 ("PUT", "/v1/admin/settings", {"upload_limit_mib": 32, "expect": (await self.call("GET", "/v1/admin/settings"))[1]["revision"]})]
        invitation = self.registry.invite("alex", "write")
        cases.append(("POST", "/v1/admin/invitations/%s/deny" % invitation["id"],
                      {"expect": await self.revision_of("invitations", "id", invitation["id"])}))
        for method, path, body in cases:
            with self.subTest(path=path):
                status, prompt = await self.call(method, path, "sam", body)
                self.assertEqual(428, status, prompt)
                self.assertTrue(prompt["title"] and prompt["effect"])
        self.assertEqual([], self.backend.calls)
        self.assertEqual("issued", self.registry.invitation(invitation["id"])["state"])
        self.assertEqual(64 * MIB, self.gateway.mutations.limit)

    async def test_stale_revision_is_409_and_returns_the_current_one(self):
        expect = await self.revision_of("devices", "id", self.amy_id)
        self.registry.disable(self.amy_id)
        status, reply = await self.call("POST", "/v1/admin/devices/%s/revoke" % self.amy_id, "sam", {"expect": expect})
        self.assertEqual((409, "stale"), (status, reply["error"]))
        self.assertNotEqual(expect, reply["revision"])
        status, reply = await self.call("POST", "/v1/admin/users/alex/admin", "sam", {"admin": True, "expect": "0" * 16})
        self.assertEqual((409, "stale"), (status, reply["error"]))


class ActionTests(AdminCase):
    async def enroll(self, uid="alex", label="Alex's phone"):
        device = Device()
        _, created = await self.call("POST", "/v1/admin/invitations", "sam", {"uid": uid, "grant": "write", "label": label})
        pending = self.registry.enroll(created["code"], device.csr, "device label")
        return device, created, pending

    async def test_invitation_code_once_listing_never_shows_code_or_fingerprint(self):
        status, created = await self.call("POST", "/v1/admin/invitations", "sam", {"uid": "alex", "grant": "read", "label": "Tablet"})
        self.assertEqual(201, status)
        self.assertEqual(PINNED_CODE_LENGTH, len(created["code"]))            # a pinned code (spec #35)
        self.assertIn("it works once", created["warning"])
        device = Device()
        self.registry.enroll(created["code"], device.csr)
        _, listing = await self.call("GET", "/v1/admin/invitations")
        text = json.dumps(listing)
        self.assertNotIn(created["code"], text)
        self.assertNotIn(device.fingerprint, text)
        self.assertEqual("Tablet", listing["pending"][0]["label"], "the admin's label is kept")
        self.assertEqual(400, (await self.call("POST", "/v1/admin/invitations", "sam", {"uid": "alex", "grant": "admin"}))[0])
        self.assertEqual(404, (await self.call("POST", "/v1/admin/invitations", "sam", {"uid": "nobody", "grant": "read"}))[0])

    async def test_approve_compares_the_typed_fingerprint_before_the_backend(self):
        # A code issued before code-only pairing (rule 6): the admin's approval sends its own alert.
        # A pinned code's approval is announced by the gateway (tests/test_code_only_pairing.py).
        device = Device()
        created = self.registry.invite("alex", "write", "Alex's phone")
        pending = self.registry.enroll(created["code"], device.csr, "device label")
        expect = await self.revision_of("invitations", "id", created["id"])
        path = "/v1/admin/invitations/%s/approve" % created["id"]
        self.assertEqual((400, "invalid"), ((r := await self.call("POST", path, "sam", {"fingerprint": device.fingerprint[:40], "expect": expect}))[0], r[1]["error"]))
        status, reply = await self.call("POST", path, "sam", {"fingerprint": "ab" * 32, "expect": expect})
        self.assertEqual((409, "fingerprint-mismatch"), (status, reply["error"]))
        await self.alerts()
        self.assertEqual([], [call for call in self.backend.calls if call["action"] != "admin-alert"])
        self.backend.calls.clear()
        self.assertEqual("reserved", self.registry.invitation(created["id"])["state"])
        self.backend.replies["approve"] = {"state": "active", "device_id": pending["device_id"]}
        status, reply = await self.call("POST", path, "sam", {"fingerprint": device.fingerprint, "expect": expect})
        self.assertEqual((200, pending["device_id"]), (status, reply["device_id"]))
        await self.alerts()
        self.assertEqual([{"action": "approve", "pairing_id": created["id"], "fingerprint": device.fingerprint},
                          {"action": "admin-alert", "event": "device-approve-other", "actor_uid": "sam", "target_uid": "alex",
                           "device_id": pending["device_id"]}], self.backend.calls)

    async def test_revoke_refuses_at_once_and_cleans_the_token_with_retry(self):
        await self.backend.stop()
        expect = await self.revision_of("devices", "id", self.amy_id)
        status, reply = await self.confirmed("POST", "/v1/admin/devices/%s/revoke" % self.amy_id, {"expect": expect})
        self.assertEqual((200, "pending"), (status, reply["token_cleanup"]))
        self.assertEqual(403, (await self.call("GET", "/v1/account", "alex"))[0], "refused at once")
        await self.alerts()
        self.assertEqual("token-cleanup-pending", next(row for row in self.audit() if row["action"] == "device-revoke")["result"])
        self.assertEqual(1, len(self.registry.token_cleanups()))
        self.gateway.console.cleanup_task.cancel()
        await self.backend.start()
        await asyncio.wait_for(self.gateway.console.retry_cleanups(interval=0.01), 5)
        self.assertEqual([], self.registry.token_cleanups())
        self.assertEqual({"action": "token-cleanup", "uid": "alex", "token_id": "1"}, self.backend.calls[-1])
        self.assertIn(("admin-alert", "alert-failed:console-backend-unavailable"),
                      [(row["action"], row["result"]) for row in self.audit()], "a failed alert is audited")
        self.assertEqual(("system", "token-cleanup", "ok"), (self.audit()[-1]["actor_uid"], self.audit()[-1]["action"], self.audit()[-1]["result"]))

    async def test_disable_refuses_devices_without_revoking_and_enable_restores(self):
        async def recorded(uid, token=None):
            return True
        self.gateway.sharing.remember_before_disable = recorded  # mount recording itself is #42's, tested there
        expect = await self.revision_of("users", "uid", "alex")
        status, reply = await self.confirmed("POST", "/v1/admin/users/alex/enabled", {"enabled": False, "expect": expect})
        self.assertEqual((200, False), (status, reply["enabled"]))
        await self.alerts()
        self.assertEqual({"action": "nextcloud-enabled", "uid": "alex", "enabled": False}, self.backend.calls[-2])
        self.assertEqual({"action": "admin-alert", "event": "user-disable", "actor_uid": "sam", "target_uid": "alex"},
                         self.backend.calls[-1])
        self.assertEqual(403, (await self.call("GET", "/v1/account", "alex"))[0])
        self.assertEqual("active", self.registry.device(self.amy_id)["state"], "certificates are not revoked")
        expect = await self.revision_of("users", "uid", "alex")
        status, reply = await self.call("POST", "/v1/admin/users/alex/enabled", "sam", {"enabled": True, "expect": expect})
        self.assertEqual((200, True), (status, reply["enabled"]), "enable needs no confirmation")
        self.assertEqual(200, (await self.call("GET", "/v1/account", "alex"))[0], "no re-pairing")

    async def test_disable_is_refused_and_nothing_changes_when_share_mounts_cannot_be_recorded(self):
        for failure in (lambda uid: False, lambda uid: (_ for _ in ()).throw(RuntimeError("Nextcloud unreachable"))):
            async def remember(uid, token=None, failure=failure):
                return failure(uid)
            self.gateway.sharing.remember_before_disable = remember
            expect = await self.revision_of("users", "uid", "alex")
            status, reply = await self.confirmed("POST", "/v1/admin/users/alex/enabled", {"enabled": False, "expect": expect})
            self.assertEqual((503, "share-mounts-unrecorded"), (status, reply["error"]))
            self.assertEqual(console_module.MOUNTS_UNRECORDED, reply["message"])
            self.assertTrue(self.registry.role("alex")["enabled"])
            self.assertEqual(200, (await self.call("GET", "/v1/account", "alex"))[0])
        self.assertEqual([], self.backend.calls, "Nextcloud is never disabled")
        self.assertEqual(["share-mounts-unrecorded"] * 2, [row["result"] for row in self.audit()])

    async def test_an_owner_without_a_device_is_disabled_through_the_backend(self):
        """Decision #101: the backend runs the operator CLI's disable with a temporary owner token."""
        self.registry.disable(self.amy_id)

        def disable(request):
            self.registry.set_account_flags("alex", enabled=False)  # what account-set does on the gateway
            return {"uid": "alex", "enabled": False, "nextcloud": "disabled"}
        self.backend.replies["account-disable"] = disable
        expect = await self.revision_of("users", "uid", "alex")
        status, reply = await self.confirmed("POST", "/v1/admin/users/alex/enabled", {"enabled": False, "expect": expect})
        await self.alerts()
        self.assertEqual((200, False), (status, reply["enabled"]))
        self.assertEqual([{"action": "account-disable", "uid": "alex"},
                          {"action": "admin-alert", "event": "user-disable", "actor_uid": "sam", "target_uid": "alex"}],
                         self.backend.calls)

    async def test_a_device_less_disable_refusal_is_shown_plainly_and_nothing_changes(self):
        self.registry.disable(self.amy_id)
        self.backend.replies["account-disable"] = {"error": "share-mounts-unrecorded", "message": console_module.MOUNTS_UNRECORDED}
        expect = await self.revision_of("users", "uid", "alex")
        status, reply = await self.confirmed("POST", "/v1/admin/users/alex/enabled", {"enabled": False, "expect": expect})
        await self.alerts()
        self.assertEqual((503, "share-mounts-unrecorded", console_module.MOUNTS_UNRECORDED), (status, reply["error"], reply["message"]))
        self.assertTrue(self.registry.role("alex")["enabled"])
        self.assertEqual(["account-disable"], [call["action"] for call in self.backend.calls], "no alert for a refused disable")

    async def test_role_change_disable_and_revoke_each_send_one_alert_and_alert_failure_never_fails_them(self):
        async def recorded(uid, token=None):
            return True
        self.gateway.sharing.remember_before_disable = recorded
        await self.confirmed("POST", "/v1/admin/users/alex/admin", {"admin": True, "expect": await self.revision_of("users", "uid", "alex")})
        await self.confirmed("POST", "/v1/admin/users/alex/admin", {"admin": False, "expect": await self.revision_of("users", "uid", "alex")})
        await self.confirmed("POST", "/v1/admin/devices/%s/revoke" % self.kid_id, {"expect": await self.revision_of("devices", "id", self.kid_id)})
        await self.alerts()
        self.backend.replies["admin-alert"] = {"error": "failed", "message": "The alert could not be sent or queued."}
        status, reply = await self.confirmed("POST", "/v1/admin/users/alex/enabled",
                                             {"enabled": False, "expect": await self.revision_of("users", "uid", "alex")})
        await self.alerts()
        self.assertEqual((200, False), (status, reply["enabled"]), "a failed alert never fails the action")
        self.assertFalse(self.registry.role("alex")["enabled"])
        alerts = [call for call in self.backend.calls if call["action"] == "admin-alert"]
        self.assertEqual([("role-grant", "alex", None), ("role-remove", "alex", None), ("device-revoke", "kid", self.kid_id),
                          ("user-disable", "alex", None)],
                         [(call["event"], call["target_uid"], call.get("device_id")) for call in alerts])
        self.assertTrue(all(set(call) <= {"action", "event", "actor_uid", "target_uid", "device_id"} and call["actor_uid"] == "sam"
                            for call in alerts))
        self.assertEqual([("admin-alert", "alert-failed:backend-failed")],
                         [(row["action"], row["result"]) for row in self.audit() if row["action"] == "admin-alert"])

    async def test_disable_holds_the_mutation_lock_from_mount_recording_to_the_flip(self):
        """#44: no share created between reading the owner's list and the flip goes unrecorded."""
        seen = []

        async def recorded(uid, token=None):
            seen.append(self.gateway.mutations.lock.locked())
            return True
        self.gateway.sharing.remember_before_disable = recorded
        expect = await self.revision_of("users", "uid", "alex")
        status, _ = await self.confirmed("POST", "/v1/admin/users/alex/enabled", {"enabled": False, "expect": expect})
        self.assertEqual((200, [True]), (status, seen))
        self.assertFalse(self.gateway.mutations.lock.locked())

    async def test_a_refused_action_sends_no_alert(self):
        await self.call("POST", "/v1/admin/users/sam/admin", "sam", {"admin": False, "expect": await self.revision_of("users", "uid", "sam")})
        await self.alerts()
        self.assertEqual([], self.backend.calls)

    async def test_backend_down_answers_503_while_views_keep_working(self):
        await self.backend.stop()
        for method, path, body in (("POST", "/v1/admin/users", {"uid": "zoe", "display_name": "Zoe"}),
                                   ("POST", "/v1/admin/test-alert", {})):
            status, reply = await self.call(method, path, "sam", body)
            self.assertEqual((503, "console-backend-unavailable", RESTARTING), (status, reply["error"], reply["message"]))
        status, health = await self.call("GET", "/v1/admin/health")
        self.assertEqual((200, "unavailable"), (status, health["server"]["state"]))
        self.assertTrue(health["gateway"]["ready"])
        for path in ("/v1/admin/users", "/v1/admin/devices", "/v1/admin/invitations", "/v1/admin/settings", "/v1/admin/audit"):
            self.assertEqual(200, (await self.call("GET", path))[0], path)
        self.assertIsNone(self.registry.role("zoe"), "nothing registered without the Nextcloud account")

    async def test_user_add_creates_through_the_backend_then_registers(self):
        self.backend.replies["user-add"] = {"uid": "zoe", "state": "created"}
        status, reply = await self.call("POST", "/v1/admin/users", "sam", {"uid": "zoe", "display_name": "Zoe"})
        self.assertEqual((201, "created"), (status, reply["state"]))
        self.assertEqual({"uid": "zoe", "display_name": "Zoe", "enabled": True, "admin": False}, self.registry.role("zoe"))
        _, listing = await self.call("GET", "/v1/admin/users")
        self.assertEqual([False], [bool(row.get("setup_incomplete")) for row in listing["users"] if row["uid"] == "zoe"])
        self.assertEqual((409, "exists"), ((r := await self.call("POST", "/v1/admin/users", "sam", {"uid": "zoe", "display_name": "Z"}))[0], r[1]["error"]))
        self.assertEqual(400, (await self.call("POST", "/v1/admin/users", "sam", {"uid": "Zoe!", "display_name": "Z"}))[0])

    async def test_upload_limit_change_is_confirmed_and_applied_at_runtime(self):
        expect = (await self.call("GET", "/v1/admin/settings"))[1]["revision"]
        for value, message in ((0, "Choose a whole number of MiB from 1 to 64."), (65, "Above 64 MiB needs large-transfer support (Feature #6)."),
                               (1.5, "Choose a whole number of MiB from 1 to 64."), ("32", "Choose a whole number of MiB from 1 to 64.")):
            status, reply = await self.call("PUT", "/v1/admin/settings", "sam", {"upload_limit_mib": value, "expect": expect})
            self.assertEqual((400, message), (status, reply["message"]))
        status, reply = await self.confirmed("PUT", "/v1/admin/settings", {"upload_limit_mib": 32, "expect": expect})
        self.assertEqual((200, 32), (status, reply["upload_limit_mib"]))
        self.assertEqual(32 * MIB, self.gateway.mutations.limit)
        self.assertEqual("settings-change", self.audit()[-1]["action"])

    async def test_audit_covers_refusals_pages_and_never_carries_secrets(self):
        device, created, pending = await self.enroll()
        await self.call("POST", "/v1/admin/invitations/%s/approve" % created["id"], "sam",
                        {"fingerprint": "cd" * 32, "expect": await self.revision_of("invitations", "id", created["id"])})
        await self.call("POST", "/v1/admin/users/sam/admin", "sam", {"admin": False, "expect": await self.revision_of("users", "uid", "sam")})
        await self.call("POST", "/v1/admin/users", "alex", {"uid": "x", "display_name": "X"})
        await self.confirmed("POST", "/v1/admin/devices/%s/revoke" % self.kid_id, {"expect": await self.revision_of("devices", "id", self.kid_id)})
        rows = self.audit()
        self.assertEqual(["invitation-create", "invitation-approve", "user-admin", "user-add", "device-revoke"], [row["action"] for row in rows])
        self.assertEqual(["ok", "fingerprint-mismatch", "last-admin", "not-admin", "ok"], [row["result"] for row in rows])
        self.assertEqual(("alex", self.amy_id), (rows[3]["actor_uid"], rows[3]["actor_device"]))
        text = json.dumps(rows) + json.dumps(self.harness.lines())
        for secret in (created["code"], device.fingerprint, "cd" * 32, "token-alex", "BEGIN CERTIFICATE"):
            self.assertNotIn(secret, text)
        self.assertTrue(any(line.get("route") == "admin" for line in self.harness.lines()))
        status, page = await self.call("GET", "/v1/admin/audit?limit=2")
        self.assertEqual(["device-revoke", "user-add"], [row["action"] for row in page["entries"]])
        status, older = await self.call("GET", "/v1/admin/audit?limit=2&after=%d" % page["after"])
        self.assertEqual(["user-admin", "invitation-approve"], [row["action"] for row in older["entries"]])

    async def test_health_combines_gateway_and_backend_facts(self):
        self.backend.replies["health"] = {"state": "ok", "pm2": {"state": "not-configured"}}
        self.gateway.guard.history.append(__import__("time").time())
        status, health = await self.call("GET", "/v1/admin/health")
        self.assertEqual(200, status)
        self.assertEqual({"state": "clear", "kind": None}, health["gateway"]["write_fence"])
        self.assertEqual(1, health["gateway"]["enroll_blocks_24h"])
        self.assertEqual({"state": "ok", "pm2": {"state": "not-configured"}}, health["server"])

    async def test_devices_listing_marks_this_device_and_last_seen(self):
        _, listing = await self.call("GET", "/v1/admin/devices", "sam")
        rows = {row["id"]: row for row in listing["devices"]}
        self.assertTrue(rows[self.jed_id]["this_device"])
        self.assertFalse(rows[self.jed2_id]["this_device"])
        self.assertIsNotNone(rows[self.jed_id]["last_seen"])
        self.assertEqual({"id", "uid", "display_name", "label", "computer_name", "fingerprint_short", "grant", "state", "last_seen",
                          "certificate_expires", "transition_leaves", "this_device", "revision"}, set(rows[self.jed_id]))


class ReviewFixTests(AdminCase):
    """PR #43 review (decision #103): M1-M3, L1-L4 and the -other alerts."""

    async def test_user_add_refuses_reserved_invalid_and_existing_server_accounts_before_any_creation(self):
        for uid in ("anj-admin", "admin", "recovery-cli", "system", "bootstrap"):
            status, reply = await self.call("POST", "/v1/admin/users", "sam", {"uid": uid, "display_name": "X"})
            self.assertEqual((409, "reserved"), (status, reply["error"]), uid)
        for uid in ("1amy", "-help", "Alex", "a" * 33, "", None, "am y"):
            status, reply = await self.call("POST", "/v1/admin/users", "sam", {"uid": uid, "display_name": "X"})
            self.assertEqual((400, "invalid"), (status, reply["error"]), uid)
        for name in ("\u202eevil", "a\x9fb", "\u200b", "", "x" * 65, None):
            status, reply = await self.call("POST", "/v1/admin/users", "sam", {"uid": "zoe", "display_name": name})
            self.assertEqual((400, "invalid"), (status, reply["error"]), repr(name))
        self.assertEqual([], self.backend.calls, "nothing reaches the backend")
        self.backend.replies["user-add"] = {"error": "exists", "message": "There is already a server account zoe that is not a household user; choose another user id."}
        status, reply = await self.call("POST", "/v1/admin/users", "sam", {"uid": "zoe", "display_name": "Zoe"})
        self.assertEqual((409, "exists"), (status, reply["error"]))
        self.assertIn("choose another user id", reply["message"])
        self.assertIsNone(self.registry.role("zoe"))
        self.assertEqual(5 + 7 + 6 + 1, len([row for row in self.audit() if row["action"] == "user-add"]), "every attempt audited")

    async def test_an_existing_digit_first_account_stays_manageable_but_cannot_be_added(self):
        """Ruling on PR #43: the leading letter applies to user-add only."""
        async def recorded(uid, token=None):
            return True
        self.gateway.sharing.remember_before_disable = recorded
        self.registry.account_set("1amy", "One Alex")
        one = Device()
        one_id, _ = pair(self.registry, self.authority, one, "1amy")
        expect = await self.revision_of("users", "uid", "1amy")
        status, reply = await self.confirmed("POST", "/v1/admin/users/1amy/enabled", {"enabled": False, "expect": expect})
        self.assertEqual((200, False), (status, reply["enabled"]))
        self.assertFalse(self.registry.role("1amy")["enabled"])
        expect = await self.revision_of("users", "uid", "1amy")
        status, reply = await self.call("POST", "/v1/admin/users/1amy/enabled", "sam", {"enabled": True, "expect": expect})
        self.assertEqual((200, True), (status, reply["enabled"]))
        self.assertTrue(self.registry.role("1amy")["enabled"])
        self.assertIn({"action": "nextcloud-enabled", "uid": "1amy", "enabled": False}, self.backend.calls)
        self.assertIn({"action": "nextcloud-enabled", "uid": "1amy", "enabled": True}, self.backend.calls)
        status, reply = await self.call("POST", "/v1/admin/invitations", "sam", {"uid": "1amy", "grant": "read"})
        self.assertEqual(201, status, "devices can still be invited for it")
        self.backend.calls.clear()
        status, reply = await self.call("POST", "/v1/admin/users", "sam", {"uid": "1zoe", "display_name": "Zoe"})
        self.assertEqual((400, "invalid", "User id: 1-32 lowercase letters, digits or '-', starting with a letter."),
                         (status, reply["error"], reply["message"]))
        await self.alerts()
        self.assertEqual([], [call for call in self.backend.calls if call["action"] == "user-add"])

    async def test_a_half_made_account_is_recorded_audited_and_finished_by_adding_again(self):
        self.backend.replies["user-add"] = {"uid": "zoe", "state": "created"}
        original = self.registry.account_set

        def broken(*args, **kwargs):
            raise RuntimeError("database is locked")
        self.registry.account_set = broken
        status, reply = await self.call("POST", "/v1/admin/users", "sam", {"uid": "zoe", "display_name": "Zoe"})
        self.assertEqual((503, "account-pending"), (status, reply["error"]))
        self.assertIn("Add the user again to finish", reply["message"])
        self.assertEqual(["zoe"], self.registry.account_cleanups())
        self.assertEqual("account-pending", self.audit()[-1]["result"])
        self.registry.account_set = original
        _, listing = await self.call("GET", "/v1/admin/users")
        pending = [row for row in listing["users"] if row.get("setup_incomplete")]
        self.assertEqual([{"uid": "zoe", "display_name": "Zoe", "enabled": False, "admin": False, "active_devices": 0,
                           "setup_incomplete": True}], [{k: v for k, v in row.items() if k != "revision"} for row in pending],
                         "a half-made account is listed, never hidden")
        self.backend.replies["user-add"] = lambda request: {"uid": "zoe", "state": "exists" if request.get("resume") else "refused"}
        status, reply = await self.call("POST", "/v1/admin/users", "sam", {"uid": "zoe", "display_name": "Zoe"})
        self.assertEqual((201, "finished"), (status, reply["state"]))
        self.assertTrue(self.backend.calls[-1]["resume"])
        self.assertEqual([], self.registry.account_cleanups())
        self.assertEqual({"uid": "zoe", "display_name": "Zoe", "enabled": True, "admin": False}, self.registry.role("zoe"))
        _, listing = await self.call("GET", "/v1/admin/users")
        self.assertEqual([False], [bool(row.get("setup_incomplete")) for row in listing["users"] if row["uid"] == "zoe"])

    async def test_an_unexpected_failure_is_audited_and_plain(self):
        def broken():
            raise RuntimeError("/var/lib/anj/registry.sqlite: disk I/O error")
        self.registry.public_devices = broken
        status, reply = await self.call("POST", "/v1/admin/devices/%s/revoke" % self.amy_id, "sam", {"expect": "x"})
        self.assertEqual((500, "error"), (status, reply["error"]))
        self.assertNotIn("sqlite", reply["message"])
        self.assertEqual(("device-revoke", "error"), (self.audit()[-1]["action"], self.audit()[-1]["result"]))

    async def test_technical_backend_text_never_reaches_the_admin(self):
        self.backend.replies["test-alert"] = {"error": "failed", "message": "Command failed (exit 1); output withheld: docker"}
        status, reply = await self.call("POST", "/v1/admin/test-alert", "sam", {})
        self.assertEqual((502, console_module.BACKEND_FAILED), (status, reply["message"]))

    async def test_a_reply_in_pieces_is_read_to_the_end(self):
        await self.backend.stop()

        async def handle(reader, writer):
            await reader.read()
            writer.write(b'{"state": "se')
            await writer.drain()
            await asyncio.sleep(0.2)
            writer.write(b'nt"}')
            await writer.drain()
            writer.close()
        server = await asyncio.start_unix_server(handle, self.backend.path)
        try:
            self.assertEqual((200, {"state": "sent"}), (await self.call("POST", "/v1/admin/test-alert", "sam", {}))[:2])
        finally:
            server.close()
            await server.wait_closed()

    async def test_an_admin_disabling_their_own_account_gets_the_reply(self):
        async def recorded(uid, token=None):
            return True
        self.gateway.sharing.remember_before_disable = recorded
        self.registry.set_account_flags("alex", admin=True)
        expect = await self.revision_of("users", "uid", "alex", "alex")
        status, reply = await self.confirmed("POST", "/v1/admin/users/alex/enabled", {"enabled": False, "expect": expect}, "alex")
        self.assertEqual((200, False), (status, reply["enabled"]))
        self.assertEqual(403, (await self.call("GET", "/v1/account", "alex"))[0], "refused from the next request")

    async def test_inviting_or_approving_for_another_account_alerts_but_not_for_ones_own(self):
        await self.call("POST", "/v1/admin/invitations", "sam", {"uid": "sam", "grant": "write"})
        await self.alerts()
        self.assertEqual([], self.backend.calls, "own account: no alert")
        _, created = await self.call("POST", "/v1/admin/invitations", "sam", {"uid": "alex", "grant": "write"})
        await self.alerts()
        self.assertEqual([{"action": "admin-alert", "event": "device-invite-other", "actor_uid": "sam", "target_uid": "alex"}],
                         self.backend.calls)
        await self.gateway.console.operator({"action": "admin", "op": "invite", "uid": "sam", "grant": "read"})
        await self.alerts()
        self.assertEqual({"action": "admin-alert", "event": "device-invite-other", "actor_uid": "recovery-cli", "target_uid": "sam"},
                         self.backend.calls[-1], "the recovery CLI is never the account's own device")

    async def test_recovery_audit_import_is_per_entry_and_idempotent(self):
        good = {"id": "a" * 32, "time": 5.0, "action": "user-admin", "result": "gateway-unavailable", "target_uid": "alex"}
        bad = {"id": "b" * 32, "time": 6.0, "action": "user-admin; drop", "result": "x"}
        first = self.gateway.console.import_audit([good, bad, "junk"])
        self.assertEqual({"imported": 1, "skipped": 0, "rejected": [1, 2]}, first)
        again = self.gateway.console.import_audit([good])
        self.assertEqual({"imported": 0, "skipped": 1, "rejected": []}, again)
        self.assertEqual(1, len([row for row in self.audit() if row["actor_uid"] == "recovery-cli"]))


class UidRuleTests(unittest.TestCase):
    def test_the_registry_refuses_a_leading_dash_and_keeps_digit_first_ids(self):
        with tempfile.TemporaryDirectory() as directory:
            registry = Registry(directory)
            for uid in ("-x", "--help", "-", "Alex", "a" * 33, ""):
                with self.assertRaises(ValueError, msg=uid):
                    registry.account_set(uid, "X")
            self.assertEqual("1amy", registry.account_set("1amy", "One Alex")[0]["uid"])
            with self.assertRaises(ValueError):
                registry.import_first_admins([{"uid": "-x", "display_name": "X"}], ["-x"])
            self.assertEqual([], [row for row in registry.roles() if row["uid"].startswith("-")])
            registry.db.close()


class FirstAdminImportTests(unittest.TestCase):
    def test_import_grants_once_and_never_demotes(self):
        with tempfile.TemporaryDirectory() as directory:
            registry = Registry(directory)
            accounts = [{"uid": "sam", "display_name": "Sam"}]
            self.assertEqual({"state": "imported", "granted": ["sam"]}, registry.import_first_admins(accounts, ["sam"]))
            self.assertTrue(registry.role("sam")["admin"])
            self.assertEqual({"state": "already-imported", "granted": []}, registry.import_first_admins(accounts, ["sam"]))
            self.assertEqual(1, registry.db.execute("SELECT count(*) FROM admin_audit WHERE action='first-admin-import'").fetchone()[0])
            registry.db.close()
        with tempfile.TemporaryDirectory() as directory:
            registry = Registry(directory)
            registry.account_set("alex", "Alex")
            registry.set_account_flags("alex", admin=True)
            result = registry.import_first_admins([{"uid": "sam", "display_name": "Sam"}], ["sam"])
            self.assertEqual([], result["granted"], "an existing enabled admin means no grant")
            self.assertTrue(registry.role("alex")["admin"])
            self.assertFalse(registry.role("sam")["admin"])
            with self.assertRaises(ValueError):
                registry.import_first_admins([{"uid": "Bad Name"}], [])
            registry.db.close()


if __name__ == "__main__":
    unittest.main()


class LongActionTests(AdminCase):
    """SC-041 F1: production HAProxy (TLS passthrough) cuts a connection idle for 120 s and cannot
    see the path, so every admin request is answered within the gateway's hold; a longer action
    keeps running, answers 202 and is collected by the same device."""

    async def asyncSetUp(self):
        await super().asyncSetUp()
        self.gateway.console.operation_hold = 0.3
        self.backend.delays["user-add"] = 1.0
        self.backend.replies["user-add"] = {"uid": "zoe", "state": "created"}

    async def collect(self, operation, who="sam", rounds=20):
        for _ in range(rounds):
            status, reply = await self.call("GET", "/v1/admin/operations/" + operation, who)
            if status != 202:
                return status, reply
        self.fail("the operation never finished")

    async def test_a_slow_action_answers_202_and_its_own_result_is_collected(self):
        status, reply = await self.call("POST", "/v1/admin/users", "sam", {"uid": "zoe", "display_name": "Zoe"})
        self.assertEqual((202, "running"), (status, reply["state"]))
        self.assertRegex(reply["operation"], r"^[0-9a-f]{32}$")
        self.assertEqual(console_module.STILL_WORKING, reply["message"])
        self.assertEqual((201, {"uid": "zoe", "state": "created"}), await self.collect(reply["operation"]))
        self.assertEqual({"uid": "zoe", "display_name": "Zoe", "enabled": True, "admin": False}, self.registry.role("zoe"))
        self.assertEqual([("user-add", "ok")], [(row["action"], row["result"]) for row in self.audit()
                                                if row["action"] == "user-add"], "audited once, when it finished")
        # A poll whose reply was lost collects the same result again until it is forgotten.
        self.assertEqual((201, {"uid": "zoe", "state": "created"}), await self.collect(reply["operation"]))
        self.now[0] += console_module.OPERATION_KEEP + 1
        status, again = await self.call("GET", "/v1/admin/operations/" + reply["operation"])
        self.assertEqual((404, "operation-unknown"), (status, again["error"]))

    async def test_a_refusal_after_the_hold_is_collected_with_its_status(self):
        self.backend.replies["user-add"] = {"error": "exists", "message": "There is already a server account zoe."}
        status, reply = await self.call("POST", "/v1/admin/users", "sam", {"uid": "zoe", "display_name": "Zoe"})
        self.assertEqual(202, status)
        status, result = await self.collect(reply["operation"])
        self.assertEqual((409, "exists"), (status, result["error"]))
        self.assertEqual("exists", self.audit()[-1]["result"])

    async def test_only_the_device_that_started_it_can_collect(self):
        status, reply = await self.call("POST", "/v1/admin/users", "sam", {"uid": "zoe", "display_name": "Zoe"})
        self.assertEqual(202, status)
        self.registry.set_account_flags("kid", admin=True)     # another admin, another account
        for who in ("jed2", "kid"):
            status, other = await self.call("GET", "/v1/admin/operations/" + reply["operation"], who)
            self.assertEqual((404, "operation-unknown"), (status, other["error"]), who)
        self.assertEqual("not-admin", (await self.call("GET", "/v1/admin/operations/" + reply["operation"], "alex"))[1]["error"])
        self.assertEqual(401, (await self.call("GET", "/v1/admin/operations/" + reply["operation"], None))[0])
        for bad in ("x" * 32, "0" * 31, "A" * 32, "0" * 33):
            self.assertEqual(404, (await self.call("GET", "/v1/admin/operations/" + bad))[0], bad)
        self.assertEqual(201, (await self.collect(reply["operation"]))[0])

    async def test_a_client_that_goes_away_never_cuts_the_action(self):
        self.gateway.console.operation_hold = 30.0
        context = self.harness.client_context(*self.who("sam"))
        with self.assertRaises(asyncio.TimeoutError):
            async with aiohttp.ClientSession(connector=aiohttp.TCPConnector(ssl=context), trust_env=False,
                                             timeout=aiohttp.ClientTimeout(total=0.3)) as session:
                await session.post("https://127.0.0.1:%d/v1/admin/users" % self.port, server_hostname=HOST,
                                   data=json.dumps({"uid": "zoe", "display_name": "Zoe"}).encode(),
                                   headers={"Content-Type": "application/json"})
        for _ in range(50):
            if self.registry.role("zoe"):
                break
            await asyncio.sleep(0.1)
        self.assertEqual({"uid": "zoe", "display_name": "Zoe", "enabled": True, "admin": False}, self.registry.role("zoe"))
        await asyncio.sleep(0.1)
        self.assertEqual([("user-add", "ok")], [(row["action"], row["result"]) for row in self.audit()
                                                if row["action"] == "user-add"])
        self.assertEqual([], self.registry.account_cleanups())

    async def test_fast_actions_answer_directly(self):
        self.backend.delays.clear()
        status, reply = await self.call("POST", "/v1/admin/users", "sam", {"uid": "zoe", "display_name": "Zoe"})
        self.assertEqual((201, "created"), (status, reply["state"]))
        self.assertEqual({}, self.gateway.console.operations)


class SetupIncompleteTests(AdminCase):
    """SC-041 (older): a cut or timed-out user add never leaves a server account nobody sees."""

    def pending(self, listing):
        return [row["uid"] for row in listing["users"] if row.get("setup_incomplete")]

    async def test_it_is_listed_while_the_backend_works_and_cleared_when_done(self):
        self.gateway.console.operation_hold = 0.3
        self.backend.delays["user-add"] = 1.0
        self.backend.replies["user-add"] = {"uid": "zoe", "state": "created"}
        status, reply = await self.call("POST", "/v1/admin/users", "sam", {"uid": "zoe", "display_name": "Zoe"})
        self.assertEqual(202, status)
        _, listing = await self.call("GET", "/v1/admin/users")
        self.assertEqual(["zoe"], self.pending(listing), "recorded before the backend call")
        for _ in range(20):
            status, result = await self.call("GET", "/v1/admin/operations/" + reply["operation"])
            if status != 202:
                break
        self.assertEqual(201, status)
        _, listing = await self.call("GET", "/v1/admin/users")
        self.assertEqual([], self.pending(listing))
        self.assertEqual([], self.registry.account_cleanups())

    async def test_a_backend_that_never_answers_leaves_setup_incomplete_then_add_again_finishes(self):
        self.gateway.console.backend = BackendClient(self.backend.path, timeout=0.3)
        self.backend.delays["user-add"] = 1.0
        status, reply = await self.call("POST", "/v1/admin/users", "sam", {"uid": "zoe", "display_name": "Zoe"})
        self.assertEqual((503, "console-backend-unavailable"), (status, reply["error"]))
        _, listing = await self.call("GET", "/v1/admin/users")
        self.assertEqual(["zoe"], self.pending(listing), "the outcome is unknown: the admin sees it")
        self.assertEqual("console-backend-unavailable", self.audit()[-1]["result"])
        self.backend.delays.clear()
        self.backend.replies["user-add"] = lambda request: {"uid": "zoe", "state": "exists" if request.get("resume") else "refused"}
        status, reply = await self.call("POST", "/v1/admin/users", "sam", {"uid": "zoe", "display_name": "Zoe"})
        self.assertEqual((201, "finished"), (status, reply["state"]))
        self.assertTrue(self.backend.calls[-1]["resume"])
        self.assertEqual([], self.registry.account_cleanups())
        self.assertEqual({"uid": "zoe", "display_name": "Zoe", "enabled": True, "admin": False}, self.registry.role("zoe"))

    async def test_a_definite_refusal_or_an_unreachable_backend_records_nothing(self):
        for reply in ({"error": "exists", "message": "There is already a server account zoe."},
                      {"error": "refused", "message": "Invalid request"}):
            self.backend.replies["user-add"] = reply
            status, _ = await self.call("POST", "/v1/admin/users", "sam", {"uid": "zoe", "display_name": "Zoe"})
            self.assertIn(status, (409, 502), reply)
            self.assertEqual([], self.registry.account_cleanups(), reply)
        await self.backend.stop()
        status, reply = await self.call("POST", "/v1/admin/users", "sam", {"uid": "zoe", "display_name": "Zoe"})
        self.assertEqual((503, "console-backend-unavailable"), (status, reply["error"]))
        self.assertEqual([], self.registry.account_cleanups(), "nothing was sent, so nothing to finish")

    async def test_a_backend_failure_keeps_it_and_finishing_a_foreign_account_clears_it(self):
        self.backend.replies["user-add"] = {"error": "failed", "message": "withheld"}
        status, _ = await self.call("POST", "/v1/admin/users", "sam", {"uid": "zoe", "display_name": "Zoe"})
        self.assertEqual(502, status)
        self.assertEqual(["zoe"], self.registry.account_cleanups(), "a failure may have created it")
        # Finishing: the backend finds a server account it did not create and refuses to adopt it.
        self.backend.replies["user-add"] = {"error": "exists", "message": "There is already a server account zoe."}
        status, reply = await self.call("POST", "/v1/admin/users", "sam", {"uid": "zoe", "display_name": "Zoe"})
        self.assertEqual((409, "exists"), (status, reply["error"]))
        self.assertTrue(self.backend.calls[-1]["resume"])
        self.assertEqual([], self.registry.account_cleanups())
        self.assertIsNone(self.registry.role("zoe"))
