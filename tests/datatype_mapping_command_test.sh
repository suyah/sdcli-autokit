#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATE_SH_SOURCE_ONLY=true source "$REPO_ROOT/sdcli-scripts/migrate.sh"

fail_test() {
  echo "$1" >&2
  exit 1
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "$tmpdir/bin"

cat > "$tmpdir/bin/sqlplus" <<'SH'
#!/usr/bin/env bash
input="$(cat)"
printf '%s' "$input" > "$SQLPLUS_INPUT_FILE"
printf 'call\n' >> "$SQLPLUS_CALLS_FILE"

if [[ "$input" == *'SDCLI_DATATYPE_PRECHECK'* ]]; then
  printf 'SDCLI_DATATYPE_PRECHECK\t%s\n' "${MAPPING_PREFLIGHT_MISSING:-0}"
  exit 0
fi

if [[ "$input" == *"p.project_name = 'R&D'"* && "$input" != *'SET DEFINE OFF'* ]]; then
  printf 'SP2-0310: unable to resolve substitution variable\n' >&2
  exit 9
fi

if [[ "$input" == *$'JOIN migr_datatype_transform_rule r ON r.map_id_fk = m.id\n\nORDER BY'* ]]; then
  printf 'SP2-0734: unknown command beginning "ORDER BY"\n' >&2
  exit 9
fi

case "${MAPPING_RESULT_MODE:-all}" in
  all)
    printf 'SDCLI_DATATYPE_MAPPING\tproda\tSQLServerDataMap\tVARCHAR\t\t\tVARCHAR2\t\t\n'
    printf 'SDCLI_DATATYPE_MAPPING\talpha\tSQLServerDataMap\tINT\t\t\tNUMBER\t10\t0\n'
    printf 'SDCLI_DATATYPE_MAPPING\talpha\tSQLServerDataMap\tBIGINT\t\t\tNUMBER\t19\t0\n'
    ;;
  project)
    [[ "$input" == *"p.project_name = 'proda'"* ]] || exit 8
    printf 'SDCLI_DATATYPE_MAPPING\tproda\tSQLServerDataMap\tVARCHAR\t\t\tVARCHAR2\t\t\n'
    ;;
  ampersand)
    [[ "$input" == *"p.project_name = 'R&D'"* ]] || exit 8
    printf 'SDCLI_DATATYPE_MAPPING\tR&D\tSQLServerDataMap\tINT\t\t\tNUMBER\t10\t0\n'
    ;;
  incomplete)
    printf 'SDCLI_DATATYPE_MAPPING\tproda\tSQLServerDataMap\tVARCHAR\t\t\tVARCHAR2\t\t\n'
    exit 0
    ;;
  empty) ;;
esac
printf 'SDCLI_DATATYPE_COMPLETE\n'
SH
chmod +x "$tmpdir/bin/sqlplus"

PATH="$tmpdir/bin:$PATH"
export SQLPLUS_INPUT_FILE="$tmpdir/sqlplus.input"
export SQLPLUS_CALLS_FILE="$tmpdir/sqlplus.calls"
repo_secret='Repo@Test-42!'

get_required_value() {
  case "$1" in
    '.migration_repository.conn') printf 'repo_alias\n' ;;
    '.migration_repository.repo_user.user') printf 'migrep\n' ;;
    *) fail_test "unexpected config path: $1" ;;
  esac
}

get_secret_value() {
  [[ "$1" == '.migration_repository.repo_user.password' ]] \
    || fail_test "unexpected secret path: $1"
  printf '%s\n' "$repo_secret"
}

ACTIVE_REPOSITORY_CONN='repo_alias'
ACTIVE_REPOSITORY_NAME='migration_repo'

MODE="full"
MODE_EXPLICIT=false
MIGRATION_NAME=""
parse_args --show-datatype-mapping
[[ "$MODE" == "show-datatype-mapping" ]] || fail_test "global mapping mode was not selected"
[[ -z "$MIGRATION_NAME" ]] || fail_test "global mapping command unexpectedly requires a migration"

MODE="full"
MODE_EXPLICIT=false
MIGRATION_NAME=""
parse_args proda --show-datatype-mapping
[[ "$MODE" == "show-datatype-mapping" ]] || fail_test "project mapping mode was not selected"
[[ "$MIGRATION_NAME" == "proda" ]] || fail_test "project mapping command lost the migration name"

expected_header=$'project\tmap_name\tsource_type\tsource_precision\tsource_scale\ttarget_type\ttarget_precision\ttarget_scale'
expected_all="$expected_header"$'\nalpha\tSQLServerDataMap\tBIGINT\t\t\tNUMBER\t19\t0\nalpha\tSQLServerDataMap\tINT\t\t\tNUMBER\t10\t0\nproda\tSQLServerDataMap\tVARCHAR\t\t\tVARCHAR2\t\t'

: > "$SQLPLUS_CALLS_FILE"
all_stderr="$tmpdir/all.stderr"
all_output="$(show_datatype_mapping "" 2> "$all_stderr")"
[[ "$all_output" == "$expected_all" ]] || fail_test "all-project mapping output was not deterministic TSV"
[[ "$(grep -c '^call$' "$SQLPLUS_CALLS_FILE")" == 2 ]] || fail_test "mapping command did not run preflight then query"
grep -F "$repo_secret" "$SQLPLUS_INPUT_FILE" >/dev/null || fail_test "repository password did not reach SQL*Plus"
grep -F 'connect migrep/"Repo@Test-42!"@repo_alias' "$SQLPLUS_INPUT_FILE" >/dev/null \
  || fail_test "global mapping command did not use the active repository endpoint"
if grep -F "$repo_secret" "$all_stderr" >/dev/null || [[ "$all_output" == *"$repo_secret"* ]]; then
  fail_test "repository password leaked from mapping command"
fi

: > "$SQLPLUS_CALLS_FILE"
ACTIVE_REPOSITORY_CONN='tcps://proda.example:1522/proda_high'
ACTIVE_REPOSITORY_NAME='migration_repo_proda'
project_output="$(MAPPING_RESULT_MODE=project show_datatype_mapping "proda" 2> "$tmpdir/project.stderr")"
[[ "$project_output" == "$expected_header"$'\nproda\tSQLServerDataMap\tVARCHAR\t\t\tVARCHAR2\t\t' ]] \
  || fail_test "project-specific mapping output was incorrect"
grep -F 'connect migrep/"Repo@Test-42!"@tcps://proda.example:1522/proda_high' "$SQLPLUS_INPUT_FILE" >/dev/null \
  || fail_test "named mapping command did not use its active repository endpoint"

ampersand_output="$(MAPPING_RESULT_MODE=ampersand show_datatype_mapping "R&D" 2> "$tmpdir/ampersand.stderr")"
[[ "$ampersand_output" == "$expected_header"$'\nR&D\tSQLServerDataMap\tINT\t\t\tNUMBER\t10\t0' ]] \
  || fail_test "ampersand-containing project name was not queried literally"

: > "$SQLPLUS_CALLS_FILE"
empty_output="$(MAPPING_RESULT_MODE=empty show_datatype_mapping "unused" 2> "$tmpdir/empty.stderr")"
[[ "$empty_output" == "$expected_header" ]] || fail_test "empty mapping result must return only the TSV header"

set +e
( MAPPING_RESULT_MODE=incomplete show_datatype_mapping "proda" ) \
  > "$tmpdir/incomplete.stdout" 2> "$tmpdir/incomplete.stderr"
incomplete_rc=$?
set -e
[[ $incomplete_rc -ne 0 ]] || fail_test "mapping query without a completion marker unexpectedly succeeded"
grep -F 'malformed evidence' "$tmpdir/incomplete.stderr" >/dev/null \
  || fail_test "missing completion marker did not produce an actionable error"

set +e
run_repository_sql_capture "$tmpdir/does-not-exist.sql" "$tmpdir/producer-failure.out" \
  2> "$tmpdir/producer-failure.stderr"
producer_rc=$?
set -e
[[ $producer_rc -ne 0 ]] || fail_test "failed SQL producer was hidden by a successful SQL*Plus process"

: > "$SQLPLUS_CALLS_FILE"
set +e
( MAPPING_PREFLIGHT_MISSING=1 show_datatype_mapping "" ) > "$tmpdir/preflight.stdout" 2> "$tmpdir/preflight.stderr"
preflight_rc=$?
set -e
[[ $preflight_rc -ne 0 ]] || fail_test "unsupported repository schema unexpectedly succeeded"
grep -F 'Unsupported SQL Developer repository schema' "$tmpdir/preflight.stderr" >/dev/null \
  || fail_test "unsupported repository schema did not produce an actionable error"
[[ "$(grep -c '^call$' "$SQLPLUS_CALLS_FILE")" == 1 ]] \
  || fail_test "mapping query ran after repository preflight failed"
if grep -F "$repo_secret" "$tmpdir/preflight.stderr" >/dev/null; then
  fail_test "repository password leaked in preflight error"
fi

interrupt_tmp="$tmpdir/interrupt-tmp"
mkdir -p "$interrupt_tmp"
set +e
MIGRATE_SCRIPT="$REPO_ROOT/sdcli-scripts/migrate.sh" INTERRUPT_TMP="$interrupt_tmp" \
  bash -c '
    set -euo pipefail
    MIGRATE_SH_SOURCE_ONLY=true source "$MIGRATE_SCRIPT"
    trap on_exit EXIT
    trap "on_signal 143" TERM
    active_tmp="$(mktemp -d "$INTERRUPT_TMP/sdcli_datatype_mapping_XXXXXX")"
    register_datatype_mapping_temp_dir "$active_tmp"
    kill -TERM "$$"
  '
interrupt_rc=$?
set -e
[[ $interrupt_rc -eq 143 ]] || fail_test "interrupt cleanup probe returned $interrupt_rc instead of 143"
if find "$interrupt_tmp" -mindepth 1 -print -quit | grep -q .; then
  fail_test "interrupted datatype mapping command retained its private temporary directory"
fi

echo "datatype mapping command test passed"
