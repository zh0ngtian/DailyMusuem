import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'publish_github_release.py'

class FakeGithub:
    def __init__(self, sha, assets=None):
        self.sha = sha
        self.assets = assets
        self.uploaded = []
        self.created = False
        self.download_dirs = []
    def resolve_tag(self, tag):
        return self.sha
    def release_assets(self, tag):
        return None if self.assets is None else list(self.assets)
    def create(self, tag, sha, notes):
        self.created = True
        self.notes = notes
        self.assets = {}
    def download(self, tag, names, destination):
        self.download_dirs.append(destination)
        for name in names:
            (destination / name).write_bytes(self.assets[name])
    def upload(self, tag, paths):
        for path in paths:
            self.uploaded.append(path.name)
            self.assets[path.name] = path.read_bytes()

class GithubReleaseTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(SCRIPT.is_file(), 'Missing immutable GitHub release publisher')
        spec = importlib.util.spec_from_file_location('publish_github_release', SCRIPT)
        self.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.module)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.packages = Path(self.tmp.name)
        self.sha = 'a' * 40
        self.tasks = [{'id': 'task-1', 'sha': 'b' * 40, 'validation': {'checks': [{'name': 'unit', 'status': 'passed'}]}}]
        self.batch = {'batchId': 'batch-1', 'tasks': self.tasks, 'frozenSHA': self.sha,
                      'prepared': {'version': '1.2.0', 'buildNumber': '10'}}
        ipa = b'fixture IPA bytes'
        digest = hashlib.sha256(ipa).hexdigest()
        self.metadata = dict(tag='v1.2.0', commit=self.sha, version='1.2.0', build='10', signed=False,
                             widgetGroups=10, authConfigured=True, bytes=len(ipa), sha256=digest,
                             bundleIDs=['tech.zh0ngtian.MuseumMuse', 'tech.zh0ngtian.MuseumMuse.widget'],
                             batchId='batch-1', tasks=self.tasks, runId='123')
        (self.packages / 'MuseumMuse-unsigned.ipa').write_bytes(ipa)
        (self.packages / 'MuseumMuse-unsigned.ipa.sha256').write_text(f'{digest}  MuseumMuse-unsigned.ipa\n')
        (self.packages / 'MuseumMuse-unsigned.json').write_text(json.dumps(self.metadata))
        self.assets = {p.name: p.read_bytes() for p in self.packages.iterdir()}

    def publish(self, github):
        return self.module.publish_release(self.packages, 'v1.2.0', self.batch, 'https://example.com/run/123', '123', github,
                                           '本版本修复小组件刷新问题')

    def test_creates_and_uploads_one_package_set(self):
        github = FakeGithub(self.sha)
        self.publish(github)
        self.assertTrue(github.created)
        self.assertIn('本版本修复小组件刷新问题', github.notes)
        self.assertCountEqual(github.uploaded, self.assets)

    def test_missing_chinese_notes_prevents_external_publication(self):
        github = FakeGithub(self.sha)
        with self.assertRaisesRegex(ValueError, 'Chinese'):
            self.module.publish_release(self.packages, 'v1.2.0', self.batch, 'https://example.com/run/123', '123', github, '')
        self.assertFalse(github.created)
        self.assertEqual(github.uploaded, [])

    def test_existing_identical_assets_are_idempotent_and_downloaded_fresh(self):
        github = FakeGithub(self.sha, dict(self.assets))
        self.publish(github)
        self.assertEqual(github.uploaded, [])
        self.assertFalse(github.created)
        self.assertEqual(len(github.download_dirs), 1)
        self.assertFalse(github.download_dirs[0].exists())

    def test_uploads_only_missing_assets(self):
        github = FakeGithub(self.sha, {'MuseumMuse-unsigned.ipa': self.assets['MuseumMuse-unsigned.ipa']})
        self.publish(github)
        self.assertCountEqual(github.uploaded, ['MuseumMuse-unsigned.ipa.sha256', 'MuseumMuse-unsigned.json'])

    def test_mismatched_existing_ipa_checksum_or_metadata_preserves_assets(self):
        for name in self.assets:
            with self.subTest(name=name):
                existing = dict(self.assets)
                if name.endswith('.json'):
                    metadata = dict(self.metadata, runId='older-run')
                    existing[name] = json.dumps(metadata).encode()
                else:
                    existing[name] += b'corruption'
                github = FakeGithub(self.sha, existing)
                with self.assertRaises(ValueError):
                    self.publish(github)
                self.assertEqual(github.uploaded, [])
                self.assertEqual(github.assets, existing)

    def test_tag_must_resolve_to_frozen_commit(self):
        github = FakeGithub('c' * 40)
        with self.assertRaises(ValueError):
            self.publish(github)
        self.assertFalse(github.created)

    def test_local_metadata_must_bind_batch_tasks_run_and_checksums(self):
        for field, value in [('batchId', 'other'), ('tasks', []), ('runId', 'other'), ('commit', 'c' * 40), ('sha256', '0' * 64), ('widgetGroups', 9)]:
            with self.subTest(field=field):
                (self.packages / 'MuseumMuse-unsigned.json').write_text(json.dumps(dict(self.metadata, **{field: value})))
                github = FakeGithub(self.sha)
                with self.assertRaises(ValueError):
                    self.publish(github)
                self.assertFalse(github.created)

if __name__ == '__main__':
    unittest.main()
