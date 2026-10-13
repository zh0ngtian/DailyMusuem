#!/usr/bin/env python3
"""Publish one immutable unsigned IPA set; preserve every existing release asset."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from urllib.parse import quote

ASSETS = ('MuseumMuse-unsigned.ipa', 'MuseumMuse-unsigned.ipa.sha256', 'MuseumMuse-unsigned.json')


class Github:
    def __init__(self, repository):
        self.repository = repository

    def run(self, *args):
        result = subprocess.run(['gh', *args], text=True, capture_output=True,
                                env={**os.environ, 'GH_REPO': self.repository})
        if result.returncode:
            raise ValueError(f'GitHub operation failed: {result.stderr.strip()}')
        return result.stdout

    def resolve_tag(self, tag):
        ref = json.loads(self.run('api', f'repos/{self.repository}/git/ref/tags/{quote(tag, safe="")}'))['object']
        for _ in range(8):
            if ref['type'] == 'commit':
                return ref['sha']
            if ref['type'] != 'tag':
                break
            ref = json.loads(self.run('api', f'repos/{self.repository}/git/tags/{ref["sha"]}'))['object']
        raise ValueError('Release tag must resolve to a commit')

    def release_assets(self, tag):
        result = subprocess.run(['gh', 'api', f'repos/{self.repository}/releases/tags/{quote(tag, safe="")}'],
                                text=True, capture_output=True)
        if result.returncode:
            if '(HTTP 404)' in result.stderr:
                return None
            raise ValueError(f'Cannot inspect existing GitHub Release: {result.stderr.strip()}')
        release = json.loads(result.stdout)
        if release['tag_name'] != tag:
            raise ValueError('GitHub returned a different release tag')
        return [asset['name'] for asset in release['assets']]

    def create(self, tag, sha, notes):
        with tempfile.TemporaryDirectory(prefix='museum-release-notes-') as directory:
            path = Path(directory) / 'notes.md'
            path.write_text(notes)
            self.run('release', 'create', tag, '--verify-tag', '--target', sha,
                     '--title', f'MuseumMuse {tag}', '--notes-file', str(path))

    def download(self, tag, names, destination):
        args = ['release', 'download', tag, '--dir', str(destination)]
        for name in names:
            args.extend(['--pattern', name])
        self.run(*args)

    def upload(self, tag, paths):
        self.run('release', 'upload', tag, *(str(path) for path in paths))


def validate_package(packages, tag, batch, run_id):
    metadata = json.loads((packages / ASSETS[2]).read_text())
    required = {'tag', 'commit', 'version', 'build', 'signed', 'widgetGroups', 'authConfigured',
                'bytes', 'sha256', 'bundleIDs', 'batchId', 'tasks', 'runId'}
    if not required.issubset(metadata):
        raise ValueError('Unsigned IPA metadata is incomplete')
    expected = dict(tag=tag, commit=batch['frozenSHA'], version=batch['prepared']['version'],
                    build=str(batch['prepared']['buildNumber']), batchId=batch['batchId'], tasks=batch['tasks'],
                    runId=str(run_id), signed=False, widgetGroups=10,
                    bundleIDs=['tech.zh0ngtian.MuseumMuse', 'tech.zh0ngtian.MuseumMuse.widget'])
    if not run_id or not re.fullmatch(r'v\d+\.\d+\.\d+', tag) or tag != 'v' + expected['version']:
        raise ValueError('Release tag/runId does not match frozen package context')
    if any(metadata.get(key) != value for key, value in expected.items()) or type(metadata['authConfigured']) is not bool:
        raise ValueError('IPA metadata does not match frozen batch, tasks, version, or runId')
    ipa = packages / ASSETS[0]
    digest = hashlib.sha256(ipa.read_bytes()).hexdigest()
    checksum = f'{digest}  {ASSETS[0]}\n'
    if metadata['sha256'] != digest or metadata['bytes'] != ipa.stat().st_size or (packages / ASSETS[1]).read_text() != checksum:
        raise ValueError('Unsigned IPA checksum/size does not match metadata')
    return metadata


def publish_release(packages, tag, batch, run_url, run_id, github):
    packages = Path(packages)
    metadata = validate_package(packages, tag, batch, run_id)
    sha = batch['frozenSHA']
    if github.resolve_tag(tag) != sha:
        raise ValueError('Remote tag does not resolve to the frozen commit')
    existing = github.release_assets(tag)
    if existing is None:
        notes = (f'未签名 iOS Release 产物，安装前需要自行签名。\n\n'
                 f'仅提供 10 组静态小组件版本，各组在 App 中独立选馆与刷新。\n\n'
                 f'Batch: `{batch["batchId"]}`\n\nCommit: `{sha}`\n\n[构建记录]({run_url})\n')
        if not metadata['authConfigured']:
            notes += '\n当前未配置后端鉴权 Secret，IPA 使用 CI 占位鉴权值，无法连接正式后端。\n'
        github.create(tag, sha, notes)
        existing = []
    present = [name for name in ASSETS if name in existing]
    if present:
        with tempfile.TemporaryDirectory(prefix='museum-existing-release-') as directory:
            fresh = Path(directory)
            github.download(tag, present, fresh)
            for name in present:
                old, new = fresh / name, packages / name
                if name.endswith('.json'):
                    if json.loads(old.read_text()) != metadata:
                        raise ValueError('Existing release metadata differs; preserving all existing assets')
                elif hashlib.sha256(old.read_bytes()).digest() != hashlib.sha256(new.read_bytes()).digest():
                    raise ValueError(f'Existing release asset {name} differs; preserving all existing assets')
    missing = [packages / name for name in ASSETS if name not in existing]
    if missing:
        github.upload(tag, missing)
        # Verify remotely stored bytes after a first or partial upload.
        with tempfile.TemporaryDirectory(prefix='museum-published-release-') as directory:
            fresh = Path(directory)
            github.download(tag, ASSETS, fresh)
            validate_package(fresh, tag, batch, run_id)
            if json.loads((fresh / ASSETS[2]).read_text()) != metadata:
                raise ValueError('Published release metadata differs from validated package')
    return {'batchId': batch['batchId'], 'sha': sha, 'tag': tag, 'uploaded': [path.name for path in missing]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--packages', type=Path, default=Path('packages'))
    parser.add_argument('--tag', default=os.environ.get('RELEASE_TAG'))
    parser.add_argument('--sha', default=os.environ.get('BUILD_SHA') or os.environ.get('GITHUB_SHA'))
    parser.add_argument('--repo', default=os.environ.get('GH_REPO') or os.environ.get('GITHUB_REPOSITORY'))
    parser.add_argument('--run-id', default=os.environ.get('GITHUB_RUN_ID'))
    parser.add_argument('--run-url', default=os.environ.get('RUN_URL', ''))
    args = parser.parse_args()
    try:
        from verify_release_batch import verify_batch
        if not args.repo or not args.tag or not args.run_id:
            raise ValueError('Repository, release tag, and GitHub run ID are required')
        batch = verify_batch(Path.cwd(), args.sha, require_client=True, release_tag=args.tag)
        result = publish_release(args.packages, args.tag, batch, args.run_url, args.run_id, Github(args.repo))
        print(json.dumps(result, sort_keys=True))
    except (ValueError, OSError, KeyError, TypeError) as error:
        print(f'Immutable GitHub Release publication failed: {error}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
