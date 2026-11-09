#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATE_SH_SOURCE_ONLY=true source "$REPO_ROOT/sdcli-scripts/migrate.sh"
task_tmp="$(mktemp -d)"
trap 'rm -rf "$task_tmp"' EXIT
mkdir -p "$task_tmp/bin"
cat > "$task_tmp/bin/sdcli" <<'SH'
#!/usr/bin/env bash
case "$TEST_COMBO_MODE" in
  error) printf 'Error:\nEither input or output action needs to be specified.\n' ;;
  missing) printf 'convert completed successfully\n'; exit 0 ;;
esac
printf 'idmap completed successfully\nconvert completed successfully\n'
SH
chmod +x "$task_tmp/bin/sdcli"
export PATH="$task_tmp/bin:$PATH"
RUN_LOG_FILE="$task_tmp/run.log"
SDCLI_PROFILE_DIR="$task_tmp/profile"
export TEST_COMBO_MODE=ok
run_sdcli sdcli migration -actions=idmap,convert -model=1 -input=/example.xml
for TEST_COMBO_MODE in error missing; do
  export TEST_COMBO_MODE
  if run_sdcli sdcli migration -actions=idmap,convert -model=1 -input=/example.xml; then
    echo "Combined action incorrectly accepted $TEST_COMBO_MODE" >&2; exit 1
  fi
done
echo 'sdcli combined action test passed'
