#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  echo "Usage: build-image.sh <version>" >&2
}

if [[ $# -ne 1 ]]; then
  usage
  exit 1
fi

VERSION="$1"
if [[ ! "$VERSION" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  echo "Error: version must contain only letters, digits, dot, underscore, and hyphen" >&2
  exit 1
fi

"$ROOT_DIR/release/preflight.sh" "$VERSION"

CONTAINER_ENGINE="${CONTAINER_ENGINE:-}"
if [[ -z "$CONTAINER_ENGINE" ]]; then
  if command -v podman >/dev/null 2>&1; then
    CONTAINER_ENGINE="podman"
  elif command -v docker >/dev/null 2>&1; then
    CONTAINER_ENGINE="docker"
  else
    echo "Error: neither podman nor docker is installed. Install Podman or start Rancher Desktop." >&2
    exit 1
  fi
fi

case "$CONTAINER_ENGINE" in
  podman|docker) ;;
  *)
    echo "Error: CONTAINER_ENGINE must be podman or docker, not '$CONTAINER_ENGINE'" >&2
    exit 1
    ;;
esac

SOURCE_COMMIT="$(git -C "$ROOT_DIR" rev-parse HEAD)"
CREATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
PLATFORM="linux/amd64"
IMAGE_NAME="sdcli-autokit:$VERSION"

printf 'Build mode: online\n'
printf 'Image: %s\n' "$IMAGE_NAME"
printf 'Source commit: %s\n' "$SOURCE_COMMIT"
printf 'Platform: %s\n' "$PLATFORM"

CONTAINER_ENGINE="$CONTAINER_ENGINE" \
RELEASE_VERSION="$VERSION" \
RELEASE_SOURCE_COMMIT="$SOURCE_COMMIT" \
RELEASE_CREATED_AT="$CREATED_AT" \
RELEASE_PLATFORM="$PLATFORM" \
  bash "$ROOT_DIR/deployment/build.sh" "$IMAGE_NAME"

image_metadata="$("$CONTAINER_ENGINE" image inspect \
  --format '{{printf "%s\t%s\t%s\t%s\t%s" .Id (index .Config.Labels "org.opencontainers.image.version") (index .Config.Labels "org.opencontainers.image.revision") (index .Config.Labels "org.opencontainers.image.created") (index .Config.Labels "org.opencontainers.image.platform")}}' \
  "$IMAGE_NAME")"
IFS=$'\t' read -r image_id image_version image_commit image_created image_platform <<< "$image_metadata"

[[ -n "$image_id" ]] || {
  echo "Error: could not determine local image ID for $IMAGE_NAME" >&2
  exit 1
}

printf 'Image ID: %s\n' "$image_id"
printf 'Image labels: version=%s revision=%s created=%s platform=%s\n' \
  "$image_version" "$image_commit" "$image_created" "$image_platform"
