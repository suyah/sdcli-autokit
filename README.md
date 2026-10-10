# sdcli-scripts

A repeatable SQL Server to Oracle migration runner built around Oracle SQL Developer CLI (`sdcli`) and a Podman-based execution environment.

Use this project to prepare a reusable migration container, define one or more SQL Server to Oracle migrations, initialize the SQL Developer migration repository, create SDCLI connections, run full migrations or individual phases, and keep each run's logs and generated files organized.

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
| `build.sh` | Builds a version-tagged Podman image on a connected build machine. |
| `Dockerfile` | Defines the container image used by the migration environment. |
| `run.sh` | Creates or reuses the container and installs customer-staged RPMs without downloading packages. |
| `install-vendor.sh` | Runs inside the container to install the staged Oracle and Microsoft RPMs locally. |
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

- Podman installed on the customer VM; Podman or Docker/Rancher Desktop on the connected build machine
- network access to the source SQL Server database
- network access to the target Oracle database
- a `.env` file in the `deployment/` directory for container settings

The connected build machine needs internet access for the base image, `yq`, and jTDS. The customer VM does not need registry or software-repository access. Its `.env` contains the container, image repository, separate data/log volume, and user/path settings; it has no package download URLs.

### Customer-provided proprietary artifacts for offline installation

The offline bundle does not distribute Oracle SQL Developer, Oracle Instant Client, Microsoft ODBC Driver, or Microsoft SQL Server command-line tool binaries. The customer obtains the required packages through its approved vendor account or internal software repository, accepts the applicable terms, and transfers them separately to the isolated environment.

| Required software | Customer download source | Files to stage |
| --- | --- | --- |
| Oracle SQL Developer | [Oracle SQL Developer downloads](https://www.oracle.com/database/sqldeveloper/technologies/download/) | Linux `noarch` RPM, for example `sqldeveloper-<version>.noarch.rpm`. |
| Oracle Instant Client | [Oracle Instant Client for Linux x86-64 downloads](https://www.oracle.com/database/technologies/instant-client/linux-x86-64-downloads.html) | Matching Oracle Linux 9 `x86_64` RPMs: Basic, SQL*Plus, and Tools. |
| Microsoft ODBC Driver 18 and SQL Server command-line tools | [Microsoft offline installation guidance for `mssql-tools18` and `msodbcsql18`](https://learn.microsoft.com/en-us/sql/linux/install-upgrade/setup-tools?view=fabric#offline-installation) | Matching `x86_64` RPMs for `msodbcsql18` and `mssql-tools18`, plus any documented dependencies. The customer must accept the Microsoft EULA. |

Place these files, plus any RPM dependencies reported by the offline install, in a customer-controlled directory such as:

```text
customer-artifacts/
├── sqldeveloper-<version>.noarch.rpm
├── oracle-instantclient<major>-basic-<version>.el9.x86_64.rpm
├── oracle-instantclient<major>-sqlplus-<version>.el9.x86_64.rpm
├── oracle-instantclient<major>-tools-<version>.el9.x86_64.rpm
├── msodbcsql18-<version>.x86_64.rpm
└── mssql-tools18-<version>.x86_64.rpm
```

`run.sh` checks that the six expected files are present before creating a container. The container then checks RPM names and CPU architecture before installing only from the read-only mount with DNF repositories disabled. This verifies technical compatibility only; it does not establish legal entitlement.

The following set was smoke-tested on Oracle Linux 9 x86_64 on 2026-10-09. These are direct vendor links for convenience; customers may instead use their approved internal mirror.

- [SQL Developer 26.2 RPM](https://download.oracle.com/otn_software/java/sqldeveloper/sqldeveloper-26.2.0-186.2220.noarch.rpm)
- [Instant Client 23.26 Basic RPM](https://download.oracle.com/otn_software/linux/instantclient/2326300/oracle-instantclient-basic-23.26.3.0.0-1.el9.x86_64.rpm), [SQL*Plus RPM](https://download.oracle.com/otn_software/linux/instantclient/2326300/oracle-instantclient-sqlplus-23.26.3.0.0-1.el9.x86_64.rpm), and [Tools RPM](https://download.oracle.com/otn_software/linux/instantclient/2326300/oracle-instantclient-tools-23.26.3.0.0-1.el9.x86_64.rpm)
- [Microsoft ODBC Driver 18 18.7.1.1 RPM](https://packages.microsoft.com/rhel/9.0/prod/Packages/m/msodbcsql18-18.7.1.1-1.x86_64.rpm) and [mssql-tools18 18.7.1.1 RPM](https://packages.microsoft.com/rhel/9.0/prod/Packages/m/mssql-tools18-18.7.1.1-1.x86_64.rpm)

### Offline handoff

On a connected Linux/amd64 build host, create a versioned bundle:

~~~bash
./release/build-offline.sh 1.0.0
~~~

The scripts prefer Podman when both tools are installed. To build with Rancher Desktop/Docker explicitly, use:

~~~bash
CONTAINER_ENGINE=docker ./release/build-offline.sh 1.0.0
~~~

Rancher Desktop must be running with its Docker engine available before starting the build.

Transfer `dist/sdcli-autokit-1.0.0-linux-amd64.tar.gz` and its adjacent `.sha256` file through any approved cloud, on-premises, or physical method. On the customer VM:

~~~bash
sha256sum -c sdcli-autokit-1.0.0-linux-amd64.tar.gz.sha256
tar -xzf sdcli-autokit-1.0.0-linux-amd64.tar.gz
cd sdcli-autokit-1.0.0-linux-amd64
podman load -i image.tar
./deployment/run.sh --vendor-dir /absolute/path/to/customer-artifacts --accept-microsoft-eula
~~~

The EULA flag records the operator's acknowledgement required for the Microsoft packages; it does not replace the vendor terms. On a system where SELinux labels are not applicable, remove `,Z` from the three `-v` options in `deployment/run.sh`.

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
    # For Autonomous Database mTLS, uncomment this and keep TCPS URLs below.
    # wallet_dir: /u01/data/sdcli-autokit/wallets/Wallet_myadb
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
  conn: tcps://your-repo-host:1522/your_repo_service?ssl_server_dn_match=yes
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
      conn: tcps://your-target-host:1522/your_target_service?ssl_server_dn_match=yes
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

### Autonomous Database mTLS wallet

For an Autonomous Database configured for mTLS, download the database's client-credentials wallet through the customer's OCI tenancy, transfer it separately, and unzip it into the running container's persistent data volume. Do not put the wallet in the image or source repository.

```bash
# On the customer VM, after run.sh has completed:
mkdir -p /tmp/Wallet_myadb
unzip /path/to/Wallet_myadb.zip -d /tmp/Wallet_myadb

podman exec --user root sdcli-autokit mkdir -p /u01/data/sdcli-autokit/wallets
podman cp /tmp/Wallet_myadb sdcli-autokit:/u01/data/sdcli-autokit/wallets/Wallet_myadb
podman exec --user root sdcli-autokit chown -R sduser:sduser /u01/data/sdcli-autokit/wallets/Wallet_myadb
```

Set `defaults.target.wallet_dir` to that directory. Keep `migration_repository.conn` and each `migrations[].target.conn` in the existing `tcps://host:port/service?ssl_server_dn_match=yes` form, using the host, port, and service name from the wallet's `tnsnames.ora` file. The migration launcher sets both `TNS_ADMIN` for SQL*Plus/SQL*Loader and `oracle.net.tns_admin` for SDCLI's JDBC connections.

Do not use a bare TNS alias in these fields: SQL Developer's SDCLI `-connDetails` parser rejects it. The wallet supplies the mTLS credentials; the TCPS URL supplies the database endpoint.

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

### 1. Build and start the container on a connected development machine

From the `deployment/` directory:

```bash
./build.sh
```

For an offline customer VM, use the bundle workflow above instead. After loading the offline image, run:

```bash
./run.sh --vendor-dir /absolute/path/to/customer-artifacts --accept-microsoft-eula
```

`run.sh` creates the separate data/log volumes, mounts the RPM directory read-only, and prepares the SQL Developer CLI environment without network downloads.

For normal daily use after the container already exists:

```bash
./start.sh
./stop.sh
```

### 2. Review migration configuration

In `sdcli-scripts/`, update `config.yaml` for your repository connection, source database, target database, migration name, password placeholder names, and optional load/offload preferences.

For an offline bundle, `run.sh` starts the container and copies this directory into the container on its first run. You can then configure it interactively inside the running container:

```bash
podman exec -it --user sduser sdcli-autokit bash
cd ~/sdcli-scripts
vi config.yaml
```

Exit the shell after saving. The configuration remains in the existing container; keep a copy of the edited `config.yaml` outside the container as well, so it can be reused if the container is deliberately recreated for an image upgrade.

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
./build.sh          # Build image on a connected development machine
./run.sh --vendor-dir /absolute/path/to/customer-artifacts --accept-microsoft-eula
                    # Create/reuse container and install staged RPMs locally
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
- If the container does not exist, run `deployment/run.sh --vendor-dir /absolute/path/to/customer-artifacts --accept-microsoft-eula` before `deployment/start.sh`.

## Notes for maintainers

For day-to-day migration work, most users only need to understand:

1. `deployment/` scripts for container lifecycle
2. `sdcli-scripts/config.yaml` for migration settings
3. password environment variables
4. `sdcli-scripts/migrate.sh` commands
5. each run's `autokit/` and `sdcli/` output directories

The helper files under `sdcli-scripts/lib/` are used internally to make generated BCP, SQL*Plus, and SQL*Loader steps run consistently. Most users should not need to modify them.
