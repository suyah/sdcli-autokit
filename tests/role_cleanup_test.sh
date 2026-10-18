#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATE_SH_SOURCE_ONLY=true source "$REPO_ROOT/sdcli-scripts/migrate.sh"

assert_contains() {
  [[ "$1" == *"$2"* ]] || {
    echo "Expected output to contain: $2" >&2
    exit 1
  }
}

assert_not_contains() {
  [[ "$1" != *"$2"* ]] || {
    echo "Expected output not to contain: $2" >&2
    exit 1
  }
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

RUN_DIR="$tmpdir/run"
AUTOKIT_DIR="$RUN_DIR/autokit"
output_dir="$RUN_DIR/sdcli"
mkdir -p "$AUTOKIT_DIR" "$output_dir/app"

cat > "$output_dir/role.sql" <<'SQL'
PROMPT Preparing migration roles
DROP ROLE ROLE_app_20261015_045253;
DROP ROLE "Mixed Role";
DROP/**/ROLE ROLE_COMMENT_GAP;
/*
DROP ROLE ROLE_COMMENT_ONLY;
*/
CREATE ROLE ROLE_app_20261015_045253;
CREATE ROLE "Mixed Role";
SQL

touch "$output_dir/app/user.sql"
cat > "$output_dir/app/master.sql" <<'SQL'
@@"app/tables.sql"
@@"app/views.sql"
SQL
cat > "$output_dir/app/tables.sql" <<'SQL'
-- DROP TABLE old_table;
/*
DROP TABLE another_old_table;
*/
CREATE TABLE app_table (id NUMBER);
SQL
cat > "$output_dir/app/views.sql" <<'SQL'
CREATE VIEW app_view AS SELECT id FROM app_table;
SQL

get_required_value() {
  case "$1" in
    ".migrations[0].target.conn") echo "adb.example/high" ;;
    ".migrations[0].target.user") echo "admin" ;;
    *) return 1 ;;
  esac
}

get_secret_value() {
  case "$1" in
    ".migrations[0].target.password") echo "AdminPass1" ;;
    *) return 1 ;;
  esac
}

prepare_role_scripts "$output_dir"
setup_file="$AUTOKIT_DIR/deploy/role_setup.sql"
cleanup_file="$AUTOKIT_DIR/cleanup/role_cleanup.sql"

fakebin="$tmpdir/bin"
mkdir -p "$fakebin"
cat > "$fakebin/sqlplus" <<'SCRIPT'
#!/usr/bin/env bash
pwd > "$SQLPLUS_CWD_FILE"
stdin_text="$(cat)"
printf '%s' "$stdin_text" > "$SQLPLUS_STDIN_FILE"
while IFS= read -r line; do
  case "$line" in
    @\"*\")
      wrapper_path="${line#@\"}"
      wrapper_path="${wrapper_path%\"}"
      cat "$wrapper_path" > "$SQLPLUS_WRAPPER_FILE"
      ;;
  esac
done <<< "$stdin_text"
SCRIPT
chmod +x "$fakebin/sqlplus"
SQLPLUS_CWD_FILE="$tmpdir/sqlplus.cwd"
SQLPLUS_STDIN_FILE="$tmpdir/sqlplus.stdin"
SQLPLUS_WRAPPER_FILE="$tmpdir/sqlplus.wrapper"
export SQLPLUS_CWD_FILE SQLPLUS_STDIN_FILE SQLPLUS_WRAPPER_FILE
PATH="$fakebin:$PATH"

DRY_RUN=false
RUN_LOG_FILE="$tmpdir/run.log"
touch "$RUN_LOG_FILE"
run_sqlplus_file "$AUTOKIT_DIR/deploy" "role_setup.sql" "adb.example/high" "admin" "AdminPass1" "" 0 "" false "$output_dir"
[[ "$(cat "$SQLPLUS_CWD_FILE")" == "$output_dir" ]]
assert_contains "$(cat "$SQLPLUS_WRAPPER_FILE")" "@\"$AUTOKIT_DIR/deploy/role_setup.sql\""

declare -a calls=()
run_sqlplus_file() {
  calls+=("$1/$2")
}

run_deploy 0 "$output_dir"

[[ -f "$setup_file" ]]
[[ -f "$cleanup_file" ]]
assert_not_contains "$(cat "$setup_file")" "DROP ROLE ROLE_app_20261015_045253;"
assert_not_contains "$(cat "$setup_file")" 'DROP ROLE "Mixed Role";'
assert_contains "$(cat "$setup_file")" "DROP ROLE ROLE_COMMENT_ONLY;"
assert_contains "$(cat "$setup_file")" "CREATE ROLE ROLE_app_20261015_045253;"
assert_contains "$(cat "$setup_file")" 'CREATE ROLE "Mixed Role";'
assert_contains "$(cat "$cleanup_file")" "EXECUTE IMMEDIATE 'DROP ROLE ROLE_app_20261015_045253';"
assert_contains "$(cat "$cleanup_file")" "EXECUTE IMMEDIATE 'DROP ROLE \"Mixed Role\"';"
assert_contains "$(cat "$cleanup_file")" "EXECUTE IMMEDIATE 'DROP ROLE ROLE_COMMENT_GAP';"
assert_not_contains "$(cat "$cleanup_file")" "ROLE_COMMENT_ONLY"
assert_contains "$(cat "$cleanup_file")" "PRAGMA EXCEPTION_INIT(role_missing, -1919);"
assert_contains "$(cat "$output_dir/role.sql")" "DROP ROLE ROLE_app_20261015_045253;"
assert_contains "${calls[*]}" "$AUTOKIT_DIR/deploy/role_setup.sql"
assert_not_contains "${calls[*]}" "$output_dir/role.sql"

calls=()
run_cleanup 0 "$output_dir"
assert_contains "${calls[*]}" "$AUTOKIT_DIR/cleanup/role_cleanup.sql"
assert_contains "$(cat "$AUTOKIT_DIR/deploy_manifest.tsv")" $'cleanup\t'
assert_contains "$(cat "$AUTOKIT_DIR/deploy_manifest.tsv")" $'deploy\t'

cat > "$output_dir/role.sql" <<'SQL'
DROP TABLE unexpected_object;
CREATE ROLE ROLE_app;
SQL
set +e
( prepare_role_scripts "$output_dir" ) >/dev/null 2>&1
unsupported_drop_rc=$?
set -e
[[ $unsupported_drop_rc -ne 0 ]]

(
  parse_args app --deploy --run 20261015_045253
  [[ "$MODE" == "phase" ]]
  [[ "$PHASE_NAME" == "deploy" ]]
  [[ "$RUN_NAME_INPUT" == "20261015_045253" ]]
)

(
  parse_args app --cleanup --run 20261015_045253
  [[ "$MODE" == "phase" ]]
  [[ "$PHASE_NAME" == "cleanup" ]]
  [[ "$RUN_NAME_INPUT" == "20261015_045253" ]]
)

set +e
( parse_args app --cleanup ) >/dev/null 2>&1
missing_run_rc=$?
set -e
[[ $missing_run_rc -ne 0 ]]

echo "role cleanup test passed"
