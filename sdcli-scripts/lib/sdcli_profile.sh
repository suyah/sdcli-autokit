#!/usr/bin/env bash
# SQL Developer process state. No shared-profile import or fallback.
SDCLI_PROFILE_DIR=""
PROFILE_LOCK_DIR=""
PROFILE_LOCK_HELD=false
PROFILE_IDENTITY=""

normalize_oracle_java_options() {
  local options="$1" result="" raw="" value="" quote="" character
  local index
  # JVM option variables accept single/double quotes within or around a token.
  # Inspect the unquoted token, but retain unrelated options verbatim. Do not
  # eval these values or remove wallet-looking text inside another property's value.
  for ((index = 0; index <= ${#options}; index++)); do
    character="${options:index:1}"
    if [[ -n "$quote" ]]; then
      raw+="$character"
      if [[ "$character" == "$quote" ]]; then quote=""; else value+="$character"; fi
    elif [[ "$character" == '"' || "$character" == "'" ]]; then
      quote="$character"
      raw+="$character"
    elif [[ -z "$character" || "$character" == [[:space:]] ]]; then
      if [[ -n "$raw" && "$value" != -Doracle.net.tns_admin=* ]]; then
        result+="${result:+ }$raw"
      fi
      raw=""
      value=""
    else
      raw+="$character"
      value+="$character"
    fi
  done
  [[ -z "$quote" ]] || { log_error 'Unbalanced quotes in Java option variable; correct the exported JVM options'; return 1; }
  printf '%s' "$result"
}

mode_uses_sdcli() {
  case "$MODE" in
    init|conn-setup|full|migrate) return 0 ;;
    phase)
      case "$PHASE_NAME" in capture|convert|generate|datamove) return 0 ;; esac
      ;;
  esac
  return 1
}

release_profile_lock() {
  $PROFILE_LOCK_HELD || return 0
  rm -f "$PROFILE_LOCK_DIR/owner"
  rmdir "$PROFILE_LOCK_DIR" 2>/dev/null || true
  PROFILE_LOCK_HELD=false
}

write_project_profile_state() {
  local state="$1" temporary
  temporary="$(mktemp "$SDCLI_PROFILE_DIR/.autokit-profile.XXXXXX")" || return 1
  printf '%s\t%s\n' "$PROFILE_IDENTITY" "$state" > "$temporary"
  mv "$temporary" "$SDCLI_PROFILE_DIR/.autokit-profile"
}

mark_project_profile_ready() {
  $DRY_RUN && return 0
  $PROFILE_LOCK_HELD || fail 'Cannot mark a project profile ready without its lock'
  write_project_profile_state ready
}

prepare_project_profile() {
  local data_root repository_user state_file stored_identity state extra
  require_active_repository_context
  [[ "$ACTIVE_MIGRATION_NAME" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]] \
    || fail 'Migration name must be a single path component using letters, digits, underscore, dot or hyphen'
  [[ "$PROJECT_ROOT" == /* ]] || fail 'defaults.paths.project_root must be absolute'
  data_root="${TOOL_DATA:-${PROJECT_ROOT%/*}}"
  [[ "$data_root" == /* && "$data_root" != / ]] || fail 'TOOL_DATA must be an absolute data directory'
  SDCLI_PROFILE_DIR="${data_root%/}/profiles/$ACTIVE_MIGRATION_NAME"
  log_info "SQL Developer project profile: $SDCLI_PROFILE_DIR"
  $DRY_RUN && return 0

  repository_user="$(get_required_value '.migration_repository.repo_user.user' 'migration_repository.repo_user.user')"
  PROFILE_IDENTITY="$(repository_lock_key "$ACTIVE_REPOSITORY_CONN|$repository_user|$ACTIVE_REPOSITORY_NAME")"
  (
    umask 077
    mkdir -p "${data_root%/}/profiles/.locks" "$SDCLI_PROFILE_DIR"
  )
  PROFILE_LOCK_DIR="${data_root%/}/profiles/.locks/$(repository_lock_key "$SDCLI_PROFILE_DIR").lock"
  if ! mkdir "$PROFILE_LOCK_DIR" 2>/dev/null; then
    fail "SQL Developer profile is already in use: $SDCLI_PROFILE_DIR. Remove $PROFILE_LOCK_DIR only after confirming its owning process is no longer running"
  fi
  PROFILE_LOCK_HELD=true
  printf 'pid=%s\nhost=%s\nmigration=%s\n' "$$" "$(hostname)" "$ACTIVE_MIGRATION_NAME" > "$PROFILE_LOCK_DIR/owner"

  state_file="$SDCLI_PROFILE_DIR/.autokit-profile"
  if [[ ! -f "$state_file" ]]; then
    [[ -z "$(find "$SDCLI_PROFILE_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ]] \
      || fail "Unmanaged project profile: $SDCLI_PROFILE_DIR. Back it up and move it aside before initializing a fresh profile"
    [[ "$MODE" == init ]] || fail "Project profile is not initialized; run ./migrate.sh $ACTIVE_MIGRATION_NAME --init first"
    write_project_profile_state pending
  fi
  IFS=$'\t' read -r stored_identity state extra < "$state_file"
  [[ "$stored_identity" == "$PROFILE_IDENTITY" && -z "$extra" && ( "$state" == pending || "$state" == ready ) ]] \
    || fail "Project repository configuration changed or profile state is invalid: $SDCLI_PROFILE_DIR. Back up and move this profile aside, then run named --init"
  if [[ "$MODE" == init ]]; then
    write_project_profile_state pending
  else
    [[ "$state" == ready ]] \
      || fail "Project initialization did not complete; retry ./migrate.sh $ACTIVE_MIGRATION_NAME --init"
  fi
}

initialize_project_preferences() {
  $DRY_RUN && return 0
  if [[ -z "$(find "$SDCLI_PROFILE_DIR" -type d -path '*/o.sqldeveloper' -print -quit)" ]]; then
    run_sdcli sdcli migration -help=init >/dev/null \
      || fail 'SQL Developer could not initialize the project preference directory'
  fi
  configure_sqldeveloper_file_output_option
}
