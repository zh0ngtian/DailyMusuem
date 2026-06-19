import hashlib
import json
import sqlite3
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from urllib.parse import urlencode
from urllib.request import Request, urlopen


JAPAN_SEARCH_BASE_URL = "https://jpsearch.go.jp/api"
JAPAN_SEARCH_ITEM_URL = f"{JAPAN_SEARCH_BASE_URL}/item"


@dataclass(frozen=True)
class JapanSearchProfile:
    museum_id: str
    source_key: str
    contributor_query: str
    accepted_contributors: frozenset[str]
    provider: str

    @property
    def country_name(self) -> str:
        return "日本"


TOKYO_PROFILE = JapanSearchProfile(
    museum_id="tnm",
    source_key="japan_search",
    contributor_query="東京国立博物館",
    accepted_contributors=frozenset({"東京国立博物館", "Tokyo National Museum"}),
    provider="tnm",
)

NARA_COLBASE_PROFILE = JapanSearchProfile(
    museum_id="nnm",
    source_key="colbase",
    contributor_query="Nara National Museum",
    accepted_contributors=frozenset({"奈良国立博物館", "Nara National Museum"}),
    provider="narahaku",
)

PROFILES = {
    "tnm": TOKYO_PROFILE,
    "nnm-colbase": NARA_COLBASE_PROFILE,
}


FIELD_CATEGORY_FALLBACKS = {
    ("tnm", "刀剣"): "weaponry",
    ("tnm", "武器・武具"): "weaponry",
    ("tnm", "絵画"): "paint",
    ("tnm", "書跡"): "ancdoc",
    ("tnm", "古文書"): "ancdoc",
    ("tnm", "金工"): "metal",
    ("tnm", "金属工芸"): "metal",
    ("tnm", "陶磁"): "ceramic",
    ("tnm", "漆工"): "lacquer",
    ("tnm", "染織"): "daw",
    ("tnm", "彫刻"): "sculpture",
    ("tnm", "建築"): "architecture",
    ("nnm", "考古"): "archeology",
    ("nnm", "書跡"): "ancdoc",
    ("nnm", "古文書"): "ancdoc",
    ("nnm", "絵画"): "paint",
    ("nnm", "工芸"): "craft",
    ("nnm", "彫刻"): "sculpture",
    ("nnm", "陶磁"): "ceramic",
    ("nnm", "金工"): "metal",
    ("nnm", "金属工芸"): "metal",
    ("nnm", "漆工"): "lacquer",
    ("nnm", "刀剣"): "weaponry",
    ("nnm", "染織"): "daw",
}


@dataclass(frozen=True)
class JapanSearchCrawlerPolicy:
    page_size: int = 10
    request_interval_seconds: float = 0.25
    prefer_has_images: bool = True


@dataclass(frozen=True)
class JapanSearchCommon:
    item_id: str
    title: str
    link_url: str | None
    thumbnail_urls: tuple[str, ...]
    content_urls: tuple[str, ...]
    contributor: tuple[str, ...]
    temporal: tuple[str, ...]
    description: str | None
    provider: str | None
    database: str | None


@dataclass(frozen=True)
class JapanSearchArtworkRecord:
    profile: JapanSearchProfile
    item_id: str
    common: JapanSearchCommon
    fields: dict[str, str]
    raw_json: str

    @property
    def stable_id(self) -> str:
        return f"{self.profile.museum_id}-{self.item_id}"

    @property
    def sort_value(self) -> int:
        explicit = self.fields.get("cobas-22-s")
        if explicit is not None:
            try:
                return int(explicit)
            except ValueError:
                pass
        suffix = self.item_id.rsplit("-", 1)[-1]
        try:
            return int(suffix)
        except ValueError:
            return 2**63 - 1

    @property
    def title(self) -> str:
        return self.common.title or self.item_id

    @property
    def artwork_description(self) -> str | None:
        return self.common.description

    @property
    def artist_display_name(self) -> str | None:
        for contributor in self.common.contributor:
            if contributor not in self.profile.accepted_contributors:
                return contributor
        return None

    @property
    def object_date(self) -> str | None:
        return self.fields.get("cobas-11-s") or first(self.common.temporal)

    @property
    def medium(self) -> str | None:
        return self.fields.get("cobas-12-s")

    @property
    def dimensions(self) -> str | None:
        return self.fields.get("cobas-13-s")

    @property
    def department(self) -> str | None:
        return self.fields.get("cobas-4-s")

    @property
    def repository(self) -> str | None:
        repository = self.fields.get("cobas-16-s")
        if repository:
            return repository
        for contributor in self.common.contributor:
            if contributor in self.profile.accepted_contributors:
                return contributor
        return first(self.common.contributor)

    @property
    def primary_image_url(self) -> str | None:
        image_url = first(self.common.content_urls) or first(self.common.thumbnail_urls)
        return high_resolution_image_url(image_url) if image_url else None

    @property
    def primary_image_small_url(self) -> str | None:
        return first(self.common.thumbnail_urls) or first(self.common.content_urls)

    @property
    def object_url(self) -> str | None:
        return self.common.link_url

    @property
    def source_detail_url(self) -> str:
        return item_detail_url(self.item_id)

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
                "repository": self.repository,
                "primary_image_url": self.primary_image_url,
                "primary_image_small_url": self.primary_image_small_url,
                "object_url": self.object_url,
            },
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
        )
        return hashlib.sha256(payload.encode("utf-8")).hexdigest()

    def matches_profile(self) -> bool:
        if any(contributor in self.profile.accepted_contributors for contributor in self.common.contributor):
            return True
        repository = self.fields.get("cobas-16-s")
        if repository in self.profile.accepted_contributors:
            return True
        return self.common.provider == self.profile.provider


@dataclass(frozen=True)
class JapanSearchSearchPage:
    items: tuple[JapanSearchArtworkRecord, ...]
    hit: int
    from_index: int


def parse_item_payload(payload: bytes | str, *, profile: JapanSearchProfile) -> JapanSearchArtworkRecord:
    raw_data = payload.decode("utf-8") if isinstance(payload, bytes) else payload
    data = json.loads(raw_data)
    return record_from_dict(data, profile=profile)


def parse_search_payload(payload: bytes | str, *, profile: JapanSearchProfile) -> JapanSearchSearchPage:
    raw_data = payload.decode("utf-8") if isinstance(payload, bytes) else payload
    data = json.loads(raw_data)
    return JapanSearchSearchPage(
        items=tuple(record_from_dict(item, profile=profile) for item in data.get("list") or []),
        hit=int(data.get("hit") or 0),
        from_index=int(data.get("from") or 0),
    )


def candidate_ids_from_search_payload(
    payload: bytes | str,
    *,
    profile: JapanSearchProfile,
    used_contributor_filter: bool,
) -> list[str]:
    page = parse_search_payload(payload, profile=profile)
    page_items = page.items if used_contributor_filter else tuple(item for item in page.items if item.matches_profile())
    return [item.item_id for item in stable_unique_items(page_items)]


def record_from_dict(data: dict[str, object], *, profile: JapanSearchProfile) -> JapanSearchArtworkRecord:
    common_data = data.get("common")
    if not isinstance(common_data, dict):
        common_data = {}
    item_id = clean_string(data.get("id")) or clean_string(common_data.get("id")) or ""
    fields = {
        key: value.strip()
        for key, value in data.items()
        if key.startswith("cobas-") and isinstance(value, str) and value.strip()
    }
    common = JapanSearchCommon(
        item_id=item_id,
        title=clean_string(common_data.get("title")) or item_id,
        link_url=clean_string(common_data.get("linkUrl")),
        thumbnail_urls=tuple(string_list(common_data.get("thumbnailUrl"))),
        content_urls=tuple(string_list(common_data.get("contentsUrl"))),
        contributor=tuple(string_list(common_data.get("contributor"))),
        temporal=tuple(string_list(common_data.get("temporal"))),
        description=clean_string(common_data.get("description")),
        provider=clean_string(common_data.get("provider")),
        database=clean_string(common_data.get("database")),
    )
    return JapanSearchArtworkRecord(
        profile=profile,
        item_id=item_id,
        common=common,
        fields=fields,
        raw_json=json.dumps(data, ensure_ascii=False, sort_keys=True),
    )


def store_artwork(
    connection: sqlite3.Connection,
    record: JapanSearchArtworkRecord,
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
            ?, ?, ?, ?, ?,
            NULL, ?, ?,
            ?, ?, ?, ?, NULL, ?,
            ?, ?, ?, NULL, ?,
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
            record.profile.museum_id,
            record.profile.source_key,
            record.item_id,
            record.stable_id,
            record.title,
            record.artwork_description,
            record.artist_display_name,
            record.object_date,
            record.medium,
            record.dimensions,
            record.department,
            record.profile.country_name,
            record.repository,
            record.object_url,
            record.source_detail_url,
            1 if record.primary_image_url or record.primary_image_small_url else 0,
            record.content_hash,
            crawled_at,
            record.raw_json,
        ),
    )
    row = connection.execute(
        """
        SELECT artwork_pk FROM artworks
        WHERE museum_id = ? AND source_key = ? AND object_id = ?
        """,
        (record.profile.museum_id, record.profile.source_key, record.item_id),
    ).fetchone()
    if row is None:
        raise RuntimeError(f"Stored Japan Search artwork disappeared: {record.item_id}")
    artwork_pk = int(row[0])
    replace_images(connection, artwork_pk, record)
    replace_category_memberships(connection, artwork_pk, record, category_id=category_id)
    return artwork_pk


def replace_images(connection: sqlite3.Connection, artwork_pk: int, record: JapanSearchArtworkRecord) -> None:
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


def replace_category_memberships(
    connection: sqlite3.Connection,
    artwork_pk: int,
    record: JapanSearchArtworkRecord,
    *,
    category_id: str | None,
) -> None:
    connection.execute("DELETE FROM artwork_categories WHERE artwork_pk = ?", (artwork_pk,))
    resolved_category_id = category_id or FIELD_CATEGORY_FALLBACKS.get(
        (record.profile.museum_id, record.department or "")
    )
    if not resolved_category_id:
        return
    row = connection.execute(
        """
        SELECT category_pk FROM categories
        WHERE museum_id = ? AND source_key = ? AND category_id = ?
        LIMIT 1
        """,
        (record.profile.museum_id, record.profile.source_key, resolved_category_id),
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


class JapanSearchCrawler:
    def __init__(
        self,
        *,
        profile: JapanSearchProfile,
        policy: JapanSearchCrawlerPolicy = JapanSearchCrawlerPolicy(),
    ) -> None:
        self.profile = profile
        self.policy = policy
        self.next_allowed_at = 0.0

    def fetch_candidate_ids(self, *, category_type_code: str | None = None, minimum_count: int | None = 10) -> list[str]:
        item_ids: list[str] = []
        seen: set[str] = set()
        next_from = 0
        has_more = True
        used_contributor_filter = True

        while (minimum_count is None or len(item_ids) < minimum_count) and has_more:
            page = self.fetch_search_page(
                from_index=next_from,
                category_type_code=category_type_code,
                used_contributor_filter=used_contributor_filter,
            )
            if not page.items:
                if used_contributor_filter and not item_ids:
                    used_contributor_filter = False
                    next_from = 0
                    has_more = True
                    continue
                break

            page_items = page.items if used_contributor_filter else tuple(
                item for item in page.items if item.matches_profile()
            )
            for item in stable_unique_items(page_items):
                if item.item_id not in seen:
                    seen.add(item.item_id)
                    item_ids.append(item.item_id)

            next_from += len(page.items)
            has_more = len(page.items) >= self.policy.page_size and next_from < page.hit

        return item_ids

    def fetch_search_page(
        self,
        *,
        from_index: int,
        category_type_code: str | None,
        used_contributor_filter: bool,
    ) -> JapanSearchSearchPage:
        query = {
            "f-db": "cobas",
            "from": str(from_index),
            "size": str(self.policy.page_size),
        }
        if used_contributor_filter:
            query["q-contributor"] = self.profile.contributor_query
        if category_type_code:
            query["f-type"] = category_type_code
        if self.policy.prefer_has_images:
            query["f-contents"] = "image"
        payload = self.fetch_url(f"{JAPAN_SEARCH_BASE_URL}/item/search/jps-cross?{urlencode(query)}")
        return parse_search_payload(payload, profile=self.profile)

    def fetch_item(self, item_id: str) -> JapanSearchArtworkRecord:
        return parse_item_payload(self.fetch_url(item_detail_url(item_id)), profile=self.profile)

    def fetch_url(self, url: str) -> bytes:
        self.wait_for_turn()
        request = Request(
            url,
            headers={
                "User-Agent": "curl/8.7.1",
                "Accept": "application/json, text/plain, */*",
                "Accept-Language": "ja-JP,ja;q=0.9,en-US;q=0.8,zh-CN;q=0.7",
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


def crawl_sample_item(*, connection: sqlite3.Connection, json_path: str, profile: JapanSearchProfile) -> int:
    payload = open(json_path, "r", encoding="utf-8").read()
    record = parse_item_payload(payload, profile=profile)
    return store_artwork(connection, record)


def item_detail_url(item_id: str) -> str:
    return f"{JAPAN_SEARCH_ITEM_URL}/{item_id}"


def high_resolution_image_url(url: str | None) -> str | None:
    if url is None:
        return None
    return (
        url.replace("/slideshow_s/", "/slideshow/")
        .replace("/slideshow_l/", "/slideshow/")
        .replace("/slideshow_m/", "/slideshow/")
    )


def stable_unique_items(items: tuple[JapanSearchArtworkRecord, ...]) -> list[JapanSearchArtworkRecord]:
    seen: set[str] = set()
    output: list[JapanSearchArtworkRecord] = []
    for item in items:
        if item.item_id not in seen:
            seen.add(item.item_id)
            output.append(item)
    return sorted(output, key=lambda item: item.sort_value)


def first(values: tuple[str, ...]) -> str | None:
    return values[0] if values else None


def clean_string(value: object) -> str | None:
    if not isinstance(value, str):
        return None
    trimmed = value.strip()
    return trimmed or None


def string_list(value: object) -> list[str]:
    if isinstance(value, list):
        return [item.strip() for item in value if isinstance(item, str) and item.strip()]
    if isinstance(value, str) and value.strip():
        return [value.strip()]
    return []
