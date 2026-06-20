import argparse
import json
import os
import sqlite3
from concurrent.futures import FIRST_COMPLETED, ThreadPoolExecutor, wait
from datetime import datetime, timezone
from pathlib import Path
from urllib.error import HTTPError

from .museums.japan_search import (
    PROFILES as JAPAN_SEARCH_PROFILES,
    JapanSearchCrawler,
    JapanSearchCrawlerPolicy,
    crawl_sample_item,
    store_artwork as store_japan_search_artwork,
)
from .museums.guimet import (
    GuimetCrawler,
    crawl_sample_detail as crawl_sample_guimet_detail,
    store_artwork as store_guimet_artwork,
)
from .museums.met import MetCrawler, crawl_sample_object, store_artwork as store_met_artwork
from .museums.met import MetCrawlerPolicy
from .museums.nara_official import (
    NaraOfficialCrawler,
    crawl_sample_detail as crawl_sample_nara_official_detail,
    store_artwork as store_nara_official_artwork,
)
from .museums.nmc import (
    NationalMuseumChinaCrawler,
    crawl_sample_detail,
    parse_detail_html,
    parse_web_detail_html,
    store_artwork,
)
from .museums.shanghai import (
    ShanghaiCrawler,
    ShanghaiCrawlerPolicy,
    crawl_sample_detail as crawl_sample_shanghai_detail,
    store_artwork as store_shanghai_artwork,
)
from .stores import initialize_database, seed_reference_metadata


SCHEMA_VERSION = 1
LIVE_CRAWL_MUSEUMS = ["nmc", "met", "tnm", "nnm-colbase", "nnm-official", "shm", "guimet"]
SUPPORTED_MUSEUMS = ["all", *LIVE_CRAWL_MUSEUMS]
LIVE_CRAWL_SOURCES = {
    "nmc": ("nmc", "nmc_api"),
    "met": ("met", "met_all"),
    "tnm": ("tnm", "japan_search"),
    "nnm-colbase": ("nnm", "colbase"),
    "nnm-official": ("nnm", "official"),
    "shm": ("shm", "shm_web"),
    "guimet": ("guimet", "guimet_web"),
}


def main() -> None:
    parser = argparse.ArgumentParser(description="MuseumMuse offline crawler entrypoint")
    subparsers = parser.add_subparsers(dest="command", required=True)

    init_parser = subparsers.add_parser("init-db", help="Create the SQLite schema and seed museum/source metadata.")
    init_parser.add_argument("--db", default="server/data/museummuse.sqlite")

    status_parser = subparsers.add_parser("status", help="Summarize crawl completion status from a SQLite database.")
    status_parser.add_argument("--db", default="server/data/museummuse.sqlite")
    status_parser.add_argument("--json", action="store_true", help="Print machine-readable JSON.")

    crawl_parser = subparsers.add_parser("crawl", help="Prepare the database for a future museum crawl run.")
    crawl_parser.add_argument("--museum", default="all")
    crawl_parser.add_argument("--db", default="server/data/museummuse.sqlite")
    crawl_parser.add_argument("--sample-detail-html", help="Parse and store one local detail HTML file without network.")
    crawl_parser.add_argument("--sample-image-html", help="Optional local image-page HTML file for sample crawlers.")
    crawl_parser.add_argument("--sample-web-html", help="Optional local official web page HTML file for sample crawlers.")
    crawl_parser.add_argument("--sample-detail-json", help="Parse and store one local detail JSON file without network.")
    crawl_parser.add_argument("--sample-exhibit-id", type=int, default=0)
    crawl_parser.add_argument("--sample-object-id", help="String object id for sample HTML crawlers.")
    crawl_parser.add_argument("--sample-detail-url")
    crawl_parser.add_argument("--category-id", help="Optional internal category id for live crawler filtering.")
    crawl_parser.add_argument("--allow-network", action="store_true", help="Allow the crawler to call remote museum endpoints.")
    crawl_parser.add_argument("--max-details", type=int, default=0, help="Maximum live detail pages to fetch after candidate discovery.")
    crawl_parser.add_argument("--full", action="store_true", help="Crawl every discovered live candidate.")
    crawl_parser.add_argument("--skip-existing", action="store_true", help="Skip detail fetches for artworks already in the target database.")
    crawl_parser.add_argument(
        "--page-size",
        type=int,
        help="Optional candidate search page size for crawlers that support it.",
    )
    crawl_parser.add_argument(
        "--request-interval",
        type=float,
        help="Optional delay in seconds between crawler requests for supported non-NMC sources.",
    )
    crawl_parser.add_argument(
        "--concurrency",
        type=int,
        help="Optional detail fetch concurrency for supported non-NMC sources.",
    )
    crawl_parser.add_argument(
        "--exclude-museum",
        action="append",
        default=[],
        choices=LIVE_CRAWL_MUSEUMS,
        help="Museum crawler id to skip when --museum all is used. Can be passed multiple times.",
    )

    args = parser.parse_args()
    db_path = Path(args.db)

    if args.command == "init-db":
        initialize_database(db_path)
        seed_reference_metadata(db_path)
        print(f"initialized {db_path}")
        return

    if args.command == "status":
        status = build_crawl_status(db_path)
        if args.json:
            print(json.dumps(status, ensure_ascii=False, indent=2, sort_keys=True))
        else:
            print_crawl_status(status)
        return

    if args.command == "crawl":
        initialize_database(db_path)
        seed_reference_metadata(db_path)
        if args.museum == "all":
            crawl_all(args, db_path)
        else:
            dispatch_crawl(args, db_path)
        manifest_path = write_manifest(db_path)
        print(f"wrote manifest {manifest_path}")
        return


def dispatch_crawl(args: argparse.Namespace, db_path: Path) -> None:
    ensure_page_size(args)
    ensure_request_interval(args)
    ensure_concurrency(args)
    if args.allow_network and not has_sample_inputs(args):
        ensure_live_detail_limit(args)

    if args.museum == "nmc":
        crawl_nmc(args, db_path)
    elif args.museum == "met":
        crawl_met(args, db_path)
    elif args.museum in JAPAN_SEARCH_PROFILES:
        crawl_japan_search(args, db_path)
    elif args.museum == "nnm-official":
        crawl_nara_official(args, db_path)
    elif args.museum == "guimet":
        crawl_guimet(args, db_path)
    elif args.museum == "shm":
        crawl_shanghai(args, db_path)
    else:
        raise SystemExit(f"Only these crawler paths are implemented so far: {', '.join(SUPPORTED_MUSEUMS)}.")


def crawl_all(args: argparse.Namespace, db_path: Path) -> None:
    if has_sample_inputs(args):
        raise SystemExit("Sample input flags are only supported for a single --museum value, not --museum all.")
    if not args.allow_network:
        raise SystemExit("Refusing live --museum all crawl without --allow-network.")

    for museum in live_crawl_museums_for_args(args):
        next_args = argparse.Namespace(**vars(args))
        next_args.museum = museum
        dispatch_crawl(next_args, db_path)


def live_crawl_museums_for_args(args: argparse.Namespace) -> list[str]:
    excluded = set(getattr(args, "exclude_museum", []) or [])
    return [museum for museum in LIVE_CRAWL_MUSEUMS if museum not in excluded]


def has_sample_inputs(args: argparse.Namespace) -> bool:
    return any(
        [
            args.sample_detail_html,
            args.sample_image_html,
            args.sample_web_html,
            args.sample_detail_json,
            args.sample_exhibit_id > 0,
            args.sample_object_id,
            args.sample_detail_url,
        ]
    )


def ensure_live_detail_limit(args: argparse.Namespace) -> None:
    if getattr(args, "full", False):
        if args.max_details > 0:
            raise SystemExit("--full cannot be combined with --max-details.")
        return
    if args.max_details <= 0:
        raise SystemExit(
            "Live crawl requires --max-details > 0. Choose an explicit per-source "
            "detail budget, especially for anti-scraping-sensitive sources."
        )


def ensure_page_size(args: argparse.Namespace) -> None:
    page_size = getattr(args, "page_size", None)
    if page_size is not None and page_size <= 0:
        raise SystemExit("--page-size must be greater than 0.")


def crawler_page_size(args: argparse.Namespace, *, default: int) -> int:
    return getattr(args, "page_size", None) or default


def ensure_request_interval(args: argparse.Namespace) -> None:
    interval = getattr(args, "request_interval", None)
    if interval is not None and interval < 0:
        raise SystemExit("--request-interval must be greater than or equal to 0.")
    if getattr(args, "museum", None) == "nmc" and interval is not None:
        raise SystemExit("--request-interval is not supported for nmc; keep NMC API limits separate.")


def crawler_request_interval(args: argparse.Namespace, *, default: float) -> float:
    interval = getattr(args, "request_interval", None)
    return default if interval is None else interval


def ensure_concurrency(args: argparse.Namespace) -> None:
    concurrency = getattr(args, "concurrency", None)
    if concurrency is not None and concurrency <= 0:
        raise SystemExit("--concurrency must be greater than 0.")
    if getattr(args, "museum", None) == "nmc" and concurrency is not None:
        raise SystemExit("--concurrency is not supported for nmc; keep NMC API limits separate.")


def crawler_concurrency(args: argparse.Namespace, *, default: int = 1) -> int:
    return getattr(args, "concurrency", None) or default


def candidate_discovery_minimum(args: argparse.Namespace, *, default: int = 10) -> int | None:
    if getattr(args, "full", False):
        return None
    return max(args.max_details, default)


def detail_candidate_iterator(candidate_ids: list[object], max_details: int, *, full: bool = False) -> list[object]:
    if full:
        return candidate_ids
    if max_details <= 0:
        return []
    return candidate_ids


def has_reached_detail_limit(completed_count: int, max_details: int, *, full: bool = False) -> bool:
    return not full and max_details > 0 and completed_count >= max_details


def has_scheduled_detail_limit(scheduled_count: int, max_details: int, *, full: bool = False) -> bool:
    return not full and max_details > 0 and scheduled_count >= max_details


def live_crawl_status(completed_count: int, candidate_count: int, max_details: int, *, full: bool = False) -> str:
    target_count = candidate_count if full else min(candidate_count, max(0, max_details))
    return "succeeded" if completed_count >= target_count else "partial"


def is_permanent_detail_failure(museum: str, exc: BaseException) -> bool:
    if museum != "met":
        return False
    if isinstance(exc, HTTPError) and exc.code == 404:
        return True
    return isinstance(exc, TimeoutError)


def should_skip_existing(
    connection: sqlite3.Connection,
    args: argparse.Namespace,
    *,
    museum_id: str,
    source_key: str,
    object_id: str,
) -> bool:
    if not getattr(args, "skip_existing", False):
        return False
    row = connection.execute(
        """
        SELECT 1
        FROM artworks
        WHERE museum_id = ? AND source_key = ? AND object_id = ?
        LIMIT 1
        """,
        (museum_id, source_key, object_id),
    ).fetchone()
    return row is not None


def completed_detail_count(stored_count: int, skipped_count: int) -> int:
    return stored_count + skipped_count


def print_live_progress(
    label: str,
    *,
    candidate_count: int,
    attempted_count: int,
    stored_count: int,
    skipped_count: int,
) -> None:
    completed_count = attempted_count + skipped_count
    if completed_count == 0 or completed_count % 100 != 0:
        return
    print(
        f"{label} progress completed={completed_count}/{candidate_count} "
        f"attempted={attempted_count} stored={stored_count} skipped={skipped_count}",
        flush=True,
    )


def crawl_shanghai(args: argparse.Namespace, db_path: Path) -> None:
    run_id = f"shm-{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}"
    started_at = datetime.now(timezone.utc).isoformat()
    with sqlite3.connect(db_path) as connection:
        connection.execute("PRAGMA foreign_keys = ON")
        start_run(connection, run_id, started_at)
        try:
            if args.sample_detail_html:
                if not args.sample_object_id:
                    raise SystemExit("--sample-object-id is required when --sample-detail-html is used for shm.")
                artwork_pk = crawl_sample_shanghai_detail(
                    connection=connection,
                    article_html_path=args.sample_detail_html,
                    object_code=args.sample_object_id,
                    image_html_path=args.sample_image_html,
                    category_id=args.category_id,
                )
                finish_run(
                    connection,
                    run_id,
                    status="succeeded",
                    manifest={
                        "museum": "shm",
                        "source": "shm_web",
                        "mode": "sample",
                        "storedArtworkPK": artwork_pk,
                    },
                )
                connection.commit()
                print(f"stored shm sample artwork_pk={artwork_pk} into {db_path}")
                return

            if not args.allow_network:
                raise SystemExit(
                    "Refusing live shm crawl without --allow-network. Use --sample-detail-html for parser validation."
                )

            crawler = ShanghaiCrawler(
                policy=ShanghaiCrawlerPolicy(
                    page_size=crawler_page_size(args, default=10),
                    request_interval_seconds=crawler_request_interval(args, default=1.0),
                ),
            )
            candidate_codes = crawler.fetch_candidate_codes(
                subtype=args.category_id,
                minimum_count=candidate_discovery_minimum(args),
                progress_label="shm candidates",
            )
            stored_count = 0
            skipped_count = 0
            attempted_count = 0
            candidate_iter = iter(detail_candidate_iterator(candidate_codes, args.max_details, full=args.full))
            inflight = {}
            concurrency = crawler_concurrency(args)

            def submit_next_details(executor: ThreadPoolExecutor) -> None:
                nonlocal attempted_count, skipped_count
                while len(inflight) < concurrency:
                    if has_scheduled_detail_limit(
                        attempted_count + skipped_count,
                        args.max_details,
                        full=args.full,
                    ):
                        return
                    try:
                        object_code = next(candidate_iter)
                    except StopIteration:
                        return
                    if should_skip_existing(
                        connection,
                        args,
                        museum_id="shm",
                        source_key="shm_web",
                        object_id=object_code,
                    ):
                        skipped_count += 1
                        print_live_progress(
                            "shm",
                            candidate_count=len(candidate_codes),
                            attempted_count=attempted_count,
                            stored_count=stored_count,
                            skipped_count=skipped_count,
                        )
                        continue
                    attempted_count += 1
                    inflight[executor.submit(crawler.fetch_artwork, object_code)] = object_code

            with ThreadPoolExecutor(max_workers=concurrency) as executor:
                submit_next_details(executor)
                while inflight:
                    done, _ = wait(inflight, return_when=FIRST_COMPLETED)
                    for future in done:
                        object_code = inflight.pop(future)
                        try:
                            record = future.result()
                            store_shanghai_artwork(connection, record, category_id=args.category_id)
                            stored_count += 1
                        except Exception as exc:  # noqa: BLE001
                            log_error(
                                connection,
                                run_id=run_id,
                                museum_id="shm",
                                source_key="shm_web",
                                object_id=object_code,
                                url=None,
                                stage="detail",
                                error=exc,
                            )
                        connection.commit()
                        print_live_progress(
                            "shm",
                            candidate_count=len(candidate_codes),
                            attempted_count=attempted_count,
                            stored_count=stored_count,
                            skipped_count=skipped_count,
                        )
                    submit_next_details(executor)

            finish_run(
                connection,
                run_id,
                status=live_crawl_status(
                    completed_detail_count(stored_count, skipped_count),
                    len(candidate_codes),
                    args.max_details,
                    full=args.full,
                ),
                manifest={
                    "museum": "shm",
                    "source": "shm_web",
                    "mode": "network",
                    "candidateCount": len(candidate_codes),
                    "attemptedCount": attempted_count,
                    "skippedExistingCount": skipped_count,
                    "storedCount": stored_count,
                    "maxDetails": args.max_details,
                    "full": args.full,
                    "pageSize": crawler.policy.page_size,
                    "requestInterval": crawler.policy.request_interval_seconds,
                    "concurrency": concurrency,
                    "categoryID": args.category_id,
                },
            )
            connection.commit()
            print(f"shm crawl finished candidates={len(candidate_codes)} stored={stored_count}")
        except BaseException:
            connection.rollback()
            raise


def crawl_guimet(args: argparse.Namespace, db_path: Path) -> None:
    run_id = f"guimet-{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}"
    started_at = datetime.now(timezone.utc).isoformat()
    with sqlite3.connect(db_path) as connection:
        connection.execute("PRAGMA foreign_keys = ON")
        start_run(connection, run_id, started_at)
        try:
            if args.sample_detail_html:
                artwork_pk = crawl_sample_guimet_detail(
                    connection=connection,
                    html_path=args.sample_detail_html,
                    detail_url=args.sample_detail_url,
                    object_id=args.sample_object_id,
                )
                finish_run(
                    connection,
                    run_id,
                    status="succeeded",
                    manifest={
                        "museum": "guimet",
                        "source": "guimet_web",
                        "mode": "sample",
                        "storedArtworkPK": artwork_pk,
                    },
                )
                connection.commit()
                print(f"stored guimet sample artwork_pk={artwork_pk} into {db_path}")
                return

            if not args.allow_network:
                raise SystemExit(
                    "Refusing live guimet crawl without --allow-network. "
                    "Use --sample-detail-html for parser validation."
                )

            crawler = GuimetCrawler()
            candidate_ids = crawler.fetch_candidate_ids(category_id=args.category_id)
            stored_count = 0
            skipped_count = 0
            attempted_count = 0
            for object_id in detail_candidate_iterator(candidate_ids, args.max_details, full=args.full):
                if has_reached_detail_limit(completed_detail_count(stored_count, skipped_count), args.max_details, full=args.full):
                    break
                if should_skip_existing(
                    connection,
                    args,
                    museum_id="guimet",
                    source_key="guimet_web",
                    object_id=object_id,
                ):
                    skipped_count += 1
                    continue
                attempted_count += 1
                try:
                    record = crawler.fetch_artwork(object_id)
                    store_guimet_artwork(connection, record, category_id=args.category_id)
                    stored_count += 1
                except Exception as exc:  # noqa: BLE001
                    log_error(
                        connection,
                        run_id=run_id,
                        museum_id="guimet",
                        source_key="guimet_web",
                        object_id=object_id,
                        url=None,
                        stage="detail",
                        error=exc,
                    )

            finish_run(
                connection,
                run_id,
                status=live_crawl_status(
                    completed_detail_count(stored_count, skipped_count),
                    len(candidate_ids),
                    args.max_details,
                    full=args.full,
                ),
                manifest={
                    "museum": "guimet",
                    "source": "guimet_web",
                    "mode": "network",
                    "candidateCount": len(candidate_ids),
                    "attemptedCount": attempted_count,
                    "skippedExistingCount": skipped_count,
                    "storedCount": stored_count,
                    "maxDetails": args.max_details,
                    "full": args.full,
                    "categoryID": args.category_id,
                },
            )
            connection.commit()
            print(f"guimet crawl finished candidates={len(candidate_ids)} stored={stored_count}")
        except BaseException:
            connection.rollback()
            raise


def crawl_nara_official(args: argparse.Namespace, db_path: Path) -> None:
    run_id = f"nnm-official-{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}"
    started_at = datetime.now(timezone.utc).isoformat()
    with sqlite3.connect(db_path) as connection:
        connection.execute("PRAGMA foreign_keys = ON")
        start_run(connection, run_id, started_at)
        try:
            if args.sample_detail_html:
                if not args.sample_object_id:
                    raise SystemExit("--sample-object-id is required when --sample-detail-html is used for nnm-official.")
                artwork_pk = crawl_sample_nara_official_detail(
                    connection=connection,
                    html_path=args.sample_detail_html,
                    raw_id=args.sample_object_id,
                    detail_url=args.sample_detail_url,
                )
                finish_run(
                    connection,
                    run_id,
                    status="succeeded",
                    manifest={
                        "museum": "nnm",
                        "source": "official",
                        "mode": "sample",
                        "storedArtworkPK": artwork_pk,
                    },
                )
                connection.commit()
                print(f"stored nnm-official sample artwork_pk={artwork_pk} into {db_path}")
                return

            if not args.allow_network:
                raise SystemExit(
                    "Refusing live nnm-official crawl without --allow-network. "
                    "Use --sample-detail-html for parser validation."
                )

            crawler = NaraOfficialCrawler()
            candidate_ids = crawler.fetch_candidate_ids(category_id=args.category_id)
            stored_count = 0
            skipped_count = 0
            attempted_count = 0
            for object_id in detail_candidate_iterator(candidate_ids, args.max_details, full=args.full):
                if has_reached_detail_limit(completed_detail_count(stored_count, skipped_count), args.max_details, full=args.full):
                    break
                if should_skip_existing(
                    connection,
                    args,
                    museum_id="nnm",
                    source_key="official",
                    object_id=object_id,
                ):
                    skipped_count += 1
                    continue
                attempted_count += 1
                try:
                    record = crawler.fetch_artwork(object_id)
                    store_nara_official_artwork(connection, record)
                    stored_count += 1
                except Exception as exc:  # noqa: BLE001
                    log_error(
                        connection,
                        run_id=run_id,
                        museum_id="nnm",
                        source_key="official",
                        object_id=object_id,
                        url=None,
                        stage="detail",
                        error=exc,
                    )

            finish_run(
                connection,
                run_id,
                status=live_crawl_status(
                    completed_detail_count(stored_count, skipped_count),
                    len(candidate_ids),
                    args.max_details,
                    full=args.full,
                ),
                manifest={
                    "museum": "nnm",
                    "source": "official",
                    "mode": "network",
                    "candidateCount": len(candidate_ids),
                    "attemptedCount": attempted_count,
                    "skippedExistingCount": skipped_count,
                    "storedCount": stored_count,
                    "maxDetails": args.max_details,
                    "full": args.full,
                    "requestInterval": crawler.policy.request_interval_seconds,
                    "categoryID": args.category_id,
                },
            )
            connection.commit()
            print(f"nnm-official crawl finished candidates={len(candidate_ids)} stored={stored_count}")
        except BaseException:
            connection.rollback()
            raise


def crawl_japan_search(args: argparse.Namespace, db_path: Path) -> None:
    profile = JAPAN_SEARCH_PROFILES[args.museum]
    run_id = f"{args.museum}-{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}"
    started_at = datetime.now(timezone.utc).isoformat()
    with sqlite3.connect(db_path) as connection:
        connection.execute("PRAGMA foreign_keys = ON")
        start_run(connection, run_id, started_at)
        try:
            if args.sample_detail_json:
                artwork_pk = crawl_sample_item(
                    connection=connection,
                    json_path=args.sample_detail_json,
                    profile=profile,
                )
                finish_run(
                    connection,
                    run_id,
                    status="succeeded",
                    manifest={
                        "museum": profile.museum_id,
                        "source": profile.source_key,
                        "mode": "sample",
                        "storedArtworkPK": artwork_pk,
                    },
                )
                connection.commit()
                print(f"stored {args.museum} sample artwork_pk={artwork_pk} into {db_path}")
                return

            if not args.allow_network:
                raise SystemExit(
                    f"Refusing live {args.museum} crawl without --allow-network. "
                    "Use --sample-detail-json for parser validation."
                )

            crawler = JapanSearchCrawler(
                profile=profile,
                policy=JapanSearchCrawlerPolicy(page_size=crawler_page_size(args, default=10)),
            )
            candidate_ids = crawler.fetch_candidate_ids(
                category_type_code=args.category_id,
                minimum_count=candidate_discovery_minimum(args),
            )
            stored_count = 0
            skipped_count = 0
            attempted_count = 0
            for item_id in detail_candidate_iterator(candidate_ids, args.max_details, full=args.full):
                if has_reached_detail_limit(completed_detail_count(stored_count, skipped_count), args.max_details, full=args.full):
                    break
                if should_skip_existing(
                    connection,
                    args,
                    museum_id=profile.museum_id,
                    source_key=profile.source_key,
                    object_id=item_id,
                ):
                    skipped_count += 1
                    continue
                attempted_count += 1
                try:
                    record = crawler.fetch_item(item_id)
                    store_japan_search_artwork(connection, record, category_id=args.category_id)
                    stored_count += 1
                except Exception as exc:  # noqa: BLE001
                    log_error(
                        connection,
                        run_id=run_id,
                        museum_id=profile.museum_id,
                        source_key=profile.source_key,
                        object_id=item_id,
                        url=None,
                        stage="detail",
                        error=exc,
                    )

            finish_run(
                connection,
                run_id,
                status=live_crawl_status(
                    completed_detail_count(stored_count, skipped_count),
                    len(candidate_ids),
                    args.max_details,
                    full=args.full,
                ),
                manifest={
                    "museum": profile.museum_id,
                    "source": profile.source_key,
                    "mode": "network",
                    "candidateCount": len(candidate_ids),
                    "attemptedCount": attempted_count,
                    "skippedExistingCount": skipped_count,
                    "storedCount": stored_count,
                    "maxDetails": args.max_details,
                    "full": args.full,
                    "pageSize": crawler.policy.page_size,
                    "categoryID": args.category_id,
                },
            )
            connection.commit()
            print(f"{args.museum} crawl finished candidates={len(candidate_ids)} stored={stored_count}")
        except BaseException:
            connection.rollback()
            raise


def crawl_met(args: argparse.Namespace, db_path: Path) -> None:
    run_id = f"met-{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}"
    started_at = datetime.now(timezone.utc).isoformat()
    with sqlite3.connect(db_path) as connection:
        connection.execute("PRAGMA foreign_keys = ON")
        start_run(connection, run_id, started_at)
        try:
            if args.sample_detail_json:
                artwork_pk = crawl_sample_object(
                    connection=connection,
                    json_path=args.sample_detail_json,
                    web_html_path=args.sample_web_html,
                )
                finish_run(
                    connection,
                    run_id,
                    status="succeeded",
                    manifest={"museum": "met", "mode": "sample", "storedArtworkPK": artwork_pk},
                )
                connection.commit()
                print(f"stored met sample artwork_pk={artwork_pk} into {db_path}")
                return

            if not args.allow_network:
                raise SystemExit(
                    "Refusing live Met crawl without --allow-network. Use --sample-detail-json for parser validation."
                )

            crawler = MetCrawler(
                policy=MetCrawlerPolicy(
                    request_interval_seconds=crawler_request_interval(args, default=0.25),
                )
            )
            department_id = met_department_id_for_category(args.category_id)
            candidate_ids = crawler.fetch_candidate_ids(department_id=department_id)
            stored_count = 0
            skipped_count = 0
            attempted_count = 0
            permanent_failure_count = 0
            candidate_iter = iter(detail_candidate_iterator(candidate_ids, args.max_details, full=args.full))
            inflight = {}
            concurrency = crawler_concurrency(args)

            def fetch_met_record(object_id: int):
                record = crawler.fetch_object(object_id)
                return record.with_description(crawler.fetch_web_description(record.object_url))

            def submit_next_details(executor: ThreadPoolExecutor) -> None:
                nonlocal attempted_count, skipped_count
                while len(inflight) < concurrency:
                    if has_scheduled_detail_limit(
                        attempted_count + skipped_count,
                        args.max_details,
                        full=args.full,
                    ):
                        return
                    try:
                        object_id = next(candidate_iter)
                    except StopIteration:
                        return
                    if should_skip_existing(
                        connection,
                        args,
                        museum_id="met",
                        source_key="met_all",
                        object_id=str(object_id),
                    ):
                        skipped_count += 1
                        print_live_progress(
                            "met",
                            candidate_count=len(candidate_ids),
                            attempted_count=attempted_count,
                            stored_count=stored_count,
                            skipped_count=skipped_count,
                        )
                        continue
                    attempted_count += 1
                    inflight[executor.submit(fetch_met_record, object_id)] = object_id

            with ThreadPoolExecutor(max_workers=concurrency) as executor:
                submit_next_details(executor)
                while inflight:
                    done, _ = wait(inflight, return_when=FIRST_COMPLETED)
                    for future in done:
                        object_id = inflight.pop(future)
                        try:
                            record = future.result()
                            store_met_artwork(connection, record)
                            stored_count += 1
                        except Exception as exc:  # noqa: BLE001
                            log_error(
                                connection,
                                run_id=run_id,
                                museum_id="met",
                                source_key="met_all",
                                object_id=str(object_id),
                                url=None,
                                stage="detail",
                                error=exc,
                            )
                            if is_permanent_detail_failure("met", exc):
                                permanent_failure_count += 1
                        connection.commit()
                        print_live_progress(
                            "met",
                            candidate_count=len(candidate_ids),
                            attempted_count=attempted_count,
                            stored_count=stored_count,
                            skipped_count=skipped_count,
                        )
                    submit_next_details(executor)

            finish_run(
                connection,
                run_id,
                status=live_crawl_status(
                    completed_detail_count(stored_count, skipped_count) + permanent_failure_count,
                    len(candidate_ids),
                    args.max_details,
                    full=args.full,
                ),
                manifest={
                    "museum": "met",
                    "mode": "network",
                    "candidateCount": len(candidate_ids),
                    "attemptedCount": attempted_count,
                    "skippedExistingCount": skipped_count,
                    "storedCount": stored_count,
                    "permanentFailureCount": permanent_failure_count,
                    "maxDetails": args.max_details,
                    "full": args.full,
                    "requestInterval": crawler.policy.request_interval_seconds,
                    "concurrency": concurrency,
                    "categoryID": args.category_id,
                },
            )
            connection.commit()
            print(f"met crawl finished candidates={len(candidate_ids)} stored={stored_count}")
        except BaseException:
            connection.rollback()
            raise


def crawl_nmc(args: argparse.Namespace, db_path: Path) -> None:
    run_id = f"nmc-{datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')}"
    started_at = datetime.now(timezone.utc).isoformat()
    with sqlite3.connect(db_path) as connection:
        connection.execute("PRAGMA foreign_keys = ON")
        start_run(connection, run_id, started_at)
        try:
            if args.sample_detail_html:
                if args.sample_exhibit_id <= 0:
                    raise SystemExit("--sample-exhibit-id is required when --sample-detail-html is used.")
                artwork_pk = crawl_sample_detail(
                    connection=connection,
                    html_path=args.sample_detail_html,
                    exhibit_id=args.sample_exhibit_id,
                    detail_url=args.sample_detail_url,
                )
                finish_run(
                    connection,
                    run_id,
                    status="succeeded",
                    manifest={"museum": "nmc", "mode": "sample", "storedArtworkPK": artwork_pk},
                )
                connection.commit()
                print(f"stored nmc sample artwork_pk={artwork_pk} into {db_path}")
                return

            if not args.allow_network:
                raise SystemExit(
                    "Refusing live NMC crawl without --allow-network. Use --sample-detail-html for parser validation."
                )

            crawler = NationalMuseumChinaCrawler()
            if args.full:
                if (
                    crawler.policy.detail_fetch_mode == "share_link_api"
                    and os.getenv("MUSEUMMUSE_NMC_ALLOW_FULL_SHARE_LINK_API") != "1"
                ):
                    raise SystemExit(
                        "Refusing NMC --full through share_link API without "
                        "MUSEUMMUSE_NMC_ALLOW_FULL_SHARE_LINK_API=1."
                    )
            if crawler.policy.detail_fetch_mode == "web_html":
                candidate_summaries = crawler.fetch_web_candidate_summaries(
                    minimum_count=candidate_discovery_minimum(args, default=1),
                    progress_label="nmc web candidates",
                )
            elif crawler.policy.detail_fetch_mode == "share_link_api":
                candidate_summaries = crawler.fetch_candidate_summaries(
                    minimum_count=candidate_discovery_minimum(args, default=1),
                )
            else:
                raise SystemExit(f"Unsupported NMC detail fetch mode: {crawler.policy.detail_fetch_mode}")
            stored_count = 0
            skipped_count = 0
            attempted_count = 0
            for summary in detail_candidate_iterator(candidate_summaries, args.max_details, full=args.full):
                if has_reached_detail_limit(completed_detail_count(stored_count, skipped_count), args.max_details, full=args.full):
                    break
                exhibit_id = summary.exhibit_id
                if should_skip_existing(
                    connection,
                    args,
                    museum_id="nmc",
                    source_key="nmc_api",
                    object_id=str(exhibit_id),
                ):
                    skipped_count += 1
                    print_live_progress(
                        "nmc",
                        candidate_count=len(candidate_summaries),
                        attempted_count=attempted_count,
                        stored_count=stored_count,
                        skipped_count=skipped_count,
                    )
                    continue
                attempted_count += 1
                try:
                    if crawler.policy.detail_fetch_mode == "web_html":
                        detail_url = str(summary.raw_item.get("detail_url") or "")
                        if not detail_url:
                            raise ValueError(f"NMC web candidate is missing detail_url: {exhibit_id}")
                        html, detail_url = crawler.fetch_web_detail_html(detail_url=detail_url)
                        record = parse_web_detail_html(
                            html,
                            detail_url=detail_url,
                            list_summary=summary,
                        )
                    else:
                        html, detail_url = crawler.fetch_detail_html(exhibit_id=exhibit_id)
                        record = parse_detail_html(
                            html,
                            exhibit_id=exhibit_id,
                            detail_url=detail_url,
                            list_summary=summary,
                        )
                    store_artwork(connection, record)
                    stored_count += 1
                except Exception as exc:  # noqa: BLE001
                    log_error(
                        connection,
                        run_id=run_id,
                        object_id=str(exhibit_id),
                        url=str(summary.raw_item.get("detail_url") or "") or None,
                        stage="detail",
                        error=exc,
                    )
                connection.commit()
                print_live_progress(
                    "nmc",
                    candidate_count=len(candidate_summaries),
                    attempted_count=attempted_count,
                    stored_count=stored_count,
                    skipped_count=skipped_count,
                )

            finish_run(
                connection,
                run_id,
                status=live_crawl_status(
                    completed_detail_count(stored_count, skipped_count),
                    len(candidate_summaries),
                    args.max_details,
                    full=args.full,
                ),
                manifest={
                    "museum": "nmc",
                    "mode": "network",
                    "candidateCount": len(candidate_summaries),
                    "attemptedCount": attempted_count,
                    "skippedExistingCount": skipped_count,
                    "storedCount": stored_count,
                    "maxDetails": args.max_details,
                    "full": args.full,
                    "detailFetchMode": crawler.policy.detail_fetch_mode,
                    "webInterval": crawler.policy.web_interval_seconds,
                    "apiListLimit": crawler.policy.list_api_limit,
                    "apiMaxListCalls": crawler.policy.max_list_api_calls,
                },
            )
            connection.commit()
            print(f"nmc crawl finished candidates={len(candidate_summaries)} stored={stored_count}")
        except BaseException:
            connection.rollback()
            raise


def start_run(connection: sqlite3.Connection, run_id: str, started_at: str) -> None:
    connection.execute(
        """
        INSERT OR REPLACE INTO crawl_runs(
            run_id, started_at, finished_at, status, crawler_version, schema_version, manifest_json
        )
        VALUES (?, ?, NULL, 'running', NULL, ?, NULL)
        """,
        (run_id, started_at, SCHEMA_VERSION),
    )


def finish_run(
    connection: sqlite3.Connection,
    run_id: str,
    *,
    status: str,
    manifest: dict[str, object],
) -> None:
    connection.execute(
        """
        UPDATE crawl_runs
        SET finished_at = ?, status = ?, manifest_json = ?
        WHERE run_id = ?
        """,
        (
            datetime.now(timezone.utc).isoformat(),
            status,
            json.dumps(manifest, ensure_ascii=False, sort_keys=True),
            run_id,
        ),
    )


def log_error(
    connection: sqlite3.Connection,
    *,
    run_id: str,
    museum_id: str = "nmc",
    source_key: str = "nmc_api",
    object_id: str | None,
    url: str | None,
    stage: str,
    error: Exception,
) -> None:
    connection.execute(
        """
        INSERT INTO crawl_errors(
            run_id, museum_id, source_key, object_id, url, stage,
            error_type, error_message, created_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            run_id,
            museum_id,
            source_key,
            object_id,
            url,
            stage,
            type(error).__name__,
            str(error),
            datetime.now(timezone.utc).isoformat(),
        ),
    )


def met_department_id_for_category(category_id: str | None) -> int | None:
    if category_id is None:
        return None
    category_to_department_id = {
        "american-decorative-arts": 1,
        "ancient-west-asian-art": 3,
        "arms-and-armor": 4,
        "africa-oceania-americas": 5,
        "asian-art": 6,
        "the-cloisters": 7,
        "costume-institute": 8,
        "drawings-and-prints": 9,
        "egyptian-art": 10,
        "european-paintings": 11,
        "european-sculpture-and-decorative-arts": 12,
        "greek-and-roman-art": 13,
        "islamic-art": 14,
        "robert-lehman-collection": 15,
        "libraries": 16,
        "medieval-art": 17,
        "musical-instruments": 18,
        "photographs": 19,
        "modern-art": 21,
    }
    return category_to_department_id.get(category_id)


def write_manifest(db_path: str | Path) -> Path:
    resolved_db_path = Path(db_path)
    manifest_path = manifest_path_for_db(resolved_db_path)
    manifest = build_manifest(resolved_db_path)
    temporary_path = manifest_path.with_suffix(f"{manifest_path.suffix}.tmp")
    temporary_path.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    temporary_path.replace(manifest_path)
    return manifest_path


def manifest_path_for_db(db_path: str | Path) -> Path:
    resolved_db_path = Path(db_path)
    if resolved_db_path.name == "museummuse.sqlite":
        return resolved_db_path.with_name("manifest.json")
    return resolved_db_path.with_name(f"{resolved_db_path.stem}.manifest.json")


def build_crawl_status(db_path: str | Path) -> dict[str, object]:
    resolved_db_path = Path(db_path)
    with sqlite3.connect(resolved_db_path) as connection:
        connection.row_factory = sqlite3.Row
        artwork_counts = {
            (row["museum_id"], row["source_key"]): int(row["artwork_count"])
            for row in connection.execute(
                """
                SELECT museum_id, source_key, COUNT(*) AS artwork_count
                FROM artworks
                GROUP BY museum_id, source_key
                """
            )
        }
        error_count = int(connection.execute("SELECT COUNT(*) FROM crawl_errors").fetchone()[0])
        targets = [
            crawl_status_for_target(connection, crawler_id, artwork_counts)
            for crawler_id in LIVE_CRAWL_MUSEUMS
        ]

    return {
        "database": str(resolved_db_path),
        "complete": all(target["completion"] == "complete" for target in targets),
        "errorCount": error_count,
        "targets": targets,
    }


def crawl_status_for_target(
    connection: sqlite3.Connection,
    crawler_id: str,
    artwork_counts: dict[tuple[str, str], int],
) -> dict[str, object]:
    museum_id, source_key = LIVE_CRAWL_SOURCES[crawler_id]
    artwork_count = artwork_counts.get((museum_id, source_key), 0)
    latest_run = connection.execute(
        """
        SELECT run_id, started_at, finished_at, status, manifest_json
        FROM crawl_runs
        WHERE run_id LIKE ?
        ORDER BY started_at DESC, run_id DESC
        LIMIT 1
        """,
        (f"{crawler_id}-%",),
    ).fetchone()
    if latest_run is None:
        return {
            "crawlerID": crawler_id,
            "museumID": museum_id,
            "sourceKey": source_key,
            "artworkCount": artwork_count,
            "completion": "missing",
            "latestRun": None,
        }

    manifest = json.loads(latest_run["manifest_json"] or "{}")
    candidate_count = int(manifest.get("candidateCount") or 0)
    stored_count = int(manifest.get("storedCount") or 0)
    skipped_count = int(manifest.get("skippedExistingCount") or 0)
    permanent_failure_count = int(manifest.get("permanentFailureCount") or 0)
    full = bool(manifest.get("full"))
    completed_count = stored_count + skipped_count + permanent_failure_count
    if latest_run["status"] != "succeeded":
        completion = latest_run["status"]
    elif full and completed_count >= candidate_count and artwork_count + permanent_failure_count >= candidate_count:
        completion = "complete"
    elif full:
        completion = "partial"
    else:
        completion = "sampled"

    return {
        "crawlerID": crawler_id,
        "museumID": museum_id,
        "sourceKey": source_key,
        "artworkCount": artwork_count,
        "completion": completion,
        "latestRun": {
            "runID": latest_run["run_id"],
            "status": latest_run["status"],
            "full": full,
            "candidateCount": candidate_count,
            "attemptedCount": int(manifest.get("attemptedCount") or 0),
            "storedCount": stored_count,
            "skippedExistingCount": skipped_count,
            "permanentFailureCount": permanent_failure_count,
            "startedAt": latest_run["started_at"],
            "finishedAt": latest_run["finished_at"],
        },
    }


def print_crawl_status(status: dict[str, object]) -> None:
    print(f"database: {status['database']}")
    print(f"complete: {str(status['complete']).lower()}")
    print(f"errorCount: {status['errorCount']}")
    for target in status["targets"]:
        latest_run = target["latestRun"]
        if latest_run is None:
            run_text = "no-run"
        else:
            run_text = (
                f"{latest_run['runID']} status={latest_run['status']} "
                f"full={str(latest_run['full']).lower()} "
                f"candidates={latest_run['candidateCount']} "
                f"stored={latest_run['storedCount']} "
                f"skipped={latest_run['skippedExistingCount']} "
                f"permanentFailures={latest_run['permanentFailureCount']}"
            )
        print(
            f"{target['crawlerID']}: {target['completion']} "
            f"artworks={target['artworkCount']} source={target['museumID']}/{target['sourceKey']} {run_text}"
        )


def build_manifest(db_path: str | Path) -> dict[str, object]:
    resolved_db_path = Path(db_path)
    build_id = datetime.now(timezone.utc).isoformat()
    with sqlite3.connect(resolved_db_path) as connection:
        connection.row_factory = sqlite3.Row
        sources = [
            {
                "museum_id": row["museum_id"],
                "museum_name": row["museum_name"],
                "source_key": row["source_key"],
                "source_name": row["source_name"],
                "artwork_count": int(row["artwork_count"]),
            }
            for row in connection.execute(
                """
                SELECT
                    m.museum_id,
                    m.display_name AS museum_name,
                    ds.source_key,
                    ds.display_name AS source_name,
                    COUNT(a.artwork_pk) AS artwork_count
                FROM data_sources ds
                JOIN museums m ON m.museum_id = ds.museum_id
                LEFT JOIN artworks a
                    ON a.museum_id = ds.museum_id
                   AND a.source_key = ds.source_key
                GROUP BY m.museum_id, m.display_name, m.sort_order, ds.source_key, ds.display_name
                ORDER BY m.sort_order, ds.is_default DESC, ds.source_key
                """
            )
        ]
        run_statuses = {
            row["status"]: int(row["count"])
            for row in connection.execute(
                """
                SELECT status, COUNT(*) AS count
                FROM crawl_runs
                GROUP BY status
                """
            )
        }
        latest_run_row = connection.execute(
            """
            SELECT run_id, started_at, finished_at, status, manifest_json
            FROM crawl_runs
            ORDER BY started_at DESC, run_id DESC
            LIMIT 1
            """
        ).fetchone()
        error_count = int(connection.execute("SELECT COUNT(*) FROM crawl_errors").fetchone()[0])

    return {
        "build_id": build_id,
        "schema_version": SCHEMA_VERSION,
        "crawler_version": os.getenv("MUSEUMMUSE_CRAWLER_VERSION"),
        "database": str(resolved_db_path),
        "artwork_count": sum(source["artwork_count"] for source in sources),
        "sources": sources,
        "crawl_runs": {
            "by_status": run_statuses,
            "latest": dict(latest_run_row) if latest_run_row is not None else None,
        },
        "error_count": error_count,
    }


if __name__ == "__main__":
    main()
