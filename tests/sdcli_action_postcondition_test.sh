#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATE_SH_SOURCE_ONLY=true source "$REPO_ROOT/sdcli-scripts/migrate.sh"

fail_test() {
  echo "$1" >&2
  exit 1
}

expect_failure() {
  local label="$1"
  shift
  local rc
  set +e
  ( "$@" ) >/dev/null 2>&1
  rc=$?
  set -e
  [[ $rc -ne 0 ]] || fail_test "Expected missing $label evidence to fail"
}

expect_model_lookup_failure() {
  local label="$1"
  shift
  local rc
  set +e
  "$@" >/dev/null 2>&1
  rc=$?
  set -e
  [[ $rc -ne 0 ]] || fail_test "Expected $label to fail"
  [[ -z "$SDCLI_VERIFIED_MODEL_INDEX" ]] \
    || fail_test "$label retained a stale model index"
}

tmpdir="$(mktemp -d)"
SDCLI_PROFILE_DIR="$tmpdir/profile"
trap 'rm -rf "$tmpdir"' EXIT

RUN_ID="20261019_100000"
RUN_NAME="run_$RUN_ID"
RUN_DIR="$tmpdir/run"
AUTOKIT_DIR="$RUN_DIR/autokit"
output_dir="$RUN_DIR/sdcli"
schema_dir="$output_dir/App"
datamove_dir="$output_dir/datamove/App"
mkdir -p \
  "$AUTOKIT_DIR/deploy" \
  "$AUTOKIT_DIR/cleanup" \
  "$schema_dir" \
  "$datamove_dir/control" \
  "$datamove_dir/data" \
  "$tmpdir/bin"

RUN_LOG_FILE="$AUTOKIT_DIR/migrate.log"
SDCLI_COMMAND_LOG="$AUTOKIT_DIR/sdcli_commands.log"
touch "$RUN_LOG_FILE" "$SDCLI_COMMAND_LOG"
DRY_RUN=false
ACTIVE_REPOSITORY_NAME='migration_repo_demo'
ACTIVE_REPOSITORY_CONN='tcps://demo.example:1522/demo_high'
export FAKE_MODEL_LIST_FIXTURE="$REPO_ROOT/tests/fixtures/sdcli/model-list-26.2.txt"

cat > "$tmpdir/bin/sdcli" <<'SCRIPT'
#!/usr/bin/env bash
action=""
printf '%s\n' "$IDE_USER_DIR" > "$SDCLI_ARGS_FILE"
for arg in "$@"; do
  [[ "$arg" == -actions=* ]] && action="${arg#-actions=}"
done
if [[ "${FAKE_MODEL_LOOKUP_HAS_MODEL:-false}" == "true" ]]; then
  case "${FAKE_MODEL_LIST_STYLE:-fixture}" in
    fixture)
      cat "${FAKE_MODEL_LIST_FIXTURE:?}"
      ;;
    legacy)
      printf '4) --> Model Name : %s\n' "${FAKE_EXPECTED_MODEL:?}"
      ;;
    malformed)
      printf '(1 --> Model Name : %s\n' "${FAKE_EXPECTED_MODEL:?}"
      ;;
    duplicate)
      printf '(2) --> Model Name : %s\n' "${FAKE_EXPECTED_MODEL:?}"
      printf '(3) --> Model Name : %s\n' "${FAKE_EXPECTED_MODEL:?}"
      ;;
    *)
      printf 'Unsupported fake model-list style: %s\n' "$FAKE_MODEL_LIST_STYLE" >&2
      exit 2
      ;;
  esac
fi
printf '%s completed successfully\n' "$action"
SCRIPT
chmod +x "$tmpdir/bin/sdcli"
PATH="$tmpdir/bin:$PATH"
export SDCLI_ARGS_FILE="$tmpdir/sdcli.args"

cat > "$output_dir/role.sql" <<'SQL'
CREATE ROLE ROLE_APP;
DROP ROLE ROLE_APP;
SQL
touch "$AUTOKIT_DIR/deploy/role_setup.sql" "$AUTOKIT_DIR/cleanup/role_cleanup.sql"
touch "$schema_dir/user.sql" "$schema_dir/tables.sql" "$schema_dir/indexes.sql" "$schema_dir/post.sql"
cat > "$schema_dir/master.sql" <<'SQL'
@@"App/tables.sql"
@@"App/indexes.sql"
SQL

cat > "$datamove_dir/MicrosoftSQLServer_data.sh" <<'SH'
#!/usr/bin/env bash
bcp demo.dbo.orders out data/orders.dat -q -c -U"$2" -P"$3" -S"$1"
SH
cat > "$datamove_dir/oracle_loader.sh" <<'SH'
#!/usr/bin/env bash
sqlldr userid="$2/$3@$1" control=control/orders.ctl
SH
cat > "$datamove_dir/control/orders.ctl" <<'CTL'
load data
infile '../data/orders.dat'
into table APP.ORDERS
(ID)
CTL
touch "$datamove_dir/data/orders.dat" "$datamove_dir/control/orders.log"

bcp_data_file="$datamove_dir/data/orders.dat"
control_file="$datamove_dir/control/orders.ctl"
sqlldr_log_file="$datamove_dir/control/orders.log"
printf '0\tdemo.dbo.orders\t%s\t1\n' "$bcp_data_file" > "$AUTOKIT_DIR/bcp_status.tsv"
printf '0\tAPP.ORDERS\t%s\t%s\t1\t0\t0\t%s\n' \
  "$control_file" "$bcp_data_file" "$sqlldr_log_file" > "$AUTOKIT_DIR/sqlldr_status.tsv"

cat > "$AUTOKIT_DIR/deploy_manifest.tsv" <<'TSV'
phase	path	status	note
deploy	autokit/deploy/role_setup.sql	executed	role setup
deploy	sdcli/App/user.sql	executed	user setup
deploy	sdcli/App/tables.sql	executed	pre-data master include
postdeploy	sdcli/App/indexes.sql	executed	post-data master include
postdeploy	sdcli/App/post.sql	executed	post-load compile and status script
cleanup	autokit/cleanup/role_cleanup.sql	executed	explicit role cleanup
TSV

cat > "$AUTOKIT_DIR/validation_checks.tsv" <<'TSV'
check	status	issues	detail
run_log	PASS	0	migration run-log diagnostics
sdcli_error_log	PASS	0	SDCLI ERROR/FATAL entries
sqlldr_logs	PASS	0	SQL*Loader log diagnostics
missing_evidence	PASS	0	required SQL*Loader log evidence
reconciliation	PASS	0	table data reconciliation
target_objects	PASS	0	Oracle invalid objects or compiler errors
metadata_collection	PASS	0	source or target object inventory
TSV
printf 'status=PASS\ntotal_issues=0\n' > "$AUTOKIT_DIR/validation_summary.txt"
touch "$AUTOKIT_DIR/migration_report.html" "$AUTOKIT_DIR/migration_report.txt"

project_name="demo"
expected_model="${project_name}_${RUN_ID}"
export FAKE_EXPECTED_MODEL="$expected_model"
export FAKE_MODEL_LOOKUP_HAS_MODEL=true

set_sdcli_postcondition_state() {
  SDCLI_LAST_ACTION="$1"
  SDCLI_LAST_SUCCESS_MARKER=true
}

set_sdcli_postcondition_state capture
FAKE_MODEL_LOOKUP_HAS_MODEL=false
export FAKE_MODEL_LOOKUP_HAS_MODEL
expect_failure "capture model" verify_phase_postcondition capture "$expected_model" "$project_name" "$output_dir"
FAKE_MODEL_LOOKUP_HAS_MODEL=true
export FAKE_MODEL_LOOKUP_HAS_MODEL

set_sdcli_postcondition_state convert
FAKE_MODEL_LOOKUP_HAS_MODEL=false
export FAKE_MODEL_LOOKUP_HAS_MODEL
expect_failure "converted model" verify_phase_postcondition convert latest "$project_name" "$output_dir"
FAKE_MODEL_LOOKUP_HAS_MODEL=true
export FAKE_MODEL_LOOKUP_HAS_MODEL

set_sdcli_postcondition_state capture
SDCLI_LAST_SUCCESS_MARKER=false
expect_failure "exact capture success marker" verify_phase_postcondition capture "$expected_model" "$project_name" "$output_dir"

# Exercise the real phase boundary so removing the postcondition call from
# run_phase cannot leave the focused verifier tests green.
migration_required_value() {
  [[ "$2 $3" == "source conn" ]] && echo "db.example:1433:demo"
}
check_source_tcp_connectivity() { :; }
PHASE_STATUS_FILE="$AUTOKIT_DIR/phase_status.tsv"
printf 'timestamp\tphase\tstate\texit_code\tattempt\tnote\n' > "$PHASE_STATUS_FILE"
FAKE_MODEL_LOOKUP_HAS_MODEL=false
export FAKE_MODEL_LOOKUP_HAS_MODEL
expect_failure "run_phase capture model" run_phase capture repository src target "$expected_model" "$project_name" "$output_dir" 0
if awk -F '\t' '$2 == "capture" && $3 == "succeeded" { found=1 } END { exit(found ? 0 : 1) }' "$PHASE_STATUS_FILE"; then
  fail_test "A failed capture postcondition was recorded as succeeded"
fi
FAKE_MODEL_LOOKUP_HAS_MODEL=true
export FAKE_MODEL_LOOKUP_HAS_MODEL

mv "$schema_dir/master.sql" "$schema_dir/master.sql.missing"
expect_failure "generate inventory" verify_phase_postcondition generate latest "$project_name" "$output_dir"
mv "$schema_dir/master.sql.missing" "$schema_dir/master.sql"

mv "$control_file" "$control_file.missing"
expect_failure "datamove control file" verify_phase_postcondition datamove latest "$project_name" "$output_dir"
mv "$control_file.missing" "$control_file"
mv "$datamove_dir/oracle_loader.sh" "$datamove_dir/oracle_loader.sh.missing"
expect_failure "datamove loader script" verify_phase_postcondition datamove latest "$project_name" "$output_dir"
mv "$datamove_dir/oracle_loader.sh.missing" "$datamove_dir/oracle_loader.sh"

mv "$AUTOKIT_DIR/bcp_status.tsv" "$AUTOKIT_DIR/bcp_status.tsv.missing"
expect_failure "offload status" verify_phase_postcondition offload latest "$project_name" "$output_dir"
mv "$AUTOKIT_DIR/bcp_status.tsv.missing" "$AUTOKIT_DIR/bcp_status.tsv"

mv "$AUTOKIT_DIR/deploy_manifest.tsv" "$AUTOKIT_DIR/deploy_manifest.tsv.missing"
expect_failure "deploy manifest" verify_phase_postcondition deploy latest "$project_name" "$output_dir"
expect_failure "postdeploy manifest" verify_phase_postcondition postdeploy latest "$project_name" "$output_dir"
expect_failure "cleanup manifest" verify_phase_postcondition cleanup latest "$project_name" "$output_dir"
mv "$AUTOKIT_DIR/deploy_manifest.tsv.missing" "$AUTOKIT_DIR/deploy_manifest.tsv"

mv "$AUTOKIT_DIR/sqlldr_status.tsv" "$AUTOKIT_DIR/sqlldr_status.tsv.missing"
expect_failure "load status" verify_phase_postcondition load latest "$project_name" "$output_dir"
mv "$AUTOKIT_DIR/sqlldr_status.tsv.missing" "$AUTOKIT_DIR/sqlldr_status.tsv"

mv "$AUTOKIT_DIR/validation_checks.tsv" "$AUTOKIT_DIR/validation_checks.tsv.missing"
expect_failure "validation checks" verify_phase_postcondition validate latest "$project_name" "$output_dir"
mv "$AUTOKIT_DIR/validation_checks.tsv.missing" "$AUTOKIT_DIR/validation_checks.tsv"

set_sdcli_postcondition_state capture
verify_phase_postcondition capture "$expected_model" "$project_name" "$output_dir"
[[ "$SDCLI_VERIFIED_MODEL_INDEX" == "2" ]] \
  || fail_test "capture model lookup did not return the fixture index"
grep -Fx -- "$SDCLI_PROFILE_DIR" "$SDCLI_ARGS_FILE" >/dev/null \
  || fail_test "capture model lookup did not use the selected profile"
set_sdcli_postcondition_state convert
verify_phase_postcondition convert latest "$project_name" "$output_dir"
[[ "$SDCLI_VERIFIED_MODEL_INDEX" == "2" ]] \
  || fail_test "converted model lookup did not return the fixture index"
grep -Fx -- "$SDCLI_PROFILE_DIR" "$SDCLI_ARGS_FILE" >/dev/null \
  || fail_test "converted model lookup did not use the selected profile"
FAKE_MODEL_LIST_STYLE=legacy
export FAKE_MODEL_LIST_STYLE
set_sdcli_postcondition_state capture
expect_model_lookup_failure "unsupported legacy model-list format" verify_phase_postcondition capture "$expected_model" "$project_name" "$output_dir"
FAKE_MODEL_LIST_STYLE=malformed
export FAKE_MODEL_LIST_STYLE
set_sdcli_postcondition_state capture
expect_model_lookup_failure "malformed model index" verify_phase_postcondition capture "$expected_model" "$project_name" "$output_dir"
FAKE_MODEL_LIST_STYLE=duplicate
export FAKE_MODEL_LIST_STYLE
set_sdcli_postcondition_state capture
expect_model_lookup_failure "duplicate model name" verify_phase_postcondition capture "$expected_model" "$project_name" "$output_dir"
unset FAKE_MODEL_LIST_STYLE
for phase in generate datamove offload deploy load postdeploy validate cleanup; do
  verify_phase_postcondition "$phase" latest "$project_name" "$output_dir"
done

# A failed SQL*Plus attempt must still be represented in the manifest. This is
# evidence collection, not recovery: the phase remains failed.
migration_required_value() {
  case "$2 $3" in
    "source conn") echo "db.example:1433:demo" ;;
    "target conn") echo "adb.example/high" ;;
    "target user") echo "admin" ;;
    *) return 1 ;;
  esac
}
migration_secret_value() {
  [[ "$2 $3" == "target password" ]] && echo "TargetPass1"
}
run_sqlplus_file() { return 1; }

expect_failure "deploy SQL*Plus result" run_deploy 0 "$output_dir"
grep -F $'deploy\tautokit/deploy/role_setup.sql\tfailed\t' "$AUTOKIT_DIR/deploy_manifest.tsv" >/dev/null \
  || fail_test "Failed deploy attempt was not recorded in the manifest"

expect_failure "cleanup SQL*Plus result" run_cleanup 0 "$output_dir"
grep -F $'cleanup\tautokit/cleanup/role_cleanup.sql\tfailed\t' "$AUTOKIT_DIR/deploy_manifest.tsv" >/dev/null \
  || fail_test "Failed cleanup attempt was not recorded in the manifest"

echo "SDCLI action postcondition test passed"
