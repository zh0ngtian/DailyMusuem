#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_root="${script_dir:h}"
runtime_dir="${HOME}/Library/Application Support/MuseumMuseNightlyInstaller"
venv_path="${runtime_dir}/venv"

mkdir -p "${runtime_dir}"
python3 -m venv "${venv_path}"
"${venv_path}/bin/python" -m pip install --upgrade pip
"${venv_path}/bin/python" -m pip install -r "${script_dir}/ios_nightly_installer_requirements.txt"
"${venv_path}/bin/python" "${script_dir}/ios_nightly_installer.py" \
  --install-launch-agent \
  --project-root "${project_root}"

echo "安装完成。状态栏中应出现 iPhone 图标。"
