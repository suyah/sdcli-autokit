#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATE_SH_SOURCE_ONLY=true source "$REPO_ROOT/sdcli-scripts/migrate.sh"
task_tmp="$(mktemp -d)"
trap 'rm -rf "$task_tmp"' EXIT
AUTOKIT_DIR="$task_tmp/autokit"
mkdir -p "$AUTOKIT_DIR"
RUN_LOG_FILE="$AUTOKIT_DIR/migrate.log"
printf 'historical ERROR\nSQL*Loader-292: informational\n' > "$RUN_LOG_FILE"
run_data_reconciliation() { printf 'fresh reconciliation\n' > "$AUTOKIT_DIR/reconciliation.tsv"; }
collect_target_object_diagnostics() {
  [[ ! -e "$3" ]] || { echo 'Stale diagnostics retained' >&2; return 1; }
  printf 'fresh CSV\n' > "$3"
}
run_validation_report() { return "${TEST_REPORT_RC:-0}"; }
run_validate "$task_tmp/sdcli" 0
for TEST_REPORT_RC in 2 1; do
  if run_validate "$task_tmp/sdcli" 0 > "$task_tmp/report.out" 2>&1; then
    echo 'Validation ignored the renderer result' >&2; exit 1
  fi
  if [[ "$TEST_REPORT_RC" == 1 ]]; then
    grep -F 'Report generation failed' "$task_tmp/report.out" >/dev/null || {
      echo 'Renderer failure did not warn about stale reports' >&2; exit 1
    }
  fi
done
TEST_REPORT_RC=0
collect_target_object_diagnostics() { return 1; }
run_validation_report() {
  [[ ! -e "$AUTOKIT_DIR/target_object_diagnostics.csv" ]]
  return 2
}
if run_validate "$task_tmp/sdcli" 0; then
  echo 'Failed collection produced validation success' >&2; exit 1
fi
echo 'validate phase test passed'
