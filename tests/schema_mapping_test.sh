#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATE_SH_SOURCE_ONLY=true source "$REPO_ROOT/sdcli-scripts/migrate.sh"
task_tmp="$(mktemp -d)"
trap 'rm -rf "$task_tmp"' EXIT
CONFIG_FILE="$task_tmp/config.yaml"
AUTOKIT_DIR="$task_tmp/autokit"
mkdir -p "$AUTOKIT_DIR"
cat > "$CONFIG_FILE" <<'YAML'
migrations:
  - name: demo
    schema_mapping:
      dbo: APP
      audit: AUDIT_LOG
YAML
cat > "$task_tmp/original.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<IdentifierMapping captureId="51"><database databaseName="demo" userName=""><schemas>
<schema internalObjID="951" qualifiedSourceName="DB.dbo" sourceName="dbo" targetName="DB" transformed="Y"><tables><table internalObjID="1001" sourceName="a&amp;b" targetName="a_b" transformed="Y"><columns><column internalObjID="1002" sourceName="id" targetName="id" transformed=""/></columns></table></tables></schema>
<schema internalObjID="1251" qualifiedSourceName="DB.audit" sourceName="audit" targetName="audit_DB" transformed="Y"/>
<schema internalObjID="1301" qualifiedSourceName="DB.stage" sourceName="stage" targetName="stage_DB" transformed="Y"/>
</schemas></database></IdentifierMapping>
XML

# The real XML parser must change only schema owner attributes, retaining all
# IDs and child names. Unknown schemas/collisions must never reach conversion.
prepare_schema_mapping_xml 0 "$task_tmp/original.xml" "$task_tmp/mapped.xml" "$task_tmp/mapping.tsv"
yq -p xml -o json '.' "$task_tmp/original.xml" > "$task_tmp/original.json"
yq -p xml -o json '.' "$task_tmp/mapped.xml" | jq -e '
  .IdentifierMapping["+@captureId"] == "51" and
  .IdentifierMapping.database.schemas.schema[0]["+@targetName"] == "APP" and
  .IdentifierMapping.database.schemas.schema[1]["+@targetName"] == "AUDIT_LOG" and
  .IdentifierMapping.database.schemas.schema[2]["+@targetName"] == "stage_DB"
' >/dev/null
yq -p xml -o json '.' "$task_tmp/mapped.xml" | jq -e --slurpfile original "$task_tmp/original.json" '
  def without_owners: .IdentifierMapping.database.schemas.schema |= map(del(.["+@targetName"], .["+@transformed"]));
  (without_owners) == ($original[0] | without_owners)
' >/dev/null
grep -F $'dbo\tAPP' "$task_tmp/mapping.tsv" >/dev/null
for mapping in '{typo: APP}' '{dbo: APP, audit: app}' '{dbo: stage_DB}' '{dbo: "bad name"}'; do
  printf 'migrations:\n  - schema_mapping: %s\n' "$mapping" > "$CONFIG_FILE"
  if (prepare_schema_mapping_xml 0 "$task_tmp/original.xml" "$task_tmp/rejected.xml" "$task_tmp/rejected.tsv") >"$task_tmp/error" 2>&1; then
    echo "Invalid schema mapping was accepted: $mapping" >&2; exit 1
  fi
done

# yq represents one schema as an object instead of an array.
printf 'migrations:\n  - schema_mapping: {dbo: APP}\n' > "$CONFIG_FILE"
yq -p xml -o json '.' "$task_tmp/original.xml" | jq '.IdentifierMapping.database.schemas.schema = .IdentifierMapping.database.schemas.schema[0]' | yq -p json -o xml '.' > "$task_tmp/single.xml"
prepare_schema_mapping_xml 0 "$task_tmp/single.xml" "$task_tmp/single-mapped.xml" "$task_tmp/single.tsv"
[[ "$(yq -p xml -o yaml '.IdentifierMapping.database.schemas.schema."+@targetName"' "$task_tmp/single-mapped.xml")" == APP ]]

# Stub only the external SDCLI boundary; preparation/composition is real.
DRY_RUN=false
run_sdcli() {
  printf '%s\n' "$*" >> "$task_tmp/calls"
  case "$*" in
    *-actions=idmap\ *)
      mkdir -p "$AUTOKIT_DIR/idmap/original/idmap"
      cp "$task_tmp/original.xml" "$AUTOKIT_DIR/idmap/original/idmap/idmap-1.xml"
      ;;
    *-actions=idmap,convert*)
      [[ "$*" == *-input=* && "$*" != *-output=* && "$*" != *-repository=* ]]
      [[ "$SDCLI_WORKING_DIR" == "$AUTOKIT_DIR/idmap" ]]
      SDCLI_LAST_ACTION=convert
      SDCLI_LAST_SUCCESS_MARKER=true
      ;;
    *) echo 'Unexpected action' >&2; return 1 ;;
  esac
}
run_schema_mapped_conversion 0 1
[[ "$(wc -l < "$task_tmp/calls" | tr -d ' ')" == 2 ]]

# Exercise the actual convert-phase branch, including run/model binding.
begin_phase_status() { :; }
complete_phase_status() { :; }
lookup_sdcli_model_index() { SDCLI_VERIFIED_MODEL_INDEX=1; }
RUN_NAME=run_20261104_010000
run_phase convert repo src tgt 1 demo "$task_tmp/output" 0
if (run_phase convert repo src tgt 2 demo "$task_tmp/output" 0) >"$task_tmp/wrong-model" 2>&1; then
  echo 'Mapped conversion accepted a model from another run' >&2; exit 1
fi
echo 'schema mapping test passed'
