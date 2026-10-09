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

CONTAINER_NAME="${CONTAINER_NAME:?CONTAINER_NAME must be set in .env}"
CONTAINER_HOSTNAME="${CONTAINER_HOSTNAME:?CONTAINER_HOSTNAME must be set in .env}"
IMAGE_REPOSITORY="${IMAGE_REPOSITORY:?IMAGE_REPOSITORY must be set in .env}"
DATA_VOLUME_NAME="${DATA_VOLUME_NAME:?DATA_VOLUME_NAME must be set in .env}"
LOG_VOLUME_NAME="${LOG_VOLUME_NAME:?LOG_VOLUME_NAME must be set in .env}"
HOME_DIR="${HOME_DIR:?HOME_DIR must be set in .env}"
SD_HOME="${SD_HOME:?SD_HOME must be set in .env}"
APP_USER="${APP_USER:?APP_USER must be set in .env}"
APP_GROUP="${APP_GROUP:?APP_GROUP must be set in .env}"

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

  [[ -f "$version_file" ]] || fail "VERSION file not found: $version_file"
  version="$(<"$version_file")"
  [[ "$version" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || fail "invalid bundle version in $version_file"
  IMAGE_NAME="$IMAGE_REPOSITORY:$version"
}

ensure_image() {
  podman image exists "$IMAGE_NAME" || fail "image '$IMAGE_NAME' is not loaded; run podman load -i image.tar first"
  IMAGE_ID="$(podman image inspect "$IMAGE_NAME" --format '{{.Id}}')"
}

ensure_volumes() {
  podman volume inspect "$DATA_VOLUME_NAME" >/dev/null 2>&1 || podman volume create "$DATA_VOLUME_NAME" >/dev/null
  podman volume inspect "$LOG_VOLUME_NAME" >/dev/null 2>&1 || podman volume create "$LOG_VOLUME_NAME" >/dev/null
}

container_is_running() {
  podman ps --filter "name=^${CONTAINER_NAME}$" --format '{{.Status}}' | grep -q '^Up'
}

start_or_reuse_container() {
  if podman container exists "$CONTAINER_NAME"; then
    local existing_image_id
    existing_image_id="$(podman container inspect "$CONTAINER_NAME" --format '{{.Image}}')"
    [[ "$existing_image_id" == "$IMAGE_ID" ]] || fail "container '$CONTAINER_NAME' uses another image; stop and remove it yourself before changing versions"

    if ! container_is_running; then
      echo "Starting existing container '$CONTAINER_NAME'..."
      podman start "$CONTAINER_NAME" >/dev/null
    fi
    return
  fi

  ensure_volumes

  command=(
    podman run
    --restart=always
    --userns=keep-id
    --network host
    -d
    --hostname "$CONTAINER_HOSTNAME"
    -v "${DATA_VOLUME_NAME}:/u01/data:Z"
    -v "${LOG_VOLUME_NAME}:/u01/log:Z"
    -v "${VENDOR_DIR}:/vendor-rpms:ro,Z"
    --name "$CONTAINER_NAME"
    "$IMAGE_NAME"
  )

  echo "Creating container '$CONTAINER_NAME'..."
  "${command[@]}" >/dev/null
}

install_vendor_packages() {
  [[ -f "$INSTALLER_SRC" ]] || fail "vendor installer not found: $INSTALLER_SRC"
  podman cp "$INSTALLER_SRC" "$CONTAINER_NAME:/tmp/install-vendor.sh"

  if ! podman exec \
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
    podman stop --time 5 "$CONTAINER_NAME" >/dev/null || true
    exit 1
  fi
}

ensure_sqldeveloper_preferences() {
  podman exec \
    --env "HOME_DIR=$HOME_DIR" \
    "$CONTAINER_NAME" \
    bash -lc '
      set -euo pipefail

      : "$HOME_DIR"

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

      if grep -q "<value n=\"FileOutputOption\" v=\"2\"/>" "$preference_file"; then
        echo "SQL Developer FileOutputOption already configured: $preference_file"
        exit 0
      fi

      tmp_file="$(mktemp "$preference_file.XXXXXX")"
      if ! awk '\''
        BEGIN {
          in_options = 0
          inserted = 0
        }
        $0 ~ /<hash n="oracle\.dbtools\.migration\.workbench\.core\.preferences\.MigrationWorkbenchOptions">/ {
          in_options = 1
        }
        in_options && $0 ~ /<value n="DefaultRepository"/ && !inserted {
          print
          match($0, /^[[:space:]]*/)
          indent = substr($0, RSTART, RLENGTH)
          print indent "<value n=\"FileOutputOption\" v=\"2\"/>"
          inserted = 1
          next
        }
        in_options && $0 ~ /<list n="MigrationRepositories">/ && !inserted {
          match($0, /^[[:space:]]*/)
          indent = substr($0, RSTART, RLENGTH)
          print indent "<value n=\"FileOutputOption\" v=\"2\"/>"
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

      cat "$tmp_file" > "$preference_file"
      rm -f "$tmp_file"
      echo "Configured SQL Developer FileOutputOption: $preference_file"
    '
}

sync_sdcli_scripts() {
  [[ -d "$SDCLI_SCRIPTS_SRC" ]] || fail "sdcli-scripts directory not found: $SDCLI_SCRIPTS_SRC"

  if podman exec "$CONTAINER_NAME" bash -lc "test -f '$SDCLI_SCRIPTS_DEST/migrate.sh' && test -f '$SDCLI_SCRIPTS_DEST/config.yaml'"; then
    return
  fi

  podman exec "$CONTAINER_NAME" bash -lc "mkdir -p '$SDCLI_SCRIPTS_DEST'"
  podman cp "$SDCLI_SCRIPTS_SRC/." "$CONTAINER_NAME:$SDCLI_SCRIPTS_DEST"
}

check_tools() {
  local tool
  for tool in sdcli sqlcmd bcp sqlplus sqlldr jq yq; do
    podman exec "$CONTAINER_NAME" bash -lc "command -v '$tool' >/dev/null" || {
      echo "Error: $tool is missing after installation" >&2
      return 1
    }
  done
  podman exec "$CONTAINER_NAME" bash -lc 'sqlcmd -? >/dev/null 2>&1' || { echo "Error: sqlcmd did not start" >&2; return 1; }
  podman exec "$CONTAINER_NAME" bash -lc 'bcp -v >/dev/null 2>&1' || { echo "Error: bcp did not start" >&2; return 1; }
  podman exec "$CONTAINER_NAME" bash -lc 'sqlplus -version >/dev/null 2>&1' || { echo "Error: sqlplus did not start" >&2; return 1; }
  podman exec "$CONTAINER_NAME" bash -lc 'sqlldr -help >/dev/null 2>&1' || { echo "Error: sqlldr did not start" >&2; return 1; }
  podman exec "$CONTAINER_NAME" bash -lc "sdcli --help >/dev/null 2>&1" || { echo "Error: sdcli did not start" >&2; return 1; }
  podman exec "$CONTAINER_NAME" bash -lc "test -f '$JTDS_TARGET_FILE'" || { echo "Error: jTDS jar is missing: $JTDS_TARGET_FILE" >&2; return 1; }
  podman exec "$CONTAINER_NAME" bash -lc "test -f '$SDCLI_SCRIPTS_DEST/migrate.sh'" || { echo "Error: migration scripts are missing" >&2; return 1; }
}

if [[ "${RUN_SH_SOURCE_ONLY:-false}" == "true" ]]; then
  return 0 2>/dev/null || exit 0
fi

parse_args "$@"
validate_vendor_dir
load_bundle_version
ensure_image
start_or_reuse_container
install_vendor_packages
ensure_sqldeveloper_preferences
sync_sdcli_scripts

if ! check_tools; then
  podman stop --time 5 "$CONTAINER_NAME" >/dev/null || true
  exit 1
fi

echo "Container '$CONTAINER_NAME' is ready with image '$IMAGE_NAME'."
