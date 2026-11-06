"""Review stacks label their containers anj.owner=<tag> (test lifecycle on the VM host); others do not."""

import json
from pathlib import Path
import tempfile
import unittest

from deploy.dev import Stack


class OwnerLabelTests(unittest.TestCase):
    def compose_argv(self, project):
        stack = Stack(project, 18999)
        with tempfile.TemporaryDirectory() as directory:
            stack.local = Path(directory) / project
            calls = []
            stack.run = lambda argv, data=None: calls.append(argv) or ""
            stack.compose("ps")
            labels = stack.local / "owner-labels.json"
            content = json.loads(labels.read_text()) if labels.exists() else None
            return calls[0], content

    def test_review_stack_labels_every_service_with_its_tag(self):
        argv, content = self.compose_argv("anj-cloud-review-share")
        services = json.loads((Path(__file__).resolve().parent.parent / "deploy/compose.json").read_text())["services"]
        self.assertEqual(2, argv.count("--file"))
        self.assertEqual({name: {"labels": {"anj.owner": "share"}} for name in services}, content["services"])

    def test_dev_and_untagged_stacks_are_not_labelled(self):
        for project in ("anj-cloud-dev", "anj-cloud-review", "anj-cloud-test-x"):
            argv, content = self.compose_argv(project)
            self.assertEqual((1, None), (argv.count("--file"), content), project)
