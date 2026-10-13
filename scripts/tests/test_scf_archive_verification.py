"""SCF download may change ZIP container bytes; every executable/input remains exact."""
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import stat
import tempfile
import unittest
import zipfile

MODULE = Path(__file__).resolve().parents[1] / 'museum_scf_release_adapter.py'
spec = importlib.util.spec_from_file_location('scf_archive_adapter', MODULE)
adapter_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(adapter_module)


def archive_bytes(files, compression=zipfile.ZIP_STORED, reverse=False, modes=None):
    stream = io.BytesIO()
    with zipfile.ZipFile(stream, 'w', compression=compression) as archive:
        for name, value in sorted(files.items(), reverse=reverse):
            item = zipfile.ZipInfo(name, (2026, 10, 13, 1, 0, 0))
            item.compress_type = compression
            item.external_attr = (stat.S_IFREG | (modes or {}).get(name, 0o644)) << 16
            archive.writestr(item, value)
    return stream.getvalue()


class SCFArchiveTests(unittest.TestCase):
    def test_repacked_container_preserves_exact_files_and_permissions(self):
        files = {'server/api/routes.py': b'route = 1\n', 'scf_bootstrap': b'#!/bin/sh\n', 'data/museummuse.sqlite': b'database'}
        original = archive_bytes(files, modes={'scf_bootstrap': 0o755})
        repacked = archive_bytes(files, zipfile.ZIP_DEFLATED, reverse=True, modes={'scf_bootstrap': 0o755})
        self.assertNotEqual(hashlib.sha256(original).hexdigest(), hashlib.sha256(repacked).hexdigest())
        self.assertEqual(adapter_module.archive_contents(original), adapter_module.archive_contents(repacked))

    def test_added_missing_or_changed_code_is_rejected_by_content_identity(self):
        original = adapter_module.archive_contents(archive_bytes({'code.py': b'original', 'data.sqlite': b'input'}))
        for files in ({'code.py': b'changed', 'data.sqlite': b'input'}, {'code.py': b'original'},
                      {'code.py': b'original', 'data.sqlite': b'input', 'extra.py': b'unknown'}):
            with self.subTest(files=files):
                self.assertNotEqual(original, adapter_module.archive_contents(archive_bytes(files)))

    def test_executable_permission_changes_are_not_container_only(self):
        original = archive_bytes({'scf_bootstrap': b'bootstrap'}, modes={'scf_bootstrap': 0o755})
        changed = archive_bytes({'scf_bootstrap': b'bootstrap'}, modes={'scf_bootstrap': 0o644})
        self.assertNotEqual(adapter_module.archive_contents(original), adapter_module.archive_contents(changed))

    def test_unsafe_duplicate_and_symlink_entries_fail_closed(self):
        for name in ('../code.py', '/code.py', 'code\\file.py'):
            with self.subTest(name=name), self.assertRaises(RuntimeError):
                adapter_module.archive_contents(archive_bytes({name: b'unsafe'}))
        for duplicate, symlink in ((True, False), (False, True)):
            stream = io.BytesIO()
            with zipfile.ZipFile(stream, 'w') as archive:
                item = zipfile.ZipInfo('code.py')
                item.external_attr = (stat.S_IFLNK if symlink else stat.S_IFREG | 0o644) << 16
                archive.writestr(item, b'code')
                if duplicate:
                    archive.writestr('code.py', b'other')
            with self.assertRaises(RuntimeError):
                adapter_module.archive_contents(stream.getvalue())

    def test_deploy_check_accepts_repacking_but_rejects_content_change(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            workspace = root / 'workspace';workspace.mkdir()
            context_path = root / 'contexts/batch.json';context_path.parent.mkdir()
            context = {'id': 'batch-1', 'workspace': str(workspace), 'config': {'options': {}},
                       'frozen': {'sha': 'a' * 40}, 'tasks': []}
            adapter = adapter_module.SCFAdapter(context, context_path=context_path)
            sqlite, manifest = b'immutable-sqlite', b'{"build_id":"existing"}'
            inputs = {'sqliteSha256': hashlib.sha256(sqlite).hexdigest(), 'manifestSha256': hashlib.sha256(manifest).hexdigest()}
            marker = dict(inputs, batchId='batch-1', sourceCommit='a' * 40, dataVersion='existing')
            files = {'data/museummuse.sqlite': sqlite, 'data/manifest.json': manifest,
                     'data/release-marker.json': json.dumps(marker).encode(), 'server/api/routes.py': b'known-code'}
            original, remote = archive_bytes(files), archive_bytes(files, zipfile.ZIP_DEFLATED, reverse=True)
            path = root / 'package.zip';path.write_bytes(original)
            adapter.save({'prepare': {'dataVersion': 'existing', 'inputFingerprint': inputs},
                          'package': {'path': str(path), 'sha256': hashlib.sha256(original).hexdigest()}})
            remote_proof = {'status': 'Active', 'marker': marker, 'zipSha256': hashlib.sha256(remote).hexdigest(),
                            **adapter_module.archive_contents(remote)}
            adapter.remote_deployment = lambda: remote_proof
            adapter.health = lambda: {'dataVersion': 'existing', 'releaseMarker': marker}
            checked = adapter.deploy_check()
            self.assertTrue(checked['done'])
            self.assertEqual(checked['result']['uploadedZipSha256'], hashlib.sha256(original).hexdigest())
            self.assertEqual(checked['result']['deployedZipSha256'], hashlib.sha256(remote).hexdigest())
            bad = archive_bytes({**files, 'server/api/routes.py': b'foreign-code'})
            remote_proof.update(adapter_module.archive_contents(bad))
            with self.assertRaisesRegex(RuntimeError, 'content|contents'):
                adapter.deploy_check()
