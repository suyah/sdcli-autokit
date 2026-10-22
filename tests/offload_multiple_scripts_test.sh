#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATE_SH_SOURCE_ONLY=true source "$REPO_ROOT/sdcli-scripts/migrate.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

RUN_DIR="$tmpdir/run"
AUTOKIT_DIR="$RUN_DIR/autokit"
output_dir="$RUN_DIR/sdcli"
datamove_dir="$output_dir/datamove"
mkdir -p "$AUTOKIT_DIR" "$datamove_dir/a/control" "$datamove_dir/b/control" "$tmpdir/real"

cat > "$datamove_dir/MicrosoftSQLServer_data.sh" <<'SH'
#!/usr/bin/env bash
( cd a && sh MicrosoftSQLServer_data.sh "$@" )
( cd b && sh MicrosoftSQLServer_data.sh "$@" )
SH

cat > "$datamove_dir/a/MicrosoftSQLServer_data.sh" <<'SH'
#!/usr/bin/env bash
bcp "demo.dbo.order history" out "data/order history.dat" -q -c -U"$2" -P"$3" -S"$1"
SH
cat > "$datamove_dir/b/MicrosoftSQLServer_data.sh" <<'SH'
#!/usr/bin/env bash
bcp "SELECT id FROM demo.dbo.table_b" queryout data/table_b.dat -q -c -U"$2" -P"$3" -S"$1"
SH
cat > "$datamove_dir/a/control/order_history.ctl" <<'CTL'
load data
infile 'data/order history.dat'
into table DEMO.ORDER_HISTORY
CTL
cat > "$datamove_dir/b/control/table_b.ctl" <<'CTL'
load data
infile 'data/table_b.dat'
into table DEMO.TABLE_B
CTL

cat > "$tmpdir/real/bcp" <<'SH'
#!/usr/bin/env bash
IFS= read -r _ || true
args=("$@")
for ((i = 0; i + 1 < ${#args[@]}; i++)); do
  if [[ "${args[$i]}" == "out" || "${args[$i]}" == "queryout" ]]; then
    mkdir -p "$(dirname "${args[$((i + 1))]}")"
    : > "${args[$((i + 1))]}"
    break
  fi
done
printf '%s\n' '1 rows copied.'
SH
chmod +x "$tmpdir/real/bcp"
export SQLSERVER_REAL_BCP="$tmpdir/real/bcp"

get_required_value() {
  case "$1" in
    ".migrations[0].source.conn") echo "db.example:1433:demo" ;;
    ".migrations[0].source.user") echo "sa" ;;
    ".defaults.source.bcp_tls_mode") echo "optional" ;;
    *) return 1 ;;
  esac
}
get_optional_value() {
  [[ "$1" == ".defaults.offload_preferences.packet_size" ]] && echo 65535
}
get_secret_value() {
  [[ "$1" == ".migrations[0].source.password" ]] && echo SourcePass1
}

RUN_LOG_FILE="$tmpdir/run.log"
touch "$RUN_LOG_FILE"
DRY_RUN=false

run_offload 0 "$output_dir"
[[ "$(wc -l < "$AUTOKIT_DIR/bcp_status.tsv" | tr -d '[:space:]')" == "2" ]]
grep -F $'demo.dbo.order history\t' "$AUTOKIT_DIR/bcp_status.tsv" >/dev/null
grep -F $'SELECT id FROM demo.dbo.table_b\t' "$AUTOKIT_DIR/bcp_status.tsv" >/dev/null
[[ -f "$datamove_dir/a/data/order history.dat" ]]
[[ -f "$datamove_dir/b/data/table_b.dat" ]]
grep -F 'BCP command scripts: 1' "$RUN_LOG_FILE" >/dev/null
grep -F 'BCP table 01 demo.dbo.order history rows=1' "$RUN_LOG_FILE" >/dev/null
grep -F 'BCP table 02 SELECT id FROM demo.dbo.table_b rows=1' "$RUN_LOG_FILE" >/dev/null
verify_offload_evidence "$output_dir"

touch "$datamove_dir/b/control/unexported.ctl"
set +e
verify_offload_evidence "$output_dir" >/dev/null 2>&1
coverage_rc=$?
set -e
[[ $coverage_rc -ne 0 ]] || {
  echo 'Offload evidence unexpectedly accepted a missing BCP invocation' >&2
  exit 1
}

echo "offload multiple scripts test passed"
