import importlib.util
from pathlib import Path
import plistlib
import stat
import tempfile
import unittest
import zipfile

spec = importlib.util.spec_from_file_location('widget_signer', Path(__file__).parents[1] / 'sign_ios_widget_ipa.py')
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)


class WidgetSigningTests(unittest.TestCase):
    def test_rejects_unsafe_archive_entries(self):
        for name, mode in [('../escape', 0), ('/absolute', 0), ('Payload/App.app/link', stat.S_IFLNK | 0o777)]:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as folder:
                root = Path(folder)
                with zipfile.ZipFile(root / 'bad.ipa', 'w') as archive:
                    item = zipfile.ZipInfo(name)
                    item.external_attr = mode << 16
                    archive.writestr(item, 'target')
                with self.assertRaises(ValueError):
                    signing.unpack(root / 'bad.ipa', root / 'out')

    def test_rejects_case_colliding_paths(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            with zipfile.ZipFile(root / 'bad.ipa', 'w') as archive:
                archive.writestr('Payload/App.app/File', 'a')
                archive.writestr('Payload/App.app/file', 'b')
            with self.assertRaises(ValueError):
                signing.unpack(root / 'bad.ipa', root / 'out')

    def test_requires_matching_extension_version_and_identity(self):
        with tempfile.TemporaryDirectory() as folder:
            app = Path(folder) / 'App.app'
            widget = app / 'PlugIns/Widget.appex'
            widget.mkdir(parents=True)
            info = {'CFBundleIdentifier': 'example.app', 'CFBundleVersion': '4', 'CFBundleShortVersionString': '1.0.3'}
            (app / 'Info.plist').write_bytes(plistlib.dumps(info))
            extension = dict(info, CFBundleIdentifier='example.app.widget', NSExtension={'NSExtensionPointIdentifier': 'com.apple.widgetkit-extension'})
            (widget / 'Info.plist').write_bytes(plistlib.dumps(extension))
            self.assertEqual(list(signing.targets(app)), ['example.app.widget', 'example.app'])
            for key, value in [('CFBundleVersion', '3'), ('CFBundleIdentifier', 'unrelated.widget')]:
                (widget / 'Info.plist').write_bytes(plistlib.dumps(dict(extension, **{key: value})))
                with self.assertRaises(ValueError):
                    signing.targets(app)

    def test_capability_policy_preserves_identity_and_delegates_authorization(self):
        baseline = {'entitlements': {'application-identifier': 'TEAM.installed', 'com.apple.developer.team-identifier': 'TEAM', 'keychain-access-groups': ['TEAM.*'], 'get-task-allow': False, 'unrelated': True}}
        class Signer:
            def _profile_identity(self, profile, bundle, udid, *, actual_entitlements):
                if actual_entitlements[signing.GROUP_KEY] != ['group.allowed']:
                    raise ValueError('Unauthorized group')
                return actual_entitlements
        planned = signing.planned_entitlements(Signer(), {}, 'example.app', 'device', baseline, 'group.allowed', {})
        self.assertEqual(planned['application-identifier'], 'TEAM.installed')
        self.assertEqual(planned['keychain-access-groups'], ['TEAM.*'])
        self.assertNotIn('unrelated', planned)
        with self.assertRaises(ValueError):
            signing.planned_entitlements(Signer(), {}, 'example.app', 'device', baseline, 'group.other', {})
        with self.assertRaises(ValueError):
            signing.planned_entitlements(Signer(), {}, 'example.app', 'device', baseline, 'group.allowed', {'application-identifier': 'TEAM.new'})

if __name__ == '__main__':
    unittest.main()
