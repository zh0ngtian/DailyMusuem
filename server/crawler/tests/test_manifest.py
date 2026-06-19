import json
import sqlite3
import tempfile
import unittest
from urllib.error import HTTPError

from server.crawler.main import (
    SCHEMA_VERSION,
    build_crawl_status,
    candidate_discovery_minimum,
    crawler_concurrency,
    crawler_page_size,
    detail_candidate_iterator,
    ensure_concurrency,
    ensure_page_size,
    ensure_request_interval,
    ensure_live_detail_limit,
    finish_run,
    has_reached_detail_limit,
    is_permanent_detail_failure,
    live_crawl_museums_for_args,
    live_crawl_status,
    manifest_path_for_db,
    met_department_id_for_category,
    start_run,
    write_manifest,
)
from server.crawler.museums.met import parse_object_payload, store_artwork
from server.crawler.stores import initialize_database, seed_reference_metadata
from server.crawler.tests.test_met import MET_OBJECT_JSON


class ManifestTests(unittest.TestCase):
    def test_write_manifest_summarizes_current_database(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            db_path = f"{directory}/museummuse.sqlite"
            initialize_database(db_path)
            seed_reference_metadata(db_path)
            record = parse_object_payload(MET_OBJECT_JSON)

            with sqlite3.connect(db_path) as connection:
                connection.execute("PRAGMA foreign_keys = ON")
                start_run(connection, "met-test-run", "2026-06-19T00:00:00+00:00")
                store_artwork(connection, record)
                finish_run(
                    connection,
                    "met-test-run",
                    status="succeeded",
                    manifest={"museum": "met", "mode": "sample"},
                )
                connection.commit()

            manifest_path = write_manifest(db_path)
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))

            self.assertEqual(manifest["schema_version"], SCHEMA_VERSION)
            self.assertEqual(manifest["artwork_count"], 1)
            self.assertEqual(manifest["crawl_runs"]["by_status"], {"succeeded": 1})
            self.assertEqual(manifest["crawl_runs"]["latest"]["run_id"], "met-test-run")
            self.assertEqual(manifest["error_count"], 0)

            met_source = next(
                source
                for source in manifest["sources"]
                if source["museum_id"] == "met" and source["source_key"] == "met_api"
            )
            self.assertEqual(met_source["artwork_count"], 1)

    def test_build_crawl_status_requires_full_success_for_completion(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            db_path = f"{directory}/museummuse.sqlite"
            initialize_database(db_path)
            seed_reference_metadata(db_path)
            record = parse_object_payload(MET_OBJECT_JSON)

            with sqlite3.connect(db_path) as connection:
                connection.execute("PRAGMA foreign_keys = ON")
                start_run(connection, "met-full-run", "2026-06-19T00:00:00+00:00")
                store_artwork(connection, record)
                finish_run(
                    connection,
                    "met-full-run",
                    status="succeeded",
                    manifest={
                        "museum": "met",
                        "mode": "network",
                        "full": True,
                        "candidateCount": 1,
                        "attemptedCount": 1,
                        "storedCount": 1,
                    },
                )
                connection.commit()

            status = build_crawl_status(db_path)
            met_target = next(target for target in status["targets"] if target["crawlerID"] == "met")
            nmc_target = next(target for target in status["targets"] if target["crawlerID"] == "nmc")

            self.assertFalse(status["complete"])
            self.assertEqual(met_target["completion"], "complete")
            self.assertEqual(met_target["artworkCount"], 1)
            self.assertEqual(nmc_target["completion"], "missing")

    def test_build_crawl_status_counts_permanent_met_misses_as_complete(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            db_path = f"{directory}/museummuse.sqlite"
            initialize_database(db_path)
            seed_reference_metadata(db_path)

            with sqlite3.connect(db_path) as connection:
                connection.execute("PRAGMA foreign_keys = ON")
                start_run(connection, "met-full-run", "2026-06-19T00:00:00+00:00")
                finish_run(
                    connection,
                    "met-full-run",
                    status="succeeded",
                    manifest={
                        "museum": "met",
                        "mode": "network",
                        "full": True,
                        "candidateCount": 1,
                        "attemptedCount": 1,
                        "storedCount": 0,
                        "permanentFailureCount": 1,
                    },
                )
                connection.commit()

            status = build_crawl_status(db_path)
            met_target = next(target for target in status["targets"] if target["crawlerID"] == "met")

            self.assertEqual(met_target["completion"], "complete")
            self.assertEqual(met_target["latestRun"]["permanentFailureCount"], 1)

    def test_non_default_database_uses_distinct_manifest_path(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            default_path = f"{directory}/museummuse.sqlite"
            alternate_path = f"{directory}/museummuse-live-full.sqlite"

            self.assertEqual(str(manifest_path_for_db(default_path)), f"{directory}/manifest.json")
            self.assertEqual(
                str(manifest_path_for_db(alternate_path)),
                f"{directory}/museummuse-live-full.manifest.json",
            )

    def test_live_detail_limit_helpers_treat_max_details_as_success_target(self) -> None:
        self.assertEqual(detail_candidate_iterator([1, 2], 0), [])
        self.assertEqual(detail_candidate_iterator([1, 2], 1), [1, 2])
        self.assertFalse(has_reached_detail_limit(0, 1))
        self.assertTrue(has_reached_detail_limit(1, 1))
        self.assertEqual(live_crawl_status(completed_count=1, candidate_count=10, max_details=1), "succeeded")
        self.assertEqual(live_crawl_status(completed_count=0, candidate_count=10, max_details=1), "partial")

    def test_full_mode_helpers_treat_candidate_count_as_success_target(self) -> None:
        class Args:
            full = True
            max_details = 0

        self.assertIsNone(candidate_discovery_minimum(Args()))
        self.assertEqual(detail_candidate_iterator([1, 2], 0, full=True), [1, 2])
        self.assertFalse(has_reached_detail_limit(100, 0, full=True))
        self.assertEqual(
            live_crawl_status(completed_count=2, candidate_count=2, max_details=0, full=True),
            "succeeded",
        )
        self.assertEqual(
            live_crawl_status(completed_count=1, candidate_count=2, max_details=0, full=True),
            "partial",
        )

    def test_live_crawl_requires_explicit_detail_budget(self) -> None:
        class Args:
            full = False
            max_details = 0

        with self.assertRaises(SystemExit):
            ensure_live_detail_limit(Args())

    def test_full_crawl_cannot_combine_with_detail_budget(self) -> None:
        class Args:
            full = True
            max_details = 1

        with self.assertRaises(SystemExit):
            ensure_live_detail_limit(Args())

    def test_page_size_helper_uses_default_or_positive_override(self) -> None:
        class DefaultArgs:
            page_size = None

        class OverrideArgs:
            page_size = 50

        class InvalidArgs:
            page_size = 0

        self.assertEqual(crawler_page_size(DefaultArgs(), default=10), 10)
        self.assertEqual(crawler_page_size(OverrideArgs(), default=10), 50)
        ensure_page_size(OverrideArgs())
        with self.assertRaises(SystemExit):
            ensure_page_size(InvalidArgs())

    def test_request_interval_helper_allows_non_nmc_overrides(self) -> None:
        class ShanghaiArgs:
            museum = "shm"
            request_interval = 0.1

        class InvalidArgs:
            museum = "shm"
            request_interval = -0.1

        class NmcArgs:
            museum = "nmc"
            request_interval = 0.1

        ensure_request_interval(ShanghaiArgs())
        with self.assertRaises(SystemExit):
            ensure_request_interval(InvalidArgs())
        with self.assertRaises(SystemExit):
            ensure_request_interval(NmcArgs())

    def test_permanent_detail_failure_is_met_only(self) -> None:
        error = HTTPError("https://example.com", 404, "Not Found", hdrs=None, fp=None)

        self.assertTrue(is_permanent_detail_failure("met", error))
        self.assertTrue(is_permanent_detail_failure("met", TimeoutError("timed out")))
        self.assertFalse(is_permanent_detail_failure("shm", error))

    def test_concurrency_helper_allows_non_nmc_overrides(self) -> None:
        class DefaultArgs:
            museum = "shm"
            concurrency = None

        class ShanghaiArgs:
            museum = "shm"
            concurrency = 10

        class InvalidArgs:
            museum = "shm"
            concurrency = 0

        class NmcArgs:
            museum = "nmc"
            concurrency = 10

        self.assertEqual(crawler_concurrency(DefaultArgs()), 1)
        self.assertEqual(crawler_concurrency(ShanghaiArgs()), 10)
        ensure_concurrency(ShanghaiArgs())
        with self.assertRaises(SystemExit):
            ensure_concurrency(InvalidArgs())
        with self.assertRaises(SystemExit):
            ensure_concurrency(NmcArgs())

    def test_all_crawl_can_exclude_high_risk_sources(self) -> None:
        class Args:
            exclude_museum = ["nmc"]

        self.assertEqual(
            live_crawl_museums_for_args(Args()),
            ["met", "tnm", "nnm-colbase", "nnm-official", "shm", "guimet"],
        )

    def test_met_category_id_maps_to_department_id(self) -> None:
        self.assertEqual(met_department_id_for_category("africa-oceania-americas"), 5)
        self.assertEqual(met_department_id_for_category("european-paintings"), 11)
        self.assertIsNone(met_department_id_for_category(None))
        self.assertIsNone(met_department_id_for_category("unknown"))


if __name__ == "__main__":
    unittest.main()
