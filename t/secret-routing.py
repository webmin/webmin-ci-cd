#!/usr/bin/env python3
"""Exercise secret selection with a synthetic archive and a local GitHub stub."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import zipfile

SCRIPT = Path(__file__).resolve().parents[1] / 'build' / 'sync-github-secrets.bash'


class SecretRouting(unittest.TestCase):
    def run_sync(self, *args):
        """Run the real helper with fixture values and no GitHub access."""
        with tempfile.TemporaryDirectory(prefix='secret-routing-') as directory:
            work = Path(directory)
            archive = work / 'fixture.zip'
            # Distinct fixture values reveal which product supplied each path.
            with zipfile.ZipFile(archive, 'w') as fixture:
                for product in ('webmin', 'virtualmin', 'cloudmin'):
                    for name in ('DEV_UPLOAD_SSH_DIR', 'PRERELEASE_UPLOAD_SSH_DIR'):
                        fixture.writestr(f'{product}__{name}', f'fixture:{product}:{name}')
            log = work / 'calls.jsonl'
            gh = work / 'gh'
            gh.write_text(f'#!{sys.executable}\n' + '''import json, os, sys
assert sys.argv[1:3] == ['secret', 'set'], sys.argv
with open(os.environ['FIXTURE_CALLS'], 'a') as log:
    log.write(json.dumps([sys.argv[3], sys.argv[5], sys.stdin.read()]) + '\\n')
''')
            gh.chmod(0o700)
            # The explicit fixture archive avoids all real credential files.
            environment = {
                'PATH': f'{work}:/usr/bin:/bin',
                'ENV_SECRETS_ZIP': str(archive),
                'FIXTURE_CALLS': str(log),
            }
            result = subprocess.run(
                ['bash', str(SCRIPT), *args,
                 '-s', 'DEV_UPLOAD_SSH_DIR', '-s', 'PRERELEASE_UPLOAD_SSH_DIR'],
                input='\n', text=True, capture_output=True, env=environment,
                cwd=work, timeout=30,
            )
            calls = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
            return result, calls

    def test_targeted_cloudmin_repositories(self):
        """Both Cloudmin editions retain their product prefix with plain -r."""
        result, calls = self.run_sync('-r', 'virtualmin/cloudmin-gpl', '-r', 'virtualmin/cloudmin-pro')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(calls), 4)
        for name, repo, value in calls:
            self.assertIn(repo, ('virtualmin/cloudmin-gpl', 'virtualmin/cloudmin-pro'))
            self.assertEqual(value, f'fixture:cloudmin:{name}')

    def test_targeted_matches_bulk(self):
        """Selecting a repository separately uses the same files as a bulk run."""
        bulk_result, bulk = self.run_sync()
        self.assertEqual(bulk_result.returncode, 0, bulk_result.stdout + bulk_result.stderr)
        repos = ('virtualmin/cloudmin-gpl', 'virtualmin/cloudmin-pro',
                 'virtualmin/Cloudmin-Config', 'virtualmin/virtualmin-gpl', 'webmin/webmin')
        for repo in repos:
            with self.subTest(repo=repo):
                result, targeted = self.run_sync('-r', repo)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(targeted, [call for call in bulk if call[1] == repo])

    def test_explicit_prefix(self):
        """Existing calls with an explicit secret prefix remain supported."""
        result, calls = self.run_sync('-r', 'virtualmin/cloudmin-gpl cloudmin')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(calls), 2)
        for name, repo, value in calls:
            self.assertEqual(repo, 'virtualmin/cloudmin-gpl')
            self.assertEqual(value, f'fixture:cloudmin:{name}')

    def test_unknown_repository(self):
        """An unknown repository is refused before any secret is sent."""
        result, calls = self.run_sync('-r', 'virtualmin/unknown-fixture')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Invalid repository', result.stdout)
        self.assertEqual(calls, [])


if __name__ == '__main__':
    unittest.main()
