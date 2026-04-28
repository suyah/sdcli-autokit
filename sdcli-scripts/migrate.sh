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

RUN_ID="$(date '+%Y%m%d_%H%M%S')"
RUN_NAME=""
PROJECT_ROOT=""
PROJECT_DIR=""
RUN_DIR=""
AUTOKIT_DIR=""
SDCLI_OUTPUT_DIR=""
RUN_LOG_FILE=""
SDCLI_COMMAND_LOG=""
SDCLI_SUMMARY_FILE=""
MIGRATION_SUMMARY_FILE=""

declare -a SDCLI_COMMANDS=()

# --- CLI and logging helpers -------------------------------------------------
usage() {
  cat <<'USAGE'
Usage:
  ./migrate.sh --init [options]
  ./migrate.sh <migration_name> [options]

Modes:
  --init                 One-off repository setup: driver + repository init
  --conn-setup           Create source and target SDCLI connections only
  --phase <name>         Run one phase only: capture|convert|generate|deploy|datamove|offload|load|postdeploy|validate
  --migrate              Run all phases: capture->convert->generate->datamove->offload->deploy->load->postdeploy->validate

Options:
  --model <name>         Optional model for non-capture --phase mode only
                         capture always uses <migration_name>_<run_id>
                         other phases default to latest
  --run <name>           Use an existing run directory for non-capture --phase mode
  --dry-run              Print/log commands without executing commands/scripts
  -h, --help             Show help

Examples:
  ./migrate.sh --init
  ./migrate.sh tpcc
  ./migrate.sh tpcc --conn-setup
  ./migrate.sh tpcc --phase capture
  ./migrate.sh tpcc --phase deploy --model latest
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
    fail "Choose only one mode: --init, --conn-setup, --phase, or --migrate"
  fi
  MODE="$new_mode"
  MODE_EXPLICIT=true
}

mask_conn_details_value() {
  local value="$1"
  local part masked_parts=()

  IFS=',' read -r -a parts <<< "$value"
  for part in "${parts[@]}"; do
    if [[ "$part" == *":oracle:"* || "$part" == *":sqlserver:"* ]]; then
      local prefix rest suffix
      prefix="${part%@*}"
      suffix="${part##*@}"
      if [[ "$prefix" == */* && "$part" == *"@"* ]]; then
        rest="${prefix%%/*}/***@${suffix}"
        masked_parts+=("$rest")
      else
        masked_parts+=("$part")
      fi
    elif [[ "$part" == *":mkrepouser:"* ]]; then
      local left right
      left="${part%%:*}"
      right="${part#*:mkrepouser:}"
      if [[ "$right" == */*:* ]]; then
        masked_parts+=("${left}:mkrepouser:${right%%/*}/***:${right##*:}")
      else
        masked_parts+=("$part")
      fi
    else
      masked_parts+=("$part")
    fi
  done

  local joined
  local IFS=,
  joined="${masked_parts[*]}"
  echo "$joined"
}

mask_sensitive() {
  local masked_args=()
  local arg
  for arg in "$@"; do
    case "$arg" in
      -connDetails=*)
        masked_args+=("-connDetails=$(mask_conn_details_value "${arg#-connDetails=}")")
        ;;
      *)
        masked_args+=("$arg")
        ;;
    esac
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

if [[ "${MIGRATE_SH_SOURCE_ONLY:-false}" != "true" ]]; then
  trap on_exit EXIT
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
    echo "$env_value"
    return 0
  fi

  if $DRY_RUN; then
    echo "DRY_RUN_SECRET"
    return 0
  fi

  fail "Environment variable '$env_name' is not set or empty"
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

get_repository_connection_name() {
  get_required_value '.migration_repository.repo_user.connection_name' 'migration_repository.repo_user.connection_name'
}

to_lower() {
  echo "$1" | tr '[:upper:]' '[:lower:]'
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

# --- SDCLI execution ---------------------------------------------------------
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

run_sdcli() {
  local cmd=("$@")
  local printable
  printable="$(mask_sensitive "${cmd[@]}")"

  log_info "+ $printable"
  SDCLI_COMMANDS+=("$printable")
  if [[ -n "${SDCLI_COMMAND_LOG:-}" ]]; then
    echo "$printable" >> "$SDCLI_COMMAND_LOG"
  fi

  if $DRY_RUN; then
    return 0
  fi

  "${cmd[@]}" 2>&1 | tee -a "$RUN_LOG_FILE" | filter_sdcli_console_output
  return ${PIPESTATUS[0]}
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

  get_required_value '.defaults.driver_file' 'defaults.driver_file' >/dev/null
  get_required_value '.defaults.paths.project_root' 'defaults.paths.project_root' >/dev/null
  local bcp_tls_mode
  bcp_tls_mode="$(normalize_bcp_tls_mode "$(get_required_value '.defaults.source.bcp_tls_mode' 'defaults.source.bcp_tls_mode')")"
  validate_bcp_packet_size_for_tls "$bcp_tls_mode" "$(get_bcp_packet_size)" >/dev/null

  get_required_value '.migration_repository.name' 'migration_repository.name' >/dev/null
  get_required_value '.migration_repository.conn' 'migration_repository.conn' >/dev/null
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

  local i
  for ((i = 0; i < migration_count; i++)); do
    validate_migration_config "$i"
  done
}

setup_repository() {
  local driver_file
  driver_file="$(get_required_value '.defaults.driver_file' 'defaults.driver_file')"
  run_sdcli sdcli migration -actions=driver -files="$driver_file" || fail "Failed to register SQL Server driver"

  local repo_label repo_name repo_conn repo_user repo_password
  repo_label="$(get_required_value '.migration_repository.name' 'migration_repository.name')"
  repo_name="$(get_repository_connection_name)"
  repo_conn="$(get_required_value '.migration_repository.conn' 'migration_repository.conn')"
  repo_user="$(get_required_value '.migration_repository.repo_user.user' 'migration_repository.repo_user.user')"
  repo_password="$(get_secret_value '.migration_repository.repo_user.password' 'migration_repository.repo_user.password')"

  local super_name super_user super_password
  super_name="$(get_required_value '.migration_repository.super_user.connection_name' 'migration_repository.super_user.connection_name')"
  super_user="$(get_required_value '.migration_repository.super_user.user' 'migration_repository.super_user.user')"
  super_password="$(get_secret_value '.migration_repository.super_user.password' 'migration_repository.super_user.password')"

  local init_conn_details
  init_conn_details="${super_name}:oracle:${super_user}/${super_password}@${repo_conn},${repo_name}:mkrepouser:${repo_user}/${repo_password}:${super_name}"

  log_info "Initializing repository '${repo_label}' via connection '${repo_name}'"
  if ! run_sdcli sdcli migration -actions=init -connDetails="$init_conn_details"; then
    log_warn "Repository init returned non-zero; continuing (it may already be initialized)"
  fi
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

# --- SQL*Plus deploy helpers -------------------------------------------------
run_sqlplus_file() {
  local base_dir="$1"
  local sqlfile="$2"
  local target_conn="$3"
  local target_user="$4"
  local target_password="$5"
  local schema_password="${6:-}"
  local prompt_count="${7:-0}"
  local current_schema="${8:-}"

  local full_path="$base_dir/$sqlfile"
  [[ -f "$full_path" ]] || return 0

  log_info "Executing SQL*Plus script: $full_path"
  if $DRY_RUN; then
    log_info "+ sqlplus -S -L /nolog (connect ${target_user}/***@${target_conn}; @$full_path)"
    return 0
  fi

  local wrapper_file password_file password_backup rc
  wrapper_file="$(mktemp "${TMPDIR:-/tmp}/sdcli_sqlplus_XXXXXX.sql")" || return 1
  {
    printf '%s\n' 'WHENEVER OSERROR EXIT FAILURE;'
    printf '%s\n' 'WHENEVER SQLERROR EXIT SQL.SQLCODE;'
    if (( prompt_count > 0 )); then
      printf '%s\n' '@"passworddefinition.sql"'
    fi
    if [[ -n "$current_schema" ]]; then
      printf 'alter session set current_schema = %s;\n' "$current_schema"
      printf '%s\n' 'set define off'
    fi
    printf '@"%s"\n' "$sqlfile"
    if [[ -n "$current_schema" ]]; then
      printf '%s\n' 'set define on'
    fi
    printf '%s\n' 'EXIT;'
  } > "$wrapper_file"

  if (( prompt_count > 0 )); then
    password_file="$base_dir/passworddefinition.sql"
    password_backup="$(install_sqlplus_password_defines "$password_file" "$schema_password")" || {
      rm -f "$wrapper_file"
      return 1
    }
  fi

  set +e
  (
    local connect_password
    connect_password="${target_password//\"/\"\"}"
    cd "$base_dir"
    {
      printf 'connect %s/"%s"@%s\n' "$target_user" "$connect_password" "$target_conn"
      printf '@"%s"\n' "$wrapper_file"
    } | sqlplus -S -L /nolog
  ) 2>&1 | filter_sqlplus_deploy_output | tee -a "$RUN_LOG_FILE"
  rc=${PIPESTATUS[0]}
  set -e

  if [[ -n "${password_backup:-}" ]]; then
    rm -f "$password_file"
    mv "$password_backup" "$password_file"
  fi
  rm -f "$wrapper_file"
  return "$rc"
}

install_sqlplus_password_defines() {
  local password_file="$1"
  local schema_password="$2"
  local backup_file var escaped_password

  [[ -f "$password_file" ]] || fail "SQL*Plus password definition file not found: $password_file"

  backup_file="$(mktemp "${TMPDIR:-/tmp}/sdcli_passworddefinition_XXXXXX.sql")" || return 1
  cp "$password_file" "$backup_file" || {
    rm -f "$backup_file"
    return 1
  }

  escaped_password="${schema_password//\"/\"\"}"
  {
    echo "-- Generated by migrate.sh for this deploy run; original restored after SQL*Plus exits."
    while IFS= read -r var; do
      printf 'DEFINE %s = "%s"\n' "$var" "$escaped_password"
    done < <(awk 'toupper($1) == "ACCEPT" { print $2 }' "$backup_file")
  } > "$password_file" || {
    mv "$backup_file" "$password_file"
    return 1
  }

  echo "$backup_file"
}

filter_sqlplus_deploy_output() {
  local line password_regex
  password_regex='^(.*[Ii][Dd][Ee][Nn][Tt][Ii][Ff][Ii][Ee][Dd][[:space:]]+[Bb][Yy][[:space:]]+)[^[:space:];]+(.*)$'
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ $password_regex ]]; then
      line="${BASH_REMATCH[1]}***${BASH_REMATCH[2]}"
    fi
    printf '%s\n' "$line"
  done
}

count_sqlplus_accept_prompts() {
  local password_file="$1"
  local count
  [[ -f "$password_file" ]] || {
    echo 0
    return 0
  }
  count="$(grep -Eci '^[[:space:]]*ACCEPT[[:space:]]+' "$password_file" 2>/dev/null || true)"
  echo "${count:-0}"
}

deploy_manifest_file() {
  echo "$AUTOKIT_DIR/deploy_manifest.csv"
}

ensure_deploy_manifest() {
  local manifest
  manifest="$(deploy_manifest_file)"
  mkdir -p "$(dirname "$manifest")"
  [[ -f "$manifest" ]] || echo "phase,path,status" > "$manifest"
}

init_deploy_manifest() {
  local manifest
  manifest="$(deploy_manifest_file)"
  mkdir -p "$(dirname "$manifest")"
  echo "phase,path,status" > "$manifest"
}

record_deploy_manifest() {
  local phase="$1"
  local path="$2"
  local status="$3"
  ensure_deploy_manifest
  [[ -z "${RUN_DIR:-}" || "$path" != "$RUN_DIR/"* ]] || path="${path#$RUN_DIR/}"
  echo "$phase,$path,$status" >> "$(deploy_manifest_file)"
}

schema_dirs() {
  local output_dir="$1"
  find "$output_dir" -mindepth 2 -maxdepth 2 -type f -name 'user.sql' 2>/dev/null | while IFS= read -r user_sql; do
    dirname "$user_sql"
  done | sort
}

run_deploy() {
  local idx="$1"
  local output_dir="$2"

  local target_conn target_user target_password prompt_count schema_password
  target_conn="$(migration_required_value "$idx" target conn)"
  target_user="$(migration_required_value "$idx" target user)"
  target_password="$(migration_secret_value "$idx" target password)"
  prompt_count="$(count_sqlplus_accept_prompts "$output_dir/passworddefinition.sql")"
  if (( prompt_count > 0 )); then
    schema_password="$(migration_secret_value "$idx" target default_schema_password)"
  fi

  log_info "Deploying generated Oracle schema for data load"
  log_info "Target: $target_user@$target_conn"
  if (( prompt_count > 0 )); then
    log_info "Deploy schema password prompts: $prompt_count from migrations[$idx].target.default_schema_password"
  fi

  if $DRY_RUN; then
    log_info "[DRY-RUN] deploy root: $output_dir"
    log_info "[DRY-RUN] deploy script: $output_dir/role.sql"
    log_info "[DRY-RUN] deploy script glob: $output_dir/*/user.sql"
    log_info "[DRY-RUN] deploy script glob: $output_dir/*/tables.sql"
    log_info "[DRY-RUN] deploy manifest: $(deploy_manifest_file)"
    return 0
  fi

  init_deploy_manifest

  if [[ -f "$output_dir/role.sql" ]]; then
    run_sqlplus_file "$output_dir" "role.sql" "$target_conn" "$target_user" "$target_password" || fail "role.sql failed"
    record_deploy_manifest "deploy" "$output_dir/role.sql" "executed"
  fi

  local found_any=false schema_dir schema_name rel_user_sql rel_tables_sql
  while IFS= read -r schema_dir; do
    found_any=true
    rel_user_sql="${schema_dir#$output_dir/}/user.sql"
    run_sqlplus_file "$output_dir" "$rel_user_sql" "$target_conn" "$target_user" "$target_password" "$schema_password" "$prompt_count" || fail "user.sql failed in $schema_dir"
    record_deploy_manifest "deploy" "$schema_dir/user.sql" "executed"
  done < <(schema_dirs "$output_dir")

  $found_any || fail "No deployable schema user.sql found under $output_dir"

  while IFS= read -r schema_dir; do
    if [[ -f "$schema_dir/tables.sql" ]]; then
      schema_name="$(basename "$schema_dir")"
      rel_tables_sql="${schema_dir#$output_dir/}/tables.sql"
      run_sqlplus_file "$output_dir" "$rel_tables_sql" "$target_conn" "$target_user" "$target_password" "" 0 "$schema_name" || fail "tables.sql failed in $schema_dir"
      record_deploy_manifest "deploy" "$schema_dir/tables.sql" "executed"
    fi
  done < <(schema_dirs "$output_dir")

  local generated_sql
  while IFS= read -r generated_sql; do
    record_deploy_manifest "deploy" "$generated_sql" "skipped"
  done < <(find "$output_dir/gen" -maxdepth 1 -type f -name 'generated-*.sql' 2>/dev/null | sort)

  log_info "Deploy manifest: $(deploy_manifest_file)"
}

run_postdeploy() {
  local idx="$1"
  local output_dir="$2"

  local target_conn target_user target_password
  target_conn="$(migration_required_value "$idx" target conn)"
  target_user="$(migration_required_value "$idx" target user)"
  target_password="$(migration_secret_value "$idx" target password)"

  log_info "Running postdeploy Oracle scripts"
  log_info "Target: $target_user@$target_conn"

  if $DRY_RUN; then
    log_info "[DRY-RUN] postdeploy root: $output_dir"
    log_info "[DRY-RUN] postdeploy script glob: $output_dir/*/indexes.sql"
    log_info "[DRY-RUN] postdeploy script glob: $output_dir/*/synonyms.sql"
    log_info "[DRY-RUN] postdeploy script glob: $output_dir/*/post.sql"
    log_info "[DRY-RUN] postdeploy skipped globs: $output_dir/*/master.sql,$output_dir/*/packages.sql,$output_dir/*/procedures.sql"
    log_info "[DRY-RUN] deploy manifest: $(deploy_manifest_file)"
    return 0
  fi

  ensure_deploy_manifest

  local schema_dir schema_name rel_script script skipped
  while IFS= read -r schema_dir; do
    schema_name="$(basename "$schema_dir")"
    for script in indexes.sql synonyms.sql post.sql; do
      if [[ -f "$schema_dir/$script" ]]; then
        rel_script="${schema_dir#$output_dir/}/$script"
        run_sqlplus_file "$output_dir" "$rel_script" "$target_conn" "$target_user" "$target_password" "" 0 "$schema_name" || fail "$script failed in $schema_dir"
        record_deploy_manifest "postdeploy" "$schema_dir/$script" "executed"
      fi
    done

    for skipped in master.sql packages.sql procedures.sql; do
      if [[ -f "$schema_dir/$skipped" ]]; then
        record_deploy_manifest "postdeploy" "$schema_dir/$skipped" "skipped"
      fi
    done
  done < <(schema_dirs "$output_dir")

  log_info "Deploy manifest: $(deploy_manifest_file)"
}

VALIDATION_LAST_COUNT=0

is_ignored_validation_diagnostic() {
  local line="$1"
  [[ "$line" == *"ORA-28098:"* ]]
}

validate_run_log() {
  local log_file="$1"
  local count=0 ignored=0 match line_no line
  local matches

  VALIDATION_LAST_COUNT=0
  if [[ ! -f "$log_file" ]]; then
    log_warn "Run log not found: $log_file"
    return 0
  fi

  matches="$(grep -nE '\[ERROR\]|SQL\*Loader table .*status=failed|SQL\*Loader load summary: tables=0([[:space:]]|$)|SQL\*Loader diagnostic:|SQL\*Loader load failed:' "$log_file" || true)"
  while IFS= read -r match; do
    [[ -n "$match" ]] || continue
    line_no="${match%%:*}"
    line="${match#*:}"
    if [[ "$line" == *"Run log issue:"* || "$line" == *"Run log diagnostics:"* || "$line" == *"Validation summary:"* ]]; then
      continue
    fi
    if is_ignored_validation_diagnostic "$line"; then
      ignored=$((ignored + 1))
      continue
    fi
    count=$((count + 1))
    log_warn "Run log issue: $log_file:$line_no: $line"
  done <<< "$matches"

  log_info "Run log diagnostics: issues=$count ignored=$ignored"
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

run_validate() {
  local output_dir="$1"

  if $DRY_RUN; then
    log_info "[DRY-RUN] validate run log: ${RUN_LOG_FILE:-$AUTOKIT_DIR/migrate.log}"
    log_info "[DRY-RUN] validate sdcli error log: $output_dir/log/error.txt"
    log_info "[DRY-RUN] validate SQL*Loader logs: $output_dir/datamove/**/log/*.log"
    return 0
  fi

  log_info "Validating migration output"

  local run_log="${RUN_LOG_FILE:-$AUTOKIT_DIR/migrate.log}"
  local run_log_issues sdcli_error_entries sqlldr_logs_checked=0 sqlldr_log_issues=0

  validate_run_log "$run_log"
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
  elif (( sqlldr_log_issues == 0 )); then
    log_info "No SQL*Loader table log issues found"
  fi

  log_info "Validation summary: run_log_issues=$run_log_issues sdcli_error_entries=$sdcli_error_entries sqlldr_logs_checked=$sqlldr_logs_checked sqlldr_log_issues=$sqlldr_log_issues"
}

run_load() {
  local idx="$1"
  local output_dir="$2"

  local target_conn target_user target_password
  target_conn="$(migration_required_value "$idx" target conn)"
  target_user="$(migration_required_value "$idx" target user)"
  target_password="$(migration_secret_value "$idx" target password)"

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
  done < <(find "$datamove_dir" -type f -name 'oracle_loader.sh' 2>/dev/null | sort)
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

  local start_ts rc
  start_ts="$(date +%s)"
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
  ) 2>&1 | tee -a "$RUN_LOG_FILE" | summarize_sqlldr_output
  rc=${PIPESTATUS[0]}
  set -e

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

  local bcp_script
  bcp_script="$(find "$datamove_dir" -type f -name 'MicrosoftSQLServer_data.sh' 2>/dev/null | head -1 || true)"
  [[ -n "$bcp_script" && -f "$bcp_script" ]] || fail "BCP script not found under $datamove_dir"

  log_info "Running BCP offload script"
  log_info "BCP TLS mode: $bcp_tls_mode"
  log_info "BCP packet size requested: $bcp_packet_size"
  log_info "BCP script: $bcp_script"
  log_info "Source host: $source_host"
  log_info "Source port: $source_port"
  log_info "Source database: $source_db"

  chmod +x "$bcp_script"
  local script_dir script_name
  script_dir="$(dirname "$bcp_script")"
  script_name="$(basename "$bcp_script")"

  local bcp_tables=() bcp_table
  while IFS= read -r bcp_table; do
    bcp_tables+=("$bcp_table")
  done < <(extract_bcp_table_names_from_dir "$datamove_dir")
  log_info "BCP tables discovered: ${#bcp_tables[@]}"

  local start_ts
  start_ts="$(date +%s)"

  local rc=0
  set +e
  (
    cd "$script_dir"
    export SQLSERVER_BCP_TLS_MODE_EFFECTIVE="$bcp_tls_mode"
    export SQLSERVER_BCP_PACKET_SIZE="$bcp_packet_size"
    export SQLSERVER_BCP_PASSWORD="${source_password}"
    export PATH="$SCRIPT_DIR/lib:$PATH"
    "./$script_name" "${source_host},${source_port}" "$source_user" "__SDCLI_BCP_PASSWORD__"
  ) 2>&1 | tee -a "$RUN_LOG_FILE" | summarize_bcp_output "${bcp_tables[@]}"
  rc=${PIPESTATUS[0]}
  set -e

  log_timed_result "BCP offload" "$rc" "$start_ts"
  return "$rc"
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

  case "$phase_name" in
    capture)
      run_sdcli sdcli migration -actions=capture -conn="$src_conn_name" -repository="$repo_name" -model="$model_name" -project="$project_name" -append -output="$output_dir" \
        || fail "Capture failed for migration '$project_name'"
      ;;
    convert)
      run_sdcli sdcli migration -actions=convert -repository="$repo_name" -model="$model_name" -output="$output_dir" \
        || fail "Convert failed for migration '$project_name'"
      ;;
    generate)
      run_sdcli sdcli migration -actions=generate -repository="$repo_name" -model="$model_name" -dest="$target_name" -output="$output_dir" \
        || fail "Generate failed for migration '$project_name'"
      ;;
    deploy)
      run_deploy "$idx" "$output_dir" || fail "Deploy failed for migration '$project_name'"
      ;;
    datamove)
      run_sdcli sdcli migration -actions=datamove -repository="$repo_name" -model="$model_name" -output="$output_dir" \
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
      run_validate "$output_dir" || fail "Validate failed for migration '$project_name'"
      ;;
    *)
      fail "Unsupported phase: $phase_name"
      ;;
  esac
}

run_all_phases() {
  local repo_name="$1"
  local src_conn_name="$2"
  local target_name="$3"
  local model_name="$4"
  local project_name="$5"
  local output_dir="$6"
  local idx="$7"

  local phase phase_model
  for phase in capture convert generate datamove offload deploy load postdeploy validate; do
    phase_model="latest"
    [[ "$phase" == "capture" ]] && phase_model="$model_name"
    run_phase "$phase" "$repo_name" "$src_conn_name" "$target_name" "$phase_model" "$project_name" "$output_dir" "$idx"
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

  local source_user source_password src_conn_details
  source_user="$(migration_required_value "$idx" source user)"
  source_password="$(migration_secret_value "$idx" source password)"
  src_conn_details="${source_conn_name}:sqlserver:${source_user}/${source_password}@${source_conn}"
  ensure_connection "$source_conn_name" "$src_conn_details"

  local target_conn target_user target_password tgt_conn_details
  target_conn="$(migration_required_value "$idx" target conn)"
  target_user="$(migration_required_value "$idx" target user)"
  target_password="$(migration_secret_value "$idx" target password)"
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

  local repo_name
  repo_name="$(get_repository_connection_name)"

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
      record_migration_completion "$migration_name" "connection_setup_completed" "" "$output_dir" "$start_ts" "Connection setup completed: $migration_name"
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
      --migrate)
        set_mode "migrate"
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

  if [[ "$MODE" == "init" ]]; then
    [[ -z "$MIGRATION_NAME" ]] || fail "Migration name is not allowed with --init"
  else
    [[ -n "$MIGRATION_NAME" ]] || fail "Migration name is required (example: ./migrate.sh tpcc)"
  fi

  if [[ "$MODE" == "phase" ]]; then
    case "$PHASE_NAME" in
      capture|convert|generate|deploy|datamove|offload|load|postdeploy|validate) ;;
      *) fail "Invalid --phase '$PHASE_NAME'. Use: capture|convert|generate|deploy|datamove|offload|load|postdeploy|validate" ;;
    esac
  fi

  if [[ "$MODE" == "phase" && "$PHASE_NAME" == "capture" && -n "$MODEL_NAME_INPUT" ]]; then
    fail "--model is not supported with --phase capture; capture always uses <migration_name>_<run_id>"
  fi

  if [[ -n "$RUN_NAME_INPUT" && ! ( "$MODE" == "phase" && "$PHASE_NAME" != "capture" ) ]]; then
    fail "--run can only be used with non-capture --phase"
  fi

  if [[ -n "$MODEL_NAME_INPUT" && "$MODE" != "phase" ]]; then
    fail "--model can only be used with --phase"
  fi
}

bootstrap_logging() {
  PROJECT_ROOT="$(get_required_value '.defaults.paths.project_root' 'defaults.paths.project_root')"

  mkdir -p "$PROJECT_ROOT"

  if [[ "$MODE" == "init" ]]; then
    PROJECT_DIR="$PROJECT_ROOT/_init"
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

  SDCLI_COMMAND_LOG="$AUTOKIT_DIR/sdcli_commands.log"
  SDCLI_SUMMARY_FILE="$AUTOKIT_DIR/sdcli_commands_summary.txt"
  MIGRATION_SUMMARY_FILE="$AUTOKIT_DIR/migration_summary.csv"

  {
    echo "timestamp,migration,status,model_name,output_dir,duration_sec,note"
  } > "$MIGRATION_SUMMARY_FILE"
}

main() {
  parse_args "$@"

  [[ -f "$CONFIG_FILE" ]] || fail "Config file not found: $CONFIG_FILE"
  require_command yq

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

  if [[ "$MODE" == "init" ]]; then
    validate_config "false"
  else
    validate_config "true"
  fi
  log_info "Config validation passed"
  log_info "Load tuning source: config.yaml defaults.load_preferences with per-migration overrides in migrations[].load_preferences"

  if ! $DRY_RUN; then
    require_command sdcli
    case "$MODE" in
      full|migrate)
        require_command sqlplus
        ;;
      phase)
        if [[ "$PHASE_NAME" == "deploy" || "$PHASE_NAME" == "postdeploy" ]]; then
          require_command sqlplus
        fi
        ;;
    esac
  fi

  if [[ "$MODE" == "init" ]]; then
    setup_repository
    log_info "Repository initialization completed."
    return 0
  fi

  local migration_idx
  migration_idx="$(get_migration_index "$MIGRATION_NAME")"
  run_single_migration "$migration_idx"

  log_info "Requested operation completed."
  log_info "Migration summary: $MIGRATION_SUMMARY_FILE"
}

if [[ "${MIGRATE_SH_SOURCE_ONLY:-false}" != "true" ]]; then
  main "$@"
fi
