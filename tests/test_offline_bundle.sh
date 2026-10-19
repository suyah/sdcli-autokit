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
PATH="$fakebin:$PATH" PODMAN_LOG="$podman_log" DIST_DIR="$dist_dir" \
  "$REPO_ROOT/release/build-offline.sh" 1.2.3

bundle="$dist_dir/sdcli-autokit-1.2.3-linux-amd64.tar.gz"
checksum="$bundle.sha256"
[[ -f "$bundle" && -f "$checksum" ]]

tar -tzf "$bundle" | grep -Fx 'sdcli-autokit-1.2.3-linux-amd64/image.tar' >/dev/null
tar -tzf "$bundle" | grep -Fx 'sdcli-autokit-1.2.3-linux-amd64/VERSION' >/dev/null
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
grep -F -- '-t sdcli-autokit:1.2.3 ' "$podman_log" >/dev/null
grep -F -- '--arch amd64' "$podman_log" >/dev/null

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
