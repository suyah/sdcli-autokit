#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATE_SH_SOURCE_ONLY=true source "$REPO_ROOT/sdcli-scripts/migrate.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

PROJECT_ROOT="$tmpdir/projects"
MIGRATION_NAME="demo"
MODE="phase"
PHASE_NAME="convert"
RUN_NAME_INPUT="20261012_100000"
mkdir -p "$PROJECT_ROOT/demo/run_20261012_100000/sdcli" "$PROJECT_ROOT/demo/run_20261012_100000/autokit"

get_required_value() {
  [[ "$1" == ".defaults.paths.project_root" ]] && echo "$PROJECT_ROOT"
}

summary="$PROJECT_ROOT/demo/run_20261012_100000/autokit/migration_summary.csv"
printf '%s\n' 'timestamp,migration,status,model_name,output_dir,duration_sec,note' > "$summary"
printf '%s\n' 'old,entry,must,remain,here,0,""' >> "$summary"

bootstrap_logging
grep -F 'old,entry,must,remain,here' "$MIGRATION_SUMMARY_FILE" >/dev/null

begin_phase_status convert
complete_phase_status convert
phase_succeeded convert

set +e
( begin_phase_status convert ) >/dev/null 2>&1
repeat_rc=$?
set -e
[[ $repeat_rc -ne 0 ]]

RERUN_COMPLETED=true
begin_phase_status convert
complete_phase_status convert
grep -F $'convert\tstarted\t\t2\toperator requested rerun of completed phase' "$PHASE_STATUS_FILE" >/dev/null

echo "phase status resume test passed"
