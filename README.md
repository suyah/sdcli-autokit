# sdcli-scripts

Simplified SQL Server to Oracle migration runner built around SQL Developer CLI (`sdcli`) and a Podman-based container environment. The repo provides:

- container lifecycle scripts for building and running the migration environment
- a one-time repository initialization flow
- repeatable migration execution for named migrations in `config.yaml`
- logging and run artifacts for each execution


## What this project does

This project assumes:

- **source** database is **SQL Server**
- **target** database is **Oracle**
- **migration repository** is **Oracle**

The main migration entrypoint is:

```bash
./migrate.sh
```

The script reads from:

```bash
./config.yaml
```

and validates required fields before doing any work.

## Repository layout

- `build.sh` - builds the container image and ensures the named Podman volume exists
- `run.sh` - creates or reuses the container, installs SQL Developer if needed, downloads the JTDS driver if needed, and copies `sdcli-scripts` into the container if missing
- `start.sh` - starts an existing stopped container
- `stop.sh` - stops a running container
- `migrate.sh` - validates config, creates SDCLI connections, initializes the migration repository, and runs migration phases
- `config.yaml` - migration definitions and defaults
- `Dockerfile` - container image definition

## Setup overview

There are **two separate setup layers**:

1. **Container environment setup**  
   Build the image and create/start the reusable container.

2. **Migration repository setup**  
   Register the SQL Server driver and initialize the Oracle migration repository inside SDCLI.

You usually do **container setup once**, **repository setup once**, and then run migrations as needed.

---

## 1) Container setup

### Prerequisites

Host requirements:

- Podman package installed
- network access to:
  - download Linux base image and required packages (this can be removed after containter started)
  - source SQL Server
  - target Oracle database

### Required `.env` file

All container helper scripts expect a `.env` file in the same directory as the scripts. No need to modify unless you would like to custimize it.

### First-time build and run

```bash
./build.sh
./run.sh
```

What these scripts do today:

#### `./build.sh`

- reads required values from `.env`
- builds the image from `Dockerfile`
- creates the Podman volume if it does not already exist

#### `./run.sh`

- creates the container if missing, or reuses the existing one
- starts the container if it already exists but is stopped
- download and installs SQL Developer into `$SD_HOME/sqldeveloper` if not already present in the mounted volume
- downloads `jtds-1.3.1.jar` into `$SD_HOME/jlib` if not already present
- copies `sdcli-scripts` into `${HOME_DIR}/sdcli-scripts` inside the container **only if those files are not already there**

### Daily container operations

After the first setup, use:

```bash
./start.sh
./stop.sh
```

Behavior:

- `./start.sh` starts an existing stopped container and exits cleanly if it is already running
- `./stop.sh` stops a running container and exits cleanly if it is already stopped or does not exist

### Important note about script updates

`run.sh` only copies `sdcli-scripts` into the container when they are missing. If you update `migrate.sh` or `config.yaml` in your working copy, rerunning `./run.sh` alone will **not** refresh those files inside the container if they already exist there.

If you need the container copy updated, re-copy the files manually or recreate/remove the container-side copy before rerunning `./run.sh`.

---

## 2) Migration configuration

The migration runner uses:

```bash
./config.yaml
```

This file has to be modified for your migration repository and source/target DB information.


### Password format requirement

All password fields in `config.yaml` must use **environment variable placeholders**, not literal passwords.

Valid example:

```yaml
password: "${SOURCE_PASSWORD}"
```

Invalid example:

```yaml
password: "Welcome1"
```

At runtime, `migrate.sh` resolves each placeholder from the current shell environment. If the referenced environment variable is unset or empty, the script fails.

### Source connection format

For SQL Server source connections, the script expects:

```text
host:port:database
```

Example:

```text
10.0.1.165:1433:tpcc
```

### BCP TLS mode

bcp_tls_mode controls what extra TLS-related flags the wrapper adds when running bcp during the offload phase. This is needed because different SQL Server environments have different encryption and certificate requirements.

Supported values for:

```yaml
defaults:
  source:
    bcp_tls_mode:
```

are:

  - `strict` - add no extra flags. Use this when the environment already has the correct TLS/certificate setup and you want bcp to fail on any TLS issue.
  - `trust` - add -u if it is not already present. Use this when SQL Server encryption is enabled but the server certificate may not be fully trusted by the client host.
  - `optional` - add -Y o if it is not already present. Use this when you need maximum compatibility with environments where encryption behavior is inconsistent.

Current config uses:

```yaml
trust
```
So during offload, the wrapper will currently add -u to the generated bcp command unless that flag is already present.

---

## 3) Make migration passwords available

Before running `migrate.sh`, export the environment variables referenced by `config.yaml`.

Example:

```bash
export MIGRATION_REPO_PASSWORD='...'
export MIGRATION_SUPER_PASSWORD='...'
export SOURCE_PASSWORD='...'
export TARGET_PASSWORD='...'
```

This is required for:

- `--init`
- connection setup
- full migrations
- most phase runs that need source/target credentials

---

## 4) Initialize the migration repository

This step is easy to miss, so here is the recommended sequence.

### Run this once before your first migration

```bash
./migrate.sh --init
```

What `--init` does:

1. registers the SQL Server driver using `defaults.driver_file`
2. initializes the Oracle migration repository using the values under `migration_repository.*`

Specifically, the script runs these SDCLI actions:

- `driver`
- `init`

### What `--init` requires

From your shell environment:

- `MIGRATION_REPO_PASSWORD`
- `MIGRATION_SUPER_PASSWORD`

### Recommended first-run sequence

For a new environment, use this order:

```bash
./build.sh
./run.sh

export MIGRATION_REPO_PASSWORD='...'
export MIGRATION_SUPER_PASSWORD='...'
export SOURCE_PASSWORD='...'
export TARGET_PASSWORD='...'

./migrate.sh --init
./migrate.sh tpcc --conn-setup
./migrate.sh tpcc --migrate
```

---

## 5) Run migrations

## Usage

```bash
./migrate.sh --init [options]
./migrate.sh <migration_name> [options]
```

### Supported modes

Exactly one mode may be used at a time:

- default full flow (no mode flag)
- `--init`
- `--conn-setup`
- `--phase <name>`
- `--migrate`

Migration name is required for every mode **except** `--init`.

### Default full flow

```bash
./migrate.sh tpcc
```

Current behavior:

1. create source connection `src_tpcc`
2. create target connection `tgt_tpcc`
3. run:
   - `capture`
   - `convert`
   - `generate`
   - `datamove`
   - `offload`

The model name used for the run is:

```text
<migration_name>_<run_id>
```

Example:

```text
tpcc_20260422_153000
```

### Connection setup only

Use this when you want to validate credentials and create SDCLI connections without starting a migration.

```bash
./migrate.sh tpcc --conn-setup
```

This runs only:

- source `mkconn`
- target `mkconn`

Connection names are generated automatically:

- source: `src_<migration_name>`
- target: `tgt_<migration_name>`

### Single phase mode

Use this to run exactly one phase:

```bash
./migrate.sh tpcc --phase capture
./migrate.sh tpcc --phase convert
./migrate.sh tpcc --phase generate --model latest
./migrate.sh tpcc --phase datamove --model latest
./migrate.sh tpcc --phase offload --model latest
```

Supported phase names:

- `capture`
- `convert`
- `generate`
- `datamove`
- `offload`

Model behavior:

- `capture` defaults to `<migration_name>_<run_id>`
- `convert`, `generate`, `datamove`, and `offload` default to `latest`
- `--model <name>` is allowed only with `--phase`

Current connection behavior in phase mode:

- `capture` ensures source and target connections exist before running
- `generate` ensures source and target connections exist before running
- `convert`, `datamove`, and `offload` do **not** create connections automatically

### Explicit migrate mode

```bash
./migrate.sh tpcc --migrate
```

This performs the same five migration phases as the default full flow:

- `capture`
- `convert`
- `generate`
- `datamove`
- `offload`

and also ensures source and target connections exist first.

### Dry run mode

The current script also supports:

```bash
./migrate.sh tpcc --migrate --dry-run
```

or:

```bash
./migrate.sh --init --dry-run
```

`--dry-run`:

- validates arguments and config
- logs the commands that would run
- does not execute `sdcli`
- does not execute BCP offload scripts
- substitutes placeholder secret text when necessary for rendering commands safely

This is useful for validating config and command construction before a real run.

---

## 6) How the migration phases work

### Full migration order

For full/default migration runs, the script executes:

```text
capture -> convert -> generate -> datamove -> offload
```

### Phase details

#### `capture`

Runs:

```text
sdcli migration -actions=capture
```

Uses:

- repository connection name from `migration_repository.repo_user.connection_name`
- source SDCLI connection name `src_<migration_name>`
- model `<migration_name>_<run_id>` by default
- project name `<migration_name>`

#### `convert`

Runs:

```text
sdcli migration -actions=convert
```

Uses:

- repository connection name
- model `latest` by default in phase mode

#### `generate`

Runs:

```text
sdcli migration -actions=generate
```

Uses:

- repository connection name
- destination connection `tgt_<migration_name>`
- model `latest` by default in phase mode

#### `datamove`

Runs:

```text
sdcli migration -actions=datamove
```

Uses:

- repository connection name
- model `latest` by default in phase mode

#### `offload`

This phase does **not** call `sdcli`.

Instead, the script:

1. looks for `MicrosoftSQLServer_data.sh` under the run's `datamove` output directory
2. creates a wrapper around `bcp`
3. applies the configured TLS behavior from `defaults.source.bcp_tls_mode`
4. executes the generated offload script with source host, port, username, and password

---

## 7) Logs and outputs

Each run creates a unique run id:

```text
YYYYMMDD_HHMMSS
```

Using current defaults, the output locations are:

### Main run log

```text
/u01/data/sdcli-autokit/logs/migrate_<run_id>.log
```

### Per-run directory

```text
/u01/data/sdcli-autokit/runs/run_<run_id>/
```

### Files written per run

- `sdcli_commands.log`
- `sdcli_commands_summary.txt`
- `migration_summary.csv`

### Per-migration output

Within a run directory, each migration gets its own subdirectory:

```text
/u01/data/sdcli-autokit/runs/run_<run_id>/<migration_name>/
```

---

## 8) Quick reference

### One-time environment setup

```bash
./build.sh
./run.sh
./migrate.sh --init
```

### One-time per migration setup

```bash
./migrate.sh tpcc --conn-setup
```

### Full migration

```bash
./migrate.sh tpcc --migrate
```

or simply:

```bash
./migrate.sh tpcc
```

### Single phase

```bash
./migrate.sh tpcc --phase capture
./migrate.sh tpcc --phase convert --model latest
./migrate.sh tpcc --phase generate --model latest
./migrate.sh tpcc --phase datamove --model latest
./migrate.sh tpcc --phase offload --model latest
```
