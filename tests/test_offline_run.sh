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

echo "offline run test passed"
