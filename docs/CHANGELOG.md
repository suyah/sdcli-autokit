# Engineering change log

This file is for maintainers. It records release differences but is not copied
into the customer offline bundle.

## Unreleased

### Fixed

- Isolated SQL Developer repository aliases, repository endpoint selection,
  wallets, locks, and initialization evidence by named migration. A named
  migration now uses its own target endpoint and derived repository aliases
  instead of a shared global alias.

### Changed

- Repository initialization is `./migrate.sh <migration> --init` when multiple
  migrations are configured. The single-migration no-name form remains
  compatible.
- `migration_repository.conn` is now the default only for no-name datatype
  mapping inspection; named migration workflows use `migrations[].target.conn`.

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
