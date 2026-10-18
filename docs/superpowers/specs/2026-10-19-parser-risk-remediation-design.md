# Parser and Validation Evidence Remediation Design

Date: 2026-10-19
Status: Approved direction; implementation proceeds one group at a time
Scope: SQL Server-to-Oracle migration orchestration, validation, reporting, and secret-safe logging

## Purpose

The autokit must remain a small, maintainable migration tool. It should not try
to become a SQL parser, infer Oracle semantics from generated text, or claim
validation results that its evidence cannot prove.

This design replaces broad regular-expression interpretation with a simple
rule:

- parse only narrow protocols whose grammar the autokit owns or explicitly
  bounds;
- obtain database facts from structured catalog or repository queries;
- treat human-readable third-party output as diagnostics, not the primary
  success contract;
- report unavailable evidence as `INCOMPLETE` or `NOT_EVALUATED`, never as an
  invented failure or success.

This document supersedes the generated-DDL and datatype-report approach in
`2026-10-17-actionable-validation-evidence-design.md`. Datatype mappings are a
separate operator command and do not appear in the migration validation report.

## What is safe to parse

Regex, AWK, and shell matching remain appropriate for bounded records:

| Input | Decision |
| --- | --- |
| Autokit-owned marker TSV such as `SDCLI_INVENTORY` | Keep; validate field count and required fields strictly. |
| Autokit-owned wrapper summaries such as `[SQLLDR-SUMMARY]` | Keep; exact anchored grammar only. |
| SQL Developer `master.sql` include lines | Keep as a bounded SQL*Plus include protocol; reject unsupported active include forms. |
| SQL Developer `role.sql` | Keep the narrow, comment-aware, one-statement-per-line splitter added by PR #2. It is not a general SQL parser. |
| SQL*Loader control-file `INFILE` and `INTO TABLE` records | Keep only after enforcing exactly one supported record of each kind. |
| SQL Developer generated Oracle DDL semantics | Remove. Regex cannot safely determine tables, columns, constraints, routines, packages, defaults, or datatype structure. |
| XML preferences | Do not mutate arbitrary XML with line regex. Manage only an autokit-owned template or a known generated structure. |
| Human-readable SDCLI/BCP/SQL*Loader messages | Use for supplemental diagnostics only; exit codes and structured artifacts determine completion. |

## Findings and remediation groups

### P0 — Credential disclosure and masking

#### Current risk

`mask_conn_details_value` splits `-connDetails` on commas and structural
delimiters. A valid password containing a comma can be split before masking.
`filter_sqlplus_deploy_output` masks only one non-whitespace token after
`IDENTIFIED BY`, so quoted passwords containing spaces or punctuation can be
partially logged. Structural password parsing will always have another edge
case involving `@`, comma, slash, semicolon, whitespace, or quotes.

#### Required solution

1. Register every resolved secret value before rendering commands or logging
   subprocess output.
2. Replace exact secret values in memory, independent of connection-string or
   SQL syntax.
3. Make `mask_sensitive` redact each raw argument before shell quoting; remove
   structural `connDetails` masking.
4. Make SQL*Plus output pass through the same literal redactor and add
   `SET VERIFY OFF` to generated wrappers.
5. Keep unredacted temporary command output mode `0600` through `mktemp` and
   delete it on every exit path.

#### Completion evidence

Tests use passwords containing comma, `@`, slash, space, semicolon, single
quote, and double quote. None may appear in console output, run logs, command
logs, summaries, or deploy output. The real command must still receive the
exact original value.

### P1 — Validation report correctness

#### Current risk

`generate_validation_report.py` removes comments and parses generated Oracle
DDL with regular expressions. This is unsafe for quoted text, nested
expressions, multiline DDL, PL/SQL, conditional compilation, and SQL Developer
format changes. It produced false `DIFFERENT`, `MISSING_IN_CONVERSION`, and
`EXTRA_IN_TARGET` rows for a migration whose table rows loaded correctly. DDL
from SQL Server and Oracle is expected to differ, so structural text equality
is not a meaningful migration check.

#### Required solution

The report must use only direct evidence:

1. data movement and row reconciliation from BCP, SQL*Loader, and Oracle row
   counts;
2. deployment attempts and failures from `deploy_manifest.tsv`;
3. live Oracle validity and compiler diagnostics from catalog queries;
4. source and target inventory counts from structured catalog queries;
5. object-level missing-conversion findings only when a supported structured
   SQL Developer repository query provides a source-to-converted mapping.

If structured conversion mapping is unavailable for the installed SQL
Developer repository version, the report states `NOT_EVALUATED`; it does not
parse generated SQL as a fallback.

The main report removes `DIFFERENT`. It also removes inferred
`MISSING_IN_CONVERSION` and `EXTRA_IN_TARGET` rows that are based only on DDL
text or name equality. `MISSING_IN_TARGET` is shown only when structured
expected-object evidence exists and target inventory collection succeeded.

#### Final report sections

1. Run identity and overall status.
2. Validation summary with explicit counts.
3. Table data reconciliation.
4. Deployment script outcomes, including failed and not-run scripts.
5. Invalid Oracle objects and compiler diagnostics with owner, object name,
   type, status, error line/position, and message.
6. Metadata coverage supported by structured evidence; otherwise a clear
   `NOT_EVALUATED` explanation.
7. Source and target inventory counts by object category.
8. Evidence health.

The text report uses aligned columns when the terminal width permits and a
stable pipe-delimited fallback for long values. HTML and text are rendered from
the same report model.

### P1 — Datatype mapping inspection command

Datatype mappings are operator reference data, not migration validation. The
report must not infer per-column mappings from generated DDL.

Required commands:

```bash
./migrate.sh --show-datatype-mapping
./migrate.sh proda --show-datatype-mapping
```

Without a migration name, the command displays the installed repository's
default mapping rules. With a migration name, it displays the effective rules
associated with that migration project. The implementation reads structured
repository data from `MIGR_DATATYPE_TRANSFORM_MAP` and
`MIGR_DATATYPE_TRANSFORM_RULE` only after a preflight confirms the tables and
required columns exist. Repository-version incompatibility produces a clear
unsupported-version error rather than guessed SQL.

Output is deterministic TSV suitable for `column -t -s $'\t'` and includes no
credentials. The command does not modify mapping rules.

### P1 — Generated execution-plan reliability

#### Current risk

`schema_post_files` decides whether an unreferenced `foreignkeys.sql` contains
work by matching one line of DDL. Normal multiline `ALTER TABLE ... ADD
CONSTRAINT` statements can be missed. Similar semantic inspection must not be
added for tables, views, routines, or datatypes.

#### Required solution

- If `foreignkeys.sql` exists and is not already included by `master.sql`, run
  it exactly once. An empty SQL file is harmless; skipping real DDL is not.
- Keep `master_include_paths` as a bounded include parser, but reject active
  `@`/`@@` forms it cannot represent instead of silently omitting them.
- Treat `passworddefinition.sql` as a narrow control protocol: accept only
  `ACCEPT <identifier> ... HIDE`, reject duplicate or malformed identifiers,
  and generate one `DEFINE` per validated prompt.
- For each SQL*Loader control file, require exactly one supported `INFILE` and
  one supported `INTO TABLE`. Reject ambiguity rather than choosing the first
  regex match.
- Set `LC_ALL=C` for deterministic generated-file ordering and text protocol
  parsing.

### P1 — Third-party command completion

#### Current risk

`run_sdcli` supplements exit codes with generic `Error`, `Fatal`, Oracle error,
and conversion-location regexes. These are useful warnings but cannot define
success for every SDCLI release or action. Human-readable BCP and SQL*Loader
messages have the same limitation.

#### Required solution

Each action has a small postcondition based on artifacts it owns:

| Action | Required postcondition |
| --- | --- |
| `capture` | exact success marker plus captured-model lookup succeeds |
| `convert` | exact success marker plus converted-model lookup succeeds |
| `generate` | supported generated inventory exists and passes execution-plan validation |
| `datamove` | expected BCP scripts and SQL*Loader control files exist |
| `offload` | every expected BCP invocation has a structured success status and data file |
| `deploy` / `postdeploy` / `cleanup` | manifest records every attempted script and its result |
| `load` | every expected control file has one structured SQL*Loader status record |
| `validate` | all required evidence sections report `PASS`, `FAIL`, `INCOMPLETE`, or `NOT_EVALUATED` explicitly |

Generic diagnostic regexes remain supplemental and must never convert missing
artifacts into success.

### P2 — Preferences and maintainability

`configure_sqldeveloper_file_output_option` edits arbitrary XML with AWK and
assumes formatting and attribute order. Replace this with an autokit-owned
preferences template installed when no SQL Developer preference file exists.
For an existing unknown file, either verify its known structure before a
minimal update or stop with an actionable message; do not perform a broad XML
rewrite.

The project remains Bash-first for orchestration. A full Python rewrite is not
part of this remediation. Python remains the report renderer and pure evidence
model only; it must not connect to databases or parse generated SQL semantics.
As focused Bash components stabilize, move them into small files under
`sdcli-scripts/lib/` rather than extending `migrate.sh` indefinitely.

## Generic behavior requirements

- No customer database, schema, object, host, wallet, or run name is hard-coded.
- Source-specific validation is explicitly limited to SQL Server in this
  release. Other source RDBMS adapters remain documented future work.
- A new SQL Developer output or repository version fails with an actionable
  unsupported-format message, not silent omission.
- Missing evidence never becomes an empty successful inventory.
- Every generated output is written atomically where practical.
- Every implementation group has focused regression tests and a separate
  review gate before the next group begins.

## Delivery order

1. P0 credential redaction.
2. P1 validation evidence/report redesign.
3. P1 datatype mapping inspection command.
4. P1 execution-plan parser hardening.
5. P1 per-action postconditions.
6. P2 preferences/template cleanup and focused file extraction.

Each group is delivered as an independently reviewable commit or feature PR.
The next group begins only after the current group's tests and review pass.
