#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIGRATE_SH_SOURCE_ONLY=true source "$SCRIPT_DIR/migrate.sh"
CONFIG_FILE="${AUTOKIT_CONFIG_FILE:-$CONFIG_FILE}"

usage() {
  cat <<'USAGE'
Usage: export-source-schema.sh <migration_name> [--output <absolute-directory>]

Exports the configured SQL Server source schema using customer-installed
SqlPackage. The export contains schema definitions only; it does not export
table data or alter the source database.
USAGE
}

cleanup() {
  [[ -n "${RAW_DIAGNOSTIC_FILE:-}" ]] && rm -f -- "$RAW_DIAGNOSTIC_FILE"
}

parse_args() {
  [[ $# -ge 1 ]] || {
    usage >&2
    exit 2
  }

  MIGRATION_NAME="$1"
  shift
  OUTPUT_DIR=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --output)
        [[ -n "${2:-}" ]] || fail "missing value for --output"
        OUTPUT_DIR="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        fail "unknown option: $1"
        ;;
    esac
  done

  [[ -n "$MIGRATION_NAME" ]] || fail "migration name must not be empty"
  [[ -z "$OUTPUT_DIR" || "$OUTPUT_DIR" == /* ]] || fail "--output must be an absolute path"
}

resolve_output_dir() {
  local project_root="$1"

  if [[ -n "$OUTPUT_DIR" ]]; then
    printf '%s\n' "$OUTPUT_DIR"
    return 0
  fi

  [[ "$project_root" == /* ]] || fail "defaults.paths.project_root must be an absolute path"
  printf '%s/%s/source-schema/%s\n' \
    "${project_root%/}" "$MIGRATION_NAME" "$(date -u '+%Y%m%dT%H%M%SZ')"
}

append_tls_args() {
  local mode="$1"

  case "$mode" in
    strict)
      SQLPACKAGE_ARGS+=(/SourceEncryptConnection:Strict)
      ;;
    trust)
      SQLPACKAGE_ARGS+=(/SourceEncryptConnection:True /SourceTrustServerCertificate:True)
      ;;
    optional)
      SQLPACKAGE_ARGS+=(/SourceEncryptConnection:Optional)
      ;;
    *)
      fail "internal error: unsupported SQL Server TLS mode '$mode'"
      ;;
  esac
}

write_manifest() {
  local output_dir="$1"
  local source_host="$2"
  local source_port="$3"
  local source_database="$4"
  local tls_mode="$5"
  local sqlpackage_version

  sqlpackage_version="$(sqlpackage /Version 2>/dev/null | head -n 1 | tr -d '\r')"
  sqlpackage_version="${sqlpackage_version:-unknown}"

  cat > "$output_dir/manifest.txt" <<EOF
Migration: $MIGRATION_NAME
Source: $source_host:$source_port/$source_database
TLS mode: $tls_mode
SqlPackage version: $sqlpackage_version
Export: schema-only (ExtractAllTableData=False)
SQL tree: sql/
EOF
  chmod 0600 "$output_dir/manifest.txt"
}

main() {
  local migration_index source_type source_conn source_user source_password
  local parsed_source source_host source_port source_database tls_mode project_root
  local sql_dir diagnostic_file

  parse_args "$@"
  [[ -f "$CONFIG_FILE" ]] || fail "Config file not found: $CONFIG_FILE"
  require_command yq
  require_command sqlpackage

  migration_index="$(get_migration_index "$MIGRATION_NAME")"
  source_type="$(to_lower "$(get_required_value '.defaults.source.type' 'defaults.source.type')")"
  [[ "$source_type" == "sqlserver" ]] || fail "Source schema export supports sqlserver only; configured source type is '$source_type'"

  source_conn="$(migration_required_value "$migration_index" source conn)"
  source_user="$(migration_required_value "$migration_index" source user)"
  source_password="$(migration_secret_value "$migration_index" source password)"
  validate_single_line_secret "migrations[$migration_index].source.password" "$source_password"
  parsed_source="$(parse_source_conn "$source_conn")"
  IFS='|' read -r source_host source_port source_database <<< "$parsed_source"
  tls_mode="$(normalize_bcp_tls_mode "$(get_required_value '.defaults.source.bcp_tls_mode' 'defaults.source.bcp_tls_mode')")"
  project_root="$(get_required_value '.defaults.paths.project_root' 'defaults.paths.project_root')"
  OUTPUT_DIR="$(resolve_output_dir "$project_root")"

  [[ ! -e "$OUTPUT_DIR" ]] || fail "output directory already exists: $OUTPUT_DIR"
  mkdir -p "$(dirname "$OUTPUT_DIR")"
  umask 077
  mkdir "$OUTPUT_DIR"
  chmod 0700 "$OUTPUT_DIR"
  sql_dir="$OUTPUT_DIR/sql"
  diagnostic_file="$OUTPUT_DIR/sqlpackage-extract.log"
  RAW_DIAGNOSTIC_FILE="$(mktemp "${TMPDIR:-/tmp}/sqlpackage-extract.XXXXXX")"
  trap cleanup EXIT HUP INT TERM

  SQLPACKAGE_ARGS=(
    /Action:Extract
    "/TargetFile:$sql_dir"
    /p:ExtractAllTableData=False
    /p:ExtractTarget=SchemaObjectType
    /p:VerifyExtraction=True
    /SourceServerName:"$source_host,$source_port"
    /SourceDatabaseName:"$source_database"
    /SourceUser:"$source_user"
    /SourcePassword:"$source_password"
  )
  append_tls_args "$tls_mode"

  log_info "Exporting SQL Server source schema for migration '$MIGRATION_NAME'"
  log_info "Source: $source_host:$source_port/$source_database"
  log_info "TLS mode: $tls_mode"
  if ! sqlpackage "${SQLPACKAGE_ARGS[@]}" > "$RAW_DIAGNOSTIC_FILE" 2>&1; then
    redact_sdcli_output < "$RAW_DIAGNOSTIC_FILE" > "$diagnostic_file"
    chmod 0600 "$diagnostic_file"
    fail "SqlPackage schema extract failed; diagnostic: $diagnostic_file"
  fi

  redact_sdcli_output < "$RAW_DIAGNOSTIC_FILE" > "$diagnostic_file"
  chmod 0600 "$diagnostic_file"
  if ! find "$sql_dir" -type f -name '*.sql' -print -quit | grep -q .; then
    fail "SqlPackage completed without generating a SQL schema tree: $sql_dir"
  fi

  write_manifest "$OUTPUT_DIR" "$source_host" "$source_port" "$source_database" "$tls_mode"
  log_info "Source schema export completed: $OUTPUT_DIR"
}

main "$@"
