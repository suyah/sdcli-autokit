#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COLLECTOR="$REPO_ROOT/sdcli-scripts/collect-run-logs.sh"
tmpdir="$(mktemp -d)"
trap 'chmod -R u+rwx "$tmpdir" 2>/dev/null || true; rm -rf "$tmpdir"' EXIT

assert_contains() {
  local haystack="$1"
  local needle="$2"
  [[ "$haystack" == *"$needle"* ]] || {
    echo "Expected output to contain: $needle" >&2
    exit 1
  }
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  [[ "$haystack" != *"$needle"* ]] || {
    echo "Expected output not to contain: $needle" >&2
    exit 1
  }
}

assert_sha256_file() {
  local checksum_file="$1"
  (
    cd "$(dirname "$checksum_file")"
    if command -v sha256sum >/dev/null 2>&1; then
      sha256sum -c "$(basename "$checksum_file")"
    else
      shasum -a 256 -c "$(basename "$checksum_file")"
    fi
  )
}

assert_collector_fails() {
  local failing_run="$1"
  if AUTOKIT_PROJECT_ROOT="$project_root" "$COLLECTOR" "$migration" --run "$failing_run" --output "$bundle_dir" > "$tmpdir/$failing_run.out" 2>&1; then
    echo "Collector unexpectedly succeeded for incomplete run: $failing_run" >&2
    exit 1
  fi
}

project_root="$tmpdir/projects"
migration="demo"
run="20261105_001122"
run_dir="$project_root/$migration/run_$run"
autokit_dir="$run_dir/autokit"
mkdir -p "$autokit_dir" "$run_dir/sdcli/log/nested" "$run_dir/sdcli/datamove/demo/log" \
  "$run_dir/sdcli/datamove/demo/data" "$run_dir/sdcli/datamove/demo/control" "$run_dir/sdcli/demo"

printf 'redacted migration log\n' > "$autokit_dir/migrate.log"
printf 'phase\tstate\nvalidate\tsucceeded\n' > "$autokit_dir/phase_status.tsv"
printf 'PASS\n' > "$autokit_dir/validation_summary.txt"
printf 'Migration Validation Report\nStatus: PASS\n' > "$autokit_dir/migration_report.txt"
printf '<html><body>PASS</body></html>\n' > "$autokit_dir/migration_report.html"
printf 'bcp evidence\n' > "$autokit_dir/bcp_status.tsv"
printf 'loader evidence\n' > "$autokit_dir/sqlldr_status.tsv"
printf 'row reconciliation\n' > "$autokit_dir/reconciliation.tsv"
printf 'customer credentials must not leave the run\n' > "$autokit_dir/credentials.txt"
printf 'customer data must not leave the run\n' > "$autokit_dir/customer.csv"
printf 'error details\n' > "$run_dir/sdcli/log/error.txt"
printf 'nested diagnostic\n' > "$run_dir/sdcli/log/nested/detail.log"
printf 'wallet data must not leave the run\n' > "$run_dir/sdcli/log/cwallet.sso"
printf 'rejected row data must not leave the run\n' > "$run_dir/sdcli/log/rows.bad"
printf 'loader log\n' > "$run_dir/sdcli/datamove/demo/log/table.log"
printf 'loader stdout\n' > "$run_dir/sdcli/datamove/demo/loader.out"
printf 'customer data must not leave the run\n' > "$run_dir/sdcli/datamove/demo/data/table.dat"
printf 'rejected row data must not leave the run\n' > "$run_dir/sdcli/datamove/demo/log/table.bad"
printf 'control file must not leave the run\n' > "$run_dir/sdcli/datamove/demo/control/table.ctl"
printf 'generated DDL must not leave the run\n' > "$run_dir/sdcli/demo/tables.sql"
original_data_checksum="$(cksum "$run_dir/sdcli/datamove/demo/data/table.dat")"

bundle_dir="$tmpdir/bundles"
AUTOKIT_PROJECT_ROOT="$project_root" "$COLLECTOR" "$migration" --run "$run" --output "$bundle_dir" > "$tmpdir/collector.out"
collector_output="$(cat "$tmpdir/collector.out")"
assert_contains "$collector_output" "Run log bundle:"
assert_contains "$collector_output" "Excluded: config, wallets, profiles, generated SQL, BCP data, loader control files, and rejected-row files"

bundle="$(sed -n 's/^Run log bundle: //p' "$tmpdir/collector.out")"
[[ -f "$bundle" && -f "$bundle.sha256" ]]
assert_sha256_file "$bundle.sha256"

extract_dir="$tmpdir/extract"
mkdir -p "$extract_dir"
tar -xzf "$bundle" -C "$extract_dir"
bundle_root="$(find "$extract_dir" -mindepth 1 -maxdepth 1 -type d | head -1)"
bundle_files="$(cd "$bundle_root" && find . -type f -print | LC_ALL=C sort)"
assert_contains "$bundle_files" "./autokit/migrate.log"
assert_contains "$bundle_files" "./autokit/phase_status.tsv"
assert_contains "$bundle_files" "./autokit/validation_summary.txt"
assert_contains "$bundle_files" "./autokit/migration_report.txt"
assert_contains "$bundle_files" "./autokit/migration_report.html"
assert_contains "$bundle_files" "./sdcli/log/error.txt"
assert_contains "$bundle_files" "./sdcli/log/nested/detail.log"
assert_contains "$bundle_files" "./sdcli/datamove/demo/log/table.log"
assert_contains "$bundle_files" "./sdcli/datamove/demo/loader.out"
assert_contains "$bundle_files" "./bundle_manifest.tsv"
assert_contains "$bundle_files" "./collection_summary.txt"
assert_not_contains "$bundle_files" "table.dat"
assert_not_contains "$bundle_files" "table.bad"
assert_not_contains "$bundle_files" "table.ctl"
assert_not_contains "$bundle_files" "tables.sql"
assert_not_contains "$bundle_files" "credentials.txt"
assert_not_contains "$bundle_files" "customer.csv"
assert_not_contains "$bundle_files" "cwallet.sso"
assert_not_contains "$bundle_files" "rows.bad"
[[ "$(cksum "$run_dir/sdcli/datamove/demo/data/table.dat")" == "$original_data_checksum" ]]

# The checksum sidecar must remain usable after the archive is moved with it.
portable_dir="$tmpdir/portable"
mkdir -p "$portable_dir"
cp "$bundle" "$bundle.sha256" "$portable_dir/"
rm -f "$bundle" "$bundle.sha256"
(
  cd "$portable_dir"
  assert_sha256_file "$(basename "$bundle").sha256"
)

# A readable log directory is required once it exists. Do not publish a bundle
# that silently omits logs because discovery failed.
incomplete_run="20261105_001123"
incomplete_dir="$project_root/$migration/run_$incomplete_run"
mkdir -p "$incomplete_dir/autokit" "$incomplete_dir/sdcli/log/denied"
printf 'redacted migration log\n' > "$incomplete_dir/autokit/migrate.log"
printf 'unreadable diagnostic\n' > "$incomplete_dir/sdcli/log/denied/hidden.log"
chmod 000 "$incomplete_dir/sdcli/log/denied"
assert_collector_fails "$incomplete_run"
chmod 700 "$incomplete_dir/sdcli/log/denied"

# Never follow a symlink from the run tree: it could point to a local secret.
symlink_run="20261105_001124"
symlink_dir="$project_root/$migration/run_$symlink_run"
mkdir -p "$symlink_dir/autokit" "$symlink_dir/sdcli"
printf 'secret outside the run\n' > "$tmpdir/secret.txt"
ln -s "$tmpdir/secret.txt" "$symlink_dir/autokit/migrate.log"
assert_collector_fails "$symlink_run"

# A completed run always has an autokit directory. A directory that exists but
# cannot be read must not result in a deceptively empty run log bundle.
unreadable_autokit_run="20261105_001125"
unreadable_autokit_dir="$project_root/$migration/run_$unreadable_autokit_run"
mkdir -p "$unreadable_autokit_dir/autokit" "$unreadable_autokit_dir/sdcli"
printf 'redacted migration log\n' > "$unreadable_autokit_dir/autokit/migrate.log"
chmod 000 "$unreadable_autokit_dir/autokit"
assert_collector_fails "$unreadable_autokit_run"
chmod 700 "$unreadable_autokit_dir/autokit"

echo "run log collection test passed"
