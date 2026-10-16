# Technical Debt: Multi-Source RDBMS Adapter Architecture

Date: 2026-10-16
Status: Deferred until a second source RDBMS is approved
Current support: SQL Server source to Oracle target

## Why this is deferred

`sdcli-autokit` currently implements one tested migration path. Its Bash
orchestration contains SQL Server-specific connection syntax, BCP execution,
TLS handling, data-movement evidence, and metadata queries. Accepting another
value in `defaults.source.type` would not create real support and could produce
misleading or unsafe results.

The current release therefore validates and accepts only:

```text
sqlserver -> oracle
```

Additional source types remain rejected until their complete migration and
validation workflows exist.

## Trigger for addressing this debt

Address this document when a specific second source RDBMS is selected for a
real migration. Do not build a generic adapter framework only because another
database might be supported later.

Before implementation, collect the selected database's requirements for:

- SQL Developer capture support and connection syntax;
- connectivity and TLS preflight;
- offline data extraction tooling;
- exported-row and load reconciliation evidence;
- schema and identifier behavior;
- source catalog metadata queries; and
- end-to-end test infrastructure.

## Recommended direction

At that point, prefer Python for shared orchestration and explicit source
adapters. Keep `migrate.sh` as a small compatibility launcher so existing
operator commands do not change abruptly. Proven executable helpers such as
the BCP and SQL*Loader wrappers can remain in shell and be invoked by the
Python orchestrator.

Each source adapter should own only these source-specific operations:

1. Validate source configuration.
2. Check connectivity.
3. Build SDCLI source connection details.
4. Supply capture options.
5. Run offline data extraction.
6. Produce normalized row evidence.
7. Produce normalized source-object inventory evidence.

Shared orchestration should continue to own run directories, phase state,
repository locking, redaction, summary files, target deployment, loading, and
validation-report generation.

## Migration approach

Do not rewrite the working tool in one step. Use an incremental transition:

1. Define the adapter contract from the actual second source requirements.
2. Move configuration validation and source dispatch into Python.
3. Wrap the existing SQL Server behavior as the first adapter without changing
   its operator-visible behavior.
4. Add the second adapter with neutral fixtures and a real integration test.
5. Move other shared orchestration from Bash only when that reduces duplicated
   source branches or fixes a demonstrated maintenance problem.

## Constraints

- No customer-specific schemas, endpoints, credentials, or naming rules.
- No claimed source support without capture, data movement, and validation.
- No new customer-side downloads; runtime components must be in the prebuilt
  offline image.
- Preserve the current CLI unless a separately approved design changes it.
- Keep source adapters small; this tool does not need a plugin marketplace or
  dynamic third-party extension system.

## Completion criteria

This debt is complete when:

- SQL Server and the selected second source use the same documented adapter
  contract;
- both have automated unit and end-to-end migration tests;
- unsupported source types still fail during preflight;
- the report consumes the same normalized evidence regardless of source;
- existing SQL Server-to-Oracle commands and results remain compatible; and
- the offline image contains everything required to run both source paths.
