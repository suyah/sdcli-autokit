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
bcp CEC_REALM.landing.NorthCanberraHospital_AHC.csv out data/ahc-csv.dat -c -S"$1" -U"$2" -P"$3"
SH
chmod +x "$datamove_dir/MicrosoftSQLServer_data.sh"
cat > "$datamove_dir/control/ahc-csv.ctl" <<'CTL'
load data
infile 'data/ahc-csv.dat'
into table TGT_LANDING.NORTHCANBERRAHOSPITAL_AHC_CSV
CTL

cat > "$tmpdir/real-bcp" <<'SH'
#!/usr/bin/env bash
IFS= read -r _ || true
[[ "$1" == '[CEC_REALM].[landing].[NorthCanberraHospital_AHC.csv]' ]] || {
  printf 'BCP object was not safely quoted: %s\n' "$1" >&2
  exit 42
}
[[ "$2" == out && "$3" == 'data/ahc-csv.dat' ]] || exit 43
mkdir -p "$(dirname "$3")"
: > "$3"
printf '1 rows copied.\n'
SH
chmod +x "$tmpdir/real-bcp"

cat > "$tmpdir/sqlcmd" <<'SH'
#!/usr/bin/env bash
[[ "$*" == *"landing.NorthCanberraHospital_AHC.csv"* ]] || {
  printf 'Unexpected metadata lookup: %s\n' "$*" >&2
  exit 44
}
[[ " $* " == *' -No '* ]] || {
  printf 'SQLCMD did not receive the optional TLS mode: %s\n' "$*" >&2
  exit 45
}
printf 'landing\tNorthCanberraHospital_AHC.csv\n'
SH
chmod +x "$tmpdir/sqlcmd"

export SQLSERVER_REAL_BCP="$tmpdir/real-bcp"
export PATH="$tmpdir:$PATH"

get_required_value() {
  case "$1" in
    '.migrations[0].source.conn') printf '10.141.1.97:1433:cec_realm\n' ;;
    '.migrations[0].source.user') printf 'eHOracle-pilot\n' ;;
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

run_offload 0 "$output_dir"

[[ -f "$datamove_dir/data/ahc-csv.dat" ]]
grep -F $'0\tCEC_REALM.landing.NorthCanberraHospital_AHC.csv\t' "$AUTOKIT_DIR/bcp_status.tsv" >/dev/null

echo 'SQL Server dotted identifier BCP test passed'
