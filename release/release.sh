#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  echo "Usage: release.sh <version> [--verify] [--rebuild]" >&2
}

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

VERSION="$1"
shift

VERIFY=false
REBUILD=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --verify)
      [[ "$VERIFY" == false ]] || {
        echo "Error: duplicate option: --verify" >&2
        exit 1
      }
      VERIFY=true
      ;;
    --rebuild)
      [[ "$REBUILD" == false ]] || {
        echo "Error: duplicate option: --rebuild" >&2
        exit 1
      }
      REBUILD=true
      ;;
    *)
      echo "Error: unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
  shift
done

"$ROOT_DIR/release/preflight.sh" "$VERSION"

if [[ "$VERIFY" == true ]]; then
  case "${RELEASE_SKIP_TESTS:-false}" in
    false|true) ;;
    *) echo "Error: RELEASE_SKIP_TESTS must be true or false" >&2; exit 1 ;;
  esac

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
fi

if [[ "$REBUILD" == true ]]; then
  bash "$ROOT_DIR/release/build-image.sh" "$VERSION"
fi

"$ROOT_DIR/release/build-offline.sh" "$VERSION"
