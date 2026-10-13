#!/usr/bin/env python3
"""Recoverable SCF release adapter. Stdout is the coordinator JSON protocol only."""
from __future__ import annotations

import argparse
import base64
import fcntl
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import socket
import stat
import sqlite3
import subprocess
import sys
import tempfile
import time
import urllib.request
import zipfile


PHASES = ('promote', 'package', 'deploy', 'verify')
BACKEND_PREFIXES = ('server/api/', 'server/crawler/', 'server/schema/')
DATA_RELEASE_PATHS = ('server/data/', '.museum-data-release.json')
MARKER_PATH = 'data/release-marker.json'


def digest(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()



def archive_contents(source):
    """Identity of every runtime file, independent of ZIP ordering/compression metadata."""
    entries = []
    seen = set()
    try:
        with zipfile.ZipFile(io.BytesIO(source) if isinstance(source, bytes) else source) as archive:
            for item in archive.infolist():
                name = item.filename
                trimmed = name.rstrip('/')
                if (not trimmed or name.startswith('/') or '\\' in name
                        or any(part in ('', '.', '..') for part in trimmed.split('/'))
                        or trimmed in seen or PurePosixPath(trimmed).is_absolute()):
                    raise RuntimeError('Unsafe or duplicate deployed code archive entry')
                seen.add(trimmed)
                mode = item.external_attr >> 16
                kind = stat.S_IFMT(mode)
                if item.is_dir():
                    if kind not in (0, stat.S_IFDIR):
                        raise RuntimeError('Non-directory archive entry type')
                    continue
                if kind not in (0, stat.S_IFREG):
                    raise RuntimeError('Symlink or special deployed code archive entry')
                checksum = hashlib.sha256()
                count = 0
                with archive.open(item) as stream:
                    for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                        count += len(chunk)
                        checksum.update(chunk)
                if count != item.file_size:
                    raise RuntimeError('Code archive entry size differs')
                entries.append({'path': trimmed, 'bytes': count, 'mode': mode & 0o777,
                                'sha256': checksum.hexdigest()})
    except (OSError, zipfile.BadZipFile, RuntimeError) as error:
        raise RuntimeError('Cannot prove deployed code archive contents: ' + str(error)) from error
    if not entries:
        raise RuntimeError('Deployed code archive has no files')
    entries.sort(key=lambda entry: entry['path'])
    encoded = json.dumps(entries, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode()
    return {'codeContentsSha256': hashlib.sha256(encoded).hexdigest(), 'codeFileCount': len(entries)}


def atomic_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, temporary = tempfile.mkstemp(dir=path.parent, prefix=path.name + '.')
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(value, stream, sort_keys=True)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def command(argv, *, cwd=None, env=None):
    # Cloud commands can return secrets or signed URLs; never echo their raw output.
    result = subprocess.run(argv, cwd=cwd, env=env, text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError('Command failed (exit %s): %s' % (result.returncode, Path(argv[0]).name))
    return result.stdout.strip()


class SCFAdapter:
    def __init__(self, context, runner=None, context_path=None):
        if isinstance(context, (str, Path)):
            context_path = Path(context)
            context = json.loads(context_path.read_text())
        self.context = context
        self.work = Path(context['workspace']).resolve()
        self.options = context['config'].get('options', {})
        self.runner = runner or command
        self.python = self.options.get('python', sys.executable)
        self.context_path = Path(context_path or context.get('contextPath', self.work / '.contexts' / 'batch.json')).resolve()
        batch_id = context['id']
        if not re.fullmatch(r'[A-Za-z0-9_-]+', batch_id):
            raise RuntimeError('Invalid batch id')
        self.state_root = self.context_path.parent.parent
        self.directory = self.state_root / 'museum-releases' / batch_id
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.checkpoint = self.directory / 'scf-checkpoint.json'

    def call(self, argv, **kwargs):
        return self.runner(argv, cwd=kwargs.pop('cwd', self.work), **kwargs)

    def git(self, *args):
        return self.call(['git', *args])

    def load(self):
        return json.loads(self.checkpoint.read_text()) if self.checkpoint.exists() else {}

    def save(self, value):
        atomic_json(self.checkpoint, value)
        if self.context.get('progressPath'):
            # No cloud configuration, credentials or presigned download URLs in progress.
            atomic_json(self.context['progressPath'], {'batchId': self.context['id'], 'scf': value})

    def response(self, done, result):
        return {'done': done, 'result': result}

    def remember(self, phase, result):
        state = self.load()
        state[phase] = result
        self.save(state)
        return self.response(True, result)

    def source_gate(self):
        frozen = self.context.get('frozen', {})
        sha = frozen.get('sha', '')
        if not re.fullmatch(r'[0-9a-f]{40}', sha):
            raise RuntimeError('Missing exact frozen SHA')
        if self.git('rev-parse', 'HEAD') != sha:
            raise RuntimeError('Workspace HEAD differs from frozen sourceCommit')
        if self.git('status', '--porcelain', '--untracked-files=all'):
            raise RuntimeError('Frozen source tree must be clean; uncommitted or untracked changes present')
        manifest = self.work / '.release-batch.json'
        if not manifest.exists() or digest(manifest) != frozen.get('manifestSha256'):
            raise RuntimeError('Frozen batch manifest checksum differs')
        if self.git('log', '-1', '--format=%H', '--', '.release-batch.json') != sha:
            raise RuntimeError('Frozen SHA must be the exact introducing commit of the manifest')
        batch = json.loads(manifest.read_text())
        if (batch.get('target') != 'museummuse-api' or batch.get('environment') != 'production'
                or batch.get('batchId') != self.context['id']):
            raise RuntimeError('Frozen manifest batchId/target/environment differs from SCF production context')
        expected_tasks = [{'id': task['id'], 'sha': task['sha'],
                           'validation': {'checks': [{'name': check['name'], 'status': check['status']}
                                                     for check in task['validation']['checks']]}}
                          for task in self.context['tasks']]
        if not expected_tasks or batch.get('tasks') != expected_tasks:
            raise RuntimeError('Frozen manifest tasks differ from coordinator context')
        for task in self.context['tasks']:
            self.git('merge-base', '--is-ancestor', task['sha'], sha)
        # Share CI's schema, mode, checks, full-history and source-ancestry gates.
        verified = json.loads(self.call([self.python, str(self.work / 'scripts/verify_release_batch.py'), '--sha', sha]))
        if verified.get('frozenSHA') != sha:
            raise RuntimeError('Core frozen batch verifier did not prove the source SHA')
        state = self.load()
        if state.get('frozenSHA') and state['frozenSHA'] != sha:
            raise RuntimeError('Checkpoint belongs to another frozen source SHA')
        if not state.get('frozenSHA'):
            state['frozenSHA'] = sha
            self.save(state)
        return sha

    def mode(self):
        paths = set()
        tasks = self.context.get('tasks', [])
        if not tasks:
            raise RuntimeError('Task validation.baseSha required to determine backend changes')
        for task in tasks:
            base = task.get('validation', {}).get('baseSha', '')
            sha = task.get('sha', '')
            if not all(re.fullmatch(r'[0-9a-f]{40}', x) for x in (base, sha)):
                raise RuntimeError('Task validation.baseSha and sha must be exact commits')
            self.git('merge-base', '--is-ancestor', base, sha)
            paths.update(self.git('diff', '--name-only', base + '..' + sha).splitlines())
        backend = any(p.startswith(BACKEND_PREFIXES + DATA_RELEASE_PATHS) and not p.endswith(('.md', '.txt', '.rst')) for p in paths)
        return 'backend' if backend else 'tooling'

    def health(self):
        url = self.options.get('base_url', 'https://museum-api.zh0ngtian.tech').rstrip('/') + '/health'
        with urllib.request.urlopen(url, timeout=15) as response:
            result = json.load(response)
        if not result.get('ok') or not result.get('databaseReadable') or not result.get('dataVersion'):
            raise RuntimeError('Backend health/readable/dataVersion check failed')
        return result

    def probe(self, **kwargs):
        script = self.work / 'scripts/probe_backend_release.py'
        argv = [self.python, str(script), '--base-url', kwargs.get('base_url', self.options.get('base_url', 'https://museum-api.zh0ngtian.tech')),
                '--repository', self.context['config']['repository']]
        if kwargs.get('marker'):
            path = self.directory / 'expected-marker.json'
            atomic_json(path, kwargs['marker'])
            argv += ['--expected-marker', str(path)]
        if kwargs.get('data_version'):
            argv += ['--data-version', kwargs['data_version']]
        return json.loads(self.call(argv))

    def prepare(self):
        # An O_EXCL reservation survives process death. flock protects each retry;
        # callers must not silently create a second version/reservation.
        lock_path = self.directory / 'prepare.lock'
        with lock_path.open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            state = self.load()
            if 'prepare' in state:
                return self.response(True, state['prepare'])
            reservation_path = self.directory / 'reservation.json'
            if reservation_path.exists():
                reservation = json.loads(reservation_path.read_text())
            else:
                mode = self.mode()
                live = self.health()
                reservation = {'mode': mode, 'dataVersion': live['dataVersion'],
                               'version': live['dataVersion'], 'previousSourceCommit': live.get('releaseMarker', {}).get('sourceCommit'),
                               'baseHealth': {k: live[k] for k in ('ok', 'databaseReadable', 'dataVersion')}}
                if mode == 'backend':
                    repo = Path(self.context['config']['repository'])
                    db = Path(self.options.get('sqlite_path', repo / 'server/data/museummuse-live-all.sqlite'))
                    manifest = Path(self.options.get('manifest_path', repo / 'server/data/museummuse-live-all.manifest.json'))
                    if not db.is_file() or not manifest.is_file():
                        raise RuntimeError('Private release SQLite/manifest missing; configure sqlite_path and manifest_path. No crawl/seed fallback.')
                    data_version = str(json.loads(manifest.read_text()).get('build_id', '')).strip()
                    if not data_version:
                        raise RuntimeError('Input manifest build_id/dataVersion missing')
                    reservation.update({'version': data_version, 'dataVersion': data_version,
                                        'originalSQLite': str(db.resolve()), 'originalManifest': str(manifest.resolve()),
                                        'inputFingerprint': {'sqliteSha256': digest(db), 'manifestSha256': digest(manifest)}})
                # Publish only a complete fsynced reservation. link is atomic
                # and fails if the reserved destination already exists.
                fd, temporary = tempfile.mkstemp(dir=self.directory, prefix='reservation.')
                try:
                    with os.fdopen(fd, 'w') as stream:
                        json.dump(reservation, stream)
                        stream.flush()
                        os.fsync(stream.fileno())
                    os.link(temporary, reservation_path)
                finally:
                    os.unlink(temporary)
            if reservation['mode'] == 'backend':
                for src_key, dst_name, hash_key in [('originalSQLite', 'museummuse.sqlite', 'sqliteSha256'),
                                                    ('originalManifest', 'manifest.json', 'manifestSha256')]:
                    destination = self.directory / dst_name
                    expected = reservation['inputFingerprint'][hash_key]
                    if not destination.exists():
                        source = Path(reservation[src_key])
                        if digest(source) != expected:
                            raise RuntimeError('Reserved release input changed; repair batch required')
                        temporary = destination.with_suffix(destination.suffix + '.tmp')
                        shutil.copyfile(source, temporary)
                        if digest(temporary) != expected:
                            raise RuntimeError('Release input changed during copy')
                        os.chmod(temporary, 0o400)
                        os.replace(temporary, destination)
                    if digest(destination) != expected:
                        raise RuntimeError('Immutable release input checksum differs')
                checks = self.validate_inputs(reservation)
            else:
                checks = {'passed': True, 'checks': ['tooling-scope', 'read-only-health'], 'skipped': 'backend package/deploy'}
            checks.update({'mode': reservation['mode'], 'status': 'passed'})
            result = {k: reservation[k] for k in ('mode', 'version', 'dataVersion', 'previousSourceCommit')}
            result.update({'localValidation': checks, 'inputFingerprint': reservation.get('inputFingerprint', {'dataVersion': reservation['dataVersion'], 'deployedSourceCommit': reservation.get('previousSourceCommit') or 'unrecorded'}),
                           'sqlitePath': str(self.directory / 'museummuse.sqlite') if reservation['mode'] == 'backend' else None})
            return self.remember('prepare', result)

    def validate_inputs(self, reservation):
        db = self.directory / 'museummuse.sqlite'
        with sqlite3.connect(db.as_uri() + '?mode=ro', uri=True) as connection:
            if connection.execute('PRAGMA integrity_check').fetchall() != [('ok',)]:
                raise RuntimeError('SQLite integrity_check failed')
        status_code = 'import json,sys; from server.crawler.main import build_crawl_status; print(json.dumps(build_crawl_status(sys.argv[1])))'
        status = json.loads(self.call([self.python, '-c', status_code, str(db)]))
        targets = status.get('targets', [])
        if not status.get('complete') or not targets or any(t.get('completion') != 'complete' for t in targets):
            raise RuntimeError('Crawler formal targets are not all completion=complete; sample/partial is not a full release')
        for tests in ('server/api/tests', 'server/crawler/tests'):
            self.call([self.python, '-B', '-m', 'unittest', 'discover', '-s', tests, '-v'])
        # Use a private local simple-auth secret so local tests never depend on cloud
        # credentials and still exercise actual signed requests and nonce replay.
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        env = os.environ.copy()
        env.update({'MUSEUMMUSE_DB_PATH': str(db), 'MUSEUMMUSE_AUTH_MODE': 'simple',
                    'MUSEUMMUSE_SIMPLE_AUTH_SECRET': os.urandom(32).hex(), 'MUSEUMMUSE_NONCE_STORE': 'memory'})
        log = (self.directory / 'local-api.log').open('a')
        process = subprocess.Popen([self.python, '-m', 'uvicorn', 'server.api.app:app', '--host', '127.0.0.1', '--port', str(port)], cwd=self.work, env=env, stdout=log, stderr=log)
        try:
            base = 'http://127.0.0.1:' + str(port)
            for _ in range(80):
                if process.poll() is not None:
                    raise RuntimeError('Local simple-auth API exited before validation')
                try:
                    with urllib.request.urlopen(base + '/health', timeout=1):
                        break
                except OSError:
                    time.sleep(.1)
            result = json.loads(self.call([self.python, str(self.work / 'scripts/probe_backend_release.py'), '--base-url', base,
                                          '--data-version', reservation['dataVersion']], env=env))
            if not result.get('passed'):
                raise RuntimeError('Local backend probe failed')
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            log.close()
        return {'passed': True, 'checks': ['sqlite-integrity', 'all-formal-crawler-targets-complete', 'server-api-tests', 'crawler-tests', 'local-simple-auth-api'],
                'crawlerTargets': [{k: t[k] for k in ('crawlerID', 'completion')} for t in targets]}

    def promote_check(self):
        sha = self.context['frozen']['sha']
        branch = self.context['config'].get('branch', 'main')
        remote = self.git('ls-remote', 'origin', 'refs/heads/' + branch).split()[0]
        if remote != sha:
            self.git('fetch', 'origin', branch)
            try:
                self.git('merge-base', '--is-ancestor', sha, remote)
            except RuntimeError:
                return self.response(False, {'sourceCommit': sha, 'remoteCommit': remote})
        return self.response(True, {'sourceCommit': sha, 'remoteCommit': remote, 'branch': branch})

    def promote(self):
        remote_url = self.git('remote', 'get-url', 'origin')
        locks = self.state_root / 'museum-main-locks'
        locks.mkdir(mode=0o700, exist_ok=True)
        lock_path = locks / hashlib.sha256(remote_url.encode()).hexdigest()
        with lock_path.open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            current = self.promote_check()
            if not current['done']:
                self.git('merge-base', '--is-ancestor', current['result']['remoteCommit'], self.context['frozen']['sha'])
                self.git('push', 'origin', self.context['frozen']['sha'] + ':refs/heads/' + self.context['config'].get('branch', 'main'))
                current = self.promote_check()
            if not current['done']:
                raise RuntimeError('Remote promotion not proven')
            return self.remember('promote', current['result'])

    def validate_marker(self, marker):
        if marker.get('sourceCommit') != self.context['frozen']['sha']:
            raise RuntimeError('Package sourceCommit differs from frozen SHA')
        prepared = self.load()['prepare']
        for key, expected in dict(prepared.get('inputFingerprint', {}), batchId=self.context['id'], dataVersion=prepared['dataVersion']).items():
            if marker.get(key) != expected:
                raise RuntimeError('Release marker ' + key + ' differs from frozen input')

    def package_check(self):
        result = self.load().get('package')
        if not result:
            return self.response(False, {})
        path = Path(result['path'])
        if not path.exists() or digest(path) != result['sha256']:
            raise RuntimeError('Checkpoint package missing or checksum changed; refusing rebuild')
        with zipfile.ZipFile(path) as archive:
            marker = json.loads(archive.read(MARKER_PATH))
            self.validate_marker(marker)
            for key, name in [('sqliteSha256', 'data/museummuse.sqlite'), ('manifestSha256', 'data/manifest.json')]:
                if hashlib.sha256(archive.read(name)).hexdigest() != marker[key]:
                    raise RuntimeError('Checkpoint package input checksum differs')
        return self.response(True, result)

    def package(self):
        # os.replace may have completed before the checkpoint/response was lost.
        # Prove the finished artifact and adopt it; never rebuild that batch.
        output = self.directory / 'api.zip'
        if not self.load().get('package') and output.exists():
            with zipfile.ZipFile(output) as archive:
                marker = json.loads(archive.read(MARKER_PATH))
                self.validate_marker(marker)
                for key, name in [('sqliteSha256', 'data/museummuse.sqlite'), ('manifestSha256', 'data/manifest.json')]:
                    if hashlib.sha256(archive.read(name)).hexdigest() != marker[key]:
                        raise RuntimeError('Completed package input checksum differs')
            self.remember('package', {'path': str(output), 'sha256': digest(output), 'marker': marker})
        checked = self.package_check()
        if checked['done']:
            return checked
        prepared = self.load()['prepare']
        for key, name in [('sqliteSha256', 'museummuse.sqlite'), ('manifestSha256', 'manifest.json')]:
            if digest(self.directory / name) != prepared['inputFingerprint'][key]:
                raise RuntimeError('Package input checksum changed')
        marker = dict(prepared['inputFingerprint'], sourceCommit=self.context['frozen']['sha'],
                      batchId=self.context['id'], dataVersion=prepared['dataVersion'])
        output = self.directory / 'api.zip'
        temporary = self.directory / 'api.building.zip'
        env = os.environ.copy()
        env['PATH'] = str(Path(self.python).parent) + os.pathsep + env.get('PATH', '')
        self.call(['bash', str(self.work / 'server/tencent_scf/build_package.sh'),
                   str(self.directory / 'museummuse.sqlite'), str(self.directory / 'manifest.json'), str(temporary)], env=env)
        with zipfile.ZipFile(temporary, 'a', compression=zipfile.ZIP_DEFLATED) as archive:
            archive.writestr(MARKER_PATH, json.dumps(marker, sort_keys=True))
            if hashlib.sha256(archive.read('data/museummuse.sqlite')).hexdigest() != prepared['inputFingerprint']['sqliteSha256']:
                raise RuntimeError('Packaged SQLite checksum differs')
            if hashlib.sha256(archive.read('data/manifest.json')).hexdigest() != prepared['inputFingerprint']['manifestSha256']:
                raise RuntimeError('Packaged manifest checksum differs')
        os.replace(temporary, output)
        return self.remember('package', {'path': str(output), 'sha256': digest(output), 'marker': marker})

    def tccli(self, action, **arguments):
        argv = [self.options.get('tccli', 'tccli'), 'scf', action, '--profile', self.options.get('tc_profile', 'default'),
                '--region', self.options.get('region', 'ap-guangzhou'), '--FunctionName', self.options.get('function', 'museummuse-api')]
        for key, value in arguments.items():
            argv += ['--' + key, str(value)]
        raw = json.loads(self.call(argv))
        result = raw.get('Response', raw)
        if result.get('Error'):
            raise RuntimeError('SCF ' + action + ' failed: ' + result['Error'].get('Code', 'unknown'))
        return result

    def function_configuration(self):
        remote = self.tccli('GetFunction', ShowCode='FALSE')
        env = {item['Key']: item['Value'] for item in remote.get('Environment', {}).get('Variables', [])}
        expected = {'MUSEUMMUSE_AUTH_MODE': 'simple', 'MUSEUMMUSE_NONCE_STORE': 'cos',
                    'MUSEUMMUSE_NONCE_COS_REGION': self.options.get('region', 'ap-guangzhou'),
                    'MUSEUMMUSE_NONCE_COS_BUCKET': self.options.get('bucket', 'museummuse-scf-artifacts-1259375612')}
        if any(env.get(k) != v for k, v in expected.items()) or not env.get('MUSEUMMUSE_SIMPLE_AUTH_SECRET'):
            raise RuntimeError('SCF simple-auth/nonce runtime contract mismatch')
        if remote.get('Role') != self.options.get('role', 'MuseumMuseSCFRole'):
            raise RuntimeError('SCF execution role mismatch')
        return {'status': remote.get('Status'), 'requestId': remote.get('RequestId'), 'codeInfoPresent': bool(remote.get('CodeInfo'))}

    def remote_deployment(self):
        remote = self.function_configuration()
        address = self.tccli('GetFunctionAddress')
        url = address.get('Url', '')
        if not url.startswith('https://'):
            raise RuntimeError('Cannot prove deployed source: no HTTPS code download URL')
        with urllib.request.urlopen(url, timeout=90) as stream:
            code = stream.read()
        checksum = hashlib.sha256(code).hexdigest()
        advertised = address.get('CodeSha256')
        if not advertised or advertised not in (checksum, base64.b64encode(hashlib.sha256(code).digest()).decode()):
            raise RuntimeError('SCF code download checksum differs from cloud metadata')
        with zipfile.ZipFile(io.BytesIO(code)) as archive:
            marker = json.loads(archive.read(MARKER_PATH)) if MARKER_PATH in archive.namelist() else {}
            if marker:
                for key, name in [('sqliteSha256', 'data/museummuse.sqlite'), ('manifestSha256', 'data/manifest.json')]:
                    if hashlib.sha256(archive.read(name)).hexdigest() != marker.get(key):
                        raise RuntimeError('SCF packaged input differs from release marker')
        return dict(remote, marker=marker, zipSha256=checksum, **archive_contents(code))

    def deploy_check(self):
        package = self.load().get('package')
        if not package:
            return self.response(False, {})
        remote = self.remote_deployment()
        if remote['marker'].get('sourceCommit') != self.context['frozen']['sha']:
            return self.response(False, {'status': remote.get('status'), 'sourceCommit': remote['marker'].get('sourceCommit')})
        self.validate_marker(remote['marker'])
        package = self.package_check()['result']
        contents = archive_contents(Path(package['path']))
        if (remote.get('codeContentsSha256') != contents['codeContentsSha256']
                or remote.get('codeFileCount') != contents['codeFileCount']):
            raise RuntimeError('Cloud function file contents differ from exact frozen package')
        if remote.get('status') != 'Active':
            return self.response(False, {'status': remote.get('status')})
        health = self.health()
        if health.get('releaseMarker') != remote['marker'] or health['dataVersion'] != self.load()['prepare']['dataVersion']:
            return self.response(False, {'status': 'waiting-for-health-marker'})
        return self.response(True, {'sourceCommit': self.context['frozen']['sha'], 'uploadedZipSha256': package['sha256'],
                                    'deployedZipSha256': remote['zipSha256'], **contents,
                                    'releaseMarker': remote['marker'], 'status': 'Active', 'configurationVerified': True,
                                    'updateRequestId': self.load().get('deployIntent', {}).get('requestId'),
                                    'reconciledRequestId': remote.get('requestId')})

    def cos_client(self):
        try:
            from qcloud_cos import CosConfig, CosS3Client
        except ImportError as exc:
            raise RuntimeError('cos-python-sdk-v5 required in adapter Python runtime') from exc
        profile = self.options.get('tc_profile', 'default')
        credentials = json.loads((Path.home() / '.tccli' / (profile + '.credential')).read_text())
        config = CosConfig(Region=self.options.get('region', 'ap-guangzhou'),
                           SecretId=credentials['secretId'], SecretKey=credentials['secretKey'], Token=credentials.get('token'))
        return CosS3Client(config)

    def upload(self, package, key):
        client = self.cos_client()
        bucket = self.options.get('bucket', 'museummuse-scf-artifacts-1259375612')
        def head():
            try:
                return client.head_object(Bucket=bucket, Key=key)
            except Exception as exc:
                if getattr(exc, 'get_status_code', lambda: 0)() == 404:
                    return None
                raise RuntimeError('COS object metadata lookup failed') from None
        existing = head()
        if not existing:
            try:
                with Path(package['path']).open('rb') as stream:
                    client.put_object(Bucket=bucket, Key=key, Body=stream,
                                      Metadata={'x-cos-meta-sha256': package['sha256'], 'x-cos-meta-source-commit': self.context['frozen']['sha'],
                                                'x-cos-forbid-overwrite': 'true'})
            except Exception:
                # Lost upload response is recovered by metadata, never overwrite.
                existing = head()
                if not existing:
                    raise RuntimeError('COS upload not proven') from None
            existing = head()
        if not existing or existing.get('x-cos-meta-sha256') != package['sha256'] or existing.get('x-cos-meta-source-commit') != self.context['frozen']['sha']:
            raise RuntimeError('Existing versioned COS object has different source/checksum; overwrite forbidden')
        # Metadata alone is not artifact proof: read the actual object checksum.
        response = client.get_object(Bucket=bucket, Key=key)
        body = response['Body'].get_raw_stream()
        h = hashlib.sha256()
        for block in iter(lambda: body.read(1024 * 1024), b''):
            h.update(block)
        if h.hexdigest() != package['sha256']:
            raise RuntimeError('COS object body checksum differs')
        return {'bucket': bucket, 'objectKey': key, 'sha256': package['sha256'], 'sourceCommit': self.context['frozen']['sha']}

    def wait_for_deployment(self):
        """Read-only convergence after any submitted or uncertain update attempt."""
        deadline = time.monotonic() + float(self.options.get('deploy_wait_seconds', 45))
        while True:
            try:
                checked = self.deploy_check()
                if checked['done']:
                    return self.remember('deploy', checked['result'])
            except Exception as exc:
                # A transient read failure during an asynchronous update is not
                # proof of failed publication. Persist only a safe error type.
                state = self.load()
                state['deployIntent']['lastCheckErrorType'] = type(exc).__name__
                self.save(state)
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise RuntimeError('Pending SCF update source remains unproven; no repeat deployment')
            time.sleep(min(2, remaining))

    def deploy(self):
        state = self.load()
        if state.get('deployIntent'):
            return self.wait_for_deployment()
        checked = self.deploy_check()
        if checked['done']:
            return self.remember('deploy', checked['result'])
        package = self.package_check()['result']
        key = 'deployments/museummuse/' + self.context['id'] + '/api.zip'
        uploaded = self.upload(package, key)
        state = self.load()
        state['upload'] = uploaded
        state['deployIntent'] = {'sourceCommit': self.context['frozen']['sha'], 'objectKey': key, 'zipSha256': package['sha256']}
        self.save(state)  # Must precede the side effect, including lost responses.
        try:
            update = self.tccli('UpdateFunctionCode', CosBucketName=uploaded['bucket'], CosObjectName=key,
                                CosBucketRegion=self.options.get('region', 'ap-guangzhou'))
            state['deployIntent']['requestId'] = update.get('RequestId')
        except Exception as exc:
            # The request may have reached SCF even when its response was lost.
            # Keep the intent and await actual cloud code/health proof once.
            state['deployIntent'].update({'responseUnavailable': True, 'responseErrorType': type(exc).__name__})
        self.save(state)
        return self.wait_for_deployment()

    def verify(self):
        promoted = self.promote_check()
        if not promoted['done']:
            raise RuntimeError('Frozen source no longer belongs to promoted remote main')
        prepared = self.load()['prepare']
        marker = None
        if prepared['mode'] == 'backend':
            deployment = self.deploy_check()
            if not deployment['done']:
                raise RuntimeError('SCF deployment has not been verified')
            marker = deployment['result']['releaseMarker']
        result = self.probe(marker=marker, data_version=prepared['dataVersion'])
        if not result.get('passed'):
            raise RuntimeError('Required backend probe channel failed')
        if prepared['mode'] == 'tooling' and result.get('releaseMarker', {}).get('sourceCommit') != prepared.get('previousSourceCommit'):
            raise RuntimeError('Tooling-only batch changed live backend source')
        result.update({'promotion': promoted['result'], 'mode': prepared['mode'], 'sourceCommit': self.context['frozen']['sha'],
                       'deployedSourceCommit': (marker or result.get('releaseMarker', {})).get('sourceCommit'),
                       'deploymentSkipped': prepared['mode'] == 'tooling'})
        return self.remember('verify', result)

    def check(self, phase):
        if phase == 'prepare':
            state = self.load()
            return self.response('prepare' in state, state.get('prepare', {}))
        self.source_gate()
        prepared = self.load().get('prepare')
        if not prepared:
            raise RuntimeError('Preparation checkpoint required')
        if phase in ('package', 'deploy') and prepared['mode'] == 'tooling':
            return self.response(True, {'skipped': 'tooling-only', 'sourceCommit': self.context['frozen']['sha'], 'dataVersion': prepared['dataVersion']})
        if phase == 'promote':
            return self.promote_check()
        if phase == 'package':
            return self.package_check()
        if phase == 'deploy':
            return self.deploy_check()
        if phase == 'verify':
            return self.verify()  # Fresh read-only channel verification on recovery.
        raise RuntimeError('Unknown phase')

    def run(self, phase):
        if phase == 'prepare':
            return self.prepare()
        self.source_gate()
        prepared = self.load().get('prepare')
        if not prepared:
            raise RuntimeError('Preparation checkpoint required')
        if phase in ('package', 'deploy') and prepared['mode'] == 'tooling':
            return self.remember(phase, {'skipped': 'tooling-only', 'sourceCommit': self.context['frozen']['sha'], 'dataVersion': prepared['dataVersion']})
        if phase not in PHASES:
            raise RuntimeError('Unknown phase')
        return getattr(self, phase)()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('run', 'check'))
    parser.add_argument('phase', choices=('prepare',) + PHASES)
    parser.add_argument('--context', required=True)
    args = parser.parse_args()
    try:
        adapter = SCFAdapter(args.context)
        result = getattr(adapter, args.action)(args.phase)
    except Exception as exc:
        # Do not print SDK exceptions: they may contain credentials/signed URLs.
        message = str(exc) if isinstance(exc, RuntimeError) else type(exc).__name__
        print(message, file=sys.stderr)
        print(json.dumps({'done': False, 'result': {'error': message}}))
        return 1
    print(json.dumps(result, sort_keys=True))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
