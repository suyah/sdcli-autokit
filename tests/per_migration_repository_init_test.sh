#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATE_SH_SOURCE_ONLY=true source "$REPO_ROOT/sdcli-scripts/migrate.sh"

fail_test() {
  echo "$1" >&2
  exit 1
}

assert_eq() {
  local actual="$1"
  local expected="$2"
  local label="$3"
  [[ "$actual" == "$expected" ]] || fail_test "$label: expected '$expected', got '$actual'"
}

assert_contains() {
  local value="$1"
  local expected="$2"
  local label="$3"
  [[ "$value" == *"$expected"* ]] || fail_test "$label: expected to contain '$expected', got '$value'"
}

assert_not_contains() {
  local value="$1"
  local unexpected="$2"
  local label="$3"
  [[ "$value" != *"$unexpected"* ]] || fail_test "$label: did not expect '$unexpected' in '$value'"
}

yq_eval() {
  case "$1" in
    '.migrations | length') printf '%s\n' "${TEST_MIGRATION_COUNT:-2}" ;;
    *) fail_test "unexpected yq lookup: $1" ;;
  esac
}

migration_required_value() {
  local idx="$1"
  shift
  case "$idx:$*" in
    '0:name') printf 'proda\n' ;;
    '1:name') printf 'cecrealm\n' ;;
    *) fail_test "unexpected migration lookup: $idx:$*" ;;
  esac
}

set +e
multi_init_output="$(MIGRATION_NAME='' select_init_migration 2>&1)"
multi_init_rc=$?
unknown_init_output="$(MIGRATION_NAME='missing' select_init_migration 2>&1)"
unknown_init_rc=$?
parse_output="$(MIGRATION_NAME='' MODE=full MODE_EXPLICIT=false parse_args proda --init 2>&1)"
parse_rc=$?
unnamed_parse_output="$(MIGRATION_NAME='' MODE=full MODE_EXPLICIT=false parse_args --init 2>&1)"
unnamed_parse_rc=$?
set -e
[[ $multi_init_rc -ne 0 ]] || fail_test "multi-migration unnamed init unexpectedly succeeded"
assert_contains "$multi_init_output" './migrate.sh <name> --init' "multi-migration init guidance"
[[ $unknown_init_rc -ne 0 ]] || fail_test "unknown migration init unexpectedly succeeded"
assert_contains "$unknown_init_output" "Migration 'missing' not found in config" "unknown init rejection"
[[ $parse_rc -eq 0 ]] || fail_test "named init parser rejected valid command: $parse_output"
[[ $unnamed_parse_rc -eq 0 ]] || fail_test "single-migration compatible init parser rejected valid command: $unnamed_parse_output"

TEST_MIGRATION_COUNT=1
assert_eq "$(MIGRATION_NAME='' select_init_migration)" 0 "single migration init selection"
assert_eq "$(MIGRATION_NAME='proda' select_init_migration)" 0 "explicit migration init selection"

declare -a calls=()
run_sdcli() {
  calls+=("$*")
}

configure_sqldeveloper_file_output_option() { :; }

get_required_value() {
  case "$1" in
    '.defaults.driver_file') printf '/vendor/jtds.jar\n' ;;
    '.migration_repository.name') printf 'repo\n' ;;
    '.migration_repository.repo_user.user') printf 'migrep\n' ;;
    '.migration_repository.super_user.user') printf 'admin\n' ;;
    *) fail_test "unexpected required config lookup: $1" ;;
  esac
}

get_secret_value() {
  case "$1" in
    '.migration_repository.repo_user.password') printf 'repo_password\n' ;;
    '.migration_repository.super_user.password') printf 'super_password\n' ;;
    *) fail_test "unexpected secret config lookup: $1" ;;
  esac
}

validate_sdcli_conn_details_password() { :; }

ACTIVE_MIGRATION_NAME='proda'
ACTIVE_REPOSITORY_CONN='tcps://proda.example:1522/proda_high'
ACTIVE_REPOSITORY_NAME='migration_repo_proda'
ACTIVE_SUPER_CONNECTION_NAME='super_migration_proda'

setup_repository

assert_eq "${#calls[@]}" 2 "repository init SDCLI call count"
assert_eq "${calls[0]}" 'sdcli migration -actions=driver -files=/vendor/jtds.jar' "driver registration"
assert_contains "${calls[1]}" 'super_migration_proda:oracle:admin/super_password@tcps://proda.example:1522/proda_high' "active super connection"
assert_contains "${calls[1]}" 'migration_repo_proda:mkrepouser:migrep/repo_password:super_migration_proda' "active repository connection"
assert_not_contains "${calls[1]}" 'legacy.example' "legacy endpoint isolation"
assert_not_contains "${calls[1]}" 'migration_repo:mkrepouser' "unsuffixed repository isolation"
assert_not_contains "${calls[1]}" 'super_migration:oracle' "unsuffixed super isolation"

echo "per-migration repository init test passed"
