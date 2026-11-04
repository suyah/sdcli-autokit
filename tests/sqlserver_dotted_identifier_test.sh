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
mkdir -p "$AUTOKIT_DIR" "$datamove_dir/control"

cat > "$datamove_dir/MicrosoftSQLServer_data.sh" <<'SH'
#!/usr/bin/env bash
bcp 'demo.landing.Report.csv' out data/report.dat -q -c -CRAW -t '<EOFD>' -r '<EORD>' -S"$1" -U"$2" -P"$3"
bcp 'demo.sales.region.Order] data.csv' out data/orders.dat -q -c -CRAW -t '<EOFD>' -r '<EORD>' -S"$1" -U"$2" -P"$3"
SH
for table in report orders; do
  printf "load data\ninfile 'data/%s.dat'\ninto table TARGET.%s\n" "$table" "$table" > "$datamove_dir/control/$table.ctl"
done

cat > "$tmpdir/real-bcp" <<'SH'
#!/usr/bin/env bash
set -eu
IFS= read -r password
[[ "$password" == SourcePass1 ]] || exit 41
case "$3" in
  data/report.dat) expected='SELECT * FROM [demo].[landing].[Report.csv]' ;;
  data/orders.dat) expected='SELECT * FROM [demo].[sales.region].[Order]] data.csv]' ;;
  *) exit 42 ;;
esac
[[ "$1" == "$expected" && "$2" == queryout ]] || {
  echo 'Expected the real-world verified queryout form, not bracketed table out' >&2
  exit 43
}
[[ "$4" == -q && "$5" == -c && "$6" == -CRAW && "$7" == -t && "$8" == '<EOFD>' && "$9" == -r && "${10}" == '<EORD>' ]] || exit 44
mkdir -p data
printf 'example<EOFD><EORD>' > "$3"
printf '1 rows copied.\n'
SH
cat > "$tmpdir/sqlcmd" <<'SH'
#!/usr/bin/env bash
set -eu
[[ "$SQLCMDPASSWORD" == SourcePass1 ]] || exit 45
[[ " $* " == *' -No '* && " $* " == *' -y 0 '* ]] || exit 46
# sqlcmd rejects -h together with -y 0.  The catalog parser deliberately
# ignores the column heading and separator that sqlcmd emits without -h.
for arg in "$@"; do
  [[ "$arg" != -h ]] || exit 47
done
printf 'query\n' >> "$METADATA_CALLS"
printf 'SDCLI_BCP_TABLE_RECORD\n'
printf '%s\n' '----------------------'
printf 'SDCLI_BCP_TABLE\tlanding.Report.csv\t[demo].[landing].[Report.csv]\tSDCLI_END\n'
printf 'SDCLI_BCP_TABLE\tsales.region.Order] data.csv\t[demo].[sales.region].[Order]] data.csv]\tSDCLI_END   \n'
SH
chmod +x "$tmpdir/real-bcp" "$tmpdir/sqlcmd"
export SQLSERVER_REAL_BCP="$tmpdir/real-bcp"
export METADATA_CALLS="$tmpdir/metadata-calls"
export PATH="$tmpdir:$PATH"

get_required_value() {
  case "$1" in
    '.migrations[0].source.conn') printf 'source.example:1433:demo\n' ;;
    '.migrations[0].source.user') printf 'migration_reader\n' ;;
    '.defaults.source.bcp_tls_mode') printf 'optional\n' ;;
    *) return 1 ;;
  esac
}
get_optional_value() {
  [[ "$1" == '.defaults.offload_preferences.packet_size' ]] && printf '65535\n'
}
get_secret_value() {
  [[ "$1" == '.migrations[0].source.password' ]] && printf 'SourcePass1\n'
}

RUN_LOG_FILE="$tmpdir/run.log"
touch "$RUN_LOG_FILE"
DRY_RUN=false
original_scripts="$(cksum "$datamove_dir/MicrosoftSQLServer_data.sh" "$datamove_dir"/control/*.ctl)"
run_offload 0 "$output_dir"
[[ "$(cksum "$datamove_dir/MicrosoftSQLServer_data.sh" "$datamove_dir"/control/*.ctl)" == "$original_scripts" ]]
[[ "$(wc -l < "$METADATA_CALLS" | tr -d '[:space:]')" == 1 ]]
[[ -f "$datamove_dir/data/report.dat" && -f "$datamove_dir/data/orders.dat" ]]
grep -F $'0\tdemo.landing.Report.csv\t' "$AUTOKIT_DIR/bcp_status.tsv" >/dev/null
grep -F 'runtime out -> queryout' "$RUN_LOG_FILE" >/dev/null

# A flattened name can refer to two different schema/table pairs. Never choose
# one arbitrarily, and never pass an unverified query to real bcp.
catalog="$AUTOKIT_DIR/bcp_source_tables.tsv"
printf 'sales.region.Order] data.csv\t[demo].[sales].[region.Order]] data.csv]\n' >> "$catalog"
set +e
SQLSERVER_BCP_SOURCE_DATABASE=demo SQLSERVER_BCP_TABLE_CATALOG_FILE="$catalog" \
  "$REPO_ROOT/sdcli-scripts/lib/bcp" 'demo.sales.region.Order] data.csv' out "$tmpdir/ambiguous.dat" \
  > "$tmpdir/ambiguous.log" 2>&1
rc=$?
set -e
[[ "$rc" == 2 && ! -e "$tmpdir/ambiguous.dat" ]]
grep -F 'matches=2' "$tmpdir/ambiguous.log" >/dev/null

echo 'SQL Server dotted identifier BCP test passed (external tools stubbed; real queryout verified by customer)'
