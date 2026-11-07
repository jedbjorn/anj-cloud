"""Release numbers survive public history rewriting and reject unsafe allocations."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

from deploy import client_version, release


class ClientVersionTests(unittest.TestCase):
    def test_committed_number_survives_short_history_and_dirty_worktree(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            def git(*args):
                return subprocess.run(['git', '-C', str(repo), *args], check=True, capture_output=True, text=True).stdout.strip()
            git('init', '-q', '-b', 'main')
            path = repo / client_version.VERSION_PATH
            path.parent.mkdir(parents=True)
            path.write_text('{"version_code":167}\n')
            git('add', '.')
            git('-c', 'user.name=Test', '-c', 'user.email=t@example.invalid', 'commit', '-qm', 'release167')
            head = git('rev-parse', 'HEAD')
            self.assertEqual('1', git('rev-list', '--count', head))
            path.write_text('{"version_code":1}\n')
            code, version = client_version.release_version(repo, head)
            self.assertEqual(167, code)
            self.assertTrue(version.endswith('.167'))
            self.assertGreater(code, 166)

    def test_invalid_or_missing_allocation_fails_closed(self):
        for record in ({'version_code': True}, {'version_code': 0}, {'version_code': 2100000001},
                       {'version_code': '167'}, {'version_code': 167, 'extra': 1}, [], None):
            with self.subTest(record=record):
                def runner(*args, **kwargs):
                    return subprocess.CompletedProcess([], 0, json.dumps(record).encode(), b'')
                with self.assertRaises(ValueError):
                    client_version.version_code('.', 'head', runner)
        with self.assertRaises(ValueError):
            client_version.version_code('.', 'head', lambda *a, **kw: subprocess.CompletedProcess([], 1, b'', b''))

    def test_publisher_checks_allocated_number_not_history(self):
        from unittest.mock import patch
        def runner(argv, **kwargs):
            if '--is-shallow-repository' in argv:
                data = b'false\n'
            elif 'show' in argv:
                data = b'{"version_code":167}'
            else:
                data = b''
            return subprocess.CompletedProcess(argv, 0, data, b'')
        with patch.object(release, 'REPO', Path('/unused')):
            release.check_source({'source_head': 'a'*40, 'version_code': 167}, fetch=False, runner=runner)
            with self.assertRaises(release.Refused):
                release.check_source({'source_head': 'a'*40, 'version_code': 6}, fetch=False, runner=runner)
