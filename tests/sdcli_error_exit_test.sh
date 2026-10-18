#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATE_SH_SOURCE_ONLY=true source "$REPO_ROOT/sdcli-scripts/migrate.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "$tmpdir/bin"

cat > "$tmpdir/bin/sdcli" <<'SCRIPT'
#!/usr/bin/env bash
printf '%s\n' 'Fatal: cannot create the requested connection'
exit 0
SCRIPT
chmod +x "$tmpdir/bin/sdcli"

PATH="$tmpdir/bin:$PATH"
RUN_LOG_FILE="$tmpdir/run.log"
touch "$RUN_LOG_FILE"
DRY_RUN=false

set +e
run_sdcli sdcli migration -actions=mkconn -connDetails=bad_connection >/dev/null
rc=$?
set -e

[[ $rc -ne 0 ]] || {
  echo "Fatal SDCLI output unexpectedly returned success" >&2
  exit 1
}
grep -F 'Fatal: cannot create the requested connection' "$RUN_LOG_FILE" >/dev/null

echo "sdcli error exit test passed"
