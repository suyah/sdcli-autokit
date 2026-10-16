# Automatic Migration Validation Report Design

Date: 2026-10-16
Status: Proposed
Scope: SQL Server-to-Oracle migrations executed by `sdcli-autokit`

## 1. Purpose

`sdcli-autokit` must produce a useful source-to-target comparison report as
part of the existing `validate` phase. The operator must not run separate SQL,
copy query results, or configure schema mappings that SQL Developer already
encoded in the generated migration artifacts.

The report is evidence for deciding whether one migration run is complete. It
must work in an offline customer environment, remain understandable to an
operator who does not maintain the scripts, and remain small enough for one
engineer to support.

Success means that this command:

```bash
./migrate.sh <migration> --phase validate --run <run_id>
```

collects read-only source and target metadata, derives the source-to-target
mapping, performs the existing data and target-health checks, writes machine-
readable evidence, creates one self-contained HTML report, and returns a
truthful exit code.

## 2. Design decisions

1. No new user configuration or report-specific command is required.
2. The existing BCP and SQL\*Loader status artifacts are the authoritative
   table and schema mapping source. They already record the exact source
   object, target object, and generated data-file path used by the run, so the
   report does not reparse executable shell commands.
3. Generated DDL is the authoritative expected-target inventory. This permits
   the report to distinguish a conversion omission from a deployment omission.
4. Tableless schemas are mapped from unique source-to-generated object identity
   overlap. Ambiguous mappings fail validation instead of being guessed.
5. The implementation does not query SQL Developer's private migration
   repository tables. Their schema is an internal implementation detail and
   can change between SQL Developer releases.
6. Existing BCP, SQL\*Loader, and final Oracle counts remain the authoritative
   row evidence. Validation does not recount the live SQL Server source after
   the migration window.
7. Source and target object inventories are collected through read-only
   `sqlcmd` and SQL\*Plus queries.
8. The report is one static HTML file with embedded CSS and JavaScript. It has
   no web server, database, CDN, or Internet dependency.
9. A Python standard-library renderer handles comparison and HTML escaping.
   No `pip` packages or runtime downloads are introduced.
10. The report is generated on both validation success and validation failure.
11. Existing TSV evidence remains available; the HTML report is a view over
    evidence, not the only record of the result.
12. This release supports exactly one migration pair: `sqlserver` as the
    source and `oracle` as the target. Configuration preflight rejects every
    other pair before SDCLI, BCP, SQL\*Loader, or database connectivity work.

## 3. Non-goals

- Supporting source platforms other than SQL Server or targets other than
  Oracle in this release. Additional RDBMS sources are planned future work and
  require source-specific connection, capture, extraction, row-evidence, and
  metadata adapters.
- Building a generic schema-comparison product.
- Adding a web service, dashboard server, report database, or cloud upload.
- Adding project-specific schema names, object names, endpoints, or exclusion
  rules to production code.
- Asking the operator to maintain duplicate schema mappings.
- Reading or modifying undocumented `MD_*` migration-repository tables.
- Automatically fixing missing objects, invalid conversions, compiler errors,
  or data differences.
- Automatically dropping, recreating, or recompiling objects during
  validation.
- Comparing every row value or calculating cross-platform row checksums in the
  first implementation.
- Showing complete side-by-side SQL Server and Oracle routine bodies in the
  first implementation. Routine presence, type, target validity, and compiler
  errors are included.
- Suppressing a mismatch through a configurable ignore list. Generic platform
  and SQL Developer artifacts are classified by built-in rules; remaining
  differences stay visible.

## 4. Operator contract

### 4.0 Supported migration pair

`sdcli-autokit` currently orchestrates SQL Server-to-Oracle migrations only.
Although `config.yaml` contains `defaults.source.type` and
`defaults.target.type`, those fields select the supported contract; they do
not activate interchangeable database adapters.

The required values are:

```yaml
defaults:
  source:
    type: sqlserver
  target:
    type: oracle
```

Startup configuration preflight normalizes the values to lowercase and then
requires the exact pair `sqlserver -> oracle`. A missing or unsupported value
stops the command before any SDCLI invocation, database connection attempt, or
migration artifact change. The error reports the configured pair and the one
supported pair without printing credentials.

Future source support is intentionally not represented by accepting additional
type names early. A new RDBMS source is supported only after it has an explicit
adapter for connection details, source capture, data offload, row evidence,
metadata extraction, artifact mapping, and validation, with end-to-end tests.

### 4.1 Normal workflow

The workflow remains:

```text
capture -> convert -> generate -> datamove -> offload -> deploy -> load
        -> postdeploy -> validate
```

The operator runs validation exactly as before:

```bash
./migrate.sh proda --phase validate --run "$RUN"
```

No report flag, schema list, mapping file, or manual extraction step is needed.
The source and target must still be reachable from the migration container
during validation because object metadata is collected at that time.

### 4.2 Result locations

Validation writes the following files under the selected run's `autokit/`
directory:

| File | Purpose |
| --- | --- |
| `schema_mapping.tsv` | Derived source schema to Oracle owner mapping and its evidence. |
| `source_object_inventory.tsv` | Read-only SQL Server user-object inventory. |
| `generated_target_inventory.tsv` | Expected Oracle objects parsed from SQL Developer's generated DDL. |
| `target_object_inventory.tsv` | Read-only Oracle object inventory and validity. |
| `object_comparison.tsv` | Per-object conversion/deployment status and reason. |
| `reconciliation.tsv` | Existing table-level exported/loaded/final row evidence. |
| `validation_summary.txt` | Existing machine-readable final result, extended with report counters. |
| `migration_report.html` | Self-contained human-readable validation report. |

The console prints the HTML path even when validation fails.

### 4.3 Reading the report

The report contains these sections:

1. **Run summary** — migration, run, source/target identities with credentials
   omitted, phase result, validation time, and overall status.
2. **Schema mapping** — each source schema, target owner, mapping method,
   evidence count, and `MAPPED` or `UNRESOLVED` status.
3. **Data reconciliation** — source object, target object, exported, loaded,
   rejected, discarded, and final target counts.
4. **Object inventory** — source, generated-target, and actual-target counts by
   mapped schema and logical category.
5. **Object exceptions** — conversion omissions, deployment omissions, extra,
   invalid, ambiguous, or unclassified objects with an actionable reason.
6. **Routine validation** — source routine presence, corresponding Oracle
   routine presence, Oracle status, and compiler errors.
7. **Supporting migration context** — SQL Server system objects, Oracle
   platform-generated objects, and SQL Developer conversion helpers that are
   visible for audit but are not user-object failures.
8. **Evidence health** — missing logs, failed commands, incomplete mappings,
   and report-generation diagnostics.

Tables are sortable and filterable using embedded JavaScript. The report opens
directly from the filesystem and makes no external requests.

### 4.4 Interpreting status

- `PASS` means all required evidence was collected, all mappings are resolved,
  all data reconciliation rows pass, required source user objects have a
  target counterpart, and the migrated target contains no invalid objects or
  compiler errors.
- `FAIL` means correctness was not established. The report is still written
  and identifies the failing evidence.
- `CONTEXT` identifies a known system, platform, or conversion artifact. It is
  visible but does not fail validation.

The HTML file may contain database object names and compiler messages. It must
be handled as customer migration evidence and must not contain passwords.

## 5. Data flow

```text
bcp_status.tsv ------------------+
                                 +--> mapping collector --> schema_mapping.tsv
sqlldr_status.tsv ---------------+

Generated Oracle DDL ----------------------------> generated_target_inventory.tsv

SQL Server sys.* --sqlcmd--> source_object_inventory.tsv --+
Generated target inventory ---------------------------------+--> comparison
Oracle ALL_* ------sqlplus--> target_object_inventory.tsv ---+      engine

bcp_status.tsv + sqlldr_status.tsv + Oracle row counts -------------+
                                                                    |
phase/log evidence -------------------------------------------------+
                                                                    v
                                                   object_comparison.tsv
                                                   validation_summary.txt
                                                   migration_report.html
```

Database collection remains in Bash because `migrate.sh` already owns
configuration, secret resolution, wallet setup, source connection parsing,
SQL\*Plus safety, redaction, and phase result handling. Generated-artifact
parsing, mapping, comparison, and rendering are delegated to one small Python
program so path normalization, identifier normalization, HTML escaping,
sorting, and report layout are testable without shell quoting complexity.

## 6. Automatic schema mapping

### 6.1 Exact table mapping

The primary mapping is derived from the existing status files written while
the SQL Developer `datamove` artifacts are executed:

1. Read source object and normalized generated data-file path from every
   successful `bcp_status.tsv` record.
2. Read Oracle owner, target table, and normalized generated data-file path
   from every successful `sqlldr_status.tsv` record.
3. Join the records by normalized generated data-file path.
4. Require each data file to map exactly one source object to exactly one target
   object.
5. Aggregate table mappings into source-schema to target-owner mappings.

A schema mapping is `MAPPED` by method `DATA_FILE` only when all of its table
pairs agree. One source schema mapping to multiple target owners, one target
owner mapping to multiple source schemas, a duplicate data file, or an
unpaired table is an error.

The mapper uses the full normalized data-file paths recorded during execution.
It does not use filename basenames as globally unique identifiers and does not
infer a mapping from a project-specific naming convention. Missing or failed
status records are already validation failures and cannot silently contribute
a mapping.

### 6.2 Tableless schema mapping

Some schemas contain only views, routines, synonyms, or triggers and therefore
have no data-move record. For each still-unmapped generated target owner:

1. Parse its generated DDL object names and logical categories.
2. Compare them with remaining source schemas after case folding identifiers.
3. Treat SQL Server procedures and functions and Oracle standalone procedures
   and functions as the common logical category `ROUTINES`.
4. Count distinct matching user-object identities by category and name.
5. Accept a mapping by method `OBJECT_IDENTITY` only when it is the unique
   one-to-one best match, contains at least one matched user object, and does
   not conflict with any exact table mapping.

Known conversion-only owners, including the generated Emulation owner, are
classified as supporting context and are not mapping candidates.

If identity overlap is empty, tied, or conflicts with an established mapping,
the schema remains `UNRESOLVED`. Validation continues far enough to write the
report, then returns nonzero. The tool never uses owner-name similarity as a
silent fallback.

### 6.3 Scope discovery

The source collector reads non-Microsoft-shipped objects outside SQL Server
system schemas. The target collector reads only owners represented by generated
per-schema `user.sql` directories. This prevents the target administration
account, migration repository, and unrelated schemas from entering the report.

Before live target collection, the generated DDL inventory records the expected
Oracle owner, object category, object type, object name, base object where
applicable, and originating generated file. Parsing is limited to the supported
SQL Developer file classes already accepted by the deployment inventory. An
unrecognized generated DDL form is incomplete evidence and fails validation;
it is not silently omitted.

The derived mapping artifact records:

```text
source_schema  target_schema  method           evidence_count  status      reason
dbo            PRODA          DATA_FILE         3               MAPPED
api            API_PRODA      OBJECT_IDENTITY   4               MAPPED
               EMULATION      CONVERSION_ONLY   1               CONTEXT
```

Identifiers in the actual TSV remain tab-separated and are safely normalized;
the spacing above is illustrative.

## 7. Metadata extraction

The attached standalone SQL Server and Oracle extraction scripts are reference
material, not files to execute unchanged. Their useful catalog coverage is
retained, while hardcoded schema lists and manual export assumptions are
removed.

The attached SQL Server row-count generator is not required by the normal
workflow. BCP, SQL\*Loader, and final Oracle counts already describe the exact
dataset exported and loaded by this run. The metadata extraction SQL remains
useful as a catalog-coverage reference, but the implementation issues its own
automated, parameterized, read-only queries.

### 7.1 SQL Server

`sqlcmd` runs read-only queries against the database already present in
`migrations[].source.conn`. The password is supplied through
`SQLCMDPASSWORD`, not a command-line argument or output file.

The inventory includes:

- schemas;
- tables and views;
- procedures and functions;
- triggers;
- primary, unique, foreign-key, check, and default constraints;
- indexes, uniqueness, and ordered key columns;
- identity columns;
- sequences and synonyms; and
- `is_ms_shipped` and base-table metadata needed for classification.

Object counts are calculated from detail rows after classification, rather than
being collected independently and risking disagreement with the detail section.

### 7.2 Oracle

The existing safe SQL\*Plus capture path queries `ALL_*` views for the derived
generated owners. It collects:

- tables and views;
- standalone procedures and functions;
- packages and package bodies as conversion context;
- triggers;
- constraints and their validation state;
- indexes and ordered key columns;
- identity columns;
- sequences and synonyms;
- object validity from `ALL_OBJECTS`; and
- compiler diagnostics from `ALL_ERRORS`.

Every generated owner is quoted as data after validation against the same
conservative identifier rules used by deployment. No credential or connect
string is written to an evidence TSV.

### 7.3 Row counts

The manual `COUNT_BIG(*)` generator is not part of the automated workflow.
For every migrated table, validation uses:

- the row count reported by the successful BCP export;
- the SQL\*Loader loaded, rejected, and discarded counts; and
- a final `COUNT(*)` against the mapped Oracle target table.

These counts describe the actual exported dataset. A later recount of a live
source could describe a different point in time and is therefore not treated
as migration evidence.

## 8. Comparison model

Comparison is three-way:

1. source to generated target, proving conversion coverage; and
2. generated target to actual target, proving deployment coverage.

The HTML may present this as a concise source-versus-target view, but every
exception retains the stage at which it arose. Comparison uses logical
cross-platform categories instead of assuming that SQL Server and Oracle
implement every object with the same physical type.

| Logical category | Matching rule |
| --- | --- |
| Tables | Derived schema mapping plus case-insensitive table name. |
| Views | Derived schema mapping plus case-insensitive view name. |
| Routines | Derived schema mapping plus routine name across procedure/function boundaries. |
| Triggers | Mapped owner, base table where available, and trigger name. |
| Identity columns | Mapped table plus column name. |
| Primary/unique constraints | Constraint kind, mapped table, and ordered columns; generated names are ignored. |
| Foreign keys | Mapped table/columns and referenced mapped table/columns; generated names are ignored. |
| Check/default constraints | Reported with source and target metadata; dialect-dependent expression differences are review findings. |
| Indexes | Mapped table, uniqueness, and ordered key columns; generated names are ignored. |
| Sequences/synonyms | Name comparison when a source counterpart exists; generated target helpers remain context. |
| Packages/package bodies | Oracle conversion context unless they are required to establish a routine counterpart. |

Each comparison row has one status:

- `MATCH`
- `MISSING_IN_CONVERSION`
- `MISSING_IN_TARGET`
- `EXTRA_IN_TARGET`
- `INVALID_IN_TARGET`
- `DIFFERENT`
- `UNRESOLVED_MAPPING`
- `CONTEXT`

Counts shown in the HTML summary are computed from these normalized detail
rows. This prevents a platform-generated sequence or constraint from creating
a count mismatch after it has already been classified as context.

## 9. Built-in artifact classification

Rules are generic to SQL Server, Oracle, or SQL Developer and do not name a
customer project. Initial context classifications include:

- SQL Server objects marked `is_ms_shipped`;
- SQL Server database-diagram support objects;
- Oracle-generated identity sequences;
- Oracle-generated names for implicit `NOT NULL` checks;
- SQL Developer's Emulation owner and `UTILS` synonyms;
- SQL Developer CLOB-to-BLOB helper routines; and
- generated Oracle package structures used to implement converted routines.

Classification is evidence-preserving: context rows remain in the report with
a reason. A broad name wildcard that could hide an application object is not
allowed. New classifications require a fixture and an explanation of why the
object is not a user migration result.

## 10. Validation and failure policy

The collector, comparator, and renderer are separate steps so one failure does
not erase evidence already collected.

Validation fails for:

- an unsupported `defaults.source.type` and `defaults.target.type` pair during
  configuration preflight, before validation or any earlier migration phase;
- missing or duplicate mapping records;
- unresolved or conflicting schema mappings;
- missing source or target inventory evidence;
- any existing run-log, SDCLI, BCP, SQL\*Loader, rejection, discard, or row
  reconciliation failure;
- a required source user object missing from the generated target plan;
- an expected generated target object missing from the actual target;
- a deployed target user object that is invalid;
- Oracle compiler errors in generated target owners; or
- failure to write the comparison TSV, summary, or HTML report.

Known context artifacts do not fail validation. Extra unclassified target
objects are reported as `EXTRA_IN_TARGET` and fail validation because the tool
cannot prove they are harmless.

When collection is partial, the report labels the missing section
`INCOMPLETE`; it never converts unavailable evidence into an empty successful
table. `validation_summary.txt` remains the machine-readable authority and is
written only after all issue counters, including report issues, are known.

## 11. HTML report requirements

The renderer accepts the SDCLI output directory, the run evidence directory,
and an output path. It does not connect to either database or read
`config.yaml`.

The generated document must:

- be valid UTF-8 HTML;
- embed all CSS and JavaScript;
- escape every database-derived value before insertion;
- perform no external network requests;
- provide summary counts and links to exception details;
- support sorting, filtering, and expand/collapse without external libraries;
- display large sections collapsed by default while leaving failures easy to
  find;
- state when evidence is incomplete;
- show generation time and run identity but no secret or full credential-bearing
  connection string; and
- remain useful with JavaScript disabled through ordinary HTML tables and
  headings.

The report generator writes to a temporary file and atomically renames it to
`migration_report.html` after successful rendering. A failed rerun does not
replace a previously complete report with a partial file.

## 12. Code boundaries

The implementation keeps the existing architecture and introduces only one
new runtime program:

- `sdcli-scripts/migrate.sh`
  - invoke metadata collection from `run_validate`;
  - safely run `sqlcmd` and the existing SQL\*Plus capture wrapper;
  - write raw source and actual-target inventory evidence;
  - invoke the report program with the SDCLI and evidence directories;
  - aggregate report issues into validation status; and
  - log the final report path.
- `sdcli-scripts/lib/generate_validation_report.py`
  - derive source-to-target table mappings from BCP and SQL\*Loader status
    evidence;
  - parse the supported generated DDL inventory;
  - normalize inventories;
  - resolve tableless mappings;
  - classify generic artifacts;
  - build comparison rows and counters;
  - render HTML; and
  - use only the Python standard library.
- `deployment/Dockerfile`
  - install the Oracle Linux `python3` package during the connected image
    build; no customer runtime download is performed.
- `release/build-offline.sh` and deployment copy logic
  - include the renderer with the existing tracked `sdcli-scripts` tree and
    verify that it is readable in the installed container.
- `README.md`
  - explain automatic report generation, result interpretation, report paths,
    sensitivity, and troubleshooting.

SQL query text may remain in focused shell functions where connection and
redaction helpers already exist. It is not duplicated in the renderer. The
initial implementation keeps those collector functions together in
`migrate.sh`; it does not add another sourced shell library.

## 13. Security and offline behavior

- Source passwords use `SQLCMDPASSWORD`; target passwords use the existing
  SQL\*Plus `/nolog` input path.
- Commands and evidence files never include resolved passwords.
- Existing log redaction remains active for collector output.
- Metadata queries are read-only and use no temporary database objects.
- Evidence files are written below the selected run directory only.
- The report performs no network calls when opened.
- Python and the renderer are present in the prebuilt image, so customer VMs
  require no repository or Internet access.
- The report may contain object names and error text and therefore inherits the
  customer's migration-evidence handling requirements.

## 14. Resume and repeat behavior

Running validation again with the same `--run` replaces snapshot-style
inventory, comparison, summary, and HTML artifacts atomically. It does not
append duplicate inventory rows. Historical phase attempts remain in the
existing append-only phase and migration logs.

The report records the time at which source and target metadata were collected.
Rerunning validation can therefore reflect metadata changes made after the
original migration. Row reconciliation continues to use the original offload
and load evidence for that run.

## 15. Test strategy

Automated tests use neutral fixtures and no real customer identifiers or
credentials.

### 15.1 Mapping tests

- one source/target status pair produces one `DATA_FILE` mapping;
- multiple tables in one schema agree on one owner;
- duplicate, unpaired, and conflicting data files fail;
- multiple source schemas map independently;
- a tableless schema maps through a unique routine or view identity;
- a tied or empty tableless match remains unresolved;
- Emulation is context and is not paired to an application schema; and
- filenames containing spaces and mixed-case identifiers are handled.

Generated-inventory tests cover every supported SQL Developer DDL file class,
multiple objects per file, comments, quoted identifiers, and an unknown form
that must fail rather than disappear.

### 15.2 Extraction tests

- SQL Server inventory queries exclude shipped system objects from user
  results while retaining them as context evidence;
- target queries are restricted to generated owners;
- `sqlcmd` receives its password through the environment;
- SQL\*Plus output parsing rejects incomplete records;
- no evidence or log contains configured test secrets; and
- query failures propagate to validation.

### 15.3 Comparison tests

- logical routine matching crosses procedure/function type differences;
- PK, unique, FK, and index comparison ignores generated names and respects
  ordered columns;
- conversion-missing, target-missing, extra, invalid, different, and context
  statuses are deterministic;
- generic artifact rules do not hide similarly named user objects; and
- summary counts are calculated from detail rows.

### 15.4 Renderer tests

- PASS, FAIL, and incomplete fixtures create a report;
- every expected section and exception link exists;
- HTML-special characters and routine error text are escaped;
- the report contains no external URL dependencies;
- a rendering failure leaves an existing complete report untouched; and
- output is deterministic apart from documented timestamps.

### 15.5 Workflow and container tests

- configuration preflight accepts `sqlserver -> oracle` case-insensitively and
  rejects missing or unsupported source/target types before invoking external
  tools;
- `validate` writes all evidence and returns zero for a complete passing
  fixture;
- every failure class returns nonzero while still producing the report;
- a repeated validation atomically refreshes snapshot artifacts;
- existing validation behavior and reconciliation tests continue to pass;
- the image contains working `python3`; and
- the offline bundle contains and installs the renderer without a download.

## 16. Acceptance criteria

The feature is complete when:

1. Configuration preflight clearly accepts only SQL Server-to-Oracle and
   rejects unsupported migration pairs before external work.
2. A normal full migration automatically creates `migration_report.html`.
3. The operator provides no schema mapping, schema list, manual export, or
   additional report command.
4. Every migrated table has one source-to-target mapping derived from generated
   artifacts.
5. Tableless schemas are either uniquely mapped or clearly fail as unresolved.
6. The report distinguishes objects omitted during conversion from objects
   generated but absent after deployment.
7. Row reconciliation, user-object comparison, target validity, and compiler
   errors appear in one report.
8. Generic conversion/platform artifacts remain visible without producing
   false user-object failures.
9. A validation failure still leaves a readable report and returns nonzero.
10. A PASS report agrees with `validation_summary.txt` and every row of
   `reconciliation.tsv`.
11. No generated evidence contains configured passwords.
12. The report works from a customer VM with no Internet access.
13. All shell, Python, workflow, and offline-bundle tests pass.

## 17. What users need to understand

- The report is generated by `validate`; there is no separate reporting setup.
- This release supports only `sqlserver -> oracle`; other RDBMS sources are
  planned but are not currently accepted by configuration preflight.
- Validation needs both databases reachable for metadata queries.
- Row counts refer to the actual exported and loaded run, not a later source
  recount.
- `FAIL` means the tool could not prove equivalence; the report explains why.
- `CONTEXT` entries are retained for audit and are not application migration
  failures.
- Rerunning validation refreshes the metadata snapshot for the same run.
- The report can contain sensitive schema and error information and should be
  stored and shared accordingly.

These points belong in the README's workflow, output-file, validation, and
troubleshooting sections during implementation.

## 18. What maintainers need to understand

- Mapping comes from generated artifacts, never project naming conventions.
- The `type` fields are a checked support contract, not a generic adapter
  registry. Do not add a type value until the whole source-specific workflow
  and its end-to-end tests exist.
- A heuristic mapping is accepted only when unique and one-to-one; ambiguity is
  a failure.
- SQL Developer private repository tables are not an integration interface.
- Detail records are the source of truth; count summaries are derived.
- Generated DDL is the expected-target contract; live target metadata proves
  whether that contract was deployed.
- Row evidence must continue to describe the original offload/load run.
- Artifact rules must be narrow, generic, evidence-preserving, and tested.
- The renderer is pure and has no database or YAML dependency.
- HTML escaping, atomic writes, password transport, and log redaction are
  correctness requirements, not optional polish.
- Production code and fixtures must not contain customer-specific schemas,
  endpoints, wallets, or credentials.
- This is a one-maintainer migration tool: one renderer, plain evidence files,
  existing phase orchestration, and no service framework.
