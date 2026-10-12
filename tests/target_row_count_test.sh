#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATE_SH_SOURCE_ONLY=true source "$REPO_ROOT/sdcli-scripts/migrate.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "$tmpdir/bin"

cat > "$tmpdir/bin/sqlplus" <<'SH'
#!/usr/bin/env bash
input="$(cat)"
[[ "$input" == *'connect admin/"TargetPass1"@adb.example/high'* ]] || exit 9
printf '%s\n' 'SDCLI_COUNT|1|2'
if [[ "${OMIT_SECOND_COUNT:-false}" != "true" ]]; then
  printf '%s\n' 'SDCLI_COUNT|2|0'
fi
SH
chmod +x "$tmpdir/bin/sqlplus"
PATH="$tmpdir/bin:$PATH"

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
printf '0\tAPP.ORDERS\torders.ctl\torders.dat\t2\t0\t0\torders.log\n' > "$tmpdir/sqlldr.tsv"
printf '0\tAPP.EMPTY_TABLE\tempty.ctl\tempty.dat\t0\t0\t0\tempty.log\n' >> "$tmpdir/sqlldr.tsv"

collect_target_row_counts 0 "$tmpdir/sqlldr.tsv" "$tmpdir/counts.tsv"
grep -Fx $'1\t2' "$tmpdir/counts.tsv" >/dev/null
grep -Fx $'2\t0' "$tmpdir/counts.tsv" >/dev/null
if grep -F 'TargetPass1' "$RUN_LOG_FILE" >/dev/null; then
  echo "Target password leaked to run log" >&2
  exit 1
fi

set +e
OMIT_SECOND_COUNT=true collect_target_row_counts 0 "$tmpdir/sqlldr.tsv" "$tmpdir/incomplete.tsv" >/dev/null 2>&1
rc=$?
set -e
[[ $rc -ne 0 ]]

echo "target row count test passed"
