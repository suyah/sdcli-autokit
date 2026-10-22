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

This release supports Oracle SQL Developer 26.2 only. Other SQL Developer
versions are not validated because their CLI output and generated SQL layout
may differ.

> **Supported database pair:** this release supports only SQL Server sources
> and Oracle targets. Although `config.yaml` contains source and target `type`
> fields, any other pair is rejected during configuration preflight before the
> runner connects to a database or creates run artifacts. Additional source
> RDBMS adapters are planned, but are not implemented in this release.

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
├── config.example.yaml
├── lib/
│   ├── bcp
│   ├── generate_validation_report.py
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
| `config.example.yaml` | Neutral configuration template shipped in source and offline bundles. |
| `config.yaml` | Compatibility link to the customer configuration stored on the persistent `/u01/data` volume; it is intentionally not tracked or bundled. |
| `migrate.sh` | Main migration command. It validates config, initializes the repository, creates connections, runs phases, and writes run logs. |
| `lib/` | Helper programs used internally for BCP, SQL*Plus, SQL*Loader, and validation-report generation. Bash owns database execution; the existing Python standard-library renderer only converts validation TSV evidence into HTML/text reports. |

## Prerequisites

On the host machine, you need:

- Podman installed on the customer VM; Podman or Docker/Rancher Desktop on the connected build machine
- network access to the source SQL Server database
- network access to the target Oracle database
- a `.env` file in the `deployment/` directory for container settings

The connected build machine needs internet access for the base image, `yq`, jTDS,
and the pinned SQLcl 26.2.2 ZIP. The customer VM does not need registry or
software-repository access. Its `.env` contains the container, image repository,
separate data/log volume, and user/path settings; it has no package download URLs.

### Customer-provided proprietary artifacts for offline installation

The offline bundle does not distribute Oracle SQL Developer, Oracle Instant Client, Microsoft ODBC Driver, or Microsoft SQL Server command-line tool binaries. The customer obtains the required packages through its approved vendor account or internal software repository, accepts the applicable terms, and transfers them separately to the isolated environment.

The image does include Oracle SQLcl 26.2.2 for DBA connectivity and diagnostic
work; migration orchestration continues to use SQL Developer CLI 26.2. SQLcl is
redistributed unmodified under Oracle Free Use Terms and Conditions (FUTC). The
customer bundle includes the FUTC copy at `licenses/ORACLE-FUTC.txt`; the image
also preserves SQLcl's `LICENSE.txt` and `NOTICES.txt` under
`/usr/share/licenses/sqlcl/`.

| Required software | Customer download source | Files to stage |
| --- | --- | --- |
| Oracle SQL Developer 26.2 | [Oracle SQL Developer downloads](https://www.oracle.com/database/sqldeveloper/technologies/download/) | SQL Developer 26.2 Linux `noarch` RPM. |
| Oracle Instant Client | [Oracle Instant Client for Linux x86-64 downloads](https://www.oracle.com/database/technologies/instant-client/linux-x86-64-downloads.html) | Matching Oracle Linux 9 `x86_64` RPMs: Basic, SQL*Plus, and Tools. |
| Microsoft ODBC Driver 18 and SQL Server command-line tools | [Microsoft offline installation guidance for `mssql-tools18` and `msodbcsql18`](https://learn.microsoft.com/en-us/sql/linux/install-upgrade/setup-tools?view=fabric#offline-installation) | Matching `x86_64` RPMs for `msodbcsql18` and `mssql-tools18`, plus any documented dependencies. The customer must accept the Microsoft EULA. |

Place these files, plus any RPM dependencies reported by the offline install, in a customer-controlled directory such as:

```text
customer-artifacts/
├── sqldeveloper-26.2.<build>.noarch.rpm
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

The publisher builds the container **online** because the image build downloads
its base packages, `yq`, and jTDS. The customer installation is **offline**:
the customer only downloads the finished bundle, loads `image.tar`, and stages
its separately obtained vendor RPMs and wallet.

On a connected Linux/amd64 publisher host, create a release candidate bundle:

~~~bash
./release/release.sh 1.1.0 --verify --rebuild
~~~

The default command, `./release/release.sh 1.1.0`, only packages a previously
validated local image; it does not rebuild or run tests. It refuses an image
whose version, Git commit, or platform provenance does not match the current
source. Maintainers should follow the engineering-only
[release process](docs/release-process.md) before creating a customer bundle.
First merge the small release-notes PR: it moves all `Unreleased` entries into
the chosen version and leaves `Unreleased` empty. The release command rejects
a bundle when that step has not happened.

The scripts prefer Podman when both tools are installed. To build with Rancher Desktop/Docker explicitly, use:

~~~bash
CONTAINER_ENGINE=docker ./release/release.sh 1.1.0 --verify --rebuild
~~~

Rancher Desktop must be running with its Docker engine available before starting the build.

Transfer `dist/sdcli-autokit-1.1.0-linux-amd64.tar.gz` and its adjacent `.sha256` file through any approved cloud, on-premises, or physical method. On the customer VM:

~~~bash
sha256sum -c sdcli-autokit-1.1.0-linux-amd64.tar.gz.sha256
tar -xzf sdcli-autokit-1.1.0-linux-amd64.tar.gz
cd sdcli-autokit-1.1.0-linux-amd64
podman load -i image.tar
./deployment/run.sh --vendor-dir /absolute/path/to/customer-artifacts --accept-microsoft-eula
~~~

The EULA flag records the operator's acknowledgement required for the Microsoft packages; it does not replace the vendor terms. On a system where SELinux labels are not applicable, remove `,Z` from the three `-v` options in `deployment/run.sh`.

Every successful `run.sh` invocation refreshes the bundled program files but
preserves an existing customer configuration byte-for-byte. The durable file
is `/u01/data/sdcli-autokit/config/config.yaml`; the familiar
`/home/sduser/sdcli-scripts/config.yaml` path is a symbolic link to it. On a
first install the durable file is created from `config.example.yaml`. Existing
configurations from an older container are moved there automatically. The
installed program version is recorded in
`/home/sduser/sdcli-scripts/.autokit-script-version`.

Each migration has an independent SQL Developer 26.2 profile under
`/u01/data/sdcli-autokit/profiles/<migration>`. The runner passes that directory
to every SDCLI process through `IDE_USER_DIR`. Saved connections, the default
repository and encryption metadata are not shared between projects.
The old `/u01/data/sdcli-autokit/sqldeveloper` directory and its
`/home/sduser/.sqldeveloper` compatibility link are preserved for backup and
rollback only; migration connections and repository selection are not imported
from them. The SDK launcher may still inspect HOME/launcher settings. All
persistent configuration and profiles remain on the existing `/u01/data` volume.

### Upgrade an existing offline installation

Use this procedure when replacing a running release such as `1.0.0` with a
newer offline bundle such as `1.1.0`. Schedule a maintenance window: do not
upgrade while a migration command is running. The procedure preserves the
named Podman volumes that contain `/u01/data` and `/u01/log`; therefore it
keeps the customer configuration, wallet, SQL Developer preferences, and
existing project/run artifacts. Before replacing the container, back up the
complete old profile and configuration (not just `connections.json`):

```bash
podman exec --user sduser sdcli-autokit bash -lc '
  set -euo pipefail
  umask 077
  backup="/u01/data/sdcli-autokit/backups/pre-upgrade-$(date +%Y%m%d_%H%M%S)"
  mkdir -p "$backup"
  tar -czf "$backup/sqldeveloper.tar.gz" -C /home/sduser/.sqldeveloper .
  cp -p /home/sduser/sdcli-scripts/config.yaml "$backup/config.yaml"
  printf "Backup: %s\n" "$backup"
'
```

Keep the old bundle/image for rollback. Protect these backups: they include
saved credentials and their encryption metadata.

Download the new bundle and its adjacent checksum file to a new directory; do
not overwrite the directory that held the old bundle. Then verify, extract,
and load the new image:

```bash
sha256sum -c sdcli-autokit-1.1.0-linux-amd64.tar.gz.sha256
tar -xzf sdcli-autokit-1.1.0-linux-amd64.tar.gz
cd sdcli-autokit-1.1.0-linux-amd64
podman load -i image.tar
```

Run the **new bundle's** `run.sh` once, using the same customer artifact
directory as the existing installation:

```bash
./deployment/run.sh --vendor-dir /absolute/path/to/customer-artifacts --accept-microsoft-eula
```

When an old `sdcli-autokit` container exists, this first invocation deliberately
exits after printing an image-version mismatch. Before it exits, it moves any
legacy home-directory configuration and preferences into the persistent
`/u01/data/sdcli-autokit` location. This message is the expected upgrade
checkpoint, not an installation failure.

Remove only the old container, then run the same command again from the new
bundle directory:

```bash
podman stop sdcli-autokit
podman rm sdcli-autokit

./deployment/run.sh --vendor-dir /absolute/path/to/customer-artifacts --accept-microsoft-eula
```

Do **not** remove Podman volumes and do not run a broad pruning command such
as `podman system prune` as part of this procedure. Verify the result:

```bash
podman ps --filter name=sdcli-autokit
podman exec --user sduser sdcli-autokit cat /home/sduser/sdcli-scripts/.autokit-script-version
podman exec --user sduser sdcli-autokit readlink /home/sduser/sdcli-scripts/config.yaml
```

The script version should be the new release version, and the configuration
link should resolve to `/u01/data/sdcli-autokit/config/config.yaml`.
When upgrading from a shared-profile release, initialize each new project
profile, then recreate its source/target connections:

```bash
# Inside the container, with the configured password variables exported:
cd ~/sdcli-scripts
./migrate.sh tpcc --init
./migrate.sh tpcc --conn-setup
```

Repeat for each configured migration. Existing repositories/models and run/data
artifacts are retained; this transition does not require recapture or data reload.
Deploy the complete `sdcli-scripts/` directory, including `lib/` and `templates/`;
replacing `migrate.sh` alone is insufficient. Resume with the original `--run` id.
If you
manually changed program files under `~/sdcli-scripts` in the old container,
save those changes first: an upgrade replaces bundled program files, while
preserving customer data.

For rollback, stop migration activity and use the previous bundle/image with
the preserved volumes and complete old shared profile. Do not replace only
`connections.json`, merge profiles, or delete the new profiles/repository.
Restoring program/profile files does not undo database DDL.

## Configure `config.yaml`

The migration runner reads migration settings through the compatibility path:

```bash
sdcli-scripts/config.yaml
```

The actual persistent file is
`/u01/data/sdcli-autokit/config/config.yaml`. Editing either path changes the
same file.

In an offline container, `run.sh` creates this file automatically on the first
install. In a source checkout, create it yourself before running a migration:

```bash
cp sdcli-scripts/config.example.yaml sdcli-scripts/config.yaml
```

The main sections are:

| Section | Purpose |
| --- | --- |
| `defaults` | Shared settings such as driver path, output project root, source/target type, and load/offload preferences. |
| `migration_repository` | Shared repository credential template and repository connection-name prefixes. |
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
  # Used only by the no-name --show-datatype-mapping command. Named migration
  # commands use the selected migration's target.conn instead.
  conn: tcps://your-repo-host:1522/your_repo_service?ssl_server_dn_match=yes
  repo_user:
    # Prefix: tpcc uses migration_repo_tpcc.
    connection_name: migration_repo
    user: migrep
    password: "${MIGRATION_REPO_PASSWORD}"
  super_user:
    # Prefix: tpcc uses super_migration_tpcc.
    connection_name: super_migration
    user: admin
    password: "${MIGRATION_SUPER_PASSWORD}"

migrations:
  - name: tpcc
    source:
      conn: sqlserver.example.internal:1433:tpcc
      user: sa
      password: "${SOURCE_PASSWORD}"
    target:
      conn: tcps://your-target-host:1522/your_target_service?ssl_server_dn_match=yes
      # Optional target-specific mTLS wallet; otherwise defaults.target.wallet_dir.
      # wallet_dir: /u01/data/sdcli-autokit/wallets/Wallet_tpcc
      user: admin
      password: "${TARGET_PASSWORD}"
      default_schema_password: "${MIGRATED_SCHEMA_PASSWORD}"
```

For an Autonomous Database wallet, set `defaults.target.wallet_dir` to the
unpacked wallet directory, or set `migrations[].target.wallet_dir` when a
target needs a different wallet. Use the full `tcps://host:port/service?...`
URL in each named migration's `target.conn`. SQLcl can resolve a wallet TNS alias such as
`myadb_high`, but SQL Developer 26.2's `sdcli migration -actions=mkconn`
does not resolve that alias inside `-connDetails`; using it produces
`ORA-17870` even when the wallet is valid.

For each invocation the runner removes inherited `oracle.net.tns_admin`
properties from Java option variables before applying the selected configured
wallet. With no configured wallet it clears inherited wallet/TNS settings.
Unrelated JVM options remain intact; your parent shell is unchanged. Configure
wallets in YAML rather than relying on a previous project's exports.

SDCLI commands have no timeout by default because metadata capture can take a
long time over a high-latency database connection. Set
`SDCLI_COMMAND_TIMEOUT_SEC` before running `migrate.sh` when an operator wants
a bounded run, for example `SDCLI_COMMAND_TIMEOUT_SEC=1800`.

Before a source connection is created or metadata is captured, the script tests
the configured SQL Server `host:port` from inside its execution environment.
This prevents SQL Developer's JTDS driver from waiting on a dropped TCP
connection. The default preflight limit is 10 seconds; set
`SDCLI_CONNECT_TIMEOUT_SEC` to use a different positive limit.

Keep credentials in environment-variable placeholders as shown above. Their
values are redacted from SDCLI console output, command summaries, and run logs.

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

The migration name is used to select the matching config entry, create source
and target connection names such as `src_tpcc` and `tgt_tpcc`, derive
repository names `migration_repo_tpcc` and `super_migration_tpcc`, create the
run directory, and create a run-specific capture model such as
`tpcc_20260427_014117`. Its `target.conn` is also the endpoint used for that
migration's SQL Developer repository.

The values under `migration_repository.repo_user` and `.super_user` are shared
credentials and name prefixes. `migration_repository.conn` is retained only
for the repository-wide `./migrate.sh --show-datatype-mapping` command with no
migration name; changing it does not change a named migration's target or
repository endpoint.

Use a normal privileged Oracle connection for `super_user`, such as the ADB
`admin` account or a PDB administrator with the required user/grant privileges.
Do not use a `SYSDBA` connection for SDCLI 26.2 `mkrepouser`: the vendor command
copies the super connection's properties, including its role, into the new
repository connection. On a multitenant database, select a PDB service rather
than the CDB root service.

For a large migration program, define one migration entry per source/target database pair. For example, 50 source databases usually means 50 migration entries with 50 unique migration names.

### Source connection format

SQL Server source connections use this format:

```text
host:port:database
```

Example:

```yaml
source:
  conn: sqlserver.example.internal:1433:tpcc
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

Set `defaults.target.wallet_dir` to that directory, or set the optional
`migrations[].target.wallet_dir` when a particular target needs its own
wallet. Keep every `migrations[].target.conn` in
`tcps://host:port/service?ssl_server_dn_match=yes` form, using the host, port,
and service name from the wallet's `tnsnames.ora` file. The migration launcher
sets both `TNS_ADMIN` for SQL*Plus/SQL*Loader and `oracle.net.tns_admin` for
SDCLI's JDBC connections.

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

Named `--init` bootstraps a fresh project profile and installs the preference
template before repository initialization. `FileOutputOption=1` keeps generated
SQL separated by object type. SQL Developer saves its own default repository
and encryption metadata; Autokit does not fabricate them or copy another
profile's saved credentials. Deployment startup checks use a disposable profile,
not the old shared preferences. Unknown existing preference files are left
unchanged.

For normal daily use after the container already exists:

```bash
./start.sh
./stop.sh
```

### 2. Review migration configuration

In `sdcli-scripts/`, update the generated `config.yaml` for your repository connection, source database, target database, migration name, password placeholder names, and optional load/offload preferences. Keep `config.example.yaml` unchanged so it remains a clean reference for later releases.

For an offline bundle, `run.sh` starts the container, synchronizes the program files on every invocation, and initializes `config.yaml` only when it is absent. You can then configure it interactively inside the running container:

```bash
podman exec -it --user sduser sdcli-autokit bash
cd ~/sdcli-scripts
vi config.yaml
```

Exit the shell after saving. Later `run.sh` upgrades preserve this configuration
and SQL Developer preferences in `/u01/data/sdcli-autokit`, including when the
container is deliberately removed and recreated. Keep an external backup of the
configuration as normal migration-operating practice.

When `run.sh` detects that an existing container uses another image, it first
migrates any legacy home-directory configuration and preferences into
`/u01/data/sdcli-autokit`, then exits. Remove the old container and rerun the
same command to create it from the new image; the persistent state is linked
back into `/home/sduser` automatically.

### 3. Set password variables

Export the password variables described in [Password variables](#password-variables).

### 4. Initialize the migration repository

Run once for each named migration target from `sdcli-scripts/`:

```bash
./migrate.sh tpcc --init
```

This registers the SQL Server driver and initializes (or registers an existing)
repository using `tpcc`'s `target.conn`. It creates the saved SQL Developer
aliases `super_migration_tpcc` and `migration_repo_tpcc`. With exactly one
migration in `config.yaml`, `./migrate.sh --init` remains supported and logs
the inferred name. With two or more migrations, a name is required.

The runner never edits `connections.json` or switches a shared
`DefaultRepository`. SDCLI manages these inside the selected project profile.
Other SDCLI phases require that project's init to have completed successfully.
A failed fresh init remains pending and can be retried. If the endpoint,
repository user or repository alias changes, back up and move aside that
project's whole profile during a maintenance window, then run named `--init`
and `--conn-setup` again. There is no silent fallback to an old target.
If saved repository credentials become unusable, SDCLI may fail before it can
replace them during init. After correcting the credentials, use the same
backup/move-aside/re-init procedure for that project only; do not delete an
individual preferences file or copy another project's connections.
Standalone use without `TOOL_DATA` places `profiles/` beside the configured
`defaults.paths.project_root` directory; use absolute paths.

Init requires SQL*Plus as well as SDCLI. After vendor init reports success,
the runner checks for the installation revision in `MD_REPOVERSIONS`, then
opens the saved repository from an independent SDCLI process. Every init
attempt stays pending until both checks pass, including re-init of an existing
profile. An interrupted install may leave database objects behind: ask the DBA
to complete/repair that installation before retrying. Autokit never drops or
recreates a repository automatically. Check `repository_init_check.sql` and
`repository_init_check.out` in the init run's `autokit/` directory for evidence.

## Typical migration workflow

### Migrate a new database

For a new source/target database pair, first add a new named entry under
`migrations:` in `config.yaml`, set its source and target connection details,
and export the password variables used by that entry. For Autonomous Database
mTLS, also make the wallet available and configure either the default or that
entry's `target.wallet_dir` as described in [Autonomous Database mTLS](#autonomous-database-mtls-wallet).
The runner sets `TNS_ADMIN` and `JAVA_TOOL_OPTIONS` for the selected wallet.

From `sdcli-scripts/`, use the following normal sequence. Replace `tpcc` with
the new migration name in `config.yaml`:

```bash
# Run only when this migration target's repository has not been initialized
# or registered under its derived aliases before.
./migrate.sh tpcc --init

# Recommended: it refreshes this migration's SDCLI connections, then runs
# capture through validation under one repository lock.
./migrate.sh tpcc --migrate
```

`--migrate` runs `capture -> convert -> generate -> datamove -> offload ->
deploy -> load -> postdeploy -> validate`. It is the preferred command for a
new migration because it keeps the model selection and repository lock
consistent. Use the [single-phase sequence](#run-a-single-phase) only for
recovery, inspection, or controlled manual execution after a failure.

To create or refresh the source and target SDCLI connections without starting
the migration, use the optional connection-only command:

```bash
./migrate.sh tpcc --conn-setup
```

`--conn-setup` saves or refreshes only `src_tpcc` and `tgt_tpcc`. It performs a
TCP reachability preflight for SQL Server; SDCLI also tests the Oracle login
while creating that connection. It does not initialize a repository or prove
source SQL Server authentication.

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

In plain language, this captures SQL Server metadata, converts it for Oracle,
generates scripts, exports data, deploys the Oracle schema objects needed before
load, loads data, attempts each independent post-load object script listed by
SQL Developer's generated `master.sql` files, and validates logs, per-table row
counts, and source/generated/target object coverage. Postdeploy continues after
individual SQL errors but stops on a SQL*Plus runtime failure. Validation also
creates self-contained HTML and plain-text comparison reports.

Each SDCLI workflow locks its project profile. Repository work also creates
an atomic lock under `<project_root>/.locks`, keyed by configured endpoint and
repository user (not connection alias). A full workflow resolves the unique
numeric captured and converted model indexes and passes those exact indexes to
later phases; it does not depend on mutable `latest` selection. Different
profiles with different repositories can run in parallel. A stale lock is not
removed automatically; inspect the owner before removing the reported lock
directory.

## Run a single phase

Use `--phase` for recovery or investigation. For a normal migration, prefer
one `--migrate` invocation: it holds the repository lock for the complete
workflow and selects the captured and converted models consistently.

For manual execution, keep every phase in the same run directory and use the
numeric SQL Developer model index associated with that run. SQL Developer does
not accept the captured model name (for example, `tpcc_20260427_014117`) as
`--model`.

```bash
# Capture creates the run and model name tpcc_<run id>.
./migrate.sh tpcc --phase capture
export RUN=20260427_014117

# Find the integer index for tpcc_<run id>, then use that index.
IDE_USER_DIR=/u01/data/sdcli-autokit/profiles/tpcc sdcli migration -actions=lscaptured
export CAPTURE_MODEL=<captured_model_index>
./migrate.sh tpcc --phase convert --run "$RUN" --model "$CAPTURE_MODEL"

# Find the integer index for the converted model created above.
IDE_USER_DIR=/u01/data/sdcli-autokit/profiles/tpcc sdcli migration -actions=lsconverted
export CONVERTED_MODEL=<converted_model_index>
./migrate.sh tpcc --phase generate --run "$RUN" --model "$CONVERTED_MODEL"
./migrate.sh tpcc --phase datamove --run "$RUN" --model "$CONVERTED_MODEL"

./migrate.sh tpcc --phase offload --run "$RUN"
./migrate.sh tpcc --deploy --run "$RUN"
./migrate.sh tpcc --phase load --run "$RUN"
./migrate.sh tpcc --phase postdeploy --run "$RUN"
./migrate.sh tpcc --phase validate --run "$RUN"
```

Supported phases:

| Phase | Purpose |
| --- | --- |
| `capture` | Read SQL Server metadata into the migration repository. It does not copy table rows. |
| `convert` | Transform the captured SQL Server model into an Oracle-compatible model and conversion report. |
| `generate` | Write the generated Oracle DDL and migration scripts to the run's `sdcli` directory. |
| `datamove` | Generate BCP export scripts and SQL*Loader control files. It does not transfer table rows. |
| `offload` | Run the generated BCP scripts to export data from SQL Server into the run directory. |
| `deploy` | Run generated Oracle schema setup required before loading data. It never runs cleanup statements. |
| `cleanup` | Explicitly remove only roles listed in the generated `role.sql`; it does not remove schemas, tables, or data. |
| `load` | Run SQL*Loader using the exported data and generated control files. |
| `postdeploy` | Attempt all non-predata scripts in generated master order, then run each schema's `post.sql`. Continue after individual SQL errors, but stop on a SQL*Plus runtime failure. |
| `validate` | Reconcile row counts, collect source and target object metadata, compare source/generated/actual objects, and create HTML and plain-text validation reports. |

### Data movement mode

This tool uses SQL Developer's **offline** data-movement flow: `datamove`
generates BCP and SQL*Loader files, `offload` exports from SQL Server, and
`load` imports into Oracle. It does not insert table rows directly from SQL
Server through JDBC.

SQL Developer's graphical migration workflow also provides an online data move
that connects to both databases through JDBC. It is intended for smaller data
sets; the offline method is the appropriate default for larger migrations and
for customer environments where the migration host must work without Internet
access.

### Deployment and role cleanup

`--deploy` is a shorthand for `--phase deploy`. The automated execution plan
excludes SQL Developer's known cleanup files. If SQL Developer generated
`role.sql`, the runner creates a setup-only copy under the run's
`autokit/deploy/` directory and executes the `CREATE ROLE` and other setup
statements, not active `DROP ROLE` statements. The original generated file is
not changed.

Use cleanup only when you intentionally need to remove those generated roles,
for example before retrying a partially completed deployment:

```bash
./migrate.sh tpcc --cleanup --run "$RUN"
./migrate.sh tpcc --deploy --run "$RUN"
```

`--cleanup` requires `--run`, writes an executable role-only cleanup script
under `autokit/cleanup/`, and ignores a missing role so it can safely finish a
partial role cleanup. It does **not** run SQL Developer's separately generated
schema cleanup files such as `dropallschemas.sql` or `dropobjects.sql`; those
can delete schemas or data and remain excluded from automated execution.

The role split is deliberately limited to SQL Developer's generated
one-statement-per-line `role.sql` format and understands SQL line and block
comments. The autokit does not claim to parse arbitrary SQL or PL/SQL to detect
every possible destructive statement; review generated migration DDL before
running it in a target environment.

Automated deploy supports only SQL Developer's tested flat per-schema layout:
each schema directory must contain `user.sql` and `master.sql`, and executable
schema files must be directly accounted for by that master plan. A monolithic
`gen/*.sql`-only output or nested generated SQL directory is rejected before
SQL*Plus runs; review or execute an unsupported layout manually instead of
asking the autokit to guess its semantics.

### SQL Developer Emulation schema

`Emulation` is a generated target schema, not the migration repository or an
internal schema used only while SQL Developer is running. For SQL Server
migrations, SQL Developer can place its compatibility `UTILS` package in a
separate `EMULATION` schema and generate synonyms and converted code that
reference it. Oracle describes a separate emulation schema as the usual best
practice because the package is maintained once instead of being copied into
every migrated schema. See [Oracle SQL Developer migration preferences](https://docs.oracle.com/en/database/oracle/sql-developer/21.4/rptug/sql-developer-concepts-usage.html).

The runner does not hard-code `Emulation`: it deploys any generated schema
directory containing `user.sql`. Therefore, if SQL Developer generated an
`Emulation/` directory, do not exclude it unless the converted scripts have
also been regenerated without references to `EMULATION.UTILS`. If no
`Emulation/` directory is generated, the runner has nothing to deploy for it.

### Model and run behavior

For normal use:

- `capture` creates a new model using `<migration_name>_<run_id>`.
- `convert`, `generate`, and `datamove` accept only `latest` or a numeric SQL Developer model index; a model name is not valid.
- A full `--migrate` workflow resolves and pins the unique numeric index after capture and convert. For manual phases, use the numeric index from `lscaptured` or `lsconverted`, not `latest`.
- `--run <run_id>` reuses an existing run directory. Supply it for every manual phase after `capture`.

Use `--run` when rerunning phases that depend on files already generated in a previous run, such as `deploy`, `load`, `postdeploy`, or `validate`.

If `postdeploy` finds generated SQL errors, it continues with independent
post-data scripts and runs `post.sql` so Oracle can compile and report object
status. It still exits nonzero and records each outcome in
`autokit/deploy_manifest.tsv`. A retry skips previously successful post-data
scripts, retries failed scripts, and runs each schema's `post.sql` again.

Locks are local to the shared data/project volume, not distributed across
independent installations. Separate manual commands do not reserve a model
between invocations. Use the same configured endpoint spelling and repository
user for a shared repository; aliases resolving to the same DB are not
automatically discovered. Raw SDCLI calls must select `IDE_USER_DIR` as above
and must not run concurrently with Autokit on that profile/repository.

Phase status is append-only. Repeating a mutating phase that already succeeded
is rejected by default. If the repeat is intentional, make it explicit:

```bash
./migrate.sh tpcc --phase load --run 20260427_014117 --rerun-completed
```

This flag does not clean or truncate the Oracle target. Before repeating
`deploy` or `load`, the operator remains responsible for making the target safe
for that operation. `validate` is read-only and may be repeated without the
flag.

### Inspect datatype mappings

Datatype mappings are operator reference data and are not part of migration
validation. Display the mappings persisted in the SQL Developer migration
repository with:

```bash
./migrate.sh --show-datatype-mapping
./migrate.sh proda --show-datatype-mapping
```

Without a migration name, the command lists every persisted project mapping in
the repository at `migration_repository.conn`. With a migration name, it uses
that migration's `target.conn` and derived repository connection, then filters
on the exact `MD_PROJECTS.PROJECT_NAME`. The installed repository schema stores mapping rows
per project; it does not expose a separate global-default mapping table. An
unknown project or a project with no persisted rules returns the TSV header and
no data rows.

The read-only output columns are project, map name, source datatype,
source precision/scale, target datatype, and target precision/scale. To align
them in a terminal:

```bash
./migrate.sh proda --show-datatype-mapping | column -t -s $'\t'
```

Before querying rules, the command checks that the installed SQL Developer
repository contains the supported tables and columns. An incompatible
repository version fails with an explicit unsupported-schema error; the tool
does not guess table layouts or parse generated DDL. Repository credentials
are passed to SQL*Plus through stdin and are not included in the TSV output.

### Automatic validation report

The full workflow runs validation automatically. To repeat it for an existing
run, use:

```bash
./migrate.sh tpcc --phase validate --run 20260427_014117
```

The SQL Server source and Oracle target must both be reachable from the
container while validation runs. The collector queries read-only system catalog
views. The SQL Server password is supplied to `sqlcmd` through
`SQLCMDPASSWORD`, and the Oracle password uses the existing SQL*Plus `/nolog`
connection path; neither password is written to report evidence or process
arguments.

When `--run` resumes an existing run directory, validation evaluates the
current generated, load, and target evidence. Earlier failed attempts remain in
`autokit/migrate.log` for audit but do not by themselves make a later, successful
retry fail validation. Errors produced by the current command and any failing
validation evidence still fail the command.

No manual row-count SQL or schema-mapping file is required. Table mappings are
derived from this run's BCP and SQL*Loader data-file evidence. Row comparison
uses the BCP exported count, SQL*Loader loaded/rejected/discarded counts, and the
final Oracle table count. This is preferable to recounting a live SQL Server
database later, when its data may have changed.

The offline `migration_report.html` and `migration_report.txt` contain the same
direct-evidence sections:

- validation summary and evidence health;
- table data reconciliation;
- deploy, postdeploy, and cleanup script outcomes;
- Oracle invalid objects and compiler errors;
- source and target inventory counts; and
- metadata coverage status.

`PASS` means all required evidence was collected and every evaluated check
passed. `FAIL` means a concrete mismatch, failed deployment script, or invalid
target object was found. Missing, malformed, not-run, or plan-only execution
evidence is reported as `INCOMPLETE` and causes the validate phase to fail.
Oracle compiler diagnostics count `ERROR` records; compiler warnings alone do
not make an object invalid.

The HTML report is a single local file with embedded styling; it does not load
internet resources. View the terminal-readable companion on the migration host
with `less autokit/migration_report.txt`. Reports can contain customer schema
names, object names, and compiler messages, so handle them as migration
evidence. A rerun atomically replaces completed reports rather than appending
duplicate rows. If rendering is interrupted, an existing complete report is
preserved, but the current validate command still fails.

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
| `autokit/migration_summary.csv` | Append-only high-level migration result summary. |
| `autokit/phase_status.tsv` | Append-only phase attempts and their final status. |
| `autokit/deploy_manifest.tsv` | Generated SQL inventory and scripts executed during deploy, postdeploy, and explicit cleanup. |
| `autokit/bcp_status.tsv` | Per-table SQL Server export status and exported row count. |
| `autokit/sqlldr_status.tsv` | Per-table Oracle load status, loaded/rejected/discarded counts, and paths. |
| `autokit/reconciliation.tsv` | Source-to-target per-table row reconciliation. Every row must be `PASS`. |
| `autokit/source_object_inventory.tsv` | Read-only SQL Server user-object inventory collected during validation. |
| `autokit/target_object_inventory.tsv` | Read-only Oracle inventory for generated target owners. |
| `autokit/validation_checks.tsv` | Normalized log, reconciliation, target-object, and metadata findings consumed by the validation reports. |
| `autokit/validation_summary.txt` | Final `PASS` or `FAIL` and issue totals. |
| `autokit/migration_report.html` | Self-contained direct-evidence report, also written for failed or incomplete validation. |
| `autokit/migration_report.txt` | Terminal-readable companion report with the same sections and findings. |
| `sdcli/` | SDCLI-generated scripts, logs, and data movement files. |

If you rerun a phase with `--run`, the new output is appended to the existing run log.

The validation report uses only structured evidence collected by the autokit:

- table export, load, and target row counts;
- deploy and postdeploy outcomes from `deploy_manifest.tsv`;
- Oracle invalid objects and compiler diagnostics from catalog queries;
- SQL Server and Oracle inventory counts; and
- evidence-health status for missing or malformed artifacts.

The report does not parse generated SQL to compare SQL Server and Oracle DDL.
Expected cross-database syntax differences are therefore not reported as
`DIFFERENT`, and object omissions are not guessed by matching generated file
text. Until a supported structured SQL Developer repository query provides an
object-level source-to-converted mapping, metadata conversion coverage is
shown as `NOT_EVALUATED`. This limitation is informational and is not by
itself a validation failure. SQL Server is the only source database supported
by the current validation collectors; additional source RDBMS adapters are
planned separately.

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
./migrate.sh <migration_name> --init
./migrate.sh --show-datatype-mapping
./migrate.sh <migration_name> --show-datatype-mapping
./migrate.sh <migration_name> --conn-setup
./migrate.sh <migration_name> --migrate
./migrate.sh <migration_name>
./migrate.sh <migration_name> --phase <phase_name>
./migrate.sh <migration_name> --phase <phase_name> --run <run_id>
./migrate.sh <migration_name> --phase <phase_name> --run <run_id> --rerun-completed
./migrate.sh <migration_name> --migrate --dry-run
```

## Troubleshooting tips

- Start with `autokit/migrate.log` for the full run history.
- Check `autokit/migration_summary.csv` for a quick status summary.
- Treat a migration as successful only when `validation_summary.txt` is `PASS`
  and the HTML report is `PASS`; every row in `reconciliation.tsv` must also be
  `PASS`.
- Check `sdcli/log/error.txt` when SDCLI phases fail.
- SDCLI success requires both exit code zero and the exact action completion
  marker, with no Oracle/SQL*Plus fatal diagnostic. The sole accepted diagnostic
  exception is repository `init` reporting existing-user `ORA-01920` together
  with its exact completion marker.
- Use `--dry-run` to confirm config and command construction before a real run.
- Run `--conn-setup` again if source or target connection details changed.
- Use `--run <run_id>` when rerunning a later phase against files from an existing run.
- If the container does not exist, run `deployment/run.sh --vendor-dir /absolute/path/to/customer-artifacts --accept-microsoft-eula` before `deployment/start.sh`.

## Notes for maintainers

For day-to-day migration work, most users only need to understand:

1. `deployment/` scripts for container lifecycle
2. `sdcli-scripts/config.example.yaml` as the shipped template and the local, untracked `config.yaml` for migration settings
3. password environment variables
4. `sdcli-scripts/migrate.sh` commands
5. each run's `autokit/` and `sdcli/` output directories

The helper files under `sdcli-scripts/lib/` are used internally to make generated BCP, SQL*Plus, and SQL*Loader steps run consistently. Most users should not need to modify them.
