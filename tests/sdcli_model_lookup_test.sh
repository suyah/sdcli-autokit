#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATE_SH_SOURCE_ONLY=true source "$REPO_ROOT/sdcli-scripts/migrate.sh"
task_tmp="$(mktemp -d)"
trap 'rm -rf "$task_tmp"' EXIT
mkdir -p "$task_tmp/bin" "$task_tmp/autokit"
SDCLI_PROFILE_DIR="$task_tmp/profile"
ACTIVE_REPOSITORY_NAME=migration_repo_demo
ACTIVE_REPOSITORY_CONN=demo.example/service
AUTOKIT_DIR="$task_tmp/autokit"
PHASE_STATUS_FILE="$AUTOKIT_DIR/phase_status.tsv"
RUN_LOG_FILE="$AUTOKIT_DIR/migrate.log"
RUN_NAME=run_20261019_100000
export EXPECTED_MODEL=demo_20261019_100000
export MODEL_STYLE=normal
export MODEL_PROFILE_LOG="$task_tmp/profile-used"
cat > "$task_tmp/bin/sdcli" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$IDE_USER_DIR" > "$MODEL_PROFILE_LOG"
for arg in "$@"; do
  [[ "$arg" != -actions=* ]] || action="${arg#-actions=}"
done
case "$action" in
  lscaptured|lsconverted)
    case "$MODEL_STYLE" in
      normal) printf '(2) --> Model Name : %s\n' "$EXPECTED_MODEL" ;;
      converted) printf '(1) --> Model Name : Converted:%s\n' "$EXPECTED_MODEL" ;;
      ambiguous) printf '(1) --> Model Name : %s\n(2) --> Model Name : %s\n' "$EXPECTED_MODEL" "$EXPECTED_MODEL" ;;
      malformed) printf '1) --> Model Name : %s\n' "$EXPECTED_MODEL" ;;
      missing) : ;;
    esac
    ;;
esac
[[ "$MODEL_STYLE" != no_completion ]] || exit 0
printf '%s completed successfully\n' "$action"
SH
chmod +x "$task_tmp/bin/sdcli"
export PATH="$task_tmp/bin:$PATH"
check_source_tcp_connectivity() { :; }
migration_required_value() { printf '%s\n' 'db.example:1433:demo'; }
has_schema_mapping() { return 1; }

run_phase capture repo src target "$EXPECTED_MODEL" demo "$task_tmp/output" 0
[[ "$SDCLI_VERIFIED_MODEL_INDEX" == 2 ]]
run_phase convert repo src target 2 demo "$task_tmp/output" 0
[[ "$SDCLI_VERIFIED_MODEL_INDEX" == 2 ]]
[[ "$(cat "$MODEL_PROFILE_LOG")" == "$SDCLI_PROFILE_DIR" ]]
MODEL_STYLE=converted
lookup_sdcli_model_index convert "$EXPECTED_MODEL"
[[ "$SDCLI_VERIFIED_MODEL_INDEX" == 1 ]]
if lookup_sdcli_model_index capture "$EXPECTED_MODEL" >/dev/null 2>&1; then
  echo 'Converted name incorrectly matched captured model' >&2; exit 1
fi
for MODEL_STYLE in ambiguous malformed missing; do
  SDCLI_VERIFIED_MODEL_INDEX=99
  if lookup_sdcli_model_index capture "$EXPECTED_MODEL" >/dev/null 2>&1; then
    echo "Incorrectly accepted $MODEL_STYLE model list" >&2; exit 1
  fi
  [[ -z "$SDCLI_VERIFIED_MODEL_INDEX" ]]
done

# No generated-output layout inspection belongs to these native SDCLI phases.
MODEL_STYLE=normal
run_phase generate repo src target 2 demo "$task_tmp/no-output" 0
run_phase datamove repo src target 2 demo "$task_tmp/no-output" 0
phase_succeeded generate
phase_succeeded datamove

for MODEL_STYLE in missing no_completion; do
  RERUN_COMPLETED=true
  if (run_phase capture repo src target "$EXPECTED_MODEL" demo "$task_tmp/output" 0) >/dev/null 2>&1; then
    echo "Capture incorrectly accepted $MODEL_STYLE" >&2; exit 1
  fi
  if phase_succeeded capture; then
    echo 'Failed capture retained a successful phase state' >&2; exit 1
  fi
done
echo 'SDCLI model lookup test passed'
