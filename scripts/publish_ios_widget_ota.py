#!/usr/bin/env python3
"""Independently verify the complex IPA and publish it to LAN OTA."""
import argparse
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
from sign_ios_widget_ipa import validate_release, load_signer


def load_ota(skill):
    spec = importlib.util.spec_from_file_location('ios_ota', skill / 'scripts/ios_ota.py')
    ota = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(ota)
    return ota


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', required=True)
    parser.add_argument('--ipa', required=True)
    parser.add_argument('--notes', required=True)
    parser.add_argument('--plan', action='store_true', help='Local validation only; does not publish')
    args = parser.parse_args()
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
        if args.plan:
            print(json.dumps({'plan': True, 'metadata': metadata, 'sha256': proof['sha256'],
                              'baseUrl': config['baseUrl']}, indent=2, ensure_ascii=False))
            return
        source = Path(work) / 'release'
        with (Path(args.config).expanduser().parent / '.museum-release.lock').open('a') as lock:
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
