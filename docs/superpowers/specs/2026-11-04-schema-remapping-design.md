# Optional one-to-one schema remapping

Add `migrations[].schema_mapping`, a source-schema to Oracle-owner YAML map.
Omitting it preserves SQL Developer defaults. Unlisted schemas keep defaults.
Use the existing Bash, yq 4.45.1 XML parser and jq; add no Python or XML regex.

## Approach and evidence

The remote SQL Developer 26.2 run proved `idmap,convert -input=...` produces
the requested target owners. Standalone import did not survive a separate
process. Passing both input and output to idmap rejects the import, yet the
vendor still prints success and proceeds to convert. Re-conversion can reuse
the existing converted model; never assume an additional model index.

Export native idmap for the captured numeric index, structurally update only
schema targetName and transformed attributes, then run idmap,convert in one
process without output/repository arguments. Keep its working directory and
evidence under the run's autokit/idmap directory. All other identifiers and
capture IDs remain unchanged. Do not edit DDL or repository tables.

## Scope and behavior

The existing convert phase performs this automatically when configured,
including full workflows. Export original XML, mapped XML and a concise TSV
of effective owner names. Preserve the original export. Retain existing
project-profile/repository locks and wallet handling. Refuse unknown source
schemas, ambiguous schema entries, invalid simple Oracle target identifiers
or owner collisions (case-insensitive), including unchanged default owners.
For mapped conversion, resolve/verify the captured model belongs to this run.

Require every requested action's completion marker and reject Error/Fatal/ORA
even if the vendor also prints success. Object-level translation diagnostics
remain warnings. Model discovery uses the existing exact 26.2 parser.

No standalone idmap phase, many-to-one mapping, datatype validation, general
SQL parsing or business-procedure rewriting. Existing runs already converted
with native idmap can resume at generate/datamove without converting again.

## Release

Ship as 1.3.0 (new optional capability), including pending PR #28 fixes.
Feature PR, separate release-notes PR, remote merges, sync local main, then
verified online image build/offline tar.gz bundle. Tag only after verified
artifact. Customer upgrades preserve named volumes, profiles and run output.
