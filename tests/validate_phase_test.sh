#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

MIGRATE_SH_SOURCE_ONLY=true source "$REPO_ROOT/sdcli-scripts/migrate.sh"

assert_contains() {
  local haystack="$1"
  local needle="$2"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "Expected output to contain: $needle" >&2
    echo "$haystack" >&2
    exit 1
  fi
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "Expected output not to contain: $needle" >&2
    echo "$haystack" >&2
    exit 1
  fi
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

output_dir="$tmpdir/sdcli"
AUTOKIT_DIR="$tmpdir/autokit"
RUN_LOG_FILE="$AUTOKIT_DIR/migrate.log"
DRY_RUN=false

mkdir -p "$output_dir/log" "$output_dir/datamove/tpcc/tpcc/log" "$AUTOKIT_DIR"

cat > "$output_dir/log/error.txt" <<'LOG'
LOG

cat > "$RUN_LOG_FILE" <<'LOG'
[INFO] 2026-04-28 03:14:35 - SQL*Loader table 01 tpcc.customer rows=3000000 path=Direct elapsed_sec=132 status=success
[WARN] 2026-04-28 03:14:35 - SQL*Loader diagnostic: ORA-28098: Profile limits PASSWORD_LIFE_TIME and PASSWORD_GRACE_TIME are not unlimited, password will expire within 18 days.
[INFO] 2026-04-28 03:16:48 - SQL*Loader load summary: tables=1 rows=3000000 sqlldr_elapsed_sec=132
LOG

cat > "$output_dir/datamove/tpcc/tpcc/log/tpcc.customer.log" <<'LOG'
SQL*Loader: Release 19.0.0.0.0 - Production
Errors allowed: 50
Path used:      Direct
Table TPCC.CUSTOMER:
  3000000 Rows successfully loaded.
  0 Rows not loaded due to data errors.
  0 Rows not loaded because all WHEN clauses were failed.
  0 Rows not loaded because all fields were null.
Total logical records rejected:         0
Total logical records discarded:        0
LOG

success_output="$(run_validate "$output_dir")"
success_output_second_run="$(run_validate "$output_dir")"

assert_contains "$success_output" "Validation summary: run_log_issues=0 sdcli_error_entries=0 sqlldr_logs_checked=1 sqlldr_log_issues=0 missing_evidence=0 reconciliation_issues=0 object_issues=0 metadata_issues=0 report_issues=0 total_issues=0"
assert_contains "$success_output" "Migration validation passed"
assert_not_contains "$success_output" "Potential load issues"
assert_not_contains "$success_output" "Run log issue:"
assert_not_contains "$success_output" "SQL*Loader log issue:"
assert_contains "$success_output_second_run" "Validation summary: run_log_issues=0 sdcli_error_entries=0 sqlldr_logs_checked=1 sqlldr_log_issues=0 missing_evidence=0 reconciliation_issues=0 object_issues=0 metadata_issues=0 report_issues=0 total_issues=0"
assert_not_contains "$success_output_second_run" "Run log issue:"

# A validation command resumed against an existing run must judge the current
# artifacts. Earlier failed attempts remain in migrate.log for audit, but must
# not cause a false validation failure after the affected phase is retried.
historical_log="$tmpdir/historical-autokit/migrate.log"
mkdir -p "$(dirname "$historical_log")"
cat > "$historical_log" <<'LOG'
[ERROR] 2026-04-27 23:59:59 - Earlier attempt failed before it was retried
LOG
RUN_LOG_FILE="$historical_log"
AUTOKIT_DIR="$tmpdir/historical-autokit"
RUN_LOG_START_LINE="$(wc -l < "$RUN_LOG_FILE" | tr -d '[:space:]')"
historical_output="$(run_validate "$output_dir")"
assert_contains "$historical_output" "Run log diagnostics: issues=0 ignored=0 historical=1"
assert_contains "$historical_output" "Migration validation passed"
assert_not_contains "$historical_output" "Run log issue:"

bad_output_dir="$tmpdir/bad-sdcli"
bad_autokit_dir="$tmpdir/bad-autokit"
bad_run_log="$bad_autokit_dir/migrate.log"
mkdir -p "$bad_output_dir/log" "$bad_output_dir/datamove/tpcc/tpcc/log" "$bad_autokit_dir"

cat > "$bad_output_dir/log/error.txt" <<'LOG'
ERROR: generated SQL failed
LOG

cat > "$bad_run_log" <<'LOG'
[INFO] 2026-04-28 03:01:10 - SQL*Loader table 01 tpcc.customer rows=unknown path=unknown elapsed_sec=0 status=failed(1)
[WARN] 2026-04-28 03:01:11 - SQL*Loader diagnostic: ORA-01017: invalid credential or not authorized; logon denied
[INFO] 2026-04-28 03:01:11 - SQL*Loader load summary: tables=0 rows=0 sqlldr_elapsed_sec=0
[WARN] 2026-04-28 03:01:11 - SQL*Loader load failed: wall_elapsed_sec=1 exit_code=1
LOG

cat > "$bad_output_dir/datamove/tpcc/tpcc/log/tpcc.customer.log" <<'LOG'
SQL*Loader: Release 19.0.0.0.0 - Production
SQL*Loader-128: unable to begin a session
ORA-01017: invalid credential or not authorized; logon denied
Table TPCC.CUSTOMER:
  2 Rows not loaded due to data errors.
Total logical records rejected:         2
LOG

RUN_LOG_FILE="$bad_run_log"
AUTOKIT_DIR="$bad_autokit_dir"
RUN_LOG_START_LINE=0
set +e
bad_output="$(run_validate "$bad_output_dir" 2>&1)"
bad_rc=$?
bad_output_second_run="$(run_validate "$bad_output_dir" 2>&1)"
bad_second_rc=$?
set -e

[[ $bad_rc -ne 0 && $bad_second_rc -ne 0 ]] || {
  echo "Validation with known errors unexpectedly succeeded" >&2
  exit 1
}

assert_contains "$bad_output" "Run log issue: $bad_run_log:1:"
assert_contains "$bad_output" "Run log issue: $bad_run_log:2:"
assert_contains "$bad_output" "Run log issue: $bad_run_log:3:"
assert_contains "$bad_output" "Run log issue: $bad_run_log:4:"
assert_contains "$bad_output" "SDCLI error log issue: $bad_output_dir/log/error.txt:1:"
assert_contains "$bad_output" "SQL*Loader log issue: $bad_output_dir/datamove/tpcc/tpcc/log/tpcc.customer.log:2:"
assert_contains "$bad_output" "SQL*Loader log issue: $bad_output_dir/datamove/tpcc/tpcc/log/tpcc.customer.log:3:"
assert_contains "$bad_output" "SQL*Loader log issue: $bad_output_dir/datamove/tpcc/tpcc/log/tpcc.customer.log:5:"
assert_contains "$bad_output" "SQL*Loader log issue: $bad_output_dir/datamove/tpcc/tpcc/log/tpcc.customer.log:6:"
assert_contains "$bad_output" "Validation summary: run_log_issues=4 sdcli_error_entries=1 sqlldr_logs_checked=1 sqlldr_log_issues=4 missing_evidence=0 reconciliation_issues=0 object_issues=0 metadata_issues=0 report_issues=0 total_issues=9"
assert_contains "$bad_output_second_run" "Validation summary: run_log_issues=4 sdcli_error_entries=1 sqlldr_logs_checked=1 sqlldr_log_issues=4 missing_evidence=0 reconciliation_issues=0 object_issues=0 metadata_issues=0 report_issues=0 total_issues=9"
grep -F 'status=FAIL' "$bad_autokit_dir/validation_summary.txt" >/dev/null

missing_output_dir="$tmpdir/missing-sdcli"
missing_autokit_dir="$tmpdir/missing-autokit"
mkdir -p "$missing_output_dir/log" "$missing_autokit_dir"
touch "$missing_output_dir/log/error.txt" "$missing_autokit_dir/migrate.log"
RUN_LOG_FILE="$missing_autokit_dir/migrate.log"
AUTOKIT_DIR="$missing_autokit_dir"
set +e
missing_output="$(run_validate "$missing_output_dir" 2>&1)"
missing_rc=$?
set -e
[[ $missing_rc -ne 0 ]]
assert_contains "$missing_output" "missing_evidence=1"

# Exercise validate orchestration with live-metadata/report helpers stubbed at
# their boundaries. Collector and report internals have focused tests; these
# cases prove failures are accumulated and never prevent the report attempt.
integration_dir="$tmpdir/integration-sdcli"
integration_autokit="$tmpdir/integration-autokit"
mkdir -p "$integration_dir/log" "$integration_dir/datamove/app/app/log" "$integration_autokit"
touch "$integration_dir/log/error.txt"
cat > "$integration_dir/datamove/app/app/log/app.orders.log" <<'LOG'
Table APP.ORDERS:
  2 Rows successfully loaded.
  0 Rows not loaded due to data errors.
Total logical records rejected:         0
Total logical records discarded:        0
LOG

RUN_LOG_FILE="$integration_autokit/migrate.log"
AUTOKIT_DIR="$integration_autokit"
touch "$RUN_LOG_FILE"
COLLECTOR_MODE=pass
REPORT_MODE=pass

run_data_reconciliation() {
  cat > "$AUTOKIT_DIR/reconciliation.tsv" <<'TSV'
source_object	target_object	data_file	exported_rows	loaded_rows	rejected_rows	discarded_rows	target_rows	status	reason
db.dbo.orders	APP.ORDERS	/tmp/orders.dat	2	2	0	0	2	PASS	matched
TSV
}

validate_target_objects() { return 0; }

collect_source_object_inventory() {
  printf 'source\n' >> "$tmpdir/collector-attempts"
  [[ "$COLLECTOR_MODE" != source_fail ]] || return 1
  inventory_tsv_header > "$2"
  printf 'dbo\tTABLES\torders\t\t\tTABLE\t\t\t\tVALID\t\tfixture\n' >> "$2"
}

collect_target_object_inventory() {
  printf 'target\n' >> "$tmpdir/collector-attempts"
  [[ "$COLLECTOR_MODE" != target_fail ]] || return 1
  inventory_tsv_header > "$3"
  printf 'APP\tTABLES\tORDERS\t\t\tTABLE\t\t\t\tVALID\t\tfixture\n' >> "$3"
}

run_validation_report() {
  printf 'report:%s:%s\n' "$1" "$2" >> "$tmpdir/report-attempts"
  [[ -s "$AUTOKIT_DIR/validation_checks.tsv" ]] || return 1
  case "$REPORT_MODE" in
    pass)
      printf '<html>pass</html>\n' > "$AUTOKIT_DIR/migration_report.html"
      printf 'text pass\n' > "$AUTOKIT_DIR/migration_report.txt"
      return 0
      ;;
    mismatch)
      printf '<html>fail</html>\n' > "$AUTOKIT_DIR/migration_report.html"
      printf 'text fail\n' > "$AUTOKIT_DIR/migration_report.txt"
      return 2
      ;;
    renderer_fail)
      return 1
      ;;
  esac
}

integration_output="$(run_validate "$integration_dir" 0)"
assert_contains "$integration_output" "metadata_issues=0 report_issues=0 total_issues=0"
assert_contains "$integration_output" "Migration validation report: $integration_autokit/migration_report.html"
assert_contains "$integration_output" "Migration validation text report: $integration_autokit/migration_report.txt"
grep -F 'status=PASS' "$integration_autokit/validation_summary.txt" >/dev/null
grep -F $'metadata_collection\tPASS\t0\t' "$integration_autokit/validation_checks.tsv" >/dev/null

second_integration_output="$(run_validate "$integration_dir" 0)"
assert_contains "$second_integration_output" "metadata_issues=0 report_issues=0 total_issues=0"
[[ "$(grep -c '^source$' "$tmpdir/collector-attempts")" == 2 ]]
[[ "$(grep -c '^target$' "$tmpdir/collector-attempts")" == 2 ]]
[[ "$(grep -c '^report:' "$tmpdir/report-attempts")" == 2 ]]
[[ "$(grep -c '^status=' "$integration_autokit/validation_summary.txt")" == 1 ]]

COLLECTOR_MODE=source_fail
REPORT_MODE=mismatch
set +e
source_failure_output="$(run_validate "$integration_dir" 0 2>&1)"
source_failure_rc=$?
set -e
[[ $source_failure_rc -ne 0 ]]
assert_contains "$source_failure_output" "metadata_issues=1 report_issues=1 total_issues=2"
assert_contains "$source_failure_output" "Migration validation report: $integration_autokit/migration_report.html"
assert_contains "$source_failure_output" "Migration validation text report: $integration_autokit/migration_report.txt"
grep -F $'metadata_collection\tINCOMPLETE\t1\t' "$integration_autokit/validation_checks.tsv" >/dev/null

COLLECTOR_MODE=target_fail
set +e
target_failure_output="$(run_validate "$integration_dir" 0 2>&1)"
target_failure_rc=$?
set -e
[[ $target_failure_rc -ne 0 ]]
assert_contains "$target_failure_output" "metadata_issues=1 report_issues=1 total_issues=2"

COLLECTOR_MODE=pass
REPORT_MODE=mismatch
set +e
comparison_output="$(run_validate "$integration_dir" 0 2>&1)"
comparison_rc=$?
set -e
[[ $comparison_rc -ne 0 ]]
assert_contains "$comparison_output" "metadata_issues=0 report_issues=1 total_issues=1"

REPORT_MODE=renderer_fail
set +e
renderer_output="$(run_validate "$integration_dir" 0 2>&1)"
renderer_rc=$?
set -e
[[ $renderer_rc -ne 0 ]]
assert_contains "$renderer_output" "metadata_issues=0 report_issues=1 total_issues=1"
[[ "$(grep -c '^report:' "$tmpdir/report-attempts")" == 6 ]]

echo "validate phase test passed"
