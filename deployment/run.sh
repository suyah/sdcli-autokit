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
CONTAINER_HOSTNAME="${CONTAINER_HOSTNAME:?CONTAINER_HOSTNAME must be set in .env}"
IMAGE_NAME="${IMAGE_NAME:?IMAGE_NAME must be set in .env}"
VOLUME_NAME="${VOLUME_NAME:?VOLUME_NAME must be set in .env}"

HOME_DIR="${HOME_DIR:?HOME_DIR must be set in .env}"
SD_HOME="${SD_HOME:?SD_HOME must be set in .env}"

# SD_RPM_PATH is intentionally expected from the shell environment
# on first run, similar to how ZEUS takes an external kit path at runtime.
SD_RPM_PATH="${SD_RPM_PATH:-}"
SD_RPM_MOUNT="${SD_RPM_MOUNT:-/mnt/sqldeveloper/sqldeveloper.rpm}"
SD_BIN="${SD_HOME%/}/sqldeveloper/bin/sdcli"

COMMON_RUN_ARGS=(
  --userns=keep-id
  --hostname "$CONTAINER_HOSTNAME"
  -v "${VOLUME_NAME}:/u01:Z"
)

podman volume inspect "$VOLUME_NAME" >/dev/null 2>&1 || podman volume create "$VOLUME_NAME" >/dev/null

has_existing_sd() {
  podman run --rm \
    "${COMMON_RUN_ARGS[@]}" \
    "$IMAGE_NAME" \
    bash -lc "test -x '$SD_BIN'"
}

install_sd_if_needed() {
  if has_existing_sd; then
    echo "Existing SQL Developer installation found in volume '$VOLUME_NAME' at $SD_BIN"
    return 0
  fi

  if [[ -z "$SD_RPM_PATH" ]]; then
    echo "Error: no existing SQL Developer installation found at $SD_BIN"
    echo "Please export SD_RPM_PATH before running ./run.sh"
    echo
    echo "Example:"
    echo "  SD_RPM_PATH=/path/to/sqldeveloper-24.3.1-347.1826.noarch.rpm ./run.sh"
    exit 1
  fi

  if [[ ! -f "$SD_RPM_PATH" ]]; then
    echo "Error: SQL Developer RPM file not found: $SD_RPM_PATH"
    exit 1
  fi

  echo "No existing SQL Developer installation found."
  echo "Running one-time installer from: $SD_RPM_PATH"

  podman run --rm \
    "${COMMON_RUN_ARGS[@]}" \
    -v "${SD_RPM_PATH}:${SD_RPM_MOUNT}:ro,Z" \
    -e "HOME_DIR=$HOME_DIR" \
    -e "SD_HOME=$SD_HOME" \
    -e "SD_RPM_MOUNT=$SD_RPM_MOUNT" \
    "$IMAGE_NAME" \
    bash -lc '
      set -euo pipefail

      : "${HOME_DIR:?HOME_DIR must be set}"
      : "${SD_HOME:?SD_HOME must be set}"
      : "${SD_RPM_MOUNT:?SD_RPM_MOUNT must be set}"

      mkdir -p "$SD_HOME" "$HOME_DIR/.sqldeveloper"

      TMP_DIR="$(mktemp -d)"
      trap '\''rm -rf "$TMP_DIR"'\'' EXIT

      mkdir -p "$TMP_DIR/root" "$TMP_DIR/db"

      rpm --root "$TMP_DIR/root" \
          --dbpath "$TMP_DIR/db" \
          --nodeps \
          --noscripts \
          --notriggers \
          -ivh "$SD_RPM_MOUNT" >/dev/null

      FOUND_DIR="$(find "$TMP_DIR/root" -type d -path "*/sqldeveloper" | head -n 1 || true)"
      if [[ -z "$FOUND_DIR" ]]; then
        echo "Error: could not locate sqldeveloper directory after installing RPM"
        exit 1
      fi

      rm -rf "$SD_HOME"
      mkdir -p "$SD_HOME"
      cp -a "$FOUND_DIR/." "$SD_HOME/"

      printf "SetJavaHome %s\n" "/usr/lib/jvm/java-17-openjdk" > "$HOME_DIR/.sqldeveloper/product.conf"

      test -x "$SD_HOME/sqldeveloper/bin/sdcli"
    '

  if ! has_existing_sd; then
    echo "Error: SQL Developer installation completed but sdcli is still missing at $SD_BIN"
    exit 1
  fi

  echo "SQL Developer installation verified successfully."
}

start_or_reuse_container() {
  if podman container exists "$CONTAINER_NAME"; then
    echo "Container '$CONTAINER_NAME' already exists."
    if podman ps --filter "name=^${CONTAINER_NAME}$" --format '{{.Status}}' | grep -q '^Up'; then
      echo "Container is already running."
      return 0
    fi

    echo "Starting existing container..."
    podman start "$CONTAINER_NAME" >/dev/null
    return 0
  fi

  CMD=(
    podman run
    --restart=always
    --userns=keep-id
    --network host
    -d
    --hostname "$CONTAINER_HOSTNAME"
    -v "${VOLUME_NAME}:/u01:Z"
    --name "$CONTAINER_NAME"
    "$IMAGE_NAME"
  )

  echo "Executing command:"
  printf ' %q' "${CMD[@]}"
  echo
  "${CMD[@]}"
}

install_sd_if_needed
start_or_reuse_container

echo
echo "=== container status ==="
podman ps -a --filter "name=^${CONTAINER_NAME}$" || true

echo
echo "=== quick checks ==="
podman exec "$CONTAINER_NAME" bash -lc "test -x '$SD_BIN' && echo 'sdcli: OK'" || true
podman exec "$CONTAINER_NAME" bash -lc "command -v sdcli && echo 'sdcli on PATH: OK'" || true
podman exec "$CONTAINER_NAME" bash -lc "command -v sqlcmd && sqlcmd -? >/dev/null 2>&1 && echo 'sqlcmd: OK'" || true
podman exec "$CONTAINER_NAME" bash -lc "command -v bcp && echo 'bcp: OK'" || true
podman exec "$CONTAINER_NAME" bash -lc "command -v jq && echo 'jq: OK'" || true
