# Offline Container Distribution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a portable, versioned runner image without Oracle SQL Developer, Oracle Instant Client, Microsoft ODBC Driver 18, or Microsoft `mssql-tools18`, then install those packages from customer-owned files on an isolated VM.

**Architecture:** A trusted release host builds an OCI image containing the approved base/runtime and project scripts. A reviewed lock file pins the customer-supplied RPMs; the customer installer validates them before mutation, mounts their directory read-only, installs locally with repositories disabled, and checks the running tools. The bundle and checksum work with cloud, on-premises, or physical transfer.

**Tech Stack:** Bash, Oracle Linux 9, Podman, RPM/DNF offline installation, OCI archive, SHA-256, tar/gzip, shell tests with fake commands

**Spec:** `docs/superpowers/specs/2026-10-09-offline-container-distribution-design.md`

## Global Constraints

- The released image and `.tar.gz` contain no SQL Developer, Oracle Instant Client, `msodbcsql18`, or `mssql-tools18` payloads or RPMs.
- The customer VM never calls `podman build`, `podman pull`, a vendor downloader, or an enabled public package repository.
- The first release targets `linux/amd64`; the accepted host names are `x86_64` and `amd64`.
- The bundle is `dist/sdcli-autokit-<version>-linux-amd64.tar.gz` plus `.sha256`; its image tag is `sdcli-autokit:<version>`.
- Versions match `[A-Za-z0-9._-]+`; manifest and lock files are parsed as data, never sourced or evaluated.
- Customer packages stay in a directory outside the release bundle; only a read-only bind mount exposes them to the container.
- Persistent mounts are `sdcli-autokit_data:/u01/data` and `sdcli-autokit_log:/u01/log`; no mount covers `/u01/app`.
- No script deletes or silently replaces a customer container, image, volume, RPM, or migration output.
- A package inventory, notices, and license review are required before an image is handed to a customer.

## Review Focus

- Missing, duplicate, extra, malformed, symlinked, or checksum-mismatched customer RPMs fail before `podman load` or container creation.
- A forged lock or manifest with shell syntax or unsafe paths is rejected without execution.
- A container with another image or package fingerprint is preserved and produces an actionable error.
- Local RPM installation fails when dependencies are missing; it never enables repositories or silently downloads them.
- A complete image and bundle scan finds no four-family vendor payload, even when build context contains an unrelated local RPM.

---

### Task 1: Pin and validate customer package inputs

**Files:**
- Create: `release/vendor-artifacts.lock`
- Create: `deployment/check-vendor-artifacts.sh`
- Create: `tests/lib/test_helpers.sh`
- Create: `tests/deployment/test_vendor_precheck.sh`
- Create: `tests/run.sh`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: `deployment/check-vendor-artifacts.sh --validate-lock <lock-file>` on the release host, or `deployment/check-vendor-artifacts.sh <lock-file> <absolute-artifact-directory>` on the customer host; the latter uses `sha256sum`, `rpm -qp`, and customer files.
- Produces: strict lock validation in either mode, and a SHA-256 fingerprint of the exact sorted lock rows on stdout when customer files pass; no mutations. Each tab-separated lock row is `role<TAB>rpm_name<TAB>version_release<TAB>arch<TAB>filename<TAB>sha256`.

- [ ] **Step 1: Add failing precheck tests**

Test the six required roles `sqldeveloper`, `instantclient-basic`, `instantclient-sqlplus`, `instantclient-tools`, `msodbcsql18`, and `mssql-tools18`. Assert `--validate-lock` works without RPM files but rejects incomplete or malformed locks. Use fixture RPM headers through a fake `rpm -qp --queryformat` command for customer mode. Assert acceptance of an exact set and rejection of missing, duplicate, extra, zero-length, symlinked, wrong-name, wrong-version, wrong-architecture, or wrong-hash files. Include shell metacharacters and `../` in lock fields and assert that no supplied text executes. Assert no Podman call occurs in a failing precheck.

- [ ] **Step 2: Verify the tests fail on the absent script**

Run: `bash tests/deployment/test_vendor_precheck.sh`

Expected: FAIL because the validator does not exist.

- [ ] **Step 3: Implement the strict validator and test runner**

`check-vendor-artifacts.sh` accepts only the six known roles plus explicitly locked dependency rows; rejects empty/duplicate fields, comments that mask required rows, unsafe filenames, and non-lowercase 64-character hashes. In customer mode it also validates the RPM header for every locked row and prints only the package-set fingerprint. The program never uses `source` or `eval`. `tests/run.sh` runs `bash -n`, the shell test files, and `shellcheck` when available. Add ignore rules so customer artifacts and `dist/` cannot enter git.

- [ ] **Step 4: Pin the release package set**

Choose the supported SQL Developer, Instant Client, Microsoft ODBC, and Microsoft tools RPM versions using the vendor pages in `README.md`. Capture exact filenames and verified SHA-256 values in `release/vendor-artifacts.lock`; inspect `rpm -qp` name, version-release, and architecture for each. If approved inputs are unavailable, leave the lock unfilled and make the release script fail closed; record that a real release cannot be produced yet. Do not invent hashes or copy customer RPMs into the repository.

- [ ] **Step 5: Verify and commit**

Run: `bash tests/deployment/test_vendor_precheck.sh && bash tests/run.sh`

Expected: PASS for all fixture cases. Commit: `git add .gitignore release/vendor-artifacts.lock deployment/check-vendor-artifacts.sh tests && git commit -m "feat: validate customer vendor artifacts"`.

### Task 2: Build a runner image without proprietary packages

**Files:**
- Create: `.dockerignore`
- Modify: `deployment/Dockerfile`
- Modify: `deployment/build.sh`
- Modify: `deployment/.env`
- Modify: `.gitignore`
- Create: `tests/deployment/test_runner_image.sh`

**Interfaces:**
- Consumes: `deployment/build.sh [image-tag]`, `RELEASE_VERSION`, `VCS_REF`, approved `jtds-1.3.1.jar` input and its pinned release-side SHA-256, and the repository's scripts.
- Produces: local `sdcli-autokit:<version>` image with open-source runtime, jTDS, immutable scripts, RPM/DNF local-install capability, and no four-family vendor payload.

- [ ] **Step 1: Add failing image-contract tests**

Use fake Podman to assert build context is the repo root, the image tag and OCI labels are passed, required jTDS/script files are copied, and no vendor RPM is copied. Assert `.dockerignore` allowlists only the Dockerfile, jTDS input, and release-ready `sdcli-scripts/` contents, so a staged vendor RPM and other untracked files are excluded. Scan Dockerfile commands for Microsoft/Oracle vendor repo setup and `dnf install` of proprietary packages. Assert the build fails if jTDS input or its verified hash is absent. Assert no runtime volume is created by `build.sh`.

- [ ] **Step 2: Verify the test fails against the current Dockerfile**

Run: `bash tests/deployment/test_runner_image.sh`

Expected: FAIL on existing Microsoft and Instant Client build steps.

- [ ] **Step 3: Update the image and build script**

Remove Microsoft repository/install and Instant Client repository/install commands. Keep `java-17-openjdk`, `unixODBC`, `rpm`, `dnf`, local RPM dependencies, `jq`, and other needed open-source packages. Copy the approved jTDS JAR to `/u01/app/jtds-1.3.1.jar` and scripts to `/home/sduser/sdcli-autokit-release`. Add a root `.dockerignore` allowlist for exactly those required build inputs. Retain customer-installed tool paths in `PATH`, but do not create fake binaries. Add version/revision labels. Make `build.sh` use `deployment/Dockerfile` with repo-root context and create no volumes. Replace `VOLUME_NAME` in `.env` with `DATA_VOLUME_NAME` and `LOG_VOLUME_NAME`; remove `SD_RPM_URL`, `JTDS_URL`, and `ARTIFACT_DIR` from runtime configuration.

- [ ] **Step 4: Check actual image contents and commit**

Run: `bash tests/deployment/test_runner_image.sh && bash tests/run.sh`

Expected: PASS. On a Podman-equipped build host, run `podman run --rm <tag> rpm -qa` and inspect a saved OCI archive's layer tar entries to confirm the four families are absent from both the final filesystem and image history. Record the result. Commit: `git add .gitignore .dockerignore deployment/Dockerfile deployment/build.sh deployment/.env tests && git commit -m "feat: build vendor-free runner image"`.

### Task 3: Install customer RPMs locally and run the container

**Files:**
- Create: `deployment/install-vendor.sh`
- Create: `deployment/install-offline.sh`
- Modify: `deployment/run.sh`
- Modify: `deployment/start.sh`
- Create: `tests/deployment/test_offline_install.sh`

**Interfaces:**
- Consumes: extracted bundle containing `manifest.env`, `vendor-artifacts.lock`, `image.oci.tar`; `install-offline.sh --artifacts <absolute-directory> --accept-microsoft-eula`; Task 1 precheck; local Podman.
- Produces: a version-matched running container with the artifact directory mounted `/vendor-artifacts:ro,Z`, persistent data/log volumes, a local installation fingerprint, and successful `sdcli`, `sqlcmd`, `bcp`, `sqlplus`, `sqlldr`, `jq`, `yq`, and jTDS checks.

- [ ] **Step 1: Add failing installer tests**

Use fake Podman/RPM commands to assert precheck and explicit Microsoft EULA acknowledgement occur before any `podman load`, volume create, or run. Assert load uses `podman load -i image.oci.tar`, image architecture is checked, the artifact bind mount is read-only, data/log mounts are narrow, and the container is not started for migrations until local package install succeeds. Cover repeat install with identical fingerprint, conflicting image/fingerprint, wrong architecture, corrupt archive, partial local package install, and missing files. Assert no `podman build`, `podman pull`, download command, or enabled repo is invoked.

- [ ] **Step 2: Verify installer tests fail**

Run: `bash tests/deployment/test_offline_install.sh`

Expected: FAIL because the offline installer is absent and `run.sh` downloads tools.

- [ ] **Step 3: Implement manifest and image validation**

In `install-offline.sh`, parse exactly `BUNDLE_VERSION`, `IMAGE_NAME`, `IMAGE_ARCH`, `IMAGE_ARCHIVE`, and `IMAGE_ARCHIVE_SHA256` as data. Require `IMAGE_NAME=sdcli-autokit:<version>`, `IMAGE_ARCH=amd64`, and `IMAGE_ARCHIVE=image.oci.tar`; reject duplicates, unknown keys, shell syntax, and unsafe values. Require the explicit `--accept-microsoft-eula` flag, then verify archive hash, host architecture, and Task 1 package precheck before Podman mutation.

- [ ] **Step 4: Implement local vendor installation**

Inspect the chosen RPM payload paths and dependencies with `rpm -qpl`/`rpm -qpR` on the approved packages. Install all locked files inside the customer container with repository access disabled, for example `dnf --disablerepo='*' --setopt=install_weak_deps=False install <explicit staged RPM paths>`; pass Microsoft's EULA acceptance only after the customer explicitly acknowledges its terms. Adapt the SQL Developer extraction/configuration to the exact RPM layout and set Java 17. Record the package-set fingerprint after all tools pass. If a selected RPM cannot install without an unstaged dependency, add that dependency to the lock and precheck, then rerun the failing test.

- [ ] **Step 5: Update Podman lifecycle scripts**

`run.sh` checks local image/container identity, creates only data/log volumes, mounts the customer directory read-only, runs `install-vendor.sh` as container root, copies editable scripts, and fails hard on missing tool checks. Remove SQL Developer/jTDS downloads. Reuse a container only when image and recorded package fingerprint match. Update `start.sh` guidance for a missing container; keep `stop.sh` unchanged unless testing finds a concrete issue.

- [ ] **Step 6: Verify and commit**

Run: `bash tests/deployment/test_offline_install.sh && bash tests/run.sh`

Expected: PASS. Commit: `git add deployment/install-vendor.sh deployment/install-offline.sh deployment/run.sh deployment/start.sh tests && git commit -m "feat: install customer packages offline"`.

### Task 4: Package and verify the transport-neutral release

**Files:**
- Create: `release/build-offline-bundle.sh`
- Create: `release/verify-offline-bundle.sh`
- Create: `tests/deployment/test_release_bundle.sh`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: `release/build-offline-bundle.sh <version> [--force]`, reviewed `release/vendor-artifacts.lock`, local runner image, approved jTDS input, project scripts.
- Produces: `dist/sdcli-autokit-<version>-linux-amd64.tar.gz` plus `.sha256`; `release/verify-offline-bundle.sh <bundle.tar.gz>` validates the pair and archive contents without a cloud CLI.

- [ ] **Step 1: Add failing release and verification tests**

Assert rejection of empty/unsafe versions, incomplete lock, a sample `config.yaml` containing literal credentials, existing output without `--force`, checksum mismatch, traversal/symlink tar members, missing bundle entries, and any vendor RPM or installed vendor payload in a staged bundle. Assert the same bundle verifies after copying it to an unrelated directory. Test that `manifest.env` contains only the five defined keys and the OCI archive uses the versioned image tag.

- [ ] **Step 2: Verify release tests fail**

Run: `bash tests/deployment/test_release_bundle.sh`

Expected: FAIL because release scripts are absent.

- [ ] **Step 3: Implement release build and verification**

Run `bash tests/run.sh`; require the reviewed lock; build/tag the runner; inspect the final image and saved OCI layers for forbidden packages and paths; generate `sbom.json` from the actual image with an approved scanner; require reviewed `THIRD_PARTY_NOTICES.md` and the image-inventory signoff before publication; stage only the documented deployment/scripts/lock files, SBOM, and notices; generate a strict manifest; tar the versioned directory; write the outer checksum; and publish both files atomically to `dist/`. `verify-offline-bundle.sh` checks the adjacent checksum, safe member types/paths, exact root, required files, and absence of vendor payloads. No cloud CLI or customer artifact path is used by either script.

- [ ] **Step 4: Verify and commit**

Run: `bash tests/deployment/test_release_bundle.sh && bash tests/run.sh && git diff --check`

Expected: PASS. Commit: `git add .gitignore release/build-offline-bundle.sh release/verify-offline-bundle.sh tests && git commit -m "feat: package vendor-free offline runner"`.

### Task 5: Reconcile documentation, license debt, and acceptance evidence

**Files:**
- Modify: `README.md`
- Modify: `.gitignore`
- Create: `docs/offline-release-runbook.md`
- Create: `docs/license-review-debt.md`
- Create: `tests/deployment/test_offline_boundary.sh`

**Interfaces:**
- Consumes: Tasks 1–4 and the approved vendor package set.
- Produces: truthful release and customer instructions, official vendor links, transport examples, explicit open license-review work, and clean-VM acceptance evidence.

- [ ] **Step 1: Add the offline-boundary test**

Assert that the release bundle excludes all customer RPMs, the README describes `--artifacts` and `--accept-microsoft-eula`, and runtime scripts cannot download vendor packages or pull an image. Check that the README vendor links and the lock roles match the installer contract. Run the test and observe failure until docs and scripts align.

- [ ] **Step 2: Update README and runbook**

Replace the README's “planned workflow” caveat when the installer exists. Give exact release, verification, artifact precheck, and install commands. Keep official Oracle SQL Developer, Oracle Instant Client, and Microsoft offline package links; explain that the customer obtains the exact versions named in `vendor-artifacts.lock` and provides any locked dependencies. Provide transfer examples for Azure Blob, Amazon S3, Google Cloud Storage, OCI Object Storage, on-premises shares, SCP/SFTP, and removable media, always transferring the same bundle/checksum pair. Explain upgrade and rollback without automatic deletion.

- [ ] **Step 3: Record license-review debt**

Document the exact-version legal review still needed for Oracle SQL Developer, Instant Client, Microsoft ODBC, and Microsoft tools. Note that newer SQL Developer releases may use Oracle Free Use terms while older releases may have different terms; do not declare all versions nonredistributable. Explain how the Task 4 SBOM, notices, and source offers for Oracle Linux, Java, OS packages, `yq`, jTDS, and transitive components are reviewed. Record the review owner/status and the runner-image inventory signoff required before publication.

- [ ] **Step 4: Verify and exercise on real hosts**

Run: `bash tests/run.sh && git diff --check && git diff --check main...HEAD`

Expected: PASS. On an approved release host, build and inspect the real image and verify that proprietary packages are absent. On an isolated Podman VM, stage the exact customer RPMs, run the precheck and installer, verify every executable, and confirm data/log persistence across stop/start and operator-controlled container replacement. Repeat bundle transfer through at least one cloud and one on-premises/physical method. Record results and any unavailable environment as unverified rather than claiming acceptance.

- [ ] **Step 5: Commit documentation and tests**

Commit: `git add .gitignore README.md docs/offline-release-runbook.md docs/license-review-debt.md tests && git commit -m "docs: describe customer-supplied offline installation"`.

## Final verification

- [ ] `git diff --check main...HEAD` reports no whitespace errors.
- [ ] `bash tests/run.sh` passes all meaningful shell tests; `shellcheck` has no errors when installed.
- [ ] The final image and bundle inventory contain no four-family vendor RPM or installed payload.
- [ ] `git status --short` has no unexpected changes, and no customer RPM is tracked.
- [ ] Actual Linux/Podman and transfer acceptance results are recorded; missing external access is reported as a remaining validation gap.
