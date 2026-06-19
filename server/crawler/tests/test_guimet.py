import sqlite3
import tempfile
import unittest

from server.crawler.museums.guimet import (
    object_id_from_artwork_url,
    parse_collection_page,
    parse_detail_html,
    store_artwork,
)
from server.crawler.stores import initialize_database, seed_reference_metadata


COLLECTION_HTML = """
<div role="article" about="/zh-hans/nos-collections/afghanistan-pakistan/bodhisattva-maitreya" class="node--view-mode-teaser node--type-art-work">
  <div class="image-wrapper">
    <img src="https://www.guimet.fr/sites/default/files/styles/mosaic_list/public/2023-07/7-bodhisattva-maitreya_0.jpg?itok=crNarYT1" width="225" height="285" />
  </div>
  <div class="taxo-row">
    <span class="field field--name-field-ref-taxo-work-category field--type-entity-reference field--label-hidden field__items">雕塑</span>
  </div>
  <h2>弥勒菩萨摘要标题</h2>
  <a href="https://www.guimet.fr/zh-hans/nos-collections/afghanistan-pakistan/bodhisattva-maitreya" class="read-more-link">了解更多</a>
</div>
"""


DETAIL_HTML = """
<main role="main">
  <div class="artwork-header">
    <h1 class="artwork-title field field--name-field-title field--type-text-long field--label-hidden field__items">弥勒菩萨</h1>
    <div class="tag field field--name-field-text-period field--type-string field--label-hidden field__items">4-5世纪</div>
    <div class="main-artwork">
      <figure>
        <img loading="lazy" src="/sites/default/files/styles/width_1220px/public/2023-07/7-bodhisattva-maitreya_0.jpg?itok=usqaJKYE" />
        <figcaption class="field field--name-field-copyright field--type-text-long field--label-hidden field__items"><p>Photo (C) MNAAG</p></figcaption>
      </figure>
    </div>
  </div>
  <div class="field--name-field-teaser field field--type-text-long field--label-hidden field__items">
    <p>这件作品是安德烈·马尔罗收藏中的一件传奇之作。</p>
  </div>
  <div class="field--name-field_ref_widgets field field--name-field-ref-widgets field--type-entity-reference-revisions field--label-hidden field__items">
    <div class="paragraph paragraph--type--wysiwyg paragraph--view-mode--default">
      <p>亚洲宗教对时间的看法是循环往复的。</p>
      <p>这件作品可追溯到公元4至5世纪。</p>
    </div>
  </div>
  <div class="paragraph--type--accordion small-container">
    <div class="info-table">
      <div class="cell field field--name-field-object-type field--type-string field--label-above">
        <span class="label field__label">分类</span>
        <span class="value field__items">雕塑</span>
      </div>
      <div class="cell field field--name-field-materials field--type-string field--label-above">
        <span class="label field__label">材质</span>
        <span class="value field__items">灰泥</span>
      </div>
      <div class="cell field field--name-field-dimensions field--type-string field--label-above field__items">
        <span class="label field__label">尺寸</span>
        <span class="value field__item">55 x 34 x 19 cm</span>
      </div>
      <div class="cell field field--name-field-ref-taxo-region field--type-entity-reference field--label-above field__items">
        <span class="label field__label">地区或地点</span>
        <span class="value field__item">阿富汗/巴基斯坦</span>
      </div>
    </div>
  </div>
  <div class="block-wrapper view-display-id-other_artwork_detail">
    <h2>了解更多藏品</h2>
    <p>这里不应进入当前展品介绍。</p>
  </div>
</main>
"""


class GuimetCrawlerTests(unittest.TestCase):
    def test_collection_page_parser_reads_official_artwork_cards(self) -> None:
        summaries = parse_collection_page(COLLECTION_HTML)

        self.assertEqual(len(summaries), 1)
        self.assertEqual(summaries[0].object_id, "afghanistan-pakistan~bodhisattva-maitreya")
        self.assertEqual(summaries[0].title, "弥勒菩萨摘要标题")
        self.assertEqual(summaries[0].category, "雕塑")
        self.assertEqual(
            summaries[0].image_url,
            "https://www.guimet.fr/sites/default/files/styles/mosaic_list/public/2023-07/7-bodhisattva-maitreya_0.jpg?itok=crNarYT1",
        )

    def test_detail_parser_matches_swift_contract(self) -> None:
        detail_url = "https://www.guimet.fr/zh-hans/nos-collections/afghanistan-pakistan/bodhisattva-maitreya"
        record = parse_detail_html(DETAIL_HTML, detail_url=detail_url)

        self.assertEqual(object_id_from_artwork_url(detail_url), "afghanistan-pakistan~bodhisattva-maitreya")
        self.assertEqual(record.stable_id, "guimet-afghanistan-pakistan~bodhisattva-maitreya")
        self.assertEqual(record.title, "弥勒菩萨")
        self.assertEqual(record.object_date, "4-5世纪")
        self.assertEqual(record.department, "雕塑")
        self.assertEqual(record.medium, "灰泥")
        self.assertEqual(record.dimensions, "55 x 34 x 19 cm")
        self.assertEqual(record.culture, "阿富汗/巴基斯坦")
        self.assertEqual(
            record.primary_image_url,
            "https://www.guimet.fr/sites/default/files/styles/width_1220px/public/2023-07/7-bodhisattva-maitreya_0.jpg?itok=usqaJKYE",
        )
        self.assertEqual(
            record.artwork_description,
            "这件作品是安德烈·马尔罗收藏中的一件传奇之作。\n亚洲宗教对时间的看法是循环往复的。\n这件作品可追溯到公元4至5世纪。",
        )
        self.assertNotIn("了解更多藏品", record.artwork_description or "")

    def test_store_guimet_artwork_writes_images_and_collection_membership(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            db_path = f"{directory}/museummuse.sqlite"
            initialize_database(db_path)
            seed_reference_metadata(db_path)
            record = parse_detail_html(
                DETAIL_HTML,
                detail_url="https://www.guimet.fr/zh-hans/nos-collections/afghanistan-pakistan/bodhisattva-maitreya",
            )

            with sqlite3.connect(db_path) as connection:
                connection.execute("PRAGMA foreign_keys = ON")
                artwork_pk = store_artwork(connection, record, category_id="afghanistan-pakistan")
                connection.commit()

                row = connection.execute(
                    "SELECT museum_id, source_key, stable_id, title, has_image FROM artworks WHERE artwork_pk = ?",
                    (artwork_pk,),
                ).fetchone()
                self.assertEqual(
                    row,
                    (
                        "guimet",
                        "guimet_web",
                        "guimet-afghanistan-pakistan~bodhisattva-maitreya",
                        "弥勒菩萨",
                        1,
                    ),
                )

                image_rows = connection.execute(
                    "SELECT role, url FROM artwork_images WHERE artwork_pk = ? ORDER BY sort_order",
                    (artwork_pk,),
                ).fetchall()
                self.assertEqual(
                    image_rows,
                    [
                        (
                            "primary",
                            "https://www.guimet.fr/sites/default/files/styles/width_1220px/public/2023-07/7-bodhisattva-maitreya_0.jpg?itok=usqaJKYE",
                        ),
                        (
                            "thumbnail",
                            "https://www.guimet.fr/sites/default/files/styles/width_1220px/public/2023-07/7-bodhisattva-maitreya_0.jpg?itok=usqaJKYE",
                        ),
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
                self.assertEqual(category_rows, [("afghanistan-pakistan",)])


if __name__ == "__main__":
    unittest.main()
