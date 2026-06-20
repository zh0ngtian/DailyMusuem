import json
import tempfile
import unittest
from pathlib import Path

from server.api.db import MuseumDatabase
from server.crawler.stores import initialize_database, seed_reference_metadata


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

    def test_museum_metadata_includes_client_policies_and_sources(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            db_path = Path(directory) / "museummuse.sqlite"
            initialize_database(db_path)
            seed_reference_metadata(db_path)

            metadata = MuseumDatabase(db_path).museum_metadata()
            museums = {museum.museumID: museum for museum in metadata.museums}

            self.assertEqual(set(museums), {"nmc", "shm", "met", "tnm", "nnm", "guimet"})
            self.assertEqual(museums["nmc"].waterfallImageFetchPolicy.qps, 1.0)
            self.assertIsNone(museums["met"].waterfallImageFetchPolicy.qps)
            self.assertEqual(museums["nnm"].defaultSourceKey, "official")
            self.assertEqual([source.sourceKey for source in museums["nnm"].sources], ["official", "colbase"])
            self.assertEqual(museums["met"].defaultSourceKey, "met_all")
            self.assertEqual([source.sourceKey for source in museums["met"].sources], ["met_all", "met_on_view"])
            self.assertTrue(museums["met"].capabilities.supportsTranslation)
            self.assertEqual(museums["met"].icon.assetName, "MetHomepageLogo")
            self.assertEqual(museums["nmc"].textPunctuationStyle, "chinese")
            self.assertEqual(museums["met"].sources[0].translationSourceLanguage, "en")
            self.assertEqual(museums["tnm"].sources[0].preferredImageURLOrder, ["thumbnail", "primary"])
            self.assertEqual(museums["nnm"].sources[0].imageRequestHeaders["Referer"], "https://www.narahaku.go.jp/chinese/collection/")
            self.assertTrue(
                any(category.categoryID == "asian-art" for category in museums["met"].categories)
            )
            source_payload = museums["met"].sources[1].model_dump()
            category_payload = museums["met"].categories[0].model_dump()
            self.assertNotIn("artworkSourceKey", source_payload)
            self.assertNotIn("listFilter", source_payload)
            self.assertNotIn("kind", category_payload)
            self.assertNotIn("remoteValue", category_payload)


if __name__ == "__main__":
    unittest.main()
