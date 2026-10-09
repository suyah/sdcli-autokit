#!/bin/bash
set -euo pipefail

DEPLOYMENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$DEPLOYMENT_DIR/.." && pwd)"
ENV_FILE="$DEPLOYMENT_DIR/.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Error: .env file not found at $ENV_FILE" >&2
  exit 1
fi

set -a
source "$ENV_FILE"
set +a

: "${APP_USER:?APP_USER must be set in .env}"
: "${APP_GROUP:?APP_GROUP must be set in .env}"
: "${APP_UID:?APP_UID must be set in .env}"
: "${APP_GID:?APP_GID must be set in .env}"
: "${HOME_DIR:?HOME_DIR must be set in .env}"
: "${APP_HOME:?APP_HOME must be set in .env}"
: "${SD_HOME:?SD_HOME must be set in .env}"
: "${TOOL_DATA:?TOOL_DATA must be set in .env}"
: "${TOOL_LOG:?TOOL_LOG must be set in .env}"
IMAGE_TAG="${1:-${IMAGE_NAME:?IMAGE_NAME must be set in .env}}"

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

if ! "$CONTAINER_ENGINE" info >/dev/null 2>&1; then
  echo "Error: cannot connect to the $CONTAINER_ENGINE daemon." >&2
  if [[ "$CONTAINER_ENGINE" == "docker" ]]; then
    echo "Start Rancher Desktop and wait until its Docker engine is running, then retry." >&2
  fi
  exit 1
fi

if [[ ! "$IMAGE_TAG" =~ ^[A-Za-z0-9][A-Za-z0-9._/:@-]*$ ]]; then
  echo "Error: invalid image tag: $IMAGE_TAG" >&2
  exit 1
fi

build_args=(
  --build-arg "APP_USER=$APP_USER"
  --build-arg "APP_GROUP=$APP_GROUP"
  --build-arg "APP_UID=$APP_UID"
  --build-arg "APP_GID=$APP_GID"
  --build-arg "HOME_DIR=$HOME_DIR"
  --build-arg "APP_HOME=$APP_HOME"
  --build-arg "SD_HOME=$SD_HOME"
  --build-arg "TOOL_DATA=$TOOL_DATA"
  --build-arg "TOOL_LOG=$TOOL_LOG"
  -t "$IMAGE_TAG"
  -f "$DEPLOYMENT_DIR/Dockerfile"
)

if [[ "$CONTAINER_ENGINE" == "podman" ]]; then
  "$CONTAINER_ENGINE" build --arch amd64 --format docker "${build_args[@]}" "$ROOT_DIR"
else
  "$CONTAINER_ENGINE" build --platform linux/amd64 "${build_args[@]}" "$ROOT_DIR"
fi

echo "Build completed for image: $IMAGE_TAG (using $CONTAINER_ENGINE)"
