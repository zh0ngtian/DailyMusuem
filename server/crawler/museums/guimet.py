import hashlib
import html
import json
import re
import sqlite3
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from urllib.parse import urljoin, urlparse
from urllib.request import Request, urlopen


GUIMET_BASE_URL = "https://www.guimet.fr"
GUIMET_ARTWORK_PATH_PREFIX = "/zh-hans/nos-collections/"
GUIMET_REPOSITORY = "吉美国立亚洲艺术博物馆"
OBJECT_ID_PATH_SEPARATOR = "~"

COLLECTION_CATEGORY_PATHS = {
    "afghanistan-pakistan": "/zh-hans/collections/afghanistan-et-gandhara",
    "southeast-asia": "/zh-hans/collections/asie-du-sud-est",
    "indian-world": "/zh-hans/collections/monde-indien",
    "himalayan-world": "/zh-hans/collections/monde-himalayen",
    "china": "/zh-hans/collections/chine",
    "buddhist-china-central-asia": "/zh-hans/collections/chine-bouddhique-asie-centrale",
    "korea": "/zh-hans/collections/coree",
    "japan": "/zh-hans/collections/japon",
    "textiles": "/zh-hans/collections/textiles",
    "historical-library": "/zh-hans/collections/tresors-de-la-bibliotheque",
    "photography": "/zh-hans/collections/photographies",
}


@dataclass(frozen=True)
class GuimetCrawlerPolicy:
    request_interval_seconds: float = 0.25


@dataclass(frozen=True)
class GuimetArtworkSummary:
    object_id: str
    title: str
    category: str | None
    image_url: str | None
    detail_url: str


@dataclass(frozen=True)
class GuimetArtworkRecord:
    object_id: str
    title: str
    artwork_description: str | None
    artist_display_name: str | None
    object_date: str | None
    medium: str | None
    dimensions: str | None
    department: str | None
    culture: str | None
    primary_image_url: str | None
    object_url: str
    raw_html_excerpt: str

    @property
    def stable_id(self) -> str:
        return f"guimet-{self.object_id}"

    @property
    def content_hash(self) -> str:
        payload = json.dumps(
            {
                "title": self.title,
                "artwork_description": self.artwork_description,
                "artist_display_name": self.artist_display_name,
                "object_date": self.object_date,
                "medium": self.medium,
                "dimensions": self.dimensions,
                "department": self.department,
                "culture": self.culture,
                "primary_image_url": self.primary_image_url,
                "object_url": self.object_url,
            },
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        )
        return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def parse_collection_page(html_text: str, *, base_url: str = GUIMET_BASE_URL) -> list[GuimetArtworkSummary]:
    starts = [match.start() for match in re.finditer(
        r"<div\b[^>]*role=[\"']article[\"'][^>]*node--type-art-work[^>]*>",
        html_text,
        flags=re.IGNORECASE,
    )]
    summaries: list[GuimetArtworkSummary] = []
    for index, start in enumerate(starts):
        end = starts[index + 1] if index + 1 < len(starts) else len(html_text)
        fragment = html_text[start:end]
        link = first_capture(
            fragment,
            r"<a\b[^>]*class=[\"'][^\"']*\bread-more-link\b[^\"']*[\"'][^>]*href=[\"']([^\"']+)[\"']",
        ) or first_capture(
            fragment,
            r"<a\b[^>]*href=[\"']([^\"']+)[\"'][^>]*class=[\"'][^\"']*\bread-more-link\b[^\"']*[\"']",
        )
        detail_url = public_url(link, base_url=base_url)
        object_id = object_id_from_artwork_url(detail_url) if detail_url else None
        if not detail_url or not object_id:
            continue
        title = sanitized_inline_text(first_capture(fragment, r"<h2[^>]*>([\s\S]*?)</h2>")) or object_id
        category = sanitized_inline_text(
            first_capture(
                fragment,
                r"<span\b[^>]*field--name-field-ref-taxo-work-category[^>]*>([\s\S]*?)</span>",
            )
        )
        summaries.append(
            GuimetArtworkSummary(
                object_id=object_id,
                title=title,
                category=category,
                image_url=image_url(fragment, base_url=base_url),
                detail_url=detail_url,
            )
        )
    return summaries


def parse_detail_html(
    html_text: str,
    *,
    detail_url: str,
    object_id: str | None = None,
) -> GuimetArtworkRecord:
    resolved_object_id = object_id or object_id_from_artwork_url(detail_url)
    if not resolved_object_id:
        raise ValueError(f"Cannot infer Guimet object id from {detail_url}")
    details = parse_info_table(html_text)
    title = (
        sanitized_inline_text(
            first_capture(
                html_text,
                r"<h1\b[^>]*class=[\"'][^\"']*\bartwork-title\b[^\"']*[\"'][^>]*>([\s\S]*?)</h1>",
            )
        )
        or meta_content("og:title", html_text)
        or resolved_object_id
    )
    main_artwork_html = first_capture(
        html_text,
        r"<div\b[^>]*class=[\"'][^\"']*\bmain-artwork\b[^\"']*[\"'][^>]*>([\s\S]*?)</figure>",
    ) or html_text
    primary_image = image_url(main_artwork_html, base_url=GUIMET_BASE_URL) or public_url(
        meta_content("og:image", html_text),
        base_url=GUIMET_BASE_URL,
    )
    object_date = sanitized_inline_text(
        first_capture(html_text, r"<div\b[^>]*field--name-field-text-period[^>]*>([\s\S]*?)</div>")
    )
    return GuimetArtworkRecord(
        object_id=resolved_object_id,
        title=title,
        artwork_description=parse_description(html_text),
        artist_display_name=details.get("作者") or details.get("艺术家"),
        object_date=object_date,
        medium=details.get("材质"),
        dimensions=details.get("尺寸"),
        department=details.get("分类"),
        culture=details.get("地区或地点"),
        primary_image_url=primary_image,
        object_url=detail_url,
        raw_html_excerpt=html_text[:20000],
    )


def parse_info_table(html_text: str) -> dict[str, str]:
    result: dict[str, str] = {}
    cells = matches(html_text, r"<div\b[^>]*class=[\"'][^\"']*\bcell\b[^\"']*[\"'][^>]*>[\s\S]*?</div>")
    for cell in cells:
        label = sanitized_inline_text(
            first_capture(cell, r"<span\b[^>]*class=[\"'][^\"']*\bfield__label\b[^\"']*[\"'][^>]*>([\s\S]*?)</span>")
        )
        value = sanitized_inline_text(
            first_capture(cell, r"<span\b[^>]*class=[\"'][^\"']*\bvalue\b[^\"']*[\"'][^>]*>([\s\S]*?)</span>")
        )
        if label and value:
            result[label] = value
    return result


def parse_description(html_text: str) -> str | None:
    fragments: list[str] = []
    teaser = first_capture(html_text, r"<div\b[^>]*field--name-field-teaser[^>]*>([\s\S]*?)</div>")
    if teaser:
        fragments.append(teaser)

    widgets_match = re.search(r"field--name-field_ref_widgets|field--name-field-ref-widgets", html_text)
    if widgets_match:
        accordion_match = re.search(r"paragraph--type--accordion", html_text[widgets_match.end():])
        if accordion_match:
            widgets_html = html_text[widgets_match.start(): widgets_match.end() + accordion_match.start()]
            fragments.extend(captures(widgets_html, r"<p\b[^>]*>([\s\S]*?)</p>"))

    lines = [line for line in (sanitized_block_text(fragment) for fragment in fragments) if line]
    unique_lines = unique_strings(lines)
    return "\n".join(unique_lines) if unique_lines else None


def store_artwork(
    connection: sqlite3.Connection,
    record: GuimetArtworkRecord,
    *,
    category_id: str | None = None,
) -> int:
    crawled_at = datetime.now(timezone.utc).isoformat()
    connection.execute(
        """
        INSERT INTO artworks(
            museum_id, source_key, object_id, stable_id, title,
            artwork_description_html, artwork_description_text, artist_display_name,
            object_date, medium, dimensions, department, culture, country,
            repository, object_url, source_detail_url, is_on_view, has_image,
            content_hash, source_updated_at, crawled_at, raw_json, extra_json
        )
        VALUES (
            'guimet', 'guimet_web', ?, ?, ?,
            NULL, ?, ?,
            ?, ?, ?, ?, ?, NULL,
            ?, ?, ?, NULL, ?,
            ?, NULL, ?, NULL, ?
        )
        ON CONFLICT(museum_id, source_key, object_id) DO UPDATE SET
            stable_id = excluded.stable_id,
            title = excluded.title,
            artwork_description_text = excluded.artwork_description_text,
            artist_display_name = excluded.artist_display_name,
            object_date = excluded.object_date,
            medium = excluded.medium,
            dimensions = excluded.dimensions,
            department = excluded.department,
            culture = excluded.culture,
            repository = excluded.repository,
            object_url = excluded.object_url,
            source_detail_url = excluded.source_detail_url,
            has_image = excluded.has_image,
            content_hash = excluded.content_hash,
            crawled_at = excluded.crawled_at,
            extra_json = excluded.extra_json
        """,
        (
            record.object_id,
            record.stable_id,
            record.title,
            record.artwork_description,
            record.artist_display_name,
            record.object_date,
            record.medium,
            record.dimensions,
            record.department,
            record.culture,
            GUIMET_REPOSITORY,
            record.object_url,
            record.object_url,
            1 if record.primary_image_url else 0,
            record.content_hash,
            crawled_at,
            json.dumps({"rawHTMLExcerpt": record.raw_html_excerpt}, ensure_ascii=False),
        ),
    )
    row = connection.execute(
        """
        SELECT artwork_pk FROM artworks
        WHERE museum_id = 'guimet' AND source_key = 'guimet_web' AND object_id = ?
        """,
        (record.object_id,),
    ).fetchone()
    if row is None:
        raise RuntimeError(f"Stored Guimet artwork disappeared: {record.object_id}")
    artwork_pk = int(row[0])
    replace_images(connection, artwork_pk, record)
    replace_category_memberships(connection, artwork_pk, category_id)
    return artwork_pk


def replace_images(connection: sqlite3.Connection, artwork_pk: int, record: GuimetArtworkRecord) -> None:
    connection.execute("DELETE FROM artwork_images WHERE artwork_pk = ?", (artwork_pk,))
    if not record.primary_image_url:
        return
    connection.executemany(
        """
        INSERT OR IGNORE INTO artwork_images(artwork_pk, role, url, sort_order)
        VALUES (?, ?, ?, ?)
        """,
        [
            (artwork_pk, "primary", record.primary_image_url, 0),
            (artwork_pk, "thumbnail", record.primary_image_url, 1),
        ],
    )


def replace_category_memberships(connection: sqlite3.Connection, artwork_pk: int, category_id: str | None) -> None:
    connection.execute("DELETE FROM artwork_categories WHERE artwork_pk = ?", (artwork_pk,))
    if not category_id:
        return
    row = connection.execute(
        """
        SELECT category_pk FROM categories
        WHERE museum_id = 'guimet' AND source_key = 'guimet_web' AND category_id = ?
        LIMIT 1
        """,
        (category_id,),
    ).fetchone()
    if row is None:
        return
    connection.execute(
        """
        INSERT OR IGNORE INTO artwork_categories(artwork_pk, category_pk, membership_source)
        VALUES (?, ?, 'crawler')
        """,
        (artwork_pk, int(row[0])),
    )


class GuimetCrawler:
    def __init__(self, policy: GuimetCrawlerPolicy = GuimetCrawlerPolicy()) -> None:
        self.policy = policy
        self.next_allowed_at = 0.0

    def fetch_candidate_ids(self, *, category_id: str | None = None) -> list[str]:
        paths = [COLLECTION_CATEGORY_PATHS[category_id]] if category_id in COLLECTION_CATEGORY_PATHS else list(
            COLLECTION_CATEGORY_PATHS.values()
        )
        object_ids: list[str] = []
        seen: set[str] = set()
        for path in paths:
            payload = self.fetch_url(urljoin(GUIMET_BASE_URL, path))
            summaries = parse_collection_page(payload.decode("utf-8", errors="replace"))
            for summary in summaries:
                if summary.object_id not in seen:
                    seen.add(summary.object_id)
                    object_ids.append(summary.object_id)
        return object_ids

    def fetch_artwork(self, object_id: str) -> GuimetArtworkRecord:
        detail_url = artwork_url_for_object_id(object_id)
        payload = self.fetch_url(detail_url)
        return parse_detail_html(payload.decode("utf-8", errors="replace"), detail_url=detail_url, object_id=object_id)

    def fetch_url(self, url: str) -> bytes:
        self.wait_for_turn()
        request = Request(
            url,
            headers={
                "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
                "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                "Accept-Language": "zh-CN,zh-Hans;q=0.9,en;q=0.8",
            },
        )
        with urlopen(request, timeout=20) as response:
            return response.read()

    def wait_for_turn(self) -> None:
        now = time.monotonic()
        delay = max(0.0, self.next_allowed_at - now)
        self.next_allowed_at = max(now, self.next_allowed_at) + self.policy.request_interval_seconds
        if delay > 0:
            time.sleep(delay)


def crawl_sample_detail(
    *,
    connection: sqlite3.Connection,
    html_path: str,
    detail_url: str | None,
    object_id: str | None = None,
) -> int:
    html_text = open(html_path, "r", encoding="utf-8").read()
    resolved_url = detail_url or (artwork_url_for_object_id(object_id) if object_id else None)
    if not resolved_url:
        raise ValueError("detail_url or object_id is required for Guimet sample detail crawl")
    record = parse_detail_html(html_text, detail_url=resolved_url, object_id=object_id)
    return store_artwork(connection, record)


def object_id_from_artwork_url(url: str | None) -> str | None:
    if not url:
        return None
    path = urlparse(url).path
    if not path.startswith(GUIMET_ARTWORK_PATH_PREFIX):
        return None
    value = path[len(GUIMET_ARTWORK_PATH_PREFIX):].strip("/")
    return value.replace("/", OBJECT_ID_PATH_SEPARATOR) if value else None


def artwork_url_for_object_id(object_id: str | None) -> str:
    if not object_id:
        raise ValueError("object_id is required")
    components = [component for component in object_id.replace("/", OBJECT_ID_PATH_SEPARATOR).split(OBJECT_ID_PATH_SEPARATOR) if component]
    if not components:
        raise ValueError("object_id is empty")
    return f"{GUIMET_BASE_URL}/zh-hans/nos-collections/{'/'.join(components)}"


def image_url(html_text: str, *, base_url: str) -> str | None:
    src = first_capture(html_text, r"<img\b[^>]*\bsrc=[\"']([^\"']+)[\"']") or first_capture(
        html_text,
        r"<source\b[^>]*\bsrcset=[\"']([^\"'\s]+)",
    )
    return public_url(src, base_url=base_url)


def meta_content(name: str, html_text: str) -> str | None:
    return sanitized_inline_text(
        first_capture(
            html_text,
            rf"<meta\b[^>]*(?:property|name)=[\"']{re.escape(name)}[\"'][^>]*content=[\"']([^\"']+)[\"'][^>]*>",
        )
    )


def public_url(raw_value: str | None, *, base_url: str) -> str | None:
    value = clean_text(raw_value)
    if not value:
        return None
    if urlparse(value).scheme:
        return value
    return urljoin(base_url, value)


def sanitized_inline_text(value: str | None) -> str | None:
    block = sanitized_block_text(value)
    if not block:
        return None
    cleaned = " ".join(line.strip() for line in block.splitlines() if line.strip()).strip()
    return cleaned or None


def sanitized_block_text(value: str | None) -> str | None:
    if value is None:
        return None
    text = re.sub(r"(?i)<br\s*/?>", "\n", value)
    text = re.sub(r"(?i)</p>", "\n", text)
    text = re.sub(r"<[^>]+>", "", text)
    decoded = html.unescape(text).replace("\xa0", " ")
    lines = [line.strip() for line in decoded.splitlines() if line.strip()]
    cleaned = "\n".join(lines).strip()
    return cleaned or None


def clean_text(value: str | None) -> str | None:
    if value is None:
        return None
    cleaned = html.unescape(value).replace("\xa0", " ").strip()
    return cleaned or None


def unique_strings(values: list[str]) -> list[str]:
    seen: set[str] = set()
    output: list[str] = []
    for value in values:
        if value not in seen:
            seen.add(value)
            output.append(value)
    return output


def matches(text: str, pattern: str) -> list[str]:
    return [match.group(0) for match in re.finditer(pattern, text, flags=re.IGNORECASE)]


def captures(text: str, pattern: str) -> list[str]:
    return [match.group(1) for match in re.finditer(pattern, text, flags=re.IGNORECASE)]


def first_capture(text: str, pattern: str) -> str | None:
    match = re.search(pattern, text, flags=re.IGNORECASE)
    return match.group(1) if match else None
