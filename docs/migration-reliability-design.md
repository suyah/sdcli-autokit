# Mandatory Migration Reliability Design

Date: 2026-10-12
Scope: SQL Server to Oracle migration using SQL\*Loader, BCP, and SQL Developer CLI
Priority source: [Migration reliability priorities](migration-reliability-priorities.md)

## 1. Goal

Make one complete migration run trustworthy: the tool must deploy every intended generated object, move every expected table, prove row-count agreement, preserve evidence across resumes, protect credentials, and return nonzero whenever correctness is not established.

This design implements mandatory items M1–M13. It keeps the current Bash/container architecture and assumes one maintainer and one active workflow per migration repository.

## 2. Non-goals

- Supporting source databases other than SQL Server or targets other than Oracle.
- Running concurrent workflows against one migration repository.
- Automatically repairing conversion diagnostics or invalid generated SQL.
- Automatically dropping schemas, truncating tables, or rolling back a partial migration.
- Adding a service, database, UI, cloud uploader, or generic workflow engine.
- Hiding SQL Developer's long serial repository operations with unsafe automatic retries.

## 3. Run contract

A run is successful only when all required phases finish and final validation proves the result. A successful command is not inferred from a friendly console message alone.

The full workflow remains:

1. preflight and acquire repository lock;
2. create/test source, repository, and target connections;
3. capture, convert, generate, and create data-move files;
4. record the source-quiescence acknowledgement;
5. offload all source tables;
6. deploy pre-data Oracle DDL;
7. load all table data;
8. deploy post-data Oracle DDL;
9. reconcile tables and validate Oracle objects;
10. write final status and release the lock.

Any failure stops later phases. The final process exit code is nonzero unless step 9 passes.

## 4. Plain-file run evidence

Evidence stays under `run_<id>/autokit`. No new state service is introduced.

| File | Purpose |
|---|---|
| `migrate.log` | Redacted human-readable log. Appended on resume. |
| `phase_status.tsv` | Append-only phase events: timestamp, phase, state, exit code, attempt, and note. |
| `sdcli_commands.log` | Redacted SQL Developer commands. Appended on resume. |
| `deploy_manifest.tsv` | Every discovered generated SQL file and whether it was executed directly, covered by a master script, or intentionally excluded with a reason. |
| `bcp_status.tsv` | One record per BCP table: source object, data file, exit code, and exported row count. |
| `sqlldr_status.tsv` | One record per target table: control file, log file, exit code, loaded, rejected, and discarded counts. |
| `reconciliation.tsv` | Source object to target object mapping and exported, loaded, rejected, discarded, and final target counts plus status. |
| `validation_summary.txt` | Final counts and an unambiguous `PASS` or `FAIL`. |

Files use TSV where values may contain commas. Headers are written only when a file is first created. Records are written to a temporary file and renamed when a whole report is replaced; append-only event files are never truncated during `--run` resume.

`phase_status.tsv` states are `started`, `succeeded`, and `failed`. A mutating phase that already has `succeeded` cannot run again unless the operator passes `--rerun-completed` together with an explicit `--phase` and `--run`. The override is recorded. The tool never performs automatic target cleanup.

## 5. Honest command and phase status

### 5.1 SQL Developer commands

`run_sdcli` will:

1. preserve the real command exit code through the logging pipeline;
2. fail on a timeout or nonzero exit;
3. fail on fatal/error diagnostics even when an action success marker also appears;
4. allow only exact, documented benign diagnostics scoped to a specific action;
5. keep conversion diagnostics fatal;
6. redact all configured secrets before writing console or log output; and
7. restore the caller's `errexit` setting instead of always enabling `set -e`.

The benign diagnostic list is a small function returning action plus exact pattern pairs. A general rule such as “ignore errors when success is printed” is prohibited.

### 5.2 Native tools

BCP, SQL\*Plus, and SQL\*Loader wrappers record both the underlying exit code and parsed result counts. A wrapper failure cannot be converted back to success by `tee`, a summarizer, or shell-option restoration.

### 5.3 Final validation

`run_validate` aggregates all findings, writes the summary, and returns `1` when any required check fails. Warnings that are known and harmless may be allowlisted by exact diagnostic code and context. Missing evidence is a failure, not a warning.

## 6. Deterministic generated-SQL deployment

The tool will not recursively execute arbitrary `*.sql` files in alphabetical order.

### 6.1 Inventory before execution

After generation, create an inventory of SQL Developer output. For each schema directory:

- identify `master.sql` and parse only its SQL\*Plus include directives;
- resolve each include relative to the master file and reject path traversal;
- require every referenced file to exist;
- reject duplicate references and cycles;
- classify each referenced file as pre-data, post-data, password definition, or unsupported;
- fail before deployment if an SQL file is neither referenced by the chosen master nor explicitly classified.

The actual SQL Developer output from the supported/tested version becomes the fixture for these tests. The code must not contain FY3000 schema names, Hyderabad endpoints, or a list of objects derived from only that project.

### 6.2 Phase split

The initial supported classification is based on generated file purpose, not alphabetical order:

- pre-data: roles, users/schemas, tables, sequences needed by table defaults, and other files confirmed by the generated master to be prerequisites for loading;
- post-data: indexes, constraints, views, synonyms, functions, procedures, packages, triggers, and final/post scripts;
- control-only: master scripts and password-definition files; these are not separately executed when their child files are executed;
- unsupported: any new generated file type not covered by the tested plan. Unsupported means fail with its path, not silently skip it.

Within a class, preserve the order in the generated master. Across schemas, use a stable sorted schema order. Each child script executes exactly once and is recorded in `deploy_manifest.tsv`.

Only the tested flat per-schema layout is automated: each schema directory has
`user.sql` and `master.sql`, and executable schema scripts are directly listed
in the bounded master plan. A monolithic `gen/*.sql`-only layout or nested SQL
directory is unsupported and must fail before SQL\*Plus executes generated
schema SQL; the tool does not guess cleanup or phase semantics for those files.

### 6.3 Oracle error handling

Pre-data SQL\*Plus wrappers set `WHENEVER OSERROR EXIT FAILURE` and
`WHENEVER SQLERROR EXIT SQL.SQLCODE`. Post-data wrappers still stop immediately
on runtime failures, but continue independent SQL statements after server-side
DDL errors so all generated post-data scripts and each schema's `post.sql` can
run. Each script is recorded as executed or failed in `deploy_manifest.tsv`;
postdeploy returns nonzero after all executable work is attempted. A retry
skips successful post-data scripts, retries failed scripts, and reruns
`post.sql`. After post-deploy, query Oracle for invalid objects and compiler
errors in the migrated schemas. Any invalid object or compiler error fails
validation and is written without exposing passwords.

Before a fresh deploy, fail if target tables from the deployment inventory already exist. A resumed run uses the phase manifest; it does not guess whether a partial schema is safe to reuse.

## 7. Complete data execution and reconciliation

### 7.1 Offload and load coverage

Discover generated `MicrosoftSQLServer_data.sh` and `oracle_loader.sh` scripts
in stable sorted order. Run each root BCP script tree once and each independent
leaf loader script once; do not execute nested BCP scripts again after their
parent entry script already invoked them. Loader selection is structural and
does not grep generated shell text for a `sqlldr` token.

Do not tokenize or interpret the generated shell command text. Execute only the
root entry script in each generated BCP script tree; nested scripts are reached
through that generated entry point and are not executed a second time. The BCP
wrapper records the actual source object or query and resolved output path from
its argv. The number of unique successful BCP data-file records must equal the
number of generated SQL\*Loader control files. Load and reconciliation then
join the independently observed BCP and SQL\*Loader records by absolute data
path.

The BCP wrapper parses the standard “rows copied” result and writes it with the source object or query and output file. SQL\*Loader log parsing records loaded, rejected, discarded, and skipped counts with the target table. Zero-row tables are valid when both sides report zero and the expected output/control files exist.

### 7.2 Source consistency checkpoint

The full workflow requires `--confirm-source-quiesced` before offload. The flag means the operator has stopped or otherwise controlled source writes for the export window. The tool records the acknowledgement time and source connection identity, excluding credentials.

Phase-only dry runs do not require the flag. A real standalone offload does. There is no bypass hidden in project-specific configuration.

### 7.3 Reconciliation

Build `reconciliation.tsv` by joining generated source-to-target mappings, BCP status, SQL\*Loader status, and Oracle row counts. Do not join solely on a filename basename when schema-qualified mappings are available.

A table passes only when:

- it exists once in the expected mapping;
- BCP succeeded and produced the expected file;
- SQL\*Loader succeeded;
- rejected and discarded counts are zero;
- exported rows equal loaded rows; and
- loaded rows equal `SELECT COUNT(*)` from the mapped Oracle table.

Any missing, duplicate, ambiguous, or unqueryable table fails validation. The final summary shows totals but the TSV retains per-table evidence.

## 8. Repository model isolation

Because later SQL Developer phases require `latest`, use a simple repository-scoped atomic lock directory rather than attempting concurrent model discovery. Atomic `mkdir` works in both the Linux container and the maintainer's macOS test environment without adding another package.

- Derive the lock-directory name from a SHA-256 of the non-secret repository identity: repository name plus connection string.
- Create it atomically under the configured project root in `.locks/`; an existing directory means another run owns the repository.
- Write PID, hostname, run ID, project, and start time into an owner file for diagnostics, but do not write the connection string.
- Acquire it before any connection setup or repository operation.
- Hold it across capture through generate/datamove and, for simplicity, the entire full workflow.
- Release it through an `EXIT`, `INT`, and `TERM` cleanup path.
- A stale lock is never removed automatically; the failure identifies the exact directory for operator review.

This lock intentionally serializes workflows. Concurrent repository use is outside the supported scope.

## 9. Credential safety

All secret values remain environment substitutions in the real config. They are never copied into example configuration, command summaries, status TSV files, or process arguments when an existing file descriptor/stdin mechanism can be used.

For `passworddefinition.sql`:

1. leave the generated file unchanged;
2. create a private runtime directory with permission `0700`;
3. write a DEFINE-only file with permission `0600` from the validated prompt
   identifiers and the current schema password;
4. have the SQL\*Plus wrapper source that private file before the generated
   schema script; and
5. remove the runtime directory on return, error, `INT`, and `TERM`.

The cleanup stack must support both temporary-secret cleanup and
repository-lock release without one cleanup overwriting the other trap. An
uncatchable process or host failure can leave only the private temporary copy,
not a modified durable migration artifact.

## 10. Configuration and preflight

### 10.1 Shipped files

- Track `sdcli-scripts/config.example.yaml` with neutral placeholders and comments.
- Do not track or bundle a populated `config.yaml`.
- `deployment/run.sh` copies program files into the container but never replaces an existing customer `config.yaml`.
- On first install it may copy the example to `config.yaml`, then stop and require the operator to edit it before migration.
- Manual integration-test config remains under `tests/manual`, is untracked or contains placeholders only, and obtains secrets exclusively from environment variables.

### 10.2 Validation rules

Before creating connections, validate:

- `defaults.source.type` is `sqlserver` and `defaults.target.type` plus repository type are `oracle`;
- migration, run, repository, and connection names match a conservative safe-name pattern and contain no path separators or `..` segments;
- source port is numeric and between 1 and 65535;
- required connection values and resolved secret environment variables are nonempty;
- project/output paths resolve below the configured project root;
- configured wallet directory exists and contains the files required by the selected Oracle connection method;
- tools and directories needed for the requested phase exist; and
- full workflow acknowledgement flags are present.

Validation reports YAML paths such as `.migrations[0].source.conn`. It must not print secret values.

## 11. Offline runtime consistency

`deployment/run.sh` remains the installation/upgrade entry point.

- Store a bundle/script version file with copied scripts.
- Copy scripts to a temporary container directory, validate required files, set ownership, and atomically replace program files while preserving `config.yaml` and run data.
- Inspect an existing container's image ID, data/log/vendor mounts, host network mode, and configured engine assumptions. Fail with a recreate instruction on mismatch.
- Record installed vendor RPM names, versions, architectures, and SHA-256 values. If the supplied directory differs on a later run, fail and require intentional container replacement instead of silently mixing versions.
- Select the preferences directory belonging to the active `sdcli` installation. Put preference editing in one shared helper rather than maintaining different implementations in `run.sh` and `migrate.sh`.
- Make `start.sh` and `stop.sh` call the configured `CONTAINER_ENGINE` and support only the already-declared `podman` and `docker` values.

The scripts never remove a container or volume automatically.

## 12. Offline input verification

- Pin the existing yq and jTDS versions and SHA-256 values in the Docker build. Verify before installation.
- Continue to verify the release tarball using its generated SHA-256 file after transfer.
- Before local RPM installation, require one package for each required family, validate package name and architecture, verify the RPM payload digest, and reject conflicting required-family versions.
- Additional RPMs remain permitted as offline dependencies, but the installer logs their package identity before DNF runs.
- A missing vendor signing key may be reported as `NOKEY`; payload digest failure is fatal. Enforcing external signature provenance is optional O4 because the project does not control how the customer obtains those RPMs.

## 13. Test and acceptance design

Unignore and track `tests/`. Every mandatory behavior receives a fixture-based shell test. The existing four failures are resolved before adding new acceptance claims.

Minimum automated coverage:

- native nonzero exits and fatal output propagate through logging pipelines;
- a success marker cannot hide an unrelated error;
- validation returns nonzero for every issue class and for missing evidence;
- all offload/load scripts execute and table coverage mismatches fail;
- generated SQL inventory rejects duplicates, unknown files, missing includes, traversal, and master-plus-child double execution;
- phase history survives resume and completed mutating phases require explicit override;
- generated password files remain unchanged and private DEFINE files are
  removed after success, failure, and handled signal interruption;
- repository lock blocks a second workflow;
- config validation rejects unsupported types, unsafe names, bad ports, missing secrets, and incomplete wallets;
- Docker and Podman lifecycle scripts use the configured engine and reject mismatched existing containers;
- pinned download checksum failures stop the image build; and
- no test fixture contains a real project endpoint, wallet, username/password, or FY3000-specific rule in production code.

Repository gate:

```text
all tests/*.sh pass
bash -n passes for tracked shell scripts
git diff --check passes
```

Final integration acceptance must run in a fresh container using test credentials supplied only through environment variables:

1. initialize repository and connections;
2. run capture through final validation;
3. confirm every phase status is `succeeded`;
4. confirm `reconciliation.tsv` has no failed table;
5. confirm Oracle invalid-object and compiler-error counts are zero;
6. confirm logs contain no configured secret values;
7. stop/start the container and verify run evidence persists; and
8. repeat a safe read-only validation using `--run` without erasing earlier history.

Only this result, rather than the presence of a final “completed successfully” line, confirms a successful migration.

## 14. Expected files changed during implementation

The implementation should remain concentrated in:

- `sdcli-scripts/migrate.sh`;
- small helpers under `sdcli-scripts/lib/` for status parsing or shared preference handling;
- `sdcli-scripts/config.example.yaml` and removal of the populated tracked config;
- `deployment/run.sh`, `start.sh`, `stop.sh`, `install-vendor.sh`, and `Dockerfile`;
- `.gitignore`, `README.md`, and `tests/`.

Do not introduce another programming language, daemon, or persistent state component for these changes.
