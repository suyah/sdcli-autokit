#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.yaml"

MIGRATION_NAME=""
MODE="full"
MODE_EXPLICIT=false
PHASE_NAME=""
MODEL_NAME_INPUT=""
DRY_RUN=false

RUN_ID="$(date '+%Y%m%d_%H%M%S')"
OUTPUT_ROOT=""
LOG_ROOT=""
RUN_DIR=""
RUN_LOG_FILE=""
SDCLI_COMMAND_LOG=""
SDCLI_SUMMARY_FILE=""
MIGRATION_SUMMARY_FILE=""

declare -a SDCLI_COMMANDS=()

usage() {
  cat <<'USAGE'
Usage:
  ./migrate.sh --init [options]
  ./migrate.sh <migration_name> [options]

Modes:
  --init                 One-off repository setup: driver + repository init
  --conn-setup           Create source and target SDCLI connections only
  --phase <name>         Run one phase only: capture|convert|generate|datamove|offload
  --migrate              Run all five phases only: capture->convert->generate->datamove->offload

Options:
  --model <name>         Optional model for --phase mode only
                         capture default: <migration_name>_<run_id>
                         convert/generate/datamove/offload default: latest
  --dry-run              Print/log commands without executing sdcli or BCP scripts
  -h, --help             Show help

Examples:
  ./migrate.sh --init
  ./migrate.sh tpcc
  ./migrate.sh tpcc --conn-setup
  ./migrate.sh tpcc --phase capture
  ./migrate.sh tpcc --phase datamove --model latest
  ./migrate.sh tpcc --phase offload --model latest
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

printable_command() {
  mask_sensitive "$@"
}

write_sdcli_summary() {
  local status="$1"
  [[ -n "${SDCLI_SUMMARY_FILE:-}" ]] || return 0

  local sdcli_count=0
  local cmd
  for cmd in "${SDCLI_COMMANDS[@]+"${SDCLI_COMMANDS[@]}"}"; do
    sdcli_count=$((sdcli_count + 1))
  done

  {
    echo "run_id: $RUN_ID"
    echo "status: $status"
    echo "total_sdcli_commands: $sdcli_count"
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

  if [[ -n "${SDCLI_SUMMARY_FILE:-}" ]]; then
    write_sdcli_summary "$status" || true
    if [[ -n "${RUN_LOG_FILE:-}" ]]; then
      echo "[INFO] $(timestamp) - SDCLI summary file: $SDCLI_SUMMARY_FILE" >> "$RUN_LOG_FILE"
    fi
    echo
    echo "===== SDCLI COMMAND SUMMARY ====="
    cat "$SDCLI_SUMMARY_FILE"
  fi
}
trap on_exit EXIT

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

run_sdcli() {
  local cmd=("$@")
  local printable
  printable="$(printable_command "${cmd[@]}")"

  log_info "+ $printable"
  SDCLI_COMMANDS+=("$printable")
  if [[ -n "${SDCLI_COMMAND_LOG:-}" ]]; then
    echo "$printable" >> "$SDCLI_COMMAND_LOG"
  fi

  if $DRY_RUN; then
    return 0
  fi

  "${cmd[@]}" 2>&1 | tee -a "$RUN_LOG_FILE"
  return ${PIPESTATUS[0]}
}

run_logged_command() {
  local cmd=("$@")
  local printable
  printable="$(printable_command "${cmd[@]}")"

  log_info "+ $printable"
  if $DRY_RUN; then
    return 0
  fi

  "${cmd[@]}" 2>&1 | tee -a "$RUN_LOG_FILE"
  return ${PIPESTATUS[0]}
}

build_oracle_conn_details() {
  local conn_name="$1"
  local user="$2"
  local password="$3"
  local conn="$4"
  echo "${conn_name}:oracle:${user}/${password}@${conn}"
}

build_sqlserver_conn_details() {
  local conn_name="$1"
  local user="$2"
  local password="$3"
  local conn="$4"
  echo "${conn_name}:sqlserver:${user}/${password}@${conn}"
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

validate_config() {
  local require_migrations="${1:-true}"

  get_required_value '.defaults.driver_file' 'defaults.driver_file' >/dev/null
  get_required_value '.defaults.paths.output_root' 'defaults.paths.output_root' >/dev/null
  get_required_value '.defaults.paths.log_root' 'defaults.paths.log_root' >/dev/null
  normalize_bcp_tls_mode "$(get_required_value '.defaults.source.bcp_tls_mode' 'defaults.source.bcp_tls_mode')" >/dev/null

  get_required_value '.migration_repository.name' 'migration_repository.name' >/dev/null
  get_required_value '.migration_repository.conn' 'migration_repository.conn' >/dev/null
  get_required_value '.migration_repository.repo_user.connection_name' 'migration_repository.repo_user.connection_name' >/dev/null
  get_required_value '.migration_repository.repo_user.user' 'migration_repository.repo_user.user' >/dev/null
  get_required_value '.migration_repository.super_user.connection_name' 'migration_repository.super_user.connection_name' >/dev/null
  get_required_value '.migration_repository.super_user.user' 'migration_repository.super_user.user' >/dev/null
  validate_secret_placeholder '.migration_repository.repo_user.password' 'migration_repository.repo_user.password'
  validate_secret_placeholder '.migration_repository.super_user.password' 'migration_repository.super_user.password'

  if [[ "$require_migrations" != "true" ]]; then
    return 0
  fi

  local migration_count
  migration_count="$(yq_eval '.migrations | length')"
  [[ "$migration_count" =~ ^[0-9]+$ ]] || fail "Invalid migrations list in config"
  (( migration_count > 0 )) || fail "No migrations defined in config"

  local i
  for ((i = 0; i < migration_count; i++)); do
    get_required_value ".migrations[$i].name" "migrations[$i].name" >/dev/null
    get_required_value ".migrations[$i].source.conn" "migrations[$i].source.conn" >/dev/null
    get_required_value ".migrations[$i].source.user" "migrations[$i].source.user" >/dev/null
    validate_secret_placeholder ".migrations[$i].source.password" "migrations[$i].source.password"
    get_required_value ".migrations[$i].target.conn" "migrations[$i].target.conn" >/dev/null
    get_required_value ".migrations[$i].target.user" "migrations[$i].target.user" >/dev/null
    validate_secret_placeholder ".migrations[$i].target.password" "migrations[$i].target.password"
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
    current="$(get_required_value ".migrations[$i].name" "migrations[$i].name")"
    if [[ "$current" == "$migration_name" ]]; then
      echo "$i"
      return 0
    fi
  done

  fail "Migration '$migration_name' not found in config"
}

ensure_migration_connections() {
  local idx="$1"

  local migration_name
  migration_name="$(get_required_value ".migrations[$idx].name" "migrations[$idx].name")"

  local source_conn_name source_conn source_user source_password
  source_conn_name="src_${migration_name}"
  source_conn="$(get_required_value ".migrations[$idx].source.conn" "migrations[$idx].source.conn")"
  source_user="$(get_required_value ".migrations[$idx].source.user" "migrations[$idx].source.user")"
  source_password="$(get_secret_value ".migrations[$idx].source.password" "migrations[$idx].source.password")"

  local target_name target_conn target_user target_password
  target_name="tgt_${migration_name}"
  target_conn="$(get_required_value ".migrations[$idx].target.conn" "migrations[$idx].target.conn")"
  target_user="$(get_required_value ".migrations[$idx].target.user" "migrations[$idx].target.user")"
  target_password="$(get_secret_value ".migrations[$idx].target.password" "migrations[$idx].target.password")"

  local src_conn_details
  src_conn_details="$(build_sqlserver_conn_details "$source_conn_name" "$source_user" "$source_password" "$source_conn")"
  ensure_connection "$source_conn_name" "$src_conn_details"

  local tgt_conn_details
  tgt_conn_details="$(build_oracle_conn_details "$target_name" "$target_user" "$target_password" "$target_conn")"
  ensure_connection "$target_name" "$tgt_conn_details"
}

setup_bcp_wrapper() {
  local wrapper_dir="$RUN_DIR/bin"
  local wrapper_path="$wrapper_dir/bcp"

  mkdir -p "$wrapper_dir"

  cat > "$wrapper_path" <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail

REAL_BCP=""
for cand in /opt/mssql-tools18/bin/bcp /opt/mssql-tools/bin/bcp; do
  if [[ -x "$cand" ]]; then
    REAL_BCP="$cand"
    break
  fi
done

if [[ -z "$REAL_BCP" ]]; then
  echo "ERROR: real bcp binary not found" >&2
  exit 127
fi

MODE="${SQLSERVER_BCP_TLS_MODE_EFFECTIVE:-trust}"

args=()
has_u=0
has_Y=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -u)
      has_u=1
      args+=("$1")
      shift
      ;;
    -Y)
      has_Y=1
      args+=("$1")
      shift
      if [[ $# -gt 0 ]]; then
        args+=("$1")
        shift
      fi
      ;;
    *)
      args+=("$1")
      shift
      ;;
  esac
done

case "$MODE" in
  strict)
    ;;
  trust)
    if [[ $has_u -eq 0 ]]; then
      args+=("-u")
    fi
    ;;
  optional)
    if [[ $has_Y -eq 0 ]]; then
      args+=("-Y" "o")
    fi
    ;;
esac

exec "$REAL_BCP" "${args[@]}"
WRAPPER

  chmod +x "$wrapper_path"
  echo "$wrapper_dir"
}

parse_source_conn() {
  local source_conn="$1"
  local host port database rest
  IFS=':' read -r host port database rest <<< "$source_conn"
  [[ -n "$host" && -n "$port" && -n "$database" ]] || fail "Invalid source.conn format '$source_conn'. Expected host:port:database"
  echo "$host|$port|$database"
}

run_offload() {
  local idx="$1"
  local output_dir="$2"

  local source_conn source_user source_password
  source_conn="$(get_required_value ".migrations[$idx].source.conn" "migrations[$idx].source.conn")"
  source_user="$(get_required_value ".migrations[$idx].source.user" "migrations[$idx].source.user")"
  source_password="$(get_secret_value ".migrations[$idx].source.password" "migrations[$idx].source.password")"

  local parsed source_host source_port source_db
  parsed="$(parse_source_conn "$source_conn")"
  IFS='|' read -r source_host source_port source_db <<< "$parsed"

  local bcp_tls_mode
  bcp_tls_mode="$(normalize_bcp_tls_mode "$(get_required_value '.defaults.source.bcp_tls_mode' 'defaults.source.bcp_tls_mode')")"

  local bcp_script
  bcp_script="$(find "$output_dir/datamove" -type f -name 'MicrosoftSQLServer_data.sh' 2>/dev/null | head -1 || true)"
  [[ -n "$bcp_script" && -f "$bcp_script" ]] || fail "BCP script not found under $output_dir/datamove"

  local wrapper_dir
  wrapper_dir="$(setup_bcp_wrapper)"

  log_info "Running BCP offload script"
  log_info "BCP TLS mode: $bcp_tls_mode"
  log_info "BCP script: $bcp_script"
  log_info "Source host: $source_host"
  log_info "Source port: $source_port"
  log_info "Source database: $source_db"

  chmod +x "$bcp_script"
  local script_dir script_name
  script_dir="$(dirname "$bcp_script")"
  script_name="$(basename "$bcp_script")"

  if $DRY_RUN; then
    log_info "+ (cd $script_dir && PATH=$wrapper_dir:\$PATH SQLSERVER_BCP_TLS_MODE_EFFECTIVE=$bcp_tls_mode ./$script_name ${source_host},${source_port} $source_user ***)"
    return 0
  fi

  (
    cd "$script_dir"
    export SQLSERVER_BCP_TLS_MODE_EFFECTIVE="$bcp_tls_mode"
    export PATH="$wrapper_dir:$PATH"
    "./$script_name" "${source_host},${source_port}" "$source_user" "$source_password"
  ) 2>&1 | tee -a "$RUN_LOG_FILE"
  return ${PIPESTATUS[0]}
}

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
      run_sdcli sdcli migration -actions=capture -conn="$src_conn_name" -repository="$repo_name" -model="$model_name" -project="$project_name" -output="$output_dir" \
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
    datamove)
      run_sdcli sdcli migration -actions=datamove -repository="$repo_name" -model="$model_name" -output="$output_dir" \
        || fail "Datamove failed for migration '$project_name'"
      ;;
    offload)
      run_offload "$idx" "$output_dir" || fail "Offload failed for migration '$project_name'"
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

  run_phase "capture" "$repo_name" "$src_conn_name" "$target_name" "$model_name" "$project_name" "$output_dir" "$idx"
  run_phase "convert" "$repo_name" "$src_conn_name" "$target_name" "$model_name" "$project_name" "$output_dir" "$idx"
  run_phase "generate" "$repo_name" "$src_conn_name" "$target_name" "$model_name" "$project_name" "$output_dir" "$idx"
  run_phase "datamove" "$repo_name" "$src_conn_name" "$target_name" "$model_name" "$project_name" "$output_dir" "$idx"
  run_phase "offload" "$repo_name" "$src_conn_name" "$target_name" "$model_name" "$project_name" "$output_dir" "$idx"
}

run_single_migration() {
  local idx="$1"
  local migration_name
  migration_name="$(get_required_value ".migrations[$idx].name" "migrations[$idx].name")"

  local source_conn_name source_conn
  source_conn_name="src_${migration_name}"
  source_conn="$(get_required_value ".migrations[$idx].source.conn" "migrations[$idx].source.conn")"

  local target_name
  target_name="tgt_${migration_name}"

  local repo_name project_name
  repo_name="$(get_repository_connection_name)"
  project_name="$migration_name"

  local output_dir="$RUN_DIR/$migration_name"
  mkdir -p "$output_dir"

  local run_model="${migration_name}_${RUN_ID}"
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
      ensure_migration_connections "$idx"
      append_migration_summary "$migration_name" "connection_setup_completed" "" "$output_dir" "$(( $(date +%s) - start_ts ))" ""
      log_info "Connection setup completed: $migration_name"
      ;;
    phase)
      local phase_model="$MODEL_NAME_INPUT"
      if [[ "$PHASE_NAME" == "capture" ]]; then
        phase_model="${phase_model:-$run_model}"
      else
        phase_model="${phase_model:-latest}"
      fi
      if [[ "$PHASE_NAME" == "capture" || "$PHASE_NAME" == "generate" || "$PHASE_NAME" == "migrate" ]]; then
        ensure_migration_connections "$idx"
      fi
      run_phase "$PHASE_NAME" "$repo_name" "$source_conn_name" "$target_name" "$phase_model" "$project_name" "$output_dir" "$idx"
      append_migration_summary "$migration_name" "phase_${PHASE_NAME}_completed" "$phase_model" "$output_dir" "$(( $(date +%s) - start_ts ))" ""
      log_info "Single phase completed: $PHASE_NAME"
      ;;
    migrate)
      ensure_migration_connections "$idx"
      run_all_phases "$repo_name" "$source_conn_name" "$target_name" "$run_model" "$project_name" "$output_dir" "$idx"
      append_migration_summary "$migration_name" "all_phases_completed" "$run_model" "$output_dir" "$(( $(date +%s) - start_ts ))" ""
      log_info "All phases completed: $migration_name"
      ;;
    full)
      ensure_migration_connections "$idx"
      run_all_phases "$repo_name" "$source_conn_name" "$target_name" "$run_model" "$project_name" "$output_dir" "$idx"
      append_migration_summary "$migration_name" "completed" "$run_model" "$output_dir" "$(( $(date +%s) - start_ts ))" ""
      log_info "Full migration completed: $migration_name"
      ;;
    *)
      fail "Unsupported mode: $MODE"
      ;;
  esac
}

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
      capture|convert|generate|datamove|offload) ;;
      *) fail "Invalid --phase '$PHASE_NAME'. Use: capture|convert|generate|datamove|offload" ;;
    esac
  fi

  if [[ -n "$MODEL_NAME_INPUT" && "$MODE" != "phase" ]]; then
    fail "--model can only be used with --phase"
  fi
}

bootstrap_logging() {
  OUTPUT_ROOT="$(get_required_value '.defaults.paths.output_root' 'defaults.paths.output_root')"
  LOG_ROOT="$(get_required_value '.defaults.paths.log_root' 'defaults.paths.log_root')"

  mkdir -p "$OUTPUT_ROOT" "$LOG_ROOT"

  RUN_DIR="$OUTPUT_ROOT/run_$RUN_ID"
  mkdir -p "$RUN_DIR"

  RUN_LOG_FILE="$LOG_ROOT/migrate_${RUN_ID}.log"
  touch "$RUN_LOG_FILE"

  SDCLI_COMMAND_LOG="$RUN_DIR/sdcli_commands.log"
  SDCLI_SUMMARY_FILE="$RUN_DIR/sdcli_commands_summary.txt"
  MIGRATION_SUMMARY_FILE="$RUN_DIR/migration_summary.csv"

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
  log_info "Run directory: $RUN_DIR"
  log_info "Run log: $RUN_LOG_FILE"
  log_info "SDCLI command log: $SDCLI_COMMAND_LOG"
  log_info "Dry run mode: $DRY_RUN"

  if [[ "$MODE" == "init" ]]; then
    validate_config "false"
  else
    validate_config "true"
  fi
  log_info "Config validation passed"

  if ! $DRY_RUN; then
    require_command sdcli
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

main "$@"
