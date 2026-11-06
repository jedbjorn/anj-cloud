"""Household administration (spec #27, decision #87): `/v1/account`, `/v1/admin/*` and the
operator socket's `admin` action used by the recovery CLI.

The admin role is on the account. Every admin request is authorized per request (no caching):
an active device whose account exists, is enabled and holds the role; mutations also need a
write-grant device. Destructive actions need a server-issued, single-use confirmation; every
mutating request names the target revision it was shown (`expect`), and a changed target is
409 `stale`. Every mutating attempt, including refusals, is audited with ids and a result class
only. Work needing the issuer key, `occ` or PM2 goes to the console backend over its private
Unix socket; the gateway never holds the mutation lock while it waits for the backend, because
the backend's approve flow calls back into the operator socket (`begin`/`activate`).
"""

import asyncio
from collections import deque
from datetime import datetime, timezone
import hashlib
import hmac
import json
import os
import re
import secrets
import time

from aiohttp import web

from .protocol import UPLOAD_LIMIT_MAX, UPLOAD_LIMIT_MIN, Rejection  # noqa: F401 - Rejection mapped in http()
from .naming import NAME_TEXT, NEW_UID_TEXT, RESERVED_UIDS, UNNAMED, clean_device_name, clean_display_name, valid_new_uid
from .registry import LAST_ADMIN_TEXT, LastAdmin

MIB = 1024 * 1024
ADMIN_RATE, ADMIN_WINDOW = 60, 60.0
CONFIRM_SECONDS = 120.0
BACKEND_SOCKET = "/run/anj-console/backend.sock"
BACKEND_TIMEOUT = 300.0
CLEANUP_RETRY_SECONDS = 30.0
FINGERPRINT = re.compile(r"[0-9a-f]{64}")
IDENTIFIER = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
RESTARTING = "The server's admin service is restarting; try again in a minute."
# Backend failures without a specific refusal are shown in plain language (spec #27 Quality 8).
BACKEND_FAILED = "The server could not complete this; try again in a minute. If it keeps failing, look at Health."
UNEXPECTED = "Something went wrong on the server; nothing more is known. Try again in a minute."
# Backend refusals whose own text is shown as is.
BACKEND_TEXTS = {"fingerprint-mismatch": 409, "stale": 409, "last-admin": 409, "exists": 409, "reserved": 409,
                 "not-configured": 503, "unavailable": 503, "share-mounts-unrecorded": 503}
MAX_REPLY = 1 << 20
RECOVERY = "After this, nobody can open Admin. Recovery is only through the recovery CLI over SSH from the VM host."
NO_STORE = {"Cache-Control": "no-store"}
# #42's refusal when recipients' mounts cannot be recorded before a disable (shown as is).
MOUNTS_UNRECORDED = ("Could not read this account's shares to record where recipients mount them; the account was not "
                     "disabled. Retry the disable.")

RECOVERY_ACTOR = "recovery-cli"
SYSTEM_ACTOR = "system"
# SC-041 F1: production HAProxy relays TLS untouched (TCP mode, decision #45) and closes a
# connection idle in both directions for 120 s; it cannot see the path, so no admin route can get a
# longer timeout there. Every admin request is therefore answered within OPERATION_HOLD: an action
# still running then keeps running here and the request answers 202 {"operation": id}; the same
# device's GET /v1/admin/operations/{id} waits up to OPERATION_HOLD again and returns the action's
# own response once it is done. tests/test_admin_timeouts.py ties these to HAProxy and the client.
OPERATION_HOLD = 25.0
OPERATION_KEEP = 600.0
OPERATION_ID = re.compile(r"[0-9a-f]{32}")
STILL_WORKING = "Still working on it; this can take a few minutes."
OPERATION_UNKNOWN = ("The server no longer has this action's result (it may have restarted). Refresh to see whether "
                     "it happened.")


class AdminError(Exception):
    """A curated refusal: HTTP status, a stable reason class and a plain-language message."""

    def __init__(self, status, reason, message, **extra):
        super().__init__(message)
        self.status, self.reason, self.message, self.extra = status, reason, message, extra

    def response(self):
        return web.json_response({"error": self.reason, "message": self.message, **self.extra}, status=self.status, headers=NO_STORE)


def revision(*parts):
    return hashlib.sha256("\x1f".join("" if part is None else str(part) for part in parts).encode()).hexdigest()[:16]


def iso(timestamp):
    if timestamp is None:
        return None
    return datetime.fromtimestamp(timestamp, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class BackendUnreachable(AdminError):
    """The backend's socket could not be reached: nothing was sent, so nothing was done."""


# Backend replies after which the backend certainly created no account (SC-041, user add).
NOTHING_CREATED = ("exists", "reserved", "unavailable", "not-configured", "backend-refused")


class BackendClient:
    """One JSON request per connection to the console backend's private Unix socket."""

    def __init__(self, path=None, timeout=BACKEND_TIMEOUT):
        self.path = path or os.environ.get("ANJ_CONSOLE_SOCKET", BACKEND_SOCKET)
        self.timeout = timeout

    async def call(self, action, **data):
        try:
            reader, writer = await asyncio.wait_for(asyncio.open_unix_connection(self.path), 5)
        except (OSError, asyncio.TimeoutError):
            raise BackendUnreachable(503, "console-backend-unavailable", RESTARTING) from None
        async def read_all():
            # The whole reply, to EOF, bounded: a reply may arrive in several pieces.
            chunks, size = [], 0
            while chunk := await reader.read(65536):
                size += len(chunk)
                if size > MAX_REPLY:
                    raise ValueError("Backend reply too large")
                chunks.append(chunk)
            return b"".join(chunks)

        try:
            writer.write(json.dumps({"action": action, **data}).encode())
            await writer.drain()
            writer.write_eof()
            reply = json.loads(await asyncio.wait_for(read_all(), self.timeout))
        except (OSError, ValueError, asyncio.TimeoutError):
            raise AdminError(503, "console-backend-unavailable", RESTARTING) from None
        finally:
            writer.close()
        if not isinstance(reply, dict):
            raise AdminError(503, "console-backend-unavailable", RESTARTING)
        if "error" in reply:
            reason = str(reply["error"])
            if reason in BACKEND_TEXTS:
                raise AdminError(BACKEND_TEXTS[reason], reason, str(reply.get("message") or BACKEND_FAILED))
            raise AdminError(502, "backend-" + (reason if reason in ("refused", "failed") else "failed"), BACKEND_FAILED)
        return reply


class Context:
    """Who acts: an admin's device over HTTPS, or the recovery CLI over the operator socket."""

    def __init__(self, actor_uid, actor_device=None, request=None, rights="write"):
        self.uid, self.device, self.request, self.rights = actor_uid, actor_device, request, rights

    @property
    def cli(self):
        return self.request is None


class Console:
    def __init__(self, gateway, backend=None, clock=None, monotonic=time.monotonic):
        self.gateway, self.registry = gateway, gateway.registry
        self.backend = backend or BackendClient()
        self.clock = clock or self.registry.clock
        self.monotonic = monotonic
        self.confirmations = {}
        self.requests = {}
        self.cleanup_task = None
        self.alert_tasks = set()
        self.operations, self.operation_tasks = {}, set()
        self.operation_hold = OPERATION_HOLD

    # Routes ----------------------------------------------------------------------------------

    def add_routes(self, router):
        router.add_get("/v1/account", self.account)
        router.add_get("/v1/admin/operations/{operation}", self.operation)
        table = (
            ("GET", "/v1/admin/users", "users", False, self.users),
            ("POST", "/v1/admin/users", "user-add", True, self.user_add),
            ("POST", "/v1/admin/users/{uid}/enabled", "user-enabled", True, self.user_enabled),
            ("POST", "/v1/admin/users/{uid}/admin", "user-admin", True, self.user_admin),
            ("GET", "/v1/admin/devices", "devices", False, self.devices),
            ("POST", "/v1/admin/devices/{device_id}/revoke", "device-revoke", True, self.device_revoke),
            ("POST", "/v1/admin/devices/{device_id}/reissue", "device-reissue", True, self.device_reissue),
            ("GET", "/v1/admin/invitations", "invitations", False, self.invitations),
            ("POST", "/v1/admin/invitations", "invitation-create", True, self.invitation_create),
            ("POST", "/v1/admin/invitations/{invitation_id}/approve", "invitation-approve", True, self.invitation_approve),
            ("POST", "/v1/admin/invitations/{invitation_id}/deny", "invitation-deny", True, self.invitation_deny),
            ("GET", "/v1/admin/settings", "settings", False, self.settings),
            ("PUT", "/v1/admin/settings", "settings-change", True, self.settings_change),
            ("GET", "/v1/admin/health", "health", False, self.health),
            ("POST", "/v1/admin/test-alert", "test-alert", True, self.test_alert),
            ("GET", "/v1/admin/audit", "audit", False, self.audit_list),
        )
        for method, path, action, mutating, function in table:
            router.add_route(method, path, self.http(action, mutating, function))

    async def account(self, request):
        """Any active device: its own account and role, never another account."""
        device = self.gateway.identity(request)
        if request.query_string:
            raise web.HTTPBadRequest(text="Queries are unsupported")
        role = self.registry.role(device["uid"])
        return web.json_response({"uid": device["uid"], "display_name": role["display_name"] if role else device["uid"],
                                  "admin": bool(role and role["enabled"] and role["admin"])}, headers=NO_STORE)

    def http(self, action, mutating, function):
        async def handle(request):
            state = {"context": None, "targets": {}}
            try:
                state["context"] = self.authorize(request, mutating)
                body = await self.body(request) if mutating else {}
                if request.query_string and action != "audit":
                    raise AdminError(400, "invalid", "Queries are unsupported")
            except web.HTTPException:
                raise
            except Exception as failure:  # noqa: BLE001 - curated, audited reply
                return self.failure(request, action, mutating, state, failure)

            async def run():
                try:
                    result = await function(state["context"], request.match_info, body, state["targets"])
                    if mutating:
                        self.record(state["context"], action, state["targets"],
                                    result.pop("_audit", "ok") if isinstance(result, dict) else "ok")
                    return web.json_response(result, status=201 if action in ("user-add", "invitation-create") else 200,
                                             headers=NO_STORE)
                except web.HTTPException:
                    raise
                except Exception as failure:  # noqa: BLE001 - curated, audited reply
                    return self.failure(request, action, mutating, state, failure)
            # The action runs as its own task: a slow one outlives this request (and a client that
            # went away) and finishes, audited, whatever happens to the connection (SC-041).
            return await self.settle(request, self.spawn(run()))
        return handle

    def failure(self, request, action, mutating, state, failure):
        if isinstance(failure, AdminError):
            error = failure
        elif isinstance(failure, Rejection):
            error = AdminError(400, "invalid", str(failure))
        else:
            # Every admin request is audited, unexpected failures included (decision #103).
            error = AdminError(500, "error", UNEXPECTED)
        request["anj.reason"] = error.reason
        if mutating and error.reason != "confirmation-required":
            actor = request.get("anj.admin.actor")
            context = state["context"] or (Context(actor[0], actor[1], request) if actor else None)
            self.record(context, action, state["targets"], error.reason)
        response = error.response()
        response["anj.reason"] = error.reason          # for the poll that returns it (request log)
        return response

    # Long actions (SC-041 F1) ----------------------------------------------------------------

    def spawn(self, coroutine):
        task = asyncio.ensure_future(coroutine)
        self.operation_tasks.add(task)

        def finished(task):
            self.operation_tasks.discard(task)
            if not task.cancelled():
                task.exception()               # retrieved: an unfetched result never logs a trace
        task.add_done_callback(finished)
        return task

    async def settle(self, request, task, operation=None):
        """The action's own response when it is done within OPERATION_HOLD; otherwise 202 with an
        operation id the same device polls. Every admin request is so answered well inside the
        production ingress's 120 s idle limit (deploy/prod/haproxy.cfg.tmpl), which cannot see the
        path (TLS passthrough) and so cannot give admin routes a longer one."""
        done, _ = await asyncio.wait({task}, timeout=self.operation_hold)
        if done:
            response = task.result()           # an HTTPException is raised here, as by the route
            if operation is None:
                return response
            # The poll that collects it: a copy, so a poll whose reply was lost can collect again
            # until the result is forgotten.
            if response.get("anj.reason"):
                request["anj.reason"] = response["anj.reason"]
            return web.Response(body=response.body, status=response.status,
                                headers={key: value for key, value in response.headers.items()
                                         if key.lower() != "content-length"})
        if operation is None:
            self.forget_operations()
            device = (request.get("anj.admin.actor") or (None, None))[1]
            operation = secrets.token_hex(16)
            self.operations[operation] = {"task": task, "device": device, "done": None}
            task.add_done_callback(lambda _task, key=operation: self.operation_done(key))
        return web.json_response({"operation": operation, "state": "running", "message": STILL_WORKING}, status=202,
                                 headers=NO_STORE)

    def operation_done(self, operation):
        row = self.operations.get(operation)
        if row is not None:
            row["done"] = self.monotonic()

    def forget_operations(self):
        """A finished result nobody fetched within OPERATION_KEEP is dropped (its action was
        audited when it finished); a running one is always kept."""
        now = self.monotonic()
        for key in [key for key, row in self.operations.items()
                    if row["done"] is not None and now - row["done"] > OPERATION_KEEP]:
            del self.operations[key]

    async def operation(self, request):
        """GET /v1/admin/operations/{id}: the result of this device's own long action."""
        try:
            context = self.authorize(request, False)
            if request.query_string:
                raise AdminError(400, "invalid", "Queries are unsupported")
            key = request.match_info["operation"]
            self.forget_operations()
            row = self.operations.get(key) if OPERATION_ID.fullmatch(key) else None
            if row is None or row["device"] != context.device:
                raise AdminError(404, "operation-unknown", OPERATION_UNKNOWN)
        except web.HTTPException:
            raise
        except AdminError as error:
            request["anj.reason"] = error.reason
            return error.response()
        return await self.settle(request, row["task"], key)

    def authorize(self, request, write):
        try:
            device = self.gateway.identity(request)
        except web.HTTPForbidden:
            if request.get("anj.reason") == "account-disabled":
                raise AdminError(403, "account-disabled", "Your account is disabled.") from None
            raise
        request["anj.admin.actor"] = (device["uid"], device["id"])
        window = self.requests.setdefault(device["id"], deque())
        now = self.monotonic()
        while window and window[0] <= now - ADMIN_WINDOW:
            window.popleft()
        if len(window) >= ADMIN_RATE:
            raise AdminError(429, "rate-limited", "Too many admin requests; wait a minute.")
        window.append(now)
        role = self.registry.role(device["uid"])
        if role is None or not role["admin"]:
            raise AdminError(403, "not-admin", "Your admin role was removed.")
        if not role["enabled"]:
            raise AdminError(403, "account-disabled", "Your account is disabled.")
        if write and device["rights"] != "write":
            raise AdminError(403, "read-grant", "This device can only view; use a device with full access to make changes.")
        return Context(device["uid"], device["id"], request, device["rights"])

    @staticmethod
    async def body(request):
        if not request.can_read_body:
            return {}
        try:
            body = await request.json()
        except ValueError:
            raise AdminError(400, "invalid", "A JSON object is required") from None
        if not isinstance(body, dict):
            raise AdminError(400, "invalid", "A JSON object is required")
        return body

    @staticmethod
    def fields(body, allowed):
        extra = set(body) - set(allowed) - {"expect", "confirm", "typed"}
        if extra:
            raise AdminError(400, "invalid", "Unexpected field: " + ", ".join(sorted(extra)))

    def record(self, context, action, targets, result):
        try:
            self.registry.audit(action, result, actor_uid=RECOVERY_ACTOR if context is not None and context.cli else (context.uid if context else None),
                                actor_device=context.device if context else None, target_uid=targets.get("uid"),
                                target_device=targets.get("device"), target_invitation=targets.get("invitation"))
        except Exception:  # noqa: BLE001 - the audit write never turns a completed action into an error
            pass

    # Shared rules ----------------------------------------------------------------------------

    @staticmethod
    def expect(context, body, current):
        """The target revision the caller was shown; required over HTTPS, optional for the CLI."""
        shown = body.get("expect")
        if shown is None and context.cli:
            return
        if shown != current:
            raise AdminError(409, "stale", "This changed since it was shown; the list has been refreshed.", revision=current)

    def confirm(self, context, body, action, target, current, title, effect, typed=None, params=None):
        """Server-issued confirmation (spec #27 Confirmations). The CLI confirms on its own side."""
        if context.cli:
            return
        token = body.get("confirm")
        binding = (context.device, action, target, current, json.dumps(params, sort_keys=True))
        now = self.monotonic()
        for key in [key for key, row in self.confirmations.items() if row["expires"] <= now]:
            del self.confirmations[key]
        if token is None:
            token = secrets.token_urlsafe(24)
            self.confirmations[token] = {"binding": binding, "expires": now + CONFIRM_SECONDS, "typed": typed}
            raise AdminError(428, "confirmation-required", title, title=title, effect=effect, confirm_token=token,
                             second_factor_typed=typed)
        row = self.confirmations.pop(token, None) if isinstance(token, str) else None
        if row is None or row["binding"] != binding:
            raise AdminError(409, "confirmation-invalid", "This confirmation is no longer valid; try again.")
        if row["typed"] is not None and not (isinstance(body.get("typed"), str) and hmac.compare_digest(body["typed"], row["typed"])):
            raise AdminError(409, "confirmation-invalid", "The typed account id did not match; nothing was changed.")

    def require_role(self, uid):
        role = self.registry.role(uid) if isinstance(uid, str) else None
        if role is None:
            raise AdminError(404, "not-found", "No such user")
        return role

    @staticmethod
    def account_revision(role):
        return revision(role["uid"], role["display_name"], role["enabled"], role["admin"])

    def last_admin(self, uid):
        role = self.registry.role(uid)
        return bool(role and role["enabled"] and role["admin"] and self.registry.enabled_admins() == [uid])

    # Users -----------------------------------------------------------------------------------

    async def users(self, context, match, body, targets):
        counts = {}
        for device in self.registry.public_devices():
            if device["state"] == "active":
                counts[device["uid"]] = counts.get(device["uid"], 0) + 1
        users = [{**role, "active_devices": counts.get(role["uid"], 0), "revision": self.account_revision(role)}
                 for role in self.registry.roles()]
        # A server account whose household step did not finish stays visible until it is (#43).
        users += [{"uid": row["uid"], "display_name": row["display_name"], "enabled": False, "admin": False, "active_devices": 0,
                   "setup_incomplete": True, "revision": revision(row["uid"], "setup-incomplete")}
                  for row in self.registry.pending_accounts()]
        return {"users": users}

    async def user_add(self, context, match, body, targets):
        """New accounts only (decision #103). The one uid and display-name rule is checked here,
        before the backend creates anything, so no account is ever half-made by a bad value."""
        self.fields(body, ("uid", "display_name"))
        uid = body.get("uid")
        if not valid_new_uid(uid):
            raise AdminError(400, "invalid", NEW_UID_TEXT + ".")
        targets["uid"] = uid
        if uid in RESERVED_UIDS:
            raise AdminError(409, "reserved", "%s is reserved by the server; choose another user id." % uid)
        name = clean_display_name(body.get("display_name"))
        if name is None:
            raise AdminError(400, "invalid", NAME_TEXT + ".")
        if self.registry.role(uid):
            raise AdminError(409, "exists", "%s is already a household user." % uid)
        # SC-041: "Setup incomplete" is recorded BEFORE the backend creates anything, so a call
        # that is cut, times out or never answers leaves a row the admin sees in Users and can
        # finish (add again), never a server account nobody knows of. It is cleared only when the
        # backend certainly created nothing. Adding again sends `resume`; the backend still
        # refuses a server account this tooling did not create.
        resume = self.registry.account_cleanup_pending(uid)
        if not resume:
            self.registry.account_cleanup_add(uid, name)
        try:
            result = await self.backend.call("user-add", uid=uid, display_name=name, **({"resume": True} if resume else {}))
        except AdminError as error:
            if (not resume and (isinstance(error, BackendUnreachable) or error.reason in NOTHING_CREATED)) or \
                    (resume and error.reason == "exists"):
                # Nothing was created; or, on finishing, the server account is one this tooling
                # never made (the backend refuses to adopt it): the row was wrong, never finishable.
                self.registry.account_cleanup_done(uid)
            raise
        try:
            self.registry.account_set(uid, name, True)
        except Exception:  # noqa: BLE001 - recorded for cleanup, audited, then reported plainly
            self.registry.account_cleanup_add(uid, name)
            raise AdminError(503, "account-pending", "The server account %s was created but not added to the household. "
                             "Add the user again to finish." % uid) from None
        self.registry.account_cleanup_done(uid)
        return {"uid": uid, "state": "finished" if resume else result.get("state", "created")}

    async def user_enabled(self, context, match, body, targets):
        self.fields(body, ("enabled",))
        role = self.require_role(match["uid"])
        targets["uid"] = role["uid"]
        enabled = body.get("enabled")
        if not isinstance(enabled, bool):
            raise AdminError(400, "invalid", "enabled must be true or false")
        current = self.account_revision(role)
        self.expect(context, body, current)
        name = role["display_name"]
        if enabled:
            # Nextcloud first, then the gateway admits the devices again (no re-pairing, #79 (b)).
            await self.backend.call("nextcloud-enabled", uid=role["uid"], enabled=True)
            self.registry.set_account_flags(role["uid"], enabled=True)
            return {"uid": role["uid"], "enabled": True}
        if self.last_admin(role["uid"]):
            raise AdminError(409, "last-admin", LAST_ADMIN_TEXT)
        self.confirm(context, body, "user-disable", role["uid"], current, "Disable %s?" % name,
                     "%s's devices stop syncing and folders %s shares become unavailable to others until you enable %s "
                     "again. Nothing is deleted." % (name, name, role["uid"]))
        if role["enabled"] and not self.registry.active_devices(role["uid"]):
            # No device to read the owner's share list through: the backend runs the operator
            # CLI's disable with a temporary owner token (decision #101). It records mounts,
            # flips the account (last-admin rule) and disables the Nextcloud account.
            await self.backend.call("account-disable", uid=role["uid"])
            self.alert(context, "user-disable", role["uid"])
            return {"uid": role["uid"], "enabled": False}
        if role["enabled"]:
            # Recipients' mounts are recorded from the owner's own share list while Nextcloud still
            # lists them (#80 (2), #42), read through one of the owner's devices. If that read
            # fails the disable is refused before anything changes and the admin sees #42's text.
            # As #44's operator account-set: the single mutation lock is held from reading the
            # owner's share list to the registry flip, so no share created in between goes
            # unrecorded. The read goes to Nextcloud, never to the console backend (no inversion).
            async with self.gateway.mutations.lock:
                try:
                    complete = await self.gateway.sharing.remember_before_disable(role["uid"])
                except Exception:  # noqa: BLE001 - any failure to record refuses the disable
                    complete = False
                if not complete:
                    raise AdminError(503, "share-mounts-unrecorded", MOUNTS_UNRECORDED)
                try:
                    self.registry.set_account_flags(role["uid"], enabled=False)
                except LastAdmin:
                    raise AdminError(409, "last-admin", LAST_ADMIN_TEXT) from None
            devices = [device["id"] for device in self.registry.active_devices(role["uid"])]
            if context.request is not None and context.device in devices:
                # An admin disabling their own account still receives this reply; the device is
                # refused from its next request.
                self.gateway.transports[context.device].discard(context.request.transport)
            await self.gateway.abort_devices(devices)
        try:
            await self.backend.call("nextcloud-enabled", uid=role["uid"], enabled=False)
        except AdminError as error:
            raise AdminError(error.status, error.reason, "%s's devices are refused now, but the Nextcloud account is not "
                             "disabled yet: %s Disable again to finish." % (name, error.message)) from None
        self.alert(context, "user-disable", role["uid"])
        return {"uid": role["uid"], "enabled": False}

    async def user_admin(self, context, match, body, targets):
        self.fields(body, ("admin",))
        role = self.require_role(match["uid"])
        targets["uid"] = role["uid"]
        grant = body.get("admin")
        if not isinstance(grant, bool):
            raise AdminError(400, "invalid", "admin must be true or false")
        current = self.account_revision(role)
        self.expect(context, body, current)
        if grant == role["admin"]:
            raise AdminError(409, "stale", "%s %s an admin already." % (role["uid"], "is" if grant else "is not"), revision=current)
        if not grant and self.last_admin(role["uid"]):
            raise AdminError(409, "last-admin", LAST_ADMIN_TEXT)
        name = role["display_name"]
        if grant:
            self.confirm(context, body, "admin-grant", role["uid"], current, "Make %s an admin?" % name,
                         "%s can then add and disable users, approve and revoke devices and change server settings." % name)
        else:
            self.confirm(context, body, "admin-remove", role["uid"], current, "Remove %s's admin role?" % name,
                         "%s can no longer open Admin. Their devices keep syncing." % name)
        async with self.gateway.mutations.lock:
            try:
                updated = self.registry.set_account_flags(role["uid"], admin=grant)
            except LastAdmin:
                raise AdminError(409, "last-admin", LAST_ADMIN_TEXT) from None
        self.alert(context, "role-grant" if grant else "role-remove", role["uid"])
        return {"uid": updated["uid"], "admin": updated["admin"]}

    # Devices ---------------------------------------------------------------------------------

    @staticmethod
    def device_revision(device):
        return revision(device["id"], device["uid"], device["state"], device["rights"], device.get("certificate_id"))

    def device_row(self, device_id):
        row = next((row for row in self.registry.public_devices() if row["id"] == device_id), None) \
            if isinstance(device_id, str) and IDENTIFIER.fullmatch(device_id) else None
        if row is None:
            raise AdminError(404, "not-found", "No such device")
        return row

    async def devices(self, context, match, body, targets):
        names = {role["uid"]: role["display_name"] for role in self.registry.roles()}
        rows = []
        for row in self.registry.public_devices():
            if row["state"] not in ("active", "revoked"):
                continue
            # The device's reported computer name and short key fingerprint, as its pairing alert
            # names them (spec #35), so an alert can be matched to the device to revoke.
            rows.append({"id": row["id"], "uid": row["uid"], "display_name": names.get(row["uid"], row["uid"]), "label": row.get("label"),
                         "computer_name": clean_device_name(row["device_label"]) if row.get("device_label") else None,
                         "fingerprint_short": (row.get("fingerprint") or "")[:8] or None,
                         "grant": row["rights"], "state": row["state"], "last_seen": iso(row.get("last_seen")),
                         "certificate_expires": iso(row.get("expires")), "transition_leaves": row.get("transition_leaves", 0),
                         "this_device": row["id"] == context.device, "revision": self.device_revision(row)})
        order = {"active": 0, "revoked": 1}
        rows.sort(key=lambda row: (row["display_name"].lower(), row["uid"], order[row["state"]], row["label"] or "", row["id"]))
        return {"devices": rows}

    def device_name(self, row):
        return row.get("label") or "device " + row["id"][:8]

    async def device_revoke(self, context, match, body, targets):
        self.fields(body, ())
        row = self.device_row(match["device_id"])
        targets.update(uid=row["uid"], device=row["id"])
        current = self.device_revision(row)
        self.expect(context, body, current)
        if row["state"] != "active":
            raise AdminError(409, "stale", "This device is already revoked.", revision=current)
        name, own = self.device_name(row), row["id"] == context.device
        last = self.last_admin(row["uid"]) and [device["id"] for device in self.registry.active_devices(row["uid"])] == [row["id"]]
        effect = "This device stops syncing at once and must be paired again to return."
        if own:
            effect += " This is the device you are using; Admin closes on it at once."
        if last:
            effect += " It is the last device of the last admin. " + RECOVERY
        self.confirm(context, body, "device-revoke", row["id"], current, "Revoke %s (%s)?" % (name, row["uid"]), effect,
                     typed=row["uid"] if (own or last) else None)
        device = self.registry.disable(row["id"])
        if own and context.request is not None:
            self.gateway.transports[row["id"]].discard(context.request.transport)
        # The acting device's own admin request completes; it is refused from its next request.
        await self.gateway.abort_devices([row["id"]])
        cleanup = await self.cleanup_token(device)
        self.alert(context, "device-revoke", row["uid"], row["id"])
        return {"device_id": row["id"], "state": "revoked", "token_cleanup": cleanup,
                "_audit": "ok" if cleanup == "done" else "token-cleanup-pending"}

    def alert(self, context, event, target_uid, device_id=None):
        """One ntfy message per role change, disable or revoke (spec #27 Audit 5, decision #101),
        sent by the backend after the change. It never delays, fails or rolls back the action;
        a failed alert is recorded in the audit."""
        actor = RECOVERY_ACTOR if context.cli else context.uid

        async def send():
            try:
                await self.backend.call("admin-alert", event=event, actor_uid=actor, target_uid=target_uid,
                                        **({"device_id": device_id} if device_id else {}))
            except AdminError as error:
                self.registry.audit("admin-alert", "alert-failed:" + error.reason, actor_uid=actor,
                                    target_uid=target_uid, target_device=device_id)
            except Exception:  # noqa: BLE001 - never surfaces into the admin action
                self.registry.audit("admin-alert", "alert-failed", actor_uid=actor, target_uid=target_uid, target_device=device_id)

        task = asyncio.get_running_loop().create_task(send())
        self.alert_tasks.add(task)
        task.add_done_callback(self.alert_tasks.discard)

    async def pairing_alert(self, kind, row):
        """Spec #35 rule 4 and its review (operator 2026-11-05): a device paired by a pinned code ("paired":
        "anj-cloud: new device 'laptop' (fp 6150cf05) for sam"), or another device trying a code one
        already holds ("reused"). Each names the computer name that device reported at enroll
        (naming.clean_device_name: printable ASCII, at most 40 characters, never the admin's label) and the first 8 hex of
        its key's SHA-256. Raises unless the backend confirmed it; the gateway retries until it does."""
        paired = kind == "paired"
        label, fingerprint = (row.get("device_label"), row.get("fingerprint")) if paired else \
            (row.get("reuse_label"), row.get("reuse_fingerprint"))

        async def send(name):
            return await self.backend.call("admin-alert", event="device-paired" if paired else "code-reused",
                                           actor_uid=SYSTEM_ACTOR, target_uid=row["uid"],
                                           **({"device_id": row["device"]} if paired else {}),
                                           label=name, fingerprint=str(fingerprint or "")[:8])
        name = clean_device_name(label)
        try:
            return await send(name)
        except AdminError as error:
            # A backend that still refuses the name (an older release) must not suppress the alert:
            # once more without it (PR #92 review H1).
            if error.reason != "backend-refused" or name == UNNAMED:
                raise
            return await send(UNNAMED)

    async def cleanup_token(self, device):
        """Remove the revoked device's app token through the backend; retry until confirmed."""
        if not device.get("token_id"):
            return "done"
        try:
            await self.backend.call("token-cleanup", uid=device["uid"], token_id=str(device["token_id"]))
            return "done"
        except AdminError:
            self.registry.token_cleanup_add(device["id"], device["uid"], device["token_id"])
            self.schedule_cleanup()
            return "pending"

    def schedule_cleanup(self):
        if self.cleanup_task is None or self.cleanup_task.done():
            self.cleanup_task = asyncio.get_running_loop().create_task(self.retry_cleanups())

    async def retry_cleanups(self, interval=CLEANUP_RETRY_SECONDS):
        while self.registry.token_cleanups():
            await asyncio.sleep(interval)
            for row in self.registry.token_cleanups():
                try:
                    await self.backend.call("token-cleanup", uid=row["uid"], token_id=row["token_id"])
                except AdminError:
                    self.registry.token_cleanup_add(row["device"], row["uid"], row["token_id"])
                    continue
                self.registry.token_cleanup_done(row["device"])
                self.registry.audit("token-cleanup", "ok", actor_uid="system", target_uid=row["uid"], target_device=row["device"])

    async def device_reissue(self, context, match, body, targets):
        self.fields(body, ())
        row = self.device_row(match["device_id"])
        targets.update(uid=row["uid"], device=row["id"])
        current = self.device_revision(row)
        self.expect(context, body, current)
        if row["state"] != "active" or not row.get("expires") or row["expires"] <= self.clock():
            raise AdminError(409, "stale", "Only an active device with a valid certificate can be reissued; others pair again.",
                             revision=current)
        self.confirm(context, body, "device-reissue", row["id"], current, "Reissue %s's certificate?" % self.device_name(row),
                     "The device gets a new certificate for the same key, valid until the issuer expires. It keeps its "
                     "current one until it picks the new one up.")
        result = await self.backend.call("reissue", device_id=row["id"])
        return {"device_id": row["id"], "state": result.get("state"), "expires_at": iso(result.get("expires_at"))}

    # Invitations -----------------------------------------------------------------------------

    @staticmethod
    def invitation_revision(row):
        return revision(row["id"], row["state"], row["expires"], row.get("fingerprint"))

    def invitation_row(self, identity):
        try:
            if not isinstance(identity, str) or not IDENTIFIER.fullmatch(identity):
                raise Rejection("Unknown pairing")
            return self.registry.invitation(identity)
        except Rejection:
            raise AdminError(404, "not-found", "No such invitation") from None

    async def invitations(self, context, match, body, targets):
        now = self.clock()
        pending, codes = [], []
        for row in self.registry.pending():
            if row["expires"] <= now:
                continue
            # Never the code, the CSR or the fingerprint: the admin types it from the new device.
            item = {"id": row["id"], "uid": row["uid"], "grant": row["rights"], "label": row.get("label"),
                    "expires_at": iso(row["expires"]), "revision": self.invitation_revision(row)}
            if row["state"] in ("reserved", "provisioning"):
                pending.append(item)
            elif row["state"] == "issued":
                codes.append(item)
        return {"pending": pending, "codes": codes}

    async def invitation_create(self, context, match, body, targets):
        self.fields(body, ("uid", "grant", "label"))
        role = self.require_role(body.get("uid"))
        targets["uid"] = role["uid"]
        if not role["enabled"]:
            raise AdminError(409, "account-disabled", "%s is disabled; enable them first." % role["uid"])
        if body.get("grant") not in ("read", "write"):
            raise AdminError(400, "invalid", "grant must be read or write")
        label = body.get("label") or None
        try:
            row = self.registry.invite(role["uid"], body["grant"], label, ca_pin=self.gateway.ca_pin)
        except Rejection as error:
            raise AdminError(400, "invalid", str(error)) from None
        targets["invitation"] = row["id"]
        if context.cli or role["uid"] != context.uid:
            self.alert(context, "device-invite-other", role["uid"])
        return {"id": row["id"], "uid": row["uid"], "grant": row["rights"], "label": label, "code": row["code"],
                "expires_at": iso(row["expires"]),
                "warning": "Share this code only with the person setting up the device; it works once."}

    async def invitation_approve(self, context, match, body, targets):
        self.fields(body, ("fingerprint",))
        row = self.invitation_row(match["invitation_id"])
        targets.update(uid=row["uid"], invitation=row["id"], device=row.get("device"))
        current = self.invitation_revision(row)
        self.expect(context, body, current)
        fingerprint = body.get("fingerprint")
        if not isinstance(fingerprint, str) or not FINGERPRINT.fullmatch(fingerprint):
            raise AdminError(400, "invalid", "Type the full 64-character fingerprint shown on the new device.")
        if row["state"] not in ("reserved", "provisioning") or row["expires"] <= self.clock():
            raise AdminError(409, "stale", "This enrollment is no longer waiting for approval.", revision=current)
        if not row.get("fingerprint") or not hmac.compare_digest(fingerprint, row["fingerprint"]):
            raise AdminError(409, "fingerprint-mismatch", "The fingerprint does not match the new device; nothing was approved.")
        result = await self.backend.call("approve", pairing_id=row["id"], fingerprint=fingerprint)
        if row.get("pinned"):
            # A pinned code (spec #35): whichever approval finished first, the device gets the one
            # new-device audit entry and its at-least-once alert, never a second alert (review L1).
            self.gateway.announce(row["id"])
        elif context.cli or row["uid"] != context.uid:
            self.alert(context, "device-approve-other", row["uid"], result.get("device_id") or row.get("device"))
        return {"invitation_id": row["id"], "device_id": result.get("device_id"), "state": result.get("state", "active")}

    async def invitation_deny(self, context, match, body, targets):
        self.fields(body, ())
        row = self.invitation_row(match["invitation_id"])
        targets.update(uid=row["uid"], invitation=row["id"])
        current = self.invitation_revision(row)
        self.expect(context, body, current)
        if row["state"] not in ("issued", "reserved", "provisioning") or row["expires"] <= self.clock():
            raise AdminError(409, "stale", "This invitation is no longer open.", revision=current)
        code = row["state"] == "issued"
        label = row.get("label") or ("this code" if code else "this device")
        self.confirm(context, body, "invitation-deny", row["id"], current,
                     ("Cancel %s for %s?" if code else "Deny %s for %s?") % (label, row["uid"]),
                     "The code stops working." if code else "The device is refused and must be invited again to pair.")
        self.registry.deny(row["id"])
        return {"invitation_id": row["id"], "state": "denied"}

    # Settings, health, alerts, audit ---------------------------------------------------------

    def limit_view(self):
        limit = self.gateway.mutations.limit
        return {"upload_limit_bytes": limit, "upload_limit_mib": limit // MIB if limit % MIB == 0 else round(limit / MIB, 2),
                "min_mib": UPLOAD_LIMIT_MIN // MIB, "max_mib": UPLOAD_LIMIT_MAX // MIB, "revision": revision(limit)}

    async def settings(self, context, match, body, targets):
        return self.limit_view()

    async def settings_change(self, context, match, body, targets):
        self.fields(body, ("upload_limit_mib",))
        view = self.limit_view()
        self.expect(context, body, view["revision"])
        mib = body.get("upload_limit_mib")
        if type(mib) is not int or mib < view["min_mib"]:
            raise AdminError(400, "invalid", "Choose a whole number of MiB from 1 to 64.")
        if mib > view["max_mib"]:
            raise AdminError(400, "invalid", "Above 64 MiB needs large-transfer support (Feature #6).")
        if mib * MIB == view["upload_limit_bytes"]:
            raise AdminError(409, "stale", "The upload limit is already %d MiB." % mib, revision=view["revision"])
        self.confirm(context, body, "settings-change", "upload-limit", view["revision"], "Change the upload limit to %d MiB?" % mib,
                     "Each upload may be at most %d MiB (now %s MiB). Uploads already in progress finish; devices learn the new "
                     "limit on their next request." % (mib, view["upload_limit_mib"]), params={"mib": mib})
        async with self.gateway.mutations.lock:
            self.gateway.mutations.set_limit(mib * MIB)
        return self.limit_view()

    async def health(self, context, match, body, targets):
        guard = getattr(self.gateway, "guard", None)
        cutoff = time.time() - 86400
        blocks = sum(1 for start in getattr(guard, "history", ()) if start >= cutoff)
        gateway = {"ready": await self.gateway.backend_ready(), "write_fence": self.gateway.fence_summary(),
                   "share_fences": len(self.registry.share_fences()), "upload_limit_bytes": self.gateway.mutations.limit,
                   "enroll_blocks_24h": blocks, "token_cleanup_pending": len(self.registry.token_cleanups())}
        try:
            server = await self.backend.call("health")
        except AdminError as error:
            server = {"state": "unavailable", "message": error.message}
        return {"gateway": gateway, "server": server, "checked_at": iso(time.time())}

    async def test_alert(self, context, match, body, targets):
        self.fields(body, ())
        result = await self.backend.call("test-alert")
        return {"state": result.get("state", "sent")}

    async def audit_list(self, context, match, body, targets):
        query = context.request.query if context.request is not None else {}
        if set(query) - {"after", "limit"}:
            raise AdminError(400, "invalid", "Unsupported audit query")
        after, limit = query.get("after"), query.get("limit", "100")
        if (after is not None and not re.fullmatch(r"[0-9]{1,19}", after)) or not re.fullmatch(r"[0-9]{1,3}", limit):
            raise AdminError(400, "invalid", "Invalid audit cursor")
        rows, cursor = self.registry.audit_page(int(after) if after else None, int(limit))
        return {"entries": [{"seq": row["seq"], "time": iso(row["time"]), "actor_uid": row["actor_uid"], "actor_device": row["actor_device"],
                             "action": row["action"], "target_uid": row["target_uid"], "target_device": row["target_device"],
                             "target_invitation": row["target_invitation"], "result": row["result"]} for row in rows],
                "after": cursor}

    # Recovery CLI over the operator socket ---------------------------------------------------

    OPERATOR_OPS = {
        "users": ("users", False), "user-add": ("user-add", True), "user-enabled": ("user-enabled", True),
        "user-admin": ("user-admin", True), "devices": ("devices", False), "revoke": ("device-revoke", True),
        "reissue": ("device-reissue", True), "invitations": ("invitations", False), "invite": ("invitation-create", True),
        "approve": ("invitation-approve", True), "deny": ("invitation-deny", True), "health": ("health", False),
        "audit": ("audit", False),
    }

    async def operator(self, body):
        """The operator socket's `admin` action: same rules and audit, actor `recovery-cli`."""
        op = body.get("op")
        if op == "audit-import":
            return self.import_audit(body.get("entries"))
        if op == "accounts-import":
            return self.import_accounts(body.get("accounts"), body.get("admins"))
        if op not in self.OPERATOR_OPS:
            raise Rejection("Unsupported admin operation")
        action, mutating = self.OPERATOR_OPS[op]
        functions = {"users": self.users, "user-add": self.user_add, "user-enabled": self.user_enabled, "user-admin": self.user_admin,
                     "devices": self.devices, "device-revoke": self.device_revoke, "device-reissue": self.device_reissue,
                     "invitations": self.invitations, "invitation-create": self.invitation_create,
                     "invitation-approve": self.invitation_approve, "invitation-deny": self.invitation_deny, "health": self.health,
                     "audit": self.audit_list}
        context, targets = Context(RECOVERY_ACTOR), {}
        match = {key: body.pop(key) for key in ("uid", "device_id", "invitation_id") if key in body and op not in ("user-add", "invite")}
        data = {key: value for key, value in body.items() if key not in ("action", "op")}
        try:
            result = await functions[action](context, match, data, targets)
        except AdminError as error:
            if mutating:
                self.record(context, action, targets, error.reason)
            raise Rejection(error.reason + ": " + error.message) from None
        except Rejection as error:
            if mutating:
                self.record(context, action, targets, "invalid")
            raise Rejection("invalid: " + str(error)) from None
        except Exception:  # noqa: BLE001 - audited, curated
            if mutating:
                self.record(context, action, targets, "error")
            raise Rejection("error: " + UNEXPECTED) from None
        if mutating:
            self.record(context, action, targets, result.pop("_audit", "ok") if isinstance(result, dict) else "ok")
        return result

    def import_audit(self, entries):
        """Recovery CLI entries written while the gateway was down (spec #27 Audit 4). Each entry
        is imported once by its id; an invalid entry is returned by index for quarantine and
        never blocks the others."""
        if not isinstance(entries, list) or len(entries) > 1000:
            raise Rejection("Invalid audit import")
        allowed = {"id", "time", "action", "target_uid", "target_device", "target_invitation", "result"}
        imported, skipped, rejected = 0, 0, []
        for index, entry in enumerate(entries):
            if (not isinstance(entry, dict) or set(entry) - allowed or not isinstance(entry.get("id"), str)
                    or not re.fullmatch(r"[0-9a-f]{16,64}", entry["id"])
                    or not isinstance(entry.get("action"), str) or not re.fullmatch(r"[a-z-]{1,64}", entry["action"])
                    or not isinstance(entry.get("result"), str) or not re.fullmatch(r"[a-z:-]{1,64}", entry["result"])
                    or type(entry.get("time")) not in (int, float)
                    or any(entry.get(key) is not None and not re.fullmatch(r"[a-z0-9-]{1,64}", str(entry[key]))
                           for key in ("target_uid", "target_device", "target_invitation"))):
                rejected.append(index)
                continue
            if self.registry.audit_import_entry(entry["id"], entry["action"], entry["result"], time=entry["time"],
                                                target_uid=entry.get("target_uid"), target_device=entry.get("target_device"),
                                                target_invitation=entry.get("target_invitation")):
                imported += 1
            else:
                skipped += 1
        return {"imported": imported, "skipped": skipped, "rejected": rejected}

    def import_accounts(self, accounts, admins):
        if not isinstance(accounts, list) or not isinstance(admins, list) or not all(isinstance(uid, str) for uid in admins):
            raise Rejection("Invalid accounts import")
        return self.registry.import_first_admins([row for row in accounts if isinstance(row, dict)], admins)
