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

RUN_DIR="$tmpdir/run"
AUTOKIT_DIR="$RUN_DIR/autokit"
output_dir="$RUN_DIR/sdcli"
mkdir -p "$AUTOKIT_DIR" "$output_dir/gen"

cat > "$output_dir/passworddefinition.sql" <<'SQL'
ACCEPT tpcc_password PROMPT "Provide the password for tpcc: " HIDE
ACCEPT tpcc_copy_tpcc_password PROMPT "Provide the password for tpcc_copy_tpcc: " HIDE
ACCEPT Emulation_password PROMPT "Provide the password for Emulation: " HIDE
SQL

cat > "$output_dir/role.sql" <<'SQL'
CREATE ROLE old_fallback_role;
SQL

cat > "$output_dir/gen/generated-1.sql" <<'SQL'
@passworddefinition.sql
DROP ROLE ROLE_tpcc_20260427_014117 ;
CREATE ROLE ROLE_tpcc_20260427_014117 ;
CREATE USER tpcc IDENTIFIED BY &&tpcc_password PASSWORD EXPIRE ACCOUNT LOCK;
SQL

fakebin="$tmpdir/bin"
mkdir -p "$fakebin"
cat > "$fakebin/sqlplus" <<'SCRIPT'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$SQLPLUS_ARGS_FILE"
stdin_text="$(cat)"
printf '%s' "$stdin_text" > "$SQLPLUS_STDIN_FILE"
for arg in "$@"; do
  case "$arg" in
    @*) cat "${arg#@}" > "$SQLPLUS_WRAPPER_FILE" ;;
  esac
done
while IFS= read -r line; do
  case "$line" in
    @\"*\")
      wrapper_path="${line#@\"}"
      wrapper_path="${wrapper_path%\"}"
      cat "$wrapper_path" > "$SQLPLUS_WRAPPER_FILE"
      ;;
  esac
done <<< "$stdin_text"
cat passworddefinition.sql > "$SQLPLUS_PASSWORD_FILE"
printf '%s\n' 'CREATE USER tpcc IDENTIFIED BY SchemaPass1 PASSWORD EXPIRE ACCOUNT LOCK;'
SCRIPT
chmod +x "$fakebin/sqlplus"

SQLPLUS_ARGS_FILE="$tmpdir/sqlplus.args"
SQLPLUS_STDIN_FILE="$tmpdir/sqlplus.stdin"
SQLPLUS_PASSWORD_FILE="$tmpdir/passworddefinition.executed.sql"
SQLPLUS_WRAPPER_FILE="$tmpdir/sqlplus.wrapper.sql"
export SQLPLUS_ARGS_FILE SQLPLUS_STDIN_FILE SQLPLUS_PASSWORD_FILE SQLPLUS_WRAPPER_FILE
PATH="$fakebin:$PATH"

RUN_LOG_FILE="$tmpdir/sqlplus.log"
touch "$RUN_LOG_FILE"
run_sqlplus_file "$output_dir" "gen/generated-1.sql" "adb.example/high" "admin" "AdminPass1" "SchemaPass1" 3
sqlplus_args="$(cat "$SQLPLUS_ARGS_FILE")"
sqlplus_stdin="$(cat "$SQLPLUS_STDIN_FILE")"
sqlplus_password_file="$(cat "$SQLPLUS_PASSWORD_FILE")"
sqlplus_wrapper="$(cat "$SQLPLUS_WRAPPER_FILE")"
assert_contains "$sqlplus_args" "/nolog"
assert_not_contains "$sqlplus_args" "AdminPass1"
assert_contains "$sqlplus_stdin" 'connect admin/"AdminPass1"@adb.example/high'
assert_not_contains "$sqlplus_stdin" "@gen/generated-1.sql"
assert_not_contains "$sqlplus_stdin" "SchemaPass1"
assert_not_contains "$sqlplus_wrapper" "alter session set current_schema"
assert_contains "$sqlplus_password_file" "DEFINE tpcc_password = \"SchemaPass1\""
assert_contains "$sqlplus_password_file" "DEFINE tpcc_copy_tpcc_password = \"SchemaPass1\""
assert_contains "$sqlplus_password_file" "DEFINE Emulation_password = \"SchemaPass1\""
assert_not_contains "$sqlplus_password_file" "ACCEPT"
assert_contains "$(cat "$output_dir/passworddefinition.sql")" "ACCEPT tpcc_password"

mkdir -p "$output_dir/tpcc"
touch "$output_dir/tpcc/tables.sql"
cat > "$output_dir/tpcc/master.sql" <<'SQL'
@@"tpcc/tables.sql"
SQL
run_sqlplus_file "$output_dir" "tpcc/tables.sql" "adb.example/high" "admin" "AdminPass1" "" 0 "tpcc"
sqlplus_wrapper="$(cat "$SQLPLUS_WRAPPER_FILE")"
assert_contains "$sqlplus_wrapper" "alter session set current_schema = tpcc;"
assert_contains "$sqlplus_wrapper" "set define off"
assert_contains "$sqlplus_wrapper" "@\"tpcc/tables.sql\""
assert_contains "$sqlplus_wrapper" "set define on"

declare -a file_calls=()

get_required_value() {
  case "$1" in
    ".migrations[0].target.conn") echo "adb.example/high" ;;
    ".migrations[0].target.user") echo "admin" ;;
    *) echo "unexpected config path: $1" >&2; return 1 ;;
  esac
}

get_secret_value() {
  case "$1" in
    ".migrations[0].target.password") echo "AdminPass1" ;;
    ".migrations[0].target.default_schema_password") echo "SchemaPass1" ;;
    *) echo "unexpected secret path: $1" >&2; return 1 ;;
  esac
}

run_sqlplus_file() {
  file_calls+=("$2|${6:-}|${7:-0}|${8:-}")
}

DRY_RUN=false
RUN_LOG_FILE="$tmpdir/run.log"
touch "$RUN_LOG_FILE"
touch "$output_dir/tpcc/user.sql"
run_deploy 0 "$output_dir"
deploy_output="$(cat "$RUN_LOG_FILE")"
assert_not_contains "$deploy_output" "defaults.deploy_preferences.schema_password"
assert_contains "$deploy_output" "migrations[0].target.default_schema_password"

[[ "${#file_calls[@]}" -eq 3 ]]
assert_contains "${file_calls[*]}" "role.sql||0|"
assert_contains "${file_calls[*]}" "tpcc/user.sql|SchemaPass1|3|"
assert_contains "${file_calls[*]}" "tpcc/tables.sql||0|tpcc"
assert_not_contains "${file_calls[*]}" "gen/generated-1.sql"
assert_contains "$(cat "$AUTOKIT_DIR/deploy_manifest.tsv")" $'plan\tsdcli/gen/generated-1.sql\texcluded\tduplicate monolithic output; schema hierarchy selected'

masked="$(printf '%s\n' \
  'CREATE USER tpcc IDENTIFIED BY SchemaPass1 PASSWORD EXPIRE ACCOUNT LOCK;' \
  'new   1: CREATE USER tpcc IDENTIFIED BY SchemaPass1 PASSWORD EXPIRE ACCOUNT LOCK;' \
  | filter_sqlplus_deploy_output)"
assert_contains "$masked" "IDENTIFIED BY *** PASSWORD"
assert_not_contains "$masked" "SchemaPass1"
