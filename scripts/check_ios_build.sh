#!/bin/bash
# Compile the App and embedded Widget once for an unsigned device Release.
set -euo pipefail

if [[ $# -ne 0 ]]; then
  echo "Usage: bash scripts/check_ios_build.sh" >&2
  exit 2
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
output="${MUSEUMMUSE_BUILD_OUTPUT:-$repo_root/build/ci}"
if [[ "$output" != /* ]]; then
  echo "MUSEUMMUSE_BUILD_OUTPUT must be an absolute path" >&2
  exit 2
fi
mkdir -p "$output"
export MUSEUMMUSE_SIMPLE_AUTH_SECRET="${MUSEUMMUSE_SIMPLE_AUTH_SECRET:-ci-build-only-placeholder}"
# Remove stale success evidence before any check or compiler invocation.
rm -f "$output/build-source.json"
python3 - "$output/build-input.json" <<'PYTHON'
import json, os, pathlib, sys
from scripts.verify_release_batch import git, require_clean_tree, verify_batch
repo = pathlib.Path.cwd()
batch = verify_batch(repo, require_client=os.environ.get('REQUIRE_RELEASE_BATCH_CLIENT') == 'true',
                     allow_development=os.environ.get('REQUIRE_RELEASE_BATCH_CLIENT') != 'true')
if not batch['buildRequired']:
    sys.exit('This frozen batch does not require an App build')
require_clean_tree(repo)
import plistlib
with (repo / 'DailyMuseum/Info.plist').open('rb') as stream:
    info = plistlib.load(stream)
source = dict(sha=batch['frozenSHA'], batchId=batch['batchId'],
              sourceTree=git(repo, 'rev-parse', 'HEAD^{tree}'), sourceClean=True,
              version=info['CFBundleShortVersionString'], buildNumber=str(info['CFBundleVersion']),
              authConfigured=os.environ['MUSEUMMUSE_SIMPLE_AUTH_SECRET'] != 'ci-build-only-placeholder',
              runId=os.environ.get('GITHUB_RUN_ID', ''))
pathlib.Path(sys.argv[1]).write_text(json.dumps(source, sort_keys=True) + '\n')
PYTHON


# Keep embedded authentication out of both uploaded logs and console output.
redact_logs() {
  python3 -u -c 'import os, sys
secret = os.environ["MUSEUMMUSE_SIMPLE_AUTH_SECRET"]
for line in sys.stdin:
    sys.stdout.write(line.replace(secret, "[REDACTED]"))'
}

xcodebuild -version 2>&1 | tee "$output/toolchain.log"
xcodebuild -showsdks 2>&1 | tee -a "$output/toolchain.log"
xcrun --sdk iphoneos --show-sdk-version 2>&1 | tee -a "$output/toolchain.log"

xcodebuild -project DailyMuseum.xcodeproj -scheme DailyMuseum \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath "$output/device-derived-data" \
  CODE_SIGNING_ALLOWED=NO \
  "MUSEUMMUSE_SIMPLE_AUTH_SECRET=$MUSEUMMUSE_SIMPLE_AUTH_SECRET" \
  build 2>&1 | redact_logs | tee "$output/device.log"

# Only a successful compiler run with an unchanged clean tree can attest products.
python3 - "$output/build-input.json" "$output/build-source.json" <<'PYTHON'
import json, pathlib, sys
from scripts.verify_release_batch import git, require_clean_tree
repo = pathlib.Path.cwd()
source = json.loads(pathlib.Path(sys.argv[1]).read_text())
require_clean_tree(repo)
if source['sha'] != git(repo, 'rev-parse', 'HEAD') or source['sourceTree'] != git(repo, 'rev-parse', 'HEAD^{tree}'):
    sys.exit('Source changed during the App build; refusing to attest products')
pathlib.Path(sys.argv[2]).write_text(json.dumps(source, sort_keys=True) + '\n')
PYTHON
