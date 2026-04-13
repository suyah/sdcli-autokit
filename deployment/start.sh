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

CONTAINER_NAME="${CONTAINER_NAME:?CONTAINER_NAME must be set in .env}"

if ! podman container exists "$CONTAINER_NAME"; then
  echo "Error: container '$CONTAINER_NAME' does not exist."
  echo "Please run ./run.sh first."
  exit 1
fi

if podman ps --filter "name=^${CONTAINER_NAME}$" --format '{{.Status}}' | grep -q '^Up'; then
  echo "Container '$CONTAINER_NAME' is already running."
  exit 0
fi

echo "Starting container '$CONTAINER_NAME'..."
podman start "$CONTAINER_NAME" >/dev/null

echo
echo "=== container status ==="
podman ps -a --filter "name=^${CONTAINER_NAME}$" || true

echo
echo "Container '$CONTAINER_NAME' started."
