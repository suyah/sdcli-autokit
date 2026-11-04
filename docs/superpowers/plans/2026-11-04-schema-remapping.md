# Schema remapping implementation plan

**Goal:** Configure optional one-to-one schema remapping without manual XML edits.

**Architecture:** A small Bash library owns native XML preparation and mapped
conversion. Existing orchestration owns locks, wallets, status and model lookup.

**Tech stack:** Bash, existing yq XML parser, jq, SDCLI 26.2.

**Spec:** ../specs/2026-11-04-schema-remapping-design.md

## Constraints and review focus

- No new Python, SQL/DDL regex or project-specific values in runtime code.
- Never send both input and output to idmap; require both action markers.
- A single schema must work as well as repeated XML schema elements.
- Preserve child identifiers/IDs; reject unknown schemas and owner collisions.
- Keep unmapped execution unchanged and use the current run's captured model.

## Tasks

- [x] Add necessary regression tests for XML preservation, mapping errors,
  native command composition and vendor false-success output; observe failure.
- [x] Implement lib/schema_mapping.sh and hook config validation/convert;
  handle comma-separated action markers in run_sdcli.
- [x] Update bundle/install allow-lists, README and Unreleased changelog;
  verify focused tests and all tracked release tests, review diff.
- [ ] Push feature branch, create/merge remote PR, update local main.
- [ ] Separate release-notes PR for 1.3.0; merge and update local main.
- [ ] Build verified release bundle, inspect checksum/tree/provenance; tag and
  provide exact upgrade/resume commands and evidence limits.

## Verification record

Both new tests failed before implementation and pass afterward. All 36
previously tracked shell test entry points pass, including the report's Python
unit tests. Both new tests and three related model/deploy/diagnostic tests
also pass in a disposable Linux/amd64 container with network disabled.
Independent read-only review found no critical/important issue.

An initial broad local glob also picked up obsolete ignored tests:
capture_project_name_test, full_connection_setup_test, load_sqlplus_failure_test,
load_userid_quote_test, sdcli_console_filter_test and sqldeveloper_preferences_test
failed against interfaces/expectations removed in earlier releases. These are
not tracked or part of the release suite; no files were deleted or rewritten.
This release uses the tracked suite defined by release.sh.

No new live database migration was run. Native remapping behavior is based on
the operator's successful remote idmap,convert/generate output; local tests
verify configuration, XML preservation, command composition and error handling.
