# Per-Migration Repository Context Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every named migration use repository and super-user connections derived from its name and bound to its own Oracle target, without duplicating repository credentials in `config.yaml`.

**Architecture:** Resolve one immutable active repository context from the selected migration before logging, wallet setup, locking, or SDCLI execution. Existing global repository fields remain credential/name-prefix defaults; named workflows use `migrations[index].target.conn`, derived connection names, and an optional migration-level wallet override.

**Tech Stack:** Bash 4+, `yq`, SQL Developer 26.2 SDCLI, SQL*Plus, existing shell test fakes.

**Spec:** `docs/superpowers/specs/2026-10-22-per-migration-repository-design.md`

## Global Constraints

- Keep production orchestration in Bash; add no Python runtime logic.
- Do not parse, edit, rename, or delete SQL Developer `connections.json`.
- Do not delete or recreate existing repository data, models, or run artifacts.
- Named workflows must use `migrations[index].target.conn`, never the global repository endpoint.
- Global repository connection names are prefixes; derive `<prefix>_<migration name>`.
- Preserve exact SDCLI success-marker and narrowly-scoped `init`/`ORA-01920` handling.
- Keep secrets in environment placeholders and existing redaction paths.
- Tests use fakes and fixtures only; no live customer database or password-combination testing.

## Review Focus

- A multi-migration no-name `--init` must fail before driver, wallet, lock, or SDCLI work; Task 2 adds this process-level assertion.
- A failed migration-specific init must not retry with unsuffixed legacy names; Task 2 inspects every fake-SDCLI invocation.
- A migration-level wallet must override the default without leaking into another migration; Task 3 tests both selections in one fixture.
- Existing Proda repository initialization with `ORA-01920` must still register/use the derived alias only when the exact success marker is present; Task 2 extends the idempotency fixture.
- No named repository consumer may continue reading `.migration_repository.conn` directly; Task 4 adds command assertions and a focused source audit.

---

## File structure

- Modify `sdcli-scripts/migrate.sh`: active migration/repository context,
  migration-aware init parsing, wallet selection, lock identity, SDCLI routing,
  repository SQL routing, and init run layout.
- Create `tests/per_migration_repository_context_test.sh`: context derivation,
  migration selection, endpoint isolation, and name construction.
- Create `tests/per_migration_repository_init_test.sh`: process-level init
  commands, failure behavior, single-migration compatibility, and existing-user
  idempotency.
- Modify `tests/repository_lock_test.sh`: active-context lock identity.
- Modify `tests/run_layout_test.sh`: migration-specific init evidence path.
- Modify `tests/datatype_mapping_command_test.sh`: named versus global/default
  repository SQL selection.
- Modify `sdcli-scripts/config.example.yaml`: explain name-prefix and endpoint
  semantics; show optional target wallet override.
- Modify `README.md`: document per-migration initialization, derived names,
  wallet selection, upgrade compatibility, and command sequence.
- Modify `docs/CHANGELOG.md`: record the repository isolation correction for
  maintainers.

### Task 1: Resolve an active repository context

**Files:**
- Create: `tests/per_migration_repository_context_test.sh`
- Modify: `sdcli-scripts/migrate.sh` near configuration access helpers and `get_migration_index`

**Interfaces:**
- Consumes: existing `migration_required_value`, `get_required_value`, and
  `get_migration_index` helpers.
- Produces: `derive_migration_connection_name(prefix, migration_name)`,
  `resolve_migration_context(index)`, `resolve_global_repository_context()`,
  and immutable process globals `ACTIVE_MIGRATION_INDEX`,
  `ACTIVE_MIGRATION_NAME`, `ACTIVE_REPOSITORY_CONN`,
  `ACTIVE_REPOSITORY_NAME`, `ACTIVE_SUPER_CONNECTION_NAME`, and
  `ACTIVE_WALLET_DIR`.

- [ ] **Step 1: Write the context regression test**

Create a two-migration fixture for Proda and Cecrealm. In isolated subshells,
assert that resolving each index yields its own target endpoint and these exact
names:

```text
migration_repo_proda / super_migration_proda
migration_repo_cecrealm / super_migration_cecrealm
```

Also add a deliberate test-only reset between resolutions and assert Cecrealm's
complete context retains no Proda endpoint or name.

- [ ] **Step 2: Run the test to verify RED**

Run: `bash tests/per_migration_repository_context_test.sh`

Expected: FAIL because the context resolver and derived-name function do not
exist.

- [ ] **Step 3: Implement context derivation**

Add the interfaces above. `resolve_migration_context(index)` must read the
selected target endpoint, derive both suffixed names from global prefixes, and
select `migrations[index].target.wallet_dir` before the default wallet. Reject
an empty migration name, prefix, endpoint, or derived name.

- [ ] **Step 4: Add the global/default context path**

`resolve_global_repository_context()` must use the unsuffixed repository name,
global `migration_repository.conn`, and default wallet only. It exists solely
for the no-name datatype-mapping command.

- [ ] **Step 5: Run focused tests**

Run: `bash tests/per_migration_repository_context_test.sh && bash tests/config_database_type_test.sh`

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add sdcli-scripts/migrate.sh tests/per_migration_repository_context_test.sh
git commit -m "feat: resolve per-migration repository context"
```

### Task 2: Make repository initialization migration-specific

**Files:**
- Create: `tests/per_migration_repository_init_test.sh`
- Modify: `sdcli-scripts/migrate.sh` in `parse_args`, `main`, `setup_repository`, and config validation
- Modify: `tests/sdcli_success_marker_test.sh`
- Modify: `tests/sdcli_success_marker_error_test.sh`

**Interfaces:**
- Consumes: `resolve_migration_context(index)` and active context globals from
  Task 1.
- Produces: `select_init_migration()` returning the explicit migration index,
  inferring the only configured migration, or failing before side effects.

- [ ] **Step 1: Write process-level init failures**

In a config with Proda and Cecrealm, assert `./migrate.sh --init` exits nonzero,
prints `./migrate.sh <name> --init`, and never invokes fake `sdcli`. Assert an
unknown explicit name also fails before fake SDCLI.

- [ ] **Step 2: Write init command isolation assertions**

Run `proda --init` and `cecrealm --init` against fake SDCLI. Capture all argv
and assert each init command contains only its derived repository/super names
and selected target endpoint. Assert no command contains the other migration's
endpoint or unsuffixed final connection names.

- [ ] **Step 3: Write backward-compatibility and failure tests**

Assert a one-migration config allows no-name `--init`, logs the inferred name,
and emits the suffixed connections. Extend the existing exact
`ORA-01920`/success-marker case to the derived names. Assert any other ORA or a
missing marker fails and does not retry using legacy names. Assert
`--conn-setup` reports that connection definitions were saved and database
connectivity was not tested.

- [ ] **Step 4: Run the tests to verify RED**

Run: `bash tests/per_migration_repository_init_test.sh && bash tests/sdcli_success_marker_test.sh && bash tests/sdcli_success_marker_error_test.sh`

Expected: FAIL because init forbids a migration name and still uses the global
endpoint/final names.

- [ ] **Step 5: Implement init selection and command construction**

Allow a migration name with `--init`. Before `bootstrap_logging`, call
`select_init_migration`, set `MIGRATION_NAME`, validate that migration, and
resolve its context. Change `setup_repository()` to consume only active
context values for endpoint and connection names while retaining global users,
passwords, and existing redaction. Make the `--conn-setup` completion message
explicitly distinguish saved definitions from a live connectivity test.

- [ ] **Step 6: Run focused init tests**

Run: `bash tests/per_migration_repository_init_test.sh && bash tests/sdcli_success_marker_test.sh && bash tests/sdcli_success_marker_error_test.sh && bash tests/sdcli_error_exit_test.sh`

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add sdcli-scripts/migrate.sh tests/per_migration_repository_init_test.sh tests/sdcli_success_marker_test.sh tests/sdcli_success_marker_error_test.sh
git commit -m "fix: isolate repository initialization by migration"
```

### Task 3: Bind wallet, logging, and locking to the active migration

**Files:**
- Modify: `sdcli-scripts/migrate.sh` in wallet configuration, `bootstrap_logging`, and repository locking
- Modify: `tests/per_migration_repository_context_test.sh`
- Modify: `tests/repository_lock_test.sh`
- Modify: `tests/run_layout_test.sh`

**Interfaces:**
- Consumes: active context globals from Task 1.
- Produces: `configure_active_oracle_wallet()` and repository lock identity
  `<ACTIVE_REPOSITORY_NAME>|<ACTIVE_REPOSITORY_CONN>`.

- [ ] **Step 1: Add wallet selection assertions**

Extend the two-migration context test with distinct wallet directories. Assert
the migration target wallet overrides the default for Cecrealm, while Proda
falls back to the default. Assert an invalid selected wallet reports its exact
config path before fake SDCLI runs.

- [ ] **Step 2: Add lock and init-layout assertions**

Update `repository_lock_test.sh` to prove the same active context collides and
different target endpoints produce different lock directories. Update
`run_layout_test.sh` to require:

```text
<project_root>/_init/<migration>/run_<id>/
```

- [ ] **Step 3: Run the tests to verify RED**

Run: `bash tests/per_migration_repository_context_test.sh && bash tests/repository_lock_test.sh && bash tests/run_layout_test.sh`

Expected: FAIL because wallet, lock, and init layout still use global state.

- [ ] **Step 4: Implement active wallet, lock, and layout behavior**

Replace the global-only wallet lookup with
`configure_active_oracle_wallet()`. Change `acquire_repository_lock()` to use
the active context and `bootstrap_logging()` to include the selected migration
under `_init`. Do not write endpoints or secrets to lock-owner metadata.

- [ ] **Step 5: Run focused tests**

Run: `bash tests/per_migration_repository_context_test.sh && bash tests/repository_lock_test.sh && bash tests/run_layout_test.sh && bash tests/load_tns_alias_test.sh`

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add sdcli-scripts/migrate.sh tests/per_migration_repository_context_test.sh tests/repository_lock_test.sh tests/run_layout_test.sh
git commit -m "fix: bind wallet and locks to migration repository"
```

### Task 4: Route every repository consumer through the context

**Files:**
- Modify: `sdcli-scripts/migrate.sh` in `run_single_migration`, phase routing, datatype-mapping validation, and repository SQL capture
- Modify: `tests/per_migration_repository_context_test.sh`
- Modify: `tests/datatype_mapping_command_test.sh`
- Modify: `tests/model_selection_test.sh`

**Interfaces:**
- Consumes: active repository context from Task 1.
- Produces: `run_repository_sql_capture(sql_file, output_file)` connecting to
  `ACTIVE_REPOSITORY_CONN`; the no-name datatype command resolves the global
  context before calling it.

- [ ] **Step 1: Add phase-routing assertions**

Capture fake SDCLI argv for capture, convert, generate, and datamove. Assert
each `-repository` value is the selected derived name and never the unsuffixed
prefix or other migration's name.

- [ ] **Step 2: Add datatype-mapping repository assertions**

Extend `datatype_mapping_command_test.sh`: the no-name form connects to global
`migration_repository.conn`; the named Cecrealm form resolves Cecrealm's
target endpoint and uses the existing project-name SQL filter. Assert passwords
remain absent from stdout and stderr.

- [ ] **Step 3: Run tests to verify RED**

Run: `bash tests/per_migration_repository_context_test.sh && bash tests/datatype_mapping_command_test.sh && bash tests/model_selection_test.sh`

Expected: FAIL because phases and SQL capture still read global repository
values.

- [ ] **Step 4: Implement repository consumer routing**

Make `run_single_migration` and every repository-backed phase use
`ACTIVE_REPOSITORY_NAME`. Make named datatype mapping resolve the migration
context and global mapping resolve the global context. Make repository SQL
capture read only active endpoint/user/password values.

- [ ] **Step 5: Audit remaining global endpoint reads**

Run:

```bash
rg -n "migration_repository\\.conn|get_repository_connection_name" sdcli-scripts/migrate.sh
```

Expected: global endpoint reads remain only in global-context resolution and
global/default datatype validation; no named workflow helper reads them.

- [ ] **Step 6: Run focused routing tests**

Run: `bash tests/per_migration_repository_context_test.sh && bash tests/datatype_mapping_command_test.sh && bash tests/model_selection_test.sh && bash tests/sdcli_action_postcondition_test.sh`

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add sdcli-scripts/migrate.sh tests/per_migration_repository_context_test.sh tests/datatype_mapping_command_test.sh tests/model_selection_test.sh
git commit -m "fix: route repository operations by migration"
```

### Task 5: Document the corrected configuration and upgrade path

**Files:**
- Modify: `sdcli-scripts/config.example.yaml`
- Modify: `README.md`
- Modify: `docs/CHANGELOG.md`

**Interfaces:**
- Consumes: final CLI and config behavior from Tasks 1-4.
- Produces: customer instructions for repository naming, initialization,
  wallets, and existing-repository alias registration.

- [ ] **Step 1: Update the example configuration**

Document global `connection_name` values as prefixes, label global `conn` as
the no-name/default datatype endpoint, and show an optional
`migrations[].target.wallet_dir` without adding duplicate repository
credentials.

- [ ] **Step 2: Update README commands and semantics**

Replace repository initialization examples with
`./migrate.sh <migration> --init`; document the single-migration no-name
compatibility, multi-migration failure, derived connection inventory, target
endpoint selection, wallet precedence, and the one-time existing-repository
alias registration procedure. State that legacy connections and database data
are not removed.

- [ ] **Step 3: Record the engineering change**

Add an unreleased changelog entry identifying the global repository connection
collision and the per-migration correction. Do not add the engineering
changelog to customer bundles.

- [ ] **Step 4: Verify documentation consistency**

Run:

```bash
git diff --check
rg -n "migrate\.sh .*--init|migration_repo_|super_migration_|wallet_dir" README.md sdcli-scripts/config.example.yaml
```

Expected: no whitespace errors; examples consistently show migration-specific
init and derived names.

- [ ] **Step 5: Commit**

```bash
git add README.md sdcli-scripts/config.example.yaml docs/CHANGELOG.md
git commit -m "docs: explain per-migration repository setup"
```

### Task 6: Full verification and branch review

**Files:**
- Modify only files required by verified failures found in this task.

**Interfaces:**
- Consumes: all completed tasks.
- Produces: a release-ready feature branch with fresh verification evidence.

- [ ] **Step 1: Run syntax and focused defect tests**

Run:

```bash
bash -n sdcli-scripts/migrate.sh
bash tests/per_migration_repository_context_test.sh
bash tests/per_migration_repository_init_test.sh
bash tests/repository_lock_test.sh
bash tests/run_layout_test.sh
bash tests/datatype_mapping_command_test.sh
```

Expected: all commands exit zero.

- [ ] **Step 2: Run the full regression suite**

Run:

```bash
for test_file in tests/*_test.sh; do bash "$test_file"; done
python3 -m unittest tests/test_validation_report.py
```

Expected: every shell test and Python report test passes.

- [ ] **Step 3: Inspect the final diff and repository reads**

Run:

```bash
git diff --check
git status --short
rg -n "migration_repository\\.conn|get_repository_connection_name" sdcli-scripts/migrate.sh
```

Expected: no unintended files, no whitespace errors, and no named workflow
consumer bypasses the active context.

- [ ] **Step 4: Request whole-branch review**

Have a fresh reviewer compare the implementation with
`docs/superpowers/specs/2026-10-22-per-migration-repository-design.md`, focusing
on cross-target isolation, existing-repository compatibility, password
redaction, and test gaps. Resolve every Critical or Important finding and rerun
the relevant tests.

- [ ] **Step 5: Commit verified review corrections if any**

Stage only the exact files changed to resolve verified review findings, then
commit them with message `fix: address per-migration repository review`. If
review requires no changes, do not create an empty commit.
