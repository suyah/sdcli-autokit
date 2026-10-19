# Reliability Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make migration command outcomes, generated SQL deployment, password handling, and offline script upgrades fail safely without adding another runtime architecture.

**Architecture:** Keep `migrate.sh` as the SDCLI boundary and `sqlplus_deploy.sh` as the generated-SQL boundary. Narrow both boundaries to explicit success contracts, and make `deployment/run.sh` synchronize only versioned program files while treating customer configuration and migration data as durable state.

**Tech Stack:** Bash 4+, AWK for bounded generated-file protocols, SQL Developer CLI, SQL*Plus, Podman/Docker-compatible shell tests, and the existing Python 3 standard-library report renderer unchanged.

**Spec:** `docs/superpowers/specs/2026-10-19-reliability-hardening-design.md`

## Global Constraints

- Support the SQL Server-to-Oracle workflow only.
- Keep database execution and generated-file protocol checks in Bash.
- Do not add Python database access or expand the report renderer's responsibility.
- Do not modify generated migration-run evidence or overwrite customer `config.yaml`.
- Accept only the tested flat per-schema SQL Developer output layout; unknown layouts fail before generated schema SQL executes.
- Do not add source-quiescence or strict migration-name/path validation in this change.

## Review Focus

- An SDCLI command that prints the exact success marker and a disallowed `ORA-` diagnostic must still fail.
- Only `init` with `ORA-01920`, no other disallowed diagnostic, and the exact init completion marker may succeed idempotently.
- Schema passwords containing spaces, `@`, semicolons, and double quotes must reach SQL*Plus without changing the generated password file or appearing in logs.
- A supported flat schema layout must still execute `user.sql` plus master-listed pre/post data scripts in the existing order.
- Re-running `deployment/run.sh` must refresh changed program content and its version marker while preserving an existing customer `config.yaml` byte-for-byte.

---

### Task 1: Enforce truthful SDCLI completion

**Files:**
- Modify: `sdcli-scripts/migrate.sh`
- Modify: `tests/sdcli_success_marker_test.sh`
- Modify: `tests/sdcli_success_marker_error_test.sh`
- Modify: `tests/sdcli_error_exit_test.sh`

**Interfaces:**
- Consumes: the action parsed from `-actions=<action>` and the captured raw SDCLI output.
- Produces: `run_sdcli ...` returning zero only for exit zero, an exact `<action> completed successfully` line, and no disallowed diagnostic; `SDCLI_LAST_SUCCESS_MARKER` remains the observed-marker flag.

- [ ] **Step 1: Extend the SDCLI regression fixtures before changing production code.**

Add cases for `mkconn` and `driver` that exit zero without a completion marker, exit zero with `ORA-01017`, and print a marker plus `ORA-01017`; assert all fail. Add the exact `init completed successfully` plus only `ORA-01920` case and assert it succeeds, while any second Oracle diagnostic makes it fail.

- [ ] **Step 2: Run the focused tests and verify RED.**

Run: `bash tests/sdcli_success_marker_test.sh && bash tests/sdcli_success_marker_error_test.sh && bash tests/sdcli_error_exit_test.sh`

Expected: at least the zero-exit/no-marker and bare-Oracle-diagnostic cases fail their assertions because current `run_sdcli` accepts them.

- [ ] **Step 3: Tighten `run_sdcli` and its diagnostic helper.**

Require a non-empty parsed action, the exact action completion marker, and absence of `Error`, `Fatal`, `ORA-`, `PLS-`, `SP2-`, or `LRM-` diagnostics. Preserve only the existing `init`/`ORA-01920` exception when its exact completion marker is present and no other disallowed diagnostic exists. Keep dry-run behavior unchanged.

- [ ] **Step 4: Run SDCLI and workflow regressions.**

Run: `bash tests/sdcli_success_marker_test.sh && bash tests/sdcli_success_marker_error_test.sh && bash tests/sdcli_error_exit_test.sh && bash tests/sdcli_conversion_diagnostic_test.sh && bash tests/sdcli_action_postcondition_test.sh`

Expected: PASS.

- [ ] **Step 5: Commit the independently working boundary change.**

```bash
git add sdcli-scripts/migrate.sh tests/sdcli_success_marker_test.sh tests/sdcli_success_marker_error_test.sh tests/sdcli_error_exit_test.sh
git commit -m "fix: require truthful sdcli completion"
```

### Task 2: Keep schema passwords out of durable run files

**Files:**
- Modify: `sdcli-scripts/migrate.sh`
- Modify: `sdcli-scripts/lib/sqlplus_deploy.sh`
- Modify: `tests/deploy_schema_password_test.sh`

**Interfaces:**
- Consumes: validated ACCEPT identifiers from `sqlplus_accept_prompt_names` and one invocation's schema password.
- Produces: `create_sqlplus_password_defines <source-file> <schema-password> <runtime-dir>` printing a `0600` DEFINE-file path; `run_sqlplus_file` sources it by absolute path and never writes to the source file.

- [ ] **Step 1: Change the password test first.**

Use a flat `<schema>/user.sql` fixture. Snapshot the generated `passworddefinition.sql`, capture the SQL*Plus wrapper and sourced DEFINE file, and assert: the source remains byte-identical, the wrapper uses the private absolute file, the special-character password is escaped correctly, no secret enters the run log, and a handled TERM cleanup path removes registered runtime directories.

- [ ] **Step 2: Run the password regression and verify RED.**

Run: `bash tests/deploy_schema_password_test.sh`

Expected: FAIL because current code overwrites `sdcli/passworddefinition.sql` during execution and the wrapper references the durable relative file.

- [ ] **Step 3: Add the private runtime-file lifecycle.**

Add one process-wide array and cleanup helper in `migrate.sh`, invoked by `on_exit`. In `sqlplus_deploy.sh`, replace `install_sqlplus_password_defines` with `create_sqlplus_password_defines`, create a `0700` runtime directory and `0600` DEFINE file, put the wrapper there, source the DEFINE file by absolute path, and remove/unregister the directory immediately after SQL*Plus. Do not claim cleanup for uncatchable process or host failure.

- [ ] **Step 4: Run deploy security and orchestration regressions.**

Run: `bash tests/deploy_schema_password_test.sh && bash tests/deploy_orchestration_test.sh && bash tests/role_cleanup_test.sh && bash tests/load_tns_alias_test.sh`

Expected: PASS.

- [ ] **Step 5: Commit the password lifecycle change.**

```bash
git add sdcli-scripts/migrate.sh sdcli-scripts/lib/sqlplus_deploy.sh tests/deploy_schema_password_test.sh
git commit -m "fix: isolate deploy password definitions"
```

### Task 3: Reject unsupported generated SQL layouts

**Files:**
- Modify: `sdcli-scripts/lib/sqlplus_deploy.sh`
- Modify: `tests/generated_deploy_fallback_test.sh`
- Modify: `tests/deploy_orchestration_test.sh`

**Interfaces:**
- Consumes: generated SQL directory and the bounded list returned by `schema_master_includes`.
- Produces: `validate_generated_sql_inventory <output-dir>` accepting only flat schema files that are explicit control files or direct master-plan entries; deploy has no monolithic fallback.

- [ ] **Step 1: Replace permissive expectations with fail-closed tests.**

Change the fallback test to assert a sole `gen/*.sql` layout fails before `run_sqlplus_file`. Add a nested `<schema>/post/*.sql` and a nested group file whose parent group is master-listed; assert each fails before SQL*Plus. Retain a flat schema fixture and assert its expected deployment calls and ordering.

- [ ] **Step 2: Run layout tests and verify RED.**

Run: `bash tests/generated_deploy_fallback_test.sh && bash tests/deploy_orchestration_test.sh`

Expected: FAIL because the current fallback executes the monolithic script and nested files are treated as implicitly covered.

- [ ] **Step 3: Narrow inventory validation and remove fallback execution.**

Remove nested-path coverage from `schema_file_is_covered` and inventory reporting. Make absence of at least one schema directory containing both `user.sql` and `master.sql` an actionable unsupported-layout failure. Remove the `run_deploy` monolithic branch and its dry-run message; continue excluding a duplicate `gen/` output only when a valid schema hierarchy is present.

- [ ] **Step 4: Run all deployment regressions.**

Run: `bash tests/generated_deploy_fallback_test.sh && bash tests/deploy_orchestration_test.sh && bash tests/deploy_schema_password_test.sh && bash tests/role_cleanup_test.sh && bash tests/target_object_validation_test.sh`

Expected: PASS.

- [ ] **Step 5: Commit the fail-closed layout contract.**

```bash
git add sdcli-scripts/lib/sqlplus_deploy.sh tests/generated_deploy_fallback_test.sh tests/deploy_orchestration_test.sh
git commit -m "fix: reject unsupported generated sql layouts"
```

### Task 4: Separate customer configuration from offline program updates

**Files:**
- Create: `sdcli-scripts/config.example.yaml`
- Delete: `sdcli-scripts/config.yaml`
- Modify: `.gitignore`
- Modify: `deployment/run.sh`
- Modify: `release/build-offline.sh`
- Modify: `tests/test_offline_run.sh`
- Modify: `tests/test_offline_bundle.sh`
- Modify: `README.md`

**Interfaces:**
- Consumes: the release `VERSION`, bundled `sdcli-scripts` program tree, and existing container destination.
- Produces: `sync_sdcli_scripts` that refreshes `migrate.sh`, `lib/`, `templates/`, and `config.example.yaml`, creates `config.yaml` only when absent, and records `.autokit-script-version` only after successful sync.

- [ ] **Step 1: Add release and upgrade behavior tests first.**

Extend the bundle test to require `config.example.yaml` and reject `config.yaml` or project-specific host/service values. Extend the run test's fake container engine to model destination files; assert a stale `migrate.sh` is replaced, an existing config checksum is unchanged, a missing config is initialized from the example, and the version marker changes only after all required staged files validate.

- [ ] **Step 2: Run offline tests and verify RED.**

Run: `bash tests/test_offline_run.sh && bash tests/test_offline_bundle.sh`

Expected: FAIL because the bundle currently includes `config.yaml` and `sync_sdcli_scripts` skips updates when files merely exist.

- [ ] **Step 3: Introduce a neutral example and safe sync.**

Replace the tracked config with generic documented placeholders and ignore customer `sdcli-scripts/config.yaml`. Have `release/build-offline.sh` explicitly package the versioned program set. In `run.sh`, stage and validate that set, refresh only those program paths, preserve or initialize `config.yaml` as specified, then write `.autokit-script-version` from the loaded bundle version (or the explicit image override identifier).

- [ ] **Step 4: Update operator documentation.**

Document copying/editing `config.example.yaml`, preservation during reruns/upgrades, the installed version marker, strict SDCLI completion, and unsupported monolithic/nested SQL behavior. Keep the existing Python report renderer documented as the only narrow Python component rather than promising an all-Bash repository.

- [ ] **Step 5: Run offline tests and documentation checks.**

Run: `bash tests/test_offline_run.sh && bash tests/test_offline_bundle.sh && git grep -nE '(10\\.[0-9]+\\.[0-9]+\\.[0-9]+|68\\.233\\.113\\.119|adb\\.[A-Za-z0-9.-]+oraclecloud\\.com)' -- sdcli-scripts/config.example.yaml README.md || true`

Expected: both tests PASS; the grep prints no project-specific endpoint from the replaced configuration example.

- [ ] **Step 6: Commit packaging and documentation.**

```bash
git add .gitignore README.md deployment/run.sh release/build-offline.sh sdcli-scripts/config.example.yaml tests/test_offline_run.sh tests/test_offline_bundle.sh
git rm --cached sdcli-scripts/config.yaml
git commit -m "fix: preserve customer config during offline updates"
```

### Task 5: Verify the complete release candidate

**Files:**
- Modify if needed: files already owned by Tasks 1-4 only

**Interfaces:**
- Consumes: all preceding task contracts.
- Produces: a release-ready branch with syntax, shell, Python report, and offline packaging regressions passing.

- [ ] **Step 1: Run syntax and the complete automated suite.**

Run: `bash -n sdcli-scripts/migrate.sh sdcli-scripts/lib/*.sh deployment/*.sh release/*.sh tests/*.sh && for test_file in tests/*.sh; do bash "$test_file" || exit 1; done && python3 -m unittest discover -s tests -p 'test_validation_report.py' -v && git diff --check`

Expected: PASS with no syntax failures, test failures, or whitespace errors.

- [ ] **Step 2: Inspect a freshly generated fake offline bundle.**

Run: `bash tests/test_offline_bundle.sh`

Expected: PASS; archive inspection proves the neutral example and required program files are present and customer `config.yaml` is absent.

- [ ] **Step 3: Review the branch against the spec.**

Check `git diff "$(git merge-base origin/main HEAD)"..HEAD` for hard-coded project data, untested parser expansion, durable secret writes, and accidental Python responsibility growth. Correct only Critical or Important findings through a new failing test followed by the minimal fix.

- [ ] **Step 4: Commit any review-driven correction separately.**

Use a focused `fix:` commit naming the corrected contract; do not squash the task history locally before remote PR review.
