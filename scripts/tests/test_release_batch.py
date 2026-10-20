import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'verify_release_batch.py'

class ReleaseBatchTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.repo = Path(self.tmp.name)
        self.git('init', '-b', 'main')
        self.git('config', 'user.email', 'test@example.com')
        self.git('config', 'user.name', 'Test')
        for directory in ('DailyMuseum', 'DailyMuseumWidget'):
            (self.repo / directory).mkdir()
            (self.repo / directory / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleVersion': '10', 'CFBundleShortVersionString': '1.2.0'}))
        (self.repo / 'DailyMuseum.xcodeproj').mkdir()
        (self.repo / 'DailyMuseum.xcodeproj/project.pbxproj').write_text('MARKETING_VERSION = 1.2.0;\nCURRENT_PROJECT_VERSION = 10;\n')
        self.git('add', '.')
        self.git('commit', '-m', 'task')
        self.task_sha = self.git('rev-parse', 'HEAD')
        self.manifest = dict(schemaVersion=1, batchId='batch-1', project='MuseumMuse', scope='ios',
            target='tech.zh0ngtian.MuseumMuse', environment='production',
            tasks=[dict(id='task-1', sha=self.task_sha, validation={'checks': [{'name': 'regression', 'status': 'passed'}]})],
            prepared=dict(version='1.2.0', buildNumber='10', bundleIdentifier='tech.zh0ngtian.MuseumMuse',
                localValidation={'mode': 'client', 'status': 'passed', 'checks': [{'name': 'local', 'status': 'passed'}]}, inputFingerprint='fixture-fingerprint'))

    def git(self, *args):
        return subprocess.check_output(['git', *args], cwd=self.repo, text=True, stderr=subprocess.DEVNULL).strip()

    def freeze(self):
        (self.repo / '.release-batch.json').write_text(json.dumps(self.manifest))
        self.git('add', '.')
        self.git('commit', '-m', 'freeze')
        return self.git('rev-parse', 'HEAD')

    def verify(self, *args, ref=None):
        env = {k: v for k, v in os.environ.items() if k not in ('BUILD_SHA', 'GITHUB_SHA', 'GITHUB_REF', 'RELEASE_TAG')}
        if ref:
            env['GITHUB_REF'] = ref
        return subprocess.run([sys.executable, str(SCRIPT), *args], cwd=self.repo, env=env, text=True, capture_output=True)

    def test_frozen_client_passes_and_writes_github_outputs(self):
        sha = self.freeze()
        output = self.repo / 'output'
        result = self.verify('--sha', sha, '--require-client', '--release-tag', 'v1.2.0', '--github-output', str(output))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('build_required=true', output.read_text())
        self.assertIn('batch_id=batch-1', output.read_text())

    def test_backend_batch_skips_client_compile_but_requires_its_production_target(self):
        self.manifest.update(scope='server', target='museummuse-api')
        self.manifest['prepared']['localValidation']['mode'] = 'backend'
        self.freeze()
        result = self.verify('--allow-development')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(json.loads(result.stdout)['buildRequired'])
        self.assertNotEqual(self.verify('--require-client').returncode, 0)
        self.manifest['target'] = 'wrong-backend'
        self.freeze()
        self.assertNotEqual(self.verify('--allow-development').returncode, 0)

    def test_backend_fingerprint_may_bind_multiple_immutable_inputs(self):
        self.manifest.update(scope='server', target='museummuse-api')
        self.manifest['prepared']['localValidation']['mode'] = 'backend'
        self.manifest['prepared']['inputFingerprint'] = {'sqliteSha256': 'a' * 64, 'manifestSha256': 'b' * 64}
        self.freeze()
        self.assertEqual(self.verify().returncode, 0)

    def test_backend_tooling_batch_skips_ios_version_checks(self):
        self.manifest.update(scope='server', target='museummuse-api')
        self.manifest['prepared'] = dict(version='dataset-v1', localValidation={'mode': 'tooling', 'status': 'passed'}, inputFingerprint={'sqliteSha256': 'a' * 64})
        self.freeze()
        result = self.verify()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(json.loads(result.stdout)['buildRequired'])
        self.assertNotEqual(self.verify('--require-client').returncode, 0)

    def test_local_validation_must_have_passed(self):
        self.manifest['prepared']['localValidation']['status'] = 'failed'
        self.freeze()
        self.assertNotEqual(self.verify().returncode, 0)

    def test_tooling_batch_skips_build_and_cannot_release_client(self):
        self.manifest['prepared']['localValidation']['mode'] = 'tooling'
        self.freeze()
        result = self.verify()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(json.loads(result.stdout)['buildRequired'])
        self.assertNotEqual(self.verify('--require-client').returncode, 0)

    def test_followup_main_commit_cannot_reuse_manifest(self):
        self.freeze()
        (self.repo / 'notes.md').write_text('follow up')
        self.git('add', '.')
        self.git('commit', '-m', 'docs')
        self.assertNotEqual(self.verify('--allow-development').returncode, 0)
        self.git('checkout', '-b', 'codex/development')
        self.assertEqual(self.verify('--allow-development').returncode, 0)

    def test_unfrozen_development_can_compile(self):
        self.git('checkout', '-b', 'codex/development')
        result = self.verify('--allow-development')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(json.loads(result.stdout)['buildRequired'])
        self.assertNotEqual(self.verify().returncode, 0)

    def test_ordinary_main_build_does_not_require_a_new_release_batch(self):
        for historical_batch in (False, True):
            with self.subTest(historical_batch=historical_batch):
                if historical_batch:
                    self.freeze()
                    (self.repo / 'notes.md').write_text('ordinary follow-up')
                    self.git('add', '.')
                    self.git('commit', '-m', 'follow-up')
                result = self.verify('--allow-unfrozen', ref='refs/heads/main')
                self.assertEqual(result.returncode, 0, result.stderr)
                context = json.loads(result.stdout)
                self.assertEqual(context['frozenSHA'], self.git('rev-parse', 'HEAD'))
                self.assertTrue(context['buildRequired'])
                self.assertEqual(context['mode'], 'unreleased')
                self.assertEqual(context['batchId'], '')
                self.assertEqual(context['tasks'], [])
                self.assertNotEqual(self.verify('--allow-unfrozen', '--require-client').returncode, 0)
                self.assertNotEqual(self.verify('--allow-unfrozen', '--release-tag', 'v1.2.0').returncode, 0)

    def test_ordinary_build_option_does_not_relax_tag_or_detached_release_checks(self):
        self.git('checkout', '--detach')
        self.assertNotEqual(self.verify('--allow-unfrozen').returncode, 0)
        self.assertNotEqual(self.verify('--allow-unfrozen', ref='refs/tags/v1.2.0').returncode, 0)
        result = self.verify('--allow-unfrozen', ref='refs/heads/main')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_ordinary_build_option_still_checks_current_frozen_manifest(self):
        self.manifest['tasks'][0]['validation']['checks'][0]['status'] = 'failed'
        self.freeze()
        result = self.verify('--allow-unfrozen', ref='refs/heads/main')
        self.assertNotEqual(result.returncode, 0)

    def test_rejects_sha_mismatch_failed_checks_wrong_target_and_version(self):
        for mutate in (
            lambda m: m['tasks'][0]['validation']['checks'][0].update(status='failed'),
            lambda m: m.update(target='wrong'),
            lambda m: m['prepared'].update(version='9.9.9'),
            lambda m: m.update(environment='staging'),
            lambda m: m['prepared'].update(inputFingerprint=''),
        ):
            with self.subTest(mutate=mutate):
                original = json.loads(json.dumps(self.manifest))
                mutate(self.manifest)
                self.freeze()
                self.assertNotEqual(self.verify().returncode, 0)
                self.manifest = original
        self.freeze()
        self.assertNotEqual(self.verify('--sha', self.task_sha).returncode, 0)

    def test_rejects_task_not_in_frozen_history(self):
        self.git('checkout', '-b', 'other')
        (self.repo / 'other').write_text('other')
        self.git('add', '.')
        self.git('commit', '-m', 'other')
        self.manifest['tasks'][0]['sha'] = self.git('rev-parse', 'HEAD')
        self.git('checkout', 'main')
        self.freeze()
        self.assertNotEqual(self.verify().returncode, 0)

    def test_tag_version_and_widget_version_must_match(self):
        self.freeze()
        self.assertNotEqual(self.verify('--release-tag', 'v1.2.1').returncode, 0)
        widget = self.repo / 'DailyMuseumWidget/Info.plist'
        widget.write_bytes(plistlib.dumps({'CFBundleVersion': '11', 'CFBundleShortVersionString': '1.2.0'}))
        self.git('add', '.')
        self.git('commit', '-m', 'widget mismatch')
        self.manifest['batchId'] = 'batch-2'
        self.freeze()
        self.assertNotEqual(self.verify().returncode, 0)

    def test_packaging_fixture_requires_actual_build_source_and_emits_frozen_context(self):
        scripts = self.repo / 'scripts'
        scripts.mkdir()
        for filename in ('package_ios_release.sh', 'verify_release_batch.py'):
            (scripts / filename).write_bytes((SCRIPT.parent / filename).read_bytes())
        (self.repo / '.gitignore').write_text('build/\n__pycache__/\n')
        self.git('add', '.')
        self.git('commit', '-m', 'packaging tools')
        sha = self.freeze()
        output = self.repo / 'build/ci'
        app = output / 'device-derived-data/Build/Products/Release-iphoneos/DailyMuseum.app'
        widget = app / 'PlugIns/DailyMuseumWidgetExtension.appex'
        for target, suffix in [(app, ''), (widget, '.widget')]:
            target.mkdir(parents=True, exist_ok=True)
            info = dict(CFBundleVersion='10', CFBundleShortVersionString='1.2.0',
                        CFBundleIdentifier='tech.zh0ngtian.MuseumMuse' + suffix,
                        CFBundleExecutable='fixture', MuseumBackendSimpleAuthSecret='test-fixture-secret',
                        MuseumWidgetCompatibilityBuild='YES')
            (target / 'Info.plist').write_bytes(plistlib.dumps(info))
            (target / 'fixture').write_bytes(b'fixture executable bytes; no App compiled')
        source = dict(sha=sha, batchId='batch-1', sourceTree=self.git('rev-parse', 'HEAD^{tree}'),
                      sourceClean=True, authConfigured=True, version='1.2.0', buildNumber='10', runId='123')
        source_path = output / 'build-source.json'
        source_path.write_text(json.dumps(source))
        env = {**os.environ, 'BUILD_SHA': sha, 'RELEASE_TAG': 'v1.2.0', 'GITHUB_RUN_ID': '123', 'AUTH_CONFIGURED': 'true'}
        command = ['bash', str(scripts / 'package_ios_release.sh')]
        result = subprocess.run(command, cwd=self.repo, env=env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        metadata = json.loads((output / 'MuseumMuse-unsigned.json').read_text())
        self.assertEqual(metadata['commit'], sha)
        self.assertEqual(metadata['batchId'], 'batch-1')
        self.assertEqual(metadata['tasks'], self.manifest['tasks'])
        self.assertEqual(metadata['runId'], '123')
        source_path.write_text(json.dumps({**source, 'sha': self.task_sha}))
        result = subprocess.run(command, cwd=self.repo, env=env, text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Actual build source does not match', result.stderr)
        source_path.unlink()
        result = subprocess.run(command, cwd=self.repo, env=env, text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)

    def test_build_script_records_only_successful_unchanged_source(self):
        scripts = self.repo / 'scripts'
        scripts.mkdir()
        for filename in ('check_ios_build.sh', 'verify_release_batch.py'):
            (scripts / filename).write_bytes((SCRIPT.parent / filename).read_bytes())
        (self.repo / '.gitignore').write_text('build/\n__pycache__/\n')
        self.git('add', '.')
        self.git('commit', '-m', 'build tools')
        binaries = tempfile.TemporaryDirectory()
        self.addCleanup(binaries.cleanup)
        bin_dir = Path(binaries.name)
        (bin_dir / 'xcodebuild').write_text('#!/bin/bash\nif [[ "$1" == "-project" ]]; then\n  if [[ "${FAKE_BUILD_FAIL:-0}" == 1 ]]; then exit 42; fi\n  if [[ "${FAKE_MUTATE_SOURCE:-0}" == 1 ]]; then echo changed >> DailyMuseum.xcodeproj/project.pbxproj; fi\nfi\necho fake-toolchain\n')
        (bin_dir / 'xcrun').write_text('#!/bin/bash\necho fake-sdk\n')
        for path in bin_dir.iterdir():
            path.chmod(0o755)
        env = {k: v for k, v in os.environ.items() if k not in ('BUILD_SHA', 'GITHUB_SHA', 'GITHUB_REF', 'RELEASE_TAG')}
        build_output = tempfile.TemporaryDirectory()
        self.addCleanup(build_output.cleanup)
        env.update(MUSEUMMUSE_BUILD_OUTPUT=build_output.name, PATH=str(bin_dir) + os.pathsep + env['PATH'], MUSEUMMUSE_SIMPLE_AUTH_SECRET='test-fixture-secret', GITHUB_RUN_ID='123')
        command = ['bash', str(scripts / 'check_ios_build.sh')]
        result = subprocess.run(command, cwd=self.repo, env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        source_path = Path(build_output.name) / 'build-source.json'
        self.assertTrue(source_path.is_file(), 'Build provenance must use explicit private output directory')
        source = json.loads(source_path.read_text())
        self.assertEqual(source['sha'], self.git('rev-parse', 'HEAD'))
        self.assertEqual(source['sourceTree'], self.git('rev-parse', 'HEAD^{tree}'))
        self.assertTrue(source['authConfigured'])
        self.assertEqual(source['runId'], '123')
        self.assertEqual(source['batchId'], '')
        result = subprocess.run(command, cwd=self.repo, env={**env, 'REQUIRE_RELEASE_BATCH_CLIENT': 'true'}, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0, 'Release builds must still require a frozen client batch')
        self.assertFalse(source_path.exists())
        result = subprocess.run(command, cwd=self.repo, env={**env, 'FAKE_BUILD_FAIL': '1'}, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(source_path.exists(), 'Failed compiler must remove stale success provenance')
        result = subprocess.run(command, cwd=self.repo, env={**env, 'FAKE_MUTATE_SOURCE': '1'}, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(source_path.exists(), 'Source mutation during build must not produce provenance')

    def test_shallow_checkout_cannot_validate_frozen_history(self):
        self.freeze()
        clone = tempfile.TemporaryDirectory()
        self.addCleanup(clone.cleanup)
        subprocess.check_call(['git', 'clone', '--quiet', '--depth', '1', self.repo.as_uri(), clone.name])
        result = subprocess.run([sys.executable, str(SCRIPT)], cwd=clone.name, text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('full Git history', result.stderr)

    def test_build_provenance_binds_clean_source_tree_and_batch(self):
        sha = self.freeze()
        spec = importlib.util.spec_from_file_location('verify_release_batch', SCRIPT)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        self.assertTrue(hasattr(module, 'validate_build_source'), 'Missing build provenance validator')
        batch = module.verify_batch(self.repo, sha, require_client=True)
        source = dict(sha=sha, batchId='batch-1', sourceTree=self.git('rev-parse', 'HEAD^{tree}'),
                      sourceClean=True, authConfigured=True, version='1.2.0', buildNumber='10')
        module.validate_build_source(self.repo, source, batch)
        for field, value in [('sha', self.task_sha), ('batchId', 'other'), ('sourceTree', '0' * 40),
                             ('sourceClean', False), ('version', '1.2.1'), ('authConfigured', 'true')]:
            with self.subTest(field=field):
                with self.assertRaises(ValueError):
                    module.validate_build_source(self.repo, {**source, field: value}, batch)
        (self.repo / 'untracked-source.swift').write_text('source mutation')
        with self.assertRaises(ValueError):
            module.validate_build_source(self.repo, source, batch)

    def test_dirty_manifest_is_rejected(self):
        self.freeze()
        (self.repo / '.release-batch.json').write_text(json.dumps({**self.manifest, 'batchId': 'edited'}))
        self.assertNotEqual(self.verify().returncode, 0)

if __name__ == '__main__':
    unittest.main()
