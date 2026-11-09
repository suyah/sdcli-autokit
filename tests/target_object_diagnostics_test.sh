#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATE_SH_SOURCE_ONLY=true source "$REPO_ROOT/sdcli-scripts/migrate.sh"
task_tmp="$(mktemp -d)"
trap 'rm -rf "$task_tmp"' EXIT
mkdir -p "$task_tmp/bin" "$task_tmp/sdcli/app" "$task_tmp/autokit"
touch "$task_tmp/sdcli/app/user.sql"
AUTOKIT_DIR="$task_tmp/autokit"
RUN_LOG_FILE="$AUTOKIT_DIR/migrate.log"
export QUERY_LOG="$task_tmp/query"
cat > "$task_tmp/bin/sqlplus" <<'SH'
#!/usr/bin/env bash
cat > "$QUERY_LOG"
[[ "${NLS_LANG:-}" == AMERICAN_AMERICA.AL32UTF8 ]] || {
  echo 'Read-only report query did not select UTF-8 output' >&2; exit 21
}
if [[ "${TEST_QUERY_FAIL:-false}" == true ]]; then
  echo 'ORA-00942: diagnostic query failed'
  exit 1
fi
printf '%s\n' '"owner","object_name","object_type","status","error_line","error_position","error_message"'
SH
chmod +x "$task_tmp/bin/sqlplus"
export PATH="$task_tmp/bin:$PATH"
migration_required_value() { case "$3" in conn) echo test_alias;; user) echo test_admin;; esac; }
migration_secret_value() { echo TestSecret1; }
output="$AUTOKIT_DIR/target_object_diagnostics.csv"
collect_target_object_diagnostics 0 "$task_tmp/sdcli" "$output"
grep -F 'SET MARKUP CSV ON QUOTE ON' "$QUERY_LOG" >/dev/null
grep -F 'ALL_ERRORS' "$QUERY_LOG" >/dev/null
grep -F "UPPER('app')" "$QUERY_LOG" >/dev/null
[[ "$(head -n 1 "$QUERY_LOG")" == 'WHENEVER OSERROR EXIT FAILURE' ]]
[[ "$(wc -l < "$output" | tr -d ' ')" == 1 ]]
if grep -F TestSecret1 "$output" "$RUN_LOG_FILE"; then
  echo 'Secret leaked to diagnostic artifacts' >&2; exit 1
fi
export TEST_QUERY_FAIL=true
rm "$output"
if collect_target_object_diagnostics 0 "$task_tmp/sdcli" "$output"; then
  echo 'Query failure accepted as zero objects' >&2; exit 1
fi
[[ ! -e "$output" ]]
echo 'target object diagnostics test passed'
