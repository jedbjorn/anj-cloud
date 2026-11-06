"""Local-only operator tooling. Docker authority and issuer key stay on the host."""

import argparse
import base64
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import sys

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization

from deploy.dev import DEV_PROFILE, Stack, private_directory, secret_file
from deploy.token_spike import token_from_output, token_rows
from deploy.token_spike import Client


UUID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
from services.access.naming import NEW_ACCOUNT_UID as ACCOUNT, NEW_UID_TEXT as UID_TEXT, RESERVED_UIDS, clean_display_name  # noqa: E402
from services.access.release_manifest import TARGETS, ManifestError, manifest_from  # noqa: E402
from deploy.vm.paths import BACKUP_IN_PROGRESS as _BACKUP, RESTORE_IN_PROGRESS as _RESTORE  # noqa: E402

# Marker file names under the state root's run/ (spec #22; deploy/vm/paths.py).
BACKUP_IN_PROGRESS, RESTORE_IN_PROGRESS = _BACKUP.name, _RESTORE.name


def add_years(moment, years):
    try:
        return moment.replace(year=moment.year + years)
    except ValueError:  # 29 February
        return moment.replace(year=moment.year + years, day=28)


def key_fingerprint(key):
    return hashlib.sha256(key.public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)).hexdigest()


def atomic_json(path, data):
    temporary = path.with_suffix(".tmp")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "w") as stream:
        json.dump(data, stream)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)
    fd = os.open(path.parent, os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


class Operator:
    def __init__(self, stack):
        self.stack = stack
        self.profile = getattr(stack, "profile", None) or DEV_PROFILE
        self.directory = stack.local / "operator"
        self.journals = self.directory / "journals"

    @contextmanager
    def lock(self):
        for directory in (self.directory, self.journals):
            private_directory(directory)
        fd = os.open(self.directory / "operation.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
            yield
        finally:
            os.close(fd)

    def init_trust(self):
        """Create the issuer and server certificate once, from the stack's trust profile.

        Dev: CN "anj-cloud Dev issuer", one year; server localhost/127.0.0.1. Production
        (deploy/prod.py): CN "anj-cloud Household issuer", ten years; server SAN the host only.
        """
        profile = self.profile
        with self.lock():
            os.umask(0o077)
            issuer = self.directory / "issuer.crt"
            key = self.directory / "issuer.key"
            if issuer.exists() != key.exists():
                raise RuntimeError("Incomplete issuer; restore the operator's matching key/certificate")
            if not issuer.exists():
                validity = (["-days", str(profile["issuer_days"])] if "issuer_years" not in profile else
                            ["-not_after", add_years(datetime.now(timezone.utc), profile["issuer_years"]).strftime("%Y%m%d%H%M%SZ")])
                self.stack.run(["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256",
                                "-noenc", *validity, "-subj", "/CN=" + profile["issuer_cn"], "-keyout", str(key),
                                "-out", str(issuer), "-addext", "basicConstraints=critical,CA:TRUE,pathlen:0",
                                "-addext", "keyUsage=critical,keyCertSign,cRLSign"])
            if x509.load_pem_x509_certificate(issuer.read_bytes()).not_valid_after_utc <= datetime.now(timezone.utc):
                raise RuntimeError("Issuer expired; explicit trust replacement and re-pairing required")
            server_key = self.directory / "server.key"
            server_certificate = self.directory / "server.crt"
            if not server_certificate.exists():
                csr = self.directory / "server.csr"
                self.stack.run(["openssl", "req", "-new", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:P-256",
                                "-noenc", "-subj", "/CN=" + profile["server_cn"], "-keyout", str(server_key), "-out", str(csr)])
                self.sign(csr, server_certificate, "server", "serverAuth", days=profile["server_days"])
            for path in self.directory.iterdir():
                if path.is_file():
                    path.chmod(0o600)
        return {"trust_anchor": str(issuer), "origin": self.stack.origin,
                "instruction": "Provision this local trust anchor through an operator-controlled channel before enrollment"}

    def issuer(self):
        return x509.load_pem_x509_certificate((self.directory / "issuer.crt").read_bytes())

    def sign(self, csr, target, identity, usage="clientAuth", days=None):
        # Client leaves live until issuer expiry (decision #44); the server certificate is bounded.
        issuer = self.issuer()
        end = issuer.not_valid_after_utc if days is None else min(datetime.now(timezone.utc) + timedelta(days=days), issuer.not_valid_after_utc)
        if end <= datetime.now(timezone.utc):
            raise RuntimeError("Issuer expired; issuer rollover is required before signing")
        extension = self.directory / "leaf.ext"
        extension.write_text("[leaf]\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\n"
                             + "extendedKeyUsage=" + usage + "\n"
                             + ("subjectAltName=" + ",".join(self.profile["server_san"]) + "\n" if usage == "serverAuth" else ""))
        extension.chmod(0o600)
        self.stack.run(["openssl", "x509", "-req", "-in", str(csr), "-CA", str(self.directory / "issuer.crt"),
                        "-CAkey", str(self.directory / "issuer.key"), "-set_serial", "0x" + secrets.token_hex(16),
                        "-not_after", end.strftime("%Y%m%d%H%M%SZ"), "-subj", "/CN=" + identity,
                        "-extfile", str(extension), "-extensions", "leaf", "-out", str(target)])
        target.chmod(0o600)

    def call(self, action, **data):
        try:
            output = self.stack.compose("exec", "-T", "access", "python", "-m", "access.admin",
                                        data=json.dumps({"action": action, **data}))
        except RuntimeError as error:
            # Only the private socket client's curated error envelope may leave this boundary.
            self.curated(error)
        return json.loads(output)

    def release_publish(self, target, package, manifest_path):
        """Publish a client package for `target` (spec #28 G1). The package and manifest are checked
        here first, then streamed through the private socket, where the gateway checks them again
        and swaps the release in atomically. Nothing is signed here or in the gateway."""
        if target not in TARGETS:
            raise RuntimeError("Unknown release target; known: " + ", ".join(sorted(TARGETS)))
        try:
            manifest = manifest_from(json.loads(Path(manifest_path).read_text()), target)
        except OSError:
            raise RuntimeError("Cannot read the release manifest file") from None
        except ManifestError as error:
            raise RuntimeError(str(error)) from None
        except ValueError:
            raise RuntimeError("Release manifest is not JSON") from None
        package = Path(package)
        if package.is_symlink() or not package.is_file():
            raise RuntimeError("Release package must be a regular file")
        digest, size = hashlib.sha256(), 0
        with package.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1 << 20), b""):
                digest.update(chunk)
                size += len(chunk)
        if size != manifest["size"]:
            raise RuntimeError(f"Package is {size} bytes; the manifest says {manifest['size']}")
        if digest.hexdigest() != manifest["sha256"]:
            raise RuntimeError("Package SHA-256 differs from the manifest")
        with self.lock():
            self.refuse_during_backup()
            current = (self.call("releases").get(target) or {}).get("current")
            if current and manifest["version_code"] <= current["version_code"]:
                raise RuntimeError(f"version_code must be greater than the current release's ({current['version_code']})")
            with package.open("rb") as stream:
                try:
                    output = self.stack.compose_stream("exec", "-T", "access", "python", "-m", "access.release_publish",
                                                       target, json.dumps(manifest, separators=(",", ":")), source=stream)
                except RuntimeError as error:
                    self.curated(error)
            result = json.loads(output)
            if result.get("prune") == "failed":
                # Published and served; only the removal of older releases failed. The next publish
                # keeps its own two and removes the rest, so this retries itself.
                message = (f"{target} release {manifest['version_code']} is published and served, but older "
                           "releases could not be removed; the next publish retries")
                alert = getattr(self.stack, "alert", None)
                result["alert"] = alert("release-prune-failed", "anj-cloud release cleanup failed", message,
                                        priority="default") if callable(alert) else "none"
                print("WARNING " + message, file=sys.stderr)
            return result

    def refuse_during_backup(self):
        """No publish while a spec #22 backup or restore holds its marker: the access volume is read
        live, so a snapshot could otherwise hold a manifest without its package."""
        for name, what in ((BACKUP_IN_PROGRESS, "A backup"), (RESTORE_IN_PROGRESS, "A restore")):
            marker = self.stack.local / "run" / name
            if marker.exists() or marker.is_symlink():
                try:
                    deadline = json.loads(marker.read_text()).get("deadline")
                except (OSError, ValueError, AttributeError):
                    deadline = None
                raise RuntimeError(f"{what} is running" + (f" (deadline {deadline})" if deadline else "")
                                   + "; nothing was published. Retry after it finishes.")

    def curated(self, error):
        """Re-raise a failed private-socket call with only its curated error envelope."""
        try:
            detail = json.loads(error.captured_stdout)
        except (AttributeError, ValueError):
            raise error from None
        if isinstance(detail, dict) and set(detail) == {"error"} and isinstance(detail["error"], str):
            raise RuntimeError("Operator action rejected: " + detail["error"]) from None
        raise error from None

    def delete_named_tokens(self, uid, name, keep=None):
        for row in token_rows(self.stack, uid):
            if row["name"] == name and str(row["id"]) != str(keep):
                self.stack.occ("user:auth-tokens:delete", "--", uid, str(row["id"]))

    def reconcile(self):
        with self.lock():
            self._cleanup_reconciliation_token()
            results = self._reconcile_reissues()
            for path in self.journals.glob("*.json"):
                journal = json.loads(path.read_text())
                row = self.call("inspect", pairing_id=journal["pairing_id"])
                if row["state"] == "approved":
                    devices = self.call("devices")
                    current = next(device for device in devices if device["id"] == row["device"])
                    if current["state"] == "active":
                        self.delete_named_tokens(row["uid"], journal["name"], keep=current["token_id"])
                        atomic_json(path, {"pairing_id": row["id"], "name": journal["name"], "state": "active", "device": row["device"]})
                        results.append({"pairing_id": row["id"], "state": "active"})
                        continue
                self.delete_named_tokens(row["uid"], journal["name"])
                atomic_json(path, {"pairing_id": row["id"], "name": journal["name"], "state": "cleaned", "device": row["device"]})
                results.append({"pairing_id": row["id"], "state": "cleaned"})
            return results

    def _reconcile_reissues(self):
        # A signed but uncommitted leaf is inert: the gateway admits only committed leaves.
        results = []
        directory = self.journals / "reissue"
        if not directory.is_dir():
            return results
        devices = None
        for path in directory.glob("*.json"):
            journal = json.loads(path.read_text())
            if journal.get("state") not in ("begin", "signed"):
                continue
            devices = devices if devices is not None else self.call("devices")
            current = next((row for row in devices if row["id"] == journal["device"]), None)
            committed = bool(current and journal.get("certificate_id") and current.get("certificate_id") == journal["certificate_id"])
            journal["state"] = "active" if committed else "abandoned"
            atomic_json(path, journal)
            results.append({"device_id": journal["device"], "reissue": journal["state"]})
        return results

    def reissue(self, identity, force=False):
        """Sign a new leaf for an active device's existing key and commit it via the private socket."""
        if not UUID.fullmatch(identity):
            raise RuntimeError("Reissue requires an exact device ID")
        with self.lock():
            return self._reissue(identity, force)

    def reissue_active(self, force=False):
        with self.lock():
            results = []
            now = datetime.now(timezone.utc).timestamp()
            for device in self.call("devices"):
                if device["state"] != "active":
                    continue
                if not device["expires"] or device["expires"] <= now:
                    results.append({"device_id": device["id"], "state": "skipped", "reason": "certificate expired; re-pair this device"})
                    continue
                try:
                    results.append(self._reissue(device["id"], force))
                except RuntimeError as error:
                    results.append({"device_id": device["id"], "state": "failed", "reason": str(error)})
            return results

    def _reissue(self, identity, force):
        target = self.call("reissue-begin", device_id=identity)
        device = target["device"]
        if device != identity or not UUID.fullmatch(device):
            raise RuntimeError("Reissue target identity changed")
        issuer = self.issuer()
        current = x509.load_pem_x509_certificate(target["certificate"].encode())
        if not force and current.not_valid_after_utc >= issuer.not_valid_after_utc:
            return {"device_id": device, "state": "current", "expires_at": target["expires"]}
        request = x509.load_pem_x509_csr(target["csr"].encode())
        if not request.is_signature_valid or key_fingerprint(request.public_key()) != target["fingerprint"]:
            raise RuntimeError("Stored enrollment request does not match the device key")
        directory = self.journals / "reissue"
        private_directory(directory)
        path = directory / (device + ".json")
        journal = {"device": device, "uid": target["uid"], "state": "begin", "previous_certificate_id": target["certificate_id"]}
        atomic_json(path, journal)
        csr = directory / (device + ".csr")
        certificate = directory / (device + ".crt")
        csr.write_text(target["csr"])
        csr.chmod(0o600)
        # Same subject device identity as approve; the CSR's own subject is never copied.
        self.sign(csr, certificate, device)
        pem = certificate.read_text()
        leaf = x509.load_pem_x509_certificate(pem.encode())
        if (key_fingerprint(leaf.public_key()) != target["fingerprint"] or leaf.subject != current.subject
                or leaf.not_valid_after_utc != issuer.not_valid_after_utc):
            raise RuntimeError("Signed leaf does not preserve the device key/identity or reach issuer expiry")
        journal.update(state="signed", certificate_id=leaf.fingerprint(hashes.SHA256()).hex())
        atomic_json(path, journal)
        try:
            result = self.call("reissue-commit", device_id=device, certificate=pem)
        except Exception as error:
            # The commit response can be lost after the registry committed. Check authority.
            try:
                row = next((row for row in self.call("devices") if row["id"] == device), None)
            except Exception:
                raise RuntimeError("Reissue outcome unknown; run reconcile. The device keeps its working certificate") from None
            if row and row.get("certificate_id") == journal["certificate_id"]:
                result = {"state": "reissued", "device_id": device, "expires_at": row["expires"], "certificate_id": journal["certificate_id"]}
            else:
                journal["state"] = "abandoned"
                atomic_json(path, journal)
                detail = str(error) if isinstance(error, RuntimeError) else type(error).__name__
                raise RuntimeError("Reissue did not commit; the device keeps its working certificate: " + detail) from None
        journal["state"] = "active"
        atomic_json(path, journal)
        return {"device_id": device, "state": result["state"], "expires_at": result["expires_at"], "certificate_id": result["certificate_id"]}

    def _cleanup_reconciliation_token(self):
        path = self.directory / "reconciliation-token.json"
        if path.exists():
            row = json.loads(path.read_text())
            self.delete_named_tokens(row["uid"], row["name"])
            path.unlink()

    def inspect_shares(self, uid, remove=None):
        """Fixed local Nextcloud inspection/repair; no arbitrary endpoint forwarding."""
        if remove is not None and not re.fullmatch(r"[0-9]+", str(remove)):
            raise RuntimeError("Repair requires an exact numeric share ID")
        with self.lock():
            self._cleanup_reconciliation_token()
            journal = self.directory / "reconciliation-token.json"
            name = "anj-reconciliation-" + secrets.token_hex(16)
            atomic_json(journal, {"uid": uid, "name": name})
            try:
                token = token_from_output(self.stack.occ("user:auth-tokens:add", "--no-interaction", "--name", name, "--", uid))
                actor = Client(self.stack, uid, token)
                actor.identity(uid)
                path = "/ocs/v2.php/apps/files_sharing/api/v1/shares" + ("/" + str(remove) if remove else "") + "?format=json"
                raw = actor.request("GET", path, headers={"OCS-APIRequest": "true"}, expected=(200, 404))
                result = json.loads(raw)["ocs"]
                if remove and result["meta"]["statuscode"] == 404:
                    self.call("share-cleanup-resolved", share_id=str(remove), owner_uid=uid)
                    return {"state": "already-absent", "share_id": str(remove)}
                if result["meta"]["statuscode"] not in (100, 200):
                    raise RuntimeError("Cannot inspect shares with the selected account")
                rows = result["data"] if isinstance(result["data"], list) else [result["data"]]
                rows = [row for row in rows if row.get("uid_owner") == uid and str(row.get("path", "")).startswith("/anj-cloud/")]
                if remove:
                    if len(rows) != 1 or str(rows[0]["id"]) != str(remove):
                        raise RuntimeError("Repair target does not match the enrolled owner/root")
                    deleted = json.loads(actor.request("DELETE", path, headers={"OCS-APIRequest": "true"}))["ocs"]["meta"]["statuscode"]
                    if deleted not in (100, 200):
                        raise RuntimeError("Exact share removal was not confirmed")
                    check = json.loads(actor.request("GET", path, headers={"OCS-APIRequest": "true"}, expected=(200, 404)))["ocs"]["meta"]["statuscode"]
                    if check != 404:
                        raise RuntimeError("Share absence was not confirmed")
                    self.call("share-cleanup-resolved", share_id=str(remove), owner_uid=uid)
                    return {"state": "removed-and-verified", "share_id": str(remove)}
                fields = ("id", "uid_owner", "share_with", "path", "file_target", "permissions")
                return [{key: row.get(key) for key in fields} for row in rows]
            finally:
                self._cleanup_reconciliation_token()

    @contextmanager
    def owner_token(self, uid):
        """A short-lived, uniquely named per-owner Nextcloud token for one gateway sharing call.

        Journaled like inspection's token (`reconcile` removes an interrupted one), deleted
        afterwards and verified absent. It is passed over the private socket and never stored.
        Call with the operator lock held.
        """
        self._cleanup_reconciliation_token()
        journal = self.directory / "reconciliation-token.json"
        name = "anj-share-" + secrets.token_hex(16)
        atomic_json(journal, {"uid": uid, "name": name})
        try:
            yield token_from_output(self.stack.occ("user:auth-tokens:add", "--no-interaction", "--name", name, "--", uid))
        finally:
            self._cleanup_reconciliation_token()
        if any(row["name"] == name for row in token_rows(self.stack, uid)):
            raise RuntimeError("Temporary owner token removal was not confirmed; run reconcile")

    def sharing(self, action, device_id=None, owner=None, **data):
        """One sharing action through the gateway's single-writer path (spec #26).

        The owner is an active device (`device_id`) or, for an owner with no paired device, an
        account (`owner`) acting through a temporary token (decision #80 (4)).
        """
        if (device_id is None) == (owner is None):
            raise RuntimeError("Name exactly one of DEVICE_ID or --owner")
        with self.lock():
            if device_id is not None:
                return self.call(action, device_id=device_id, **data)
            with self.owner_token(owner) as token:
                return self.call(action, owner_uid=owner, token=token, **data)

    def account_set(self, uid, display_name=None, enabled=None):
        """Register a household account or change its display name and enabled state.

        Disable (decision #79 (b)): the gateway records where recipients mount the account's
        shares from one read of the owner's own share list (a temporary owner token minted here),
        then refuses its devices (403, no certificate revoked); only then is the Nextcloud account
        disabled. A disabled recipient does not block this. When the owner's list cannot be read
        the gateway refuses and nothing changes (retry later); `occ user:disable` is never reached. Enable reverses
        the order. Revoke stays the separate, permanent action.
        """
        with self.lock():
            nextcloud = None
            if enabled is True:
                self.stack.occ("user:enable", "--", uid)
                nextcloud = "enabled"
            data = {"uid": uid, **({"display_name": display_name} if display_name is not None else {}),
                    **({"enabled": enabled} if enabled is not None else {})}
            current = next((row for row in self.call("accounts") if row["uid"] == uid), None)
            if enabled is False and (current is None or current["enabled"]):
                # The gateway records recipients' mounts from the owner's own share list, read with
                # a temporary owner token (the owner may have no paired device).
                with self.owner_token(uid) as token:
                    result = self.call("account-set", **data, token=token)
            else:
                result = self.call("account-set", **data)
            if enabled is False:
                if result.get("mounts_recorded") is False:
                    raise RuntimeError("Recipients' mounts were not recorded; Nextcloud account left enabled. Retry the disable")
                self.stack.occ("user:disable", "--", uid)
                nextcloud = "disabled"
            return {**result, "nextcloud": nextcloud}

    def approve(self, identity, fingerprint):
        if not re.fullmatch(r"[a-f0-9]{64}", fingerprint):
            raise RuntimeError("Approval requires the full displayed lowercase SHA256 fingerprint")
        with self.lock():
            row = self.call("begin", pairing_id=identity, fingerprint=fingerprint)
            if row.get("already_active"):
                return {"state": "active", "device_id": row["device"]}
            # All external resources have a stable identity before any external creation.
            name = "anj-device-" + row["device"]
            path = self.journals / (row["device"] + ".json")
            journal = {"pairing_id": identity, "device": row["device"], "uid": row["uid"], "name": name, "state": "begin"}
            # A prior uncertain issuance is not recoverable from Nextcloud's token-list output.
            # Delete every exact-name orphan before minting a replacement.
            self.delete_named_tokens(row["uid"], name)
            atomic_json(path, journal)
            try:
                output = self.stack.occ("user:auth-tokens:add", "--no-interaction", "--name", name, "--", row["uid"])
                token = token_from_output(output)
                tokens = [item for item in token_rows(self.stack, row["uid"]) if item["name"] == name]
                if len(tokens) != 1:
                    raise RuntimeError("Provisioning token identity is uncertain; reconcile before retry")
                journal.update(state="minted", token=token, token_id=str(tokens[0]["id"]))
                atomic_json(path, journal)
                csr = self.journals / (row["device"] + ".csr")
                certificate = self.journals / (row["device"] + ".crt")
                csr.write_text(row["csr"])
                csr.chmod(0o600)
                self.sign(csr, certificate, row["device"])
                journal.update(state="signed", certificate=certificate.read_text())
                atomic_json(path, journal)
                result = self.call("activate", pairing_id=identity, fingerprint=fingerprint, token=token,
                                   token_id=journal["token_id"], certificate=journal["certificate"])
                atomic_json(path, {"pairing_id": identity, "name": name, "state": "active", "device": row["device"]})
                return result
            except Exception as error:
                # The activate response can be lost after a commit. Never assume no side effect.
                current = self.call("inspect", pairing_id=identity)
                if current["state"] == "approved":
                    atomic_json(path, {"pairing_id": identity, "name": name, "state": "active", "device": row["device"]})
                    return {"state": "active", "device_id": row["device"]}
                self.delete_named_tokens(row["uid"], name)
                atomic_json(path, {"pairing_id": identity, "name": name, "state": "cleaned", "device": row["device"]})
                detail = str(error) if isinstance(error, RuntimeError) else type(error).__name__
                raise RuntimeError("Approval did not activate; backend resources cleaned: " + detail) from None

    def revoke(self, identity):
        with self.lock():
            result = self.call("revoke", device_id=identity)
            # Gateway state is already disabled and its transfers aborted, even if backend cleanup fails.
            if result["token_id"]:
                if any(str(row["id"]) == str(result["token_id"]) for row in token_rows(self.stack, result["uid"])):
                    self.stack.occ("user:auth-tokens:delete", "--", result["uid"], str(result["token_id"]))
            return {"state": "revoked", "device_id": identity}

    def user_add(self, uid, display_name=None):
        """Create one Nextcloud account with a random password kept only in secrets/<uid>.

        The password is never printed or logged; devices use app tokens. The operator reads the
        file on the host only for account recovery.
        """
        # The registry's one rule (decision #103): a household account can only have such an id.
        if not isinstance(uid, str) or not ACCOUNT.fullmatch(uid) or uid in RESERVED_UIDS \
                or uid.startswith("anj-fixture-") and self.profile.get("production"):
            raise RuntimeError(UID_TEXT + "; reserved ids and fixture accounts in production are refused")
        if display_name is not None:
            display_name = clean_display_name(display_name)
            if display_name is None:
                raise RuntimeError("Display name must be 1-64 printable characters")
        with self.lock():
            existing = json.loads(self.stack.occ("user:list", "--output=json"))
            if uid in existing:
                return {"uid": uid, "state": "exists"}
            private_directory(self.stack.secret_dir)
            path = self.stack.secret_dir / uid
            secret_file(path)
            password = path.read_text().strip()
            script = 'read -r OC_PASS; export OC_PASS; exec php occ user:add --password-from-env --display-name="$2" -- "$1"'
            self.stack.compose("exec", "-T", "--user", "www-data", "nextcloud", "sh", "-c", script,
                               "operator-account", uid, display_name or uid, data=password + "\n")
            if uid not in json.loads(self.stack.occ("user:list", "--output=json")):
                raise RuntimeError("Account creation was not confirmed")
            return {"uid": uid, "state": "created", "password_file": str(path)}

    def quiesce(self):
        with self.lock():
            self.call("maintenance")
            # Stop the owned content writers and DB so no uncertain PHP/SQL commit can outlive
            # quiescence. This never targets any other project or discards a volume.
            self.stack.compose("stop", "--timeout", "30", "cron", "nextcloud", "db")
            self.stack.compose("up", "--detach", "--wait", "--wait-timeout", "420", "db", "redis", "nextcloud", "cron")
            return self.call("fence")

    def recover_writes(self, sharing_reconciled=False):
        self.quiesce()
        with self.lock():
            return self.call("recover", sharing_reconciled=sharing_reconciled)


def stack_for(project, port, state_root=None):
    """Dev default deploy/.local/<project>, or an explicit production-profile state root."""
    if state_root is None:
        return Stack(project or "anj-cloud-dev", port)
    if not project:
        raise RuntimeError("--state-root requires an explicit --project")
    from deploy.prod import ProdStack
    return ProdStack(project, state_root).require_setup()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", help="Compose project (default anj-cloud-dev; required with --state-root)")
    parser.add_argument("--port", type=int, default=os.environ.get("SC_DEV_PORT", "8834"))
    parser.add_argument("--state-root", help="Operator and secrets root outside any git worktree (production, drills)")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("trust")
    user_add = sub.add_parser("user-add", help="Create a Nextcloud account; its password goes only to secrets/<uid>")
    user_add.add_argument("uid")
    user_add.add_argument("--display-name")
    invite = sub.add_parser("invite")
    invite.add_argument("uid")
    invite.add_argument("--rights", choices=("read", "write"), default="write")
    sub.add_parser("pending")
    sub.add_parser("devices")
    sub.add_parser("fence")
    sub.add_parser("quiesce")
    sub.add_parser("share-cleanups")
    approve = sub.add_parser("approve")
    approve.add_argument("pairing_id")
    approve.add_argument("--fingerprint", required=True)
    deny = sub.add_parser("deny")
    deny.add_argument("pairing_id")
    revoke = sub.add_parser("revoke")
    revoke.add_argument("device_id")
    reissue = sub.add_parser("reissue", help="Sign a leaf valid to issuer expiry for an active device's existing key")
    reissue.add_argument("device_id", nargs="?")
    reissue.add_argument("--active", action="store_true", help="Reissue every active device with an unexpired leaf")
    reissue.add_argument("--force", action="store_true", help="Reissue even when the current leaf already reaches issuer expiry")
    sub.add_parser("reconcile")
    recovery = sub.add_parser("recover-writes")
    recovery.add_argument("--confirm-sharing-reconciled", action="store_true")
    sub.add_parser("maintenance")
    inspect = sub.add_parser("inspect-shares")
    inspect.add_argument("uid")
    repair = sub.add_parser("repair-share")
    repair.add_argument("uid")
    repair.add_argument("share_id")
    sub.add_parser("accounts")
    account_set = sub.add_parser("account-set", help="Register a household account or change its display name/enabled state")
    account_set.add_argument("uid")
    account_set.add_argument("--display-name")
    state = account_set.add_mutually_exclusive_group()
    state.add_argument("--enable", dest="enabled", action="store_const", const=True)
    state.add_argument("--disable", dest="enabled", action="store_const", const=False)
    # Sharing (spec #26): directories only; read = View only (1), write = Can edit (15), never reshare.
    # The owner is DEVICE_ID (an active device) or --owner UID (temporary token, no paired device).
    for command, arguments in (("share", "[DEVICE_ID] PATH RECIPIENT"), ("share-update", "[DEVICE_ID] SHARE_ID"),
                               ("unshare", "[DEVICE_ID] SHARE_ID"), ("shares", "[DEVICE_ID]")):
        parser_ = sub.add_parser(command, usage="%(prog)s " + arguments + " [--owner UID]")
        parser_.add_argument("arguments", nargs="*")
        parser_.add_argument("--owner")
        if command in ("share", "share-update"):
            parser_.add_argument("--rights", choices=("read", "write"), default="write" if command == "share" else None,
                                 required=command == "share-update")
    sub.add_parser("share-fences")
    # Client update feed (spec #28 G1): the gateway stores what the operator publishes, never signs.
    release = sub.add_parser("release-publish", help="Publish a signed client package and its manifest for one target")
    release.add_argument("target")
    release.add_argument("package")
    release.add_argument("--manifest", required=True,
                         help="JSON file: version, version_code, size, sha256 and signer_sha256 (Android) or key_id and signature (desktop, deploy/release.py); optional target")
    sub.add_parser("releases", help="The served release and the version codes kept, per target")
    fence_clear = sub.add_parser("share-fence-clear", help="Clear one scoped share fence after checking the share")
    fence_clear.add_argument("scope")
    args = parser.parse_args()
    try:
        operator = Operator(stack_for(args.project, args.port, args.state_root))
    except (RuntimeError, ValueError) as error:
        print("ERROR " + str(error), file=sys.stderr)
        return 1
    try:
        if args.command == "trust":
            result = operator.init_trust()
        elif args.command == "user-add":
            result = operator.user_add(args.uid, args.display_name)
        elif args.command == "approve":
            result = operator.approve(args.pairing_id, args.fingerprint)
        elif args.command == "revoke":
            result = operator.revoke(args.device_id)
        elif args.command == "reissue":
            if bool(args.device_id) == args.active:
                raise RuntimeError("reissue requires exactly one of DEVICE_ID or --active")
            result = operator.reissue_active(args.force) if args.active else operator.reissue(args.device_id, args.force)
            failed = isinstance(result, list) and any(row["state"] == "failed" for row in result)
            if failed:
                print(json.dumps(result, indent=2))
                print("ERROR at least one device was not reissued; it keeps its working certificate", file=sys.stderr)
                return 1
        elif args.command == "reconcile":
            result = operator.reconcile()
        elif args.command == "recover-writes":
            result = operator.recover_writes(args.confirm_sharing_reconciled)
        elif args.command == "quiesce":
            result = operator.quiesce()
        elif args.command == "inspect-shares":
            result = operator.inspect_shares(args.uid)
        elif args.command == "repair-share":
            result = operator.inspect_shares(args.uid, args.share_id)
        elif args.command == "invite":
            result = operator.call("invite", uid=args.uid, rights=args.rights)
        elif args.command == "deny":
            result = operator.call("deny", pairing_id=args.pairing_id)
        elif args.command == "account-set":
            result = operator.account_set(args.uid, args.display_name, args.enabled)
        elif args.command in ("share", "share-update", "unshare", "shares"):
            names = {"share": ["path", "recipient"], "share-update": ["share_id"], "unshare": ["share_id"], "shares": []}[args.command]
            values = list(args.arguments)
            device = None if args.owner else (values.pop(0) if values else None)
            if len(values) != len(names):
                raise RuntimeError(args.command + " takes " + ("--owner UID " if args.owner else "DEVICE_ID ") + " ".join(n.upper() for n in names))
            data = dict(zip(names, values))
            if args.command in ("share", "share-update"):
                data["rights"] = args.rights
            result = operator.sharing(args.command, device_id=device, owner=args.owner, **data)
        elif args.command == "release-publish":
            result = operator.release_publish(args.target, args.package, args.manifest)
        elif args.command == "share-fence-clear":
            result = operator.call("share-fence-clear", scope=args.scope)
        else:
            result = operator.call(args.command)
        # invite deliberately displays its one-time code to the operator. Never pipe this into logs.
        print(json.dumps(result, indent=2))
    except Exception as error:
        if isinstance(error, RuntimeError):
            print("ERROR " + str(error), file=sys.stderr)
        else:
            print("ERROR operator action failed; private journal retained for reconciliation; diagnostic values withheld", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
