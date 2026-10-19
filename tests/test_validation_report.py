from __future__ import annotations

import importlib.util
import io
import shutil
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = REPO_ROOT / "sdcli-scripts" / "lib" / "generate_validation_report.py"
SPEC = importlib.util.spec_from_file_location("validation_report", MODULE_PATH)
assert SPEC and SPEC.loader
report = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = report
SPEC.loader.exec_module(report)

FIXTURE_DIR = REPO_ROOT / "tests" / "fixtures" / "validation" / "base"
INVENTORY_HEADER = (
    "schema\tcategory\tobject_name\tparent_schema\tparent_name\tsubtype\t"
    "ordinal\tattribute_name\tattribute_value\tstatus\tdetail\torigin\n"
)


class ReportEvidenceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.evidence_dir = Path(self.temporary.name)
        for name in (
            "validation_checks.tsv",
            "reconciliation.tsv",
            "source_object_inventory.tsv",
            "target_object_inventory.tsv",
        ):
            shutil.copy(FIXTURE_DIR / name, self.evidence_dir / name)
        (self.evidence_dir / "deploy_manifest.tsv").write_text(
            "phase\tpath\tstatus\tnote\n"
            "plan\tsdcli/APP/master.sql\tcontrol\tordered include source\n"
            "deploy\tsdcli/APP/user.sql\texecuted\t\n"
            "deploy\tsdcli/APP/tables.sql\texecuted\tpre-data master include\n"
            "postdeploy\tsdcli/APP/indexes.sql\texecuted\tpost-data master include\n"
            "postdeploy\t__phase_complete__\texecuted\tpostdeploy phase completed\n",
            encoding="utf-8",
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def build(self):
        return report._build_report_data(
            self.evidence_dir,
            "demo",
            "20261019_120000",
            "2026-10-19T01:00:00Z",
        )

    def test_report_uses_only_direct_evidence(self) -> None:
        data = self.build()

        self.assertEqual("PASS", data.status)
        self.assertEqual(2, len(data.reconciliation))
        self.assertEqual(5, len(data.deployment_records))
        metadata = next(row for row in data.summary if row.check == "metadata_coverage")
        self.assertEqual("NOT_EVALUATED", metadata.status)
        self.assertIn("structured source-to-converted object mapping", metadata.detail)
        self.assertFalse(hasattr(report, "parse_generated_inventory"))
        self.assertFalse(hasattr(report, "compare_objects"))
        self.assertFalse(hasattr(report, "_strip_sql_comments"))

    def test_missing_target_inventory_is_incomplete_without_invented_findings(self) -> None:
        (self.evidence_dir / "target_object_inventory.tsv").unlink()

        data = self.build()
        output = self.evidence_dir / "migration_report.txt"
        report.render_text_report(data, output)
        text = output.read_text(encoding="utf-8")

        self.assertEqual("INCOMPLETE", data.status)
        invalid_summary = next(
            row for row in data.summary if row.check == "invalid_target_objects"
        )
        self.assertEqual("INCOMPLETE", invalid_summary.status)
        self.assertIn("target inventory", text)
        self.assertNotIn("MISSING_IN_TARGET", text)
        self.assertNotIn("EXTRA_IN_TARGET", text)

    def test_missing_deployment_manifest_is_not_reported_as_pass(self) -> None:
        (self.evidence_dir / "deploy_manifest.tsv").unlink()

        data = self.build()
        deployment = next(row for row in data.summary if row.check == "deployment_scripts")

        self.assertEqual("INCOMPLETE", data.status)
        self.assertEqual("INCOMPLETE", deployment.status)

    def test_plan_only_deployment_manifest_is_incomplete(self) -> None:
        (self.evidence_dir / "deploy_manifest.tsv").write_text(
            "phase\tpath\tstatus\tnote\n"
            "plan\tsdcli/APP/master.sql\tcontrol\tordered include source\n",
            encoding="utf-8",
        )

        data = self.build()
        deployment = next(row for row in data.summary if row.check == "deployment_scripts")

        self.assertEqual("INCOMPLETE", data.status)
        self.assertEqual("INCOMPLETE", deployment.status)

    def test_deploy_without_completed_postdeploy_is_incomplete(self) -> None:
        (self.evidence_dir / "deploy_manifest.tsv").write_text(
            "phase\tpath\tstatus\tnote\n"
            "plan\tsdcli/APP/master.sql\tcontrol\tordered include source\n"
            "deploy\tsdcli/APP/user.sql\texecuted\t\n"
            "deploy\tsdcli/APP/tables.sql\texecuted\tpre-data master include\n",
            encoding="utf-8",
        )

        data = self.build()
        deployment = next(row for row in data.summary if row.check == "deployment_scripts")

        self.assertEqual("INCOMPLETE", data.status)
        self.assertEqual("INCOMPLETE", deployment.status)
        self.assertIn("postdeploy_complete=0", deployment.detail)

    def test_not_run_deployment_is_incomplete(self) -> None:
        manifest = self.evidence_dir / "deploy_manifest.tsv"
        manifest.write_text(
            manifest.read_text(encoding="utf-8")
            + "postdeploy\tsdcli/APP/routines.sql\tnot_run\tawaiting manual correction\n",
            encoding="utf-8",
        )

        data = self.build()
        deployment = next(row for row in data.summary if row.check == "deployment_scripts")

        self.assertEqual("INCOMPLETE", data.status)
        self.assertEqual("INCOMPLETE", deployment.status)

    def test_unknown_deployment_status_is_incomplete_evidence(self) -> None:
        manifest = self.evidence_dir / "deploy_manifest.tsv"
        manifest.write_text(
            manifest.read_text(encoding="utf-8")
            + "postdeploy\tsdcli/APP/routines.sql\tmaybe\tunknown state\n",
            encoding="utf-8",
        )

        data = self.build()

        self.assertEqual("INCOMPLETE", data.status)
        self.assertTrue(
            any(row.section == "deployment manifest" for row in data.evidence_health)
        )

    def test_invalid_objects_include_structured_compiler_diagnostics(self) -> None:
        target = self.evidence_dir / "target_object_inventory.tsv"
        with target.open("a", encoding="utf-8") as handle:
            handle.write(
                "APP\tROUTINES\tBROKEN_PROC\t\t\tPROCEDURE\t\t\t\tINVALID\t\toracle\n"
                "APP\tCOMPILER_ERRORS\tBROKEN_PROC\tAPP\tBROKEN_PROC\tPROCEDURE\t1\tline_position\t10:7\tINVALID\tPLS-00103: bad token\toracle\n"
                "APP\tCOMPILER_ERRORS\tBROKEN_PROC\tAPP\tBROKEN_PROC\tPROCEDURE\t2\tline_position\t11:2\tINVALID\tPLS-00103: bad token\toracle\n"
            )
        checks = self.evidence_dir / "validation_checks.tsv"
        checks.write_text(
            checks.read_text(encoding="utf-8").replace(
                "target_objects\tPASS\t0\tno issues",
                "target_objects\tFAIL\t1\tOracle invalid objects or compiler errors",
            ),
            encoding="utf-8",
        )

        data = self.build()

        self.assertEqual("FAIL", data.status)
        self.assertEqual(2, len(data.invalid_objects))
        self.assertEqual("10", data.invalid_objects[0].line)
        self.assertEqual("7", data.invalid_objects[0].position)
        self.assertEqual("PLS-00103: bad token", data.invalid_objects[0].message)
        invalid_summary = next(
            row for row in data.summary if row.check == "invalid_target_objects"
        )
        self.assertEqual(1, invalid_summary.issues)
        self.assertIn("compiler_errors=2", invalid_summary.detail)

    def test_quoted_case_sensitive_objects_keep_separate_diagnostics(self) -> None:
        target = self.evidence_dir / "target_object_inventory.tsv"
        with target.open("a", encoding="utf-8") as handle:
            handle.write(
                "APP\tROUTINES\tCalc\t\t\tPROCEDURE\t\t\t\tINVALID\tfirst error\toracle\n"
                "APP\tROUTINES\tCALC\t\t\tPROCEDURE\t\t\t\tINVALID\tsecond error\toracle\n"
            )

        data = self.build()

        self.assertEqual(["CALC", "Calc"], sorted(row.name for row in data.invalid_objects))

    def test_latest_deployment_outcome_supersedes_an_earlier_failure(self) -> None:
        manifest = self.evidence_dir / "deploy_manifest.tsv"
        manifest.write_text(
            manifest.read_text(encoding="utf-8")
            + "postdeploy\tsdcli/APP/routines.sql\tfailed\tSQL errors\n"
            + "postdeploy\tsdcli/APP/routines.sql\texecuted\tmanual fix rerun\n",
            encoding="utf-8",
        )

        data = self.build()
        routine = next(
            row
            for row in data.deployment_records
            if row.path == "sdcli/APP/routines.sql"
        )

        self.assertEqual("executed", routine.status)
        self.assertEqual("PASS", data.status)

    def test_current_failed_deployment_is_a_concrete_failure(self) -> None:
        manifest = self.evidence_dir / "deploy_manifest.tsv"
        manifest.write_text(
            manifest.read_text(encoding="utf-8")
            + "postdeploy\tsdcli/APP/routines.sql\tfailed\tpost-data SQL errors\n",
            encoding="utf-8",
        )

        data = self.build()

        self.assertEqual("FAIL", data.status)
        deployment = next(row for row in data.summary if row.check == "deployment_scripts")
        self.assertEqual("FAIL", deployment.status)
        self.assertEqual(1, deployment.issues)

    def test_reports_share_sections_escape_html_and_omit_ddl_comparison(self) -> None:
        data = report._build_report_data(
            self.evidence_dir,
            "demo<script>",
            "20261019_120000",
            "2026-10-19T01:00:00Z",
        )
        html_output = self.evidence_dir / "migration_report.html"
        text_output = self.evidence_dir / "migration_report.txt"

        report.render_report(data, html_output)
        report.render_text_report(data, text_output)
        html_text = html_output.read_text(encoding="utf-8")
        terminal_text = text_output.read_text(encoding="utf-8")

        for heading in (
            "Validation Summary",
            "Data Reconciliation",
            "Deployment Script Outcomes",
            "Invalid Oracle Objects and Compiler Diagnostics",
            "Metadata Coverage",
            "Inventory Counts",
            "Evidence Health",
        ):
            self.assertIn(heading, html_text)
            self.assertIn(heading, terminal_text)
        self.assertIn("demo&lt;script&gt;", html_text)
        self.assertNotIn("demo<script>", html_text)
        self.assertIn("demo<script>", terminal_text)
        for obsolete in ("DIFFERENT", "MISSING_IN_CONVERSION", "EXTRA_IN_TARGET"):
            self.assertNotIn(obsolete, html_text)
            self.assertNotIn(obsolete, terminal_text)

    def test_empty_inventory_is_incomplete_evidence(self) -> None:
        (self.evidence_dir / "source_object_inventory.tsv").write_text(
            INVENTORY_HEADER, encoding="utf-8"
        )

        data = self.build()

        self.assertEqual("INCOMPLETE", data.status)
        self.assertTrue(
            any(row.section == "source inventory" for row in data.evidence_health)
        )

    def test_truncated_inventory_row_is_incomplete_without_crashing(self) -> None:
        (self.evidence_dir / "target_object_inventory.tsv").write_text(
            INVENTORY_HEADER + "APP\tTABLES\tCUSTOMER\n", encoding="utf-8"
        )

        data = self.build()

        self.assertEqual("INCOMPLETE", data.status)
        self.assertTrue(
            any(row.section == "target inventory" for row in data.evidence_health)
        )

    def test_validation_checks_require_the_complete_contract(self) -> None:
        (self.evidence_dir / "validation_checks.tsv").write_text(
            "check\tstatus\tissues\tdetail\nrun_log\tPASS\t0\tno issues\n",
            encoding="utf-8",
        )

        data = self.build()

        self.assertEqual("INCOMPLETE", data.status)
        self.assertTrue(
            any(row.section == "validation checks" for row in data.evidence_health)
        )

    def test_pass_reconciliation_requires_valid_row_counts(self) -> None:
        reconciliation = self.evidence_dir / "reconciliation.tsv"
        reconciliation.write_text(
            reconciliation.read_text(encoding="utf-8").replace(
                "demo.sales.customer\tAPP.CUSTOMER\tdata/sales/customer.dat\t2\t2\t0\t0\t2\tPASS",
                "demo.sales.customer\tAPP.CUSTOMER\tdata/sales/customer.dat\tNaN\t2\t0\t0\t2\tPASS",
            ),
            encoding="utf-8",
        )

        data = self.build()

        self.assertEqual("INCOMPLETE", data.status)
        self.assertTrue(
            any(row.section == "data reconciliation" for row in data.evidence_health)
        )

    def test_cli_writes_both_reports_without_sdcli_directory(self) -> None:
        output = self.evidence_dir / "migration_report.html"
        stdout = io.StringIO()

        with redirect_stdout(stdout):
            rc = report.main(
                (
                    "--evidence-dir",
                    str(self.evidence_dir),
                    "--output",
                    str(output),
                    "--migration",
                    "demo",
                    "--run-id",
                    "20261019_120000",
                )
            )

        self.assertEqual(0, rc)
        self.assertTrue(output.is_file())
        self.assertTrue(output.with_suffix(".txt").is_file())
        self.assertIn("REPORT_RESULT status=PASS", stdout.getvalue())
        self.assertIn("not_evaluated_sections=1", stdout.getvalue())


if __name__ == "__main__":
    unittest.main()
