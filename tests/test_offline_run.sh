#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

RUN_SH_SOURCE_ONLY=true source "$REPO_ROOT/deployment/run.sh"

vendor_dir="$tmpdir/vendor-rpms"
mkdir -p "$vendor_dir"
touch \
  "$vendor_dir/sqldeveloper-24.3.1.noarch.rpm" \
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

SDCLI_SCRIPTS_SRC="$source_dir"
SDCLI_SCRIPTS_DEST="$container_root/home/sduser/sdcli-scripts"
CONTAINER_NAME=test-container
BUNDLE_VERSION=1.2.3

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
      while [[ "${1:-}" == "--env" ]]; do
        environment+=("$2")
        shift 2
      done
      shift
      [[ "$1" == "bash" && "$2" == "-lc" ]]
      shift 2
      env ${environment[@]+"${environment[@]}"} bash -lc "$1"
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
customer_config_checksum="$(cksum "$SDCLI_SCRIPTS_DEST/config.yaml")"

sync_sdcli_scripts

grep -F 'new-program' "$SDCLI_SCRIPTS_DEST/migrate.sh" >/dev/null
[[ ! -e "$SDCLI_SCRIPTS_DEST/lib/stale.sh" ]]
[[ "$(cksum "$SDCLI_SCRIPTS_DEST/config.yaml")" == "$customer_config_checksum" ]]
[[ "$(cat "$SDCLI_SCRIPTS_DEST/.autokit-script-version")" == "1.2.3" ]]

second_destination="$container_root/home/sduser/second-scripts"
SDCLI_SCRIPTS_DEST="$second_destination"
sync_sdcli_scripts
cmp "$source_dir/config.example.yaml" "$second_destination/config.yaml"

printf '%s\n' 'previous-version' > "$second_destination/.autokit-script-version"
rm "$source_dir/lib/sqlplus_deploy.sh"
if ( sync_sdcli_scripts ) >/dev/null 2>&1; then
  echo "incomplete program source unexpectedly synchronized" >&2
  exit 1
fi
[[ "$(cat "$second_destination/.autokit-script-version")" == "previous-version" ]]

echo "offline run test passed"
