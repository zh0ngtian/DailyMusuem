import csv
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT_PATH = Path(__file__).resolve().parents[1] / "build_british_museum_department_index.py"
SPEC = importlib.util.spec_from_file_location("build_british_museum_department_index", SCRIPT_PATH)
builder = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = builder
SPEC.loader.exec_module(builder)


class BritishMuseumDepartmentIndexTests(unittest.TestCase):
    def test_builds_department_files_manifest_and_reports(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_path = Path(temp_dir)
            input_path = temp_path / "export.csv"
            output_dir = temp_path / "output"

            with input_path.open("w", encoding="utf-8", newline="") as handle:
                writer = csv.DictWriter(handle, fieldnames=["Object page", "Museum number", "Department"])
                writer.writeheader()
                writer.writerow(
                    {
                        "Object page": "https://www.britishmuseum.org/collection/object/Y_EA24",
                        "Museum number": "EA24",
                        "Department": "Egypt and Sudan",
                    }
                )
                writer.writerow(
                    {
                        "Object page": "https://www.britishmuseum.org/collection/object/Y_EA24",
                        "Museum number": "EA24",
                        "Department": "Egypt and Sudan",
                    }
                )
                writer.writerow(
                    {
                        "Object page": "https://www.britishmuseum.org/collection/object/P_1880-0214-25",
                        "Museum number": "1880,0214.25",
                        "Department": "Prints and Drawings",
                    }
                )
                writer.writerow(
                    {
                        "Object page": "https://www.britishmuseum.org/collection/object/P_1880-0214-25",
                        "Museum number": "1880,0214.25",
                        "Department": "Asia",
                    }
                )
                writer.writerow(
                    {
                        "Object page": "https://www.britishmuseum.org/collection/object/C_R-10089",
                        "Museum number": "R.10089",
                        "Department": "Unsupported Department",
                    }
                )
                writer.writerow({"Object page": "", "Museum number": "As1905,-.643", "Department": "Asia"})
                writer.writerow({"Object page": "", "Museum number": "", "Department": "Asia"})

            builder.main(["--input", str(input_path), "--output-dir", str(output_dir)])

            manifest = json.loads((output_dir / "british_museum_department_manifest.json").read_text())
            departments = {item["departmentID"]: item for item in manifest["departments"]}
            self.assertEqual(departments["egypt-sudan"]["count"], 1)
            self.assertEqual(departments["prints-drawings"]["count"], 0)
            self.assertEqual(departments["asia"]["count"], 1)

            egypt = json.loads((output_dir / "departments" / "egypt-sudan.json").read_text())
            self.assertEqual(egypt["objectIDs"], ["Y_EA24"])
            self.assertEqual(egypt["count"], len(egypt["objectIDs"]))

            prints = json.loads((output_dir / "departments" / "prints-drawings.json").read_text())
            self.assertEqual(prints["objectIDs"], [])

            asia = json.loads((output_dir / "departments" / "asia.json").read_text())
            self.assertEqual(asia["objectIDs"], ["A_As1905-643"])

            unknown = json.loads((output_dir / "reports" / "unknown_department.json").read_text())
            self.assertEqual(len(unknown), 1)
            self.assertEqual(unknown[0]["reason"], "unknown_department")

            missing = json.loads((output_dir / "reports" / "missing_object_id.json").read_text())
            self.assertEqual(len(missing), 1)
            self.assertEqual(missing[0]["reason"], "missing_object_id")

            conflicts = json.loads((output_dir / "reports" / "conflicting_department.json").read_text())
            self.assertEqual(len(conflicts), 1)
            self.assertEqual(conflicts[0]["objectID"], "P_1880-0214-25")

            summary = json.loads((output_dir / "reports" / "build_summary.json").read_text())
            self.assertEqual(summary["totalRows"], 7)
            self.assertEqual(summary["duplicateRecords"], 2)
            self.assertEqual(summary["uniqueObjectIDs"], 3)
            self.assertEqual(summary["indexedObjectIDs"], 2)
            self.assertEqual(summary["inferredObjectIDRecords"], 1)
            self.assertEqual(summary["unknownDepartmentRecords"], 1)
            self.assertEqual(summary["missingObjectIDRecords"], 1)


if __name__ == "__main__":
    unittest.main()
