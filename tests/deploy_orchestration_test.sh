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

assert_line() {
  local file="$1"
  local expected="$2"
  grep -Fx "$expected" "$file" >/dev/null || {
    echo "Expected line in $file: $expected" >&2
    cat "$file" >&2
    exit 1
  }
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

RUN_DIR="$tmpdir/run"
AUTOKIT_DIR="$RUN_DIR/autokit"
output_dir="$RUN_DIR/sdcli"
mkdir -p "$AUTOKIT_DIR" "$output_dir/gen" "$output_dir/Emulation" "$output_dir/tpcc" "$output_dir/tpcc_copy_tpcc"

cat > "$output_dir/passworddefinition.sql" <<'SQL'
ACCEPT tpcc_password PROMPT "Provide the password for tpcc: " HIDE
SQL
cat > "$output_dir/role.sql" <<'SQL'
CREATE ROLE ROLE_tpcc;
SQL
touch "$output_dir/gen/generated-1.sql"

touch "$output_dir/Emulation/user.sql"
cat > "$output_dir/Emulation/master.sql" <<'SQL'
@@"Emulation/packages.sql"
SQL
touch "$output_dir/Emulation/packages.sql"
touch "$output_dir/Emulation/post.sql"

touch "$output_dir/tpcc/user.sql"
touch "$output_dir/tpcc/tables.sql"
touch "$output_dir/tpcc/indexes.sql"
touch "$output_dir/tpcc/synonyms.sql"
touch "$output_dir/tpcc/procedures.sql"
cat > "$output_dir/tpcc/master.sql" <<'SQL'
@@"tpcc/tables.sql"
@@"tpcc/indexes.sql"
@@"tpcc/synonyms.sql"
@@"tpcc/procedures.sql"
SQL
touch "$output_dir/tpcc/post.sql"

touch "$output_dir/tpcc_copy_tpcc/user.sql"
touch "$output_dir/tpcc_copy_tpcc/tables.sql"
touch "$output_dir/tpcc_copy_tpcc/synonyms.sql"
cat > "$output_dir/tpcc_copy_tpcc/master.sql" <<'SQL'
@@"tpcc_copy_tpcc/tables.sql"
@@"tpcc_copy_tpcc/synonyms.sql"
SQL
touch "$output_dir/tpcc_copy_tpcc/post.sql"

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

declare -a calls=()
run_sqlplus_file() {
  calls+=("$2|${6:-}|${7:-0}|${8:-}")
}

DRY_RUN=false
RUN_LOG_FILE="$tmpdir/run.log"
touch "$RUN_LOG_FILE"

run_deploy 0 "$output_dir"

deploy_calls="${calls[*]}"
expected_deploy_calls=(
  "role_setup.sql||0|"
  "Emulation/user.sql|SchemaPass1|1|"
  "tpcc/user.sql|SchemaPass1|1|"
  "tpcc_copy_tpcc/user.sql|SchemaPass1|1|"
  "tpcc/tables.sql||0|tpcc"
  "tpcc_copy_tpcc/tables.sql||0|tpcc_copy_tpcc"
)
[[ "${#calls[@]}" -eq "${#expected_deploy_calls[@]}" ]]
for i in "${!expected_deploy_calls[@]}"; do
  [[ "${calls[$i]}" == "${expected_deploy_calls[$i]}" ]] || {
    echo "Unexpected deploy call order at $i" >&2
    printf 'expected: %s\nactual:   %s\n' "${expected_deploy_calls[$i]}" "${calls[$i]}" >&2
    exit 1
  }
done
assert_contains "$deploy_calls" "role_setup.sql||0|"
assert_contains "$deploy_calls" "Emulation/user.sql|SchemaPass1|1|"
assert_contains "$deploy_calls" "tpcc/user.sql|SchemaPass1|1|"
assert_contains "$deploy_calls" "tpcc/tables.sql||0|tpcc"
assert_contains "$deploy_calls" "tpcc_copy_tpcc/user.sql|SchemaPass1|1|"
assert_contains "$deploy_calls" "tpcc_copy_tpcc/tables.sql||0|tpcc_copy_tpcc"
assert_not_contains "$deploy_calls" "gen/generated-1.sql"
assert_not_contains "$deploy_calls" "master.sql"
assert_not_contains "$deploy_calls" "procedures.sql"
assert_not_contains "$deploy_calls" "packages.sql"

manifest="$AUTOKIT_DIR/deploy_manifest.tsv"
assert_line "$manifest" $'phase\tpath\tstatus\tnote'
assert_line "$manifest" $'deploy\tautokit/deploy/role_setup.sql\texecuted\tderived from sdcli/role.sql; DROP ROLE is available through --cleanup'
assert_line "$manifest" $'deploy\tsdcli/Emulation/user.sql\texecuted\t'
assert_line "$manifest" $'deploy\tsdcli/tpcc/user.sql\texecuted\t'
assert_line "$manifest" $'deploy\tsdcli/tpcc/tables.sql\texecuted\tpre-data master include'
assert_line "$manifest" $'deploy\tsdcli/tpcc_copy_tpcc/user.sql\texecuted\t'
assert_line "$manifest" $'deploy\tsdcli/tpcc_copy_tpcc/tables.sql\texecuted\tpre-data master include'
assert_line "$manifest" $'plan\tsdcli/gen/generated-1.sql\texcluded\tduplicate monolithic output; schema hierarchy selected'

calls=()
run_postdeploy 0 "$output_dir"

post_calls="${calls[*]}"
assert_contains "$post_calls" "Emulation/post.sql||0|Emulation"
assert_contains "$post_calls" "Emulation/packages.sql||0|Emulation"
assert_contains "$post_calls" "tpcc/indexes.sql||0|tpcc"
assert_contains "$post_calls" "tpcc/synonyms.sql||0|tpcc"
assert_contains "$post_calls" "tpcc/procedures.sql||0|tpcc"
assert_contains "$post_calls" "tpcc/post.sql||0|tpcc"
assert_contains "$post_calls" "tpcc_copy_tpcc/synonyms.sql||0|tpcc_copy_tpcc"
assert_contains "$post_calls" "tpcc_copy_tpcc/post.sql||0|tpcc_copy_tpcc"
assert_not_contains "$post_calls" "master.sql"

assert_line "$manifest" $'postdeploy\tsdcli/Emulation/packages.sql\texecuted\tpost-data master include'
assert_line "$manifest" $'postdeploy\tsdcli/Emulation/post.sql\texecuted\tpost-load compile and status script'
assert_line "$manifest" $'postdeploy\tsdcli/tpcc/indexes.sql\texecuted\tpost-data master include'
assert_line "$manifest" $'postdeploy\tsdcli/tpcc/synonyms.sql\texecuted\tpost-data master include'
assert_line "$manifest" $'postdeploy\tsdcli/tpcc/procedures.sql\texecuted\tpost-data master include'
assert_line "$manifest" $'postdeploy\tsdcli/tpcc/post.sql\texecuted\tpost-load compile and status script'
assert_line "$manifest" $'postdeploy\tsdcli/tpcc_copy_tpcc/synonyms.sql\texecuted\tpost-data master include'
assert_line "$manifest" $'postdeploy\tsdcli/tpcc_copy_tpcc/post.sql\texecuted\tpost-load compile and status script'

touch "$output_dir/tpcc/unplanned.sql"
set +e
( validate_generated_sql_inventory "$output_dir" ) >/dev/null 2>&1
unknown_rc=$?
set -e
[[ $unknown_rc -ne 0 ]]
