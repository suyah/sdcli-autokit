# Lean Orchestrator Stage A Implementation Plan

> Execute inline using superpowers:executing-plans. The user explicitly requested no agents.

**Goal:** Remove duplicated orchestration while retaining execution-critical guards.

**Architecture:** Native tool outcomes drive phase status. Actual script attempts drive the manifest. Model lookup and transfer coverage stay at their execution boundary.

**Tech stack:** Bash and the existing standard-library Python report renderer.

**Spec:** [Design](../specs/2026-11-06-lean-orchestrator-design.md) and [removal inventory](../specs/2026-11-06-lean-orchestrator-code-removal.md).

## Constraints and review focus

- SQL Developer 26.2; SQL Server to Oracle; no new dependency or project-specific data.
- Preserve password/profile/schema-map behaviour and generated originals.
- Failed include discovery must reach deploy/postdeploy even when invoked conditionally.
- Use the latest phase state after a failed/interrupted rerun.
- Preserve exact loader control-path coverage, duplicate detection, and input-file checks.
- Remove completion sentinels without invalidating the existing report.
- Keep model lookup failure from being recorded as phase success.

## Task 1: scheduling and retry protection

- [x] Extend existing resume and deployment tests with latest failed/started reruns and a malformed include invoked through a conditional phase call. Observe failures.
- [x] Make `phase_succeeded(phase)` use the latest state. Check generated include lists before iterating them in `check_deploy_inputs`, `schema_post_files`, deploy, and postdeploy.
- [x] Run the resume, deploy orchestration, and generated-layout tests.

## Task 2: remove duplicate postconditions and plan records

- [x] Keep necessary model-list fixtures/assertions in a focused `tests/sdcli_model_lookup_test.sh`; keep generate/datamove native-result and actual SQL failure coverage. Remove the old framework test after migration.
- [x] Move capture/convert lookup to the action success paths; remove redundant globals and generic verifier functions.
- [x] Consolidate exact expected-control coverage and file existence into `run_load`; retain BCP malformed-status checks in `run_offload`. Adapt transfer tests to exercise these real entrypoints.
- [x] Remove plan inventory functions, monolithic discovery, and completion sentinel writes. Preserve actual manifest outcomes and retry skipping.
- [x] Make report deployment completion use the latest deploy/postdeploy phase states and ignore old plan/sentinel records. Add a regression proving one failed script counts once.
- [x] Rename the generated-layout test and update explicit tracking entries.
- [x] Run relevant model, transfer, deployment, report, schema-map, and secret-handling tests.

## Task 3: output and review

- [x] Add one assertion that an unknown loader warning is visible verbatim and recorded once. Remove duplicate output prefixes.
- [x] Update the engineering changelog and document any remaining Stage B/C limitations in this plan.
- [x] Self-review the complete diff, run focused regressions and syntax/whitespace checks, and record results. No release image rebuild is required for Stage A acceptance.

## Progress and rulings

- Implementation approved by the user's request to review and then begin implementation.
- Work uses the existing checkout on `refactor/lean-orchestrator-stage-a`, preserving the pending English design documents. No agents are used.
- Stage B load SQL*Plus error handling and Stage C report replacement remain separate deliverables. Stage A must not claim these defects are repaired.

## Verification record

- All 24 focused shell regression scripts passed in the existing Linux test container; the report wrapper ran 19 Python unit cases successfully.
- Five additional profile/repository/preferences/lock regression scripts passed in the same container.
- Syntax and whitespace checks passed. No image build or live database migration was performed for this removal stage.
- Self-review retained exact model selection, actual transfer coverage, source-file preservation, and explicit cleanup semantics. The new model/layout tests replace obsolete framework/fallback tests in the tracking allow-list.
- Ruling: compare physical loader control paths because wrappers record physical paths and a symlink must not cause a false mismatch.
- Ruling: use Linux Bash for authoritative runtime regression evidence. The macOS Bash 3.2 shell can continue after bare assertions when functions toggle errexit; new critical output assertions explicitly exit on failure.
