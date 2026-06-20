import json
import sqlite3
from pathlib import Path


SERVER_ROOT = Path(__file__).resolve().parents[1]
SCHEMA_PATH = SERVER_ROOT / "migrations" / "001_initial.sql"


def initialize_database(db_path: str | Path) -> None:
    path = Path(db_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    schema = SCHEMA_PATH.read_text(encoding="utf-8")
    with sqlite3.connect(path) as connection:
        connection.executescript(schema)
        ensure_client_metadata_schema(connection)
        connection.commit()


def ensure_client_metadata_schema(connection: sqlite3.Connection) -> None:
    ensure_column(connection, "museums", "address", "TEXT")
    ensure_column(connection, "museums", "icon_url", "TEXT")
    ensure_column(connection, "museums", "icon_asset_name", "TEXT")
    ensure_column(connection, "museums", "icon_background_color", "TEXT")
    ensure_column(connection, "museums", "text_punctuation_style", "TEXT NOT NULL DEFAULT 'western'")
    ensure_column(connection, "museums", "supports_favorites", "INTEGER NOT NULL DEFAULT 1")
    ensure_column(connection, "data_sources", "translation_source_language", "TEXT")
    ensure_column(connection, "data_sources", "preferred_image_url_order_json", "TEXT")
    ensure_column(connection, "data_sources", "image_request_headers_json", "TEXT")
    ensure_column(connection, "data_sources", "artwork_source_key", "TEXT")
    ensure_column(connection, "data_sources", "list_filter_json", "TEXT")
    connection.execute(
        """
        CREATE TABLE IF NOT EXISTS museum_client_policies (
            museum_id TEXT PRIMARY KEY REFERENCES museums(museum_id) ON DELETE CASCADE,
            waterfall_image_qps REAL,
            raw_json TEXT
        )
        """
    )


def ensure_column(connection: sqlite3.Connection, table: str, column: str, definition: str) -> None:
    rows = connection.execute(f"PRAGMA table_info({table})").fetchall()
    if any(row[1] == column for row in rows):
        return
    connection.execute(f"ALTER TABLE {table} ADD COLUMN {column} {definition}")


def seed_reference_metadata(db_path: str | Path) -> None:
    with sqlite3.connect(db_path) as connection:
        connection.executemany(
            """
            INSERT INTO museums(
                museum_id, display_name, country, city, subtitle,
                address, icon_url, icon_asset_name, icon_background_color, text_punctuation_style,
                supports_translation, supports_widget_content, supports_favorites, sort_order
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(museum_id) DO UPDATE SET
                display_name = excluded.display_name,
                country = excluded.country,
                city = excluded.city,
                subtitle = excluded.subtitle,
                address = excluded.address,
                icon_url = excluded.icon_url,
                icon_asset_name = excluded.icon_asset_name,
                icon_background_color = excluded.icon_background_color,
                text_punctuation_style = excluded.text_punctuation_style,
                supports_translation = excluded.supports_translation,
                supports_widget_content = excluded.supports_widget_content,
                supports_favorites = excluded.supports_favorites,
                sort_order = excluded.sort_order
            """,
            [
                ("nmc", "中国国家博物馆", "中国", "北京", "北京", None, None, "NmcHomepageLogo", None, "chinese", 0, 1, 1, 10),
                ("shm", "上海博物馆", "中国", "上海", "上海", None, None, "ShmHomepageLogo", None, "chinese", 0, 1, 1, 20),
                ("met", "大都会艺术博物馆", "美国", "纽约", "纽约", None, None, "MetHomepageLogo", None, "western", 1, 1, 1, 30),
                ("tnm", "东京国立博物馆", "日本", "东京", "东京", None, None, "TnmHomepageLogo", None, "western", 1, 1, 1, 40),
                ("nnm", "奈良国立博物馆", "日本", "奈良", "奈良", None, None, "NnmHomepageLogo", None, "western", 1, 1, 1, 50),
                ("guimet", "吉美国立亚洲艺术博物馆", "法国", "巴黎", "巴黎", None, None, "GuimetHomepageLogo", None, "western", 1, 1, 1, 60),
            ],
        )
        connection.executemany(
            """
            INSERT INTO data_sources(
                museum_id, source_key, display_name, is_default, artwork_source_key, list_filter_json, request_base_url,
                translation_source_language, preferred_image_url_order_json, image_request_headers_json, notes
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(museum_id, source_key) DO UPDATE SET
                display_name = excluded.display_name,
                is_default = excluded.is_default,
                artwork_source_key = excluded.artwork_source_key,
                list_filter_json = excluded.list_filter_json,
                request_base_url = excluded.request_base_url,
                translation_source_language = excluded.translation_source_language,
                preferred_image_url_order_json = excluded.preferred_image_url_order_json,
                image_request_headers_json = excluded.image_request_headers_json,
                notes = excluded.notes
            """,
            source_metadata_rows(),
        )
        connection.executemany(
            """
            INSERT INTO categories(
                museum_id, source_key, category_id, display_name,
                sort_order, raw_json
            )
            VALUES (?, ?, ?, ?, ?, NULL)
            ON CONFLICT(museum_id, source_key, category_id) DO UPDATE SET
                display_name = excluded.display_name,
                sort_order = excluded.sort_order
            """,
            reference_categories(),
        )
        normalize_obsolete_metadata(connection)
        connection.executemany(
            """
            INSERT INTO museum_client_policies(museum_id, waterfall_image_qps, raw_json)
            VALUES (?, ?, NULL)
            ON CONFLICT(museum_id) DO UPDATE SET
                waterfall_image_qps = excluded.waterfall_image_qps,
                raw_json = excluded.raw_json
            """,
            [
                ("nmc", 1.0),
                ("shm", None),
                ("met", None),
                ("tnm", None),
                ("nnm", None),
                ("guimet", None),
            ],
        )
        connection.commit()


def normalize_obsolete_metadata(connection: sqlite3.Connection) -> None:
    connection.execute(
        """
        INSERT OR IGNORE INTO artwork_categories(artwork_pk, category_pk, membership_source)
        SELECT ac.artwork_pk, new_category.category_pk, ac.membership_source
        FROM artwork_categories ac
        JOIN categories old_category ON old_category.category_pk = ac.category_pk
        JOIN categories new_category
          ON new_category.museum_id = old_category.museum_id
         AND new_category.source_key = 'met_all'
         AND new_category.category_id = old_category.category_id
        WHERE old_category.museum_id = 'met'
          AND old_category.source_key = 'met_api'
        """
    )
    connection.execute(
        """
        DELETE FROM artworks
        WHERE artwork_pk IN (
            SELECT old_artwork.artwork_pk
            FROM artworks old_artwork
            JOIN artworks new_artwork
              ON new_artwork.museum_id = old_artwork.museum_id
             AND new_artwork.source_key = 'met_all'
             AND new_artwork.object_id = old_artwork.object_id
            WHERE old_artwork.museum_id = 'met'
              AND old_artwork.source_key = 'met_api'
        )
        """
    )
    connection.execute(
        """
        UPDATE artworks
        SET source_key = 'met_all'
        WHERE museum_id = 'met' AND source_key = 'met_api'
        """
    )
    connection.execute(
        """
        UPDATE crawl_errors
        SET source_key = 'met_all'
        WHERE museum_id = 'met' AND source_key = 'met_api'
        """
    )
    connection.execute(
        """
        DELETE FROM data_sources
        WHERE museum_id = 'met' AND source_key = 'met_api'
        """
    )


def source_metadata_rows() -> list[tuple[str, str, str, int, str | None, str | None, str, str | None, str, str, str | None]]:
    image_order_primary = json.dumps(["primary", "thumbnail"], ensure_ascii=False)
    image_order_thumbnail = json.dumps(["thumbnail", "primary"], ensure_ascii=False)
    empty_filter = json.dumps({}, ensure_ascii=False)
    met_on_view_filter = json.dumps({"only_on_view": True}, ensure_ascii=False, sort_keys=True)
    browser_image_headers = {
        "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
        "Accept": "image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8",
        "Accept-Language": "ja-JP,ja;q=0.9,en-US;q=0.8,zh-CN;q=0.7",
        "Cache-Control": "no-cache",
        "Pragma": "no-cache",
    }

    def headers_with_referer(referer: str) -> str:
        headers = {**browser_image_headers, "Referer": referer}
        return json.dumps(headers, ensure_ascii=False, sort_keys=True)

    empty_headers = json.dumps({}, ensure_ascii=False)
    return [
        ("met", "met_all", "全部展品", 1, None, empty_filter, "https://collectionapi.metmuseum.org", "en", image_order_primary, empty_headers, None),
        ("met", "met_on_view", "在展展品", 0, "met_all", met_on_view_filter, "https://collectionapi.metmuseum.org", "en", image_order_primary, empty_headers, None),
        ("tnm", "japan_search", "Japan Search", 1, None, empty_filter, "https://jpsearch.go.jp", "ja", image_order_thumbnail, headers_with_referer("https://colbase.nich.go.jp/"), None),
        (
            "nnm",
            "official",
            "馆方数据源",
            1,
            None,
            empty_filter,
            "https://www.narahaku.go.jp/chinese/collection/",
            "zh-Hans",
            image_order_primary,
            headers_with_referer("https://www.narahaku.go.jp/chinese/collection/"),
            None,
        ),
        (
            "nnm",
            "colbase",
            "ColBase",
            0,
            None,
            empty_filter,
            "https://jpsearch.go.jp",
            "ja",
            image_order_thumbnail,
            headers_with_referer("https://colbase.nich.go.jp/"),
            None,
        ),
        (
            "nmc",
            "nmc_api",
            "中国国家博物馆 App API",
            1,
            None,
            empty_filter,
            "https://appapi.chnmuseum.cn",
            None,
            image_order_primary,
            empty_headers,
            "Strict API budget: prefer cate_id=0 large pages; avoid per-category API loops; detail via web HTML when possible.",
        ),
        ("shm", "shm_web", "上海博物馆官网", 1, None, empty_filter, "https://www.shanghaimuseum.net", None, image_order_primary, empty_headers, "1 QPS crawler limiter"),
        ("guimet", "guimet_web", "吉美官网中文藏品页", 1, None, empty_filter, "https://www.guimet.fr/zh-hans", None, image_order_primary, empty_headers, None),
    ]


def reference_categories() -> list[tuple[str, str, str, str, int]]:
    rows: list[tuple[str, str, str, str, int]] = []

    def add(
        museum_id: str,
        source_key: str,
        category_id: str,
        display_name: str,
    ) -> None:
        rows.append((museum_id, source_key, category_id, display_name, len(rows)))

    for category_id, display_name, department_id in [
        ("american-decorative-arts", "美国装饰艺术", "1"),
        ("ancient-west-asian-art", "古代西亚艺术", "3"),
        ("arms-and-armor", "武器与盔甲", "4"),
        ("africa-oceania-americas", "非洲、大洋洲与美洲艺术", "5"),
        ("asian-art", "亚洲艺术", "6"),
        ("the-cloisters", "修道院分馆", "7"),
        ("costume-institute", "服装学院", "8"),
        ("drawings-and-prints", "素描与版画", "9"),
        ("egyptian-art", "古埃及艺术", "10"),
        ("european-paintings", "欧洲绘画", "11"),
        ("european-sculpture-and-decorative-arts", "欧洲雕塑与装饰艺术", "12"),
        ("greek-and-roman-art", "古希腊与古罗马艺术", "13"),
        ("islamic-art", "伊斯兰艺术", "14"),
        ("robert-lehman-collection", "罗伯特·雷曼收藏", "15"),
        ("libraries", "图书馆藏", "16"),
        ("medieval-art", "中世纪艺术", "17"),
        ("musical-instruments", "乐器", "18"),
        ("photographs", "摄影", "19"),
        ("modern-art", "现代艺术", "21"),
    ]:
        add("met", "met_all", category_id, display_name)

    for category_id, display_name in [
        ("archeology", "考古与历史资料"),
        ("paint", "绘画"),
        ("ancdoc", "书迹与古文书"),
        ("metal", "金属工艺"),
        ("ceramic", "陶瓷"),
        ("lacquer", "漆器"),
        ("daw", "染织"),
        ("weaponry", "刀剑与兵器"),
        ("sculpture", "雕刻"),
        ("arts", "艺术与美术"),
        ("architecture", "建筑"),
    ]:
        add("tnm", "japan_search", category_id, display_name)

    for category_id, display_name in [
        ("official-sculpture", "雕刻"),
        ("official-painting", "绘画"),
        ("official-calligraphy", "书迹"),
        ("official-craft", "工艺"),
        ("official-archaeology", "考古"),
        ("official-ancient-chinese-bronze", "中国古代青铜器"),
        ("official-other", "其他"),
    ]:
        add("nnm", "official", category_id, display_name)

    for category_id, display_name in [
        ("archeology", "考古与历史资料"),
        ("ancdoc", "书迹与古文书"),
        ("paint", "绘画"),
        ("craft", "工艺"),
        ("sculpture", "雕刻"),
        ("ceramic", "陶瓷"),
        ("metal", "金属工艺"),
        ("lacquer", "漆器"),
        ("weaponry", "刀剑与兵器"),
        ("daw", "染织"),
    ]:
        add("nnm", "colbase", category_id, display_name)

    for category_id, display_name in [
        ("archaeology", "考古发掘品"),
        ("revolutionary", "革命文物"),
        ("national-history", "国史文物"),
        ("heirloom", "传世文物"),
        ("currency", "货币"),
        ("rubbings", "文献拓本"),
        ("arts", "艺术品"),
    ]:
        add("nmc", "nmc_api", category_id, display_name)

    for name in [
        "礼器", "明器", "法器", "道具", "模具/模版", "丧葬用具", "陈设/观赏品", "日用品", "文具", "农具",
        "工具", "兵器", "饪食器", "酒器", "水器", "车马器", "度量衡", "古钱", "铸币", "打制币",
        "机制币", "纸币", "金银锭", "非法定钱币", "雕塑", "造像", "碑刻/墓志", "俑像", "画像石", "画像砖",
        "封泥", "符节（牌）", "印玺", "建筑配件", "器物配件", "织物", "绣品", "服装", "饰品", "文献",
        "书籍图谱", "拓本", "玩具", "乐器",
    ]:
        add("shm", "shm_web", name, name)

    for category_id, display_name in [
        ("afghanistan-pakistan", "阿富汗 - 巴基斯坦"),
        ("southeast-asia", "东南亚"),
        ("indian-world", "印度世界"),
        ("himalayan-world", "喜马拉雅世界"),
        ("china", "中国"),
        ("buddhist-china-central-asia", "中国佛教 - 中亚"),
        ("korea", "韩国收藏"),
        ("japan", "日本"),
        ("textiles", "织物"),
        ("historical-library", "历史图书馆珍藏"),
        ("photography", "摄影作品"),
    ]:
        add("guimet", "guimet_web", category_id, display_name)

    return rows
