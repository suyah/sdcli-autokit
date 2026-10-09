# Offline Container Distribution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce a versioned, checksummed `sdcli-autokit` bundle that can be transferred unchanged through any cloud or on-premises channel and that a registry-isolated customer VM can verify, load, and run with Podman without building or downloading software.

**Architecture:** Bake SQL Developer, jTDS, and the migration scripts into the image during the trusted release build, then export the tagged image as an OCI archive inside a provider-neutral customer bundle. Keep immutable tools below `/u01/app`, mount only data and log volumes, and give the customer strict verification and installation scripts that work regardless of whether the files arrived through Azure, AWS, GCP, OCI, an on-premises service, a file share, or removable media.

**Tech Stack:** Bash, Podman, OCI image archive, Dockerfile, SHA-256, tar/gzip, provider CLI examples, fake-command shell tests

**Spec:** `docs/superpowers/specs/2026-10-09-offline-container-distribution-design.md`

## Global Constraints

- The customer runtime path must not call `podman build`, `podman pull`, `curl`, `wget`, `dnf`, or any public package repository.
- The first supported platform is exactly `linux/amd64`; accept host machine names `x86_64` and `amd64` and reject all others.
- The release bundle is `dist/sdcli-autokit-<version>-linux-amd64.tar.gz` with checksum file `dist/sdcli-autokit-<version>-linux-amd64.tar.gz.sha256`.
- The authoritative image tag is `sdcli-autokit:<version>`; version values are restricted to `[A-Za-z0-9._-]+`.
- Immutable tools remain under `/u01/app`; only `sdcli-autokit_data:/u01/data` and `sdcli-autokit_log:/u01/log` are persistent mounts.
- Customer configuration, database passwords, cloud credentials, signed URLs, access tokens, private endpoint details, migration output, and logs must never be added to an image layer or release manifest.
- Parse `manifest.env` as an allowlisted data format; never execute it with `source`, `.`, or `eval`.
- Installation and release scripts must not delete or silently replace images, containers, volumes, bundles, logs, or migration data.
- Software redistribution must be approved before upload; release automation must not make the bundle public.

## Review Focus

- A crafted manifest containing shell syntax, duplicate keys, unknown keys, or path traversal must be rejected as data by Task 2 tests, never executed.
- An existing same-named container using a different image must remain unchanged and cause an actionable Task 2 failure.
- A partial, corrupt, or checksum-mismatched software artifact, OCI archive, or outer bundle must fail before use in Tasks 1–3.
- Release versions with whitespace, slashes, shell metacharacters, or an empty value must be rejected by Task 3 before filesystem or Podman mutations.
- The build, verification, and installation scripts must have no dependency on Azure, AWS, GCP, OCI, or an on-premises product; provider credentials and endpoints must not appear in generated output, manifests, or repository files, as tested in Task 4.

---

### Task 1: Build a self-contained image

**Files:**
- Modify: `.gitignore`
- Modify: `deployment/Dockerfile`
- Modify: `deployment/build.sh`
- Modify: `deployment/.env`
- Create: `deployment/artifacts/README.md`
- Create: `tests/lib/test_helpers.sh`
- Create: `tests/deployment/test_image_build.sh`
- Create: `tests/run.sh`

**Interfaces:**
- Consumes: `deployment/artifacts/sqldeveloper.rpm`, `deployment/artifacts/jtds-1.3.1.jar`, optional `IMAGE_NAME`, `RELEASE_VERSION`, and `VCS_REF` environment values.
- Produces: `deployment/build.sh [image_name]`, which builds from the repository root using `deployment/Dockerfile`; a complete local image containing `/u01/app/sqldeveloper/sqldeveloper/bin/sdcli`, `/u01/app/jtds-1.3.1.jar`, and `/home/sduser/sdcli-autokit-release/migrate.sh`; `tests/run.sh`, the repository test entry point.

- [ ] **Step 1: Add failing build-contract tests**

In `tests/deployment/test_image_build.sh`, use a temporary fake `podman` on `PATH` and assert:

- missing SQL Developer or jTDS input fails before `podman` is called and names the missing path;
- `deployment/build.sh sdcli-autokit:1.2.3` invokes `podman build --file <repo>/deployment/Dockerfile --tag sdcli-autokit:1.2.3 <repo>`;
- the command supplies `RELEASE_VERSION` and `VCS_REF` build arguments;
- build does not create a volume;
- the Dockerfile copies the two artifacts and `sdcli-scripts/`, verifies `sdcli`, and contains no first-run installer command.

Add reusable `fail`, `assert_eq`, `assert_contains`, `assert_not_contains`, and isolated fake-command helpers to `tests/lib/test_helpers.sh`. Add `tests/run.sh` to run `bash -n` on tracked shell scripts, execute each `tests/deployment/test_*.sh`, and run `shellcheck` when installed.

- [ ] **Step 2: Run the new tests and verify the expected failure**

Run: `bash tests/deployment/test_image_build.sh`

Expected: FAIL because artifact validation and repository-root build behavior do not exist.

- [ ] **Step 3: Expose only safe new paths through `.gitignore`**

Allow `release/` and `tests/`, ignore `dist/`, ignore every file under `deployment/artifacts/`, and re-include only `deployment/artifacts/README.md`. The artifact README must list the exact required filenames and state that licensed binaries must never be committed.

- [ ] **Step 4: Make `deployment/Dockerfile` self-contained at runtime**

Keep all existing package installation on the release/build side. Add `ARG RELEASE_VERSION` and `ARG VCS_REF` plus OCI labels. Copy and extract `deployment/artifacts/sqldeveloper.rpm` during the image build using the current RPM extraction method, set `product.conf` to Java 17, copy jTDS to `/u01/app/jtds-1.3.1.jar`, and copy `sdcli-scripts/` to `/home/sduser/sdcli-autokit-release/`. Set ownership to `sduser` and fail the build unless `sdcli`, jTDS, and `migrate.sh` are present.

- [ ] **Step 5: Change `deployment/build.sh [image_name]` to build from the repository root**

Resolve `REPO_ROOT`, validate both artifact files before invoking Podman, choose the positional image name before `IMAGE_NAME` from `.env`, require nonempty `RELEASE_VERSION` and `VCS_REF` values with development-safe defaults, and call:

```text
podman build --file <repo>/deployment/Dockerfile --tag <image> \
  --build-arg ... --build-arg RELEASE_VERSION=... --build-arg VCS_REF=... <repo>
```

Remove volume creation from this script. Keep the current user, UID/GID, home, and tool-path build arguments.

- [ ] **Step 6: Update default deployment settings**

In `deployment/.env`, replace `VOLUME_NAME` with:

```text
DATA_VOLUME_NAME=sdcli-autokit_data
LOG_VOLUME_NAME=sdcli-autokit_log
```

Keep `IMAGE_NAME=sdcli-autokit:latest` for the maintainer workflow. Remove `SD_RPM_URL`, `JTDS_URL`, and `ARTIFACT_DIR` from `deployment/.env`; Task 3 moves release-side URL and checksum documentation to `release/release.env.example`.

- [ ] **Step 7: Run the build-contract tests**

Run: `bash tests/deployment/test_image_build.sh`

Expected: PASS, including the missing-artifact and fake-Podman cases.

- [ ] **Step 8: Commit Task 1**

```bash
git add .gitignore deployment/Dockerfile deployment/build.sh deployment/.env deployment/artifacts/README.md tests
git commit -m "feat: build self-contained migration image"
```

### Task 2: Make customer installation network-free and idempotent

**Files:**
- Modify: `deployment/run.sh`
- Modify: `deployment/start.sh`
- Create: `deployment/install-offline.sh`
- Create: `tests/deployment/test_offline_install.sh`
- Modify: `tests/run.sh`

**Interfaces:**
- Consumes: bundle-root `manifest.env`, `image.oci.tar`, `deployment/.env`, and `sdcli-scripts/`; local Podman; existing container and volume state.
- Produces: `deployment/install-offline.sh` with no arguments when run inside the extracted bundle; network-free `deployment/run.sh`; existing `start.sh` and `stop.sh` lifecycle compatibility.

- [ ] **Step 1: Add failing offline-install tests**

In `tests/deployment/test_offline_install.sh`, create a temporary bundle and fake `podman`, `uname`, and `sha256sum` commands. Add named cases asserting:

- a valid bundle verifies `image.oci.tar`, loads `sdcli-autokit:1.2.3`, applies the convenience tag `sdcli-autokit:latest` only after successful validation, creates the two volumes, starts the container, and passes health checks;
- `manifest.env` rejects unknown keys, duplicate keys, shell syntax, missing values, invalid image names, and an `IMAGE_ARCHIVE` containing `/`, `..`, or anything other than `image.oci.tar`;
- `arm64` is rejected before Podman mutation;
- a wrong embedded archive checksum is rejected before `podman load`;
- an existing container using another image fails without `rm`, `rmi`, `volume rm`, or container replacement;
- rerunning the same version succeeds without loading the archive again;
- Podman arguments mount only `<data-volume>:/u01/data:Z` and `<log-volume>:/u01/log:Z`, never a volume at `/u01`;
- the complete customer command log contains none of `build`, `pull`, `curl`, `wget`, or `dnf`.

- [ ] **Step 2: Run the installer tests and verify they fail**

Run: `bash tests/deployment/test_offline_install.sh`

Expected: FAIL because `install-offline.sh` does not exist and `run.sh` still performs downloads.

- [ ] **Step 3: Remove runtime software acquisition from `deployment/run.sh`**

Delete `SD_RPM_URL`, `JTDS_URL`, `ARTIFACT_DIR`, `install_sd_if_needed`, and `install_jtds_if_needed` runtime behavior. Require `IMAGE_NAME`, `DATA_VOLUME_NAME`, and `LOG_VOLUME_NAME`; fail if the local image is absent; create the two named volumes; mount them at `/u01/data:Z` and `/u01/log:Z`; retain host networking, container reuse, SQL Developer preference configuration, script copy, and local health checks. Add checks for `yq` and the immutable release copy.

When a same-named container exists, inspect its image reference. Reuse it only when it matches `IMAGE_NAME`; otherwise print both references and exit without modifying the container.

- [ ] **Step 4: Implement strict manifest parsing in `deployment/install-offline.sh`**

Resolve the bundle root as the parent of the script's `deployment/` directory. Read `manifest.env` line-by-line without `source`, `.`, command substitution from file content, or `eval`. Accept exactly one value for each of `BUNDLE_VERSION`, `IMAGE_NAME`, `IMAGE_ARCH`, `IMAGE_ARCHIVE`, and `IMAGE_ARCHIVE_SHA256`, reject every other record, and validate:

```text
BUNDLE_VERSION: [A-Za-z0-9._-]+
IMAGE_NAME: sdcli-autokit:<BUNDLE_VERSION>
IMAGE_ARCH: amd64
IMAGE_ARCHIVE: image.oci.tar
IMAGE_ARCHIVE_SHA256: 64 lowercase hexadecimal characters
```

Require an `x86_64` or `amd64` host, verify the embedded archive, load only when the versioned image is absent, confirm the image exists, apply the local `sdcli-autokit:latest` convenience tag, set the bundle-local `.env` image tag without accepting arbitrary shell content, invoke `run.sh`, and print the installed version and lifecycle commands.

- [ ] **Step 5: Align lifecycle messages**

Update `deployment/start.sh` so a missing container directs the customer to `./install-offline.sh` for a bundle installation or `./run.sh` for a locally built image. Preserve current start/stop behavior and do not introduce image or volume deletion.

- [ ] **Step 6: Run Task 2 and regression tests**

Run: `bash tests/deployment/test_offline_install.sh && bash tests/run.sh`

Expected: PASS. The fake command log contains no customer-side external acquisition command.

- [ ] **Step 7: Commit Task 2**

```bash
git add deployment/run.sh deployment/start.sh deployment/install-offline.sh tests
git commit -m "feat: install and run image offline"
```

### Task 3: Build a reproducible customer bundle

**Files:**
- Create: `release/build-offline-bundle.sh`
- Create: `release/release.env.example`
- Create: `tests/deployment/test_release_bundle.sh`
- Modify: `tests/run.sh`

**Interfaces:**
- Consumes: `release/build-offline-bundle.sh <version> [--force]`; `SD_RPM_URL`, `SD_RPM_SHA256`, `JTDS_URL`, and `JTDS_SHA256` environment variables; Git revision; Podman; release-side `curl`, `sha256sum`, `tar`, `gzip`, and `shellcheck`.
- Produces: `dist/sdcli-autokit-<version>-linux-amd64.tar.gz` and the adjacent `.sha256`; image `sdcli-autokit:<version>`; the bundle layout and strict `manifest.env` defined by the spec.

- [ ] **Step 1: Add failing release-builder tests**

Use fake `curl` and `podman` commands plus real `sha256sum` and `tar`. Assert:

- empty versions and values containing spaces, `/`, `;`, `$`, or backticks fail before downloads, file creation, or Podman calls;
- downloads go to temporary files, a mismatched checksum leaves no artifact at its final path, and a valid checksum atomically installs the artifact;
- `--force` is required to replace an existing bundle or checksum;
- image validation checks `sdcli`, `sqlcmd`, `bcp`, `jq`, `yq`, jTDS, and the immutable migration script before `podman save`;
- the OCI archive is saved with `podman save --format oci-archive` using the versioned image;
- the bundle contains exactly the documented image, manifest, deployment scripts, and editable `sdcli-scripts/` tree;
- both the embedded archive checksum and outer bundle checksum match their files;
- the generated manifest contains only the five allowlisted keys and no URL, cloud credential, signed token, password, local absolute path, or customer value.

- [ ] **Step 2: Run the release-builder tests and verify failure**

Run: `bash tests/deployment/test_release_bundle.sh`

Expected: FAIL because the release builder does not exist.

- [ ] **Step 3: Document release inputs**

Create `release/release.env.example` with placeholder URLs and mandatory 64-character checksum placeholders for SQL Developer and jTDS. State that maintainers copy values into their environment or a non-tracked local file and must confirm redistribution approval before transfer. Do not include signed cloud URLs, access tokens, or secrets.

- [ ] **Step 4: Implement `release/build-offline-bundle.sh <version> [--force]`**

Validate all arguments and tool prerequisites first. Require `shellcheck`, run `bash tests/run.sh`, download each missing or mismatched software artifact through a `mktemp` file, verify its expected checksum, and atomically move it into `deployment/artifacts/`. Never accept a zero-length artifact.

Build `sdcli-autokit:<version>` through `deployment/build.sh`, label it with `git rev-parse HEAD`, and validate its required commands/files with a disposable `podman run --rm` before export. Stage the documented layout in `mktemp -d`, generate the strict manifest, save `image.oci.tar`, calculate its checksum, copy only the required deployment and migration files, create the outer `.tar.gz`, calculate the adjacent checksum, and move both completed outputs into `dist/` only after every check passes. Use a trap to clean temporary files.

- [ ] **Step 5: Run release-builder and full shell tests**

Run: `bash tests/deployment/test_release_bundle.sh && bash tests/run.sh`

Expected: PASS, including invalid-version, corrupt-download, no-overwrite, bundle-layout, and checksum tests.

- [ ] **Step 6: Commit Task 3**

```bash
git add release/build-offline-bundle.sh release/release.env.example tests
git commit -m "feat: package versioned offline release bundle"
```

### Task 4: Verify release files independently of transport

**Files:**
- Create: `release/verify-offline-bundle.sh`
- Create: `tests/deployment/test_bundle_transport.sh`
- Modify: `tests/run.sh`

**Interfaces:**
- Consumes: `release/verify-offline-bundle.sh <bundle.tar.gz>` and adjacent `<bundle.tar.gz>.sha256`; standard `sha256sum`, `tar`, and `gzip` tools.
- Produces: provider-neutral confirmation of the outer checksum, safe archive paths, exact top-level bundle directory, required manifest/image/deployment/migration entries, and no embedded transport configuration.

- [ ] **Step 1: Add failing provider-neutral verification tests**

Assert that missing arguments, a non-`.tar.gz` bundle, a missing checksum, an invalid local checksum, an archive whose root does not match its versioned filename, absolute paths, `..` path traversal, symlinks, missing required entries, or extra top-level entries all fail. A valid release must pass unchanged when copied to a new local directory. Scan the core build, verification, and deployment scripts and assert that none invoke `azcopy`, `aws`, `gcloud`, `gsutil`, `oci`, `scp`, `sftp`, or a vendor SDK.

- [ ] **Step 2: Run the bundle transport tests and verify failure**

Run: `bash tests/deployment/test_bundle_transport.sh`

Expected: FAIL because the provider-neutral verification script does not exist.

- [ ] **Step 3: Implement `release/verify-offline-bundle.sh <bundle.tar.gz>`**

Validate the filename and adjacent checksum before reading the archive. Inspect the tar member list without extracting it; require every member to be a regular file or directory beneath the exact `sdcli-autokit-<version>/` root, reject absolute paths, `..`, links, devices, and extra roots, then require the documented manifest, image archive, deployment scripts, and migration-script entries. Print only the verified bundle name and SHA-256. Do not accept or call a transport CLI.

- [ ] **Step 4: Run transport-neutral and full tests**

Run: `bash tests/deployment/test_bundle_transport.sh && bash tests/run.sh`

Expected: PASS. The same copied bundle verifies without a provider tool, and core scripts contain no provider command.

- [ ] **Step 5: Commit Task 4**

```bash
git add release/verify-offline-bundle.sh tests
git commit -m "feat: verify offline bundles independently of transport"
```

### Task 5: Document operations and prove the offline boundary

**Files:**
- Modify: `.gitignore`
- Modify: `README.md`
- Create: `docs/offline-release-runbook.md`
- Create: `tests/deployment/test_offline_boundary.sh`
- Modify: `tests/run.sh`

**Interfaces:**
- Consumes: the scripts and release contract from Tasks 1–4.
- Produces: maintainer release/transfer instructions, customer receive/install instructions, upgrade/rollback guidance, licensing gate, provider command examples, and a static/runtime guard against customer-side software downloads.

- [ ] **Step 1: Add a failing offline-boundary test**

Assert that `deployment/install-offline.sh`, `deployment/run.sh`, `deployment/start.sh`, and `deployment/stop.sh` contain no executable calls to `podman build`, `podman pull`, `curl`, `wget`, or `dnf`. Execute the valid fake-customer flow and apply the same assertion to its command log. Also assert that runtime volume arguments never target `/u01` and that the README names the release builder, provider-neutral verifier, installer, and Azure/AWS/GCP/OCI/on-premises transfer options.

- [ ] **Step 2: Run the boundary test and verify failure**

Run: `bash tests/deployment/test_offline_boundary.sh`

Expected: FAIL until the documentation and command contract are complete.

- [ ] **Step 3: Track the runbook and update `README.md` for both workflows**

Add a narrow `.gitignore` exception for `docs/offline-release-runbook.md`. Separate maintainer/developer build instructions from customer offline installation. Include exact examples for:

```bash
./release/build-offline-bundle.sh 1.2.3
./release/verify-offline-bundle.sh dist/sdcli-autokit-1.2.3-linux-amd64.tar.gz
# Transfer the .tar.gz and .sha256 through the approved provider or offline channel.
sha256sum -c sdcli-autokit-1.2.3-linux-amd64.tar.gz.sha256
tar -xzf sdcli-autokit-1.2.3-linux-amd64.tar.gz
cd sdcli-autokit-1.2.3
./deployment/install-offline.sh
```

Add a transfer matrix with upload and retrieval examples for Azure Blob (`azcopy`), Amazon S3 (`aws s3 cp`), Google Cloud Storage (`gcloud storage cp`), OCI Object Storage (`oci os object put/get`), an on-premises repository or mounted file share, SCP/SFTP, and removable media. Each example transfers the same `.tar.gz` and `.sha256` without repackaging. Explain the `linux/amd64`, Podman, approved file-transfer, and database-network prerequisites; editable configuration; start/stop behavior; and the fact that customer installation does not build or pull.

- [ ] **Step 4: Add the operational runbook**

Document release approval, license approval, image scanning, artifact checksums, provider-neutral transfer, customer verification, clean-VM acceptance, upgrade, rollback, troubleshooting, and retention. Include authentication and least-privilege notes for Azure, AWS, GCP, OCI, and on-premises repositories without storing credentials in project files. Make removal/replacement of a stopped container an explicit operator command; never place it inside installation automation. State that the checksum should be shared through an approved independent channel when tamper resistance is required.

- [ ] **Step 5: Run all automated verification**

Run: `bash tests/run.sh`

Expected: PASS for syntax, build contract, offline install, release bundle, provider-neutral transport, and offline boundary suites. `shellcheck` reports no errors.

- [ ] **Step 6: Perform release-machine integration verification**

On an approved `linux/amd64` machine with Podman and access to licensed inputs through public sources, internal mirrors, or pre-staged artifacts, run:

```bash
./release/build-offline-bundle.sh 0.0.0-acceptance
sha256sum -c dist/sdcli-autokit-0.0.0-acceptance-linux-amd64.tar.gz.sha256
```

Expected: the real image builds, required in-image tools pass, and the bundle checksum is valid. Record the image ID and archive checksum in the release evidence; do not commit the generated bundle.

- [ ] **Step 7: Perform isolated customer-VM acceptance**

On a clean `linux/amd64` VM with Podman, access to one approved transfer method, required database routes, no registry credentials, and public software repositories blocked, receive the acceptance bundle and run `deployment/install-offline.sh`. Repeat the file-transfer/verification portion with at least one cloud object store and one non-cloud method such as a mounted share or removable media.

Expected: the image loads, container starts, every tool health check passes, no public endpoint is contacted, and data/log files survive stop/start and an operator-controlled container replacement.

- [ ] **Step 8: Commit Task 5**

```bash
git add .gitignore README.md docs/offline-release-runbook.md tests
git commit -m "docs: add offline release and installation runbook"
```

## Final Verification

- [ ] Run `git diff --check main...HEAD` and expect no whitespace errors.
- [ ] Run `bash tests/run.sh` and expect every suite plus `shellcheck` to pass.
- [ ] Run `git status --short` and confirm only intentionally uncommitted local artifact or `dist/` files are ignored.
- [ ] Review the branch for secrets with `git grep -nE '(sig=|password=|token=|secret=|BEGIN .*PRIVATE KEY)' HEAD`; inspect every match and confirm no credential is committed.
- [ ] Confirm the design's acceptance test has been completed or clearly record that real release/customer VM verification remains pending because the required Linux/Podman/transfer environments are external to the repository.
