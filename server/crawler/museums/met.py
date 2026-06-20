import hashlib
import html
import json
import re
import sqlite3
import threading
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from urllib.parse import urlencode, urlparse, urlunparse
from urllib.request import Request, urlopen


MET_BASE_URL = "https://collectionapi.metmuseum.org/public/collection/v1"

DEPARTMENT_NAME_TO_CATEGORY_ID = {
    "The American Wing": "american-decorative-arts",
    "Ancient Near Eastern Art": "ancient-west-asian-art",
    "Arms and Armor": "arms-and-armor",
    "Arts of Africa, Oceania, and the Americas": "africa-oceania-americas",
    "Asian Art": "asian-art",
    "The Cloisters": "the-cloisters",
    "The Costume Institute": "costume-institute",
    "Drawings and Prints": "drawings-and-prints",
    "Egyptian Art": "egyptian-art",
    "European Paintings": "european-paintings",
    "European Sculpture and Decorative Arts": "european-sculpture-and-decorative-arts",
    "Greek and Roman Art": "greek-and-roman-art",
    "Islamic Art": "islamic-art",
    "The Robert Lehman Collection": "robert-lehman-collection",
    "The Libraries": "libraries",
    "Medieval Art": "medieval-art",
    "Musical Instruments": "musical-instruments",
    "Photographs": "photographs",
    "Modern and Contemporary Art": "modern-art",
}


@dataclass(frozen=True)
class MetCrawlerPolicy:
    request_interval_seconds: float = 0.25
    search_query: str = "*"
    max_details: int = 0


@dataclass(frozen=True)
class MetArtworkRecord:
    object_id: int
    title: str
    artist_display_name: str | None
    object_date: str | None
    medium: str | None
    dimensions: str | None
    department: str | None
    culture: str | None
    country: str | None
    repository: str | None
    artwork_description: str | None
    primary_image_url: str | None
    primary_image_small_url: str | None
    object_url: str | None
    is_on_view: bool | None
    raw_json: str

    @property
    def stable_id(self) -> str:
        return f"met-{self.object_id}"

    @property
    def content_hash(self) -> str:
        payload = json.dumps(
            {
                "title": self.title,
                "artist_display_name": self.artist_display_name,
                "object_date": self.object_date,
                "medium": self.medium,
                "dimensions": self.dimensions,
                "department": self.department,
                "culture": self.culture,
                "country": self.country,
                "repository": self.repository,
                "artwork_description": self.artwork_description,
                "primary_image_url": self.primary_image_url,
                "primary_image_small_url": self.primary_image_small_url,
                "object_url": self.object_url,
                "is_on_view": self.is_on_view,
            },
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        )
        return hashlib.sha256(payload.encode("utf-8")).hexdigest()

    def with_description(self, description: str | None) -> "MetArtworkRecord":
        return MetArtworkRecord(
            object_id=self.object_id,
            title=self.title,
            artist_display_name=self.artist_display_name,
            object_date=self.object_date,
            medium=self.medium,
            dimensions=self.dimensions,
            department=self.department,
            culture=self.culture,
            country=self.country,
            repository=self.repository,
            artwork_description=description,
            primary_image_url=self.primary_image_url,
            primary_image_small_url=self.primary_image_small_url,
            object_url=self.object_url,
            is_on_view=self.is_on_view,
            raw_json=self.raw_json,
        )


def parse_object_payload(payload: bytes | str) -> MetArtworkRecord:
    raw_data = payload.decode("utf-8") if isinstance(payload, bytes) else payload
    data = json.loads(raw_data)
    object_id = int(data["objectID"])
    title = clean_string(data.get("title")) or f"Met Object {object_id}"
    return MetArtworkRecord(
        object_id=object_id,
        title=title,
        artist_display_name=clean_string(data.get("artistDisplayName")),
        object_date=clean_string(data.get("objectDate")),
        medium=clean_string(data.get("medium")),
        dimensions=clean_string(data.get("dimensions")),
        department=clean_string(data.get("department")),
        culture=clean_string(data.get("culture")),
        country=clean_string(data.get("country")),
        repository=clean_string(data.get("repository")),
        artwork_description=None,
        primary_image_url=clean_string(data.get("primaryImage")),
        primary_image_small_url=clean_string(data.get("primaryImageSmall")),
        object_url=clean_string(data.get("objectURL")),
        is_on_view=parse_is_on_view(data),
        raw_json=json.dumps(data, ensure_ascii=False, sort_keys=True),
    )


def parse_is_on_view(data: dict) -> bool | None:
    if isinstance(data.get("isOnView"), bool):
        return bool(data["isOnView"])
    gallery_number = clean_string(data.get("GalleryNumber"))
    if gallery_number:
        return True
    return None


def object_ids_from_search_payload(payload: bytes | str) -> list[int]:
    raw_data = payload.decode("utf-8") if isinstance(payload, bytes) else payload
    data = json.loads(raw_data)
    return stable_unique_ints([int(value) for value in data.get("objectIDs") or []])


def store_artwork(connection: sqlite3.Connection, record: MetArtworkRecord) -> int:
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
            'met', 'met_all', ?, ?, ?,
            NULL, ?, ?,
            ?, ?, ?, ?, ?, ?,
            ?, ?, ?, ?, ?,
            ?, NULL, ?, ?, NULL
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
            country = excluded.country,
            repository = excluded.repository,
            object_url = excluded.object_url,
            source_detail_url = excluded.source_detail_url,
            is_on_view = excluded.is_on_view,
            has_image = excluded.has_image,
            content_hash = excluded.content_hash,
            crawled_at = excluded.crawled_at,
            raw_json = excluded.raw_json
        """,
        (
            str(record.object_id),
            record.stable_id,
            record.title,
            record.artwork_description,
            record.artist_display_name,
            record.object_date,
            record.medium,
            record.dimensions,
            record.department,
            record.culture,
            record.country,
            record.repository,
            record.object_url,
            object_detail_url(record.object_id),
            1 if record.is_on_view else 0 if record.is_on_view is False else None,
            1 if record.primary_image_url or record.primary_image_small_url else 0,
            record.content_hash,
            crawled_at,
            record.raw_json,
        ),
    )
    row = connection.execute(
        """
        SELECT artwork_pk FROM artworks
        WHERE museum_id = 'met' AND source_key = 'met_all' AND object_id = ?
        """,
        (str(record.object_id),),
    ).fetchone()
    if row is None:
        raise RuntimeError(f"Stored Met artwork disappeared: {record.object_id}")
    artwork_pk = int(row[0])
    replace_images(connection, artwork_pk, record)
    replace_category_memberships(connection, artwork_pk, record.department)
    return artwork_pk


def replace_images(connection: sqlite3.Connection, artwork_pk: int, record: MetArtworkRecord) -> None:
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
    category_id = DEPARTMENT_NAME_TO_CATEGORY_ID.get(department or "")
    if not category_id:
        return
    row = connection.execute(
        """
        SELECT category_pk FROM categories
        WHERE museum_id = 'met' AND source_key = 'met_all' AND category_id = ?
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


class MetCrawler:
    def __init__(self, policy: MetCrawlerPolicy = MetCrawlerPolicy()) -> None:
        self.policy = policy
        self.next_allowed_at = 0.0
        self.turn_lock = threading.Lock()

    def fetch_candidate_ids(self, *, department_id: int | None = None, only_on_view: bool = False) -> list[int]:
        query = {
            "q": self.policy.search_query,
            "hasImages": "true",
        }
        if department_id is not None:
            query["departmentId"] = str(department_id)
        if only_on_view:
            query["isOnView"] = "true"
        payload = self.fetch_url(f"{MET_BASE_URL}/search?{urlencode(query)}")
        return object_ids_from_search_payload(payload)

    def fetch_object(self, object_id: int) -> MetArtworkRecord:
        return parse_object_payload(self.fetch_url(object_detail_url(object_id)))

    def fetch_web_description(self, object_url: str | None) -> str | None:
        for candidate_url in web_description_candidate_urls(object_url):
            try:
                description = extract_web_description(self.fetch_url(candidate_url).decode("utf-8", errors="replace"))
            except Exception:
                description = None
            if description:
                return description
        return None

    def fetch_url(self, url: str) -> bytes:
        self.wait_for_turn()
        if "metmuseum.org" in urlparse(url).netloc:
            headers = {
                "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                "Accept-Language": "zh-CN,zh-Hans;q=0.9,en;q=0.8",
                "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
            }
        else:
            headers = {"Accept": "application/json"}
        request = Request(url, headers=headers)
        with urlopen(request, timeout=20) as response:
            return response.read()

    def wait_for_turn(self) -> None:
        with self.turn_lock:
            now = time.monotonic()
            delay = max(0.0, self.next_allowed_at - now)
            self.next_allowed_at = max(now, self.next_allowed_at) + self.policy.request_interval_seconds
        if delay > 0:
            time.sleep(delay)


def crawl_sample_object(
    *,
    connection: sqlite3.Connection,
    json_path: str,
    web_html_path: str | None = None,
) -> int:
    payload = open(json_path, "r", encoding="utf-8").read()
    record = parse_object_payload(payload)
    if web_html_path:
        description = extract_web_description(open(web_html_path, "r", encoding="utf-8").read())
        record = record.with_description(description)
    return store_artwork(connection, record)


def object_detail_url(object_id: int) -> str:
    return f"{MET_BASE_URL}/objects/{object_id}"


def web_description_candidate_urls(object_url: str | None) -> list[str]:
    if not object_url:
        return []
    parsed = urlparse(object_url)
    english_prefix = "/art/collection/search/"
    chinese_prefix = "/zh/art/collection/search/"
    if parsed.path.startswith(chinese_prefix):
        suffix = parsed.path[len(chinese_prefix):]
        english = parsed._replace(path=f"{english_prefix}{suffix}")
        return [object_url, urlunparse(english)]
    if parsed.path.startswith(english_prefix):
        suffix = parsed.path[len(english_prefix):]
        chinese = parsed._replace(path=f"{chinese_prefix}{suffix}")
        return [urlunparse(chinese), object_url]
    return [object_url]


def extract_web_description(html_text: str) -> str | None:
    rendered_html = rendered_object_html(html_text)
    overview_html = extract_object_overview_html(rendered_html)
    if overview_html:
        cleaned = sanitize_html_fragment(overview_html)
        if cleaned:
            return cleaned

    lead_description = extract_object_lead_description(rendered_html)
    if lead_description:
        return lead_description

    for pattern in [
        r"<meta[^>]*name=[\"']description[\"'][^>]*content=[\"']([^\"']+)[\"'][^>]*>",
        r"<meta[^>]*property=[\"']og:description[\"'][^>]*content=[\"']([^\"']+)[\"'][^>]*>",
    ]:
        value = first_capture(html_text, pattern)
        if value:
            cleaned = html.unescape(value).strip()
            if cleaned:
                return cleaned
    return None


def rendered_object_html(html_text: str) -> str:
    body_start = html_text.lower().find("<body")
    start = body_start if body_start >= 0 else 0
    next_f_markers = [
        "(self.__next_f=self.__next_f||[]).push([0])",
        "self.__next_f.push([1,",
    ]
    end = len(html_text)
    for marker in next_f_markers:
        marker_index = html_text.find(marker, start)
        if marker_index >= 0:
            end = min(end, marker_index)
    body_slice = html_text[start:end]
    main_match = re.search(r"<main\b[\s\S]*?</main>", body_slice, flags=re.IGNORECASE)
    return main_match.group(0) if main_match else body_slice


def extract_object_overview_html(html_text: str) -> str | None:
    for pattern in [
        r"<div\b[^>]*class\s*=\s*[\"'][^\"']*object-overview-module-scss-module__[^\"']*__label[^\"']*[\"'][^>]*>",
        r"<div\b[^>]*class\s*=\s*[\"'][^\"']*object-overview[^\"']*label[^\"']*[\"'][^>]*>",
    ]:
        match = re.search(pattern, html_text, flags=re.IGNORECASE)
        if match:
            extracted = extract_div_element_html(html_text, match.start())
            if extracted:
                return extracted
    return None


def extract_div_element_html(html_text: str, start: int) -> str | None:
    source = html_text[start:]
    if not source.lower().startswith("<div"):
        return None
    depth = 0
    for match in re.finditer(r"<\s*/?\s*div\b[^>]*>", source, flags=re.IGNORECASE):
        tag = match.group(0).lower()
        if tag.startswith("</") or tag.startswith("< /"):
            depth -= 1
            if depth == 0:
                return source[: match.end()]
        else:
            depth += 1
    return None


def extract_object_lead_description(html_text: str) -> str | None:
    title_match = re.search(r"</h1>", html_text, flags=re.IGNORECASE)
    content = html_text[title_match.end():] if title_match else html_text
    end_indices = [
        index for index in [
            lower_find(content, "Artwork Details"),
            lower_find(content, "<h2"),
        ]
        if index >= 0
    ]
    lead_html = content[: min(end_indices)] if end_indices else content
    lines = [line.strip() for line in sanitize_html_fragment(lead_html).splitlines() if line.strip()]
    for line in lines:
        if len(line) >= 80 and re.search(r"[.!?。！？]", line) and "image:" not in line.lower():
            return line
    return None


def sanitize_html_fragment(html_fragment: str) -> str:
    text = re.sub(r"(?i)<br\s*/?>", "\n", html_fragment)
    text = re.sub(r"(?i)</p\s*>", "\n\n", text)
    text = re.sub(r"(?i)</h[1-6]\s*>", "\n", text)
    text = re.sub(r"(?i)</li\s*>", "\n", text)
    text = re.sub(r"(?i)<p[^>]*>", "", text)
    text = re.sub(r"(?i)</div\s*>", "\n", text)
    text = re.sub(r"<[^>]+>", "", text)
    lines = [clean_description_line(html.unescape(line)) for line in text.splitlines()]
    return "\n".join(line for line in lines if line).strip()


def clean_description_line(line: str) -> str:
    cleaned = line.strip()
    cleaned = re.sub(r'^\[\s*"?\s*', "", cleaned)
    cleaned = re.sub(r'\s*"?\s*\]$', "", cleaned)
    cleaned = re.sub(r"^\[\]$", "", cleaned)
    cleaned = re.sub(r'^[\[\]",\s]+$', "", cleaned)
    cleaned = re.sub(r"^->\s*", "", cleaned)
    cleaned = re.sub(r"^>+\s*", "", cleaned)
    return cleaned.strip()


def clean_string(value: object) -> str | None:
    if not isinstance(value, str):
        return None
    trimmed = value.strip()
    return trimmed or None


def first_capture(text: str, pattern: str) -> str | None:
    match = re.search(pattern, text, flags=re.IGNORECASE)
    return match.group(1) if match else None


def lower_find(text: str, needle: str) -> int:
    return text.lower().find(needle.lower())


def stable_unique_ints(values: list[int]) -> list[int]:
    seen: set[int] = set()
    output: list[int] = []
    for value in values:
        if value not in seen:
            seen.add(value)
            output.append(value)
    return output
