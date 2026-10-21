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

migration_required_value() {
  local idx="$1"
  shift
  case "$idx:$*" in
    '0:name') printf 'proda\n' ;;
    '0:source conn') printf '10.0.0.10:1433:proda\n' ;;
    '0:target conn') printf 'tcps://proda.example:1522/proda_high\n' ;;
    '1:name') printf 'cecrealm\n' ;;
    '1:source conn') printf '10.0.0.11:1433:cecrealm\n' ;;
    '1:target conn') printf 'tcps://cecrealm.example:1522/cecrealm_high\n' ;;
    *) fail_test "unexpected migration config lookup: $idx:$*" ;;
  esac
}

get_required_value() {
  case "$1" in
    '.migration_repository.repo_user.connection_name') printf 'migration_repo\n' ;;
    '.migration_repository.super_user.connection_name') printf 'super_migration\n' ;;
    '.migration_repository.conn') printf 'tcps://legacy.example:1522/legacy\n' ;;
    *) fail_test "unexpected required config lookup: $1" ;;
  esac
}

get_optional_value() {
  case "$1" in
    '.defaults.target.wallet_dir') printf '/wallets/Wallet_default\n' ;;
    '.migrations[0].target.wallet_dir') printf '\n' ;;
    '.migrations[1].target.wallet_dir') printf '/wallets/Wallet_cecrealm\n' ;;
    *) fail_test "unexpected optional config lookup: $1" ;;
  esac
}

assert_context() {
  local index="$1"
  local migration="$2"
  local endpoint="$3"
  local repository="$4"
  local super_name="$5"
  local wallet="$6"

  resolve_migration_context "$index"
  assert_eq "$ACTIVE_MIGRATION_INDEX" "$index" "migration index"
  assert_eq "$ACTIVE_MIGRATION_NAME" "$migration" "migration name"
  assert_eq "$ACTIVE_REPOSITORY_CONN" "$endpoint" "repository endpoint"
  assert_eq "$ACTIVE_REPOSITORY_NAME" "$repository" "repository connection name"
  assert_eq "$ACTIVE_SUPER_CONNECTION_NAME" "$super_name" "super connection name"
  assert_eq "$ACTIVE_WALLET_DIR" "$wallet" "wallet directory"
  if [[ "$index" == '0' ]]; then
    assert_eq "$ACTIVE_WALLET_CONFIG_PATH" '.defaults.target.wallet_dir' "default wallet config path"
  else
    assert_eq "$ACTIVE_WALLET_CONFIG_PATH" ".migrations[$index].target.wallet_dir" "migration wallet config path"
  fi
}

(
  assert_context 0 proda 'tcps://proda.example:1522/proda_high' \
    migration_repo_proda super_migration_proda /wallets/Wallet_default
)

(
  assert_context 1 cecrealm 'tcps://cecrealm.example:1522/cecrealm_high' \
    migration_repo_cecrealm super_migration_cecrealm /wallets/Wallet_cecrealm
)

ACTIVE_MIGRATION_INDEX='0'
ACTIVE_MIGRATION_NAME='proda'
ACTIVE_REPOSITORY_CONN='tcps://proda.example:1522/proda_high'
ACTIVE_REPOSITORY_NAME='migration_repo_proda'
ACTIVE_SUPER_CONNECTION_NAME='super_migration_proda'
ACTIVE_WALLET_DIR='/wallets/Wallet_default'
resolve_migration_context 1
assert_eq "$ACTIVE_MIGRATION_NAME" cecrealm "replaced migration name"
assert_eq "$ACTIVE_REPOSITORY_CONN" 'tcps://cecrealm.example:1522/cecrealm_high' "replaced endpoint"
assert_eq "$ACTIVE_REPOSITORY_NAME" migration_repo_cecrealm "replaced repository name"
assert_eq "$ACTIVE_SUPER_CONNECTION_NAME" super_migration_cecrealm "replaced super name"
assert_eq "$ACTIVE_WALLET_DIR" /wallets/Wallet_cecrealm "replaced wallet"
assert_eq "$ACTIVE_WALLET_CONFIG_PATH" '.migrations[1].target.wallet_dir' "replaced wallet config path"

resolve_global_repository_context
assert_eq "$ACTIVE_MIGRATION_INDEX" '' "global context migration index"
assert_eq "$ACTIVE_MIGRATION_NAME" '' "global context migration name"
assert_eq "$ACTIVE_REPOSITORY_CONN" 'tcps://legacy.example:1522/legacy' "global repository endpoint"
assert_eq "$ACTIVE_REPOSITORY_NAME" migration_repo "global repository name"
assert_eq "$ACTIVE_SUPER_CONNECTION_NAME" super_migration "global super name"
assert_eq "$ACTIVE_WALLET_DIR" /wallets/Wallet_default "global wallet"
assert_eq "$ACTIVE_WALLET_CONFIG_PATH" '.defaults.target.wallet_dir' "global wallet config path"

declare -a phase_calls=()
run_phase() {
  phase_calls+=("$1|$2")
}
record_migration_completion() { :; }
log_info() { :; }
MODE='phase'
SDCLI_OUTPUT_DIR="$(mktemp -d)"
for phase_name in capture convert generate datamove; do
  PHASE_NAME="$phase_name"
  phase_calls=()
  resolve_migration_context 1
  run_single_migration 1
  assert_eq "${#phase_calls[@]}" 1 "${phase_name} phase call count"
  assert_eq "${phase_calls[0]}" "${phase_name}|migration_repo_cecrealm" "${phase_name} active repository"
done
rmdir "$SDCLI_OUTPUT_DIR"

invalid_wallet_output="$(
  ACTIVE_WALLET_DIR='/wallets/does-not-exist'
  ACTIVE_WALLET_CONFIG_PATH='.migrations[1].target.wallet_dir'
  configure_active_oracle_wallet 2>&1
)" || invalid_wallet_rc=$?
[[ "${invalid_wallet_rc:-0}" -ne 0 ]] || fail_test "invalid active wallet unexpectedly succeeded"
[[ "$invalid_wallet_output" == *'.migrations[1].target.wallet_dir'* ]] \
  || fail_test "invalid active wallet did not identify its selected config path"

echo "per-migration repository context test passed"
