#!/usr/bin/env bash
# Native SQL Developer identifier mappings. XML is parsed by existing yq/jq,
# never by SQL text matching. Only schema owner attributes are changed.

schema_mapping_json() {
  local kind
  kind="$(yq_eval ".migrations[$1].schema_mapping | tag")" || return 1
  if [[ "$kind" == '!!null' ]]; then
    printf '{}\n'
  else
    yq -o=json ".migrations[$1].schema_mapping" "$CONFIG_FILE"
  fi
}

validate_schema_mapping_config() {
  local mapping
  mapping="$(schema_mapping_json "$1")" || return 1
  if ! jq -e '
    type == "object" and all(to_entries[];
      (.key | length > 0) and
      (.value | if type == "string" then test("^[A-Za-z][A-Za-z0-9_]{0,127}$") else false end)
    )
  ' <<< "$mapping" >/dev/null; then
    log_error "migrations[$1].schema_mapping must map source schema names to simple Oracle owner names (letters, digits, underscore; start with a letter; up to 128 characters)"
    return 1
  fi
}

has_schema_mapping() {
  local mapping
  mapping="$(schema_mapping_json "$1")" || return 1
  [[ "$(jq 'length' <<< "$mapping")" != 0 ]]
}

prepare_schema_mapping_xml() {
  local idx="$1" original="$2" mapped="$3" summary="$4"
  local mapping json_file
  validate_schema_mapping_config "$idx" || return 1
  mapping="$(schema_mapping_json "$idx")" || return 1
  json_file="${mapped}.json"
  # A single schema is an XML object; repeated schemas form an array. Preserve
  # that representation when serializing back, along with all child nodes.
  if ! yq -p=xml -o=json '.' "$original" | jq --argjson mapping "$mapping" '
    def schemas: .IdentifierMapping.database.schemas.schema |
      if type == "array" then . else [.] end;
    (schemas) as $schemas |
    if (.IdentifierMapping["+@captureId"] == null or
        ($schemas | length) == 0 or
        any($schemas[]; .["+@internalObjID"] == null or .["+@sourceName"] == null or .["+@targetName"] == null))
    then error("Native idmap XML is missing schema identifiers") else . end |
    if ($schemas | map(.["+@sourceName"]) | length) !=
       ($schemas | map(.["+@sourceName"]) | unique | length)
    then error("Native idmap contains ambiguous source schema names") else . end |
    ($mapping | keys - ($schemas | map(.["+@sourceName"]))) as $unknown |
    if ($unknown | length) > 0
    then error("Unknown source schemas in schema_mapping: " + ($unknown | join(", "))) else . end |
    def remap:
      .["+@sourceName"] as $source |
      if $mapping | has($source) then
        .["+@targetName"] = $mapping[$source] | .["+@transformed"] = "Y"
      else . end;
    .IdentifierMapping.database.schemas.schema |=
      (if type == "array" then map(remap) else remap end) |
    (schemas | map(.["+@targetName"] | ascii_upcase)) as $owners |
    if ($owners | length) != ($owners | unique | length)
    then error("Schema mapping must be one-to-one; target owner collision (including unchanged default owners)")
    else . end
  ' > "$json_file"; then
    rm -f "$json_file"
    log_error 'Cannot prepare schema mapping; inspect the native XML and configured source/target names'
    return 1
  fi
  yq -p=json -o=xml '.' "$json_file" > "$mapped" || return 1
  {
    printf 'source_schema\ttarget_schema\n'
    jq -r '.IdentifierMapping.database.schemas.schema |
      (if type == "array" then .[] else . end) |
      [.["+@sourceName"], .["+@targetName"]] | @tsv' "$json_file"
  } > "$summary" || return 1
  rm -f "$json_file"
}

run_schema_mapped_conversion() {
  local idx="$1" model="$2" mapping_dir original mapped
  mapping_dir="$AUTOKIT_DIR/idmap"
  original="$mapping_dir/original/idmap/idmap-${model}.xml"
  mapped="$mapping_dir/schema-mapping.xml"
  log_info "Applying configured schema mapping during conversion (captured model $model)"
  if $DRY_RUN; then
    log_info "[DRY-RUN] export native idmap and prepare $mapped using migrations[$idx].schema_mapping"
  else
    mkdir -p "$mapping_dir/original" || return 1
    run_sdcli sdcli migration -actions=idmap -model="$model" -output="$mapping_dir/original" || return 1
    [[ -s "$original" ]] || { log_error "SDCLI idmap export is missing: $original"; return 1; }
    prepare_schema_mapping_xml "$idx" "$original" "$mapped" "$mapping_dir/schema_mapping.tsv" || return 1
    log_info "Schema mapping evidence: $mapping_dir/schema_mapping.tsv"
  fi
  # SQL Developer must see idmap and convert in the SAME session. -output
  # conflicts with -input for idmap; -repository disconnects after the action.
  # Work below /u01/data so the vendor default output cannot land in home.
  SDCLI_WORKING_DIR="$mapping_dir" run_sdcli sdcli migration -actions=idmap,convert -model="$model" -input="$mapped"
}
