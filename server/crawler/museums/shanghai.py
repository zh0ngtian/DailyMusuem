import hashlib
import html
import json
import re
import sqlite3
import threading
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from urllib.parse import urljoin
from urllib.request import Request, urlopen


SHANGHAI_BASE_URL = "https://www.shanghaimuseum.net/mu/"
SHANGHAI_REPOSITORY = "上海博物馆"
SHANGHAI_COUNTRY = "中国"


@dataclass(frozen=True)
class ShanghaiCrawlerPolicy:
    page_size: int = 10
    request_interval_seconds: float = 1.0
    max_request_attempts: int = 3


@dataclass(frozen=True)
class ShanghaiImageURLs:
    primary_image_url: str | None
    primary_image_small_url: str | None


@dataclass(frozen=True)
class ShanghaiArtworkRecord:
    object_code: str
    title: str
    artwork_description: str | None
    artist_display_name: str | None
    object_date: str | None
    medium: str | None
    dimensions: str | None
    department: str | None
    culture: str | None
    primary_image_url: str | None
    primary_image_small_url: str | None
    object_url: str
    raw_json: str | None
    raw_html_excerpt: str | None

    @property
    def stable_id(self) -> str:
        return f"shm-{self.object_code}"

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
                "primary_image_small_url": self.primary_image_small_url,
                "object_url": self.object_url,
            },
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        )
        return hashlib.sha256(payload.encode("utf-8")).hexdigest()

    def with_images(self, image_urls: ShanghaiImageURLs) -> "ShanghaiArtworkRecord":
        return ShanghaiArtworkRecord(
            object_code=self.object_code,
            title=self.title,
            artwork_description=self.artwork_description,
            artist_display_name=self.artist_display_name,
            object_date=self.object_date,
            medium=self.medium,
            dimensions=self.dimensions,
            department=self.department,
            culture=self.culture,
            primary_image_url=image_urls.primary_image_url,
            primary_image_small_url=image_urls.primary_image_small_url,
            object_url=self.object_url,
            raw_json=self.raw_json,
            raw_html_excerpt=self.raw_html_excerpt,
        )


def parse_search_payload(payload: bytes | str, *, base_url: str = SHANGHAI_BASE_URL) -> tuple[list[str], list[ShanghaiArtworkRecord], int]:
    raw_data = payload.decode("utf-8") if isinstance(payload, bytes) else payload
    data = json.loads(raw_data)
    if int(data.get("code") or 0) != 0:
        raise ValueError(data.get("msg") or "Shanghai search API returned non-zero code")
    records: list[ShanghaiArtworkRecord] = []
    codes: list[str] = []
    seen: set[str] = set()
    for item in data.get("data") or []:
        if not isinstance(item, dict):
            continue
        code = clean_text(item.get("code"))
        if not code or code in seen:
            continue
        seen.add(code)
        codes.append(code)
        records.append(record_from_search_item(item, base_url=base_url))
    return codes, records, int(data.get("count") or len(codes))


def record_from_search_item(item: dict[str, object], *, base_url: str = SHANGHAI_BASE_URL) -> ShanghaiArtworkRecord:
    code = clean_text(item.get("code")) or ""
    catalog_values = parse_catalog(item.get("catalog") if isinstance(item.get("catalog"), str) else None)
    primary_image_url = (
        absolute_url(clean_text(item.get("picPath")), base_url=base_url)
        or absolute_url(clean_text(item.get("picPath2")), base_url=base_url)
        or absolute_url(clean_text(item.get("thumbnailPath")), base_url=base_url)
    )
    primary_image_small_url = (
        absolute_url(clean_text(item.get("thumbnailPath")), base_url=base_url)
        or absolute_url(clean_text(item.get("picPath2")), base_url=base_url)
        or absolute_url(clean_text(item.get("picPath")), base_url=base_url)
    )
    return ShanghaiArtworkRecord(
        object_code=code,
        title=clean_text(item.get("name")) or code,
        artwork_description=clean_text(item.get("description")),
        artist_display_name=catalog_values.get("作者"),
        object_date=make_date(
            era=entry_item_name(item.get("age")),
            detailed_date=catalog_values.get("纪年"),
        ),
        medium=catalog_values.get("材质"),
        dimensions=catalog_values.get("尺寸"),
        department=department_name(
            entry_item_name(item.get("antiqueType1")),
            entry_item_name(item.get("antiqueType2")),
        ),
        culture=catalog_values.get("产地"),
        primary_image_url=primary_image_url,
        primary_image_small_url=primary_image_small_url,
        object_url=article_url(code),
        raw_json=json.dumps(item, ensure_ascii=False, sort_keys=True),
        raw_html_excerpt=None,
    )


def parse_article_html(
    html_text: str,
    *,
    object_code: str,
    object_url: str | None = None,
    base_url: str = SHANGHAI_BASE_URL,
) -> ShanghaiArtworkRecord:
    title = parse_article_title(html_text)
    if not title:
        raise ValueError(f"Cannot parse Shanghai article title for {object_code}")
    rows = parse_article_rows(html_text)
    description_html = clean_text(
        first_capture(html_text, r"<div\s+class=[\"']subtitle[\"']>简介</div>\s*((?:<p.*?</p>\s*)+)")
    )
    return ShanghaiArtworkRecord(
        object_code=object_code,
        title=title,
        artwork_description=description_html,
        artist_display_name=article_row_text(rows, "作者"),
        object_date=make_date(
            era=article_row_text(rows, "时代"),
            detailed_date=article_row_text(rows, "详细年代"),
        ),
        medium=article_row_text(rows, "材质"),
        dimensions=article_row_text(rows, "尺寸", separator="；"),
        department=article_row_text(rows, "类别", separator=" / "),
        culture=article_row_text(rows, "产地"),
        primary_image_url=None,
        primary_image_small_url=None,
        object_url=object_url or article_url(object_code, base_url=base_url),
        raw_json=None,
        raw_html_excerpt=html_text[:20000],
    )


def parse_image_html(html_text: str, *, base_url: str = SHANGHAI_BASE_URL) -> ShanghaiImageURLs:
    primary = absolute_url(first_capture(html_text, r"<figure[^>]*data-src=[\"'](.*?)[\"']"), base_url=base_url)
    small = absolute_url(first_capture(html_text, r"<img\s+src=[\"'](.*?)[\"']"), base_url=base_url)
    if not primary and not small:
        raise ValueError("Cannot parse Shanghai image page")
    return ShanghaiImageURLs(
        primary_image_url=primary or small,
        primary_image_small_url=small or primary,
    )


def parse_article_title(html_text: str) -> str | None:
    title_html = first_capture(html_text, r"<div\s+class=[\"']title[\"']>\s*(.*?)\s*</div>")
    if not title_html:
        return None
    title_html = re.sub(r"<script\b.*?</script>", "", title_html, flags=re.IGNORECASE | re.DOTALL)
    title_html = re.sub(r"<a\b.*?</a>", "", title_html, flags=re.IGNORECASE | re.DOTALL)
    return html_decoded_text(title_html)


def store_artwork(
    connection: sqlite3.Connection,
    record: ShanghaiArtworkRecord,
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
            'shm', 'shm_web', ?, ?, ?,
            ?, NULL, ?,
            ?, ?, ?, ?, ?, ?,
            ?, ?, ?, NULL, ?,
            ?, NULL, ?, ?, ?
        )
        ON CONFLICT(museum_id, source_key, object_id) DO UPDATE SET
            stable_id = excluded.stable_id,
            title = excluded.title,
            artwork_description_html = excluded.artwork_description_html,
            artist_display_name = excluded.artist_display_name,
            object_date = excluded.object_date,
            medium = excluded.medium,
            dimensions = excluded.dimensions,
            department = excluded.department,
            culture = excluded.culture,
            country = excluded.country,
            repository = excluded.repository,
            object_url = excluded.object_url,
            source_detail_url = excluded.source_detail_url,
            has_image = excluded.has_image,
            content_hash = excluded.content_hash,
            crawled_at = excluded.crawled_at,
            raw_json = excluded.raw_json,
            extra_json = excluded.extra_json
        """,
        (
            record.object_code,
            record.stable_id,
            record.title,
            record.artwork_description,
            record.artist_display_name,
            record.object_date,
            record.medium,
            record.dimensions,
            record.department,
            record.culture,
            SHANGHAI_COUNTRY,
            SHANGHAI_REPOSITORY,
            record.object_url,
            record.object_url,
            1 if record.primary_image_url or record.primary_image_small_url else 0,
            record.content_hash,
            crawled_at,
            record.raw_json,
            json.dumps({"rawHTMLExcerpt": record.raw_html_excerpt}, ensure_ascii=False) if record.raw_html_excerpt else None,
        ),
    )
    row = connection.execute(
        """
        SELECT artwork_pk FROM artworks
        WHERE museum_id = 'shm' AND source_key = 'shm_web' AND object_id = ?
        """,
        (record.object_code,),
    ).fetchone()
    if row is None:
        raise RuntimeError(f"Stored Shanghai artwork disappeared: {record.object_code}")
    artwork_pk = int(row[0])
    replace_images(connection, artwork_pk, record)
    replace_category_memberships(connection, artwork_pk, category_id)
    return artwork_pk


def replace_images(connection: sqlite3.Connection, artwork_pk: int, record: ShanghaiArtworkRecord) -> None:
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


def replace_category_memberships(connection: sqlite3.Connection, artwork_pk: int, category_id: str | None) -> None:
    connection.execute("DELETE FROM artwork_categories WHERE artwork_pk = ?", (artwork_pk,))
    if not category_id:
        return
    row = connection.execute(
        """
        SELECT category_pk FROM categories
        WHERE museum_id = 'shm' AND source_key = 'shm_web' AND category_id = ?
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


class ShanghaiCrawler:
    def __init__(self, policy: ShanghaiCrawlerPolicy = ShanghaiCrawlerPolicy()) -> None:
        self.policy = policy
        self.next_allowed_at = 0.0
        self.turn_lock = threading.Lock()

    def fetch_candidate_codes(
        self,
        *,
        subtype: str | None = None,
        minimum_count: int | None = 10,
        progress_label: str | None = None,
        progress_interval: int = 25,
    ) -> list[str]:
        codes: list[str] = []
        seen: set[str] = set()
        page = 1
        has_more = True
        while (minimum_count is None or len(codes) < minimum_count) and has_more:
            if progress_label and (page == 1 or page % progress_interval == 0):
                print(f"{progress_label} fetching page={page} collected={len(codes)}", flush=True)
            payload = self.fetch_search_page(page=page, subtype=subtype)
            page_codes, _, total_count = parse_search_payload(payload)
            for code in page_codes:
                if code not in seen:
                    seen.add(code)
                    codes.append(code)
            has_more = bool(page_codes) and page * self.policy.page_size < total_count
            if progress_label and (page == 1 or page % progress_interval == 0 or not has_more):
                print(
                    f"{progress_label} collected={len(codes)}/{total_count} pages={page}",
                    flush=True,
                )
            page += 1
        return codes

    def fetch_artwork(self, object_code: str) -> ShanghaiArtworkRecord:
        article_payload = self.fetch_url(article_url(object_code))
        record = parse_article_html(
            article_payload.decode("utf-8", errors="replace"),
            object_code=object_code,
            object_url=article_url(object_code),
        )
        try:
            image_payload = self.fetch_url(image_url(object_code))
            return record.with_images(parse_image_html(image_payload.decode("utf-8", errors="replace")))
        except Exception:
            return record

    def fetch_search_page(self, *, page: int, subtype: str | None) -> bytes:
        payload = {
            "params": {
                "langCode": "CHINESE",
                "antiqueSourceCode": "ANTIQUE_SOURCE_1",
                "esFlag": True,
                "ai0": "1",
                "ai1": "1",
                "keywords": None,
                "types": None,
                "ages": None,
                "year": None,
                "place": None,
                "author": None,
                "matter": None,
                "shape": None,
                "style": None,
                "subject": None,
                "subtype": subtype,
                "tech": None,
                "objectFlag": None,
                "videoFlag": None,
                "stampFlag": None,
                "prefaceFlag": None,
                "donateFlag": None,
                "unearthFlag": None,
            },
            "page": page,
            "limit": self.policy.page_size,
        }
        body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        return self.fetch_url(
            search_url(),
            method="POST",
            body=body,
            headers={
                "Content-Type": "application/json",
                "Accept": "application/json, text/plain, */*",
                "Referer": collection_url(),
            },
        )

    def fetch_url(
        self,
        url: str,
        *,
        method: str = "GET",
        body: bytes | None = None,
        headers: dict[str, str] | None = None,
    ) -> bytes:
        last_error: Exception | None = None
        for attempt in range(max(1, self.policy.max_request_attempts)):
            self.wait_for_turn()
            request_headers = {
                "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
                "Accept-Language": "zh-CN,zh-Hans;q=0.9,en;q=0.8",
                "Cache-Control": "no-cache",
                "Pragma": "no-cache",
            }
            request_headers.update(headers or {"Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"})
            request = Request(url, data=body, headers=request_headers, method=method)
            try:
                with urlopen(request, timeout=20) as response:
                    return response.read()
            except Exception as exc:  # noqa: BLE001
                last_error = exc
                if attempt + 1 >= max(1, self.policy.max_request_attempts):
                    raise
                time.sleep(self.policy.request_interval_seconds)
        raise RuntimeError(f"Shanghai request failed without an exception: {url}") from last_error

    def wait_for_turn(self) -> None:
        with self.turn_lock:
            now = time.monotonic()
            delay = max(0.0, self.next_allowed_at - now)
            self.next_allowed_at = max(now, self.next_allowed_at) + self.policy.request_interval_seconds
        if delay > 0:
            time.sleep(delay)


def crawl_sample_detail(
    *,
    connection: sqlite3.Connection,
    article_html_path: str,
    object_code: str,
    image_html_path: str | None = None,
    category_id: str | None = None,
) -> int:
    article_html = open(article_html_path, "r", encoding="utf-8").read()
    record = parse_article_html(article_html, object_code=object_code)
    if image_html_path:
        image_html = open(image_html_path, "r", encoding="utf-8").read()
        record = record.with_images(parse_image_html(image_html))
    return store_artwork(connection, record, category_id=category_id)


def parse_article_rows(html_text: str) -> dict[str, list[str]]:
    rows: dict[str, list[str]] = {}
    for match in re.finditer(
        r"<li>\s*<div\s+class=[\"']left[\"']>(.*?)：</div>\s*<ul\s+class=[\"']site-list right[\"']>\s*(.*?)\s*</ul>\s*</li>",
        html_text,
        flags=re.IGNORECASE | re.DOTALL,
    ):
        label = html_decoded_text(match.group(1))
        values = [html_decoded_text(value) for value in captures(match.group(2), r"<li>(.*?)</li>")]
        values = [value for value in values if value]
        if label and values:
            rows[label] = values
    return rows


def article_row_text(rows: dict[str, list[str]], key: str, *, separator: str = " / ") -> str | None:
    values = rows.get(key) or []
    return separator.join(values) if values else None


def parse_catalog(catalog_html: str | None) -> dict[str, str]:
    if not catalog_html:
        return {}
    values: dict[str, str] = {}
    for match in re.finditer(
        r"<tr[^>]*>\s*<td[^>]*>(.*?)</td>\s*<td[^>]*>(.*?)</td>\s*</tr>",
        catalog_html,
        flags=re.IGNORECASE | re.DOTALL,
    ):
        key = html_decoded_text(match.group(1))
        value = html_decoded_text(match.group(2))
        if key and value:
            values[key] = value
    return values


def parse_image_payload_or_none(html_text: str) -> ShanghaiImageURLs | None:
    try:
        return parse_image_html(html_text)
    except ValueError:
        return None


def make_date(*, era: str | None, detailed_date: str | None) -> str | None:
    cleaned_era = clean_text(era)
    cleaned_detailed = clean_text(detailed_date)
    if cleaned_era and cleaned_detailed and cleaned_era != cleaned_detailed:
        return f"{cleaned_era} · {cleaned_detailed}"
    return cleaned_detailed or cleaned_era


def department_name(primary: str | None, secondary: str | None) -> str | None:
    values = [value for value in (clean_text(primary), clean_text(secondary)) if value]
    return " / ".join(values) if values else None


def entry_item_name(value: object) -> str | None:
    if isinstance(value, dict):
        return clean_text(value.get("entryItemName"))
    return None


def search_url() -> str:
    return urljoin(SHANGHAI_BASE_URL, "frontend/pg/collection/search-antique")


def collection_url() -> str:
    return urljoin(SHANGHAI_BASE_URL, "frontend/pg/collection/antique")


def article_url(object_code: str, *, base_url: str = SHANGHAI_BASE_URL) -> str:
    return urljoin(base_url, f"frontend/pg/article/id/{object_code}")


def image_url(object_code: str, *, base_url: str = SHANGHAI_BASE_URL) -> str:
    return urljoin(base_url, f"frontend/pg/article/aid/{object_code}")


def absolute_url(path: str | None, *, base_url: str = SHANGHAI_BASE_URL) -> str | None:
    value = clean_text(path)
    if not value:
        return None
    return urljoin(base_url, value)


def html_decoded_text(value: str | None) -> str | None:
    if value is None:
        return None
    text = re.sub(r"<[^>]+>", "", value)
    return clean_text(html.unescape(text))


def clean_text(value: object) -> str | None:
    if not isinstance(value, str):
        return None
    cleaned = value.replace("\xa0", " ").strip()
    return cleaned or None


def captures(text: str, pattern: str) -> list[str]:
    return [match.group(1) for match in re.finditer(pattern, text, flags=re.IGNORECASE | re.DOTALL)]


def first_capture(text: str, pattern: str) -> str | None:
    match = re.search(pattern, text, flags=re.IGNORECASE | re.DOTALL)
    return match.group(1) if match else None
