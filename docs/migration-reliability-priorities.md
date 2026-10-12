# SQL Server to Oracle Migration Reliability Priorities

Date: 2026-10-12

## Purpose

This review defines the smallest set of changes needed to trust `sdcli-autokit` for a SQL Server to Oracle migration. It deliberately excludes commercial-product features, broad platform abstractions, and conveniences that do not affect migration correctness.

The tool is maintained by one person and normally runs one migration workflow at a time. The design should therefore prefer fail-fast checks, plain text evidence files, and simple locking over services, databases, queues, dashboards, or plugin systems.

## Decision rule

A change is **mandatory** when its absence can cause any of the following:

- the tool reports success after a failed or incomplete migration;
- schema objects or table data are silently omitted, duplicated, or applied in the wrong order;
- one workflow operates on another workflow's captured model;
- credentials remain in generated files after interruption;
- customer-specific values are shipped as defaults;
- the offline runtime executes stale or unverified migration code;
- a defect cannot be caught by the repository's repeatable tests.

A change is **optional** only when the current single-operator scope remains correct without it and a specific future requirement would activate it. There is no separate “nice to have” category.

## Current readiness decision

The workflow is **not ready to be declared migration-successful** until all P0 items below are implemented and the full workflow is rerun. A process exit code of zero is not currently sufficient evidence because validation can find errors and still return success.

P1 items are also mandatory before handing the bundle to another customer or relying on it for a second project. They address portability and reproducibility rather than the data path itself.

## Mandatory changes

### P0 — blockers for a trustworthy migration result

| ID | Change | Why it is mandatory | Minimum completion evidence |
|---|---|---|---|
| M1 | Make every phase and final validation return an honest exit status | `run_validate` reports counts but does not fail. `run_sdcli` can ignore an arbitrary `Error:` when a success marker also appears. Shell option restoration in the offload error path can terminate the caller unexpectedly. | Tests prove that nonzero tool exits, fatal output, validation findings, BCP failures, SQL\*Loader failures, and post-deploy compile errors all make the workflow nonzero. |
| M2 | Use one deterministic, complete DDL deployment plan | The current fallback executes all SQL files alphabetically, while the normal path skips packages and procedures and may omit other generated object types. This can produce tables and data without a complete application schema. | A deployment inventory accounts for every generated SQL file exactly once as executed, intentionally excluded, or referenced by an executed master script. Unknown or duplicate files fail before execution. |
| M3 | Reconcile every table from SQL Server export through Oracle target | Successful BCP and SQL\*Loader commands do not prove that every table and row arrived. Rejected, discarded, missing, duplicated, or pre-existing rows can otherwise pass unnoticed. | One TSV report contains every expected table with exported, loaded, rejected, discarded, and final Oracle row counts. Success requires no missing table, zero rejected/discarded rows, and equal exported/loaded/target counts. |
| M4 | Require a consistent source window for offload | BCP exports tables separately. If the source application continues writing, individually correct table copies may still represent different points in time and be relationally inconsistent. | The full workflow requires an explicit operator acknowledgement that source writes are quiesced before offload. The acknowledgement and timestamp are recorded in the run evidence. |
| M5 | Prevent `latest` from selecting another captured model | SQL Developer accepts `latest` for later phases. Two workflows using the same repository can cause convert or generate to select the wrong model. | A repository-scoped workflow lock prevents overlapping repository operations. Lock ownership is visible and is released on normal exit and signals. |
| M6 | Make temporary credential handling interruption-safe | Deployment temporarily writes the migrated schema password into `passworddefinition.sql`. An interruption can leave the secret on disk. | Cleanup registered before modification restores the original file on success, failure, and handled signals. Tests interrupt the deploy path and confirm restoration and log redaction. |
| M7 | Make resumption preserve evidence and reject unsafe re-execution | Resuming a phase currently overwrites `migration_summary.csv`; rerunning deploy or load against a partially populated target can also duplicate work or hide prior failures. | Phase history is append-only. Each phase has a recorded start/end/status. Re-execution of a completed mutating phase requires an explicit override; an incomplete phase is clearly reported for operator cleanup or retry. |

### P1 — blockers for reusable customer delivery

| ID | Change | Why it is mandatory | Minimum completion evidence |
|---|---|---|---|
| M8 | Remove project-specific configuration from the shipped scripts | The tracked config contains a specific ADB service, source address, database, and usernames. Those values are unsafe defaults and can make another project target the wrong systems. | The bundle contains only `config.example.yaml` with placeholders. A real `config.yaml` is local/untracked and is never overwritten by installation or upgrade. |
| M9 | Validate the supported configuration before connecting | The implementation is specifically SQL Server to Oracle but does not reject other declared types. Names become paths and connection names, and the source port/connection structure is weakly validated. | Preflight accepts only `sqlserver` to `oracle`, safe migration/run/connection names, a valid port, nonempty resolved secrets, writable paths, and complete wallet files when mTLS is configured. Errors name the exact config key. |
| M10 | Execute all generated offload/load scripts and verify their coverage | Offload currently selects only the first `MicrosoftSQLServer_data.sh`. Projects with multiple generated script trees can silently omit tables. | All unique generated offload and loader scripts run in sorted order. Expected table commands, status records, and data/control files have one-to-one coverage. |
| M11 | Keep container runtime, scripts, vendor tools, and preferences consistent | Existing containers can keep stale scripts, mounts, network settings, vendor versions, or SQL Developer preferences. `start.sh` and `stop.sh` are Podman-only even when Docker/Rancher is selected. | Re-running `run.sh` refreshes program files atomically while preserving config/data, verifies the existing container definition and installed artifact versions, applies preferences to the active SQL Developer version, and all lifecycle scripts use the configured engine. |
| M12 | Track and repair the test suite, then use it as the release gate | The useful tests are ignored by `.gitignore`; four currently fail. Unversioned tests cannot protect a one-maintainer project from regressions. | Tests are tracked, stale expectations are corrected, the real offload shell-state defect is fixed, and all tests plus `bash -n` and `git diff --check` pass. Mandatory failure cases from M1–M11 are covered. |
| M13 | Verify the offline inputs that the project itself distributes or downloads | The image build downloads fixed yq and jTDS versions without checking their content. Local package installation also needs to reject damaged or conflicting required RPMs instead of continuing. | Pinned SHA-256 values protect yq and jTDS. Required RPM identities, architecture, uniqueness, payload digest, and mutually compatible version families are checked before installation. The release tarball checksum still verifies after transfer. |

## Optional changes, activated only by a real requirement

These are intentionally not part of the mandatory implementation.

| ID | Condition that would require it | Change |
|---|---|---|
| O1 | More than one workflow must use the same migration repository concurrently | Replace the single repository lock and `latest` with a proven way to capture and pass SQL Developer's immutable internal model identifier. Do not add distributed locking while the tool remains single-operator. |
| O2 | A project requires SQL Server named instances, IPv6 literals, or another connection shape | Replace `host:port:database` with separate structured `host`, `port`, and `database` keys. The present format is adequate for IPv4/DNS plus a TCP port. |
| O3 | Measured migration windows cannot be met by serial export/load | Add bounded parallelism separately to offload and load, with per-table status isolation. Do not parallelize repository capture/convert calls; SQL Developer repository behavior is the current bottleneck and is outside this script's control. |
| O4 | The customer requires cryptographic provenance for customer-downloaded Oracle/Microsoft RPMs | Require a customer-maintained checksum manifest or import the vendors' signing keys and enforce signatures. The base mandatory check detects damage and mismatched packages but cannot establish customer chain of custody. |
| O5 | Repeated tests prove transient network failures are common and a phase is safe to repeat | Add a small, bounded retry only to the proven idempotent phase. Do not automatically retry deploy, offload, or load because repetition can duplicate or partially apply work. |

## Explicit non-goals

The following should not be added for this project:

- a web UI, API service, scheduler, queue, database-backed state store, or monitoring platform;
- provider-specific Azure, AWS, GCP, or OCI upload code;
- multi-tenant support, role management, approval workflows, or centralized secrets management;
- automatic target cleanup or rollback after a partial migration;
- a generic source/target plugin architecture;
- automatic conversion-rule rewriting for arbitrary SQL Developer diagnostics.

The operator should make destructive cleanup decisions. The tool should preserve evidence, stop at the first unsafe condition, and make the required manual action clear.

## Recommended implementation order

1. M1, M6, and M7: establish truthful execution, cleanup, and durable evidence.
2. M2 and M10: make generated DDL and data scripts complete and deterministic.
3. M3 and M4: add data reconciliation and the source-consistency checkpoint.
4. M5: protect SQL Developer's `latest` model selection.
5. M8 and M9: remove project values and strengthen preflight validation.
6. M11 and M13: make the delivered offline runtime reproducible.
7. M12 throughout the work: add each regression test with its corresponding change, then run the complete acceptance workflow.

No current full-run result should be treated as final acceptance until steps 1–4 are complete and the migration is rerun from capture through validation.
