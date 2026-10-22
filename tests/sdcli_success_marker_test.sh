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
printf '%s\n' 'Error starting at line : 1 in command -'
printf '%s\n' "ORA-01920: user name 'MIGREP' conflicts with another user or role name"
printf '%s\n' 'init completed successfully'
exit 0
SCRIPT
chmod +x "$tmpdir/bin/sdcli"

PATH="$tmpdir/bin:$PATH"
RUN_LOG_FILE="$tmpdir/run.log"
touch "$RUN_LOG_FILE"
DRY_RUN=false

run_sdcli sdcli migration -actions=init -connDetails=repository_init

grep -F 'init completed successfully' "$RUN_LOG_FILE" >/dev/null

echo "sdcli success marker test passed"
