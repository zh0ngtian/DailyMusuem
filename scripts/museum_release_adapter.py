#!/usr/bin/env python3
"""MuseumMuse client release policy for the shared release-coordinator service."""
import argparse
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import time
import uuid
import zipfile

CLIENT_PATHS = ('DailyMuseum/', 'DailyMuseumWidget/', 'Shared/', 'DailyMuseumTests/', 'DailyMuseum.xcodeproj/', 'Config/')
CLIENT_FILES = {'Project.yml'}
PHASES = ('promote', 'build', 'github', 'device', 'sign', 'ota', 'verify')


def atomic_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    tmp = path.with_name(path.name + '.' + uuid.uuid4().hex)
    with tmp.open('x') as stream:
        os.chmod(tmp, 0o600)
        json.dump(value, stream, ensure_ascii=False, indent=2)
        stream.write('\n')
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(tmp, path)


def digest(path):
    result = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(chunk)
    return result.hexdigest()


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def version_tuple(value):
    if not re.fullmatch(r'\d+\.\d+\.\d+', str(value)):
        raise ValueError('Expected an existing X.Y.Z version')
    return tuple(map(int, value.split('.')))


class Adapter:
    def __init__(self, context):
        self.context = context
        self.workspace = Path(context['workspace'])
        self.config = context['config']
        self.options = self.config.get('options', {})
        self.state_root = Path(context['progressPath']).parent.parent
        self.root = self.state_root / 'museum-releases' / context['id']
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.path = self.root / 'checkpoint.json'
        self.state = json.loads(self.path.read_text()) if self.path.exists() else {}
        self.repo = self.options['github_repository']

    def save(self, **values):
        self.state.update(values)
        atomic_json(self.path, self.state)

    def progress(self, phase, **values):
        atomic_json(self.context['progressPath'], {'phase': phase, 'updatedAt': time.time(), **values})

    def secret(self):
        value = os.environ.get('MUSEUMMUSE_SIMPLE_AUTH_SECRET')
        if not value:
            path = Path(self.options['secret_config'])
            match = re.search(r'^\s*MUSEUMMUSE_SIMPLE_AUTH_SECRET\s*=\s*(.+?)\s*$', path.read_text(), re.M)
            value = match.group(1).strip().strip('"') if match else None
        if not value or value == 'ci-build-only-placeholder':
            raise ValueError('Private device build requires the existing backend auth configuration')
        return value

    def command(self, args, cwd=None, env=None, log=None):
        effective = {**os.environ, 'GIT_TERMINAL_PROMPT': '0', **(env or {})}
        if log:
            # Persist the compiler's completion marker before returning. Recovery can distinguish a completed build.
            with Path(log).open('w') as stream:
                os.chmod(log, 0o600)
                result = subprocess.run(args, cwd=cwd or self.workspace, env=effective,
                                        stdout=stream, stderr=subprocess.STDOUT, text=True)
            if result.returncode:
                raise RuntimeError(Path(str(args[0])).name + ' failed; diagnostics retained in batch log')
            return ''
        result = subprocess.run(args, cwd=cwd or self.workspace, env=effective, capture_output=True, text=True)
        if result.returncode:
            # No command arguments or environment values are included in errors.
            raise RuntimeError(Path(str(args[0])).name + ' exited ' + str(result.returncode))
        return result.stdout.strip()

    def json_command(self, args):
        return json.loads(self.command(args))

    def git(self, *args):
        return self.command(['git', *args])

    def mode(self):
        prepared = self.context.get('results', {}).get('prepare', self.state.get('reservation', {}))
        return prepared.get('localValidation', {}).get('mode', self.state.get('mode'))

    def ota_config(self):
        return json.loads(Path(self.options['ota_config']).read_text())

    def changed_paths(self):
        changed = set()
        for task in self.context['tasks']:
            base = task['validation'].get('baseSha', '')
            if not re.fullmatch(r'[0-9a-f]{40}', base):
                raise ValueError('Validation must record immutable baseSha for change classification')
            self.git('merge-base', '--is-ancestor', base, task['sha'])
            changed.update(self.git('diff', '--name-only', base, task['sha']).splitlines())
        return changed

    def reserve(self, mode):
        with (self.root / 'prepare.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            if self.path.exists():
                self.state = json.loads(self.path.read_text())
            if self.state.get('reservation'):
                if self.state['mode'] != mode:
                    raise ValueError('Reserved batch classification changed')
                return self.state['reservation']
            text = (self.workspace / 'Project.yml').read_text()
            versions = set(re.findall(r'MARKETING_VERSION:\s*(\d+\.\d+\.\d+)', text))
            builds = set(re.findall(r'CURRENT_PROJECT_VERSION:\s*(\d+)', text))
            if len(versions) != 1 or len(builds) != 1:
                raise ValueError('App, Widget and test project versions must agree')
            version, build = versions.pop(), int(builds.pop())
            engineering = (self.workspace / 'DailyMuseum.xcodeproj/project.pbxproj').read_text()
            if (set(re.findall(r'MARKETING_VERSION = (\d+\.\d+\.\d+);', engineering)) != {version}
                    or set(re.findall(r'CURRENT_PROJECT_VERSION = (\d+);', engineering)) != {str(build)}):
                raise ValueError('Xcode project and version configuration disagree')
            for name in ('DailyMuseum/Info.plist', 'DailyMuseumWidget/Info.plist'):
                info = plistlib.loads((self.workspace / name).read_bytes())
                if info['CFBundleShortVersionString'] != version or str(info['CFBundleVersion']) != str(build):
                    raise ValueError('App and Widget Info.plist versions disagree')
            if mode == 'client':
                config = self.ota_config()
                previous_path = Path(config['localRoot']) / 'current/latest-ios.json'
                previous = json.loads(previous_path.read_text()) if previous_path.exists() else {}
                remote = self.git('ls-remote', '--tags', 'origin')
                floors = [version, previous.get('version', version)]
                floors += re.findall(r'refs/tags/v(\d+\.\d+\.\d+)(?:\^\{\})?$', remote, re.M)
                major, minor, patch = max(map(version_tuple, floors))
                if patch >= 999:
                    raise ValueError('Patch version exhausted; explicit higher minor required')
                version = f'{major}.{minor}.{patch + 1}'
                build = max(build, int(previous.get('buildNumber', build))) + 1
            fingerprint = hashlib.sha256(json.dumps([(t['id'], t['sha'], t['validation']['baseSha'])
                                                      for t in self.context['tasks']], sort_keys=True).encode()).hexdigest()
            reserved = {'version': version, 'buildNumber': str(build),
                        'bundleIdentifier': 'tech.zh0ngtian.MuseumMuse',
                        'localValidation': {'mode': mode, 'status': 'reserved'}, 'inputFingerprint': fingerprint}
            # Reservation is durable before any version file is changed.
            self.save(reservation=reserved, mode=mode)
            return reserved

    def merged_checks(self, paths):
        self.command([sys.executable, '-B', '-m', 'unittest', 'discover', '-s', 'scripts/tests',
                      '-p', 'test_museum_release_adapter.py'])
        self.command([sys.executable, '-B', '-m', 'unittest', 'discover', '-s', 'scripts/tests',
                      '-p', 'test_release_batch.py'])
        self.git('diff', '--check')
        if self.state['mode'] == 'client':
            checks = {check['name'] for task in self.context['tasks'] for check in task['validation']['checks']
                      if check['status'] == 'passed' and check.get('evidence')}
            required = {'client-local'}
            if any(path.startswith('DailyMuseumWidget/') or 'Widget' in path for path in paths):
                required.add('widget-desktop')
            if not required <= checks:
                raise ValueError('Client readiness lacks local functional/Widget desktop evidence')
            self.command(['xcodebuild', '-project', 'DailyMuseum.xcodeproj', '-scheme', 'DailyMuseum',
                          '-configuration', 'Debug', '-destination', 'platform=iOS Simulator,name=iPhone 17 Pro',
                          '-derivedDataPath', str(self.root / 'simulator-derived-data'),
                          'CODE_SIGNING_ALLOWED=NO', 'build'], log=self.root / 'merged-simulator.log')

    def prepare(self):
        paths = self.changed_paths()
        mode = 'client' if any(p.startswith(CLIENT_PATHS) or p in CLIENT_FILES for p in paths) else 'tooling'
        reserved = self.reserve(mode)
        if mode == 'client':
            for name in ('Project.yml', 'DailyMuseum.xcodeproj/project.pbxproj'):
                path = self.workspace / name
                text = path.read_text()
                if name.endswith('.yml'):
                    text = re.sub(r'(MARKETING_VERSION:\s*)\d+\.\d+\.\d+', lambda m: m[1] + reserved['version'], text)
                    text = re.sub(r'(CURRENT_PROJECT_VERSION:\s*)\d+', lambda m: m[1] + reserved['buildNumber'], text)
                    text = re.sub(r'(CFBundleShortVersionString:\s*)[\"\']?\d+\.\d+\.\d+[\"\']?', lambda m: m[1] + '\"' + reserved['version'] + '\"', text)
                    text = re.sub(r'(CFBundleVersion:\s*)[\"\']?\d+[\"\']?', lambda m: m[1] + '\"' + reserved['buildNumber'] + '\"', text)
                else:
                    text = re.sub(r'(MARKETING_VERSION = )\d+\.\d+\.\d+', lambda m: m[1] + reserved['version'], text)
                    text = re.sub(r'(CURRENT_PROJECT_VERSION = )\d+', lambda m: m[1] + reserved['buildNumber'], text)
                path.write_text(text)
            for name in ('DailyMuseum/Info.plist', 'DailyMuseumWidget/Info.plist'):
                path = self.workspace / name
                info = plistlib.loads(path.read_bytes())
                info['CFBundleShortVersionString'] = reserved['version']
                info['CFBundleVersion'] = reserved['buildNumber']
                path.write_bytes(plistlib.dumps(info))
        self.merged_checks(paths)
        reserved = {**reserved, 'localValidation': {'mode': mode, 'status': 'passed'}}
        self.save(reservation=reserved)
        return {'done': True, 'result': reserved}

    def assert_frozen(self):
        frozen = self.context['frozen']
        if self.git('rev-parse', 'HEAD') != frozen['sha'] or self.git('status', '--porcelain'):
            raise ValueError('Frozen workspace changed')
        manifest_path = self.workspace / '.release-batch.json'
        if digest(manifest_path) != frozen['manifestSha256']:
            raise ValueError('Frozen manifest changed')
        manifest = json.loads(manifest_path.read_text())
        if (manifest['batchId'] != self.context['id'] or manifest['target'] != 'tech.zh0ngtian.MuseumMuse'
                or manifest['environment'] != 'production'
                or self.git('log', '-1', '--format=%H', '--', '.release-batch.json') != frozen['sha']):
            raise ValueError('Batch must match exact introducing commit and production target')
        if manifest['tasks'] != [{'id': t['id'], 'sha': t['sha'],
                                 'validation': {'checks': [{'name': c['name'], 'status': c['status']}
                                                          for c in t['validation']['checks']]}}
                                for t in self.context['tasks']]:
            raise ValueError('Frozen task list differs')
        for task in self.context['tasks']:
            self.git('merge-base', '--is-ancestor', task['sha'], frozen['sha'])
        existing = self.state.get('frozenSHA')
        if existing and existing != frozen['sha']:
            raise ValueError('Checkpoint belongs to another frozen source')
        self.save(frozenSHA=frozen['sha'])

    def check_promote(self):
        sha = self.context['frozen']['sha']
        remote = self.git('ls-remote', 'origin', 'refs/heads/' + self.config['branch']).split()
        if not remote:
            raise ValueError('Formal branch is missing')
        if remote[0] != sha:
            self.git('fetch', 'origin', self.config['branch'])
            try:
                self.git('merge-base', '--is-ancestor', sha, remote[0])
            except RuntimeError:
                return {'done': False, 'result': {'remoteHead': remote[0]}}
        return {'done': True, 'result': {'sourceCommit': sha, 'remoteHead': remote[0], 'branch': self.config['branch']}}

    def run_promote(self):
        lock_root = self.state_root / 'museum-main-locks'
        lock_root.mkdir(exist_ok=True, mode=0o700)
        key = hashlib.sha256(self.config['remote'].encode()).hexdigest()
        with (lock_root / key).open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            if not self.check_promote()['done']:
                self.git('push', 'origin', self.context['frozen']['sha'] + ':refs/heads/' + self.config['branch'])
        return self.check_promote()

    def runs(self, workflow):
        sha = self.context['frozen']['sha']
        data = self.json_command(['gh', 'api', f'repos/{self.repo}/actions/workflows/{workflow}/runs?head_sha={sha}&per_page=100'])
        return [run for run in data['workflow_runs'] if run['head_sha'] == sha]

    def workflow_check(self, phase, workflow, jobs):
        expected_event = 'push'
        candidates = [r for r in self.runs(workflow) if r['event'] == expected_event]
        pinned = self.state.get(phase + 'RunId')
        if pinned:
            candidates = [r for r in candidates if r['id'] == pinned]
        if not candidates:
            return {'done': False, 'result': {}}
        run = min(candidates, key=lambda r: r['id'])
        self.save(**{phase + 'RunId': run['id']})
        self.progress(phase, runId=run['id'], status=run['status'], attempt=run.get('run_attempt'))
        result = {'runId': run['id'], 'runUrl': run['html_url'], 'sourceCommit': run['head_sha'],
                  'attempt': run.get('run_attempt'), 'status': run['status']}
        if run['status'] != 'completed':
            return {'done': False, 'result': result}
        if run['conclusion'] != 'success':
            raise RuntimeError(phase + ' CI failed; retain batch and use a linked repair')
        details = self.json_command(['gh', 'api', f'repos/{self.repo}/actions/runs/{run["id"]}/jobs'])
        for name in jobs:
            if not any(j['name'] == name and j['conclusion'] == 'success' for j in details['jobs']):
                raise ValueError('Missing successful required CI job: ' + name)
        return {'done': True, 'result': result}

    def check_build(self):
        return self.workflow_check('build', 'ios-build.yml', ['Build'])

    def wait_for(self, phase):
        deadline = time.monotonic() + self.options.get('ci_timeout', 2400)
        while time.monotonic() < deadline:
            checked = getattr(self, 'check_' + phase)()
            if checked['done']:
                return checked
            time.sleep(8)
        raise TimeoutError('Existing operation has not completed; no replacement was triggered')

    def run_build(self):
        # The branch push is the durable, unique trigger. Do not submit another workflow when its response is late.
        return self.wait_for('build')

    def check_github(self):
        version = self.context['frozen']['version']
        tag = 'v' + version
        remote = self.git('ls-remote', 'origin', 'refs/tags/' + tag, 'refs/tags/' + tag + '^{}').splitlines()
        if not remote:
            return {'done': False, 'result': {}}
        ref_sha = next((line.split()[0] for line in remote if line.endswith('^{}')), remote[0].split()[0])
        if ref_sha != self.context['frozen']['sha']:
            raise ValueError('Immutable tag belongs to another frozen source')
        checked = self.workflow_check('github', 'ios-release.yml', ['Build', 'Publish unsigned IPA'])
        if not checked['done']:
            return checked
        release = self.json_command(['gh', 'release', 'view', tag, '--repo', self.repo, '--json', 'id,url,assets,tagName'])
        names = {'MuseumMuse-unsigned.ipa', 'MuseumMuse-unsigned.ipa.sha256', 'MuseumMuse-unsigned.json'}
        if {a['name'] for a in release['assets']} != names:
            raise ValueError('Release must contain exactly the three required attachments')
        with tempfile.TemporaryDirectory(prefix='museum-release-check-', dir=self.root) as directory:
            self.command(['gh', 'release', 'download', tag, '--repo', self.repo, '--dir', directory])
            folder = Path(directory)
            metadata = json.loads((folder / 'MuseumMuse-unsigned.json').read_text())
            ipa = folder / 'MuseumMuse-unsigned.ipa'
            checksum = digest(ipa)
            expected = self.context['frozen']
            if (metadata['commit'] != expected['sha'] or metadata['batchId'] != self.context['id']
                    or metadata['version'] != expected['version'] or str(metadata['build']) != expected['buildNumber']
                    or metadata['sha256'] != checksum or metadata.get('bytes') != ipa.stat().st_size
                    or str(metadata.get('runId')) != str(checked['result']['runId'])
                    or (folder / 'MuseumMuse-unsigned.ipa.sha256').read_text().split()[0] != checksum
                    or metadata.get('signed') is not False or metadata.get('widgetGroups') != 10):
                raise ValueError('GitHub artifacts do not match frozen batch')
            expected_tasks = [{'id': t['id'], 'sha': t['sha'],
                               'validation': {'checks': [{'name': c['name'], 'status': c['status']}
                                                        for c in t['validation']['checks']]}}
                              for t in self.context['tasks']]
            if metadata.get('tasks') != expected_tasks:
                raise ValueError('GitHub artifact task lineage differs')
        return {'done': True, 'result': {**checked['result'], 'releaseId': release['id'], 'url': release['url'], 'sha256': checksum}}

    def run_github(self):
        tag = 'v' + self.context['frozen']['version']
        remote = self.git('ls-remote', 'origin', 'refs/tags/' + tag)
        if not remote:
            existing = self.git('tag', '--list', tag)
            if existing and self.git('rev-parse', tag + '^{}') != self.context['frozen']['sha']:
                raise ValueError('Local tag belongs to another source')
            if not existing:
                self.git('tag', tag, self.context['frozen']['sha'])
            self.git('push', 'origin', 'refs/tags/' + tag)
        return self.wait_for('github')

    @property
    def app(self):
        return self.root / 'device-derived-data/Build/Products/Release-iphoneos/DailyMuseum.app'

    def check_device(self):
        log = self.root / 'device.log'
        intent = self.root / 'device-source.json'
        if not self.app.exists() or not log.exists() or not intent.exists():
            return {'done': False, 'result': {}}
        if json.loads(intent.read_text()) != {'sourceCommit': self.context['frozen']['sha'], 'batchId': self.context['id']}:
            raise ValueError('Device build directory belongs to another source')
        if '** BUILD SUCCEEDED **' not in log.read_text(errors='replace'):
            return {'done': False, 'result': {}}
        expected = self.context['frozen']
        source_path = self.root / 'build-source.json'
        input_path = self.root / 'build-input.json'
        evidence_path = source_path if source_path.exists() else input_path
        if not evidence_path.exists():
            return {'done': False, 'result': {}}
        provenance = json.loads(evidence_path.read_text())
        if (provenance.get('sha') != expected['sha'] or provenance.get('batchId') != self.context['id']
                or provenance.get('sourceClean') is not True or provenance.get('authConfigured') is not True
                or provenance.get('sourceTree') != self.git('rev-parse', 'HEAD^{tree}')
                or provenance.get('runId') != 'local-device:' + self.context['id']
                or provenance.get('version') != expected['version']
                or str(provenance.get('buildNumber')) != expected['buildNumber']):
            raise ValueError('Device compiler provenance differs from frozen source or private auth requirements')
        targets = [self.app, self.app / 'PlugIns/DailyMuseumWidgetExtension.appex']
        for target in targets:
            info = plistlib.loads((target / 'Info.plist').read_bytes())
            if (info['CFBundleShortVersionString'] != expected['version'] or str(info['CFBundleVersion']) != expected['buildNumber']
                    or not (target / info['CFBundleExecutable']).is_file()):
                raise ValueError('Device App/Widget version or executable differs')
        if not source_path.exists():
            # Compiler completed before its final response/checkpoint. Only matching immutable input + completed
            # compiler log + both actual targets may adopt the artifact without another build.
            atomic_json(source_path, provenance)
        return {'done': True, 'result': {'sourceCommit': expected['sha'], 'deviceBuildId': self.context['id']}}

    def run_device(self):
        if self.check_device()['done']:
            return self.check_device()
        atomic_json(self.root / 'device-source.json', {'sourceCommit': self.context['frozen']['sha'], 'batchId': self.context['id']})
        self.command(['bash', str(self.workspace / 'scripts/check_ios_build.sh')],
                     env={'MUSEUMMUSE_SIMPLE_AUTH_SECRET': self.secret(), 'MUSEUMMUSE_BUILD_OUTPUT': str(self.root),
                          'GITHUB_RUN_ID': 'local-device:' + self.context['id'], 'REQUIRE_RELEASE_BATCH_CLIENT': 'true'},
                     log=self.root / 'device-command.log')
        return self.check_device()

    def batch_signing_config(self):
        config = self.ota_config()
        config['version'] = self.context['frozen']['version']
        config['buildNumber'] = self.context['frozen']['buildNumber']
        config['coordinationLockDirectory'] = str(Path(self.options['ota_config']).parent)
        config['projectEntitlements'] = {'tech.zh0ngtian.MuseumMuse': str(self.workspace / 'DailyMuseum/DailyMuseum.entitlements'),
                                         'tech.zh0ngtian.MuseumMuse.widget': str(self.workspace / 'DailyMuseumWidget/DailyMuseumWidgetAppGroup.entitlements')}
        path = self.root / 'signing.local.json'
        atomic_json(path, config)
        return path, config

    def verify_signed(self, ipa):
        _, config = self.batch_signing_config()
        signer_adapter = load_module('museum_signing', self.workspace / 'scripts/sign_ios_widget_ipa.py')
        signer = signer_adapter.load_signer(config['skillDir'])
        proof = signer_adapter.validate_release(signer, Path(ipa), config)
        with zipfile.ZipFile(ipa) as archive:
            for name in ['Payload/DailyMuseum.app/Info.plist',
                         'Payload/DailyMuseum.app/PlugIns/DailyMuseumWidgetExtension.appex/Info.plist']:
                info = plistlib.loads(archive.read(name))
                if (info.get('MuseumReleaseSourceCommit') != self.context['frozen']['sha']
                        or info.get('MuseumReleaseBatchID') != self.context['id']):
                    raise ValueError('Signed IPA provenance differs from frozen batch')
        return proof

    def check_sign(self):
        ipa = self.root / 'MuseumMuse-signed.ipa'
        if not ipa.exists():
            return {'done': False, 'result': {}}
        proof = self.verify_signed(ipa)
        return {'done': True, 'result': {'sourceCommit': self.context['frozen']['sha'], 'batchId': self.context['id'],
                                        'sha256': proof['sha256'], 'targetsVerified': list(proof['targets'])}}

    def run_sign(self):
        if self.check_sign()['done']:
            return self.check_sign()
        if not self.check_device()['done']:
            raise ValueError('Device build is not verified')
        for target in [self.app, self.app / 'PlugIns/DailyMuseumWidgetExtension.appex']:
            path = target / 'Info.plist'
            info = plistlib.loads(path.read_bytes())
            info['MuseumReleaseSourceCommit'] = self.context['frozen']['sha']
            info['MuseumReleaseBatchID'] = self.context['id']
            path.write_bytes(plistlib.dumps(info))
        config, _ = self.batch_signing_config()
        self.command([sys.executable, str(self.workspace / 'scripts/sign_ios_widget_ipa.py'), '--config', str(config),
                      '--app', str(self.app), '--output', str(self.root / 'MuseumMuse-signed.ipa')])
        return self.check_sign()

    def ota_module(self):
        config = self.ota_config()
        if config.get('caFile'):
            os.environ['IOS_ADHOC_OTA_CA_FILE'] = config['caFile']
        return load_module('museum_ota', Path(config['skillDir']) / 'scripts/ios_ota.py')

    def live_ota(self, require_batch=True):
        config = self.ota_config()
        folder = Path(config['localRoot'])
        path = folder / ('releases/' + self.context['frozen']['version'] + '/latest-ios.json' if require_batch else 'current/latest-ios.json')
        if not path.exists():
            return None
        receipt = json.loads(path.read_text())
        if require_batch:
            if (receipt.get('sourceCommit') != self.context['frozen']['sha'] or receipt.get('batchId') != self.context['id']
                    or receipt.get('version') != self.context['frozen']['version']
                    or str(receipt.get('buildNumber')) != self.context['frozen']['buildNumber']):
                raise ValueError('Immutable OTA release belongs to a different batch')
            signed = self.check_sign()
            if not signed['done'] or signed['result']['sha256'] != receipt['sha256']:
                raise ValueError('Published OTA IPA differs from independently verified signed artifact')
        self.ota_module().verify_published(receipt, fixed=False)
        current = folder / 'current/latest-ios.json'
        if not current.exists():
            return {'receipt': receipt, 'activated': False}
        actual_current = json.loads(current.read_text())
        keys = ('sha256', 'version', 'buildNumber', 'sourceCommit', 'batchId') if require_batch else ('sha256', 'version', 'buildNumber')
        if any(actual_current.get(key) != receipt.get(key) for key in keys):
            return {'receipt': receipt, 'activated': False}
        self.ota_module().verify_published(receipt)
        return {'receipt': receipt, 'activated': True}

    def check_ota(self):
        checked = self.live_ota()
        if not checked:
            return {'done': False, 'result': {}}
        receipt = checked['receipt']
        return {'done': checked['activated'], 'result': {'sourceCommit': receipt['sourceCommit'], 'batchId': receipt['batchId'],
                                                        'version': receipt['version'], 'buildNumber': receipt['buildNumber'],
                                                        'sha256': receipt['sha256'], 'downloadUrl': receipt['downloadUrl'],
                                                        'installUrl': receipt['installUrl'], 'httpsFullDownloadVerified': True}}

    def run_ota(self):
        checked = self.live_ota()
        if checked:
            if not checked['activated']:
                # A staged immutable version is checked before activation; never sign or create it again.
                config = self.ota_config()
                folder = Path(config['localRoot'])
                self.ota_module().activate_staged(folder / 'releases' / self.context['frozen']['version'], folder)
            return self.check_ota()
        if not self.check_sign()['done']:
            raise ValueError('Signed artifact is not verified')
        config, _ = self.batch_signing_config()
        self.command([sys.executable, str(self.workspace / 'scripts/publish_ios_widget_ota.py'), '--config', str(config),
                      '--ipa', str(self.root / 'MuseumMuse-signed.ipa'), '--notes', '发布批次 ' + self.context['id'],
                      '--source-commit', self.context['frozen']['sha'], '--batch-id', self.context['id']])
        return self.check_ota()

    def verify_baseline_github(self, receipt):
        legacy = self.options.get('legacy_baseline', {'version': '1.1.3', 'buildNumber': '9',
                                                    'tag': 'build-b2ccbcddc4947bb62f7859e783b4f6a05a84928c'})
        historical = receipt['version'] == legacy['version'] and str(receipt['buildNumber']) == str(legacy['buildNumber'])
        tag = legacy['tag'] if historical else 'v' + receipt['version']
        release = self.json_command(['gh', 'release', 'view', tag, '--repo', self.repo, '--json', 'id,url,assets'])
        with tempfile.TemporaryDirectory(prefix='museum-baseline-', dir=self.root) as directory:
            self.command(['gh', 'release', 'download', tag, '--repo', self.repo, '--dir', directory,
                          '--pattern', 'MuseumMuse-unsigned*'])
            folder = Path(directory)
            ipa = folder / 'MuseumMuse-unsigned.ipa'
            checksum = digest(ipa)
            if (folder / 'MuseumMuse-unsigned.ipa.sha256').read_text().split()[0] != checksum:
                raise ValueError('Historical GitHub artifact checksum differs')
            with zipfile.ZipFile(ipa) as archive:
                for name in ['Payload/DailyMuseum.app/Info.plist',
                             'Payload/DailyMuseum.app/PlugIns/DailyMuseumWidgetExtension.appex/Info.plist']:
                    info = plistlib.loads(archive.read(name))
                    if info['CFBundleShortVersionString'] != receipt['version'] or str(info['CFBundleVersion']) != str(receipt['buildNumber']):
                        raise ValueError('Historical GitHub and current OTA versions differ')
            metadata_path = folder / 'MuseumMuse-unsigned.json'
            if not historical:
                if not metadata_path.exists():
                    raise ValueError('Coordinated current GitHub baseline lacks source metadata')
                metadata = json.loads(metadata_path.read_text())
                if (metadata.get('commit') != receipt.get('sourceCommit') or metadata.get('batchId') != receipt.get('batchId')
                        or metadata.get('version') != receipt['version'] or str(metadata.get('build')) != str(receipt['buildNumber'])
                        or metadata.get('sha256') != checksum):
                    raise ValueError('Current coordinated channels disagree on source')
        return {'releaseId': release['id'], 'url': release['url'], 'sha256': checksum,
                'artifactSource': 'historical-client-baseline' if historical else receipt['sourceCommit'],
                'metadataPresent': not historical}

    def check_verify(self):
        promoted = self.check_promote()
        if not promoted['done']:
            return promoted
        if self.mode() == 'tooling':
            current = self.live_ota(require_batch=False)
            if not current or not current['activated']:
                return {'done': False, 'result': {}}
            receipt = current['receipt']
            # Baseline signature checks use the deployed version, never claim it was built from this tooling SHA.
            config = self.ota_config()
            config = {**config, 'version': receipt['version'], 'buildNumber': receipt['buildNumber']}
            signing = load_module('museum_signing_baseline', self.workspace / 'scripts/sign_ios_widget_ipa.py')
            signer = signing.load_signer(config['skillDir'])
            ipa = Path(config['localRoot']) / 'current/latest.ipa'
            proof = signing.validate_release(signer, ipa, config)
            if proof['sha256'] != receipt['sha256']:
                raise ValueError('Current OTA and signature proof disagree')
            github = self.verify_baseline_github(receipt)
            return {'done': True, 'result': {'sourceCommit': self.context['frozen']['sha'], 'mode': 'tooling',
                                            'main': promoted['result'], 'githubBaseline': github,
                                            'otaBaseline': {k: receipt[k] for k in ('version', 'buildNumber', 'sha256', 'installUrl')},
                                            'baselineTargetsVerified': list(proof['targets']),
                                            'newClientBuildRequired': False, 'httpsFullDownloadVerified': True}}
        results = {}
        for phase in PHASES[:-1]:
            checked = getattr(self, 'check_' + phase)()
            if not checked['done']:
                return {'done': False, 'result': {'missingPhase': phase}}
            results[phase] = checked['result']
        paths = self.changed_paths()
        checks = {c['name'] for t in self.context['tasks'] for c in t['validation']['checks'] if c['status'] == 'passed' and c.get('evidence')}
        if 'client-local' not in checks:
            raise ValueError('Local client acceptance missing')
        if any(p.startswith('DailyMuseumWidget/') or 'Widget' in p for p in paths) and 'widget-desktop' not in checks:
            raise ValueError('Widget desktop/request/system-log acceptance missing')
        return {'done': True, 'result': {**results, 'sourceCommit': self.context['frozen']['sha'],
                                        'localAcceptance': 'passed', 'httpsFullDownloadVerified': True}}

    def run_verify(self):
        return self.check_verify()

    def phase(self, action, phase):
        if phase == 'prepare':
            if action != 'run':
                raise ValueError('Preparation requires run')
            return self.prepare()
        if phase not in PHASES:
            raise ValueError('Unknown client release phase')
        self.assert_frozen()
        if self.mode() == 'tooling' and phase in ('build', 'github', 'device', 'sign', 'ota'):
            return {'done': True, 'result': {'required': False, 'reason': 'tooling-only', 'sourceCommit': self.context['frozen']['sha']}}
        return getattr(self, action + '_' + phase)()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['check', 'run'])
    parser.add_argument('phase')
    parser.add_argument('--context', required=True)
    args = parser.parse_args()
    try:
        adapter = Adapter(json.loads(Path(args.context).read_text()))
        print(json.dumps(adapter.phase(args.action, args.phase), ensure_ascii=False))
    except Exception as error:
        print(type(error).__name__ + ': ' + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
