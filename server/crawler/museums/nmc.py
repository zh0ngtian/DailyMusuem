import os
import hashlib
import html as html_lib
import json
import re
import sqlite3
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from urllib.parse import urlencode, urljoin
from urllib.request import Request, urlopen


@dataclass(frozen=True)
class NationalMuseumChinaCrawlPolicy:
    # The list API is the anti-scraping-sensitive part. Use the largest verified
    # page size and the all-category bucket first, then derive categories from
    # detail HTML instead of repeating list calls per category.
    list_api_category_id: int = 0
    list_api_limit: int = int(os.getenv("MUSEUMMUSE_NMC_LIST_LIMIT", "100"))
    max_list_api_calls: int = int(os.getenv("MUSEUMMUSE_NMC_MAX_LIST_API_CALLS", "20"))
    api_interval_seconds: float = 1.0
    web_interval_seconds: float = float(os.getenv("MUSEUMMUSE_NMC_WEB_INTERVAL_SECONDS", "0.2"))
    detail_fetch_mode: str = os.getenv("MUSEUMMUSE_NMC_DETAIL_FETCH_MODE", "web_html")


DEFAULT_POLICY = NationalMuseumChinaCrawlPolicy()


class NationalMuseumChinaApiBudgetExceeded(RuntimeError):
    pass


@dataclass
class NationalMuseumChinaApiBudget:
    max_calls: int
    used_calls: int = 0

    @property
    def remaining_calls(self) -> int:
        return max(0, self.max_calls - self.used_calls)

    def consume(self, *, endpoint: str, page: int | None = None) -> None:
        if self.used_calls >= self.max_calls:
            suffix = f", page={page}" if page is not None else ""
            raise NationalMuseumChinaApiBudgetExceeded(
                f"NMC API budget exhausted before {endpoint}{suffix}; "
                f"max_calls={self.max_calls}."
            )
        self.used_calls += 1


class NationalMuseumChinaURLBuilder:
    base_url = "https://appapi.chnmuseum.cn"
    website_base_url = "https://www.chnmuseum.cn"
    web_catalog_base_url = "https://www.chnmuseum.cn/zp/zpml/"

    @classmethod
    def exhibit_list_url(
        cls,
        *,
        category_id: int,
        page: int,
        limit: int,
    ) -> str:
        query = urlencode(
            {
                "cate_id": category_id,
                "limit": limit,
                "page": page,
                "p": "i",
                "son_cate_id": 0,
            }
        )
        return f"{cls.base_url}/api/exhibit_list?{query}"

    @classmethod
    def share_link_url(cls, *, exhibit_id: int) -> str:
        query = urlencode({"p": "i", "exhibit_id": exhibit_id})
        return f"{cls.base_url}/api/exhibit/share_link?{query}"

    @classmethod
    def web_catalog_url(cls, *, page_index: int = 0) -> str:
        if page_index <= 0:
            return f"{cls.web_catalog_base_url}index.shtml"
        return f"{cls.web_catalog_base_url}index_{page_index}.shtml"


def make_list_budget(policy: NationalMuseumChinaCrawlPolicy = DEFAULT_POLICY) -> NationalMuseumChinaApiBudget:
    return NationalMuseumChinaApiBudget(max_calls=policy.max_list_api_calls)


def planned_list_pages(
    *,
    page_count: int,
    policy: NationalMuseumChinaCrawlPolicy = DEFAULT_POLICY,
) -> range:
    safe_page_count = max(1, page_count)
    capped_page_count = min(safe_page_count, policy.max_list_api_calls)
    return range(1, capped_page_count + 1)


@dataclass(frozen=True)
class NationalMuseumChinaArtworkRecord:
    exhibit_id: int
    title: str
    object_date: str | None
    department: str | None
    dimensions: str | None
    description_html: str | None
    primary_image_url: str | None
    object_url: str
    source_detail_url: str
    raw_json: str

    @property
    def object_id(self) -> str:
        return str(self.exhibit_id)

    @property
    def stable_id(self) -> str:
        return f"nmc-{self.exhibit_id}"

    @property
    def content_hash(self) -> str:
        payload = json.dumps(
            {
                "title": self.title,
                "object_date": self.object_date,
                "department": self.department,
                "dimensions": self.dimensions,
                "description_html": self.description_html,
                "primary_image_url": self.primary_image_url,
                "object_url": self.object_url,
            },
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        )
        return hashlib.sha256(payload.encode("utf-8")).hexdigest()


@dataclass(frozen=True)
class NationalMuseumChinaListSummary:
    exhibit_id: int
    title: str | None
    object_date: str | None
    department: str | None
    dimensions: str | None
    primary_image_url: str | None
    raw_item: dict[str, object]


def parse_detail_html(
    html: str,
    *,
    exhibit_id: int,
    detail_url: str,
    base_url: str = NationalMuseumChinaURLBuilder.base_url,
    list_summary: NationalMuseumChinaListSummary | None = None,
) -> NationalMuseumChinaArtworkRecord:
    brief_html = first_capture(html, r'<div\s+class="content brief">\s*(.*?)\s*</div>') or html
    title = clean_text(first_capture(brief_html, r"<h1>(.*?)</h1>")) or list_summary_title(list_summary)
    if not title:
        raise ValueError(f"Cannot parse NMC title for exhibit_id={exhibit_id}")

    brief_paragraphs = [
        clean_text(value)
        for value in captures(brief_html, r"<p>(.*?)</p>")
    ]
    brief_paragraphs = [value for value in brief_paragraphs if value]

    description_html = strip_empty(first_capture(
        html,
        r'<div\s+class="content detail">\s*<h1>.*?</h1>\s*(.*?)\s*</div>',
    ))
    image_path = strip_empty(first_capture(html, r"<img\s+src=[\"'](.*?)[\"']"))
    primary_image_url = urljoin(base_url, image_path) if image_path else list_summary_image_url(list_summary, base_url)

    raw_json = json.dumps(
        {
            "source": "nmc_html",
            "briefParagraphs": brief_paragraphs,
            "imagePath": image_path,
            "listSummary": list_summary.raw_item if list_summary else None,
        },
        ensure_ascii=False,
        sort_keys=True,
    )
    return NationalMuseumChinaArtworkRecord(
        exhibit_id=exhibit_id,
        title=title,
        object_date=list_get(brief_paragraphs, 0) or list_summary_object_date(list_summary),
        department=list_get(brief_paragraphs, 1) or list_summary_department(list_summary),
        dimensions=list_get(brief_paragraphs, 2) or list_summary_dimensions(list_summary),
        description_html=description_html,
        primary_image_url=primary_image_url,
        object_url=detail_url,
        source_detail_url=detail_url,
        raw_json=raw_json,
    )


def parse_web_detail_html(
    html: str,
    *,
    detail_url: str,
    list_summary: NationalMuseumChinaListSummary | None = None,
) -> NationalMuseumChinaArtworkRecord:
    exhibit_id = web_content_id(html, detail_url)
    title = (
        meta_content(html, "ArticleTitle")
        or clean_text(first_capture(html, r'<div\s+class=["\']cj_ertitlere["\'][^>]*>(.*?)</div>'))
        or clean_text(first_capture(html, r"<title>(.*?)</title>"))
        or list_summary_title(list_summary)
    )
    if not title:
        raise ValueError(f"Cannot parse NMC web title for detail_url={detail_url}")

    params_html = first_capture(html, r'<div\s+class=["\']cj_e_canshu["\'][^>]*>(.*?)</div>')
    params = [clean_text(value) for value in captures(params_html or "", r"<p[^>]*>(.*?)</p>")]
    params = [value for value in params if value]
    description_html = strip_empty(first_capture(html, r'<div\s+class=["\']wwms["\'][^>]*>(.*?)</div>'))
    primary_image_url = first_web_detail_image_url(html, detail_url)

    raw_json = json.dumps(
        {
            "source": "nmc_web_html",
            "contentID": exhibit_id,
            "detailURL": detail_url,
            "pubDate": meta_content(html, "PubDate"),
            "listSummary": list_summary.raw_item if list_summary else None,
        },
        ensure_ascii=False,
        sort_keys=True,
    )
    return NationalMuseumChinaArtworkRecord(
        exhibit_id=exhibit_id,
        title=title,
        object_date=web_object_date(html) or list_summary_object_date(list_summary),
        department=meta_content(html, "ColumnName") or list_summary_department(list_summary),
        dimensions=list_get(params, 0) or list_summary_dimensions(list_summary),
        description_html=description_html,
        primary_image_url=primary_image_url or list_summary_image_url(list_summary, NationalMuseumChinaURLBuilder.website_base_url),
        object_url=detail_url,
        source_detail_url=detail_url,
        raw_json=raw_json,
    )


def exhibit_ids_from_list_payload(payload: bytes | str) -> tuple[list[int], int]:
    summaries, page_count = exhibit_summaries_from_list_payload(payload)
    return [summary.exhibit_id for summary in summaries], page_count


def exhibit_summaries_from_list_payload(payload: bytes | str) -> tuple[list[NationalMuseumChinaListSummary], int]:
    raw_data = payload.decode("utf-8") if isinstance(payload, bytes) else payload
    data = json.loads(raw_data)
    body = data.get("data") or {}
    summaries: list[NationalMuseumChinaListSummary] = []
    for item in body.get("list", []):
        if not isinstance(item, dict) or item.get("exhibit_id") is None:
            continue
        summaries.append(list_summary_from_item(item))
    page_count = int(body.get("page_count") or 1)
    return stable_unique_summaries(summaries), max(1, page_count)


def web_catalog_summaries_from_html(
    html: bytes | str,
    *,
    catalog_url: str = NationalMuseumChinaURLBuilder.web_catalog_base_url,
) -> tuple[list[NationalMuseumChinaListSummary], int, int]:
    html_text = html.decode("utf-8", errors="replace") if isinstance(html, bytes) else html
    page_count = int(first_capture(html_text, r"var\s+countPage\s*=\s*(\d+)") or 1)
    total_count = int(first_capture(html_text, r"var\s+countnum\s*=\s*(\d+)") or 0)
    summaries: list[NationalMuseumChinaListSummary] = []
    seen_urls: set[str] = set()
    for href, body in re.findall(
        r"<a\b[^>]*href=[\"']([^\"']+\.shtml)[\"'][^>]*>(.*?)</a>",
        html_text,
        flags=re.IGNORECASE | re.DOTALL,
    ):
        detail_url = urljoin(catalog_url, href)
        if "/zp/zpml/" not in detail_url or detail_url in seen_urls:
            continue
        seen_urls.add(detail_url)
        content_id = web_content_id_from_url(detail_url)
        if content_id is None:
            continue
        title = clean_text(first_capture(body, r"<p[^>]*>(.*?)</p>")) or clean_text(first_capture(body, r"<img[^>]+alt=[\"']([^\"']+)"))
        image_path = first_capture(body, r"<img[^>]+src=[\"']([^\"']+)")
        summaries.append(
            NationalMuseumChinaListSummary(
                exhibit_id=content_id,
                title=title,
                object_date=None,
                department=None,
                dimensions=None,
                primary_image_url=urljoin(detail_url, image_path) if image_path else None,
                raw_item={
                    "source": "nmc_web_catalog",
                    "detail_url": detail_url,
                    "title": title,
                    "image": image_path,
                },
            )
        )
    return stable_unique_summaries(summaries), max(1, page_count), total_count


def store_artwork(connection: sqlite3.Connection, record: NationalMuseumChinaArtworkRecord) -> int:
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
            'nmc', 'nmc_api', ?, ?, ?,
            ?, ?, NULL,
            ?, NULL, ?, ?, NULL, '中国',
            '中国国家博物馆', ?, ?, NULL, ?,
            ?, NULL, ?, ?, NULL
        )
        ON CONFLICT(museum_id, source_key, object_id) DO UPDATE SET
            stable_id = excluded.stable_id,
            title = excluded.title,
            artwork_description_html = excluded.artwork_description_html,
            artwork_description_text = excluded.artwork_description_text,
            object_date = excluded.object_date,
            dimensions = excluded.dimensions,
            department = excluded.department,
            country = excluded.country,
            repository = excluded.repository,
            object_url = excluded.object_url,
            source_detail_url = excluded.source_detail_url,
            has_image = excluded.has_image,
            content_hash = excluded.content_hash,
            crawled_at = excluded.crawled_at,
            raw_json = excluded.raw_json
        """,
        (
            record.object_id,
            record.stable_id,
            record.title,
            record.description_html,
            description_text(record.description_html),
            record.object_date,
            record.dimensions,
            record.department,
            record.object_url,
            record.source_detail_url,
            1 if record.primary_image_url else 0,
            record.content_hash,
            crawled_at,
            record.raw_json,
        ),
    )
    row = connection.execute(
        """
        SELECT artwork_pk FROM artworks
        WHERE museum_id = 'nmc' AND source_key = 'nmc_api' AND object_id = ?
        """,
        (record.object_id,),
    ).fetchone()
    if row is None:
        raise RuntimeError(f"Stored NMC artwork disappeared: {record.object_id}")
    artwork_pk = int(row[0])
    replace_images(connection, artwork_pk, record.primary_image_url)
    replace_category_memberships(connection, artwork_pk, record.department)
    return artwork_pk


def replace_images(connection: sqlite3.Connection, artwork_pk: int, primary_image_url: str | None) -> None:
    connection.execute("DELETE FROM artwork_images WHERE artwork_pk = ?", (artwork_pk,))
    if not primary_image_url:
        return
    connection.executemany(
        """
        INSERT OR IGNORE INTO artwork_images(artwork_pk, role, url, sort_order)
        VALUES (?, ?, ?, ?)
        """,
        [
            (artwork_pk, "primary", primary_image_url, 0),
            (artwork_pk, "thumbnail", primary_image_url, 1),
        ],
    )


def replace_category_memberships(connection: sqlite3.Connection, artwork_pk: int, department: str | None) -> None:
    connection.execute("DELETE FROM artwork_categories WHERE artwork_pk = ?", (artwork_pk,))
    if not department:
        return
    row = connection.execute(
        """
        SELECT category_pk FROM categories
        WHERE museum_id = 'nmc' AND source_key = 'nmc_api' AND display_name = ?
        LIMIT 1
        """,
        (department,),
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


class NationalMuseumChinaCrawler:
    def __init__(self, policy: NationalMuseumChinaCrawlPolicy = DEFAULT_POLICY) -> None:
        self.policy = policy
        self.list_budget = make_list_budget(policy)
        self.next_allowed_at = 0.0
        self.next_web_allowed_at = 0.0

    def fetch_candidate_ids(self, *, minimum_count: int | None = None) -> list[int]:
        return [summary.exhibit_id for summary in self.fetch_candidate_summaries(minimum_count=minimum_count)]

    def fetch_candidate_summaries(self, *, minimum_count: int | None = None) -> list[NationalMuseumChinaListSummary]:
        page = 1
        page_count = 1
        collected_summaries: list[NationalMuseumChinaListSummary] = []
        while page <= page_count and self.list_budget.remaining_calls > 0:
            payload = self.fetch_list_page(page=page)
            summaries, page_count = exhibit_summaries_from_list_payload(payload)
            collected_summaries.extend(summaries)
            if minimum_count is not None and len(stable_unique_summaries(collected_summaries)) >= minimum_count:
                break
            page += 1
        return stable_unique_summaries(collected_summaries)

    def fetch_web_candidate_summaries(
        self,
        *,
        minimum_count: int | None = None,
        progress_label: str | None = None,
    ) -> list[NationalMuseumChinaListSummary]:
        first_url = NationalMuseumChinaURLBuilder.web_catalog_url(page_index=0)
        first_payload = self.fetch_web_url(first_url)
        first_summaries, page_count, total_count = web_catalog_summaries_from_html(first_payload, catalog_url=first_url)
        collected_summaries = list(first_summaries)
        if progress_label:
            print(f"{progress_label} collected={len(stable_unique_summaries(collected_summaries))}/{total_count} pages=1/{page_count}", flush=True)
        if minimum_count is not None and len(stable_unique_summaries(collected_summaries)) >= minimum_count:
            return stable_unique_summaries(collected_summaries)
        for page_index in range(1, page_count):
            page_url = NationalMuseumChinaURLBuilder.web_catalog_url(page_index=page_index)
            payload = self.fetch_web_url(page_url)
            summaries, _, _ = web_catalog_summaries_from_html(payload, catalog_url=page_url)
            collected_summaries.extend(summaries)
            unique_summaries = stable_unique_summaries(collected_summaries)
            if progress_label and (page_index + 1 == page_count or (page_index + 1) % 10 == 0):
                print(
                    f"{progress_label} collected={len(unique_summaries)}/{total_count} pages={page_index + 1}/{page_count}",
                    flush=True,
                )
            if minimum_count is not None and len(unique_summaries) >= minimum_count:
                return unique_summaries
        return stable_unique_summaries(collected_summaries)

    def fetch_list_page(self, *, page: int) -> bytes:
        self.list_budget.consume(endpoint="exhibit_list", page=page)
        url = NationalMuseumChinaURLBuilder.exhibit_list_url(
            category_id=self.policy.list_api_category_id,
            page=page,
            limit=self.policy.list_api_limit,
        )
        return self.fetch_url(url, accept="application/json, text/plain, */*")

    def fetch_detail_html(self, *, exhibit_id: int) -> tuple[str, str]:
        if self.policy.detail_fetch_mode != "share_link_api":
            raise RuntimeError(
                "NMC detail web URL is not configured for live crawl. "
                "Use --sample-detail-html for offline validation, or set "
                "MUSEUMMUSE_NMC_DETAIL_FETCH_MODE=share_link_api explicitly."
            )
        self.list_budget.consume(endpoint="share_link", page=None)
        url = NationalMuseumChinaURLBuilder.share_link_url(exhibit_id=exhibit_id)
        payload = self.fetch_url(url, accept="text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8")
        return payload.decode("utf-8", errors="replace"), url

    def fetch_web_detail_html(self, *, detail_url: str) -> tuple[str, str]:
        payload = self.fetch_web_url(detail_url)
        return payload.decode("utf-8", errors="replace"), detail_url

    def fetch_url(self, url: str, *, accept: str) -> bytes:
        self.wait_for_turn()
        request = Request(
            url,
            headers={
                "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
                "Accept": accept,
                "Accept-Language": "zh-CN,zh-Hans;q=0.9,en;q=0.8",
            },
        )
        with urlopen(request, timeout=20) as response:
            return response.read()

    def fetch_web_url(self, url: str) -> bytes:
        self.wait_for_web_turn()
        request = Request(
            url,
            headers={
                "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                "Accept-Language": "zh-CN,zh-Hans;q=0.9,en;q=0.8",
            },
        )
        with urlopen(request, timeout=20) as response:
            return response.read()

    def wait_for_turn(self) -> None:
        now = time.monotonic()
        delay = max(0.0, self.next_allowed_at - now)
        self.next_allowed_at = max(now, self.next_allowed_at) + self.policy.api_interval_seconds
        if delay > 0:
            time.sleep(delay)

    def wait_for_web_turn(self) -> None:
        now = time.monotonic()
        delay = max(0.0, self.next_web_allowed_at - now)
        self.next_web_allowed_at = max(now, self.next_web_allowed_at) + self.policy.web_interval_seconds
        if delay > 0:
            time.sleep(delay)


def crawl_sample_detail(
    *,
    connection: sqlite3.Connection,
    html_path: str,
    exhibit_id: int,
    detail_url: str | None = None,
) -> int:
    html = open(html_path, "r", encoding="utf-8").read()
    resolved_detail_url = detail_url or NationalMuseumChinaURLBuilder.share_link_url(exhibit_id=exhibit_id)
    record = parse_detail_html(html, exhibit_id=exhibit_id, detail_url=resolved_detail_url)
    return store_artwork(connection, record)


def clean_text(value: str | None) -> str | None:
    if value is None:
        return None
    without_tags = re.sub(r"<[^>]+>", "", value)
    decoded = html_lib.unescape(without_tags)
    return strip_empty(decoded)


def meta_content(html: str, name: str) -> str | None:
    value = first_capture(
        html,
        rf"<meta\b(?=[^>]*\bname=[\"']{re.escape(name)}[\"'])(?=[^>]*\bcontent=[\"'](.*?)[\"'])[^>]*>",
    )
    return clean_text(value)


def web_content_id(html: str, detail_url: str) -> int:
    content_id = meta_content(html, "contentid")
    if content_id and content_id.isdigit():
        return int(content_id)
    url_content_id = web_content_id_from_url(detail_url)
    if url_content_id is not None:
        return url_content_id
    raise ValueError(f"Cannot parse NMC web content id for detail_url={detail_url}")


def web_content_id_from_url(detail_url: str) -> int | None:
    value = first_capture(detail_url, r"t\d+_(\d+)\.shtml(?:$|\?)")
    return int(value) if value and value.isdigit() else None


def web_object_date(html: str) -> str | None:
    script_value = first_capture(html, r"var\s+content2\s*=\s*['\"](.*?)['\"]")
    if script_value:
        return clean_text(script_value.replace(";", " · "))
    comment_value = first_capture(html, r"</head>\s*<!--\s*(.*?)\s*-->")
    if comment_value:
        return clean_text(comment_value.replace(";", " · "))
    return None


def first_web_detail_image_url(html: str, detail_url: str) -> str | None:
    body = first_capture(html, r'<div\s+class=["\']cj_dycp_lef["\'][^>]*>(.*?)</div>\s*<dl\s+class=["\']cj_dycp_rig["\']')
    search_area = body or html
    for pattern in [
        r"<a\b[^>]*data-src=[\"']([^\"']+)[\"']",
        r"<img\b[^>]*\bid=[\"']img[\"'][^>]*src=[\"']([^\"']+)[\"']",
        r"<img\b[^>]*src=[\"']([^\"']+)[\"']",
    ]:
        for path in captures(search_area, pattern):
            if is_ignorable_web_image(path):
                continue
            return urljoin(detail_url, html_lib.unescape(path))
    return None


def is_ignorable_web_image(path: str) -> bool:
    lowered = path.lower()
    return any(
        marker in lowered
        for marker in [
            "/images/header",
            "/images/search",
            "/images/download",
            "/images/cj_close",
            "/images/cp2021_",
            "/images/wx",
            "/images/ft_",
            "/images/blue.png",
        ]
    )


def description_text(value: str | None) -> str | None:
    if value is None:
        return None
    text = re.sub(r"(?i)<br\s*/?>", "\n", value)
    text = re.sub(r"(?i)</p>", "\n\n", text)
    text = re.sub(r"(?i)<p[^>]*>", "", text)
    text = re.sub(r"<[^>]+>", "", text)
    lines = [html_lib.unescape(line).strip() for line in text.splitlines()]
    cleaned = "\n".join(line for line in lines if line)
    return strip_empty(re.sub(r"\n{3,}", "\n\n", cleaned))


def first_capture(text: str, pattern: str) -> str | None:
    values = captures(text, pattern)
    return values[0] if values else None


def captures(text: str, pattern: str) -> list[str]:
    return re.findall(pattern, text, flags=re.IGNORECASE | re.DOTALL)


def strip_empty(value: str | None) -> str | None:
    if value is None:
        return None
    trimmed = value.strip()
    return trimmed or None


def list_get(values: list[str], index: int) -> str | None:
    return values[index] if 0 <= index < len(values) else None


def list_summary_from_item(item: dict[str, object]) -> NationalMuseumChinaListSummary:
    return NationalMuseumChinaListSummary(
        exhibit_id=int(item["exhibit_id"]),
        title=first_text_value(
            item,
            [
                "title",
                "name",
                "exhibit_name",
                "exhibit_title",
                "title_name",
                "artifact_name",
                "cultural_relic_name",
            ],
        ),
        object_date=first_text_value(
            item,
            [
                "object_date",
                "date",
                "age",
                "era",
                "period",
                "dynasty",
                "years",
                "exhibit_time",
                "time",
            ],
        ),
        department=first_text_value(
            item,
            [
                "department",
                "category",
                "category_name",
                "cate_name",
                "type",
                "type_name",
                "class_name",
                "son_cate_name",
            ],
        ),
        dimensions=first_text_value(
            item,
            [
                "dimensions",
                "dimension",
                "size",
                "spec",
                "specification",
                "measure",
                "measurement",
            ],
        ),
        primary_image_url=first_text_value(
            item,
            [
                "primary_image_url",
                "image_url",
                "img_url",
                "pic_url",
                "thumb_url",
                "cover_url",
                "image",
                "img",
                "pic",
                "thumb",
                "cover",
            ],
        ),
        raw_item=item,
    )


def first_text_value(item: dict[str, object], keys: list[str]) -> str | None:
    normalized = {key.lower(): value for key, value in item.items()}
    for key in keys:
        value = normalized.get(key.lower())
        if isinstance(value, str):
            cleaned = strip_empty(html_lib.unescape(value))
            if cleaned:
                return cleaned
        elif isinstance(value, (int, float)):
            return str(value)
    return None


def list_summary_title(summary: NationalMuseumChinaListSummary | None) -> str | None:
    return summary.title if summary else None


def list_summary_object_date(summary: NationalMuseumChinaListSummary | None) -> str | None:
    return summary.object_date if summary else None


def list_summary_department(summary: NationalMuseumChinaListSummary | None) -> str | None:
    return summary.department if summary else None


def list_summary_dimensions(summary: NationalMuseumChinaListSummary | None) -> str | None:
    return summary.dimensions if summary else None


def list_summary_image_url(summary: NationalMuseumChinaListSummary | None, base_url: str) -> str | None:
    if summary is None or summary.primary_image_url is None:
        return None
    return urljoin(base_url, summary.primary_image_url)


def stable_unique_ints(values: list[int]) -> list[int]:
    seen: set[int] = set()
    output: list[int] = []
    for value in values:
        if value not in seen:
            seen.add(value)
            output.append(value)
    return output


def stable_unique_summaries(
    values: list[NationalMuseumChinaListSummary],
) -> list[NationalMuseumChinaListSummary]:
    seen: set[int] = set()
    output: list[NationalMuseumChinaListSummary] = []
    for value in values:
        if value.exhibit_id not in seen:
            seen.add(value.exhibit_id)
            output.append(value)
    return output
