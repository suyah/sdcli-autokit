# Password Definition Contract Design

## Intent

Autokit must run SQL Developer 26.2 generated Oracle deployment scripts without
becoming a parser for the SQL*Plus `ACCEPT` command grammar. It must still
provide the configured default schema password non-interactively, keep secrets
outside the generated SDCLI output, and preserve the generated files.

## Evidence

CECREALM generated a valid-looking SQL Developer file with a block-comment
header and `PROMPT "..."HIDE`; the previous parser rejected both formatting
details. A native SQL*Plus 23.26 probe in the local vendor-installed container
showed that an `ACCEPT` executed from an `@file` did not consume answers placed
on the outer non-interactive input stream. Placing answers after an `ACCEPT` in
the sourced file caused `SP2-0734`. Therefore executing the source file
unchanged cannot supply passwords safely in this Bash-only, non-interactive
workflow without adding an expect/PTY dependency.

## Approaches considered

1. Extend the SQL*Plus grammar parser for every observed output variant.
   Rejected: it makes Autokit responsible for vendor syntax and will fail again
   when prompts or comments change.
2. Execute the generated prompt file and stream password answers to SQL*Plus.
   Rejected: native probe showed sourced `ACCEPT` does not consume the outer
   non-interactive input as needed.
3. Extract only the stable `ACCEPT <identifier>` prefix, ignore the rest of
   each prompt command, and generate private SQL*Plus `DEFINE` values.
   Selected: it preserves the existing secure non-interactive mechanism while
   limiting Autikit's contract to the only information it needs.

## Selected design

- `passworddefinition.sql` remains read-only and is never executed or edited by
  Autokit.
- Autokit scans active lines outside SQL*Plus `--` and `/* ... */` comments.
- A line beginning with case-insensitive `ACCEPT` followed by a whitespace-
  delimited identifier contributes that identifier. Everything after the
  identifier is opaque: no validation of `PROMPT`, `HIDE`, quoting, data type,
  formatting, or default syntax.
- Identifiers must remain safe SQL*Plus identifiers (`[A-Za-z_][A-Za-z0-9_]*`).
  An `ACCEPT` line without one is an error. Names are de-duplicated
  case-insensitively because one `DEFINE` is sufficient for repeated references.
- Other active lines are ignored because this file is neither a deployment SQL
  input nor executed by Autokit. This deliberately avoids interpreting future
  SQL Developer control directives.
- Autokit writes one private `0600` temporary `DEFINE` file per SQL*Plus
  invocation and removes it with the existing runtime-directory lifecycle. All
  variables receive the migration's existing `default_schema_password`; support
  for different passwords per generated owner is out of scope and unchanged.
- Log wording reports the number of password variables, not an asserted count
  of vendor prompts.

## Non-goals

- No SQL*Plus grammar implementation.
- No editing generated SDCLI files.
- No expect, PTY, Python, or new package dependency.
- No change to generated DDL, target connections, or password configuration.

## Acceptance evidence

- The exact CECREALM format extracts five identifiers.
- Normal SQL Developer prompt lines and arbitrary valid suffix variations are
  accepted.
- Comments and unrelated directives do not become variables.
- Invalid `ACCEPT` identifiers remain failures.
- Deployment password security, orchestration, generated-layout, role-cleanup,
  and mTLS loader regressions pass.
