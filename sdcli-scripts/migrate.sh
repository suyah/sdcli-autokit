#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.yaml"

MIGRATION_NAME=""
MODE="full"
MODE_EXPLICIT=false
PHASE_NAME=""
MODEL_NAME_INPUT=""
RUN_NAME_INPUT=""
DRY_RUN=false
# SQL Developer capture can legitimately stage thousands of metadata rows over
# a high-latency database connection. Keep the default unbounded so a healthy
# long capture is not converted into a false failure. Operators can opt into a
# bound (for example, 1800) when an external watchdog is preferred.
SDCLI_COMMAND_TIMEOUT_SEC="${SDCLI_COMMAND_TIMEOUT_SEC:-0}"

RUN_ID="$(date '+%Y%m%d_%H%M%S')"
RUN_NAME=""
PROJECT_ROOT=""
PROJECT_DIR=""
RUN_DIR=""
AUTOKIT_DIR=""
SDCLI_OUTPUT_DIR=""
RUN_LOG_FILE=""
RUN_LOG_START_LINE=0
SDCLI_COMMAND_LOG=""
SDCLI_SUMMARY_FILE=""
MIGRATION_SUMMARY_FILE=""
ORACLE_WALLET_DIR=""
ACTIVE_MIGRATION_INDEX=""
ACTIVE_MIGRATION_NAME=""
ACTIVE_REPOSITORY_CONN=""
ACTIVE_REPOSITORY_NAME=""
ACTIVE_SUPER_CONNECTION_NAME=""
ACTIVE_WALLET_DIR=""
ACTIVE_WALLET_CONFIG_PATH=""
PHASE_STATUS_FILE=""
ACTIVE_PHASE=""
ACTIVE_PHASE_ATTEMPT=""
REPOSITORY_LOCK_DIR=""
REPOSITORY_LOCK_HELD=false
RERUN_COMPLETED=false
SDCLI_LAST_ACTION=""
SDCLI_LAST_SUCCESS_MARKER=false
SDCLI_CAPTURE_OUTPUT_FILE=""
SDCLI_VERIFIED_MODEL_INDEX=""

declare -a SDCLI_COMMANDS=()
declare -a SENSITIVE_VALUES=()
declare -a DATATYPE_MAPPING_TEMP_DIRS=()
declare -a SQLPLUS_RUNTIME_TEMP_DIRS=()

source "$SCRIPT_DIR/lib/sdcli_profile.sh"

# --- CLI and logging helpers -------------------------------------------------
usage() {
  cat <<'USAGE'
Usage:
  ./migrate.sh [<migration_name>] --init [options]
  ./migrate.sh [<migration_name>] --show-datatype-mapping
  ./migrate.sh <migration_name> [options]

Modes:
  --init                 Repository setup for one migration target: driver + repository init
  --conn-setup           Create source and target SDCLI connections only
  --phase <name>         Run one phase only: capture|convert|generate|deploy|datamove|offload|load|postdeploy|validate|cleanup
  --deploy               Shorthand for --phase deploy (setup only; never runs cleanup)
  --cleanup              Run the separated generated role cleanup for an existing run
  --migrate              Run all phases: capture->convert->generate->datamove->offload->deploy->load->postdeploy->validate
  --show-datatype-mapping
                         Show persisted SQL Developer repository datatype mappings as TSV

Options:
  --model <name>         Optional model for non-capture --phase mode only
                         capture always uses <migration_name>_<run_id>
                         other phases default to latest
  --run <name>           Use an existing run directory for non-capture --phase mode
  --rerun-completed      Allow an explicitly selected completed phase to run again
                         (requires --phase and --run; recorded in phase status)
  --dry-run              Print/log commands without executing commands/scripts
  -h, --help             Show help

Examples:
  ./migrate.sh tpcc --init
  ./migrate.sh --show-datatype-mapping
  ./migrate.sh tpcc --show-datatype-mapping
  ./migrate.sh tpcc
  ./migrate.sh tpcc --conn-setup
  ./migrate.sh tpcc --phase capture
  ./migrate.sh tpcc --deploy --run 20260427_014117
  ./migrate.sh tpcc --cleanup --run 20260427_014117
  ./migrate.sh tpcc --phase deploy --run 20260427_014117
  ./migrate.sh tpcc --phase datamove --model latest
  ./migrate.sh tpcc --phase offload --model latest
  ./migrate.sh tpcc --phase load --model latest
  ./migrate.sh tpcc --phase postdeploy --model latest
  ./migrate.sh tpcc --migrate
USAGE
}

timestamp() {
  date '+%Y-%m-%d %H:%M:%S'
}

log_line() {
  local level="$1"
  shift
  local message="$*"
  local line="[$level] $(timestamp) - $message"
  echo "$line"
  if [[ -n "${RUN_LOG_FILE:-}" ]]; then
    echo "$line" >> "$RUN_LOG_FILE"
  fi
}

log_info() { log_line "INFO" "$*"; }
log_warn() { log_line "WARN" "$*"; }
log_error() {
  local message="$*"
  local line="[ERROR] $(timestamp) - $message"
  echo "$line" >&2
  if [[ -n "${RUN_LOG_FILE:-}" ]]; then
    echo "$line" >> "$RUN_LOG_FILE"
  fi
}

fail() {
  log_error "$1"
  exit 1
}

set_mode() {
  local new_mode="$1"
  if $MODE_EXPLICIT; then
    fail "Choose only one mode: --init, --conn-setup, --phase, --migrate, or --show-datatype-mapping"
  fi
  MODE="$new_mode"
  MODE_EXPLICIT=true
}

mask_sensitive() {
  local masked_args=()
  local arg
  for arg in "$@"; do
    masked_args+=("$(redact_text "$arg")")
  done

  local rendered=""
  printf -v rendered '%q ' "${masked_args[@]}"
  echo "${rendered% }"
}

write_sdcli_summary() {
  local status="$1"
  [[ -n "${SDCLI_SUMMARY_FILE:-}" ]] || return 0

  local cmd

  {
    echo "run_id: $RUN_ID"
    echo "status: $status"
    echo "total_sdcli_commands: ${#SDCLI_COMMANDS[@]}"
    echo
    local i=1
    for cmd in "${SDCLI_COMMANDS[@]+"${SDCLI_COMMANDS[@]}"}"; do
      echo "$i. $cmd"
      i=$((i + 1))
    done
  } > "$SDCLI_SUMMARY_FILE"
}

on_exit() {
  local rc=$?
  local status="success"

  if [[ -n "${ACTIVE_PHASE:-}" ]]; then
    record_phase_status "$ACTIVE_PHASE" "failed" "$rc" "process exited before phase completion" "${ACTIVE_PHASE_ATTEMPT:-1}" || true
    ACTIVE_PHASE=""
  fi
  cleanup_sqlplus_runtime_temp_dirs || true
  cleanup_datatype_mapping_temp_dirs || true
  release_repository_lock || true
  release_profile_lock || true

  if [[ $rc -ne 0 ]]; then
    status="failed($rc)"
  fi

  if [[ -n "${SDCLI_SUMMARY_FILE:-}" && "${#SDCLI_COMMANDS[@]}" != "0" ]]; then
    write_sdcli_summary "$status" || true
    if [[ -n "${RUN_LOG_FILE:-}" ]]; then
      echo "[INFO] $(timestamp) - SDCLI summary file: $SDCLI_SUMMARY_FILE" >> "$RUN_LOG_FILE"
    fi
    echo
    echo "===== SDCLI COMMAND SUMMARY ====="
    cat "$SDCLI_SUMMARY_FILE"
  fi
}

register_datatype_mapping_temp_dir() {
  DATATYPE_MAPPING_TEMP_DIRS+=("$1")
}

cleanup_datatype_mapping_temp_dirs() {
  local temp_dir
  for temp_dir in "${DATATYPE_MAPPING_TEMP_DIRS[@]+"${DATATYPE_MAPPING_TEMP_DIRS[@]}"}"; do
    [[ -n "$temp_dir" && -d "$temp_dir" ]] && rm -rf -- "$temp_dir"
  done
  DATATYPE_MAPPING_TEMP_DIRS=()
}

register_sqlplus_runtime_dir() {
  SQLPLUS_RUNTIME_TEMP_DIRS+=("$1")
}

remove_sqlplus_runtime_dir() {
  local target="$1"
  local temp_dir
  local -a remaining=()

  if [[ -n "$target" && -d "$target" ]]; then
    rm -rf -- "$target"
  fi
  for temp_dir in "${SQLPLUS_RUNTIME_TEMP_DIRS[@]+"${SQLPLUS_RUNTIME_TEMP_DIRS[@]}"}"; do
    [[ "$temp_dir" == "$target" ]] || remaining+=("$temp_dir")
  done
  SQLPLUS_RUNTIME_TEMP_DIRS=("${remaining[@]+"${remaining[@]}"}")
}

cleanup_sqlplus_runtime_temp_dirs() {
  local temp_dir
  for temp_dir in "${SQLPLUS_RUNTIME_TEMP_DIRS[@]+"${SQLPLUS_RUNTIME_TEMP_DIRS[@]}"}"; do
    [[ -n "$temp_dir" && -d "$temp_dir" ]] && rm -rf -- "$temp_dir"
  done
  SQLPLUS_RUNTIME_TEMP_DIRS=()
}

on_signal() {
  local exit_code="$1"
  trap - INT TERM
  exit "$exit_code"
}

if [[ "${MIGRATE_SH_SOURCE_ONLY:-false}" != "true" ]]; then
  trap on_exit EXIT
  trap 'on_signal 130' INT
  trap 'on_signal 143' TERM
fi

# --- Config helpers ----------------------------------------------------------
require_command() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || fail "Required command not found: $cmd"
}

yq_eval() {
  yq eval "$1" "$CONFIG_FILE"
}

get_required_value() {
  local path="$1"
  local label="$2"
  local value
  value="$(yq_eval "$path")"
  if [[ "$value" == "null" || -z "$value" ]]; then
    fail "Missing required config: $label ($path)"
  fi
  echo "$value"
}

get_optional_value() {
  local path="$1"
  local value
  value="$(yq_eval "$path")"
  if [[ "$value" == "null" ]]; then
    echo ""
  else
    echo "$value"
  fi
}

configure_oracle_wallet_dir() {
  local wallet_dir="$1"
  local wallet_config_path="$2"
  local option_variable normalized
  for option_variable in JAVA_TOOL_OPTIONS JDK_JAVA_OPTIONS _JAVA_OPTIONS; do
    normalized="$(normalize_oracle_java_options "${!option_variable:-}")"
    if [[ -n "$normalized" ]]; then
      printf -v "$option_variable" '%s' "$normalized"
      export "$option_variable"
    else
      unset "$option_variable"
    fi
  done
  unset TNS_ADMIN
  ORACLE_WALLET_DIR=""
  [[ -n "$wallet_dir" ]] || return 0

  [[ "$wallet_dir" == /* ]] || fail "$wallet_config_path must be an absolute path"
  [[ "$wallet_dir" != *[[:space:]]* ]] || fail "$wallet_config_path must not contain whitespace"
  [[ -d "$wallet_dir" ]] || fail "$wallet_config_path: Oracle wallet directory does not exist: $wallet_dir"
  [[ -f "$wallet_dir/tnsnames.ora" ]] || fail "$wallet_config_path: Oracle wallet is missing tnsnames.ora: $wallet_dir"
  [[ -f "$wallet_dir/sqlnet.ora" ]] || fail "$wallet_config_path: Oracle wallet is missing sqlnet.ora: $wallet_dir"
  [[ -f "$wallet_dir/cwallet.sso" || -f "$wallet_dir/ewallet.sso" || -f "$wallet_dir/ewallet.p12" ]] \
    || fail "$wallet_config_path: Oracle wallet is missing a wallet file (cwallet.sso, ewallet.sso, or ewallet.p12): $wallet_dir"

  ORACLE_WALLET_DIR="$wallet_dir"
  export TNS_ADMIN="$ORACLE_WALLET_DIR"
  export JAVA_TOOL_OPTIONS="${JAVA_TOOL_OPTIONS:+${JAVA_TOOL_OPTIONS} }-Doracle.net.tns_admin=$ORACLE_WALLET_DIR"
  log_info "Oracle mTLS wallet directory: $ORACLE_WALLET_DIR"
}

configure_oracle_wallet() {
  configure_oracle_wallet_dir "$(get_optional_value '.defaults.target.wallet_dir')" '.defaults.target.wallet_dir'
}

configure_active_oracle_wallet() {
  configure_oracle_wallet_dir "$ACTIVE_WALLET_DIR" "$ACTIVE_WALLET_CONFIG_PATH"
}

configure_sqldeveloper_file_output_option() {
  local output_option="${SQLDEVELOPER_FILE_OUTPUT_OPTION:-1}"
  local prefs_root preference_file="" template_file tmp_file candidate
  local existing_count=0 directory_count=0
  local -a existing_files=() preference_dirs=()

  [[ "$output_option" =~ ^[0-9]+$ ]] || fail "SQLDEVELOPER_FILE_OUTPUT_OPTION must be a non-negative integer"
  [[ -n "$SDCLI_PROFILE_DIR" ]] || fail 'No SQL Developer project profile selected for preferences'
  prefs_root="$SDCLI_PROFILE_DIR"
  [[ -d "$prefs_root" ]] || return 0

  template_file="$SCRIPT_DIR/templates/product-preferences.xml"
  [[ -f "$template_file" ]] || fail "SQL Developer preferences template not found: $template_file"

  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    existing_files+=("$candidate")
    existing_count=$((existing_count + 1))
  done < <(find -H "$prefs_root" -type f -path '*/o.sqldeveloper/product-preferences.xml' | LC_ALL=C sort)

  if (( existing_count == 1 )); then
    preference_file="${existing_files[0]}"
  elif (( existing_count > 1 )); then
    log_warn "Found multiple SQL Developer product-preferences.xml files under $prefs_root; all were left unchanged because the active SQL Developer version is ambiguous"
    return 0
  else
    while IFS= read -r candidate; do
      [[ -n "$candidate" ]] || continue
      preference_dirs+=("$candidate")
      directory_count=$((directory_count + 1))
    done < <(find -H "$prefs_root" -type d -path '*/o.sqldeveloper' | LC_ALL=C sort)

    if (( directory_count == 0 )); then
      log_warn "SQL Developer preference directory not found under $prefs_root; run sdcli once, then retry"
      return 0
    fi
    if (( directory_count > 1 )); then
      log_warn "Found multiple SQL Developer preference directories under $prefs_root; no product-preferences.xml was installed"
      return 0
    fi

    preference_file="${preference_dirs[0]}/product-preferences.xml"
    tmp_file="$(mktemp "${preference_file}.XXXXXX")" || return 1
    if ! awk -v output_option="$output_option" '
      {
        if ($0 == "      <value n=\"FileOutputOption\" v=\"__SQLDEVELOPER_FILE_OUTPUT_OPTION__\"/>") {
          print "      <value n=\"FileOutputOption\" v=\"" output_option "\"/>"
          replaced++
        } else {
          print
        }
      }
      END { if (replaced != 1) exit 2 }
    ' "$template_file" > "$tmp_file"; then
      rm -f "$tmp_file"
      fail "Invalid SQL Developer preferences template: $template_file"
    fi
    mv "$tmp_file" "$preference_file"
    log_info "Installed sdcli-autokit SQL Developer preferences: $preference_file"
    return 0
  fi

  if ! grep -F '<!-- sdcli-autokit FileOutputOption v1 begin -->' "$preference_file" >/dev/null 2>&1 \
      || ! grep -F '<!-- sdcli-autokit FileOutputOption v1 end -->' "$preference_file" >/dev/null 2>&1; then
    if [[ -f "$prefs_root/.autokit-profile" ]]; then
      # SDCLI strips template comments when it saves its own metadata. The
      # profile lifecycle establishes ownership; never rewrite that saved XML.
      log_info "Retained SQL Developer-saved project preferences: $preference_file"
      return 0
    fi
    log_warn "SQL Developer preferences are not managed by sdcli-autokit; left unchanged: $preference_file (inspect FileOutputOption manually; retain saved encryption metadata)"
    return 0
  fi

  tmp_file="$(mktemp "${preference_file}.XXXXXX")" || return 1
  if ! awk -v output_option="$output_option" '
    $0 ~ /^[[:space:]]*<!--[[:space:]]*sdcli-autokit FileOutputOption v1 begin[[:space:]]*-->[[:space:]]*$/ {
      if (in_managed || begin_count > 0) exit 2
      in_managed=1
      begin_count++
      print
      next
    }
    $0 ~ /^[[:space:]]*<!--[[:space:]]*sdcli-autokit FileOutputOption v1 end[[:space:]]*-->[[:space:]]*$/ {
      if (!in_managed || end_count > 0) exit 2
      in_managed=0
      end_count++
      print
      next
    }
    in_managed && $0 ~ /^[[:space:]]*<value n="FileOutputOption" v="[0-9]+"\/>[[:space:]]*$/ {
      if (replaced > 0) exit 2
      print "      <value n=\"FileOutputOption\" v=\"" output_option "\"/>"
      replaced++
      next
    }
    { print }
    END {
      if (in_managed || begin_count != 1 || end_count != 1 || replaced != 1) exit 2
    }
  ' "$preference_file" > "$tmp_file"; then
    rm -f "$tmp_file"
    log_warn "SQL Developer preferences contain an invalid sdcli-autokit managed block; left unchanged: $preference_file"
    return 0
  fi

  if cmp -s "$tmp_file" "$preference_file"; then
    rm -f "$tmp_file"
    return 0
  fi

  mv "$tmp_file" "$preference_file"
  log_info "Configured SQL Developer FileOutputOption=$output_option: $preference_file"
}

migration_value_path() {
  local idx="$1"
  shift
  local path=".migrations[$idx]" part
  for part in "$@"; do
    path="${path}.${part}"
  done
  echo "$path"
}

migration_required_value() {
  local path
  path="$(migration_value_path "$@")"
  get_required_value "$path" "${path#.}"
}

migration_optional_value() {
  local path
  path="$(migration_value_path "$@")"
  get_optional_value "$path"
}

migration_secret_value() {
  local path
  path="$(migration_value_path "$@")"
  get_secret_value "$path" "${path#.}"
}

is_env_placeholder() {
  local value="$1"
  [[ "$value" =~ ^\$\{[A-Za-z_][A-Za-z0-9_]*\}$ ]]
}

resolve_env_placeholder() {
  local value="$1"

  if ! is_env_placeholder "$value"; then
    echo "$value"
    return 0
  fi

  local env_name="${value:2:${#value}-3}"
  local env_value="${!env_name-}"

  if [[ -n "$env_value" ]]; then
    register_sensitive_value "$env_value"
    echo "$env_value"
    return 0
  fi

  if $DRY_RUN; then
    echo "DRY_RUN_SECRET"
    return 0
  fi

  fail "Environment variable '$env_name' is not set or empty"
}

register_sensitive_value() {
  local value="$1"
  local existing
  local inserted=false
  local -a ordered=()

  [[ -n "$value" ]] || return 0
  for existing in "${SENSITIVE_VALUES[@]+"${SENSITIVE_VALUES[@]}"}"; do
    [[ "$existing" == "$value" ]] && return 0
  done

  # Replace longer literals first so an overlapping shorter secret cannot
  # expose the unmatched suffix of a longer credential.
  for existing in "${SENSITIVE_VALUES[@]+"${SENSITIVE_VALUES[@]}"}"; do
    if [[ "$inserted" == "false" ]] && (( ${#value} > ${#existing} )); then
      ordered+=("$value")
      inserted=true
    fi
    ordered+=("$existing")
  done
  if [[ "$inserted" == "false" ]]; then
    ordered+=("$value")
  fi
  SENSITIVE_VALUES=("${ordered[@]}")
}

register_environment_secrets() {
  local env_name env_value

  while IFS='=' read -r env_name env_value; do
    case "$env_name" in
      *PASSWORD*|*PASSWD*|*SECRET*|*TOKEN*)
        register_sensitive_value "$env_value"
        ;;
    esac
  done < <(env)
}

redact_text() {
  local redacted="$1"
  local secret

  for secret in "${SENSITIVE_VALUES[@]+"${SENSITIVE_VALUES[@]}"}"; do
    [[ -n "$secret" ]] || continue
    redacted="${redacted//"$secret"/***}"
  done
  printf '%s' "$redacted"
}

validate_single_line_secret() {
  local label="$1"
  local value="$2"

  register_sensitive_value "$value"
  if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
    fail "$label contains an unsupported line-break character"
  fi
}

register_sqlplus_secret() {
  local label="$1"
  local value="$2"

  validate_single_line_secret "$label" "$value"
  # SQL*Plus double-quotes embedded quotes in both CONNECT commands and DEFINE
  # values. Register that exact transport literal as well as the raw value.
  register_sensitive_value "${value//\"/\"\"}"
}

validate_sdcli_conn_details_password() {
  local label="$1"
  local value="$2"

  validate_single_line_secret "$label" "$value"
  if [[ "$value" == *','* || "$value" == *'/'* ]]; then
    fail "$label contains an unsupported SDCLI -connDetails delimiter (comma or slash); use a password without those characters"
  fi
}

get_secret_value() {
  local path="$1"
  local label="$2"
  local value
  value="$(get_required_value "$path" "$label")"
  resolve_env_placeholder "$value"
}

validate_secret_placeholder() {
  local path="$1"
  local label="$2"
  local value
  value="$(get_required_value "$path" "$label")"
  if ! is_env_placeholder "$value"; then
    fail "$label must use environment variable placeholder format like \${VAR_NAME}"
  fi
  resolve_env_placeholder "$value" >/dev/null
}

validate_migration_secret_placeholder() {
  local path
  path="$(migration_value_path "$@")"
  validate_secret_placeholder "$path" "${path#.}"
}

require_active_repository_identity() {
  [[ -n "$ACTIVE_REPOSITORY_CONN" ]] || fail "Active migration '$ACTIVE_MIGRATION_NAME' has no repository endpoint"
  [[ -n "$ACTIVE_REPOSITORY_NAME" ]] || fail "Active migration '$ACTIVE_MIGRATION_NAME' has no repository connection name"
}

require_active_repository_context() {
  [[ -n "$ACTIVE_MIGRATION_NAME" ]] || fail "No active migration repository context was resolved"
  require_active_repository_identity
  [[ -n "$ACTIVE_SUPER_CONNECTION_NAME" ]] || fail "Active migration '$ACTIVE_MIGRATION_NAME' has no super-user connection name"
}

derive_migration_connection_name() {
  local prefix="$1"
  local migration_name="$2"

  [[ -n "$prefix" ]] || fail "Repository connection-name prefix must not be empty"
  [[ -n "$migration_name" ]] || fail "Migration name must not be empty when deriving repository connection names"
  printf '%s_%s\n' "$prefix" "$migration_name"
}

resolve_migration_context() {
  local index="$1"
  local migration_name repository_conn repository_prefix super_prefix migration_wallet default_wallet

  migration_name="$(migration_required_value "$index" name)"
  repository_conn="$(migration_required_value "$index" target conn)"
  repository_prefix="$(get_required_value '.migration_repository.repo_user.connection_name' 'migration_repository.repo_user.connection_name')"
  super_prefix="$(get_required_value '.migration_repository.super_user.connection_name' 'migration_repository.super_user.connection_name')"
  migration_wallet="$(migration_optional_value "$index" target wallet_dir)"
  default_wallet="$(get_optional_value '.defaults.target.wallet_dir')"

  ACTIVE_MIGRATION_INDEX="$index"
  ACTIVE_MIGRATION_NAME="$migration_name"
  ACTIVE_REPOSITORY_CONN="$repository_conn"
  ACTIVE_REPOSITORY_NAME="$(derive_migration_connection_name "$repository_prefix" "$migration_name")"
  ACTIVE_SUPER_CONNECTION_NAME="$(derive_migration_connection_name "$super_prefix" "$migration_name")"
  if [[ -n "$migration_wallet" ]]; then
    ACTIVE_WALLET_DIR="$migration_wallet"
    ACTIVE_WALLET_CONFIG_PATH=".migrations[$index].target.wallet_dir"
  else
    ACTIVE_WALLET_DIR="$default_wallet"
    ACTIVE_WALLET_CONFIG_PATH='.defaults.target.wallet_dir'
  fi
}

resolve_global_repository_context() {
  ACTIVE_MIGRATION_INDEX=""
  ACTIVE_MIGRATION_NAME=""
  ACTIVE_REPOSITORY_CONN="$(get_required_value '.migration_repository.conn' 'migration_repository.conn')"
  ACTIVE_REPOSITORY_NAME="$(get_required_value '.migration_repository.repo_user.connection_name' 'migration_repository.repo_user.connection_name')"
  ACTIVE_SUPER_CONNECTION_NAME="$(get_required_value '.migration_repository.super_user.connection_name' 'migration_repository.super_user.connection_name')"
  ACTIVE_WALLET_DIR="$(get_optional_value '.defaults.target.wallet_dir')"
  ACTIVE_WALLET_CONFIG_PATH='.defaults.target.wallet_dir'
}

to_lower() {
  echo "$1" | tr '[:upper:]' '[:lower:]'
}

validate_supported_migration_pair() {
  local source_type target_type
  source_type="$(to_lower "$(get_required_value '.defaults.source.type' 'defaults.source.type')")"
  target_type="$(to_lower "$(get_required_value '.defaults.target.type' 'defaults.target.type')")"

  if [[ "$source_type" != "sqlserver" || "$target_type" != "oracle" ]]; then
    fail "Unsupported migration pair: $source_type -> $target_type. Supported migration pair: sqlserver -> oracle"
  fi
}

normalize_bcp_tls_mode() {
  local raw="$1"
  local mode
  mode="$(to_lower "$raw")"
  case "$mode" in
    strict|trust|optional) echo "$mode" ;;
    *) fail "Invalid bcp_tls_mode '$raw'. Allowed values: strict, trust, optional" ;;
  esac
}

normalize_bcp_packet_size() {
  local raw="$1"
  [[ "$raw" =~ ^[0-9]+$ ]] || fail "Invalid offload_preferences.packet_size '$raw'. Must be an integer from 512 to 65535"
  if (( raw < 512 || raw > 65535 )); then
    fail "Invalid offload_preferences.packet_size '$raw'. Must be an integer from 512 to 65535"
  fi
  echo "$raw"
}

validate_bcp_packet_size_for_tls() {
  local tls_mode="$1"
  local packet_size="$2"
  local max_packet_size=65535

  case "$tls_mode" in
    strict|trust)
      max_packet_size=16383
      ;;
    optional)
      max_packet_size=65535
      ;;
  esac

  if (( packet_size > max_packet_size )); then
    fail "bcp_tls_mode=$tls_mode supports offload_preferences.packet_size up to $max_packet_size"
  fi

  echo "$packet_size"
}

get_bcp_packet_size() {
  local value
  value="$(get_optional_value '.defaults.offload_preferences.packet_size')"
  value="${value:-65535}"
  normalize_bcp_packet_size "$value"
}

check_source_tcp_connectivity() {
  local host="$1"
  local port="$2"
  local timeout_seconds="${SDCLI_CONNECT_TIMEOUT_SEC:-10}"

  if $DRY_RUN; then
    log_info "[DRY-RUN] source TCP preflight: ${host}:${port}"
    return 0
  fi

  [[ "$timeout_seconds" =~ ^[0-9]+$ ]] && (( timeout_seconds > 0 )) \
    || fail "SDCLI_CONNECT_TIMEOUT_SEC must be a positive integer"

  # SQL Developer's JTDS connection test can wait for the operating-system TCP
  # timeout when a customer firewall drops packets. Detect that condition first
  # and identify the endpoint that needs to be reachable from this host.
  if ! command -v timeout >/dev/null 2>&1; then
    log_warn "Cannot preflight source TCP connectivity: 'timeout' is unavailable"
    return 0
  fi
  if ! timeout "$timeout_seconds" bash -c 'exec 3<>"/dev/tcp/$1/$2"' bash "$host" "$port"; then
    fail "Cannot reach SQL Server source ${host}:${port} from this host; check network routing and firewall rules (set SDCLI_CONNECT_TIMEOUT_SEC to adjust the ${timeout_seconds}s preflight)"
  fi
}

# --- SDCLI execution ---------------------------------------------------------
redact_sdcli_output() {
  local line

  # Config helpers often resolve placeholders through command substitutions,
  # so collect conventionally named environment secrets again at the output
  # boundary. Replacement remains literal and does not parse tool syntax.
  register_environment_secrets

  while IFS= read -r line || [[ -n "$line" ]]; do
    printf '%s\n' "$(redact_text "$line")"
  done
}

filter_sdcli_console_output() {
  local line

  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      "WARNING: A terminally deprecated method in java.lang.System has been called" | \
      "WARNING: System::setSecurityManager will be removed in a future release" | \
      "WARNING: Please consider reporting this to the maintainers of oracle.ide.IdeCore" | \
      "WARNING: Please consider reporting this to the maintainers of org.netbeans.TopSecurityManager")
        continue
        ;;
    esac

    if [[ "$line" =~ ^WARNING:\ System::setSecurityManager\ has\ been\ called\ by\ (oracle\.ide\.IdeCore|org\.netbeans\.TopSecurityManager)[[:space:]]+\(file:.*\)$ ]]; then
      continue
    fi

    printf '%s\n' "$line"
  done
}

sdcli_has_only_benign_diagnostics() {
  local action="$1"
  local completed_successfully="$2"
  local output_file="$3"
  local unexpected

  # SQL Developer repository initialization is idempotent but reports an
  # existing repository user as an Oracle error. This is the only known error
  # that is safe after init explicitly reports completion. Never use the
  # success marker as a blanket exception for other diagnostics.
  [[ "$action" == "init" && "$completed_successfully" == "true" ]] || return 1
  grep -Eq 'ORA-01920:' "$output_file" || return 1
  ! grep -Eqi '^[[:space:]]*fatal[[:space:]:]' "$output_file" || return 1

  unexpected="$(grep -Ei '^[[:space:]]*error([[:space:]:]|$)' "$output_file" \
    | grep -Eiv '^[[:space:]]*Error starting at line([[:space:]:]|$)|^[[:space:]]*Error report[[:space:]]*-[[:space:]]*$' || true)"
  [[ -z "$unexpected" ]] || return 1

  unexpected="$(grep -Eo 'ORA-[0-9]{5}:' "$output_file" | grep -Ev '^ORA-01920:$' || true)"
  [[ -z "$unexpected" ]] || return 1

  ! grep -Eqi '(^|[^[:alnum:]_])(PLS|SP2|LRM)-[0-9]{4,5}:' "$output_file"
}

sdcli_output_has_diagnostics() {
  local output_file="$1"

  grep -Eqi \
    '^[[:space:]]*(error|fatal)([[:space:]:]|$)|(^|[^[:alnum:]_])(ORA|PLS|SP2|LRM)-[0-9]{4,5}:' \
    "$output_file"
}

run_sdcli() {
  local cmd=("$@")
  local printable output_file rc arg action="" is_convert=false is_help=false completed_successfully=false timeout_seconds errexit_enabled=false
  for arg in "${cmd[@]}"; do
    [[ "$arg" == -help=* || "$arg" == -h=* ]] && is_help=true
    if [[ "$arg" == -actions=* ]]; then
      action="${arg#-actions=}"
      [[ "$action" == "convert" ]] && is_convert=true
    fi
  done
  SDCLI_LAST_ACTION="$action"
  SDCLI_LAST_SUCCESS_MARKER=false
  [[ -n "$SDCLI_PROFILE_DIR" ]] || { log_error 'No SQL Developer project profile selected'; return 1; }
  register_environment_secrets
  printable="$(mask_sensitive "${cmd[@]}")"

  log_info "+ $printable"
  SDCLI_COMMANDS+=("$printable")
  if [[ -n "${SDCLI_COMMAND_LOG:-}" ]]; then
    echo "$printable" >> "$SDCLI_COMMAND_LOG"
  fi

  if $DRY_RUN; then
    return 0
  fi

  output_file="$(mktemp "${TMPDIR:-/tmp}/sdcli_output_XXXXXX")" || return 1
  timeout_seconds="$SDCLI_COMMAND_TIMEOUT_SEC"
  if ! [[ "$timeout_seconds" =~ ^[0-9]+$ ]]; then
    log_error "SDCLI_COMMAND_TIMEOUT_SEC must be a non-negative integer, got '$timeout_seconds'"
    rm -f "$output_file"
    return 1
  fi

  [[ "$-" == *e* ]] && errexit_enabled=true
  set +e
  if (( timeout_seconds > 0 )) && command -v timeout >/dev/null 2>&1; then
    timeout "$timeout_seconds" env "IDE_USER_DIR=$SDCLI_PROFILE_DIR" "${cmd[@]}" 2>&1 | tee "$output_file" | redact_sdcli_output | tee -a "$RUN_LOG_FILE" | filter_sdcli_console_output
  else
    env "IDE_USER_DIR=$SDCLI_PROFILE_DIR" "${cmd[@]}" 2>&1 | tee "$output_file" | redact_sdcli_output | tee -a "$RUN_LOG_FILE" | filter_sdcli_console_output
  fi
  rc=${PIPESTATUS[0]}

  if [[ "$rc" == "124" && "$timeout_seconds" != "0" ]]; then
    log_error "SDCLI command timed out after ${timeout_seconds}s"
  fi

  # Some SDCLI releases report a fatal diagnostic on standard output while
  # returning zero. Only an exact, understood init diagnostic is benign.
  if [[ -n "$action" ]] && grep -Eqi "^[[:space:]]*${action}[[:space:]]+completed successfully[[:space:]]*$" "$output_file"; then
    completed_successfully=true
    SDCLI_LAST_SUCCESS_MARKER=true
  fi
  if sdcli_output_has_diagnostics "$output_file"; then
    if ! sdcli_has_only_benign_diagnostics "$action" "$completed_successfully" "$output_file"; then
      rc=1
    fi
  fi
  if (( rc == 0 )) && ! $is_help && [[ -z "$action" || "$completed_successfully" != "true" ]]; then
    log_error "SDCLI did not report the exact completion marker for action '${action:-unknown}'"
    rc=1
  fi
  if $is_convert && grep -Eq '\[[[:space:]]*line[[:space:]]+[0-9]+:[0-9]+:' "$output_file"; then
    log_error "SQL Developer reported conversion diagnostics; review the object errors before generating deployment SQL"
    rc=1
  fi
  if [[ -n "${SDCLI_CAPTURE_OUTPUT_FILE:-}" ]]; then
    cp "$output_file" "$SDCLI_CAPTURE_OUTPUT_FILE" || rc=1
  fi
  rm -f "$output_file"
  $errexit_enabled && set -e
  return "$rc"
}

ensure_connection() {
  local conn_name="$1"
  local conn_details="$2"
  log_info "Creating SDCLI connection: $conn_name"
  run_sdcli sdcli migration -actions=mkconn -connDetails="$conn_details" || fail "Failed to create connection: $conn_name"
}

append_migration_summary() {
  local migration_name="$1"
  local status="$2"
  local model_name="$3"
  local output_dir="$4"
  local duration_sec="$5"
  local note="$6"

  note="${note//,/;}"
  echo "$(timestamp),$migration_name,$status,$model_name,$output_dir,$duration_sec,\"$note\"" >> "$MIGRATION_SUMMARY_FILE"
}

sanitize_status_field() {
  local value="$1"
  value="${value//$'\t'/ }"
  value="${value//$'\r'/ }"
  value="${value//$'\n'/ }"
  printf '%s' "$value"
}

record_phase_status() {
  local phase="$1"
  local state="$2"
  local exit_code="$3"
  local note="${4:-}"
  local attempt="${5:-1}"

  [[ -n "${PHASE_STATUS_FILE:-}" ]] || return 0
  mkdir -p "$(dirname "$PHASE_STATUS_FILE")"
  if [[ ! -s "$PHASE_STATUS_FILE" ]]; then
    printf 'timestamp\tphase\tstate\texit_code\tattempt\tnote\n' > "$PHASE_STATUS_FILE"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(timestamp)" \
    "$(sanitize_status_field "$phase")" \
    "$(sanitize_status_field "$state")" \
    "$exit_code" \
    "$attempt" \
    "$(sanitize_status_field "$note")" >> "$PHASE_STATUS_FILE"
}

phase_succeeded() {
  local phase="$1"
  [[ -s "${PHASE_STATUS_FILE:-}" ]] || return 1
  awk -F '\t' -v phase="$phase" 'NR > 1 && $2 == phase && $3 == "succeeded" { found=1 } END { exit(found ? 0 : 1) }' "$PHASE_STATUS_FILE"
}

phase_attempt_number() {
  local phase="$1"
  local previous=0
  if [[ -s "${PHASE_STATUS_FILE:-}" ]]; then
    previous="$(awk -F '\t' -v phase="$phase" 'NR > 1 && $2 == phase && $3 == "started" { count++ } END { print count+0 }' "$PHASE_STATUS_FILE")"
  fi
  echo $((previous + 1))
}

begin_phase_status() {
  local phase="$1"
  if [[ "$phase" != "validate" ]] && phase_succeeded "$phase" && ! $RERUN_COMPLETED; then
    fail "Phase '$phase' already succeeded in this run; use --rerun-completed with an explicit --phase and --run command to repeat it"
  fi

  ACTIVE_PHASE="$phase"
  ACTIVE_PHASE_ATTEMPT="$(phase_attempt_number "$phase")"
  local note=""
  $RERUN_COMPLETED && note="operator requested rerun of completed phase"
  record_phase_status "$phase" "started" "" "$note" "$ACTIVE_PHASE_ATTEMPT"
}

complete_phase_status() {
  local phase="$1"
  record_phase_status "$phase" "succeeded" "0" "" "${ACTIVE_PHASE_ATTEMPT:-1}"
  ACTIVE_PHASE=""
  ACTIVE_PHASE_ATTEMPT=""
}

repository_lock_key() {
  local identity="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$identity" | sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$identity" | shasum -a 256 | awk '{print $1}'
  else
    printf '%s' "$identity" | cksum | awk '{print $1}'
  fi
}

acquire_repository_lock() {
  local repo_user repo_conn lock_key lock_root owner_file owner=""
  require_active_repository_identity
  repo_user="$(get_required_value '.migration_repository.repo_user.user' 'migration_repository.repo_user.user')"
  repo_conn="$ACTIVE_REPOSITORY_CONN"
  lock_key="$(repository_lock_key "${repo_user}|${repo_conn}")"
  lock_root="$PROJECT_ROOT/.locks"
  REPOSITORY_LOCK_DIR="$lock_root/repository_${lock_key}.lock"
  owner_file="$REPOSITORY_LOCK_DIR/owner"
  mkdir -p "$lock_root"

  if ! mkdir "$REPOSITORY_LOCK_DIR" 2>/dev/null; then
    [[ -f "$owner_file" ]] && owner="$(tr '\n' ' ' < "$owner_file")"
    fail "Migration repository is already in use${owner:+ ($owner)}. If no workflow is active, remove the stale lock directory: $REPOSITORY_LOCK_DIR"
  fi

  REPOSITORY_LOCK_HELD=true
  {
    printf 'pid=%s\n' "$$"
    printf 'host=%s\n' "$(hostname 2>/dev/null || echo unknown)"
    printf 'run_id=%s\n' "$RUN_ID"
    printf 'migration=%s\n' "${MIGRATION_NAME:-_init}"
    printf 'started=%s\n' "$(timestamp)"
  } > "$owner_file"
  log_info "Acquired migration repository lock: $REPOSITORY_LOCK_DIR"
}

release_repository_lock() {
  $REPOSITORY_LOCK_HELD || return 0
  [[ -n "$REPOSITORY_LOCK_DIR" && -d "$REPOSITORY_LOCK_DIR" ]] || {
    REPOSITORY_LOCK_HELD=false
    return 0
  }
  rm -f "$REPOSITORY_LOCK_DIR/owner"
  rmdir "$REPOSITORY_LOCK_DIR" 2>/dev/null || true
  REPOSITORY_LOCK_HELD=false
}

mode_needs_repository_lock() {
  case "$MODE" in
    init|full|migrate) return 0 ;;
    phase)
      case "$PHASE_NAME" in
        capture|convert|generate|datamove) return 0 ;;
      esac
      ;;
  esac
  return 1
}

log_timed_result() {
  local label="$1"
  local rc="$2"
  local start_ts="$3"
  local elapsed_sec
  elapsed_sec=$(( $(date +%s) - start_ts ))

  if [[ $rc -eq 0 ]]; then
    log_info "$label completed: wall_elapsed_sec=$elapsed_sec"
  else
    log_warn "$label failed: wall_elapsed_sec=$elapsed_sec exit_code=$rc"
  fi
}

validate_load_preferences() {
  local path="$1"
  local label="$2"
  local load_direct load_rows load_bindsize load_readsize

  load_direct="$(get_optional_value "$path.direct")"
  [[ -z "$load_direct" ]] || get_bool_value "$label.direct" "$load_direct" >/dev/null
  load_rows="$(get_optional_value "$path.rows")"
  [[ -z "$load_rows" ]] || get_sqlldr_rows_default_check "$load_rows" >/dev/null
  load_bindsize="$(get_optional_value "$path.bindsize")"
  [[ -z "$load_bindsize" ]] || get_sqlldr_buffer_size "$label.bindsize" "$load_bindsize" >/dev/null
  load_readsize="$(get_optional_value "$path.readsize")"
  [[ -z "$load_readsize" ]] || get_sqlldr_buffer_size "$label.readsize" "$load_readsize" >/dev/null
}

validate_migration_config() {
  local idx="$1"

  migration_required_value "$idx" name >/dev/null
  migration_required_value "$idx" source conn >/dev/null
  migration_required_value "$idx" source user >/dev/null
  validate_migration_secret_placeholder "$idx" source password
  migration_required_value "$idx" target conn >/dev/null
  migration_required_value "$idx" target user >/dev/null
  validate_migration_secret_placeholder "$idx" target password
  validate_migration_secret_placeholder "$idx" target default_schema_password
  validate_load_preferences ".migrations[$idx].load_preferences" "migrations[$idx].load_preferences"
}

validate_config() {
  local require_migrations="${1:-true}"
  local selected_migration_index="${2:-}"

  validate_supported_migration_pair
  get_required_value '.defaults.driver_file' 'defaults.driver_file' >/dev/null
  get_required_value '.defaults.paths.project_root' 'defaults.paths.project_root' >/dev/null
  local bcp_tls_mode
  bcp_tls_mode="$(normalize_bcp_tls_mode "$(get_required_value '.defaults.source.bcp_tls_mode' 'defaults.source.bcp_tls_mode')")"
  validate_bcp_packet_size_for_tls "$bcp_tls_mode" "$(get_bcp_packet_size)" >/dev/null

  get_required_value '.migration_repository.name' 'migration_repository.name' >/dev/null
  get_required_value '.migration_repository.repo_user.connection_name' 'migration_repository.repo_user.connection_name' >/dev/null
  get_required_value '.migration_repository.repo_user.user' 'migration_repository.repo_user.user' >/dev/null
  get_required_value '.migration_repository.super_user.connection_name' 'migration_repository.super_user.connection_name' >/dev/null
  get_required_value '.migration_repository.super_user.user' 'migration_repository.super_user.user' >/dev/null
  validate_secret_placeholder '.migration_repository.repo_user.password' 'migration_repository.repo_user.password'
  validate_secret_placeholder '.migration_repository.super_user.password' 'migration_repository.super_user.password'

  validate_load_preferences ".defaults.load_preferences" "defaults.load_preferences"

  if [[ "$require_migrations" != "true" ]]; then
    return 0
  fi

  local migration_count
  migration_count="$(yq_eval '.migrations | length')"
  [[ "$migration_count" =~ ^[0-9]+$ ]] || fail "Invalid migrations list in config"
  (( migration_count > 0 )) || fail "No migrations defined in config"

  if [[ -n "$selected_migration_index" ]]; then
    [[ "$selected_migration_index" =~ ^[0-9]+$ && "$selected_migration_index" -lt "$migration_count" ]] \
      || fail "Selected migration index is invalid: $selected_migration_index"
    validate_migration_config "$selected_migration_index"
    return 0
  fi

  local i
  for ((i = 0; i < migration_count; i++)); do
    validate_migration_config "$i"
  done
}

validate_datatype_mapping_config() {
  get_required_value '.migration_repository.repo_user.user' 'migration_repository.repo_user.user' >/dev/null
  validate_secret_placeholder '.migration_repository.repo_user.password' 'migration_repository.repo_user.password'
}

run_repository_sql_capture() {
  local sql_file="$1"
  local output_file="$2"
  local repo_conn repo_user repo_password connect_password rc producer_rc
  local errexit_enabled=false
  local -a pipeline_status=()

  require_active_repository_identity
  repo_conn="$ACTIVE_REPOSITORY_CONN"
  repo_user="$(get_required_value '.migration_repository.repo_user.user' 'migration_repository.repo_user.user')"
  repo_password="$(get_secret_value '.migration_repository.repo_user.password' 'migration_repository.repo_user.password')"
  register_sqlplus_secret "migration_repository.repo_user.password" "$repo_password"
  connect_password="${repo_password//\"/\"\"}"

  [[ "$-" == *e* ]] && errexit_enabled=true
  set +e
  {
    printf 'connect %s/"%s"@%s\n' "$repo_user" "$connect_password" "$repo_conn"
    cat "$sql_file"
  } | sqlplus -S -L /nolog > "$output_file" 2>&1
  pipeline_status=("${PIPESTATUS[@]}")
  producer_rc=${pipeline_status[0]}
  rc=${pipeline_status[1]}
  $errexit_enabled && set -e

  if [[ $producer_rc -ne 0 || $rc -ne 0 ]]; then
    redact_sdcli_output < "$output_file" >&2
    [[ $producer_rc -eq 0 ]] || return "$producer_rc"
    return "$rc"
  fi
  return 0
}

datatype_mapping_preflight() {
  local temp_dir="$1"
  local query_file="$temp_dir/preflight.sql"
  local raw_file="$temp_dir/preflight.out"
  local missing_count

  cat > "$query_file" <<'SQL'
WHENEVER OSERROR EXIT FAILURE;
WHENEVER SQLERROR EXIT SQL.SQLCODE;
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 32767 VERIFY OFF ECHO OFF TERMOUT ON TRIMSPOOL ON;
SET DEFINE OFF
WITH required_columns (table_name, column_name) AS (
  SELECT 'MD_PROJECTS', 'ID' FROM dual UNION ALL
  SELECT 'MD_PROJECTS', 'PROJECT_NAME' FROM dual UNION ALL
  SELECT 'MIGR_DATATYPE_TRANSFORM_MAP', 'ID' FROM dual UNION ALL
  SELECT 'MIGR_DATATYPE_TRANSFORM_MAP', 'PROJECT_ID_FK' FROM dual UNION ALL
  SELECT 'MIGR_DATATYPE_TRANSFORM_MAP', 'MAP_NAME' FROM dual UNION ALL
  SELECT 'MIGR_DATATYPE_TRANSFORM_RULE', 'ID' FROM dual UNION ALL
  SELECT 'MIGR_DATATYPE_TRANSFORM_RULE', 'MAP_ID_FK' FROM dual UNION ALL
  SELECT 'MIGR_DATATYPE_TRANSFORM_RULE', 'SOURCE_DATA_TYPE_NAME' FROM dual UNION ALL
  SELECT 'MIGR_DATATYPE_TRANSFORM_RULE', 'SOURCE_PRECISION' FROM dual UNION ALL
  SELECT 'MIGR_DATATYPE_TRANSFORM_RULE', 'SOURCE_SCALE' FROM dual UNION ALL
  SELECT 'MIGR_DATATYPE_TRANSFORM_RULE', 'TARGET_DATA_TYPE_NAME' FROM dual UNION ALL
  SELECT 'MIGR_DATATYPE_TRANSFORM_RULE', 'TARGET_PRECISION' FROM dual UNION ALL
  SELECT 'MIGR_DATATYPE_TRANSFORM_RULE', 'TARGET_SCALE' FROM dual
)
SELECT 'SDCLI_DATATYPE_PRECHECK' || CHR(9) || COUNT(*)
FROM required_columns required
WHERE NOT EXISTS (
  SELECT 1
  FROM user_tab_columns actual
  WHERE actual.table_name = required.table_name
    AND actual.column_name = required.column_name
);
EXIT;
SQL

  if ! run_repository_sql_capture "$query_file" "$raw_file"; then
    cleanup_datatype_mapping_temp_dirs
    fail "Failed to inspect the SQL Developer repository datatype mapping schema"
  fi

  if ! missing_count="$(awk -F '\t' '
    /^[[:space:]]*$/ { next }
    $1 != "SDCLI_DATATYPE_PRECHECK" || NF != 2 || $2 !~ /^[0-9]+$/ { invalid=1; next }
    { rows++; value=$2 }
    END {
      if (invalid || rows != 1) exit 1
      print value
    }
  ' "$raw_file")"; then
    redact_sdcli_output < "$raw_file" >&2
    cleanup_datatype_mapping_temp_dirs
    fail "Unsupported SQL Developer repository schema: datatype mapping preflight returned malformed evidence"
  fi

  if (( missing_count != 0 )); then
    cleanup_datatype_mapping_temp_dirs
    fail "Unsupported SQL Developer repository schema: $missing_count required datatype mapping table/column definition(s) are missing"
  fi
}

show_datatype_mapping() {
  local project_name="${1:-}"
  local project_filter="WHERE 1 = 1" escaped_project=""
  local temp_dir query_file raw_file rows_file

  if [[ "$project_name" == *$'\n'* || "$project_name" == *$'\r'* ]]; then
    fail "Migration project name contains an unsupported line-break character"
  fi

  temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/sdcli_datatype_mapping_XXXXXX")" || return 1
  register_datatype_mapping_temp_dir "$temp_dir"
  query_file="$temp_dir/query.sql"
  raw_file="$temp_dir/query.out"
  rows_file="$temp_dir/rows.tsv"

  datatype_mapping_preflight "$temp_dir"

  if [[ -n "$project_name" ]]; then
    escaped_project="${project_name//\'/\'\'}"
    project_filter="WHERE p.project_name = '${escaped_project}'"
  fi

  cat > "$query_file" <<SQL
WHENEVER OSERROR EXIT FAILURE;
WHENEVER SQLERROR EXIT SQL.SQLCODE;
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 32767 VERIFY OFF ECHO OFF TERMOUT ON TRIMSPOOL ON;
SET DEFINE OFF
SELECT 'SDCLI_DATATYPE_MAPPING' || CHR(9) ||
       REPLACE(REPLACE(REPLACE(p.project_name, CHR(9), ' '), CHR(13), ' '), CHR(10), ' ') || CHR(9) ||
       REPLACE(REPLACE(REPLACE(m.map_name, CHR(9), ' '), CHR(13), ' '), CHR(10), ' ') || CHR(9) ||
       REPLACE(REPLACE(REPLACE(r.source_data_type_name, CHR(9), ' '), CHR(13), ' '), CHR(10), ' ') || CHR(9) ||
       NVL(TO_CHAR(r.source_precision), '') || CHR(9) ||
       NVL(TO_CHAR(r.source_scale), '') || CHR(9) ||
       REPLACE(REPLACE(REPLACE(r.target_data_type_name, CHR(9), ' '), CHR(13), ' '), CHR(10), ' ') || CHR(9) ||
       NVL(TO_CHAR(r.target_precision), '') || CHR(9) ||
       NVL(TO_CHAR(r.target_scale), '')
FROM md_projects p
JOIN migr_datatype_transform_map m ON m.project_id_fk = p.id
JOIN migr_datatype_transform_rule r ON r.map_id_fk = m.id
${project_filter}
ORDER BY p.project_name, m.map_name, r.source_data_type_name,
         r.source_precision NULLS FIRST, r.source_scale NULLS FIRST,
         r.target_data_type_name, r.target_precision NULLS FIRST,
         r.target_scale NULLS FIRST, r.id;
SELECT 'SDCLI_DATATYPE_COMPLETE' FROM dual;
EXIT;
SQL

  if ! run_repository_sql_capture "$query_file" "$raw_file"; then
    cleanup_datatype_mapping_temp_dirs
    fail "Failed to query SQL Developer repository datatype mappings"
  fi

  if ! awk -F '\t' -v OFS='\t' '
    /^[[:space:]]*$/ { next }
    $1 == "SDCLI_DATATYPE_COMPLETE" && NF == 1 { completed++; next }
    $1 != "SDCLI_DATATYPE_MAPPING" || NF != 9 { invalid=1; next }
    $2 == "" || $3 == "" || $4 == "" || $7 == "" { invalid=1; next }
    {
      for (i=2; i<=9; i++) printf "%s%s", $i, (i == 9 ? ORS : OFS)
    }
    END { if (invalid || completed != 1) exit 1 }
  ' "$raw_file" > "$rows_file"; then
    redact_sdcli_output < "$raw_file" >&2
    cleanup_datatype_mapping_temp_dirs
    fail "SQL Developer repository datatype mapping query returned malformed evidence"
  fi

  printf 'project\tmap_name\tsource_type\tsource_precision\tsource_scale\ttarget_type\ttarget_precision\ttarget_scale\n'
  if [[ -s "$rows_file" ]]; then
    LC_ALL=C sort -t $'\t' -k1,1 -k2,2 -k3,3 -k4,4 -k5,5 -k6,6 -k7,7 -k8,8 "$rows_file"
  fi
  cleanup_datatype_mapping_temp_dirs
}

verify_initialized_repository() {
  if $DRY_RUN; then
    log_info '[DRY-RUN] verify repository install revision and reopen saved connection'
    return 0
  fi
  local query_file="$AUTOKIT_DIR/repository_init_check.sql"
  local raw_file="$AUTOKIT_DIR/repository_init_check.out"
  # SDCLI 26.2's existence check only probes MD_CONNECTIONS. A cancelled
  # install can have that table without the revision written at install end.
  cat > "$query_file" <<'SQL'
WHENEVER OSERROR EXIT FAILURE
WHENEVER SQLERROR EXIT FAILURE
SET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 32767 TRIMSPOOL ON DEFINE OFF
SELECT 'SDCLI_REPOSITORY_READY' || CHR(9) || MAX(REVISION)
FROM MD_REPOVERSIONS
HAVING COUNT(*) > 0;
EXIT
SQL
  run_repository_sql_capture "$query_file" "$raw_file" \
    || fail "Cannot verify repository installation; inspect $raw_file before retrying init"
  awk -F '\t' '$1 == "SDCLI_REPOSITORY_READY" && $2 ~ /^[0-9]+[[:space:]]*$/ { found++ } END { exit found != 1 }' "$raw_file" \
    || fail "Repository installation is incomplete; ask the DBA to complete or repair it before retrying init. Evidence: $raw_file"
  # A new process must decrypt the saved password and open this repository.
  run_sdcli sdcli migration -actions=lscaptured \
    || fail 'Repository saved connection could not be reopened; project profile remains pending'
}

setup_repository() {
  require_active_repository_context

  local driver_file
  driver_file="$(get_required_value '.defaults.driver_file' 'defaults.driver_file')"
  run_sdcli sdcli migration -actions=driver -files="$driver_file" || fail "Failed to register SQL Server driver"
  configure_sqldeveloper_file_output_option

  local repo_label repo_name repo_conn repo_user repo_password
  repo_label="$(get_required_value '.migration_repository.name' 'migration_repository.name')"
  repo_name="$ACTIVE_REPOSITORY_NAME"
  repo_conn="$ACTIVE_REPOSITORY_CONN"
  repo_user="$(get_required_value '.migration_repository.repo_user.user' 'migration_repository.repo_user.user')"
  repo_password="$(get_secret_value '.migration_repository.repo_user.password' 'migration_repository.repo_user.password')"
  validate_sdcli_conn_details_password "migration_repository.repo_user.password" "$repo_password"

  local super_name super_user super_password
  super_name="$ACTIVE_SUPER_CONNECTION_NAME"
  super_user="$(get_required_value '.migration_repository.super_user.user' 'migration_repository.super_user.user')"
  super_password="$(get_secret_value '.migration_repository.super_user.password' 'migration_repository.super_user.password')"
  validate_sdcli_conn_details_password "migration_repository.super_user.password" "$super_password"

  local init_conn_details
  init_conn_details="${super_name}:oracle:${super_user}/${super_password}@${repo_conn},${repo_name}:mkrepouser:${repo_user}/${repo_password}:${super_name}"

  log_info "Initializing repository '${repo_label}' for migration '${ACTIVE_MIGRATION_NAME}' via connection '${repo_name}'"
  # Unlike other migration actions, init supports -conn. Select it explicitly:
  # the vendor's implicit detection otherwise depends on a "mig" alias prefix.
  run_sdcli sdcli migration -actions=init -conn="$repo_name" -connDetails="$init_conn_details" \
    || fail "Repository initialization failed; verify the Oracle connection and repository user details"
  verify_initialized_repository
}

get_migration_index() {
  local migration_name="$1"
  local count
  count="$(yq_eval '.migrations | length')"

  local i
  for ((i = 0; i < count; i++)); do
    local current
    current="$(migration_required_value "$i" name)"
    if [[ "$current" == "$migration_name" ]]; then
      echo "$i"
      return 0
    fi
  done

  fail "Migration '$migration_name' not found in config"
}

select_init_migration() {
  local migration_count

  if [[ -n "$MIGRATION_NAME" ]]; then
    get_migration_index "$MIGRATION_NAME"
    return 0
  fi

  migration_count="$(yq_eval '.migrations | length')"
  [[ "$migration_count" =~ ^[0-9]+$ ]] || fail "Invalid migrations list in config"
  if (( migration_count != 1 )); then
    fail "--init requires a migration name when config.yaml contains multiple migrations (example: ./migrate.sh <name> --init)"
  fi

  printf '0\n'
}

# --- BCP offload helpers -----------------------------------------------------
strip_outer_quotes() {
  local value="$1"
  value="${value%\"}"
  value="${value#\"}"
  value="${value%\'}"
  value="${value#\'}"
  printf '%s\n' "$value"
}

extract_bcp_table_names() {
  local bcp_script="$1"
  local line i object direction

  while IFS= read -r line; do
    line="${line//$'\r'/}"
    local words=()
    read -r -a words <<< "$line"
    for ((i = 0; i + 1 < ${#words[@]}; i++)); do
      object="$(strip_outer_quotes "${words[$i]}")"
      direction="$(to_lower "$(strip_outer_quotes "${words[$((i + 1))]}")")"

      if [[ "$direction" == "out" ]]; then
        printf '%s\n' "$object"
        break
      fi
    done
  done < "$bcp_script"
}

extract_bcp_table_names_from_dir() {
  local datamove_dir="$1"
  local script

  while IFS= read -r script; do
    extract_bcp_table_names "$script"
  done < <(find "$datamove_dir" -type f -name 'MicrosoftSQLServer_data.sh' 2>/dev/null | awk '{ print gsub(/\//, "/") " " $0 }' | LC_ALL=C sort -n -k1,1 -k2,2 | cut -d' ' -f2-)
}

summarize_bcp_output() {
  local table_names=("$@")
  local table_idx=0 total_tables=0 total_rows=0 total_elapsed_ms=0
  local rows="" packet_size="" elapsed_ms="" rows_per_sec=""
  local warnings=0 diagnostics=0
  local line

  emit_bcp_table_summary() {
    [[ -n "$rows$packet_size$elapsed_ms$rows_per_sec" ]] || return 0

    table_idx=$((table_idx + 1))
    total_tables=$((total_tables + 1))

    if [[ "$rows" =~ ^[0-9]+$ ]]; then
      total_rows=$((total_rows + rows))
    fi
    if [[ "$elapsed_ms" =~ ^[0-9]+$ ]]; then
      total_elapsed_ms=$((total_elapsed_ms + elapsed_ms))
    fi

    local table_label table_name summary
    printf -v table_label '%02d' "$table_idx"
    table_name="${table_names[$((table_idx - 1))]:-table_$table_label}"
    summary="BCP table $table_label $table_name rows=${rows:-unknown} packet=${packet_size:-unknown} elapsed_ms=${elapsed_ms:-unknown}"
    if [[ -n "$rows_per_sec" ]]; then
      summary+=" rate=$rows_per_sec"
    fi
    if (( warnings > 0 )); then
      summary+=" warnings=$warnings"
    fi
    if (( diagnostics > 0 )); then
      summary+=" diagnostics=$diagnostics"
    fi
    log_info "$summary"

    rows=""
    packet_size=""
    elapsed_ms=""
    rows_per_sec=""
    warnings=0
    diagnostics=0
  }

  log_info "BCP table summary:"

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^[[:space:]]*$ ]]; then
      continue
    fi
    if [[ "$line" =~ ^[[:space:]]*Starting[[:space:]]+copy\.\.\.[[:space:]]*$ ]]; then
      continue
    fi
    if [[ "$line" =~ ^[[:space:]]*Password:[[:space:]]*$ ]]; then
      # Password is supplied to bcp through standard input by the wrapper.
      # Its prompt is expected once per command and has no diagnostic value.
      continue
    fi
    if [[ "$line" =~ ^[[:space:]]*[0-9]+[[:space:]]+rows[[:space:]]+successfully[[:space:]]+bulk-copied[[:space:]]+to[[:space:]]+host-file\.[[:space:]]+Total[[:space:]]+received:[[:space:]]+[0-9]+$ ]]; then
      continue
    fi
    if [[ "$line" =~ ^[[:space:]]*([0-9]+)[[:space:]]+rows[[:space:]]+copied\.$ ]]; then
      rows="${BASH_REMATCH[1]}"
      continue
    fi
    if [[ "$line" =~ ^Network[[:space:]]+packet[[:space:]]+size[[:space:]]+\(bytes\):[[:space:]]*([0-9]+)$ ]]; then
      packet_size="${BASH_REMATCH[1]}"
      continue
    fi
    if [[ "$line" =~ ^Clock[[:space:]]+Time[[:space:]]+\(ms\.\)[[:space:]]+Total[[:space:]]*:[[:space:]]*([0-9]+)[[:space:]]+Average[[:space:]]*:[[:space:]]*\(([0-9.]+)[[:space:]]+rows[[:space:]]+per[[:space:]]+sec\.\)$ ]]; then
      elapsed_ms="${BASH_REMATCH[1]}"
      rows_per_sec="${BASH_REMATCH[2]}"
      emit_bcp_table_summary
      continue
    fi
    if [[ "$line" =~ ^Clock[[:space:]]+Time[[:space:]]+\(ms\.\)[[:space:]]+Total[[:space:]]*:[[:space:]]*[0-9]+[[:space:]]*$ ]]; then
      # Some bcp versions print this incomplete progress line before a final
      # summary. Command success is verified independently below.
      continue
    fi
    if [[ "$line" == *"Warning:"* ]]; then
      warnings=$((warnings + 1))
      continue
    fi
    if [[ "$line" == SQLState* ]]; then
      continue
    fi
    if [[ "$line" == Error* ]]; then
      diagnostics=$((diagnostics + 1))
      log_warn "BCP diagnostic: $line"
      continue
    fi

    log_info "BCP output: $line"
  done

  emit_bcp_table_summary

  local total_elapsed_sec
  total_elapsed_sec=$(( (total_elapsed_ms + 999) / 1000 ))
  log_info "BCP offload summary: tables=$total_tables rows=$total_rows bcp_elapsed_ms=$total_elapsed_ms bcp_elapsed_sec=$total_elapsed_sec"
  return 0
}

table_name_from_control_file() {
  local control_file="$1"
  local name
  name="$(basename "$control_file")"
  name="${name%.ctl}"
  echo "$name"
}

summarize_sqlldr_output() {
  local table_idx=0 total_tables=0 total_rows=0 total_elapsed_sec=0
  local control_file="" table_name="" output_table="" rows="" path_used="" elapsed_sec="" rc=""
  local line

  emit_sqlldr_table_summary() {
    [[ -n "$control_file$rows$elapsed_sec$rc" ]] || return 0

    table_idx=$((table_idx + 1))
    total_tables=$((total_tables + 1))

    if [[ "$rows" =~ ^[0-9]+$ ]]; then
      total_rows=$((total_rows + rows))
    fi
    if [[ "$elapsed_sec" =~ ^[0-9]+$ ]]; then
      total_elapsed_sec=$((total_elapsed_sec + elapsed_sec))
    fi

    local table_label summary status
    printf -v table_label '%02d' "$table_idx"
    if [[ -n "$control_file" ]]; then
      table_name="$(table_name_from_control_file "$control_file")"
    elif [[ -n "$output_table" ]]; then
      table_name="$output_table"
    else
      table_name="table_$table_label"
    fi
    status="success"
    if [[ -n "$rc" && "$rc" != "0" ]]; then
      status="failed($rc)"
    fi

    summary="SQL*Loader table $table_label $table_name rows=${rows:-unknown} path=${path_used:-unknown} elapsed_sec=${elapsed_sec:-unknown} status=$status"
    log_info "$summary"

    control_file=""
    table_name=""
    output_table=""
    rows=""
    path_used=""
    elapsed_sec=""
    rc=""
  }

  log_info "SQL*Loader table summary:"

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^\[SQLLDR-SUMMARY\][[:space:]]+control=([^[:space:]]*)[[:space:]]+elapsed_sec=([0-9]+)[[:space:]]+rc=([0-9]+)$ ]]; then
      control_file="${BASH_REMATCH[1]}"
      elapsed_sec="${BASH_REMATCH[2]}"
      rc="${BASH_REMATCH[3]}"
      emit_sqlldr_table_summary
      continue
    fi
    if [[ "$line" =~ ^Path[[:space:]]+used:[[:space:]]*(.+)$ ]]; then
      path_used="${BASH_REMATCH[1]}"
      continue
    fi
    if [[ "$line" =~ ^Table[[:space:]]+([^:]+):$ ]]; then
      output_table="$(echo "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')"
      continue
    fi
    if [[ "$line" =~ ^[[:space:]]*([0-9]+)[[:space:]]+Rows[[:space:]]+successfully[[:space:]]+loaded\.$ ]]; then
      rows="${BASH_REMATCH[1]}"
      continue
    fi
    if [[ "$line" =~ ^Commit[[:space:]]+point[[:space:]]+reached[[:space:]]+-[[:space:]]+logical[[:space:]]+record[[:space:]]+count[[:space:]]+[0-9]+$ ]]; then
      continue
    fi
    if [[ "$line" =~ ^Save[[:space:]]+data[[:space:]]+point[[:space:]]+reached[[:space:]]+-[[:space:]]+logical[[:space:]]+record[[:space:]]+count[[:space:]]+[0-9]+\.?$ ]]; then
      continue
    fi
    if [[ "$line" =~ ^SQL\*Loader:|^Copyright[[:space:]]|^Version[[:space:]]|^Check[[:space:]]+the[[:space:]]+log[[:space:]]+file:|^for[[:space:]]+more[[:space:]]+information ]]; then
      continue
    fi
    if [[ "$line" =~ ^SQL\> || "$line" =~ ^Connected[[:space:]]+to: || "$line" =~ ^Disconnected[[:space:]]+from[[:space:]]+Oracle || "$line" =~ ^Oracle[[:space:]] ]]; then
      continue
    fi
    if [[ "$line" == ORA-* || "$line" == SQL*Loader-* || "$line" == LRM-* ]]; then
      log_warn "SQL*Loader diagnostic: $line"
      continue
    fi
    if [[ "$line" =~ ^[[:space:]]*$ ]]; then
      continue
    fi

    log_info "SQL*Loader output: $line"
  done

  emit_sqlldr_table_summary

  log_info "SQL*Loader load summary: tables=$total_tables rows=$total_rows sqlldr_elapsed_sec=$total_elapsed_sec"
  return 0
}

parse_source_conn() {
  local source_conn="$1"
  local host port database rest
  IFS=':' read -r host port database rest <<< "$source_conn"
  [[ -n "$host" && -n "$port" && -n "$database" ]] || fail "Invalid source.conn format '$source_conn'. Expected host:port:database"
  echo "$host|$port|$database"
}

get_bool_value() {
  local name="$1"
  local value="$2"
  value="$(to_lower "$value")"
  case "$value" in
    true|false) echo "$value" ;;
    *) fail "Invalid $name '$value'. Allowed values: true or false" ;;
  esac
}

get_sqlldr_config_raw() {
  local idx="$1"
  local key="$2"
  local fallback="${3:-}"
  local migration_value default_value
  migration_value="$(migration_optional_value "$idx" load_preferences "$key")"
  if [[ -n "$migration_value" ]]; then
    echo "$migration_value"
    return 0
  fi
  default_value="$(get_optional_value ".defaults.load_preferences.${key}")"
  echo "${default_value:-$fallback}"
}

get_sqlldr_buffer_size() {
  local label="$1"
  local value="$2"
  [[ "$value" =~ ^[0-9]+$ ]] || fail "Invalid ${label} '$value'. Must be a positive integer"
  if (( value < 65536 )); then
    fail "Invalid ${label} '$value'. Use at least 65536 bytes"
  fi
  echo "$value"
}

get_sqlldr_rows_default_check() {
  local value="$1"
  [[ "$value" =~ ^[0-9]+$ ]] || fail "Invalid load_preferences.rows '$value'. Must be a positive integer"
  if (( value < 1 || value > 65534 )); then
    fail "Invalid load_preferences.rows '$value'. Conventional path maximum is 65534"
  fi
  echo "$value"
}

write_load_tns_alias() {
  local target_conn="$1"
  local alias_name="$2"

  case "$target_conn" in
    tcp://*|tcps://*) ;;
    *) echo ""; return 0 ;;
  esac

  local protocol rest query address service host port ssl_server_dn_match part lower_part tns_dir
  protocol="${target_conn%%://*}"
  protocol="$(echo "$protocol" | tr '[:lower:]' '[:upper:]')"
  rest="${target_conn#*://}"
  query=""
  if [[ "$rest" == *\?* ]]; then
    query="${rest#*\?}"
    rest="${rest%%\?*}"
  fi

  address="${rest%%/*}"
  service="${rest#*/}"
  [[ "$address" != "$rest" && -n "$service" ]] || fail "Invalid target.conn Easy Connect format for load: $target_conn"

  if [[ "$address" == *:* ]]; then
    host="${address%%:*}"
    port="${address##*:}"
  else
    host="$address"
    port="1521"
  fi
  [[ -n "$host" && -n "$port" ]] || fail "Invalid target.conn Easy Connect host/port for load: $target_conn"

  ssl_server_dn_match=""
  if [[ -n "$query" ]]; then
    local IFS='&'
    for part in $query; do
      lower_part="$(to_lower "$part")"
      case "$lower_part" in
        ssl_server_dn_match=yes) ssl_server_dn_match="YES" ;;
        ssl_server_dn_match=no) ssl_server_dn_match="NO" ;;
      esac
    done
  fi

  tns_dir="$AUTOKIT_DIR/tns"
  mkdir -p "$tns_dir"
  if [[ -n "$ORACLE_WALLET_DIR" ]]; then
    # SQL*Loader uses the generated alias below. Preserve the wallet files in
    # that generated TNS_ADMIN directory so its mTLS connection remains valid.
    cp -a "$ORACLE_WALLET_DIR/." "$tns_dir/"
  fi
  {
    echo "$alias_name ="
    echo "  (DESCRIPTION ="
    echo "    (ADDRESS = (PROTOCOL = $protocol)(HOST = $host)(PORT = $port))"
    echo "    (CONNECT_DATA = (SERVICE_NAME = $service))"
    if [[ -n "$ssl_server_dn_match" ]]; then
      echo "    (SECURITY = (SSL_SERVER_DN_MATCH = $ssl_server_dn_match))"
    fi
    echo "  )"
  } > "$tns_dir/tnsnames.ora"

  echo "$tns_dir"
}

is_sqlldr_loader_script() {
  local script="$1"
  grep -Eiq '(^|[[:space:]])sqlldr([[:space:]]|$)' "$script"
}


source "$SCRIPT_DIR/lib/sqlplus_deploy.sh"

VALIDATION_LAST_COUNT=0

is_ignored_validation_diagnostic() {
  local line="$1"
  [[ "$line" == *"ORA-28098:"* ]]
}

validate_run_log() {
  local log_file="$1"
  local start_line="${2:-0}"
  local count=0 ignored=0 historical=0 match line_no line
  local matches

  VALIDATION_LAST_COUNT=0
  [[ "$start_line" =~ ^[0-9]+$ ]] || start_line=0
  if [[ ! -f "$log_file" ]]; then
    log_warn "Run log not found: $log_file"
    return 0
  fi

  matches="$(grep -nE '\[ERROR\]|SQL\*Loader table .*status=failed|SQL\*Loader load summary: tables=0([[:space:]]|$)|SQL\*Loader diagnostic:|SQL\*Loader load failed:' "$log_file" || true)"
  while IFS= read -r match; do
    [[ -n "$match" ]] || continue
    line_no="${match%%:*}"
    line="${match#*:}"
    if (( line_no <= start_line )); then
      historical=$((historical + 1))
      continue
    fi
    if [[ "$line" == *"Run log issue:"* || "$line" == *"Run log diagnostics:"* \
        || "$line" == *"Validation summary:"* || "$line" == *"Migration validation failed with"* \
        || "$line" == *"Validate failed for migration"* ]]; then
      continue
    fi
    if is_ignored_validation_diagnostic "$line"; then
      ignored=$((ignored + 1))
      continue
    fi
    count=$((count + 1))
    log_warn "Run log issue: $log_file:$line_no: $line"
  done <<< "$matches"

  log_info "Run log diagnostics: issues=$count ignored=$ignored historical=$historical"
  VALIDATION_LAST_COUNT=$count
}

validate_sdcli_error_log() {
  local error_log="$1"
  local count=0 match line_no line max_lines=20

  VALIDATION_LAST_COUNT=0
  if [[ ! -f "$error_log" ]]; then
    log_warn "SDCLI error log not found: $error_log"
    return 0
  fi

  while IFS= read -r match; do
    line_no="${match%%:*}"
    line="${match#*:}"
    count=$((count + 1))
    if (( count <= max_lines )); then
      log_warn "SDCLI error log issue: $error_log:$line_no: $line"
    fi
  done < <(grep -nE 'ERROR|FATAL' "$error_log" || true)

  if (( count == 0 )); then
    log_info "No ERROR/FATAL entries found in $error_log"
  elif (( count > max_lines )); then
    log_warn "SDCLI error log has $((count - max_lines)) additional ERROR/FATAL entries: $error_log"
  fi
  VALIDATION_LAST_COUNT=$count
}

validate_sqlldr_log_file() {
  local log_file="$1"
  local count=0 line_no=0 line rows value

  VALIDATION_LAST_COUNT=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line_no=$((line_no + 1))
    if is_ignored_validation_diagnostic "$line"; then
      continue
    fi
    if [[ "$line" =~ SQL\*Loader-[0-9]+|ORA-[0-9]+ ]]; then
      count=$((count + 1))
      log_warn "SQL*Loader log issue: $log_file:$line_no: $line"
      continue
    fi
    if [[ "$line" =~ ^[[:space:]]*([0-9]+)[[:space:]]+Rows[[:space:]]+not[[:space:]]+loaded[[:space:]]+(due|because)[[:space:]]+ ]]; then
      rows="${BASH_REMATCH[1]}"
      if (( rows > 0 )); then
        count=$((count + 1))
        log_warn "SQL*Loader log issue: $log_file:$line_no: $line"
      fi
      continue
    fi
    if [[ "$line" =~ ^Total[[:space:]]+logical[[:space:]]+records[[:space:]]+(rejected|discarded):[[:space:]]*([0-9]+)[[:space:]]*$ ]]; then
      value="${BASH_REMATCH[2]}"
      if (( value > 0 )); then
        count=$((count + 1))
        log_warn "SQL*Loader log issue: $log_file:$line_no: $line"
      fi
    fi
  done < "$log_file"

  VALIDATION_LAST_COUNT=$count
}

run_target_sql_capture() {
  local idx="$1"
  local sql_file="$2"
  local output_file="$3"
  local target_conn target_user target_password connect_password rc errexit_enabled=false

  target_conn="$(migration_required_value "$idx" target conn)"
  target_user="$(migration_required_value "$idx" target user)"
  target_password="$(migration_secret_value "$idx" target password)"
  register_sensitive_value "$target_password"
  connect_password="${target_password//\"/\"\"}"

  [[ "$-" == *e* ]] && errexit_enabled=true
  set +e
  {
    printf 'connect %s/"%s"@%s\n' "$target_user" "$connect_password" "$target_conn"
    cat "$sql_file"
  } | sqlplus -S -L /nolog > "$output_file" 2>&1
  rc=${PIPESTATUS[1]}
  $errexit_enabled && set -e

  if [[ $rc -ne 0 ]]; then
    redact_sdcli_output < "$output_file" | tee -a "$RUN_LOG_FILE" >&2
    return "$rc"
  fi
  return 0
}

inventory_tsv_header() {
  printf '%s\n' $'schema\tcategory\tobject_name\tparent_schema\tparent_name\tsubtype\tordinal\tattribute_name\tattribute_value\tstatus\tdetail\torigin'
}

write_marked_inventory() {
  local raw_file="$1"
  local output_file="$2"
  local label="$3"
  local output_dir tmp_file row_count

  output_dir="$(dirname "$output_file")"
  mkdir -p "$output_dir"
  tmp_file="$(mktemp "$output_dir/.inventory_XXXXXX")" || return 1

  inventory_tsv_header > "$tmp_file"
  if ! awk -F '\t' -v OFS='\t' '
    /^[[:space:]]*$/ { next }
    $1 != "SDCLI_INVENTORY" { invalid=1; next }
    NF != 13 || $2 == "" || $3 == "" || $4 == "" { invalid=1; next }
    {
      for (i=2; i<=13; i++) printf "%s%s", $i, (i == 13 ? ORS : OFS)
      rows++
    }
    END { if (invalid || rows == 0) exit 1 }
  ' "$raw_file" >> "$tmp_file"; then
    rm -f "$tmp_file"
    awk -F '\t' -v label="$label" '
      /^[[:space:]]*$/ { next }
      $1 != "SDCLI_INVENTORY" {
        printf "%s inventory parse diagnostic: line %d: expected SDCLI_INVENTORY marker\n", label, NR
        next
      }
      NF != 13 {
        printf "%s inventory parse diagnostic: line %d: expected 13 tab-separated fields, got %d\n", label, NR, NF
        next
      }
      $2 == "" || $3 == "" || $4 == "" {
        printf "%s inventory parse diagnostic: line %d: schema, category, and object name are required\n", label, NR
      }
    ' "$raw_file" | redact_sdcli_output | tee -a "$RUN_LOG_FILE" >&2
    redact_sdcli_output < "$raw_file" | tee -a "$RUN_LOG_FILE" >&2
    log_error "$label inventory query returned empty or malformed evidence"
    return 1
  fi

  row_count=$(( $(wc -l < "$tmp_file" | tr -d '[:space:]') - 1 ))
  mv "$tmp_file" "$output_file"
  log_info "$label object inventory: rows=$row_count file=$output_file"
}

collect_source_object_inventory() {
  local idx="$1"
  local output_file="$2"
  local source_conn source_user source_password parsed source_host source_port source_database tls_mode
  local query raw_file
  local -a tls_args=()

  source_conn="$(migration_required_value "$idx" source conn)"
  source_user="$(migration_required_value "$idx" source user)"
  source_password="$(migration_secret_value "$idx" source password)"
  validate_single_line_secret "migrations[$idx].source.password" "$source_password"
  parsed="$(parse_source_conn "$source_conn")"
  IFS='|' read -r source_host source_port source_database <<< "$parsed"
  tls_mode="$(normalize_bcp_tls_mode "$(get_required_value '.defaults.source.bcp_tls_mode' 'defaults.source.bcp_tls_mode')")"
  case "$tls_mode" in
    strict) tls_args=(-Ns) ;;
    trust) tls_args=(-Nm -C) ;;
    optional) tls_args=(-No) ;;
  esac

  query="$(cat <<'SQL'
SET NOCOUNT ON;
DECLARE @tab nchar(1) = NCHAR(9);
WITH inventory AS (
  SELECT s.name AS schema_name, 'SCHEMAS' AS category, s.name AS object_name,
         '' AS parent_schema, '' AS parent_name, 'SCHEMA' AS subtype,
         0 AS ordinal, '' AS attribute_name, '' AS attribute_value,
         'VALID' AS status, '' AS detail
  FROM sys.schemas s
  WHERE s.name NOT IN ('sys', 'INFORMATION_SCHEMA', 'guest')
    AND s.schema_id < 16384
  UNION ALL
  SELECT SCHEMA_NAME(t.schema_id), 'TABLES', t.name, '', '', 'TABLE',
         0, '', '', 'VALID', ''
  FROM sys.tables t
  WHERE t.is_ms_shipped = 0
  UNION ALL
  SELECT SCHEMA_NAME(v.schema_id), 'VIEWS', v.name, '', '', 'VIEW',
         0, '', '', 'VALID', ''
  FROM sys.views v
  WHERE v.is_ms_shipped = 0
  UNION ALL
  SELECT SCHEMA_NAME(o.schema_id), 'ROUTINES', o.name, '', '',
         CASE WHEN o.type = 'P' THEN 'PROCEDURE' ELSE 'FUNCTION' END,
         0, '', '', 'VALID', ''
  FROM sys.objects o
  LEFT JOIN sys.procedures p ON p.object_id = o.object_id
  WHERE o.type IN ('P', 'FN', 'IF', 'TF') AND o.is_ms_shipped = 0
  UNION ALL
  SELECT SCHEMA_NAME(parent.schema_id), 'TRIGGERS', tr.name,
         SCHEMA_NAME(parent.schema_id), parent.name, 'TRIGGER',
         0, '', '',
         CASE WHEN tr.is_disabled = 1 THEN 'DISABLED' ELSE 'VALID' END, ''
  FROM sys.triggers tr
  JOIN sys.objects parent ON parent.object_id = tr.parent_id
  WHERE tr.is_ms_shipped = 0
  UNION ALL
  SELECT SCHEMA_NAME(parent.schema_id),
         CASE kc.type WHEN 'PK' THEN 'PRIMARY_KEYS' ELSE 'UNIQUE_CONSTRAINTS' END,
         kc.name, SCHEMA_NAME(parent.schema_id), parent.name, kc.type_desc,
         ic.key_ordinal, 'column', col.name, 'VALID', ''
  FROM sys.key_constraints kc
  JOIN sys.tables parent ON parent.object_id = kc.parent_object_id
  JOIN sys.index_columns ic ON ic.object_id = kc.parent_object_id AND ic.index_id = kc.unique_index_id
  JOIN sys.columns col ON col.object_id = ic.object_id AND col.column_id = ic.column_id
  WHERE parent.is_ms_shipped = 0 AND ic.key_ordinal > 0
  UNION ALL
  SELECT SCHEMA_NAME(parent.schema_id), 'FOREIGN_KEYS', fk.name,
         SCHEMA_NAME(parent.schema_id), parent.name, 'FOREIGN_KEY',
         fkc.constraint_column_id, 'column', parent_col.name, 'VALID',
         ''
  FROM sys.foreign_keys fk
  JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id = fk.object_id
  JOIN sys.tables parent ON parent.object_id = fk.parent_object_id
  JOIN sys.columns parent_col ON parent_col.object_id = fkc.parent_object_id AND parent_col.column_id = fkc.parent_column_id
  WHERE parent.is_ms_shipped = 0
  UNION ALL
  SELECT SCHEMA_NAME(parent.schema_id), 'CHECK_CONSTRAINTS', cc.name,
         SCHEMA_NAME(parent.schema_id), parent.name, 'CHECK',
         0, 'expression', cc.definition,
         CASE WHEN cc.is_disabled = 1 THEN 'DISABLED' ELSE 'VALID' END, ''
  FROM sys.check_constraints cc
  JOIN sys.tables parent ON parent.object_id = cc.parent_object_id
  WHERE parent.is_ms_shipped = 0
  UNION ALL
  SELECT SCHEMA_NAME(parent.schema_id), 'DEFAULT_CONSTRAINTS', dc.name,
         SCHEMA_NAME(parent.schema_id), parent.name, 'DEFAULT',
         col.column_id, 'column', col.name, 'VALID', dc.definition
  FROM sys.default_constraints dc
  JOIN sys.tables parent ON parent.object_id = dc.parent_object_id
  JOIN sys.columns col ON col.object_id = dc.parent_object_id AND col.column_id = dc.parent_column_id
  WHERE parent.is_ms_shipped = 0
  UNION ALL
  SELECT SCHEMA_NAME(parent.schema_id), 'INDEXES', i.name,
         SCHEMA_NAME(parent.schema_id), parent.name,
         CASE WHEN i.is_unique = 1 THEN 'UNIQUE' ELSE 'INDEX' END,
         0, 'unique', CASE WHEN i.is_unique = 1 THEN 'true' ELSE 'false' END,
         CASE WHEN i.is_disabled = 1 THEN 'DISABLED' ELSE 'VALID' END, ''
  FROM sys.indexes i
  JOIN sys.tables parent ON parent.object_id = i.object_id
  WHERE parent.is_ms_shipped = 0 AND i.name IS NOT NULL AND i.is_hypothetical = 0
    AND i.is_primary_key = 0 AND i.is_unique_constraint = 0
  UNION ALL
  SELECT SCHEMA_NAME(parent.schema_id), 'INDEXES', i.name,
         SCHEMA_NAME(parent.schema_id), parent.name,
         CASE WHEN i.is_unique = 1 THEN 'UNIQUE' ELSE 'INDEX' END,
         ic.key_ordinal, 'column', col.name,
         CASE WHEN i.is_disabled = 1 THEN 'DISABLED' ELSE 'VALID' END,
         ''
  FROM sys.indexes i
  JOIN sys.tables parent ON parent.object_id = i.object_id
  JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
  JOIN sys.columns col ON col.object_id = ic.object_id AND col.column_id = ic.column_id
  WHERE parent.is_ms_shipped = 0 AND i.name IS NOT NULL AND i.is_hypothetical = 0
    AND i.is_primary_key = 0 AND i.is_unique_constraint = 0 AND ic.key_ordinal > 0
  UNION ALL
  SELECT SCHEMA_NAME(parent.schema_id), 'IDENTITY_COLUMNS', col.name,
         SCHEMA_NAME(parent.schema_id), parent.name, 'IDENTITY',
         0, '', '', 'VALID', ''
  FROM sys.identity_columns col
  JOIN sys.tables parent ON parent.object_id = col.object_id
  WHERE parent.is_ms_shipped = 0
  UNION ALL
  SELECT SCHEMA_NAME(seq.schema_id), 'SEQUENCES', seq.name, '', '', 'SEQUENCE',
         0, '', '', 'VALID', ''
  FROM sys.sequences seq
  UNION ALL
  SELECT SCHEMA_NAME(syn.schema_id), 'SYNONYMS', syn.name, '', '', 'SYNONYM',
         0, '', '', 'VALID', ''
  FROM sys.synonyms syn
)
SELECT CONCAT(
  'SDCLI_INVENTORY', @tab,
  REPLACE(REPLACE(REPLACE(CONVERT(nvarchar(max), schema_name) COLLATE DATABASE_DEFAULT, @tab, ' '), CHAR(13), ' '), CHAR(10), ' '), @tab,
  category COLLATE DATABASE_DEFAULT, @tab,
  REPLACE(REPLACE(REPLACE(CONVERT(nvarchar(max), object_name) COLLATE DATABASE_DEFAULT, @tab, ' '), CHAR(13), ' '), CHAR(10), ' '), @tab,
  REPLACE(REPLACE(REPLACE(CONVERT(nvarchar(max), parent_schema) COLLATE DATABASE_DEFAULT, @tab, ' '), CHAR(13), ' '), CHAR(10), ' '), @tab,
  REPLACE(REPLACE(REPLACE(CONVERT(nvarchar(max), parent_name) COLLATE DATABASE_DEFAULT, @tab, ' '), CHAR(13), ' '), CHAR(10), ' '), @tab,
  subtype COLLATE DATABASE_DEFAULT, @tab, CONVERT(varchar(12), ordinal), @tab,
  attribute_name COLLATE DATABASE_DEFAULT, @tab,
  REPLACE(REPLACE(REPLACE(CONVERT(nvarchar(max), attribute_value) COLLATE DATABASE_DEFAULT, @tab, ' '), CHAR(13), ' '), CHAR(10), ' '), @tab,
  status COLLATE DATABASE_DEFAULT, @tab,
  REPLACE(REPLACE(REPLACE(CONVERT(nvarchar(max), detail) COLLATE DATABASE_DEFAULT, @tab, ' '), CHAR(13), ' '), CHAR(10), ' '), @tab,
  'sqlserver')
FROM inventory
ORDER BY schema_name, category, object_name, ordinal;
SQL
)"

  raw_file="$(mktemp "${TMPDIR:-/tmp}/sdcli_source_inventory_XXXXXX.out")" || return 1
  if ! SQLCMDPASSWORD="$source_password" sqlcmd \
    -S "${source_host},${source_port}" -d "$source_database" -U "$source_user" \
    -b -r 1 -h -1 -W -w 65535 "${tls_args[@]}" -Q "$query" > "$raw_file" 2>&1; then
    redact_sdcli_output < "$raw_file" | tee -a "$RUN_LOG_FILE" >&2
    rm -f "$raw_file"
    log_error "Failed to query SQL Server object inventory"
    return 1
  fi

  if ! write_marked_inventory "$raw_file" "$output_file" "SQL Server"; then
    rm -f "$raw_file"
    return 1
  fi
  rm -f "$raw_file"
}

collect_target_object_inventory() {
  local idx="$1"
  local output_dir="$2"
  local output_file="$3"
  local query_file raw_file schema_dir schema_name escaped_schema owners="" schema_count=0

  while IFS= read -r schema_dir; do
    schema_name="$(basename "$schema_dir")"
    [[ "$schema_name" != *$'\t'* && "$schema_name" != *$'\n'* && "$schema_name" != *$'\r'* ]] || {
      log_error "Generated schema directory contains a control character"
      return 1
    }
    escaped_schema="${schema_name//\'/\'\'}"
    [[ -z "$owners" ]] || owners+=","
    owners+="'${escaped_schema}',UPPER('${escaped_schema}')"
    schema_count=$((schema_count + 1))
  done < <(schema_dirs "$output_dir")

  if (( schema_count == 0 )); then
    log_error "Cannot collect Oracle object inventory because no generated schema hierarchy was found"
    return 1
  fi

  query_file="$(mktemp "${TMPDIR:-/tmp}/sdcli_target_inventory_XXXXXX.sql")" || return 1
  raw_file="$(mktemp "${TMPDIR:-/tmp}/sdcli_target_inventory_XXXXXX.out")" || {
    rm -f "$query_file"
    return 1
  }
  {
    printf '%s\n' 'WHENEVER OSERROR EXIT FAILURE;'
    printf '%s\n' 'WHENEVER SQLERROR EXIT SQL.SQLCODE;'
    printf '%s\n' 'SET HEADING OFF FEEDBACK OFF PAGESIZE 0 LINESIZE 32767 LONG 1000000 LONGCHUNKSIZE 1000000 VERIFY OFF ECHO OFF TERMOUT ON TRIMSPOOL ON;'
    cat <<SQL
WITH inventory AS (
  SELECT o.owner AS schema_name,
         CASE o.object_type
           WHEN 'TABLE' THEN 'TABLES' WHEN 'VIEW' THEN 'VIEWS'
           WHEN 'PROCEDURE' THEN 'ROUTINES' WHEN 'FUNCTION' THEN 'ROUTINES'
           WHEN 'PACKAGE' THEN 'PACKAGES' WHEN 'PACKAGE BODY' THEN 'PACKAGE_BODIES'
           WHEN 'SEQUENCE' THEN 'SEQUENCES'
           WHEN 'SYNONYM' THEN 'SYNONYMS'
         END AS category,
         o.object_name, '' AS parent_schema, '' AS parent_name,
         o.object_type AS subtype, 0 AS ordinal, '' AS attribute_name, '' AS attribute_value,
         o.status,
         NVL((SELECT MIN(e.type || ':' || e.line || ':' || e.position || ':' || e.text)
              FROM all_errors e
              WHERE e.owner = o.owner AND e.name = o.object_name AND e.type = o.object_type
                AND e.attribute = 'ERROR'), '') AS detail
  FROM all_objects o
  WHERE o.owner IN (${owners})
    AND o.object_type IN ('TABLE','VIEW','PROCEDURE','FUNCTION','PACKAGE','PACKAGE BODY','SEQUENCE','SYNONYM')
  UNION ALL
  SELECT tr.owner, 'TRIGGERS', tr.trigger_name, tr.table_owner, tr.table_name,
         'TRIGGER', 0, '', '',
         CASE WHEN o.status = 'VALID' AND tr.status = 'ENABLED' THEN 'VALID' ELSE 'INVALID' END,
         NVL((SELECT MIN(e.type || ':' || e.line || ':' || e.position || ':' || e.text)
              FROM all_errors e
              WHERE e.owner = tr.owner AND e.name = tr.trigger_name AND e.type = 'TRIGGER'
                AND e.attribute = 'ERROR'), '')
  FROM all_triggers tr
  LEFT JOIN all_objects o
    ON o.owner = tr.owner AND o.object_name = tr.trigger_name AND o.object_type = 'TRIGGER'
  WHERE tr.owner IN (${owners})
  UNION ALL
  SELECT c.owner,
         CASE c.constraint_type WHEN 'P' THEN 'PRIMARY_KEYS' WHEN 'U' THEN 'UNIQUE_CONSTRAINTS'
              WHEN 'R' THEN 'FOREIGN_KEYS' END,
         c.constraint_name, c.owner, c.table_name,
         CASE c.constraint_type WHEN 'P' THEN 'PRIMARY_KEY' WHEN 'U' THEN 'UNIQUE'
              WHEN 'R' THEN 'FOREIGN_KEY' END,
         NVL(cc.position, 0),
         'column', cc.column_name,
         CASE WHEN c.status = 'ENABLED' AND c.validated = 'VALIDATED' THEN 'VALID' ELSE 'INVALID' END,
         CASE WHEN c.constraint_type = 'R' THEN
           NVL((SELECT 'references=' || r.owner || '.' || r.table_name
                FROM all_constraints r WHERE r.owner = c.r_owner AND r.constraint_name = c.r_constraint_name), '')
           ELSE '' END
  FROM all_constraints c
  LEFT JOIN all_cons_columns cc ON cc.owner = c.owner AND cc.constraint_name = c.constraint_name AND cc.table_name = c.table_name
  WHERE c.owner IN (${owners}) AND c.constraint_type IN ('P','U','R')
  UNION ALL
  SELECT c.owner, 'CHECK_CONSTRAINTS', c.constraint_name, c.owner, c.table_name,
         'CHECK', 0, 'expression', c.search_condition_vc,
         CASE WHEN c.status = 'ENABLED' AND c.validated = 'VALIDATED' THEN 'VALID' ELSE 'INVALID' END,
         ''
  FROM all_constraints c
  WHERE c.owner IN (${owners}) AND c.constraint_type = 'C' AND c.generated = 'USER NAME'
  UNION ALL
  SELECT i.owner, 'INDEXES', i.index_name, i.table_owner, i.table_name,
         CASE WHEN i.uniqueness = 'UNIQUE' THEN 'UNIQUE' ELSE 'INDEX' END,
         0, 'unique', CASE WHEN i.uniqueness = 'UNIQUE' THEN 'true' ELSE 'false' END,
         CASE WHEN i.status = 'VALID' THEN 'VALID' ELSE 'INVALID' END, ''
  FROM all_indexes i
  WHERE i.owner IN (${owners}) AND i.generated = 'N'
    AND NOT EXISTS (
      SELECT 1 FROM all_constraints k
      WHERE k.owner = i.owner AND k.index_name = i.index_name AND k.constraint_type IN ('P','U')
    )
  UNION ALL
  SELECT i.owner, 'INDEXES', i.index_name, i.table_owner, i.table_name,
         CASE WHEN i.uniqueness = 'UNIQUE' THEN 'UNIQUE' ELSE 'INDEX' END,
         c.column_position, 'column', c.column_name,
         CASE WHEN i.status = 'VALID' THEN 'VALID' ELSE 'INVALID' END, ''
  FROM all_indexes i
  JOIN all_ind_columns c ON c.index_owner = i.owner AND c.index_name = i.index_name
  WHERE i.owner IN (${owners}) AND i.generated = 'N'
    AND NOT EXISTS (
      SELECT 1 FROM all_constraints k
      WHERE k.owner = i.owner AND k.index_name = i.index_name AND k.constraint_type IN ('P','U')
    )
  UNION ALL
  SELECT ic.owner, 'IDENTITY_COLUMNS', ic.column_name, ic.owner, ic.table_name,
         'IDENTITY', 0, '', '', 'VALID', ''
  FROM all_tab_identity_cols ic
  WHERE ic.owner IN (${owners})
  UNION ALL
  SELECT col.owner, 'DEFAULT_CONSTRAINTS', col.table_name || '_' || col.column_name || '_DEFAULT',
         col.owner, col.table_name, 'DEFAULT', col.column_id, 'column', col.column_name,
         'VALID', ''
  FROM all_tab_cols col
  WHERE col.owner IN (${owners}) AND col.default_length > 0
    AND col.hidden_column = 'NO'
    AND col.identity_column = 'NO' AND col.virtual_column = 'NO'
  UNION ALL
  SELECT e.owner, 'COMPILER_ERRORS', e.name, e.owner, e.name, e.type,
         e.sequence, 'line_position', TO_CHAR(e.line) || ':' || TO_CHAR(e.position),
         'INVALID', e.text
  FROM all_errors e
  WHERE e.owner IN (${owners}) AND e.attribute = 'ERROR'
)
SELECT 'SDCLI_INVENTORY' || CHR(9) ||
       REPLACE(REPLACE(REPLACE(schema_name, CHR(9), ' '), CHR(13), ' '), CHR(10), ' ') || CHR(9) ||
       category || CHR(9) ||
       REPLACE(REPLACE(REPLACE(object_name, CHR(9), ' '), CHR(13), ' '), CHR(10), ' ') || CHR(9) ||
       REPLACE(REPLACE(REPLACE(parent_schema, CHR(9), ' '), CHR(13), ' '), CHR(10), ' ') || CHR(9) ||
       REPLACE(REPLACE(REPLACE(parent_name, CHR(9), ' '), CHR(13), ' '), CHR(10), ' ') || CHR(9) ||
       subtype || CHR(9) || TO_CHAR(ordinal) || CHR(9) || attribute_name || CHR(9) ||
       REPLACE(REPLACE(REPLACE(attribute_value, CHR(9), ' '), CHR(13), ' '), CHR(10), ' ') || CHR(9) ||
       status || CHR(9) ||
       REPLACE(REPLACE(REPLACE(detail, CHR(9), ' '), CHR(13), ' '), CHR(10), ' ') || CHR(9) || 'oracle'
FROM inventory
ORDER BY schema_name, category, object_name, ordinal;
EXIT;
SQL
  } > "$query_file"

  if ! run_target_sql_capture "$idx" "$query_file" "$raw_file"; then
    rm -f "$query_file" "$raw_file"
    log_error "Failed to query Oracle object inventory"
    return 1
  fi
  if ! write_marked_inventory "$raw_file" "$output_file" "Oracle"; then
    rm -f "$query_file" "$raw_file"
    return 1
  fi
  rm -f "$query_file" "$raw_file"
}

collect_target_row_counts() {
  local idx="$1"
  local sqlldr_status_file="$2"
  local counts_file="$3"
  local query_file output_file
  local record_no=0 sqlldr_exit target_table control_file data_file loaded rejected discarded log_file

  query_file="$(mktemp "${TMPDIR:-/tmp}/sdcli_target_counts_XXXXXX.sql")" || return 1
  output_file="$(mktemp "${TMPDIR:-/tmp}/sdcli_target_counts_XXXXXX.out")" || {
    rm -f "$query_file"
    return 1
  }

  {
    printf '%s\n' 'WHENEVER OSERROR EXIT FAILURE;'
    printf '%s\n' 'WHENEVER SQLERROR EXIT SQL.SQLCODE;'
    printf '%s\n' 'SET HEADING OFF FEEDBACK OFF PAGESIZE 0 VERIFY OFF ECHO OFF TERMOUT ON;'
    while IFS=$'\t' read -r sqlldr_exit target_table control_file data_file loaded rejected discarded log_file; do
      [[ -n "$sqlldr_exit" ]] || continue
      record_no=$((record_no + 1))
      [[ -n "$target_table" ]] || {
        rm -f "$query_file" "$output_file"
        log_error "Cannot count target rows because SQL*Loader did not report a target table for $control_file"
        return 1
      }
      case "$target_table" in
        *$'\n'*|*';'*|*--*|*'/*'*)
          rm -f "$query_file" "$output_file"
          log_error "Unsafe target table identifier in generated control file: $target_table"
          return 1
          ;;
      esac
      printf "SELECT 'SDCLI_COUNT|%s|' || COUNT(*) FROM %s;\n" "$record_no" "$target_table"
    done < "$sqlldr_status_file"
    printf '%s\n' 'EXIT;'
  } > "$query_file"

  (( record_no > 0 )) || {
    rm -f "$query_file" "$output_file"
    log_error "No SQL*Loader status records are available for target row counts"
    return 1
  }

  if ! run_target_sql_capture "$idx" "$query_file" "$output_file"; then
    rm -f "$query_file" "$output_file"
    log_error "Failed to query final Oracle table row counts"
    return 1
  fi

  : > "$counts_file"
  sed -nE 's/^[[:space:]]*SDCLI_COUNT\|([0-9]+)\|([0-9]+)[[:space:]]*$/\1\t\2/p' "$output_file" > "$counts_file"
  if [[ "$(wc -l < "$counts_file" | tr -d '[:space:]')" != "$record_no" ]]; then
    redact_sdcli_output < "$output_file" | tee -a "$RUN_LOG_FILE" >&2
    rm -f "$query_file" "$output_file"
    log_error "Oracle target row-count query returned incomplete results"
    return 1
  fi

  rm -f "$query_file" "$output_file"
}

validate_target_objects() {
  local idx="$1"
  local output_dir="$2"
  local query_file output_file schema_dir schema_name escaped_schema owners="" schema_count=0
  local invalid_count compile_error_count

  while IFS= read -r schema_dir; do
    schema_name="$(basename "$schema_dir")"
    escaped_schema="${schema_name//\'/\'\'}"
    [[ -z "$owners" ]] || owners+=","
    owners+="UPPER('${escaped_schema}')"
    schema_count=$((schema_count + 1))
  done < <(schema_dirs "$output_dir")

  if (( schema_count == 0 )); then
    log_warn "Oracle object validation skipped because no generated schema hierarchy was found"
    return 2
  fi

  query_file="$(mktemp "${TMPDIR:-/tmp}/sdcli_object_validation_XXXXXX.sql")" || return 1
  output_file="$(mktemp "${TMPDIR:-/tmp}/sdcli_object_validation_XXXXXX.out")" || {
    rm -f "$query_file"
    return 1
  }
  {
    printf '%s\n' 'WHENEVER OSERROR EXIT FAILURE;'
    printf '%s\n' 'WHENEVER SQLERROR EXIT SQL.SQLCODE;'
    printf '%s\n' 'SET HEADING OFF FEEDBACK OFF PAGESIZE 0 VERIFY OFF ECHO OFF TERMOUT ON;'
    printf "SELECT 'SDCLI_INVALID|' || COUNT(*) FROM all_objects WHERE owner IN (%s) AND status = 'INVALID';\n" "$owners"
    printf "SELECT 'SDCLI_COMPILE_ERRORS|' || COUNT(*) FROM all_errors WHERE owner IN (%s) AND attribute = 'ERROR';\n" "$owners"
    printf '%s\n' 'EXIT;'
  } > "$query_file"

  if ! run_target_sql_capture "$idx" "$query_file" "$output_file"; then
    rm -f "$query_file" "$output_file"
    log_error "Failed to query Oracle invalid objects and compiler errors"
    return 1
  fi

  invalid_count="$(sed -nE 's/^[[:space:]]*SDCLI_INVALID\|([0-9]+)[[:space:]]*$/\1/p' "$output_file" | tail -n 1)"
  compile_error_count="$(sed -nE 's/^[[:space:]]*SDCLI_COMPILE_ERRORS\|([0-9]+)[[:space:]]*$/\1/p' "$output_file" | tail -n 1)"
  rm -f "$query_file" "$output_file"

  if [[ ! "$invalid_count" =~ ^[0-9]+$ || ! "$compile_error_count" =~ ^[0-9]+$ ]]; then
    log_error "Oracle object validation returned incomplete results"
    return 1
  fi
  if (( invalid_count > 0 || compile_error_count > 0 )); then
    log_error "Oracle object validation failed: schemas=$schema_count invalid_objects=$invalid_count compiler_errors=$compile_error_count"
    return 1
  fi

  log_info "Oracle object validation passed: schemas=$schema_count invalid_objects=0 compiler_errors=0"
}

build_reconciliation_report() {
  local bcp_status_file="$1"
  local sqlldr_status_file="$2"
  local target_counts_file="$3"
  local report_file="$4"

  local errexit_enabled=false rc
  [[ "$-" == *e* ]] && errexit_enabled=true
  set +e
  awk -F '\t' -v OFS='\t' '
    FILENAME == ARGV[1] {
      if (NF >= 2) target_count[$1]=$2
      next
    }
    FILENAME == ARGV[2] {
      if (NF < 3 || $3 == "") next
      bcp_seen[$3]++
      bcp_rc[$3]=$1
      source[$3]=$2
      exported[$3]=$4
      next
    }
    FILENAME == ARGV[3] {
      if (NF < 4 || $4 == "") next
      load_no++
      key=$4
      load_seen[key]++
      status="PASS"
      reason=""
      if (!(key in bcp_seen)) {status="FAIL"; reason="missing BCP status"}
      else if (bcp_seen[key] != 1) {status="FAIL"; reason="duplicate BCP status"}
      else if ($1 != 0) {status="FAIL"; reason="SQL*Loader exit code " $1}
      else if (bcp_rc[key] != 0) {status="FAIL"; reason="BCP exit code " bcp_rc[key]}
      else if (exported[key] !~ /^[0-9]+$/) {status="FAIL"; reason="missing exported row count"}
      else if ($5 !~ /^[0-9]+$/) {status="FAIL"; reason="missing loaded row count"}
      else if ($6 !~ /^[0-9]+$/ || $7 !~ /^[0-9]+$/) {status="FAIL"; reason="missing reject/discard count"}
      else if ($6 != 0 || $7 != 0) {status="FAIL"; reason="rejected or discarded rows"}
      else if (exported[key] != $5) {status="FAIL"; reason="exported and loaded row counts differ"}
      else if (!(load_no in target_count)) {status="FAIL"; reason="missing target row count"}
      else if ($5 != target_count[load_no]) {status="FAIL"; reason="loaded and target row counts differ"}
      if (load_seen[key] != 1) {status="FAIL"; reason="duplicate SQL*Loader status"}
      if (status == "FAIL") issues++
      print source[key], $2, key, exported[key], $5, $6, $7, target_count[load_no], status, reason
      next
    }
    END {
      for (key in bcp_seen) {
        if (!(key in load_seen)) {
          issues++
          print source[key], "", key, exported[key], "", "", "", "", "FAIL", "missing SQL*Loader status"
        }
      }
      exit(issues > 0 ? 1 : 0)
    }
  ' "$target_counts_file" "$bcp_status_file" "$sqlldr_status_file" > "$report_file.body"
  rc=$?
  $errexit_enabled && set -e
  {
    printf 'source_object\ttarget_object\tdata_file\texported_rows\tloaded_rows\trejected_rows\tdiscarded_rows\ttarget_rows\tstatus\treason\n'
    cat "$report_file.body"
  } > "$report_file"
  rm -f "$report_file.body"
  return "$rc"
}

run_data_reconciliation() {
  local idx="$1"
  local bcp_status_file="$AUTOKIT_DIR/bcp_status.tsv"
  local sqlldr_status_file="$AUTOKIT_DIR/sqlldr_status.tsv"
  local target_counts_file="$AUTOKIT_DIR/target_row_counts.tsv"
  local report_file="$AUTOKIT_DIR/reconciliation.tsv"

  [[ -s "$bcp_status_file" ]] || {
    log_error "BCP status evidence is missing or empty: $bcp_status_file"
    return 1
  }
  [[ -s "$sqlldr_status_file" ]] || {
    log_error "SQL*Loader status evidence is missing or empty: $sqlldr_status_file"
    return 1
  }

  collect_target_row_counts "$idx" "$sqlldr_status_file" "$target_counts_file" || return 1
  if ! build_reconciliation_report "$bcp_status_file" "$sqlldr_status_file" "$target_counts_file" "$report_file"; then
    log_error "Table data reconciliation failed; see $report_file"
    return 1
  fi

  log_info "Table data reconciliation passed: $report_file"
}

write_validation_checks() {
  local output_file="$1"
  local run_log_issues="$2"
  local sdcli_error_entries="$3"
  local sqlldr_log_issues="$4"
  local missing_evidence="$5"
  local reconciliation_issues="$6"
  local object_issues="$7"
  local metadata_issues="$8"
  local target_object_status="$9"
  local tmp_file

  tmp_file="$(mktemp "$(dirname "$output_file")/.validation_checks_XXXXXX")" || return 1
  {
    printf 'check\tstatus\tissues\tdetail\n'
    printf 'run_log\t%s\t%s\t%s\n' "$([[ $run_log_issues -eq 0 ]] && echo PASS || echo FAIL)" "$run_log_issues" "migration run-log diagnostics"
    printf 'sdcli_error_log\t%s\t%s\t%s\n' "$([[ $sdcli_error_entries -eq 0 ]] && echo PASS || echo FAIL)" "$sdcli_error_entries" "SDCLI ERROR/FATAL entries"
    printf 'sqlldr_logs\t%s\t%s\t%s\n' "$([[ $sqlldr_log_issues -eq 0 ]] && echo PASS || echo FAIL)" "$sqlldr_log_issues" "SQL*Loader log diagnostics"
    printf 'missing_evidence\t%s\t%s\t%s\n' "$([[ $missing_evidence -eq 0 ]] && echo PASS || echo INCOMPLETE)" "$missing_evidence" "required SQL*Loader log evidence"
    printf 'reconciliation\t%s\t%s\t%s\n' "$([[ $reconciliation_issues -eq 0 ]] && echo PASS || echo FAIL)" "$reconciliation_issues" "table data reconciliation"
    printf 'target_objects\t%s\t%s\t%s\n' "$target_object_status" "$object_issues" \
      "$([[ "$target_object_status" == INCOMPLETE ]] && echo 'not evaluated: no generated schema hierarchy' || echo 'Oracle invalid objects or compiler errors')"
    printf 'metadata_collection\t%s\t%s\t%s\n' "$([[ $metadata_issues -eq 0 ]] && echo PASS || echo INCOMPLETE)" "$metadata_issues" "source or target object inventory"
  } > "$tmp_file"
  mv "$tmp_file" "$output_file"
}

run_validation_report() {
  local output_dir="$1"
  local idx="$2"
  local migration_name report_file report_run_id rc errexit_enabled=false

  migration_name="$(migration_required_value "$idx" name)"
  report_file="$AUTOKIT_DIR/migration_report.html"
  report_run_id="${RUN_NAME#run_}"
  [[ -n "$report_run_id" ]] || report_run_id="$RUN_ID"

  # Remove artifacts created by the retired generated-DDL comparison report so
  # a rerun cannot leave false DIFFERENT/MISSING/EXTRA findings beside the new
  # direct-evidence report.
  rm -f \
    "$AUTOKIT_DIR/generated_target_inventory.tsv" \
    "$AUTOKIT_DIR/schema_mapping.tsv" \
    "$AUTOKIT_DIR/object_comparison.tsv"

  [[ "$-" == *e* ]] && errexit_enabled=true
  set +e
  python3 "$SCRIPT_DIR/lib/generate_validation_report.py" \
    --evidence-dir "$AUTOKIT_DIR" \
    --output "$report_file" \
    --migration "$migration_name" \
    --run-id "$report_run_id" \
    2>&1 | redact_sdcli_output | tee -a "$RUN_LOG_FILE"
  rc=${PIPESTATUS[0]}
  $errexit_enabled && set -e
  return "$rc"
}

run_validate() {
  local output_dir="$1"
  local idx="${2:-}"

  if $DRY_RUN; then
    log_info "[DRY-RUN] validate run log: ${RUN_LOG_FILE:-$AUTOKIT_DIR/migrate.log}"
    log_info "[DRY-RUN] validate sdcli error log: $output_dir/log/error.txt"
    log_info "[DRY-RUN] validate SQL*Loader logs: $output_dir/datamove/**/log/*.log"
    return 0
  fi

  log_info "Validating migration output"

  local run_log="${RUN_LOG_FILE:-$AUTOKIT_DIR/migrate.log}"
  local run_log_issues sdcli_error_entries sqlldr_logs_checked=0 sqlldr_log_issues=0 missing_evidence=0 reconciliation_issues=0 object_issues=0 metadata_issues=0 report_issues=0 total_issues
  local target_object_status=PASS object_validation_rc=0

  validate_run_log "$run_log" "$RUN_LOG_START_LINE"
  run_log_issues=$VALIDATION_LAST_COUNT

  validate_sdcli_error_log "$output_dir/log/error.txt"
  sdcli_error_entries=$VALIDATION_LAST_COUNT

  local logf
  while IFS= read -r logf; do
    sqlldr_logs_checked=$((sqlldr_logs_checked + 1))
    validate_sqlldr_log_file "$logf"
    sqlldr_log_issues=$((sqlldr_log_issues + VALIDATION_LAST_COUNT))
  done < <(find "$output_dir/datamove" -type f -path '*/log/*.log' 2>/dev/null | sort)

  if (( sqlldr_logs_checked == 0 )); then
    log_warn "No SQL*Loader table logs found under $output_dir/datamove"
    missing_evidence=$((missing_evidence + 1))
  elif (( sqlldr_log_issues == 0 )); then
    log_info "No SQL*Loader table log issues found"
  fi

  if [[ -n "$idx" ]]; then
    run_data_reconciliation "$idx" || reconciliation_issues=1
    if validate_target_objects "$idx" "$output_dir"; then
      :
    else
      object_validation_rc=$?
      object_issues=1
      if (( object_validation_rc == 2 )); then
        target_object_status=INCOMPLETE
      else
        target_object_status=FAIL
      fi
    fi

    local source_inventory="$AUTOKIT_DIR/source_object_inventory.tsv"
    local target_inventory="$AUTOKIT_DIR/target_object_inventory.tsv"
    # A failed rerun must not allow a previous inventory to be interpreted as
    # current evidence by the report generator.
    rm -f "$source_inventory" "$target_inventory"
    if ! collect_source_object_inventory "$idx" "$source_inventory"; then
      metadata_issues=$((metadata_issues + 1))
    fi
    if ! collect_target_object_inventory "$idx" "$output_dir" "$target_inventory"; then
      metadata_issues=$((metadata_issues + 1))
    fi
    local validation_checks="$AUTOKIT_DIR/validation_checks.tsv"
    rm -f "$validation_checks"
    if ! write_validation_checks "$validation_checks" \
      "$run_log_issues" "$sdcli_error_entries" "$sqlldr_log_issues" \
      "$missing_evidence" "$reconciliation_issues" "$object_issues" "$metadata_issues" \
      "$target_object_status"; then
      metadata_issues=$((metadata_issues + 1))
      log_error "Failed to write validation checks evidence: $validation_checks"
    fi
    if ! run_validation_report "$output_dir" "$idx"; then
      report_issues=1
    fi
    if [[ -f "$AUTOKIT_DIR/migration_report.html" ]]; then
      log_info "Migration validation report: $AUTOKIT_DIR/migration_report.html"
    else
      log_error "Migration validation report was not created: $AUTOKIT_DIR/migration_report.html"
    fi
    if [[ -f "$AUTOKIT_DIR/migration_report.txt" ]]; then
      log_info "Migration validation text report: $AUTOKIT_DIR/migration_report.txt"
    else
      log_warn "Migration validation text report was not created: $AUTOKIT_DIR/migration_report.txt"
    fi
  fi

  total_issues=$((run_log_issues + sdcli_error_entries + sqlldr_log_issues + missing_evidence + reconciliation_issues + object_issues + metadata_issues + report_issues))
  log_info "Validation summary: run_log_issues=$run_log_issues sdcli_error_entries=$sdcli_error_entries sqlldr_logs_checked=$sqlldr_logs_checked sqlldr_log_issues=$sqlldr_log_issues missing_evidence=$missing_evidence reconciliation_issues=$reconciliation_issues object_issues=$object_issues metadata_issues=$metadata_issues report_issues=$report_issues total_issues=$total_issues"
  {
    printf 'status=%s\n' "$([[ $total_issues -eq 0 ]] && echo PASS || echo FAIL)"
    printf 'run_log_issues=%s\n' "$run_log_issues"
    printf 'sdcli_error_entries=%s\n' "$sdcli_error_entries"
    printf 'sqlldr_logs_checked=%s\n' "$sqlldr_logs_checked"
    printf 'sqlldr_log_issues=%s\n' "$sqlldr_log_issues"
    printf 'missing_evidence=%s\n' "$missing_evidence"
    printf 'reconciliation_issues=%s\n' "$reconciliation_issues"
    printf 'object_issues=%s\n' "$object_issues"
    printf 'metadata_issues=%s\n' "$metadata_issues"
    printf 'report_issues=%s\n' "$report_issues"
    printf 'total_issues=%s\n' "$total_issues"
  } > "$AUTOKIT_DIR/validation_summary.txt"
  if (( total_issues > 0 )); then
    log_error "Migration validation failed with $total_issues issue(s)"
    return 1
  fi
  log_info "Migration validation passed"
  return 0
}

run_load() {
  local idx="$1"
  local output_dir="$2"

  local target_conn target_user target_password
  target_conn="$(migration_required_value "$idx" target conn)"
  target_user="$(migration_required_value "$idx" target user)"
  target_password="$(migration_secret_value "$idx" target password)"
  validate_single_line_secret "migrations[$idx].target.password" "$target_password"

  local datamove_dir="$output_dir/datamove"
  if $DRY_RUN; then
    log_info "[DRY-RUN] load script dir: $datamove_dir"
    log_info "[DRY-RUN] load script glob: $datamove_dir/**/oracle_loader.sh"
    log_info "[DRY-RUN] sqlldr wrapper: $SCRIPT_DIR/lib/sqlldr"
    return 0
  fi

  [[ -d "$datamove_dir" ]] || fail "Datamove directory not found under $output_dir"

  local loader_scripts=() found_loader_script
  while IFS= read -r found_loader_script; do
    if is_sqlldr_loader_script "$found_loader_script"; then
      loader_scripts+=("$found_loader_script")
    fi
  done < <(find "$datamove_dir" -type f -name 'oracle_loader.sh' 2>/dev/null | LC_ALL=C sort)
  [[ ${#loader_scripts[@]} -gt 0 ]] || fail "Oracle loader script with sqlldr not found under $datamove_dir"

  local direct rows bindsize readsize
  direct="$(get_bool_value SQLLDR_DIRECT "$(get_sqlldr_config_raw "$idx" direct false)")"
  rows="$(get_sqlldr_rows_default_check "$(get_sqlldr_config_raw "$idx" rows 50000)")"
  bindsize="$(get_sqlldr_buffer_size load_preferences.bindsize "$(get_sqlldr_config_raw "$idx" bindsize 16777216)")"
  readsize="$(get_sqlldr_buffer_size load_preferences.readsize "$(get_sqlldr_config_raw "$idx" readsize 16777216)")"

  log_info "Running Oracle SQL*Loader import step"
  log_info "SQL*Loader target: $target_user@$target_conn"
  log_info "SQL*Loader tuning: DIRECT=$direct ROWS=$rows BINDSIZE=$bindsize READSIZE=$readsize"
  if [[ "$direct" == "true" ]]; then
    log_info "SQL*Loader tuning: MULTITHREADING=true"
  fi

  local loader_conn="$target_conn"
  local load_tns_admin=""
  if [[ "$target_conn" == tcp://* || "$target_conn" == tcps://* ]]; then
    loader_conn="SDCLI_LOAD_${RUN_ID}"
    load_tns_admin="$(write_load_tns_alias "$target_conn" "$loader_conn")"
    log_info "SQL*Loader connect alias: $loader_conn"
    log_info "SQL*Loader TNS_ADMIN: $load_tns_admin"
  fi

  local loader_script
  for loader_script in "${loader_scripts[@]}"; do
    log_info "Executing loader script: $loader_script"
  done

  local real_sqlplus real_sqlldr load_bash_env
  real_sqlplus="$(type -P sqlplus || true)"
  real_sqlldr="$(type -P sqlldr || true)"
  [[ -n "$real_sqlplus" && -x "$real_sqlplus" ]] || fail "sqlplus command not found"
  [[ -n "$real_sqlldr" && -x "$real_sqlldr" ]] || fail "sqlldr command not found"

  load_bash_env="$SCRIPT_DIR/lib/load_wrappers.sh"

  local start_ts rc errexit_enabled=false sqlldr_status_file sqlldr_status_count=0 sqlldr_status_issues=0
  sqlldr_status_file="$AUTOKIT_DIR/sqlldr_status.tsv"
  : > "$sqlldr_status_file"
  start_ts="$(date +%s)"
  [[ "$-" == *e* ]] && errexit_enabled=true
  set +e
  (
    local loader_script script_dir script_rc
    if [[ -n "$load_tns_admin" ]]; then
      export TNS_ADMIN="$load_tns_admin"
    fi
    export SDCLI_SQLLDR_DIRECT="$direct"
    export SDCLI_SQLLDR_ROWS="$rows"
    export SDCLI_SQLLDR_BINDSIZE="$bindsize"
    export SDCLI_SQLLDR_READSIZE="$readsize"
    export ORACLE_REAL_SQLPLUS="$real_sqlplus"
    export ORACLE_REAL_SQLLDR="$real_sqlldr"
    export ORACLE_SQLLDR_STATUS_FILE="$sqlldr_status_file"
    export BASH_ENV="$load_bash_env"
    export PATH="$SCRIPT_DIR/lib:$PATH"
    case "$-" in *x*) set +x ;; esac
    exec 9< <(while :; do printf '%s\n' "$target_password"; done) || exit 1
    trap 'unset SDCLI_LOAD_PASSWORD_FD; exec 9<&-' EXIT
    export SDCLI_LOAD_PASSWORD_FD=9

    for loader_script in "${loader_scripts[@]}"; do
      script_dir="$(dirname "$loader_script")"
      cd "$script_dir" || exit 1
      bash +x -e "$(basename "$loader_script")" "$loader_conn" "$target_user" "__SDCLI_LOAD_PASSWORD__"
      script_rc=$?
      if [[ $script_rc -ne 0 ]]; then
        exit "$script_rc"
      fi
    done
  ) 2>&1 | redact_sdcli_output | tee -a "$RUN_LOG_FILE" | summarize_sqlldr_output
  rc=${PIPESTATUS[0]}
  $errexit_enabled && set -e

  local sqlldr_exit_code target_table control_file data_file loaded_rows rejected_rows discarded_rows sqlldr_log_file
  while IFS=$'\t' read -r sqlldr_exit_code target_table control_file data_file loaded_rows rejected_rows discarded_rows sqlldr_log_file; do
    [[ -n "$sqlldr_exit_code" ]] || continue
    sqlldr_status_count=$((sqlldr_status_count + 1))
    if [[ "$sqlldr_exit_code" != "0" || -z "$target_table" || -z "$data_file" \
        || ! "$loaded_rows" =~ ^[0-9]+$ || ! "$rejected_rows" =~ ^[0-9]+$ \
        || ! "$discarded_rows" =~ ^[0-9]+$ ]]; then
      sqlldr_status_issues=$((sqlldr_status_issues + 1))
      log_error "SQL*Loader status is incomplete or failed: target=${target_table:-unknown} control=${control_file:-unknown} exit_code=${sqlldr_exit_code:-unknown}"
    fi
  done < "$sqlldr_status_file"

  if (( sqlldr_status_count == 0 || sqlldr_status_issues > 0 )); then
    log_error "SQL*Loader status verification failed: records=$sqlldr_status_count issues=$sqlldr_status_issues"
    rc=1
  else
    log_info "SQL*Loader status records: $sqlldr_status_count file=$sqlldr_status_file"
  fi

  log_timed_result "SQL*Loader load" "$rc" "$start_ts"
  return "$rc"
}

run_offload() {
  local idx="$1"
  local output_dir="$2"

  local source_conn source_user source_password
  source_conn="$(migration_required_value "$idx" source conn)"
  source_user="$(migration_required_value "$idx" source user)"
  source_password="$(migration_secret_value "$idx" source password)"
  validate_single_line_secret "migrations[$idx].source.password" "$source_password"

  local parsed source_host source_port source_db
  parsed="$(parse_source_conn "$source_conn")"
  IFS='|' read -r source_host source_port source_db <<< "$parsed"

  local bcp_tls_mode bcp_packet_size
  bcp_tls_mode="$(normalize_bcp_tls_mode "$(get_required_value '.defaults.source.bcp_tls_mode' 'defaults.source.bcp_tls_mode')")"
  bcp_packet_size="$(get_bcp_packet_size)"

  local datamove_dir="$output_dir/datamove"
  if $DRY_RUN; then
    log_info "[DRY-RUN] offload script dir: $datamove_dir"
    log_info "[DRY-RUN] offload script glob: $datamove_dir/**/MicrosoftSQLServer_data.sh"
    log_info "[DRY-RUN] offload bcp packet size: $bcp_packet_size"
    log_info "[DRY-RUN] offload console filter: bcp row progress"
    return 0
  fi

  local bcp_scripts=() bcp_script
  while IFS= read -r bcp_script; do
    if [[ -n "$(extract_bcp_table_names "$bcp_script" | head -n 1)" ]]; then
      bcp_scripts+=("$bcp_script")
    fi
  done < <(find "$datamove_dir" -type f -name 'MicrosoftSQLServer_data.sh' 2>/dev/null | sort)
  [[ ${#bcp_scripts[@]} -gt 0 ]] || fail "Generated BCP command script not found under $datamove_dir"

  log_info "Running BCP offload script"
  log_info "BCP TLS mode: $bcp_tls_mode"
  log_info "BCP packet size requested: $bcp_packet_size"
  log_info "BCP command scripts: ${#bcp_scripts[@]}"
  for bcp_script in "${bcp_scripts[@]}"; do
    log_info "BCP command script: $bcp_script"
  done
  log_info "Source host: $source_host"
  log_info "Source port: $source_port"
  log_info "Source database: $source_db"

  local bcp_tables=() bcp_table
  while IFS= read -r bcp_table; do
    bcp_tables+=("$bcp_table")
  done < <(extract_bcp_table_names_from_dir "$datamove_dir")
  log_info "BCP tables discovered: ${#bcp_tables[@]}"

  local start_ts bcp_status_file bcp_command_count bcp_failed_count bcp_missing_file_count errexit_enabled=false
  start_ts="$(date +%s)"
  bcp_status_file="$AUTOKIT_DIR/bcp_status.tsv"
  : > "$bcp_status_file"

  local rc=0
  [[ "$-" == *e* ]] && errexit_enabled=true
  set +e
  (
    export SQLSERVER_BCP_TLS_MODE_EFFECTIVE="$bcp_tls_mode"
    export SQLSERVER_BCP_PACKET_SIZE="$bcp_packet_size"
    export SQLSERVER_BCP_PASSWORD="${source_password}"
    export SQLSERVER_BCP_STATUS_FILE="$bcp_status_file"
    export PATH="$SCRIPT_DIR/lib:$PATH"
    local script_dir script_name script_rc
    for bcp_script in "${bcp_scripts[@]}"; do
      script_dir="$(dirname "$bcp_script")"
      script_name="$(basename "$bcp_script")"
      cd "$script_dir" || exit 1
      bash +x -e "$script_name" "${source_host},${source_port}" "$source_user" "__SDCLI_BCP_PASSWORD__"
      script_rc=$?
      [[ $script_rc -eq 0 ]] || exit "$script_rc"
    done
  ) 2>&1 | redact_sdcli_output | tee -a "$RUN_LOG_FILE" | summarize_bcp_output "${bcp_tables[@]}"
  rc=${PIPESTATUS[0]}
  $errexit_enabled && set -e

  bcp_command_count="$(wc -l < "$bcp_status_file" | tr -d '[:space:]')"
  bcp_failed_count=0
  bcp_missing_file_count=0
  local bcp_exit_code bcp_object bcp_data_file bcp_rows
  while IFS=$'\t' read -r bcp_exit_code bcp_object bcp_data_file bcp_rows; do
    [[ -n "$bcp_exit_code" ]] || continue
    if [[ "$bcp_exit_code" != "0" ]]; then
      bcp_failed_count=$((bcp_failed_count + 1))
      log_error "BCP command failed: object=${bcp_object:-unknown} exit_code=$bcp_exit_code"
    elif [[ -n "$bcp_data_file" && "$bcp_data_file" != "-" && ! -f "$bcp_data_file" ]]; then
      bcp_missing_file_count=$((bcp_missing_file_count + 1))
      log_error "BCP command produced no data file: object=${bcp_object:-unknown} path=$bcp_data_file"
    elif [[ ! "$bcp_rows" =~ ^[0-9]+$ ]]; then
      bcp_failed_count=$((bcp_failed_count + 1))
      log_error "BCP command did not report an exported row count: object=${bcp_object:-unknown}"
    fi
  done < "$bcp_status_file"
  log_info "BCP command summary: invoked=$bcp_command_count expected=${#bcp_tables[@]} failed=$bcp_failed_count missing_files=$bcp_missing_file_count status_file=$bcp_status_file"
  if (( bcp_command_count != ${#bcp_tables[@]} || bcp_failed_count > 0 || bcp_missing_file_count > 0 )); then
    log_error "BCP offload verification failed"
    rc=1
  fi

  log_timed_result "BCP offload" "$rc" "$start_ts"
  return "$rc"
}

# --- Phase postconditions ---------------------------------------------------
expected_run_model_name() {
  local project_name="$1"
  local run_id="${RUN_NAME#run_}"
  [[ -n "$project_name" && -n "$run_id" ]] || return 1
  printf '%s_%s\n' "$project_name" "$run_id"
}

lookup_sdcli_model_index() {
  local phase="$1"
  local expected_model="$2"
  local list_action output_file model_index="" rc=0 saved_action saved_marker

  SDCLI_VERIFIED_MODEL_INDEX=""

  case "$phase" in
    capture) list_action="lscaptured" ;;
    convert) list_action="lsconverted" ;;
    *)
      log_error "No SQL Developer model lookup is defined for phase '$phase'"
      return 1
      ;;
  esac

  output_file="$(mktemp "${TMPDIR:-/tmp}/sdcli_model_lookup_XXXXXX")" || return 1
  require_active_repository_identity
  saved_action="$SDCLI_LAST_ACTION"
  saved_marker="$SDCLI_LAST_SUCCESS_MARKER"
  SDCLI_CAPTURE_OUTPUT_FILE="$output_file"
  if ! LC_ALL=C run_sdcli sdcli migration "-actions=$list_action"; then
    rc=1
  elif ! model_index="$(LC_ALL=C awk -v expected="$expected_model" '
    {
      line=$0
      gsub(/\r/, "", line)
      marker=") --> Model Name : "
      marker_pos=index(line, marker)
      if (marker_pos > 1) {
        model_index=substr(line, 1, marker_pos - 1)
        model_name=substr(line, marker_pos + length(marker))
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", model_index)
        # The marker includes the closing ")". SQL Developer 26.2 therefore
        # leaves "(1" in model_index, while older output leaves "1". Remove
        # only the leading display parenthesis; the exact marker and numeric
        # check still reject malformed rows.
        if (model_index ~ /^\([0-9]+$/) {
          sub(/^\(/, "", model_index)
        }
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", model_name)
        if (model_index ~ /^[0-9]+$/ && model_name == expected) {
          matches++
          matched_index=model_index
        }
      }
    }
    END {
      if (matches != 1) exit 1
      print matched_index
    }
  ' "$output_file")"; then
    log_error "SQL Developer $phase model lookup did not return exactly one model named '$expected_model'"
    rc=1
  else
    SDCLI_VERIFIED_MODEL_INDEX="$model_index"
  fi
  SDCLI_CAPTURE_OUTPUT_FILE=""
  SDCLI_LAST_ACTION="$saved_action"
  SDCLI_LAST_SUCCESS_MARKER="$saved_marker"
  rm -f "$output_file"
  return "$rc"
}

verify_datamove_artifacts() {
  local output_dir="$1"
  local datamove_dir="$output_dir/datamove"
  local bcp_script control_file bcp_script_count=0 control_file_count=0

  [[ -d "$datamove_dir" ]] || {
    log_error "Datamove postcondition failed: directory not found: $datamove_dir"
    return 1
  }
  while IFS= read -r bcp_script; do
    [[ -n "$bcp_script" ]] || continue
    if [[ -z "$(extract_bcp_table_names "$bcp_script" | head -n 1)" ]]; then
      log_error "Datamove postcondition failed: generated BCP script has no supported export command: $bcp_script"
      return 1
    fi
    bcp_script_count=$((bcp_script_count + 1))
  done < <(find "$datamove_dir" -type f -name 'MicrosoftSQLServer_data.sh' 2>/dev/null | LC_ALL=C sort)

  while IFS= read -r control_file; do
    [[ -n "$control_file" ]] || continue
    control_file_count=$((control_file_count + 1))
  done < <(find "$datamove_dir" -type f -name '*.ctl' 2>/dev/null | LC_ALL=C sort)

  (( bcp_script_count > 0 )) || {
    log_error "Datamove postcondition failed: no generated BCP command script was found under $datamove_dir"
    return 1
  }
  (( control_file_count > 0 )) || {
    log_error "Datamove postcondition failed: no SQL*Loader control file was found under $datamove_dir"
    return 1
  }
}

verify_offload_evidence() {
  local output_dir="$1"
  local datamove_dir="$output_dir/datamove"
  local status_file="$AUTOKIT_DIR/bcp_status.tsv"
  local expected_file actual_file path rc=0

  [[ -s "$status_file" ]] || {
    log_error "Offload postcondition failed: BCP status evidence is missing or empty: $status_file"
    return 1
  }
  expected_file="$(mktemp "${TMPDIR:-/tmp}/sdcli_bcp_expected_XXXXXX")" || return 1
  actual_file="$(mktemp "${TMPDIR:-/tmp}/sdcli_bcp_actual_XXXXXX")" || {
    rm -f "$expected_file"
    return 1
  }
  extract_bcp_table_names_from_dir "$datamove_dir" | LC_ALL=C sort > "$expected_file"
  if [[ ! -s "$expected_file" ]]; then
    log_error "Offload postcondition failed: no expected BCP invocation could be derived from $datamove_dir"
    rc=1
  elif ! LC_ALL=C awk -F '\t' '
    NF != 4 || $1 != "0" || $2 == "" || $3 == "" || $3 == "-" || $4 !~ /^[0-9]+$/ { invalid=1; next }
    { print $2 }
    END { if (invalid) exit 1 }
  ' "$status_file" | LC_ALL=C sort > "$actual_file"; then
    log_error "Offload postcondition failed: BCP status evidence is malformed or contains a failed invocation"
    rc=1
  elif ! cmp -s "$expected_file" "$actual_file"; then
    log_error "Offload postcondition failed: BCP status records do not match the expected invocations"
    rc=1
  fi

  if (( rc == 0 )); then
    while IFS=$'\t' read -r _ _ path _; do
      [[ -f "$path" ]] || {
        log_error "Offload postcondition failed: exported data file is missing: $path"
        rc=1
      }
    done < "$status_file"
  fi
  rm -f "$expected_file" "$actual_file"
  return "$rc"
}

verify_load_evidence() {
  local output_dir="$1"
  local datamove_dir="$output_dir/datamove"
  local status_file="$AUTOKIT_DIR/sqlldr_status.tsv"
  local expected_file actual_file control_file data_file rc=0

  [[ -s "$status_file" ]] || {
    log_error "Load postcondition failed: SQL*Loader status evidence is missing or empty: $status_file"
    return 1
  }
  expected_file="$(mktemp "${TMPDIR:-/tmp}/sdcli_sqlldr_expected_XXXXXX")" || return 1
  actual_file="$(mktemp "${TMPDIR:-/tmp}/sdcli_sqlldr_actual_XXXXXX")" || {
    rm -f "$expected_file"
    return 1
  }
  find "$datamove_dir" -type f -name '*.ctl' 2>/dev/null | LC_ALL=C sort > "$expected_file"
  if [[ ! -s "$expected_file" ]]; then
    log_error "Load postcondition failed: no expected SQL*Loader control file was found under $datamove_dir"
    rc=1
  elif ! LC_ALL=C awk -F '\t' '
    NF != 8 || $1 != "0" || $2 == "" || $3 == "" || $4 == "" ||
      $5 !~ /^[0-9]+$/ || $6 !~ /^[0-9]+$/ || $7 !~ /^[0-9]+$/ || $8 == "" { invalid=1; next }
    { print $3 }
    END { if (invalid) exit 1 }
  ' "$status_file" | LC_ALL=C sort > "$actual_file"; then
    log_error "Load postcondition failed: SQL*Loader status evidence is malformed or contains a failed invocation"
    rc=1
  elif ! cmp -s "$expected_file" "$actual_file"; then
    log_error "Load postcondition failed: SQL*Loader status records do not match the expected control files"
    rc=1
  fi

  if (( rc == 0 )); then
    while IFS=$'\t' read -r _ _ control_file data_file _; do
      [[ -f "$control_file" ]] || {
        log_error "Load postcondition failed: control file is missing: $control_file"
        rc=1
      }
      [[ -f "$data_file" ]] || {
        log_error "Load postcondition failed: input data file is missing: $data_file"
        rc=1
      }
    done < "$status_file"
  fi
  rm -f "$expected_file" "$actual_file"
  return "$rc"
}

manifest_relative_path() {
  local path="$1"
  [[ -z "${RUN_DIR:-}" || "$path" != "$RUN_DIR/"* ]] || path="${path#$RUN_DIR/}"
  printf '%s\n' "$path"
}

expected_manifest_paths() {
  local phase="$1"
  local output_dir="$2"
  local schema_dir include_path generated_sql cleanup_file

  case "$phase" in
    deploy)
      if [[ -f "$output_dir/role.sql" && -f "$(role_setup_dir)/role_setup.sql" ]]; then
        manifest_relative_path "$(role_setup_dir)/role_setup.sql"
      fi
      while IFS= read -r schema_dir; do
        manifest_relative_path "$schema_dir/user.sql"
        while IFS= read -r include_path; do
          is_predata_sql "$include_path" || continue
          manifest_relative_path "$output_dir/$include_path"
        done < <(schema_master_includes "$output_dir" "$schema_dir")
      done < <(schema_dirs "$output_dir")
      if [[ -z "$(schema_dirs "$output_dir")" ]]; then
        generated_sql="$(generated_sql_files "$output_dir")"
        [[ -n "$generated_sql" ]] && manifest_relative_path "$generated_sql"
      fi
      ;;
    postdeploy)
      while IFS= read -r schema_dir; do
        while IFS= read -r include_path; do
          manifest_relative_path "$output_dir/$include_path"
        done < <(schema_post_files "$output_dir" "$schema_dir")
        [[ ! -f "$schema_dir/post.sql" ]] || manifest_relative_path "$schema_dir/post.sql"
      done < <(schema_dirs "$output_dir")
      ;;
    cleanup)
      cleanup_file="$(role_cleanup_dir)/role_cleanup.sql"
      [[ ! -f "$cleanup_file" ]] || manifest_relative_path "$cleanup_file"
      ;;
  esac
}

verify_deploy_manifest_phase() {
  local phase="$1"
  local output_dir="$2"
  local manifest expected_file path status
  manifest="$(deploy_manifest_file)"
  expected_file="$(mktemp "${TMPDIR:-/tmp}/sdcli_manifest_expected_XXXXXX")" || return 1
  if ! expected_manifest_paths "$phase" "$output_dir" > "$expected_file"; then
    rm -f "$expected_file"
    return 1
  fi
  [[ -f "$manifest" ]] || {
    if [[ ! -s "$expected_file" ]]; then
      rm -f "$expected_file"
      return 0
    fi
    log_error "${phase^} postcondition failed: deploy manifest is missing: $manifest"
    rm -f "$expected_file"
    return 1
  }
  if ! LC_ALL=C awk -F '\t' '
    NR == 1 { if ($0 != "phase\tpath\tstatus\tnote") invalid=1; next }
    NF != 4 || $1 == "" || $2 == "" { invalid=1; next }
    $3 != "executed" && $3 != "failed" && $3 != "control" &&
      $3 != "excluded" && $3 != "covered" && $3 != "not_run" &&
      $3 != "pending" && $3 != "planned" { invalid=1 }
    END { if (invalid) exit 1 }
  ' "$manifest"; then
    log_error "${phase^} postcondition failed: deploy manifest is malformed: $manifest"
    rm -f "$expected_file"
    return 1
  fi

  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    status="$(awk -F '\t' -v phase="$phase" -v path="$path" '$1 == phase && $2 == path { status=$3 } END { print status }' "$manifest")"
    if [[ "$status" != "executed" ]]; then
      log_error "${phase^} postcondition failed: manifest has no successful result for $path"
      rm -f "$expected_file"
      return 1
    fi
  done < "$expected_file"
  rm -f "$expected_file"
}

verify_validation_evidence() {
  local checks_file="$AUTOKIT_DIR/validation_checks.tsv"
  local summary_file="$AUTOKIT_DIR/validation_summary.txt"
  local required_check

  [[ -f "$checks_file" ]] || {
    log_error "Validate postcondition failed: validation checks are missing: $checks_file"
    return 1
  }
  if ! LC_ALL=C awk -F '\t' '
    NR == 1 { if ($0 != "check\tstatus\tissues\tdetail") invalid=1; next }
    NF != 4 || $1 == "" || $3 !~ /^[0-9]+$/ || $4 == "" { invalid=1; next }
    $2 != "PASS" && $2 != "FAIL" && $2 != "INCOMPLETE" && $2 != "NOT_EVALUATED" { invalid=1 }
    seen[$1]++
    END {
      required[1]="run_log"; required[2]="sdcli_error_log"; required[3]="sqlldr_logs"
      required[4]="missing_evidence"; required[5]="reconciliation"; required[6]="target_objects"
      required[7]="metadata_collection"
      for (i=1; i<=7; i++) if (seen[required[i]] != 1) invalid=1
      if (invalid) exit 1
    }
  ' "$checks_file"; then
    log_error "Validate postcondition failed: validation checks are incomplete or malformed: $checks_file"
    return 1
  fi
  [[ -f "$summary_file" ]] && grep -Fx 'status=PASS' "$summary_file" >/dev/null 2>&1 || {
    log_error "Validate postcondition failed: validation summary does not report PASS: $summary_file"
    return 1
  }
  for required_check in migration_report.html migration_report.txt; do
    [[ -f "$AUTOKIT_DIR/$required_check" ]] || {
      log_error "Validate postcondition failed: report is missing: $AUTOKIT_DIR/$required_check"
      return 1
    }
  done
}

verify_phase_postcondition() {
  local phase="$1"
  local model_name="$2"
  local project_name="$3"
  local output_dir="$4"
  local expected_model

  $DRY_RUN && return 0
  case "$phase" in
    capture|convert)
      if [[ "$SDCLI_LAST_ACTION" != "$phase" || "$SDCLI_LAST_SUCCESS_MARKER" != "true" ]]; then
        log_error "${phase^} postcondition failed: exact '$phase completed successfully' marker was not observed"
        return 1
      fi
      if [[ "$phase" == "capture" ]]; then
        expected_model="$model_name"
      else
        expected_model="$(expected_run_model_name "$project_name")" || return 1
      fi
      lookup_sdcli_model_index "$phase" "$expected_model"
      ;;
    generate)
      ( validate_generated_sql_inventory "$output_dir" ) || {
        log_error "Generate postcondition failed: generated execution-plan inventory is missing or unsupported"
        return 1
      }
      ;;
    datamove) verify_datamove_artifacts "$output_dir" ;;
    offload) verify_offload_evidence "$output_dir" ;;
    deploy|postdeploy)
      ( validate_generated_sql_inventory "$output_dir" ) || {
        log_error "${phase^} postcondition failed: generated execution-plan inventory is missing or unsupported"
        return 1
      }
      verify_deploy_manifest_phase "$phase" "$output_dir"
      ;;
    cleanup) verify_deploy_manifest_phase "$phase" "$output_dir" ;;
    load) verify_load_evidence "$output_dir" ;;
    validate) verify_validation_evidence ;;
    *)
      log_error "No postcondition is defined for phase '$phase'"
      return 1
      ;;
  esac
}

# --- Phase orchestration -----------------------------------------------------
run_phase() {
  local phase_name="$1"
  local repo_name="$2"
  local src_conn_name="$3"
  local target_name="$4"
  local model_name="$5"
  local project_name="$6"
  local output_dir="$7"
  local idx="$8"

  begin_phase_status "$phase_name"

  case "$phase_name" in
    capture)
      local source_conn parsed_source source_host source_port source_database
      source_conn="$(migration_required_value "$idx" source conn)"
      parsed_source="$(parse_source_conn "$source_conn")"
      IFS='|' read -r source_host source_port source_database <<< "$parsed_source"
      check_source_tcp_connectivity "$source_host" "$source_port"
      run_sdcli sdcli migration -actions=capture -conn="$src_conn_name" -dblist="$source_database" -model="$model_name" -project="$project_name" -append -output="$output_dir" \
        || fail "Capture failed for migration '$project_name'"
      ;;
    convert)
      run_sdcli sdcli migration -actions=convert -model="$model_name" -output="$output_dir" \
        || fail "Convert failed for migration '$project_name'"
      ;;
    generate)
      run_sdcli sdcli migration -actions=generate -model="$model_name" -dest="$target_name" -output="$output_dir" \
        || fail "Generate failed for migration '$project_name'"
      ;;
    deploy)
      run_deploy "$idx" "$output_dir" || fail "Deploy failed for migration '$project_name'"
      ;;
    cleanup)
      run_cleanup "$idx" "$output_dir" || fail "Cleanup failed for migration '$project_name'"
      ;;
    datamove)
      run_sdcli sdcli migration -actions=datamove -model="$model_name" -output="$output_dir" \
        || fail "Datamove failed for migration '$project_name'"
      ;;
    offload)
      run_offload "$idx" "$output_dir" || fail "Offload failed for migration '$project_name'"
      ;;
    load)
      run_load "$idx" "$output_dir" || fail "Load failed for migration '$project_name'"
      ;;
    postdeploy)
      run_postdeploy "$idx" "$output_dir" || fail "Postdeploy failed for migration '$project_name'"
      ;;
    validate)
      run_validate "$output_dir" "$idx" || fail "Validate failed for migration '$project_name'"
      ;;
    *)
      fail "Unsupported phase: $phase_name"
      ;;
  esac

  verify_phase_postcondition "$phase_name" "$model_name" "$project_name" "$output_dir" \
    || fail "Postcondition failed for migration '$project_name' phase '$phase_name'"

  complete_phase_status "$phase_name"
}

run_all_phases() {
  local repo_name="$1"
  local src_conn_name="$2"
  local target_name="$3"
  local model_name="$4"
  local project_name="$5"
  local output_dir="$6"
  local idx="$7"

  local phase captured_model_index converted_model_index

  SDCLI_VERIFIED_MODEL_INDEX=""
  run_phase capture "$repo_name" "$src_conn_name" "$target_name" "$model_name" "$project_name" "$output_dir" "$idx"
  if $DRY_RUN; then
    captured_model_index="<captured-model-index>"
  else
    captured_model_index="$SDCLI_VERIFIED_MODEL_INDEX"
    [[ "$captured_model_index" =~ ^[0-9]+$ ]] \
      || fail "Capture did not resolve a unique numeric SQL Developer model index"
  fi

  SDCLI_VERIFIED_MODEL_INDEX=""
  run_phase convert "$repo_name" "$src_conn_name" "$target_name" "$captured_model_index" "$project_name" "$output_dir" "$idx"
  if $DRY_RUN; then
    converted_model_index="<converted-model-index>"
  else
    converted_model_index="$SDCLI_VERIFIED_MODEL_INDEX"
    [[ "$converted_model_index" =~ ^[0-9]+$ ]] \
      || fail "Convert did not resolve a unique numeric SQL Developer model index"
  fi

  for phase in generate datamove offload deploy load postdeploy validate; do
    run_phase "$phase" "$repo_name" "$src_conn_name" "$target_name" "$converted_model_index" "$project_name" "$output_dir" "$idx"
  done
}

record_migration_completion() {
  local migration_name="$1"
  local status="$2"
  local model_name="$3"
  local output_dir="$4"
  local start_ts="$5"
  local message="$6"

  append_migration_summary "$migration_name" "$status" "$model_name" "$output_dir" "$(( $(date +%s) - start_ts ))" ""
  log_info "$message"
}

run_connection_setup() {
  local idx="$1"
  local source_conn_name="$2"
  local source_conn="$3"
  local target_name="$4"

  local source_user source_password src_conn_details source_host source_port source_database parsed_source
  source_user="$(migration_required_value "$idx" source user)"
  source_password="$(migration_secret_value "$idx" source password)"
  validate_sdcli_conn_details_password "migrations[$idx].source.password" "$source_password"
  parsed_source="$(parse_source_conn "$source_conn")"
  IFS='|' read -r source_host source_port source_database <<< "$parsed_source"
  check_source_tcp_connectivity "$source_host" "$source_port"
  src_conn_details="${source_conn_name}:sqlserver:${source_user}/${source_password}@${source_conn}"
  ensure_connection "$source_conn_name" "$src_conn_details"

  local target_conn target_user target_password tgt_conn_details
  target_conn="$(migration_required_value "$idx" target conn)"
  target_user="$(migration_required_value "$idx" target user)"
  target_password="$(migration_secret_value "$idx" target password)"
  validate_sdcli_conn_details_password "migrations[$idx].target.password" "$target_password"
  tgt_conn_details="${target_name}:oracle:${target_user}/${target_password}@${target_conn}"
  ensure_connection "$target_name" "$tgt_conn_details"
}

run_single_migration() {
  local idx="$1"
  local migration_name
  migration_name="$(migration_required_value "$idx" name)"

  local source_conn_name source_conn
  source_conn_name="src_${migration_name}"
  source_conn="$(migration_required_value "$idx" source conn)"

  local target_name
  target_name="tgt_${migration_name}"

  require_active_repository_identity
  local repo_name="$ACTIVE_REPOSITORY_NAME"

  local output_dir="$SDCLI_OUTPUT_DIR"
  mkdir -p "$output_dir"

  local run_model="${migration_name}_${RUN_ID}"
  local project_name="$migration_name"
  local start_ts
  start_ts="$(date +%s)"

  log_info "--------------------------------------------------"
  log_info "Migration: $migration_name"
  log_info "Source connection name: ${source_conn_name}"
  log_info "Source connection: ${source_conn}"
  log_info "Target connection: $target_name"
  log_info "Output directory: $output_dir"
  log_info "Mode: $MODE"

  case "$MODE" in
    conn-setup)
      run_connection_setup "$idx" "$source_conn_name" "$source_conn" "$target_name"
      log_info "SDCLI connections saved in the project profile; Oracle connection creation also tests its login."
      record_migration_completion "$migration_name" "connection_setup_completed" "" "$output_dir" "$start_ts" "Connection definitions saved: $migration_name"
      ;;
    phase)
      local phase_model
      phase_model="${MODEL_NAME_INPUT:-latest}"
      [[ "$PHASE_NAME" == "capture" ]] && phase_model="$run_model"
      run_phase "$PHASE_NAME" "$repo_name" "$source_conn_name" "$target_name" "$phase_model" "$project_name" "$output_dir" "$idx"
      record_migration_completion "$migration_name" "phase_${PHASE_NAME}_completed" "$phase_model" "$output_dir" "$start_ts" "Single phase completed: $PHASE_NAME"
      ;;
    migrate|full)
      local summary_status="completed" done_message="Full migration completed: $migration_name"
      if [[ "$MODE" == "migrate" ]]; then
        summary_status="all_phases_completed"
        done_message="All phases completed: $migration_name"
      fi
      # Capture references named SQL Developer connections. Create or refresh
      # them as part of every full workflow so a single migrate invocation does
      # not depend on a separate, manually run --conn-setup command.
      run_connection_setup "$idx" "$source_conn_name" "$source_conn" "$target_name"
      run_all_phases "$repo_name" "$source_conn_name" "$target_name" "$run_model" "$project_name" "$output_dir" "$idx"
      record_migration_completion "$migration_name" "$summary_status" "$run_model" "$output_dir" "$start_ts" "$done_message"
      ;;
    *)
      fail "Unsupported mode: $MODE"
      ;;
  esac
}

# --- CLI parsing and bootstrap ----------------------------------------------
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --init)
        set_mode "init"
        shift
        ;;
      --conn-setup)
        set_mode "conn-setup"
        shift
        ;;
      --phase)
        set_mode "phase"
        shift
        [[ $# -gt 0 ]] || fail "--phase requires a value"
        PHASE_NAME="$(to_lower "$1")"
        shift
        ;;
      --deploy)
        set_mode "phase"
        PHASE_NAME="deploy"
        shift
        ;;
      --cleanup)
        set_mode "phase"
        PHASE_NAME="cleanup"
        shift
        ;;
      --migrate)
        set_mode "migrate"
        shift
        ;;
      --show-datatype-mapping)
        set_mode "show-datatype-mapping"
        shift
        ;;
      --model)
        shift
        [[ $# -gt 0 ]] || fail "--model requires a value"
        MODEL_NAME_INPUT="$1"
        shift
        ;;
      --run)
        shift
        [[ $# -gt 0 ]] || fail "--run requires a value"
        RUN_NAME_INPUT="$1"
        shift
        ;;
      --rerun-completed)
        RERUN_COMPLETED=true
        shift
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      --)
        shift
        break
        ;;
      -*)
        fail "Unknown argument: $1"
        ;;
      *)
        if [[ -z "$MIGRATION_NAME" ]]; then
          MIGRATION_NAME="$1"
          shift
        else
          fail "Unexpected extra argument: $1"
        fi
        ;;
    esac
  done

  if [[ "$MODE" == "init" || "$MODE" == "show-datatype-mapping" ]]; then
    : # Migration project name is an optional repository filter.
  else
    [[ -n "$MIGRATION_NAME" ]] || fail "Migration name is required (example: ./migrate.sh tpcc)"
  fi

  if [[ "$MODE" == "phase" ]]; then
    case "$PHASE_NAME" in
      capture|convert|generate|deploy|datamove|offload|load|postdeploy|validate|cleanup) ;;
      *) fail "Invalid --phase '$PHASE_NAME'. Use: capture|convert|generate|deploy|datamove|offload|load|postdeploy|validate|cleanup" ;;
    esac
  fi

  if [[ "$MODE" == "phase" && "$PHASE_NAME" == "capture" && -n "$MODEL_NAME_INPUT" ]]; then
    fail "--model is not supported with --phase capture; capture always uses <migration_name>_<run_id>"
  fi

  if [[ -n "$RUN_NAME_INPUT" && ! ( "$MODE" == "phase" && "$PHASE_NAME" != "capture" ) ]]; then
    fail "--run can only be used with non-capture --phase"
  fi

  if [[ "$MODE" == "phase" && "$PHASE_NAME" == "cleanup" && -z "$RUN_NAME_INPUT" ]]; then
    fail "--cleanup requires --run so it can use the generated files from the intended migration run"
  fi

  if [[ -n "$MODEL_NAME_INPUT" && "$MODE" != "phase" ]]; then
    fail "--model can only be used with --phase"
  fi

  if $RERUN_COMPLETED && [[ ! ( "$MODE" == "phase" && -n "$RUN_NAME_INPUT" ) ]]; then
    fail "--rerun-completed requires --phase and --run"
  fi

  if [[ "$MODE" == "show-datatype-mapping" && "$DRY_RUN" == "true" ]]; then
    fail "--dry-run is not supported with --show-datatype-mapping"
  fi
}

bootstrap_logging() {
  PROJECT_ROOT="$(get_required_value '.defaults.paths.project_root' 'defaults.paths.project_root')"

  mkdir -p "$PROJECT_ROOT"

  if [[ "$MODE" == "init" ]]; then
    PROJECT_DIR="$PROJECT_ROOT/_init/$MIGRATION_NAME"
    RUN_NAME="run_$RUN_ID"
  else
    PROJECT_DIR="$PROJECT_ROOT/$MIGRATION_NAME"
    if [[ -n "$RUN_NAME_INPUT" ]]; then
      RUN_NAME="$RUN_NAME_INPUT"
      [[ "$RUN_NAME" == run_* ]] || RUN_NAME="run_$RUN_NAME"
    else
      RUN_NAME="run_$RUN_ID"
    fi
  fi

  RUN_DIR="$PROJECT_DIR/$RUN_NAME"
  AUTOKIT_DIR="$RUN_DIR/autokit"
  SDCLI_OUTPUT_DIR="$RUN_DIR/sdcli"

  if [[ -n "$RUN_NAME_INPUT" && ! -d "$SDCLI_OUTPUT_DIR" ]]; then
    fail "Run SDCLI output directory not found: $SDCLI_OUTPUT_DIR"
  fi

  mkdir -p "$AUTOKIT_DIR" "$SDCLI_OUTPUT_DIR"

  RUN_LOG_FILE="$AUTOKIT_DIR/migrate.log"
  touch "$RUN_LOG_FILE"
  RUN_LOG_START_LINE="$(wc -l < "$RUN_LOG_FILE" | tr -d '[:space:]')"

  SDCLI_COMMAND_LOG="$AUTOKIT_DIR/sdcli_commands.log"
  SDCLI_SUMMARY_FILE="$AUTOKIT_DIR/sdcli_commands_summary.txt"
  MIGRATION_SUMMARY_FILE="$AUTOKIT_DIR/migration_summary.csv"
  PHASE_STATUS_FILE="$AUTOKIT_DIR/phase_status.tsv"

  if [[ ! -s "$MIGRATION_SUMMARY_FILE" ]]; then
    echo "timestamp,migration,status,model_name,output_dir,duration_sec,note" > "$MIGRATION_SUMMARY_FILE"
  fi
  if [[ ! -s "$PHASE_STATUS_FILE" ]]; then
    printf 'timestamp\tphase\tstate\texit_code\tattempt\tnote\n' > "$PHASE_STATUS_FILE"
  fi
}

main() {
  parse_args "$@"

  [[ -f "$CONFIG_FILE" ]] || fail "Config file not found: $CONFIG_FILE"
  require_command yq

  local migration_idx=""
  local init_migration_was_explicit=true

  if [[ "$MODE" == "init" ]]; then
    [[ -n "$MIGRATION_NAME" ]] || init_migration_was_explicit=false
    migration_idx="$(select_init_migration)"
    MIGRATION_NAME="$(migration_required_value "$migration_idx" name)"
    validate_config "true" "$migration_idx"
    resolve_migration_context "$migration_idx"
  elif [[ "$MODE" == "show-datatype-mapping" ]]; then
    validate_datatype_mapping_config
    if [[ -n "$MIGRATION_NAME" ]]; then
      migration_idx="$(get_migration_index "$MIGRATION_NAME")"
      resolve_migration_context "$migration_idx"
    else
      resolve_global_repository_context
    fi
  else
    migration_idx="$(get_migration_index "$MIGRATION_NAME")"
    validate_config "true" "$migration_idx"
    resolve_migration_context "$migration_idx"
  fi

  if [[ "$MODE" == "show-datatype-mapping" ]]; then
    configure_active_oracle_wallet >&2
    require_command sqlplus
    show_datatype_mapping "$MIGRATION_NAME"
    return 0
  fi

  bootstrap_logging

  log_info "Config file: $CONFIG_FILE"
  log_info "Run ID: $RUN_ID"
  log_info "Run name: $RUN_NAME"
  log_info "Project directory: $PROJECT_DIR"
  log_info "Run directory: $RUN_DIR"
  log_info "Autokit directory: $AUTOKIT_DIR"
  log_info "SDCLI output directory: $SDCLI_OUTPUT_DIR"
  log_info "Run log: $RUN_LOG_FILE"
  log_info "SDCLI command log: $SDCLI_COMMAND_LOG"
  log_info "Dry run mode: $DRY_RUN"

  if [[ "$MODE" == "init" && "$init_migration_was_explicit" == "false" ]]; then
    log_info "Inferred the only configured migration for repository initialization: $MIGRATION_NAME"
  fi

  configure_active_oracle_wallet
  log_info "Config validation passed"
  log_info "Load tuning source: config.yaml defaults.load_preferences with per-migration overrides in migrations[].load_preferences"

  if ! $DRY_RUN; then
    if mode_uses_sdcli; then require_command sdcli; fi
    case "$MODE" in
      init)
        require_command sqlplus
        ;;
      full|migrate)
        require_command sqlplus
        require_command sqlcmd
        require_command python3
        ;;
      phase)
        if [[ "$PHASE_NAME" == "deploy" || "$PHASE_NAME" == "cleanup" || "$PHASE_NAME" == "postdeploy" || "$PHASE_NAME" == "validate" ]]; then
          require_command sqlplus
        fi
        if [[ "$PHASE_NAME" == "validate" ]]; then
          require_command sqlcmd
          require_command python3
        fi
        ;;
    esac
  fi

  if mode_uses_sdcli; then
    prepare_project_profile
    if [[ "$MODE" == init ]]; then
      initialize_project_preferences
    elif ! $DRY_RUN; then
      configure_sqldeveloper_file_output_option
    fi
  fi
  if mode_needs_repository_lock; then
    acquire_repository_lock
  fi

  if [[ "$MODE" == "init" ]]; then
    setup_repository
    mark_project_profile_ready
    log_info "Repository initialization completed."
    return 0
  fi

  run_single_migration "$migration_idx"

  log_info "Requested operation completed."
  log_info "Migration summary: $MIGRATION_SUMMARY_FILE"
}

if [[ "${MIGRATE_SH_SOURCE_ONLY:-false}" != "true" ]]; then
  main "$@"
fi
