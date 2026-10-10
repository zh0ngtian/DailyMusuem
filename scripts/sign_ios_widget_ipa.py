#!/usr/bin/env python3
"""Sign this app + Widget using ios-adhoc-ota crypto and explicit target profiles.

Compatibility mode pins an independently verified installed archive. The
explicit, profile-authorized App Group may change. An explicit per-target
project capability map may replace unrelated old entitlements; installation
identity and keychain groups always remain exact. Never edits an Apple profile.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import shutil
import stat
import tempfile
import zipfile

GROUP_KEY = 'com.apple.security.application-groups'


def load_signer(skill_dir):
    spec = importlib.util.spec_from_file_location('ota_sign', Path(skill_dir) / 'scripts/ios_sign.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def digest(path):
    hasher = hashlib.sha256()
    with Path(path).open('rb') as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b''):
            hasher.update(chunk)
    return hasher.hexdigest()


def unpack(path, root):
    """Extract regular files only, preserving signed executable modes."""
    root = Path(root)
    root.mkdir(parents=True)
    with zipfile.ZipFile(path) as archive:
        seen = set()
        for item in archive.infolist():
            name = item.filename.rstrip('/')
            parts = PurePosixPath(name).parts
            mode = item.external_attr >> 16
            if (not name or name.startswith('/') or '\\' in name
                    or any(p in ('', '.', '..') for p in name.split('/'))
                    or name.casefold() in seen
                    or stat.S_IFMT(mode) not in (0, stat.S_IFDIR, stat.S_IFREG)):
                raise ValueError('Unsafe, duplicate, or unsupported IPA path')
            seen.add(name.casefold())
            target = root.joinpath(*parts)
            if item.is_dir():
                target.mkdir(parents=True, exist_ok=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                with archive.open(item) as source, target.open('xb') as output:
                    shutil.copyfileobj(source, output)
                target.chmod((mode & 0o777) or 0o644)
    apps = list(root.rglob('*.app'))
    if len(apps) != 1 or apps[0].parent != root / 'Payload':
        raise ValueError('Expected exactly one containing app')
    return apps[0]


def targets(app):
    if any(p.is_symlink() for p in app.rglob('*')):
        raise ValueError('Symlinks are unsupported')
    extensions = list(app.rglob('*.appex'))
    if len(extensions) != 1 or extensions[0].parent != app / 'PlugIns':
        raise ValueError('Expected exactly one direct Widget extension')
    if list(app.rglob('*.app')) or list(app.rglob('*.xpc')):
        raise ValueError('Other nested apps/XPC are unsupported')
    result = {}
    app_info = plistlib.loads((app / 'Info.plist').read_bytes())
    for target in [extensions[0], app]:
        info = plistlib.loads((target / 'Info.plist').read_bytes())
        bundle = info['CFBundleIdentifier']
        if target != app:
            if (not bundle.startswith(app_info['CFBundleIdentifier'] + '.')
                    or info.get('NSExtension', {}).get('NSExtensionPointIdentifier') != 'com.apple.widgetkit-extension'
                    or any(info.get(k) != app_info.get(k) for k in ('CFBundleVersion', 'CFBundleShortVersionString'))):
                raise ValueError('Invalid containing app / Widget relationship')
        if bundle in result:
            raise ValueError('Duplicate bundle identifier')
        result[bundle] = target
    return result


def inspect(signer, ipa, udid, *, group=None):
    with tempfile.TemporaryDirectory(prefix='museum-verify-') as work:
        root = Path(work)
        app = unpack(ipa, root / 'unpacked')
        results = {}
        for bundle, target in targets(app).items():
            detail = signer.verify_app(target, root, details=True)
            profile = signer.read_profile(target / 'embedded.mobileprovision')
            signer._profile_identity(profile, bundle, udid, actual_entitlements=detail['entitlements'])
            if group is not None:
                info = plistlib.loads((target / 'Info.plist').read_bytes())
                if (info.get('MuseumAppGroupIdentifier') != group
                        or detail['entitlements'].get(GROUP_KEY) != [group]):
                    raise ValueError('Runtime group and signed group differ')
            detail['widgetCompatibilityMode'] = plistlib.loads((target / 'Info.plist').read_bytes()).get('MuseumWidgetCompatibilityMode', False)
            detail.pop('certificate')
            results[bundle] = detail
        if len({d['metadata']['teamId'] for d in results.values()}) != 1:
            raise ValueError('App and Widget teams differ')
        main = results[signer.read_bundle_id(app)]['metadata'].copy()
        main['profileExpiresAt'] = min(d['metadata']['profileExpiresAt'] for d in results.values())
        return {'metadata': main, 'targets': results, 'sha256': digest(ipa)}


def planned_entitlements(signer, profile, bundle, udid, baseline, group, required=None):
    actual = dict(baseline['entitlements'])
    if required is not None:
        # Explicit project capability policy, not a blanket copy of unrelated
        # capabilities a third-party signer injected into the old app.
        actual = {k: actual[k] for k in ('application-identifier',
                  'com.apple.developer.team-identifier', 'keychain-access-groups', 'get-task-allow')}
        for key, value in required.items():
            if key in actual and actual[key] != value:
                raise ValueError('Project capabilities cannot change installed identity')
            actual[key] = value
    actual[GROUP_KEY] = [group]
    return signer._profile_identity(profile, bundle, udid, actual_entitlements=actual)


def validate_release(signer, ipa, config):
    """Validate every final target against this project's fixed installed base."""
    with tempfile.TemporaryDirectory(prefix='museum-baseline-') as work:
        baseline = Path(work) / 'baseline.ipa'
        shutil.copyfile(Path(config['compatibilityIpa']).expanduser(), baseline)
        if digest(baseline) != config['compatibilityIpaSha256']:
            raise ValueError('Pinned baseline SHA-256 mismatch')
        previous = inspect(signer, baseline, config['udid'])
    current = inspect(signer, ipa, config['udid'], group=config['appGroup'])
    if set(previous['targets']) != set(current['targets']) or set(current['targets']) != set(config['profiles']):
        raise ValueError('Final target set differs from installed baseline / profile map')
    required = config.get('projectEntitlements')
    if required is not None and set(required) != set(current['targets']):
        raise ValueError('Explicit project capabilities required for every target')
    for bid, detail in current['targets'].items():
        if detail['widgetCompatibilityMode'] is not bool(config.get('widgetCompatibilityMode', False)):
            raise ValueError('Widget compatibility mode differs from release configuration')
        profile = signer.read_profile(Path(config['profiles'][bid]).expanduser())
        expected = planned_entitlements(signer, profile, bid, config['udid'], previous['targets'][bid], config['appGroup'],
                    None if required is None else plistlib.loads(Path(required[bid]).read_bytes()))
        signer.validate_signed_entitlements(detail['entitlements'], expected)
        if (detail['metadata']['version'] != config['version']
                or detail['metadata']['buildNumber'] != config['buildNumber']):
            raise ValueError('Final version/build differs from release configuration')
    return current


def sign(config, source, output, signer):
    output = Path(output)
    sidecar = Path(str(output) + '.signing.json')
    if output.exists() or sidecar.exists():
        raise ValueError('Output already exists; choose a new build')
    shared = json.loads(Path(config['sharedSigningConfig']).expanduser().read_text())
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.museum-sign-', dir=output.parent) as work:
        root = Path(work)
        baseline = root / 'baseline.ipa'
        shutil.copyfile(Path(config['compatibilityIpa']).expanduser(), baseline)
        if digest(baseline) != config['compatibilityIpaSha256']:
            raise ValueError('Pinned baseline SHA-256 mismatch')
        previous = inspect(signer, baseline, config['udid'])
        payload = root / 'package/Payload'
        payload.mkdir(parents=True)
        app = payload / Path(source).name
        # Validate before copytree to avoid following arbitrary symlinks.
        targets(Path(source))
        shutil.copytree(source, app)
        components = targets(app)
        if set(components) != set(previous['targets']) or set(components) != set(config['profiles']):
            raise ValueError('Input, baseline and explicit profile mapping targets differ')
        group = config['appGroup']
        profiles = {bid: signer.read_profile(Path(path).expanduser()) for bid, path in config['profiles'].items()}
        required = config.get('projectEntitlements')
        if required is not None and set(required) != set(components):
            raise ValueError('Explicit project capabilities required for every target')
        expected = {bid: planned_entitlements(signer, profiles[bid], bid, config['udid'], previous['targets'][bid], group,
                    None if required is None else plistlib.loads(Path(required[bid]).read_bytes())) for bid in components}
        password = signer.read_password(shared.get('passwordFile'), shared.get('passwordKeychainService'))
        with signer.temporary_keychain(root) as (keychain, keychain_password):
            identity = signer.import_identity(Path(shared['p12']).expanduser(), password, keychain, keychain_password, profiles[next(iter(components))], root)
            for profile in profiles.values():
                if identity not in {hashlib.sha1(c).hexdigest().upper() for c in profile['DeveloperCertificates']}:
                    raise ValueError('P12 leaf is not authorized for every target')
            for index, (bid, target) in enumerate(components.items()):
                info_file = target / 'Info.plist'
                info = plistlib.loads(info_file.read_bytes())
                if (info.get('MuseumWidgetCompatibilityBuild') == 'YES') != bool(config.get('widgetCompatibilityMode', False)):
                    raise ValueError('Build mode differs from requested Widget compatibility mode')
                info.update(MuseumAppGroupIdentifier=group, CFBundleVersion=config['buildNumber'], CFBundleShortVersionString=config['version'])
                info['MuseumWidgetCompatibilityMode'] = bool(config.get('widgetCompatibilityMode', False))
                info['IOSOTATeamID'] = expected[bid]['teamId']
                info['IOSOTAApplicationIdentifier'] = expected[bid]['applicationIdentifier']
                info_file.write_bytes(plistlib.dumps(info))
                shutil.copyfile(Path(config['profiles'][bid]).expanduser(), target / 'embedded.mobileprovision')
                ent = root / f'entitlements-{index}.plist'
                ent.write_bytes(plistlib.dumps(expected[bid]['entitlements']))
                # Sign only this target's frameworks; the containing app must not
                # re-sign or alter the already sealed extension.
                frameworks = target / 'Frameworks'
                if frameworks.exists():
                    nested = [p for p in frameworks.rglob('*') if p.suffix in ('.framework', '.dylib')]
                    for component in sorted(nested, key=lambda p: len(p.parts), reverse=True):
                        signer.run(['codesign', '--force', '--sign', identity, '--keychain', keychain, '--timestamp=none', component])
                signer.run(['codesign', '--force', '--sign', identity, '--keychain', keychain, '--entitlements', ent, '--generate-entitlement-der', '--timestamp=none', target])
            candidate = root / 'candidate.ipa'
            signer.pack_ipa(root / 'package', candidate)
            verified = inspect(signer, candidate, config['udid'], group=group)
            for bid, detail in verified['targets'].items():
                signer.validate_signed_entitlements(detail['entitlements'], expected[bid])
            verified['metadata']['appName'] = 'MuseumMuse'
            proof = root / 'signing.json'
            proof.write_text(json.dumps(verified, indent=2, ensure_ascii=False) + '\n')
            os.replace(candidate, output)
            try:
                os.replace(proof, sidecar)
            except BaseException:
                output.unlink(missing_ok=True)
                raise
        return verified


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--skill-dir', default=str(Path.home() / '.codex/skills/ios-adhoc-ota'))
    parser.add_argument('--config', required=True)
    parser.add_argument('--app')
    parser.add_argument('--output')
    parser.add_argument('--verify-ipa')
    args = parser.parse_args()
    signer = load_signer(args.skill_dir)
    config = json.loads(Path(args.config).expanduser().read_text())
    try:
        if args.verify_ipa:
            result = validate_release(signer, args.verify_ipa, config)
        else:
            if not args.app or not args.output:
                parser.error('--app and --output are required for signing')
            result = sign(config, args.app, args.output, signer)
        print(json.dumps({'metadata': result['metadata'], 'sha256': result['sha256'], 'verifiedTargets': list(result['targets'])}, ensure_ascii=False, indent=2))
    except (signer.SigningError, ValueError) as error:
        parser.exit(1, str(error) + '\n')


if __name__ == '__main__':
    main()
