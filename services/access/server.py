"""One TLS gateway and one private operator socket; Nextcloud stays internal."""

import asyncio
from collections import defaultdict
from datetime import datetime, timezone
import json
import logging
import os
from pathlib import Path
import re
import signal
import ssl
import time
from urllib.parse import urlencode, unquote

from aiohttp import BasicAuth, ClientSession, ClientTimeout, DummyCookieJar, web
from aiohttp.abc import AbstractAccessLogger
from cryptography import x509
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.x509.oid import ExtendedKeyUsageOID
from defusedxml import ElementTree as SafeET

from .protocol import (MAX_XML, METHODS, READ_METHODS, UPLOAD_LIMIT_HEADER, UPLOAD_LIMIT_MAX, UPLOAD_LIMIT_MIN, Rejection, backend_root, ca_pin, canonical_path,
                       encode_filename_path, gateway_reference, key_fingerprint, move_destination, rewrite_multistatus)
from .registry import AccountDisabled, CodeReused, Registry
from .mutations import Mutations, name_refusal, split_leaf
from . import portable_names
from .edge import KEEPALIVE_TIMEOUT, Edge, peer_source
from .observe import EnrollmentGuard, Events
from .sharing import OPERATOR_RIGHTS, ShareError, Sharing, owner_of
from .console import Console
from .releases import Releases

REQUEST_HEADERS = {"content-type", "content-length", "if-match", "if-none-match", "if-modified-since",
                   "if-unmodified-since", "range", "if-range", "depth", "overwrite"}
RESPONSE_HEADERS = {"content-type", "etag", "last-modified", "content-range", "accept-ranges", "dav", "allow"}
# ECDHE key exchange with AEAD ciphers only for TLS 1.2; TLS 1.3 suites are all AEAD (S2).
TLS12_CIPHERS = "ECDHE+AESGCM:ECDHE+CHACHA20"
LISTENERS = ("tcp", "proxy-unix")
# An unauthenticated enrollment body must arrive within this many seconds of the headers.
ENROLL_BODY_TIMEOUT = 10.0
# Routes answering without a device certificate (S9); everything else requires one.
UNAUTHENTICATED_ROUTES = {("GET", "/health"), ("HEAD", "/health"), ("GET", "/v1/ca"), ("HEAD", "/v1/ca"),
                          ("POST", "/v1/enroll"), ("POST", "/v1/enroll/status")}
# Code-only pairing (decision #151, spec #35): how long one enroll exchange waits for the automatic
# approval before it answers `pending` (the device then asks /v1/enroll/status, which waits again).
# Well inside the production ingress's 120 s idle limit and the client's 45 s response timeout.
APPROVAL_HOLD = 20.0
# After an automatic approval failed, the next status request starts another only this much later:
# each attempt mints and removes a Nextcloud app token, so a failing backend is not hammered.
APPROVAL_RETRY = 15.0
# Pairing alerts are at least once (spec #35 review M1): a due alert the backend did not confirm is
# sent again by a pass this often, also after a restart and when no device asks any more.
ALERT_PASS_SECONDS = 60.0


def drop_server_header():
    """Remove `Server` from every response, including aiohttp's own parser errors (S1).

    aiohttp sets `Server` in `_prepare_headers`; the signal hook runs only for routed requests,
    so the removal is applied where the default is set. Pinned aiohttp 3.14.5; a test asserts
    the header is absent on routed, unrouted and malformed-request responses.
    """
    if getattr(web.StreamResponse._prepare_headers, "_anj_no_server", False):
        return
    original = web.StreamResponse._prepare_headers

    async def prepare_headers(self):
        await original(self)
        self._headers.popall("Server", None)

    prepare_headers._anj_no_server = True
    web.StreamResponse._prepare_headers = prepare_headers


def tls_context(certificate, key, issuer):
    context = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.set_ciphers(TLS12_CIPHERS)
    context.options |= getattr(ssl, "OP_NO_RENEGOTIATION", 0)
    context.load_cert_chain(str(certificate), str(key))
    context.load_verify_locations(str(issuer))
    context.verify_mode = ssl.CERT_OPTIONAL
    return context
NO_STORE = {"Cache-Control": "no-store"}
SHARING_INTENTS = {"share", "share-update", "unshare", "leave", "share-rename"}


class Gateway:
    def __init__(self, state, backend, origin, issuer, *, clock=time.time, events=None, guard=None):
        self.registry = Registry(state, clock=clock)
        self.backend = backend.rstrip("/")
        self.origin = origin.rstrip("/")
        self.issuer = x509.load_pem_x509_certificate(Path(issuer).read_bytes())
        # The public issuer certificate only (GET /v1/ca) and the pin every new code carries.
        self.issuer_pem = self.issuer.public_bytes(serialization.Encoding.PEM)
        self.ca_pin = ca_pin(self.issuer)
        self.approvals, self.approval_failed = {}, {}
        self.approval_hold, self.approval_retry = APPROVAL_HOLD, APPROVAL_RETRY
        self.alerts_sending, self.alert_pass_task, self.alert_failures = {}, None, set()
        self.active = defaultdict(set)
        self.transports = defaultdict(set)
        self.events = events if events is not None else Events()
        self.guard = guard if guard is not None else EnrollmentGuard(self.events)
        self.edge = None
        self.body_timeout = ENROLL_BODY_TIMEOUT
        self.session = None
        self.throttle = float(os.environ.get("ANJ_DEV_STREAM_DELAY", "0"))
        self.mutations = Mutations(self)

    @property
    def sharing(self):
        if "_sharing" not in self.__dict__:
            self._sharing = Sharing(self)
        return self._sharing

    @property
    def releases(self):
        """Client update feed (spec #28 G1)."""
        if "_releases" not in self.__dict__:
            self._releases = Releases(self)
        return self._releases

    @property
    def console(self):
        """Household administration (spec #27)."""
        if "_console" not in self.__dict__:
            self._console = Console(self)
        return self._console

    def note_seen(self, device):
        """Record when a device last authenticated, at most once a minute per device (spec #27)."""
        now = self.registry.clock()
        seen = self.__dict__.setdefault("_seen", {})
        if now - seen.get(device["id"], 0) >= 60:
            seen[device["id"]] = now
            try:
                self.registry.seen(device["id"], now)
            except Exception:  # noqa: BLE001 - a missed last-seen time never refuses a request
                pass

    async def start(self, app):
        registry = self.__dict__.get("registry")
        if registry is not None and registry.token_cleanups():
            self.console.schedule_cleanup()
        if registry is not None:
            self.alert_pass_task = asyncio.get_running_loop().create_task(self.alert_pass())
        if registry is not None:
            try:
                # An upload a crash or restart cut off (spec #28 G1): nothing can be publishing yet.
                self.releases.clear_incoming()
            except OSError:
                pass                             # refused storage: every publish and download says so
        self.session = ClientSession(auto_decompress=False, trust_env=False, cookie_jar=DummyCookieJar(), headers={"Accept-Encoding": "identity"},
                                     timeout=ClientTimeout(total=None, sock_connect=10, sock_read=120))

    async def close(self, app):
        console = self.__dict__.get("_console")
        for task in [getattr(console, "cleanup_task", None), *getattr(console, "alert_tasks", ()),
                     *getattr(console, "operation_tasks", ()), *self.__dict__.get("approvals", {}).values(),
                     self.__dict__.get("alert_pass_task"), *self.__dict__.get("alerts_sending", {}).values()]:
            if task is not None:
                task.cancel()
        await self.session.close()
        self.registry.db.close()

    async def envelope(self, request):
        body = await request.json()
        if not isinstance(body, dict):
            raise Rejection("JSON object required")
        return body

    def source(self, request):
        """The connection's source: the PROXY v2 header's in production, the peer in dev.

        `request.remote` is empty on a Unix socket and is never used.
        """
        if "anj.source" in request:
            return request["anj.source"]
        transport = request.transport
        connection = self.edge.connection(transport) if self.edge is not None and transport is not None else None
        source = connection.source if connection is not None else (peer_source(transport) if transport is not None else "unknown")
        request["anj.source"] = source
        return source

    async def health(self, request):
        """Status only: no version, no backend detail (S1)."""
        ready = False
        try:
            self.registry.db.execute("SELECT 1")
            async with self.session.get(self.backend + "/status.php", allow_redirects=False) as response:
                data = await response.json(content_type=None)
                ready = response.status == 200 and bool(data.get("installed")) and not data.get("maintenance")
        except asyncio.CancelledError:
            raise
        except Exception:
            ready = False
        if not ready:
            return web.json_response({"status": "unavailable"}, status=503, headers={"Cache-Control": "no-store"})
        return web.json_response({"status": "ready"}, headers={"Cache-Control": "no-store"})

    async def enroll(self, request):
        source = self.source(request)
        limit = self.guard.admit(source)
        if limit:
            request["anj.reason"] = limit
            raise web.HTTPTooManyRequests(text="Enrollment rate exceeded")
        try:
            try:
                body = await asyncio.wait_for(self.envelope(request), self.body_timeout)
            except asyncio.TimeoutError:
                # A missing or trickled body never holds the connection (or a slot) open:
                # answer 408, then close instead of draining the rest of the body.
                request["anj.reason"] = "body-timeout"
                refusal = web.json_response({"error": "Request body timeout"}, status=408, headers={"Connection": "close"})
                await refusal.prepare(request)
                await refusal.write_eof()
                request.protocol.force_close()
                return refusal
            if set(body) - {"code", "csr", "label"}:
                raise Rejection("Unexpected enrollment field")
            result = self.registry.enroll(body["code"], body["csr"], body.get("label", ""))
        except (ValueError, KeyError, TypeError) as error:
            # A rejected code, CSR or envelope counts toward this source's block (decision #69 (a)).
            self.guard.failed(source)
            if isinstance(error, CodeReused):
                # Same refusal for the requester; the admin hears once that a taken code was tried.
                self.registry.note_reuse(error.invitation, error.label, error.fingerprint)
                self.send_alerts()
            raise
        if result.get("approval") == "automatic":
            if result["state"] == "pending" and await self.approve_pinned(result):
                result = self.registry.enroll(body["code"], body["csr"])
            if result["state"] == "approved":
                self.announce(result["pairing_id"])
        return web.json_response(result, headers={"Cache-Control": "no-store"})

    async def ca(self, request):
        """The household CA's public certificate, nothing else (decision #151, spec #35 rule 2). A
        device fetches it without trust and accepts it only if it matches its code's pin."""
        if request.query_string:
            raise web.HTTPBadRequest(text="Queries are unsupported")
        return web.Response(body=self.issuer_pem, content_type="application/x-pem-file", headers={"Cache-Control": "no-store"})

    async def approve_pinned(self, pending):
        """Approve a redeemed pinned code through the console backend's approve path, with the
        fingerprint of the CSR this exchange reserved it to (decision #151, rule 3). One approval
        runs per pairing, as its own task: it finishes whatever happens to the connection, and a
        later /v1/enroll/status waits for it again or, after a failure, starts it again. True once
        the device is active within this exchange's hold."""
        key = pending["pairing_id"]
        task = self.approvals.get(key)
        if task is None:
            failed = self.approval_failed.get(key)
            if failed is not None and time.monotonic() - failed < self.approval_retry:
                return False
            task = asyncio.ensure_future(self._approve_pinned(key, pending["fingerprint"]))
            self.approvals[key] = task

            def finished(done, key=key):
                if self.approvals.get(key) is done:
                    del self.approvals[key]
            task.add_done_callback(finished)
        done, _ = await asyncio.wait({task}, timeout=self.approval_hold)
        return bool(done) and not task.cancelled() and task.result()

    async def _approve_pinned(self, key, fingerprint):
        try:
            await self.console.backend.call("approve", pairing_id=key, fingerprint=fingerprint)
        except asyncio.CancelledError:
            raise
        except Exception:  # noqa: BLE001 - the device stays pending; its next status request retries
            if len(self.approval_failed) > 1000:
                self.approval_failed.clear()
            self.approval_failed[key] = time.monotonic()
            return False
        self.approval_failed.pop(key, None)
        self.announce(key)
        return True

    def announce(self, identity):
        """Exactly one audit entry (claimed with it, restart-safe) and an at-least-once ntfy alert per
        device paired by a pinned code (rule 4, review M1), whichever path saw it approved first."""
        try:
            self.registry.announce(identity)
        except Exception:  # noqa: BLE001 - never fails the pairing answer; the alert pass retries
            pass
        self.send_alerts()

    def send_alerts(self):
        """Start sending every due pairing alert not already in flight. An alert is marked done only
        when the backend confirms it (sent, or spooled for the dispatcher), so a failure, a backend
        that is down or a restart leaves it due for the next pass: at least once (review M1)."""
        try:
            due = self.registry.alerts_due()
        except Exception:  # noqa: BLE001 - retried by the next pass
            return
        for kind, row in due:
            key = (kind, row["id"])
            if key in self.alerts_sending:
                continue
            task = asyncio.get_running_loop().create_task(self._send_alert(kind, row))
            self.alerts_sending[key] = task
            task.add_done_callback(lambda _task, key=key: self.alerts_sending.pop(key, None))

    async def _send_alert(self, kind, row):
        key = (kind, row["id"])
        try:
            await self.console.pairing_alert(kind, row)
        except asyncio.CancelledError:
            raise
        except Exception as error:  # noqa: BLE001 - stays due; the next pass sends it again
            # The first failure of each episode is audited, so an undelivered alert is visible
            # in Admin (PR #92 review H1); the retries every pass are not.
            if key not in self.alert_failures:
                self.alert_failures.add(key)
                reason = getattr(error, "reason", None) or "error"
                try:
                    self.registry.audit("pairing-alert", "alert-failed:" + reason, actor_uid="system", target_uid=row["uid"],
                                        target_device=row.get("device") if kind == "paired" else None,
                                        target_invitation=row["id"])
                except Exception:  # noqa: BLE001 - the audit write never stops the retries
                    pass
            return
        self.alert_failures.discard(key)
        self.registry.alert_confirmed(kind, row["id"])

    def alert_pass_once(self):
        """Audit approved pinned invitations nobody announced yet (setup's operator fallback), then
        start every due alert."""
        for identity in self.registry.unannounced():
            self.announce(identity)
        self.send_alerts()

    async def alert_pass(self, interval=None):
        while True:
            try:
                self.alert_pass_once()
            except Exception:  # noqa: BLE001 - the pass never stops
                pass
            await asyncio.sleep(interval or ALERT_PASS_SECONDS)

    def identity(self, request):
        ssl_object = request.transport.get_extra_info("ssl_object") if request.transport is not None else None
        der = ssl_object.getpeercert(binary_form=True) if ssl_object else None
        if not der:
            request["anj.reason"] = "no-certificate"
            raise web.HTTPUnauthorized(text="Device certificate required")
        certificate = x509.load_der_x509_certificate(der)
        now = datetime.now(timezone.utc)
        if not certificate.not_valid_before_utc <= now < certificate.not_valid_after_utc:
            request["anj.reason"] = "certificate-expired"
            raise web.HTTPUnauthorized(text="Device certificate expired")
        leaf = certificate.fingerprint(hashes.SHA256()).hex()
        try:
            device = self.registry.admit(key_fingerprint(certificate.public_key()), leaf, observe=True)
        except AccountDisabled:
            request["anj.reason"] = "account-disabled"
            raise web.HTTPForbidden(text="Account is disabled") from None
        except ValueError:
            request["anj.reason"] = "inactive-device"
            raise web.HTTPForbidden(text="Device is not active") from None
        request["anj.device"] = device["id"]
        request["anj.cert"] = leaf
        self.note_seen(device)
        return device

    async def device_certificate(self, request):
        """The authenticated device's own current leaf; no parameters select another device."""
        device = self.identity(request)
        return web.json_response({"device_id": device["id"], "certificate": device["certificate"], "expires_at": device["expires"]},
                                 headers={"Cache-Control": "no-store"})

    async def files_added(self, request):
        """When the caller's own files were first created through this gateway (decision #56).

        Authenticated exactly like DAV; rows are only ever read for the device's own UID. A read:
        served while writes are fenced. Query: `after` (cursor, default 0), `limit` (1-1000).
        """
        device = self.identity(request)
        query = request.query
        if set(query) - {"after", "limit"} or any(len(query.getall(key)) != 1 for key in query):
            raise Rejection("Unsupported files-added query")
        after, limit = query.get("after", "0"), query.get("limit", str(Registry.ADDED_PAGE))
        if (not re.fullmatch(r"[0-9]{1,19}", after) or int(after) >= 2 ** 63
                or not re.fullmatch(r"[0-9]{1,4}", limit) or not 1 <= int(limit) <= Registry.ADDED_PAGE):
            raise Rejection("Invalid files-added cursor or limit")
        return web.json_response(self.registry.added_since(device["uid"], int(after), int(limit)), headers={"Cache-Control": "no-store"})

    # Directory sharing (spec #26). Each route acts only as the certificate's account, takes no
    # query string and answers with Cache-Control: no-store. Error bodies never carry a path.

    def share_caller(self, request, write=False):
        device = self.identity(request)
        if request.query_string:
            raise ShareError(400, "Queries are unsupported")
        if write and device["rights"] != "write":
            raise ShareError(403, "This device can only view")
        return device

    async def share_body(self, request, fields):
        try:
            body = await request.json()
        except ValueError:
            raise ShareError(400, "A JSON object is required") from None
        if not isinstance(body, dict) or set(body) != set(fields):
            raise ShareError(400, "Expected exactly: " + ", ".join(sorted(fields)))
        return body

    async def household_users(self, request):
        device = self.share_caller(request)
        return web.json_response(self.registry.household(device["uid"]), headers=NO_STORE)

    async def shares_outgoing(self, request):
        device = self.share_caller(request)
        return web.json_response(await self.sharing.outgoing(self.sharing.device_principal(device)), headers=NO_STORE)

    async def shares_incoming(self, request):
        device = self.share_caller(request)
        return web.json_response(await self.sharing.incoming(self.sharing.device_principal(device)), headers=NO_STORE)

    async def share_create(self, request):
        device = self.share_caller(request, write=True)
        body = await self.share_body(request, {"path", "recipient_id", "permission"})
        row = await self.sharing.create(self.sharing.device_principal(device), body["path"], body["recipient_id"], body["permission"])
        return web.json_response(row, status=201, headers=NO_STORE)

    async def share_update(self, request):
        device = self.share_caller(request, write=True)
        body = await self.share_body(request, {"permission"})
        row = await self.sharing.update(self.sharing.device_principal(device), request.match_info["share_id"], body["permission"])
        return web.json_response(row, headers=NO_STORE)

    async def share_remove(self, request):
        device = self.share_caller(request, write=True)
        return web.json_response(await self.sharing.remove(self.sharing.device_principal(device), request.match_info["share_id"]),
                                 headers=NO_STORE)

    async def share_leave(self, request):
        # The recipient deletes a shared folder on a device: leave that share (decision #157).
        device = self.share_caller(request, write=True)
        return web.json_response(await self.sharing.leave(self.sharing.device_principal(device), request.match_info["share_id"]),
                                 headers=NO_STORE)

    async def share_rename_for_all(self, request):
        # The recipient renames a shared folder for everyone (decision #155).
        device = self.share_caller(request, write=True)
        body = await self.share_body(request, {"name"})
        return web.json_response(await self.sharing.rename_for_all(self.sharing.device_principal(device), request.match_info["share_id"],
                                                                   body["name"]), headers=NO_STORE)

    def client_leaf(self, pem, fingerprint):
        """Validate an operator-signed fixed-profile client leaf; return it with expiry and leaf ID."""
        certificate = x509.load_pem_x509_certificate(pem.encode())
        try:
            certificate.verify_directly_issued_by(self.issuer)
        except InvalidSignature:
            raise Rejection("Client certificate is not signed by the issuer") from None
        if key_fingerprint(certificate.public_key()) != fingerprint:
            raise Rejection("Issued certificate key mismatch")
        if certificate.extensions.get_extension_for_class(x509.BasicConstraints).value.ca:
            raise Rejection("Client certificate cannot be an issuer")
        if list(certificate.extensions.get_extension_for_class(x509.ExtendedKeyUsage).value) != [ExtendedKeyUsageOID.CLIENT_AUTH]:
            raise Rejection("Client certificate profile mismatch")
        expires = certificate.not_valid_after_utc.timestamp()
        now = self.registry.clock()
        # Leaves live until the issuer's expiry (decision #44); revocation is per request.
        if certificate.not_valid_before_utc.timestamp() > now or expires <= now or expires > self.issuer.not_valid_after_utc.timestamp():
            raise Rejection("Client certificate validity mismatch")
        return certificate, expires, certificate.fingerprint(hashes.SHA256()).hex()

    def settings(self):
        return {"upload_limit_bytes": self.mutations.limit, "upload_limit_min_bytes": UPLOAD_LIMIT_MIN,
                "upload_limit_max_bytes": UPLOAD_LIMIT_MAX, "staging_bytes": self.mutations.capacity}

    async def backend_ready(self):
        """Read-only readiness for the operator status view; never raises."""
        try:
            self.registry.db.execute("SELECT 1")
            async with self.session.get(self.backend + "/status.php", allow_redirects=False) as response:
                data = await response.json(content_type=None)
                return response.status == 200 and bool(data.get("installed")) and not data.get("maintenance")
        except asyncio.CancelledError:
            raise
        except Exception:
            return False

    def fence_summary(self):
        """Fence state and the kind of operation that holds it, never its path or intent detail."""
        row = self.registry.db.execute("SELECT state,path FROM mutation_fence WHERE singleton=1").fetchone()
        state, path = row[0], row[1] or ""
        if state == "clear":
            return {"state": "clear", "kind": None}
        if state == "maintenance":
            return {"state": state, "kind": "maintenance"}
        try:
            intent = json.loads(path)
        except ValueError:
            intent = None
        if isinstance(intent, dict) and intent.get("kind") in SHARING_INTENTS:
            kind = intent["kind"]
        elif path.startswith("cleanup-unconfined-share-"):
            kind = "share-cleanup"
        elif path.startswith("operator-sharing"):
            kind = "share"
        elif path == "provision-enrolled-root":
            kind = "root-provisioning"
        else:
            kind = "file-write"
        return {"state": state, "kind": kind}

    async def advertise_limit(self, request, response):
        """Every DAV response states the upload limit, so a client learns it before any upload."""
        if request.path.startswith("/dav/"):
            response.headers[UPLOAD_LIMIT_HEADER] = str(self.mutations.limit)

    async def refuse_oversized(self, request, limit=None):
        """Answer 413 from the declared length alone and close the connection.

        The body is never read. Without the close, aiohttp would drain an unread body for
        up to its lingering time (10 s) before closing, so a client that streams the whole
        body before reading a response would keep sending it (SC-028).
        """
        refusal = self.mutations.too_large(request.content_length, limit)
        await refusal.prepare(request)
        await refusal.write_eof()
        request.protocol.force_close()
        return refusal

    async def refuse_name(self, request, reason):
        """422 `name-not-portable`, closing the connection so an unread upload body is not drained."""
        refusal = name_refusal(reason)
        refusal.headers["Connection"] = "close"
        await refusal.prepare(request)
        await refusal.write_eof()
        request.protocol.force_close()
        return refusal

    async def dav(self, request):
        device = self.identity(request)
        if request.method not in METHODS:
            raise web.HTTPMethodNotAllowed(request.method, sorted(METHODS))
        if request.query_string or "If" in request.headers:
            raise Rejection("Queries and tagged DAV If headers are unsupported")
        if device["rights"] == "read" and request.method not in READ_METHODS:
            raise web.HTTPForbidden(text="Device is read-only")
        raw = request.raw_path
        if not raw.startswith("/dav/"):
            raise Rejection("Invalid DAV path")
        relative = canonical_path(raw[len("/dav/"):])
        if not relative and request.method in {"DELETE", "MOVE", "PUT", "MKCOL"}:
            raise web.HTTPForbidden(text="Enrolled root is preserved")
        if request.headers.get("Content-Encoding", "identity") != "identity":
            raise Rejection("Encoded request content is unsupported")
        # The limit in force when this request started governs it, even if the owner console
        # changes the limit while it waits for the mutation lock (spec #27).
        limit = self.mutations.limit
        if request.method == "PUT":
            if request.content_length is None:
                raise web.HTTPLengthRequired(text="Declare upload Content-Length")
            if request.content_length > limit:
                return await self.refuse_oversized(request, limit)
        headers = {key.title(): value for key, value in request.headers.items() if key.lower() in REQUEST_HEADERS}
        headers["Accept-Encoding"] = "identity"
        if request.method == "PROPFIND":
            if request.headers.get("Depth") not in {"0", "1"}:
                raise Rejection("PROPFIND requires Depth 0 or 1")
        destination = None
        if request.method == "MOVE":
            destination = move_destination(request.headers.get("Destination", ""), self.origin)
            if not destination:
                raise Rejection("Cannot replace enrolled root")
            headers["Destination"] = self.backend + backend_root(device["uid"]) + destination
        # Portable names (decision #120): a create or rename to a name Windows or macOS cannot
        # hold is refused before any body byte is read or anything is queued. A PUT with
        # If-None-Match: * is a create; an overwrite of an existing item keeps its name.
        created = (destination if request.method == "MOVE" else relative
                   if request.method == "MKCOL" or (request.method == "PUT" and request.headers.get("If-None-Match") == "*") else None)
        if created is not None:
            reason = portable_names.check(split_leaf(created)[1])
            if reason is not None:
                return await self.refuse_name(request, reason)
        task = asyncio.current_task()
        transport = request.transport
        mutation = None
        # Synchronous registry admission above and registration below contain no await:
        # the single worker cannot commit revoke in the gap.
        self.active[device["id"]].add(task)
        self.transports[device["id"]].add(transport)
        try:
            if request.method not in READ_METHODS:
                if len(self.mutations.tasks) >= 16:
                    raise web.HTTPServiceUnavailable(text="Development mutation queue is full")
                mutation = asyncio.create_task(self.mutations.run(request, device, relative, headers, limit, destination))
                self.mutations.register(mutation, device["id"])
                mutation.add_done_callback(self.mutations.finished)
                return await asyncio.shield(mutation)
            if request.method in {"PROPFIND", "MKCOL", "OPTIONS", "MOVE", "DELETE", "GET", "HEAD"}:
                body = await request.read()
                if request.method == "PROPFIND" and body:
                    root = SafeET.fromstring(body, forbid_dtd=True)
                    if root.tag != "{DAV:}propfind":
                        raise Rejection("Invalid PROPFIND document")
                data = body or None
            else:
                async def upload():
                    size = 0
                    async for chunk in request.content.iter_chunked(16384):
                        size += len(chunk)
                        if size > limit:
                            raise Rejection("Development upload limit exceeded")
                        if self.throttle:
                            await asyncio.sleep(self.throttle)
                        yield chunk
                data = upload()
            url = self.backend + backend_root(device["uid"]) + relative
            async with self.session.request(request.method, url, data=data, headers=headers,
                                            auth=BasicAuth(device["uid"], device["token"]), allow_redirects=False) as upstream:
                if 300 <= upstream.status < 400 and upstream.status != 304:
                    raise web.HTTPBadGateway(text="Backend redirect rejected")
                if upstream.headers.get("Content-Encoding", "identity") != "identity":
                    raise web.HTTPBadGateway(text="Unexpected backend content encoding")
                outgoing = {key: value for key, value in upstream.headers.items() if key.lower() in RESPONSE_HEADERS}
                outgoing["Cache-Control"] = "no-store"
                if "Location" in upstream.headers:
                    outgoing["Location"] = gateway_reference(upstream.headers["Location"], device["uid"], self.origin, self.backend)
                if upstream.status == 207:
                    chunks, size = [], 0
                    async for chunk in upstream.content.iter_chunked(16384):
                        size += len(chunk)
                        if size > MAX_XML:
                            raise Rejection("DAV XML exceeds development limit")
                        chunks.append(chunk)
                    content = b"".join(chunks)
                    content = rewrite_multistatus(content, device["uid"], self.origin, self.backend)
                    return web.Response(status=207, body=content, headers=outgoing)
                if upstream.status >= 400:
                    # Backend error XML can contain internal paths/URLs; return the status without it.
                    return web.Response(status=upstream.status, headers=outgoing)
                if "Content-Length" in upstream.headers:
                    outgoing["Content-Length"] = upstream.headers["Content-Length"]
                response = web.StreamResponse(status=upstream.status, headers=outgoing)
                await response.prepare(request)
                if request.method != "HEAD":
                    async for chunk in upstream.content.iter_chunked(16384):
                        if self.throttle:
                            await asyncio.sleep(self.throttle)
                        await response.write(chunk)
                await response.write_eof()
                return response
        except asyncio.CancelledError:
            if mutation is not None and mutation not in self.mutations.dispatched:
                mutation.cancel()
            transport.abort()
            raise
        finally:
            self.active[device["id"]].discard(task)
            self.transports[device["id"]].discard(transport)

    async def admin(self, request):
        # A ShareError keeps its status; safe_errors gives it the curated {"error": ...} envelope.
        return await self._admin(request)

    async def _account_set(self, body):
        """account-set; for a disable the caller holds the mutation lock (see `_admin`)."""
        current = self.registry.account(body.get("uid"))
        recorded = None
        if body.get("enabled") is False and (current is None or current["enabled"]):
            # Nextcloud hides a disabled owner's shares; record recipients' mounts first.
            # One read of the owner's own list (operator token, else an owner device).
            recorded = await self.sharing.remember_before_disable(body.get("uid"), body.get("token"))
            if not recorded:
                # Without every recipient's mount on record, a recipient's client would read
                # the hidden share as an unshare (decisions #79 (b), #80 (2)). Nothing changes.
                raise Rejection("Could not read this account's shares to record where recipients mount them; "
                                "the account was not disabled. Retry the disable.")
        account, changed = self.registry.account_set(body.get("uid"), body.get("display_name"), body.get("enabled"))
        if changed and not account["enabled"]:
            # Refused from now on (403); certificates stay valid. Abort what is in flight
            # (unsubmitted work only; a mutation in flight would hold this lock).
            await self.abort_devices([device["id"] for device in self.registry.active_devices(account["uid"])])
        return web.json_response({"account": account, "changed": changed, "mounts_recorded": recorded})

    async def abort_devices(self, devices):
        tasks = []
        for device in devices:
            tasks += list(self.active[device]) + self.mutations.cancel_unsubmitted(device)
            for transport in list(self.transports[device]):
                transport.abort()
        for task in tasks:
            task.cancel()
        if tasks:
            await asyncio.wait(tasks, timeout=2)

    async def _admin(self, request):
        body = await self.envelope(request)
        action = body.get("action")
        if action == "invite":
            return web.json_response(self.registry.invite(body["uid"], body["rights"], ca_pin=self.ca_pin))
        if action == "pending":
            return web.json_response(self.registry.pending())
        if action == "devices":
            return web.json_response(self.registry.public_devices())
        if action == "activity":
            return web.json_response({"active": {key: len(value) for key, value in self.active.items()},
                                      "mutations": len(self.mutations.tasks), "mutation_lock": self.mutations.lock.locked(),
                                      "write_fence": self.registry.db.execute("SELECT state FROM mutation_fence WHERE singleton=1").fetchone()[0]})
        if action == "fence":
            fence = dict(self.registry.db.execute("SELECT * FROM mutation_fence WHERE singleton=1").fetchone())
            fence["owner_uid"] = owner_of(self.registry, fence["device"])
            return web.json_response(fence)
        if action == "settings-get":
            return web.json_response(self.settings())
        if action == "settings-set":
            # Same single-writer lock as uploads and share changes: the change lands between
            # mutations, never inside one (spec #27).
            async with self.mutations.lock:
                self.mutations.set_limit(body.get("upload_limit_bytes"))
            return web.json_response(self.settings())
        if action == "status":
            return web.json_response({"backend": "ready" if await self.backend_ready() else "unavailable",
                                      "write_fence": self.fence_summary(),
                                      "transition_leaves": self.registry.db.execute(
                                          "SELECT count(*) FROM device_leaves WHERE expires>?", (self.registry.clock(),)).fetchone()[0],
                                      "upload_limit_bytes": self.mutations.limit})
        if action == "share-cleanups":
            return web.json_response([dict(row) for row in self.registry.db.execute("SELECT * FROM share_cleanup")])
        if action == "share-cleanup-resolved":
            row = self.registry.db.execute("SELECT device FROM share_cleanup WHERE share_id=?", (str(body["share_id"]),)).fetchone()
            if row and owner_of(self.registry, row["device"]) != body["owner_uid"]:
                raise Rejection("Cleanup owner mismatch")
            with self.registry.db:
                self.registry.db.execute("UPDATE share_cleanup SET state='resolved' WHERE share_id=?", (str(body["share_id"]),))
            return web.json_response({"state": "resolved"})
        if action == "inspect":
            return web.json_response(self.registry.invitation(body["pairing_id"]))
        if action == "begin":
            return web.json_response(self.registry.begin(body["pairing_id"], body["fingerprint"]))
        if action == "deny":
            return web.json_response(self.registry.deny(body["pairing_id"]))
        if action == "activate":
            stage = "backend-account"
            try:
                invitation = self.registry.invitation(body["pairing_id"])
                # Never trust a caller's claimed account. Validate the token against fixed backend.
                async with self.session.get(self.backend + "/ocs/v2.php/cloud/user?format=json",
                                            auth=BasicAuth(invitation["uid"], body["token"]),
                                            headers={"OCS-APIRequest": "true"}, allow_redirects=False) as response:
                    data = await response.json(content_type=None)
                    if response.status != 200 or data["ocs"]["data"]["id"] != invitation["uid"]:
                        raise Rejection("Backend account binding failed")
                stage = "certificate-profile"
                certificate, expires, leaf = self.client_leaf(body["certificate"], invitation["fingerprint"])
                stage = "root-provisioning"
                async def provision_root():
                    for folder in ("", "Music", "Videos", "Documents", "Shared"):
                        url = self.backend + backend_root(invitation["uid"]) + folder
                        async with self.session.request("MKCOL", url, auth=BasicAuth(invitation["uid"], body["token"]), allow_redirects=False) as response:
                            await response.read()
                            if response.status not in (201, 405):
                                raise Rejection("Could not provision the enrolled root")
                await self.mutations.operator_operation(invitation["device"], "provision-enrolled-root", provision_root)
                stage = "registry-activation"
                self.registry.activate(body["pairing_id"], body["fingerprint"], body["token"], body["token_id"], body["certificate"], expires, leaf)
                return web.json_response({"state": "active", "device_id": invitation["device"]})
            except Rejection:
                raise
            except (ValueError, KeyError, TypeError) as error:
                raise Rejection("Activation rejected at " + stage + " (" + type(error).__name__ + ")") from None
        if action == "reissue-begin":
            return web.json_response(self.registry.reissue_target(body["device_id"]))
        if action == "reissue-commit":
            target = self.registry.reissue_target(body["device_id"])
            try:
                certificate, expires, leaf = self.client_leaf(body["certificate"], target["fingerprint"])
                # Same subject device identity as the leaf it replaces (rule 2).
                if certificate.subject != x509.load_pem_x509_certificate(target["certificate"].encode()).subject:
                    raise Rejection("Reissued certificate subject mismatch")
            except Rejection:
                raise
            except (ValueError, KeyError, TypeError) as error:
                raise Rejection("Reissue rejected at certificate-profile (" + type(error).__name__ + ")") from None
            return web.json_response(self.registry.reissue(target["device"], target["fingerprint"], body["certificate"], expires, leaf))
        if action in {"share", "share-update", "unshare", "shares"}:
            # One sharing component (decision #78 C3): an owner's active device, or an owner with no
            # paired device through an operator-minted temporary token (decision #80 (4)).
            principal = await self.sharing.operator_principal(body)
            if action == "shares":
                return web.json_response(await self.sharing.outgoing(principal))
            # One access level (decision #155): `write` (full access) is the default and the only
            # level a share is created or changed to; `read` is refused by the sharing component.
            if action in {"share", "share-update"} and body.get("rights", "write") not in OPERATOR_RIGHTS:
                raise Rejection("Share rights must be read or write")
            permission = OPERATOR_RIGHTS[body.get("rights", "write")] if action != "unshare" else None
            if action == "share":
                row = await self.sharing.create(principal, body["path"], body["recipient"], permission)
                # Nextcloud resolves target-name collisions on the recipient's first mount; the
                # creation response's provisional name is not presented as the final path.
                return web.json_response({**row, "incoming_root": "/dav/Shared/", "rights": body.get("rights", "write")})
            if action == "share-update":
                return web.json_response({**await self.sharing.update(principal, str(body["share_id"]), permission),
                                          "rights": body.get("rights", "write")})
            if not re.fullmatch(r"[0-9]+", str(body["share_id"])):
                raise Rejection("Invalid share ID")
            return web.json_response(await self.sharing.remove(principal, str(body["share_id"])))
        if action == "admin":
            # Recovery CLI and console backend (spec #27): same rules and audit as /v1/admin.
            return web.json_response(await self.console.operator(body))
        if action == "accounts":
            return web.json_response(self.registry.accounts())
        if action == "releases":
            return web.json_response(self.releases.status())
        if action == "account-set":
            if set(body) - {"action", "uid", "display_name", "enabled", "token"}:
                raise Rejection("Unexpected account field")
            if body.get("enabled") is False:
                # The single mutation lock is held from reading the owner's share list to the
                # registry flip, so no share created in between can go unrecorded.
                async with self.mutations.lock:
                    return await self._account_set(body)
            return await self._account_set(body)
        if action == "share-fences":
            return web.json_response(self.registry.share_fences())
        if action == "share-fence-clear":
            if not self.registry.share_fence_clear(body.get("scope")):
                raise Rejection("No such share fence")
            return web.json_response({"state": "clear"})
        if action == "revoke":
            device = self.registry.disable(body["device_id"])
            await self.abort_devices([device["id"]])
            return web.json_response({"state": "revoked", "token_id": device["token_id"], "uid": device["uid"]})
        if action == "maintenance":
            self.registry.maintenance()
            for owner in set(self.mutations.owners.values()):
                self.mutations.cancel_unsubmitted(owner)
            return web.json_response({"state": "maintenance"})
        if action == "recover":
            if self.mutations.lock.locked() or self.mutations.tasks:
                raise Rejection("Backend work has not quiesced")
            fence = self.registry.db.execute("SELECT path FROM mutation_fence WHERE singleton=1").fetchone()[0] or ""
            try:
                intent = json.loads(fence)
            except ValueError:
                intent = None
            sharing = fence.startswith(("operator-sharing", "cleanup-unconfined-share-")) or (isinstance(intent, dict) and intent.get("kind") in SHARING_INTENTS)
            unresolved = self.registry.db.execute("SELECT count(*) FROM share_cleanup WHERE state!='resolved'").fetchone()[0]
            if unresolved:
                raise Rejection("Known share cleanup must be inspected/repaired before fence clear")
            if sharing and body.get("sharing_reconciled") is not True:
                raise Rejection("Sharing intent requires explicit local reconciliation after quiescence")
            self.registry.recover()
            with self.registry.db:
                self.registry.db.execute("DELETE FROM share_cleanup WHERE state='resolved'")
            return web.json_response({"state": "clear"})
        raise Rejection("Unsupported operator action")


    def after_response(self, request, response, duration):
        """Called by aiohttp once a response is fully written: log it and re-arm the watchdog."""
        source = self.source(request)
        transport = request.transport
        connection = self.edge.connection(transport) if self.edge is not None and transport is not None else None
        if connection is not None:
            connection.arm()
        if response.status == 429:
            self.events.count(source, request.get("anj.reason", "limit"))
        else:
            self.events.request(request, response, duration)

    def access_log_class(self):
        gateway = self

        class AccessLog(AbstractAccessLogger):
            def log(self, request, response, time):
                gateway.after_response(request, response, time)

        return AccessLog

    def edge_middleware(self):
        @web.middleware
        async def middleware(request, handler):
            # Outermost: a request has started, so the header deadline no longer applies.
            self.source(request)
            transport = request.transport
            connection = self.edge.connection(transport) if self.edge is not None and transport is not None else None
            if connection is not None:
                connection.disarm()
            return await handler(request)
        return middleware

    def public_app(self):
        drop_server_header()
        public = web.Application(client_max_size=16384, middlewares=[self.edge_middleware(), safe_errors])
        public.on_startup.append(self.start)
        public.on_cleanup.append(self.close)
        public.router.add_get("/health", self.health)
        public.router.add_get("/v1/ca", self.ca)
        public.router.add_post("/v1/enroll", self.enroll)
        public.router.add_post("/v1/enroll/status", self.enroll)
        public.router.add_get("/v1/device/certificate", self.device_certificate)
        public.router.add_get("/v1/files/added", self.files_added)
        public.router.add_get("/v1/household/users", self.household_users)
        public.router.add_get("/v1/shares/outgoing", self.shares_outgoing)
        public.router.add_get("/v1/shares/incoming", self.shares_incoming)
        public.router.add_post("/v1/shares", self.share_create)
        public.router.add_patch("/v1/shares/{share_id}", self.share_update)
        public.router.add_delete("/v1/shares/{share_id}", self.share_remove)
        public.router.add_delete("/v1/shares/incoming/{share_id}", self.share_leave)
        public.router.add_post("/v1/shares/incoming/{share_id}/rename", self.share_rename_for_all)
        self.console.add_routes(public.router)
        self.releases.add_routes(public.router)
        public.router.add_route("*", "/dav/{path:.*}", self.dav)
        public.on_response_prepare.append(self.advertise_limit)
        return public

    def runner(self, public):
        return web.AppRunner(public, access_log=logging.getLogger("anj.access"), access_log_class=self.access_log_class(),
                             handler_cancellation=True, keepalive_timeout=KEEPALIVE_TIMEOUT)


@web.middleware
async def safe_errors(request, handler):
    try:
        return await handler(request)
    except web.HTTPException:
        raise
    except ShareError as error:
        return web.json_response({"error": error.message, **error.detail}, status=error.status, headers=NO_STORE)
    except Rejection as error:
        return web.json_response({"error": str(error)}, status=400)
    except (ValueError, KeyError, TypeError):
        return web.json_response({"error": "Request rejected"}, status=400)
    except asyncio.CancelledError:
        raise
    except Exception:
        return web.json_response({"error": "Service operation failed"}, status=503)


def operator_app(gateway):
    """The private operator socket's application."""
    admin = web.Application(client_max_size=16384, middlewares=[safe_errors])
    admin.router.add_post("/operator", gateway.admin)
    # Release publish streams the package (spec #28 G1); client_max_size bounds only read()/json().
    admin.router.add_put("/operator/release/{target}", gateway.releases.publish)
    return admin


async def serve():
    os.umask(0o077)
    state = Path(os.environ.get("ANJ_STATE", "/var/lib/anj"))
    # Dev mounts TLS material as compose secrets; production reads the copies its init
    # service installs for the non-root user (compose file secrets keep host ownership).
    tls = Path(os.environ.get("ANJ_TLS_DIR", "/run/secrets"))
    listener = os.environ.get("ANJ_LISTENER", "tcp")
    if listener not in LISTENERS:
        raise SystemExit("ANJ_LISTENER must be tcp or proxy-unix")
    gateway = Gateway(state, os.environ.get("ANJ_BACKEND", "http://nextcloud"), os.environ["ANJ_ORIGIN"], tls / "issuer_crt")
    public = gateway.public_app()
    admin = operator_app(gateway)
    context = tls_context(tls / "server_crt", tls / "server_key", tls / "issuer_crt")
    socket = state / "operator.sock"
    socket.unlink(missing_ok=True)
    runner = gateway.runner(public)
    admin_runner = web.AppRunner(admin, access_log=None)
    await runner.setup()
    await admin_runner.setup()
    gateway.edge = Edge(gateway.events, runner.server, context)
    if listener == "tcp":
        # Dev: TLS on 0.0.0.0:8443, no PROXY (decision #49).
        await gateway.edge.start_tcp("0.0.0.0", 8443)
    else:
        await gateway.edge.start_unix(os.environ.get("ANJ_SOCKET", "/run/anj-cloud-gw/gateway.sock"))
    await web.UnixSite(admin_runner, str(socket)).start()
    socket.chmod(0o600)
    stopping = asyncio.Event()
    loop = asyncio.get_running_loop()
    for number in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(number, stopping.set)

    async def flush_summaries():
        while True:
            await asyncio.sleep(15)
            gateway.events.flush()

    flusher = asyncio.create_task(flush_summaries())
    try:
        await stopping.wait()
    finally:
        flusher.cancel()
        await gateway.edge.close()
        gateway.events.flush(force=True)
        await admin_runner.cleanup()
        await runner.cleanup()


if __name__ == "__main__":
    logging.disable(logging.CRITICAL)
    asyncio.run(serve())
