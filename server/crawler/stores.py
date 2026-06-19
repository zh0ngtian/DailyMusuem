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
        connection.commit()


def seed_reference_metadata(db_path: str | Path) -> None:
    with sqlite3.connect(db_path) as connection:
        connection.executemany(
            """
            INSERT INTO museums(
                museum_id, display_name, country, city, subtitle,
                supports_translation, supports_widget_content, sort_order
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(museum_id) DO UPDATE SET
                display_name = excluded.display_name,
                country = excluded.country,
                city = excluded.city,
                subtitle = excluded.subtitle,
                supports_translation = excluded.supports_translation,
                supports_widget_content = excluded.supports_widget_content,
                sort_order = excluded.sort_order
            """,
            [
                ("nmc", "中国国家博物馆", "中国", "北京", "北京", 0, 1, 10),
                ("shm", "上海博物馆", "中国", "上海", "上海", 0, 1, 20),
                ("met", "大都会艺术博物馆", "美国", "纽约", "纽约", 1, 1, 30),
                ("tnm", "东京国立博物馆", "日本", "东京", "东京", 1, 1, 40),
                ("nnm", "奈良国立博物馆", "日本", "奈良", "奈良", 1, 1, 50),
                ("guimet", "吉美国立亚洲艺术博物馆", "法国", "巴黎", "巴黎", 1, 1, 60),
            ],
        )
        connection.executemany(
            """
            INSERT INTO data_sources(
                museum_id, source_key, display_name, is_default, request_base_url, notes
            )
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(museum_id, source_key) DO UPDATE SET
                display_name = excluded.display_name,
                is_default = excluded.is_default,
                request_base_url = excluded.request_base_url,
                notes = excluded.notes
            """,
            [
                ("met", "met_api", "The Met Collection API", 1, "https://collectionapi.metmuseum.org", None),
                ("tnm", "japan_search", "Japan Search", 1, "https://jpsearch.go.jp", None),
                ("nnm", "official", "馆方数据源", 1, "https://www.narahaku.go.jp/chinese/collection/", None),
                ("nnm", "colbase", "ColBase", 0, "https://jpsearch.go.jp", None),
                (
                    "nmc",
                    "nmc_api",
                    "中国国家博物馆 App API",
                    1,
                    "https://appapi.chnmuseum.cn",
                    "Strict API budget: prefer cate_id=0 large pages; avoid per-category API loops; detail via web HTML when possible.",
                ),
                ("shm", "shm_web", "上海博物馆官网", 1, "https://www.shanghaimuseum.net", "1 QPS crawler limiter"),
                ("guimet", "guimet_web", "吉美官网中文藏品页", 1, "https://www.guimet.fr/zh-hans", None),
            ],
        )
        connection.executemany(
            """
            INSERT INTO categories(
                museum_id, source_key, category_id, display_name, kind,
                remote_value, sort_order, raw_json
            )
            VALUES (?, ?, ?, ?, ?, ?, ?, NULL)
            ON CONFLICT(museum_id, source_key, category_id) DO UPDATE SET
                display_name = excluded.display_name,
                kind = excluded.kind,
                remote_value = excluded.remote_value,
                sort_order = excluded.sort_order
            """,
            reference_categories(),
        )
        connection.commit()


def reference_categories() -> list[tuple[str, str, str, str, str, str, int]]:
    rows: list[tuple[str, str, str, str, str, str, int]] = []

    def add(
        museum_id: str,
        source_key: str,
        category_id: str,
        display_name: str,
        kind: str,
        remote_value: str,
    ) -> None:
        rows.append((museum_id, source_key, category_id, display_name, kind, remote_value, len(rows)))

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
        add("met", "met_api", category_id, display_name, "metDepartment", department_id)

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
        add("tnm", "japan_search", category_id, display_name, "japanSearchType", category_id)

    for category_id, display_name in [
        ("official-sculpture", "雕刻"),
        ("official-painting", "绘画"),
        ("official-calligraphy", "书迹"),
        ("official-craft", "工艺"),
        ("official-archaeology", "考古"),
        ("official-ancient-chinese-bronze", "中国古代青铜器"),
        ("official-other", "其他"),
    ]:
        add("nnm", "official", category_id, display_name, "naraMuseumOfficialDepartment", display_name)

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
        add("nnm", "colbase", category_id, display_name, "japanSearchType", category_id)

    for category_id, display_name, remote_value in [
        ("archaeology", "考古发掘品", "1"),
        ("revolutionary", "革命文物", "2"),
        ("national-history", "国史文物", "3"),
        ("heirloom", "传世文物", "4"),
        ("currency", "货币", "22"),
        ("rubbings", "文献拓本", "24"),
        ("arts", "艺术品", "26"),
    ]:
        add("nmc", "nmc_api", category_id, display_name, "nationalMuseumChinaBucket", remote_value)

    for name in [
        "礼器", "明器", "法器", "道具", "模具/模版", "丧葬用具", "陈设/观赏品", "日用品", "文具", "农具",
        "工具", "兵器", "饪食器", "酒器", "水器", "车马器", "度量衡", "古钱", "铸币", "打制币",
        "机制币", "纸币", "金银锭", "非法定钱币", "雕塑", "造像", "碑刻/墓志", "俑像", "画像石", "画像砖",
        "封泥", "符节（牌）", "印玺", "建筑配件", "器物配件", "织物", "绣品", "服装", "饰品", "文献",
        "书籍图谱", "拓本", "玩具", "乐器",
    ]:
        add("shm", "shm_web", name, name, "shanghaiMuseumSubtype", name)

    for category_id, display_name, path in [
        ("afghanistan-pakistan", "阿富汗 - 巴基斯坦", "/zh-hans/collections/afghanistan-et-gandhara"),
        ("southeast-asia", "东南亚", "/zh-hans/collections/asie-du-sud-est"),
        ("indian-world", "印度世界", "/zh-hans/collections/monde-indien"),
        ("himalayan-world", "喜马拉雅世界", "/zh-hans/collections/monde-himalayen"),
        ("china", "中国", "/zh-hans/collections/chine"),
        ("buddhist-china-central-asia", "中国佛教 - 中亚", "/zh-hans/collections/chine-bouddhique-asie-centrale"),
        ("korea", "韩国收藏", "/zh-hans/collections/coree"),
        ("japan", "日本", "/zh-hans/collections/japon"),
        ("textiles", "织物", "/zh-hans/collections/textiles"),
        ("historical-library", "历史图书馆珍藏", "/zh-hans/collections/tresors-de-la-bibliotheque"),
        ("photography", "摄影作品", "/zh-hans/collections/photographies"),
    ]:
        add("guimet", "guimet_web", category_id, display_name, "guimetCollection", path)

    return rows
