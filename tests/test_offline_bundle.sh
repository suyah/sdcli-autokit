#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

assert_mode() {
  local path="$1"
  local expected="$2"
  local actual
  actual="$(stat -f '%Lp' "$path" 2>/dev/null || stat -c '%a' "$path")"
  if [[ "$actual" != "$expected" ]]; then
    echo "unexpected mode for $path: expected $expected, got $actual" >&2
    exit 1
  fi
}

fakebin="$tmpdir/bin"
mkdir -p "$fakebin"
cat > "$fakebin/podman" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

printf '%q ' "$@" >> "${PODMAN_LOG:?}"
printf '\n' >> "$PODMAN_LOG"

case "$1" in
  info)
    printf '%s\n' 'amd64'
    exit 0
    ;;
  image)
    if [[ "${2:-}" == inspect ]]; then
      inspect_format=''
      for ((index = 1; index <= $#; index++)); do
        if [[ "${!index}" == '--format' ]]; then
          next_index=$((index + 1))
          inspect_format="${!next_index}"
          break
        fi
      done

      inspect_count=1
      if [[ -n "${PODMAN_INSPECT_COUNT_FILE:-}" ]]; then
        if [[ -f "$PODMAN_INSPECT_COUNT_FILE" ]]; then
          inspect_count=$(( $(<"$PODMAN_INSPECT_COUNT_FILE") + 1 ))
        fi
        printf '%s\n' "$inspect_count" > "$PODMAN_INSPECT_COUNT_FILE"
      fi

      image_id="${PODMAN_IMAGE_ID:-sha256:fake-image-id}"
      if ((inspect_count > 1)) && [[ -n "${PODMAN_RETAGGED_IMAGE_ID:-}" ]]; then
        image_id="$PODMAN_RETAGGED_IMAGE_ID"
      fi

      state_version=''
      state_revision=''
      state_created=''
      state_platform=''
      if [[ -n "${PODMAN_IMAGE_STATE_FILE:-}" && -f "$PODMAN_IMAGE_STATE_FILE" ]]; then
        while IFS= read -r state_line; do
          case "$state_line" in
            version=*) state_version="${state_line#version=}" ;;
            revision=*) state_revision="${state_line#revision=}" ;;
            created=*) state_created="${state_line#created=}" ;;
            platform=*) state_platform="${state_line#platform=}" ;;
          esac
        done < "$PODMAN_IMAGE_STATE_FILE"
      fi

      if [[ -n "${PODMAN_IMAGE_VERSION+x}" ]]; then image_version="$PODMAN_IMAGE_VERSION"; else image_version="${state_version:-1.2.3}"; fi
      if [[ -n "${PODMAN_IMAGE_REVISION+x}" ]]; then image_revision="$PODMAN_IMAGE_REVISION"; else image_revision="${state_revision:-unknown}"; fi
      if [[ -n "${PODMAN_IMAGE_CREATED+x}" ]]; then image_created="$PODMAN_IMAGE_CREATED"; else image_created="${state_created:-2026-10-20T00:00:00Z}"; fi
      if [[ -n "${PODMAN_IMAGE_PLATFORM+x}" ]]; then image_platform="$PODMAN_IMAGE_PLATFORM"; else image_platform="${state_platform:-linux/amd64}"; fi

      if [[ "$inspect_format" == '{{.Id}}' ]]; then
        printf '%s\n' "$image_id"
      elif [[ "$inspect_format" == *'.Os'* ]]; then
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
          "$image_id" \
          "${PODMAN_IMAGE_OS-linux}" \
          "${PODMAN_IMAGE_ARCHITECTURE-amd64}" \
          "$image_version" \
          "$image_revision" \
          "$image_created" \
          "$image_platform"
      else
        printf '%s\t%s\t%s\t%s\t%s\n' \
          "$image_id" \
          "$image_version" \
          "$image_revision" \
          "$image_created" \
          "$image_platform"
      fi
      exit 0
    fi
    ;;
  build)
    if [[ -n "${PODMAN_IMAGE_STATE_FILE:-}" ]]; then
      release_version=''
      release_revision=''
      release_created=''
      release_platform=''
      for ((index = 1; index <= $#; index++)); do
        if [[ "${!index}" == '--build-arg' ]]; then
          next_index=$((index + 1))
          case "${!next_index}" in
            RELEASE_VERSION=*) release_version="${!next_index#RELEASE_VERSION=}" ;;
            RELEASE_SOURCE_COMMIT=*) release_revision="${!next_index#RELEASE_SOURCE_COMMIT=}" ;;
            RELEASE_CREATED_AT=*) release_created="${!next_index#RELEASE_CREATED_AT=}" ;;
            RELEASE_PLATFORM=*) release_platform="${!next_index#RELEASE_PLATFORM=}" ;;
          esac
        fi
      done
      printf 'version=%s\nrevision=%s\ncreated=%s\nplatform=%s\n' \
        "$release_version" "$release_revision" "$release_created" "$release_platform" > "$PODMAN_IMAGE_STATE_FILE"
    fi
    exit 0
    ;;
  save)
    shift
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --output)
          printf 'fake oci archive\n' > "$2"
          exit 0
          ;;
      esac
      shift
    done
    ;;
esac

echo "unexpected podman command: $*" >&2
exit 1
SH
chmod +x "$fakebin/podman"

dist_dir="$tmpdir/dist"
podman_log="$tmpdir/podman.log"
release_changelog="$tmpdir/CHANGELOG.md"
printf '%s\n' '# Engineering change log' '' '## Unreleased' '' '## 1.2.3 - 2026-10-19' '' '### Added' '- Test release entry.' > "$release_changelog"
source_commit="$(git -C "$REPO_ROOT" rev-parse HEAD)"

preflight_repo="$tmpdir/preflight-repo"
mkdir -p "$preflight_repo/release" "$preflight_repo/docs"
cp "$REPO_ROOT/release/preflight.sh" "$preflight_repo/release/preflight.sh"
cp "$release_changelog" "$preflight_repo/docs/CHANGELOG.md"
printf '%s\n' 'tracked release input' > "$preflight_repo/tracked.txt"
git -C "$preflight_repo" init -q
git -C "$preflight_repo" config user.name 'release test'
git -C "$preflight_repo" config user.email 'release-test@example.invalid'
git -C "$preflight_repo" add .
git -C "$preflight_repo" commit -qm 'initial release test fixture'
printf '%s\n' 'uncommitted change' >> "$preflight_repo/tracked.txt"

if "$preflight_repo/release/preflight.sh" 1.2.3 >"$tmpdir/preflight-dirty.log" 2>&1; then
  echo "release preflight unexpectedly accepted a dirty worktree" >&2
  exit 1
fi
grep -F 'tracked worktree has uncommitted changes' "$tmpdir/preflight-dirty.log" >/dev/null

preflight_output="$(
  RELEASE_ALLOW_DIRTY=true RELEASE_CHANGELOG_FILE="$release_changelog" \
    "$REPO_ROOT/release/preflight.sh" 1.2.3
)"
grep -F 'Release preflight passed' <<< "$preflight_output" >/dev/null
grep -F "Source commit: $source_commit" <<< "$preflight_output" >/dev/null

unreleased_changelog="$tmpdir/CHANGELOG-with-unreleased.md"
printf '%s\n' \
  '# Engineering change log' '' \
  '## Unreleased' '' \
  '### Fixed' '- A change waiting to be released.' '' \
  '## 1.2.3 - 2026-10-19' '' \
  '### Added' '- Test release entry.' > "$unreleased_changelog"
if RELEASE_ALLOW_DIRTY=true RELEASE_CHANGELOG_FILE="$unreleased_changelog" \
    "$REPO_ROOT/release/preflight.sh" 1.2.3 >"$tmpdir/preflight-unreleased.log" 2>&1; then
  echo "release preflight unexpectedly accepted unreleased changelog entries" >&2
  exit 1
fi
grep -F 'engineering changelog still has unreleased entries' "$tmpdir/preflight-unreleased.log" >/dev/null

if RELEASE_ALLOW_DIRTY=true RELEASE_CHANGELOG_FILE="$release_changelog" \
    "$REPO_ROOT/release/preflight.sh" 1.2.4 >/dev/null 2>&1; then
  echo "release preflight unexpectedly accepted a missing changelog entry" >&2
  exit 1
fi

image_state="$tmpdir/image-state"
online_build_output="$(
  RELEASE_ALLOW_DIRTY=true RELEASE_CHANGELOG_FILE="$release_changelog" \
    PATH="$fakebin:$PATH" PODMAN_LOG="$podman_log" PODMAN_IMAGE_STATE_FILE="$image_state" \
    "$REPO_ROOT/release/build-image.sh" 1.2.3
)"
grep -F 'Build mode: online' <<< "$online_build_output" >/dev/null
grep -F 'Image ID: sha256:fake-image-id' <<< "$online_build_output" >/dev/null
grep -F "Image labels: version=1.2.3 revision=$source_commit" <<< "$online_build_output" >/dev/null
grep -F -- '--build-arg RELEASE_VERSION=1.2.3' "$podman_log" >/dev/null
grep -F -- '--build-arg RELEASE_SOURCE_COMMIT=' "$podman_log" >/dev/null
grep -F -- '--build-arg RELEASE_CREATED_AT=' "$podman_log" >/dev/null

: > "$podman_log"
build_output="$(
  RELEASE_ALLOW_DIRTY=true RELEASE_CHANGELOG_FILE="$release_changelog" RELEASE_SKIP_TESTS=true \
    PATH="$fakebin:$PATH" PODMAN_LOG="$podman_log" PODMAN_IMAGE_STATE_FILE="$image_state" DIST_DIR="$dist_dir" \
    "$REPO_ROOT/release/release.sh" 1.2.3
)"

grep -Fx 'Bundle contents:' <<< "$build_output" >/dev/null
grep -Fx 'sdcli-autokit-1.2.3-linux-amd64/' <<< "$build_output" >/dev/null
grep -Fx '│   ├── run.sh' <<< "$build_output" >/dev/null
grep -Fx '├── image.tar' <<< "$build_output" >/dev/null
grep -Fx '└── sdcli-scripts/' <<< "$build_output" >/dev/null

bundle="$dist_dir/sdcli-autokit-1.2.3-linux-amd64.tar.gz"
checksum="$bundle.sha256"
[[ -f "$bundle" && -f "$checksum" ]]

tar -tzf "$bundle" | grep -Fx 'sdcli-autokit-1.2.3-linux-amd64/image.tar' >/dev/null
tar -tzf "$bundle" | grep -Fx 'sdcli-autokit-1.2.3-linux-amd64/VERSION' >/dev/null
tar -tzf "$bundle" | grep -Fx 'sdcli-autokit-1.2.3-linux-amd64/IMAGE_ID' >/dev/null
tar -tzf "$bundle" | grep -Fx 'sdcli-autokit-1.2.3-linux-amd64/deployment/run.sh' >/dev/null
tar -tzf "$bundle" | grep -Fx 'sdcli-autokit-1.2.3-linux-amd64/deployment/install-vendor.sh' >/dev/null
tar -tzf "$bundle" | grep -Fx 'sdcli-autokit-1.2.3-linux-amd64/sdcli-scripts/migrate.sh' >/dev/null
tar -tzf "$bundle" | grep -Fx 'sdcli-autokit-1.2.3-linux-amd64/sdcli-scripts/lib/sdcli_profile.sh' >/dev/null
tar -tzf "$bundle" | grep -Fx 'sdcli-autokit-1.2.3-linux-amd64/sdcli-scripts/lib/generate_validation_report.py' >/dev/null
tar -tzf "$bundle" | grep -Fx 'sdcli-autokit-1.2.3-linux-amd64/sdcli-scripts/config.example.yaml' >/dev/null
if tar -tzf "$bundle" | grep -Fx 'sdcli-autokit-1.2.3-linux-amd64/sdcli-scripts/config.yaml' >/dev/null; then
  echo "customer config.yaml was packaged" >&2
  exit 1
fi
[[ "$(tar -xOzf "$bundle" sdcli-autokit-1.2.3-linux-amd64/VERSION)" == "1.2.3" ]]
[[ "$(tar -xOzf "$bundle" sdcli-autokit-1.2.3-linux-amd64/SOURCE_COMMIT)" == "$source_commit" ]]
[[ "$(tar -xOzf "$bundle" sdcli-autokit-1.2.3-linux-amd64/IMAGE_ID)" == 'sha256:fake-image-id' ]]
example_config="$(tar -xOzf "$bundle" sdcli-autokit-1.2.3-linux-amd64/sdcli-scripts/config.example.yaml)"
if grep -Eq '(10\.[0-9]+\.[0-9]+\.[0-9]+|68\.233\.113\.119|adb\.[A-Za-z0-9.-]+oraclecloud\.com)' <<< "$example_config"; then
  echo "project-specific endpoint found in config.example.yaml" >&2
  exit 1
fi

extracted_bundle="$tmpdir/extracted"
mkdir -p "$extracted_bundle"
tar -xzf "$bundle" -C "$extracted_bundle"
extracted_root="$extracted_bundle/sdcli-autokit-1.2.3-linux-amd64"
grep -F 'This release supports Oracle SQL Developer 26.2 only.' "$extracted_root/README.md" >/dev/null
assert_mode "$extracted_root/sdcli-scripts/migrate.sh" 755
assert_mode "$extracted_root/sdcli-scripts/lib/sqlplus_deploy.sh" 644

expected_hash="$(awk '{print $1}' "$checksum")"
if command -v sha256sum >/dev/null 2>&1; then
  actual_hash="$(sha256sum "$bundle" | awk '{print $1}')"
else
  actual_hash="$(shasum -a 256 "$bundle" | awk '{print $1}')"
fi
[[ "$expected_hash" == "$actual_hash" ]]
grep -F 'image inspect' "$podman_log" >/dev/null
grep -F 'save ' "$podman_log" >/dev/null
if grep -Fq 'build ' "$podman_log"; then
  echo "default release unexpectedly rebuilt the image" >&2
  exit 1
fi
if grep -Fq 'Release test suite skipped by RELEASE_SKIP_TESTS=true' <<< "$build_output"; then
  echo "default release unexpectedly considered the test-suite skip setting" >&2
  exit 1
fi

: > "$podman_log"
rebuild_dist="$tmpdir/rebuild-dist"
rebuild_output="$(
  RELEASE_ALLOW_DIRTY=true RELEASE_CHANGELOG_FILE="$release_changelog" \
    PATH="$fakebin:$PATH" PODMAN_LOG="$podman_log" PODMAN_IMAGE_REVISION="$source_commit" DIST_DIR="$rebuild_dist" \
    "$REPO_ROOT/release/release.sh" 1.2.3 --rebuild
)"
grep -F 'Build mode: online' <<< "$rebuild_output" >/dev/null
rebuild_bundle="$rebuild_dist/sdcli-autokit-1.2.3-linux-amd64.tar.gz"
[[ -f "$rebuild_bundle" ]]
build_line="$(grep -n 'build ' "$podman_log" | head -1 | cut -d: -f1)"
inspect_line="$(grep -n 'image inspect' "$podman_log" | head -1 | cut -d: -f1)"
((build_line < inspect_line)) || {
  echo "release rebuild did not build before inspecting the image" >&2
  exit 1
}

verify_dist="$tmpdir/verify-dist"
verify_output="$(
  RELEASE_ALLOW_DIRTY=true RELEASE_CHANGELOG_FILE="$release_changelog" RELEASE_SKIP_TESTS=true \
    PATH="$fakebin:$PATH" PODMAN_LOG="$tmpdir/verify.log" PODMAN_IMAGE_REVISION="$source_commit" DIST_DIR="$verify_dist" \
    "$REPO_ROOT/release/release.sh" 1.2.3 --verify
)"
grep -F 'Release test suite skipped by RELEASE_SKIP_TESTS=true' <<< "$verify_output" >/dev/null
[[ -f "$verify_dist/sdcli-autokit-1.2.3-linux-amd64.tar.gz" ]]

for invalid_option in '--unknown' '--rebuild --rebuild'; do
  invalid_log="$tmpdir/invalid-option-$(tr -cd '[:alnum:]' <<< "$invalid_option").log"
  invalid_dist="$tmpdir/invalid-option-$(tr -cd '[:alnum:]' <<< "$invalid_option")"
  if RELEASE_ALLOW_DIRTY=true RELEASE_CHANGELOG_FILE="$release_changelog" \
      PATH="$fakebin:$PATH" PODMAN_LOG="$invalid_log" PODMAN_IMAGE_REVISION="$source_commit" DIST_DIR="$invalid_dist" \
      "$REPO_ROOT/release/release.sh" 1.2.3 $invalid_option >"$tmpdir/invalid-option.out" 2>&1; then
    echo "release unexpectedly accepted invalid options: $invalid_option" >&2
    exit 1
  fi
  [[ ! -e "$invalid_log" && ! -e "$invalid_dist" ]] || {
    echo "release options had side effects before validation: $invalid_option" >&2
    exit 1
  }
done

missing_provenance_log="$tmpdir/missing-provenance.log"
if RELEASE_ALLOW_DIRTY=true RELEASE_CHANGELOG_FILE="$release_changelog" \
    PATH="$fakebin:$PATH" PODMAN_LOG="$missing_provenance_log" PODMAN_IMAGE_REVISION='' DIST_DIR="$tmpdir/missing-provenance" \
    "$REPO_ROOT/release/build-offline.sh" 1.2.3 >"$tmpdir/missing-provenance.out" 2>&1; then
  echo "bundle build unexpectedly accepted an image without provenance" >&2
  exit 1
fi
grep -F 'image provenance mismatch' "$tmpdir/missing-provenance.out" >/dev/null
if grep -Fq 'save ' "$missing_provenance_log"; then
  echo "bundle build exported an image without provenance" >&2
  exit 1
fi

mismatched_provenance_log="$tmpdir/mismatched-provenance.log"
if RELEASE_ALLOW_DIRTY=true RELEASE_CHANGELOG_FILE="$release_changelog" \
    PATH="$fakebin:$PATH" PODMAN_LOG="$mismatched_provenance_log" PODMAN_IMAGE_REVISION='deadbeefdeadbeefdeadbeefdeadbeefdeadbeef' DIST_DIR="$tmpdir/mismatched-provenance" \
    "$REPO_ROOT/release/build-offline.sh" 1.2.3 >"$tmpdir/mismatched-provenance.out" 2>&1; then
  echo "bundle build unexpectedly accepted a mismatched image revision" >&2
  exit 1
fi
grep -F 'image provenance mismatch' "$tmpdir/mismatched-provenance.out" >/dev/null
if grep -Fq 'save ' "$mismatched_provenance_log"; then
  echo "bundle build exported an image with a mismatched revision" >&2
  exit 1
fi

version_mismatch_log="$tmpdir/version-mismatch.log"
if RELEASE_ALLOW_DIRTY=true RELEASE_CHANGELOG_FILE="$release_changelog" \
    PATH="$fakebin:$PATH" PODMAN_LOG="$version_mismatch_log" PODMAN_IMAGE_VERSION='9.9.9' PODMAN_IMAGE_REVISION="$source_commit" DIST_DIR="$tmpdir/version-mismatch" \
    "$REPO_ROOT/release/build-offline.sh" 1.2.3 >"$tmpdir/version-mismatch.out" 2>&1; then
  echo "bundle build unexpectedly accepted a mismatched image version" >&2
  exit 1
fi
grep -F 'image provenance mismatch' "$tmpdir/version-mismatch.out" >/dev/null
if grep -Fq 'save ' "$version_mismatch_log"; then
  echo "bundle build exported an image with a mismatched version" >&2
  exit 1
fi

architecture_mismatch_log="$tmpdir/architecture-mismatch.log"
if RELEASE_ALLOW_DIRTY=true RELEASE_CHANGELOG_FILE="$release_changelog" \
    PATH="$fakebin:$PATH" PODMAN_LOG="$architecture_mismatch_log" PODMAN_IMAGE_ARCHITECTURE='arm64' PODMAN_IMAGE_REVISION="$source_commit" DIST_DIR="$tmpdir/architecture-mismatch" \
    "$REPO_ROOT/release/build-offline.sh" 1.2.3 >"$tmpdir/architecture-mismatch.out" 2>&1; then
  echo "bundle build unexpectedly accepted a non-amd64 image with an amd64 label" >&2
  exit 1
fi
grep -F 'image platform mismatch' "$tmpdir/architecture-mismatch.out" >/dev/null
if grep -Fq 'save ' "$architecture_mismatch_log"; then
  echo "bundle build exported a non-amd64 image" >&2
  exit 1
fi

retag_log="$tmpdir/retag.log"
retag_count_file="$tmpdir/retag-inspect-count"
if RELEASE_ALLOW_DIRTY=true RELEASE_CHANGELOG_FILE="$release_changelog" \
    PATH="$fakebin:$PATH" PODMAN_LOG="$retag_log" PODMAN_IMAGE_REVISION="$source_commit" PODMAN_INSPECT_COUNT_FILE="$retag_count_file" PODMAN_RETAGGED_IMAGE_ID='sha256:retagged-image-id' DIST_DIR="$tmpdir/retag" \
    "$REPO_ROOT/release/build-offline.sh" 1.2.3 >"$tmpdir/retag.out" 2>&1; then
  echo "bundle build unexpectedly accepted an image tag that changed during export" >&2
  exit 1
fi
grep -F 'image tag changed while exporting' "$tmpdir/retag.out" >/dev/null
grep -F 'save ' "$retag_log" >/dev/null
[[ ! -e "$tmpdir/retag/sdcli-autokit-1.2.3-linux-amd64.tar.gz" ]]

if PATH="$fakebin:$PATH" PODMAN_LOG="$podman_log" DIST_DIR="$tmpdir/invalid" \
    "$REPO_ROOT/release/build-offline.sh" 'bad/version' >/dev/null 2>&1; then
  echo "invalid version unexpectedly succeeded" >&2
  exit 1
fi

if PATH="$fakebin:$PATH" PODMAN_LOG="$podman_log" DIST_DIR="$dist_dir" \
    "$REPO_ROOT/release/build-offline.sh" 1.2.3 >/dev/null 2>&1; then
  echo "existing output was unexpectedly overwritten" >&2
  exit 1
fi

! grep -q 'packages.microsoft.com' "$REPO_ROOT/deployment/Dockerfile"
! grep -q 'oracle-instantclient-release' "$REPO_ROOT/deployment/Dockerfile"
! grep -q 'msodbcsql18' "$REPO_ROOT/deployment/Dockerfile"
! grep -q 'mssql-tools18' "$REPO_ROOT/deployment/Dockerfile"
grep -Eq '^[[:space:]]+python3([[:space:]\\]|$)' "$REPO_ROOT/deployment/Dockerfile"

echo "offline bundle test passed"
