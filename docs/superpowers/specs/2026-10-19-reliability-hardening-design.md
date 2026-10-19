# Reliability Hardening Design

## Purpose

Close the five approved reliability gaps without changing the tool into a
platform: truthful SQL Developer command outcomes, non-persistent deployment
password handling, fail-closed generated-SQL execution, safe offline script
updates, and a neutral customer configuration handoff.

This applies to the supported SQL Server-to-Oracle workflow only. It preserves
the Bash-first architecture: Bash remains responsible for command execution,
database access, generated-file protocol checks, and deployment. The existing
standard-library Python report renderer remains a TSV-to-report component only.

## Scope

### Included

1. Require an exact SDCLI `<action> completed successfully` marker for every
   `sdcli migration -actions=...` invocation that exits zero. Reject Oracle,
   PL/SQL, SQL*Plus, or fatal diagnostics even if the process returns zero.
   The sole exception is `init` with exactly the existing-repository
   `ORA-01920` diagnostic and its exact completion marker.
2. Do not overwrite the generated run's `passworddefinition.sql`. For a
   password-prompting deployment, create a private temporary DEFINE file and
   have the SQL*Plus wrapper source that file before the generated schema SQL.
   Clean temporary secrets on normal exit, failure, and handled INT/TERM
   signals.
3. Support only the tested per-schema SQL Developer layout: a schema directory
   containing `user.sql` and `master.sql`. Reject monolithic `gen/*.sql` output
   when no such hierarchy exists. Reject nested generated SQL files rather than
   assume an included group script executes them.
4. Ship `config.example.yaml`, not a populated `config.yaml`. On first
   container setup, create customer `config.yaml` from the example only when it
   does not already exist. On every later `run.sh` invocation, update program
   files while preserving customer `config.yaml`, run data, and logs.
5. Record the script bundle version in the container after a successful program
   sync, so operator diagnostics show the code currently installed.

### Explicitly excluded

- Source-quiescence acknowledgement or cross-table snapshot guarantees.
- New validation object-mapping semantics; `metadata_coverage` remains an
  explicit `NOT_EVALUATED` limitation.
- Strict migration/run-name/path validation for deliberately malformed manual
  input; it remains deferred for the normal single-operator workflow.
- A generic recursive SQL or PL/SQL parser, support for alternate untested SQL
  Developer layouts, a Python rewrite, or Python database access.
- Checksums or signature-policy changes for vendor RPMs and build downloads.

## Design

### SDCLI outcome contract

`run_sdcli` is the single boundary for SDCLI calls. A command succeeds only
when all of the following are true:

- its process exit code is zero;
- its output contains the exact action-specific completion marker; and
- its output has no `Error`, `Fatal`, `ORA-`, `PLS-`, `SP2-`, or `LRM-`
  diagnostic, except the narrowly-defined idempotent `init` case.

This applies to `driver`, `mkconn`, `init`, model listing, capture, convert,
generate, and datamove. The completion marker is not an exception to error
handling. This removes the current false-success path in which `mkconn` may
return zero after an Oracle diagnostic with no leading `Error:` line.

### Deployment password handling

Generated SQL is never rewritten. When generated `passworddefinition.sql`
contains supported hidden `ACCEPT` prompts:

1. Create a private `0700` runtime directory outside the durable migration run.
2. Create a `0600` DEFINE-only file in that directory containing the verified
   values for the current SQL*Plus invocation.
3. Create the existing SQL*Plus wrapper in the same private directory. The
   wrapper sources the temporary DEFINE file by absolute path, then executes the
   generated schema script from its original directory.
4. Remove the private directory immediately after SQL*Plus and from the process
   exit and handled INT/TERM signal cleanup paths.

The supported per-schema SQL Developer output relies on the wrapper to define
these password variables; it does not need a copied or symlinked output tree.
If the process is killed with an uncatchable signal or the host fails, the
operating system may leave the runtime directory behind. Any residual secret is
still outside the durable run evidence and protected by `0700`/`0600`
permissions; the design does not claim cleanup after events no process can
handle.

### Generated SQL execution contract

The supported layout is:

```text
sdcli/
  <schema>/user.sql
  <schema>/master.sql
  <schema>/*.sql
```

`master.sql` remains the only parsed generated protocol and accepts only its
bounded `@`/`@@` include grammar. Every non-control SQL file must be directly
listed in that master plan. A nested SQL path (`<schema>/<group>/<file>.sql`)
is rejected with an actionable unsupported-layout error. This deliberately
avoids semantic parsing of arbitrary group scripts.

When no schema hierarchy is present, deploy stops before executing `gen/*.sql`.
The previous monolithic fallback is removed because it can contain cleanup DDL
and cannot support target schema inventory or successful validation.

### Offline configuration and program synchronization

The repository tracks `sdcli-scripts/config.example.yaml`, containing generic
placeholders and comments, and ignores `sdcli-scripts/config.yaml`.

The release bundle contains only the example configuration. `run.sh` performs
an idempotent sync on every invocation:

1. Stage `migrate.sh`, `lib/`, `templates/`, and `config.example.yaml` in a
   temporary container directory.
2. Validate all required program files in the stage.
3. Replace only the program files in the installed scripts directory.
4. If the customer `config.yaml` is absent, copy the staged example to it;
   otherwise leave it byte-for-byte unchanged.
5. Write the release version marker only after the program sync succeeds.

An interrupted sync leaves either the previous version marker or no new marker,
so a later `run.sh` repeats the idempotent sync. It never treats file existence
alone as proof that current code is installed.

## Failure behavior

| Condition | Required outcome |
| --- | --- |
| SDCLI exits zero without exact marker | command and workflow fail |
| SDCLI emits an Oracle/fatal diagnostic | command and workflow fail, except exact idempotent init case |
| SQL*Plus is interrupted during password deployment | original run files remain unchanged; temporary secrets are removed on handled exit |
| Nested or monolithic generated SQL layout | deploy fails before any generated schema SQL executes |
| Existing customer config during release update | configuration is preserved |
| New program release over existing container | program files refresh and version marker changes |

## Test strategy

- Add fake-SDCLI tests for `mkconn` and `driver` returning zero with an ORA
  diagnostic or a missing completion marker; both must fail. Preserve the
  exact `init`/`ORA-01920` idempotent case.
- Add deployment helper tests showing generated `passworddefinition.sql` is
  unchanged while the SQL*Plus wrapper sees the private DEFINE file, including
  a handled interruption cleanup assertion.
- Replace the existing monolithic-fallback success test with rejection tests;
  add a nested SQL file to a schema fixture and assert deploy fails before
  SQL*Plus is called.
- Extend offline-bundle and offline-run fakes to assert that no populated
  `config.yaml` is packaged, an existing customer config survives a sync, and
  changed program files are refreshed even when their old filenames exist.
- Run Bash syntax checks, all shell regression tests, Python report tests, and
  an offline-bundle inspection.

## Acceptance criteria

- No approved false-success or password-on-run-disk path remains.
- Standard flat TPCC/Proda-style generated schema output still deploys and
  postdeploys as before.
- Unsupported generated layouts stop early with clear operator guidance.
- A customer configuration never enters a release bundle and is never
  overwritten by `run.sh`.
- The released offline image still needs no Internet access at customer runtime.
