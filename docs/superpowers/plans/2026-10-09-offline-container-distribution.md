# Offline Container Distribution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the runner on a connected machine and run it on an offline customer VM using customer-supplied Oracle and Microsoft RPMs.

**Architecture:** Export one versioned Podman image with the deployment and migration scripts in a checksum-protected tarball. The customer verifies and loads it, then `run.sh` mounts a local RPM directory and installs only from those files. No cloud-specific code or release service is involved.

**Tech Stack:** Bash, Podman, Oracle Linux 9, RPM/DNF, tar, SHA-256

**Spec:** `docs/superpowers/specs/2026-10-09-offline-container-distribution-design.md`

## Global Constraints

- Customer VM: Linux/amd64 with Podman; no image build, registry pull, vendor download, or enabled package repository.
- Do not put Oracle SQL Developer, Oracle Instant Client, `msodbcsql18`, or `mssql-tools18` in the distributed image or tarball.
- Customer RPMs stay in a separate directory mounted read-only at `/vendor-rpms`; no script uploads them.
- Preserve `/u01/data` and `/u01/log` in separate volumes. Never mount over `/u01/app` or silently delete/replace a container or volume.
- Keep official customer-download links and tested RPM versions in the README. Do not claim all versions are legally barred from redistribution.

## Review Focus

- A missing RPM, wrong architecture, or unsatisfied dependency produces a clear local failure, not a download.
- A different existing container image is left alone with instructions for operator-controlled replacement.
- A failed install cannot be reported as a ready migration environment.
- The exported image and tarball contain no customer-supplied Oracle/Microsoft payloads.
- The bundle checksum and offline `podman load` work after transfer to another machine.

---

### Task 1: Run with customer RPMs and no network downloads

**Files:**
- Modify: `deployment/run.sh`, `deployment/start.sh`, `deployment/.env`
- Create: `deployment/install-vendor.sh`, `tests/test_offline_run.sh`

**Interfaces:**
- Consumes: a local image tagged `sdcli-autokit:<version>`, a plain `VERSION` file in the bundle root, and `deployment/run.sh --vendor-dir <absolute-directory> --accept-microsoft-eula`.
- Produces: a running container with working `sdcli`, `sqlcmd`, `bcp`, `sqlplus`, and `sqlldr`; `start.sh`/`stop.sh` control it afterward.

- [ ] **Step 1: Write a failing run test.** Use a fixture `VERSION` and fake Podman/RPM/DNF commands to cover absent image or directory, missing required RPM filenames before container creation, wrong RPM architecture after mounting, missing EULA acknowledgement, read-only mount, narrow data/log volumes, and image mismatch on an existing container. Assert no `wget`, `curl`, `podman pull`, `podman build`, or enabled repository path is used. Assert a failed local install stops the container and does not report readiness.
- [ ] **Step 2: Run `bash tests/test_offline_run.sh`.** Expected: FAIL because `run.sh` still downloads SQL Developer/jTDS and mounts over `/u01`.
- [ ] **Step 3: Add the local installer.** In `install-vendor.sh`, inspect every staged RPM header, require SQL Developer, Instant Client Basic/SQL*Plus/Tools, `msodbcsql18`, and `mssql-tools18`, and reject other architectures. Reuse the existing SQL Developer RPM extraction into `SD_HOME`. Install the other RPMs and staged dependencies using only local paths and `dnf --disablerepo='*'`, passing Microsoft's EULA setting only after the operator's flag. Fail with the DNF error if offline dependencies are missing.
- [ ] **Step 4: Update `run.sh` and configuration.** Read `VERSION` as a simple validated value to choose the loaded image; retain `.env` for existing settings but remove download URLs. Check for the six expected RPM filenames before container creation, then mount `/vendor-rpms` read-only and separate `/u01/data` and `/u01/log` volumes. Invoke the installer for a new or incomplete same-version container, remove first-run downloads, keep the existing script-copy/preferences behavior, and check the tool binaries. Stop the container if installation fails. Refuse another image version; never auto-remove it. Point `start.sh` at `run.sh` when a container is missing.
- [ ] **Step 5: Run `bash tests/test_offline_run.sh && git diff --check`.** Expected: PASS. Then test with real RPMs on an isolated Linux/amd64 Podman VM; record any package-layout or dependency correction instead of guessing it from fixtures.
- [ ] **Step 6: Commit the offline-run change.** Commit only the files from this task.

### Task 2: Build and export the small offline bundle

**Files:**
- Modify: `deployment/Dockerfile`, `deployment/build.sh`, `.gitignore`
- Create: `release/build-offline.sh`, `tests/test_offline_bundle.sh`

**Interfaces:**
- Consumes: `release/build-offline.sh <version>` on a connected Linux/amd64 Podman host.
- Produces: `dist/sdcli-autokit-<version>-linux-amd64.tar.gz` and its `.sha256`. The tarball has `image.tar`, `VERSION`, `README.md`, `sdcli-scripts/`, and only `deployment/.env`, `run.sh`, `start.sh`, `stop.sh`, and `install-vendor.sh` under `deployment/`.

- [ ] **Step 1: Write a failing bundle test.** With a fake Podman command, assert that the version becomes image tag `sdcli-autokit:<version>`, `podman save` creates `image.tar`, the tarball has the named files, and the checksum verifies. Assert invalid versions and an existing output fail without overwriting it. Stage an unrelated RPM in the source tree and assert it is excluded from the tarball. Check that Dockerfile no longer installs Oracle Instant Client or Microsoft packages.
- [ ] **Step 2: Run `bash tests/test_offline_bundle.sh`.** Expected: FAIL against the current build script and missing release script.
- [ ] **Step 3: Implement the build/export path.** Keep the existing Dockerfile runtime, remove proprietary package/repository steps, and obtain jTDS during this connected build instead of at customer startup. Check jTDS distribution terms and retain required notices before publication; if it cannot be included, change the spec to make it customer supplied. Make `build.sh` accept a versioned tag and stop creating volumes. Make `build-offline.sh` validate a simple version string, build, `podman save`, stage only the named files and tracked `sdcli-scripts` files, archive them, and write the checksum. Do not add a manifest, lockfile, cloud uploader, scanner, or signing framework.
- [ ] **Step 4: Run `bash tests/test_offline_bundle.sh && git diff --check`.** Expected: PASS. On a real build host, inspect the saved image for the four excluded package families; the fake test does not prove image contents.
- [ ] **Step 5: Commit the build/export change.** Commit only the files from this task.

### Task 3: Document and smoke-test the handoff

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: Tasks 1 and 2 plus the RPM versions actually tested on an isolated VM.
- Produces: copyable maintainer/customer commands and honest acceptance notes.

- [ ] **Step 1: Update README.** Replace the “planned workflow” wording only after the scripts exist. Show build, checksum verification, extraction, `podman load`, vendor RPM placement, `run.sh`, start/stop, and manual container replacement commands. Keep official vendor links and state the exact RPM versions tested together. Say any cloud or on-premises transfer method may carry the same tarball and checksum; do not add provider-specific scripts.
- [ ] **Step 2: Verify the actual handoff.** Build and inspect the image on a connected host. Check bundled `config.yaml` for customer-specific values, and check jTDS and other software notices before distribution. Transfer the tarball/checksum to a clean isolated VM, verify checksum, load, install from customer RPMs, run the tool health checks and a migration smoke test, and confirm data/logs survive stop/start. Record which checks ran and which remain unverified.
- [ ] **Step 3: Run `bash tests/test_offline_run.sh && bash tests/test_offline_bundle.sh && git diff --check`.** Expected: PASS. Commit the README change.

## Completion check

- [ ] The real image and tarball have no customer-supplied Oracle/Microsoft packages.
- [ ] The customer VM can verify, load, install, and run without a registry or software-repository connection.
- [ ] README commands match the shipped files, and untested steps are labeled unverified.
