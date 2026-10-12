#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATE_SH_SOURCE_ONLY=true source "$REPO_ROOT/sdcli-scripts/migrate.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

data_file="$tmpdir/orders.dat"
touch "$data_file"

printf '0\tdemo.dbo.orders\t%s\t2\n' "$data_file" > "$tmpdir/bcp.tsv"
printf '0\tAPP.ORDERS\t%s\t%s\t2\t0\t0\t%s\n' \
  "$tmpdir/orders.ctl" "$data_file" "$tmpdir/orders.log" > "$tmpdir/sqlldr.tsv"
printf '1\t2\n' > "$tmpdir/counts.tsv"

build_reconciliation_report "$tmpdir/bcp.tsv" "$tmpdir/sqlldr.tsv" "$tmpdir/counts.tsv" "$tmpdir/report.tsv"
grep -F $'demo.dbo.orders\tAPP.ORDERS' "$tmpdir/report.tsv" >/dev/null
grep -F $'\t2\t2\t0\t0\t2\tPASS\t' "$tmpdir/report.tsv" >/dev/null

printf '1\t1\n' > "$tmpdir/counts.tsv"
set +e
build_reconciliation_report "$tmpdir/bcp.tsv" "$tmpdir/sqlldr.tsv" "$tmpdir/counts.tsv" "$tmpdir/mismatch.tsv"
rc=$?
set -e
[[ $rc -ne 0 ]]
grep -F $'\tFAIL\tloaded and target row counts differ' "$tmpdir/mismatch.tsv" >/dev/null

printf '0\tdemo.dbo.extra\t%s\t0\n' "$tmpdir/extra.dat" >> "$tmpdir/bcp.tsv"
set +e
build_reconciliation_report "$tmpdir/bcp.tsv" "$tmpdir/sqlldr.tsv" "$tmpdir/counts.tsv" "$tmpdir/missing.tsv"
rc=$?
set -e
[[ $rc -ne 0 ]]
grep -F $'demo.dbo.extra\t\t' "$tmpdir/missing.tsv" >/dev/null
grep -F $'\tFAIL\tmissing SQL*Loader status' "$tmpdir/missing.tsv" >/dev/null

echo "data reconciliation test passed"
