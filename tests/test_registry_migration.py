"""Kill the migration process at real DDL/data boundaries, then reopen its DB."""

from datetime import datetime, timedelta, timezone
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID

from services.access.registry import Registry

OLD_COLUMNS = "id,invitation,uid,rights,fingerprint,state,certificate,expires,token,token_id"
OLD_TABLE = """CREATE TABLE devices_old_seed (
 id TEXT PRIMARY KEY, invitation TEXT UNIQUE NOT NULL REFERENCES invitations(id),
 uid TEXT NOT NULL, rights TEXT NOT NULL, fingerprint TEXT UNIQUE NOT NULL,
 state TEXT NOT NULL, certificate TEXT, expires REAL, token TEXT, token_id TEXT)"""


def legacy_seed(directory):
    registry = Registry(directory)
    for index, uid in enumerate(("alice", "bob")):
        key = ec.generate_private_key(ec.SECP256R1())
        name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "migration fixture")])
        request = x509.CertificateSigningRequestBuilder().subject_name(name).sign(key, hashes.SHA256())
        certificate = x509.CertificateBuilder().subject_name(name).issuer_name(name).public_key(key.public_key()).serial_number(index + 1).not_valid_before(datetime.now(timezone.utc) - timedelta(minutes=1)).not_valid_after(datetime.now(timezone.utc) + timedelta(days=1)).sign(key, hashes.SHA256())
        invitation = registry.invite(uid, "write")
        pending = registry.enroll(invitation["code"], request.public_bytes(serialization.Encoding.PEM).decode())
        registry.begin(pending["pairing_id"], pending["fingerprint"])
        registry.activate(pending["pairing_id"], pending["fingerprint"], "synthetic-legacy-token-" + uid, str(index + 1), certificate.public_bytes(serialization.Encoding.PEM).decode(), registry.clock() + 1000, certificate.fingerprint(hashes.SHA256()).hex())
        if uid == "bob":
            registry.disable(pending["device_id"])
    expected = {row["id"]: dict(row) for row in registry.db.execute("SELECT " + OLD_COLUMNS + " FROM devices")}
    current_schema = registry.db.execute("SELECT sql FROM sqlite_master WHERE name='devices'").fetchone()[0]
    registry.db.close()
    connection = sqlite3.connect(Path(directory) / "registry.sqlite")
    connection.execute("BEGIN IMMEDIATE")
    connection.execute(OLD_TABLE)
    connection.execute("INSERT INTO devices_old_seed SELECT " + OLD_COLUMNS + " FROM devices")
    connection.execute("DROP TABLE devices")
    connection.execute("ALTER TABLE devices_old_seed RENAME TO devices")
    connection.execute("PRAGMA user_version=0")
    connection.commit()
    connection.close()
    return expected, current_schema


class MigrationTests(unittest.TestCase):
    def assert_preserved(self, directory, expected):
        registry = Registry(directory)
        try:
            rows = {row["id"]: dict(row) for row in registry.db.execute("SELECT " + OLD_COLUMNS + " FROM devices")}
            self.assertEqual(expected, rows)
            self.assertEqual(2, registry.db.execute("PRAGMA user_version").fetchone()[0])
            self.assertEqual(0, registry.db.execute("SELECT count(*) FROM sqlite_master WHERE name='devices_spki_prototype'").fetchone()[0])
            self.assertEqual(2, registry.db.execute("SELECT count(*) FROM devices WHERE certificate_id IS NOT NULL").fetchone()[0])
        finally:
            registry.db.close()

    def test_process_loss_at_each_boundary_preserves_prior_devices_and_tokens(self):
        code = r'''
import os,sqlite3,sys
from services.access.registry import Registry
connect=sqlite3.connect
trigger=sys.argv[2]
class Interrupted(sqlite3.Connection):
 def execute(self,sql,*args):
  result=super().execute(sql,*args)
  if sql == 'BEGIN IMMEDIATE': self.armed=True
  if getattr(self,'armed',False) and trigger != 'commit' and trigger in sql: os._exit(81)
  return result
 def commit(self):
  super().commit()
  if getattr(self,'armed',False) and trigger == 'commit': os._exit(81)
sqlite3.connect=lambda *args,**kwargs: connect(*args,**kwargs,factory=Interrupted)
Registry(sys.argv[1])
os._exit(82)
'''
        with tempfile.TemporaryDirectory() as temporary:
            seed = Path(temporary) / "seed"
            expected, _ = legacy_seed(seed)
            for number, trigger in enumerate(("ALTER TABLE devices RENAME", "CREATE TABLE devices (", "INSERT INTO devices(", "DROP TABLE devices_spki_prototype", "PRAGMA user_version=2", "commit")):
                with self.subTest(boundary=trigger):
                    directory = Path(temporary) / str(number)
                    shutil.copytree(seed, directory)
                    result = subprocess.run([sys.executable, "-c", code, str(directory), trigger], capture_output=True, timeout=10)
                    self.assertEqual(81, result.returncode)
                    self.assert_preserved(directory, expected)

    def test_recovers_a_stranded_table_from_the_unpublished_migration(self):
        with tempfile.TemporaryDirectory() as directory:
            expected, schema = legacy_seed(directory)
            connection = sqlite3.connect(Path(directory) / "registry.sqlite", isolation_level=None)
            connection.execute("ALTER TABLE devices RENAME TO devices_spki_prototype")
            connection.execute(schema)  # Previous bug made an empty new table visible before copying.
            connection.close()
            self.assert_preserved(directory, expected)
