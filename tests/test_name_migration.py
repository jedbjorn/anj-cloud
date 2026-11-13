"""The one-time name migration (spec #49 Gateway, D4; AC9).

The real gateway runs the pass over an in-process fake Nextcloud that answers the PROPFIND
(resourcetype, fileid, owner-id) and MOVE calls the way Nextcloud 33.0.10 does. The operator
path runs through the in-process private socket handler with a fake occ, as in
test_sharing_operator.
"""

import asyncio
import base64
import io
import json
import posixpath
from unittest import mock
from urllib.parse import quote, unquote, urlsplit

from aiohttp import web
from aiohttp.test_utils import TestServer

import unittest

from gateway_harness import Harness
from test_permanent_credentials import admin
from test_sharing_operator import FakeOccStack
from services.access import name_migration, name_rule
from services.access.protocol import Rejection
from services.access.sharing import Principal

LONG = "x" * 300 + ".pdf"


class FakeCloud:
    """Per-user trees: path below the user's files root -> {"id", "owner", "folder"}."""

    def __init__(self):
        self.tokens, self.tree = {}, {}
        self.next_id = 100
        self.moves = 0
        self.fail = []  # per MOVE, in order: a status, "lost" (not applied) or "applied-lost"
        self.fail_listing = 0  # PROPFINDs to refuse once a MOVE has been answered
        self.server = None

    def user(self, uid):
        self.tokens["token-" + uid] = uid
        self.tree[uid] = {}

    def add(self, uid, path, folder=False, owner=None, fileid=None):
        if fileid is None:
            self.next_id += 1
            fileid = self.next_id
        self.tree[uid][path] = {"id": fileid, "owner": owner or uid, "folder": folder}

    def names(self, uid):
        return sorted(self.tree[uid])

    def caller(self, request):
        try:
            uid, token = base64.b64decode(request.headers.get("Authorization", "").split(" ", 1)[1]).decode().split(":", 1)
        except (IndexError, ValueError):
            return None
        return uid if self.tokens.get(token) == uid else None

    async def handle(self, request):
        uid = self.caller(request)
        if uid is None:
            return web.Response(status=401)
        if request.path == "/ocs/v2.php/cloud/user":
            return web.json_response({"ocs": {"data": {"id": uid}}})
        root = "/remote.php/dav/files/%s/anj-cloud" % uid
        path = unquote(request.path).rstrip("/")
        if path != root and not path.startswith(root + "/"):
            return web.Response(status=404)
        relative, tree = path[len(root) + 1:], self.tree[uid]
        if request.method == "PROPFIND":
            if self.fail_listing and self.moves:
                self.fail_listing -= 1
                return web.Response(status=503)
            if relative and relative not in tree:
                return web.Response(status=404)
            entries = [(root + "/" + relative if relative else root, {"id": 1, "owner": uid, "folder": True})]
            entries += [(root + "/" + key, item) for key, item in sorted(tree.items()) if posixpath.dirname(key) == relative]
            return web.Response(status=207, body=(
                '<?xml version="1.0"?><d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">' + "".join(
                    "<d:response><d:href>%s%s</d:href><d:propstat><d:prop><d:resourcetype>%s</d:resourcetype>"
                    "<oc:fileid>%d</oc:fileid><oc:owner-id>%s</oc:owner-id></d:prop></d:propstat></d:response>"
                    % (quote(href), "/" if item["folder"] else "", "<d:collection/>" if item["folder"] else "", item["id"], item["owner"])
                    for href, item in entries) + "</d:multistatus>").encode())
        if request.method == "MOVE":
            self.moves += 1
            failure = self.fail.pop(0) if self.fail else None
            if isinstance(failure, int):
                return web.Response(status=failure)
            if failure == "lost":
                return web.Response(status=500)
            destination = unquote(urlsplit(request.headers["Destination"]).path).rstrip("/")[len(root) + 1:]
            if relative not in tree:
                return web.Response(status=404)
            if destination in tree and request.headers.get("Overwrite") == "F":
                return web.Response(status=412)
            for key in [k for k in tree if k == relative or k.startswith(relative + "/")]:
                tree[destination + key[len(relative):]] = tree.pop(key)
            return web.Response(status=500 if failure == "applied-lost" else 201)
        return web.Response(status=405)

    async def start(self):
        app = web.Application()
        app.router.add_route("*", "/{path:.*}", self.handle)
        self.server = TestServer(app)
        await self.server.start_server()
        return str(self.server.make_url("")).rstrip("/")


class MigrationTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.harness = Harness()
        await self.harness.start()
        self.gateway = self.harness.gateway
        self.cloud = FakeCloud()
        for uid in ("alice", "bob"):
            self.cloud.user(uid)
        self.gateway.backend = await self.cloud.start()

    async def asyncTearDown(self):
        await self.cloud.server.close()
        await self.harness.stop()

    async def migrate(self, uid="alice"):
        return await name_migration.migrate(self.gateway, Principal(uid, "token-" + uid))

    def fence(self):
        return self.gateway.registry.db.execute("SELECT state FROM mutation_fence WHERE singleton=1").fetchone()[0]

    def events(self):
        return [line for line in self.harness.lines() if line["event"] == "name-migration"]

    async def test_untrimmed_and_over_long_names_are_renamed_once_and_a_second_pass_changes_nothing(self):
        cloud = self.cloud
        cloud.add("alice", "Documents", folder=True)
        cloud.add("alice", " Trip ", folder=True)
        cloud.add("alice", " Trip /photo.jpg ")
        cloud.add("alice", "Documents/" + LONG)
        cloud.add("alice", "Documents/fine.txt")
        cloud.add("alice", "Documents/a:b?.txt")
        trip, photo, long = (cloud.tree["alice"][k]["id"] for k in (" Trip ", " Trip /photo.jpg ", "Documents/" + LONG))
        counts = await self.migrate()
        self.assertEqual({"folders": 3, "renamed": 3, "unresolved": 0, "failed": 0}, counts)
        fitted = name_rule.cleanup(LONG)
        self.assertEqual((250, ".pdf"), (len(fitted.encode()), fitted[-4:]))
        self.assertEqual(["Documents", "Documents/a:b?.txt", "Documents/fine.txt", "Documents/" + fitted, "Trip", "Trip/photo.jpg"],
                         cloud.names("alice"))
        # The same items, renamed: their file IDs are unchanged.
        self.assertEqual([trip, photo, long], [cloud.tree["alice"][k]["id"] for k in ("Trip", "Trip/photo.jpg", "Documents/" + fitted)])
        self.assertEqual("clear", self.fence())
        moves = cloud.moves
        self.assertEqual({"folders": 3, "renamed": 0, "unresolved": 0, "failed": 0}, await self.migrate())
        self.assertEqual(moves, cloud.moves)
        # One event line per pass: counts only, never a name or an account.
        events = self.events()
        self.assertEqual([True, True], [event["complete"] for event in events])
        self.assertEqual([3, 0], [event["renamed"] for event in events])
        self.assertEqual({"time", "event", "complete", "folders", "renamed", "unresolved", "failed"}, set(events[0]))
        text = self.harness.stream.getvalue()
        for secret in ("Trip", "photo", "alice", "xxxx"):
            self.assertNotIn(secret, text)

    async def test_the_oldest_item_keeps_the_trimmed_name_and_the_others_get_a_suffix(self):
        cloud = self.cloud
        cloud.add("alice", "report.pdf ", fileid=30)
        cloud.add("alice", " report.pdf", fileid=20)
        cloud.add("alice", "Notes", folder=True, fileid=40)
        cloud.add("alice", "notes ", fileid=10)
        self.assertEqual(3, (await self.migrate())["renamed"])
        tree = cloud.tree["alice"]
        self.assertEqual((20, 30), (tree["report.pdf"]["id"], tree["report (2).pdf"]["id"]))
        # An existing name is never taken: a changed name meeting it by case gets the suffix.
        self.assertEqual((40, 10), (tree["Notes"]["id"], tree["notes (2)"]["id"]))

    async def test_a_share_mounted_here_is_neither_renamed_nor_entered(self):
        cloud = self.cloud
        cloud.add("alice", "Shared", folder=True)
        cloud.add("alice", "Shared/ Recipes ", folder=True, owner="bob")
        cloud.add("alice", "Shared/ Recipes /cake.txt ", owner="bob")
        cloud.add("alice", "Shared/ mine.txt")
        counts = await self.migrate()
        self.assertEqual({"folders": 2, "renamed": 1, "unresolved": 0, "failed": 0}, counts)
        self.assertEqual(["Shared", "Shared/ Recipes ", "Shared/ Recipes /cake.txt ", "Shared/mine.txt"], cloud.names("alice"))

    async def test_a_refused_rename_is_counted_and_the_pass_goes_on(self):
        self.cloud.add("alice", " a.txt")
        self.cloud.add("alice", " b.txt")
        self.cloud.fail = [423]
        self.assertEqual({"folders": 1, "renamed": 1, "unresolved": 0, "failed": 1}, await self.migrate())
        self.assertEqual([" a.txt", "b.txt"], self.cloud.names("alice"))
        self.assertEqual("clear", self.fence())
        # The next pass retries what failed.
        self.assertEqual(1, (await self.migrate())["renamed"])

    async def test_a_lost_answer_is_resolved_by_reading_the_folder_again(self):
        self.cloud.add("alice", " a.txt")
        self.cloud.add("alice", " b.txt")
        self.cloud.fail = ["applied-lost", "lost"]
        self.assertEqual({"folders": 1, "renamed": 1, "unresolved": 0, "failed": 1}, await self.migrate())
        self.assertEqual([" b.txt", "a.txt"], self.cloud.names("alice"))
        self.assertEqual("clear", self.fence())

    async def test_an_unknown_outcome_leaves_writes_fenced_and_ends_the_pass(self):
        self.cloud.add("alice", " a.txt")
        self.cloud.add("alice", " b.txt")
        self.cloud.fail, self.cloud.fail_listing = ["lost"], 1
        with self.assertRaises(Rejection):
            await self.migrate()
        self.assertEqual("dispatched", self.fence())
        self.assertEqual(1, self.cloud.moves)
        self.assertEqual([False], [event["complete"] for event in self.events()])
        # A fenced gateway refuses the next pass before any rename.
        with self.assertRaises(Rejection):
            await self.migrate()
        self.assertEqual(1, self.cloud.moves)

    async def test_the_operator_action_needs_the_owners_token(self):
        self.cloud.add("alice", " a.txt")
        result = await admin(self.gateway, "migrate-names", owner_uid="alice", token="token-alice")
        self.assertEqual(1, result["renamed"])
        with self.assertRaises(RuntimeError):
            await admin(self.gateway, "migrate-names", owner_uid="alice", token="token-bob")
        with self.assertRaises(RuntimeError):
            await admin(self.gateway, "migrate-names", owner_uid="alice", token="token-alice", path="Documents")


class OperatorMigrationTests(MigrationTests):
    """deploy/access_operator.py migrate-names: every enabled account, through temporary owner tokens."""

    async def asyncSetUp(self):
        await super().asyncSetUp()
        from deploy.access_operator import Operator
        from deploy import dev
        self.stack = FakeOccStack(self.harness.directory / "operator-host", self.cloud)
        users = {"alice": "Alice", "bob": "Bob", "carol": "Carol"}
        self.cloud.user("carol")
        occ = self.stack.occ
        self.stack.occ = lambda *args: json.dumps(users) if args[0] == "user:list" else occ(*args)
        self.operator = Operator(self.stack)
        dev.private_directory(self.stack.local)
        loop = asyncio.get_running_loop()
        self.operator.call = lambda action, **data: asyncio.run_coroutine_threadsafe(admin(self.gateway, action, **data), loop).result(10)

    async def test_every_enabled_account_is_migrated_and_its_token_removed(self):
        self.cloud.add("alice", " a.txt")
        self.cloud.add("bob", "b.txt ")
        self.cloud.add("carol", " c.txt")
        self.gateway.registry.account_set("carol", "Carol", enabled=False)
        totals = await asyncio.to_thread(self.operator.migrate_names)
        self.assertEqual({"accounts": 2, "folders": 2, "renamed": 2, "unresolved": 0, "failed": 0, "accounts_failed": 0}, totals)
        self.assertEqual((["a.txt"], ["b.txt"], [" c.txt"]), tuple(self.cloud.names(uid) for uid in ("alice", "bob", "carol")))
        self.assertEqual({}, self.stack.tokens)
        totals = await asyncio.to_thread(self.operator.migrate_names)
        self.assertEqual(0, totals["renamed"])

    async def test_a_refused_pass_is_counted_and_every_token_is_still_removed(self):
        self.cloud.add("alice", " a.txt")
        self.cloud.add("bob", "b.txt ")
        self.cloud.fail = [423]
        totals = await asyncio.to_thread(self.operator.migrate_names)
        self.assertEqual((3, 1, 1, 0), (totals["accounts"], totals["renamed"], totals["failed"], totals["accounts_failed"]))
        # An unknown outcome fences writes: that pass and every later one is refused, none renames.
        self.cloud.fail, self.cloud.fail_listing, self.cloud.moves = ["lost"], 1, 0
        totals = await asyncio.to_thread(self.operator.migrate_names)
        self.assertEqual((0, 3), (totals["accounts"], totals["accounts_failed"]))
        self.assertEqual("dispatched", self.fence())
        self.assertEqual({}, self.stack.tokens)


class DeployHookTests(unittest.TestCase):
    def test_the_deploy_hook_is_best_effort(self):
        from deploy.dev import Stack
        stack = Stack("anj-cloud-review-migration", 18998)
        with mock.patch.object(stack, "run", side_effect=RuntimeError("Command failed (exit 1); output withheld")), \
                mock.patch("sys.stderr", new_callable=io.StringIO) as stderr:
            self.assertIsNone(stack.migrate_names())
        self.assertIn("next deploy runs it again", stderr.getvalue())
        counts = {"accounts": 1, "folders": 2, "renamed": 1, "unresolved": 0, "failed": 0, "accounts_failed": 0}
        with mock.patch.object(stack, "run", return_value=json.dumps(counts)) as run, \
                mock.patch("sys.stderr", new_callable=io.StringIO) as stderr:
            self.assertEqual(counts, stack.migrate_names())
        # The operator CLI runs in the access venv against this project.
        argv = run.call_args.args[0]
        self.assertEqual((str(stack.venv_python), "deploy.access_operator", "anj-cloud-review-migration", "migrate-names"),
                         (argv[0], argv[2], argv[4], argv[-1]))
        self.assertIn('Name migration: {"accounts":1', stderr.getvalue())

    def test_production_runs_the_operator_in_process(self):
        from deploy import prod
        stack = mock.Mock()
        with mock.patch("deploy.access_operator.Operator") as operator:
            operator.return_value.migrate_names.return_value = {"renamed": 0}
            self.assertEqual({"renamed": 0}, prod.ProdStack.name_migration(stack))
        operator.assert_called_once_with(stack)


if __name__ == "__main__":
    unittest.main()
