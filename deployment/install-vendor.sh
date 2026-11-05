#!/bin/bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: install-vendor.sh --vendor-dir /vendor-rpms --accept-microsoft-eula \
  --accept-sqlpackage-license

Installs customer-provided RPMs from a directory already mounted in the
container, plus the customer-provided SqlPackage Linux ZIP. This release
supports SQL Developer 26.2 only. It never enables a repository or downloads
a package.
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
ACCEPT_SQLPACKAGE_LICENSE=false

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
    --accept-sqlpackage-license)
      ACCEPT_SQLPACKAGE_LICENSE=true
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
[[ "$ACCEPT_SQLPACKAGE_LICENSE" == true ]] || fail "--accept-sqlpackage-license is required"
[[ -d "$VENDOR_DIR" ]] || fail "vendor RPM directory does not exist: $VENDOR_DIR"

APP_USER="${APP_USER:-sduser}"
APP_GROUP="${APP_GROUP:-sduser}"
HOME_DIR="${HOME_DIR:-/home/sduser}"
SD_HOME="${SD_HOME:-/u01/app/sqldeveloper}"
TOOL_DATA="${TOOL_DATA:-/u01/data/sdcli-autokit}"
SQLPACKAGE_ARCHIVE_NAME="sqlpackage-linux-x64-en-170.4.83.3.zip"
SQLPACKAGE_VERSION="170.4.83.3"
SQLPACKAGE_SHA256="e81ede2429f3a15d9e752845c8928569c7706b3a911fad2d1717c0f03e0fc7c3"

require_single_rpm() {
  local label="$1"
  local pattern="$2"
  local matches=()

  shopt -s nullglob
  matches=("$VENDOR_DIR"/$pattern)
  shopt -u nullglob

  [[ ${#matches[@]} -eq 1 ]] || fail "expected exactly one $label RPM matching $pattern in $VENDOR_DIR"
  [[ -f "${matches[0]}" && ! -L "${matches[0]}" ]] || fail "$label RPM must be a regular file: ${matches[0]}"
  printf '%s\n' "${matches[0]}"
}

require_vendor_file() {
  local label="$1"
  local filename="$2"
  local file="$VENDOR_DIR/$filename"

  [[ -f "$file" && ! -L "$file" ]] || fail "$label must be a regular file named $filename in $VENDOR_DIR"
  printf '%s\n' "$file"
}

validate_rpm() {
  local role="$1"
  local file="$2"
  local expected_name="$3"
  local expected_arch="$4"
  local rpm_name rpm_arch

  rpm_name="$(rpm -qp --qf '%{NAME}' "$file")" || fail "cannot read RPM metadata: $file"
  rpm_arch="$(rpm -qp --qf '%{ARCH}' "$file")" || fail "cannot read RPM architecture: $file"

  case "$expected_name" in
    exact:*) [[ "$rpm_name" == "${expected_name#exact:}" ]] ;;
    prefix:*) [[ "$rpm_name" == "${expected_name#prefix:}"* ]] ;;
    *) fail "internal error: unknown RPM name rule for $role" ;;
  esac || fail "$role RPM has unexpected package name '$rpm_name': $file"

  [[ "$rpm_arch" == "$expected_arch" ]] || fail "$role RPM has architecture '$rpm_arch', expected '$expected_arch': $file"
}

SQLDEVELOPER_RPM="$(require_single_rpm "SQL Developer" 'sqldeveloper-*.noarch.rpm')"
INSTANTCLIENT_BASIC_RPM="$(require_single_rpm "Instant Client Basic" 'oracle-instantclient*-basic-*.x86_64.rpm')"
INSTANTCLIENT_SQLPLUS_RPM="$(require_single_rpm "Instant Client SQL*Plus" 'oracle-instantclient*-sqlplus-*.x86_64.rpm')"
INSTANTCLIENT_TOOLS_RPM="$(require_single_rpm "Instant Client Tools" 'oracle-instantclient*-tools-*.x86_64.rpm')"
MSODBC_RPM="$(require_single_rpm "Microsoft ODBC Driver 18" 'msodbcsql18-*.x86_64.rpm')"
MSSQL_TOOLS_RPM="$(require_single_rpm "Microsoft SQL Server tools" 'mssql-tools18-*.x86_64.rpm')"
SQLPACKAGE_ARCHIVE="$(require_vendor_file "Microsoft SqlPackage Linux archive" "$SQLPACKAGE_ARCHIVE_NAME")"

validate_rpm "SQL Developer" "$SQLDEVELOPER_RPM" "exact:sqldeveloper" noarch
validate_rpm "Instant Client Basic" "$INSTANTCLIENT_BASIC_RPM" "prefix:oracle-instantclient" x86_64
validate_rpm "Instant Client SQL*Plus" "$INSTANTCLIENT_SQLPLUS_RPM" "prefix:oracle-instantclient" x86_64
validate_rpm "Instant Client Tools" "$INSTANTCLIENT_TOOLS_RPM" "prefix:oracle-instantclient" x86_64
validate_rpm "Microsoft ODBC Driver 18" "$MSODBC_RPM" "exact:msodbcsql18" x86_64
validate_rpm "Microsoft SQL Server tools" "$MSSQL_TOOLS_RPM" "exact:mssql-tools18" x86_64

printf '%s  %s\n' "$SQLPACKAGE_SHA256" "$SQLPACKAGE_ARCHIVE" | sha256sum -c - >/dev/null \
  || fail "Microsoft SqlPackage Linux archive checksum does not match the supported $SQLPACKAGE_VERSION release"

if [[ ! -x "$SD_HOME/sqldeveloper/bin/sdcli" ]]; then
  tmp_dir="$(mktemp -d)"
  trap 'rm -rf "$tmp_dir"' EXIT

  mkdir -p "$tmp_dir/root" "$tmp_dir/db" "$SD_HOME" "$HOME_DIR/.sqldeveloper"
  rpm --root "$tmp_dir/root" \
      --dbpath "$tmp_dir/db" \
      --nodeps \
      --noscripts \
      --notriggers \
      -ivh "$SQLDEVELOPER_RPM" >/dev/null

  sql_developer_dir="$(find "$tmp_dir/root" -type d -path '*/sqldeveloper' -print -quit)"
  [[ -n "$sql_developer_dir" ]] || fail "could not locate sqldeveloper after extracting $SQLDEVELOPER_RPM"

  rm -rf "$SD_HOME"
  mkdir -p "$SD_HOME"
  cp -a "$sql_developer_dir/." "$SD_HOME/"
  printf 'SetJavaHome %s\n' '/usr/lib/jvm/java-17-openjdk' > "$HOME_DIR/.sqldeveloper/product.conf"
fi

# SQL Developer 26.2 includes Windows-only directives that its Linux launcher
# does not implement. They are irrelevant on Linux but otherwise print a shell
# error on every sdcli invocation.
for launcher_config in "$SD_HOME/ide/bin/jdk.conf" "$SD_HOME/sqldeveloper/bin/java11.conf"; do
  [[ -f "$launcher_config" ]] || continue
  sed -i -E '/^[[:space:]]*AddWindowsVM11OrHigherOption[[:space:]]/s/^/# /' "$launcher_config"
done

rpm_files=()
shopt -s nullglob
for rpm_file in "$VENDOR_DIR"/*.rpm; do
  [[ "$rpm_file" == "$SQLDEVELOPER_RPM" ]] || rpm_files+=("$rpm_file")
done
shopt -u nullglob
[[ ${#rpm_files[@]} -gt 0 ]] || fail "no RPMs available for local installation"

ACCEPT_EULA=Y dnf -y \
  --disablerepo='*' \
  --setopt=install_weak_deps=False \
  --nogpgcheck \
  install "${rpm_files[@]}"

oracle_sqlplus="$(find /usr/lib/oracle -type f -path '*/client64/bin/sqlplus' -print -quit)"
oracle_sqlldr="$(find /usr/lib/oracle -type f -path '*/client64/bin/sqlldr' -print -quit)"
[[ -n "$oracle_sqlplus" && -n "$oracle_sqlldr" ]] || fail "Instant Client SQL*Plus and Tools did not install expected commands"
ln -sf "$oracle_sqlplus" /usr/local/bin/sqlplus
ln -sf "$oracle_sqlldr" /usr/local/bin/sqlldr

sqlpackage_root="${TOOL_DATA%/}/tools"
mkdir -p "$sqlpackage_root"
sqlpackage_version_dir="$sqlpackage_root/sqlpackage-$SQLPACKAGE_VERSION"
sqlpackage_link="$sqlpackage_root/sqlpackage"
sqlpackage_stage="$(mktemp -d "$sqlpackage_root/.sqlpackage-stage.XXXXXX")"
if ! unzip -q "$SQLPACKAGE_ARCHIVE" -d "$sqlpackage_stage"; then
  rm -rf -- "$sqlpackage_stage"
  fail "could not extract Microsoft SqlPackage Linux archive"
fi
[[ -f "$sqlpackage_stage/LICENSE.TXT" ]] || {
  rm -rf -- "$sqlpackage_stage"
  fail "Microsoft SqlPackage Linux archive is missing LICENSE.TXT"
}
[[ -f "$sqlpackage_stage/sqlpackage" ]] || {
  rm -rf -- "$sqlpackage_stage"
  fail "Microsoft SqlPackage Linux archive is missing the sqlpackage executable"
}
chmod 0755 "$sqlpackage_stage/sqlpackage"
rm -rf -- "$sqlpackage_version_dir"
mv "$sqlpackage_stage" "$sqlpackage_version_dir"
if [[ -e "$sqlpackage_link" && ! -L "$sqlpackage_link" ]]; then
  fail "SqlPackage installation path already exists and is not managed: $sqlpackage_link"
fi
ln -sfn "sqlpackage-$SQLPACKAGE_VERSION" "$sqlpackage_link"
if [[ -e /usr/local/bin/sqlpackage && ! -L /usr/local/bin/sqlpackage ]]; then
  fail "/usr/local/bin/sqlpackage already exists and is not managed"
fi
ln -sfn "$sqlpackage_link/sqlpackage" /usr/local/bin/sqlpackage
chown -R "$APP_USER:$APP_GROUP" "$sqlpackage_version_dir"
chown -h "$APP_USER:$APP_GROUP" "$sqlpackage_link"
sqlpackage /Version >/dev/null || fail "Microsoft SqlPackage did not start"

chown -R "$APP_USER:$APP_GROUP" "$SD_HOME" "$HOME_DIR/.sqldeveloper"

test -x "$SD_HOME/sqldeveloper/bin/sdcli"
command -v sqlcmd >/dev/null
command -v bcp >/dev/null
command -v sqlplus >/dev/null
command -v sqlldr >/dev/null
command -v sqlpackage >/dev/null

echo "Customer-provided vendor packages installed from $VENDOR_DIR"
