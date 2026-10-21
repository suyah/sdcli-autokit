#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

mkdir -p "$tmpdir/release" "$tmpdir/sdcli-scripts/lib" "$tmpdir/deployment" "$tmpdir/tests" "$tmpdir/bin"
cp "$REPO_ROOT/release/release.sh" "$tmpdir/release/release.sh"

cat > "$tmpdir/release/preflight.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$tmpdir/release/build-offline.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$tmpdir/sdcli-scripts/migrate.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$tmpdir/sdcli-scripts/lib/placeholder.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$tmpdir/deployment/placeholder.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat > "$tmpdir/tests/validation_report_test.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
python3 -m unittest discover -s tests -p 'test_validation_report.py' -v
SH
cat > "$tmpdir/bin/git" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *'ls-files'* ]]; then
  printf '%s\n' 'tests/validation_report_test.sh'
  exit 0
fi
exit 1
SH
cat > "$tmpdir/bin/python3" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$PYTHON_CALLS"
SH
chmod +x "$tmpdir/release/"*.sh "$tmpdir/sdcli-scripts/migrate.sh" "$tmpdir/sdcli-scripts/lib/placeholder.sh" "$tmpdir/deployment/placeholder.sh" "$tmpdir/tests/validation_report_test.sh" "$tmpdir/bin/"*

calls_file="$tmpdir/python.calls"
PATH="$tmpdir/bin:$PATH" PYTHON_CALLS="$calls_file" "$tmpdir/release/release.sh" 1.1.0 --verify

call_count="$(wc -l < "$calls_file" | tr -d '[:space:]')"
if [[ "$call_count" != '1' ]]; then
  echo "expected Python validation tests once, got $call_count" >&2
  exit 1
fi
echo 'release verify test passed'
