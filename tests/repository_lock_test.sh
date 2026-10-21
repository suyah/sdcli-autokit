#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATE_SH_SOURCE_ONLY=true source "$REPO_ROOT/sdcli-scripts/migrate.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

PROJECT_ROOT="$tmpdir/projects"
RUN_ID="20261012_100000"
MIGRATION_NAME="demo"
ACTIVE_MIGRATION_NAME="demo"
ACTIVE_REPOSITORY_NAME="migration_repo_demo"
ACTIVE_REPOSITORY_CONN='tcps://adb.example/service'
RUN_LOG_FILE="$tmpdir/run.log"
mkdir -p "$PROJECT_ROOT"
touch "$RUN_LOG_FILE"

acquire_repository_lock
[[ -d "$REPOSITORY_LOCK_DIR" ]]
grep -F 'migration=demo' "$REPOSITORY_LOCK_DIR/owner" >/dev/null
if grep -F 'adb.example' "$REPOSITORY_LOCK_DIR/owner" >/dev/null; then
  echo "Repository connection should not be written to lock metadata" >&2
  exit 1
fi

lock_dir="$REPOSITORY_LOCK_DIR"
set +e
(
  REPOSITORY_LOCK_HELD=false
  REPOSITORY_LOCK_DIR=""
  acquire_repository_lock
) >/dev/null 2>&1
second_rc=$?
set -e
[[ $second_rc -ne 0 ]]

release_repository_lock
[[ ! -e "$lock_dir" ]]

ACTIVE_REPOSITORY_CONN='tcps://other-adb.example/service'
acquire_repository_lock
[[ "$REPOSITORY_LOCK_DIR" != "$lock_dir" ]] || {
  echo "Different migration repository endpoint reused the same lock" >&2
  exit 1
}
release_repository_lock

echo "repository lock test passed"
