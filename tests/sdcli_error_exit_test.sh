#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATE_SH_SOURCE_ONLY=true source "$REPO_ROOT/sdcli-scripts/migrate.sh"

tmpdir="$(mktemp -d)"
SDCLI_PROFILE_DIR="$tmpdir/profile"
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "$tmpdir/bin"

cat > "$tmpdir/bin/sdcli" <<'SCRIPT'
#!/usr/bin/env bash
case "${FAKE_SDCLI_CASE:?}" in
  fatal)
    printf '%s\n' 'Fatal: cannot create the requested connection'
    ;;
  bare_ora)
    printf '%s\n' 'ORA-01017: invalid credential or not authorized'
    ;;
  missing_marker)
    printf '%s\n' 'Driver Preferences Saved'
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

assert_fails fatal mkconn
grep -F 'Fatal: cannot create the requested connection' "$RUN_LOG_FILE" >/dev/null
assert_fails bare_ora mkconn
assert_fails missing_marker driver

echo "sdcli error exit test passed"
