#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$ROOT_DIR/.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Error: .env file not found at $ENV_FILE" >&2
  exit 1
fi

set -a
source "$ENV_FILE"
set +a

CONTAINER_NAME="${CONTAINER_NAME_OVERRIDE:-${CONTAINER_NAME:?CONTAINER_NAME must be set in .env}}"
CONTAINER_HOSTNAME="${CONTAINER_HOSTNAME:?CONTAINER_HOSTNAME must be set in .env}"
IMAGE_REPOSITORY="${IMAGE_REPOSITORY:?IMAGE_REPOSITORY must be set in .env}"
DATA_VOLUME_NAME="${DATA_VOLUME_NAME_OVERRIDE:-${DATA_VOLUME_NAME:?DATA_VOLUME_NAME must be set in .env}}"
LOG_VOLUME_NAME="${LOG_VOLUME_NAME_OVERRIDE:-${LOG_VOLUME_NAME:?LOG_VOLUME_NAME must be set in .env}}"
HOME_DIR="${HOME_DIR:?HOME_DIR must be set in .env}"
SD_HOME="${SD_HOME:?SD_HOME must be set in .env}"
APP_USER="${APP_USER:?APP_USER must be set in .env}"
APP_GROUP="${APP_GROUP:?APP_GROUP must be set in .env}"
SQLDEVELOPER_FILE_OUTPUT_OPTION="${SQLDEVELOPER_FILE_OUTPUT_OPTION:-1}"
CONTAINER_ENGINE="${CONTAINER_ENGINE:-podman}"

SD_BIN="${SD_HOME%/}/sqldeveloper/bin/sdcli"
JTDS_TARGET_FILE="/u01/app/jtds-1.3.1.jar"
SDCLI_SCRIPTS_SRC="$ROOT_DIR/../sdcli-scripts"
SDCLI_SCRIPTS_DEST="${HOME_DIR%/}/sdcli-scripts"
INSTALLER_SRC="$ROOT_DIR/install-vendor.sh"

usage() {
  cat <<'USAGE'
Usage: run.sh --vendor-dir /absolute/path/to/rpms --accept-microsoft-eula

The RPM directory must contain SQL Developer, Oracle Instant Client Basic,
SQL*Plus, and Tools, plus msodbcsql18 and mssql-tools18 RPMs. It may also
contain their offline dependencies.
USAGE
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

container_engine() {
  "$CONTAINER_ENGINE" "$@"
}

require_value() {
  [[ $# -ge 2 && -n "$2" ]] || fail "missing value for $1"
}

VENDOR_DIR=""
ACCEPT_MICROSOFT_EULA=false

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --vendor-dir)
        require_value "$1" "${2:-}"
        VENDOR_DIR="$2"
        shift 2
        ;;
      --accept-microsoft-eula)
        ACCEPT_MICROSOFT_EULA=true
        shift
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

  [[ -n "$VENDOR_DIR" ]] || fail "--vendor-dir is required"
  [[ "$VENDOR_DIR" == /* ]] || fail "--vendor-dir must be an absolute path"
  [[ "$ACCEPT_MICROSOFT_EULA" == true ]] || fail "--accept-microsoft-eula is required"
}

require_vendor_rpm() {
  local label="$1"
  local pattern="$2"
  local matches=()

  shopt -s nullglob
  matches=("$VENDOR_DIR"/$pattern)
  shopt -u nullglob

  [[ ${#matches[@]} -eq 1 ]] || fail "expected exactly one $label RPM matching $pattern in $VENDOR_DIR"
  [[ -f "${matches[0]}" && ! -L "${matches[0]}" ]] || fail "$label RPM must be a regular file: ${matches[0]}"
}

validate_vendor_dir() {
  [[ -d "$VENDOR_DIR" ]] || fail "vendor RPM directory does not exist: $VENDOR_DIR"
  require_vendor_rpm "SQL Developer" 'sqldeveloper-*.noarch.rpm'
  require_vendor_rpm "Instant Client Basic" 'oracle-instantclient*-basic-*.x86_64.rpm'
  require_vendor_rpm "Instant Client SQL*Plus" 'oracle-instantclient*-sqlplus-*.x86_64.rpm'
  require_vendor_rpm "Instant Client Tools" 'oracle-instantclient*-tools-*.x86_64.rpm'
  require_vendor_rpm "Microsoft ODBC Driver 18" 'msodbcsql18-*.x86_64.rpm'
  require_vendor_rpm "Microsoft SQL Server tools" 'mssql-tools18-*.x86_64.rpm'
}

load_bundle_version() {
  local version_file="${VERSION_FILE:-$ROOT_DIR/../VERSION}"
  local version

  if [[ -n "${IMAGE_TAG_OVERRIDE:-}" ]]; then
    [[ "$IMAGE_TAG_OVERRIDE" =~ ^[A-Za-z0-9][A-Za-z0-9._/:@-]*$ ]] || fail "invalid IMAGE_TAG_OVERRIDE"
    IMAGE_NAME="$IMAGE_TAG_OVERRIDE"
    return
  fi

  [[ -f "$version_file" ]] || fail "VERSION file not found: $version_file"
  version="$(<"$version_file")"
  [[ "$version" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || fail "invalid bundle version in $version_file"
  IMAGE_NAME="$IMAGE_REPOSITORY:$version"
}

ensure_image() {
  container_engine image inspect "$IMAGE_NAME" >/dev/null 2>&1 || fail "image '$IMAGE_NAME' is not loaded; load or build it before running this command"
  IMAGE_ID="$(container_engine image inspect "$IMAGE_NAME" --format '{{.Id}}')"
}

ensure_volumes() {
  container_engine volume inspect "$DATA_VOLUME_NAME" >/dev/null 2>&1 || container_engine volume create "$DATA_VOLUME_NAME" >/dev/null
  container_engine volume inspect "$LOG_VOLUME_NAME" >/dev/null 2>&1 || container_engine volume create "$LOG_VOLUME_NAME" >/dev/null
}

container_is_running() {
  container_engine ps --filter "name=^${CONTAINER_NAME}$" --format '{{.Status}}' | grep -q '^Up'
}

start_or_reuse_container() {
  if container_engine container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
    local existing_image_id
    existing_image_id="$(container_engine container inspect "$CONTAINER_NAME" --format '{{.Image}}')"
    [[ "$existing_image_id" == "$IMAGE_ID" ]] || fail "container '$CONTAINER_NAME' uses another image; stop and remove it yourself before changing versions"

    if ! container_is_running; then
      echo "Starting existing container '$CONTAINER_NAME'..."
      container_engine start "$CONTAINER_NAME" >/dev/null
    fi
    return
  fi

  ensure_volumes

  local data_mount="${DATA_VOLUME_NAME}:/u01/data"
  local log_mount="${LOG_VOLUME_NAME}:/u01/log"
  local vendor_mount="${VENDOR_DIR}:/vendor-rpms:ro"
  command=(
    "$CONTAINER_ENGINE" run
    --restart=always
  )
  if [[ "$CONTAINER_ENGINE" == "podman" ]]; then
    data_mount+=":Z"
    log_mount+=":Z"
    vendor_mount+=",Z"
    command+=(--userns=keep-id)
  fi

  command+=(
    --network host
    -d
    --hostname "$CONTAINER_HOSTNAME"
    -v "$data_mount"
    -v "$log_mount"
    -v "$vendor_mount"
    --name "$CONTAINER_NAME"
    "$IMAGE_NAME"
  )

  echo "Creating container '$CONTAINER_NAME'..."
  "${command[@]}" >/dev/null
}

install_vendor_packages() {
  [[ -f "$INSTALLER_SRC" ]] || fail "vendor installer not found: $INSTALLER_SRC"
  container_engine cp "$INSTALLER_SRC" "$CONTAINER_NAME:/tmp/install-vendor.sh"

  if ! container_engine exec \
      --user root \
      --env "APP_USER=$APP_USER" \
      --env "APP_GROUP=$APP_GROUP" \
      --env "HOME_DIR=$HOME_DIR" \
      --env "SD_HOME=$SD_HOME" \
      "$CONTAINER_NAME" \
      bash /tmp/install-vendor.sh \
        --vendor-dir /vendor-rpms \
        --accept-microsoft-eula; then
    echo "Vendor package installation failed; stopping '$CONTAINER_NAME'." >&2
    container_engine stop --time 5 "$CONTAINER_NAME" >/dev/null || true
    exit 1
  fi
}

ensure_sqldeveloper_preferences() {
  container_engine exec \
    --env "HOME_DIR=$HOME_DIR" \
    --env "SQLDEVELOPER_FILE_OUTPUT_OPTION=$SQLDEVELOPER_FILE_OUTPUT_OPTION" \
    "$CONTAINER_NAME" \
    bash -lc '
      set -euo pipefail

      : "$HOME_DIR"
      : "$SQLDEVELOPER_FILE_OUTPUT_OPTION"

      prefs_root="$HOME_DIR/.sqldeveloper"
      if [[ ! -d "$prefs_root" ]]; then
        echo "Warning: SQL Developer preferences directory not found: $prefs_root"
        exit 0
      fi

      preference_file="$(find "$prefs_root" -type f -path "*/o.sqldeveloper/product-preferences.xml" | sort | head -n 1 || true)"
      if [[ -z "$preference_file" ]]; then
        echo "Warning: SQL Developer product-preferences.xml not found under: $prefs_root"
        exit 0
      fi

      tmp_file="$(mktemp "$preference_file.XXXXXX")"
      if ! awk -v output_option="$SQLDEVELOPER_FILE_OUTPUT_OPTION" '\''
        BEGIN {
          in_options = 0
          inserted = 0
        }
        $0 ~ /<hash n="oracle\.dbtools\.migration\.workbench\.core\.preferences\.MigrationWorkbenchOptions">/ {
          in_options = 1
        }
        in_options && $0 ~ /<value n="FileOutputOption"/ {
          if (!inserted) {
            match($0, /^[[:space:]]*/)
            indent = substr($0, RSTART, RLENGTH)
            print indent "<value n=\"FileOutputOption\" v=\"" output_option "\"/>"
            inserted = 1
          }
          next
        }
        in_options && $0 ~ /<value n="DefaultRepository"/ && !inserted {
          print
          match($0, /^[[:space:]]*/)
          indent = substr($0, RSTART, RLENGTH)
          print indent "<value n=\"FileOutputOption\" v=\"" output_option "\"/>"
          inserted = 1
          next
        }
        in_options && $0 ~ /<list n="MigrationRepositories">/ && !inserted {
          match($0, /^[[:space:]]*/)
          indent = substr($0, RSTART, RLENGTH)
          print indent "<value n=\"FileOutputOption\" v=\"" output_option "\"/>"
          inserted = 1
        }
        $0 ~ /<\/ide:preferences>/ && !in_options && !inserted {
          print "   <hash n=\"oracle.dbtools.migration.workbench.core.preferences.MigrationWorkbenchOptions\">"
          print "      <value n=\"FileOutputOption\" v=\"" output_option "\"/>"
          print "   </hash>"
          inserted = 1
        }
        {
          print
        }
        END {
          if (!inserted) {
            exit 2
          }
        }
      '\'' "$preference_file" > "$tmp_file"; then
        rm -f "$tmp_file"
        echo "Warning: SQL Developer MigrationWorkbenchOptions block not found in: $preference_file"
        exit 0
      fi

      if cmp -s "$tmp_file" "$preference_file"; then
        rm -f "$tmp_file"
        echo "SQL Developer FileOutputOption already configured: $preference_file"
        exit 0
      fi

      cat "$tmp_file" > "$preference_file"
      rm -f "$tmp_file"
      echo "Configured SQL Developer FileOutputOption=$SQLDEVELOPER_FILE_OUTPUT_OPTION: $preference_file"
    '
}

initialize_sqldeveloper_preferences() {
  # Start SQL Developer once before patching its preference. Some releases
  # create product-preferences.xml only after driver registration; migrate.sh
  # repeats the idempotent preference update after that command.
  container_engine exec "$CONTAINER_NAME" bash -lc "'$SD_BIN' --help >/dev/null 2>&1" || {
    echo "Error: sdcli did not start while initializing preferences" >&2
    return 1
  }
}

sync_sdcli_scripts() {
  [[ -d "$SDCLI_SCRIPTS_SRC" ]] || fail "sdcli-scripts directory not found: $SDCLI_SCRIPTS_SRC"

  if container_engine exec "$CONTAINER_NAME" bash -lc "test -f '$SDCLI_SCRIPTS_DEST/migrate.sh' && test -f '$SDCLI_SCRIPTS_DEST/config.yaml' && test -f '$SDCLI_SCRIPTS_DEST/lib/generate_validation_report.py'"; then
    return
  fi

  container_engine exec "$CONTAINER_NAME" bash -lc "mkdir -p '$SDCLI_SCRIPTS_DEST'"
  container_engine cp "$SDCLI_SCRIPTS_SRC/." "$CONTAINER_NAME:$SDCLI_SCRIPTS_DEST"
}

check_tools() {
  local tool
  for tool in sdcli sqlcmd bcp sqlplus sqlldr jq yq python3; do
    container_engine exec "$CONTAINER_NAME" bash -lc "command -v '$tool' >/dev/null" || {
      echo "Error: $tool is missing after installation" >&2
      return 1
    }
  done
  container_engine exec "$CONTAINER_NAME" bash -lc 'sqlcmd -? >/dev/null 2>&1' || { echo "Error: sqlcmd did not start" >&2; return 1; }
  container_engine exec "$CONTAINER_NAME" bash -lc 'bcp -v >/dev/null 2>&1' || { echo "Error: bcp did not start" >&2; return 1; }
  container_engine exec "$CONTAINER_NAME" bash -lc 'sqlplus -version >/dev/null 2>&1' || { echo "Error: sqlplus did not start" >&2; return 1; }
  container_engine exec "$CONTAINER_NAME" bash -lc 'sqlldr -help >/dev/null 2>&1' || { echo "Error: sqlldr did not start" >&2; return 1; }
  container_engine exec "$CONTAINER_NAME" bash -lc "sdcli --help >/dev/null 2>&1" || { echo "Error: sdcli did not start" >&2; return 1; }
  container_engine exec "$CONTAINER_NAME" bash -lc "test -f '$JTDS_TARGET_FILE'" || { echo "Error: jTDS jar is missing: $JTDS_TARGET_FILE" >&2; return 1; }
  container_engine exec "$CONTAINER_NAME" bash -lc "test -f '$SDCLI_SCRIPTS_DEST/migrate.sh'" || { echo "Error: migration scripts are missing" >&2; return 1; }
  container_engine exec "$CONTAINER_NAME" bash -lc "test -f '$SDCLI_SCRIPTS_DEST/lib/generate_validation_report.py'" || { echo "Error: validation report program is missing" >&2; return 1; }
}

if [[ "${RUN_SH_SOURCE_ONLY:-false}" == "true" ]]; then
  return 0 2>/dev/null || exit 0
fi

parse_args "$@"
[[ "$SQLDEVELOPER_FILE_OUTPUT_OPTION" =~ ^[0-9]+$ ]] || fail "SQLDEVELOPER_FILE_OUTPUT_OPTION must be a non-negative integer"
case "$CONTAINER_ENGINE" in
  podman|docker) ;;
  *) fail "CONTAINER_ENGINE must be podman or docker, not '$CONTAINER_ENGINE'" ;;
esac
command -v "$CONTAINER_ENGINE" >/dev/null 2>&1 || fail "$CONTAINER_ENGINE command not found"
validate_vendor_dir
load_bundle_version
ensure_image
start_or_reuse_container
install_vendor_packages
sync_sdcli_scripts
initialize_sqldeveloper_preferences
ensure_sqldeveloper_preferences

if ! check_tools; then
  container_engine stop --time 5 "$CONTAINER_NAME" >/dev/null || true
  exit 1
fi

echo "Container '$CONTAINER_NAME' is ready with image '$IMAGE_NAME'."
