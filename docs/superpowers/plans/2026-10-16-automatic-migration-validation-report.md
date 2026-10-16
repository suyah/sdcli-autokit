# Automatic Migration Validation Report Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make SQL Server-to-Oracle validation automatically collect object evidence, compare source/generated/target objects, and produce a self-contained migration report with truthful exit status.

**Architecture:** Keep connection handling and phase orchestration in `migrate.sh`. Add one Python standard-library program that consumes normalized TSV evidence and generated SQL Developer artifacts, derives mappings, compares objects, and atomically renders the HTML report. Continue using the existing BCP, SQL\*Loader, and Oracle row-count evidence rather than recounting the live source.

**Tech Stack:** Bash, Python 3 standard library, SQL Server system catalogs through `sqlcmd`, Oracle `ALL_*` views through SQL\*Plus, existing shell fixture tests, Python `unittest`.

**Spec:** `docs/superpowers/specs/2026-10-16-automatic-migration-validation-report-design.md`

## Global Constraints

- The only supported migration pair is `sqlserver -> oracle`; reject every other pair before external work.
- Do not hardcode customer schemas, endpoints, wallets, object names, credentials, or migration-specific naming rules.
- Do not query SQL Developer private `MD_*` repository tables.
- Do not add Python packages, a service, a report database, or runtime downloads.
- Use `bcp_status.tsv`, `sqlldr_status.tsv`, and final Oracle counts as row evidence; do not recount SQL Server rows.
- Generate the report on validation failure as well as success, and never report incomplete evidence as PASS.
- Keep all metadata collection read-only and all evidence under the selected run directory.
- Transport source passwords with `SQLCMDPASSWORD` and target passwords through the existing SQL\*Plus `/nolog` path.
- HTML must escape database-derived content, contain no external dependencies, and be useful without JavaScript.
- Preserve the current shell architecture and keep the change maintainable by one engineer.

## Review Focus

- Mixed-case, quoted, whitespace-bearing, or HTML-special identifiers must remain distinguishable and safely escaped; Task 2 and Task 3 tests cover them.
- Relative and absolute data-file paths from BCP and SQL\*Loader evidence must normalize to the same mapping without basename-only collisions; Task 2 tests cover them.
- Partial or malformed `sqlcmd`/SQL\*Plus output must become incomplete evidence and a failing report, never an empty successful inventory; Task 4 tests cover it.
- Tableless schemas with tied or empty object overlap must remain unresolved instead of being guessed; Task 2 tests cover it.
- A report-rendering failure or interrupted rerun must not overwrite an existing complete HTML report; Task 3 tests cover atomic replacement.

---

### Task 1: Enforce the supported database pair during preflight

**Files:**
- Modify: `.gitignore`
- Modify: `sdcli-scripts/migrate.sh`
- Create: `tests/config_database_type_test.sh`

**Interfaces:**
- Produces: `validate_supported_migration_pair() -> exit 0 or fail`, reading `defaults.source.type` and `defaults.target.type` through `get_required_value`.
- Produces: startup order in `main()` where configuration validation completes before `bootstrap_logging`, wallet setup, SDCLI setup, connectivity checks, or migration artifact creation.
- Consumes: existing `to_lower`, `get_required_value`, and `fail` helpers.

- [ ] **Step 1: Write the failing preflight test**

  Add a shell fixture that proves `SQLSERVER -> ORACLE` is accepted, missing types are rejected, and `postgresql -> oracle` plus `sqlserver -> postgresql` produce an error naming the configured and supported pairs. Exercise `main()` with stubbed helpers to prove an invalid pair exits before `bootstrap_logging` or any external-operation marker runs.

- [ ] **Step 2: Run the test and verify RED**

  Run: `bash tests/config_database_type_test.sh`

  Expected: FAIL because `validate_supported_migration_pair` does not exist and invalid type values currently pass configuration validation.

- [ ] **Step 3: Implement the minimal preflight guard**

  Add `validate_supported_migration_pair`, call it first from `validate_config`, and move `validate_config` ahead of `bootstrap_logging` in `main`. Normalize only case; require the exact `sqlserver` and `oracle` values. Update `.gitignore` to track the new validation tests, Python test, and plan without broadening unrelated ignored files.

- [ ] **Step 4: Verify GREEN and regression safety**

  Run: `bash tests/config_database_type_test.sh && bash tests/run_layout_test.sh && bash -n sdcli-scripts/migrate.sh && git diff --check`

  Expected: PASS with unsupported pairs rejected before the marker for bootstrap or external work.

- [ ] **Step 5: Commit**

  Run: `git add .gitignore sdcli-scripts/migrate.sh tests/config_database_type_test.sh && git commit -m "fix: reject unsupported migration database pairs"`

---

### Task 2: Build artifact mapping and three-way comparison core

**Files:**
- Create: `sdcli-scripts/lib/generate_validation_report.py`
- Create: `tests/test_validation_report.py`
- Create: `tests/validation_report_test.sh`
- Create: `tests/fixtures/validation/base/source_object_inventory.tsv`
- Create: `tests/fixtures/validation/base/target_object_inventory.tsv`
- Create: `tests/fixtures/validation/base/bcp_status.tsv`
- Create: `tests/fixtures/validation/base/sqlldr_status.tsv`
- Create: `tests/fixtures/validation/base/reconciliation.tsv`
- Create: neutral generated DDL fixtures below `tests/fixtures/validation/base/sdcli/`

**Interfaces:**
- Produces: immutable `InventoryAttribute(ordinal, name, value)` and `ObjectRecord(schema, category, name, parent_schema, parent_name, subtype, attributes, status, detail, origin)`. Raw inventory TSV uses one attribute row per logical object with the exact header `schema\tcategory\tobject_name\tparent_schema\tparent_name\tsubtype\tordinal\tattribute_name\tattribute_value\tstatus\tdetail\torigin`; simple objects have one row with empty attribute fields.
- Produces: immutable `SchemaMapping(source_schema, target_schema, method, evidence_count, status, reason)`.
- Produces: `load_inventory(path: Path) -> list[ObjectRecord]`.
- Produces: `build_table_mappings(evidence_dir: Path) -> list[SchemaMapping]`, joining full normalized data-file paths from successful BCP and SQL\*Loader status records.
- Produces: `parse_generated_inventory(sdcli_dir: Path) -> list[ObjectRecord]` for the generated file classes represented by SQL Developer master/schema output.
- Produces: `resolve_schema_mappings(source, generated, table_mappings) -> list[SchemaMapping]`.
- Produces: `compare_objects(source, generated, target, mappings) -> list[ComparisonRecord]` with the spec statuses.
- Consumes later: Task 3 CLI and renderer use these pure functions and records.

- [ ] **Step 1: Write failing mapping and parser tests**

  Cover one and multiple `DATA_FILE` mappings, path normalization, two same-basename files in different directories, duplicate/unpaired/failed status records, conflicting schema mappings, independent schemas, mixed-case and quoted identifiers, Emulation context, unique tableless mapping, and tied/empty tableless mapping. Fixtures must use neutral names such as `sales`, `app`, and `customer`, never a customer project name.

- [ ] **Step 2: Run mapping tests and verify RED**

  Run: `python3 -m unittest discover -s tests -p 'test_validation_report.py' -v`

  Expected: FAIL because the report module and record interfaces do not exist.

- [ ] **Step 3: Implement records, TSV readers, mapping, and generated-DDL inventory parsing**

  Use `csv` with tab delimiters, `pathlib`, conservative identifier normalization, and focused regular expressions for generated SQL Developer DDL. Follow generated `master.sql` include graphs, exclude recognized cleanup files, and classify active `CREATE`/`ALTER` statements from included files instead of maintaining a project-specific filename list. Preserve origin file/line evidence. Treat unrecognized active DDL in the included graph as incomplete evidence rather than skipping it.

- [ ] **Step 4: Add failing comparison tests**

  Cover `MATCH`, `MISSING_IN_CONVERSION`, `MISSING_IN_TARGET`, `EXTRA_IN_TARGET`, `INVALID_IN_TARGET`, `DIFFERENT`, `UNRESOLVED_MAPPING`, and `CONTEXT`. Include routine procedure/function normalization, name-independent PK/UK/FK/index structural matching with ordered columns, identity columns, narrow generic artifact rules, and an application object whose similar name must not be hidden.

- [ ] **Step 5: Run comparison tests and verify RED**

  Run: `python3 -m unittest discover -s tests -p 'test_validation_report.py' -v`

  Expected: FAIL on missing comparison behavior while the mapping tests remain green.

- [ ] **Step 6: Implement comparison and TSV output**

  Add deterministic sorting and `write_tsv_atomic(path, header, rows)`. Generate `schema_mapping.tsv`, `generated_target_inventory.tsv`, and `object_comparison.tsv` from detail records; derive all counters from those same rows.

- [ ] **Step 7: Verify core behavior**

  Run: `bash tests/validation_report_test.sh && python3 -m py_compile sdcli-scripts/lib/generate_validation_report.py && git diff --check`

  Expected: PASS for mapping, generated-inventory, comparison, and deterministic TSV tests.

- [ ] **Step 8: Commit**

  Run: `git add sdcli-scripts/lib/generate_validation_report.py tests/test_validation_report.py tests/validation_report_test.sh tests/fixtures/validation && git commit -m "feat: compare migration object evidence"`

---

### Task 3: Render the self-contained validation report

**Files:**
- Modify: `sdcli-scripts/lib/generate_validation_report.py`
- Modify: `tests/test_validation_report.py`

**Interfaces:**
- Produces: `render_report(report_data: ReportData, output_path: Path) -> None`, using an atomic temporary-file replacement.
- Produces: `main(argv: Sequence[str] | None = None) -> int` with required `--sdcli-dir`, `--evidence-dir`, `--output`, `--migration`, and `--run-id` arguments.
- Exit contract: `0` when report evidence passes, `2` when a complete or incomplete report is written with validation findings, and `1` only when the program cannot safely render or write a report.
- Consumes: all Task 2 mapping, parsing, comparison, and atomic TSV interfaces.
- Consumed later: Task 4 invokes the CLI and folds exit `2` into validation issues without suppressing the report path.

- [ ] **Step 1: Write failing renderer and CLI tests**

  Assert PASS, FAIL, and incomplete fixtures all create HTML; headings and exception anchors exist; filters/sorting code is embedded; JavaScript-disabled tables remain readable; `<`, `>`, `&`, quotes, and compiler messages are escaped; no `http://`, `https://`, CDN, font, image, or script dependency occurs; and output is deterministic apart from the documented generation timestamp.

- [ ] **Step 2: Add the atomic-rerun regression test and verify RED**

  Seed a known complete report, force rendering to fail before replacement, and assert the seeded bytes remain unchanged.

  Run: `python3 -m unittest discover -s tests -p 'test_validation_report.py' -v`

  Expected: FAIL because the renderer and CLI are missing.

- [ ] **Step 3: Implement report assembly and HTML rendering**

  Render run summary, schema mapping, data reconciliation, object inventory, object exceptions, routine validation, supporting context, and evidence health. Embed minimal CSS/JavaScript only; use `html.escape` for every evidence value. Write all snapshot outputs through temporary files in their destination directory and `os.replace` only after successful completion.

- [ ] **Step 4: Implement CLI exit behavior**

  Ensure evidence mismatches and missing or malformed evidence return `2` after writing an `INCOMPLETE` report. Reserve `1` for an internal or I/O failure that prevents safe report creation, with no secret-bearing diagnostics. Print one concise result line containing status, mapping issue count, comparison issue count, incomplete section count, and report path.

- [ ] **Step 5: Verify renderer and core suite**

  Run: `bash tests/validation_report_test.sh && python3 -m py_compile sdcli-scripts/lib/generate_validation_report.py && git diff --check`

  Expected: PASS, including HTML escaping, offline behavior, and atomic replacement.

- [ ] **Step 6: Commit**

  Run: `git add sdcli-scripts/lib/generate_validation_report.py tests/test_validation_report.py && git commit -m "feat: render migration validation report"`

---

### Task 4: Collect live metadata and integrate reporting with validate

**Files:**
- Modify: `sdcli-scripts/migrate.sh`
- Create: `tests/validation_metadata_collection_test.sh`
- Modify: `tests/validate_phase_test.sh`
- Modify: `tests/target_object_validation_test.sh`

**Interfaces:**
- Produces: `collect_source_object_inventory(idx, output_file) -> exit status`, invoking `sqlcmd` with `SQLCMDPASSWORD` and writing normalized `source_object_inventory.tsv`.
- Produces: `collect_target_object_inventory(idx, output_dir, output_file) -> exit status`, invoking the existing safe SQL\*Plus capture path and writing normalized `target_object_inventory.tsv` restricted to generated owners.
- Produces: `run_validation_report(output_dir, idx) -> exit 0|1|2`, deriving the migration name from the selected config entry and invoking Task 3's CLI.
- Extends: `run_validate(output_dir, idx)` so metadata or report failures add issues, but report generation is still attempted and its path is always logged when present.
- Consumes: Task 3 CLI exit contract and output artifacts; existing source connection parsing, TLS mode, secret resolution, SQL\*Plus capture, reconciliation, and target validity helpers.

- [ ] **Step 1: Write failing collector tests**

  Use executable fake `sqlcmd` and `sqlplus` binaries. Assert the source password is present only in `SQLCMDPASSWORD`, absent from argv/evidence/logs; the configured host, port, database, user, and TLS mode reach the command correctly; target owner predicates contain only generated schema directories; and the queries are read-only. Feed valid, empty, malformed, and nonzero outputs and assert incomplete evidence fails.

- [ ] **Step 2: Run collector tests and verify RED**

  Run: `bash tests/validation_metadata_collection_test.sh`

  Expected: FAIL because the collector functions do not exist.

- [ ] **Step 3: Implement source and target collectors**

  Query the catalog coverage listed in the spec. Have SQL emit marker-prefixed, tab-separated normalized rows with tabs/newlines removed from free text. Validate the marker and exact field count before atomically replacing each inventory. Reuse BCP TLS semantics for `sqlcmd` and the current SQL\*Plus wallet/password path for Oracle.

- [ ] **Step 4: Write failing validate-integration tests**

  Extend the validation fixture so a passing run creates all evidence and HTML and reports `metadata_issues=0 report_issues=0`. Add source failure, target failure, comparison mismatch, renderer failure, and repeated-validation cases. Each failure must return nonzero, still attempt the renderer, and write final `validation_summary.txt` after all counters are known.

- [ ] **Step 5: Run integration tests and verify RED**

  Run: `bash tests/validate_phase_test.sh`

  Expected: FAIL on missing report invocation and missing summary counters.

- [ ] **Step 6: Integrate collectors and report CLI**

  Require `sqlcmd` and `python3` for real validate/full workflows. In `run_validate`, collect both inventories without early exit, retain existing log/reconciliation/object checks, invoke the report even with partial metadata, add `metadata_issues` and `report_issues` to the total, and print the report path on PASS or FAIL. Do not expose source or target passwords in process arguments or logs.

- [ ] **Step 7: Verify validation behavior**

  Run: `bash tests/validation_metadata_collection_test.sh && bash tests/validate_phase_test.sh && bash tests/data_reconciliation_test.sh && bash tests/target_object_validation_test.sh && bash -n sdcli-scripts/migrate.sh && git diff --check`

  Expected: PASS with existing reconciliation/target checks preserved and report failure propagation proven.

- [ ] **Step 8: Commit**

  Run: `git add sdcli-scripts/migrate.sh tests/validation_metadata_collection_test.sh tests/validate_phase_test.sh tests/target_object_validation_test.sh && git commit -m "feat: integrate automatic migration validation report"`

---

### Task 5: Package and document the offline report workflow

**Files:**
- Modify: `deployment/Dockerfile`
- Modify: `deployment/run.sh`
- Modify: `tests/test_offline_run.sh`
- Modify: `tests/test_offline_bundle.sh`
- Modify: `README.md`

**Interfaces:**
- Produces: a built/offline-loaded container containing working `python3` and the report program under the copied `sdcli-scripts` tree.
- Produces: README contract stating current SQL Server-to-Oracle support, early rejection of other pairs, planned future RDBMS source adapters, automatic validation outputs, and why the supplied row-count SQL is not a required operator step.
- Consumes: existing connected image build and offline bundle/copy workflow.

- [ ] **Step 1: Write failing packaging assertions**

  Update fake-container tests to require `python3` in the tool health check and require `generate_validation_report.py` in the bundled/copied `sdcli-scripts` tree.

- [ ] **Step 2: Run packaging tests and verify RED**

  Run: `bash tests/test_offline_run.sh && bash tests/test_offline_bundle.sh`

  Expected: FAIL because the image and runtime health check do not explicitly provide or verify Python 3.

- [ ] **Step 3: Add Python to the prebuilt image and health check**

  Install Oracle Linux's `python3` package in the connected Docker build, add `python3` to `deployment/run.sh` health checks, and rely on the existing offline image archive—never customer-side package installation—for delivery.

- [ ] **Step 4: Update the README**

  State prominently that this release supports only SQL Server sources and Oracle targets even though type fields exist. Explain that additional RDBMS source adapters are planned later and are not currently accepted. Document automatic report generation, report sections/files, PASS/FAIL/CONTEXT, metadata reachability, sensitive evidence handling, reruns, and that no manual row-count SQL or schema mapping is required.

- [ ] **Step 5: Run the complete verification suite**

  Run:

  ```bash
  set -e
  for test_file in tests/*.sh; do
    bash "$test_file"
  done
  python3 -m py_compile sdcli-scripts/lib/generate_validation_report.py
  bash -n sdcli-scripts/migrate.sh deployment/run.sh deployment/build.sh release/build-offline.sh
  git diff --check
  ```

  Expected: every shell test passes, Python compiles, all modified shell files parse, and no whitespace errors remain.

- [ ] **Step 6: Commit**

  Run: `git add deployment/Dockerfile deployment/run.sh tests/test_offline_run.sh tests/test_offline_bundle.sh README.md && git commit -m "feat: package automatic validation reports"`

---

## Final whole-branch verification

- [ ] Run the complete suite from Task 5 again from a clean shell.
- [ ] Inspect `git diff $(git merge-base main HEAD)..HEAD` for customer-specific values, secrets, broad artifact suppression, and unrelated refactoring.
- [ ] Generate PASS, FAIL, and incomplete reports from neutral fixtures and open each from the filesystem with networking disabled.
- [ ] Build the image with Rancher Desktop/Docker when available and verify `python3 --version` plus one fixture report inside the container. If no container engine is available, report this as an unverified environment acceptance item rather than implying it passed.
- [ ] Confirm the README, `validation_summary.txt`, comparison TSVs, process exit status, and HTML status agree for each fixture.
