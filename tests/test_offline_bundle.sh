#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

fakebin="$tmpdir/bin"
mkdir -p "$fakebin"
cat > "$fakebin/podman" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

printf '%q ' "$@" >> "${PODMAN_LOG:?}"
printf '\n' >> "$PODMAN_LOG"

case "$1" in
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
[[ "$(tar -xOzf "$bundle" sdcli-autokit-1.2.3-linux-amd64/VERSION)" == "1.2.3" ]]

expected_hash="$(awk '{print $1}' "$checksum")"
actual_hash="$(shasum -a 256 "$bundle" | awk '{print $1}')"
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

echo "offline bundle test passed"
