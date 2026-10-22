#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

MIGRATE_SH_SOURCE_ONLY=true source "$REPO_ROOT/sdcli-scripts/migrate.sh"

assert_eq() {
  local actual="$1"
  local expected="$2"
  if [[ "$actual" != "$expected" ]]; then
    echo "Expected: $expected" >&2
    echo "Actual:   $actual" >&2
    exit 1
  fi
}

tmpdir="$(mktemp -d)"
SDCLI_PROFILE_DIR="$tmpdir/profile"
trap 'rm -rf "$tmpdir"' EXIT

RUN_ID="20260427_001939"
MODE="phase"
PHASE_NAME="capture"
MIGRATION_NAME="tpcc"
ACTIVE_REPOSITORY_NAME="migration_repo_tpcc"
ACTIVE_REPOSITORY_CONN='tcps://adb.example/tpcc'

get_required_value() {
  case "$1" in
    ".defaults.paths.project_root") echo "$tmpdir/projects" ;;
    ".migrations[0].name") echo "tpcc" ;;
    ".migrations[0].source.conn") echo "10.0.1.165:1433:tpcc" ;;
    *) echo "unexpected config path: $1" >&2; return 1 ;;
  esac
}

bootstrap_logging

assert_eq "$RUN_NAME" "run_20260427_001939"
assert_eq "$PROJECT_DIR" "$tmpdir/projects/tpcc"
assert_eq "$RUN_DIR" "$tmpdir/projects/tpcc/run_20260427_001939"
assert_eq "$AUTOKIT_DIR" "$tmpdir/projects/tpcc/run_20260427_001939/autokit"
assert_eq "$SDCLI_OUTPUT_DIR" "$tmpdir/projects/tpcc/run_20260427_001939/sdcli"
assert_eq "$RUN_LOG_FILE" "$tmpdir/projects/tpcc/run_20260427_001939/autokit/migrate.log"
assert_eq "$SDCLI_COMMAND_LOG" "$tmpdir/projects/tpcc/run_20260427_001939/autokit/sdcli_commands.log"
assert_eq "$SDCLI_SUMMARY_FILE" "$tmpdir/projects/tpcc/run_20260427_001939/autokit/sdcli_commands_summary.txt"
assert_eq "$MIGRATION_SUMMARY_FILE" "$tmpdir/projects/tpcc/run_20260427_001939/autokit/migration_summary.csv"

DRY_RUN=true
output="$(run_single_migration 0)"
assert_eq "$(printf '%s\n' "$output" | sed -n 's/.*Output directory: //p')" "$SDCLI_OUTPUT_DIR"

RUN_NAME_INPUT="20260427_014117"
RUN_NAME=""
PROJECT_DIR=""
RUN_DIR=""
AUTOKIT_DIR=""
SDCLI_OUTPUT_DIR=""
RUN_LOG_FILE=""
SDCLI_COMMAND_LOG=""
SDCLI_SUMMARY_FILE=""
MIGRATION_SUMMARY_FILE=""
mkdir -p "$tmpdir/projects/tpcc/run_20260427_014117/sdcli"

bootstrap_logging

assert_eq "$RUN_NAME" "run_20260427_014117"
assert_eq "$PROJECT_DIR" "$tmpdir/projects/tpcc"
assert_eq "$RUN_DIR" "$tmpdir/projects/tpcc/run_20260427_014117"
assert_eq "$AUTOKIT_DIR" "$tmpdir/projects/tpcc/run_20260427_014117/autokit"
assert_eq "$SDCLI_OUTPUT_DIR" "$tmpdir/projects/tpcc/run_20260427_014117/sdcli"

MODE="init"
MIGRATION_NAME="tpcc"
RUN_NAME_INPUT=""
RUN_NAME=""
PROJECT_DIR=""
RUN_DIR=""
AUTOKIT_DIR=""
SDCLI_OUTPUT_DIR=""
bootstrap_logging

assert_eq "$PROJECT_DIR" "$tmpdir/projects/_init/tpcc"
assert_eq "$RUN_DIR" "$tmpdir/projects/_init/tpcc/run_20260427_001939"
