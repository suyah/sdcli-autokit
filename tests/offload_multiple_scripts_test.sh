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
mkdir -p "$AUTOKIT_DIR" "$datamove_dir/a" "$datamove_dir/b" "$tmpdir/real"

cat > "$datamove_dir/a/MicrosoftSQLServer_data.sh" <<'SH'
#!/usr/bin/env bash
bcp demo.dbo.table_a out data/table_a.dat -q -c -U"$2" -P"$3" -S"$1"
SH
cat > "$datamove_dir/b/MicrosoftSQLServer_data.sh" <<'SH'
#!/usr/bin/env bash
bcp demo.dbo.table_b out data/table_b.dat -q -c -U"$2" -P"$3" -S"$1"
SH

cat > "$tmpdir/real/bcp" <<'SH'
#!/usr/bin/env bash
IFS= read -r _ || true
args=("$@")
for ((i = 0; i + 1 < ${#args[@]}; i++)); do
  if [[ "${args[$i]}" == "out" ]]; then
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
grep -F $'demo.dbo.table_a\t' "$AUTOKIT_DIR/bcp_status.tsv" >/dev/null
grep -F $'demo.dbo.table_b\t' "$AUTOKIT_DIR/bcp_status.tsv" >/dev/null
[[ -f "$datamove_dir/a/data/table_a.dat" ]]
[[ -f "$datamove_dir/b/data/table_b.dat" ]]

echo "offload multiple scripts test passed"
