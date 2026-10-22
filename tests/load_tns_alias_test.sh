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

RUN_ID="20260427_121621"
RUN_DIR="$tmpdir/run"
AUTOKIT_DIR="$RUN_DIR/autokit"
output_dir="$RUN_DIR/sdcli"
datamove_dir="$output_dir/datamove"
mkdir -p "$AUTOKIT_DIR" "$datamove_dir/tpcc"
mkdir -p "$datamove_dir/tpcc/control" "$datamove_dir/tpcc/data"
cat > "$datamove_dir/tpcc/control/tpcc.customer.ctl" <<'CTL'
load data
infile 'data/tpcc.customer.dat'
into table TPCC.CUSTOMER
fields terminated by ','
(ID)
CTL
touch "$datamove_dir/tpcc/data/tpcc.customer.dat"

cat > "$datamove_dir/oracle_loader.sh" <<'SH'
#!/usr/bin/env bash
echo "WRAPPER_EXECUTED"
( cd tpcc ; sh oracle_loader.sh "$@" )
SH
chmod +x "$datamove_dir/oracle_loader.sh"

cat > "$datamove_dir/tpcc/oracle_loader.sh" <<'SH'
#!/usr/bin/env bash
servername=$1
username=$2
password=$3
loader_command=sqlldr
echo "SCRIPT_ARG3=${3:-}"
echo "SERVER=$servername"
echo "TNS_ADMIN=${TNS_ADMIN:-}"
PATH="$BAD_LOAD_PATH:$PATH"
sqlplus $username/$password@$servername @control/pre_load.sql
sqlplus $username/$password@$servername <<'SQL'
prompt HEREDOC_PRE_LOAD
SQL
sqlplus /nolog <<SQL
connect $username/$password@$servername
prompt NOLOG_PRE_LOAD
SQL
"$loader_command" userid=$username/$password@$servername control=control/tpcc.customer.ctl
SH

fakebin="$tmpdir/bin"
mkdir -p "$fakebin"
badbin="$tmpdir/badbin"
mkdir -p "$badbin"
cat > "$fakebin/sqlplus" <<'SH'
#!/usr/bin/env bash
stdin="$(cat)"
if [[ "$stdin" == *'connect admin/"TargetPass1"@SDCLI_LOAD_20260427_121621'* ]]; then
  printf '%s\n' 'SQLPLUS_STDIN_PASSWORD_OK'
else
  printf 'SQLPLUS_STDIN_PASSWORD_BAD:%s\n' "$stdin"
fi
if [[ "$stdin" == *'HEREDOC_PRE_LOAD'* ]]; then
  printf '%s\n' 'SQLPLUS_STDIN_HEREDOC_OK'
fi
if [[ "$stdin" == *'NOLOG_PRE_LOAD'* && "$stdin" == *'connect admin/"TargetPass1"@SDCLI_LOAD_20260427_121621'* ]]; then
  printf '%s\n' 'SQLPLUS_STDIN_NOLOG_OK'
fi
for arg in "$@"; do
  printf 'SQLPLUS_ARG:%s\n' "$arg"
done
SH
chmod +x "$fakebin/sqlplus"
cat > "$badbin/sqlplus" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'BAD_SQLPLUS_USED'
exit 1
SH
chmod +x "$badbin/sqlplus"

cat > "$fakebin/sqlldr" <<'SH'
#!/usr/bin/env bash
IFS= read -r sqlldr_password || sqlldr_password=""
if [[ "$sqlldr_password" == "TargetPass1" ]]; then
  printf '%s\n' 'SQLLDR_STDIN_PASSWORD_OK'
else
  printf 'SQLLDR_STDIN_PASSWORD_BAD:%s\n' "$sqlldr_password"
fi
for arg in "$@"; do
  printf 'SQLLDR_ARG:%s\n' "$arg"
done
printf '%s\n' 'Path used:      Conventional'
printf '%s\n' 'Commit point reached - logical record count 42'
printf '%s\n' 'Save data point reached - logical record count 50000.'
printf '%s\n' 'Table TPCC.CUSTOMER:'
printf '%s\n' '  42 Rows successfully loaded.'
mkdir -p control
cat > control/tpcc.customer.log <<'LOG'
Table TPCC.CUSTOMER:
  42 Rows successfully loaded.
Total logical records rejected:         0
Total logical records discarded:        0
LOG
SH
chmod +x "$fakebin/sqlldr"
cat > "$badbin/sqlldr" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'BAD_SQLLDR_USED'
exit 1
SH
chmod +x "$badbin/sqlldr"
PATH="$fakebin:$PATH"
export BAD_LOAD_PATH="$badbin"

get_required_value() {
  case "$1" in
    ".migrations[0].target.conn") echo "tcps://adb.ap-hyderabad-1.oraclecloud.com:1521/g207e55d6197742_test23atp_high.adb.oraclecloud.com?ssl_server_dn_match=yes" ;;
    ".migrations[0].target.user") echo "admin" ;;
    *) echo "unexpected config path: $1" >&2; return 1 ;;
  esac
}

get_secret_value() {
  case "$1" in
    ".migrations[0].target.password") echo "TargetPass1" ;;
    *) echo "unexpected secret path: $1" >&2; return 1 ;;
  esac
}

get_sqlldr_config_raw() {
  case "$2" in
    direct) echo false ;;
    rows) echo 50000 ;;
    bindsize|readsize) echo 16777216 ;;
    *) echo "" ;;
  esac
}

RUN_LOG_FILE="$tmpdir/run.log"
touch "$RUN_LOG_FILE"
DRY_RUN=false

run_load 0 "$output_dir"

run_log="$(cat "$RUN_LOG_FILE")"
load_wrappers="$(cat "$REPO_ROOT/sdcli-scripts/lib/load_wrappers.sh")"
tns_file="$AUTOKIT_DIR/tns/tnsnames.ora"
tns_text="$(cat "$tns_file")"

assert_contains "$load_wrappers" 'bash "$_sdcli_lib_dir/sqlplus" "$@"'
assert_contains "$load_wrappers" 'bash "$_sdcli_lib_dir/sqlldr" "$@"'
if [[ -e "$AUTOKIT_DIR/load_wrappers.sh" ]]; then
  echo "Did not expect run-generated load_wrappers.sh" >&2
  exit 1
fi
assert_contains "$run_log" "SQL*Loader connect alias: SDCLI_LOAD_20260427_121621"
assert_not_contains "$run_log" "WRAPPER_EXECUTED"
assert_contains "$run_log" "SCRIPT_ARG3="
assert_contains "$run_log" "SERVER=SDCLI_LOAD_20260427_121621"
assert_contains "$run_log" "TNS_ADMIN=$AUTOKIT_DIR/tns"
assert_contains "$run_log" "SQLPLUS_STDIN_PASSWORD_OK"
assert_contains "$run_log" "SQLPLUS_STDIN_HEREDOC_OK"
assert_contains "$run_log" "SQLPLUS_STDIN_NOLOG_OK"
assert_contains "$run_log" "SQLPLUS_ARG:/nolog"
assert_contains "$run_log" "SQLLDR_STDIN_PASSWORD_OK"
assert_contains "$run_log" 'SQLLDR_ARG:userid=admin@SDCLI_LOAD_20260427_121621'
assert_not_contains "$run_log" "BAD_SQLPLUS_USED"
assert_not_contains "$run_log" "BAD_SQLLDR_USED"
assert_not_contains "$run_log" "TargetPass1"
assert_not_contains "$run_log" "__SDCLI_LOAD_PASSWORD__@SDCLI_LOAD_20260427_121621"
assert_contains "$run_log" "Save data point reached - logical record count 50000."
assert_not_contains "$run_log" "SQL*Loader output: Save data point reached"
assert_contains "$run_log" "SQL*Loader table 01 tpcc.customer rows=42 path=Conventional elapsed_sec="
assert_contains "$run_log" "SQL*Loader load summary: tables=1 rows=42 sqlldr_elapsed_sec="
assert_contains "$run_log" "SQL*Loader load completed: wall_elapsed_sec="
assert_contains "$tns_text" "SDCLI_LOAD_20260427_121621 ="
assert_contains "$tns_text" "(PROTOCOL = TCPS)"
assert_contains "$tns_text" "(HOST = adb.ap-hyderabad-1.oraclecloud.com)"
assert_contains "$tns_text" "(PORT = 1521)"
assert_contains "$tns_text" "(SERVICE_NAME = g207e55d6197742_test23atp_high.adb.oraclecloud.com)"
assert_contains "$tns_text" "(SSL_SERVER_DN_MATCH = YES)"

assert_control_rejected() {
  local expected="$1"
  local output rc
  : > "$RUN_LOG_FILE"
  set +e
  output="$(run_load 0 "$output_dir" 2>&1)"
  rc=$?
  set -e
  [[ $rc -ne 0 ]] || {
    echo "Expected ambiguous SQL*Loader control file to fail" >&2
    exit 1
  }
  assert_contains "$output" "$expected"
}

cat > "$datamove_dir/tpcc/control/tpcc.customer.ctl" <<'CTL'
load data
infile 'data/tpcc.customer.dat'
infile 'data/tpcc.customer-part2.dat'
into table TPCC.CUSTOMER
(ID)
CTL
assert_control_rejected "exactly one INFILE record"

cat > "$datamove_dir/tpcc/control/tpcc.customer.ctl" <<'CTL'
load data
infile 'data/tpcc.customer.dat'
into table TPCC.CUSTOMER
into table TPCC.CUSTOMER_ARCHIVE
(ID)
CTL
assert_control_rejected "exactly one INTO TABLE record"

cat > "$datamove_dir/tpcc/control/tpcc.customer.ctl" <<'CTL'
load data
infile 'data/tpcc.customer.dat'
into table TPCC.CUSTOMER;DROP
(ID)
CTL
assert_control_rejected "unsupported INTO TABLE identifier"

cat > "$datamove_dir/tpcc/control/tpcc.customer.ctl" <<'CTL'
load data
infile 'data/tpcc.customer.dat'
into table TPCC.CUSTOMER
(ID)
CTL
cat > "$datamove_dir/tpcc/control/not_invoked.ctl" <<'CTL'
load data
infile 'data/not_invoked.dat'
into table TPCC.NOT_INVOKED
(ID)
CTL
assert_control_rejected "records=1 expected=2 unique_controls=1 issues=0"
