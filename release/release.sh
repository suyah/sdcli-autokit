#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  echo "Usage: release.sh <version>" >&2
}

if [[ $# -ne 1 ]]; then
  usage
  exit 1
fi

VERSION="$1"
case "${RELEASE_SKIP_TESTS:-false}" in
  false|true) ;;
  *) echo "Error: RELEASE_SKIP_TESTS must be true or false" >&2; exit 1 ;;
esac

"$ROOT_DIR/release/preflight.sh" "$VERSION"

if [[ "${RELEASE_SKIP_TESTS:-false}" == true ]]; then
  echo "Release test suite skipped by RELEASE_SKIP_TESTS=true"
else
  bash -n "$ROOT_DIR"/sdcli-scripts/migrate.sh \
    "$ROOT_DIR"/sdcli-scripts/lib/*.sh \
    "$ROOT_DIR"/deployment/*.sh \
    "$ROOT_DIR"/release/*.sh

  while IFS= read -r test_file; do
    bash -n "$ROOT_DIR/$test_file"
    bash "$ROOT_DIR/$test_file"
  done < <(git -C "$ROOT_DIR" ls-files 'tests/*.sh')

  (
    cd "$ROOT_DIR"
    python3 -m unittest discover -s tests -p 'test_validation_report.py' -v
  )
fi

"$ROOT_DIR/release/build-offline.sh" "$VERSION"
