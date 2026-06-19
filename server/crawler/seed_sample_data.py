import argparse
import sqlite3
from pathlib import Path

from .main import write_manifest
from .museums.guimet import parse_detail_html as parse_guimet_detail_html
from .museums.guimet import store_artwork as store_guimet_artwork
from .museums.japan_search import NARA_COLBASE_PROFILE, TOKYO_PROFILE, parse_item_payload
from .museums.japan_search import store_artwork as store_japan_search_artwork
from .museums.met import extract_web_description, parse_object_payload
from .museums.met import store_artwork as store_met_artwork
from .museums.nara_official import parse_detail_html as parse_nara_official_detail_html
from .museums.nara_official import store_artwork as store_nara_official_artwork
from .museums.nmc import NationalMuseumChinaURLBuilder, parse_detail_html as parse_nmc_detail_html
from .museums.nmc import store_artwork as store_nmc_artwork
from .museums.shanghai import parse_article_html, parse_image_html
from .museums.shanghai import store_artwork as store_shanghai_artwork
from .stores import initialize_database, seed_reference_metadata


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
  "primaryImage": "https://images.metmuseum.org/CRDImages/as/original/DP123456.jpg",
  "primaryImageSmall": "https://images.metmuseum.org/CRDImages/as/web-large/DP123456.jpg",
  "objectURL": "https://www.metmuseum.org/art/collection/search/1001"
}
"""

MET_OVERVIEW_HTML = """
<main>
  <div class="object-overview-module-scss-module__x8Q2kL__label">
    <p>This gilt bronze figure is used as a local backend smoke-test artwork.</p>
    <p>The record follows the same fields as a crawled Met object.</p>
  </div>
</main>
"""

TOKYO_ITEM_JSON = """
{
  "id": "jpsearch-20",
  "common": {
    "id": "jpsearch-20",
    "title": "太刀",
    "linkUrl": "https://colbase.nich.go.jp/collection_items/tnm/F-1",
    "thumbnailUrl": ["https://image.example/slideshow_s/tokyo-thumb.jpg"],
    "contentsUrl": ["https://image.example/slideshow_s/tokyo-main.jpg"],
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

NARA_COLBASE_ITEM_JSON = """
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

NARA_OFFICIAL_DETAIL_HTML = """
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

SHANGHAI_ARTICLE_HTML = """
<div class="title">青铜鼎</div>
<ul>
  <li><div class="left">时代：</div><ul class="site-list right"><li>商后期</li></ul></li>
  <li><div class="left">材质：</div><ul class="site-list right"><li>青铜</li></ul></li>
  <li><div class="left">尺寸：</div><ul class="site-list right"><li>高10厘米</li></ul></li>
  <li><div class="left">类别：</div><ul class="site-list right"><li>礼器</li></ul></li>
</ul>
<div class="subtitle">简介</div>
<p>这是上海博物馆本地样本详情。</p>
"""

SHANGHAI_IMAGE_HTML = """
<figure data-src="/mu/images/large.jpg"></figure>
<img src="/mu/images/small.jpg" />
"""

GUIMET_DETAIL_HTML = """
<main role="main">
  <div class="artwork-header">
    <h1 class="artwork-title field field--name-field-title field--type-text-long field--label-hidden field__items">弥勒菩萨</h1>
    <div class="tag field field--name-field-text-period field--type-string field--label-hidden field__items">4-5世纪</div>
    <div class="main-artwork">
      <figure>
        <img loading="lazy" src="/sites/default/files/styles/width_1220px/public/2023-07/7-bodhisattva-maitreya_0.jpg?itok=usqaJKYE" />
      </figure>
    </div>
  </div>
  <div class="field--name-field-teaser field field--type-text-long field--label-hidden field__items">
    <p>这件作品是安德烈·马尔罗收藏中的一件传奇之作。</p>
  </div>
  <div class="field--name-field_ref_widgets field field--name-field-ref-widgets field--type-entity-reference-revisions field--label-hidden field__items">
    <div class="paragraph paragraph--type--wysiwyg paragraph--view-mode--default">
      <p>亚洲宗教对时间的看法是循环往复的。</p>
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
</main>
"""


def main() -> None:
    parser = argparse.ArgumentParser(description="Seed a local MuseumMuse SQLite database with parser-generated sample data.")
    parser.add_argument("--db", default="server/data/museummuse.sqlite")
    args = parser.parse_args()

    db_path = Path(args.db)
    initialize_database(db_path)
    seed_reference_metadata(db_path)

    with sqlite3.connect(db_path) as connection:
        connection.execute("PRAGMA foreign_keys = ON")

        met_record = parse_object_payload(MET_OBJECT_JSON).with_description(
            extract_web_description(MET_OVERVIEW_HTML)
        )
        store_met_artwork(connection, met_record)

        tokyo_record = parse_item_payload(TOKYO_ITEM_JSON, profile=TOKYO_PROFILE)
        store_japan_search_artwork(connection, tokyo_record, category_id="weaponry")

        nara_official_record = parse_nara_official_detail_html(
            NARA_OFFICIAL_DETAIL_HTML,
            raw_id="1032-0",
            detail_url="https://www.narahaku.go.jp/chinese/collection/1032-0.html",
        )
        store_nara_official_artwork(connection, nara_official_record)

        nara_colbase_record = parse_item_payload(NARA_COLBASE_ITEM_JSON, profile=NARA_COLBASE_PROFILE)
        store_japan_search_artwork(connection, nara_colbase_record, category_id="craft")

        nmc_record = parse_nmc_detail_html(
            NMC_DETAIL_HTML,
            exhibit_id=801,
            detail_url=NationalMuseumChinaURLBuilder.share_link_url(exhibit_id=801),
        )
        store_nmc_artwork(connection, nmc_record)

        shanghai_record = parse_article_html(SHANGHAI_ARTICLE_HTML, object_code="A-100").with_images(
            parse_image_html(SHANGHAI_IMAGE_HTML)
        )
        store_shanghai_artwork(connection, shanghai_record, category_id="礼器")

        guimet_record = parse_guimet_detail_html(
            GUIMET_DETAIL_HTML,
            detail_url="https://www.guimet.fr/zh-hans/nos-collections/afghanistan-pakistan/bodhisattva-maitreya",
        )
        store_guimet_artwork(connection, guimet_record, category_id="afghanistan-pakistan")

        connection.commit()

    manifest_path = write_manifest(db_path)
    print(f"seeded sample data into {db_path}")
    print(f"wrote manifest {manifest_path}")


if __name__ == "__main__":
    main()
