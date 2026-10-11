#!/bin/bash
# Compile device/simulator targets and package an unsigned IPA.
set -euo pipefail

variant="${1:-standard}"
case "$variant" in
  standard)
    conditions=""
    compatibility=NO
    ;;
  compatibility)
    conditions=WIDGET_COMPATIBILITY
    compatibility=YES
    ;;
  *)
    echo "Usage: bash scripts/check_ios_build.sh [standard|compatibility]" >&2
    exit 2
    ;;
esac

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
output="$repo_root/build/ci/$variant"
mkdir -p "$output"
export MUSEUMMUSE_SIMPLE_AUTH_SECRET="${MUSEUMMUSE_SIMPLE_AUTH_SECRET:-ci-build-only-placeholder}"

# Keep embedded authentication out of both uploaded logs and console output.
redact_logs() {
  python3 -u -c 'import os, sys
secret = os.environ["MUSEUMMUSE_SIMPLE_AUTH_SECRET"]
for line in sys.stdin:
    sys.stdout.write(line.replace(secret, "[REDACTED]"))'
}

# A result bundle must not already exist. Preserve all other verification evidence.
rm -rf "$output/device.xcresult" "$output/simulator.xcresult"
xcodebuild -version | tee "$output/toolchain.log"
xcodebuild -showsdks | tee -a "$output/toolchain.log"

common=(
  -project DailyMuseum.xcodeproj
  CODE_SIGNING_ALLOWED=NO
  "MUSEUMMUSE_SIMPLE_AUTH_SECRET=$MUSEUMMUSE_SIMPLE_AUTH_SECRET"
  "MUSEUM_WIDGET_COMPATIBILITY_BUILD=$compatibility"
)

xcodebuild "${common[@]}" -scheme DailyMuseum \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath "$output/device-derived-data" \
  -resultBundlePath "$output/device.xcresult" \
  "SWIFT_ACTIVE_COMPILATION_CONDITIONS=$conditions" \
  build 2>&1 | redact_logs | tee "$output/device.log"

# Compile the existing tests; runtime/UI and desktop Widget verification remain local.
xcodebuild "${common[@]}" -scheme DailyMuseumTests \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$output/simulator-derived-data" \
  -resultBundlePath "$output/simulator.xcresult" \
  -parallel-testing-enabled NO \
  "SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG $conditions" \
  build-for-testing 2>&1 | redact_logs | tee "$output/simulator.log"

app="$output/device-derived-data/Build/Products/Release-iphoneos/DailyMuseum.app"
test -d "$app/PlugIns/DailyMuseumWidgetExtension.appex"
package_dir="$(mktemp -d "${TMPDIR:-/tmp}/museum-ipa.XXXXXX")"
trap 'rm -rf "$package_dir"' EXIT
mkdir "$package_dir/Payload"
ditto "$app" "$package_dir/Payload/DailyMuseum.app"
ipa="$output/MuseumMuse-$variant-unsigned.ipa"
rm -f "$ipa"
ditto -c -k --keepParent "$package_dir/Payload" "$ipa"
(cd "$output" && shasum -a 256 "$(basename "$ipa")" > "$(basename "$ipa").sha256")
echo "Unsigned IPA: $ipa"
