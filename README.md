# DASOM

**DASOM** — **Deterministic AST SQLServer to Oracle Migrator** — is a containerized automation toolkit for SQL Server to Oracle migrations using Oracle SQL Developer CLI (`sdcli`).

The project is delivered through the `sdcli-autokit` repository and provides a repeatable workflow for preparing the migration runtime, configuring migrations, initializing the SQL Developer migration repository, creating SDCLI connections, running full migrations or individual phases, and organizing each run's logs and generated artifacts.

Use DASOM to automate and standardize SQL Server to Oracle migration workflows that would otherwise require many manual `sdcli` commands and generated script execution steps.

The project assumes:

- **Source database:** SQL Server
- **Target database:** Oracle
- **Migration repository:** Oracle
- **Migration engine:** Oracle SQL Developer CLI (`sdcli`)
- **Runtime environment:** Podman container

## Project layout

The files are split into two working areas:

```text
deployment/
├── build.sh
├── Dockerfile
├── run.sh
├── start.sh
└── stop.sh

sdcli-scripts/
├── config.yaml
├── lib/
│   ├── bcp
│   ├── load_wrappers.sh
│   ├── sqlldr
│   └── sqlplus
└── migrate.sh
```

### `deployment/`

Use this directory on the host to build and manage the Podman environment.

| File | Purpose |
| --- | --- |
| `build.sh` | Builds the Podman image and prepares the named Podman volume. |
| `Dockerfile` | Defines the container image used by the migration environment. |
| `run.sh` | Creates or reuses the container, starts it, prepares SQL Developer CLI, downloads the SQL Server driver if needed, and copies `sdcli-scripts` into the container when missing. |
| `start.sh` | Starts an existing stopped container. |
| `stop.sh` | Stops the running container. |

### `sdcli-scripts/`

Use this directory inside the migration working area/container to configure and run migrations.

| File | Purpose |
| --- | --- |
| `config.yaml` | Main configuration file for repository, source database, target database, and migration definitions. |
| `migrate.sh` | Main migration command. It validates config, initializes the repository, creates connections, runs phases, and writes run logs. |
| `lib/` | Helper scripts used internally for BCP, SQL*Plus, and SQL*Loader execution. Most users do not need to edit these files. |

## Prerequisites

On the host machine, you need:

- Podman installed
- network access to the source SQL Server database
- network access to the target Oracle database
- network access for first-time software downloads, unless the required artifacts are already available
- a `.env` file in the `deployment/` directory for container settings

The `.env` file is used by the deployment scripts and normally contains values such as container name, image name, volume name, user/home paths, SQL Developer download URL, and driver download URL.

## Configure `config.yaml`

The migration runner reads migration settings from:

```bash
sdcli-scripts/config.yaml
```

The main sections are:

| Section | Purpose |
| --- | --- |
| `defaults` | Shared settings such as driver path, output project root, source/target type, and load/offload preferences. |
| `migration_repository` | Oracle migration repository connection used by SQL Developer migration. |
| `migrations` | One or more named source-to-target migration definitions. |

Example:

```yaml
defaults:
  driver_file: /u01/app/jtds-1.3.1.jar
  paths:
    project_root: /u01/data/sdcli-autokit/projects
  source:
    type: sqlserver
    bcp_tls_mode: optional
  target:
    type: oracle
  offload_preferences:
    packet_size: 65535
  load_preferences:
    direct: true
    rows: 50000
    bindsize: 268435456
    readsize: 268435456

migration_repository:
  type: oracle
  name: repo
  conn: tcps://your-repo-host:1521/your_repo_service?ssl_server_dn_match=yes
  repo_user:
    connection_name: migration_repo
    user: migrep
    password: "${MIGRATION_REPO_PASSWORD}"
  super_user:
    connection_name: super_migration
    user: admin
    password: "${MIGRATION_SUPER_PASSWORD}"

migrations:
  - name: tpcc
    source:
      conn: 10.0.1.165:1433:tpcc
      user: sa
      password: "${SOURCE_PASSWORD}"
    target:
      conn: tcps://your-target-host:1521/your_target_service?ssl_server_dn_match=yes
      user: admin
      password: "${TARGET_PASSWORD}"
      default_schema_password: "${MIGRATED_SCHEMA_PASSWORD}"
```

### Migration name

Each entry under `migrations` has a `name`. That value is the migration name passed to `migrate.sh`.

For example, this config:

```yaml
migrations:
  - name: tpcc
```

is run with:

```bash
./migrate.sh tpcc --migrate
```

The migration name is used to select the matching config entry, create connection names such as `src_tpcc` and `tgt_tpcc`, create the run directory, and create a run-specific capture model such as `tpcc_20260427_014117`.

For a large migration program, define one migration entry per source/target database pair. For example, 50 source databases usually means 50 migration entries with 50 unique migration names.

### Source connection format

SQL Server source connections use this format:

```text
host:port:database
```

Example:

```yaml
source:
  conn: 10.0.1.165:1433:tpcc
```

### Password variables

Do not put literal passwords in `config.yaml`. Use environment variable placeholders instead:

```yaml
password: "${SOURCE_PASSWORD}"
```

Before running `migrate.sh`, export every password variable referenced by your `config.yaml`. For the example above:

```bash
export MIGRATION_REPO_PASSWORD='...'
export MIGRATION_SUPER_PASSWORD='...'
export SOURCE_PASSWORD='...'
export TARGET_PASSWORD='...'
export MIGRATED_SCHEMA_PASSWORD='...'
```

These correspond to:

| Variable | Used for |
| --- | --- |
| `MIGRATION_REPO_PASSWORD` | Migration repository owner/user password. |
| `MIGRATION_SUPER_PASSWORD` | Oracle super/admin user used during repository initialization. |
| `SOURCE_PASSWORD` | SQL Server source database password. |
| `TARGET_PASSWORD` | Oracle target database password. |
| `MIGRATED_SCHEMA_PASSWORD` | Password used for generated Oracle schema users during deploy. |

If your config uses different placeholder names, export those names instead. The script checks placeholders during startup and fails early if a required variable is missing.

## First-time setup

### 1. Build and start the container

From the `deployment/` directory:

```bash
./build.sh
./run.sh
```

`build.sh` builds the Podman image and prepares the shared volume. `run.sh` creates or reuses the container and prepares the SQL Developer CLI environment.

For normal daily use after the container already exists:

```bash
./start.sh
./stop.sh
```

### 2. Review migration configuration

In `sdcli-scripts/`, update `config.yaml` for your repository connection, source database, target database, migration name, password placeholder names, and optional load/offload preferences.

### 3. Set password variables

Export the password variables described in [Password variables](#password-variables).

### 4. Initialize the migration repository

Run once per migration repository from `sdcli-scripts/`:

```bash
./migrate.sh --init
```

This registers the SQL Server driver and initializes the Oracle migration repository used by SDCLI.

## Typical migration workflow

From `sdcli-scripts/`, after `config.yaml` is reviewed and password variables are exported:

```bash
./migrate.sh --init
./migrate.sh tpcc --conn-setup
./migrate.sh tpcc --migrate
```

Replace `tpcc` with your migration name from `config.yaml`.

## Run a migration

### Create SDCLI connections

Run once for a migration, or rerun when connection details or credentials change:

```bash
./migrate.sh tpcc --conn-setup
```

For migration name `tpcc`, this creates source connection `src_tpcc` and target connection `tgt_tpcc`.

### Run the full migration

```bash
./migrate.sh tpcc --migrate
```

You can also run the same full flow by omitting `--migrate`:

```bash
./migrate.sh tpcc
```

The full flow runs:

```text
capture -> convert -> generate -> datamove -> offload -> deploy -> load -> postdeploy -> validate
```

In plain language, this captures SQL Server metadata, converts it for Oracle, generates scripts, exports data, deploys the Oracle schema objects needed before load, loads data, runs selected post-load scripts, and checks logs for common issues.

## Run a single phase

Use `--phase` when you want to run or rerun one part of the migration.

```bash
./migrate.sh tpcc --phase capture
./migrate.sh tpcc --phase convert --model latest
./migrate.sh tpcc --phase generate --model latest
./migrate.sh tpcc --phase datamove --model latest
./migrate.sh tpcc --phase offload --model latest
./migrate.sh tpcc --phase deploy --run 20260427_014117
./migrate.sh tpcc --phase load --run 20260427_014117
./migrate.sh tpcc --phase postdeploy --run 20260427_014117
./migrate.sh tpcc --phase validate --run 20260427_014117
```

Supported phases:

| Phase | Purpose |
| --- | --- |
| `capture` | Capture source database metadata into the migration repository. |
| `convert` | Convert the captured model for Oracle. |
| `generate` | Generate Oracle migration scripts. |
| `datamove` | Generate data movement scripts. |
| `offload` | Export data from SQL Server. |
| `deploy` | Run generated Oracle schema setup needed before loading data. |
| `load` | Load exported data into Oracle. |
| `postdeploy` | Run selected post-load Oracle scripts. |
| `validate` | Check migration logs for common errors and warnings. |

### Model and run behavior

For normal use:

- `capture` creates a new model using `<migration_name>_<run_id>`.
- non-capture SDCLI phases usually use `latest`.
- `--model <name>` is only for non-capture single-phase runs.
- `--run <run_id>` is only for non-capture single-phase runs and reuses an existing run directory.

Use `--run` when rerunning phases that depend on files already generated in a previous run, such as `deploy`, `load`, `postdeploy`, or `validate`.

The run id can be provided with or without the `run_` prefix:

```bash
./migrate.sh tpcc --phase load --run 20260427_014117
./migrate.sh tpcc --phase load --run run_20260427_014117
```

## Dry run

Use `--dry-run` to validate arguments and configuration without executing the migration:

```bash
./migrate.sh tpcc --migrate --dry-run
```

Dry run is useful before a real run because it shows the major commands or script paths that would be used.

## Output and logs

Each run gets a timestamped run directory under `defaults.paths.project_root`.

Example for migration name `tpcc`:

```text
/u01/data/sdcli-autokit/projects/tpcc/run_20260427_014117/
```

Inside each run directory, output is split into two main areas:

```text
autokit/   logs and summaries from this runner
sdcli/     files generated by SQL Developer CLI
```

Important files:

| File | Description |
| --- | --- |
| `autokit/migrate.log` | Main run log. Start here when troubleshooting. |
| `autokit/sdcli_commands.log` | SDCLI commands executed by the run. |
| `autokit/sdcli_commands_summary.txt` | Short command summary printed at the end of SDCLI runs. |
| `autokit/migration_summary.csv` | High-level migration result summary. |
| `autokit/deploy_manifest.csv` | SQL scripts executed or skipped during deploy/postdeploy. |
| `sdcli/` | SDCLI-generated scripts, logs, and data movement files. |

If you rerun a phase with `--run`, the new output is appended to the existing run log.

## Command reference

Run deployment commands from `deployment/`:

```bash
./build.sh          # Build image and prepare volume
./run.sh            # Create/reuse/start container and prepare sdcli environment
./start.sh          # Start existing container
./stop.sh           # Stop running container
```

Run migration commands from `sdcli-scripts/`:

```bash
./migrate.sh --init
./migrate.sh <migration_name> --conn-setup
./migrate.sh <migration_name> --migrate
./migrate.sh <migration_name>
./migrate.sh <migration_name> --phase <phase_name>
./migrate.sh <migration_name> --phase <phase_name> --run <run_id>
./migrate.sh <migration_name> --migrate --dry-run
```

## Troubleshooting tips

- Start with `autokit/migrate.log` for the full run history.
- Check `autokit/migration_summary.csv` for a quick status summary.
- Check `sdcli/log/error.txt` when SDCLI phases fail.
- Use `--dry-run` to confirm config and command construction before a real run.
- Run `--conn-setup` again if source or target connection details changed.
- Use `--run <run_id>` when rerunning a later phase against files from an existing run.
- If the container does not exist, run `deployment/run.sh` before `deployment/start.sh`.

## Notes for maintainers

For day-to-day migration work, most users only need to understand:

1. `deployment/` scripts for container lifecycle
2. `sdcli-scripts/config.yaml` for migration settings
3. password environment variables
4. `sdcli-scripts/migrate.sh` commands
5. each run's `autokit/` and `sdcli/` output directories

The helper files under `sdcli-scripts/lib/` are used internally to make generated BCP, SQL*Plus, and SQL*Loader steps run consistently. Most users should not need to modify them.
