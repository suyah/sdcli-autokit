# BCP queryout script update for 1.3.0

SQL Developer emits flat source names that become ambiguous when a schema or
table contains dots. Real testing rejected `[db].[schema].[Table.csv] out` and
exported the same table successfully through `SELECT * ... queryout` (89 rows).
The fix uses that tested form. It changes process arguments, not generated files.

## Implementation

- `migrate.sh` supplies the configured source database and per-attempt evidence paths.
- `lib/bcp` reads a table/view catalog through SQLCMD only on the first ambiguous
  local export. SQL Server `QUOTENAME` produces the escaped qualified identifiers;
  names are never split into schema/table by guessing dot positions.
- The catalog query keeps unlimited output width and parses the SQLCMD heading
  explicitly; SQLCMD 18 rejects its header-suppression (`-h`) option together
  with unlimited-width output (`-y 0`).
- The catalog is shared across sequential BCP processes for this attempt and
  refreshed on retry. No new repository schema dependency or runtime package.
- Zero/multiple matches stop the export. Existing queryout and ordinary out
  commands retain their behavior. Only matched ambiguous exports become queryout.
- Password delivery, output files, encoding and terminators remain unchanged.
- Generated shell/control files remain byte-identical; logging and
  `autokit/bcp_queryout_adjustments.tsv` show each adjustment, while
  `bcp_status.tsv` retains the original source object for reconciliation.

The supported scope is SQL Developer 26.2 local SQL Server table/view exports.
The source user must see the objects' catalog entries. Tab/newline identifiers
are unsupported by the existing TSV evidence interface. Final SQL*Loader and
reconciliation results must still be checked; an export test alone does not
establish a successful migration.

## Verification

The regression tests use fake SQLCMD/BCP boundaries to verify arguments,
one catalog query for multiple affected objects, dotted schemas and escaped
brackets, unchanged format options/source evidence, ambiguous-name failure, and
byte-identical generated scripts. Real BCP behavior is established separately
by the customer's successful queryout test; the mocks are not a real DB test.

## Install on a running 1.3.0 container

No migration command may be running while replacing program files. Transfer the
small `sdcli-autokit-bcp-queryout-hotfix.tar.gz` and adjacent `.sha256` file to
the customer VM. These contain only the two updated runtime files and this guide.
Do not replace config.yaml, vendor packages, wallets, profiles or run data.

On the customer VM host:

```bash
sha256sum -c sdcli-autokit-bcp-queryout-hotfix.tar.gz.sha256
tar -xzf sdcli-autokit-bcp-queryout-hotfix.tar.gz

podman exec --user sduser sdcli-autokit bash -lc '
set -e
umask 077
backup="/u01/data/sdcli-autokit/backups/bcp-queryout-$(date +%Y%m%d_%H%M%S)"
mkdir -p "$backup/lib"
cp -p ~/sdcli-scripts/migrate.sh "$backup/migrate.sh"
cp -p ~/sdcli-scripts/lib/bcp "$backup/lib/bcp"
printf "Backup: %s\n" "$backup"
'

podman cp sdcli-autokit-bcp-queryout-hotfix/sdcli-scripts/migrate.sh \
  sdcli-autokit:/home/sduser/sdcli-scripts/migrate.sh
podman cp sdcli-autokit-bcp-queryout-hotfix/sdcli-scripts/lib/bcp \
  sdcli-autokit:/home/sduser/sdcli-scripts/lib/bcp

podman exec --user root sdcli-autokit bash -lc '
set -e
chown sduser:sduser /home/sduser/sdcli-scripts/migrate.sh /home/sduser/sdcli-scripts/lib/bcp
chmod 0755 /home/sduser/sdcli-scripts/migrate.sh /home/sduser/sdcli-scripts/lib/bcp
'
podman exec --user sduser sdcli-autokit bash -lc '
set -e
bash -n ~/sdcli-scripts/migrate.sh ~/sdcli-scripts/lib/bcp
grep -n "args\[1\]=queryout" ~/sdcli-scripts/lib/bcp
grep -n "SQLSERVER_BCP_TABLE_CATALOG_FILE" ~/sdcli-scripts/migrate.sh
sha256sum ~/sdcli-scripts/migrate.sh ~/sdcli-scripts/lib/bcp
'
```

The filename is exactly `lib/bcp`, **not** `lib/bcp.sh`. The image/script release
version remains 1.3.0 plus this script update. A later deployment/run.sh refresh
from an older bundle can overwrite it; use a future release containing this fix.

Inside the container, export the existing password variables and retry only
the failed offload using the original migration run ID:

```bash
cd ~/sdcli-scripts
./migrate.sh <migration> --phase offload --run <original-run-id>
```

The console should show `runtime out -> queryout`, successful BCP row counts,
and summary `invoked=expected=unique_data_files`, `failed=0`, `missing_files=0`.
Inspect `autokit/bcp_queryout_adjustments.tsv`. Continue deploy/load only after
offload succeeds. No init, capture, convert, generate or datamove repeat is needed.

## Rollback

While migration commands are stopped, restore `migrate.sh` and `lib/bcp` from
the exact backup path printed above and check permissions/syntax again. This
restores previous script behavior, not data files overwritten by an offload
retry, and does not resolve the old dotted-name export failure.
