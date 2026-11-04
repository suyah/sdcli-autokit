# Password Definition Contract Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace SQL*Plus prompt grammar validation with a stable identifier-only contract for non-interactive schema-password injection.

**Architecture:** The generated password definition file remains immutable. The Bash deploy helper extracts only active `ACCEPT <identifier>` prefixes and writes the existing temporary `DEFINE` file from those identifiers; all suffix syntax stays vendor-owned and opaque.

**Tech Stack:** Bash 3-compatible shell, awk, SQL*Plus temporary scripts, existing shell regression tests.

**Spec:** `docs/superpowers/specs/2026-11-05-passworddefinition-contract-design.md`

## Global Constraints

- Support SQL Developer 26.2, SQL Server sources, and Oracle targets only.
- Do not modify generated SDCLI files or add a runtime dependency.
- Keep secrets in private temporary files and out of logs.
- Preserve the existing single `default_schema_password` configuration model.

## Review Focus

- Block comments containing text that resembles `ACCEPT` must not create a definition; test in Task 1.
- Prompt suffix changes such as missing whitespace before `HIDE` must not matter; test in Task 1.
- An active `ACCEPT` without a safe identifier must still fail; test in Task 1.
- Repeated identifiers must yield one definition; test in Task 1.
- Existing temporary-file cleanup and SQL*Plus invocation must remain unchanged; cover in Task 2 regressions.

### Task 1: Define the identifier-only extraction contract

**Files:**
- Modify: `tests/deploy_schema_password_test.sh`
- Modify: `sdcli-scripts/lib/sqlplus_deploy.sh`

**Interfaces:**
- Consumes: `sqlplus_accept_prompt_names <passworddefinition.sql>`.
- Produces: newline-delimited, unique safe SQL*Plus variable names; nonzero only for malformed active `ACCEPT` prefixes or unterminated comments.

- [ ] **Step 1: Write failing extraction cases**

Add exact CECREALM content plus prompt suffix variants, block comments, unrelated directives, repeated identifiers, and malformed `ACCEPT` cases. Assert only safe identifier extraction and a unique count.

- [ ] **Step 2: Run the password regression to verify failure**

Run: `bash tests/deploy_schema_password_test.sh`

Expected: FAIL because the current implementation validates `HIDE` and rejects non-comment control text.

- [ ] **Step 3: Simplify `sqlplus_accept_prompt_names`**

In `sdcli-scripts/lib/sqlplus_deploy.sh`, scan comments and identify only the case-insensitive `ACCEPT <identifier>` prefix. Do not parse or validate suffix syntax. Retain safe identifier validation and temporary DEFINE generation.

- [ ] **Step 4: Run the focused regression to verify success**

Run: `bash tests/deploy_schema_password_test.sh`

Expected: PASS.

### Task 2: Preserve deploy behavior and document the boundary

**Files:**
- Modify: `sdcli-scripts/lib/sqlplus_deploy.sh`
- Modify: `tests/deploy_schema_password_test.sh`
- Modify: `docs/CHANGELOG.md`

**Interfaces:**
- Consumes: unique password-variable names from Task 1.
- Produces: private temporary `DEFINE` file and accurate log terminology.

- [ ] **Step 1: Update wording and assertions**

Change the operator log from password prompts to password variables and assert the existing private `DEFINE` lifecycle still receives each identifier once.

- [ ] **Step 2: Run deploy-related regressions**

Run: `bash tests/deploy_schema_password_test.sh && bash tests/deploy_orchestration_test.sh && bash tests/generated_deploy_fallback_test.sh && bash tests/role_cleanup_test.sh && bash tests/load_tns_alias_test.sh`

Expected: PASS.

- [ ] **Step 3: Run syntax and diff checks**

Run: `bash -n sdcli-scripts/migrate.sh sdcli-scripts/lib/sqlplus_deploy.sh && git diff --check`

Expected: PASS.

- [ ] **Step 4: Commit**

Commit the extractor, tests, and engineering changelog on a dedicated feature branch, then use the project's remote PR merge workflow.

## Self-review

- The plan covers immutable generated input, narrow parsing, comment handling, identifier safety, duplicate behavior, temporary secret handling, and deploy regressions.
- The only behavior change is accepting vendor suffix variations and ignoring unrelated control lines; target DDL and configuration are unchanged.
