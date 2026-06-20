import base64
import hashlib
import json
import os
import sqlite3
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .models import (
    ArtworkDTO,
    CursorPayload,
    MuseumCapabilitiesDTO,
    MuseumCategoryDTO,
    MuseumDTO,
    MuseumIconDTO,
    MuseumMetadataCategoryDTO,
    MuseumMetadataDTO,
    MuseumMetadataDataDTO,
    MuseumSourceDTO,
    WaterfallImageFetchPolicyDTO,
)


DEFAULT_DB_PATH = Path("server/data/museummuse.sqlite")


class MuseumDatabaseError(Exception):
    pass


@dataclass(frozen=True)
class SourceResolution:
    source_key: str
    artwork_source_key: str
    list_filter: dict[str, Any]


class MuseumDatabase:
    def __init__(self, db_path: str | os.PathLike[str] | None = None) -> None:
        self.db_path = Path(db_path or os.getenv("MUSEUMMUSE_DB_PATH", DEFAULT_DB_PATH))

    def connect(self) -> sqlite3.Connection:
        if not self.db_path.exists():
            raise MuseumDatabaseError(f"SQLite database does not exist: {self.db_path}")
        uri = f"file:{self.db_path}?mode=ro"
        connection = sqlite3.connect(uri, uri=True, check_same_thread=False)
        connection.row_factory = sqlite3.Row
        connection.execute("PRAGMA query_only = ON")
        connection.execute("PRAGMA foreign_keys = ON")
        connection.execute("PRAGMA temp_store = MEMORY")
        return connection

    def data_version(self) -> str:
        for manifest_path in self.manifest_paths():
            if not manifest_path.exists():
                continue
            try:
                manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
                build_id = str(manifest.get("build_id", "")).strip()
                if build_id:
                    return build_id
            except (OSError, json.JSONDecodeError):
                pass

        try:
            with self.connect() as connection:
                row = connection.execute(
                    "SELECT finished_at FROM crawl_runs WHERE finished_at IS NOT NULL ORDER BY finished_at DESC LIMIT 1"
                ).fetchone()
                if row and row["finished_at"]:
                    return str(row["finished_at"])
        except (sqlite3.Error, MuseumDatabaseError):
            pass

        return "unknown"

    def manifest_paths(self) -> list[Path]:
        if self.db_path.name == "museummuse.sqlite":
            return [self.db_path.with_name("manifest.json")]
        return [
            self.db_path.with_name(f"{self.db_path.stem}.manifest.json"),
            self.db_path.with_name("manifest.json"),
        ]

    def health(self) -> bool:
        try:
            with self.connect() as connection:
                connection.execute("SELECT 1").fetchone()
            return True
        except (sqlite3.Error, MuseumDatabaseError):
            return False

    def museums(self) -> list[MuseumDTO]:
        with self.connect() as connection:
            rows = connection.execute(
                """
                SELECT museum_id, display_name, country, city, subtitle, supports_widget_content
                FROM museums
                ORDER BY sort_order, museum_id
                """
            ).fetchall()
        return [
            MuseumDTO(
                museumID=row["museum_id"],
                displayName=row["display_name"],
                country=row["country"],
                city=row["city"],
                subtitle=row["subtitle"],
                supportsWidgetContent=bool(row["supports_widget_content"]),
            )
            for row in rows
        ]

    def museum_metadata(self) -> MuseumMetadataDataDTO:
        with self.connect() as connection:
            museum_rows = connection.execute(
                """
                SELECT
                    m.museum_id,
                    m.display_name,
                    m.country,
                    m.city,
                    m.subtitle,
                    m.address,
                    m.text_punctuation_style,
                    m.icon_url,
                    m.icon_asset_name,
                    m.icon_background_color,
                    m.supports_translation,
                    m.supports_widget_content,
                    m.supports_favorites,
                    m.sort_order,
                    p.waterfall_image_qps
                FROM museums m
                LEFT JOIN museum_client_policies p ON p.museum_id = m.museum_id
                ORDER BY m.sort_order, m.museum_id
                """
            ).fetchall()
            source_rows = connection.execute(
                """
                SELECT
                    museum_id,
                    source_key,
                    display_name,
                    is_default,
                    artwork_source_key,
                    list_filter_json,
                    translation_source_language,
                    preferred_image_url_order_json,
                    image_request_headers_json
                FROM data_sources
                ORDER BY museum_id, is_default DESC, source_key
                """
            ).fetchall()
            category_rows = connection.execute(
                """
                SELECT museum_id, source_key, category_id, display_name, sort_order
                FROM categories
                ORDER BY museum_id, source_key, sort_order, category_id
                """
            ).fetchall()
        sources_by_museum: dict[str, list[MuseumSourceDTO]] = {}
        source_rows_by_museum: dict[str, list[sqlite3.Row]] = {}
        default_source_by_museum: dict[str, str] = {}
        for row in source_rows:
            museum_id = row["museum_id"]
            source = MuseumSourceDTO(
                sourceKey=row["source_key"],
                displayName=row["display_name"],
                isDefault=bool(row["is_default"]),
                translationSourceLanguage=row["translation_source_language"],
                preferredImageURLOrder=self.parse_string_list(row["preferred_image_url_order_json"]),
                imageRequestHeaders=self.parse_string_dict(row["image_request_headers_json"]),
            )
            sources_by_museum.setdefault(museum_id, []).append(source)
            source_rows_by_museum.setdefault(museum_id, []).append(row)
            if museum_id not in default_source_by_museum or source.isDefault:
                default_source_by_museum[museum_id] = source.sourceKey

        categories_by_museum: dict[str, list[MuseumMetadataCategoryDTO]] = {}
        for row in category_rows:
            museum_id = row["museum_id"]
            visible_sources = source_rows_by_museum.get(museum_id, [])
            metadata_source_keys = [
                source["source_key"]
                for source in visible_sources
                if (source["artwork_source_key"] or source["source_key"]) == row["source_key"]
            ] or [row["source_key"]]
            for source_key in metadata_source_keys:
                categories_by_museum.setdefault(museum_id, []).append(
                    MuseumMetadataCategoryDTO(
                        sourceKey=source_key,
                        categoryID=row["category_id"],
                        displayName=row["display_name"],
                        sortOrder=int(row["sort_order"]),
                    )
                )

        museums = [
            MuseumMetadataDTO(
                museumID=row["museum_id"],
                displayName=row["display_name"],
                subtitle=row["subtitle"],
                country=row["country"],
                city=row["city"],
                address=row["address"],
                textPunctuationStyle=row["text_punctuation_style"],
                icon=MuseumIconDTO(
                    url=row["icon_url"],
                    assetName=row["icon_asset_name"],
                    backgroundColor=row["icon_background_color"],
                ),
                sortOrder=int(row["sort_order"]),
                capabilities=MuseumCapabilitiesDTO(
                    supportsWidgetContent=bool(row["supports_widget_content"]),
                    supportsTranslation=bool(row["supports_translation"]),
                    supportsFavorites=bool(row["supports_favorites"]),
                ),
                defaultSourceKey=default_source_by_museum.get(row["museum_id"], ""),
                sources=sources_by_museum.get(row["museum_id"], []),
                categories=categories_by_museum.get(row["museum_id"], []),
                waterfallImageFetchPolicy=WaterfallImageFetchPolicyDTO(qps=row["waterfall_image_qps"]),
            )
            for row in museum_rows
        ]
        return MuseumMetadataDataDTO(museums=museums)

    @staticmethod
    def parse_json_value(raw_value: str | None) -> Any:
        if raw_value is None:
            return None
        try:
            return json.loads(raw_value)
        except json.JSONDecodeError:
            return raw_value

    @staticmethod
    def parse_string_list(raw_value: str | None) -> list[str]:
        parsed = MuseumDatabase.parse_json_value(raw_value)
        if not isinstance(parsed, list):
            return []
        return [str(value) for value in parsed if str(value)]

    @staticmethod
    def parse_string_dict(raw_value: str | None) -> dict[str, str]:
        parsed = MuseumDatabase.parse_json_value(raw_value)
        if not isinstance(parsed, dict):
            return {}
        return {
            str(key): str(value)
            for key, value in parsed.items()
            if str(key) and str(value)
        }

    @staticmethod
    def parse_string_key_dict(raw_value: str | None) -> dict[str, Any]:
        parsed = MuseumDatabase.parse_json_value(raw_value)
        if not isinstance(parsed, dict):
            return {}
        return {str(key): value for key, value in parsed.items() if str(key)}

    def categories(self, museum_id: str, source: str | None) -> list[MuseumCategoryDTO]:
        source_resolution = self.resolve_source(museum_id, source)
        source_key = source_resolution.artwork_source_key
        with self.connect() as connection:
            rows = connection.execute(
                """
                SELECT museum_id, category_id, display_name
                FROM categories
                WHERE museum_id = ? AND source_key = ?
                ORDER BY sort_order, category_id
                """,
                (museum_id, source_key),
            ).fetchall()
        return [
            MuseumCategoryDTO(
                museumID=row["museum_id"],
                id=row["category_id"],
                displayName=row["display_name"],
            )
            for row in rows
        ]

    def artwork(self, museum_id: str, object_id: str, source: str | None) -> ArtworkDTO | None:
        source_key = self.resolve_detail_source_key(museum_id, object_id, source)
        with self.connect() as connection:
            row = connection.execute(
                """
                SELECT *
                FROM artworks
                WHERE museum_id = ? AND source_key = ? AND object_id = ?
                LIMIT 1
                """,
                (museum_id, source_key, object_id),
            ).fetchone()
            if not row:
                return None
            images = self.images_for_artworks(connection, [row["artwork_pk"]])
        return self.artwork_dto(row, images.get(row["artwork_pk"], {}))

    def artworks(
        self,
        museum_id: str,
        source: str | None,
        category_ids: list[str],
        limit: int,
        cursor: str | None,
        order: str,
        seed: int | None,
        has_image: bool,
    ) -> tuple[list[ArtworkDTO], str | None, bool]:
        source_resolution = self.resolve_source(museum_id, source)
        source_key = source_resolution.artwork_source_key
        effective_only_on_view = bool(source_resolution.list_filter.get("only_on_view"))
        limit = min(max(limit, 1), 50)
        filter_hash = self.filter_hash(
            museum_id=museum_id,
            source_key=source_resolution.source_key,
            artwork_source_key=source_key,
            category_ids=category_ids,
            order=order,
            seed=seed,
            only_on_view=effective_only_on_view,
            has_image=has_image,
        )
        offset = self.decode_cursor(cursor, filter_hash).offset if cursor else 0
        params: list[Any] = [museum_id, source_key]
        where = ["a.museum_id = ?", "a.source_key = ?"]
        joins = []

        if has_image:
            where.append("a.has_image = 1")
        if effective_only_on_view:
            where.append("a.is_on_view = 1")
        if category_ids:
            joins.append(
                """
                JOIN artwork_categories ac ON ac.artwork_pk = a.artwork_pk
                JOIN categories c ON c.category_pk = ac.category_pk
                """
            )
            placeholders = ", ".join(["?"] * len(category_ids))
            where.append(f"c.category_id IN ({placeholders})")
            params.extend(category_ids)

        if order == "random":
            effective_seed = int(seed or 1)
            order_sql = f"((a.artwork_pk * 1103515245 + {effective_seed}) & 2147483647), a.artwork_pk"
        else:
            order_sql = "a.object_id, a.artwork_pk"

        sql = f"""
            SELECT DISTINCT a.*
            FROM artworks a
            {' '.join(joins)}
            WHERE {' AND '.join(where)}
            ORDER BY {order_sql}
            LIMIT ? OFFSET ?
        """
        params.extend([limit + 1, offset])

        with self.connect() as connection:
            rows = connection.execute(sql, params).fetchall()
            page_rows = rows[:limit]
            images = self.images_for_artworks(connection, [row["artwork_pk"] for row in page_rows])

        has_more = len(rows) > limit
        next_cursor = None
        if has_more:
            next_cursor = self.encode_cursor(
                CursorPayload(
                    offset=offset + limit,
                    order=order,
                    seed=seed,
                    filterHash=filter_hash,
                )
            )
        return [self.artwork_dto(row, images.get(row["artwork_pk"], {})) for row in page_rows], next_cursor, has_more

    def resolve_source(self, museum_id: str, source: str | None) -> SourceResolution:
        with self.connect() as connection:
            row = connection.execute(
                """
                SELECT source_key, artwork_source_key, list_filter_json
                FROM data_sources
                WHERE museum_id = ?
                  AND (? IS NULL OR source_key = ?)
                ORDER BY is_default DESC, source_key
                LIMIT 1
                """,
                (museum_id, source, source),
            ).fetchone()
        if not row:
            raise MuseumDatabaseError(f"Unknown source for museum={museum_id}: {source or 'default'}")
        source_key = str(row["source_key"])
        artwork_source_key = row["artwork_source_key"] or source_key
        return SourceResolution(
            source_key=source_key,
            artwork_source_key=str(artwork_source_key),
            list_filter=self.parse_string_key_dict(row["list_filter_json"]),
        )

    def resolve_source_key(self, museum_id: str, source: str | None) -> str:
        return self.resolve_source(museum_id, source).artwork_source_key

    def resolve_detail_source_key(self, museum_id: str, object_id: str, source: str | None) -> str:
        if source is None:
            with self.connect() as connection:
                rows = connection.execute(
                    """
                    SELECT source_key
                    FROM artworks
                    WHERE museum_id = ? AND object_id = ?
                    ORDER BY source_key
                    LIMIT 2
                    """,
                    (museum_id, object_id),
                ).fetchall()
            if len(rows) == 1:
                return str(rows[0]["source_key"])
        return self.resolve_source_key(museum_id, source)

    def images_for_artworks(self, connection: sqlite3.Connection, artwork_pks: list[int]) -> dict[int, dict[str, str]]:
        if not artwork_pks:
            return {}
        placeholders = ", ".join(["?"] * len(artwork_pks))
        rows = connection.execute(
            f"""
            SELECT artwork_pk, role, url
            FROM artwork_images
            WHERE artwork_pk IN ({placeholders})
            ORDER BY sort_order, image_pk
            """,
            artwork_pks,
        ).fetchall()
        images: dict[int, dict[str, str]] = {}
        for row in rows:
            per_artwork = images.setdefault(int(row["artwork_pk"]), {})
            role = str(row["role"])
            if role == "primary" and "primary" not in per_artwork:
                per_artwork["primary"] = str(row["url"])
            elif role == "thumbnail" and "thumbnail" not in per_artwork:
                per_artwork["thumbnail"] = str(row["url"])
        return images

    def artwork_dto(self, row: sqlite3.Row, images: dict[str, str]) -> ArtworkDTO:
        return ArtworkDTO(
            id=row["stable_id"],
            museumID=row["museum_id"],
            sourceKey=row["source_key"],
            objectID=row["object_id"],
            title=row["title"],
            artworkDescription=row["artwork_description_html"] or row["artwork_description_text"],
            artistDisplayName=row["artist_display_name"],
            objectDate=row["object_date"],
            medium=row["medium"],
            dimensions=row["dimensions"],
            department=row["department"],
            culture=row["culture"],
            country=row["country"],
            repository=row["repository"],
            primaryImageURL=images.get("primary"),
            primaryImageSmallURL=images.get("thumbnail") or images.get("primary"),
            objectURL=row["object_url"],
        )

    @staticmethod
    def filter_hash(**values: object) -> str:
        payload = json.dumps(values, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
        return hashlib.sha256(payload.encode("utf-8")).hexdigest()

    @staticmethod
    def encode_cursor(payload: CursorPayload) -> str:
        raw = payload.model_dump_json().encode("utf-8")
        return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")

    @staticmethod
    def decode_cursor(raw_value: str, expected_filter_hash: str) -> CursorPayload:
        padding = "=" * (-len(raw_value) % 4)
        try:
            raw = base64.urlsafe_b64decode((raw_value + padding).encode("ascii"))
            payload = CursorPayload.model_validate_json(raw)
        except Exception as exc:  # noqa: BLE001
            raise MuseumDatabaseError("Invalid cursor") from exc
        if payload.filterHash != expected_filter_hash:
            raise MuseumDatabaseError("Cursor does not match current filters")
        return payload
