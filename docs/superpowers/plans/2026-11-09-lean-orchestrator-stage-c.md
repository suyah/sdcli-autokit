# Lean Validation Implementation Plan

Execute inline without agents. Spec: [lean orchestrator](../specs/2026-11-06-lean-orchestrator-design.md).

- [x] Replace report tests with small synthetic phase, manifest, reconciliation, mapping, and native CSV fixtures. Cover fail/incomplete precedence, latest retry, current validate exclusion, malformed/missing diagnostics, quoted multiline messages, and matching HTML/text/summary.
- [x] Remove full inventory collection, duplicate object counts, log scoring, and their unused state. Add one owner-scoped native CSV diagnostics query.
- [x] Reduce the existing Python module to artifact reading and rendering. Produce one status with exits 0/2/1; no SQL parsing or new dependency.
- [x] Refresh only current validation artifacts before collection; pass collection failures to the report and preserve native diagnostics.
- [x] Replace obsolete collector tests, update the run-log allow-list and README, and remove unused fixtures after checking references.
- [x] Run focused Linux tests, inspect a sample text report, update the changelog, self-review, and merge through a remote PR; update local main.

The CSV query emits a native CSV header record even for an empty result so a successfully empty query is distinguishable from failed collection. Test connection details and real data do not belong in formal documents.

## Results and review

- Nine focused Python report cases and the Linux validation/diagnostics/reconciliation/row-count/collection/type-preflight/load regressions passed.
- Sample terminal output was inspected using synthetic names/data. Long compiler messages use indented object blocks; phase names align; no inventory/metadata-coverage/internal-scoring sections remain.
- Current query artifacts are refreshed before collection. Missing CSV and a confirmed failure yield FAIL with an unavailable-check explanation, never zero invalid objects.
- Native header-only output is implemented with a header record in the query rather than relying on client headings for an empty result. Connected Oracle CSV verification remains unavailable because the authorised test ADB timed out; no complete live migration is claimed.
- Retired inventory fixtures and the tests dedicated to them were removed. Historical customer artifacts are preserved; only the log collector retains their known names for old-run inspection.
