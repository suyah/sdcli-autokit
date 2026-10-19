#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATE_SH_SOURCE_ONLY=true source "$REPO_ROOT/sdcli-scripts/migrate.sh"

assert_contains() {
  local haystack="$1"
  local needle="$2"
  if [[ "$haystack" != *"$needle"* ]]; then
    echo "Expected output to contain: $needle" >&2
    echo "$haystack" >&2
    exit 1
  fi
}

TEST_SOURCE_TYPE=""
TEST_TARGET_TYPE=""

yq_eval() {
  case "$1" in
    '.defaults.source.type') printf '%s\n' "$TEST_SOURCE_TYPE" ;;
    '.defaults.target.type') printf '%s\n' "$TEST_TARGET_TYPE" ;;
    *) printf 'null\n' ;;
  esac
}

TEST_SOURCE_TYPE="SQLSERVER"
TEST_TARGET_TYPE="ORACLE"
validate_supported_migration_pair

TEST_SOURCE_TYPE="postgresql"
TEST_TARGET_TYPE="oracle"
set +e
unsupported_source_output="$(validate_supported_migration_pair 2>&1)"
unsupported_source_rc=$?
set -e
[[ $unsupported_source_rc -ne 0 ]]
assert_contains "$unsupported_source_output" "Unsupported migration pair: postgresql -> oracle"
assert_contains "$unsupported_source_output" "Supported migration pair: sqlserver -> oracle"

TEST_SOURCE_TYPE="sqlserver"
TEST_TARGET_TYPE="postgresql"
set +e
unsupported_target_output="$(validate_supported_migration_pair 2>&1)"
unsupported_target_rc=$?
set -e
[[ $unsupported_target_rc -ne 0 ]]
assert_contains "$unsupported_target_output" "Unsupported migration pair: sqlserver -> postgresql"

TEST_SOURCE_TYPE=""
TEST_TARGET_TYPE="oracle"
set +e
missing_source_output="$(validate_supported_migration_pair 2>&1)"
missing_source_rc=$?
set -e
[[ $missing_source_rc -ne 0 ]]
assert_contains "$missing_source_output" "Missing required config: defaults.source.type"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
CONFIG_FILE="$tmpdir/config.yaml"
touch "$CONFIG_FILE"
bootstrap_marker="$tmpdir/bootstrap-called"
external_marker="$tmpdir/external-called"

TEST_SOURCE_TYPE="postgresql"
TEST_TARGET_TYPE="oracle"

yq_eval() {
  case "$1" in
    '.defaults.source.type') printf '%s\n' "$TEST_SOURCE_TYPE" ;;
    '.defaults.target.type') printf '%s\n' "$TEST_TARGET_TYPE" ;;
    '.defaults.driver_file') printf '/u01/app/jtds.jar\n' ;;
    '.defaults.paths.project_root') printf '%s/projects\n' "$tmpdir" ;;
    '.defaults.source.bcp_tls_mode') printf 'optional\n' ;;
    '.migration_repository.name') printf 'repo\n' ;;
    '.migration_repository.conn') printf 'oracle.example/service\n' ;;
    '.migration_repository.repo_user.connection_name') printf 'migration_repo\n' ;;
    '.migration_repository.repo_user.user') printf 'migrep\n' ;;
    '.migration_repository.super_user.connection_name') printf 'super_migration\n' ;;
    '.migration_repository.super_user.user') printf 'admin\n' ;;
    *) printf 'null\n' ;;
  esac
}

parse_args() {
  MODE="init"
  MIGRATION_NAME=""
}
require_command() { :; }
bootstrap_logging() { touch "$bootstrap_marker"; }
validate_secret_placeholder() { :; }
validate_load_preferences() { :; }
get_bcp_packet_size() { printf '65535\n'; }
configure_oracle_wallet() { :; }
configure_sqldeveloper_file_output_option() { :; }
mode_needs_repository_lock() { return 1; }
setup_repository() { touch "$external_marker"; }

set +e
main_output="$(main --init 2>&1)"
main_rc=$?
set -e

[[ $main_rc -ne 0 ]] || {
  echo "Unsupported migration pair unexpectedly passed main preflight" >&2
  exit 1
}
assert_contains "$main_output" "Unsupported migration pair: postgresql -> oracle"
[[ ! -e "$bootstrap_marker" ]] || {
  echo "bootstrap_logging ran before database-pair validation" >&2
  exit 1
}
[[ ! -e "$external_marker" ]] || {
  echo "External setup ran for an unsupported migration pair" >&2
  exit 1
}

echo "database type preflight test passed"
