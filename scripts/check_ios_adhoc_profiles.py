#!/usr/bin/env python3
"""Read-only profile preflight for MuseumMuse's app and Widget targets.

Uses ios-adhoc-ota's Apple CMS verifier; does not sign, publish, install,
import a private key, or certify upgrade compatibility with an installed IPA.
"""
import argparse
import importlib.util
import json
from pathlib import Path
import plistlib
import re
import subprocess


GROUPS = "com.apple.security.application-groups"
PRODUCT_TYPES = {"com.apple.product-type.application", "com.apple.product-type.app-extension"}


def project_targets(root):
    result = subprocess.run(
        ["plutil", "-convert", "json", "-o", "-", str(root / "DailyMuseum.xcodeproj/project.pbxproj")],
        check=True, capture_output=True, timeout=30,
    )
    objects = json.loads(result.stdout)["objects"]
    targets = []
    for target in objects.values():
        if target.get("isa") != "PBXNativeTarget" or target.get("productType") not in PRODUCT_TYPES:
            continue
        configs = objects[target["buildConfigurationList"]]["buildConfigurations"]
        releases = [objects[key]["buildSettings"] for key in configs if objects[key]["name"] == "Release"]
        if len(releases) != 1:
            raise ValueError("目标缺少唯一 Release 配置")
        settings = releases[0]
        bundle_id = settings["PRODUCT_BUNDLE_IDENTIFIER"]
        entitlements_path = settings["CODE_SIGN_ENTITLEMENTS"]
        if "$" in bundle_id or "$" in entitlements_path:
            raise ValueError("目标身份含未展开变量；请先适配实际 build settings 解析")
        entitlements = plistlib.loads((root / entitlements_path).read_bytes())
        targets.append({"target": target["name"], "bundleId": bundle_id, "entitlements": entitlements})
    if len(targets) != 2 or len({t["bundleId"] for t in targets}) != 2:
        raise ValueError("预检仅支持当前主 App + Widget 两个独立目标")
    runtime = (root / "Shared/Settings/SettingsKeys.swift").read_text()
    match = re.search(r'static let defaultAppGroupID = "([^"]+)"', runtime)
    if not match or any(t["entitlements"].get(GROUPS) != [match[1]] for t in targets):
        raise ValueError("主 App、Widget entitlements 与 SettingsKeys.appGroupID 不一致")
    return sorted(targets, key=lambda t: t["target"])


def capability_errors(target, profile, signing):
    errors = []
    allowed = profile.get("Entitlements", {})
    for key, actual in target["entitlements"].items():
        if key not in allowed or not signing.entitlement_authorized(allowed[key], actual):
            errors.append(f"未授权必要权限 {key}: {actual}")
    return errors


def check_targets(targets, profiles, udid, signing):
    reports = []
    valid = []
    for target in targets:
        report = {"target": target["target"], "bundleId": target["bundleId"], "errors": []}
        profile = profiles.get(target["target"])
        if profile is None:
            report["errors"].append("缺少该目标独立的 Ad Hoc 描述文件")
        else:
            report["profileApplicationIdentifier"] = profile.get("Entitlements", {}).get("application-identifier")
            report["authorizedAppGroups"] = profile.get("Entitlements", {}).get(GROUPS, [])
            try:
                identity = signing.validate_profile(profile, target["bundleId"], udid)
                valid.append((profile, identity))
            except signing.SigningError as error:
                report["errors"].append(str(error))
            report["errors"].extend(capability_errors(target, profile, signing))
        reports.append(report)
    errors = []
    if len(valid) == len(targets):
        if len({identity["teamId"] for _, identity in valid}) != 1:
            errors.append("主 App 与 Widget 的 Team 不一致")
        if len({profile.get("UUID") for profile, _ in valid}) != len(targets):
            errors.append("主 App 与 Widget 不得共用同一描述文件")
        certs = [set(profile["DeveloperCertificates"]) for profile, _ in valid]
        if not set.intersection(*certs):
            errors.append("主 App 与 Widget 没有共同获授权的签名证书")
    return {
        "profilePreflightPassed": not errors and all(not r["errors"] for r in reports),
        "targets": reports,
        "errors": errors,
        "notVerified": ["P12 私钥与证书匹配", "已安装 IPA 的逐目标升级身份", "最终 IPA 验签", "OTA 发布与真机安装"],
    }


def load_signing(skill_dir):
    path = skill_dir / "scripts/ios_sign.py"
    spec = importlib.util.spec_from_file_location("museum_ota_signing", path)
    if spec is None or spec.loader is None:
        raise ValueError("无法加载 ios-adhoc-ota 验签工具")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project-root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--skill-dir", type=Path, default=Path.home() / ".codex/skills/ios-adhoc-ota")
    parser.add_argument("--signing-config", type=Path, default=Path.home() / "Library/Application Support/IOSAdHocOTA/signing.local.json")
    parser.add_argument("--app-profile", type=Path)
    parser.add_argument("--widget-profile", type=Path)
    parser.add_argument("--udid", required=True)
    args = parser.parse_args()
    try:
        signing = load_signing(args.skill_dir.expanduser())
        targets = project_targets(args.project_root.resolve())
        app_profile = args.app_profile
        if app_profile is None:
            config_path = args.signing_config.expanduser().resolve()
            config = json.loads(config_path.read_text())
            path = Path(config["profile"]).expanduser()
            app_profile = path if path.is_absolute() else config_path.parent / path
        paths = {"DailyMuseum": app_profile, "DailyMuseumWidgetExtension": args.widget_profile}
        if {t["target"] for t in targets} != set(paths):
            raise ValueError("项目目标已改变，请更新逐目标 profile 映射")
        profiles = {name: signing.read_profile(path.expanduser()) for name, path in paths.items() if path is not None}
        report = check_targets(targets, profiles, args.udid, signing)
        print(json.dumps(report, ensure_ascii=False, indent=2))
        return 0 if report["profilePreflightPassed"] else 1
    except Exception as error:
        # Do not expose subprocess output or credential content.
        print(json.dumps({"profilePreflightPassed": False, "errorType": type(error).__name__,
                          "error": "无法完成预检；请检查 skill、项目、配置及 Apple CMS/profile 信任链"}, ensure_ascii=False))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
