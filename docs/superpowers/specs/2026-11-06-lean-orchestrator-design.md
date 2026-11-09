# Lean Autokit Orchestrator Design

Date: 2026-11-06

Status: accepted for staged implementation; Stage A is implemented on its feature branch
Baseline: `v1.4.0` / `db94c41ff3aa548aaf4e5c060eafa9f9ea06ff7f`

## Intent

Autokit is a single-maintainer SQL Developer CLI migration orchestrator. It invokes the required tools, passes configuration, preserves diagnostics, and records outcomes. It is not a cross-database SQL converter, DDL analyser, or generic migration-validation platform.

The agreed direction is to reduce Autokit-specific inference, expose SDCLI and execution-tool warnings/errors directly, remove redundant checks first, then correct real failures in independently reviewed stages. SqlPackage's native object classification remains authoritative. An optional grouped-by-type reading layout will be added alongside the existing per-object DDL layout.

This design also proposes deleting complete source/target object inventories and their generic report model. The report needs only Oracle invalid-object and compiler-error diagnostics. Removing the inventory eliminates unhelpful sections and the broken wide-TSV protocol instead of repairing it.

Detailed removals, callers, and test disposition are in the companion [code-removal inventory](2026-11-06-lean-orchestrator-code-removal.md). This design supersedes historical requirements for complete inventory collection, log scoring, and generic phase postconditions where they conflict.

## Failure scenarios and boundaries

The design addresses the following observed failure patterns. Project identifiers, run identifiers, object names, and dataset statistics are intentionally excluded. Detailed run evidence belongs in local diagnostic records rather than this design.

| Scenario | Observation | Required response |
| --- | --- | --- |
| Postdeployment failure | Row counts reconciled, but a postdeploy script failed and Oracle objects had compilation errors. | Retain the real failure and show it clearly. |
| Load false success | A CLOB-to-BLOB helper call failed during load but load was marked successful. | Fix failure propagation and establish original generated dependency order. |
| Warning misclassification | Informational `SQL*Loader-292` messages became validation failures. | Stop error-code scoring; keep native log text. |
| Diagnostic collection failure | A wide TSV parse error discarded the entire target inventory. | Replace inventories with a small native CSV diagnostic query. |
| Conflicting report results | `No records`, `INCOMPLETE`, `FAIL`, and issue totals contradicted each other. | Produce one report result from one decision. |

Matching source export, SQL*Loader, and target row counts is row-count evidence only. It does not prove BLOB content or business routine correctness. This work does not add value-by-value validation.

## Options considered

| Option | Decision |
| --- | --- |
| Trust process exit codes only | Rejected: SDCLI 26.2 has demonstrated zero-exit failures. |
| Expand generic postconditions, log categories, and SQL semantic analysis | Rejected: ongoing format/exception maintenance is unsuitable for one maintainer. |
| Thin orchestration, narrow proven 26.2 adapters, and direct report queries | Adopted. |

### Retained capabilities

- Existing commands, configuration, run directories, and phase order; support remains SQL Developer 26.2 and SQL Server to Oracle.
- Per-project profiles, repository selection, wallets, locks, password delivery, and literal secret redaction.
- Exact numeric model selection and native idmap XML schema mapping.
- BCP special-name support, SQL*Loader wrappers, actual invocation checks, setup-only deploy, explicit role cleanup, and continue-across-file postdeploy behaviour.
- Row-count reconciliation, direct Oracle diagnostics, HTML/text reports, run-log collection, and `--show-datatype-mapping`.

### Non-goals

- No generated-DDL semantic parsing or inferred missing/extra/different objects.
- No automatic SQL Developer conversion repair, automatic schema DROP/reuse, SQL dependency graph, or source-database adapter framework.
- No new strict/ignore/skip-validation switch family, consistency window, content validation, or commercial audit feature.

## Execution and diagnostic contract

`run_sdcli` retains exit-code processing, the 26.2 native completion marker, and the proven zero-exit fatal guard. Object conversion location diagnostics do not make a completed SDCLI action fail. `run_offload` and `run_load` each retain exactly one actual execution-coverage check; checks that detect missing, duplicate, or missing-data-file execution must remain.

SQL*Plus load uses native error-exit settings. Postdeploy is the explicit exception: it continues independent SQL files and returns an aggregate failure. Unknown warnings remain verbatim and are not migration issues merely because they contain `ORA-` or `SQL*Loader-`.

The generic `verify_phase_postcondition` framework is removed. Capture/convert do their model lookup directly after their own successful action; model selection is retained. Other phases write `phase_status.tsv` directly from the matching `run_*` result. No new warning-state machine is introduced.

Child-process output is redacted and written to the run log once. The console hides only fixed banners, startup deprecation notices, and high-frequency progress lines; all other text is native output. Summary functions do not write the same raw text again with wrappers such as `SQL*Loader output:`. Validate no longer scores historical `migrate.log`, SDCLI `error.txt`, or loader logs; these artifacts remain available for human inspection and log collection.

Execution facts are not changed by report generation. A report-renderer failure is an incomplete check, not an additional business defect. Existing stop-on-failed-phase behaviour remains; users can explicitly request validation after a failure.

Stage A also closes two orchestration gaps found during code review. Phase retry decisions use the latest phase state, including a later failed or interrupted rerun. Generated include discovery must return its failure to the calling phase: a failed process substitution must never be interpreted as an empty successful plan. Materialise and check only the lists required for scheduling; do not add another generic verifier.

## Stage B: load failure propagation and native dependency order

The load-specific path in `lib/sqlplus` will set `WHENEVER OSERROR EXIT FAILURE` and `WHENEVER SQLERROR EXIT FAILURE` before connection. The wrapper must also handle bounded native SQL*Plus `SP2` errors because `WHENEVER SQLERROR` does not cover all SQL*Plus command errors. Its nonzero result must be proven to reach `run_load`; do not assume `bash -e` is sufficient. A nonzero SQL*Loader or SQL*Plus result fails load and retains its native diagnostics. This affects only the Autokit load wrapper, not interactive DBA SQL*Plus.

The observed load failure shows that a helper was absent when called and present after postdeploy, but does not establish which original file creates it or SDCLI's intended order. Before changing order, inspect the original generated `master.sql`, `procedures.sql`, `oracle_loader.sh`, and referenced files for the same run. If a distinct native setup exists, call it in native order. If the helper is mixed with business procedures, define and approve a concrete minimal correction first. Do not regex-extract a procedure, hard-code names, or move all routines before load.

Stage B may fix error propagation independently, but it must not claim a complete LOB migration is verified until a small authorised test proves helper creation, invocation, and outcome. Existing false-success history is not rewritten or replayed automatically; affected BLOB data remains a DBA check.

Native artifact inspection confirmed that the generated post-load stream sets `WHENEVER SQLERROR CONTINUE`. The load adapter must enforce its failure policy on these streamed SQL*Plus directives as well as before CONNECT, without modifying generated files. The helper definition is in the native procedures output, which can also contain business routines; installing that mixed output automatically before load is outside this change. Operators must install/review the required native helper before LOB loads. A missing helper now fails load visibly. Nested scripts can set their own SQL*Plus policy, so explicit native error headings must still produce a failed call even when SQL*Plus returns zero.

## Stage C: lean validation and report

Remove complete source/target inventories, wide TSV generation, log scoring, and duplicate count-only object queries. Retain `run_target_sql_capture`, target row counts, and reconciliation. `sqlcmd` and the lazy BCP metadata query remain execution support for SQL Server special table names, not report inventory.

Add one direct Oracle diagnostics query, restricted to target owners generated by the current migration (including the conversion-support owner), returning:

```text
owner,object_name,object_type,status,error_line,error_position,error_message
```

It reads `ALL_OBJECTS` and `ALL_ERRORS`, reports invalid objects and associated `attribute='ERROR'` compiler errors, and does not reinterpret other states. Output is `autokit/target_object_diagnostics.csv` using SQL*Plus `SET MARKUP CSV ON QUOTE ON`; the existing Python standard-library `csv` reader consumes it. Quotes, commas, tabs, and multiline messages must survive. A valid header-only query means zero findings; missing/malformed/failed collection means incomplete, never zero objects. Validate CSV quoting and encoding once with local SQL*Plus 23.26 before release.

The existing Python renderer continues to read only artifacts: `phase_status.tsv`, real `deploy_manifest.tsv`, `reconciliation.tsv`, `idmap/schema_mapping.tsv`, and the new diagnostics CSV. It does not connect to databases, read YAML, or parse SQL. It creates HTML, text, and summary output from one result:

| Result | Meaning |
| --- | --- |
| `FAIL` | Current failed phase/script, row mismatch, rejected/discarded rows, invalid object, or compiler error. This wins over unavailable checks. |
| `INCOMPLETE` | No confirmed failure, but a required result is unavailable. |
| `PASS` | Listed checks completed with no such findings; it does not claim business correctness, value-by-value validation, or full metadata coverage. |

Renderer exits are `0` PASS, `2` report produced with FAIL/INCOMPLETE, `1` renderer failure. `run_validate` propagates the result and does not add another `report_issues` count. Latest phase records supersede old failed attempts; the current validate `started` record and old validate failures do not decide their own new report.

`deploy_manifest.tsv` records real script attempts/outcomes only. Remove plan/control/covered/excluded rows and `__phase_complete__`; phase completion belongs in `phase_status.tsv`.

The lean report contains only:

1. **Migration Summary** — migration/run, generation time, result, and latest phase outcomes.
2. **Schema Mapping** — only when present.
3. **Table Data Transfer** — table/row counts, rejected/discarded values, and per-table row reconciliation.
4. **Scripts Requiring Attention** — real failed/incomplete scripts and a compact successful count.
5. **Objects Requiring Repair** — name, type, source line/column, and raw compiler text.
6. **Checks Not Completed** — only when applicable, with the real reason.

Remove Metadata Coverage, Inventory Counts, Evidence Health, and internal check-ID tables. A diagnostics collection failure says `Unable to retrieve Oracle object diagnostics`, never `No records`. Long messages use object blocks; short output uses aligned columns. A single scope note states that there is no value-by-value, business-function, or missing-object comparison. Datatype mapping is not included in the report.

## Stage D: grouped source DDL for reading

```bash
./export-source-schema.sh <migration> [--output <absolute-directory>] [--layout object|type]
```

Default `object` remains unchanged. `type` performs the current one-pass `ExtractTarget=SchemaObjectType` export, retains original `sql/` output, and writes `by-type/*.sql`. Files are grouped only by native paths (`<schema>/<type>/<object>.sql`), ordered by schema then native filename under `LC_ALL=C`.

Database-level `Security/<file>.sql` becomes `Security.sql`, not a business schema. Root SQL becomes `Database.sql`; only existing categories are created; native category names are retained. Each original file is appended once with a source-relative-path comment, preserved `GO`/`SET` content, appropriate boundary newline, and correct BOM/encoding treatment. Unknown layouts fail the type aggregation explicitly while preserving raw SqlPackage output. No SQL text is scanned or rewritten.

Native table files may include related indexes/constraints, so `Tables.sql` retains them. Grouped output is intended for review/LLM context, not a dependency-ordered deployment script. Existing customer-provided SqlPackage licensing, directories, and credential handling remain unchanged. The manifest records the selected layout and grouped directory; redacted native SqlPackage errors are displayed.

## Staged delivery, test environment, and rollback

| Stage | Deliverable | Boundary |
| --- | --- | --- |
| A | Remove duplicated phase verification, manifest plan/sentinels, misleading monolithic fallback, and duplicate raw-output wrapping. | Can merge independently; does not claim migration correctness is fixed. |
| B | Correct load SQL*Plus error return; investigate native helper order; consolidate narrow proven SDCLI adapters. | No complete-LOB success claim without test evidence. |
| C | Atomically replace complete inventories/log scoring/generic model with direct CSV diagnostics and lean report. | Follows Stage A manifest change; produces a fix-release candidate. |
| D | Add `--layout type` source DDL aggregation. | Independent feature; may ship with the next candidate. |

Integration tests use an authorised test host, a dedicated SQL Server container, and a dedicated Oracle test database or Autonomous Database. Host aliases, endpoint details, credentials, wallet locations, and actual test schema names stay in local, untracked test configuration. Tests use small synthetic datasets and isolated test schemas. Confirm both database endpoints are available before any cross-engine test, and obtain authorisation before creating additional test schemas.

Acceptance is intentionally small: preserve model/profile/password and actual invocation tests in A; prove SQL*Plus failure stops a later statement and reaches load in B; prove quoted multiline CSV, header-only vs failed query, result precedence, and retry handling in C; prove two schemas/two types/Security/space-containing filenames aggregate once in D. Do not create exhaustive password or datatype matrices.

Each stage uses its own feature branch and remote PR. After remote merge, update local `main` before the next stage. Every behaviour-change PR updates `docs/CHANGELOG.md` under Unreleased. This design work does not build a release, create a PR, or modify live systems.

Rollback uses the previous verified Git/image version while preserving data volumes and generated originals. It never auto-rolls back executed DDL, recaptures/reconverts, or initialises/deletes repositories. Historical reports retain their meaning; new validation does not parse historical inventories. Log collection may retain legacy artifact names solely for historical inspection.

## References

- [SQL*Plus native CSV/QUOTE settings](https://docs.oracle.com/en/database/oracle/oracle-database/26/sqpug/SET-system-variable-summary.html)
- [SqlPackage Extract native layouts](https://learn.microsoft.com/en-us/sql/tools/sqlpackage/sqlpackage-extract?view=sql-server-ver17)
- [Existing source-schema export design](2026-11-05-sqlpackage-source-schema-export-design.md)
