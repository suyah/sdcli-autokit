#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXPORT_SCRIPT="$REPO_ROOT/sdcli-scripts/export-source-schema.sh"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

mkdir -p "$tmpdir/bin" "$tmpdir/project-root"

cat > "$tmpdir/bin/yq" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

[[ "$1" == "eval" ]]
case "$2" in
  '.migrations | length') printf '1\n' ;;
  '.migrations[0].name') printf 'demo\n' ;;
  '.migrations[0].source.conn') printf 'sql.example.test:1433:SalesDb\n' ;;
  '.migrations[0].source.user') printf 'migration_user\n' ;;
  '.migrations[0].source.password') printf '%s\n' '${SOURCE_PASSWORD}' ;;
  '.defaults.source.type') printf 'SQLServer\n' ;;
  '.defaults.source.bcp_tls_mode') printf '%s\n' "${TEST_TLS_MODE:-trust}" ;;
  '.defaults.paths.project_root') printf '%s\n' "${TEST_PROJECT_ROOT:?}" ;;
  *) echo "unexpected yq expression: $2" >&2; exit 64 ;;
esac
SH

cat > "$tmpdir/bin/sqlpackage" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == '/Version' ]]; then
  printf '170.4.83.3\n'
  exit 0
fi

printf '%s\n' "$@" > "${FAKE_SQLPACKAGE_ARGS:?}"
target=''
for argument in "$@"; do
  case "$argument" in
    /TargetFile:*) target="${argument#/TargetFile:}" ;;
  esac
done
[[ -n "$target" ]] || exit 65

printf 'diagnostic password=%s\n' "${SOURCE_PASSWORD:?}" >&2
if [[ "${FAKE_SQLPACKAGE_FAIL:-false}" == true ]]; then
  exit 9
fi

mkdir -p "$target/dbo/Stored Procedures"
printf 'CREATE PROCEDURE [dbo].[example] AS SELECT 1;\n' > "$target/dbo/Stored Procedures/example.sql"
if [[ "${TEST_TYPE_LAYOUT:-false}" == true ]]; then
  mkdir -p "$target/dbo/Tables" "$target/other/Tables" "$target/dbo/Functions" "$target/Security"
  printf 'CREATE TABLE [dbo].[first table] (id int);\nGO\nCREATE INDEX ix ON [dbo].[first table](id);\nGO\n' > "$target/dbo/Tables/first table.sql"
  printf 'CREATE TABLE [other].[last] (id int);\nGO\n' > "$target/other/Tables/last.sql"
  printf '\357\273\277CREATE FUNCTION example() RETURNS int AS BEGIN RETURN 1 END;\nGO\n' > "$target/dbo/Functions/example.sql"
  printf 'CREATE USER [reader] WITHOUT LOGIN;\nGO\n' | iconv -f UTF-8 -t UTF-16 > "$target/Security/reader.sql"
  printf 'ALTER DATABASE CURRENT SET READ_WRITE;\nGO\n' > "$target/Database.sql"
fi
if [[ "${TEST_BAD_LAYOUT:-false}" == true ]]; then
  mkdir -p "$target/dbo/Tables/nested"
  printf 'SELECT 1;\n' > "$target/dbo/Tables/nested/unsupported.sql"
fi
SH
chmod +x "$tmpdir/bin/yq" "$tmpdir/bin/sqlpackage"

config_file="$tmpdir/config.yaml"
printf '%s\n' 'fixture: only fake yq reads this file' > "$config_file"

export PATH="$tmpdir/bin:$PATH"
export AUTOKIT_CONFIG_FILE="$config_file"
export TEST_PROJECT_ROOT="$tmpdir/project-root"
export SOURCE_PASSWORD='P@ss word$with#chars'
export FAKE_SQLPACKAGE_ARGS="$tmpdir/sqlpackage.args"

run_export() {
  local tls_mode="$1"
  local output_dir="$2"
  TEST_TLS_MODE="$tls_mode" "$EXPORT_SCRIPT" demo --output "$output_dir"
}

success_dir="$tmpdir/project-root/demo/source-schema/test-success"
success_stdout="$tmpdir/success.stdout"
run_export trust "$success_dir" > "$success_stdout"

[[ -f "$success_dir/manifest.txt" ]]
[[ -f "$success_dir/sqlpackage-extract.log" ]]
[[ -f "$success_dir/sql/dbo/Stored Procedures/example.sql" ]]
grep -Fx '/Action:Extract' "$FAKE_SQLPACKAGE_ARGS" >/dev/null
grep -Fx '/p:ExtractAllTableData=False' "$FAKE_SQLPACKAGE_ARGS" >/dev/null
grep -Fx '/p:ExtractTarget=SchemaObjectType' "$FAKE_SQLPACKAGE_ARGS" >/dev/null
grep -Fx '/SourceServerName:sql.example.test,1433' "$FAKE_SQLPACKAGE_ARGS" >/dev/null
grep -Fx '/SourceDatabaseName:SalesDb' "$FAKE_SQLPACKAGE_ARGS" >/dev/null
grep -Fx '/SourceUser:migration_user' "$FAKE_SQLPACKAGE_ARGS" >/dev/null
grep -Fx "/SourcePassword:$SOURCE_PASSWORD" "$FAKE_SQLPACKAGE_ARGS" >/dev/null
grep -Fx '/SourceEncryptConnection:True' "$FAKE_SQLPACKAGE_ARGS" >/dev/null
grep -Fx '/SourceTrustServerCertificate:True' "$FAKE_SQLPACKAGE_ARGS" >/dev/null
if grep -F "$SOURCE_PASSWORD" "$success_stdout" "$success_dir/manifest.txt" "$success_dir/sqlpackage-extract.log"; then
  echo 'source password leaked into export output' >&2
  exit 1
fi
grep -F '***' "$success_dir/sqlpackage-extract.log" >/dev/null

TEST_TLS_MODE=trust "$EXPORT_SCRIPT" demo > "$tmpdir/default.stdout"
default_dir="$(find "$tmpdir/project-root/demo/source-schema" -mindepth 1 -maxdepth 1 -type d ! -name test-success -print -quit)"
[[ -n "$default_dir" && -f "$default_dir/manifest.txt" ]] || {
  echo 'default source-schema output was not created' >&2
  exit 1
}

strict_dir="$tmpdir/strict-output"
run_export strict "$strict_dir" >/dev/null
grep -Fx '/SourceEncryptConnection:Strict' "$FAKE_SQLPACKAGE_ARGS" >/dev/null
if grep -F '/SourceTrustServerCertificate:' "$FAKE_SQLPACKAGE_ARGS" >/dev/null; then
  echo 'strict TLS unexpectedly trusts the certificate' >&2
  exit 1
fi

optional_dir="$tmpdir/optional-output"
run_export optional "$optional_dir" >/dev/null
grep -Fx '/SourceEncryptConnection:Optional' "$FAKE_SQLPACKAGE_ARGS" >/dev/null

existing_dir="$tmpdir/already-exists"
mkdir -p "$existing_dir"
if run_export trust "$existing_dir" > "$tmpdir/existing.stdout" 2> "$tmpdir/existing.stderr"; then
  echo 'existing output directory unexpectedly accepted' >&2
  exit 1
fi
grep -F 'output directory already exists' "$tmpdir/existing.stderr" >/dev/null

failure_dir="$tmpdir/tool-failure"
if FAKE_SQLPACKAGE_FAIL=true run_export trust "$failure_dir" > "$tmpdir/failure.stdout" 2> "$tmpdir/failure.stderr"; then
  echo 'SqlPackage failure unexpectedly succeeded' >&2
  exit 1
fi
[[ -f "$failure_dir/sqlpackage-extract.log" ]]
grep -F 'diagnostic password=***' "$failure_dir/sqlpackage-extract.log" >/dev/null
grep -F 'diagnostic password=***' "$tmpdir/failure.stderr" >/dev/null
if grep -F "$SOURCE_PASSWORD" "$tmpdir/failure.stderr" "$failure_dir/sqlpackage-extract.log"; then
  echo 'source password leaked after SqlPackage failure' >&2
  exit 1
fi
[[ ! -f "$failure_dir/manifest.txt" ]]

type_dir="$tmpdir/type-output"
TEST_TYPE_LAYOUT=true TEST_TLS_MODE=trust "$EXPORT_SCRIPT" demo --layout type --output "$type_dir" > "$tmpdir/type.stdout"
[[ -f "$type_dir/by-type/Tables.sql" && -f "$type_dir/by-type/Stored Procedures.sql" && -f "$type_dir/by-type/Security.sql" && -f "$type_dir/by-type/Database.sql" ]]
grep -F 'CREATE INDEX ix' "$type_dir/by-type/Tables.sql" >/dev/null
grep -F 'CREATE FUNCTION example' "$type_dir/by-type/Functions.sql" >/dev/null
grep -F 'CREATE USER [reader]' "$type_dir/by-type/Security.sql" >/dev/null
[[ "$(head -c 3 "$type_dir/sql/dbo/Functions/example.sql" | od -An -tx1 | tr -d ' \n')" == efbbbf ]]
if LC_ALL=C grep -Fq $'\357\273\277' "$type_dir/by-type/Functions.sql"; then
  echo 'Embedded BOM remained in grouped UTF-8 SQL' >&2; exit 1
fi
[[ "$(grep -Rh '^-- Source: ' "$type_dir/by-type" | wc -l | tr -d ' ')" == 6 ]]
first_line="$(grep -n '^-- Source: dbo/Tables/' "$type_dir/by-type/Tables.sql" | cut -d: -f1)"
last_line="$(grep -n '^-- Source: other/Tables/' "$type_dir/by-type/Tables.sql" | cut -d: -f1)"
(( first_line < last_line ))
grep -Fx 'Layout: type' "$type_dir/manifest.txt" >/dev/null
[[ ! -e "$success_dir/by-type" ]]

bad_layout_dir="$tmpdir/unsupported-layout"
if TEST_BAD_LAYOUT=true TEST_TLS_MODE=trust "$EXPORT_SCRIPT" demo --layout type --output "$bad_layout_dir" > "$tmpdir/bad-layout.out" 2>&1; then
  echo 'Unsupported native layout was silently omitted' >&2; exit 1
fi
[[ -f "$bad_layout_dir/sql/dbo/Tables/nested/unsupported.sql" && ! -e "$bad_layout_dir/manifest.txt" ]]

echo 'source schema export test passed'
