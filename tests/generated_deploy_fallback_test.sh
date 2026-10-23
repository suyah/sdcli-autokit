#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATE_SH_SOURCE_ONLY=true source "$REPO_ROOT/sdcli-scripts/migrate.sh"

assert_contains() {
  [[ "$1" == *"$2"* ]] || {
    echo "Expected output to contain: $2" >&2
    exit 1
  }
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

RUN_DIR="$tmpdir/run"
AUTOKIT_DIR="$RUN_DIR/autokit"
output_dir="$RUN_DIR/sdcli"
mkdir -p "$AUTOKIT_DIR" "$output_dir/gen"
printf '%s\n' 'ACCEPT app_password PROMPT "Application password: " HIDE' > "$output_dir/passworddefinition.sql"
touch "$output_dir/gen/generated-main.sql"

get_required_value() {
  case "$1" in
    ".migrations[0].target.conn") echo "adb.example/high" ;;
    ".migrations[0].target.user") echo "admin" ;;
    *) return 1 ;;
  esac
}

get_secret_value() {
  case "$1" in
    ".migrations[0].target.password") echo "AdminPass1" ;;
    ".migrations[0].target.default_schema_password") echo "SchemaPass1" ;;
    *) return 1 ;;
  esac
}

calls_file="$tmpdir/sqlplus-calls.log"
: > "$calls_file"
run_sqlplus_file() {
  printf '%s\n' "$2|${6:-}|${7:-0}|${8:-}" >> "$calls_file"
}

DRY_RUN=false
RUN_LOG_FILE="$tmpdir/run.log"
touch "$RUN_LOG_FILE"

set +e
fallback_output="$({ run_deploy 0 "$output_dir"; } 2>&1)"
fallback_rc=$?
set -e
[[ $fallback_rc -ne 0 ]] || {
  echo "Monolithic generated SQL layout unexpectedly deployed" >&2
  exit 1
}
assert_contains "$fallback_output" "Unsupported generated SQL layout"
[[ ! -s "$calls_file" ]] || {
  echo "Monolithic layout reached SQL*Plus" >&2
  cat "$calls_file" >&2
  exit 1
}

assert_nested_layout_supported() {
  local fixture_name="$1"
  local nested_kind="$2"
  local fixture_dir="$tmpdir/$fixture_name"
  local fixture_output="$fixture_dir/sdcli"
  local output rc

  RUN_DIR="$fixture_dir"
  AUTOKIT_DIR="$fixture_dir/autokit"
  mkdir -p "$AUTOKIT_DIR" "$fixture_output/app"
  : > "$fixture_output/passworddefinition.sql"
  touch "$fixture_output/app/user.sql"
  case "$nested_kind" in
    post)
      printf '%s\n' '@@"app/post/compile.sql"' > "$fixture_output/app/post.sql"
      mkdir -p "$fixture_output/app/post"
      touch "$fixture_output/app/post/compile.sql"
      : > "$fixture_output/app/master.sql"
      ;;
    group)
      printf '%s\n' '@@"app/routines/procedure.sql"' > "$fixture_output/app/routines.sql"
      mkdir -p "$fixture_output/app/routines"
      touch "$fixture_output/app/routines/procedure.sql"
      printf '%s\n' '@"app/routines.sql"' > "$fixture_output/app/master.sql"
      ;;
  esac
  : > "$calls_file"

  set +e
  output="$({ run_deploy 0 "$fixture_output"; } 2>&1)"
  rc=$?
  set -e
  [[ $rc -eq 0 ]] || {
    echo "$fixture_name failed to deploy: $output" >&2
    exit 1
  }
  grep -F 'app/user.sql|' "$calls_file" >/dev/null || {
    echo "$fixture_name did not deploy its schema" >&2
    exit 1
  }
  run_postdeploy 0 "$fixture_output"
  case "$nested_kind" in
    post) grep -F 'app/post.sql|' "$calls_file" >/dev/null ;;
    group) grep -F 'app/routines.sql|' "$calls_file" >/dev/null ;;
  esac
  if grep -Eq 'app/(post/compile|routines/procedure)\.sql\|' "$calls_file"; then
    echo "Nested children must be executed by their parent SQL script, not scheduled twice" >&2
    exit 1
  fi
}

assert_nested_layout_supported nested-post post
assert_nested_layout_supported nested-group group

echo "generated deploy fallback test passed"
