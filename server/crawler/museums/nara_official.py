import hashlib
import html
import json
import re
import sqlite3
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from urllib.parse import urlencode, urljoin, urlparse, urlunparse
from urllib.request import Request, urlopen


NARA_OFFICIAL_BASE_URL = "https://www.narahaku.go.jp/chinese/collection/"
NARA_OFFICIAL_REPOSITORY = "奈良国立博物馆"
NARA_OBJECT_ID_PREFIX = "narahaku-"

OFFICIAL_DEPARTMENT_CATEGORY_IDS = {
    "雕刻": "official-sculpture",
    "绘画": "official-painting",
    "书迹": "official-calligraphy",
    "工艺": "official-craft",
    "考古": "official-archaeology",
    "中国古代青铜器": "official-ancient-chinese-bronze",
    "其他": "official-other",
}

CATEGORY_ID_TO_DEPARTMENT = {value: key for key, value in OFFICIAL_DEPARTMENT_CATEGORY_IDS.items()}


@dataclass(frozen=True)
class NaraOfficialCrawlerPolicy:
    request_interval_seconds: float = 0.25


@dataclass(frozen=True)
class NaraOfficialSearchSummary:
    raw_id: str
    title: str
    summary: str | None
    thumbnail_url: str | None
    detail_url: str

    @property
    def object_id(self) -> str:
        return official_object_id(self.raw_id)


@dataclass(frozen=True)
class NaraOfficialArtworkRecord:
    raw_id: str
    title: str
    artwork_description: str | None
    object_date: str | None
    medium: str | None
    dimensions: str | None
    department: str | None
    country: str | None
    primary_image_url: str | None
    primary_image_small_url: str | None
    object_url: str
    raw_html_excerpt: str

    @property
    def object_id(self) -> str:
        return official_object_id(self.raw_id)

    @property
    def stable_id(self) -> str:
        return f"nnm-{self.object_id}"

    @property
    def content_hash(self) -> str:
        payload = json.dumps(
            {
                "title": self.title,
                "artwork_description": self.artwork_description,
                "object_date": self.object_date,
                "medium": self.medium,
                "dimensions": self.dimensions,
                "department": self.department,
                "country": self.country,
                "primary_image_url": self.primary_image_url,
                "primary_image_small_url": self.primary_image_small_url,
                "object_url": self.object_url,
            },
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        )
        return hashlib.sha256(payload.encode("utf-8")).hexdigest()


@dataclass(frozen=True)
class DescriptionFields:
    medium: str | None
    dimensions: str | None
    place_and_date: str | None


def parse_search_page(html_text: str, *, base_url: str = NARA_OFFICIAL_BASE_URL) -> list[NaraOfficialSearchSummary]:
    summaries: list[NaraOfficialSearchSummary] = []
    for block in matches(html_text, r"<p\b[^>]*data-href=[\"'][^\"']+[\"'][\s\S]*?</p>"):
        href = first_capture(block, r"data-href=[\"']([^\"']+\.html)[\"']")
        if not href:
            continue
        raw_id = href.split(".", 1)[0]
        image_tag = first_capture(block, r"(<img\b[^>]*>)")
        image_url = None
        title = None
        if image_tag:
            image_url = attribute("data-original", image_tag) or attribute("src", image_tag)
            title = clean_text(attribute("alt", image_tag) or "")
        span_html = first_capture(block, r"<span>([\s\S]*?)</span>")
        if not title and span_html:
            title = clean_text(span_html)
        summary = None
        if span_html:
            summary = clean_text(re.sub(r"(?i)\s*<br\s*/?>\s*", " / ", span_html))
        summaries.append(
            NaraOfficialSearchSummary(
                raw_id=raw_id,
                title=title or raw_id,
                summary=summary,
                thumbnail_url=absolute_url(image_url, base_url=base_url) if image_url else None,
                detail_url=absolute_url(href, base_url=base_url) or urljoin(base_url, href),
            )
        )
    return stable_unique_summaries(summaries)


def parse_detail_html(html_text: str, *, raw_id: str, detail_url: str) -> NaraOfficialArtworkRecord:
    title = clean_text(first_capture(html_text, r"<h2>\s*([\s\S]*?)</h2>") or "")
    if not title:
        raise ValueError(f"Cannot parse Nara official title for {raw_id}")

    description_block = first_capture(
        html_text,
        r"<div class=[\"']description[\"'][^>]*>([\s\S]*?)<div class=[\"']btnOperation[\"']",
    ) or ""
    paragraph = first_capture(description_block, r"<p>([\s\S]*?)</p>") or ""
    description_fields = parse_description_fields(lines_from_break_separated_html(paragraph))
    country, object_date = split_place_and_date(description_fields.place_and_date)
    department = parse_table_value("门类", html_text)
    artwork_description = clean_description_text(
        first_capture(html_text, r"<div class=[\"']text[\"']\s+id=[\"']kaisetsu[\"'][^>]*>([\s\S]*?)</div>") or ""
    )
    main_image_tag = first_match(html_text, r"<img\b[^>]*class=[\"']mainPicture[\"'][^>]*>")
    if not main_image_tag:
        main_image_tag = first_match(html_text, rf"<img\b[^>]*data-id=[\"']{re.escape(raw_id)}[\"'][^>]*>")
    primary_raw = None
    small_raw = None
    if main_image_tag:
        primary_raw = (
            attribute("palm", main_image_tag)
            or attribute("data-original", main_image_tag)
            or attribute("src", main_image_tag)
        )
        small_raw = (
            attribute("data-original", main_image_tag)
            or attribute("src", main_image_tag)
            or attribute("palm", main_image_tag)
        )

    return NaraOfficialArtworkRecord(
        raw_id=raw_id,
        title=title,
        artwork_description=artwork_description,
        object_date=object_date,
        medium=description_fields.medium,
        dimensions=description_fields.dimensions,
        department=department,
        country=country,
        primary_image_url=absolute_url(primary_raw, base_url=detail_url) if primary_raw else None,
        primary_image_small_url=absolute_url(small_raw, base_url=detail_url) if small_raw else None,
        object_url=detail_url,
        raw_html_excerpt=html_text[:20000],
    )


def store_artwork(connection: sqlite3.Connection, record: NaraOfficialArtworkRecord) -> int:
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
            'nnm', 'official', ?, ?, ?,
            NULL, ?, NULL,
            ?, ?, ?, ?, NULL, ?,
            ?, ?, ?, NULL, ?,
            ?, NULL, ?, NULL, ?
        )
        ON CONFLICT(museum_id, source_key, object_id) DO UPDATE SET
            stable_id = excluded.stable_id,
            title = excluded.title,
            artwork_description_text = excluded.artwork_description_text,
            object_date = excluded.object_date,
            medium = excluded.medium,
            dimensions = excluded.dimensions,
            department = excluded.department,
            country = excluded.country,
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
            record.object_date,
            record.medium,
            record.dimensions,
            record.department,
            record.country,
            NARA_OFFICIAL_REPOSITORY,
            record.object_url,
            record.object_url,
            1 if record.primary_image_url or record.primary_image_small_url else 0,
            record.content_hash,
            crawled_at,
            json.dumps({"rawHTMLExcerpt": record.raw_html_excerpt}, ensure_ascii=False),
        ),
    )
    row = connection.execute(
        """
        SELECT artwork_pk FROM artworks
        WHERE museum_id = 'nnm' AND source_key = 'official' AND object_id = ?
        """,
        (record.object_id,),
    ).fetchone()
    if row is None:
        raise RuntimeError(f"Stored Nara official artwork disappeared: {record.object_id}")
    artwork_pk = int(row[0])
    replace_images(connection, artwork_pk, record)
    replace_category_memberships(connection, artwork_pk, record.department)
    return artwork_pk


def replace_images(connection: sqlite3.Connection, artwork_pk: int, record: NaraOfficialArtworkRecord) -> None:
    connection.execute("DELETE FROM artwork_images WHERE artwork_pk = ?", (artwork_pk,))
    rows: list[tuple[int, str, str, int]] = []
    if record.primary_image_url:
        rows.append((artwork_pk, "primary", record.primary_image_url, 0))
    if record.primary_image_small_url:
        rows.append((artwork_pk, "thumbnail", record.primary_image_small_url, 1))
    elif record.primary_image_url:
        rows.append((artwork_pk, "thumbnail", record.primary_image_url, 1))
    connection.executemany(
        """
        INSERT OR IGNORE INTO artwork_images(artwork_pk, role, url, sort_order)
        VALUES (?, ?, ?, ?)
        """,
        rows,
    )


def replace_category_memberships(connection: sqlite3.Connection, artwork_pk: int, department: str | None) -> None:
    connection.execute("DELETE FROM artwork_categories WHERE artwork_pk = ?", (artwork_pk,))
    category_id = OFFICIAL_DEPARTMENT_CATEGORY_IDS.get(department or "")
    if not category_id:
        return
    row = connection.execute(
        """
        SELECT category_pk FROM categories
        WHERE museum_id = 'nnm' AND source_key = 'official' AND category_id = ?
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


class NaraOfficialCrawler:
    def __init__(self, policy: NaraOfficialCrawlerPolicy = NaraOfficialCrawlerPolicy()) -> None:
        self.policy = policy
        self.next_allowed_at = 0.0

    def fetch_candidate_ids(self, *, category_id: str | None = None) -> list[str]:
        departments = [CATEGORY_ID_TO_DEPARTMENT[category_id]] if category_id in CATEGORY_ID_TO_DEPARTMENT else list(
            OFFICIAL_DEPARTMENT_CATEGORY_IDS.keys()
        )
        summaries: list[NaraOfficialSearchSummary] = []
        for department in departments:
            payload = self.fetch_url(search_url(department))
            summaries.extend(parse_search_page(payload.decode("utf-8", errors="replace")))
        return [summary.object_id for summary in stable_unique_summaries(summaries)]

    def fetch_artwork(self, object_id: str) -> NaraOfficialArtworkRecord:
        raw_id = raw_object_id(object_id)
        detail_url = detail_page_url(raw_id)
        payload = self.fetch_url(detail_url)
        return parse_detail_html(payload.decode("utf-8", errors="replace"), raw_id=raw_id, detail_url=detail_url)

    def fetch_url(self, url: str) -> bytes:
        self.wait_for_turn()
        request = Request(
            url,
            headers={
                "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
                "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                "Accept-Language": "zh-CN,zh-Hans;q=0.9,ja;q=0.8,en;q=0.7",
                "Cache-Control": "no-cache",
                "Pragma": "no-cache",
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
    raw_id: str,
    detail_url: str | None = None,
) -> int:
    html_text = open(html_path, "r", encoding="utf-8").read()
    resolved_url = detail_url or detail_page_url(raw_id)
    record = parse_detail_html(html_text, raw_id=raw_id, detail_url=resolved_url)
    return store_artwork(connection, record)


def search_url(department: str) -> str:
    return f"{NARA_OFFICIAL_BASE_URL}?{urlencode({'bumon': department, 'img': '1', 'action': 'image_search'})}"


def detail_page_url(raw_id: str) -> str:
    return urljoin(NARA_OFFICIAL_BASE_URL, f"{raw_id}.html")


def official_object_id(raw_id: str) -> str:
    return raw_id if raw_id.startswith(NARA_OBJECT_ID_PREFIX) else f"{NARA_OBJECT_ID_PREFIX}{raw_id}"


def raw_object_id(object_id: str) -> str:
    return object_id.removeprefix(NARA_OBJECT_ID_PREFIX)


def stable_unique_summaries(summaries: list[NaraOfficialSearchSummary]) -> list[NaraOfficialSearchSummary]:
    seen: set[str] = set()
    output: list[NaraOfficialSearchSummary] = []
    for summary in summaries:
        if summary.raw_id not in seen:
            seen.add(summary.raw_id)
            output.append(summary)
    return output


def parse_table_value(label: str, html_text: str) -> str | None:
    return clean_text(
        first_capture(html_text, rf"<th>\s*{re.escape(label)}\s*</th>\s*<td>([\s\S]*?)</td>") or ""
    )


def lines_from_break_separated_html(html_text: str) -> list[str]:
    return [
        line
        for line in (clean_text(fragment) for fragment in re.sub(r"(?i)<br\s*/?>", "\n", html_text).splitlines())
        if line
    ]


def parse_description_fields(lines: list[str]) -> DescriptionFields:
    dimension_index = next((index for index, line in enumerate(lines) if is_dimension_line(line)), None)
    place_and_date_index = None
    if dimension_index is not None:
        place_and_date_index = next(
            (
                index
                for index, line in enumerate(lines)
                if index > dimension_index and not is_dimension_line(line)
            ),
            None,
        )
    if place_and_date_index is None:
        place_and_date_index = next(
            (
                index
                for index, line in enumerate(lines)
                if index != dimension_index and is_place_and_date_line(line)
            ),
            None,
        )
    medium_index = next(
        (
            index
            for index, _ in enumerate(lines)
            if index != dimension_index and index != place_and_date_index
        ),
        None,
    )
    return DescriptionFields(
        medium=lines[medium_index] if medium_index is not None else None,
        dimensions=lines[dimension_index] if dimension_index is not None else None,
        place_and_date=lines[place_and_date_index] if place_and_date_index is not None else None,
    )


def split_place_and_date(value: str | None) -> tuple[str | None, str | None]:
    if not value:
        return None, None
    parts = [part.strip() for part in value.split("　") if part.strip()]
    if not parts:
        return None, value
    if len(parts) == 1:
        return parts[0], value
    return parts[0], " ".join(parts[1:])


def is_dimension_line(line: str) -> bool:
    if not re.search(r"[0-9０-９]", line):
        return False
    return re.search(r"(?i)(cm|mm|㎝|厘米|公分|高|縦|纵|長|长|横|幅|径|厚|奥行|全長|口径|底径)", line) is not None


def is_place_and_date_line(line: str) -> bool:
    return re.search(
        r"(世纪|世紀|公元|时代|時代|王朝|西周|东周|東周|春秋|战国|戰國|秦|汉|漢|魏|晋|隋|唐|宋|元|明|清|飞鸟|飛鳥|奈良|平安|鎌倉|镰仓|室町|桃山|江户|江戸|明治|大正|昭和|平成|令和)",
        line,
    ) is not None


def clean_description_text(html_text: str) -> str | None:
    paragraph_htmls = matches(html_text, r"(?i)<p\b[^>]*>[\s\S]*?</p>")
    source_htmls = paragraph_htmls or [html_text]
    segments: list[str] = []
    for source_html in source_htmls:
        for segment in description_text_segments(source_html):
            if "翻译" in segment:
                continue
            segments.append(removing_text_after_final_chinese_period(segment))
    cleaned = "\n".join(segment for segment in segments if segment).strip()
    return cleaned or None


def description_text_segments(html_text: str) -> list[str]:
    text = re.sub(r"(?i)<br\s*/?>", "\n", html_text)
    text = re.sub(r"<[^>]+>", "", text)
    decoded = html.unescape(text).replace("\xa0", " ")
    return [line.strip() for line in decoded.splitlines() if line.strip()]


def removing_text_after_final_chinese_period(text: str) -> str:
    index = text.rfind("。")
    if index < 0:
        return text.strip()
    return text[: index + 1].strip()


def clean_text(html_text: str) -> str | None:
    text = re.sub(r"(?i)<br\s*/?>", "\n", html_text)
    text = re.sub(r"<[^>]+>", "", text)
    decoded = html.unescape(text).replace("\xa0", " ")
    lines = [line.strip() for line in decoded.splitlines() if line.strip()]
    cleaned = "\n".join(lines).strip()
    return cleaned or None


def absolute_url(raw_value: str | None, *, base_url: str) -> str | None:
    if raw_value is None:
        return None
    trimmed = raw_value.strip()
    if not trimmed:
        return None
    if trimmed.startswith("//"):
        resolved = f"https:{trimmed}"
    else:
        resolved = urljoin(base_url, trimmed)
    parsed = urlparse(resolved)
    if parsed.scheme == "http":
        parsed = parsed._replace(scheme="https")
    return urlunparse(parsed)


def matches(text: str, pattern: str) -> list[str]:
    return [match.group(0) for match in re.finditer(pattern, text, flags=re.IGNORECASE)]


def first_match(text: str, pattern: str) -> str | None:
    match = re.search(pattern, text, flags=re.IGNORECASE)
    return match.group(0) if match else None


def first_capture(text: str, pattern: str) -> str | None:
    match = re.search(pattern, text, flags=re.IGNORECASE)
    return match.group(1) if match else None


def attribute(name: str, tag: str) -> str | None:
    return first_capture(tag, rf"\b{re.escape(name)}=[\"']([^\"']*)[\"']")
