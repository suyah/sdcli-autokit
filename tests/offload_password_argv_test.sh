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

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

RUN_ID="20260427_131500"
RUN_DIR="$tmpdir/run"
AUTOKIT_DIR="$RUN_DIR/autokit"
output_dir="$RUN_DIR/sdcli"
datamove_dir="$output_dir/datamove"
mkdir -p "$AUTOKIT_DIR" "$datamove_dir" "$tmpdir/real"

cat > "$datamove_dir/MicrosoftSQLServer_data.sh" <<'SH'
#!/usr/bin/env bash
servername=$1
username=$2
password=$3
echo "SCRIPT_ARG3=${3:-}"
bcp tpcc.dbo.customer out data/tpcc.customer.dat -q -c -U$username -P$password -S$servername
SH
chmod +x "$datamove_dir/MicrosoftSQLServer_data.sh"

cat > "$tmpdir/real/bcp" <<'SH'
#!/usr/bin/env bash
IFS= read -r bcp_password || bcp_password=""
if [[ "$bcp_password" == "SourcePass1" ]]; then
  printf '%s\n' 'BCP_STDIN_PASSWORD_OK'
else
  printf 'BCP_STDIN_PASSWORD_BAD:%s\n' "$bcp_password"
fi
for arg in "$@"; do
  printf 'BCP_ARG:%s\n' "$arg"
done
args=("$@")
for ((i = 0; i + 1 < ${#args[@]}; i++)); do
  if [[ "${args[$i]}" == "out" ]]; then
    data_file="${args[$((i + 1))]}"
    mkdir -p "$(dirname "$data_file")"
    : > "$data_file"
    break
  fi
done
printf '%s\n' '0 rows copied.'
SH
chmod +x "$tmpdir/real/bcp"
export SQLSERVER_REAL_BCP="$tmpdir/real/bcp"

get_required_value() {
  case "$1" in
    ".migrations[0].source.conn") echo "10.0.1.165:1433:tpcc" ;;
    ".migrations[0].source.user") echo "sa" ;;
    ".defaults.source.bcp_tls_mode") echo "optional" ;;
    *) echo "unexpected config path: $1" >&2; return 1 ;;
  esac
}

get_optional_value() {
  case "$1" in
    ".defaults.offload_preferences.packet_size") echo "65535" ;;
    *) echo "" ;;
  esac
}

get_secret_value() {
  case "$1" in
    ".migrations[0].source.password") echo "SourcePass1" ;;
    *) echo "unexpected secret path: $1" >&2; return 1 ;;
  esac
}

RUN_LOG_FILE="$tmpdir/run.log"
touch "$RUN_LOG_FILE"
DRY_RUN=false

run_offload 0 "$output_dir"

run_log="$(cat "$RUN_LOG_FILE")"
assert_contains "$run_log" "SCRIPT_ARG3=__SDCLI_BCP_PASSWORD__"
assert_contains "$run_log" "BCP_STDIN_PASSWORD_OK"
assert_contains "$run_log" "BCP_ARG:-Usa"
assert_contains "$run_log" "BCP_ARG:-S10.0.1.165,1433"
assert_not_contains "$run_log" "SourcePass1"
assert_not_contains "$run_log" "BCP_ARG:-P"
assert_contains "$run_log" "BCP command summary: invoked=1 expected=1 failed=0 missing_files=0"
[[ "$(cut -f1 "$AUTOKIT_DIR/bcp_status.tsv")" == "0" ]]
[[ "$(cut -f4 "$AUTOKIT_DIR/bcp_status.tsv")" == "0" ]]
