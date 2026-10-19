# Parser and Validation Evidence Remediation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove unsafe semantic regex parsing, prevent credential leakage, and make migration validation depend only on structured evidence the autokit can prove.

**Architecture:** Bash remains the workflow orchestrator and database client boundary. Python remains a pure TSV-to-HTML/text report model and renderer; it no longer parses generated SQL. Narrow generated-file protocols are validated explicitly and fail closed when their supported grammar changes.

**Tech Stack:** Bash 4+, AWK for bounded line protocols, Python 3 standard library, SQL*Plus, SQLcmd, BCP, SQL*Loader, Oracle SQL Developer CLI, shell and `unittest` regression tests.

**Spec:** `docs/superpowers/specs/2026-10-19-parser-risk-remediation-design.md`

## Global Constraints

- Keep the tool practical for one maintainer; do not add a framework, parser generator, or new runtime package.
- Do not parse SQL, PL/SQL, or arbitrary XML semantics with regular expressions.
- Do not hard-code customer database, schema, object, host, wallet, or run names.
- SQL Server is the only validated source adapter in this release; other source RDBMS support remains future work.
- Preserve offline operation and customer-supplied proprietary vendor packages.
- Missing or malformed evidence must become `INCOMPLETE`, `NOT_EVALUATED`, or an actionable error—never an empty success.
- Complete one task, tests, review, commit, and PR gate before beginning the next task.

## Review Focus

- A representative supported password containing `@` and punctuation must be passed unchanged to tools but absent from every log and summary. Known ambiguous SDCLI `connDetails` separators are rejected before execution with a secret-free error; Task 1 does not enumerate password combinations.
- A SQL Developer format change must fail closed instead of silently skipping a generated file; Tasks 4 and 5 add unsupported-format cases.
- Missing target inventory must not create invented `MISSING_IN_TARGET` rows; Task 2 tests missing and malformed evidence.
- SQL errors in one postdeploy script must not lose cleanup behavior, manifest history, or later independent scripts; Task 4 reruns the merged deploy/postdeploy suite.
- Repository versions without supported datatype tables/columns must return an explicit unsupported-version error and perform no guessed query; Task 3 tests preflight failure.

---

### Task 1: P0 literal secret redaction

**Files:**
- Modify: `.gitignore`
- Modify: `sdcli-scripts/migrate.sh:124-160`
- Modify: `sdcli-scripts/migrate.sh:543-675`
- Modify: `sdcli-scripts/migrate.sh:1444-1590`
- Create: `tests/sdcli_output_redaction_test.sh`
- Test: `tests/deploy_schema_password_test.sh`

**Interfaces:**
- Consumes: existing `register_sensitive_value(value)` and `SENSITIVE_VALUES` registry.
- Produces: `redact_text(value)` for command arguments and `redact_sdcli_output()` for streams; both perform literal secret replacement only.

- [ ] **Step 1: Add failing special-character secret tests**

Add one representative supported password containing `@` and punctuation to the SDCLI and SQL*Plus tests. Add one representative unsupported `connDetails` delimiter case. Assert supported values reach fake tools unchanged, logs contain no credential fragments, and unsupported syntax fails before SDCLI with a clear secret-free message.

- [ ] **Step 2: Run focused tests and verify the current structural masking fails**

Run: `bash tests/sdcli_output_redaction_test.sh && bash tests/deploy_schema_password_test.sh`

Expected: FAIL because unsupported `connDetails` delimiters are not preflighted and SQL*Plus output still uses structural masking.

- [ ] **Step 3: Replace structural masking with literal redaction**

Remove `mask_conn_details_value`. Make `mask_sensitive` redact each complete raw argument before `%q` rendering. Register target, repository, source, and schema passwords before their commands are rendered.

- [ ] **Step 4: Harden SQL*Plus output handling**

Make `filter_sqlplus_deploy_output` delegate to literal redaction instead of parsing `IDENTIFIED BY`. Add `SET VERIFY OFF` to the generated wrapper and preserve `continue_on_sql_error` behavior.

- [ ] **Step 5: Run security and regression tests**

Run: `bash tests/sdcli_output_redaction_test.sh && bash tests/deploy_schema_password_test.sh && bash tests/role_cleanup_test.sh && bash tests/deploy_orchestration_test.sh`

Expected: PASS and zero secret occurrences in captured artifacts.

- [ ] **Step 6: Commit and review Task 1**

```bash
git add .gitignore sdcli-scripts/migrate.sh tests/sdcli_output_redaction_test.sh tests/deploy_schema_password_test.sh
git commit -m "fix: make secret redaction syntax independent"
```

### Task 2: P1 evidence-based validation report

**Files:**
- Modify: `sdcli-scripts/lib/generate_validation_report.py:1-1812`
- Modify: `sdcli-scripts/migrate.sh:2175-2890`
- Modify: `tests/test_validation_report.py`
- Modify: `tests/validation_report_test.sh`
- Modify: `tests/validate_phase_test.sh`
- Modify: `README.md`
- Modify: `docs/superpowers/specs/2026-10-17-actionable-validation-evidence-design.md`

**Interfaces:**
- Consumes: `validation_checks.tsv`, `reconciliation.tsv`, `deploy_manifest.tsv`, `source_object_inventory.tsv`, and `target_object_inventory.tsv`.
- Produces: one `ReportData` model rendered identically to `migration_report.html` and `migration_report.txt`; no generated-SQL inventory input.

- [ ] **Step 1: Replace parser-oriented tests with evidence-oriented failing tests**

Delete tests that require `_strip_sql_comments`, `_parse_generated_file`, generated structural equality, or `DIFFERENT`. Add tests asserting missing target evidence is `INCOMPLETE`, unavailable structured conversion mapping is `NOT_EVALUATED`, invalid Oracle objects include compiler details, and successful row reconciliation remains visible independently.

- [ ] **Step 2: Run Python and shell report tests to verify failure**

Run: `python3 -m unittest tests/test_validation_report.py && bash tests/validation_report_test.sh`

Expected: FAIL because the current model still requires generated DDL and emits structural comparison statuses.

- [ ] **Step 3: Remove generated SQL semantic parsing**

Delete `_strip_sql_comments`, `_split_sql_list`, `_parse_generated_file`, `parse_generated_inventory`, and generated-object structural comparison paths. Remove `--sdcli-dir` from the renderer CLI unless it is needed only for a non-semantic artifact link.

- [ ] **Step 4: Build report sections from direct evidence**

Add pure loaders for deployment manifest outcomes, invalid target objects/compiler diagnostics, inventory counts, and explicit metadata-evaluation status. Remove `DIFFERENT` and unproved missing/extra findings from the model and renderer.

- [ ] **Step 5: Align HTML and terminal reports**

Render the ordered sections specified in the design from the same model. Use deterministic aligned or pipe-delimited terminal tables and escape every HTML value.

- [ ] **Step 6: Run complete report and validation tests**

Run: `python3 -m unittest tests/test_validation_report.py && bash tests/validation_report_test.sh && bash tests/validation_metadata_collection_test.sh && bash tests/validate_phase_test.sh`

Expected: PASS; no generated DDL parser remains.

- [ ] **Step 7: Update documentation, commit, and review Task 2**

Mark the 2026-10-17 generated-DDL design superseded, update README report semantics, then commit:

```bash
git add README.md docs/superpowers/specs sdcli-scripts/lib/generate_validation_report.py sdcli-scripts/migrate.sh tests
git commit -m "fix: make validation report evidence based"
```

### Task 3: P1 datatype mapping inspection command

**Files:**
- Modify: `.gitignore`
- Modify: `sdcli-scripts/migrate.sh`
- Create: `tests/datatype_mapping_command_test.sh`
- Modify: `README.md`

**Interfaces:**
- Consumes: repository connection from `migration_repository`, optional migration name, and preflight metadata for `MIGR_DATATYPE_TRANSFORM_MAP` / `MIGR_DATATYPE_TRANSFORM_RULE`.
- Produces: `show_datatype_mapping(optional_migration_name)` writing deterministic, credential-free TSV to stdout.

- [ ] **Step 1: Record the supported repository table/column contract**

Use read-only SQL in the local test container to capture the exact columns and joins for the installed SQL Developer version. Store only neutral schema fixtures in the test; do not store credentials or customer data.

- [ ] **Step 2: Add failing CLI and repository-version tests**

Cover `./migrate.sh --show-datatype-mapping`, `./migrate.sh proda --show-datatype-mapping`, stable sort order, empty result, project-specific result, and missing required table/column preflight.

- [ ] **Step 3: Implement read-only structured queries**

Add argument parsing, repository preflight, marker-prefixed query output, strict TSV validation, and deterministic rendering. Do not parse SQL Developer GUI files or generated DDL.

- [ ] **Step 4: Run focused tests and local container integration**

Run: `bash tests/datatype_mapping_command_test.sh`

Expected: PASS for fixtures, followed by successful default and project queries in the local repository container.

- [ ] **Step 5: Document, commit, and review Task 3**

```bash
git add .gitignore README.md sdcli-scripts/migrate.sh tests/datatype_mapping_command_test.sh
git commit -m "feat: show repository datatype mappings"
```

### Task 4: P1 generated execution-plan hardening

**Files:**
- Modify: `sdcli-scripts/migrate.sh:1555-1810`
- Modify: `sdcli-scripts/lib/sqlldr`
- Modify: `tests/deploy_orchestration_test.sh`
- Modify: `tests/deploy_schema_password_test.sh`
- Modify: `tests/load_tns_alias_test.sh`
- Test: `tests/role_cleanup_test.sh`

**Interfaces:**
- Consumes: SQL Developer `master.sql`, `foreignkeys.sql`, `passworddefinition.sql`, and SQL*Loader `.ctl` bounded protocols.
- Produces: deterministic ordered execution lists or an actionable unsupported-format failure.

- [ ] **Step 1: Add failing multiline and ambiguity tests**

Prove multiline `foreignkeys.sql` is not skipped, unreferenced empty foreign-key files run harmlessly once, unsupported active master include forms fail, malformed/duplicate `ACCEPT` prompts fail, and multiple `INFILE` or `INTO TABLE` records fail.

- [ ] **Step 2: Remove foreign-key DDL inspection**

If an unreferenced `foreignkeys.sql` exists, append it once after master-listed post scripts without inspecting its SQL text.

- [ ] **Step 3: Harden bounded parsers**

Validate supported `@`/`@@` include records, prompt identifiers, prompt `HIDE`, control-file cardinality, identifiers, and `LC_ALL=C` ordering. Do not add general SQL parsing.

- [ ] **Step 4: Run deploy/load regression tests**

Run: `bash tests/deploy_orchestration_test.sh && bash tests/deploy_schema_password_test.sh && bash tests/role_cleanup_test.sh && bash tests/load_tns_alias_test.sh`

Expected: PASS with cleanup, postdeploy continuation, password handling, and wallet behavior unchanged.

- [ ] **Step 5: Commit and review Task 4**

```bash
git add sdcli-scripts/migrate.sh sdcli-scripts/lib/sqlldr tests
git commit -m "fix: make generated execution plans fail closed"
```

### Task 5: P1 per-action postconditions

**Files:**
- Modify: `.gitignore`
- Modify: `sdcli-scripts/migrate.sh:543-825`
- Modify: `sdcli-scripts/migrate.sh:2890-3290`
- Create: `tests/sdcli_action_postcondition_test.sh`
- Modify: existing BCP, SQL*Loader, phase-status, and model-selection tests.

**Interfaces:**
- Consumes: SDCLI exit code, exact action marker, model lookup, generated inventory, and structured BCP/SQL*Loader/manifest evidence.
- Produces: `verify_phase_postcondition(phase, run_context)` returning success only when that phase's artifact contract is satisfied.

- [ ] **Step 1: Add one missing-artifact failure test per phase**

Use fake tools returning zero and human-readable success while omitting the required model or file. Each phase must fail its postcondition.

- [ ] **Step 2: Implement explicit phase postconditions**

Keep diagnostic regexes as warnings. Require the exact artifact contracts listed in the design before recording phase success.

- [ ] **Step 3: Run workflow reliability tests**

Run all `tests/sdcli_*`, `tests/model_selection_test.sh`, `tests/phase_status_resume_test.sh`, `tests/offload_*`, and load tests.

Expected: PASS and no zero-exit/missing-artifact false success.

- [ ] **Step 4: Commit and review Task 5**

```bash
git add .gitignore sdcli-scripts/migrate.sh tests
git commit -m "fix: verify migration phase postconditions"
```

### Task 6: P2 controlled preferences and focused libraries

**Files:**
- Modify: `.gitignore`
- Create: `sdcli-scripts/templates/product-preferences.xml`
- Create: `sdcli-scripts/lib/sqlplus_deploy.sh`
- Modify: `sdcli-scripts/migrate.sh:270-335`
- Modify: `deployment/run.sh`
- Create: `tests/migrate_preferences_test.sh`
- Modify: deploy/postdeploy tests.

**Interfaces:**
- Consumes: `SQLDEVELOPER_FILE_OUTPUT_OPTION` and known autokit-owned preference template.
- Produces: idempotent preference installation plus sourced SQL*Plus deploy helpers with unchanged public shell function names.

- [ ] **Step 1: Add formatting-independent preference tests**

Cover missing preferences, autokit-owned existing template, repeated installation, and an unknown existing XML layout. Unknown XML must remain untouched with an actionable message.

- [ ] **Step 2: Install a controlled template**

Copy and substitute only the documented numeric output option in an autokit-owned template. Remove broad AWK mutation of arbitrary user XML.

- [ ] **Step 3: Extract stable SQL*Plus deploy helpers**

Move cohesive deploy, cleanup, manifest, and bounded include functions into `sdcli-scripts/lib/sqlplus_deploy.sh` without changing command behavior.

- [ ] **Step 4: Run full verification**

Run: `bash -n sdcli-scripts/migrate.sh sdcli-scripts/lib/*.sh tests/*.sh && for test_file in tests/*.sh; do bash "$test_file" || exit 1; done && python3 -m unittest tests/test_validation_report.py`

Expected: PASS; timeout-only test may explicitly skip when `timeout` is unavailable.

- [ ] **Step 5: Commit and request whole-branch review**

```bash
git add deployment sdcli-scripts README.md tests
git commit -m "refactor: isolate controlled migration parsers"
```

Review the complete diff for customer-specific assumptions, unsupported SQL parsing, secret exposure, incomplete evidence handling, and one-maintainer complexity before creating the remote PR.
