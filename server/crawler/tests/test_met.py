import sqlite3
import tempfile
import unittest

from server.crawler.museums.met import (
    extract_web_description,
    object_ids_from_search_payload,
    parse_object_payload,
    store_artwork,
    web_description_candidate_urls,
)
from server.crawler.stores import initialize_database, seed_reference_metadata


MET_OBJECT_JSON = """
{
  "objectID": 1001,
  "title": "Bodhisattva",
  "artistDisplayName": "Unknown artist",
  "objectDate": "7th century",
  "medium": "Gilt bronze",
  "dimensions": "H. 20 cm",
  "department": "Asian Art",
  "culture": "China",
  "country": "China",
  "repository": "Metropolitan Museum of Art, New York, NY",
  "primaryImage": "https://images.metmuseum.org/large.jpg",
  "primaryImageSmall": "https://images.metmuseum.org/small.jpg",
  "objectURL": "https://www.metmuseum.org/art/collection/search/1001",
  "isOnView": true
}
"""

MET_OVERVIEW_HTML = """
<html>
<body>
<main>
  <h1>Sample Object</h1>
  <div class="object-overview-module-scss-module__x8Q2kL__label">
    <p>First line &amp; detail</p>
    <p>Second line</p>
    <p>Third line</p>
  </div>
  <section>
    <h2>Provenance</h2>
    <p>This section should not be used.</p>
  </section>
</main>
</body>
</html>
"""


class MetCrawlerTests(unittest.TestCase):
    def test_parse_object_payload_matches_swift_contract(self) -> None:
        record = parse_object_payload(MET_OBJECT_JSON)

        self.assertEqual(record.stable_id, "met-1001")
        self.assertEqual(record.object_id, 1001)
        self.assertEqual(record.title, "Bodhisattva")
        self.assertEqual(record.artist_display_name, "Unknown artist")
        self.assertEqual(record.department, "Asian Art")
        self.assertEqual(record.is_on_view, True)
        self.assertEqual(record.primary_image_url, "https://images.metmuseum.org/large.jpg")
        self.assertEqual(record.primary_image_small_url, "https://images.metmuseum.org/small.jpg")

    def test_parse_object_payload_derives_on_view_from_gallery_number(self) -> None:
        payload = MET_OBJECT_JSON.replace('"isOnView": true', '"GalleryNumber": "602"')

        record = parse_object_payload(payload)

        self.assertEqual(record.is_on_view, True)

    def test_search_payload_deduplicates_object_ids(self) -> None:
        payload = b'{"total":3,"objectIDs":[1001,1001,1002]}'

        self.assertEqual(object_ids_from_search_payload(payload), [1001, 1002])

    def test_web_description_prefers_overview_and_skips_other_sections(self) -> None:
        self.assertEqual(
            extract_web_description(MET_OVERVIEW_HTML),
            "First line & detail\nSecond line\nThird line",
        )
        self.assertNotIn("Provenance", extract_web_description(MET_OVERVIEW_HTML) or "")

    def test_web_description_uses_lead_before_artwork_details(self) -> None:
        expected = (
            "Scenes of courtly pleasure, garden settings, and longlegged female figures dressed in "
            "high-waisted, flowing angarkhas typify paintings attributed to Farrukhabad."
        )
        html = f"""
        <html><body><main>
          <h1>Princesses Gather at a Fountain</h1>
          <div>ca. 1770</div>
          <section class="collection-object-lead">
            <p>{expected}</p>
          </section>
          <a href="/art/collection/search/454054">Image: Princesses Gather at a Fountain</a>
          <h2>Artwork Details</h2>
        </main></body></html>
        """

        self.assertEqual(extract_web_description(html), expected)

    def test_web_description_falls_back_to_meta_description(self) -> None:
        html = """
        <html><head><meta property="og:description" content="Meta description fallback &amp; details."></head>
        <body><main><h2>Catalogue Entry</h2><p>Not overview.</p></main></body></html>
        """

        self.assertEqual(extract_web_description(html), "Meta description fallback & details.")

    def test_web_description_candidate_urls_try_chinese_before_english(self) -> None:
        self.assertEqual(
            web_description_candidate_urls("https://www.metmuseum.org/art/collection/search/1001"),
            [
                "https://www.metmuseum.org/zh/art/collection/search/1001",
                "https://www.metmuseum.org/art/collection/search/1001",
            ],
        )

    def test_store_artwork_writes_images_and_department_membership(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            db_path = f"{directory}/museummuse.sqlite"
            initialize_database(db_path)
            seed_reference_metadata(db_path)
            record = parse_object_payload(MET_OBJECT_JSON).with_description("Overview text")

            with sqlite3.connect(db_path) as connection:
                connection.execute("PRAGMA foreign_keys = ON")
                artwork_pk = store_artwork(connection, record)
                connection.commit()

                row = connection.execute(
                    "SELECT source_key, stable_id, title, artwork_description_text, is_on_view, has_image FROM artworks WHERE artwork_pk = ?",
                    (artwork_pk,),
                ).fetchone()
                self.assertEqual(row, ("met_all", "met-1001", "Bodhisattva", "Overview text", 1, 1))

                image_rows = connection.execute(
                    "SELECT role, url FROM artwork_images WHERE artwork_pk = ? ORDER BY sort_order",
                    (artwork_pk,),
                ).fetchall()
                self.assertEqual(
                    image_rows,
                    [
                        ("primary", "https://images.metmuseum.org/large.jpg"),
                        ("thumbnail", "https://images.metmuseum.org/small.jpg"),
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
                self.assertEqual(category_rows, [("asian-art",)])


if __name__ == "__main__":
    unittest.main()
