#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$ROOT_DIR/.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Error: .env file not found at $ENV_FILE" >&2
  exit 1
fi

cd "$ROOT_DIR"

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
: "${IMAGE_NAME:?IMAGE_NAME must be set in .env}"
: "${VOLUME_NAME:?VOLUME_NAME must be set in .env}"

podman build \
  --build-arg APP_USER="$APP_USER" \
  --build-arg APP_GROUP="$APP_GROUP" \
  --build-arg APP_UID="$APP_UID" \
  --build-arg APP_GID="$APP_GID" \
  --build-arg HOME_DIR="$HOME_DIR" \
  --build-arg APP_HOME="$APP_HOME" \
  --build-arg SD_HOME="$SD_HOME" \
  --build-arg TOOL_DATA="$TOOL_DATA" \
  --build-arg TOOL_LOG="$TOOL_LOG" \
  --format docker \
  -t "$IMAGE_NAME" \
  .

podman volume inspect "$VOLUME_NAME" >/dev/null 2>&1 || podman volume create "$VOLUME_NAME" >/dev/null

echo "Build completed for image: $IMAGE_NAME"
echo "Volume ready: $VOLUME_NAME"
