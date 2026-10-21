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
    '0:target conn') printf 'tcps://proda.example:1522/proda_high\n' ;;
    '1:name') printf 'cecrealm\n' ;;
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

resolve_global_repository_context
assert_eq "$ACTIVE_MIGRATION_INDEX" '' "global context migration index"
assert_eq "$ACTIVE_MIGRATION_NAME" '' "global context migration name"
assert_eq "$ACTIVE_REPOSITORY_CONN" 'tcps://legacy.example:1522/legacy' "global repository endpoint"
assert_eq "$ACTIVE_REPOSITORY_NAME" migration_repo "global repository name"
assert_eq "$ACTIVE_SUPER_CONNECTION_NAME" super_migration "global super name"
assert_eq "$ACTIVE_WALLET_DIR" /wallets/Wallet_default "global wallet"

echo "per-migration repository context test passed"
