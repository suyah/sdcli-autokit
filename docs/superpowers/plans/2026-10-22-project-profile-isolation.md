# Project Profile Isolation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Execution method: Native, as selected by the user.

**Goal:** Make SQL Developer 26.2 repository state independent per migration.

**Architecture:** A small Bash runtime library owns profile lifecycle and locks.
The existing runner supplies its IDE_USER_DIR; the vendor owns repository
preferences and encryption metadata. Keep shared-state backup separate from
normal execution.

**Tech Stack:** Bash, Oracle Linux 9, SQL Developer 26.2, existing yq/jq utilities.

**Spec:** `docs/superpowers/specs/2026-10-22-project-profile-isolation-design.md`

## Global Constraints

- SQL Developer 26.2 only; no Python added; no customer or project literals.
- No legacy profile fallback, XML DefaultRepository switching, or credential copying.
- All persistent runtime data is under the configured data volume.
- Test scripts remain minimal; fake SDK only at the external process boundary.
- Git: feature branch → remote PR → remote merge → update local main.

## Review Focus

- Inherited wallet properties must not override the selected project's wallet.
- A successful connection listing alone does not prove saved-password usability.
- Two aliases for one repository must not bypass its lock.
- Oracle-only artifact phases must still work without profile initialization.
- Fresh-profile initialization must install FileOutputOption before vendor save.

### Task 1: Profile runtime

**Files:** new `sdcli-scripts/lib/sdcli_profile.sh`, new `tests/project_profile_test.sh`, modified `sdcli-scripts/migrate.sh`.

**Interfaces:** `prepare_project_profile()` selects SDCLI_PROFILE_DIR and validates
pending/ready state; `mark_project_profile_ready()` commits ready state;
`release_profile_lock()` releases only an owned lock;
`normalize_oracle_java_options()` removes wallet properties without losing
other options. `mode_uses_sdcli()` decides which modes consume this interface.

- [x] Write a focused test exercising actual library and runner calls through a fake executable: separate concurrent profile/wallet environments; ready gating; same-profile contention; changed identity; no-wallet normalization.
- [x] Observe missing behavior fail, implement the library and child env boundary.
- [x] Run the focused test and affected runner/wallet tests; commit.

### Task 2: Initialization and repository routing

**Files:** `sdcli-scripts/migrate.sh`, `tests/per_migration_repository_init_test.sh`, `tests/sdcli_action_postcondition_test.sh`, `tests/repository_lock_test.sh`, preferences fixtures.

**Interfaces:** `initialize_project_preferences()` bootstraps layout with help;
the existing configure_sqldeveloper_file_output_option consumes SDCLI_PROFILE_DIR.
Repository lock consumes endpoint plus configured repository user.

- [x] Extend existing tests for profile-before-driver ordering, help handling, failed init remaining pending and alias-independent repository locks; observe failures.
- [x] Route named SDK modes through profile setup/locks; mark ready only after init success. Remove unsupported -repository flags from affected vendor commands; update boundary expectations to check profile selection.
- [x] Configure preferences inside the selected profile; preserve unrelated vendor metadata. Normalize wallet environment once for Oracle subprocesses.
- [x] Run focused tests and relevant existing suite; commit.

### Task 3: Deployment, strace and operator documentation

**Files:** `deployment/run.sh`, `deployment/Dockerfile`, `tests/test_offline_run.sh`, `README.md`, `docs/CHANGELOG.md`.

- [x] Update deployment fixtures to cover preserving old state without initializing shared preferences.
- [x] Remove shared preference setup; use a disposable data-volume profile for SDK startup checks. Install/check strace.
- [x] Document complete backup, new per-project init sequence, manual SDK profile selection and explicit rollback. Retain source/run artifacts. Update engineering changelog.
- [x] Run deployment/offline tests and syntax checks; commit.

### Task 4: Real-container verification and integration

**Files:** engineering verification notes alongside the spec; private container test configuration/logs outside Git.

- [x] Back up the complete old test-container profile and config under /u01/data with restrictive permissions.
- [ ] Stage the feature scripts separately in the existing running container. Use the explicitly authorized ExaCS schema MIGREP_AUTOKIT_TEST_20261022 for fresh init, then reopen from an independent process. Check preferences/default repository and database evidence without logging passwords.
- [ ] Run the full shell suite including offline tests and report tests, inspect the branch diff, and perform one independent whole-branch review.
- [ ] Fix important review findings, commit verified results, push feature branch and create/merge remote PR; fast-forward local main. Preserve test container/schema and report test limitations.
