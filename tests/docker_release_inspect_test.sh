#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

fakebin="$tmpdir/bin"
mkdir -p "$fakebin"
cat > "$fakebin/docker" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}:${2:-}" in
  info:*)
    printf '%s\n' 'amd64'
    exit 0
    ;;
  build:*)
    exit 0
    ;;
  image:inspect)
    inspect_format=''
    for ((index = 1; index <= $#; index++)); do
      if [[ "${!index}" == '--format' ]]; then
        next_index=$((index + 1))
        inspect_format="${!next_index}"
        break
      fi
    done

    if [[ "$inspect_format" == '{{.Id}}' ]]; then
      printf '%s\n' 'sha256:docker-test-image'
    elif [[ "$inspect_format" == *'printf'* ]]; then
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        'sha256:docker-test-image' 'linux' 'amd64' '1.1.0' \
        "$DOCKER_TEST_SOURCE_COMMIT" '2026-10-21T00:00:00Z' 'linux/amd64'
    else
      # Docker renders {{"\\t"}} as the literal characters backslash and t.
      # This reproduces the regression that the production scripts must avoid.
      printf '%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\n' \
        'sha256:docker-test-image' 'linux' 'amd64' '1.1.0' \
        "$DOCKER_TEST_SOURCE_COMMIT" '2026-10-21T00:00:00Z' 'linux/amd64'
    fi
    exit 0
    ;;
  image:save)
    shift 2
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --output)
          printf 'fake docker archive\n' > "$2"
          exit 0
          ;;
      esac
      shift
    done
    ;;
esac

echo "unexpected docker command: $*" >&2
exit 1
SH
chmod +x "$fakebin/docker"

source_commit="$(git -C "$REPO_ROOT" rev-parse HEAD)"
output="$(
  PATH="$fakebin:$PATH" \
  CONTAINER_ENGINE=docker \
  DOCKER_TEST_SOURCE_COMMIT="$source_commit" \
  DIST_DIR="$tmpdir/dist" \
  RELEASE_ALLOW_DIRTY=true \
  RELEASE_SKIP_TESTS=true \
  "$REPO_ROOT/release/release.sh" 1.1.0 --rebuild
)"

grep -F "Image labels: version=1.1.0 revision=$source_commit created=2026-10-21T00:00:00Z platform=linux/amd64" <<< "$output" >/dev/null
grep -F 'Created offline bundle:' <<< "$output" >/dev/null
[[ -f "$tmpdir/dist/sdcli-autokit-1.1.0-linux-amd64.tar.gz" ]]

echo 'docker release inspect test passed'
