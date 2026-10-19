# Engineering change log

This file is for maintainers. It records release differences but is not copied
into the customer offline bundle.

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

### Compatibility

- Supports Oracle SQL Developer 26.2 only.
- Supports SQL Server sources and Oracle targets only.

## 1.0.0

- Initial offline container distribution release.
