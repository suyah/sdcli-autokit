# Engineering change log

This file is for maintainers. It records release differences but is not copied
into the customer offline bundle.

## Unreleased

### Added

- Add `export-source-schema.sh --layout type` to group a database's native
  SqlPackage files by category and schema order. Preserve the original tree,
  source-path comments, and complete SQL batches without parsing DDL.

### Changed

- Add a post-migration operator checklist with per-phase log locations,
  validation evidence, focused terminal commands, and support-bundle guidance.
- Document the safe distinction between a new migration run with new mapped
  target owners and recovery of an existing run. Make explicit that repository
  models are retained and target schema/data cleanup remains a DBA action.
- Add a generated-identity pre-deployment checklist for repeat migrations,
  including roles, compatibility schemas, partial deploy recovery, and the
  post-deploy load/postdeploy/validate sequence.
- Replace full source/target inventories and validation log scoring with direct
  Oracle invalid-object/compiler-error CSV diagnostics, phase/script outcomes,
  and row reconciliation. Produce matching HTML, terminal, and summary results;
  a confirmed failure takes precedence over an unavailable check.
- Remove obsolete report sections and inventory fixtures. Collect the new
  diagnostic CSV in run-log bundles while preserving existing data exclusions.
- Simplify phase orchestration by removing duplicate postcondition dispatch and
  plan-only deployment manifest records. Keep exact model lookup and transfer
  coverage at their execution boundaries; report completion from phase status.
- Show native BCP and SQL*Loader warnings and diagnostics verbatim on the
  console, with one copy in the raw run log.

### Fixed

- Keep unavailable row totals distinct from zero and identify older reports as
  potentially stale after a renderer failure.
- Preserve quoted Oracle identifiers when reading runner TSV artifacts while
  retaining native CSV quoting for compiler diagnostics.
- Select UTF-8 explicitly for read-only Oracle report queries, independently
  of any character set selected for data loading.

- Fail load on SQL*Plus SQL/OS failures and native command errors. Enforce the
  load error policy before CONNECT and in streamed WHENEVER directives, keeping
  generated files unchanged. Preserve native diagnostics and prevent subsequent
  generated-shell steps after a failed SQL*Plus call.
- Use the latest phase state for retry protection, so a failed or interrupted
  rerun cannot inherit an earlier successful result.
- Propagate generated include-list discovery failures to deployment callers.
- Preserve exact loader control-file coverage, including physical paths when
  accessing a run through a symbolic link.

## 1.4.0 - 2026-11-05

### Added

- Add `collect-run-logs.sh`, which creates a checksummed, allow-listed support
  bundle for one migration run. It includes selected run logs and status files
  while excluding configuration, wallets, generated DDL, exported data, loader
  controls, and rejected-row payloads.
- Add `export-source-schema.sh` for SQL Server source DDL collection. It uses
  SqlPackage Extract with `ExtractAllTableData=False`, so routines and schema
  objects can be reviewed without exporting table data.

### Fixed

- Export SQL Server local objects with embedded dots using metadata-resolved
  `queryout`. Real customer BCP testing rejected bracketed table-mode `out` but
  successfully exported the same table through `SELECT * ... queryout` (89 rows).
  Query the source catalog lazily once per offload attempt, preserve generated
  scripts byte-for-byte, and log/persist runtime adjustments. This replaces the
  unsuccessful bracket-only hotfix, without an image rebuild or new dependency.
- Correct the source-catalog `sqlcmd` options used by that hotfix: `sqlcmd`
  rejects `-h` together with `-y 0`. The catalog reader now retains unlimited
  column width, explicitly accepts its named heading/separator, and continues
  to reject malformed data rows.
- Replace password-definition grammar validation with a narrow identifier-only
  contract. Autokit now extracts active `ACCEPT <identifier>` prefixes outside
  comments and treats the remaining SQL Developer prompt syntax as opaque.
  Generated files remain immutable; invalid identifiers and unterminated block
  comments still fail, while repeated variables are safely de-duplicated.

### Changed

- Offline deployment now requires the customer to stage Microsoft SqlPackage
  Linux x64 170.4.83.3 beside the existing RPM artifacts and acknowledge its
  separate license. Autokit verifies its SHA-256 and installs it to persistent
  tool storage; the release image and bundle do not redistribute the binary.

### Compatibility

- Supports Oracle SQL Developer 26.2, SQL Server sources, and Oracle targets
  only. Existing migration configuration and run data remain unchanged.

## 1.3.0 - 2026-11-04

### Added

- Optional per-migration `schema_mapping` for one-to-one SQL Server schema to
  Oracle owner names. Autokit exports native identifier XML, updates schema
  attributes with existing yq/jq, and runs idmap,convert in the same process.
  No manual XML editing, DDL parsing or new runtime dependency is required.

### Fixed

- Treat object-level conversion diagnostics as warnings after successful SDCLI
  completion, while retaining failures for tool errors and Oracle error codes.
- Judge generate/datamove by the SDCLI result and remove whole-directory SQL
  layout rejection. SQL*Plus executes nested includes through their parent
  scripts during deployment, including schema post/rebuild.sql.
- Hide repeated SQL Developer banners and known Java startup deprecation
  messages in the terminal; retain the full redacted output in migrate.log.
- Check every action completion marker for combined SDCLI commands and reject
  vendor error output even when a later action reports success.
- Resolve the native `Converted:<run model name>` display name from SQL
  Developer 26.2 while keeping model lookup exact and rejecting ambiguity.

### Compatibility

- Supports SQL Developer 26.2, SQL Server sources and Oracle targets only.
- Existing configuration remains valid. Optional schema_mapping applies during
  convert; existing 1.2.x profiles, repositories and run artifacts are retained
  on upgrade. Runs already remapped/generated with native SDCLI can resume at
  datamove without repeating capture or conversion.

## 1.2.1 - 2026-10-22

### Fixed

- Corrected SQL Developer 26.2 parenthesized model-list parsing and pinned full
  workflows to unique numeric captured and converted model indexes instead of
  mutable `latest` selection.
- Replaced generated BCP shell-token parsing with wrapper-owned structured
  execution evidence and control-file coverage checks.
- Replaced generated SQL*Loader command grep with structural leaf-script
  discovery and exact control-file status coverage.

## 1.2.0 - 2026-10-22

### Added

- Bundled pinned Oracle SQLcl 26.2.2 with its FUTC license and notices for
  DBA connectivity and diagnostics; migration orchestration remains on SQL
  Developer CLI 26.2.

### Fixed

- Isolated SQL Developer 26.2 saved connections, DefaultRepository and encryption
  state per migration with IDE_USER_DIR, preventing stale shared repository
  discovery before init. Fresh profiles require successful initialization.
- Scoped inherited Java wallet settings to the selected project and keyed
  repository locks by endpoint/user rather than saved connection alias.
- Verified repository installation completion and independent saved-connection
  reopening before marking a profile ready, including retries after failed init.
- Isolated SQL Developer repository aliases, repository endpoint selection,
  wallets, locks, and initialization evidence by named migration. A named
  migration now uses its own target endpoint and derived repository aliases
  instead of a shared global alias.

### Changed

- Upgrades from shared preferences require named init and connection setup for
  each project; existing models and data artifacts are retained. Deployment
  uses disposable startup-check profiles and preserves old state for rollback.
- Added strace to the image's diagnostic tools.
- Repository initialization is `./migrate.sh <migration> --init` when multiple
  migrations are configured. The single-migration no-name form remains
  compatible.
- `migration_repository.conn` is now the default only for no-name datatype
  mapping inspection; named migration workflows use `migrations[].target.conn`.
- Release preflight now rejects a package when `Unreleased` still contains
  entries, requiring a separate release-notes PR before a version is built.

## 1.1.0 - 2026-10-19

### Added

- SQL Server-to-Oracle migration validation reports with HTML and text output.
- Release bundle tree output and source-commit provenance.

### Changed

- Customer configuration and SQL Developer preferences persist under
  `/u01/data/sdcli-autokit` across container recreation.

### Fixed

- Improved deployment, postdeploy continuation, password handling, repository
  locking, and migration failure detection.
- Corrected Docker release-image metadata parsing so valid provenance labels
  are preserved when producing the offline bundle.

### Compatibility

- Supports Oracle SQL Developer 26.2 only.
- Supports SQL Server sources and Oracle targets only.

## 1.0.0

- Initial offline container distribution release.
