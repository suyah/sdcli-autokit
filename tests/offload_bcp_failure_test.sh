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
mkdir -p "$AUTOKIT_DIR" "$datamove_dir/control" "$tmpdir/real"

cat > "$datamove_dir/MicrosoftSQLServer_data.sh" <<'SCRIPT'
#!/usr/bin/env bash
bcp demo.dbo.table_one out data/table_one.dat -q -c -U"$2" -P"$3" -S"$1"
# Generated scripts do not always use set -e, so this mimics a parent script
# that reaches a successful final command after an individual bcp failure.
true
SCRIPT
chmod +x "$datamove_dir/MicrosoftSQLServer_data.sh"
cat > "$datamove_dir/control/table_one.ctl" <<'CTL'
load data
infile 'data/table_one.dat'
into table DEMO.TABLE_ONE
CTL

cat > "$tmpdir/real/bcp" <<'SCRIPT'
#!/usr/bin/env bash
IFS= read -r _ || true
printf '%s\n' 'Error = simulated bcp failure'
exit 17
SCRIPT
chmod +x "$tmpdir/real/bcp"
export SQLSERVER_REAL_BCP="$tmpdir/real/bcp"

get_required_value() {
  case "$1" in
    ".migrations[0].source.conn") echo "10.0.1.165:1433:demo" ;;
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

set +e
run_offload 0 "$output_dir"
rc=$?
set -e

[[ $rc -ne 0 ]] || {
  echo "BCP failure unexpectedly returned success" >&2
  exit 1
}
grep -F 'BCP command failed or returned incomplete evidence: object=demo.dbo.table_one exit_code=17' "$RUN_LOG_FILE" >/dev/null
grep -F 'BCP offload verification failed' "$RUN_LOG_FILE" >/dev/null

echo "offload BCP failure test passed"
