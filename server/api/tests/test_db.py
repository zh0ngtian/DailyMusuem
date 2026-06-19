import json
import tempfile
import unittest
from pathlib import Path

from server.api.db import MuseumDatabase


class MuseumDatabaseTests(unittest.TestCase):
    def test_non_default_database_prefers_stem_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            db_path = Path(directory) / "museummuse-live-full.sqlite"
            db_path.write_bytes(b"")
            (Path(directory) / "manifest.json").write_text(
                json.dumps({"build_id": "default-version"}),
                encoding="utf-8",
            )
            (Path(directory) / "museummuse-live-full.manifest.json").write_text(
                json.dumps({"build_id": "live-version"}),
                encoding="utf-8",
            )

            database = MuseumDatabase(db_path)

            self.assertEqual(database.data_version(), "live-version")


if __name__ == "__main__":
    unittest.main()
