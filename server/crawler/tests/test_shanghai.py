import sqlite3
import tempfile
import unittest

from server.crawler.museums.shanghai import (
    ShanghaiCrawler,
    ShanghaiCrawlerPolicy,
    parse_article_html,
    parse_image_html,
    parse_search_payload,
    store_artwork,
)
from server.crawler.stores import initialize_database, seed_reference_metadata


SEARCH_JSON = """
{
  "code": 0,
  "count": 2,
  "msg": "ok",
  "data": [
    {
      "code": "A-100",
      "name": "青铜鼎",
      "description": "搜索摘要",
      "age": {"entryItemName": "商"},
      "antiqueType1": {"entryItemName": "青铜器"},
      "antiqueType2": {"entryItemName": "礼器"},
      "catalog": "<tr><td>纪年</td><td>商后期</td></tr><tr><td>材质</td><td>青铜</td></tr><tr><td>尺寸</td><td>高10厘米</td></tr><tr><td>产地</td><td>中国</td></tr>",
      "picPath": "/mu/images/large.jpg",
      "picPath2": "/mu/images/mid.jpg",
      "thumbnailPath": "/mu/images/small.jpg"
    },
    {
      "code": "A-100",
      "name": "青铜鼎重复"
    }
  ]
}
"""


ARTICLE_HTML = """
<div class="title">青铜鼎</div>
<ul>
  <li><div class="left">时代：</div><ul class="site-list right"><li>商</li></ul></li>
  <li><div class="left">详细年代：</div><ul class="site-list right"><li>商后期</li></ul></li>
  <li><div class="left">类别：</div><ul class="site-list right"><li>青铜器</li><li>礼器</li></ul></li>
  <li><div class="left">材质：</div><ul class="site-list right"><li>青铜</li></ul></li>
  <li><div class="left">尺寸：</div><ul class="site-list right"><li>高10厘米</li></ul></li>
  <li><div class="left">作者：</div><ul class="site-list right"><li>佚名</li></ul></li>
  <li><div class="left">产地：</div><ul class="site-list right"><li>中国</li></ul></li>
</ul>
<div class="subtitle">简介</div>
<p>这是文字详情。</p>
"""


IMAGE_HTML = """
<figure data-src="/mu/images/large.jpg"></figure>
<img src="/mu/images/small.jpg" />
"""


class ShanghaiCrawlerTests(unittest.TestCase):
    def test_search_payload_deduplicates_and_maps_summary_fields(self) -> None:
        codes, records, total_count = parse_search_payload(SEARCH_JSON)

        self.assertEqual(codes, ["A-100"])
        self.assertEqual(total_count, 2)
        self.assertEqual(records[0].stable_id, "shm-A-100")
        self.assertEqual(records[0].title, "青铜鼎")
        self.assertEqual(records[0].artwork_description, "搜索摘要")
        self.assertEqual(records[0].object_date, "商 · 商后期")
        self.assertEqual(records[0].medium, "青铜")
        self.assertEqual(records[0].dimensions, "高10厘米")
        self.assertEqual(records[0].department, "青铜器 / 礼器")
        self.assertEqual(records[0].culture, "中国")
        self.assertEqual(records[0].primary_image_url, "https://www.shanghaimuseum.net/mu/images/large.jpg")
        self.assertEqual(records[0].primary_image_small_url, "https://www.shanghaimuseum.net/mu/images/small.jpg")

    def test_candidate_discovery_with_no_minimum_reads_until_last_page(self) -> None:
        class StubCrawler(ShanghaiCrawler):
            def __init__(self) -> None:
                super().__init__(policy=ShanghaiCrawlerPolicy(page_size=2))
                self.pages: list[int] = []

            def fetch_search_page(self, *, page: int, subtype: str | None) -> bytes:
                self.pages.append(page)
                payload = (
                    """
                    {"code":0,"count":3,"data":[
                      {"code":"A-100","name":"A"},
                      {"code":"A-200","name":"B"}
                    ]}
                    """
                    if page == 1
                    else """
                    {"code":0,"count":3,"data":[
                      {"code":"A-300","name":"C"}
                    ]}
                    """
                )
                return payload.encode("utf-8")

        crawler = StubCrawler()
        codes = crawler.fetch_candidate_codes(minimum_count=None)

        self.assertEqual(codes, ["A-100", "A-200", "A-300"])
        self.assertEqual(crawler.pages, [1, 2])

    def test_article_and_image_parsers_match_swift_contract(self) -> None:
        record = parse_article_html(ARTICLE_HTML, object_code="A-100")
        image_urls = parse_image_html(IMAGE_HTML)
        record = record.with_images(image_urls)

        self.assertEqual(record.title, "青铜鼎")
        self.assertEqual(record.object_date, "商 · 商后期")
        self.assertEqual(record.department, "青铜器 / 礼器")
        self.assertEqual(record.medium, "青铜")
        self.assertEqual(record.dimensions, "高10厘米")
        self.assertEqual(record.artist_display_name, "佚名")
        self.assertEqual(record.culture, "中国")
        self.assertEqual(record.artwork_description, "<p>这是文字详情。</p>")
        self.assertEqual(record.primary_image_url, "https://www.shanghaimuseum.net/mu/images/large.jpg")
        self.assertEqual(record.primary_image_small_url, "https://www.shanghaimuseum.net/mu/images/small.jpg")

    def test_article_title_allows_leading_image_and_action_link(self) -> None:
        article_html = """
        <div class="site-article">
          <div class="title">
            <img class="jwz" src="/mu/upload/title.png">母癸甗
            <a href="javascript:void(0);" class="site-link add-to-my-art-trigger">添加到我的私家艺术史</a>
          </div>
        </div>
        """

        record = parse_article_html(article_html, object_code="CI00000578")

        self.assertEqual(record.title, "母癸甗")

    def test_store_text_only_when_image_page_is_missing(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            db_path = f"{directory}/museummuse.sqlite"
            initialize_database(db_path)
            seed_reference_metadata(db_path)
            record = parse_article_html(ARTICLE_HTML, object_code="A-100")

            with sqlite3.connect(db_path) as connection:
                connection.execute("PRAGMA foreign_keys = ON")
                artwork_pk = store_artwork(connection, record, category_id="礼器")
                connection.commit()

                row = connection.execute(
                    "SELECT museum_id, source_key, stable_id, title, has_image FROM artworks WHERE artwork_pk = ?",
                    (artwork_pk,),
                ).fetchone()
                self.assertEqual(row, ("shm", "shm_web", "shm-A-100", "青铜鼎", 0))

                image_rows = connection.execute(
                    "SELECT role, url FROM artwork_images WHERE artwork_pk = ? ORDER BY sort_order",
                    (artwork_pk,),
                ).fetchall()
                self.assertEqual(image_rows, [])

                category_rows = connection.execute(
                    """
                    SELECT c.category_id
                    FROM artwork_categories ac
                    JOIN categories c ON c.category_pk = ac.category_pk
                    WHERE ac.artwork_pk = ?
                    """,
                    (artwork_pk,),
                ).fetchall()
                self.assertEqual(category_rows, [("礼器",)])


if __name__ == "__main__":
    unittest.main()
