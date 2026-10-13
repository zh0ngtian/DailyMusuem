#!/bin/bash
# Package and validate an already-built device Release; never invoke xcodebuild.
set -euo pipefail
if [[ $# -ne 0 ]]; then
  echo "Usage: RELEASE_TAG=vX.Y.Z bash scripts/package_ios_release.sh" >&2
  exit 2
fi
: "${RELEASE_TAG:?Set RELEASE_TAG to vX.Y.Z}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
output="$repo_root/build/ci"
app="$output/device-derived-data/Build/Products/Release-iphoneos/DailyMuseum.app"

# Validate the tag and both targets before creating any release attachment.
python3 - "$app" <<'PY'
import json, os, pathlib, plistlib, re, sys
from scripts.verify_release_batch import validate_build_source, verify_batch
repo = pathlib.Path.cwd()
app = pathlib.Path(sys.argv[1])
batch = verify_batch(repo, require_client=True, release_tag=os.environ['RELEASE_TAG'])
source = json.loads((repo / 'build/ci/build-source.json').read_text())
validate_build_source(repo, source, batch)
run_id = os.environ.get('GITHUB_RUN_ID')
if not run_id or source.get('runId') != run_id:
    sys.exit('Actual build source does not belong to this GitHub run')
if 'AUTH_CONFIGURED' in os.environ and (os.environ['AUTH_CONFIGURED'] == 'true') != source['authConfigured']:
    sys.exit('Authentication context differs from actual build source')
tag = os.environ['RELEASE_TAG']
if not re.fullmatch(r'v\d+\.\d+\.\d+', tag):
    sys.exit('Release tag must be vX.Y.Z')
with (app / 'Info.plist').open('rb') as f:
    info = plistlib.load(f)
if info.get('CFBundleShortVersionString') != tag[1:]:
    sys.exit('Release tag does not match App version')
if str(info.get('CFBundleVersion')) != str(batch['prepared']['buildNumber']):
    sys.exit('App build number does not match frozen batch')
if info.get('CFBundleIdentifier') != batch['prepared']['bundleIdentifier']:
    sys.exit('Built App bundle identifier does not match frozen batch')
if not re.fullmatch(r'[1-9]\d*', str(info.get('CFBundleVersion', ''))):
    sys.exit('App build number must be a positive integer')
extensions = sorted((app / 'PlugIns').glob('*.appex'))
if [p.name for p in extensions] != ['DailyMuseumWidgetExtension.appex']:
    sys.exit('Expected the MuseumMuse Widget extension')
for target in [app, *extensions]:
    with (target / 'Info.plist').open('rb') as f:
        target_info = plistlib.load(f)
    if any(target_info.get(k) != info[k] for k in ('CFBundleVersion', 'CFBundleShortVersionString')):
        sys.exit('App and Widget versions must match')
    expected_bundle = 'tech.zh0ngtian.MuseumMuse' + ('.widget' if target != app else '')
    if target_info.get('CFBundleIdentifier') != expected_bundle:
        sys.exit('Built target bundle identifier does not match frozen production target')
    secret = target_info.get('MuseumBackendSimpleAuthSecret', '')
    configured = bool(secret) and secret != 'ci-build-only-placeholder' and not secret.startswith('$(')
    if configured != source['authConfigured']:
        sys.exit('Built target authentication does not match recorded build source')
    if target_info.get('MuseumWidgetCompatibilityBuild') != 'YES':
        sys.exit('Expected the 10-group compatibility build')
    executable = target_info.get('CFBundleExecutable', '')
    if not executable or not (target / executable).is_file():
        sys.exit('Missing target executable')
PY

package_dir="$(mktemp -d "${TMPDIR:-/tmp}/museum-ipa.XXXXXX")"
trap 'rm -rf "$package_dir"' EXIT
mkdir "$package_dir/Payload"
ditto "$app" "$package_dir/Payload/DailyMuseum.app"
ipa="$output/MuseumMuse-unsigned.ipa"
rm -f "$ipa"
ditto -c -k --keepParent "$package_dir/Payload" "$ipa"

python3 - "$ipa" <<'PY'
import hashlib, json, os, pathlib, plistlib, sys, zipfile
from scripts.verify_release_batch import validate_build_source, verify_batch
repo = pathlib.Path.cwd()
batch = verify_batch(repo, require_client=True, release_tag=os.environ['RELEASE_TAG'])
source = json.loads((repo / 'build/ci/build-source.json').read_text())
validate_build_source(repo, source, batch)
ipa = pathlib.Path(sys.argv[1])
with zipfile.ZipFile(ipa) as archive:
    if archive.testzip() is not None:
        sys.exit('IPA archive integrity check failed')
    root = 'Payload/DailyMuseum.app/'
    app = plistlib.loads(archive.read(root + 'Info.plist'))
    widget = plistlib.loads(archive.read(root + 'PlugIns/DailyMuseumWidgetExtension.appex/Info.plist'))
    for info in [app, widget]:
        if info['CFBundleShortVersionString'] != os.environ['RELEASE_TAG'][1:] or info['CFBundleVersion'] != app['CFBundleVersion']:
            sys.exit('Packaged target versions do not match')
checksum = hashlib.sha256(ipa.read_bytes()).hexdigest()
ipa.with_suffix('.ipa.sha256').write_text(f'{checksum}  {ipa.name}\n')
metadata = dict(tag=os.environ['RELEASE_TAG'], commit=batch['frozenSHA'],
                batchId=batch['batchId'], tasks=batch['tasks'], runId=os.environ['GITHUB_RUN_ID'],
                version=app['CFBundleShortVersionString'], build=app['CFBundleVersion'],
                signed=False, widgetGroups=10, authConfigured=source['authConfigured'],
                bytes=ipa.stat().st_size, sha256=checksum,
                bundleIDs=[app['CFBundleIdentifier'], widget['CFBundleIdentifier']])
ipa.with_suffix('.json').write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + '\n')
print(f'Validated unsigned IPA: {ipa.name} ({metadata["version"]}, build {metadata["build"]})')
PY
