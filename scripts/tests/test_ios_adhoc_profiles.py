import copy
import datetime as dt
import importlib.util
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("profile_preflight", ROOT / "scripts/check_ios_adhoc_profiles.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
SKILL = Path.home() / ".codex/skills/ios-adhoc-ota"


@unittest.skipUnless((SKILL / "scripts/ios_sign.py").is_file(), "需要安装 ios-adhoc-ota skill")
class ProfilePreflightTests(unittest.TestCase):
    def setUp(self):
        self.signing = MODULE.load_signing(SKILL)
        self.targets = [
            {"target": "App", "bundleId": "example.museum", "entitlements": {MODULE.GROUPS: ["group.example.museum"]}},
            {"target": "Widget", "bundleId": "example.museum.widget", "entitlements": {MODULE.GROUPS: ["group.example.museum"]}},
        ]
        self.profiles = {}
        for target in self.targets:
            self.profiles[target["target"]] = {
                "UUID": target["target"], "TeamIdentifier": ["TEAM"],
                "ApplicationIdentifierPrefix": ["PREFIX"],
                "DeveloperCertificates": [b"synthetic-certificate"],
                "ProvisionedDevices": ["test-device"],
                "ExpirationDate": dt.datetime.now(dt.timezone.utc) + dt.timedelta(days=1),
                "Entitlements": {
                    "application-identifier": "PREFIX." + target["bundleId"],
                    "com.apple.developer.team-identifier": "TEAM",
                    "keychain-access-groups": ["PREFIX.*"],
                    "get-task-allow": False,
                    MODULE.GROUPS: ["group.example.museum"],
                },
            }

    def check(self, udid="test-device"):
        return MODULE.check_targets(self.targets, self.profiles, udid, self.signing)

    def test_matching_targets_accept_distinct_team_and_app_prefix(self):
        self.assertTrue(self.check()["profilePreflightPassed"])

    def test_default_unrelated_profile_and_missing_widget_fail(self):
        self.profiles["App"]["Entitlements"]["application-identifier"] = "PREFIX.example.other"
        self.profiles["App"]["Entitlements"][MODULE.GROUPS] = ["group.example.other"]
        del self.profiles["Widget"]
        result = self.check()
        self.assertFalse(result["profilePreflightPassed"])
        self.assertEqual(len(result["targets"][0]["errors"]), 2)
        self.assertIn("缺少", result["targets"][1]["errors"][0])

    def test_widget_without_required_app_group_fails(self):
        del self.profiles["Widget"]["Entitlements"][MODULE.GROUPS]
        self.assertFalse(self.check()["profilePreflightPassed"])

    def test_unknown_device_and_expired_profile_fail(self):
        self.assertFalse(self.check("unregistered-device")["profilePreflightPassed"])
        self.profiles["App"]["ExpirationDate"] = dt.datetime(2000, 1, 1)
        self.assertFalse(self.check()["profilePreflightPassed"])

    def test_development_profile_cannot_be_used_as_adhoc(self):
        self.profiles["Widget"]["Entitlements"]["get-task-allow"] = True
        self.assertFalse(self.check()["profilePreflightPassed"])

    def test_same_wildcard_profile_for_both_targets_is_rejected(self):
        self.profiles["App"]["Entitlements"]["application-identifier"] = "PREFIX.example.*"
        self.profiles["Widget"] = copy.deepcopy(self.profiles["App"])
        self.assertIn("主 App 与 Widget 不得共用同一描述文件", self.check()["errors"])

    def test_profiles_without_common_signing_certificate_fail(self):
        self.profiles["Widget"]["DeveloperCertificates"] = [b"different-certificate"]
        self.assertFalse(self.check()["profilePreflightPassed"])


if __name__ == "__main__":
    unittest.main()
