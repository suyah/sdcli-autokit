#!/usr/bin/env bash
set -euo pipefail

# Collect diagnostic evidence for one completed migration run without copying
# configuration, credentials, wallets, generated DDL, exported rows, loader
# control files, or rejected-row payloads.

usage() {
  cat <<'USAGE'
Usage:
  collect-run-evidence.sh <migration> --run <run-id> [--output <directory>]

Environment:
  AUTOKIT_PROJECT_ROOT  Defaults to /u01/data/sdcli-autokit/projects.

The bundle contains run logs, phase/status evidence, validation reports,
mapping evidence, and SDCLI/loader log files only. It excludes configuration,
wallets, profiles, generated SQL, BCP data, SQL*Loader control files, and
rejected-row files.
USAGE
}

fail() {
  echo "Error: $*" >&2
  exit 1
}

sha256_value() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

[[ $# -ge 1 ]] || {
  usage >&2
  exit 2
}

migration="$1"
shift
run_id=""
output_dir=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --run)
      [[ $# -ge 2 ]] || fail "--run requires a value"
      run_id="$2"
      shift 2
      ;;
    --output)
      [[ $# -ge 2 ]] || fail "--output requires a directory"
      output_dir="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      fail "unknown option: $1"
      ;;
  esac
done

[[ -n "$run_id" ]] || fail "--run is required"
project_root="${AUTOKIT_PROJECT_ROOT:-/u01/data/sdcli-autokit/projects}"
run_dir="$project_root/$migration/run_$run_id"
[[ -d "$run_dir" ]] || fail "run directory not found: $run_dir"
[[ ! -L "$run_dir" ]] || fail "run directory must not be a symbolic link: $run_dir"
run_dir_physical="$(cd "$run_dir" && pwd -P)" || fail "cannot resolve run directory: $run_dir"

if [[ -z "$output_dir" ]]; then
  output_dir="$(dirname "$project_root")/support-bundles"
fi
mkdir -p "$output_dir"
command -v tar >/dev/null 2>&1 || fail "tar is required"
command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 || fail "sha256sum or shasum is required"

created_utc="$(date -u +%Y%m%dT%H%M%SZ)"
bundle_name="sdcli-autokit-evidence-${migration}-${run_id}-${created_utc}"
tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/sdcli-autokit-evidence.XXXXXX")"
trap 'rm -rf "$tmpdir"' EXIT
stage_dir="$tmpdir/$bundle_name"
mkdir -p "$stage_dir"
collected_count=0

copy_evidence_file() {
  local source="$1"
  local relative destination source_parent
  [[ -e "$source" || -L "$source" ]] || return 0
  [[ ! -L "$source" ]] || fail "evidence file must not be a symbolic link: $source"
  [[ -f "$source" ]] || fail "evidence path is not a regular file: $source"
  [[ -r "$source" ]] || fail "evidence file is not readable: $source"
  source_parent="$(cd "$(dirname "$source")" && pwd -P)" \
    || fail "cannot resolve evidence parent directory: $source"
  case "$source_parent/" in
    "$run_dir_physical/"*) ;;
    *) fail "evidence file resolves outside the run directory: $source" ;;
  esac
  relative="${source#"$run_dir"/}"
  destination="$stage_dir/$relative"
  mkdir -p "$(dirname "$destination")"
  cp -p "$source" "$destination"
  collected_count=$((collected_count + 1))
}

ensure_evidence_directory() {
  local path="$1"
  local label="$2"
  local required="$3"

  if [[ ! -e "$path" && ! -L "$path" ]]; then
    [[ "$required" == true ]] && fail "$label is missing: $path"
    return 0
  fi
  [[ ! -L "$path" ]] || fail "$label must not be a symbolic link: $path"
  [[ -d "$path" ]] || fail "$label is not a directory: $path"
  [[ -r "$path" && -x "$path" ]] || fail "$label is not readable: $path"
}

ensure_evidence_directory "$run_dir/autokit" "runner evidence directory" true
ensure_evidence_directory "$run_dir/sdcli" "SQL Developer output directory" true
ensure_evidence_directory "$run_dir/autokit/idmap" "schema-mapping evidence directory" false
ensure_evidence_directory "$run_dir/sdcli/log" "SDCLI log directory" false
ensure_evidence_directory "$run_dir/sdcli/datamove" "data-movement log directory" false

# A run's root evidence is a fixed runner contract. Do not treat a familiar
# suffix as evidence: a customer could put credentials.txt or customer.csv in
# this directory, and support bundles must never discover those by accident.
root_evidence_files=(
  migrate.log
  sdcli_commands.log
  sdcli_commands_summary.txt
  migration_summary.csv
  phase_status.tsv
  deploy_manifest.tsv
  bcp_status.tsv
  bcp_source_tables.tsv
  bcp_queryout_adjustments.tsv
  sqlldr_status.tsv
  target_row_counts.tsv
  reconciliation.tsv
  source_object_inventory.tsv
  target_object_inventory.tsv
  validation_checks.tsv
  validation_summary.txt
  migration_report.html
  migration_report.txt
  repository_init_check.out
)
for evidence_name in "${root_evidence_files[@]}"; do
  copy_evidence_file "$run_dir/autokit/$evidence_name"
done

# Schema mapping is small evidence needed to interpret generated owners. Native
# idmap XML is intentionally excluded because it is an editable input artifact,
# not a support log.
copy_evidence_file "$run_dir/autokit/idmap/schema_mapping.tsv"

collect_log_files() {
  local log_root="$1"
  local label="$2"
  local list_file="$3"
  shift 3

  [[ -d "$log_root" ]] || return 0
  if ! find "$log_root" "$@" > "$list_file"; then
    fail "Cannot collect $label; directory is unreadable or changed: $log_root"
  fi
  while IFS= read -r -d '' source; do
    copy_evidence_file "$source"
  done < "$list_file"
}

# SQL Developer's documented error log is error.txt. Other runtime diagnostics
# must use a conventional log/output/error suffix; arbitrary files under an
# SDCLI directory are never trusted as logs.
collect_log_files "$run_dir/sdcli/log" "SDCLI log evidence" "$tmpdir/sdcli-log-files" \
  -type f \( -iname '*.log' -o -iname '*.out' -o -iname '*.err' \
    -o -name 'error.txt' -o -name 'stdout.txt' -o -name 'stderr.txt' \) -print0

# SQL*Loader and its wrapper can write diagnostics anywhere under datamove.
# Keep only conventional diagnostic suffixes; .bad/.dsc files contain rejected
# customer rows and are never collected.
collect_log_files "$run_dir/sdcli/datamove" "SQL*Loader log evidence" "$tmpdir/sqlldr-log-files" \
  -type f \( -iname '*.log' -o -iname '*.out' -o -iname '*.err' \) -print0

cat > "$stage_dir/collection_summary.txt" <<EOF
SDCLI Autokit Evidence Bundle
Migration: $migration
Run: $run_id
Collected (UTC): $created_utc
Run directory: $run_dir

Included:
- named runner status files, validation reports, and schema-mapping TSV evidence
- SQL Developer error/output/log files with conventional diagnostic names
- SQL*Loader .log, .out, and .err files under datamove

Excluded by design:
- config, wallets, profiles, credentials, and SQL Developer saved connections
- generated SQL/DDL, BCP export data, SQL*Loader control files, and rejected-row files
- SQL*Loader .bad and .dsc payloads
EOF

manifest="$stage_dir/bundle_manifest.tsv"
printf 'path\tbytes\tsha256\n' > "$manifest"
while IFS= read -r source; do
  relative="${source#"$stage_dir"/}"
  [[ "$relative" == "bundle_manifest.tsv" ]] && continue
  printf '%s\t%s\t%s\n' \
    "$relative" \
    "$(wc -c < "$source" | tr -d '[:space:]')" \
    "$(sha256_value "$source")" >> "$manifest"
done < <(find "$stage_dir" -type f | LC_ALL=C sort)

bundle="$output_dir/$bundle_name.tar.gz"
tar -C "$tmpdir" -czf "$bundle" "$bundle_name"
(
  cd "$output_dir"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$(basename "$bundle")" > "$(basename "$bundle").sha256"
  else
    shasum -a 256 "$(basename "$bundle")" > "$(basename "$bundle").sha256"
  fi
)

echo "Collected evidence files: $collected_count"
echo "Excluded: config, wallets, profiles, generated SQL, BCP data, loader control files, and rejected-row files"
echo "Evidence bundle: $bundle"
echo "SHA-256 file: $bundle.sha256"
