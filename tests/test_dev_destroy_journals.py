"""`deploy/dev.py destroy` removes the destroyed project's operator journals (SC-055).

A fake Compose stands in for Docker: `exec ... access.admin` answers from an in-memory registry
and `down --volumes` empties it, as deleting the registry volume does. Create (an approved
pairing with its journal), destroy, recreate, then `reconcile` must find no stale journal.
"""

import json
from pathlib import Path
import tempfile
import unittest

from deploy.access_operator import Operator, atomic_json
from deploy.dev import Stack


class FakeCompose:
    """One project's containers and volumes: the gateway registry lives in the volumes."""

    def __init__(self):
        self.registry, self.downs = {}, []

    def run(self, argv, data=None):
        if "down" in argv:
            self.downs.append(argv)
            if "--volumes" in argv:
                self.registry = {}
            return ""
        if "access.admin" in argv:
            body = json.loads(data)
            if body["action"] == "inspect":
                row = self.registry.get(body["pairing_id"])
                if row is None:
                    error = RuntimeError("Command failed (exit 1); output withheld: docker")
                    error.captured_stdout = json.dumps({"error": "Unknown pairing"})
                    raise error
                return json.dumps(row)
            if body["action"] == "devices":
                return json.dumps([{"id": row["device"], "state": "active", "token_id": "7"}
                                   for row in self.registry.values()])
            raise AssertionError(body["action"])
        if "occ" in argv and "user:auth-tokens:list" in argv:
            return json.dumps([{"id": 7, "name": "anj-device-d1"}])
        raise AssertionError(argv)


class DestroyJournalTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="anj-destroy-test-"))
        self.addCleanup(__import__("shutil").rmtree, self.root, ignore_errors=True)

    def stack(self, project, compose):
        stack = Stack(project, 18999)
        stack.local = self.root / project
        stack.run = compose.run
        return stack

    def create(self, stack, compose, pairing="p1", device="d1"):
        """An approved pairing as `approve` leaves it: registry row plus its journal."""
        compose.registry[pairing] = {"id": pairing, "state": "approved", "device": device, "uid": "anj-fixture-alice"}
        operator = Operator(stack)
        with operator.lock():
            atomic_json(operator.journals / f"{device}.json",
                        {"pairing_id": pairing, "name": "anj-device-" + device, "state": "active", "device": device})
            (operator.journals / f"{device}.crt").write_text("leaf")
            reissue = operator.journals / "reissue"
            reissue.mkdir(mode=0o700, exist_ok=True)
            atomic_json(reissue / f"{device}.json", {"device": device, "state": "committed"})
        atomic_json(operator.directory / "reconciliation-token.json", {"uid": "anj-fixture-alice", "name": "anj-reconciliation-x"})
        (operator.directory / "issuer.crt").write_text("issuer")
        return operator

    def test_create_destroy_recreate_reconciles_with_no_stale_journal(self):
        compose = FakeCompose()
        stack = self.stack("anj-cloud-review-w6b", compose)
        operator = self.create(stack, compose)
        self.assertEqual([{"pairing_id": "p1", "state": "active"}], operator.reconcile())
        stack.destroy()
        self.assertEqual(1, len(compose.downs))
        self.assertFalse(operator.journals.exists())
        self.assertFalse((operator.directory / "reconciliation-token.json").exists())
        # The issuer and the lock stay: only state about the deleted volumes goes.
        self.assertEqual("issuer", (operator.directory / "issuer.crt").read_text())
        # Recreated: a fresh, empty registry. Reconcile finds nothing stale.
        self.assertEqual([], Operator(self.stack("anj-cloud-review-w6b", compose)).reconcile())

    def test_without_the_removal_the_recreated_stack_fails_unknown_pairing(self):
        # The SC-055 failure itself, so the test above is known to catch it.
        compose = FakeCompose()
        stack = self.stack("anj-cloud-review-w6b", compose)
        operator = self.create(stack, compose)
        stack.compose("down", "--volumes", "--timeout", "30")  # the old destroy
        with self.assertRaisesRegex(RuntimeError, "Unknown pairing"):
            operator.reconcile()

    def test_only_the_destroyed_projects_journals_go(self):
        mine, other = FakeCompose(), FakeCompose()
        stack = self.stack("anj-cloud-review-w6b", mine)
        kept = self.create(self.stack("anj-cloud-review-w4", other), other, pairing="p2", device="d2")
        self.create(stack, mine)
        stack.destroy()
        self.assertTrue((kept.journals / "d2.json").exists())
        self.assertTrue((kept.journals / "reissue" / "d2.json").exists())
        self.assertTrue((kept.directory / "reconciliation-token.json").exists())
        self.assertEqual([{"pairing_id": "p2", "state": "active"}], kept.reconcile())

    def test_a_failed_down_keeps_the_journals(self):
        compose = FakeCompose()
        stack = self.stack("anj-cloud-review-w6b", compose)
        operator = self.create(stack, compose)

        def failing(argv, data=None):
            if "down" in argv:
                raise RuntimeError("Command failed (exit 1); output withheld: docker")
            return compose.run(argv, data)

        stack.run = failing
        with self.assertRaises(RuntimeError):
            stack.destroy()
        self.assertTrue((operator.journals / "d1.json").exists())

    def test_a_symlinked_journals_directory_is_refused_and_its_target_kept(self):
        compose = FakeCompose()
        stack = self.stack("anj-cloud-review-w6b", compose)
        operator = Operator(stack)
        outside = self.root / "outside"
        outside.mkdir()
        (outside / "keep.json").write_text("{}")
        operator.directory.mkdir(parents=True)
        operator.journals.symlink_to(outside)
        with self.assertRaisesRegex(RuntimeError, "symlinked journals"):
            stack.destroy()
        self.assertTrue((outside / "keep.json").exists())

    def test_the_review_fixtures_reconcile_reads_the_directory_destroy_clears(self):
        # deploy/windows_admin_fixture.py (and the other review fixtures) reconcile through
        # Operator(Stack(project, port)): the same project directory destroy empties, so after a
        # stack-up following destroy they see only the current stack's journals.
        stack = Stack("anj-cloud-review-w6b", 18873)
        self.assertEqual(stack.local / "operator" / "journals", Operator(stack).journals)
        self.assertEqual(Path(__file__).resolve().parent.parent / "deploy/.local/anj-cloud-review-w6b", stack.local)

    def test_a_project_never_set_up_destroys_cleanly(self):
        compose = FakeCompose()
        self.stack("anj-cloud-review-w6b", compose).destroy()
        self.assertEqual(1, len(compose.downs))


if __name__ == "__main__":
    unittest.main()
