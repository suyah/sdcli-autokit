#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

MIGRATE_SH_SOURCE_ONLY=true source "$REPO_ROOT/sdcli-scripts/migrate.sh"

TEST_WALLET_DIR="$tmpdir/Wallet_example"
mkdir -p "$TEST_WALLET_DIR"
touch "$TEST_WALLET_DIR/tnsnames.ora" "$TEST_WALLET_DIR/sqlnet.ora" "$TEST_WALLET_DIR/cwallet.sso"

get_optional_value() {
  [[ "$1" == '.defaults.target.wallet_dir' ]] || return 1
  printf '%s\n' "$TEST_WALLET_DIR"
}

unset TNS_ADMIN JAVA_TOOL_OPTIONS
configure_oracle_wallet

[[ "$ORACLE_WALLET_DIR" == "$TEST_WALLET_DIR" ]]
[[ "$TNS_ADMIN" == "$TEST_WALLET_DIR" ]]
[[ "$JAVA_TOOL_OPTIONS" == "-Doracle.net.tns_admin=$TEST_WALLET_DIR" ]]

rm -f "$TEST_WALLET_DIR/tnsnames.ora"
set +e
error_output="$(configure_oracle_wallet 2>&1)"
error_rc=$?
set -e

[[ $error_rc -ne 0 ]]
[[ "$error_output" == *"missing tnsnames.ora"* ]]

echo "oracle wallet configuration test passed"
