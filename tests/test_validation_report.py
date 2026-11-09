from __future__ import annotations

import csv
import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("report", ROOT / "sdcli-scripts/lib/generate_validation_report.py")
report = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = report
spec.loader.exec_module(report)


class ReportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.addCleanup(self.temp.cleanup)
        self.phases = self.root / "phase_status.tsv"
        self.phases.write_text("timestamp\tphase\tstate\texit_code\tattempt\tnote\n" + "".join(
            f"t\t{phase}\tsucceeded\t0\t1\t\n" for phase in
            ("capture", "convert", "generate", "datamove", "offload", "deploy", "load", "postdeploy")
        ))
        (self.root / "deploy_manifest.tsv").write_text(
            "phase\tpath\tstatus\tnote\n"
            "deploy\tsdcli/APP/tables.sql\texecuted\t\n"
            "postdeploy\tsdcli/APP/procedures.sql\texecuted\t\n"
        )
        (self.root / "reconciliation.tsv").write_text(
            "source_object\ttarget_object\tdata_file\texported_rows\tloaded_rows\trejected_rows\tdiscarded_rows\ttarget_rows\tstatus\treason\n"
            "demo.sales.orders\tAPP.ORDERS\tdata/orders.dat\t2\t2\t0\t0\t2\tPASS\t\n"
        )
        self.diagnostics = self.root / "target_object_diagnostics.csv"
        self.write_diagnostics([])

    def write_diagnostics(self, rows):
        with self.diagnostics.open("w", newline="", encoding="utf-8") as handle:
            writer = csv.writer(handle, quoting=csv.QUOTE_ALL)
            writer.writerow(("owner", "object_name", "object_type", "status", "error_line", "error_position", "error_message"))
            writer.writerows(rows)

    def build(self):
        return report.build_report(self.root, "demo", "sample-run")

    def test_pass_needs_no_inventory_or_log_scan(self):
        (self.root / "migrate.log").write_text("historical ERROR\nSQL*Loader-292: informational\n")
        self.assertEqual("PASS", self.build().status)
        self.assertFalse(hasattr(report, "load_inventory"))

    def test_latest_retry_and_current_validation_do_not_preserve_old_failure(self):
        with self.phases.open("a") as handle:
            handle.write("t\tpostdeploy\tfailed\t1\t2\terror\n")
            handle.write("t\tpostdeploy\tsucceeded\t0\t3\t\n")
            handle.write("t\tvalidate\tfailed\t1\t1\told result\n")
            handle.write("t\tvalidate\tstarted\t\t2\t\n")
        self.assertEqual("PASS", self.build().status)

    def test_failed_phase_wins_over_missing_diagnostics(self):
        with self.phases.open("a") as handle:
            handle.write("t\tload\tfailed\t1\t2\tSQL error\n")
        self.diagnostics.unlink()
        data = self.build()
        self.assertEqual("FAIL", data.status)
        self.assertTrue(data.incomplete)

    def test_interrupted_rerun_is_incomplete(self):
        with self.phases.open("a") as handle:
            handle.write("t\tpostdeploy\tstarted\t\t2\t\n")
        self.assertEqual("INCOMPLETE", self.build().status)

    def test_one_script_failure_counts_once_and_retry_recovers(self):
        manifest = self.root / "deploy_manifest.tsv"
        with manifest.open("a") as handle:
            handle.write("plan\tsdcli/APP/master.sql\tcontrol\tlegacy\n")
            handle.write("postdeploy\t__phase_complete__\tpending\tlegacy\n")
            handle.write("postdeploy\tsdcli/APP/procedures.sql\tfailed\tSQL error\n")
        data = self.build()
        self.assertEqual("FAIL", data.status)
        self.assertEqual(1, data.failed_scripts)
        with manifest.open("a") as handle:
            handle.write("postdeploy\tsdcli/APP/procedures.sql\texecuted\t\n")
        self.assertEqual("PASS", self.build().status)

    def test_quoted_multiline_compiler_message_and_invalid_without_message(self):
        message = 'PLS-00103: found "token", expected expression\nsecond\tline <tag>'
        self.write_diagnostics([
            ("APP", "SEARCH", "PROCEDURE", "INVALID", 12, 4, message),
            ("APP", "OTHER", "VIEW", "INVALID", "", "", ""),
        ])
        (self.root / "reconciliation.tsv").unlink()
        data = self.build()
        self.assertEqual("FAIL", data.status)
        self.assertEqual(2, data.invalid_objects)
        self.assertEqual(1, data.compiler_errors)
        self.assertEqual(message, data.diagnostics[0]["error_message"])

    def test_header_only_is_zero_but_missing_or_malformed_is_incomplete(self):
        self.assertEqual("PASS", self.build().status)
        for bad in ("", '"owner",broken\n', '"unterminated\n'):
            self.diagnostics.write_text(bad)
            self.assertEqual("INCOMPLETE", self.build().status)

    def test_inconsistent_pass_row_is_not_accepted(self):
        path = self.root / "reconciliation.tsv"
        path.write_text(path.read_text().replace("\t2\t2\t0\t0\t2\tPASS", "\t2\t1\t0\t0\t1\tPASS"))
        self.assertEqual("INCOMPLETE", self.build().status)

    def test_outputs_share_result_and_show_readable_diagnostics(self):
        self.write_diagnostics([("APP", "SEARCH", "PROCEDURE", "INVALID", 1, 2, 'bad "token"\nnext <tag>')])
        (self.root / "idmap").mkdir()
        (self.root / "idmap/schema_mapping.tsv").write_text("source_schema\ttarget_schema\nsales\tAPP\n")
        output = self.root / "migration_report.html"
        rc = report.main(["--evidence-dir", str(self.root), "--output", str(output), "--migration", "demo<script>", "--run-id", "sample-run"])
        self.assertEqual(2, rc)
        html = output.read_text()
        text = output.with_suffix(".txt").read_text()
        for heading in ("Migration Summary", "Schema Mapping", "Table Data Transfer", "Scripts Requiring Attention", "Objects Requiring Repair"):
            self.assertIn(heading, html)
            self.assertIn(heading, text)
        for removed in ("Evidence Health", "Metadata Coverage", "Inventory Counts", "total_issues"):
            self.assertNotIn(removed, html + text)
        self.assertIn("demo&lt;script&gt;", html)
        self.assertIn("Line 1:2", text)
        self.assertIn("status=FAIL", (self.root / "validation_summary.txt").read_text())


if __name__ == "__main__":
    unittest.main()
