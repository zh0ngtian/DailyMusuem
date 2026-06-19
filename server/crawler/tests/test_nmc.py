import sqlite3
import tempfile
import unittest

from server.crawler.museums.nmc import (
    NationalMuseumChinaCrawler,
    NationalMuseumChinaApiBudgetExceeded,
    NationalMuseumChinaCrawlPolicy,
    NationalMuseumChinaURLBuilder,
    exhibit_ids_from_list_payload,
    exhibit_summaries_from_list_payload,
    make_list_budget,
    parse_detail_html,
    parse_web_detail_html,
    store_artwork,
    web_catalog_summaries_from_html,
)
from server.crawler.stores import initialize_database, seed_reference_metadata


NMC_DETAIL_HTML = """
<html>
  <body>
    <div class="content brief">
      <h1>后母戊鼎</h1>
      <p>商后期</p>
      <p>考古发掘品</p>
      <p>高 133 厘米</p>
    </div>
    <div class="content detail">
      <h1>展品介绍</h1>
      <p>后母戊鼎是商代青铜礼器。</p>
      <p>器身厚重，纹饰精美。</p>
    </div>
    <img src="/uploads/image/ding.jpg" />
  </body>
</html>
"""

NMC_DETAIL_HTML_WITHOUT_BRIEF_PARAGRAPHS = """
<html>
  <body>
    <div class="content brief">
      <h1>洒蓝釉地描金缠枝莲纹棒槌瓶</h1>
    </div>
    <div class="content detail">
      <h1>展品介绍</h1>
      <p>瓷器表面覆盖的玻璃质薄层叫做釉。</p>
    </div>
  </body>
</html>
"""

NMC_WEB_CATALOG_HTML = """
<html>
  <body>
    <a href="./kgfjp/202008/t20200824_247248.shtml">
      <span><img src="./thumb.jpg" /></span>
      <p>鹰形陶鼎</p>
    </a>
    <script>
      var currentPage = 0;
      var countPage = 67;
      var countnum = 1336;
    </script>
  </body>
</html>
"""

NMC_WEB_DETAIL_HTML = """
<html>
  <head>
    <meta name="ColumnName" content="考古发掘品" />
    <meta name="ArticleTitle" content="鹰形陶鼎" />
    <meta name="PubDate" content="2020-08-24 17:01:18" />
    <meta name="contentid" content="247248" />
  </head>
  <!--新石器;仰韶文化-->
  <body>
    <div class="cj_dycp_lef">
      <ul class="rslides picView-magnify-list">
        <li><a data-src="./large.jpg"><img src="./small.jpg" /></a></li>
      </ul>
    </div>
    <dl class="cj_dycp_rig">
      <dt>
        <div class="cj_ertitlere">鹰形陶鼎</div>
        <div class="cj_e_qing2">
          <div class="cj_e_canshu"><p>高35.8厘米，口径23.3厘米</p><p>1958年陕西省华县太平庄出土</p></div>
        </div>
      </dt>
      <dd>
        <div class="wwms"><p>此陶鼎采用伫足站立的雄鹰造型。</p></div>
      </dd>
    </dl>
  </body>
</html>
"""


class NationalMuseumChinaCrawlerTests(unittest.TestCase):
    def test_parse_detail_html_matches_swift_contract(self) -> None:
        record = parse_detail_html(
            NMC_DETAIL_HTML,
            exhibit_id=801,
            detail_url=NationalMuseumChinaURLBuilder.share_link_url(exhibit_id=801),
        )

        self.assertEqual(record.stable_id, "nmc-801")
        self.assertEqual(record.object_id, "801")
        self.assertEqual(record.title, "后母戊鼎")
        self.assertEqual(record.object_date, "商后期")
        self.assertEqual(record.department, "考古发掘品")
        self.assertEqual(record.dimensions, "高 133 厘米")
        self.assertEqual(record.primary_image_url, "https://appapi.chnmuseum.cn/uploads/image/ding.jpg")
        self.assertIn("后母戊鼎是商代青铜礼器", record.description_html or "")

    def test_store_artwork_writes_dto_visible_data(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            db_path = f"{directory}/museummuse.sqlite"
            initialize_database(db_path)
            seed_reference_metadata(db_path)
            record = parse_detail_html(
                NMC_DETAIL_HTML,
                exhibit_id=801,
                detail_url=NationalMuseumChinaURLBuilder.share_link_url(exhibit_id=801),
            )

            with sqlite3.connect(db_path) as connection:
                connection.execute("PRAGMA foreign_keys = ON")
                artwork_pk = store_artwork(connection, record)
                connection.commit()

                row = connection.execute(
                    "SELECT stable_id, title, has_image FROM artworks WHERE artwork_pk = ?",
                    (artwork_pk,),
                ).fetchone()
                self.assertEqual(row, ("nmc-801", "后母戊鼎", 1))

                image_count = connection.execute(
                    "SELECT COUNT(*) FROM artwork_images WHERE artwork_pk = ?",
                    (artwork_pk,),
                ).fetchone()[0]
                self.assertEqual(image_count, 2)

                category_count = connection.execute(
                    "SELECT COUNT(*) FROM artwork_categories WHERE artwork_pk = ?",
                    (artwork_pk,),
                ).fetchone()[0]
                self.assertEqual(category_count, 1)

    def test_list_payload_deduplicates_ids_and_reads_page_count(self) -> None:
        payload = b'{"data":{"page_count":3,"list":[{"exhibit_id":1},{"exhibit_id":1},{"exhibit_id":2}]}}'

        ids, page_count = exhibit_ids_from_list_payload(payload)

        self.assertEqual(ids, [1, 2])
        self.assertEqual(page_count, 3)

    def test_list_summary_fills_missing_detail_fields(self) -> None:
        payload = """
        {
          "data": {
            "page_count": 1,
            "list": [
              {
                "exhibit_id": 7570,
                "title": "洒蓝釉地描金缠枝莲纹棒槌瓶",
                "cate_name": "传世文物",
                "age": "清",
                "size": "高 45 厘米",
                "image_url": "/uploadfiles/exhibit_t_img/20240227/202402271606003933.jpg"
              }
            ]
          }
        }
        """
        summaries, page_count = exhibit_summaries_from_list_payload(payload)

        record = parse_detail_html(
            NMC_DETAIL_HTML_WITHOUT_BRIEF_PARAGRAPHS,
            exhibit_id=7570,
            detail_url=NationalMuseumChinaURLBuilder.share_link_url(exhibit_id=7570),
            list_summary=summaries[0],
        )

        self.assertEqual(page_count, 1)
        self.assertEqual(record.object_date, "清")
        self.assertEqual(record.department, "传世文物")
        self.assertEqual(record.dimensions, "高 45 厘米")
        self.assertEqual(
            record.primary_image_url,
            "https://appapi.chnmuseum.cn/uploadfiles/exhibit_t_img/20240227/202402271606003933.jpg",
        )

    def test_web_catalog_payload_reads_static_links(self) -> None:
        summaries, page_count, total_count = web_catalog_summaries_from_html(
            NMC_WEB_CATALOG_HTML,
            catalog_url="https://www.chnmuseum.cn/zp/zpml/index.shtml",
        )

        self.assertEqual(page_count, 67)
        self.assertEqual(total_count, 1336)
        self.assertEqual(len(summaries), 1)
        self.assertEqual(summaries[0].exhibit_id, 247248)
        self.assertEqual(summaries[0].title, "鹰形陶鼎")
        self.assertEqual(
            summaries[0].raw_item["detail_url"],
            "https://www.chnmuseum.cn/zp/zpml/kgfjp/202008/t20200824_247248.shtml",
        )

    def test_parse_web_detail_html_matches_static_catalog_page(self) -> None:
        record = parse_web_detail_html(
            NMC_WEB_DETAIL_HTML,
            detail_url="https://www.chnmuseum.cn/zp/zpml/kgfjp/202008/t20200824_247248.shtml",
        )

        self.assertEqual(record.stable_id, "nmc-247248")
        self.assertEqual(record.title, "鹰形陶鼎")
        self.assertEqual(record.object_date, "新石器 · 仰韶文化")
        self.assertEqual(record.department, "考古发掘品")
        self.assertEqual(record.dimensions, "高35.8厘米，口径23.3厘米")
        self.assertEqual(
            record.primary_image_url,
            "https://www.chnmuseum.cn/zp/zpml/kgfjp/202008/large.jpg",
        )
        self.assertIn("伫足站立", record.description_html or "")

    def test_api_budget_raises_when_exhausted(self) -> None:
        budget = make_list_budget(NationalMuseumChinaCrawlPolicy(max_list_api_calls=1))
        budget.consume(endpoint="exhibit_list", page=1)

        with self.assertRaises(NationalMuseumChinaApiBudgetExceeded):
            budget.consume(endpoint="exhibit_list", page=2)

    def test_candidate_discovery_stops_after_minimum_count(self) -> None:
        class StubCrawler(NationalMuseumChinaCrawler):
            def __init__(self) -> None:
                super().__init__(NationalMuseumChinaCrawlPolicy(max_list_api_calls=20))
                self.pages: list[int] = []

            def fetch_list_page(self, *, page: int) -> bytes:
                self.pages.append(page)
                return b'{"data":{"page_count":20,"list":[{"exhibit_id":101},{"exhibit_id":102}]}}'

        crawler = StubCrawler()

        ids = crawler.fetch_candidate_ids(minimum_count=1)

        self.assertEqual(ids, [101, 102])
        self.assertEqual(crawler.pages, [1])


if __name__ == "__main__":
    unittest.main()
