#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"

usage() {
  echo "Usage: build-offline.sh <version>" >&2
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

IMAGE_NAME="sdcli-autokit:$VERSION"
BUNDLE_NAME="sdcli-autokit-$VERSION-linux-amd64"
BUNDLE_PATH="$DIST_DIR/$BUNDLE_NAME.tar.gz"
CHECKSUM_PATH="$BUNDLE_PATH.sha256"

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

[[ ! -e "$BUNDLE_PATH" && ! -e "$CHECKSUM_PATH" ]] || {
  echo "Error: release output already exists: $BUNDLE_PATH" >&2
  exit 1
}

mkdir -p "$DIST_DIR"
stage_dir="$(mktemp -d)"
trap 'rm -rf "$stage_dir"' EXIT
bundle_dir="$stage_dir/$BUNDLE_NAME"
mkdir -p "$bundle_dir/deployment" "$bundle_dir/sdcli-scripts"

CONTAINER_ENGINE="$CONTAINER_ENGINE" bash "$ROOT_DIR/deployment/build.sh" "$IMAGE_NAME"
if [[ "$CONTAINER_ENGINE" == "podman" ]]; then
  "$CONTAINER_ENGINE" save --format oci-archive --output "$bundle_dir/image.tar" "$IMAGE_NAME"
else
  "$CONTAINER_ENGINE" image save --output "$bundle_dir/image.tar" "$IMAGE_NAME"
fi
printf '%s\n' "$VERSION" > "$bundle_dir/VERSION"

cp "$ROOT_DIR/README.md" "$bundle_dir/README.md"
for deployment_file in .env run.sh start.sh stop.sh install-vendor.sh; do
  cp "$ROOT_DIR/deployment/$deployment_file" "$bundle_dir/deployment/$deployment_file"
done
chmod 0755 "$bundle_dir/deployment/"*.sh

script_files=(
  sdcli-scripts/migrate.sh
  sdcli-scripts/config.example.yaml
  sdcli-scripts/lib/bcp
  sdcli-scripts/lib/generate_validation_report.py
  sdcli-scripts/lib/load_wrappers.sh
  sdcli-scripts/lib/sqlldr
  sdcli-scripts/lib/sqlplus
  sdcli-scripts/lib/sqlplus_deploy.sh
  sdcli-scripts/templates/product-preferences.xml
)
for script_file in "${script_files[@]}"; do
  [[ -f "$ROOT_DIR/$script_file" ]] || {
    echo "Error: required release file not found: $ROOT_DIR/$script_file" >&2
    exit 1
  }
  relative_path="${script_file#sdcli-scripts/}"
  mkdir -p "$bundle_dir/sdcli-scripts/$(dirname "$relative_path")"
  cp "$ROOT_DIR/$script_file" "$bundle_dir/sdcli-scripts/$relative_path"
done
find "$bundle_dir/sdcli-scripts/lib" "$bundle_dir/sdcli-scripts/templates" -type f -exec chmod 0644 {} +
chmod 0644 "$bundle_dir/sdcli-scripts/config.example.yaml"
chmod 0755 "$bundle_dir/sdcli-scripts/migrate.sh" "$bundle_dir/sdcli-scripts/lib/bcp" "$bundle_dir/sdcli-scripts/lib/load_wrappers.sh" "$bundle_dir/sdcli-scripts/lib/sqlldr" "$bundle_dir/sdcli-scripts/lib/sqlplus"

# macOS attaches Finder/provenance extended attributes to copied files. Excluding
# them keeps Linux GNU tar output clean when customers unpack the bundle.
COPYFILE_DISABLE=1 tar --no-xattrs -C "$stage_dir" -czf "$BUNDLE_PATH" "$BUNDLE_NAME"

if command -v sha256sum >/dev/null 2>&1; then
  (cd "$DIST_DIR" && sha256sum "$BUNDLE_NAME.tar.gz" > "$BUNDLE_NAME.tar.gz.sha256")
else
  (cd "$DIST_DIR" && shasum -a 256 "$BUNDLE_NAME.tar.gz" > "$BUNDLE_NAME.tar.gz.sha256")
fi

echo "Created offline bundle: $BUNDLE_PATH"
echo "Checksum: $CHECKSUM_PATH"
