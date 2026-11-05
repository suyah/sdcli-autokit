# SqlPackage Source Schema Export Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a schema-only SQL Server export command backed by a
customer-supplied SqlPackage ZIP installed during offline deployment.

**Architecture:** A small standalone Bash command sources the existing
configuration helpers from `migrate.sh`; it does not duplicate YAML,
secret-expansion, connection parsing, or TLS policy code. It invokes
SqlPackage Extract once with `SchemaObjectType`, then creates a redacted
manifest beside the generated SQL tree. The customer stages the pinned official
ZIP; deployment verifies its checksum and installs it under persistent tool
storage rather than distributing the binary in the release image.

**Tech Stack:** Bash 3.2+, Oracle Linux 9 image, Microsoft SqlPackage/DacFx Linux x64, existing `yq` configuration parser.

**Spec:** `docs/superpowers/specs/2026-11-05-sqlpackage-source-schema-export-design.md`

## Global Constraints

- Support the existing tested SQL Developer 26.2 image only.
- Schema extraction never exports table data or changes either database.
- Reuse `migrate.sh` configuration, secret, source-connection, and TLS helpers; do not create a second parser.
- Do not parse or rewrite generated SQL with Bash or regular expressions.
- The script must never write a source password to logs, manifest, or export artefacts.
- SqlPackage's documented SQL authentication CLI limitation is retained in the design and README.
- Do not bundle the official SqlPackage binary until product/legal selects a distribution path; the official ZIP's `LICENSE.TXT` controls binary distribution.

## Review Focus

- A password containing shell metacharacters: test that it is one argument to the fake executable and is absent from outputs/logs.
- `strict`, `trust`, and `optional` source TLS modes: test their precise SqlPackage connection flags.
- Pre-existing output directory: test that export refuses it rather than overwriting evidence.
- SqlPackage nonzero exit: test that a redacted diagnostic survives but no success manifest is produced.
- A schema-only invocation: test the exact `ExtractAllTableData=False` and `SchemaObjectType` properties.

---

### Task 1: Select and implement the approved SqlPackage distribution path

**Files:**
- Modify: `deployment/Dockerfile` or `deployment/run.sh`, depending on the approved distribution path
- Create: `docs/licenses/SQLPACKAGE-LICENSE.txt` from the official ZIP
- Modify: `README.md`

**Interfaces:**
- Produces: an approved, documented `sqlpackage` executable location in the running container.
- Consumes: a product/legal decision, pinned version, SHA-256, official Linux x64 ZIP, and its `LICENSE.TXT`.

- [x] **Step 1: Obtain the approved binary-distribution decision**

Choose customer-supplied ZIP staging or publisher distribution with customer terms satisfying the official `LICENSE.TXT`.  Do not download or package the binary before this decision.

- [x] **Step 2: Write the failing distribution-path test**

Add the minimal static test that asserts the selected path pins a version/checksum, preserves `LICENSE.TXT`, and exposes `sqlpackage` at the documented location.

- [x] **Step 3: Implement only the approved distribution path**

For customer staging, validate and install the provided ZIP to persistent tool storage.  For approved publisher distribution, verify and install the ZIP at image build time.  Do not implement both paths.

- [x] **Step 4: Run the distribution-path test and document the boundary**

Verify the selected path and update README with the required customer action and licence acknowledgement.

### Task 2: Add the standalone schema export command

**Files:**
- Create: `sdcli-scripts/export-source-schema.sh`
- Modify: `README.md`
- Test: `tests/export_source_schema_test.sh`

**Interfaces:**
- Consumes: `export-source-schema.sh <migration> [--output <absolute-directory>]`, `config.yaml`, and environment-expanded source password.
- Produces: `<project_root>/<migration>/source-schema/<UTC timestamp>/sql/`, a redacted `sqlpackage-extract.log`, and `manifest.txt`; no output is overwritten.

- [x] **Step 1: Write a failing success-path test**

Create a fake `sqlpackage` that records a redacted argument shape and creates a SQL tree.  Assert that `export-source-schema.sh demo` derives its connection from a fixture config, invokes `/Action:Extract`, `ExtractAllTableData=False`, `ExtractTarget=SchemaObjectType`, and creates the default output layout without source data.

- [x] **Step 2: Run test to verify it fails**

Run: `bash tests/export_source_schema_test.sh`

Expected: FAIL because the command does not exist.

- [x] **Step 3: Implement `sdcli-scripts/export-source-schema.sh`**

Source `migrate.sh` in source-only mode.  Parse `<migration>` and optional absolute `--output`, resolve the migration source values through existing helpers, map existing TLS policy to SqlPackage flags, create a non-existing private output directory, invoke one SqlPackage Extract process, redact diagnostics, validate the SQL output tree, and write a password-free manifest.

- [x] **Step 4: Run the success-path test to verify it passes**

Run: `bash tests/export_source_schema_test.sh`

Expected: PASS.

- [x] **Step 5: Extend the test for review focus**

Add tests for special-character password non-disclosure, three TLS modes, output overwrite refusal, and SqlPackage failure with redacted diagnostics.  Each test uses the same fake executable and a fixture config; none contacts a database.

- [x] **Step 6: Run the command test to verify it passes**

Run: `bash tests/export_source_schema_test.sh`

Expected: PASS.

- [x] **Step 7: Document the command**

Add the operator command, output layout, LLM handoff guidance, source-data exclusion, and the SQL-auth process-argument limitation to README.

### Task 3: Verify image and regression behaviour

**Files:**
- Modify: `docs/superpowers/plans/2026-11-05-sqlpackage-source-schema-export.md` (mark completed steps only)

**Interfaces:**
- Consumes: Tasks 1–2.
- Produces: verification evidence for the packaged binary and focused tests.

- [x] **Step 1: Run focused test suite**

Run: `bash tests/export_source_schema_test.sh` plus the selected distribution-path test

Expected: PASS.

- [x] **Step 2: Build or inspect the local container image**

Run the existing image-build workflow, then run `sqlpackage /Version` inside the resulting container.

Expected: SqlPackage reports the pinned version and exits zero.

- [ ] **Step 3: Run repository shell regression suite**

Run the tracked shell test command used by the repository.

Expected: all relevant tests pass; document any pre-existing environment-only failure separately.

- [x] **Step 4: Re-read design and README examples**

Confirm documentation says `Extract`, never `Export`; it must describe schema-only output and must not advertise password secrecy beyond the documented process boundary.

### Verification note

Focused tests passed: `export_source_schema_test.sh`,
`sqlpackage_vendor_install_test.sh`, `test_offline_run.sh`, and
`test_offline_bundle.sh`. A local Oracle Linux 9 image build completed after
removing the unavailable `libunwind` package; the customer ZIP ran inside it
and reported `170.4.83.3`.

The broad local shell-test loop stops at the pre-existing,
ignored `tests/capture_project_name_test.sh`: its source-only fixture calls
`run_single_migration` without setting the per-migration repository context
required by the current `migrate.sh`. This change does not alter that code path,
so Task 3 Step 3 remains intentionally unchecked rather than folding an
unrelated fixture repair into the SqlPackage feature.

## Self-review

- **Spec coverage:** Task 1 is explicitly blocked on selecting the lawful distribution path; Task 2 provides the one command, safe output, configuration reuse, TLS, and diagnostics; Task 3 verifies packaging, behaviour, and docs.  No unapproved binary is packaged.
- **Step scan:** Each code change has a preceding observable failing shell test.  No task asks the implementer to invent a second parser or a custom DDL renderer.
- **Type consistency:** The command name, arguments, output names, and Docker executable path are consistent with the design.
- **Review focus:** Password non-disclosure, TLS choices, overwrite protection, failure diagnostics, and schema-only properties are assigned to Task 2 tests.
- **Proportion:** Three tasks cover packaging, command behavior, and verification without adding unrelated release or migration work.
