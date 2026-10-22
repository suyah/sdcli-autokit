#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
dockerfile="$REPO_ROOT/deployment/Dockerfile"
run_script="$REPO_ROOT/deployment/run.sh"
bundle_script="$REPO_ROOT/release/build-offline.sh"
futc_license="$REPO_ROOT/docs/licenses/ORACLE-FUTC.txt"
dockerignore="$REPO_ROOT/.dockerignore"

grep -F 'ARG SQLCL_VERSION=26.2.2.233.1901' "$dockerfile" >/dev/null
grep -F 'ARG SQLCL_SHA256=17f89fddf69722f37d7bde0718e66490647b25b295bf52fba92ba0ad042fa256' "$dockerfile" >/dev/null
grep -F 'sqlcl-${SQLCL_VERSION}.zip' "$dockerfile" >/dev/null
grep -F 'sha256sum -c -' "$dockerfile" >/dev/null
grep -F 'ln -s "$java_home" "$JAVA_HOME"' "$dockerfile" >/dev/null
grep -F 'test -x "$JAVA_HOME/bin/java"' "$dockerfile" >/dev/null
grep -F 'chgrp -R "${APP_GROUP}" /opt/sqlcl' "$dockerfile" >/dev/null
grep -F 'chmod -R g+rX /opt/sqlcl' "$dockerfile" >/dev/null
grep -F '/opt/sqlcl/LICENSE.txt' "$dockerfile" >/dev/null
grep -F '/opt/sqlcl/NOTICES.txt' "$dockerfile" >/dev/null
grep -F 'sql -version' "$run_script" >/dev/null
grep -F 'docs/licenses/ORACLE-FUTC.txt' "$bundle_script" >/dev/null
grep -Fx '!docs/' "$dockerignore" >/dev/null
grep -Fx '!docs/licenses/' "$dockerignore" >/dev/null
grep -Fx '!docs/licenses/ORACLE-FUTC.txt' "$dockerignore" >/dev/null
test -f "$futc_license"
grep -F 'Oracle Free Use Terms and Conditions' "$futc_license" >/dev/null

if grep -Fq 'sqlcl-latest.zip' "$dockerfile"; then
  echo 'Dockerfile must not download the moving SQLcl latest artifact' >&2
  exit 1
fi

echo 'SQLcl image configuration test passed'
