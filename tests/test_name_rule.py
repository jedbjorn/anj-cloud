"""The name rule (spec #49 D2): services/access/name_rule.py runs the shared `rule` vectors.

apps/client/test/name_rule_test.dart runs the same vectors against the client's NameRule.
"""

import json
from pathlib import Path
import unittest

from services.access import name_rule, portable_names
from services.access.name_rule import Entry

ROOT = Path(__file__).resolve().parent.parent
RULE = json.loads((ROOT / "tests/name_policy_vectors.json").read_text(encoding="utf-8"))["rule"]


def entries(vector):
    return [Entry(name, fileid, folder) for name, fileid, folder in vector["entries"]]


def orders(items):
    """The listing in every rotation, forwards and backwards."""
    for start in range(len(items)):
        rotated = items[start:] + items[:start]
        yield rotated
        yield rotated[::-1]


class NameRuleVectorTests(unittest.TestCase):
    def test_version_and_constants_match_the_vectors(self):
        self.assertEqual(RULE["version"], name_rule.RULE_VERSION)
        self.assertEqual(RULE["maxBytes"], name_rule.MAX_BYTES)
        self.assertEqual(set(RULE["whitespace"]), name_rule.WHITESPACE)

    def test_cleanup(self):
        for vector in RULE["cleanup"]:
            with self.subTest(name=vector["name"], siblings=vector["siblings"]):
                result = name_rule.cleanup(vector["name"], vector["siblings"], vector["folder"])
                self.assertEqual(vector["result"], result)
                self.assertEqual(result, name_rule.cleanup(result, vector["siblings"], vector["folder"]))
                if result != vector["name"]:  # A rename never lands on a sibling's name.
                    self.assertNotIn(portable_names.fold_key(result), {portable_names.fold_key(s) for s in vector["siblings"]})

    def test_cloud_check(self):
        for vector in RULE["cloudCheck"]:
            with self.subTest(name=vector["name"]):
                self.assertEqual(vector["reason"], name_rule.cloud_check(vector["name"]))
        self.assertEqual(set(name_rule.REASONS), {vector["reason"] for vector in RULE["cloudCheck"]} - {None})

    def test_cleanup_leaves_only_residual_problems(self):
        # What cleanup cannot fix is the residual error row (no lookalike, or no room for the stem), or a
        # .part/.filepart file, which clients keep as a local temporary. No room for a ` (n)` leaves the
        # name as it was, untrimmed included.
        residual = {"forbiddenCharacter", "forbiddenName", "forbiddenExtension", "tooLong"}
        for vector in RULE["cleanup"]:
            with self.subTest(name=vector["name"]):
                unchanged = {"untrimmed"} if vector["result"] == vector["name"] else set()
                self.assertIn(name_rule.cloud_check(vector["result"]), residual | unchanged | {None})
                if vector["folder"]:  # Decision #195: only a file may stay a .part/.filepart temporary.
                    self.assertNotEqual("forbiddenExtension", name_rule.cloud_check(vector["result"]))

    def test_local_names_are_stable_under_sibling_reordering(self):
        for vector in RULE["localNames"]:
            items = entries(vector)
            with self.subTest(os=vector["os"], entries=vector["entries"]):
                for listing in orders(items):
                    self.assertEqual(vector["local"], name_rule.local_names(listing, vector["os"]))
                for item in items:
                    self.assertEqual(vector["local"][item.name], name_rule.local_name(item.name, items[::-1], vector["os"]))

    def test_local_names_are_one_to_one_and_reverse(self):
        for vector in RULE["localNames"]:
            items, os = entries(vector), vector["os"]
            with self.subTest(os=os, entries=vector["entries"]):
                local = name_rule.local_names(items, os)
                named = [item for item in items if local[item.name] is not None]  # None: the residual row.
                keys = {portable_names.fold_key(local[item.name]) if os in ("windows", "macos") else local[item.name]
                        for item in named}
                self.assertEqual(len(named), len(keys))
                for item in named:
                    self.assertEqual(item.name, name_rule.cloud_name(local[item.name], items, os))
                    if os == "windows":
                        self.assertIsNone(portable_names.check(local[item.name]))

    def test_reverse(self):
        for vector in RULE["reverse"]:
            with self.subTest(os=vector["os"], local=vector["local"]):
                self.assertEqual(vector["cloud"], name_rule.cloud_name(vector["local"], entries(vector), vector["os"]))

    def test_an_item_missing_from_the_listing_is_the_newest(self):
        listing = [Entry("Report.pdf", 7)]
        self.assertEqual("report (2).pdf", name_rule.local_name("report.pdf", listing, "windows"))
        with self.assertRaises(ValueError):
            name_rule.local_names(listing, "beos")


if __name__ == "__main__":
    unittest.main()
