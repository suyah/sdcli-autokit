# Lean Orchestrator: Code Removal Inventory and Stage Acceptance

Date: 2026-11-06

Status: approved inventory; implementation history and verification are recorded in stage plans
Baseline: `v1.4.0` / `db94c41`

Companion: [lean orchestrator design](2026-11-06-lean-orchestrator-design.md)

Line numbers are navigation aids only; implementation uses function names and current callers.

## Inventory rules

- **Remove**: the responsibility no longer exists; delete implementation, callers, and tests that only protect it.
- **Consolidate**: the responsibility remains; retain one execution check and remove its duplicate.
- **Replace then remove**: introduce the replacement in the same stage; do not leave an empty function, compatibility shim, or false-success path.
- **Retain**: execution-critical adaptation must not disappear merely because its name contains `verify` or `validate`.

## Stage A — remove duplicated orchestration and plan records

### Generic postcondition framework

| Location | Action | Replacement responsibility |
| --- | --- | --- |
| `migrate.sh:3197` `verify_phase_postcondition` | Remove | `run_phase` consumes the direct `run_*` result. |
| Second verify call at the end of `run_phase` | Remove | Phase status comes directly from phase execution. |
| `migrate.sh:2982` `verify_offload_evidence` | Consolidate then remove | `run_offload` performs the single coverage check after preserving unique protections. |
| `migrate.sh:3025` `verify_load_evidence` | Consolidate then remove | `run_load` performs one control-path/set and status check, not count-only checking. |
| `migrate.sh:3073` `manifest_relative_path` | Remove when unreferenced | Real manifest recording retains existing path normalisation. |
| `migrate.sh:3079` `expected_manifest_paths` | Remove | Do not re-enumerate an execution plan to validate the manifest. |
| `migrate.sh:3116` `verify_deploy_manifest_phase` | Remove | Real SQL*Plus result and real manifest records. |
| `migrate.sh:3160` `verify_validation_evidence` | Remove | `run_validate` returns the report result directly. |
| `SDCLI_LAST_ACTION`, `SDCLI_LAST_SUCCESS_MARKER` | Remove unused globals and lookup save/restore | Completion recognition remains local to `run_sdcli`; model lookup remains. |

Before removal, move capture/convert `lookup_sdcli_model_index` calls to their successful action paths. The workflow still passes exact numeric models to later phases and still checks manual schema mapping against the selected capture/run. Do not replace this with unrestricted `latest` or add caching.

### Plan-only SQL inventories

| Location | Action |
| --- | --- |
| `sqlplus_deploy.sh:605` `record_root_sql_inventory` | Remove it and its `run_deploy` caller. |
| `sqlplus_deploy.sh:624` `record_schema_inventory` | Remove it and its `run_deploy` caller. |
| `sqlplus_deploy.sh:454` `generated_sql_files` | Remove after deleting all monolithic/fallback/duplicate-record callers. |
| `run_postdeploy` `__phase_complete__` pending/executed rows | Remove; completion belongs only in `phase_status.tsv`. |
| End-of-`run_deploy` excluded `gen/*.sql` scan | Remove; do not scan a second non-executed SQL set. |

In the same stage, adjust the existing report to count only real failed scripts, ignore plan/sentinel history, and read completion from phase status. Do not remove the old report inventory structure until Stage C; otherwise A would make every postdeploy look incomplete.

Retain `record_deploy_manifest` and `postdeploy_script_succeeded` for actual execution tracking and retry skipping. `init_deploy_manifest` may overwrite attempt records on a rerun; Stage A does not become an automatic partial-deployment recovery system. Historical phase status/logs remain and operators are warned that a partial deployment may exist.

### Native output

Summary paths such as `summarize_sqlldr_output` must not re-write raw lines already saved through `tee` using prefixes such as `SQL*Loader output:`. Preserve native warning/error output and narrow fixed banner/progress filters.

### Stage A acceptance

- Successful capture/convert still obtains the correct model; false completion and ambiguous models fail.
- A BCP failure and a missing/duplicate loader-control invocation still fail.
- Deploy/postdeploy manifest contains actual scripts only; sentinels do not add report findings.
- SQL*Plus owns nested post/rebuild include execution and runs it once.
- `rg` finds no production callers of removed functions; obsolete tests do not justify stubs.

## Stage B — propagate real execution failures

| File/function | Change | Boundary retained |
| --- | --- | --- |
| `lib/sqlplus`, load path enabled by `SDCLI_LOAD_PASSWORD_FD` | Add native SQL/OS error exits and bounded SQL*Plus command-error handling; prove shell propagation. | Do not change interactive SQL*Plus or analyse SQL bodies. |
| `run_load` | Record wrapper failure as load failure and show native diagnostics. | SQL*Loader status does not replace SQL*Plus outcome. |
| `run_sdcli`, `sdcli_output_has_diagnostics` | Consolidate proven zero-exit fatal handling. | Do not fail for every arbitrary `ORA-` text or hide unknown warnings. |
| Helper-object order | Inspect original generated files/calls and invoke a distinct native setup only if present. | No hard-coded names or regex DDL extraction. |

Retain `sdcli_has_only_benign_diagnostics` unless the known init behaviour proves it can be removed. Do not create a broad error-code allow-list.

### Stage B acceptance

- A SQL*Plus SQL error prevents a later observable statement and returns nonzero from load.
- Postdeploy continues later independent files, exposes native SQL errors, and finishes nonzero.
- Known SDCLI zero-exit fatal remains failure; normal conversion diagnostics still permit generate.
- A small helper test proves creation, invocation, and result; a row count alone does not pass the test.

## Stage C — atomically replace old validation

### Remove from `migrate.sh`

| Function/state | Action |
| --- | --- |
| `validate_run_log`, `validate_sdcli_error_log`, `validate_sqlldr_log_file` | Remove; do not infer present execution state by scoring historical logs. |
| `is_ignored_validation_diagnostic` | Remove after callers disappear; there is no log-ignore table. |
| `RUN_LOG_START_LINE`, `VALIDATION_LAST_COUNT` | Remove unused initialisation/assignments. |
| `inventory_tsv_header`, `write_marked_inventory` | Remove; do not repair wide TSV. |
| `collect_source_object_inventory` | Remove; do not collect complete source attributes or unrelated schema counts. |
| `collect_target_object_inventory` | Replace then remove with direct invalid/compiler diagnostics. |
| `validate_target_objects` | Remove after the new diagnostics query owns counts. |
| `write_validation_checks` | Remove; no second internal-check protocol. |
| Log loops and `metadata_issues`, `report_issues`, `total_issues` arithmetic in `run_validate` | Remove; use collection result plus renderer result. |
| Legacy generated-inventory list in `run_validation_report` | Remove; new reports do not rewrite historical attachments. |

Add `collect_target_object_diagnostics(idx, output_dir, output_file)` in `migrate.sh`: it connects, runs the one native CSV query, and writes the artifact. The existing Python renderer reads the artifact. Retain `run_target_sql_capture`, target row-count collection, reconciliation building, and reconciliation execution.

### Remove/replace report implementation

| Current implementation | Action |
| --- | --- |
| `INVENTORY_HEADER`, `InventoryAttribute`, `ObjectRecord`, `InventoryCount` | Remove. |
| `_object_sort_key`, `load_inventory`, `_inventory_counts`, `_line_and_position` | Remove. |
| `ValidationCheck`, `REQUIRED_VALIDATION_CHECKS`, `_read_validation_checks` | Remove. |
| `_invalid_object_findings` | Replace with direct diagnostics CSV parsing. |
| `_build_report_data` | Reduce to phase status, real manifest, reconciliation, mapping, and diagnostics. |
| Metadata Coverage, Inventory Counts, Evidence Health | Remove. Unavailable diagnostics becomes Checks Not Completed. |
| Sentinel/not-run deployment issue arithmetic | Remove. Count latest real script failures only. |
| Wide `_text_table` pipe fallback | Replace with aligned short tables and long object blocks. |
| Renderer, `_atomic_write`, standard `csv`/`html` use | Retain and reduce. |

No Python framework is added and the renderer is not rewritten in Bash.

### Artifacts and collector

- Retain phase status, deployment manifest, reconciliation, target row counts, raw logs, and schema mapping.
- Add `target_object_diagnostics.csv` to the fixed `collect-run-logs.sh` allow-list.
- Stop creating source/target inventory TSV and `validation_checks.tsv`.
- Preserve historical files but never read them as fallback. The collector may include legacy names solely for old-run inspection.
- Keep `validation_summary.txt`, replacing mixed `total_issues` arithmetic with explicit table, failed-script, invalid-object, compiler-error, and incomplete-check counts.

### Stage C acceptance

- A small synthetic fixture preserves exported, loaded, and target row totals as row-count-only evidence; include a mismatch case.
- Native CSV with quoted multiline compiler error is readable; header-only is zero findings; query failure is incomplete.
- Confirmed failure plus unavailable diagnostics is FAIL, never `No records`.
- Latest retry success supersedes older failure; current validate start and old validate failure do not block reevaluation.
- One script failure counts once; informational `SQL*Loader-292` output stays visible without producing validation failures.
- HTML, text, and summary agree; renderer failure remains distinct.

## Stage D — native-path DDL aggregation

Add `--layout object|type` to `export-source-schema.sh`, defaulting to `object`. Keep a small helper in that script and add no dependencies. For `type`, make one native SqlPackage export, preserve `sql/`, group complete files by native path, sort schema/filename, and append to `by-type`. Treat database-level Security as defined in the design; do not parse SQL.

Update README with both layouts, native classification limits, reading-not-deployment purpose, and redacted SqlPackage error/log location. Test two schemas, two types, one Security file, and one space-containing filename; prove exact coverage, intact batches, stable order, and unchanged default layout.

## Test disposition

| Test/artifact | Stage and treatment |
| --- | --- |
| `tests/sdcli_action_postcondition_test.sh` | A: relocate necessary model/failure assertions, then remove framework-specific test. |
| `tests/model_selection_test.sh`, `tests/sdcli_combined_action_test.sh` | A/B: retain. |
| `tests/offload_bcp_failure_test.sh`, `tests/offload_multiple_scripts_test.sh` | A: test the one real coverage entrypoint. |
| `tests/load_tns_alias_test.sh` | A/B: retain wrapper/password/control contract; add one SQL failure case only. |
| `tests/deploy_orchestration_test.sh` | A: remove plan/sentinel assertions; retain order and continue-after-error behaviour. |
| `tests/generated_deploy_fallback_test.sh` | A: retain nested-include/no-monolithic-auto-execution behaviour; rename to `generated_deploy_layout_test.sh`. |
| `tests/validation_metadata_collection_test.sh`, `tests/target_object_validation_test.sh`, `tests/validate_phase_test.sh`, `tests/test_validation_report.py` | C: remove inventory/log-score coverage and replace with focused diagnostics/report cases. |
| Inventory/check TSV fixtures and obsolete generated DDL fixtures | C: remove after the final caller disappears. |
| `tests/collect_run_logs_test.sh` | C: add diagnostics CSV collection and retain data/wallet exclusion. |
| `tests/export_source_schema_test.sh` | D: add grouped type layout and unchanged default layout. |
| Password/profile/repository/schema-map/release tests | Retain. |

Before deleting a test, confirm it protects no remaining production contract. Add/rename tests in `.gitignore` allow-lists and verify `git ls-files tests` sees them so release verification cannot silently skip them.

## Retained high-value code and implementation stop point

Retain project profile isolation, native XML schema mapping, generated-source-preserving role cleanup, identifier-only password prompt parsing, native include/path scheduling, BCP/SQL*Loader/SQL*Plus wrappers, secret redaction, wallet/repository/profile locks, run selection, `--rerun-completed`, and explicit manual recovery. `is_predata_sql` remains unchanged in A; B may make a minimal evidence-based adjustment only after inspecting native files.

This inventory records scope rather than asserting that every stage is complete. Implementation follows the user's approval, starting with a concise Stage A plan and proceeding through B, C, and D. Database changes remain subject to the existing test-environment authorisation. Each stage uses a separate remote PR; update the engineering changelog for behaviour changes and update local `main` after remote merge.

## Follow-up review: 2026-11-09

The user approved implementation after another code/log review. Stage A additionally addresses latest-attempt retry state and include-list producer failures that could be lost through process substitution. Its loader coverage compares physical control paths, matching the wrapper's recorded paths even through symbolic links. These are execution-boundary corrections, not additional generic postconditions.

Stage B still owns SQL*Plus load error propagation and evidence-based helper dependency order. Stage C still owns report result precedence, direct compiler diagnostics, and removal of log scoring. Partial-deploy recovery remains an explicit operator decision because Oracle DDL may already have committed. Full migration success is not inferred from fixture tests or matching row counts.
