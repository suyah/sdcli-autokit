# Actionable Migration Validation Evidence Design

Date: 2026-10-17
Status: Proposed revision to the automatic validation report
Scope: SQL Server-to-Oracle validation evidence and offline reports

## Purpose

The final migration report must help a DBA decide whether the migrated
database is ready for application testing. It must distinguish successful data
movement from conversion and deployment work that remains. It must not present
expected cross-database DDL differences as migration failures.

The report therefore shows:

1. table data reconciliation;
2. every table-column datatype conversion from source through generated DDL to
   the live Oracle target;
3. invalid Oracle objects and their compiler diagnostics; and
4. metadata objects that are not paired in conversion or are generated but not
   present in the live target.

No configuration, manual schema mapping, repository-table query, network
service, or customer-specific rule is introduced.

## Evidence model

The existing normalized inventory TSV contract remains unchanged. A column is
represented as an `ObjectRecord` with category `COLUMNS`, its table as
`parent_schema` and `parent_name`, and one attribute row for each property.
The record stores at least:

| Property | SQL Server source | Generated Oracle DDL | Live Oracle target |
| --- | --- | --- | --- |
| table owner/name | `sys.schemas` and `sys.tables` | generated `CREATE TABLE` | `ALL_TAB_COLUMNS` |
| column name and ordinal | `sys.columns` | generated column definition | `ALL_TAB_COLUMNS.COLUMN_ID` |
| native datatype | `sys.types` plus length, precision, scale and collation semantics | datatype expression as generated | `DATA_TYPE` plus length, precision, scale and character semantics |
| nullability | `sys.columns.is_nullable` | generated `NULL`/`NOT NULL` clause | `NULLABLE` |

The source and target collectors use read-only database catalog queries. The
Python renderer parses only the generated SQL files selected by the existing
deployment include graph. `MD_*` SQL Developer repository tables remain out of
scope: they are internal, do not prove what was deployed, and are less useful
than the source catalog, generated deliverable, and target catalog.

The report records the original native type expressions. It does not attempt to
claim that, for example, `varchar` and `VARCHAR2` are textually equal. This
preserves the actual SQL Developer conversion for DBA review without inventing
a cross-platform datatype-equivalence engine.

## Datatype conversion report

`datatype_conversion.tsv` is a deterministic evidence artifact with one row
per source column. Its columns are:

```text
source_schema  source_table  source_column  source_ordinal  source_definition
generated_schema  generated_table  generated_column  generated_ordinal  generated_definition
target_schema  target_table  target_column  target_ordinal  target_definition
status  detail
```

`source_definition`, `generated_definition`, and `target_definition` are
human-readable native database definitions, including datatype parameters and
nullability. Examples include `varchar(50) NOT NULL`, `VARCHAR2(50 CHAR) NOT
NULL`, and `NUMBER(12,2) NULL`.

The status values are:

| Status | Meaning | Validation effect |
| --- | --- | --- |
| `DEPLOYED` | The source column has a generated column and matching live target column. | Informational. |
| `UNPAIRED_IN_CONVERSION` | No exact mapped generated column was found. It can be an omission or a converted rename. | Fails validation as unverified metadata. |
| `MISSING_IN_TARGET` | A generated column is absent from a successfully collected target inventory. | Fails validation. |
| `TARGET_DEFINITION_MISMATCH` | Generated and live Oracle datatype/nullability definitions differ. | Fails validation. |
| `UNRESOLVED_MAPPING` | The parent table schema mapping is unavailable. | Fails validation. |
| `INCOMPLETE` | Generated or target evidence was unavailable or malformed. | Makes validation incomplete. |

The source-to-generated type difference is never itself a failure. It is the
conversion result the DBA needs to review. The generated-to-target difference
is a failure because the deployed target does not match the generated Oracle
DDL.

Generated and source column names are matched only after the existing safe
case-folding identifier normalization. The implementation never assumes a
customer naming convention. A renamed column is reported as
`UNPAIRED_IN_CONVERSION`, not silently guessed as a match.

## Metadata coverage and omission policy

The generated-DDL inventory and target catalog continue to cover tables, views,
routines, triggers, indexes, primary/unique/foreign/check/default constraints,
identity columns, sequences, synonyms, packages, and package bodies where the
generated DDL exposes them.

The report has a **Metadata requiring review** section with only actionable
rows:

| Status | Meaning |
| --- | --- |
| `UNPAIRED_IN_CONVERSION` | A source user object has no exact mapped generated counterpart. This is conversion coverage that requires review; it may be a transformed name. |
| `MISSING_IN_TARGET` | An expected generated object has no live target counterpart after a successful target inventory collection. |
| `INVALID_IN_TARGET` | A live target object is invalid; compiler diagnostic is included. |
| `EXTRA_IN_TARGET` | A live user object is not in the generated plan. |

Routine bodies and cross-platform table/index implementation differences are
not shown in this section merely because they differ. The detailed normalized
`object_comparison.tsv` remains available for engineering investigation.

Generated conversion-support objects, such as an Emulation owner, remain
visible as context. If a generated support object is absent from the target, it
is reported as a deployment review item, not hidden. No report rule names a
customer schema or object.

If `target_object_inventory.tsv` is missing or malformed, generated-to-target
comparisons are skipped. The report records one `INCOMPLETE` diagnostic instead
of inventing `MISSING_IN_TARGET` rows from an empty target set.

## Report layout and status

The HTML and text reports use the same evidence and status rules. The text
report uses pipe-delimited tables so it remains readable in `less` regardless
of terminal width or CJK character width.

The ordered report sections are:

1. **Validation summary** — one row per check: data reconciliation, target
   object validity (with invalid-object and compiler-error counts), source
   inventory, target inventory, datatype conversion, and metadata deployment.
2. **Data reconciliation** — the existing row evidence.
3. **Datatype conversions** — all source columns, with source, generated, and
   target definitions and status.
4. **Invalid target objects** — owner, name, object type, status, and first
   compiler diagnostic. Full diagnostics stay in `target_object_inventory.tsv`.
5. **Metadata requiring review** — only the actionable omission, deployment,
   invalid, and extra-object rows above.
6. **Schema mapping and supporting context** — retained for audit.
7. **Evidence health** — unavailable or malformed evidence.

`DIFFERENT` rows do not appear in the main report and do not determine its
status. They remain in `object_comparison.tsv` for a maintainer who needs to
inspect structural detail.

`PASS` requires complete evidence, passing data reconciliation, no invalid
target objects or compiler errors, no conversion/deployment omissions, and no
generated-to-target datatype mismatch. `FAIL` means a concrete validation
finding exists. `INCOMPLETE` takes precedence whenever required evidence is
unavailable or malformed.

## Code boundaries

`migrate.sh` retains all connectivity, secret transport, redaction, and
read-only catalog collection. It gains focused source and target column
collector rows only; query text is not duplicated elsewhere.

`generate_validation_report.py` retains generated-DDL parsing, mapping,
comparison, evidence generation, and rendering. It gains small pure helpers
for parsing generated column definitions, constructing display definitions,
building datatype conversion rows, filtering actionable metadata rows, and
rendering pipe-delimited text tables. It does not connect to either database or
read configuration.

The change introduces no runtime package, new command, or new configuration.

## Failure handling and security

All collector output remains marker-prefixed TSV and is atomically replaced
only after structural validation. Malformed output remains incomplete evidence
and is logged through existing password redaction. The target collector never
turns missing evidence into an empty target inventory.

Datatype evidence contains object names and type definitions but no data values
or credentials. It is stored under the selected run's `autokit/` directory
alongside the existing evidence artifacts.

## Test strategy

Neutral fixture tests will prove:

1. SQL Server and Oracle collectors emit columns with types, length/precision/
   scale, nullability, and ordinal without exposing secrets.
2. Generated table DDL parsing handles common Oracle type expressions,
   parentheses, character semantics, numeric precision/scale, and nullable
   clauses.
3. Datatype rows distinguish expected source-to-generated conversion from a
   generated-to-target mismatch, missing generated column, missing target
   column, unresolved mapping, and missing target evidence.
4. A missing target inventory produces `INCOMPLETE` and no
   `MISSING_IN_TARGET` false positives.
5. Routine/table/index `DIFFERENT` rows remain in `object_comparison.tsv` but
   are absent from the HTML and text report summaries and do not affect report
   status.
6. Invalid target objects and their diagnostics appear as aligned text and
   HTML report rows.
7. Existing report, shell, offline package, syntax, and secret-redaction tests
   continue to pass.

## Acceptance criteria

1. One `validate` command produces the new evidence and both offline reports.
2. Every source table column appears once in `datatype_conversion.tsv`.
3. Each datatype row shows source and generated native definitions; it also
   shows the live target definition when target inventory is available.
4. The final report shows all datatype conversions, not only mismatches.
5. The final report identifies invalid target metadata and concrete conversion
   or deployment omissions across supported object categories.
6. It never labels an object missing from target when target inventory is
   unavailable.
7. No project-specific identifiers, credentials, repository `MD_*` tables, or
   customer-side dependencies are introduced.
8. All tests pass using neutral fixtures.
