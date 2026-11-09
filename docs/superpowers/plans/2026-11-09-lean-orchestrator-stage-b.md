# Load Failure Propagation Implementation Plan

Execute inline without agents. Spec: [lean orchestrator](../specs/2026-11-06-lean-orchestrator-design.md).

## Scope

Keep generated SQL and shell scripts unchanged. Add native SQL*Plus error exits before connection in the load password wrapper, preserve native output, and return a failure for SQL*Plus command errors. Prove a failed SQL*Plus call reaches `run_load` and prevents later generated-shell work. Ordinary interactive SQL*Plus remains unchanged.

## Tasks

- [x] Extend the existing loader fixture with a SQL*Plus failure followed by a marker; verify the current wrapper fails the test.
- [x] Add SQL/OS error-exit directives before both direct-logon and stdin CONNECT paths. Capture and propagate SQL*Plus exit status, treating anchored native SP2 diagnostics as failure.
- [x] Verify missing includes, native SQL errors, and normal password/heredoc handling with focused tests and the installed client when reachable.
- [x] Inspect native helper generation/call order using existing authorised test artifacts; record any unresolved dependency separately rather than guessing a SQL rewrite.
- [x] Run related regressions, update the engineering changelog, self-review, and integrate through a remote PR; update local main.

No live business data or schema changes are required for error-exit verification. Test connection details and generated object names stay outside formal documents.

## Results

- Focused Linux load/deploy/password regressions passed. The load fixture proves nonzero SQL failure, a streamed vendor CONTINUE override, and zero-exit SP2 failure stop later shell work.
- Installed SQL*Plus client missing-file verification returned nonzero. The authorised test ADB read-only connection timed out; native connected SQL and complete LOB migration were not verified.
- Native generated artifacts place the helper definition in procedures output and call it during post-load. There is no separate setup file in the inspected output. Keep DBA installation of the required native helper explicit rather than moving all business procedures or extracting SQL with regex.
