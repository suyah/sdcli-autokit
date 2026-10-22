# Engineering change log

This file is for maintainers. It records release differences but is not copied
into the customer offline bundle.

## Unreleased

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
