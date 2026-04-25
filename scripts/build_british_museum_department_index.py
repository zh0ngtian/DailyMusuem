#!/usr/bin/env python3
"""Build British Museum Department -> object ID indexes from CSV exports.

The British Museum Collection online download flow exports search results in
spreadsheet form. This script intentionally consumes those offline exports and
does not crawl detail pages.
"""

from __future__ import annotations

import argparse
import csv
import glob
import json
import re
import shutil
import sys
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


OBJECT_URL_RE = re.compile(r"/collection/object/([^/?#\s]+)")
OBJECT_ID_RE = re.compile(r"^[A-Za-z]+_[^\s/?#]+$")
WHITESPACE_RE = re.compile(r"\s+")


@dataclass(frozen=True)
class Department:
    raw: str
    department_id: str
    display_name: str


DEPARTMENTS: tuple[Department, ...] = (
    Department("Africa, Oceania and the Americas", "africa-oceania-americas", "非洲、大洋洲与美洲"),
    Department("Asia", "asia", "亚洲"),
    Department("Britain, Europe and Prehistory", "britain-europe-prehistory", "不列颠、欧洲与史前"),
    Department("Egypt and Sudan", "egypt-sudan", "埃及与苏丹"),
    Department("Greece and Rome", "greece-rome", "希腊与罗马"),
    Department("Middle East", "middle-east", "中东"),
    Department("Money and Medals", "money-medals", "钱币与奖章"),
    Department("Prints and Drawings", "prints-drawings", "版画与素描"),
)

DEPARTMENT_BY_RAW = {department.raw: department for department in DEPARTMENTS}
DEPARTMENT_BY_ID = {department.department_id: department for department in DEPARTMENTS}
OBJECT_URL_PREFIX_BY_DEPARTMENT_ID = {
    "africa-oceania-americas": "E",
    "asia": "A",
    "britain-europe-prehistory": "H",
    "egypt-sudan": "Y",
    "greece-rome": "G",
    "middle-east": "W",
    "money-medals": "C",
    "prints-drawings": "P",
}

DEPARTMENT_COLUMN_CANDIDATES = (
    "department",
    "departments",
    "dept",
)

OBJECT_ID_COLUMN_CANDIDATES = (
    "objectid",
    "objectidentifier",
    "id",
    "recordid",
    "url",
    "uri",
    "link",
    "objecturl",
    "objectpage",
    "recordurl",
    "recordlink",
    "collectiononline",
)

MUSEUM_NUMBER_COLUMN_CANDIDATES = (
    "museumnumber",
    "regnumber",
    "registrationnumber",
    "bmnumber",
    "bignumber",
    "bmbignumber",
)


def normalize_header(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "", value.casefold())


def normalize_value(value: str | None) -> str:
    if value is None:
        return ""
    return WHITESPACE_RE.sub(" ", value).strip()


def expand_inputs(patterns: Iterable[str]) -> list[Path]:
    paths: list[Path] = []
    for pattern in patterns:
        matches = sorted(glob.glob(pattern))
        if matches:
            paths.extend(Path(match) for match in matches)
        else:
            paths.append(Path(pattern))

    unique_paths: list[Path] = []
    seen: set[Path] = set()
    for path in paths:
        resolved = path.expanduser()
        if resolved not in seen:
            unique_paths.append(resolved)
            seen.add(resolved)

    missing = [str(path) for path in unique_paths if not path.is_file()]
    if missing:
        raise FileNotFoundError("Input file not found: " + ", ".join(missing))

    return unique_paths


def sniff_dialect(path: Path) -> csv.Dialect:
    sample = path.read_text(encoding="utf-8-sig", errors="replace")[:8192]
    try:
        return csv.Sniffer().sniff(sample, delimiters=",\t;")
    except csv.Error:
        if path.suffix.lower() == ".tsv":
            return csv.excel_tab
        return csv.excel


def read_rows(path: Path) -> Iterable[tuple[int, dict[str, str]]]:
    dialect = sniff_dialect(path)
    with path.open("r", encoding="utf-8-sig", errors="replace", newline="") as handle:
        reader = csv.DictReader(handle, dialect=dialect)
        for row_number, row in enumerate(reader, start=2):
            yield row_number, {key or "": value or "" for key, value in row.items()}


def normalized_row(row: dict[str, str]) -> dict[str, str]:
    return {normalize_header(key): normalize_value(value) for key, value in row.items()}


def value_for_candidates(row: dict[str, str], candidates: tuple[str, ...]) -> str:
    for candidate in candidates:
        value = row.get(candidate, "")
        if value:
            return value
    return ""


def extract_object_id_from_value(value: str) -> str:
    value = normalize_value(value)
    if not value:
        return ""

    match = OBJECT_URL_RE.search(value)
    if match:
        return match.group(1)

    if OBJECT_ID_RE.match(value):
        return value

    return ""


def extract_object_id(row: dict[str, str]) -> str:
    for candidate in OBJECT_ID_COLUMN_CANDIDATES:
        object_id = extract_object_id_from_value(row.get(candidate, ""))
        if object_id:
            return object_id

    for value in row.values():
        object_id = extract_object_id_from_value(value)
        if object_id:
            return object_id

    return ""


def infer_object_id_from_museum_number(row: dict[str, str], department: Department) -> str:
    museum_number = value_for_candidates(row, MUSEUM_NUMBER_COLUMN_CANDIDATES)
    if not museum_number:
        return ""

    normalized_number = re.sub(r"^no:\s*", "", museum_number, flags=re.IGNORECASE)
    normalized_number = normalized_number.replace("+", "")
    normalized_number = re.sub(r"[,./\s]+", "-", normalized_number)
    normalized_number = re.sub(r"-+", "-", normalized_number).strip("-")
    if not normalized_number or not re.search(r"\d", normalized_number):
        return ""

    prefix = OBJECT_URL_PREFIX_BY_DEPARTMENT_ID[department.department_id]
    return f"{prefix}_{normalized_number}"


def resolve_department(raw_value: str) -> Department | None:
    raw_value = normalize_value(raw_value)
    if not raw_value:
        return None
    return DEPARTMENT_BY_RAW.get(raw_value)


def report_entry(
    *,
    input_file: Path,
    row_number: int,
    object_id: str,
    department_raw: str,
    row: dict[str, str],
    reason: str,
) -> dict[str, str | int]:
    normalized = normalized_row(row)
    museum_number = value_for_candidates(normalized, MUSEUM_NUMBER_COLUMN_CANDIDATES)
    return {
        "inputFile": str(input_file),
        "rowNumber": row_number,
        "objectID": object_id,
        "museumNumber": museum_number,
        "departmentRaw": department_raw,
        "reason": reason,
    }


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def build_index(input_paths: list[Path], output_dir: Path, clean: bool, infer_from_museum_number: bool) -> None:
    if clean and output_dir.exists():
        shutil.rmtree(output_dir)

    departments_dir = output_dir / "departments"
    reports_dir = output_dir / "reports"
    departments_dir.mkdir(parents=True, exist_ok=True)
    reports_dir.mkdir(parents=True, exist_ok=True)

    department_ids_by_object_id: dict[str, str] = {}
    object_ids_by_department: dict[str, set[str]] = defaultdict(set)
    occurrences_by_object_id: dict[str, list[dict[str, str | int]]] = defaultdict(list)

    unknown_department_entries: list[dict[str, str | int]] = []
    missing_object_id_entries: list[dict[str, str | int]] = []
    conflicting_department_entries: dict[str, dict[str, object]] = {}

    total_rows = 0
    duplicate_records = 0
    inferred_object_id_records = 0

    for input_path in input_paths:
        for row_number, raw_row in read_rows(input_path):
            total_rows += 1
            row = normalized_row(raw_row)
            object_id = extract_object_id(row)
            department_raw = value_for_candidates(row, DEPARTMENT_COLUMN_CANDIDATES)
            department = resolve_department(department_raw)
            if not object_id and department is not None and infer_from_museum_number:
                object_id = infer_object_id_from_museum_number(row, department)
                if object_id:
                    inferred_object_id_records += 1

            if not object_id:
                missing_object_id_entries.append(
                    report_entry(
                        input_file=input_path,
                        row_number=row_number,
                        object_id="",
                        department_raw=department_raw,
                        row=raw_row,
                        reason="missing_object_id",
                    )
                )
                continue

            if department is None:
                reason = "missing_department" if not department_raw else "unknown_department"
                unknown_department_entries.append(
                    report_entry(
                        input_file=input_path,
                        row_number=row_number,
                        object_id=object_id,
                        department_raw=department_raw,
                        row=raw_row,
                        reason=reason,
                    )
                )
                continue

            occurrence = {
                "inputFile": str(input_path),
                "rowNumber": row_number,
                "departmentID": department.department_id,
                "departmentRaw": department.raw,
            }
            occurrences_by_object_id[object_id].append(occurrence)

            existing_department_id = department_ids_by_object_id.get(object_id)
            if existing_department_id is None:
                department_ids_by_object_id[object_id] = department.department_id
                object_ids_by_department[department.department_id].add(object_id)
            elif existing_department_id == department.department_id:
                duplicate_records += 1
            else:
                duplicate_records += 1
                existing_department = DEPARTMENT_BY_ID[existing_department_id]
                object_ids_by_department[existing_department_id].discard(object_id)
                conflicting_department_entries[object_id] = {
                    "objectID": object_id,
                    "existingDepartmentID": existing_department.department_id,
                    "existingDepartmentRaw": existing_department.raw,
                    "newDepartmentID": department.department_id,
                    "newDepartmentRaw": department.raw,
                    "occurrences": occurrences_by_object_id[object_id],
                }

    accepted_records = sum(len(object_ids) for object_ids in object_ids_by_department.values())

    manifest_departments: list[dict[str, str | int]] = []
    for department in DEPARTMENTS:
        object_ids = sorted(object_ids_by_department.get(department.department_id, set()))
        department_file = f"departments/{department.department_id}.json"
        write_json(
            output_dir / department_file,
            {
                "count": len(object_ids),
                "departmentDisplayName": department.display_name,
                "departmentID": department.department_id,
                "departmentRaw": department.raw,
                "objectIDs": object_ids,
            },
        )
        manifest_departments.append(
            {
                "count": len(object_ids),
                "departmentDisplayName": department.display_name,
                "departmentID": department.department_id,
                "departmentRaw": department.raw,
                "file": department_file,
            }
        )

    write_json(output_dir / "british_museum_department_manifest.json", {"departments": manifest_departments})
    write_json(reports_dir / "unknown_department.json", unknown_department_entries)
    write_json(reports_dir / "missing_object_id.json", missing_object_id_entries)
    write_json(
        reports_dir / "conflicting_department.json",
        sorted(conflicting_department_entries.values(), key=lambda entry: str(entry["objectID"])),
    )
    write_json(
        reports_dir / "build_summary.json",
        {
            "acceptedRecords": accepted_records,
            "conflictingDepartmentRecords": len(conflicting_department_entries),
            "countsByDepartment": {
                department.department_id: len(object_ids_by_department.get(department.department_id, set()))
                for department in DEPARTMENTS
            },
            "duplicateRecords": duplicate_records,
            "inputFiles": [str(path) for path in input_paths],
            "inferredObjectIDRecords": inferred_object_id_records,
            "indexedObjectIDs": accepted_records,
            "missingObjectIDRecords": len(missing_object_id_entries),
            "totalRows": total_rows,
            "uniqueObjectIDs": len(department_ids_by_object_id),
            "unknownDepartmentRecords": len(unknown_department_entries),
        },
    )


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Build British Museum Department inverted indexes from exported CSV/TSV files."
    )
    parser.add_argument(
        "--input",
        nargs="+",
        required=True,
        help="One or more British Museum CSV/TSV exports. Globs are accepted.",
    )
    parser.add_argument(
        "--output-dir",
        default="build/british_museum_department_index",
        help="Output directory. Default: build/british_museum_department_index",
    )
    parser.add_argument(
        "--clean",
        action="store_true",
        help="Delete the output directory before writing.",
    )
    parser.add_argument(
        "--no-infer-id-from-museum-number",
        action="store_true",
        help="Do not infer object IDs from Museum number and Department when no object URL/ID column is present.",
    )
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    input_paths = expand_inputs(args.input)
    build_index(
        input_paths,
        Path(args.output_dir),
        args.clean,
        infer_from_museum_number=not args.no_infer_id_from_museum_number,
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except Exception as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1)
