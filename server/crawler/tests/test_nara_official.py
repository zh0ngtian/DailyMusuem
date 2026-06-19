import sqlite3
import tempfile
import unittest

from server.crawler.museums.nara_official import (
    parse_detail_html,
    parse_search_page,
    store_artwork,
)
from server.crawler.stores import initialize_database, seed_reference_metadata


SEARCH_HTML = """
<div class="list clearfix">
  <p data-href="1032-0.html">
    <a href="1032-0.html">
      <i><img src="http://www.narahaku.go.jp/photo/exhibition/D025456.jpg" data-original="http://www.narahaku.go.jp/photo/exhibition/D025456.jpg" alt="浮雕佛传图" /></i>
      <span>浮雕佛传图<br>贵霜王朝<br /> 2世纪</span>
    </a>
  </p>
  <p data-href="1324-0.html">
    <a href="1324-0.html">
      <i><img src="//www.narahaku.go.jp/photo/exhibition/H017708.jpg" alt="菩萨立像" /></i>
      <span>菩萨立像<br>贵霜王朝<br /> 3世纪</span>
    </a>
  </p>
</div>
"""


DETAIL_HTML = """
<div id="content" class="gallery-detail">
  <div class="description">
    <h2>浮雕佛传图</h2>
    <p><br>
      石造　浮雕　圆雕<br>
      高8.9cm　长34.0～74.0cm<br>
      印度　贵霜王朝　2世纪<br>
    </p>
    <div class="btnOperation"></div>
  </div>
  <div class="main">
    <img src="//www.narahaku.go.jp/photo/exhibition/D025456.jpg" data-id="1032-0" data-original="//www.narahaku.go.jp/photo/exhibition/D025456.jpg" palm="//www.narahaku.go.jp/_fKkxXPHb/D025456.jpg" alt="浮雕佛传图" class="mainPicture" />
  </div>
  <div class="text" id="kaisetsu">
    <p>该作品是将佛教创始人释迦牟尼传记的场面表现出来的浮雕的一部分。</p>
  </div>
  <table class="dbdetail">
    <tr><th>门类</th><td>雕刻</td></tr>
  </table>
</div>
"""


DESCRIPTION_HTML = """
<div id="content" class="gallery-detail">
  <div class="description">
    <h2>阿弥陀如来坐像</h2>
    <p><br>
      木造<br>
      高42.0cm<br>
      日本　奈良时代　8世纪<br>
    </p>
    <div class="btnOperation"></div>
  </div>
  <div class="text" id="kaisetsu">
    <p>　　该造像平稳柔和、姿态优美。像体的立体感和衣褶处都表现出下一个 时代的要素。造像体内空洞，密密麻麻写着阿弥陀佛的种子，应该是受到了密宗的影响。<br />&nbsp;<br /><span style="display:block; text-align:right;">内藤航</span><span style="display:block; text-align:right;">(翻译： 张小娟)</span>奈良博三昧 －佛教美术品精选－. 奈良国立博物馆, 2021.7, 317</p>
    <p>　　该像明显具有平安时代后期造像稳健的作风。双手交叠腹前，拇指和食指相捻，呈阿弥陀定印。像内中空部分，以墨书密密麻麻地写着阿弥陀佛的种子符号（象征佛的梵文）。语音导览</p>
  </div>
  <table class="dbdetail">
    <tr><th>门类</th><td>雕刻</td></tr>
  </table>
</div>
"""


MISSING_MEDIUM_HTML = """
<div id="content" class="gallery-detail">
  <div class="description">
    <h2>銮</h2>
    <p><br>
      <br>
      高17.8cm<br>
      中国　中国・西周　公元前11世纪<br>
    </p>
    <div class="btnOperation"></div>
  </div>
  <div class="main">
    <img src="//www.narahaku.go.jp/photo/exhibition/D037178.jpg" data-id="1317-331" data-original="//www.narahaku.go.jp/photo/exhibition/D037178.jpg" palm="//www.narahaku.go.jp/_fKkxXPHb/D037178.jpg" alt="銮" class="mainPicture" />
  </div>
  <div class="text" id="kaisetsu"></div>
  <table class="dbdetail">
    <tr><th>门类</th><td>考古</td></tr>
  </table>
</div>
"""


class NaraOfficialCrawlerTests(unittest.TestCase):
    def test_search_page_parser_normalizes_candidates_and_urls(self) -> None:
        summaries = parse_search_page(SEARCH_HTML)

        self.assertEqual([summary.raw_id for summary in summaries], ["1032-0", "1324-0"])
        self.assertEqual(summaries[0].object_id, "narahaku-1032-0")
        self.assertEqual(summaries[0].title, "浮雕佛传图")
        self.assertEqual(summaries[0].summary, "浮雕佛传图 / 贵霜王朝 / 2世纪")
        self.assertEqual(summaries[0].thumbnail_url, "https://www.narahaku.go.jp/photo/exhibition/D025456.jpg")
        self.assertEqual(summaries[0].detail_url, "https://www.narahaku.go.jp/chinese/collection/1032-0.html")
        self.assertEqual(summaries[1].thumbnail_url, "https://www.narahaku.go.jp/photo/exhibition/H017708.jpg")

    def test_detail_parser_maps_artwork_fields(self) -> None:
        record = parse_detail_html(
            DETAIL_HTML,
            raw_id="1032-0",
            detail_url="https://www.narahaku.go.jp/chinese/collection/1032-0.html",
        )

        self.assertEqual(record.stable_id, "nnm-narahaku-1032-0")
        self.assertEqual(record.object_id, "narahaku-1032-0")
        self.assertEqual(record.title, "浮雕佛传图")
        self.assertEqual(record.medium, "石造　浮雕　圆雕")
        self.assertEqual(record.dimensions, "高8.9cm　长34.0～74.0cm")
        self.assertEqual(record.country, "印度")
        self.assertEqual(record.object_date, "贵霜王朝 2世纪")
        self.assertEqual(record.department, "雕刻")
        self.assertEqual(record.artwork_description, "该作品是将佛教创始人释迦牟尼传记的场面表现出来的浮雕的一部分。")
        self.assertEqual(record.primary_image_url, "https://www.narahaku.go.jp/_fKkxXPHb/D025456.jpg")
        self.assertEqual(record.primary_image_small_url, "https://www.narahaku.go.jp/photo/exhibition/D025456.jpg")

    def test_description_cleaning_removes_translation_and_audio_guide_tail(self) -> None:
        record = parse_detail_html(
            DESCRIPTION_HTML,
            raw_id="1324-0",
            detail_url="https://www.narahaku.go.jp/chinese/collection/1324-0.html",
        )

        self.assertEqual(
            record.artwork_description,
            "该造像平稳柔和、姿态优美。像体的立体感和衣褶处都表现出下一个 时代的要素。造像体内空洞，密密麻麻写着阿弥陀佛的种子，应该是受到了密宗的影响。\n"
            "该像明显具有平安时代后期造像稳健的作风。双手交叠腹前，拇指和食指相捻，呈阿弥陀定印。像内中空部分，以墨书密密麻麻地写着阿弥陀佛的种子符号（象征佛的梵文）。",
        )
        self.assertNotIn("翻译", record.artwork_description or "")
        self.assertNotIn("语音导览", record.artwork_description or "")

    def test_detail_parser_handles_missing_medium_line(self) -> None:
        record = parse_detail_html(
            MISSING_MEDIUM_HTML,
            raw_id="1317-331",
            detail_url="https://www.narahaku.go.jp/chinese/collection/1317-331.html",
        )

        self.assertEqual(record.title, "銮")
        self.assertIsNone(record.medium)
        self.assertEqual(record.dimensions, "高17.8cm")
        self.assertEqual(record.country, "中国")
        self.assertEqual(record.object_date, "中国・西周 公元前11世纪")
        self.assertEqual(record.department, "考古")

    def test_store_official_artwork_writes_images_and_category_membership(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            db_path = f"{directory}/museummuse.sqlite"
            initialize_database(db_path)
            seed_reference_metadata(db_path)
            record = parse_detail_html(
                DETAIL_HTML,
                raw_id="1032-0",
                detail_url="https://www.narahaku.go.jp/chinese/collection/1032-0.html",
            )

            with sqlite3.connect(db_path) as connection:
                connection.execute("PRAGMA foreign_keys = ON")
                artwork_pk = store_artwork(connection, record)
                connection.commit()

                row = connection.execute(
                    "SELECT museum_id, source_key, stable_id, title, has_image FROM artworks WHERE artwork_pk = ?",
                    (artwork_pk,),
                ).fetchone()
                self.assertEqual(row, ("nnm", "official", "nnm-narahaku-1032-0", "浮雕佛传图", 1))

                image_rows = connection.execute(
                    "SELECT role, url FROM artwork_images WHERE artwork_pk = ? ORDER BY sort_order",
                    (artwork_pk,),
                ).fetchall()
                self.assertEqual(
                    image_rows,
                    [
                        ("primary", "https://www.narahaku.go.jp/_fKkxXPHb/D025456.jpg"),
                        ("thumbnail", "https://www.narahaku.go.jp/photo/exhibition/D025456.jpg"),
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
                self.assertEqual(category_rows, [("official-sculpture",)])


if __name__ == "__main__":
    unittest.main()
