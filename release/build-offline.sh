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

[[ ! -e "$BUNDLE_PATH" && ! -e "$CHECKSUM_PATH" ]] || {
  echo "Error: release output already exists: $BUNDLE_PATH" >&2
  exit 1
}

mkdir -p "$DIST_DIR"
stage_dir="$(mktemp -d)"
trap 'rm -rf "$stage_dir"' EXIT
bundle_dir="$stage_dir/$BUNDLE_NAME"
mkdir -p "$bundle_dir/deployment" "$bundle_dir/sdcli-scripts"

bash "$ROOT_DIR/deployment/build.sh" "$IMAGE_NAME"
podman save --format oci-archive --output "$bundle_dir/image.tar" "$IMAGE_NAME"
printf '%s\n' "$VERSION" > "$bundle_dir/VERSION"

cp "$ROOT_DIR/README.md" "$bundle_dir/README.md"
for deployment_file in .env run.sh start.sh stop.sh install-vendor.sh; do
  cp "$ROOT_DIR/deployment/$deployment_file" "$bundle_dir/deployment/$deployment_file"
done
chmod 0755 "$bundle_dir/deployment/"*.sh

while IFS= read -r script_file; do
  relative_path="${script_file#sdcli-scripts/}"
  mkdir -p "$bundle_dir/sdcli-scripts/$(dirname "$relative_path")"
  cp "$ROOT_DIR/$script_file" "$bundle_dir/sdcli-scripts/$relative_path"
done < <(cd "$ROOT_DIR" && git ls-files 'sdcli-scripts/**')
chmod 0755 "$bundle_dir/sdcli-scripts/migrate.sh" "$bundle_dir/sdcli-scripts/lib/bcp" "$bundle_dir/sdcli-scripts/lib/load_wrappers.sh" "$bundle_dir/sdcli-scripts/lib/sqlldr" "$bundle_dir/sdcli-scripts/lib/sqlplus"

tar -C "$stage_dir" -czf "$BUNDLE_PATH" "$BUNDLE_NAME"

if command -v sha256sum >/dev/null 2>&1; then
  (cd "$DIST_DIR" && sha256sum "$BUNDLE_NAME.tar.gz" > "$BUNDLE_NAME.tar.gz.sha256")
else
  (cd "$DIST_DIR" && shasum -a 256 "$BUNDLE_NAME.tar.gz" > "$BUNDLE_NAME.tar.gz.sha256")
fi

echo "Created offline bundle: $BUNDLE_PATH"
echo "Checksum: $CHECKSUM_PATH"
