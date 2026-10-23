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

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  if [[ "$haystack" == *"$needle"* ]]; then
    echo "Expected output not to contain: $needle" >&2
    echo "$haystack" >&2
    exit 1
  fi
}

tmpdir="$(mktemp -d)"
SDCLI_PROFILE_DIR="$tmpdir/profile"
trap 'rm -rf "$tmpdir"' EXIT

fakebin="$tmpdir/bin"
mkdir -p "$fakebin"
cat > "$fakebin/sdcli" <<'SCRIPT'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$SDCLI_CAPTURE_FILE"
printf 'diagnostic credential=%s\n' "$SDCLI_TEST_CREDENTIAL"
printf '%s\n' \
  'Oracle SQL Developer' \
  'Copyright (c) 2005, 2026, Oracle and/or its affiliates. All rights reserved.' \
  'OpenJDK 64-Bit Server VM warning: Options -Xverify:none and -noverify were deprecated in JDK 13 and will likely be removed in a future release.' \
  'WARNING: A terminally deprecated method in java.lang.System has been called' \
  'WARNING: System::setSecurityManager has been called by oracle.ide.IdeCore (file:/u01/app/sqldeveloper/ide/extensions/oracle.ide.jar)' \
  'WARNING: Please consider reporting this to the maintainers of oracle.ide.IdeCore' \
  'WARNING: System::setSecurityManager has been called by org.netbeans.TopSecurityManager (file:/u01/app/sqldeveloper/netbeans/platform/lib/boot.jar)' \
  'WARNING: Please consider reporting this to the maintainers of org.netbeans.TopSecurityManager' \
  'WARNING: System::setSecurityManager will be removed in a future release' \
  'Warning: connection certificate requires attention'
printf 'mkconn completed successfully\n'
SCRIPT
chmod +x "$fakebin/sdcli"

export PATH="$fakebin:$PATH"
export SDCLI_CAPTURE_FILE="$tmpdir/sdcli.args"
export SDCLI_TEST_CREDENTIAL='P@ss!word#9'

RUN_LOG_FILE="$tmpdir/migrate.log"
SDCLI_COMMAND_LOG="$tmpdir/sdcli_commands.log"
SDCLI_SUMMARY_FILE="$tmpdir/sdcli_summary.log"
touch "$RUN_LOG_FILE" "$SDCLI_COMMAND_LOG"

# Register an overlapping suffix first to prove that the complete credential is
# still removed before any shorter literal.
register_sensitive_value 'word#9'
validate_sdcli_conn_details_password "source password" "$SDCLI_TEST_CREDENTIAL"
console_output="$(run_sdcli sdcli migration -actions=mkconn \
  -connDetails="src_test:sqlserver:sa/${SDCLI_TEST_CREDENTIAL}@db.example:1433:test")"
write_sdcli_summary success

assert_not_contains "$console_output" 'Oracle SQL Developer'
assert_not_contains "$console_output" 'Copyright (c)'
assert_not_contains "$console_output" 'OpenJDK 64-Bit Server VM warning:'
assert_not_contains "$console_output" 'System::setSecurityManager'
assert_not_contains "$console_output" 'terminally deprecated method'
assert_not_contains "$console_output" 'Please consider reporting'
assert_contains "$console_output" 'Warning: connection certificate requires attention'
assert_contains "$console_output" 'mkconn completed successfully'
assert_contains "$(cat "$RUN_LOG_FILE")" 'Oracle SQL Developer'
assert_contains "$(cat "$RUN_LOG_FILE")" 'OpenJDK 64-Bit Server VM warning:'
assert_contains "$(cat "$RUN_LOG_FILE")" 'System::setSecurityManager'

captured_args="$(cat "$SDCLI_CAPTURE_FILE")"
assert_contains "$captured_args" "sa/${SDCLI_TEST_CREDENTIAL}@db.example:1433:test"

logged_output="$console_output
$(cat "$RUN_LOG_FILE")
$(cat "$SDCLI_COMMAND_LOG")
$(cat "$SDCLI_SUMMARY_FILE")"
assert_not_contains "$logged_output" "$SDCLI_TEST_CREDENTIAL"
assert_not_contains "$logged_output" 'P@ss!'
assert_not_contains "$logged_output" 'word#9'

set +e
unsupported_output="$(validate_sdcli_conn_details_password "source password" 'bad,password' 2>&1)"
unsupported_rc=$?
set -e
[[ $unsupported_rc -ne 0 ]]
assert_contains "$unsupported_output" "source password"
assert_contains "$unsupported_output" "unsupported"
assert_not_contains "$unsupported_output" "bad,password"

echo "sdcli output redaction test passed"
