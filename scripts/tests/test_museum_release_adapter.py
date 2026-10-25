"""Client adapter recovery acceptance; all channel reads/writes are controlled mocks."""
import copy
import hashlib
import json
import plistlib
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from museum_release_adapter import Adapter


SHA = 'a' * 40
BASE = 'b' * 40
OTHER = 'c' * 40


class MuseumClientAdapterTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='museum-client-adapter-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.workspace = self.root / 'work'
        self.workspace.mkdir()
        self.progress = self.root / 'progress' / 'batch.json'
        self.progress.parent.mkdir()
        self.directory = self.root / 'museum-releases' / 'batch-test'
        self.directory.mkdir(parents=True)
        self.version_files('1.1.3', 9)
        notes = self.workspace / 'Config/ReleaseNotes/1.1.4.md'
        notes.parent.mkdir(parents=True)
        notes.write_text('本版本修复小组件刷新问题\n')
        manifest = self.workspace / '.release-batch.json'
        manifest.write_text('{"batchId":"batch-test"}\n')
        self.context = {
            'id': 'batch-test', 'workspace': str(self.workspace), 'progressPath': str(self.progress),
            'config': {'repository': str(self.workspace), 'branch': 'main', 'options': {
                'github_repository': 'example/acceptance'}},
            'tasks': [{'id': 'change', 'sha': SHA, 'validation': {
                'baseSha': BASE, 'checks': [{'name': 'local', 'status': 'passed'}]}}],
            'results': {'prepare': {'localValidation': {'mode': 'client'}}},
            'frozen': {'sha': SHA, 'version': '1.1.4', 'buildNumber': '10',
                       'manifestSha256': hashlib.sha256(manifest.read_bytes()).hexdigest()},
        }
        manifest.write_text(json.dumps({'batchId': 'batch-test', 'target': 'tech.zh0ngtian.MuseumMuse',
            'environment': 'production', 'tasks': [{'id': 'change', 'sha': SHA,
                'validation': {'checks': [{'name': 'local', 'status': 'passed'}]}}]}))
        self.context['frozen']['manifestSha256'] = hashlib.sha256(manifest.read_bytes()).hexdigest()
        self.head = SHA
        self.paths = 'DailyMuseum/Views/Example.swift\n'
        self.tags = SHA + '\trefs/tags/v1.1.3\n'
        self.command_calls = []
        self.json_calls = []
        self.command_patch = patch.object(Adapter, 'command', autospec=True, side_effect=self.command)
        self.json_patch = patch.object(Adapter, 'json_command', autospec=True, side_effect=self.json_command)
        for mocking in (self.command_patch, self.json_patch):
            mocking.start()
            self.addCleanup(mocking.stop)
        self.runs_payload = []
        self.jobs_payload = {'jobs': []}
        self.metadata_overrides = {}

    def version_files(self, version, build):
        (self.workspace / 'Project.yml').write_text(
            f'name: DailyMuseum\ntargets:\n  DailyMuseum:\n    info:\n      properties:\n'
            f'        CFBundleShortVersionString: "{version}"\n        CFBundleVersion: "{build}"\n'
            f'    settings:\n      base:\n        MARKETING_VERSION: {version}\n'
            f'        CURRENT_PROJECT_VERSION: {build}\n')
        project = self.workspace / 'DailyMuseum.xcodeproj'
        project.mkdir(exist_ok=True)
        (project / 'project.pbxproj').write_text(
            f'MARKETING_VERSION = {version};\nCURRENT_PROJECT_VERSION = {build};\n')
        for name in ('DailyMuseum', 'DailyMuseumWidget'):
            target = self.workspace / name
            target.mkdir(exist_ok=True)
            (target / 'Info.plist').write_bytes(plistlib.dumps({
                'CFBundleShortVersionString': version, 'CFBundleVersion': str(build)}))

    def adapter(self):
        return Adapter(copy.deepcopy(self.context))

    def command(self, instance, args, cwd=None, env=None, log=None):
        self.command_calls.append([str(value) for value in args])
        command = ' '.join(str(value) for value in args)
        if args[0] == 'git':
            if 'rev-parse' in args:
                return 'd' * 40 if 'HEAD^{tree}' in args else self.head
            if 'ls-remote' in args:
                if any(str(value).startswith('refs/tags/v1.1.4') for value in args):
                    return SHA + '\trefs/tags/v1.1.4\n'
                return self.tags
            if 'status' in args:
                return ''
            if 'log' in args:
                return self.head
            if 'diff' in args:
                return self.paths
            if 'merge-base' in args:
                return ''
            if any(value in args for value in ('add', 'commit', 'push', 'fetch')):
                return ''
        if args[:3] == ['gh', 'release', 'download']:
            folder = Path(args[args.index('--dir') + 1])
            ipa = folder / 'MuseumMuse-unsigned.ipa'
            ipa.write_bytes(b'controlled unsigned ipa')
            checksum = hashlib.sha256(ipa.read_bytes()).hexdigest()
            (folder / 'MuseumMuse-unsigned.ipa.sha256').write_text(checksum + '  MuseumMuse-unsigned.ipa\n')
            matching_runs = [run for run in self.runs_payload
                             if run['head_sha'] == SHA and run['event'] == 'push']
            run_id = min(run['id'] for run in matching_runs)
            metadata = {
                'tag': 'v1.1.4', 'commit': SHA, 'batchId': 'batch-test', 'runId': str(run_id),
                'version': '1.1.4', 'build': '10', 'bytes': ipa.stat().st_size,
                'sha256': checksum, 'signed': False, 'widgetGroups': 10, 'authConfigured': True,
                'bundleIDs': ['tech.zh0ngtian.MuseumMuse', 'tech.zh0ngtian.MuseumMuse.widget'],
                'tasks': [{'id': task['id'], 'sha': task['sha'],
                    'validation': {'checks': [{'name': check['name'], 'status': check['status']}
                        for check in task['validation']['checks']]}} for task in self.context['tasks']]}
            metadata.update(copy.deepcopy(self.metadata_overrides))
            (folder / 'MuseumMuse-unsigned.json').write_text(json.dumps(metadata))
            return ''
        raise AssertionError('Unapproved external command: ' + command)

    def json_command(self, instance, args):
        args = [str(value) for value in args]
        self.json_calls.append(args)
        if args[:2] == ['gh', 'api']:
            if '/actions/workflows/' in args[2]:
                return {'workflow_runs': copy.deepcopy(self.runs_payload)}
            if '/jobs' in args[2]:
                return copy.deepcopy(self.jobs_payload)
        if args[:3] == ['gh', 'release', 'view']:
            return {'id': 999, 'url': 'https://unused.example.invalid/release', 'assets': [
                {'name': name} for name in ('MuseumMuse-unsigned.ipa', 'MuseumMuse-unsigned.ipa.sha256', 'MuseumMuse-unsigned.json')]}
        raise AssertionError('Unapproved external JSON command: ' + ' '.join(args))

    def run_record(self, number, sha=SHA, event='push', workflow='iOS Build', **updates):
        result = {'id': number, 'head_sha': sha, 'head_branch': 'main', 'event': event,
                  'name': workflow, 'status': 'completed', 'conclusion': 'success',
                  'html_url': 'https://unused.example.invalid/run/' + str(number), 'run_attempt': 1}
        result.update(updates)
        return result

    def test_client_version_is_reserved_once_across_repeated_calls(self):
        adapter = self.adapter()
        first = adapter.reserve('client')
        second = adapter.reserve('client')
        self.assertEqual(first, second)
        self.assertEqual(first['version'], '1.1.4')
        self.assertEqual(str(first['buildNumber']), '10')
        self.assertTrue(list(self.directory.glob('*.json')), 'Reservation must survive process restart')
        self.assertFalse(any('xcodebuild' in call for call in self.command_calls))

    def test_reservation_survives_reopen_after_partial_version_file_update(self):
        first = self.adapter().reserve('client')
        self.version_files(first['version'], first['buildNumber'])
        self.tags += OTHER + '\trefs/tags/v1.1.4\n'
        resumed = self.adapter().reserve('client')
        self.assertEqual(resumed, first)
        self.assertEqual(resumed['version'], '1.1.4')
        self.assertEqual(str(resumed['buildNumber']), '10')

    def test_tooling_reservation_does_not_increment_app_version(self):
        before = (self.workspace / 'Project.yml').read_bytes()
        reservation = self.adapter().reserve('tooling')
        self.assertEqual(reservation['version'], '1.1.3')
        self.assertEqual(str(reservation['buildNumber']), '9')
        self.assertEqual((self.workspace / 'Project.yml').read_bytes(), before)
        self.assertFalse(any('xcodebuild' in call for call in self.command_calls))

    def test_reservation_rejects_inconsistent_xcode_version(self):
        (self.workspace / 'DailyMuseum.xcodeproj/project.pbxproj').write_text(
            'MARKETING_VERSION = 1.1.2;\nCURRENT_PROJECT_VERSION = 9;\n')
        with self.assertRaisesRegex(ValueError, 'disagree'):
            self.adapter().reserve('client')
        self.assertFalse((self.directory / 'checkpoint.json').exists())

    def test_reservation_rejects_inconsistent_widget_info(self):
        (self.workspace / 'DailyMuseumWidget/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleShortVersionString': '1.1.3', 'CFBundleVersion': '8'}))
        with self.assertRaisesRegex(ValueError, 'disagree'):
            self.adapter().reserve('client')
        self.assertFalse((self.directory / 'checkpoint.json').exists())

    def test_prepare_after_interrupted_checks_reuses_version_and_updates_all_files(self):
        adapter = self.adapter()
        with patch.object(adapter, 'merged_checks', side_effect=RuntimeError('interrupted after version update')):
            with self.assertRaisesRegex(RuntimeError, 'interrupted'):
                adapter.prepare()
        reopened = self.adapter()
        with patch.object(reopened, 'merged_checks'):
            response = reopened.prepare()
        self.assertTrue(response['done'])
        self.assertEqual(response['result']['version'], '1.1.4')
        self.assertEqual(response['result']['buildNumber'], '10')
        text = (self.workspace / 'Project.yml').read_text()
        self.assertIn('CFBundleShortVersionString: "1.1.4"', text)
        self.assertIn('CFBundleVersion: "10"', text)
        self.assertIn('MARKETING_VERSION: 1.1.4', text)
        self.assertIn('CURRENT_PROJECT_VERSION: 10', text)
        for name in ('DailyMuseum', 'DailyMuseumWidget'):
            info = plistlib.loads((self.workspace / name / 'Info.plist').read_bytes())
            self.assertEqual(info['CFBundleShortVersionString'], '1.1.4')
            self.assertEqual(info['CFBundleVersion'], '10')
        project = (self.workspace / 'DailyMuseum.xcodeproj/project.pbxproj').read_text()
        self.assertIn('MARKETING_VERSION = 1.1.4;', project)
        self.assertIn('CURRENT_PROJECT_VERSION = 10;', project)

    def test_frozen_head_is_rejected_before_any_channel_action(self):
        adapter = self.adapter()
        self.head = OTHER
        with self.assertRaises(ValueError):
            adapter.assert_frozen()
        self.assertFalse(self.json_calls)

    def test_frozen_manifest_hash_is_rejected(self):
        adapter = self.adapter()
        (self.workspace / '.release-batch.json').write_text('{"changed":true}')
        with self.assertRaises(ValueError):
            adapter.assert_frozen()
        self.assertFalse(self.json_calls)

    def test_workflow_runs_require_exact_frozen_sha(self):
        self.runs_payload = [self.run_record(101, sha=OTHER), self.run_record(102),
                             self.run_record(103, event='pull_request')]
        runs = self.adapter().runs('ios-build.yml')
        self.assertEqual([run['id'] for run in runs], [102, 103])
        self.assertIn('head_sha=' + SHA, self.json_calls[-1][2])

    def test_build_check_reads_jobs_from_selected_exact_run_id(self):
        self.runs_payload = [self.run_record(201, sha=OTHER), self.run_record(202),
                             self.run_record(203, event='pull_request')]
        self.jobs_payload = {'jobs': [{'name': 'Build', 'conclusion': 'success'}]}
        response = self.adapter().check_build()
        self.assertTrue(response['done'])
        view_calls = [call for call in self.json_calls if call[:2] == ['gh', 'api'] and '/jobs' in call[2]]
        self.assertEqual(len(view_calls), 1)
        self.assertIn('/runs/202/jobs', view_calls[0][2])
        self.assertNotIn('/runs/201/', view_calls[0][2])
        self.assertNotIn('/runs/203/', view_calls[0][2])

    def test_resumed_build_check_keeps_pinned_run_id(self):
        self.runs_payload = [self.run_record(501)]
        self.jobs_payload = {'jobs': [{'name': 'Build', 'conclusion': 'success'}]}
        first = self.adapter().check_build()
        self.assertTrue(first['done'])
        self.runs_payload = [self.run_record(501), self.run_record(502)]
        resumed = self.adapter().check_build()
        self.assertEqual(resumed['result']['runId'], 501)
        self.runs_payload = [self.run_record(502)]
        missing = self.adapter().check_build()
        self.assertFalse(missing['done'], 'Missing pinned operation must not switch to another run')
        self.assertFalse(any('/runs/502/jobs' in ' '.join(call) for call in self.json_calls))

    def test_github_release_needs_both_jobs_from_one_exact_source_run(self):
        self.runs_payload = [self.run_record(301, workflow='iOS Release', headBranch='v1.1.4')]
        self.jobs_payload = {'jobs': [{'name': 'Build', 'conclusion': 'success'},
                                     {'name': 'Publish unsigned IPA', 'conclusion': 'failure'}]}
        with self.assertRaisesRegex(ValueError, 'required CI job'):
            self.adapter().check_github()
        self.assertFalse(any('sign_ios_widget_ipa.py' in ' '.join(call) for call in self.command_calls))

    def release_fixture(self):
        self.runs_payload = [self.run_record(601, workflow='iOS Release', head_branch='v1.1.4')]
        self.jobs_payload = {'jobs': [{'name': 'Build', 'conclusion': 'success'},
                                     {'name': 'Publish unsigned IPA', 'conclusion': 'success'}]}

    def test_full_release_metadata_contract_is_accepted(self):
        self.release_fixture()
        response = self.adapter().check_github()
        self.assertTrue(response['done'])
        self.assertEqual(response['result']['runId'], 601)
        self.assertEqual(response['result']['sourceCommit'], SHA)
        self.assertEqual(response['result']['sha256'],
                         hashlib.sha256(b'controlled unsigned ipa').hexdigest())
        downloads = [call for call in self.command_calls if call[:3] == ['gh', 'release', 'download']]
        self.assertEqual(len(downloads), 1)

    def test_release_metadata_for_another_ci_run_is_rejected(self):
        self.release_fixture()
        self.metadata_overrides = {'runId': '602'}
        with self.assertRaisesRegex(ValueError, 'frozen batch'):
            self.adapter().check_github()

    def test_release_metadata_with_changed_task_check_is_rejected(self):
        self.release_fixture()
        self.metadata_overrides = {'tasks': [{'id': 'change', 'sha': SHA,
            'validation': {'checks': [{'name': 'local', 'status': 'failed'}]}}]}
        with self.assertRaisesRegex(ValueError, 'task lineage'):
            self.adapter().check_github()

    def test_release_metadata_with_wrong_byte_count_is_rejected(self):
        self.release_fixture()
        self.metadata_overrides = {'bytes': len(b'controlled unsigned ipa') + 1}
        with self.assertRaisesRegex(ValueError, 'frozen batch'):
            self.adapter().check_github()

    def test_reservation_uses_newest_github_version_without_private_signing_config(self):
        self.tags += OTHER + '\trefs/tags/v1.2.8\n'
        result = self.adapter().reserve('client')
        self.assertEqual(result['version'], '1.2.9')
        self.assertEqual(result['buildNumber'], '10')
        self.assertTrue(all(call[0] == 'git' for call in self.command_calls))

    def test_missing_release_notes_stops_prepare_before_version_changes(self):
        (self.workspace / 'Config/ReleaseNotes/1.1.4.md').unlink()
        with self.assertRaises(FileNotFoundError):
            self.adapter().prepare()
        self.assertIn('MARKETING_VERSION: 1.1.3', (self.workspace / 'Project.yml').read_text())

    def test_legacy_coordinator_phases_skip_without_signing_or_ota_access(self):
        adapter = self.adapter()
        for action in ('check', 'run'):
            for phase in ('device', 'sign', 'ota'):
                with self.subTest(action=action, phase=phase):
                    response = adapter.phase(action, phase)
                    self.assertTrue(response['done'])
                    self.assertIs(response['result']['required'], False)
                    self.assertEqual(response['result']['reason'], 'unsigned-ipa-only')
        self.assertFalse(self.json_calls)
        self.assertTrue(all(call[0] == 'git' for call in self.command_calls))

    def local_acceptance(self, widget=False):
        self.context['tasks'][0]['validation']['checks'] = [
            {'name': 'client-local', 'status': 'passed', 'evidence': 'controlled local acceptance'}]
        if widget:
            self.context['tasks'][0]['validation']['checks'].append(
                {'name': 'widget-desktop', 'status': 'passed', 'evidence': 'controlled desktop and logs'})

    def test_client_verification_completes_with_unsigned_github_artifacts_only(self):
        self.release_fixture()
        self.local_acceptance()
        response = self.adapter().check_verify()
        self.assertTrue(response['done'])
        result = response['result']
        self.assertEqual(result['delivery'], 'unsigned-ipa')
        self.assertEqual(result['sourceCommit'], SHA)
        self.assertIn('build', result)
        self.assertIn('github', result)
        self.assertFalse(set(result) & {'device', 'sign', 'ota', 'httpsFullDownloadVerified'})
        self.assertTrue(all(call[0] in ('git', 'gh') for call in self.command_calls))

    def test_client_verification_waits_for_missing_build(self):
        self.local_acceptance()
        response = self.adapter().check_verify()
        self.assertFalse(response['done'])
        self.assertEqual(response['result']['missingPhase'], 'build')

    def test_client_verification_still_requires_local_acceptance(self):
        self.release_fixture()
        with self.assertRaisesRegex(ValueError, 'Local client acceptance'):
            self.adapter().check_verify()

    def test_widget_verification_still_requires_desktop_and_system_logs(self):
        self.release_fixture()
        self.local_acceptance()
        self.paths = 'DailyMuseumWidget/Widget.swift\n'
        with self.assertRaisesRegex(ValueError, 'Widget desktop/request/system-log'):
            self.adapter().check_verify()
        self.local_acceptance(widget=True)
        self.assertTrue(self.adapter().check_verify()['done'])

    def test_signed_github_release_is_rejected(self):
        self.release_fixture()
        self.metadata_overrides = {'signed': True}
        with self.assertRaisesRegex(ValueError, 'frozen batch'):
            self.adapter().check_github()

    def test_tooling_verification_does_not_read_signed_or_ota_baselines(self):
        self.context['results']['prepare']['localValidation']['mode'] = 'tooling'
        response = self.adapter().check_verify()
        self.assertTrue(response['done'])
        self.assertEqual(response['result']['mode'], 'tooling')
        self.assertIs(response['result']['newClientBuildRequired'], False)
        self.assertFalse(self.json_calls)
        self.assertTrue(all(call[0] == 'git' for call in self.command_calls))

    def test_tooling_only_phases_never_build_sign_install_or_publish(self):
        self.context['results']['prepare']['localValidation']['mode'] = 'tooling'
        self.paths = 'scripts/museum_release_adapter.py\n'
        adapter = self.adapter()
        for phase in ('build', 'github', 'device', 'sign', 'ota'):
            with self.subTest(phase=phase):
                response = adapter.phase('run', phase)
                self.assertTrue(response['done'])
                self.assertIs(response['result']['required'], False)
        self.assertFalse(self.json_calls)
        self.assertTrue(all(call[0] == 'git' for call in self.command_calls),
                        'Tooling phases may check source but must not invoke external channels')
        for phase in ('promote', 'verify'):
            with self.subTest(phase=phase):
                with patch.object(adapter, 'run_' + phase, return_value={'done': True, 'result': {'checked': phase}}) as required:
                    response = adapter.phase('run', phase)
                self.assertTrue(response['done'])
                required.assert_called_once()


if __name__ == '__main__':
    unittest.main()
