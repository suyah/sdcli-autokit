# Offline Container Distribution Design

## Decision and scope

Build a versioned `linux/amd64` runner image in an approved build environment and transfer it as a checksum-protected OCI archive. The customer VM loads and runs the image with Podman and needs no registry or public software repository access. The archive and checksum are ordinary files that can travel through Azure Blob Storage, Amazon S3, Google Cloud Storage, OCI Object Storage, an on-premises share or repository, SCP/SFTP, or removable media.

The released image and bundle exclude Oracle SQL Developer, Oracle Instant Client, Microsoft ODBC Driver 18, and Microsoft `mssql-tools18`. The customer obtains the exact approved packages under its own vendor arrangements and places them in a customer-controlled directory. The offline installer verifies those files before creating or changing a container, mounts the directory read-only, and installs the packages locally inside the customer-owned container. Neither the release build nor any transfer location receives those customer packages.

This is a conservative packaging policy, not a determination that every version of every listed product forbids redistribution. Oracle's [current SQL Developer download page](https://www.oracle.com/database/sqldeveloper/technologies/download/) links to [Free Use terms](https://www.oracle.com/downloads/licenses/oracle-free-license.html) that permit redistribution subject to conditions; [older SQL Developer Business Operations terms](https://www.oracle.com/downloads/licenses/sqldev-license.html) are more restrictive. [Instant Client has separate distribution terms](https://www.oracle.com/downloads/licenses/instant-client-lic.html). Microsoft publishes [offline package installation instructions](https://learn.microsoft.com/en-us/sql/linux/install-upgrade/setup-tools?view=sql-server-ver17#offline-installation). The applicable version, package terms, customer entitlement, and any alternate contract need separate review before the policy changes.

The current `deployment/Dockerfile` installs Instant Client and Microsoft RPMs during image build, while `deployment/run.sh` downloads SQL Developer and jTDS at first start. The current named volume also mounts over all of `/u01`, masking any image files placed under `/u01/app`. All three behaviors must change for this design.

## Goals

- Distribute a runner image and project scripts without the four customer-supplied proprietary package families.
- Install those packages from files already present on the customer VM, with no image build, registry pull, vendor download, or public package repository access there.
- Validate package identity, architecture, version, and SHA-256 before creating the application container.
- Preserve `sdcli`, `sqlcmd`, `bcp`, `sqlplus`, `sqlldr`, jTDS, migration scripts, data, and logs in their documented roles.
- Keep transport choice independent of the bundle format and runtime scripts.
- Make repeated installation of the same release and same package set safe and predictable.
- Produce a reviewed inventory and notices for software that remains in the image.

## Boundaries

- The first release targets `linux/amd64` on an `x86_64` customer host with Podman already installed.
- The customer needs access to SQL Server, the Oracle target, and the Oracle migration repository during migration runs.
- Customer files are never copied into a release archive, release image, git, or a publisher-controlled artifact store. The image build context has an explicit path allowlist for vendor RPM exclusion, and the release builder validates the included `config.yaml` as a credential-free template.
- A checksum establishes file integrity against the pinned release inputs, not legal entitlement or publisher identity. An approved trusted channel must provide or authenticate the lock file and bundle checksum.
- This work does not install Podman, provide database credentials, decide commercial licensing, or automatically remove existing containers or volumes.

## Release artifact and component ownership

`release/build-offline-bundle.sh VERSION` produces:

```text
dist/
├── sdcli-autokit-<version>-linux-amd64.tar.gz
└── sdcli-autokit-<version>-linux-amd64.tar.gz.sha256
```

The compressed bundle contains the approved runner image, project scripts, a package requirements lock, and generated release inventory/notices; it contains no customer-supplied vendor packages:

```text
sdcli-autokit-<version>/
├── image.oci.tar
├── manifest.env
├── vendor-artifacts.lock
├── sbom.json
├── THIRD_PARTY_NOTICES.md
├── deployment/
│   ├── .env
│   ├── check-vendor-artifacts.sh
│   ├── install-offline.sh
│   ├── install-vendor.sh
│   ├── run.sh
│   ├── start.sh
│   └── stop.sh
└── sdcli-scripts/
    ├── config.yaml
    ├── migrate.sh
    └── lib/
```

The OCI archive contains Oracle Linux 9, required open-source OS/runtime packages, `yq`, an approved jTDS 1.3.1 JAR, and an immutable copy of `sdcli-scripts`. It contains no SQL Developer, Instant Client, Microsoft ODBC, or Microsoft tools binaries or RPMs. The jTDS input has its own pinned SHA-256 on the release side. Including jTDS is conditional on retaining its applicable license and notices; if that review fails, move it to the same customer-supplied artifact contract before publication. The SBOM and third-party notices in the bundle must pass the organization's review gate.

`manifest.env` contains only five allowlisted data fields: `BUNDLE_VERSION`, `IMAGE_NAME`, `IMAGE_ARCH`, `IMAGE_ARCHIVE`, and `IMAGE_ARCHIVE_SHA256`. It is parsed as data, never executed with `source` or `eval`. The version tag `sdcli-autokit:<version>` is authoritative; `latest` is only a local convenience tag applied after verification.

`vendor-artifacts.lock` is a reviewed, text-only list with one tab-separated row per required RPM: `role`, RPM name, exact version-release, architecture, expected filename, and 64-character SHA-256. The required package roles are SQL Developer, Instant Client Basic, SQL*Plus, Tools, `msodbcsql18`, and `mssql-tools18`; any additional RPM dependencies identified during an isolated smoke test are added as explicit rows. The lock is authored from the approved package set before release and shipped with the bundle. Its hashes and filenames are not generated from whatever the customer happens to supply. A release is refused if any required row is absent, duplicated, malformed, or lacks a reviewed checksum. The release build validates the lock's structure without requiring the proprietary files; the customer precheck validates the files against it.

## Customer installation

The customer first obtains the RPMs from the [official vendor pages listed in the README](../../../README.md#customer-provided-proprietary-artifacts-for-offline-installation) or its approved internal mirrors and transfers them to a directory outside the extracted release. The customer also receives the release bundle and checksum through any approved channel.

`deployment/install-offline.sh --artifacts <absolute-directory> --accept-microsoft-eula` performs this sequence. The acknowledgement flag must be supplied by the customer operator before local installation of Microsoft RPMs; it does not replace the applicable legal terms.

1. Check Podman, `tar`, `sha256sum`, RPM query capability, host architecture, and the customer artifact directory.
2. Parse and validate `manifest.env` and `vendor-artifacts.lock` as strict data formats. Reject duplicate/unknown manifest keys, unsafe paths, duplicate package roles, or malformed lock rows.
3. Verify the bundle's embedded OCI archive and each customer RPM against its pinned hash, RPM header name/version/architecture, and expected role. Reject missing, extra, zero-length, or symlinked artifacts.
4. Check that the configured container name is unused or already identifies the same versioned image and package-set fingerprint. A conflicting container is left untouched with an actionable error.
5. Load the OCI archive if the versioned image is absent, confirm its architecture and contents, and create data/log volumes.
6. Create the application container with the customer artifact directory mounted read-only at `/vendor-artifacts:ro,Z`. Mount only the data and log volumes at `/u01/data:Z` and `/u01/log:Z`; do not mount a volume over `/u01/app`.
7. Run the local vendor installer inside the container before reporting installation success. Record the lock fingerprint in the container's local installation state so restarts do not reinstall and a changed package set is rejected for an existing container.
8. Copy editable migration scripts into the customer container and run executable/file health checks. Required tools are `sdcli`, `sqlcmd`, `bcp`, `sqlplus`, `sqlldr`, `jq`, `yq`, and jTDS.

`deployment/install-vendor.sh` installs only from `/vendor-artifacts`, with all package repositories explicitly disabled. It uses the customer-acknowledged Microsoft EULA mechanism for the pinned RPMs, lets normal RPM package scripts/configuration run where required, and fails if dependencies cannot be satisfied from the base image and staged files. The required dependency set is established through a real isolated smoke test before the lock is approved. SQL Developer is installed/extracted into the expected `SD_HOME` and configured for the image's Java 17 runtime. Installation changes only the customer container's writable layer. On explicit container replacement or image upgrade, the installer repeats from the customer-held artifact directory. Data and logs remain in volumes.

The application container may use `--network host` for database access, but vendor installation must run with network access disabled or otherwise prove that package-manager repositories are disabled and no download command is used. Startup scripts never fetch missing packages. A host without direct internet can receive the release bundle and RPMs through separate approved channels.

## Script and layout changes

- `deployment/Dockerfile` and `.dockerignore`: remove the Microsoft repository and RPM install, and the Instant Client repository and RPM install. Allowlist only required build inputs from the repository root, then copy the approved jTDS JAR and immutable migration scripts. Include local RPM installation/query prerequisites and pinned runtime paths, without vendor payloads.
- `deployment/build.sh`: build the runner on a trusted machine, validate only redistributable inputs, and stop creating customer volumes.
- `release/build-offline-bundle.sh`: validate the reviewed lock and sample `config.yaml`, build and inspect the runner, reject forbidden vendor package names/files in its package inventory and build context, export an OCI archive, and package scripts, lock, checksum, SBOM, and notices. It never downloads or embeds customer vendor RPMs.
- `release/verify-offline-bundle.sh`: verify outer checksum, safe archive paths, required entries, and absence of vendor RPM payloads before publication or extraction.
- `deployment/install-offline.sh`: perform all host-side checks before `podman load`, volume creation, or container creation; mount the customer directory read-only and coordinate installation.
- `deployment/run.sh`: manage local container reuse, volume mounts, script copy, and health checks. Remove the first-start downloads and fail when vendor installation has not completed.
- `deployment/start.sh` and `deployment/stop.sh`: retain daily lifecycle behavior. A missing container directs users to the offline installer.
- `deployment/.env`: replace the broad `/u01` volume with separate `DATA_VOLUME_NAME` and `LOG_VOLUME_NAME`; remove vendor URLs and first-run download settings.

The runner's immutable script copy is under `/home/sduser/sdcli-autokit-release`. Customer configuration is copied to `/home/sduser/sdcli-scripts` after the container is created. SQL Developer and jTDS remain accessible at `/u01/app/sqldeveloper/sqldeveloper/bin/sdcli` and `/u01/app/jtds-1.3.1.jar` respectively. Instant Client uses the pinned Oracle Linux 9 RPM paths; Microsoft tools retain `/opt/mssql-tools18/bin`. The actual RPM payload paths and dependency set must be validated with the selected packages during implementation and acceptance testing.

## Failures, upgrades, and rollback

Missing, mismatched, duplicate, or unrecognized customer files cause a preflight failure before container mutation. A local RPM install failure may leave a stopped, incomplete customer container; it is reported explicitly, never marked installed, and never followed by migration execution. A retry with the same verified inputs can complete or an operator can remove that container. Automation never deletes an image, container, volume, or customer file.

An existing container with the correct version and package fingerprint is reused without reinstallation. An existing container with another version or package fingerprint is not silently upgraded. To upgrade or roll back, an operator stops and replaces only the application container, then runs the chosen version's installer against the required customer artifact set. Named data and log volumes survive replacement. A future persistent-data schema change needs a separate migration design.

## Licensing and supply-chain debt

Before release, generate an actual image inventory/SBOM, capture the RPM `License` metadata and bundled notice files, and review the Oracle Linux base, Java, OS packages, `yq`, jTDS, and transitive dependencies. Publish required notices and source offers with the runner. This inventory is a release gate; it is not a claim that an automated scan alone establishes compliance.

Track a separate legal review by exact product and version for SQL Developer, Instant Client, Microsoft ODBC, and Microsoft tools. Reconsider bundling a product only after legal/procurement confirms the applicable license and customer agreement. Customer supplied files are a delivery policy; the technical precheck cannot validate legal entitlement.

## Verification and acceptance

Shell tests with fake Podman, RPM-query, and package-manager commands cover manifest/lock parsing, checksum and header mismatches, missing and extra files, preflight order, read-only mount arguments, offline installation commands, image identity, idempotence, and conflict safety. Static checks confirm that release artifacts and the image build exclude the four proprietary package families, and that customer scripts have no vendor-download or registry-pull path.

On an approved `linux/amd64` release host, build and inspect the real runner. On an isolated `linux/amd64` VM with the pinned customer RPM set, verify and load the release, install the packages from the read-only mount, start the container, exercise all tool health checks, and confirm data/log persistence across stop/start and explicit container replacement. Test transfer through one cloud channel and one on-premises or physical channel without changing the bundle. Record package versions, hashes, image ID, test results, and any license review still open.
