#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATE_SH_SOURCE_ONLY=true source "$REPO_ROOT/sdcli-scripts/migrate.sh"

fail_test() {
  echo "$1" >&2
  exit 1
}

assert_contains_file() {
  local file="$1"
  local value="$2"
  grep -F -- "$value" "$file" >/dev/null || fail_test "Expected $file to contain: $value"
}

assert_not_contains_file() {
  local file="$1"
  local value="$2"
  if grep -F -- "$value" "$file" >/dev/null; then
    fail_test "Expected $file not to contain: $value"
  fi
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "$tmpdir/bin" "$tmpdir/sdcli/App" "$tmpdir/sdcli/Emulation" "$tmpdir/autokit"
touch "$tmpdir/sdcli/App/user.sql" "$tmpdir/sdcli/Emulation/user.sql"

cat > "$tmpdir/bin/sqlcmd" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$SQLCMD_ARGS_FILE"
printf '%s' "${SQLCMDPASSWORD:-}" > "$SQLCMD_PASSWORD_FILE"
query=""
args=("$@")
for ((i = 0; i + 1 < ${#args[@]}; i++)); do
  if [[ "${args[$i]}" == "-Q" ]]; then
    query="${args[$((i + 1))]}"
  fi
done
printf '%s' "$query" > "$SQLCMD_QUERY_FILE"
case "${SQLCMD_MODE:-valid}" in
  valid)
    printf 'SDCLI_INVENTORY\tdbo\tTABLES\torders\t\t\tTABLE\t\t\t\tVALID\t0\tsqlserver\n'
    printf 'SDCLI_INVENTORY\tdbo\tIDENTITY_COLUMNS\torders_id\tdbo\torders\tIDENTITY\t1\tcolumn\tid\tVALID\t\tsqlserver\n'
    ;;
  empty) ;;
  malformed) printf 'SDCLI_INVENTORY\tdbo\tTABLES\n' ;;
  fail) printf 'simulated sqlcmd failure\n' >&2; exit 17 ;;
esac
SH
chmod +x "$tmpdir/bin/sqlcmd"

cat > "$tmpdir/bin/sqlplus" <<'SH'
#!/usr/bin/env bash
input="$(cat)"
printf '%s' "$input" > "$SQLPLUS_INPUT_FILE"
case "${SQLPLUS_MODE:-valid}" in
  valid)
    printf 'SDCLI_INVENTORY\tAPP\tTABLES\tORDERS\t\t\tTABLE\t\t\t\tVALID\t\toracle\n'
    printf 'SDCLI_INVENTORY\tAPP\tIDENTITY_COLUMNS\tORDERS_ID\tAPP\tORDERS\tIDENTITY\t1\tcolumn\tID\tVALID\t\toracle\n'
    ;;
  empty) ;;
  malformed) printf 'SDCLI_INVENTORY\tAPP\tTABLES\n' ;;
  fail) printf 'simulated sqlplus failure\n' >&2; exit 19 ;;
esac
SH
chmod +x "$tmpdir/bin/sqlplus"

PATH="$tmpdir/bin:$PATH"
export SQLCMD_ARGS_FILE="$tmpdir/sqlcmd.args"
export SQLCMD_PASSWORD_FILE="$tmpdir/sqlcmd.password"
export SQLCMD_QUERY_FILE="$tmpdir/sqlcmd.query"
export SQLPLUS_INPUT_FILE="$tmpdir/sqlplus.input"

get_required_value() {
  case "$1" in
    '.migrations[0].source.conn') printf 'sql.example.test:1444:SalesDb\n' ;;
    '.migrations[0].source.user') printf 'collector_user\n' ;;
    '.migrations[0].name') printf 'sales\n' ;;
    '.migrations[0].target.conn') printf 'adb_alias\n' ;;
    '.migrations[0].target.user') printf 'admin\n' ;;
    '.defaults.source.bcp_tls_mode') printf '%s\n' "${TEST_TLS_MODE:-optional}" ;;
    *) echo "unexpected config path: $1" >&2; return 1 ;;
  esac
}

get_secret_value() {
  case "$1" in
    '.migrations[0].source.password') printf 'Source-Secret-42!\n' ;;
    '.migrations[0].target.password') printf 'Target-Secret-42!\n' ;;
    *) echo "unexpected secret path: $1" >&2; return 1 ;;
  esac
}

AUTOKIT_DIR="$tmpdir/autokit"
RUN_LOG_FILE="$AUTOKIT_DIR/migrate.log"
touch "$RUN_LOG_FILE"
DRY_RUN=false

source_inventory="$tmpdir/autokit/source_object_inventory.tsv"
collect_source_object_inventory 0 "$source_inventory"

expected_header=$'schema\tcategory\tobject_name\tparent_schema\tparent_name\tsubtype\tordinal\tattribute_name\tattribute_value\tstatus\tdetail\torigin'
[[ "$(head -n 1 "$source_inventory")" == "$expected_header" ]] || fail_test "Unexpected source inventory header"
[[ "$(cat "$SQLCMD_PASSWORD_FILE")" == 'Source-Secret-42!' ]] || fail_test "sqlcmd did not receive SQLCMDPASSWORD"
assert_contains_file "$SQLCMD_ARGS_FILE" '-S'
assert_contains_file "$SQLCMD_ARGS_FILE" 'sql.example.test,1444'
assert_contains_file "$SQLCMD_ARGS_FILE" '-d'
assert_contains_file "$SQLCMD_ARGS_FILE" 'SalesDb'
assert_contains_file "$SQLCMD_ARGS_FILE" '-U'
assert_contains_file "$SQLCMD_ARGS_FILE" 'collector_user'
assert_contains_file "$SQLCMD_ARGS_FILE" '-No'
assert_not_contains_file "$SQLCMD_ARGS_FILE" 'Source-Secret-42!'
assert_not_contains_file "$source_inventory" 'Source-Secret-42!'
assert_not_contains_file "$RUN_LOG_FILE" 'Source-Secret-42!'
assert_contains_file "$SQLCMD_QUERY_FILE" 'sys.tables'
assert_contains_file "$SQLCMD_QUERY_FILE" 'sys.views'
assert_contains_file "$SQLCMD_QUERY_FILE" 'sys.procedures'
assert_contains_file "$SQLCMD_QUERY_FILE" 'sys.foreign_keys'
assert_contains_file "$SQLCMD_QUERY_FILE" 'sys.indexes'
assert_contains_file "$SQLCMD_QUERY_FILE" 'is_ms_shipped'
if grep -Eiq '(^|[^[:alpha:]])(insert|update|delete|merge|drop|alter|create|truncate)([^[:alpha:]]|$)' "$SQLCMD_QUERY_FILE"; then
  fail_test "Source inventory query is not read-only"
fi

TEST_TLS_MODE=strict collect_source_object_inventory 0 "$tmpdir/autokit/source-strict.tsv"
assert_contains_file "$SQLCMD_ARGS_FILE" '-Ns'
TEST_TLS_MODE=trust collect_source_object_inventory 0 "$tmpdir/autokit/source-trust.tsv"
assert_contains_file "$SQLCMD_ARGS_FILE" '-Nm'
assert_contains_file "$SQLCMD_ARGS_FILE" '-C'

for mode in empty malformed fail; do
  preserved="$tmpdir/autokit/source-$mode.tsv"
  printf 'preserve-source-%s\n' "$mode" > "$preserved"
  set +e
  SQLCMD_MODE="$mode" collect_source_object_inventory 0 "$preserved" >/dev/null 2>&1
  rc=$?
  set -e
  [[ $rc -ne 0 ]] || fail_test "Source collector unexpectedly accepted $mode output"
  [[ "$(cat "$preserved")" == "preserve-source-$mode" ]] || fail_test "Source collector replaced evidence after $mode output"
done

target_inventory="$tmpdir/autokit/target_object_inventory.tsv"
collect_target_object_inventory 0 "$tmpdir/sdcli" "$target_inventory"
[[ "$(head -n 1 "$target_inventory")" == "$expected_header" ]] || fail_test "Unexpected target inventory header"
assert_contains_file "$SQLPLUS_INPUT_FILE" "UPPER('App')"
assert_contains_file "$SQLPLUS_INPUT_FILE" "UPPER('Emulation')"
assert_not_contains_file "$SQLPLUS_INPUT_FILE" "UPPER('ADMIN')"
assert_contains_file "$SQLPLUS_INPUT_FILE" 'all_objects'
assert_contains_file "$SQLPLUS_INPUT_FILE" 'all_constraints'
assert_contains_file "$SQLPLUS_INPUT_FILE" 'all_indexes'
assert_contains_file "$SQLPLUS_INPUT_FILE" 'all_errors'
assert_contains_file "$SQLPLUS_INPUT_FILE" 'all_triggers'
assert_contains_file "$SQLPLUS_INPUT_FILE" 'all_tab_columns'
assert_contains_file "$SQLPLUS_INPUT_FILE" "c.generated = 'USER NAME'"
if grep -Eiq '(^|[^[:alpha:]])(insert|update|delete|merge|drop|truncate)([^[:alpha:]]|$)' "$SQLPLUS_INPUT_FILE"; then
  fail_test "Target inventory query is not read-only"
fi
assert_not_contains_file "$target_inventory" 'Target-Secret-42!'
assert_not_contains_file "$RUN_LOG_FILE" 'Target-Secret-42!'

for mode in empty malformed fail; do
  preserved="$tmpdir/autokit/target-$mode.tsv"
  printf 'preserve-target-%s\n' "$mode" > "$preserved"
  set +e
  SQLPLUS_MODE="$mode" collect_target_object_inventory 0 "$tmpdir/sdcli" "$preserved" >/dev/null 2>&1
  rc=$?
  set -e
  [[ $rc -ne 0 ]] || fail_test "Target collector unexpectedly accepted $mode output"
  [[ "$(cat "$preserved")" == "preserve-target-$mode" ]] || fail_test "Target collector replaced evidence after $mode output"
done

cat > "$tmpdir/bin/python3" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$PYTHON_ARGS_FILE"
args=("$@")
for ((i = 0; i + 1 < ${#args[@]}; i++)); do
  if [[ "${args[$i]}" == "--output" ]]; then
    printf '<html>report</html>\n' > "${args[$((i + 1))]}"
  fi
done
printf 'REPORT_RESULT status=%s\n' "${PYTHON_REPORT_STATUS:-PASS}"
[[ "${PYTHON_REPORT_STATUS:-PASS}" == PASS ]] && exit 0
exit 2
SH
chmod +x "$tmpdir/bin/python3"
export PYTHON_ARGS_FILE="$tmpdir/python.args"
RUN_NAME=run_20261016_120000
RUN_ID=20261016_130000

run_validation_report "$tmpdir/sdcli" 0
assert_contains_file "$PYTHON_ARGS_FILE" "$REPO_ROOT/sdcli-scripts/lib/generate_validation_report.py"
assert_contains_file "$PYTHON_ARGS_FILE" '--sdcli-dir'
assert_contains_file "$PYTHON_ARGS_FILE" "$tmpdir/sdcli"
assert_contains_file "$PYTHON_ARGS_FILE" '--evidence-dir'
assert_contains_file "$PYTHON_ARGS_FILE" "$tmpdir/autokit"
assert_contains_file "$PYTHON_ARGS_FILE" '--migration'
assert_contains_file "$PYTHON_ARGS_FILE" 'sales'
assert_contains_file "$PYTHON_ARGS_FILE" '--run-id'
assert_contains_file "$PYTHON_ARGS_FILE" '20261016_120000'

set +e
PYTHON_REPORT_STATUS=FAIL run_validation_report "$tmpdir/sdcli" 0 >/dev/null 2>&1
report_rc=$?
set -e
[[ $report_rc -eq 2 ]] || fail_test "Report runner did not preserve the report CLI finding exit code"

echo "validation metadata collection test passed"
