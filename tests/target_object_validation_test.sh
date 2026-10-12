#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATE_SH_SOURCE_ONLY=true source "$REPO_ROOT/sdcli-scripts/migrate.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "$tmpdir/bin" "$tmpdir/sdcli/customer_app"
touch "$tmpdir/sdcli/customer_app/user.sql" "$tmpdir/sdcli/customer_app/master.sql"

cat > "$tmpdir/bin/sqlplus" <<'SH'
#!/usr/bin/env bash
input="$(cat)"
printf '%s' "$input" > "$SQL_INPUT_FILE"
[[ "$input" == *'connect admin/"TargetPass1"@adb.example/high'* ]] || exit 9
printf 'SDCLI_INVALID|%s\n' "${INVALID_OBJECTS:-0}"
printf 'SDCLI_COMPILE_ERRORS|%s\n' "${COMPILER_ERRORS:-0}"
SH
chmod +x "$tmpdir/bin/sqlplus"
PATH="$tmpdir/bin:$PATH"
SQL_INPUT_FILE="$tmpdir/sql-input.txt"
export SQL_INPUT_FILE

get_required_value() {
  case "$1" in
    ".migrations[0].target.conn") echo "adb.example/high" ;;
    ".migrations[0].target.user") echo "admin" ;;
    *) return 1 ;;
  esac
}
get_secret_value() {
  [[ "$1" == ".migrations[0].target.password" ]] && echo "TargetPass1"
}

RUN_LOG_FILE="$tmpdir/run.log"
touch "$RUN_LOG_FILE"

validate_target_objects 0 "$tmpdir/sdcli"
grep -F "owner IN (UPPER('customer_app'))" "$SQL_INPUT_FILE" >/dev/null
if grep -F 'TargetPass1' "$RUN_LOG_FILE" >/dev/null; then
  echo "Target password leaked to run log" >&2
  exit 1
fi

set +e
INVALID_OBJECTS=2 COMPILER_ERRORS=3 validate_target_objects 0 "$tmpdir/sdcli" >/dev/null 2>&1
rc=$?
set -e
[[ $rc -ne 0 ]]

echo "target object validation test passed"
