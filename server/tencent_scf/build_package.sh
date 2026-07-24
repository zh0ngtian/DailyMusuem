#!/bin/bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
    echo "Usage: $0 <sqlite-path> <manifest-path> <output-zip>" >&2
    exit 2
fi

repository_root="$(cd "$(dirname "$0")/../.." && pwd)"
sqlite_path="$1"
manifest_path="$2"
output_directory="$(cd "$(dirname "$3")" && pwd)"
output_zip="$output_directory/$(basename "$3")"
package_root="$(mktemp -d "${TMPDIR:-/tmp}/museummuse-scf-package.XXXXXX")"
trap 'rm -rf "$package_root"' EXIT

if [[ ! -f "$sqlite_path" || ! -f "$manifest_path" ]]; then
    echo "SQLite database and manifest must both exist." >&2
    exit 2
fi

mkdir -p "$package_root/server/api" "$package_root/data"

python3 -m pip install \
    --platform manylinux2014_x86_64 \
    --implementation cp \
    --python-version 3.10 \
    --abi cp310 \
    --only-binary=:all: \
    --target "$package_root" \
    "fastapi>=0.111,<1" \
    "uvicorn>=0.30,<1" \
    "pydantic>=2,<3" \
    "exceptiongroup>=1.0.2,<2"

python3 -m pip install \
    --platform manylinux2014_x86_64 \
    --implementation cp \
    --python-version 3.10 \
    --abi cp310 \
    --only-binary=:all: \
    --no-deps \
    --target "$package_root" \
    "cos-python-sdk-v5>=1.9.44,<2" \
    "requests>=2.8,<3" \
    "certifi>=2023.5.7" \
    "charset-normalizer>=2,<4" \
    "idna>=2.5,<4" \
    "urllib3>=1.26,<3" \
    "six>=1.16,<2" \
    "xmltodict>=0.13,<2"

python3 -m pip install --target "$package_root" "crcmod==1.7"
find "$package_root/crcmod" -name '_crcfunext*.so' -delete

cp -R "$repository_root/server/api/." "$package_root/server/api/"
cp "$repository_root/server/tencent_scf/scf_bootstrap" "$package_root/scf_bootstrap"
cp "$sqlite_path" "$package_root/data/museummuse.sqlite"
cp "$manifest_path" "$package_root/data/manifest.json"
chmod +x "$package_root/scf_bootstrap"

find "$package_root" -type d -name '__pycache__' -prune -exec rm -rf {} +
find "$package_root" -type f -name '*.pyc' -delete
rm -f "$output_zip"
(
    cd "$package_root"
    zip -q -r "$output_zip" .
)

echo "$output_zip"
