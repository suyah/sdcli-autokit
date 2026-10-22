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
BUNDLE_VERSION=""

usage() {
  cat <<'USAGE'
Usage: run.sh --vendor-dir /absolute/path/to/rpms --accept-microsoft-eula

The RPM directory must contain SQL Developer 26.2, Oracle Instant Client Basic,
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
    BUNDLE_VERSION="$IMAGE_TAG_OVERRIDE"
    return
  fi

  [[ -f "$version_file" ]] || fail "VERSION file not found: $version_file"
  version="$(<"$version_file")"
  [[ "$version" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || fail "invalid bundle version in $version_file"
  IMAGE_NAME="$IMAGE_REPOSITORY:$version"
  BUNDLE_VERSION="$version"
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
    if ! container_is_running; then
      echo "Starting existing container '$CONTAINER_NAME'..."
      container_engine start "$CONTAINER_NAME" >/dev/null
    fi
    if [[ "$existing_image_id" != "$IMAGE_ID" ]]; then
      echo "Preserving customer configuration before image replacement..."
      prepare_persistent_user_state
      fail "container '$CONTAINER_NAME' uses another image; customer state is preserved under $TOOL_DATA, so stop and remove the container before changing versions"
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

check_sdcli_startup() {
  container_engine exec \
    --env "TOOL_DATA=$TOOL_DATA" \
    --env "SDCLI_CHECK_BIN=$SD_BIN" \
    "$CONTAINER_NAME" bash -lc '
      set -euo pipefail
      umask 077
      check_profile="$(mktemp -d "${TOOL_DATA%/}/.sdcli-check.XXXXXX")"
      trap '\''rm -rf -- "$check_profile"'\'' EXIT
      IDE_USER_DIR="$check_profile" "$SDCLI_CHECK_BIN" --help >/dev/null 2>&1
    ' || { echo "Error: sdcli did not start with an isolated profile" >&2; return 1; }
}

prepare_persistent_user_state() {
  container_engine exec \
    --user root \
    --env "APP_USER=$APP_USER" \
    --env "APP_GROUP=$APP_GROUP" \
    --env "HOME_DIR=$HOME_DIR" \
    --env "SDCLI_SCRIPTS_DEST=$SDCLI_SCRIPTS_DEST" \
    --env "TOOL_DATA=$TOOL_DATA" \
    --env "TOOL_LOG=$TOOL_LOG" \
    "$CONTAINER_NAME" bash -lc '
      set -euo pipefail

      preferences_link="$HOME_DIR/.sqldeveloper"
      preferences_dir="${TOOL_DATA%/}/sqldeveloper"
      config_link="$SDCLI_SCRIPTS_DEST/config.yaml"
      config_dir="${TOOL_DATA%/}/config"
      persistent_config="$config_dir/config.yaml"
      mkdir -p "${TOOL_DATA%/}" "${TOOL_LOG%/}" "$SDCLI_SCRIPTS_DEST"
      chown "$APP_USER:$APP_GROUP" "${TOOL_DATA%/}" "${TOOL_LOG%/}"

      if [[ -L "$preferences_link" ]]; then
        [[ "$(readlink "$preferences_link")" == "$preferences_dir" ]] || {
          echo "Error: $preferences_link points outside the managed data directory" >&2
          exit 1
        }
      elif [[ -e "$preferences_link" ]]; then
        if [[ -d "$preferences_dir" && -n "$(find "$preferences_dir" -mindepth 1 -print -quit)" ]]; then
          if [[ -n "$(find "$preferences_link" -mindepth 1 -print -quit)" ]]; then
            echo "Error: SQL Developer preferences exist in both $preferences_link and $preferences_dir; reconcile them manually" >&2
            exit 1
          fi
          rm -rf -- "$preferences_link"
        else
          rm -rf -- "$preferences_dir"
          mv "$preferences_link" "$preferences_dir"
        fi
      fi

      mkdir -p "$preferences_dir"
      if [[ ! -L "$preferences_link" ]]; then
        ln -s "$preferences_dir" "$preferences_link"
      fi
      chown -R "$APP_USER:$APP_GROUP" "$preferences_dir"
      chown -h "$APP_USER:$APP_GROUP" "$preferences_link"

      mkdir -p "$config_dir"
      if [[ -L "$config_link" ]]; then
        [[ "$(readlink "$config_link")" == "$persistent_config" ]] || {
          echo "Error: $config_link points outside the managed data directory" >&2
          exit 1
        }
      elif [[ -e "$config_link" ]]; then
        if [[ -e "$persistent_config" ]]; then
          cmp -s "$config_link" "$persistent_config" || {
            echo "Error: config.yaml exists in both $SDCLI_SCRIPTS_DEST and $persistent_config with different content; reconcile them manually" >&2
            exit 1
          }
          rm -f -- "$config_link"
        else
          mv "$config_link" "$persistent_config"
        fi
      fi
      if [[ -f "$persistent_config" && ! -L "$config_link" ]]; then
        ln -s "$persistent_config" "$config_link"
      fi
      chown -R "$APP_USER:$APP_GROUP" "$config_dir"
      [[ ! -L "$config_link" ]] || chown -h "$APP_USER:$APP_GROUP" "$config_link"
      [[ ! -f "$persistent_config" ]] || chmod 0600 "$persistent_config"
    '
}

sync_sdcli_scripts() {
  local required_file stage_dir
  local -a required_files=(
    migrate.sh
    config.example.yaml
    lib/generate_validation_report.py
    lib/sqlplus_deploy.sh
    lib/sdcli_profile.sh
    templates/product-preferences.xml
  )

  [[ -d "$SDCLI_SCRIPTS_SRC" ]] || fail "sdcli-scripts directory not found: $SDCLI_SCRIPTS_SRC"
  [[ -n "$BUNDLE_VERSION" ]] || fail "bundle version is not loaded"
  for required_file in "${required_files[@]}"; do
    [[ -f "$SDCLI_SCRIPTS_SRC/$required_file" ]] \
      || fail "required migration program file not found: $SDCLI_SCRIPTS_SRC/$required_file"
  done
  [[ -d "$SDCLI_SCRIPTS_SRC/lib" ]] || fail "migration library directory not found: $SDCLI_SCRIPTS_SRC/lib"
  [[ -d "$SDCLI_SCRIPTS_SRC/templates" ]] || fail "migration template directory not found: $SDCLI_SCRIPTS_SRC/templates"

  # The vendor installer can create SQL Developer preferences as root. Running
  # the shared state preparation here keeps migration, conflict detection, and
  # ownership repair in one place.
  prepare_persistent_user_state

  stage_dir="${SDCLI_SCRIPTS_DEST}.stage.$$"
  container_engine exec \
    --user root \
    --env "STAGE_DIR=$stage_dir" \
    "$CONTAINER_NAME" bash -lc 'rm -rf -- "$STAGE_DIR" && mkdir -p "$STAGE_DIR/lib" "$STAGE_DIR/templates"'
  container_engine cp "$SDCLI_SCRIPTS_SRC/migrate.sh" "$CONTAINER_NAME:$stage_dir/migrate.sh"
  container_engine cp "$SDCLI_SCRIPTS_SRC/config.example.yaml" "$CONTAINER_NAME:$stage_dir/config.example.yaml"
  container_engine cp "$SDCLI_SCRIPTS_SRC/lib/." "$CONTAINER_NAME:$stage_dir/lib"
  container_engine cp "$SDCLI_SCRIPTS_SRC/templates/." "$CONTAINER_NAME:$stage_dir/templates"

  container_engine exec \
    --user root \
    --env "APP_USER=$APP_USER" \
    --env "APP_GROUP=$APP_GROUP" \
    --env "STAGE_DIR=$stage_dir" \
    --env "DEST_DIR=$SDCLI_SCRIPTS_DEST" \
    --env "SCRIPT_BUNDLE_VERSION=$BUNDLE_VERSION" \
    --env "TOOL_DATA=$TOOL_DATA" \
    "$CONTAINER_NAME" bash -lc '
      set -euo pipefail

      for required_file in \
        migrate.sh \
        config.example.yaml \
        lib/generate_validation_report.py \
        lib/sqlplus_deploy.sh \
        lib/sdcli_profile.sh \
        templates/product-preferences.xml; do
        test -f "$STAGE_DIR/$required_file" || {
          echo "Error: staged migration program file is missing: $required_file" >&2
          exit 1
        }
      done

      mkdir -p "$DEST_DIR"
      rm -rf -- "$DEST_DIR/lib.next" "$DEST_DIR/templates.next"
      mv "$STAGE_DIR/lib" "$DEST_DIR/lib.next"
      mv "$STAGE_DIR/templates" "$DEST_DIR/templates.next"
      install -m 0755 "$STAGE_DIR/migrate.sh" "$DEST_DIR/migrate.sh.next"
      install -m 0644 "$STAGE_DIR/config.example.yaml" "$DEST_DIR/config.example.yaml.next"

      rm -rf -- "$DEST_DIR/lib" "$DEST_DIR/templates"
      mv "$DEST_DIR/lib.next" "$DEST_DIR/lib"
      mv "$DEST_DIR/templates.next" "$DEST_DIR/templates"
      mv "$DEST_DIR/migrate.sh.next" "$DEST_DIR/migrate.sh"
      mv "$DEST_DIR/config.example.yaml.next" "$DEST_DIR/config.example.yaml"

      chmod 0755 "$DEST_DIR/migrate.sh"
      find "$DEST_DIR/lib" "$DEST_DIR/templates" -type f -exec chmod 0644 {} +
      for executable in bcp load_wrappers.sh sqlldr sqlplus; do
        [[ ! -f "$DEST_DIR/lib/$executable" ]] || chmod 0755 "$DEST_DIR/lib/$executable"
      done
      chmod 0644 "$DEST_DIR/config.example.yaml"

      persistent_config_dir="${TOOL_DATA%/}/config"
      persistent_config="$persistent_config_dir/config.yaml"
      mkdir -p "$persistent_config_dir"
      if [[ -L "$DEST_DIR/config.yaml" ]]; then
        [[ "$(readlink "$DEST_DIR/config.yaml")" == "$persistent_config" ]] || {
          echo "Error: $DEST_DIR/config.yaml points outside the managed data directory" >&2
          exit 1
        }
      elif [[ -e "$DEST_DIR/config.yaml" ]]; then
        echo "Error: $DEST_DIR/config.yaml was not prepared for persistent storage" >&2
        exit 1
      fi
      if [[ ! -f "$persistent_config" ]]; then
        install -m 0600 "$DEST_DIR/config.example.yaml" "$persistent_config"
      fi
      if [[ ! -L "$DEST_DIR/config.yaml" ]]; then
        ln -s "$persistent_config" "$DEST_DIR/config.yaml"
      fi

      printf "%s\n" "$SCRIPT_BUNDLE_VERSION" > "$DEST_DIR/.autokit-script-version.next"
      mv "$DEST_DIR/.autokit-script-version.next" "$DEST_DIR/.autokit-script-version"
      chown "$APP_USER:$APP_GROUP" "$DEST_DIR/migrate.sh" "$DEST_DIR/config.example.yaml" "$DEST_DIR/.autokit-script-version"
      chown -R "$APP_USER:$APP_GROUP" "$DEST_DIR/lib" "$DEST_DIR/templates" "$persistent_config_dir"
      chown -h "$APP_USER:$APP_GROUP" "$DEST_DIR/config.yaml"
      chmod 0600 "$persistent_config"
      rm -rf -- "$STAGE_DIR"
    '
}

check_tools() {
  local tool
  for tool in sdcli sqlcmd bcp sqlplus sqlldr jq yq python3 strace; do
    container_engine exec "$CONTAINER_NAME" bash -lc "command -v '$tool' >/dev/null" || {
      echo "Error: $tool is missing after installation" >&2
      return 1
    }
  done
  container_engine exec "$CONTAINER_NAME" bash -lc 'sqlcmd -? >/dev/null 2>&1' || { echo "Error: sqlcmd did not start" >&2; return 1; }
  container_engine exec "$CONTAINER_NAME" bash -lc 'bcp -v >/dev/null 2>&1' || { echo "Error: bcp did not start" >&2; return 1; }
  container_engine exec "$CONTAINER_NAME" bash -lc 'sqlplus -version >/dev/null 2>&1' || { echo "Error: sqlplus did not start" >&2; return 1; }
  container_engine exec "$CONTAINER_NAME" bash -lc 'sqlldr -help >/dev/null 2>&1' || { echo "Error: sqlldr did not start" >&2; return 1; }
  check_sdcli_startup || return 1
  container_engine exec "$CONTAINER_NAME" bash -lc "test -f '$JTDS_TARGET_FILE'" || { echo "Error: jTDS jar is missing: $JTDS_TARGET_FILE" >&2; return 1; }
  container_engine exec "$CONTAINER_NAME" bash -lc "test -f '$SDCLI_SCRIPTS_DEST/migrate.sh'" || { echo "Error: migration scripts are missing" >&2; return 1; }
  container_engine exec "$CONTAINER_NAME" bash -lc "test -f '$SDCLI_SCRIPTS_DEST/lib/sqlplus_deploy.sh'" || { echo "Error: SQL*Plus deploy helper library is missing" >&2; return 1; }
  container_engine exec "$CONTAINER_NAME" bash -lc "test -f '$SDCLI_SCRIPTS_DEST/lib/sdcli_profile.sh'" || { echo "Error: SQL Developer profile helper library is missing" >&2; return 1; }
  container_engine exec "$CONTAINER_NAME" bash -lc "test -f '$SDCLI_SCRIPTS_DEST/templates/product-preferences.xml'" || { echo "Error: SQL Developer preferences template is missing" >&2; return 1; }
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
prepare_persistent_user_state
install_vendor_packages
sync_sdcli_scripts
if ! check_tools; then
  container_engine stop --time 5 "$CONTAINER_NAME" >/dev/null || true
  exit 1
fi

echo "Container '$CONTAINER_NAME' is ready with image '$IMAGE_NAME'."
