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

SD_RPM_URL="${SD_RPM_URL:?SD_RPM_URL must be set in .env}"
JTDS_URL="${JTDS_URL:?JTDS_URL must be set in .env}"
ARTIFACT_DIR="${ARTIFACT_DIR:?ARTIFACT_DIR must be set in .env}"

SD_BIN="${SD_HOME%/}/sqldeveloper/bin/sdcli"
SD_RPM_FILE="${ARTIFACT_DIR%/}/$(basename "$SD_RPM_URL")"
JTDS_TARGET_DIR="${SD_HOME%/}/jlib"
JTDS_TARGET_FILE="${JTDS_TARGET_DIR}/jtds-1.3.1.jar"
SDCLI_SCRIPTS_SRC="$ROOT_DIR/../sdcli-scripts"
SDCLI_SCRIPTS_DEST="${HOME_DIR%/}/sdcli-scripts"

podman volume inspect "$VOLUME_NAME" >/dev/null 2>&1 || podman volume create "$VOLUME_NAME" >/dev/null

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

has_existing_sd() {
  podman exec "$CONTAINER_NAME" bash -lc "test -x '$SD_BIN'"
}

install_sd_if_needed() {
  if has_existing_sd; then
    echo "Existing SQL Developer installation found in volume '$VOLUME_NAME' at $SD_BIN"
    return 0
  fi

  echo "No existing SQL Developer installation found."
  echo "Running one-time installer from URL: $SD_RPM_URL"

  podman exec \
    --env "HOME_DIR=$HOME_DIR" \
    --env "SD_HOME=$SD_HOME" \
    --env "ARTIFACT_DIR=$ARTIFACT_DIR" \
    --env "SD_RPM_URL=$SD_RPM_URL" \
    --env "SD_RPM_FILE=$SD_RPM_FILE" \
    "$CONTAINER_NAME" \
    bash -lc '
      set -euo pipefail

      : "${HOME_DIR:?HOME_DIR must be set}"
      : "${SD_HOME:?SD_HOME must be set}"
      : "${ARTIFACT_DIR:?ARTIFACT_DIR must be set}"
      : "${SD_RPM_URL:?SD_RPM_URL must be set}"
      : "${SD_RPM_FILE:?SD_RPM_FILE must be set}"

      mkdir -p "$ARTIFACT_DIR" "$SD_HOME" "$HOME_DIR/.sqldeveloper"
      if [[ ! -s "$SD_RPM_FILE" ]]; then
        wget -q -O "$SD_RPM_FILE" "$SD_RPM_URL"
        echo "Downloaded SQL Developer RPM: $SD_RPM_FILE"
      fi

      TMP_DIR="$(mktemp -d)"
      trap "rm -rf \"$TMP_DIR\"" EXIT

      mkdir -p "$TMP_DIR/root" "$TMP_DIR/db"

      rpm --root "$TMP_DIR/root" \
          --dbpath "$TMP_DIR/db" \
          --nodeps \
          --noscripts \
          --notriggers \
          -ivh "$SD_RPM_FILE" >/dev/null

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

has_existing_jtds() {
  podman exec "$CONTAINER_NAME" bash -lc "test -f '$JTDS_TARGET_FILE'"
}

install_jtds_if_needed() {
  if has_existing_jtds; then
    echo "Existing jtds jar found at $JTDS_TARGET_FILE"
    return 0
  fi

  echo "Downloading jtds jar to: $JTDS_TARGET_FILE"
  podman exec \
    --env "JTDS_URL=$JTDS_URL" \
    --env "JTDS_TARGET_DIR=$JTDS_TARGET_DIR" \
    --env "JTDS_TARGET_FILE=$JTDS_TARGET_FILE" \
    "$CONTAINER_NAME" \
    bash -lc '
      set -euo pipefail

      : "${JTDS_URL:?JTDS_URL must be set}"
      : "${JTDS_TARGET_DIR:?JTDS_TARGET_DIR must be set}"
      : "${JTDS_TARGET_FILE:?JTDS_TARGET_FILE must be set}"

      mkdir -p "$JTDS_TARGET_DIR"
      if [[ ! -s "$JTDS_TARGET_FILE" ]]; then
        wget -q -O "$JTDS_TARGET_FILE" "$JTDS_URL"
        echo "Downloaded jtds jar: $JTDS_TARGET_FILE"
      fi
    '

  if ! has_existing_jtds; then
    echo "Error: jtds download completed but jar is still missing at $JTDS_TARGET_FILE"
    exit 1
  fi

  echo "jtds jar download verified successfully."
}

sync_sdcli_scripts() {
  if [[ ! -d "$SDCLI_SCRIPTS_SRC" ]]; then
    echo "Error: sdcli-scripts directory not found in repository: $SDCLI_SCRIPTS_SRC"
    exit 1
  fi

  if podman exec "$CONTAINER_NAME" bash -lc "test -f '$SDCLI_SCRIPTS_DEST/migrate.sh' && test -f '$SDCLI_SCRIPTS_DEST/config.yaml'"; then
    echo "Existing sdcli-scripts found at $SDCLI_SCRIPTS_DEST"
    return 0
  fi

  echo "Syncing sdcli-scripts to: $SDCLI_SCRIPTS_DEST"
  podman exec "$CONTAINER_NAME" bash -lc "mkdir -p '$SDCLI_SCRIPTS_DEST'"
  podman cp "$SDCLI_SCRIPTS_SRC/." "$CONTAINER_NAME:$SDCLI_SCRIPTS_DEST"
}

start_or_reuse_container
install_sd_if_needed
install_jtds_if_needed
sync_sdcli_scripts

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
podman exec "$CONTAINER_NAME" bash -lc "test -f '$JTDS_TARGET_FILE' && echo 'jtds jar: OK'" || true
podman exec "$CONTAINER_NAME" bash -lc "test -d '$SDCLI_SCRIPTS_DEST' && echo 'sdcli-scripts: OK'" || true

