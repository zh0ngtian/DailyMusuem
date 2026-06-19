PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS schema_migrations (
    version INTEGER PRIMARY KEY,
    applied_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS museums (
    museum_id TEXT PRIMARY KEY,
    display_name TEXT NOT NULL,
    country TEXT NOT NULL,
    city TEXT NOT NULL,
    subtitle TEXT NOT NULL,
    supports_translation INTEGER NOT NULL DEFAULT 0,
    supports_widget_content INTEGER NOT NULL DEFAULT 1,
    sort_order INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS data_sources (
    source_pk INTEGER PRIMARY KEY AUTOINCREMENT,
    museum_id TEXT NOT NULL REFERENCES museums(museum_id) ON DELETE CASCADE,
    source_key TEXT NOT NULL,
    display_name TEXT NOT NULL,
    is_default INTEGER NOT NULL DEFAULT 1,
    request_base_url TEXT,
    notes TEXT,
    UNIQUE (museum_id, source_key)
);

CREATE TABLE IF NOT EXISTS categories (
    category_pk INTEGER PRIMARY KEY AUTOINCREMENT,
    museum_id TEXT NOT NULL,
    source_key TEXT NOT NULL,
    category_id TEXT NOT NULL,
    display_name TEXT NOT NULL,
    kind TEXT NOT NULL,
    remote_value TEXT,
    sort_order INTEGER NOT NULL DEFAULT 0,
    raw_json TEXT,
    FOREIGN KEY (museum_id, source_key) REFERENCES data_sources(museum_id, source_key) ON DELETE CASCADE,
    UNIQUE (museum_id, source_key, category_id)
);

CREATE TABLE IF NOT EXISTS artworks (
    artwork_pk INTEGER PRIMARY KEY AUTOINCREMENT,
    museum_id TEXT NOT NULL,
    source_key TEXT NOT NULL,
    object_id TEXT NOT NULL,
    stable_id TEXT NOT NULL,
    title TEXT NOT NULL,
    artwork_description_html TEXT,
    artwork_description_text TEXT,
    artist_display_name TEXT,
    object_date TEXT,
    medium TEXT,
    dimensions TEXT,
    department TEXT,
    culture TEXT,
    country TEXT,
    repository TEXT,
    object_url TEXT,
    source_detail_url TEXT,
    is_on_view INTEGER,
    has_image INTEGER NOT NULL DEFAULT 0,
    content_hash TEXT,
    source_updated_at TEXT,
    crawled_at TEXT NOT NULL,
    raw_json TEXT,
    extra_json TEXT,
    FOREIGN KEY (museum_id, source_key) REFERENCES data_sources(museum_id, source_key) ON DELETE CASCADE,
    UNIQUE (museum_id, source_key, object_id)
);

CREATE INDEX IF NOT EXISTS idx_artworks_museum_source ON artworks(museum_id, source_key);
CREATE INDEX IF NOT EXISTS idx_artworks_museum_object ON artworks(museum_id, object_id);
CREATE INDEX IF NOT EXISTS idx_artworks_image ON artworks(museum_id, source_key, has_image);
CREATE INDEX IF NOT EXISTS idx_artworks_on_view ON artworks(museum_id, source_key, is_on_view);

CREATE TABLE IF NOT EXISTS artwork_images (
    image_pk INTEGER PRIMARY KEY AUTOINCREMENT,
    artwork_pk INTEGER NOT NULL REFERENCES artworks(artwork_pk) ON DELETE CASCADE,
    role TEXT NOT NULL,
    url TEXT NOT NULL,
    width INTEGER,
    height INTEGER,
    mime_type TEXT,
    sort_order INTEGER NOT NULL DEFAULT 0,
    UNIQUE (artwork_pk, role, url)
);

CREATE INDEX IF NOT EXISTS idx_artwork_images_role ON artwork_images(artwork_pk, role, sort_order);

CREATE TABLE IF NOT EXISTS artwork_categories (
    artwork_pk INTEGER NOT NULL REFERENCES artworks(artwork_pk) ON DELETE CASCADE,
    category_pk INTEGER NOT NULL REFERENCES categories(category_pk) ON DELETE CASCADE,
    membership_source TEXT NOT NULL DEFAULT 'crawler',
    PRIMARY KEY (artwork_pk, category_pk)
);

CREATE INDEX IF NOT EXISTS idx_artwork_categories_category ON artwork_categories(category_pk, artwork_pk);

CREATE TABLE IF NOT EXISTS artwork_facets (
    facet_pk INTEGER PRIMARY KEY AUTOINCREMENT,
    artwork_pk INTEGER NOT NULL REFERENCES artworks(artwork_pk) ON DELETE CASCADE,
    facet_kind TEXT NOT NULL,
    facet_key TEXT NOT NULL,
    display_value TEXT,
    remote_value TEXT,
    UNIQUE (artwork_pk, facet_kind, facet_key, remote_value)
);

CREATE INDEX IF NOT EXISTS idx_artwork_facets_kind ON artwork_facets(artwork_pk, facet_kind);

CREATE TABLE IF NOT EXISTS crawl_runs (
    run_id TEXT PRIMARY KEY,
    started_at TEXT NOT NULL,
    finished_at TEXT,
    status TEXT NOT NULL,
    crawler_version TEXT,
    schema_version INTEGER NOT NULL,
    manifest_json TEXT
);

CREATE TABLE IF NOT EXISTS crawl_errors (
    error_pk INTEGER PRIMARY KEY AUTOINCREMENT,
    run_id TEXT NOT NULL REFERENCES crawl_runs(run_id) ON DELETE CASCADE,
    museum_id TEXT NOT NULL,
    source_key TEXT NOT NULL,
    object_id TEXT,
    url TEXT,
    stage TEXT NOT NULL,
    error_type TEXT NOT NULL,
    error_message TEXT NOT NULL,
    created_at TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_crawl_errors_run ON crawl_errors(run_id, museum_id, stage);

INSERT OR IGNORE INTO schema_migrations(version) VALUES (1);
