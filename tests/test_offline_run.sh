#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

RUN_SH_SOURCE_ONLY=true source "$REPO_ROOT/deployment/run.sh"

assert_mode() {
  local path="$1"
  local expected="$2"
  local actual
  actual="$(stat -f '%Lp' "$path" 2>/dev/null || stat -c '%a' "$path")"
  if [[ "$actual" != "$expected" ]]; then
    echo "unexpected mode for $path: expected $expected, got $actual" >&2
    exit 1
  fi
}

vendor_dir="$tmpdir/vendor-rpms"
mkdir -p "$vendor_dir"
touch \
  "$vendor_dir/sqldeveloper-26.2.0-186.2220.noarch.rpm" \
  "$vendor_dir/oracle-instantclient23.9-basic-23.9.x86_64.rpm" \
  "$vendor_dir/oracle-instantclient23.9-sqlplus-23.9.x86_64.rpm" \
  "$vendor_dir/oracle-instantclient23.9-tools-23.9.x86_64.rpm" \
  "$vendor_dir/msodbcsql18-18.5.x86_64.rpm" \
  "$vendor_dir/mssql-tools18-18.4.x86_64.rpm"

VENDOR_DIR="$vendor_dir"
validate_vendor_dir

version_file="$tmpdir/VERSION"
printf '1.2.3\n' > "$version_file"
VERSION_FILE="$version_file"
load_bundle_version
[[ "$IMAGE_NAME" == "sdcli-autokit:1.2.3" ]]

rm "$vendor_dir/msodbcsql18-18.5.x86_64.rpm"
if (validate_vendor_dir) >/dev/null 2>&1; then
  echo "missing vendor RPM unexpectedly passed validation" >&2
  exit 1
fi

grep -F -- '--vendor-dir /vendor-rpms' "$REPO_ROOT/deployment/run.sh" >/dev/null
grep -F -- 'vendor_mount="${VENDOR_DIR}:/vendor-rpms:ro"' "$REPO_ROOT/deployment/run.sh" >/dev/null
grep -F -- 'vendor_mount+=",Z"' "$REPO_ROOT/deployment/run.sh" >/dev/null
grep -F -- '--disablerepo=' "$REPO_ROOT/deployment/install-vendor.sh" >/dev/null
grep -F -- '--accept-microsoft-eula' "$REPO_ROOT/deployment/run.sh" >/dev/null
grep -F -- 'for tool in sdcli sqlcmd bcp sqlplus sqlldr jq yq python3' "$REPO_ROOT/deployment/run.sh" >/dev/null
grep -F -- "test -f '\$SDCLI_SCRIPTS_DEST/lib/generate_validation_report.py'" "$REPO_ROOT/deployment/run.sh" >/dev/null
! grep -qE '\b(wget|curl)\b' "$REPO_ROOT/deployment/run.sh"
! grep -q 'podman pull' "$REPO_ROOT/deployment/run.sh"
! grep -q 'podman build' "$REPO_ROOT/deployment/run.sh"
! grep -q ':/u01:Z' "$REPO_ROOT/deployment/run.sh"

source_dir="$tmpdir/source-scripts"
container_root="$tmpdir/container"
mkdir -p "$source_dir/lib" "$source_dir/templates" "$container_root/home/sduser/sdcli-scripts/lib"
printf '%s\n' '#!/usr/bin/env bash' 'echo new-program' > "$source_dir/migrate.sh"
printf '%s\n' 'new report renderer' > "$source_dir/lib/generate_validation_report.py"
printf '%s\n' 'new deploy library' > "$source_dir/lib/sqlplus_deploy.sh"
printf '%s\n' 'new wrapper' > "$source_dir/lib/sqlplus"
printf '%s\n' 'new template' > "$source_dir/templates/product-preferences.xml"
printf '%s\n' 'defaults:' '  driver_file: /u01/app/jtds-1.3.1.jar' > "$source_dir/config.example.yaml"
chmod 0700 "$source_dir/migrate.sh"
chmod 0600 "$source_dir/lib/sqlplus_deploy.sh"

SDCLI_SCRIPTS_SRC="$source_dir"
SDCLI_SCRIPTS_DEST="$container_root/home/sduser/sdcli-scripts"
HOME_DIR="$container_root/home/sduser"
TOOL_DATA="$container_root/u01/data/sdcli-autokit"
TOOL_LOG="$container_root/u01/log"
APP_USER="$(id -un)"
APP_GROUP="$(id -gn)"
CONTAINER_NAME=test-container
BUNDLE_VERSION=1.2.3
FAKE_EXISTING_IMAGE_ID=""

container_engine() {
  local operation="$1"
  shift
  case "$operation" in
    cp)
      local source_path="$1"
      local destination="${2#*:}"
      cp -R "$source_path" "$destination"
      ;;
    exec)
      local -a environment=()
      local exec_user=""
      while [[ "${1:-}" == --* ]]; do
        case "$1" in
          --env)
            environment+=("$2")
            shift 2
            ;;
          --user)
            exec_user="$2"
            shift 2
            ;;
          *)
            echo "unexpected fake exec option: $1" >&2
            return 1
            ;;
        esac
      done
      shift
      [[ "$1" == "bash" && "$2" == "-lc" ]]
      shift 2
      if printf '%s\n' "${environment[@]+"${environment[@]}"}" | grep -q '^STAGE_DIR=' \
          && [[ "$exec_user" != "root" ]]; then
        echo "simulated Docker ownership failure: staged files require root" >&2
        return 77
      fi
      CONTAINER_EXEC_USER="$exec_user" env ${environment[@]+"${environment[@]}"} bash -lc "$1"
      ;;
    container)
      [[ "$1" == "inspect" && -n "$FAKE_EXISTING_IMAGE_ID" ]] || return 1
      if [[ "$*" == *"--format"* ]]; then
        printf '%s\n' "$FAKE_EXISTING_IMAGE_ID"
      fi
      ;;
    ps)
      [[ -n "$FAKE_EXISTING_IMAGE_ID" ]] && printf '%s\n' 'Up 1 minute'
      ;;
    start)
      ;;
    *)
      echo "unexpected fake container operation: $operation" >&2
      return 1
      ;;
  esac
}

printf '%s\n' 'old-program' > "$SDCLI_SCRIPTS_DEST/migrate.sh"
printf '%s\n' 'stale-library' > "$SDCLI_SCRIPTS_DEST/lib/stale.sh"
printf '%s\n' 'customer: keep-this-byte-for-byte' > "$SDCLI_SCRIPTS_DEST/config.yaml"
mkdir -p "$HOME_DIR/.sqldeveloper/system26.2.0/o.sqldeveloper"
printf '%s\n' 'customer preferences' > "$HOME_DIR/.sqldeveloper/system26.2.0/o.sqldeveloper/product-preferences.xml"
customer_config_checksum="$(cksum "$SDCLI_SCRIPTS_DEST/config.yaml")"

prepare_persistent_user_state
sync_sdcli_scripts
[[ -d "$TOOL_LOG" && -w "$TOOL_LOG" ]]

grep -F 'new-program' "$SDCLI_SCRIPTS_DEST/migrate.sh" >/dev/null
[[ ! -e "$SDCLI_SCRIPTS_DEST/lib/stale.sh" ]]
assert_mode "$SDCLI_SCRIPTS_DEST/migrate.sh" 755
assert_mode "$SDCLI_SCRIPTS_DEST/lib/sqlplus_deploy.sh" 644
[[ "$(cksum "$SDCLI_SCRIPTS_DEST/config.yaml")" == "$customer_config_checksum" ]]
[[ -L "$SDCLI_SCRIPTS_DEST/config.yaml" ]]
[[ "$(readlink "$SDCLI_SCRIPTS_DEST/config.yaml")" == "$TOOL_DATA/config/config.yaml" ]]
[[ -f "$TOOL_DATA/config/config.yaml" ]]
[[ -L "$HOME_DIR/.sqldeveloper" ]]
[[ "$(readlink "$HOME_DIR/.sqldeveloper")" == "$TOOL_DATA/sqldeveloper" ]]
grep -F 'customer preferences' "$TOOL_DATA/sqldeveloper/system26.2.0/o.sqldeveloper/product-preferences.xml" >/dev/null
[[ "$(cat "$SDCLI_SCRIPTS_DEST/.autokit-script-version")" == "1.2.3" ]]

HOME_DIR="$container_root/home/second-user"
second_destination="$HOME_DIR/sdcli-scripts"
SDCLI_SCRIPTS_DEST="$second_destination"
TOOL_DATA="$container_root/u01/data/second-install"
TOOL_LOG="$container_root/u01/second-log"
mkdir -p "$HOME_DIR"
sync_sdcli_scripts
cmp "$source_dir/config.example.yaml" "$second_destination/config.yaml"

HOME_DIR="$container_root/home/recreated-user"
SDCLI_SCRIPTS_DEST="$HOME_DIR/sdcli-scripts"
TOOL_DATA="$container_root/u01/data/recreated-install"
TOOL_LOG="$container_root/u01/recreated-log"
mkdir -p "$HOME_DIR" "$TOOL_DATA/config"
printf '%s\n' 'customer: survived-container-recreation' > "$TOOL_DATA/config/config.yaml"
sync_sdcli_scripts
grep -F 'customer: survived-container-recreation' "$SDCLI_SCRIPTS_DEST/config.yaml" >/dev/null

HOME_DIR="$container_root/home/second-user"
SDCLI_SCRIPTS_DEST="$second_destination"
TOOL_DATA="$container_root/u01/data/second-install"
TOOL_LOG="$container_root/u01/second-log"
printf '%s\n' 'previous-version' > "$second_destination/.autokit-script-version"
rm "$source_dir/lib/sqlplus_deploy.sh"
if ( sync_sdcli_scripts ) >/dev/null 2>&1; then
  echo "incomplete program source unexpectedly synchronized" >&2
  exit 1
fi
[[ "$(cat "$second_destination/.autokit-script-version")" == "previous-version" ]]

upgrade_root="$container_root/upgrade"
HOME_DIR="$upgrade_root/home/sduser"
TOOL_DATA="$upgrade_root/u01/data/sdcli-autokit"
TOOL_LOG="$upgrade_root/u01/log"
SDCLI_SCRIPTS_DEST="$HOME_DIR/sdcli-scripts"
mkdir -p "$SDCLI_SCRIPTS_DEST" "$HOME_DIR/.sqldeveloper"
printf '%s\n' 'upgrade customer config' > "$SDCLI_SCRIPTS_DEST/config.yaml"
printf '%s\n' 'upgrade preferences' > "$HOME_DIR/.sqldeveloper/product.conf"
FAKE_EXISTING_IMAGE_ID=old-image
IMAGE_ID=new-image
if ( start_or_reuse_container ) >/dev/null 2>&1; then
  echo "image mismatch unexpectedly reused the existing container" >&2
  exit 1
fi
grep -F 'upgrade customer config' "$TOOL_DATA/config/config.yaml" >/dev/null
grep -F 'upgrade preferences' "$TOOL_DATA/sqldeveloper/product.conf" >/dev/null

echo "offline run test passed"
