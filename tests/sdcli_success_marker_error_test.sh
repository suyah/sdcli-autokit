#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATE_SH_SOURCE_ONLY=true source "$REPO_ROOT/sdcli-scripts/migrate.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "$tmpdir/bin"

cat > "$tmpdir/bin/sdcli" <<'SCRIPT'
#!/usr/bin/env bash
case "${FAKE_SDCLI_CASE:?}" in
  marker_and_ora)
    printf '%s\n' 'ORA-01017: invalid credential or not authorized'
    printf '%s\n' 'mkconn completed successfully'
    ;;
  benign_plus_other_ora)
    printf '%s\n' 'Error starting at line : 1 in command -'
    printf '%s\n' "ORA-01920: user name 'MIGREP' conflicts with another user or role name"
    printf '%s\n' 'ORA-01017: invalid credential or not authorized'
    printf '%s\n' 'init completed successfully'
    ;;
esac
exit 0
SCRIPT
chmod +x "$tmpdir/bin/sdcli"

PATH="$tmpdir/bin:$PATH"
RUN_LOG_FILE="$tmpdir/run.log"
touch "$RUN_LOG_FILE"
DRY_RUN=false

assert_fails() {
  local fake_case="$1"
  local action="$2"
  local rc
  export FAKE_SDCLI_CASE="$fake_case"
  set +e
  run_sdcli sdcli migration "-actions=$action" -connDetails=bad_connection >/dev/null
  rc=$?
  set -e
  [[ $rc -ne 0 ]] || {
    echo "$fake_case unexpectedly returned success" >&2
    exit 1
  }
}

assert_fails marker_and_ora mkconn
assert_fails benign_plus_other_ora init

echo "sdcli success marker error test passed"
