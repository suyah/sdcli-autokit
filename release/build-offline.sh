#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${DIST_DIR:-$ROOT_DIR/dist}"

usage() {
  echo "Usage: build-offline.sh <version>" >&2
}

print_tree_entries() {
  local directory="$1"
  local prefix="$2"
  local entry connector child_prefix index
  local -a entries=()

  while IFS= read -r entry; do
    entries+=("$entry")
  done < <(find "$directory" -mindepth 1 -maxdepth 1 -print | LC_ALL=C sort)

  for ((index = 0; index < ${#entries[@]}; index++)); do
    entry="${entries[$index]}"
    if ((index == ${#entries[@]} - 1)); then
      connector='└── '
      child_prefix="${prefix}    "
    else
      connector='├── '
      child_prefix="${prefix}│   "
    fi

    if [[ -d "$entry" ]]; then
      printf '%s%s%s/\n' "$prefix" "$connector" "${entry##*/}"
      print_tree_entries "$entry" "$child_prefix"
    else
      printf '%s%s%s\n' "$prefix" "$connector" "${entry##*/}"
    fi
  done
}

print_bundle_tree() {
  local bundle_directory="$1"

  printf 'Bundle contents:\n'
  printf '%s/\n' "${bundle_directory##*/}"
  print_tree_entries "$bundle_directory" ""
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
SOURCE_COMMIT="$(git -C "$ROOT_DIR" rev-parse HEAD)"

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

if ! image_metadata="$("$CONTAINER_ENGINE" image inspect \
  --format '{{printf "%s\t%s\t%s\t%s\t%s\t%s\t%s" .Id .Os .Architecture (index .Config.Labels "org.opencontainers.image.version") (index .Config.Labels "org.opencontainers.image.revision") (index .Config.Labels "org.opencontainers.image.created") (index .Config.Labels "org.opencontainers.image.platform")}}' \
  "$IMAGE_NAME")"; then
  echo "Error: release image is unavailable: $IMAGE_NAME" >&2
  echo "Run ./release/build-image.sh $VERSION or ./release/release.sh $VERSION --rebuild." >&2
  exit 1
fi

IFS=$'\t' read -r image_id image_os image_architecture image_version image_commit image_created image_platform <<< "$image_metadata"
if [[ -z "$image_id" || -z "$image_os" || -z "$image_architecture" || -z "$image_version" || -z "$image_commit" || -z "$image_created" || -z "$image_platform" ]]; then
  echo "Error: image provenance mismatch for $IMAGE_NAME: one or more required labels are missing" >&2
  echo "Run ./release/build-image.sh $VERSION or ./release/release.sh $VERSION --rebuild." >&2
  exit 1
fi

if [[ "$image_os" != "linux" || "$image_architecture" != "amd64" ]]; then
  echo "Error: image platform mismatch for $IMAGE_NAME" >&2
  printf 'Expected image platform: linux/amd64\n' >&2
  printf 'Observed image platform: %s/%s\n' "$image_os" "$image_architecture" >&2
  exit 1
fi

if [[ "$image_version" != "$VERSION" || "$image_commit" != "$SOURCE_COMMIT" || "$image_platform" != "linux/amd64" ]]; then
  echo "Error: image provenance mismatch for $IMAGE_NAME" >&2
  printf 'Expected: version=%s revision=%s platform=linux/amd64\n' "$VERSION" "$SOURCE_COMMIT" >&2
  printf 'Observed: version=%s revision=%s platform=%s\n' "$image_version" "$image_commit" "$image_platform" >&2
  echo "Run ./release/build-image.sh $VERSION or ./release/release.sh $VERSION --rebuild." >&2
  exit 1
fi

printf 'Using validated image: %s\n' "$IMAGE_NAME"
printf 'Image ID: %s\n' "$image_id"
printf 'Image labels: version=%s revision=%s created=%s platform=%s\n' \
  "$image_version" "$image_commit" "$image_created" "$image_platform"

if [[ "$CONTAINER_ENGINE" == "podman" ]]; then
  "$CONTAINER_ENGINE" save --format oci-archive --output "$bundle_dir/image.tar" "$IMAGE_NAME"
else
  "$CONTAINER_ENGINE" image save --output "$bundle_dir/image.tar" "$IMAGE_NAME"
fi

if ! exported_image_id="$("$CONTAINER_ENGINE" image inspect --format '{{.Id}}' "$IMAGE_NAME")"; then
  echo "Error: could not verify image tag after export: $IMAGE_NAME" >&2
  exit 1
fi
if [[ "$exported_image_id" != "$image_id" ]]; then
  echo "Error: image tag changed while exporting $IMAGE_NAME" >&2
  printf 'Expected image ID: %s\n' "$image_id" >&2
  printf 'Observed image ID: %s\n' "$exported_image_id" >&2
  exit 1
fi

printf 'Verified exported image ID: %s\n' "$image_id"
printf '%s\n' "$VERSION" > "$bundle_dir/VERSION"
printf '%s\n' "$SOURCE_COMMIT" > "$bundle_dir/SOURCE_COMMIT"
printf '%s\n' "$image_id" > "$bundle_dir/IMAGE_ID"

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

print_bundle_tree "$bundle_dir"
echo "Created offline bundle: $BUNDLE_PATH"
echo "Checksum: $CHECKSUM_PATH"
