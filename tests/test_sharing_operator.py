"""The operator CLI's sharing and account paths (spec #26; decisions #79 (b), #80 (3), (4)).

Operator.call is routed to the in-process gateway socket handler; occ is a fake that models app
tokens, so the temporary owner token's creation and removal are observable without Docker.
"""

import asyncio
import json

from test_permanent_credentials import admin
# Import the module, not the class, so the base suite is not collected a second time here.
import test_sharing

class FakeOccStack:
    """Operator-side stack: records occ calls and models app tokens; no Docker."""

    def __init__(self, directory, cloud=None):
        self.local = directory
        self.calls = []
        self.tokens = {}  # (uid, name) -> {"id", "token"}
        self.cloud = cloud
        self.next_id = 100

    def occ(self, *args):
        self.calls.append(args)
        if args[0] == "user:auth-tokens:add":
            uid, name = args[-1], args[args.index("--name") + 1]
            token = ("T%d" % self.next_id).ljust(72, "x")
            self.tokens[(uid, name)] = {"id": self.next_id, "token": token}
            self.next_id += 1
            if self.cloud is not None:
                self.cloud.tokens[token] = uid
            return "app password:\n" + token + "\n"
        if args[0] == "user:auth-tokens:list":
            uid = args[-1]
            return json.dumps([{"id": row["id"], "name": name} for (owner, name), row in self.tokens.items() if owner == uid])
        if args[0] == "user:auth-tokens:delete":
            uid, token_id = args[-2], int(args[-1])
            for key, row in list(self.tokens.items()):
                if key[0] == uid and row["id"] == token_id:
                    del self.tokens[key]
                    if self.cloud is not None:
                        self.cloud.tokens.pop(row["token"], None)
        return ""


class OperatorSharingTests(test_sharing.SharingTests):
    """The operator CLI's sharing and account paths against the in-process gateway socket handler."""

    async def asyncSetUp(self):
        await super().asyncSetUp()
        from deploy.access_operator import Operator
        from deploy import dev
        self.stack = FakeOccStack(self.harness.directory / "operator-host", self.cloud)
        self.operator = Operator(self.stack)
        dev.private_directory(self.stack.local)
        loop = asyncio.get_running_loop()
        # Operator.call is synchronous (Compose exec); route it to the socket handler on this loop.
        self.operator.call = lambda action, **data: asyncio.run_coroutine_threadsafe(admin(self.gateway, action, **data), loop).result(10)

    async def run_operator(self, method, *args, **kwargs):
        return await asyncio.to_thread(getattr(self.operator, method), *args, **kwargs)

    async def test_owner_without_device_shares_through_a_temporary_token_that_is_removed(self):
        self.cloud.folders["carol"].add("Recipes")
        row = await self.run_operator("sharing", "share", owner="carol", path="Recipes", recipient="bob", rights="write")
        self.assertEqual(("carol", 15), (self.cloud.shares[row["share_id"]]["uid_owner"], self.cloud.shares[row["share_id"]]["permissions"]))
        self.assertEqual({}, self.stack.tokens)
        self.assertFalse((self.operator.directory / "reconciliation-token.json").exists())
        listed = await self.run_operator("sharing", "shares", owner="carol")
        self.assertEqual([row["share_id"]], [r["share_id"] for r in listed])
        # One access level (decision #155): a change to View only is refused, full access stays.
        with self.assertRaises(RuntimeError):
            await self.run_operator("sharing", "share-update", owner="carol", share_id=row["share_id"], rights="read")
        self.assertEqual({}, self.stack.tokens)
        updated = await self.run_operator("sharing", "share-update", owner="carol", share_id=row["share_id"], rights="write")
        self.assertEqual("edit", updated["permission"])
        self.assertEqual({"state": "removed"}, await self.run_operator("sharing", "unshare", owner="carol", share_id=row["share_id"]))
        self.assertEqual({}, self.stack.tokens)
        # A refused call still removes its token.
        with self.assertRaises(RuntimeError):
            await self.run_operator("sharing", "share", owner="carol", path="Missing", recipient="bob", rights="read")
        self.assertEqual({}, self.stack.tokens)
        with self.assertRaises(RuntimeError):
            await self.run_operator("sharing", "shares", device_id=self.alice_id, owner="carol")

    async def test_account_set_disables_gateway_before_nextcloud_and_enables_in_reverse(self):
        result = await self.run_operator("account_set", "alice", enabled=False)
        self.assertEqual(("disabled", False), (result["nextcloud"], result["account"]["enabled"]))
        self.assertEqual([("user:disable", "--", "alice")], [c for c in self.stack.calls if c[0] in ("user:enable", "user:disable")])
        # The owner's list was read with a temporary owner token, minted then removed.
        self.assertTrue(any(c[0] == "user:auth-tokens:add" and c[-1] == "alice" for c in self.stack.calls))
        self.assertEqual({}, self.stack.tokens)
        self.assertFalse((self.operator.directory / "reconciliation-token.json").exists())
        result = await self.run_operator("account_set", "alice", enabled=True)
        self.assertEqual(("user:enable", "--", "alice"), [c for c in self.stack.calls if c[0] in ("user:enable", "user:disable")][-1])
        self.assertTrue(result["account"]["enabled"])
        result = await self.run_operator("account_set", "dave", display_name="Dave")
        self.assertEqual((None, "Dave"), (result["nextcloud"], result["account"]["display_name"]))
        self.assertEqual(2, len([c for c in self.stack.calls if c[0] in ("user:enable", "user:disable")]))

    async def test_a_refused_disable_never_disables_the_nextcloud_account(self):
        await self.share()
        self.cloud.fail_owner_listing.add("alice")
        with self.assertRaises(RuntimeError) as refused:
            await self.run_operator("account_set", "alice", enabled=False)
        self.assertIn("not disabled", str(refused.exception))
        self.assertEqual([], [c for c in self.stack.calls if c[0] in ("user:enable", "user:disable")])
        self.assertTrue(self.gateway.registry.account("alice")["enabled"])

    async def test_cli_disable_exits_non_zero_without_occ(self):
        import io
        from contextlib import redirect_stderr, redirect_stdout
        from unittest.mock import patch
        from deploy import access_operator
        self.cloud.fail_owner_listing.add("alice")
        await self.share()
        operator = self.operator
        with patch.object(access_operator, "Operator", lambda stack: operator), \
                patch.object(access_operator, "stack_for", lambda *args: self.stack), \
                patch("sys.argv", ["access_operator", "account-set", "alice", "--disable"]), \
                redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()) as errors:
            code = await asyncio.to_thread(access_operator.main)
        self.assertEqual(1, code)
        self.assertIn("not disabled", errors.getvalue())
        self.assertEqual([], [c for c in self.stack.calls if c[0] in ("user:enable", "user:disable")])

    for _name in [name for name in dir(test_sharing.SharingTests) if name.startswith("test_")]:
        locals()[_name] = None
    del _name
