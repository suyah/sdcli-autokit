#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATE_SH_SOURCE_ONLY=true source "$REPO_ROOT/sdcli-scripts/migrate.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

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
ACTIVE_REPOSITORY_NAME='repo_proda'
ACTIVE_SUPER_CONNECTION_NAME='super_migration_proda'

setup_repository

assert_eq "${#calls[@]}" 2 "repository init SDCLI call count"
assert_eq "${calls[0]}" 'sdcli migration -actions=driver -files=/vendor/jtds.jar' "driver registration"
assert_contains "${calls[1]}" '-conn=repo_proda' "explicit init repository selection for a non-mig alias prefix"
assert_contains "${calls[1]}" 'super_migration_proda:oracle:admin/super_password@tcps://proda.example:1522/proda_high' "active super connection"
assert_contains "${calls[1]}" 'repo_proda:mkrepouser:migrep/repo_password:super_migration_proda' "active repository connection"
assert_not_contains "${calls[1]}" 'legacy.example' "legacy endpoint isolation"
assert_not_contains "${calls[1]}" 'migration_repo:mkrepouser' "unsuffixed repository isolation"
assert_not_contains "${calls[1]}" 'super_migration:oracle' "unsuffixed super isolation"

# Exercise main rather than only its helpers. These fakes keep the test
# hermetic while proving argument parsing and init selection happen before any
# driver, wallet, lock, or SDCLI side effect.
main_tmpdir="$tmpdir/main"
TOOL_DATA="$main_tmpdir/data"
mkdir -p "$main_tmpdir"
: > "$main_tmpdir/config.yaml"
export INIT_MAIN_CALLS="$main_tmpdir/sdcli.calls"
CONFIG_FILE="$main_tmpdir/config.yaml"

require_command() { :; }
yq_eval() {
  [[ "$1" == '.migrations | length' ]] || fail_test "unexpected main yq lookup: $1"
  printf '%s\n' "${INIT_TEST_MIGRATION_COUNT:-2}"
}
migration_required_value() {
  local idx="$1"
  shift
  case "$idx:$*" in
    '0:name') printf 'proda\n' ;;
    '1:name') printf 'cecrealm\n' ;;
    *) fail_test "unexpected main migration lookup: $idx:$*" ;;
  esac
}
get_required_value() {
  case "$1" in
    '.defaults.paths.project_root') printf '%s\n' "$main_tmpdir/projects" ;;
    '.defaults.driver_file') printf '/vendor/jtds.jar\n' ;;
    '.migration_repository.name') printf 'repo\n' ;;
    '.migration_repository.repo_user.user') printf 'migrep\n' ;;
    '.migration_repository.super_user.user') printf 'admin\n' ;;
    *) fail_test "unexpected main required config lookup: $1" ;;
  esac
}
get_secret_value() {
  case "$1" in
    '.migration_repository.repo_user.password') printf 'repo_password\n' ;;
    '.migration_repository.super_user.password') printf 'super_password\n' ;;
    *) fail_test "unexpected main secret config lookup: $1" ;;
  esac
}
validate_config() { :; }
resolve_migration_context() {
  case "$1" in
    0)
      ACTIVE_MIGRATION_NAME='proda'
      ACTIVE_REPOSITORY_CONN='tcps://proda.example:1522/proda_high'
      ACTIVE_REPOSITORY_NAME='migration_repo_proda'
      ACTIVE_SUPER_CONNECTION_NAME='super_migration_proda'
      ;;
    1)
      ACTIVE_MIGRATION_NAME='cecrealm'
      ACTIVE_REPOSITORY_CONN='tcps://cecrealm.example:1522/cecrealm_high'
      ACTIVE_REPOSITORY_NAME='migration_repo_cecrealm'
      ACTIVE_SUPER_CONNECTION_NAME='super_migration_cecrealm'
      ;;
    *) fail_test "unexpected main repository context index: $1" ;;
  esac
  ACTIVE_WALLET_DIR=''
  ACTIVE_WALLET_CONFIG_PATH='.defaults.target.wallet_dir'
}
configure_active_oracle_wallet() { :; }
acquire_repository_lock() { :; }
validate_sdcli_conn_details_password() { :; }
run_sdcli() {
  [[ -n "$SDCLI_PROFILE_DIR" && "$PROFILE_LOCK_HELD" == true ]] || fail_test 'SDCLI started before project profile selection/locking'
  if [[ "$*" == *'-help=init'* ]]; then
    mkdir -p "$SDCLI_PROFILE_DIR/system26.2.0.186.2220/o.sqldeveloper"
  fi
  if [[ "${FAIL_MAIN_INIT:-false}" == true && "$*" == *'-actions=init'* ]]; then
    return 1
  fi
  printf '%s\n' "$*" >> "$INIT_MAIN_CALLS"
}

reset_main_state() {
  MIGRATION_NAME=''
  MODE='full'
  MODE_EXPLICIT=false
  PHASE_NAME=''
  MODEL_NAME_INPUT=''
  RUN_NAME_INPUT=''
  DRY_RUN=false
  RUN_NAME=''
  PROJECT_ROOT=''
  PROJECT_DIR=''
  RUN_DIR=''
  AUTOKIT_DIR=''
  SDCLI_OUTPUT_DIR=''
  RUN_LOG_FILE=''
  SDCLI_COMMAND_LOG=''
  SDCLI_SUMMARY_FILE=''
  MIGRATION_SUMMARY_FILE=''
  PHASE_STATUS_FILE=''
  ACTIVE_MIGRATION_NAME=''
  ACTIVE_REPOSITORY_CONN=''
  ACTIVE_REPOSITORY_NAME=''
  ACTIVE_SUPER_CONNECTION_NAME=''
}

assert_main_init_fails_without_sdcli() {
  local label="$1"
  shift
  local output rc
  : > "$INIT_MAIN_CALLS"
  reset_main_state
  set +e
  output="$(main "$@" 2>&1)"
  rc=$?
  set -e
  [[ $rc -ne 0 ]] || fail_test "$label unexpectedly succeeded"
  [[ ! -s "$INIT_MAIN_CALLS" ]] || fail_test "$label invoked SDCLI before failing"
  printf '%s' "$output"
}

INIT_TEST_MIGRATION_COUNT=2
multi_main_output="$(assert_main_init_fails_without_sdcli 'multi-migration unnamed init' --init)"
assert_contains "$multi_main_output" './migrate.sh <name> --init' "main multi-migration init guidance"
unknown_main_output="$(assert_main_init_fails_without_sdcli 'unknown migration init' missing --init)"
assert_contains "$unknown_main_output" "Migration 'missing' not found in config" "main unknown init rejection"

for migration_name in proda cecrealm; do
  : > "$INIT_MAIN_CALLS"
  reset_main_state
  main "$migration_name" --init
  [[ "$(awk -F '\t' '{print $2}' "$SDCLI_PROFILE_DIR/.autokit-profile")" == ready ]] || fail_test 'successful init did not mark the profile ready'
  release_profile_lock
  init_main_call="$(tail -n 1 "$INIT_MAIN_CALLS")"
  assert_contains "$init_main_call" "migration_repo_${migration_name}:mkrepouser" "main ${migration_name} repository alias"
  assert_contains "$init_main_call" "super_migration_${migration_name}:oracle" "main ${migration_name} super alias"
  assert_contains "$init_main_call" "${migration_name}.example:1522/${migration_name}_high" "main ${migration_name} endpoint"
  assert_not_contains "$init_main_call" 'legacy.example' "main ${migration_name} legacy endpoint isolation"
done

if (
  trap 'release_profile_lock' EXIT
  TOOL_DATA="$main_tmpdir/failed-data"
  FAIL_MAIN_INIT=true
  reset_main_state
  main proda --init
) >/dev/null 2>&1; then
  fail_test 'failed initialization unexpectedly succeeded'
fi
[[ "$(awk -F '\t' '{print $2}' "$main_tmpdir/failed-data/profiles/proda/.autokit-profile")" == pending ]] || fail_test 'failed init left a ready profile'

INIT_TEST_MIGRATION_COUNT=1
: > "$INIT_MAIN_CALLS"
reset_main_state
single_main_output="$(trap 'release_profile_lock' EXIT; main --init)"
assert_contains "$single_main_output" 'Inferred the only configured migration' "main single-migration init inference"
assert_contains "$(tail -n 1 "$INIT_MAIN_CALLS")" 'migration_repo_proda:mkrepouser' "main inferred repository alias"

echo "per-migration repository init test passed"
