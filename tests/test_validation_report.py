from __future__ import annotations

import importlib.util
import shutil
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from io import StringIO
from pathlib import Path
from unittest import mock


REPO_ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = REPO_ROOT / "sdcli-scripts" / "lib" / "generate_validation_report.py"
SPEC = importlib.util.spec_from_file_location("generate_validation_report", MODULE_PATH)
REPORT = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
sys.modules[SPEC.name] = REPORT
SPEC.loader.exec_module(REPORT)

FIXTURE_ROOT = REPO_ROOT / "tests" / "fixtures" / "validation" / "base"


def object_record(
    schema: str,
    category: str,
    name: str,
    *,
    subtype: str = "",
    parent_schema: str = "",
    parent_name: str = "",
    status: str = "VALID",
    attributes: tuple = (),
):
    return REPORT.ObjectRecord(
        schema=schema,
        category=category,
        name=name,
        parent_schema=parent_schema,
        parent_name=parent_name,
        subtype=subtype,
        attributes=attributes,
        status=status,
        detail="",
        origin="fixture",
    )


class InventoryAndMappingTests(unittest.TestCase):
    def test_inventory_reader_preserves_mixed_case_spaces_and_quotes(self):
        with tempfile.TemporaryDirectory() as tmp:
            inventory = Path(tmp) / "inventory.tsv"
            inventory.write_text(
                "schema\tcategory\tobject_name\tparent_schema\tparent_name\t"
                "subtype\tordinal\tattribute_name\tattribute_value\tstatus\tdetail\torigin\n"
                'Mixed Case\tVIEWS\tA "Quoted" View\t\t\tVIEW\t\t\t\tVALID\t\tfixture\n',
                encoding="utf-8",
            )
            records = REPORT.load_inventory(inventory)

        self.assertEqual(len(records), 1)
        self.assertEqual(records[0].schema, "Mixed Case")
        self.assertEqual(records[0].name, 'A "Quoted" View')

    def test_status_evidence_maps_multiple_tables_by_full_data_path(self):
        mappings = REPORT.build_table_mappings(FIXTURE_ROOT)

        self.assertEqual(
            mappings,
            [
                REPORT.SchemaMapping(
                    source_schema="sales",
                    target_schema="APP",
                    method="DATA_FILE",
                    evidence_count=2,
                    status="MAPPED",
                    reason="",
                )
            ],
        )

    def test_relative_and_absolute_paths_normalize_to_the_same_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            evidence = Path(tmp)
            data_file = evidence / "data" / "customer.dat"
            data_file.parent.mkdir()
            data_file.touch()
            (evidence / "bcp_status.tsv").write_text(
                "0\tdemo.sales.customer\tdata/customer.dat\t1\n", encoding="utf-8"
            )
            (evidence / "sqlldr_status.tsv").write_text(
                f"0\tAPP.CUSTOMER\tcontrol.ctl\t{data_file}\t1\t0\t0\tloader.log\n",
                encoding="utf-8",
            )

            mappings = REPORT.build_table_mappings(evidence)

        self.assertEqual(mappings[0].status, "MAPPED")
        self.assertEqual(mappings[0].evidence_count, 1)

    def test_same_basename_in_different_directories_does_not_cross_map(self):
        with tempfile.TemporaryDirectory() as tmp:
            evidence = Path(tmp)
            (evidence / "bcp_status.tsv").write_text(
                "0\tdemo.sales.customer\ta/customer.dat\t1\n"
                "0\tdemo.audit.customer\tb/customer.dat\t1\n",
                encoding="utf-8",
            )
            (evidence / "sqlldr_status.tsv").write_text(
                "0\tAPP.CUSTOMER\tapp.ctl\ta/customer.dat\t1\t0\t0\tapp.log\n"
                "0\tAUDIT_APP.CUSTOMER\taudit.ctl\tb/customer.dat\t1\t0\t0\taudit.log\n",
                encoding="utf-8",
            )

            mappings = REPORT.build_table_mappings(evidence)

        self.assertEqual(
            {(row.source_schema, row.target_schema) for row in mappings},
            {("sales", "APP"), ("audit", "AUDIT_APP")},
        )
        self.assertTrue(all(row.status == "MAPPED" for row in mappings))

    def test_duplicate_unpaired_failed_and_conflicting_status_records_fail_mapping(self):
        with tempfile.TemporaryDirectory() as tmp:
            evidence = Path(tmp)
            (evidence / "bcp_status.tsv").write_text(
                "0\tdemo.sales.customer\tdata/customer.dat\t1\n"
                "0\tdemo.sales.customer_copy\tdata/customer.dat\t1\n"
                "7\tdemo.sales.failed\tdata/failed.dat\t\n"
                "0\tdemo.sales.unpaired\tdata/unpaired.dat\t1\n"
                "0\tdemo.sales.invoice\tdata/invoice.dat\t1\n"
                "0\tdemo.sales.orders\tdata/orders.dat\t1\n",
                encoding="utf-8",
            )
            (evidence / "sqlldr_status.tsv").write_text(
                "0\tAPP.CUSTOMER\tc.ctl\tdata/customer.dat\t1\t0\t0\tc.log\n"
                "0\tAPP.INVOICE\ti.ctl\tdata/invoice.dat\t1\t0\t0\ti.log\n"
                "0\tOTHER.ORDERS\to.ctl\tdata/orders.dat\t1\t0\t0\to.log\n",
                encoding="utf-8",
            )

            mappings = REPORT.build_table_mappings(evidence)

        self.assertTrue(any(row.status == "UNRESOLVED" for row in mappings))
        reasons = " ".join(row.reason for row in mappings)
        self.assertIn("duplicate", reasons)
        self.assertIn("failed", reasons)
        self.assertIn("unpaired", reasons)
        self.assertIn("multiple target schemas", reasons)

    def test_generated_inventory_follows_master_includes_and_skips_cleanup(self):
        records = REPORT.parse_generated_inventory(FIXTURE_ROOT / "sdcli")
        identities = {(row.schema, row.category, row.name) for row in records}

        self.assertIn(("APP", "TABLES", "CUSTOMER"), identities)
        self.assertIn(("APP", "VIEWS", "ACTIVE CUSTOMERS"), identities)
        self.assertIn(("APP", "ROUTINES", "GetCustomer"), identities)
        self.assertIn(("APP", "PRIMARY_KEYS", "PK_CUSTOMER"), identities)
        self.assertIn(("APP", "INDEXES", "UK_CUSTOMER_NAME"), identities)
        self.assertIn(("Emulation", "PACKAGES", "UTILS"), identities)
        self.assertEqual(sum(1 for row in records if row.name == "CUSTOMER" and row.category == "TABLES"), 1)

    def test_unknown_active_generated_ddl_is_incomplete_evidence(self):
        with tempfile.TemporaryDirectory() as tmp:
            sdcli = Path(tmp) / "sdcli"
            shutil.copytree(FIXTURE_ROOT / "sdcli", sdcli)
            (sdcli / "APP" / "unknown.sql").write_text(
                "CREATE MATERIALIZED VIEW APP.MV_CUSTOMER AS SELECT * FROM APP.CUSTOMER;\n",
                encoding="utf-8",
            )
            with (sdcli / "APP" / "master.sql").open("a", encoding="utf-8") as handle:
                handle.write("@@unknown.sql\n")

            with self.assertRaises(REPORT.EvidenceError):
                REPORT.parse_generated_inventory(sdcli)

    def test_tableless_schema_maps_only_on_unique_object_identity(self):
        source = [object_record("api", "ROUTINES", "GetOrder", subtype="PROCEDURE")]
        generated = [object_record("API_APP", "ROUTINES", "GETORDER", subtype="FUNCTION")]

        mappings = REPORT.resolve_schema_mappings(source, generated, [])

        self.assertEqual(mappings[0].source_schema, "api")
        self.assertEqual(mappings[0].target_schema, "API_APP")
        self.assertEqual(mappings[0].method, "OBJECT_IDENTITY")
        self.assertEqual(mappings[0].status, "MAPPED")

    def test_tableless_tie_remains_unresolved_and_emulation_is_context(self):
        source = [
            object_record("api_one", "VIEWS", "STATUS"),
            object_record("api_two", "VIEWS", "STATUS"),
        ]
        generated = [
            object_record("API_APP", "VIEWS", "STATUS"),
            object_record("Emulation", "PACKAGES", "UTILS"),
        ]

        mappings = REPORT.resolve_schema_mappings(source, generated, [])

        self.assertTrue(
            any(row.target_schema == "API_APP" and row.status == "UNRESOLVED" for row in mappings)
        )
        self.assertTrue(
            any(row.target_schema.casefold() == "emulation" and row.status == "CONTEXT" for row in mappings)
        )


class ComparisonTests(unittest.TestCase):
    def setUp(self):
        self.mapping = [
            REPORT.SchemaMapping("sales", "APP", "DATA_FILE", 2, "MAPPED", "")
        ]

    def test_routines_match_across_procedure_and_function_types(self):
        source = [object_record("sales", "ROUTINES", "CalculateTax", subtype="PROCEDURE")]
        generated = [object_record("APP", "ROUTINES", "CALCULATETAX", subtype="FUNCTION")]
        target = [object_record("APP", "ROUTINES", "CalculateTax", subtype="FUNCTION")]

        rows = REPORT.compare_objects(source, generated, target, self.mapping)

        self.assertEqual([row.status for row in rows], ["MATCH"])

    def test_structural_constraint_and_index_matching_ignores_generated_names(self):
        columns = (
            REPORT.InventoryAttribute(1, "column", "CUSTOMER_ID"),
            REPORT.InventoryAttribute(2, "column", "ORDER_ID"),
        )
        source = [
            object_record(
                "sales",
                "PRIMARY_KEYS",
                "PK_orders",
                parent_schema="sales",
                parent_name="orders",
                subtype="PRIMARY_KEY",
                attributes=columns,
            ),
            object_record(
                "sales",
                "INDEXES",
                "IX_orders",
                parent_schema="sales",
                parent_name="orders",
                subtype="INDEX",
                attributes=columns,
            ),
        ]
        generated = [
            object_record(
                "APP",
                "PRIMARY_KEYS",
                "SYS_C001",
                parent_schema="APP",
                parent_name="ORDERS",
                subtype="PRIMARY_KEY",
                attributes=columns,
            ),
            object_record(
                "APP",
                "INDEXES",
                "GENERATED_IX_42",
                parent_schema="APP",
                parent_name="ORDERS",
                subtype="INDEX",
                attributes=columns,
            ),
        ]
        target = list(generated)

        rows = REPORT.compare_objects(source, generated, target, self.mapping)

        self.assertEqual([row.status for row in rows], ["MATCH", "MATCH"])

    def test_all_failure_and_context_statuses_are_deterministic(self):
        source = [
            object_record("sales", "TABLES", "missing_conversion"),
            object_record("sales", "TABLES", "missing_target"),
            object_record("sales", "VIEWS", "invalid_view"),
        ]
        generated = [
            object_record("APP", "TABLES", "missing_target"),
            object_record("APP", "VIEWS", "invalid_view"),
            object_record("Emulation", "PACKAGES", "UTILS"),
        ]
        target = [
            object_record("APP", "VIEWS", "invalid_view", status="INVALID"),
            object_record("APP", "TABLES", "unexpected_table"),
            object_record("APP", "SEQUENCES", "ISEQ$$_12345"),
            object_record("Emulation", "PACKAGES", "UTILS"),
        ]

        rows = REPORT.compare_objects(source, generated, target, self.mapping)
        by_name = {(row.source_name or row.generated_name or row.target_name): row for row in rows}

        self.assertEqual(by_name["missing_conversion"].status, "MISSING_IN_CONVERSION")
        self.assertEqual(by_name["missing_target"].status, "MISSING_IN_TARGET")
        self.assertEqual(by_name["invalid_view"].status, "INVALID_IN_TARGET")
        self.assertEqual(by_name["unexpected_table"].status, "EXTRA_IN_TARGET")
        self.assertEqual(by_name["ISEQ$$_12345"].status, "CONTEXT")
        self.assertEqual(by_name["UTILS"].status, "CONTEXT")

    def test_attribute_difference_and_unresolved_mapping_fail_explicitly(self):
        source = [
            object_record(
                "sales",
                "INDEXES",
                "IX_customer",
                parent_schema="sales",
                parent_name="customer",
                attributes=(REPORT.InventoryAttribute(1, "column", "NAME"),),
            ),
            object_record("unmapped", "TABLES", "orphan"),
        ]
        generated = [
            object_record(
                "APP",
                "INDEXES",
                "IX_generated",
                parent_schema="APP",
                parent_name="CUSTOMER",
                attributes=(REPORT.InventoryAttribute(1, "column", "EMAIL"),),
            )
        ]
        mappings = self.mapping + [
            REPORT.SchemaMapping("unmapped", "", "OBJECT_IDENTITY", 0, "UNRESOLVED", "no unique owner")
        ]

        rows = REPORT.compare_objects(source, generated, [], mappings)
        statuses = {row.source_name: row.status for row in rows if row.source_name}

        self.assertEqual(statuses["IX_customer"], "DIFFERENT")
        self.assertEqual(statuses["orphan"], "UNRESOLVED_MAPPING")

    def test_narrow_artifact_rule_does_not_hide_similarly_named_user_sequence(self):
        target = [
            object_record("APP", "SEQUENCES", "ISEQ$$_123"),
            object_record("APP", "SEQUENCES", "ISEQ$$_CUSTOM"),
        ]

        rows = REPORT.compare_objects([], [], target, self.mapping)
        statuses = {row.target_name: row.status for row in rows}

        self.assertEqual(statuses["ISEQ$$_123"], "CONTEXT")
        self.assertEqual(statuses["ISEQ$$_CUSTOM"], "EXTRA_IN_TARGET")

    def test_evidence_outputs_have_stable_headers_and_sort_order(self):
        mappings = [
            REPORT.SchemaMapping("zeta", "Z_APP", "DATA_FILE", 1, "MAPPED", ""),
            REPORT.SchemaMapping("alpha", "A_APP", "DATA_FILE", 1, "MAPPED", ""),
        ]
        generated = [
            object_record("Z_APP", "TABLES", "Z_TABLE"),
            object_record("A_APP", "TABLES", "A_TABLE"),
        ]
        comparisons = REPORT.compare_objects([], [], generated, [])

        with tempfile.TemporaryDirectory() as tmp:
            evidence = Path(tmp)
            REPORT.write_evidence_outputs(evidence, mappings, generated, comparisons)
            mapping_lines = (evidence / "schema_mapping.tsv").read_text(encoding="utf-8").splitlines()
            inventory_lines = (evidence / "generated_target_inventory.tsv").read_text(encoding="utf-8").splitlines()
            comparison_lines = (evidence / "object_comparison.tsv").read_text(encoding="utf-8").splitlines()

        self.assertEqual(
            mapping_lines[0],
            "source_schema\ttarget_schema\tmethod\tevidence_count\tstatus\treason",
        )
        self.assertTrue(mapping_lines[1].startswith("alpha\tA_APP\t"))
        self.assertEqual(inventory_lines[0], "\t".join(REPORT.INVENTORY_HEADER))
        self.assertIn("A_APP\tTABLES\tA_TABLE", inventory_lines[1])
        self.assertTrue(comparison_lines[0].startswith("source_schema\tsource_category"))
        self.assertIn("A_APP", comparison_lines[1])


class RendererAndCliTests(unittest.TestCase):
    def make_report_data(self, *, status="PASS", detail=""):
        mapping = REPORT.SchemaMapping("sales", "APP", "DATA_FILE", 1, "MAPPED", "")
        source = object_record("sales", "VIEWS", "special <view>")
        generated = object_record("APP", "VIEWS", "special <view>")
        target = object_record("APP", "VIEWS", "special <view>", status="VALID")
        comparison = REPORT.ComparisonRecord(
            source_schema=source.schema,
            source_category=source.category,
            source_name=source.name,
            generated_schema=generated.schema,
            generated_category=generated.category,
            generated_name=generated.name,
            target_schema=target.schema,
            target_category=target.category,
            target_name=target.name,
            status=status,
            reason=detail,
            origin="fixture & evidence",
        )
        return REPORT.ReportData(
            migration="sales & reporting",
            run_id="20261016_010203",
            generated_at="2026-10-16T01:02:03Z",
            status="PASS" if status == "MATCH" else status,
            mappings=(mapping,),
            reconciliation=({"source_object": "sales.customer", "status": "PASS"},),
            source_inventory=(source,),
            generated_inventory=(generated,),
            target_inventory=(target,),
            comparisons=(comparison,),
            evidence_issues=(),
        )

    def test_renderer_is_self_contained_escaped_and_readable_without_javascript(self):
        report_data = self.make_report_data(status="INVALID_IN_TARGET", detail='<broken & "bad">')
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "migration_report.html"
            REPORT.render_report(report_data, output)
            html = output.read_text(encoding="utf-8")

        for heading in (
            "Run Summary",
            "Schema Mapping",
            "Data Reconciliation",
            "Object Inventory",
            "Object Exceptions",
            "Routine Validation",
            "Supporting Migration Context",
            "Evidence Health",
        ):
            self.assertIn(heading, html)
        self.assertIn("data-sortable", html)
        self.assertIn("filterTable", html)
        self.assertIn("<table", html)
        self.assertIn("&lt;broken &amp; &quot;bad&quot;&gt;", html)
        self.assertIn("sales &amp; reporting", html)
        self.assertNotIn("http://", html)
        self.assertNotIn("https://", html)

    def test_rendering_is_deterministic_when_generation_time_is_fixed(self):
        report_data = self.make_report_data(status="MATCH")
        with tempfile.TemporaryDirectory() as tmp:
            first = Path(tmp) / "first.html"
            second = Path(tmp) / "second.html"
            REPORT.render_report(report_data, first)
            REPORT.render_report(report_data, second)
            self.assertEqual(first.read_bytes(), second.read_bytes())

    def test_failed_atomic_replace_preserves_existing_report(self):
        report_data = self.make_report_data(status="MATCH")
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "migration_report.html"
            output.write_text("known complete report", encoding="utf-8")
            with mock.patch.object(REPORT.os, "replace", side_effect=OSError("simulated")):
                with self.assertRaises(OSError):
                    REPORT.render_report(report_data, output)
            self.assertEqual(output.read_text(encoding="utf-8"), "known complete report")

    def run_cli(self, fixture: Path, output: Path):
        stdout = StringIO()
        with redirect_stdout(stdout):
            rc = REPORT.main(
                [
                    "--sdcli-dir",
                    str(fixture / "sdcli"),
                    "--evidence-dir",
                    str(fixture),
                    "--output",
                    str(output),
                    "--migration",
                    "sales",
                    "--run-id",
                    "20261016_010203",
                ]
            )
        return rc, stdout.getvalue()

    def test_cli_writes_pass_report_and_normalized_evidence(self):
        with tempfile.TemporaryDirectory() as tmp:
            fixture = Path(tmp) / "fixture"
            shutil.copytree(FIXTURE_ROOT, fixture)
            output = Path(tmp) / "migration_report.html"
            rc, stdout = self.run_cli(fixture, output)

            self.assertEqual(rc, 0)
            self.assertTrue(output.is_file())
            self.assertIn("status=PASS", stdout)
            self.assertTrue((fixture / "schema_mapping.tsv").is_file())
            self.assertTrue((fixture / "generated_target_inventory.tsv").is_file())
            self.assertTrue((fixture / "object_comparison.tsv").is_file())

    def test_cli_writes_fail_report_for_invalid_target(self):
        with tempfile.TemporaryDirectory() as tmp:
            fixture = Path(tmp) / "fixture"
            shutil.copytree(FIXTURE_ROOT, fixture)
            inventory = fixture / "target_object_inventory.tsv"
            inventory.write_text(
                inventory.read_text(encoding="utf-8").replace(
                    "APP\tVIEWS\tACTIVE CUSTOMERS\t\t\tVIEW\t\t\t\tVALID\t\tfixture",
                    "APP\tVIEWS\tACTIVE CUSTOMERS\t\t\tVIEW\t\t\t\tINVALID\t<compile & error>\tfixture",
                ),
                encoding="utf-8",
            )
            output = Path(tmp) / "migration_report.html"
            rc, stdout = self.run_cli(fixture, output)
            html = output.read_text(encoding="utf-8")

            self.assertEqual(rc, 2)
            self.assertIn("status=FAIL", stdout)
            self.assertIn("&lt;compile &amp; error&gt;", html)

    def test_cli_writes_incomplete_report_for_missing_evidence(self):
        with tempfile.TemporaryDirectory() as tmp:
            fixture = Path(tmp) / "fixture"
            shutil.copytree(FIXTURE_ROOT, fixture)
            (fixture / "source_object_inventory.tsv").unlink()
            output = Path(tmp) / "migration_report.html"
            rc, stdout = self.run_cli(fixture, output)
            html = output.read_text(encoding="utf-8")

            self.assertEqual(rc, 2)
            self.assertIn("status=INCOMPLETE", stdout)
            self.assertIn("INCOMPLETE", html)


if __name__ == "__main__":
    unittest.main()
