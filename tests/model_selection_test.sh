#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATE_SH_SOURCE_ONLY=true source "$REPO_ROOT/sdcli-scripts/migrate.sh"

declare -a calls=()
run_phase() {
  calls+=("$1|$5")
}

run_all_phases repo src tgt FY3000_20261010_064039 FY3000 /tmp/output 0

[[ "${#calls[@]}" == "9" ]]
[[ "${calls[0]}" == 'capture|FY3000_20261010_064039' ]]
for call in "${calls[@]:1}"; do
  [[ "$call" == *'|latest' ]] || {
    echo "Unexpected model selection: $call" >&2
    exit 1
  }
done

echo "model selection test passed"
