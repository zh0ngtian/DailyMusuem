#!/usr/bin/env python3
"""Independently verify the complex IPA and publish it to LAN OTA."""
import argparse
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import sys
import tempfile
import uuid
import zipfile
from sign_ios_widget_ipa import validate_release, load_signer, unpack, targets


def load_ota(skill):
    spec = importlib.util.spec_from_file_location('ios_ota', skill / 'scripts/ios_ota.py')
    ota = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(ota)
    return ota


def validate_provenance_context(sha, batch):
    if not isinstance(sha, str) or not re.fullmatch(r'[0-9a-f]{40}', sha):
        raise ValueError('source-commit must be the full frozen 40-character Git SHA')
    if not isinstance(batch, str):
        raise ValueError('batch-id must be a canonical UUID')
    try:
        identifier = uuid.UUID(batch)
    except (ValueError, AttributeError) as error:
        raise ValueError('batch-id must be a canonical UUID') from error
    if str(identifier) != batch or not identifier.int:
        raise ValueError('batch-id must be a canonical nonzero UUID')


def release_provenance(ipa, sha, batch):
    """Read batch provenance from both actual targets in the final signed IPA."""
    validate_provenance_context(sha, batch)
    try:
        with tempfile.TemporaryDirectory(prefix='museum-release-source-') as directory:
            app = unpack(Path(ipa), Path(directory) / 'unpacked')
            components = targets(app)
            if set(components) != {'tech.zh0ngtian.MuseumMuse', 'tech.zh0ngtian.MuseumMuse.widget'}:
                raise ValueError('Release provenance requires the containing MuseumMuse App and its Widget target')
            actual = None
            for target in components.values():
                info = plistlib.loads((target / 'Info.plist').read_bytes())
                provenance = {'sourceCommit': info.get('MuseumReleaseSourceCommit'),
                              'batchId': info.get('MuseumReleaseBatchID')}
                if provenance != {'sourceCommit': sha, 'batchId': batch}:
                    raise ValueError('Final App and Widget release provenance must both match the frozen source and batch')
                actual = provenance
            return actual
    except (OSError, plistlib.InvalidFileException, zipfile.BadZipFile) as error:
        raise ValueError(f'Cannot read final IPA release provenance: {error}') from error


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', required=True)
    parser.add_argument('--ipa', required=True)
    parser.add_argument('--notes', required=True)
    parser.add_argument('--source-commit', help='Full frozen source commit SHA; required for publication')
    parser.add_argument('--batch-id', help='Frozen coordinator batch UUID; required for publication')
    parser.add_argument('--plan', action='store_true', help='Local validation only; does not publish')
    args = parser.parse_args()
    if args.source_commit is not None or args.batch_id is not None or not args.plan:
        try:
            validate_provenance_context(args.source_commit, args.batch_id)
        except ValueError as error:
            parser.error(str(error))
    config = json.loads(Path(args.config).expanduser().read_text())
    skill = Path(config['skillDir']).expanduser()
    signer = load_signer(skill)
    ota = load_ota(skill)
    if config.get('caFile'):
        # Add the LAN CA without replacing the system trust store.
        os.environ['IOS_ADHOC_OTA_CA_FILE'] = config['caFile']
    root = Path(config['localRoot']).expanduser()
    with tempfile.TemporaryDirectory(prefix='museum-publish-') as work:
        snapshot = Path(work) / 'verified.ipa'
        shutil.copyfile(args.ipa, snapshot)
        proof = validate_release(signer, snapshot, config)
        metadata = proof['metadata'] | {'appName': 'MuseumMuse'}
        if args.source_commit is not None:
            metadata |= release_provenance(snapshot, args.source_commit, args.batch_id)
        if args.plan:
            print(json.dumps({'plan': True, 'metadata': metadata, 'sha256': proof['sha256'],
                              'baseUrl': config['baseUrl']}, indent=2, ensure_ascii=False))
            return
        source = Path(work) / 'release'
        lock_directory = Path(config.get('coordinationLockDirectory', Path(args.config).expanduser().parent)).expanduser()
        with (lock_directory / '.museum-release.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            previous = ota.read_release(root / 'current/latest-ios.json')
            release = ota.create_release(snapshot, metadata, source, config['baseUrl'], args.notes, previous)
            ota.stage_local(source, root)
            ota.verify_published(release, fixed=False)
            ota.activate_staged(source, root)
            ota.verify_published(release)
            receipt = root / 'releases' / release['version'] / 'latest-ios.json'
            print('OTA verified. Receipt: ' + str(receipt), file=sys.stderr, flush=True)
    print(json.dumps(release, indent=2, ensure_ascii=False))


if __name__ == '__main__':
    main()
