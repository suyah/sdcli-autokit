# SqlPackage Source Schema Export Design

## Intent

Provide one reliable, offline-capable way to obtain the SQL Server source
schema for migration review and LLM-assisted repair of SQL Developer conversion
failures.  The export must include routines and ordinary schema objects without
trying to recreate SQL Server DDL in Bash or with regular expressions.

## Scope

- Support a customer-provided Microsoft SqlPackage for Linux x64 ZIP installed
  during deployment; do not add the binary to the publisher-built image.
- Add one project-aware command that reads the existing `config.yaml` source
  connection and environment-expanded source password.
- Produce a source DDL tree, including SQL Server routines, under the selected
  migration's project directory.
- Document the customer-facing command, output, security properties, licence
  notice, and limitations.

The command does not export table data, send artefacts to an LLM, alter the
source database, replace SDCLI-generated artefacts, or change migration phases.

## Selected approach

Use the supported `SqlPackage /Action:Extract` operation with
`ExtractAllTableData=False` and `ExtractTarget=SchemaObjectType`.

This produces organised source SQL files.  `DacPac` and `SchemaObjectType` are
alternative Extract targets, so the tool deliberately produces the latter
rather than running a second extraction merely to retain a binary package that
is not needed for migration repair.  In particular, routines are obtained from
SqlPackage/DacFx rather than from a custom query against `sys.sql_modules`.

### Alternatives considered

1. **Custom `sqlcmd` routine exporter plus a metadata-to-DDL Bash exporter**
   was rejected: it would duplicate a growing subset of SQL Server DDL and
   eventually mishandle dependencies, constraints, advanced types, or object
   options.
2. **Publish the official SqlPackage ZIP in the Autokit image or bundle** was
   rejected: it would make the publisher subject to the archive's distinct
   Distributable Code conditions. The customer instead stages the ZIP in its
   existing vendor-artifact directory alongside the RPMs.
3. **A new migration phase in `migrate.sh`** was rejected: schema extraction is
   a supporting evidence operation, not a required SDCLI migration phase.

## Packaging and licence

The public DacFx source repository uses MIT, but the official self-contained
SqlPackage Linux ZIP carries distinct Microsoft SQL Server Data-Tier Application
Framework licence terms.  Its "Distributable Code" clause permits distribution
only with an application that adds significant primary functionality, requires
downstream users to accept sufficiently protective terms, and imposes an
indemnity obligation on the distributor.

Therefore this design does not bundle SqlPackage in the Autokit image merely
because the source repository is MIT.  The selected path is that the customer
downloads the official ZIP through its approved Microsoft channel and stages it
as a named vendor artefact.  `run.sh` requires a separate
`--accept-sqlpackage-license` acknowledgement, verifies the fixed release's
SHA-256, and installs it under the persistent data volume.  The archive's
`LICENSE.TXT` is retained there; a verbatim reference copy is kept in this
source repository and the README links to the official download.

## Command interface

Add a standalone command:

```bash
./export-source-schema.sh <migration> [--output <absolute-directory>]
```

Without `--output`, the command creates a timestamped directory:

```text
<project_root>/<migration>/source-schema/<UTC timestamp>/
  sql/                         # SqlPackage SchemaObjectType SQL output
  sqlpackage-extract.log        # diagnostic artefact, password-redacted
  manifest.txt                  # source endpoint, TLS mode, and tool version
```

The output directory and contents are created with owner-only permissions
where the filesystem permits it, because DDL can contain business logic and
literals.  Existing output is never overwritten.

## Connection and secret handling

The script reuses existing `migrate.sh` configuration helpers for migration
selection, environment-variable substitution, validation, source connection
parsing, and `defaults.source.bcp_tls_mode` (`strict`, `trust`, or `optional`).

The resolved password is supplied to SqlPackage only for its one Extract
process.  SqlPackage's documented SQL-auth interface accepts the password as a
CLI parameter; unlike `sqlcmd`, it has no `SQLCMDPASSWORD`-style environment
variable or stdin password option for Extract.  The script therefore never
puts it in an Autokit command log, diagnostic, generated artefact, manifest,
or shell trace.  The documented trust boundary is the existing container's
single `sduser` account: an untrusted process running as that same Unix user
could inspect a live process argument, just as it can inspect existing SDCLI
SQL-auth calls.  The script uses the source host, port, database, and SQL-auth
user already declared in `migrations[].source`.

## Behaviour and failure handling

- Validate `sqlpackage` exists before starting.
- Validate the source connection and selected migration before creating output.
- Pass the selected TLS policy to SqlPackage explicitly.
- Write diagnostics to a temporary file; redact it before copying it into the
  output directory or emitting it to stderr.
- Treat a nonzero SqlPackage exit or a missing SQL tree as a failed export;
  retain the redacted diagnostic artefact for diagnosis.
- Never use output text as a correctness signal and never parse generated SQL
  with regular expressions.

## Testing

Unit tests use a fake `sqlpackage` executable.  They assert command shape,
source-secret non-disclosure, TLS mapping, output layout, no-overwrite
behaviour, successful schema-only artefacts, and failure handling.  A local
container smoke test verifies `sqlpackage /Version` and the script's preflight;
a live source extraction is optional and only performed when the user provides
an authorised test source.

## Documentation

README gains:

- SqlPackage availability in the image and the supported 26.2 tool boundary.
- The extraction command and the distinction between schema-only output and
  migration data files.
- How to give selected routine source plus relevant table DDL to an LLM.
- The retained licence/notice location.
