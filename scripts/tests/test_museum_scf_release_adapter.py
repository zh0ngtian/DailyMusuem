"""Recovery and source gates for SCF releases; no cloud writes."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import shutil
import subprocess
import unittest
from unittest.mock import patch
import zipfile

MODULE = Path(__file__).resolve().parents[1] / 'museum_scf_release_adapter.py'

class SCFAdapterTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if MODULE.exists():
            spec = importlib.util.spec_from_file_location('scf_adapter', MODULE)
            cls.module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(cls.module)
        else:
            cls.module = None

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.work = self.root / 'work'
        self.work.mkdir()
        self.context_path = self.root / 'contexts' / 'batch.json'
        self.context_path.parent.mkdir()
        self.context = {'id': 'batch-1', 'workspace': str(self.work),
                        'config': {'repository': str(self.work), 'branch': 'main', 'options': {'deploy_wait_seconds': 0}},
                        'tasks': [{'id': 'task-1', 'sha': 'a' * 40, 'validation': {'baseSha': 'd' * 40, 'checks': [{'name': 'tests', 'status': 'passed'}]}}],
                        'results': {}, 'progressPath': str(self.root / 'progress.json'),
                        'frozen': {'sha': 'a' * 40, 'manifestSha256': '', 'version': 'existing'}}
        manifest = self.work / '.release-batch.json'
        manifest.write_text(json.dumps({'schemaVersion': 1, 'batchId': 'batch-1', 'project': 'scf', 'scope': 'scf-production', 'target': 'museummuse-api', 'environment': 'production', 'prepared': {'version': 'existing', 'inputFingerprint': {'sqliteSha256': 'b' * 64}, 'localValidation': {'mode': 'backend', 'status': 'passed'}}, 'tasks': [{'id': 'task-1', 'sha': 'a' * 40, 'validation': {'checks': [{'name': 'tests', 'status': 'passed'}]}}]}))
        self.context['frozen']['manifestSha256'] = hashlib.sha256(manifest.read_bytes()).hexdigest()
        self.calls = []

    def adapter(self):
        self.assertIsNotNone(self.module, 'SCF adapter is not implemented')
        return self.module.SCFAdapter(self.context, context_path=self.context_path, runner=self.runner)

    def runner(self, argv, **kwargs):
        self.calls.append(argv)
        if len(argv) > 1 and argv[1].endswith('verify_release_batch.py'):
            return json.dumps(dict(json.loads((self.work / '.release-batch.json').read_text()), frozenSHA='a' * 40))
        if argv[:2] == ['git', 'log']:
            return 'a' * 40
        if argv[:2] == ['git', 'rev-parse']:
            return 'a' * 40
        if argv[:2] == ['git', 'status']:
            return ''
        if argv[:2] == ['git', 'merge-base']:
            return ''
        if argv[:2] == ['git', 'diff']:
            return 'scripts/museum_scf_release_adapter.py\n'
        if argv[:3] == ['git', 'ls-remote', 'origin']:
            return ('a' * 40) + '\trefs/heads/main\n'
        raise AssertionError('Unexpected command: ' + repr(argv))

    def seed(self, adapter, mode='backend'):
        inputs = {'sqliteSha256': 'b' * 64, 'manifestSha256': 'c' * 64}
        adapter.save({'prepare': {'mode': mode, 'version': 'existing', 'dataVersion': 'existing',
                                  'inputFingerprint': inputs, 'localValidation': {'passed': True}}})
        return inputs

    def test_prepare_tooling_reserves_once_without_build(self):
        adapter = self.adapter()
        adapter.health = lambda: {'ok': True, 'databaseReadable': True, 'dataVersion': 'existing'}
        first = adapter.run('prepare')
        second = adapter.run('prepare')
        self.assertEqual(first, second)
        self.assertEqual(first['result']['mode'], 'tooling')
        self.assertFalse(any('build_package.sh' in str(c) for c in self.calls))

    def test_tooling_package_and_deploy_are_explicit_skips(self):
        adapter = self.adapter()
        self.seed(adapter, 'tooling')
        for phase in ('package', 'deploy'):
            result = adapter.run(phase)
            self.assertTrue(result['done'])
            self.assertEqual(result['result']['skipped'], 'tooling-only')
        self.assertFalse(self.calls and any('UpdateFunctionCode' in c for c in self.calls))

    def test_matching_marker_does_not_hide_wrong_packaged_data(self):
        adapter = self.adapter()
        inputs = self.seed(adapter)
        marker = dict(inputs, sourceCommit='a' * 40, batchId='batch-1', dataVersion='existing')
        package = adapter.directory / 'api.zip'
        with zipfile.ZipFile(package, 'w') as archive:
            archive.writestr('data/release-marker.json', json.dumps(marker))
            archive.writestr('data/museummuse.sqlite', b'wrong-data')
            archive.writestr('data/manifest.json', b'wrong-manifest')
        state = adapter.load()
        state['package'] = {'path': str(package), 'sha256': hashlib.sha256(package.read_bytes()).hexdigest(), 'marker': marker}
        adapter.save(state)
        with self.assertRaisesRegex(RuntimeError, 'input checksum'):
            adapter.package_check()

    def test_payload_marker_must_reference_frozen_commit(self):
        adapter = self.adapter()
        self.seed(adapter)
        with self.assertRaisesRegex(RuntimeError, 'sourceCommit'):
            adapter.validate_marker({'sourceCommit': 'd' * 40})

    def test_package_reuses_exact_checkpoint_without_rebuild(self):
        adapter = self.adapter()
        sqlite = b'checkpoint-db'
        manifest = b'checkpoint-manifest'
        inputs = {'sqliteSha256': hashlib.sha256(sqlite).hexdigest(), 'manifestSha256': hashlib.sha256(manifest).hexdigest()}
        adapter.save({'prepare': {'mode': 'backend', 'version': 'existing', 'dataVersion': 'existing', 'inputFingerprint': inputs}})
        marker = dict(inputs, sourceCommit='a' * 40, batchId='batch-1', dataVersion='existing')
        package = adapter.directory / 'api.zip'
        with zipfile.ZipFile(package, 'w') as z:
            z.writestr('data/release-marker.json', json.dumps(marker))
            z.writestr('data/museummuse.sqlite', sqlite)
            z.writestr('data/manifest.json', manifest)
        state = adapter.load()
        state['package'] = {'path': str(package), 'sha256': hashlib.sha256(package.read_bytes()).hexdigest(), 'marker': marker}
        adapter.save(state)
        self.assertTrue(adapter.run('package')['done'])
        self.assertFalse(any('build_package.sh' in str(c) for c in self.calls))

    def test_complete_package_recovers_after_checkpoint_write_loss(self):
        adapter = self.adapter()
        sqlite = b'immutable-data'
        manifest = b'{"build_id":"existing"}'
        inputs = {'sqliteSha256': hashlib.sha256(sqlite).hexdigest(), 'manifestSha256': hashlib.sha256(manifest).hexdigest()}
        adapter.save({'prepare': {'mode': 'backend', 'version': 'existing', 'dataVersion': 'existing', 'inputFingerprint': inputs}})
        marker = dict(inputs, sourceCommit='a' * 40, batchId='batch-1', dataVersion='existing')
        package = adapter.directory / 'api.zip'
        with zipfile.ZipFile(package, 'w') as z:
            z.writestr('data/release-marker.json', json.dumps(marker))
            z.writestr('data/museummuse.sqlite', sqlite)
            z.writestr('data/manifest.json', manifest)
        self.assertTrue(adapter.run('package')['done'])
        self.assertFalse(any('build_package.sh' in str(c) for c in self.calls))

    def test_lost_deploy_response_reconciles_without_resubmission(self):
        adapter = self.adapter()
        sqlite, manifest = b'known-sqlite', b'known-manifest'
        inputs = {'sqliteSha256': hashlib.sha256(sqlite).hexdigest(), 'manifestSha256': hashlib.sha256(manifest).hexdigest()}
        marker = dict(inputs, sourceCommit='a' * 40, batchId='batch-1', dataVersion='existing')
        package = adapter.directory / 'api.zip'
        with zipfile.ZipFile(package, 'w') as archive:
            archive.writestr('data/museummuse.sqlite', sqlite)
            archive.writestr('data/manifest.json', manifest)
            archive.writestr('data/release-marker.json', json.dumps(marker))
        checksum = self.module.digest(package)
        adapter.save({'prepare': {'mode': 'backend', 'dataVersion': 'existing', 'inputFingerprint': inputs},
                      'package': {'path': str(package), 'sha256': checksum, 'marker': marker},
                      'deployIntent': {'sourceCommit': 'a' * 40, 'objectKey': 'deployments/museummuse/batch-1/api.zip'}})
        adapter.remote_deployment = lambda: {'status': 'Active', 'marker': marker, 'zipSha256': checksum,
                                            'requestId': 'read-request', **self.module.archive_contents(package)}
        adapter.health = lambda: {'ok': True, 'databaseReadable': True, 'dataVersion': 'existing', 'releaseMarker': marker}
        self.assertTrue(adapter.run('deploy')['done'])
        self.assertFalse(any('UpdateFunctionCode' in c for c in self.calls))

    def test_unproven_pending_deploy_fails_instead_of_repeating(self):
        adapter = self.adapter()
        self.seed(adapter)
        state = adapter.load()
        state['deployIntent'] = {'sourceCommit': 'a' * 40}
        state['package'] = {'sha256': 'e' * 64}
        adapter.save(state)
        adapter.remote_deployment = lambda: {'status': 'Active', 'marker': {}, 'zipSha256': 'f' * 64}
        adapter.health = lambda: {'ok': True, 'databaseReadable': True, 'dataVersion': 'existing'}
        with self.assertRaisesRegex(RuntimeError, 'unproven|prove'):
            adapter.run('deploy')
        self.assertFalse(any('UpdateFunctionCode' in c for c in self.calls))

    def test_async_lost_update_response_waits_without_resubmission(self):
        adapter = self.adapter()
        self.seed(adapter)
        adapter.options['deploy_wait_seconds'] = 45
        adapter.package_check = lambda: {'done': True, 'result': {'sha256': 'e' * 64, 'path': 'unused'}}
        adapter.upload = lambda package, key: {'bucket': 'test-bucket', 'objectKey': key}
        updates = []
        def update(action, **kwargs):
            updates.append(action)
            raise RuntimeError('update response lost')
        adapter.tccli = update
        reads = iter([{'done': False, 'result': {}}, {'done': False, 'result': {}},
                      {'done': True, 'result': {'sourceCommit': 'a' * 40, 'status': 'Active'}}])
        adapter.deploy_check = lambda: next(reads)
        with patch.object(self.module.time, 'sleep', return_value=None):
            self.assertTrue(adapter.run('deploy')['done'])
        self.assertEqual(updates, ['UpdateFunctionCode'])
        self.assertEqual(adapter.load()['deployIntent']['sourceCommit'], 'a' * 40)
        self.assertTrue(adapter.load()['deployIntent']['responseUnavailable'])

    def test_final_verify_requires_remote_main_to_include_frozen_source(self):
        adapter = self.adapter()
        self.seed(adapter, 'tooling')
        adapter.promote_check = lambda: {'done': False, 'result': {'remoteCommit': 'd' * 40}}
        adapter.probe = lambda **kwargs: {'passed': True}
        with self.assertRaisesRegex(RuntimeError, 'promot|main'):
            adapter.run('verify')
        self.assertNotIn('verify', adapter.load())

    def test_source_gate_rejects_dirty_file_outside_backend_subtree(self):
        adapter = self.adapter()
        old = adapter.git
        adapter.git = lambda *args: '?? unrelated.txt' if args == ('status', '--porcelain', '--untracked-files=all') else old(*args)
        with self.assertRaisesRegex(RuntimeError, 'clean|uncommitted'):
            adapter.source_gate()

    def test_source_gate_rejects_historical_manifest_commit(self):
        adapter = self.adapter()
        old = adapter.git
        adapter.git = lambda *args: 'd' * 40 if args[0] == 'log' else old(*args)
        with self.assertRaisesRegex(RuntimeError, 'introduc'):
            adapter.source_gate()

    def test_source_gate_rejects_wrong_manifest_target_or_tasks(self):
        adapter = self.adapter()
        path = self.work / '.release-batch.json'
        original = json.loads(path.read_text())
        for changed in ({'target': 'other-function'}, {'environment': 'staging'}, {'batchId': 'other-batch'}, {'tasks': []}):
            with self.subTest(changed=changed):
                path.write_text(json.dumps(dict(original, **changed)))
                self.context['frozen']['manifestSha256'] = hashlib.sha256(path.read_bytes()).hexdigest()
                with self.assertRaises(RuntimeError):
                    adapter.source_gate()

    def test_verify_failure_never_writes_success(self):
        adapter = self.adapter()
        self.seed(adapter, 'tooling')
        adapter.probe = lambda **kwargs: (_ for _ in ()).throw(RuntimeError('nonce channel failed'))
        with self.assertRaisesRegex(RuntimeError, 'nonce channel'):
            adapter.run('verify')
        self.assertNotIn('verify', adapter.load())

    def test_cos_upload_forbids_overwrite_and_proves_body(self):
        adapter = self.adapter()
        self.seed(adapter)
        content = b'new-frozen-package'
        package_path = adapter.directory / 'api.zip'
        package_path.write_bytes(content)
        package = {'path': str(package_path), 'sha256': hashlib.sha256(content).hexdigest()}
        class Missing(Exception):
            def get_status_code(self):
                return 404
        class FakeCOS:
            metadata = None
            calls = []
            def head_object(self, **kwargs):
                if not self.metadata:
                    raise Missing()
                return self.metadata
            def put_object(self, **kwargs):
                self.calls.append(kwargs)
                self.metadata = kwargs['Metadata']
            def get_object(self, **kwargs):
                import io
                class Body:
                    def get_raw_stream(self):
                        return io.BytesIO(content)
                return {'Body': Body()}
        client = FakeCOS()
        adapter.cos_client = lambda: client
        result = adapter.upload(package, 'deployments/museummuse/batch-1/api.zip')
        self.assertEqual(result['sha256'], package['sha256'])
        self.assertEqual(client.calls[0]['Metadata']['x-cos-forbid-overwrite'], 'true')
        self.assertEqual(client.calls[0]['Metadata']['x-cos-meta-sha256'], package['sha256'])
        adapter.upload(package, result['objectKey'])
        self.assertEqual(len(client.calls), 1)

    def test_backend_detection_uses_task_base_after_main_promotion(self):
        adapter = self.adapter()
        adapter.git = lambda *args: 'server/api/routes.py' if args[0] == 'diff' else ''
        self.assertEqual(adapter.mode(), 'backend')

    def test_missing_task_base_is_rejected(self):
        self.context['tasks'][0]['validation'].pop('baseSha')
        adapter = self.adapter()
        with self.assertRaisesRegex(RuntimeError, 'baseSha'):
            adapter.mode()

    def test_probe_uses_same_headers_for_nonce_replay(self):
        import importlib.util
        path = MODULE.with_name('probe_backend_release.py')
        spec = importlib.util.spec_from_file_location('scripts.probe_backend_release', path)
        probe = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(probe)
        seen = set()
        replay_headers = []
        def request(url, headers):
            nonce = headers.get('X-MuseumMuse-Nonce')
            if url.endswith('/health'):
                return 200, {'ok': True, 'databaseReadable': True, 'dataVersion': 'existing'}
            if not nonce:
                return 401, {'error': {'code': 'unauthorized'}}
            if nonce in seen:
                replay_headers.append(headers)
                return 401, {'error': {'code': 'replayed_request'}}
            seen.add(nonce)
            if url.endswith('/metadata'):
                replay_headers.append(headers)
                return 200, {'data': {'museums': [{'museumID': m, 'defaultSourceKey': 'source'} for m in probe.FORMAL_MUSEUMS]}}
            if url.endswith('/v1/museums'):
                return 200, {'data': [{'museumID': m} for m in probe.FORMAL_MUSEUMS]}
            museum = url.split('/museums/')[1].split('/')[0]
            item = {'museumID': museum, 'objectID': 'object'}
            if 'limit=1' in url:
                return 200, {'data': {'items': [item]}}
            return 200, {'data': item}
        result = probe.probe_release('https://backend.example', 'test-only', data_version='existing', request=request)
        self.assertTrue(result['passed'])
        self.assertIs(replay_headers[-1], replay_headers[-2])

    def test_changed_frozen_workspace_is_rejected(self):
        adapter = self.adapter()
        self.seed(adapter, 'tooling')
        (self.work / '.release-batch.json').write_text('{"changed":true}')
        with self.assertRaisesRegex(RuntimeError, 'manifest'):
            adapter.run('package')

class SCFRealSourceGateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location('scf_real_source', MODULE)
        cls.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.module)

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.work = self.root / 'repo'
        self.work.mkdir()
        self.git('init', '-b', 'main')
        self.git('config', 'user.name', 'SCF Test')
        self.git('config', 'user.email', 'scf-test@example.invalid')
        (self.work / 'scripts').mkdir()
        shutil.copyfile(MODULE.with_name('verify_release_batch.py'), self.work / 'scripts/verify_release_batch.py')
        self.git('add', '.')
        self.git('commit', '-m', 'base')
        base = self.git('rev-parse', 'HEAD')
        (self.work / 'payload.py').write_text('release = True\n')
        self.git('add', '.')
        self.git('commit', '-m', 'task')
        task_sha = self.git('rev-parse', 'HEAD')
        task = {'id': 'task-1', 'sha': task_sha, 'validation': {'baseSha': base, 'checks': [{'name': 'tests', 'status': 'passed'}]}}
        batch = {'schemaVersion': 1, 'batchId': 'batch-1', 'project': 'scf', 'scope': 'scf-production',
                 'target': 'museummuse-api', 'environment': 'production',
                 'prepared': {'version': 'existing', 'inputFingerprint': {'sqliteSha256': 'b' * 64}, 'localValidation': {'mode': 'backend', 'status': 'passed'}},
                 'tasks': [{'id': task['id'], 'sha': task['sha'], 'validation': {'checks': task['validation']['checks']}}]}
        self.manifest = self.work / '.release-batch.json'
        self.manifest.write_text(json.dumps(batch))
        self.git('add', '.')
        self.git('commit', '-m', 'freeze')
        self.context = {'id': 'batch-1', 'workspace': str(self.work), 'tasks': [task],
                        'config': {'repository': str(self.work), 'options': {}},
                        'frozen': {'sha': self.git('rev-parse', 'HEAD'), 'manifestSha256': hashlib.sha256(self.manifest.read_bytes()).hexdigest()}}
        self.context_path = self.root / 'contexts' / 'batch.json'
        self.context_path.parent.mkdir()

    def git(self, *args):
        result = subprocess.run(['git', *args], cwd=self.work, capture_output=True, text=True, check=True)
        return result.stdout.strip()

    def adapter(self):
        return self.module.SCFAdapter(self.context, context_path=self.context_path)

    def test_core_validator_proves_clean_real_frozen_history(self):
        self.assertEqual(self.adapter().source_gate(), self.context['frozen']['sha'])

    def test_untracked_non_backend_file_blocks_real_source(self):
        (self.work / 'unrelated.txt').write_text('dirty')
        with self.assertRaisesRegex(RuntimeError, 'clean'):
            self.adapter().source_gate()

    def test_later_commit_cannot_reuse_historical_manifest(self):
        (self.work / 'docs.txt').write_text('later')
        self.git('add', '.')
        self.git('commit', '-m', 'later unrelated source')
        self.context['frozen']['sha'] = self.git('rev-parse', 'HEAD')
        with self.assertRaisesRegex(RuntimeError, 'introducing'):
            self.adapter().source_gate()

    def test_nonancestor_task_is_rejected_with_real_git(self):
        orphan = self.git('commit-tree', 'HEAD^{tree}', '-m', 'unrelated orphan')
        self.context['tasks'][0]['sha'] = orphan
        batch = json.loads(self.manifest.read_text())
        batch['tasks'][0]['sha'] = orphan
        self.manifest.write_text(json.dumps(batch))
        self.git('add', '.')
        self.git('commit', '-m', 'new invalid freeze')
        self.context['frozen'].update(sha=self.git('rev-parse', 'HEAD'), manifestSha256=hashlib.sha256(self.manifest.read_bytes()).hexdigest())
        with self.assertRaises(RuntimeError):
            self.adapter().source_gate()

if __name__ == '__main__':
    unittest.main()
