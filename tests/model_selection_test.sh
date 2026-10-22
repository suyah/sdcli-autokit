#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATE_SH_SOURCE_ONLY=true source "$REPO_ROOT/sdcli-scripts/migrate.sh"

declare -a calls=()
run_phase() {
  calls+=("$1|$5")
  case "$1" in
    capture) SDCLI_VERIFIED_MODEL_INDEX=17 ;;
    convert) SDCLI_VERIFIED_MODEL_INDEX=23 ;;
  esac
}

run_all_phases repo src tgt FY3000_20261010_064039 FY3000 /tmp/output 0

[[ "${#calls[@]}" == "9" ]]
[[ "${calls[0]}" == 'capture|FY3000_20261010_064039' ]]
[[ "${calls[1]}" == 'convert|17' ]]
for call in "${calls[@]:2}"; do
  [[ "$call" == *'|23' ]] || {
    echo "Unexpected pinned model selection: $call" >&2
    exit 1
  }
done

calls=()
DRY_RUN=true
run_phase() {
  calls+=("$1|$5")
}
run_all_phases repo src tgt FY3000_20261010_064039 FY3000 /tmp/output 0
[[ "${calls[1]}" == 'convert|<captured-model-index>' ]]
for call in "${calls[@]:2}"; do
  [[ "$call" == *'|<converted-model-index>' ]] || {
    echo "Unexpected dry-run model selection: $call" >&2
    exit 1
  }
done

echo "model selection test passed"
