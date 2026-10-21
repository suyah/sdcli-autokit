# Per-Migration Repository Context Design

## Purpose

Prevent one migration from silently using another target database's SQL
Developer migration repository while keeping `config.yaml` compact. Each named
migration must use repository and super-user connections that are unique to
that migration and point to that migration's Oracle target.

This change preserves the Bash-first, single-maintainer design. It introduces
one repository-context boundary in `migrate.sh`; it does not add a new service,
state store, or configuration hierarchy.

## Defect

The current configuration defines one global repository endpoint and two final
SQL Developer connection names:

```yaml
migration_repository:
  conn: tcps://repository-target/service
  repo_user:
    connection_name: migration_repo
  super_user:
    connection_name: super_migration
```

`migrate.sh` uses those values for every migration. SQL Developer persists the
connections in its user preferences, so initializing Proda leaves
`migration_repo` and `super_migration` pointing to Proda. Creating
`src_cecrealm` and `tgt_cecrealm` does not create Cecrealm repository
connections. A later Cecrealm workflow can therefore select the saved Proda
repository even when Cecrealm has a different target endpoint.

The defect affects repository initialization, repository locking, capture,
convert, generate, datamove, datatype-mapping queries, and any validation query
that reads the SQL Developer repository.

## Goals

1. Derive unique repository and super-user connection names for every named
   migration without repeating repository credentials inside every migration.
2. Use the selected migration's `target.conn` as its repository endpoint.
3. Require repository initialization to select a migration when the config
   contains more than one migration.
4. Allow a migration to select its own wallet with a one-line optional
   override.
5. Preserve existing repository schemas, models, run artifacts, and legacy
   saved connections during upgrade.
6. Fail before an SDCLI repository action if the migration-specific context
   cannot be resolved unambiguously.

## Non-goals

- Do not support one migration repository spanning different Oracle targets.
- Do not automatically delete, rename, or edit SQL Developer's
  `connections.json`.
- Do not copy or move repository tables between databases.
- Do not add per-migration copies of repository usernames and passwords.
- Do not add automatic repository creation to `--migrate`; initialization
  remains an explicit operator action.
- Do not add concurrent execution guarantees beyond the existing repository
  lock.

## Configuration contract

The existing global `migration_repository` structure remains the credential
and naming template:

```yaml
migration_repository:
  type: oracle
  name: repo
  conn: tcps://legacy-default/service

  repo_user:
    connection_name: migration_repo
    user: migrep
    password: "${MIGRATION_REPO_PASSWORD}"

  super_user:
    connection_name: super_migration
    user: admin
    password: "${MIGRATION_SUPER_PASSWORD}"
```

For a named migration, the two `connection_name` values are prefixes rather
than final names. Given migration `cecrealm`, the active names are:

```text
migration_repo_cecrealm
super_migration_cecrealm
```

The active repository endpoint is always
`migrations[].target.conn`, not `migration_repository.conn`. The global
repository usernames and password placeholders remain shared defaults. An
operator may export different values for those placeholders before running a
different migration; secrets remain outside the YAML file.

`migration_repository.conn` is retained for compatibility with the
repository-wide `--show-datatype-mapping` form that has no migration name. It
is not used by `--init`, `--migrate`, or migration phases once a migration has
been selected. Documentation must label this distinction so it cannot be
mistaken for the endpoint of every migration.

### Wallet selection

A migration may add one optional target field:

```yaml
migrations:
  - name: cecrealm
    target:
      conn: tcps://cecrealm-target/service
      wallet_dir: /u01/data/sdcli-autokit/wallets/Wallet_cecrealm
```

`migrations[].target.wallet_dir` takes precedence over
`defaults.target.wallet_dir`. If neither exists, the script preserves the
current non-wallet behavior. The selected path must pass the existing absolute
path and required-wallet-file checks.

## Repository context

The implementation will resolve one active repository context after selecting
the migration and before logging, locking, wallet configuration, or database
execution. The context contains:

| Value | Source |
| --- | --- |
| migration name | `migrations[index].name` |
| endpoint | `migrations[index].target.conn` |
| repository label | `migration_repository.name` |
| repository connection | `<repo_user.connection_name>_<migration name>` |
| super connection | `<super_user.connection_name>_<migration name>` |
| repository user/password | global `repo_user` template |
| super user/password | global `super_user` template |
| wallet | migration target override, then default target wallet |

Repository consumers must read this resolved context instead of independently
reading `.migration_repository.conn` or the unsuffixed connection names. This
applies to:

- repository initialization;
- repository lock identity;
- capture, convert, generate, and datamove;
- migration-scoped datatype mapping;
- repository SQL capture used by validation/reporting; and
- log messages and dry-run command construction.

The context is resolved once per process so a later helper cannot accidentally
select a different target.

## Command behavior

### Initialize a repository

The normal commands become:

```bash
./migrate.sh proda --init
./migrate.sh cecrealm --init
```

When exactly one migration is configured, `./migrate.sh --init` may infer that
sole migration for backward compatibility and must log the inferred name. When
more than one migration exists, omitting the name fails before driver or SDCLI
execution with an instruction to run `./migrate.sh <name> --init`.

Initialization constructs `-connDetails` with the selected target endpoint and
derived names. For Cecrealm this produces logical connections equivalent to:

```text
super_migration_cecrealm -> Cecrealm target as admin
migration_repo_cecrealm  -> Cecrealm target as migrep
```

### Full and phased migrations

`--migrate` and every repository-backed phase use the derived repository name
for the selected migration. Source and target connection naming remains
unchanged:

```text
src_cecrealm
tgt_cecrealm
migration_repo_cecrealm
super_migration_cecrealm
```

`--conn-setup` continues to create or refresh only `src_<migration>` and
`tgt_<migration>`. Its success message must continue to describe saved
connection definitions rather than imply that repository initialization has
occurred.

### Datatype mapping

`./migrate.sh cecrealm --show-datatype-mapping` selects the Cecrealm repository
context and filters the repository output to that migration as it does today.
The no-name form retains its existing global/default repository behavior using
`migration_repository.conn`; it is informational and is not used by a
migration workflow.

## Locking and run layout

The repository lock identity is the derived repository connection name plus
the selected target endpoint. Proda and Cecrealm therefore cannot share a lock
by accident. Two commands targeting the same migration repository continue to
contend for the same atomic lock.

Initialization evidence is stored under a migration-specific path:

```text
<project_root>/_init/<migration>/run_<id>/
```

This prevents initialization logs for different targets from being presented
as one undifferentiated `_init` history.

## Upgrade compatibility

Existing unsuffixed SQL Developer connections are left untouched. The script
must not edit or delete `connections.json`, and it must never remove the
database repository user or tables.

After upgrading, the operator runs the new migration-specific initialization:

```bash
./migrate.sh proda --init
```

SQL Developer then registers `super_migration_proda` and
`migration_repo_proda` against the existing Proda endpoint. If the `MIGREP`
user already exists, the existing tightly-scoped idempotent rule applies:
`ORA-01920` is acceptable only when `init` also prints its exact completion
marker and no other fatal diagnostic. Existing repository models remain in the
database and become accessible through the new connection alias.

The same command for a new Cecrealm target creates
`super_migration_cecrealm`, `migration_repo_cecrealm`, and the Cecrealm
repository schema. A failure for one target cannot fall back to an unsuffixed
legacy connection or another migration's derived connection.

Existing migration run directories remain valid because models are stored in
the unchanged repository schema and run files remain under `/u01/data`. A
later phase resumes using the new alias that points to the same repository
endpoint and user.

## Validation and failure behavior

| Condition | Required result |
| --- | --- |
| Multiple migrations and `--init` has no name | Fail before SDCLI and show the required syntax. |
| Selected migration does not exist | Fail before wallet, lock, or SDCLI work. |
| Derived repository or super name is empty | Fail configuration validation. |
| Selected target endpoint is missing | Fail configuration validation. |
| Per-migration wallet is invalid | Fail before SDCLI and identify the exact config path. |
| Repository initialization fails | Do not fall back to an unsuffixed or other migration connection. |
| Existing repository user returns only the accepted idempotent init result | Register/use the derived alias without deleting existing repository data. |
| Two workflows select the same repository context | The second fails on the existing atomic lock. |
| Two workflows select different targets | Their lock identities and connection names differ. |

No password, encrypted saved-password value, or raw `connections.json`
content is added to logs or run evidence.

## Implementation boundaries

Keep the change concentrated in:

- `sdcli-scripts/migrate.sh` for context resolution and command behavior;
- `sdcli-scripts/config.example.yaml` for comments and the optional wallet
  override example;
- focused shell tests for config selection, init command construction,
  locking, datatype mapping, and compatibility; and
- `README.md` plus the engineering changelog.

Do not add Python or parse generated SQL. Do not introduce a second config
loader. Existing `yq` access helpers remain the configuration boundary.

## Test strategy

1. Add a two-migration fixture whose targets and wallets differ.
2. Assert `proda --init` emits only `migration_repo_proda`,
   `super_migration_proda`, and the Proda endpoint.
3. Assert `cecrealm --init` emits only `migration_repo_cecrealm`,
   `super_migration_cecrealm`, and the Cecrealm endpoint.
4. Assert a multi-migration no-name `--init` fails before fake SDCLI is called;
   assert a single-migration config still infers its only migration.
5. Assert full and manual repository phases receive the matching derived
   repository name.
6. Assert the per-migration wallet overrides the default and an invalid path
   fails before SDCLI.
7. Assert repository locks differ for different target endpoints and collide
   for the same active context.
8. Preserve the existing `ORA-01920` idempotent test and extend it to the
   derived connection names.
9. Assert an initialization failure never retries with the unsuffixed legacy
   names.
10. Assert migration-scoped datatype mapping and repository SQL capture use
    the selected target endpoint.
11. Run the complete tracked shell and Python report regression suite.

Tests use fake SDCLI and database clients; they do not require live customer
connections or enumerate password combinations.

## Acceptance criteria

- A Cecrealm command cannot use Proda's repository or super-user connection.
- Connection inventory contains unique derived repository names for each
  initialized migration.
- The selected repository endpoint always equals the selected migration's
  target endpoint.
- Existing repository data and migration runs survive creation of the new
  aliases.
- Multi-migration repository initialization is explicit and unambiguous.
- The customer config remains compact; repository credentials are declared
  once and only wallet differences require an optional per-migration line.
- All existing supported SQL Server-to-Oracle workflow tests continue to pass.
