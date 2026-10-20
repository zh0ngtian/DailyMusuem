#!/usr/bin/env python3
"""Check ordinary build context or bind a release to its frozen batch commit."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys

MANIFEST = '.release-batch.json'
BUNDLE_ID = 'tech.zh0ngtian.MuseumMuse'


def git(repo, *args):
    result = subprocess.run(['git', *args], cwd=repo, text=True, capture_output=True)
    if result.returncode:
        raise ValueError(f'Git verification failed: {" ".join(args)}: {result.stderr.strip()}')
    return result.stdout.strip()


def nonempty(value, label):
    if not isinstance(value, str) or not value.strip() or '\n' in value or '\r' in value:
        raise ValueError(f'{label} must be a nonempty single-line string')
    return value


def require_clean_tree(repo):
    if git(repo, 'status', '--porcelain', '--untracked-files=all'):
        raise ValueError('Source tree must be clean before recording or packaging build provenance')


def check_versions(repo, prepared, release_tag=None):
    version = nonempty(prepared.get('version'), 'prepared.version')
    build = str(prepared.get('buildNumber', ''))
    if not re.fullmatch(r'\d+\.\d+\.\d+', version) or not re.fullmatch(r'[1-9]\d*', build):
        raise ValueError('Prepared version/buildNumber must be X.Y.Z and a positive integer')
    if release_tag and release_tag != 'v' + version:
        raise ValueError('Release tag does not match frozen version')
    for directory in ('DailyMuseum', 'DailyMuseumWidget'):
        with (repo / directory / 'Info.plist').open('rb') as stream:
            info = plistlib.load(stream)
        if info.get('CFBundleShortVersionString') != version or str(info.get('CFBundleVersion')) != build:
            raise ValueError(f'{directory} source version does not match frozen version/buildNumber')
    project = (repo / 'DailyMuseum.xcodeproj/project.pbxproj').read_text()
    for key, expected in [('MARKETING_VERSION', version), ('CURRENT_PROJECT_VERSION', build)]:
        values = re.findall(r'\b' + key + r'\s*=\s*"?([^;"\s]+)"?\s*;', project)
        if not values or any(value != expected for value in values):
            raise ValueError(f'Xcode {key} does not match frozen version/buildNumber')


def is_development(repo):
    ref = os.environ.get('GITHUB_REF')
    if ref:
        return not (ref == 'refs/heads/main' or ref.startswith('refs/tags/'))
    return git(repo, 'branch', '--show-current') not in ('', 'main')


def is_branch_build(repo):
    ref = os.environ.get('GITHUB_REF')
    if ref:
        return ref.startswith(('refs/heads/', 'refs/pull/'))
    return bool(git(repo, 'branch', '--show-current'))


def verify_batch(repo, sha=None, *, require_client=False, allow_development=False, allow_unfrozen=False, release_tag=None):
    repo = Path(repo)
    head = git(repo, 'rev-parse', 'HEAD')
    sha = sha or os.environ.get('BUILD_SHA') or os.environ.get('GITHUB_SHA') or head
    if not re.fullmatch(r'[0-9a-f]{40}', sha) or sha != head:
        raise ValueError('Build SHA must be the full checked-out HEAD SHA')
    manifest_path = repo / MANIFEST
    introduced = git(repo, 'log', '-1', '--format=%H', '--', MANIFEST)
    ordinary_build = (allow_unfrozen and is_branch_build(repo)) or (allow_development and is_development(repo))
    if ordinary_build and not require_client and not release_tag and (not manifest_path.exists() or introduced != head):
        return {'schemaVersion': 1, 'batchId': '', 'mode': 'unreleased' if allow_unfrozen else 'development',
                'frozenSHA': head, 'buildRequired': True, 'tasks': []}
    if not manifest_path.is_file():
        raise ValueError('Production CI requires a frozen .release-batch.json')
    if git(repo, 'rev-parse', '--is-shallow-repository') != 'false':
        raise ValueError('Frozen batch verification requires full Git history (fetch-depth: 0)')
    if introduced != head:
        raise ValueError('HEAD must be the exact commit introducing the frozen manifest; historical batches cannot be reused')
    if git(repo, 'diff', 'HEAD', '--', MANIFEST):
        raise ValueError('Frozen manifest differs from checked-out HEAD')
    manifest = json.loads(manifest_path.read_text())
    if type(manifest.get('schemaVersion')) is not int or manifest['schemaVersion'] != 1:
        raise ValueError('Unsupported frozen manifest schemaVersion')
    for key in ('batchId', 'project', 'scope', 'target', 'environment'):
        nonempty(manifest.get(key), key)
    prepared = manifest.get('prepared')
    if not isinstance(prepared, dict):
        raise ValueError('Missing prepared batch context')
    fingerprint = prepared.get('inputFingerprint')
    if isinstance(fingerprint, dict) and fingerprint:
        for key, value in fingerprint.items():
            nonempty(key, 'prepared.inputFingerprint key')
            nonempty(value, f'prepared.inputFingerprint.{key}')
    else:
        nonempty(fingerprint, 'prepared.inputFingerprint')
    local = prepared.get('localValidation')
    if not isinstance(local, dict) or local.get('mode') not in ('client', 'tooling', 'backend'):
        raise ValueError('prepared.localValidation.mode must be client, tooling, or backend')
    mode = local['mode']
    if local.get('status') != 'passed':
        raise ValueError('Frozen local validation must have status passed')
    if require_client and mode != 'client':
        raise ValueError('Tagged IPA release requires a client batch')
    target = manifest['target']
    if manifest['environment'] != 'production':
        raise ValueError('Frozen release environment must be production')
    if target == BUNDLE_ID and mode in ('client', 'tooling'):
        if prepared.get('bundleIdentifier') != BUNDLE_ID:
            raise ValueError('Frozen iOS bundleIdentifier must be tech.zh0ngtian.MuseumMuse')
        check_versions(repo, prepared, release_tag)
    elif target == 'museummuse-api' and mode in ('backend', 'tooling'):
        nonempty(prepared.get('version'), 'prepared.version')
    else:
        raise ValueError('Frozen target does not match its client/backend validation mode')
    tasks = manifest.get('tasks')
    if not isinstance(tasks, list) or not tasks:
        raise ValueError('Frozen batch must contain tasks')
    task_ids = set()
    for task in tasks:
        if not isinstance(task, dict):
            raise ValueError('Invalid frozen task')
        task_id = nonempty(task.get('id'), 'task.id')
        if task_id in task_ids:
            raise ValueError('Duplicate frozen task id')
        task_ids.add(task_id)
        task_sha = task.get('sha', '')
        if not isinstance(task_sha, str) or not re.fullmatch(r'[0-9a-f]{40}', task_sha):
            raise ValueError('Task SHA must be a full Git SHA')
        git(repo, 'merge-base', '--is-ancestor', task_sha, head)
        validation = task.get('validation')
        checks = validation.get('checks') if isinstance(validation, dict) else None
        if not isinstance(checks, list) or not checks:
            raise ValueError('Each frozen task requires nonempty validation.checks')
        for check in checks:
            if not isinstance(check, dict) or check.get('status') != 'passed':
                raise ValueError('Every frozen task check must have status passed')
            nonempty(check.get('name'), 'task.validation.check.name')
    return {**manifest, 'mode': mode, 'frozenSHA': head, 'buildRequired': mode == 'client'}


def validate_build_source(repo, source, batch):
    """Reject stale products, including products from a different source tree."""
    require_clean_tree(repo)
    expected = {'sha': batch['frozenSHA'], 'batchId': batch['batchId'],
                'sourceTree': git(repo, 'rev-parse', 'HEAD^{tree}'), 'sourceClean': True,
                'version': batch['prepared']['version'], 'buildNumber': str(batch['prepared']['buildNumber'])}
    if not isinstance(source, dict) or any(source.get(key) != value for key, value in expected.items()):
        raise ValueError('Actual build source does not match frozen SHA, source tree, batch, or version')
    if type(source.get('sourceClean')) is not bool or type(source.get('authConfigured')) is not bool:
        raise ValueError('Actual build source must record authentication configuration')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sha')
    parser.add_argument('--require-client', action='store_true')
    parser.add_argument('--allow-development', action='store_true')
    parser.add_argument('--allow-unfrozen', action='store_true', help='Allow ordinary branch builds, including main, without a new release batch')
    parser.add_argument('--release-tag', default=os.environ.get('RELEASE_TAG'))
    parser.add_argument('--github-output', type=Path)
    args = parser.parse_args()
    try:
        batch = verify_batch(Path.cwd(), args.sha, require_client=args.require_client,
                             allow_development=args.allow_development, allow_unfrozen=args.allow_unfrozen,
                             release_tag=args.release_tag)
        if args.github_output:
            with args.github_output.open('a') as stream:
                stream.write(f'build_required={str(batch["buildRequired"]).lower()}\nbatch_id={batch["batchId"]}\nmode={batch["mode"]}\nfrozen_sha={batch["frozenSHA"]}\n')
        print(json.dumps(batch, ensure_ascii=False, sort_keys=True))
    except (ValueError, OSError, KeyError, TypeError) as error:
        print(f'Release batch verification failed: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
