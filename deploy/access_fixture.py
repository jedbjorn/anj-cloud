"""Real TLS pairing/DAV proof with isolated synthetic devices and exact cleanup."""

import argparse
import asyncio
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import secrets
import ssl
import sys
import time
from urllib.parse import quote
from xml.etree import ElementTree as ET

import aiohttp
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID
from yarl import URL

from deploy.access_operator import Operator
from deploy.dev import FIXTURE_USERS, Stack, private_directory
from services.access.protocol import key_fingerprint


class Actor:
    def __init__(self, stack, directory, key, csr, invitation):
        self.stack, self.directory, self.key, self.csr, self.invitation = stack, directory, key, csr, invitation
        self.identity = None
        self.session = None
        self.extra_paths = []

    def context(self, certificate=True):
        context = ssl.create_default_context(cafile=str(self.stack.local / "operator/issuer.crt"))
        if certificate:
            context.load_cert_chain(self.directory / "device.crt", self.directory / "device.key")
        return context

    async def open(self):
        self.session = aiohttp.ClientSession(connector=aiohttp.TCPConnector(ssl=self.context()), trust_env=False)

    async def request(self, method, path, *, data=None, headers=None, expected=(200,)):
        async with self.session.request(method, URL(self.stack.origin + path, encoded=True), data=data, headers=headers,
                                        allow_redirects=False, timeout=aiohttp.ClientTimeout(total=60)) as response:
            body = await response.read()
            if response.status not in expected:
                raise RuntimeError(f"Gateway fixture {method} returned {response.status}, expected {expected}; response withheld")
            return body, dict(response.headers)

    async def etag(self, relative):
        body, _ = await self.request("PROPFIND", "/dav/" + relative, headers={"Depth": "0"}, expected=(207,))
        value = ET.fromstring(body).findtext(".//{DAV:}getetag")
        if not value:
            raise RuntimeError("Gateway fixture resource has no ETag")
        return value

    async def close(self):
        if self.session:
            await self.session.close()


async def pair(stack, operator, uid, directory, rights="write", retained=None):
    private_directory(directory)
    key = retained.key if retained else ec.generate_private_key(ec.SECP256R1())
    csr = x509.load_pem_x509_csr(retained.csr.encode()) if retained else x509.CertificateSigningRequestBuilder().subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "untrusted fixture label")])).add_extension(x509.BasicConstraints(ca=True, path_length=0), critical=True).sign(key, hashes.SHA256())
    key_path = directory / "device.key"
    key_path.write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
    key_path.chmod(0o600)
    csr_pem = csr.public_bytes(serialization.Encoding.PEM).decode()
    invitation = await asyncio.to_thread(operator.call, "invite", uid=uid, rights=rights)
    actor = Actor(stack, directory, key, csr_pem, invitation)
    context = actor.context(False)
    async with aiohttp.ClientSession(connector=aiohttp.TCPConnector(ssl=context), trust_env=False) as bootstrap:
        async with bootstrap.get(stack.origin + "/dav/") as response:
            if response.status != 401:
                raise RuntimeError("Bootstrap connection gained file access without a certificate")
        code = invitation["code"]
        manual = "-".join(code[i:i+4] for i in range(0, 32, 4)).lower()
        async with bootstrap.post(stack.origin + "/v1/enroll", json={"code": manual, "csr": csr_pem, "label": "synthetic fixture"}) as response:
            if response.status != 200:
                raise RuntimeError(f"Real bootstrap enrollment failed HTTP {response.status}")
            pending = await response.json()
        fingerprint = key_fingerprint(key.public_key())
        if pending["fingerprint"] != fingerprint or pending["state"] != "pending":
            raise RuntimeError("Client/operator CSR public-key fingerprint mismatch")
        async with bootstrap.post(stack.origin + "/v1/enroll/status", json={"code": code, "csr": csr_pem}) as response:
            if await response.json() != pending:
                raise RuntimeError("QR/manual or same-key retry identity changed")
        try:
            await asyncio.to_thread(operator.approve, pending["pairing_id"], "0" * 64)
        except RuntimeError:
            pass
        else:
            raise RuntimeError("Mismatched operator fingerprint was approved")
        await asyncio.to_thread(operator.approve, pending["pairing_id"], fingerprint)
        async with bootstrap.post(stack.origin + "/v1/enroll/status", json={"code": code, "csr": csr_pem}) as response:
            approved = await response.json()
    if approved.get("state") != "approved":
        raise RuntimeError("Approved fixture did not receive its certificate")
    certificate = x509.load_pem_x509_certificate(approved["certificate"].encode())
    if key_fingerprint(certificate.public_key()) != fingerprint or certificate.extensions.get_extension_for_class(x509.BasicConstraints).value.ca:
        raise RuntimeError("Returned certificate does not match key/fixed leaf profile")
    issuer = x509.load_pem_x509_certificate((stack.local / "operator/issuer.crt").read_bytes())
    if certificate.not_valid_after_utc != issuer.not_valid_after_utc or certificate.not_valid_after_utc <= datetime.now(timezone.utc):
        raise RuntimeError("Certificate does not live until Dev issuer expiry")
    target = directory / "device.crt"
    target.write_text(approved["certificate"])
    target.chmod(0o600)
    actor.identity = approved["device_id"]
    await actor.open()
    return actor


async def qualify_reissue(stack, operator, actor):
    """Operator reissue plus device pickup over the existing mTLS session, without re-pairing."""
    issuer = x509.load_pem_x509_certificate((stack.local / "operator/issuer.crt").read_bytes())
    held = (actor.directory / "device.crt").read_text()
    old = x509.load_pem_x509_certificate(held.encode())
    result = await asyncio.to_thread(operator.reissue, actor.identity, True)
    if result["state"] != "reissued":
        raise RuntimeError("Operator reissue did not commit")
    body, headers = await actor.request("GET", "/v1/device/certificate")
    pickup = json.loads(body)
    new = x509.load_pem_x509_certificate(pickup["certificate"].encode())
    if (pickup["device_id"] != actor.identity or key_fingerprint(new.public_key()) != key_fingerprint(actor.key.public_key())
            or new.subject != old.subject or new.not_valid_after_utc != issuer.not_valid_after_utc
            or new.fingerprint(hashes.SHA256()) == old.fingerprint(hashes.SHA256()) or headers.get("Cache-Control") != "no-store"):
        raise RuntimeError("Picked-up leaf does not preserve key/identity or reach issuer expiry")
    await actor.request("PROPFIND", "/dav/", headers={"Depth": "0"}, expected=(207,))
    row = next(row for row in await asyncio.to_thread(operator.call, "devices") if row["id"] == actor.identity)
    if row["transition_leaves"] != 1:
        raise RuntimeError("Previous leaf was not retained during the transition")
    previous = actor.directory / "previous.crt"
    previous.write_text(held)
    previous.chmod(0o600)
    target = actor.directory / "device.crt"
    target.write_text(pickup["certificate"])
    target.chmod(0o600)
    await actor.close()
    await actor.open()
    await actor.request("PROPFIND", "/dav/", headers={"Depth": "0"}, expected=(207,))
    context = ssl.create_default_context(cafile=str(stack.local / "operator/issuer.crt"))
    context.load_cert_chain(previous, actor.directory / "device.key")
    async with aiohttp.ClientSession(connector=aiohttp.TCPConnector(ssl=context), trust_env=False) as session:
        async with session.request("PROPFIND", stack.origin + "/dav/", headers={"Depth": "0"}, allow_redirects=False) as response:
            if response.status != 403:
                raise RuntimeError("Previous leaf stayed accepted after the device used its reissued leaf")
    print("PASS reissue to issuer expiry, pickup over the previous leaf, previous retired on first use of the new leaf", flush=True)


async def wait_activity(operator, predicate):
    start = time.monotonic()
    while time.monotonic() - start < 10:
        activity = await asyncio.to_thread(operator.call, "activity")
        if predicate(activity):
            return activity
        await asyncio.sleep(0.05)
    raise RuntimeError("Expected active fixture operation was not observed")


async def reopen(actors):
    for actor in actors:
        await actor.close()
        await actor.open()


async def share_hrefs(actor):
    body, _ = await actor.request("PROPFIND", "/dav/Shared/", headers={"Depth": "1"}, expected=(207,))
    return {node.text for node in ET.fromstring(body).iter("{DAV:}href")}


async def resolved_share_path(actor, before):
    created = await share_hrefs(actor) - before
    if len(created) != 1:
        raise RuntimeError("Recipient mount did not resolve one unique incoming share")
    target = created.pop()
    if not target.startswith(actor.stack.origin + "/dav/Shared/"):
        raise RuntimeError("Resolved share escaped incoming root")
    return target[len(actor.stack.origin):]


async def extended_proofs(stack, operator, actors, clients, folder, nonce):
    a, b = actors[:2]
    c = await pair(stack, operator, FIXTURE_USERS[0], clients / "alice-control")
    actors.append(c)
    await a.request("MKCOL", "/dav/" + folder, headers={"If-None-Match": "*"}, expected=(201,))
    # Shares are directories only (spec #26): the shared folder holds the proof file.
    shared = folder + "/shared-" + nonce
    await a.request("MKCOL", "/dav/" + shared, headers={"If-None-Match": "*"}, expected=(201,))
    source = shared + "/proof.txt"
    source_bytes = b"shared owner bytes\n"
    await a.request("PUT", "/dav/" + source, data=source_bytes, headers={"If-None-Match": "*"}, expected=(201,))
    collision = "Shared/shared-" + nonce
    b.extra_paths.append(collision + "/own.txt")
    await b.request("MKCOL", "/dav/" + collision, headers={"If-None-Match": "*"}, expected=(201,))
    await b.request("PUT", "/dav/" + collision + "/own.txt", data=b"recipient collision bytes\n", headers={"If-None-Match": "*"}, expected=(201,))
    try:
        await asyncio.to_thread(operator.call, "share", device_id=a.identity, path=source, recipient=FIXTURE_USERS[1])
    except RuntimeError:
        pass
    else:
        raise RuntimeError("A file share was accepted")
    before = await share_hrefs(b)
    share = await asyncio.to_thread(operator.call, "share", device_id=a.identity, path=shared, recipient=FIXTURE_USERS[1])
    mount = await resolved_share_path(b, before)
    if not mount.startswith("/dav/Shared/") or mount.rstrip("/") == "/dav/" + collision:
        raise RuntimeError("Incoming share root/collision handling failed")
    target = mount.rstrip("/") + "/proof.txt"
    if (await b.request("GET", target))[0] != source_bytes:
        raise RuntimeError("Root-confined incoming share bytes differ")
    await b.request("PUT", target, data=b"must not overwrite", headers={"If-Match": await b.etag(target[len('/dav/'):])}, expected=(403,))
    for actor in actors:
        await actor.close()
    await asyncio.to_thread(stack.compose, "down", "--timeout", "30")
    await asyncio.to_thread(stack.up)
    await reopen(actors)
    if (await b.request("GET", target))[0] != source_bytes:
        raise RuntimeError("Share/certificate/account state did not survive recreation")
    await asyncio.to_thread(operator.call, "unshare", device_id=c.identity, share_id=share["share_id"])
    await b.request("GET", target, expected=(404,))
    if (await b.request("GET", "/dav/" + collision + "/own.txt"))[0] != b"recipient collision bytes\n":
        raise RuntimeError("Sharing overwrote recipient collision bytes")
    await b.request("DELETE", "/dav/" + collision + "/own.txt", headers={"If-Match": await b.etag(collision + "/own.txt")}, expected=(204,))
    await b.request("DELETE", "/dav/" + collision, headers={"If-Match": await b.etag(collision)}, expected=(204,))
    print("PASS confined incoming share/collision, read-only denial, certificate/share persistence and unshare", flush=True)

    before = await share_hrefs(b)
    share = await asyncio.to_thread(operator.call, "share", device_id=c.identity, path=shared, recipient=FIXTURE_USERS[1], rights="write")
    alias = (await resolved_share_path(b, before)).rstrip("/") + "/proof.txt"
    baseline = await a.etag(source)
    async def race(actor, path, payload):
        async with actor.session.put(actor.stack.origin + path, data=payload, headers={"If-Match": baseline}) as response:
            await response.read()
            return response.status
    outcomes = await asyncio.gather(race(a, "/dav/" + source, b"owner winner\n"), race(b, alias, b"recipient winner\n"))
    if sorted(outcomes) != [204, 412] or (await a.request("GET", "/dav/" + source))[0] != (await b.request("GET", alias))[0]:
        raise RuntimeError("Shared aliases bypassed global compare-and-write ordering")
    await asyncio.to_thread(operator.call, "unshare", device_id=c.identity, share_id=share["share_id"])
    print("PASS concurrent owner/recipient alias writes yield one commit and one stale-version rejection", flush=True)

    queued = folder + "/queued"
    await c.request("MKCOL", "/dav/" + queued, headers={"If-None-Match": "*"}, expected=(201,))
    old_folder = await c.etag(queued)
    released = asyncio.Event()
    payload = b"queue fixture" * 4096
    async def staged_input():
        yield payload[:16384]
        await released.wait()
        yield payload[16384:]
    upload = asyncio.create_task(c.request("PUT", "/dav/" + queued + "/child.bin", data=staged_input(),
                                          headers={"If-None-Match": "*", "Content-Length": str(len(payload))}, expected=(201,)))
    await wait_activity(operator, lambda state: state["mutation_lock"] and state["mutations"] >= 1)
    deletion = asyncio.create_task(a.request("DELETE", "/dav/" + queued, headers={"If-Match": old_folder}, expected=(412,)))
    await asyncio.sleep(0.15)
    if deletion.done():
        raise RuntimeError("Folder deletion did not queue behind staged child upload")
    released.set()
    await upload
    await deletion
    if (await c.request("GET", "/dav/" + queued + "/child.bin"))[0] != payload:
        raise RuntimeError("Queued stale folder deletion lost uploaded bytes")
    print("PASS slow child upload holds ordering; queued stale folder deletion preserves completed child bytes", flush=True)

    large = folder + "/download.bin"
    large_bytes = b"bounded transfer fixture\n" * 65536
    await c.request("PUT", "/dav/" + large, data=large_bytes, headers={"If-None-Match": "*"}, expected=(201,))
    upload_path = folder + "/cancel-upload.bin"
    await c.request("PUT", "/dav/" + upload_path, data=b"old clean bytes\n", headers={"If-None-Match": "*"}, expected=(201,))
    victim = await pair(stack, operator, FIXTURE_USERS[0], clients / "upload-victim")
    actors.append(victim)
    stack.environment["ANJ_DEV_STREAM_DELAY"] = "0.02"
    await asyncio.to_thread(stack.compose, "up", "--detach", "--no-deps", "--wait", "--wait-timeout", "90", "access")
    await reopen(actors)
    try:
        started = asyncio.Event()
        async def downloading():
            received = 0
            try:
                async with a.session.get(stack.origin + "/dav/" + large) as response:
                    if response.status != 200:
                        raise RuntimeError("Download victim was not initially authorized")
                    async for chunk in response.content.iter_chunked(16384):
                        received += len(chunk)
                        started.set()
            except aiohttp.ClientError:
                return received, time.monotonic()
            raise RuntimeError("Throttled download finished instead of being cut off")
        download = asyncio.create_task(downloading())
        await asyncio.wait_for(started.wait(), 10)
        await wait_activity(operator, lambda state: state["active"].get(a.identity, 0) > 0)
        revoked_at = time.monotonic()
        await asyncio.to_thread(operator.revoke, a.identity)
        received, stopped = await asyncio.wait_for(download, 30)
        if stopped - revoked_at > 30 or received >= len(large_bytes):
            raise RuntimeError("Active download exceeded revocation cutoff")
        await a.request("GET", "/dav/" + source, expected=(403,))
        if not (await c.request("GET", "/dav/" + source))[0]:
            raise RuntimeError("Other same-account device lost continuity")
        print(f"PASS active download cutoff {stopped-revoked_at:.3f}s; certificate reuse denied, other device continues", flush=True)
        replacement = await pair(stack, operator, FIXTURE_USERS[0], clients / "retained-key-replacement", retained=a)
        actors.append(replacement)
        await a.request("GET", "/dav/" + source, expected=(403,))
        if replacement.identity == a.identity or (await replacement.request("GET", "/dav/" + source))[0] != (await c.request("GET", "/dav/" + source))[0]:
            raise RuntimeError("Same-key re-pair did not bind a distinct usable certificate")
        print("PASS retained-key re-pair uses a new leaf/device; prior still-valid revoked leaf remains denied", flush=True)

        blocked = asyncio.Event()
        async def incomplete_upload():
            yield b"pending bytes" * 1024
            await blocked.wait()
            yield b"never completed"
        baseline = await c.etag(upload_path)
        upload = asyncio.create_task(victim.request("PUT", "/dav/" + upload_path, data=incomplete_upload(),
                                                   headers={"If-Match": baseline, "Content-Length": str(4 * 1024 * 1024)}))
        await wait_activity(operator, lambda state: state["active"].get(victim.identity, 0) > 0 and state["mutation_lock"])
        revoked_at = time.monotonic()
        await asyncio.to_thread(operator.revoke, victim.identity)
        try:
            await asyncio.wait_for(upload, 30)
        except (aiohttp.ClientError, RuntimeError):
            stopped = time.monotonic()
        else:
            raise RuntimeError("Revoked incomplete upload returned success")
        finally:
            blocked.set()
        if stopped - revoked_at > 30 or (await c.request("GET", "/dav/" + upload_path))[0] != b"old clean bytes\n":
            raise RuntimeError("Revoked staged upload changed remote bytes or exceeded cutoff")
        await victim.request("GET", "/dav/" + source, expected=(403,))
        await wait_activity(operator, lambda state: state["mutations"] == 0 and not state["mutation_lock"])
        print(f"PASS staged upload cutoff {stopped-revoked_at:.3f}s; old remote bytes retained and new admission denied", flush=True)
    finally:
        stack.environment["ANJ_DEV_STREAM_DELAY"] = "0"
        await asyncio.to_thread(stack.compose, "up", "--detach", "--no-deps", "--wait", "--wait-timeout", "90", "access")
        await reopen(actors)

    # Inject a durable in-flight intent through the application's own registry API, then kill
    # the actual worker. Network-backed unit coverage separately withholds a backend receipt.
    code = "from access.registry import Registry;Registry('/var/lib/anj').mutation_begin('fixture-intent','fixture-content-uncertainty')"
    await asyncio.to_thread(stack.compose, "exec", "-T", "access", "python", "-c", code)
    await asyncio.to_thread(stack.run, ["docker", "kill", "--signal", "KILL", stack.project + "-access-1"])
    await asyncio.to_thread(stack.compose, "up", "--detach", "--no-deps", "--wait", "--wait-timeout", "90", "access")
    await reopen(actors)
    await c.request("PUT", "/dav/" + folder + "/fenced.bin", data=b"must not dispatch", headers={"If-None-Match": "*"}, expected=(503,))
    if not (await c.request("GET", "/dav/" + source))[0]:
        raise RuntimeError("Read access did not survive a content write fence")
    await asyncio.to_thread(operator.recover_writes)
    await c.request("PUT", "/dav/" + folder + "/fenced.bin", data=b"recovered content\n", headers={"If-None-Match": "*"}, expected=(201,))
    print("PASS actual worker crash preserves injected write fence; scoped backend/database quiescence restores writes", flush=True)

    share = await asyncio.to_thread(operator.call, "share", device_id=c.identity, path=shared, recipient=FIXTURE_USERS[1])
    intent = json.dumps({"kind": "share", "path": "/anj-cloud/" + shared, "recipient": FIXTURE_USERS[1], "permissions": 1, "prior_ids": []})
    code = "import json,sys;from access.registry import Registry;r=json.load(sys.stdin);Registry('/var/lib/anj').mutation_begin(r['device'],r['intent'])"
    await asyncio.to_thread(stack.compose, "exec", "-T", "access", "python", "-c", code,
                            data=json.dumps({"device": c.identity, "intent": intent}))
    try:
        await asyncio.to_thread(operator.recover_writes)
    except RuntimeError:
        pass
    else:
        raise RuntimeError("Generic recovery cleared an unresolved sharing intent")
    records = await asyncio.to_thread(operator.inspect_shares, FIXTURE_USERS[0])
    if not any(str(row["id"]) == share["share_id"] and row["path"] == "/anj-cloud/" + shared for row in records):
        raise RuntimeError("Local owner/root inspection could not identify exact sharing side effect")
    await asyncio.to_thread(operator.inspect_shares, FIXTURE_USERS[0], share["share_id"])
    await asyncio.to_thread(operator.recover_writes, True)
    await c.request("GET", "/dav/" + source)
    print("PASS sharing fence refuses generic clear; scoped inspection, exact repair and confirmed recovery complete", flush=True)


async def scenario(stack):
    stack.check()
    stack.accounts()
    operator = Operator(stack)
    nonce = secrets.token_hex(6)
    clients = stack.local / "operator/clients" / ("fixture-" + nonce)
    private_directory(clients)
    actors = []
    folder = "Documents/anj-gateway-fixture-" + nonce
    try:
        a = await pair(stack, operator, FIXTURE_USERS[0], clients / "alice")
        actors.append(a)
        b = await pair(stack, operator, FIXTURE_USERS[1], clients / "bob")
        actors.append(b)
        print("PASS real no-cert TLS enrollment, QR/manual retries, fingerprint approval, issuer-lifetime fixed-profile certificates", flush=True)
        await qualify_reissue(stack, operator, a)
        for actor in actors:
            await actor.request("MKCOL", "/dav/" + folder, headers={"If-None-Match": "*"}, expected=(201,))
        payload = b"real paired synthetic gateway bytes\n" * 2048
        path = folder + "/private.txt"
        await a.request("PUT", "/dav/" + path, data=payload, headers={"If-None-Match": "*"}, expected=(201,))
        body, headers = await a.request("GET", "/dav/" + path)
        if body != payload or not headers.get("Etag", headers.get("ETag")):
            raise RuntimeError("Gateway byte roundtrip/ETag differs")
        ranged, _ = await a.request("GET", "/dav/" + path, headers={"Range": "bytes=3-12"}, expected=(206,))
        if ranged != payload[3:13]:
            raise RuntimeError("Gateway range bytes differ")
        await b.request("GET", "/dav/" + path, expected=(404,))
        listing, _ = await a.request("PROPFIND", "/dav/" + folder + "/", headers={"Depth": "1"}, expected=(207,))
        for node in ET.fromstring(listing).iter("{DAV:}href"):
            if not node.text.startswith(stack.origin + "/dav/"):
                raise RuntimeError("DAV reference escaped gateway namespace")
        for bad in ("/dav/%2e%2e/private", "/dav/a%2fb", "/dav/a//b"):
            await a.request("GET", bad, expected=(400,))
        # Double encoding is literal filename data ("%2e%2e" is a valid name since the DAV filename
        # work): never a traversal, simply absent here.
        await a.request("GET", "/dav/%252e%252e/private", expected=(404,))
        await a.request("COPY", "/dav/" + path, expected=(405,))
        await a.request("GET", "/remote.php/dav/files/" + FIXTURE_USERS[0] + "/anj-cloud/" + path, expected=(404,))
        print("PASS confined DAV byte/range/ETag roundtrip, account isolation, URI rewriting and unsupported-route rejection", flush=True)
        before = await a.etag(folder + "/")
        file_etag = await a.etag(path)
        await a.request("PUT", "/dav/" + path, data=b"changed fixture\n", headers={"If-Match": file_etag}, expected=(204,))
        after = await a.etag(folder + "/")
        if before == after:
            raise RuntimeError("Descendant changes did not update collection ETag; folder DELETE must remain disabled")
        await a.request("DELETE", "/dav/" + folder, headers={"If-Match": before}, expected=(412,))
        await a.request("DELETE", "/dav/" + folder, headers={"If-Match": after}, expected=(204,))
        print("PASS descendant collection ETag changes; stale folder DELETE preserves bytes and current guarded DELETE succeeds", flush=True)
        await extended_proofs(stack, operator, actors, clients, folder, nonce)
    finally:
        cleanup_error = None
        try:
            activity = await asyncio.to_thread(operator.call, "activity")
            if activity["write_fence"] != "clear":
                await asyncio.to_thread(operator.recover_writes)
                await reopen(actors)
            states = {row["id"]: row["state"] for row in await asyncio.to_thread(operator.call, "devices")}
            for uid in FIXTURE_USERS:
                current = next((actor for actor in actors if actor.invitation["uid"] == uid and states.get(actor.identity) == "active"), None)
                if current:
                    paths = {folder, *(path for actor in actors if actor.invitation["uid"] == uid for path in actor.extra_paths)}
                    for path in paths:
                        body, _ = await current.request("PROPFIND", "/dav/" + path, headers={"Depth": "0"}, expected=(207, 404))
                        if body:
                            etag = ET.fromstring(body).findtext(".//{DAV:}getetag")
                            await current.request("DELETE", "/dav/" + path, headers={"If-Match": etag}, expected=(204,))
        except Exception as error:
            cleanup_error = error
        finally:
            for actor in actors:
                await actor.close()
                try:
                    await asyncio.to_thread(operator.revoke, actor.identity)
                except Exception as error:
                    cleanup_error = error
            await asyncio.to_thread(operator.reconcile)
        if cleanup_error:
            raise RuntimeError("Synthetic fixture cleanup incomplete; no credential details logged") from None
        print("Fixture devices revoked; operator reconciliation completed (client keys remain in private ignored fixture paths)", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", default="anj-cloud-dev")
    parser.add_argument("--port", type=int, default=os.environ.get("SC_DEV_PORT", "8834"))
    args = parser.parse_args()
    try:
        asyncio.run(scenario(Stack(args.project, args.port)))
    except Exception as error:
        if isinstance(error, RuntimeError):
            print("ERROR " + str(error), file=sys.stderr)
        else:
            print("ERROR gateway fixture " + type(error).__name__ + "; diagnostic values withheld", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
