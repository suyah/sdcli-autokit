#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"
CHANGELOG_FILE="${RELEASE_CHANGELOG_FILE:-$ROOT_DIR/docs/CHANGELOG.md}"

usage() {
  echo "Usage: preflight.sh <version>" >&2
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

if [[ $# -ne 1 ]]; then
  usage
  exit 1
fi

VERSION="$1"
[[ "$VERSION" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] \
  || fail "version must contain only letters, digits, dot, underscore, and hyphen"

case "${RELEASE_ALLOW_DIRTY:-false}" in
  false|true) ;;
  *) fail "RELEASE_ALLOW_DIRTY must be true or false" ;;
esac

git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || fail "release source is not a Git worktree: $ROOT_DIR"

if [[ "${RELEASE_ALLOW_DIRTY:-false}" != true ]] \
    && [[ -n "$(git -C "$ROOT_DIR" status --porcelain --untracked-files=no)" ]]; then
  fail "tracked worktree has uncommitted changes; commit or stash them before building a release"
fi

[[ -f "$CHANGELOG_FILE" ]] || fail "engineering changelog not found: $CHANGELOG_FILE"
if ! awk -v version="$VERSION" '
  BEGIN { heading = "## " version }
  $0 == heading || substr($0, 1, length(heading) + 1) == heading " " { found = 1 }
  END { exit !found }
' "$CHANGELOG_FILE"; then
  fail "engineering changelog has no entry for version $VERSION: $CHANGELOG_FILE"
fi

BUNDLE_NAME="sdcli-autokit-$VERSION-linux-amd64"
BUNDLE_PATH="$DIST_DIR/$BUNDLE_NAME.tar.gz"
CHECKSUM_PATH="$BUNDLE_PATH.sha256"
[[ ! -e "$BUNDLE_PATH" && ! -e "$CHECKSUM_PATH" ]] \
  || fail "release output already exists: $BUNDLE_PATH"

SOURCE_COMMIT="$(git -C "$ROOT_DIR" rev-parse HEAD)"
printf 'Release preflight passed\n'
printf 'Version: %s\n' "$VERSION"
printf 'Source commit: %s\n' "$SOURCE_COMMIT"
printf 'Engineering changelog: %s\n' "$CHANGELOG_FILE"
printf 'Expected bundle: %s\n' "$BUNDLE_PATH"
