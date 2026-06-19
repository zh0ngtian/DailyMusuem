import sqlite3
import tempfile
import unittest

from server.crawler.museums.japan_search import (
    JapanSearchCrawler,
    JapanSearchCrawlerPolicy,
    NARA_COLBASE_PROFILE,
    TOKYO_PROFILE,
    candidate_ids_from_search_payload,
    parse_search_payload,
    parse_item_payload,
    store_artwork,
)
from server.crawler.stores import initialize_database, seed_reference_metadata


TOKYO_ITEM_JSON = """
{
  "id": "jpsearch-20",
  "common": {
    "id": "jpsearch-20",
    "title": "太刀",
    "linkUrl": "https://colbase.nich.go.jp/collection_items/tnm/F-1",
    "thumbnailUrl": ["https://image.example/slideshow_s/thumb.jpg"],
    "contentsUrl": ["https://image.example/slideshow_s/main.jpg"],
    "contributor": ["Tokyo National Museum", "東京国立博物館", "刀工"],
    "temporal": ["鎌倉時代"],
    "description": "刀剣の説明",
    "provider": "tnm",
    "database": "cobas"
  },
  "cobas-22-s": "20",
  "cobas-16-s": "東京国立博物館",
  "cobas-11-s": "鎌倉時代",
  "cobas-12-s": "鉄",
  "cobas-13-s": "長さ70cm",
  "cobas-4-s": "刀剣"
}
"""


NARA_ITEM_JSON = """
{
  "id": "cobas-16086",
  "common": {
    "id": "cobas-16086",
    "title": "刺繍釈迦如来説法図",
    "linkUrl": "https://colbase.nich.go.jp/collection_items/narahaku/16086",
    "thumbnailUrl": ["https://image.example/slideshow_m/nara-thumb.jpg"],
    "contentsUrl": ["https://image.example/slideshow_l/nara-main.jpg"],
    "contributor": ["奈良国立博物館", "Nara National Museum"],
    "temporal": ["13～14世紀"],
    "provider": "narahaku",
    "database": "cobas"
  },
  "cobas-22-s": "16086",
  "cobas-16-s": "奈良国立博物館",
  "cobas-11-s": "13～14世紀",
  "cobas-12-s": "刺繍",
  "cobas-13-s": "縦127.0　横52.0",
  "cobas-4-s": "工芸"
}
"""


class JapanSearchCrawlerTests(unittest.TestCase):
    def test_parse_tokyo_item_matches_swift_contract(self) -> None:
        record = parse_item_payload(TOKYO_ITEM_JSON, profile=TOKYO_PROFILE)

        self.assertEqual(record.stable_id, "tnm-jpsearch-20")
        self.assertEqual(record.item_id, "jpsearch-20")
        self.assertEqual(record.title, "太刀")
        self.assertEqual(record.artist_display_name, "刀工")
        self.assertEqual(record.repository, "東京国立博物館")
        self.assertEqual(record.object_date, "鎌倉時代")
        self.assertEqual(record.medium, "鉄")
        self.assertEqual(record.dimensions, "長さ70cm")
        self.assertEqual(record.department, "刀剣")
        self.assertEqual(record.primary_image_url, "https://image.example/slideshow/main.jpg")
        self.assertEqual(record.primary_image_small_url, "https://image.example/slideshow_s/thumb.jpg")

    def test_search_payload_filters_sorts_and_deduplicates_fallback_results(self) -> None:
        payload = """
        {
          "hit": 4,
          "from": 0,
          "list": [
            {"id":"tokyo-20","common":{"id":"tokyo-20","title":"B","contributor":["東京国立博物館"],"provider":"tnm"},"cobas-22-s":"20"},
            {"id":"other-99","common":{"id":"other-99","title":"X","contributor":["Other"],"provider":"other"},"cobas-22-s":"99"},
            {"id":"tokyo-10","common":{"id":"tokyo-10","title":"A","contributor":["Other"],"provider":"tnm"},"cobas-22-s":"10"},
            {"id":"tokyo-20","common":{"id":"tokyo-20","title":"B","contributor":["東京国立博物館"],"provider":"tnm"},"cobas-22-s":"20"}
          ]
        }
        """

        ids = candidate_ids_from_search_payload(
            payload,
            profile=TOKYO_PROFILE,
            used_contributor_filter=False,
        )

        self.assertEqual(ids, ["tokyo-10", "tokyo-20"])

    def test_candidate_discovery_with_no_minimum_reads_until_last_page(self) -> None:
        class StubCrawler(JapanSearchCrawler):
            def __init__(self) -> None:
                super().__init__(profile=TOKYO_PROFILE, policy=JapanSearchCrawlerPolicy(page_size=2))
                self.pages: list[int] = []

            def fetch_search_page(
                self,
                *,
                from_index: int,
                category_type_code: str | None,
                used_contributor_filter: bool,
            ):
                self.pages.append(from_index)
                payload = (
                    """
                    {"hit":3,"from":0,"list":[
                      {"id":"tokyo-10","common":{"id":"tokyo-10","title":"A","contributor":["東京国立博物館"],"provider":"tnm"}},
                      {"id":"tokyo-20","common":{"id":"tokyo-20","title":"B","contributor":["東京国立博物館"],"provider":"tnm"}}
                    ]}
                    """
                    if from_index == 0
                    else """
                    {"hit":3,"from":2,"list":[
                      {"id":"tokyo-30","common":{"id":"tokyo-30","title":"C","contributor":["東京国立博物館"],"provider":"tnm"}}
                    ]}
                    """
                )
                return parse_search_payload(payload, profile=self.profile)

        crawler = StubCrawler()
        ids = crawler.fetch_candidate_ids(minimum_count=None)

        self.assertEqual(ids, ["tokyo-10", "tokyo-20", "tokyo-30"])
        self.assertEqual(crawler.pages, [0, 2])

    def test_store_nara_colbase_item_writes_images_and_category_membership(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            db_path = f"{directory}/museummuse.sqlite"
            initialize_database(db_path)
            seed_reference_metadata(db_path)
            record = parse_item_payload(NARA_ITEM_JSON, profile=NARA_COLBASE_PROFILE)

            with sqlite3.connect(db_path) as connection:
                connection.execute("PRAGMA foreign_keys = ON")
                artwork_pk = store_artwork(connection, record)
                connection.commit()

                row = connection.execute(
                    """
                    SELECT museum_id, source_key, stable_id, title, country, has_image
                    FROM artworks WHERE artwork_pk = ?
                    """,
                    (artwork_pk,),
                ).fetchone()
                self.assertEqual(row, ("nnm", "colbase", "nnm-cobas-16086", "刺繍釈迦如来説法図", "日本", 1))

                image_rows = connection.execute(
                    "SELECT role, url FROM artwork_images WHERE artwork_pk = ? ORDER BY sort_order",
                    (artwork_pk,),
                ).fetchall()
                self.assertEqual(
                    image_rows,
                    [
                        ("primary", "https://image.example/slideshow/nara-main.jpg"),
                        ("thumbnail", "https://image.example/slideshow_m/nara-thumb.jpg"),
                    ],
                )

                category_rows = connection.execute(
                    """
                    SELECT c.category_id
                    FROM artwork_categories ac
                    JOIN categories c ON c.category_pk = ac.category_pk
                    WHERE ac.artwork_pk = ?
                    """,
                    (artwork_pk,),
                ).fetchall()
                self.assertEqual(category_rows, [("craft",)])


if __name__ == "__main__":
    unittest.main()
