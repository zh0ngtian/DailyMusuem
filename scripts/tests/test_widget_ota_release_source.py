import fcntl
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import zipfile

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
spec = importlib.util.spec_from_file_location('widget_ota_publisher', SCRIPTS / 'publish_ios_widget_ota.py')
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)
SHA = 'a' * 40
BATCH = 'a6bb18cf-ad6a-468e-a40e-222b21b2f4d3'

class WidgetOTAReleaseSourceTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.ipa = self.root / 'signed-fixture.ipa'
        self.infos = [dict(CFBundleIdentifier='tech.zh0ngtian.MuseumMuse', CFBundleVersion='10',
                           CFBundleShortVersionString='1.2.0', MuseumReleaseSourceCommit=SHA, MuseumReleaseBatchID=BATCH),
                      dict(CFBundleIdentifier='tech.zh0ngtian.MuseumMuse.widget', CFBundleVersion='10',
                           CFBundleShortVersionString='1.2.0', MuseumReleaseSourceCommit=SHA, MuseumReleaseBatchID=BATCH,
                           NSExtension={'NSExtensionPointIdentifier': 'com.apple.widgetkit-extension'})]
        self.write_ipa()

    def write_ipa(self, include_widget=True):
        with zipfile.ZipFile(self.ipa, 'w') as archive:
            archive.writestr('Payload/DailyMuseum.app/Info.plist', plistlib.dumps(self.infos[0]))
            if include_widget:
                archive.writestr('Payload/DailyMuseum.app/PlugIns/DailyMuseumWidgetExtension.appex/Info.plist', plistlib.dumps(self.infos[1]))

    def provenance(self, sha=SHA, batch=BATCH):
        self.assertTrue(hasattr(publisher, 'release_provenance'), 'Missing independent OTA release provenance gate')
        return publisher.release_provenance(self.ipa, sha, batch)

    def test_exact_two_target_provenance_returns_package_values(self):
        self.assertEqual(self.provenance(), {'sourceCommit': SHA, 'batchId': BATCH})

    def test_bad_or_foreign_target_source_and_batch_are_rejected(self):
        for index, key, value in [(0, 'MuseumReleaseSourceCommit', 'b' * 40),
                                  (1, 'MuseumReleaseSourceCommit', 'b' * 40),
                                  (0, 'MuseumReleaseBatchID', 'other'),
                                  (1, 'MuseumReleaseBatchID', 'other'),
                                  (1, 'CFBundleIdentifier', 'foreign.widget')]:
            with self.subTest(index=index, key=key):
                original = dict(self.infos[index])
                self.infos[index][key] = value
                self.write_ipa()
                with self.assertRaises(ValueError):
                    self.provenance()
                self.infos[index] = original

    def test_missing_target_or_source_field_is_rejected(self):
        self.write_ipa(include_widget=False)
        with self.assertRaises(ValueError):
            self.provenance()
        self.infos[1].pop('MuseumReleaseBatchID')
        self.write_ipa()
        with self.assertRaises(ValueError):
            self.provenance()

    def test_invalid_sha_or_batch_context_is_rejected(self):
        for sha, batch in [('a' * 7, BATCH), ('g' * 40, BATCH), ('b' * 40, BATCH), (SHA, 'ae1d595a-c5a5-4b7b-82c7-63a69230f55a'), (SHA, ''), (SHA, 'not-a-batch-uuid'), (None, BATCH), (SHA, None)]:
            with self.subTest(sha=sha, batch=batch), self.assertRaises(ValueError):
                self.provenance(sha, batch)

    def test_actual_publish_missing_context_fails_before_signing_or_config(self):
        command = [sys.executable, str(SCRIPTS / 'publish_ios_widget_ota.py'), '--config', str(self.root / 'absent.json'),
                   '--ipa', str(self.ipa), '--notes', 'fixture']
        for extra in [[], ['--source-commit', SHA], ['--batch-id', BATCH], ['--source-commit', 'abc', '--batch-id', BATCH]]:
            result = subprocess.run(command + extra, text=True, capture_output=True, env={**os.environ, 'PYTHONDONTWRITEBYTECODE': '1'})
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertNotIn('Traceback', result.stderr)

    def test_corrupt_archive_is_rejected(self):
        self.ipa.write_bytes(b'not an IPA archive')
        with self.assertRaises(ValueError):
            self.provenance()

    def test_partial_plan_context_also_fails_before_signing(self):
        command = [sys.executable, str(SCRIPTS / 'publish_ios_widget_ota.py'), '--config', str(self.root / 'absent.json'),
                   '--ipa', str(self.ipa), '--notes', 'fixture', '--plan', '--source-commit', SHA]
        result = subprocess.run(command, text=True, capture_output=True, env={**os.environ, 'PYTHONDONTWRITEBYTECODE': '1'})
        self.assertEqual(result.returncode, 2)
        self.assertNotIn('Traceback', result.stderr)

    def test_existing_original_publication_lock_cannot_be_bypassed(self):
        ota = self.fake_ota()
        original = self.root / 'original-config'
        original.mkdir()
        config = {'skillDir': '/unused', 'localRoot': str(self.root / 'ota'), 'baseUrl': 'https://example.com/ota',
                  'coordinationLockDirectory': str(original)}
        with (original / '.museum-release.lock').open('a') as existing:
            fcntl.flock(existing, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaises(BlockingIOError):
                self.run_main(['--source-commit', SHA, '--batch-id', BATCH], config, ota)
        ota.create_release.assert_not_called()
        ota.stage_local.assert_not_called()
        ota.activate_staged.assert_not_called()

    def fake_ota(self):
        ota = mock.Mock()
        ota.read_release.return_value = None
        def create(ipa, metadata, source, base, notes, previous):
            source.mkdir()
            result = dict(metadata, version='1.2.0')
            (source / 'latest-ios.json').write_text(json.dumps(result))
            return result
        ota.create_release.side_effect = create
        return ota

    def run_main(self, argv, config, ota):
        config_path = self.root / 'batch/config.json'
        config_path.parent.mkdir(exist_ok=True)
        config_path.write_text(json.dumps(config))
        proof = {'metadata': {'version': '1.2.0', 'signed': True}, 'sha256': 'checksum-fixture'}
        arguments = ['publisher', '--config', str(config_path), '--ipa', str(self.ipa), '--notes', 'fixture', *argv]
        with mock.patch.object(sys, 'argv', arguments), mock.patch.object(publisher, 'load_signer', return_value=object()), \
             mock.patch.object(publisher, 'load_ota', return_value=ota), \
             mock.patch.object(publisher, 'validate_release', return_value=proof) as verify, \
             mock.patch('sys.stdout', new=io.StringIO()), mock.patch('sys.stderr', new=io.StringIO()):
            publisher.main()
            self.assertEqual(verify.call_count, 1, 'Existing independent target signature validator must still run')

    def test_plan_without_context_keeps_local_verification_compatible(self):
        ota = self.fake_ota()
        config = {'skillDir': '/unused', 'localRoot': str(self.root / 'ota'), 'baseUrl': 'https://example.com/ota'}
        self.run_main(['--plan'], config, ota)
        ota.create_release.assert_not_called()
        self.assertFalse((self.root / 'batch/.museum-release.lock').exists())

    def test_publication_records_verified_provenance_and_reuses_original_lock_directory(self):
        ota = self.fake_ota()
        original = self.root / 'original-config'
        original.mkdir()
        config = {'skillDir': '/unused', 'localRoot': str(self.root / 'ota'), 'baseUrl': 'https://example.com/ota',
                  'coordinationLockDirectory': str(original)}
        self.run_main(['--source-commit', SHA, '--batch-id', BATCH], config, ota)
        metadata = ota.create_release.call_args.args[1]
        self.assertEqual(metadata['sourceCommit'], SHA)
        self.assertEqual(metadata['batchId'], BATCH)
        self.assertTrue((original / '.museum-release.lock').exists())
        self.assertFalse((self.root / 'batch/.museum-release.lock').exists())
        self.assertEqual(ota.verify_published.call_args_list[0].kwargs, {'fixed': False})
        self.assertEqual(ota.verify_published.call_count, 2)
        ota.stage_local.assert_called_once()
        ota.activate_staged.assert_called_once()

if __name__ == '__main__':
    unittest.main()
