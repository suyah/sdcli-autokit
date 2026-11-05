#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
run_script="$REPO_ROOT/deployment/run.sh"
installer="$REPO_ROOT/deployment/install-vendor.sh"
dockerfile="$REPO_ROOT/deployment/Dockerfile"
license_file="$REPO_ROOT/docs/licenses/SQLPACKAGE-LICENSE.txt"

grep -F -- '--accept-sqlpackage-license' "$run_script" >/dev/null
grep -F 'sqlpackage-linux-x64-en-170.4.83.3.zip' "$run_script" >/dev/null
grep -F 'sqlpackage-linux-x64-en-170.4.83.3.zip' "$installer" >/dev/null
grep -F 'e81ede2429f3a15d9e752845c8928569c7706b3a911fad2d1717c0f03e0fc7c3' "$installer" >/dev/null
grep -F 'TOOL_DATA="${TOOL_DATA:-/u01/data/sdcli-autokit}"' "$installer" >/dev/null
grep -F 'sqlpackage_root="${TOOL_DATA%/}/tools"' "$installer" >/dev/null
grep -F 'sqlpackage /Version' "$installer" >/dev/null
grep -F 'sqlpackage /Version' "$run_script" >/dev/null
grep -F 'libicu' "$dockerfile" >/dev/null
if grep -Eq '^[[:space:]]+libunwind([[:space:]\\]|$)' "$dockerfile"; then
  echo 'Oracle Linux 9 does not provide a libunwind package; do not add it to the image dependency list' >&2
  exit 1
fi
test -f "$license_file"
grep -F 'MICROSOFT SQL SERVER DATA-TIER APPLICATION FRAMEWORK' "$license_file" >/dev/null

echo 'SqlPackage customer-staged installation test passed'
