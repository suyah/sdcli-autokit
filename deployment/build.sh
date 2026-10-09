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

if [[ ! "$IMAGE_TAG" =~ ^[A-Za-z0-9][A-Za-z0-9._/:@-]*$ ]]; then
  echo "Error: invalid image tag: $IMAGE_TAG" >&2
  exit 1
fi

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
  --arch amd64 \
  --format docker \
  -t "$IMAGE_TAG" \
  -f "$DEPLOYMENT_DIR/Dockerfile" \
  "$ROOT_DIR"

echo "Build completed for image: $IMAGE_TAG"
