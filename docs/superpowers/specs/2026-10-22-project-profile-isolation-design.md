# SQL Developer 26.2 project profile isolation

## Evidence and decision

SDCLI 26.2 InitCmd inherits MigrationCmd.execute(), which opens the persisted
default repository before InitCmd.executeImpl() installs new connection details.
Native traces reproduced this with loopback ports: a stale default selected
15261 and prevented the requested 15264 connection; without a default, the same
init arguments selected 15264. lscaptured ignored a supplied -repository option.
IDE_USER_DIR independently controlled the actual connections.json and
product-preferences.xml paths. Concurrent profiles did not cross-read these
files, and the old profile's file hashes stayed unchanged.

Use one persistent profile per migration, not a shared preference switch. Retain
the existing derived aliases, target endpoint selection and compact YAML.
No PRODA-specific branch, automatic import or legacy profile fallback.

## Runtime and state

- Profiles: `${TOOL_DATA}/profiles/<migration>/system26.2.<build>/...`.
  For standalone execution without TOOL_DATA, the data directory is the parent
  of defaults.paths.project_root. Both roots must be absolute. Project names
  must be a single safe component beginning with a letter, digit or underscore.
- New Bash library `sdcli-scripts/lib/sdcli_profile.sh` owns profile selection,
  state, profile locks and Java wallet-option normalization. migrate.sh retains
  the existing command runner, preference template handling and repository lock.
- Every actual SDCLI subprocess receives the selected IDE_USER_DIR from
  run_sdcli. Missing selection is an error, not a fallback to HOME.
- A private `.autokit-profile` file stores an identity hash and pending/ready
  state. The hash includes target endpoint, repository username and alias.
  Nonempty unmanaged profiles and identity changes are rejected with backup /
  fresh-profile instructions. Every init attempt starts pending, including a
  retry of a ready profile. Verified init writes ready atomically.
- SDCLI modes require ready except init. Oracle-only artifact phases and datatype
  mapping inspection do not require or modify a SQL Developer profile. Dry runs
  show the selected directory without creating or updating profile state.

## Initialization

Take the profile lock before any profile file write or SDCLI invocation. A fresh
init uses `sdcli migration -help=init` to create the installed version's directory
layout, installs the controlled FileOutputOption template if absent, then runs
driver and init. Help is an explicitly recognized runner operation; action
commands still require their exact success marker and clean diagnostics.

Successful vendor init saves its own default repository and generated
db.system.id. Do not generate encryption identifiers or edit DefaultRepository
in production code. A real test must reopen the initialized repository from a
new process; listing saved connection names is insufficient.

Before marking ready, SQL*Plus verifies an installation revision exists in
MD_REPOVERSIONS (the vendor's install script writes it at the end), then an
independent SDCLI lscaptured process reopens the saved repository. These are
read-only checks; no fixed revision number or project-specific object name is
used. Keep query/output evidence in the init run's autokit directory. This
guards the native existence test, which checks only MD_CONNECTIONS and can
accept a cancelled partial installation. Init therefore also requires SQL*Plus.

Init alone receives its supported `-conn=<derived repository alias>` option.
Its implicit connDetails detection otherwise depends on an alias starting with
`mig`; explicitly selecting the alias also supports configured non-default
prefixes. This does not restore the unsupported generic `-repository` option.

The profile remains pending on failure. Init can be retried with unchanged
identity after resolving the cause; an incomplete database repository requires
DBA repair, not an automatic drop/recreate or a silent success. Changing a
target requires an explicit backup and fresh profile;
there is no silent reuse of a different database's preferences.

## Wallets and locking

Wallet selection remains target.wallet_dir, then defaults.target.wallet_dir.
Normalize oracle.net.tns_admin in JAVA_TOOL_OPTIONS, JDK_JAVA_OPTIONS and
_JAVA_OPTIONS while preserving unrelated options. With no configured wallet,
clear inherited TNS_ADMIN / the wallet property; other Java options stay intact.
The calling user's shell is unaffected. SQL*Plus receives the same selected
wallet configuration; IDE_USER_DIR is scoped to SDCLI children.

A profile lock covers all SDCLI modes, including conn-setup. A separate
repository lock uses endpoint plus repository username, never a project alias.
Different projects sharing the same actual configured repository serialize;
different profiles and repositories can run concurrently. Acquire profile then
repository lock, and release both on process exit/signals. No global lock.

## Deployment and transition

Keep old shared state durably backed up; do not repoint its symlink or copy its
connections to new profiles. Remove deployment's shared preferences bootstrap
and template update. Tool startup checks use a disposable profile on TOOL_DATA.
Add strace to the image and tool checks. No Python dependency is added.

Users back up the complete old profile/config, deploy the complete scripts
directory, then run named init and conn-setup for each migration. Re-registering
connections does not require recapturing database models or recopying data.
Raw SDCLI commands must explicitly select the project IDE_USER_DIR; remove
unsupported -repository examples. Existing deployment volume/config protection
remains; it is not a runtime preference fallback.

## Verification and rollback

One focused Bash test covers independent concurrent process environments,
pending/ready state, changed identity, profile contention and wallet option
replacement. Extend the existing repository lock test to cover two aliases
sharing endpoint/user. Update affected fixtures instead of duplicating suites.
Run all tracked shell tests, report unit tests, syntax checks and diff checks.
strace is verified as an installed executable; do not add a source-text test.

With explicit user permission, initialize only MIGREP_AUTOKIT_TEST_20261022 on
the supplied ExaCS test target, using an isolated profile and a private test
config. Verify reopening, default selection and repository evidence in a new
process. Preserve the test schema and container. Do not run the migration data
workflow against this target. ADB mTLS remains a separate validation scope.

Rollback selects the previous Git/release version and backed-up complete shared
profile during a maintenance window. Never automatically delete either profile
or drop a repository. Rolling back files does not reverse database DDL.

## Engineering verification — 2026-10-22

- The tracked Bash suite passed 35/35, including the report's 17 unit cases.
  Focused regressions were observed failing before fixes for profile selection,
  alias-independent locks, quoted wallet tokens, explicit init alias selection,
  vendor-saved preferences, incomplete installation and re-init pending state.
- The actual deployment startup helper passed in the existing container. Its
  disposable profile was removed, strace 6.12 was available, and the complete
  original shared-profile file hash list remained unchanged.
- The supplied ExaCS screenshot service selected CDB root. PDBSYH's full service
  was verified by direct login. Native mkrepouser inherited SYSDBA from the SYS
  connection; an ordinary SYSTEM connection avoided that vendor role issue.
  No production role workaround was added.
- The first real install hit the private test's 600-second limit while the
  SDK worker was running vendor repository SQL. Read-only checks showed 109
  tables and no installation revision row. The profile stayed pending and
  locks were released. This is not a successful initialization result.
- The actual read-only readiness helper rejected that partial schema with
  `Repository installation is incomplete` (REAL_INCOMPLETE_GUARD=PASS).
- Clean positive acceptance passed with the explicitly approved
  MIGREP_AUTOKIT_RETRY_20261022 on PDBSYH. The init run
  `20261022_031538` completed at 03:29:18 UTC (about 14 minutes overall),
  verified installation revision 65, and reopened the saved repository with an
  independent SDCLI lscaptured process. The profile became ready only afterward.
- The non-default alias prefix worked: DefaultRepository was saved as
  `IdeConnections%23repo_test_isolation_test`. The SDK persisted its own
  db.system.id; FileOutputOption remained 1. No encryption identifier or
  DefaultRepository was manually injected. Direct SQL*Plus evidence showed
  the expected retry schema with 134 tables; old shared-profile hashes matched.
- The running container and both test schemas were preserved. No automatic
  repository cleanup is part of production execution. ADB mTLS, a complete
  data migration and a clean image rebuild are outside this acceptance run;
  the strace Dockerfile change is for the next image build.

Private container evidence and complete old-state backups are under
`/u01/data/sdcli-autokit/profile-isolation-test.VR30Ea`; credentials are not
included in Git or release artifacts. Preserve the running container and test
schemas for inspection.
