"""Single-worker, transactional device registry. No external side effect here."""

import hashlib
import hmac
import os
import re
from pathlib import Path
import secrets
import sqlite3
import time
import uuid

from .protocol import (CODE_NOT_VALID, LEGACY_SECRET_BYTES, PINNED_SECRET_BYTES, Rejection, code_from_bytes, normalize_code,
                       parse_csr, pinned_code)


# The one account ID and display-name rule (spec #27, decision #103), shared with the console
# backend and the operator CLI.
from .naming import ACCOUNT_UID, NAME_TEXT, RESERVED_UIDS, UID_TEXT, clean_device_name, clean_display_name  # noqa: E402


class AccountDisabled(Rejection):
    """The device is valid but its account is disabled: 403, never a revocation."""


class CodeReused(Rejection):
    """A pinned code already reserved to one device, presented with another key (spec #35 review M2).
    The requester gets the same generic refusal; the gateway alerts the admin once."""

    def __init__(self, invitation, label, fingerprint):
        super().__init__(CODE_NOT_VALID)
        self.invitation, self.label, self.fingerprint = invitation, label, fingerprint


class FetchCap(Rejection):
    """The account already holds the most unfinished fetch jobs it may (spec #42): 429."""

    def __init__(self, room):
        super().__init__("Too many downloads are waiting")
        self.room = max(0, room)


class LastAdmin(Rejection):
    """The change would leave no enabled admin (decision #87): 409 `last-admin`."""


LAST_ADMIN_TEXT = "Make another user an admin first."
# A device's reported name as stored with a pinned invitation (the alert shows at most 40).
DEVICE_LABEL_MAX = 80
AUDIT_KEEP = 10000
FIRST_ADMIN_IMPORT = "first_admin_import"


class Registry:
    def __init__(self, directory, clock=time.time):
        self.clock = clock
        directory = Path(directory)
        self.directory = directory
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        directory.chmod(0o700)
        pepper = directory / "invitation-hmac"
        if not pepper.exists():
            fd = os.open(pepper, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "wb") as stream:
                stream.write(secrets.token_bytes(32))
        self.pepper = pepper.read_bytes()
        self.db = sqlite3.connect(directory / "registry.sqlite")
        (directory / "registry.sqlite").chmod(0o600)
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA foreign_keys=ON")
        self.db.executescript("""
            CREATE TABLE IF NOT EXISTS invitations (
              id TEXT PRIMARY KEY, digest TEXT UNIQUE NOT NULL, uid TEXT NOT NULL,
              rights TEXT NOT NULL, expires REAL NOT NULL, state TEXT NOT NULL,
              csr TEXT, fingerprint TEXT, device TEXT UNIQUE);
            CREATE TABLE IF NOT EXISTS devices (
              id TEXT PRIMARY KEY, invitation TEXT UNIQUE NOT NULL REFERENCES invitations(id),
              uid TEXT NOT NULL, rights TEXT NOT NULL, fingerprint TEXT NOT NULL,
              state TEXT NOT NULL, certificate TEXT, expires REAL, token TEXT, token_id TEXT, certificate_id TEXT UNIQUE);
            CREATE TABLE IF NOT EXISTS mutation_fence (
              singleton INTEGER PRIMARY KEY CHECK(singleton=1), state TEXT NOT NULL, operation TEXT, device TEXT, path TEXT);
            INSERT OR IGNORE INTO mutation_fence(singleton,state) VALUES(1,'clear');
            CREATE TABLE IF NOT EXISTS share_cleanup (
              share_id TEXT PRIMARY KEY, device TEXT NOT NULL, state TEXT NOT NULL);
            -- Earlier leaves of an active device that remain acceptable while it picks up a
            -- reissued current leaf (devices.certificate_id). Same device, same key. No foreign
            -- key: the legacy devices-table migration renames that table.
            CREATE TABLE IF NOT EXISTS device_leaves (
              certificate_id TEXT PRIMARY KEY, device TEXT NOT NULL, certificate TEXT NOT NULL, expires REAL NOT NULL);
            -- When a file was first created through this gateway (decision #56): owner UID, the
            -- Nextcloud file ID and the gateway's own UTC clock. AUTOINCREMENT keeps `seq` strictly
            -- increasing and never reused, so it serves as the incremental read cursor.
            CREATE TABLE IF NOT EXISTS files_added (
              seq INTEGER PRIMARY KEY AUTOINCREMENT, uid TEXT NOT NULL, fileid INTEGER NOT NULL,
              added_at REAL NOT NULL, UNIQUE(uid, fileid));
            CREATE INDEX IF NOT EXISTS files_added_by_uid ON files_added(uid, seq);
            -- Household accounts (decision #78 N5): the household user list's only source, written
            -- only through the private operator socket. A disabled account's devices are refused
            -- (403) without revoking certificates; re-enabling restores them (decision #79 (b)).
            -- `admin` is the account's admin role (decision #87, spec #27), default false; the
            -- console work owns every API that reads or changes it.
            CREATE TABLE IF NOT EXISTS accounts (
              uid TEXT PRIMARY KEY, display_name TEXT NOT NULL, enabled INTEGER NOT NULL CHECK(enabled IN (0,1)),
              admin INTEGER NOT NULL DEFAULT 0 CHECK(admin IN (0,1)));
            -- A known failed share mutation fences only its own scope (decision #80 (1)): a share
            -- ID ("share:<id>") or an owner's directory ("path:<uid>:<path>"). The household-wide
            -- mutation_fence is kept for unknown outcomes only.
            CREATE TABLE IF NOT EXISTS share_fence (
              scope TEXT PRIMARY KEY, kind TEXT NOT NULL, owner_uid TEXT NOT NULL, share_id TEXT, created REAL NOT NULL);
            -- Where each recipient last saw an incoming share mounted. Nextcloud hides a disabled
            -- owner's shares entirely, so this is how the gateway can still name them as
            -- "owner unavailable" instead of letting a client infer deletions (decision #80 (2)).
            CREATE TABLE IF NOT EXISTS incoming_mounts (
              share_id TEXT NOT NULL, recipient_uid TEXT NOT NULL, owner_uid TEXT NOT NULL, path TEXT NOT NULL,
              permissions INTEGER NOT NULL, PRIMARY KEY(recipient_uid, share_id));
            -- New shares from an owner's top-level Documents, Music or Videos are mounted in the
            -- recipient's same folder instead of Shared/ (spec #34 P6, decision #149). One row per
            -- such share: `folder` is that top folder and the only place besides Shared/ the
            -- recipient's mount may be; `name` is the source folder's own name. `pending` until the
            -- gateway has moved the mount with a recipient device's credential, `placed` after,
            -- `kept` when it stays in Shared/ (no free name, or the move was refused).
            CREATE TABLE IF NOT EXISTS share_placement (
              share_id TEXT PRIMARY KEY, owner_uid TEXT NOT NULL, recipient_uid TEXT NOT NULL,
              folder TEXT NOT NULL CHECK(folder IN ('Documents','Music','Videos')), name TEXT NOT NULL,
              state TEXT NOT NULL CHECK(state IN ('pending','placed','kept')), created REAL NOT NULL,
              attempts INTEGER NOT NULL DEFAULT 0, next_try REAL NOT NULL DEFAULT 0);
            -- A recipient renamed a shared folder for everyone (decision #155): each other recipient's
            -- mount takes the new name at that recipient's next incoming read.
            CREATE TABLE IF NOT EXISTS mount_rename (
              share_id TEXT PRIMARY KEY, recipient_uid TEXT NOT NULL, owner_uid TEXT NOT NULL, name TEXT NOT NULL,
              created REAL NOT NULL);
            -- Runtime gateway settings changed through the operator socket (spec #27).
            CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            -- Household administration audit (spec #27): ids and result classes only, never paths,
            -- names of files, codes, fingerprints, tokens, certificates or bodies. Newest 10,000 kept.
            CREATE TABLE IF NOT EXISTS admin_audit (
              seq INTEGER PRIMARY KEY AUTOINCREMENT, time REAL NOT NULL, actor_uid TEXT, actor_device TEXT,
              action TEXT NOT NULL, target_uid TEXT, target_device TEXT, target_invitation TEXT, result TEXT NOT NULL);
            -- App tokens of revoked devices whose Nextcloud removal is not yet confirmed (spec #27).
            -- Nextcloud accounts user-add created whose household row did not follow (spec #27):
            -- Add user for the same id finishes them instead of refusing an existing account.
            CREATE TABLE IF NOT EXISTS account_cleanup (uid TEXT PRIMARY KEY, created REAL NOT NULL, display_name TEXT);
            -- Recovery CLI audit entries already imported, by entry id (idempotent import).
            CREATE TABLE IF NOT EXISTS audit_imported (entry_id TEXT PRIMARY KEY);
            CREATE TABLE IF NOT EXISTS token_cleanup (
              device TEXT PRIMARY KEY, uid TEXT NOT NULL, token_id TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0);
            -- Media fetch (spec #42 F2): one row per media item, or per submitted link until the worker
            -- says whether it is a playlist (`expand`). Owned by one account and the device that
            -- submitted it. The link and title are kept only here, never in a log line. `dispatch`
            -- names the job's spool directory while it runs; `target`/`target_size` record an import
            -- in flight so an unknown outcome is read back. `interrupted` counts restarts (once only).
            CREATE TABLE IF NOT EXISTS fetch_jobs (
              seq INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT UNIQUE NOT NULL, uid TEXT NOT NULL, device TEXT NOT NULL,
              kind TEXT NOT NULL CHECK(kind IN ('audio','video')), height INTEGER, url TEXT NOT NULL,
              expand INTEGER NOT NULL DEFAULT 1, folder TEXT, state TEXT NOT NULL, title TEXT, media_id TEXT,
              obtained INTEGER, percent REAL, destination TEXT, message TEXT, submitted REAL NOT NULL, started REAL,
              finished REAL, interrupted INTEGER NOT NULL DEFAULT 0, dispatch TEXT, target TEXT, target_size INTEGER);
            CREATE INDEX IF NOT EXISTS fetch_jobs_by_uid ON fetch_jobs(uid, seq);
            CREATE INDEX IF NOT EXISTS fetch_jobs_by_state ON fetch_jobs(state, seq);
            -- When each account's last job left the running slot: the queue's turn order (decision #180).
            CREATE TABLE IF NOT EXISTS fetch_turns (uid TEXT PRIMARY KEY, served REAL NOT NULL);
        """)
        self._upgrade_devices()
        self._upgrade_invitation_labels()
        self._upgrade_last_seen()
        self._upgrade_pinned_invitations()

    def _upgrade_devices(self):
        # DDL must be inside an explicit SQLite transaction: a connection context alone
        # does not BEGIN before ALTER/CREATE. Preserve prior credentials across any crash.
        self.db.execute("BEGIN IMMEDIATE")
        try:
            columns = {row[1] for row in self.db.execute("PRAGMA table_info(devices)")}
            legacy = self.db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='devices_spki_prototype'").fetchone()
            if "certificate_id" not in columns or legacy:
                from cryptography import x509
                from cryptography.hazmat.primitives import hashes
                if not legacy:
                    self.db.execute("ALTER TABLE devices RENAME TO devices_spki_prototype")
                    self.db.execute("""CREATE TABLE devices (
                        id TEXT PRIMARY KEY, invitation TEXT UNIQUE NOT NULL REFERENCES invitations(id),
                        uid TEXT NOT NULL, rights TEXT NOT NULL, fingerprint TEXT NOT NULL,
                        state TEXT NOT NULL, certificate TEXT, expires REAL, token TEXT, token_id TEXT, certificate_id TEXT UNIQUE)""")
                # Also recover the earlier unpublished migration if it stranded the old table.
                rows = [dict(row) for row in self.db.execute("SELECT * FROM devices_spki_prototype")]
                for row in rows:
                    leaf = x509.load_pem_x509_certificate(row["certificate"].encode()).fingerprint(hashes.SHA256()).hex() if row["certificate"] else None
                    existing = self.db.execute("SELECT * FROM devices WHERE id=?", (row["id"],)).fetchone()
                    if existing:
                        if any(existing[key] != value for key, value in row.items()) or existing["certificate_id"] != leaf:
                            raise RuntimeError("Conflicting prototype migration rows; restore/reconcile registry before startup")
                    else:
                        self.db.execute("INSERT INTO devices(id,invitation,uid,rights,fingerprint,state,certificate,expires,token,token_id,certificate_id) VALUES(?,?,?,?,?,?,?,?,?,?,?)",
                                        (*(row[key] for key in ("id", "invitation", "uid", "rights", "fingerprint", "state", "certificate", "expires", "token", "token_id")), leaf))
                self.db.execute("DROP TABLE devices_spki_prototype")
            self.db.execute("PRAGMA user_version=2")
            self.db.commit()
        except BaseException:
            self.db.rollback()
            raise

    def _upgrade_invitation_labels(self):
        """The device's own label, kept from its first reservation so the owner can tell
        pending devices apart (spec #27). Rows reserved before this column carry none."""
        self.db.execute("BEGIN IMMEDIATE")
        try:
            if "label" not in {row[1] for row in self.db.execute("PRAGMA table_info(invitations)")}:
                self.db.execute("ALTER TABLE invitations ADD COLUMN label TEXT")
            self.db.commit()
        except BaseException:
            self.db.rollback()
            raise

    def _upgrade_pinned_invitations(self):
        """Code-only pairing (decision #151, spec #35): `pinned` marks a code that carries the CA
        pin and is approved automatically when redeemed; `announced` records its one audit entry;
        `alerted` that the backend confirmed its new-device alert (sent or spooled); `reused` that
        another key tried it after it was taken (0 none, 1 alert due, 2 alert confirmed).
        `device_label` is the computer name the redeeming device reported (the alert names it, never
        the admin's label); `reuse_label`/`reuse_fingerprint` are the first other device's. Alerts are
        at least once: a flag is set only after the backend confirmed. Earlier rows keep the
        fingerprint approval (rule 6)."""
        self.db.execute("BEGIN IMMEDIATE")
        try:
            columns = {row[1] for row in self.db.execute("PRAGMA table_info(invitations)")}
            for column in ("pinned", "announced", "alerted", "reused"):
                if column not in columns:
                    self.db.execute("ALTER TABLE invitations ADD COLUMN %s INTEGER NOT NULL DEFAULT 0" % column)
            for column in ("device_label", "reuse_label", "reuse_fingerprint"):
                if column not in columns:
                    self.db.execute("ALTER TABLE invitations ADD COLUMN %s TEXT" % column)
            self.db.commit()
        except BaseException:
            self.db.rollback()
            raise

    def _upgrade_last_seen(self):
        """When each device last authenticated, for the Admin section's device list (spec #27)."""
        self.db.execute("BEGIN IMMEDIATE")
        try:
            if "last_seen" not in {row[1] for row in self.db.execute("PRAGMA table_info(devices)")}:
                self.db.execute("ALTER TABLE devices ADD COLUMN last_seen REAL")
            self.db.commit()
        except BaseException:
            self.db.rollback()
            raise

    def setting(self, key):
        row = self.db.execute("SELECT value FROM settings WHERE key=?", (key,)).fetchone()
        return None if row is None else row[0]

    def set_setting(self, key, value):
        with self.db:
            self.db.execute("INSERT INTO settings(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                            (key, str(value)))

    def digest(self, code):
        return hmac.new(self.pepper, normalize_code(code).encode(), hashlib.sha256).hexdigest()

    def invite(self, uid, rights, label=None, ca_pin=None):
        """A one-time code valid ten minutes. With `ca_pin` (the gateway always passes its issuer's)
        the code carries it and is approved automatically when redeemed (decision #151)."""
        if not isinstance(uid, str) or not uid or len(uid) > 128 or any(ord(c) < 32 for c in uid):
            raise Rejection("Invalid account UID")
        if rights not in ("read", "write"):
            raise Rejection("Rights must be read or write")
        if label is not None and (not isinstance(label, str) or not 1 <= len(label) <= 80 or any(ord(c) < 32 or ord(c) == 127 for c in label)):
            raise Rejection("Invalid label")
        code = code_from_bytes(secrets.token_bytes(LEGACY_SECRET_BYTES)) if ca_pin is None else \
            pinned_code(secrets.token_bytes(PINNED_SECRET_BYTES), ca_pin)
        row = dict(id=str(uuid.uuid4()), uid=uid, rights=rights, expires=self.clock() + 600)
        with self.db:
            # An admin's label for the code (spec #27) is kept; otherwise the device's own applies.
            self.db.execute("INSERT INTO invitations(id,digest,uid,rights,expires,state,label,pinned) VALUES(?,?,?,?,?,'issued',?,?)",
                            (row["id"], self.digest(code), uid, rights, row["expires"], label, int(ca_pin is not None)))
        return {**row, "code": code}

    def _invitation(self, code):
        row = self.db.execute("SELECT * FROM invitations WHERE digest=?", (self.digest(code),)).fetchone()
        if row is None:
            raise Rejection(CODE_NOT_VALID)
        return dict(row)

    def enroll(self, code, csr, label=""):
        if not isinstance(label, str) or len(label) > 80 or any(ord(c) < 32 for c in label):
            raise Rejection("Invalid label")
        normalized, fingerprint = parse_csr(csr)
        with self.db:
            row = self._invitation(code)
            if row["pinned"]:
                return self._enroll_pinned(row, normalized, fingerprint, label)
            if row["state"] in ("denied", "revoked"):
                return {"state": row["state"]}
            if row["fingerprint"] and row["fingerprint"] != fingerprint:
                raise Rejection("Invitation is reserved to another key")
            if row["csr"] and row["csr"] != normalized:
                raise Rejection("Retry requires the same signed CSR")
            if row["state"] == "approved":
                device = self.device(row["device"])
                if device["state"] == "active" and device["expires"] > self.clock():
                    return {"state": "approved", "pairing_id": row["id"], "device_id": device["id"],
                            "fingerprint": fingerprint, "uid": device["uid"], "rights": device["rights"], "certificate": device["certificate"], "expires_at": device["expires"]}
                return {"state": "revoked" if device["state"] == "revoked" else "expired"}
            if row["expires"] <= self.clock():
                return {"state": "expired"}
            if row["state"] == "issued":
                device = str(uuid.uuid4())
                self.db.execute("UPDATE invitations SET state='reserved',csr=?,fingerprint=?,device=?,label=COALESCE(label,?) WHERE id=?",
                                (normalized, fingerprint, device, label or None, row["id"]))
                row.update(state="reserved", csr=normalized, fingerprint=fingerprint, device=device)
            return {"state": "pending", "pairing_id": row["id"], "device_id": row["device"],
                    "fingerprint": fingerprint, "expires_at": row["expires"]}

    def _enroll_pinned(self, row, normalized, fingerprint, label):
        """A pinned code (decision #151): single use, bound to the first signed CSR that redeems
        it. Anything but that device's own retry is refused with no detail (rules 3 and 5):
        unknown, expired, denied, revoked, or used by another key or request. Another key on a code
        some device holds raises CodeReused, the same refusal, so the gateway can alert the admin."""
        # The device's own name, kept only in its shown form (printable ASCII, PR #92 review H1).
        name = clean_device_name(label, DEVICE_LABEL_MAX) if label else None
        if row["fingerprint"] and row["fingerprint"] != fingerprint and row["state"] in ("reserved", "provisioning", "approved"):
            raise CodeReused(row["id"], name, fingerprint)
        if row["state"] in ("denied", "revoked") or (row["fingerprint"] and row["fingerprint"] != fingerprint) \
                or (row["csr"] and row["csr"] != normalized):
            raise Rejection(CODE_NOT_VALID)
        if row["state"] == "approved":
            device = self.device(row["device"])
            if device["state"] == "active" and device["expires"] > self.clock():
                return {"state": "approved", "pairing_id": row["id"], "device_id": device["id"], "fingerprint": fingerprint,
                        "uid": device["uid"], "rights": device["rights"], "certificate": device["certificate"],
                        "expires_at": device["expires"], "approval": "automatic"}
            raise Rejection(CODE_NOT_VALID)
        if row["expires"] <= self.clock():
            raise Rejection(CODE_NOT_VALID)
        if row["state"] == "issued":
            device = str(uuid.uuid4())
            self.db.execute("UPDATE invitations SET state='reserved',csr=?,fingerprint=?,device=?,label=COALESCE(label,?),"
                            "device_label=? WHERE id=? AND state='issued' AND fingerprint IS NULL",
                            (normalized, fingerprint, device, name, name, row["id"]))
            if self.db.execute("SELECT changes()").fetchone()[0] != 1:
                raise Rejection(CODE_NOT_VALID)
            row.update(state="reserved", device=device)
        return {"state": "pending", "pairing_id": row["id"], "device_id": row["device"], "fingerprint": fingerprint,
                "expires_at": row["expires"], "approval": "automatic"}

    def announce(self, identity):
        """Write the one `device-paired` audit entry of an approved pinned invitation, in the same
        transaction as its claim: the row the first time, None ever after (restart-safe). Its
        alert is separate and at least once (`alerts_due`)."""
        with self.db:
            self.db.execute("UPDATE invitations SET announced=1 WHERE id=? AND pinned=1 AND announced=0 AND state='approved'",
                            (identity,))
            if self.db.execute("SELECT changes()").fetchone()[0] != 1:
                return None
            row = self.invitation(identity)
            self.db.execute("INSERT INTO admin_audit(time,actor_uid,action,target_uid,target_device,target_invitation,result) "
                            "VALUES(?,?,?,?,?,?,?)", (self.clock(), "system", "device-paired", row["uid"], row["device"], row["id"], "ok"))
            self.db.execute("DELETE FROM admin_audit WHERE seq <= (SELECT max(seq) FROM admin_audit) - ?", (AUDIT_KEEP,))
        return row

    def unannounced(self):
        """Approved pinned invitations whose audit entry is not written yet (e.g. approved by setup's
        operator fallback while no device asked again)."""
        return [row[0] for row in self.db.execute(
            "SELECT id FROM invitations WHERE pinned=1 AND state='approved' AND announced=0")]

    def note_reuse(self, identity, label, fingerprint):
        """Another key tried a taken pinned code: its alert, naming that first other device, becomes
        due once per invitation."""
        with self.db:
            self.db.execute("UPDATE invitations SET reused=1,reuse_label=?,reuse_fingerprint=? WHERE id=? AND pinned=1 AND reused=0",
                            (label or None, fingerprint, identity))

    def alerts_due(self):
        """(kind, invitation) for every alert the backend has not confirmed: 'paired' for an
        approved, audited pinned invitation, 'reused' for a taken code another key tried."""
        rows = [dict(row) for row in self.db.execute(
            "SELECT * FROM invitations WHERE pinned=1 AND ((state='approved' AND announced=1 AND alerted=0) OR reused=1)")]
        due = []
        for row in rows:
            row.pop("digest", None)
            if row["state"] == "approved" and row["announced"] and not row["alerted"]:
                due.append(("paired", row))
            if row["reused"] == 1:
                due.append(("reused", row))
        return due

    def alert_confirmed(self, kind, identity):
        with self.db:
            if kind == "paired":
                self.db.execute("UPDATE invitations SET alerted=1 WHERE id=?", (identity,))
            else:
                self.db.execute("UPDATE invitations SET reused=2 WHERE id=? AND reused=1", (identity,))

    def invitation(self, identity):
        row = self.db.execute("SELECT * FROM invitations WHERE id=?", (identity,)).fetchone()
        if row is None:
            raise Rejection("Unknown pairing")
        result = dict(row)
        result.pop("digest")
        return result

    def pending(self):
        return [self.invitation(row[0]) for row in self.db.execute("SELECT id FROM invitations ORDER BY rowid DESC LIMIT 100")]

    def begin(self, identity, fingerprint):
        with self.db:
            row = self.invitation(identity)
            if row["fingerprint"] != fingerprint:
                raise Rejection("Fingerprint mismatch")
            if row["state"] == "approved":
                if self.device(row["device"])["state"] != "active" or self.device(row["device"])["expires"] <= self.clock():
                    raise Rejection("Device is not active")
                return {**row, "already_active": True}
            if row["state"] not in ("reserved", "provisioning") or row["expires"] <= self.clock():
                raise Rejection("Pairing is not approvable")
            self.db.execute("UPDATE invitations SET state='provisioning' WHERE id=?", (identity,))
            # Re-pairing may use a new key; an existing active key is never reassigned.
            self.db.execute("INSERT OR IGNORE INTO devices(id,invitation,uid,rights,fingerprint,state) VALUES(?,?,?,?,?,'provisioning')",
                            (row["device"], identity, row["uid"], row["rights"], fingerprint))
            current = self.device(row["device"])
            if current["state"] != "provisioning":
                raise Rejection("Device is not provisionable")
            return row

    def activate(self, identity, fingerprint, token, token_id, certificate, expires, certificate_id):
        with self.db:
            row = self.invitation(identity)
            if row["state"] != "provisioning" or row["fingerprint"] != fingerprint or row["expires"] <= self.clock():
                raise Rejection("Pairing changed or expired during provisioning")
            if expires <= self.clock():
                raise Rejection("Certificate has expired")
            self.db.execute("UPDATE devices SET state='active',token=?,token_id=?,certificate=?,expires=?,certificate_id=? WHERE id=? AND state='provisioning'",
                            (token, str(token_id), certificate, expires, certificate_id, row["device"]))
            if self.db.execute("SELECT changes()").fetchone()[0] != 1:
                raise Rejection("Device changed during provisioning")
            self.db.execute("UPDATE invitations SET state='approved' WHERE id=?", (identity,))

    def device(self, identity):
        row = self.db.execute("SELECT * FROM devices WHERE id=?", (identity,)).fetchone()
        if row is None:
            raise Rejection("Unknown device")
        return dict(row)

    def admit(self, fingerprint, certificate_id, observe=False):
        """Admit an active device presenting its key and an exact accepted leaf.

        The current leaf is always accepted until expiry. An earlier leaf of the same device and
        key stays accepted during a reissue until it expires or, with ``observe``, until the
        device first authenticates with the current leaf, proving it persisted the new one.
        Every device of a disabled account is refused; its certificates stay valid.
        """
        device = self._admit(fingerprint, certificate_id, observe)
        if not self.account_enabled(device["uid"]):
            raise AccountDisabled("Account is disabled")
        return device

    def _admit(self, fingerprint, certificate_id, observe):
        now = self.clock()
        row = self.db.execute("SELECT * FROM devices WHERE fingerprint=? AND certificate_id=? AND state='active' AND expires>?", (fingerprint, certificate_id, now)).fetchone()
        if row is not None:
            if observe and self.db.execute("SELECT 1 FROM device_leaves WHERE device=? LIMIT 1", (row["id"],)).fetchone():
                with self.db:
                    self.db.execute("DELETE FROM device_leaves WHERE device=?", (row["id"],))
            return dict(row)
        row = self.db.execute("SELECT devices.* FROM device_leaves JOIN devices ON devices.id=device_leaves.device "
                              "WHERE devices.fingerprint=? AND device_leaves.certificate_id=? AND devices.state='active' AND device_leaves.expires>?",
                              (fingerprint, certificate_id, now)).fetchone()
        if row is None:
            raise Rejection("Device is not active")
        return dict(row)

    def reissue_target(self, identity):
        """Public signing inputs for an active device whose current leaf can still reach it."""
        device = self.device(identity)
        if device["state"] != "active":
            raise Rejection("Only an active device can be reissued; revoked or inactive devices re-pair")
        if not device["certificate"] or not device["expires"] or device["expires"] <= self.clock():
            raise Rejection("Device certificate has expired; the device cannot fetch a reissue and must re-pair")
        invitation = self.invitation(device["invitation"])
        if not invitation["csr"] or invitation["fingerprint"] != device["fingerprint"]:
            raise Rejection("Device enrollment request is unavailable")
        return {"device": device["id"], "uid": device["uid"], "fingerprint": device["fingerprint"], "csr": invitation["csr"],
                "certificate": device["certificate"], "certificate_id": device["certificate_id"], "expires": device["expires"]}

    def reissue(self, identity, fingerprint, certificate, expires, certificate_id):
        """Make a verified same-key leaf current; the previous current leaf stays accepted."""
        with self.db:
            device = self.device(identity)
            now = self.clock()
            if device["state"] != "active" or not device["expires"] or device["expires"] <= now:
                raise Rejection("Only an active device can be reissued; revoked or inactive devices re-pair")
            if device["fingerprint"] != fingerprint:
                raise Rejection("Reissued certificate key mismatch")
            if device["certificate_id"] == certificate_id:
                return {"state": "current", "device_id": identity, "expires_at": device["expires"], "certificate_id": certificate_id}
            if expires <= now:
                raise Rejection("Certificate has expired")
            if self.db.execute("SELECT 1 FROM device_leaves WHERE certificate_id=?", (certificate_id,)).fetchone():
                raise Rejection("Certificate was already superseded")
            # Every earlier unexpired leaf remains acceptable: the device may not have picked up an
            # intermediate reissue, and a lost pickup must never strand its working certificate.
            self.db.execute("INSERT INTO device_leaves(certificate_id,device,certificate,expires) VALUES(?,?,?,?)",
                            (device["certificate_id"], identity, device["certificate"], device["expires"]))
            self.db.execute("UPDATE devices SET certificate=?,expires=?,certificate_id=? WHERE id=? AND state='active' AND certificate_id=?",
                            (certificate, expires, certificate_id, identity, device["certificate_id"]))
            if self.db.execute("SELECT changes()").fetchone()[0] != 1:
                raise Rejection("Device changed during reissue")
            self.db.execute("DELETE FROM device_leaves WHERE expires<=?", (now,))
        return {"state": "reissued", "device_id": identity, "expires_at": expires, "certificate_id": certificate_id}

    def disable(self, identity, state="revoked"):
        with self.db:
            device = self.device(identity)
            self.db.execute("UPDATE devices SET state=? WHERE id=?", (state, identity))
            self.db.execute("UPDATE invitations SET state=? WHERE id=?", (state, device["invitation"]))
            # The state check already refuses every leaf; also forget the transition leaves.
            self.db.execute("DELETE FROM device_leaves WHERE device=?", (identity,))
        return device

    def deny(self, identity):
        with self.db:
            row = self.invitation(identity)
            if row["state"] == "approved":
                raise Rejection("Use revoke for an approved device")
            self.db.execute("UPDATE invitations SET state='denied' WHERE id=?", (identity,))
            self.db.execute("UPDATE devices SET state='denied' WHERE invitation=?", (identity,))
        return {"state": "denied"}

    def public_devices(self):
        return [dict(row) for row in self.db.execute(
            "SELECT id,invitation,uid,rights,fingerprint,state,expires,token_id,certificate_id,"
            "(SELECT count(*) FROM device_leaves WHERE device=devices.id AND expires>?) AS transition_leaves,"
            "(SELECT label FROM invitations WHERE invitations.id=devices.invitation) AS label,"
            "(SELECT device_label FROM invitations WHERE invitations.id=devices.invitation) AS device_label,last_seen FROM devices",
            (self.clock(),))]

    ADDED_PAGE = 1000

    def record_added(self, uid, fileid):
        """Record a file's creation once; the first record wins. Returns whether it was new."""
        if not isinstance(fileid, int) or isinstance(fileid, bool) or not 0 < fileid < 2 ** 63:
            raise Rejection("Invalid file ID")
        with self.db:
            self.db.execute("INSERT OR IGNORE INTO files_added(uid,fileid,added_at) VALUES(?,?,?)", (uid, fileid, self.clock()))
            return self.db.execute("SELECT changes()").fetchone()[0] == 1

    def prune_added(self, uid, fileid):
        with self.db:
            self.db.execute("DELETE FROM files_added WHERE uid=? AND fileid=?", (uid, fileid))

    def added_since(self, uid, after=0, limit=ADDED_PAGE):
        """One bounded page of `uid`'s rows after cursor `after`, oldest first.

        `cursor` is the last returned row's sequence (or `after` when none), `more` says another
        page is ready. A cursor beyond every sequence ever issued (a replaced registry) is answered
        with `reset` so the caller starts again from 0. Only `uid`'s rows are ever read.
        """
        limit = max(1, min(int(limit), self.ADDED_PAGE))
        issued = self.db.execute("SELECT seq FROM sqlite_sequence WHERE name='files_added'").fetchone()
        if after > (issued[0] if issued else 0):
            return {"added": {}, "cursor": 0, "more": False, "reset": True}
        rows = self.db.execute("SELECT seq,fileid,added_at FROM files_added WHERE uid=? AND seq>? ORDER BY seq LIMIT ?",
                               (uid, after, limit + 1)).fetchall()
        more = len(rows) > limit
        rows = rows[:limit]
        return {"added": {str(row["fileid"]): row["added_at"] for row in rows},
                "cursor": rows[-1]["seq"] if rows else after, "more": more, "reset": False}

    def fence_state(self):
        """clear, dispatched (a write's outcome pending) or maintenance."""
        return self.db.execute("SELECT state FROM mutation_fence WHERE singleton=1").fetchone()[0]

    def mutation_ready(self):
        return self.db.execute("SELECT state FROM mutation_fence WHERE singleton=1").fetchone()[0] == "clear"

    def mutation_begin(self, device, path):
        with self.db:
            if not self.mutation_ready():
                raise Rejection("Writes are fenced pending scoped operator recovery")
            self.db.execute("UPDATE mutation_fence SET state='dispatched',operation=?,device=?,path=? WHERE singleton=1", (str(uuid.uuid4()), device, path))

    def mutation_finish(self):
        with self.db:
            self.db.execute("UPDATE mutation_fence SET state='clear',operation=NULL,device=NULL,path=NULL WHERE singleton=1 AND state='dispatched'")

    def note_share_cleanup_and_finish(self, share_id, device):
        self.db.execute("BEGIN IMMEDIATE")
        try:
            self.db.execute("INSERT OR REPLACE INTO share_cleanup VALUES(?,?,'pending')", (share_id, device))
            self.db.execute("UPDATE mutation_fence SET state='clear',operation=NULL,device=NULL,path=NULL WHERE singleton=1 AND state='dispatched'")
            self.db.commit()
        except BaseException:
            self.db.rollback()
            raise

    def maintenance(self):
        with self.db:
            self.db.execute("UPDATE mutation_fence SET state='maintenance' WHERE singleton=1")

    def recover(self):
        with self.db:
            if self.db.execute("SELECT state FROM mutation_fence WHERE singleton=1").fetchone()[0] != "maintenance":
                raise Rejection("Scoped quiescence is required before clearing uncertainty")
            self.db.execute("UPDATE mutation_fence SET state='clear',operation=NULL,device=NULL,path=NULL WHERE singleton=1")

    # Household accounts (decision #78 N5, #79 (b)).

    def account(self, uid):
        row = self.db.execute("SELECT uid,display_name,enabled FROM accounts WHERE uid=?", (uid,)).fetchone()
        return None if row is None else {"uid": row["uid"], "display_name": row["display_name"], "enabled": bool(row["enabled"])}

    def account_enabled(self, uid):
        """False only for an account explicitly disabled; an unregistered account is not refused."""
        row = self.db.execute("SELECT enabled FROM accounts WHERE uid=?", (uid,)).fetchone()
        return row is None or bool(row["enabled"])

    def accounts(self):
        return [{"uid": row["uid"], "display_name": row["display_name"], "enabled": bool(row["enabled"])}
                for row in self.db.execute("SELECT uid,display_name,enabled FROM accounts ORDER BY display_name COLLATE NOCASE, uid")]

    def household(self, caller):
        """Enabled household users other than the caller: id and display name only."""
        return [{"id": row["uid"], "display_name": row["display_name"]}
                for row in self.db.execute("SELECT uid,display_name FROM accounts WHERE enabled=1 AND uid!=? "
                                           "ORDER BY display_name COLLATE NOCASE, uid", (caller,))]

    def account_set(self, uid, display_name=None, enabled=None):
        """Register an account or change its display name and enabled state.

        A new account needs a display name and starts enabled unless ``enabled`` says otherwise.
        Returns the row and whether its enabled state changed.
        """
        if not isinstance(uid, str) or not ACCOUNT_UID.fullmatch(uid):
            raise Rejection(UID_TEXT)
        if display_name is not None:
            # isprintable() also refuses C1 controls and format characters (bidi overrides,
            # zero-width), which would reorder or hide text in a recipient's "Shared by" row.
            display_name = clean_display_name(display_name)
            if display_name is None:
                raise Rejection(NAME_TEXT)
        if enabled is not None and not isinstance(enabled, bool):
            raise Rejection("Enabled must be true or false")
        with self.db:
            current = self.account(uid)
            if current is None:
                if display_name is None:
                    raise Rejection("A new account needs a display name")
                self.db.execute("INSERT INTO accounts(uid,display_name,enabled) VALUES(?,?,?)",
                                (uid, display_name, int(True if enabled is None else enabled)))
                changed = enabled is False
            else:
                changed = enabled is not None and enabled != current["enabled"]
                if changed and not enabled:
                    self._ensure_admin_remains(uid)
                self.db.execute("UPDATE accounts SET display_name=?,enabled=? WHERE uid=?",
                                (display_name or current["display_name"], int(current["enabled"] if enabled is None else enabled), uid))
        return self.account(uid), changed

    def active_devices(self, uid):
        return [dict(row) for row in self.db.execute("SELECT * FROM devices WHERE uid=? AND state='active'", (uid,))]

    # Scoped share fences (decision #80 (1)).

    def share_fenced(self, *scopes):
        return any(self.db.execute("SELECT 1 FROM share_fence WHERE scope=?", (scope,)).fetchone() for scope in scopes if scope)

    def share_fence(self, scope, kind, owner_uid, share_id=None):
        with self.db:
            self.db.execute("INSERT OR REPLACE INTO share_fence(scope,kind,owner_uid,share_id,created) VALUES(?,?,?,?,?)",
                            (scope, kind, owner_uid, share_id, self.clock()))

    def share_fences(self):
        return [dict(row) for row in self.db.execute("SELECT scope,kind,owner_uid,share_id,created FROM share_fence ORDER BY created")]

    def share_fence_clear(self, scope):
        with self.db:
            self.db.execute("DELETE FROM share_fence WHERE scope=?", (scope,))
            return self.db.execute("SELECT changes()").fetchone()[0] == 1

    # Incoming mounts as recipients last saw them (decision #80 (2)).

    def record_owner_mounts(self, owner, rows):
        """Replace every recorded mount of `owner`'s shares from one complete owner-side listing."""
        with self.db:
            self.db.execute("DELETE FROM incoming_mounts WHERE owner_uid=?", (owner,))
            for item in rows:
                self.db.execute("INSERT OR REPLACE INTO incoming_mounts(share_id,recipient_uid,owner_uid,path,permissions) VALUES(?,?,?,?,?)",
                                (item["share_id"], item["recipient_uid"], owner, item["path"], item["permissions"]))

    def remember_incoming(self, recipient, rows):
        """Replace the recipient's mounts from a complete listing, keeping disabled owners' rows."""
        with self.db:
            for row in self.db.execute("SELECT share_id,owner_uid FROM incoming_mounts WHERE recipient_uid=?", (recipient,)).fetchall():
                if self.account_enabled(row["owner_uid"]) and row["share_id"] not in {item["share_id"] for item in rows}:
                    self.db.execute("DELETE FROM incoming_mounts WHERE recipient_uid=? AND share_id=?", (recipient, row["share_id"]))
            for item in rows:
                self.db.execute("INSERT OR REPLACE INTO incoming_mounts(share_id,recipient_uid,owner_uid,path,permissions) VALUES(?,?,?,?,?)",
                                (item["share_id"], recipient, item["owner_uid"], item["path"], item["permissions"]))

    def forget_incoming(self, recipient, share_id):
        with self.db:
            self.db.execute("DELETE FROM incoming_mounts WHERE recipient_uid=? AND share_id=?", (recipient, share_id))

    # Placement of incoming shares (spec #34 P6, decision #149).

    def placement_add(self, share_id, owner, recipient, folder, name):
        with self.db:
            self.db.execute("INSERT OR REPLACE INTO share_placement(share_id,owner_uid,recipient_uid,folder,name,state,created) "
                            "VALUES(?,?,?,?,?,'pending',?)", (share_id, owner, recipient, folder, name, time.time()))

    def placement(self, share_id):
        row = self.db.execute("SELECT * FROM share_placement WHERE share_id=?", (share_id,)).fetchone()
        return None if row is None else dict(row)

    def placements_pending(self, recipient):
        return [dict(row) for row in self.db.execute(
            "SELECT * FROM share_placement WHERE recipient_uid=? AND state='pending' ORDER BY created", (recipient,))]

    def placement_retry(self, share_id, attempts, next_try):
        with self.db:
            self.db.execute("UPDATE share_placement SET attempts=?, next_try=? WHERE share_id=?", (attempts, next_try, share_id))

    def placement_set(self, share_id, state):
        with self.db:
            self.db.execute("UPDATE share_placement SET state=? WHERE share_id=?", (state, share_id))

    def placement_forget(self, share_id):
        with self.db:
            self.db.execute("DELETE FROM share_placement WHERE share_id=?", (share_id,))

    def mount_rename_add(self, share_id, recipient, owner, name):
        with self.db:
            self.db.execute("INSERT OR REPLACE INTO mount_rename(share_id,recipient_uid,owner_uid,name,created) VALUES(?,?,?,?,?)",
                            (share_id, recipient, owner, name, time.time()))

    def mount_renames(self, recipient):
        return [dict(row) for row in self.db.execute(
            "SELECT * FROM mount_rename WHERE recipient_uid=? ORDER BY created", (recipient,))]

    def mount_rename_done(self, share_id):
        with self.db:
            self.db.execute("DELETE FROM mount_rename WHERE share_id=?", (share_id,))

    def unavailable_incoming(self, recipient):
        return [dict(row) for row in self.db.execute(
            "SELECT incoming_mounts.* FROM incoming_mounts JOIN accounts ON accounts.uid=incoming_mounts.owner_uid "
            "WHERE incoming_mounts.recipient_uid=? AND accounts.enabled=0 ORDER BY path", (recipient,))]

    # Household administration (spec #27, decision #87). The admin role is on the account.

    def role(self, uid):
        row = self.db.execute("SELECT uid,display_name,enabled,admin FROM accounts WHERE uid=?", (uid,)).fetchone()
        return None if row is None else {"uid": row["uid"], "display_name": row["display_name"], "enabled": bool(row["enabled"]),
                                         "admin": bool(row["admin"])}

    def roles(self):
        return [{"uid": row["uid"], "display_name": row["display_name"], "enabled": bool(row["enabled"]), "admin": bool(row["admin"])}
                for row in self.db.execute("SELECT uid,display_name,enabled,admin FROM accounts ORDER BY display_name COLLATE NOCASE, uid")]

    def enabled_admins(self):
        return [row[0] for row in self.db.execute("SELECT uid FROM accounts WHERE enabled=1 AND admin=1 ORDER BY uid")]

    def _ensure_admin_remains(self, uid):
        """Inside a transaction: refuse when `uid` is the only enabled admin."""
        if self.db.execute("SELECT 1 FROM accounts WHERE uid=? AND enabled=1 AND admin=1", (uid,)).fetchone() and \
                self.db.execute("SELECT count(*) FROM accounts WHERE enabled=1 AND admin=1").fetchone()[0] <= 1:
            raise LastAdmin(LAST_ADMIN_TEXT)

    def set_account_flags(self, uid, *, enabled=None, admin=None):
        """Change an account's enabled state and/or admin role in one transaction.

        The last-admin check and the change commit together, so two admins removing each
        other's role at the same moment cannot both succeed (spec #27 Last-Admin Protection).
        """
        for value in (enabled, admin):
            if value is not None and not isinstance(value, bool):
                raise Rejection("Flags must be true or false")
        self.db.execute("BEGIN IMMEDIATE")
        try:
            row = self.db.execute("SELECT enabled,admin FROM accounts WHERE uid=?", (uid,)).fetchone()
            if row is None:
                raise Rejection("Unknown account")
            new_enabled = bool(row["enabled"]) if enabled is None else enabled
            new_admin = bool(row["admin"]) if admin is None else admin
            if row["enabled"] and row["admin"] and not (new_enabled and new_admin):
                self._ensure_admin_remains(uid)
            self.db.execute("UPDATE accounts SET enabled=?,admin=? WHERE uid=?", (int(new_enabled), int(new_admin), uid))
            self.db.commit()
        except BaseException:
            self.db.rollback()
            raise
        return self.role(uid)

    def seen(self, device_id, when=None):
        with self.db:
            self.db.execute("UPDATE devices SET last_seen=? WHERE id=?", (self.clock() if when is None else when, device_id))

    def audit(self, action, result, *, actor_uid=None, actor_device=None, target_uid=None, target_device=None,
              target_invitation=None, time=None):
        with self.db:
            self.db.execute("INSERT INTO admin_audit(time,actor_uid,actor_device,action,target_uid,target_device,target_invitation,result) "
                            "VALUES(?,?,?,?,?,?,?,?)", (self.clock() if time is None else time, actor_uid, actor_device, action,
                                                        target_uid, target_device, target_invitation, result))
            self.db.execute("DELETE FROM admin_audit WHERE seq <= (SELECT max(seq) FROM admin_audit) - ?", (AUDIT_KEEP,))

    def audit_page(self, before=None, limit=100):
        """Newest first; `before` is the previous page's last sequence."""
        limit = max(1, min(int(limit), 100))
        query = "SELECT * FROM admin_audit" + (" WHERE seq<?" if before is not None else "") + " ORDER BY seq DESC LIMIT ?"
        rows = [dict(row) for row in self.db.execute(query, ((before, limit + 1) if before is not None else (limit + 1,)))]
        return rows[:limit], (rows[limit - 1]["seq"] if len(rows) > limit else None)

    def token_cleanup_add(self, device, uid, token_id):
        with self.db:
            self.db.execute("INSERT INTO token_cleanup(device,uid,token_id) VALUES(?,?,?) "
                            "ON CONFLICT(device) DO UPDATE SET attempts=attempts+1", (device, uid, str(token_id)))

    def token_cleanups(self):
        return [dict(row) for row in self.db.execute("SELECT * FROM token_cleanup ORDER BY device")]

    def token_cleanup_done(self, device):
        with self.db:
            self.db.execute("DELETE FROM token_cleanup WHERE device=?", (device,))

    def import_first_admins(self, accounts, admins):
        """One-time first-admin import (spec #27, decision #89 (9)), in one transaction.

        Creates missing account rows (enabled), grants admin to `admins` only when no enabled
        admin exists (never demotes), records one audit entry and an import marker. A second
        call is a no-op.
        """
        for row in accounts:
            if not isinstance(row.get("uid"), str) or not ACCOUNT_UID.fullmatch(row["uid"]):
                raise Rejection("Account ID must be 1-32 lowercase letters, digits or '-'")
        if not set(admins) <= {row["uid"] for row in accounts}:
            raise Rejection("Every imported admin needs an account row")
        self.db.execute("BEGIN IMMEDIATE")
        try:
            if self.db.execute("SELECT 1 FROM settings WHERE key=?", (FIRST_ADMIN_IMPORT,)).fetchone():
                self.db.commit()
                return {"state": "already-imported", "granted": []}
            for row in accounts:
                name = " ".join(str(row.get("display_name") or row["uid"]).split())[:64] or row["uid"]
                self.db.execute("INSERT OR IGNORE INTO accounts(uid,display_name,enabled,admin) VALUES(?,?,1,0)", (row["uid"], name))
            granted = []
            if not self.db.execute("SELECT 1 FROM accounts WHERE enabled=1 AND admin=1").fetchone():
                for uid in admins:
                    self.db.execute("UPDATE accounts SET admin=1 WHERE uid=? AND enabled=1", (uid,))
                    if self.db.execute("SELECT changes()").fetchone()[0]:
                        granted.append(uid)
            self.db.execute("INSERT INTO settings(key,value) VALUES(?,?)", (FIRST_ADMIN_IMPORT, str(self.clock())))
            self.db.execute("INSERT INTO admin_audit(time,actor_uid,action,result) VALUES(?,?,?,?)",
                            (self.clock(), "bootstrap", "first-admin-import", "ok"))
            self.db.commit()
        except BaseException:
            self.db.rollback()
            raise
        return {"state": "imported", "granted": granted}

    def account_cleanup_add(self, uid, display_name=None):
        with self.db:
            self.db.execute("INSERT OR IGNORE INTO account_cleanup(uid,created,display_name) VALUES(?,?,?)",
                            (uid, self.clock(), display_name))

    def account_cleanup_pending(self, uid):
        return self.db.execute("SELECT 1 FROM account_cleanup WHERE uid=?", (uid,)).fetchone() is not None

    def account_cleanup_done(self, uid):
        with self.db:
            self.db.execute("DELETE FROM account_cleanup WHERE uid=?", (uid,))

    def account_cleanups(self):
        return [row[0] for row in self.db.execute("SELECT uid FROM account_cleanup ORDER BY uid")]

    def pending_accounts(self):
        """Created on the server, household step not finished (spec #27): listed, never hidden."""
        return [{"uid": row["uid"], "display_name": row["display_name"] or row["uid"]}
                for row in self.db.execute("SELECT uid,display_name FROM account_cleanup "
                                           "WHERE uid NOT IN (SELECT uid FROM accounts) ORDER BY uid")]

    # Media fetch jobs (spec #42 F2). Every read is scoped to one account except the queue's own.

    FETCH_UNFINISHED = ("waiting", "checking", "downloading", "placing")
    FETCH_COLUMNS = frozenset({"state", "title", "media_id", "obtained", "percent", "destination", "message", "started",
                               "finished", "interrupted", "dispatch", "target", "target_size", "folder", "expand"})

    def fetch_add(self, uid, device, kind, height, urls, *, cap, folder=None, expand=True):
        """Queue one waiting row per link in one transaction, or none: FetchCap when the account
        would hold more than `cap` unfinished rows."""
        now = self.clock()
        self.db.execute("BEGIN IMMEDIATE")
        try:
            unfinished = self.db.execute("SELECT count(*) FROM fetch_jobs WHERE uid=? AND state IN (?,?,?,?)",
                                         (uid, *self.FETCH_UNFINISHED)).fetchone()[0]
            if unfinished + len(urls) > cap:
                raise FetchCap(cap - unfinished)
            ids = []
            for url in urls:
                identity = str(uuid.uuid4())
                self.db.execute("INSERT INTO fetch_jobs(id,uid,device,kind,height,url,expand,folder,state,submitted) "
                                "VALUES(?,?,?,?,?,?,?,?,'waiting',?)", (identity, uid, device, kind, height, url, int(expand), folder, now))
                ids.append(identity)
            self.db.commit()
        except BaseException:
            self.db.rollback()
            raise
        return [self.fetch_job(identity) for identity in ids]

    def fetch_unfinished(self, uid):
        return self.db.execute("SELECT count(*) FROM fetch_jobs WHERE uid=? AND state IN (?,?,?,?)",
                               (uid, *self.FETCH_UNFINISHED)).fetchone()[0]

    def fetch_job(self, identity):
        row = self.db.execute("SELECT * FROM fetch_jobs WHERE id=?", (identity,)).fetchone()
        return None if row is None else dict(row)

    def fetch_jobs(self, uid):
        """The account's rows, newest first."""
        return [dict(row) for row in self.db.execute("SELECT * FROM fetch_jobs WHERE uid=? ORDER BY seq DESC", (uid,))]

    def fetch_update(self, identity, **fields):
        if not fields or set(fields) - self.FETCH_COLUMNS:
            raise ValueError("Unknown fetch job field")
        with self.db:
            self.db.execute("UPDATE fetch_jobs SET " + ",".join(name + "=?" for name in fields) + " WHERE id=?",
                            (*fields.values(), identity))
        return self.fetch_job(identity)

    def fetch_remove(self, uid, identity):
        with self.db:
            self.db.execute("DELETE FROM fetch_jobs WHERE uid=? AND id=? AND state NOT IN (?,?,?,?)",
                            (uid, identity, *self.FETCH_UNFINISHED))
            return self.db.execute("SELECT changes()").fetchone()[0] == 1

    def fetch_clear(self, uid):
        with self.db:
            self.db.execute("DELETE FROM fetch_jobs WHERE uid=? AND state NOT IN (?,?,?,?)", (uid, *self.FETCH_UNFINISHED))
            return self.db.execute("SELECT changes()").fetchone()[0]

    def fetch_prune(self, before):
        """Finished rows older than `before` (retention, decision #180)."""
        with self.db:
            self.db.execute("DELETE FROM fetch_jobs WHERE finished IS NOT NULL AND finished<? AND state NOT IN (?,?,?,?)",
                            (before, *self.FETCH_UNFINISHED))

    def fetch_running(self):
        """Rows holding the single running slot (normally at most one), oldest first."""
        return [dict(row) for row in self.db.execute(
            "SELECT * FROM fetch_jobs WHERE state IN ('checking','downloading','placing') ORDER BY seq")]

    def fetch_next(self):
        """The next waiting row: from the account whose oldest waiting row has waited longest,
        counting its wait from when the account's previous job left the running slot, so accounts
        alternate between a long playlist's items (decision #180). FIFO within an account."""
        heads = self.db.execute(
            "SELECT uid, min(seq) AS head, min(submitted) AS oldest, (SELECT served FROM fetch_turns WHERE fetch_turns.uid=j.uid) AS served "
            "FROM fetch_jobs j WHERE state='waiting' GROUP BY uid").fetchall()
        if not heads:
            return None
        best = min(heads, key=lambda row: (max(row["oldest"], row["served"] or 0), row["head"]))
        return dict(self.db.execute("SELECT * FROM fetch_jobs WHERE seq=?", (best["head"],)).fetchone())

    def fetch_served(self, uid, when=None):
        with self.db:
            self.db.execute("INSERT INTO fetch_turns(uid,served) VALUES(?,?) ON CONFLICT(uid) DO UPDATE SET served=excluded.served",
                            (uid, self.clock() if when is None else when))

    def audit_import_entry(self, entry_id, action, result, *, time, target_uid=None, target_device=None, target_invitation=None):
        """One recovery-CLI entry, once per entry id. Returns whether it was new."""
        with self.db:
            self.db.execute("INSERT OR IGNORE INTO audit_imported(entry_id) VALUES(?)", (entry_id,))
            if self.db.execute("SELECT changes()").fetchone()[0] != 1:
                return False
            self.db.execute("INSERT INTO admin_audit(time,actor_uid,action,target_uid,target_device,target_invitation,result) "
                            "VALUES(?,?,?,?,?,?,?)", (time, "recovery-cli", action, target_uid, target_device, target_invitation, result))
            self.db.execute("DELETE FROM admin_audit WHERE seq <= (SELECT max(seq) FROM admin_audit) - ?", (AUDIT_KEEP,))
        return True
