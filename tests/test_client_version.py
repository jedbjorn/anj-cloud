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


class GitHubVersionTests(unittest.TestCase):
    def check(self, code, records, *, status=0):
        def runner(argv, **kwargs):
            self.assertIn('--paginate', argv)
            self.assertIn('--slurp', argv)
            return subprocess.CompletedProcess(argv, status, json.dumps(records), '')
        return client_version.check_github_version('jedbjorn/anj-cloud', code, runner)

    def test_existing_unified166_allows167(self):
        record = {'tag_name': 'v2026.11.06.166', 'assets': [
            {'name': 'anj-cloud-2026.11.06.166.apk'},
            {'name': 'anj-cloud-macos-arm64-0.1.0+166-2371b402931f.zip'},
            {'name': 'anj-cloud-linux-x86_64-2371b402931f.tar.gz'}]}
        self.assertEqual(166, self.check(167, [[record]]))
        for code in (6, 165, 166):
            with self.subTest(code=code), self.assertRaisesRegex(ValueError, 'not above GitHub'):
                self.check(code, [[record]])

    def test_reuse_on_another_date_and_older_codes_refused_across_pages(self):
        pages = [[{'tag_name': 'android-2026.11.07.167', 'assets': []}],
                 [{'tag_name': 'android-168', 'assets': []}]]
        for code in (166, 167, 168):
            with self.subTest(code=code), self.assertRaisesRegex(ValueError, 'not above GitHub'):
                self.check(code, pages)
        self.assertEqual(168, self.check(169, pages))

    def test_unknown_client_assets_or_inconsistent_metadata_refused(self):
        for record in (
            {'tag_name': 'latest', 'assets': [{'name': 'anj-cloud-unknown.apk'}]},
            {'tag_name': 'v2026.11.07.167', 'assets': [{'name': 'anj-cloud-2026.11.07.168.apk'}]},
            {'tag_name': 'android-bogus', 'assets': []},
        ):
            with self.subTest(record=record), self.assertRaisesRegex(ValueError, 'Cannot determine'):
                self.check(169, [[record]])

    def test_network_and_parse_failures_never_publish(self):
        with self.assertRaisesRegex(ValueError, 'Cannot verify'):
            self.check(167, [], status=1)
        for records in ({}, [None], [[{}]], [[{'tag_name': 'x', 'assets': None}]]):
            with self.subTest(records=records), self.assertRaisesRegex(ValueError, 'Cannot determine'):
                self.check(167, records)
