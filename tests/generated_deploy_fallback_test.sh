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

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

RUN_DIR="$tmpdir/run"
AUTOKIT_DIR="$RUN_DIR/autokit"
output_dir="$RUN_DIR/sdcli"
mkdir -p "$AUTOKIT_DIR" "$output_dir/gen"
printf '%s\n' 'ACCEPT app_password PROMPT "Application password: " HIDE' > "$output_dir/passworddefinition.sql"
touch "$output_dir/gen/generated-main.sql"

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
    ".migrations[0].target.default_schema_password") echo "SchemaPass1" ;;
    *) return 1 ;;
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

[[ "${calls[*]}" == "gen/generated-main.sql|SchemaPass1|1|" ]]
assert_contains "$(cat "$RUN_LOG_FILE")" "No per-schema user.sql files found; deploying the single generated SQL output"
assert_contains "$(cat "$AUTOKIT_DIR/deploy_manifest.tsv")" $'deploy\tsdcli/gen/generated-main.sql\texecuted\tsingle generated fallback'

touch "$output_dir/gen/generated-extra.sql"
set +e
( validate_generated_sql_inventory "$output_dir" ) >/dev/null 2>&1
multiple_rc=$?
set -e
[[ $multiple_rc -ne 0 ]]

echo "generated deploy fallback test passed"
