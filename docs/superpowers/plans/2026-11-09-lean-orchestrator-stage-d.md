# Grouped Source DDL Implementation Plan

Execute inline without agents. Spec: [lean orchestrator](../specs/2026-11-06-lean-orchestrator-design.md).

- [x] Extend the existing export test with two synthetic schemas, native types, database-level Security, root SQL, a spaced filename, and a UTF-8 BOM. Verify exact file coverage/order and unchanged originals.
- [x] Add `--layout object|type` (default object). Aggregate complete native files by path into `by-type`, retaining the original `sql/` tree. Preserve SQL batches without parsing SQL text; fail visibly for unsupported layout/encoding.
- [x] Display redacted native SqlPackage diagnostics and record layout in the manifest.
- [x] Document both layouts and their reading/LLM-context purpose; no dependency-order deployment guarantee.
- [x] Run focused Linux and local export regressions, self-review, update the changelog, merge through a remote PR, and synchronise local main.

No database connection is required for grouping tests. No vendor binary or new dependency is added to the image.

## Results and final review

- Grouped export tests passed locally and on Linux: native category names, schema order, Security/root SQL, spaced filenames, exact coverage, retained originals/batches, UTF-8 BOM removal, UTF-16 conversion, and unsupported-layout failure.
- The existing image already provides system iconv; no image package change was needed.
- All 35 runtime shell regression scripts passed on Linux. Final review added focused regressions for unavailable totals, quoted Oracle identifiers in raw runner TSV, and renderer failures that leave older reports. The report suite now has 11 Python cases; affected tests were rerun after these fixes.
- Native diagnostics remain visible and redacted. No new image/release archive was built and no live database migration was performed.
- Final review also scopes AL32UTF8 to read-only Oracle report subprocesses, keeping diagnostic encoding independent of data-loading character sets. The collector test verifies the environment passed to SQL*Plus.
- Connected Oracle CSV and complete LOB migration remain unverified because the authorised test ADB connection timed out. The required native LOB helper is an explicit DBA preparation step rather than a generated-SQL rewrite.
