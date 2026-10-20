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
      printf '%s\t%s\t%s\t%s\t%s\n' \
        "${PODMAN_IMAGE_ID:-sha256:fake-image-id}" \
        "${PODMAN_IMAGE_VERSION-1.2.3}" \
        "${PODMAN_IMAGE_REVISION-unknown}" \
        "${PODMAN_IMAGE_CREATED-2026-10-20T00:00:00Z}" \
        "${PODMAN_IMAGE_PLATFORM-linux/amd64}"
      exit 0
    fi
    ;;
  build)
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
printf '%s\n' '# Engineering change log' '' '## 1.2.3 - 2026-10-19' '' '### Added' '- Test release entry.' > "$release_changelog"
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

if RELEASE_ALLOW_DIRTY=true RELEASE_CHANGELOG_FILE="$release_changelog" \
    "$REPO_ROOT/release/preflight.sh" 1.2.4 >/dev/null 2>&1; then
  echo "release preflight unexpectedly accepted a missing changelog entry" >&2
  exit 1
fi

online_build_output="$(
  RELEASE_ALLOW_DIRTY=true RELEASE_CHANGELOG_FILE="$release_changelog" \
    PATH="$fakebin:$PATH" PODMAN_LOG="$podman_log" \
    "$REPO_ROOT/release/build-image.sh" 1.2.3
)"
grep -F 'Build mode: online' <<< "$online_build_output" >/dev/null
grep -F 'Image ID: sha256:fake-image-id' <<< "$online_build_output" >/dev/null
grep -F -- '--build-arg RELEASE_VERSION=1.2.3' "$podman_log" >/dev/null
grep -F -- '--build-arg RELEASE_SOURCE_COMMIT=' "$podman_log" >/dev/null
grep -F -- '--build-arg RELEASE_CREATED_AT=' "$podman_log" >/dev/null

: > "$podman_log"
build_output="$(
  RELEASE_ALLOW_DIRTY=true RELEASE_CHANGELOG_FILE="$release_changelog" RELEASE_SKIP_TESTS=true \
    PATH="$fakebin:$PATH" PODMAN_LOG="$podman_log" PODMAN_IMAGE_REVISION="$source_commit" DIST_DIR="$dist_dir" \
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
