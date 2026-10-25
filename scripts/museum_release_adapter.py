#!/usr/bin/env python3
"""MuseumMuse client release policy for the shared release-coordinator service."""
import argparse
import fcntl
import hashlib
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

CLIENT_PATHS = ('DailyMuseum/', 'DailyMuseumWidget/', 'Shared/', 'DailyMuseumTests/', 'DailyMuseum.xcodeproj/', 'Config/')
CLIENT_FILES = {'Project.yml'}
PHASES = ('promote', 'build', 'github', 'verify')
RETIRED_PHASES = ('device', 'sign', 'ota')


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

    def release_notes(self, version):
        notes = (self.workspace / 'Config/ReleaseNotes' / (version + '.md')).read_text().strip()
        if not re.search(r'[\u4e00-\u9fff]', notes):
            raise ValueError('Release notes must describe the delivered changes in Chinese')
        return notes

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
                remote = self.git('ls-remote', '--tags', 'origin')
                floors = [version]
                floors += re.findall(r'refs/tags/v(\d+\.\d+\.\d+)(?:\^\{\})?$', remote, re.M)
                major, minor, patch = max(map(version_tuple, floors))
                if patch >= 999:
                    raise ValueError('Patch version exhausted; explicit higher minor required')
                version = f'{major}.{minor}.{patch + 1}'
                build += 1
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
            self.release_notes(reserved['version'])
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

    def check_verify(self):
        promoted = self.check_promote()
        if not promoted['done']:
            return promoted
        if self.mode() == 'tooling':
            return {'done': True, 'result': {'sourceCommit': self.context['frozen']['sha'], 'mode': 'tooling',
                                            'main': promoted['result'], 'newClientBuildRequired': False}}
        results = {'promote': promoted['result']}
        for phase in ('build', 'github'):
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
                                        'localAcceptance': 'passed', 'delivery': 'unsigned-ipa'}}

    def run_verify(self):
        return self.check_verify()

    def phase(self, action, phase):
        if phase == 'prepare':
            if action != 'run':
                raise ValueError('Preparation requires run')
            return self.prepare()
        if phase not in PHASES + RETIRED_PHASES:
            raise ValueError('Unknown client release phase')
        self.assert_frozen()
        # Older coordinator configurations can still request these retired phases.
        # Finish without reading signing material or accessing the former OTA channel.
        if phase in RETIRED_PHASES:
            return {'done': True, 'result': {'required': False, 'reason': 'unsigned-ipa-only',
                                            'sourceCommit': self.context['frozen']['sha']}}
        if self.mode() == 'tooling' and phase in ('build', 'github'):
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
