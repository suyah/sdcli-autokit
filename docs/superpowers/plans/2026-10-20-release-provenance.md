# Release Provenance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Separate the publisher’s online image build from offline-bundle packaging and prevent a normal release from using an unverified local image.

**Architecture:** `build-image.sh` creates a Linux/amd64 image with source and
release provenance labels. `build-offline.sh` only inspects and exports an
already labelled image, while `release.sh` composes optional verification and
rebuild steps. The archive records the image ID beside the existing source
metadata.

**Tech Stack:** Bash, Docker/Podman CLI, OCI image labels, shell integration
tests with a fake Podman executable.

**Spec:** `docs/superpowers/specs/2026-10-20-release-provenance-design.md`

## Global Constraints

- Support Oracle SQL Developer 26.2 and Linux/amd64 only.
- Publisher image builds are online; customer installation and execution are
  offline.
- Do not bundle customer configuration, wallets, vendor RPMs, runtime data,
  logs, mounted volumes, or the engineering changelog.
- Preserve the `release/build-offline.sh` entry point for existing callers.
- Do not create tags, upload artifacts, or add registry/CI/signing machinery.
- Keep the implementation Bash-only and proportionate for one maintainer.

## Review Focus

- An existing image with the right tag but missing provenance must fail before
  `save`; Task 2 test asserts this.
- A label from a different source commit or version must fail without an
  implicit rebuild; Task 2 test asserts both the error and no `build` call.
- Default `release.sh` must not run either the image build or test suite;
  Task 3 test asserts its fake-engine command log.
- Option parsing must reject duplicate or unknown flags before creating output;
  Task 3 test asserts no archive is created.
- The bundle must bind its saved image to a readable immutable ID; Task 2 test
  extracts and asserts `IMAGE_ID`.

---

### Task 1: Build a labelled online release image

**Files:**
- Create: `release/build-image.sh`
- Modify: `deployment/Dockerfile`
- Modify: `deployment/build.sh`
- Test: `tests/test_offline_bundle.sh`

**Interfaces:**
- Consumes: `release/preflight.sh <version>` and `deployment/build.sh <tag>`.
- Produces: `release/build-image.sh <version>`, which creates
  `sdcli-autokit:<version>` with `org.opencontainers.image.version`,
  `org.opencontainers.image.revision`, `org.opencontainers.image.created`, and
  `org.opencontainers.image.platform=linux/amd64` labels.

- [ ] **Step 1: Write failing fake-engine assertions for the online image-build interface**

Extend `tests/test_offline_bundle.sh` so its fake Podman accepts `image
inspect`, captures build arguments, and asserts `build-image.sh 1.2.3` calls
`podman build --arch amd64` with the four provenance build arguments.

- [ ] **Step 2: Run the focused test to verify it fails**

Run: `bash tests/test_offline_bundle.sh`

Expected: FAIL because `release/build-image.sh` does not exist and the
Dockerfile/build script do not accept provenance build arguments.

- [ ] **Step 3: Implement the online image build path**

Create `release/build-image.sh` with exactly one required version positional
argument. Run preflight, obtain `HEAD` and a UTC RFC-3339 timestamp, then call
`deployment/build.sh` with `RELEASE_VERSION`, `RELEASE_SOURCE_COMMIT`, and
`RELEASE_CREATED_AT`. Extend `deployment/build.sh` to validate and pass those
values as build arguments. Extend `deployment/Dockerfile` to declare the
arguments and add the four specified OCI labels. After build, use the engine’s
image inspection output to print the local image ID and labels.

- [ ] **Step 4: Run the focused test to verify it passes**

Run: `bash tests/test_offline_bundle.sh`

Expected: PASS for the new online-build assertions.

- [ ] **Step 5: Commit**

```bash
git add release/build-image.sh deployment/Dockerfile deployment/build.sh tests/test_offline_bundle.sh
git commit -m "feat: label online release images"
```

### Task 2: Export only a provenance-validated existing image

**Files:**
- Modify: `release/build-offline.sh`
- Modify: `tests/test_offline_bundle.sh`

**Interfaces:**
- Consumes: `sdcli-autokit:<version>` with the Task 1 labels.
- Produces: an offline archive containing `VERSION`, `SOURCE_COMMIT`, and
  `IMAGE_ID`; missing/mismatched labels return nonzero before image export.

- [ ] **Step 1: Write failing bundle tests for validated image export**

Extend `tests/test_offline_bundle.sh` to emulate inspect output for a labelled
image, assert default export never records a `build` command, extract
`IMAGE_ID`, and assert missing/revision-mismatched label fixtures fail before
`save`.

- [ ] **Step 2: Run the focused test to verify it fails**

Run: `bash tests/test_offline_bundle.sh`

Expected: FAIL because `build-offline.sh` currently rebuilds and does not
inspect labels or create `IMAGE_ID`.

- [ ] **Step 3: Implement provenance inspection and archive metadata**

Remove the build invocation from `release/build-offline.sh`. Add an engine
inspection helper that obtains the local image ID and four OCI label values.
Require requested version/current Git revision/`linux/amd64`; report expected
and observed values on mismatch. Save only after validation and write
`IMAGE_ID` to the staged bundle.

- [ ] **Step 4: Run the focused test to verify it passes**

Run: `bash tests/test_offline_bundle.sh`

Expected: PASS; archive contains `IMAGE_ID` and invalid provenance leaves no
archive or image export.

- [ ] **Step 5: Commit**

```bash
git add release/build-offline.sh tests/test_offline_bundle.sh
git commit -m "feat: require image provenance for offline bundles"
```

### Task 3: Add explicit release modes and operational documentation

**Files:**
- Modify: `release/release.sh`
- Modify: `docs/release-process.md`
- Modify: `README.md`
- Modify: `tests/test_offline_bundle.sh`

**Interfaces:**
- Consumes: `release/release.sh <version> [--verify] [--rebuild]`.
- Produces: default package-only release; optional test verification and/or
  online rebuild, then the Task 2 validated bundle.

- [ ] **Step 1: Write failing command-mode tests**

Extend `tests/test_offline_bundle.sh` to assert default `release.sh` calls
only inspect/save, `--rebuild` calls the new image-build path before
inspect/save, and unknown/duplicate flags fail without build/save/archive.

- [ ] **Step 2: Run the focused test to verify it fails**

Run: `bash tests/test_offline_bundle.sh`

Expected: FAIL because `release.sh` currently accepts only a version and runs
the full suite plus build unconditionally.

- [ ] **Step 3: Implement option handling and update operational guidance**

Parse `--verify` and `--rebuild` in either order without duplicates. Run the
existing tracked test suite only for `--verify`; invoke `build-image.sh` only
for `--rebuild`; always call `build-offline.sh` last. Update release-process
and README to state the online/offline boundary, all four commands, the 1.1.0
strict candidate command, the provenance evidence reported after packaging,
and that tags/uploads require separate approval.

- [ ] **Step 4: Run focused and full verification**

Run:

```bash
bash tests/test_offline_bundle.sh
bash -n sdcli-scripts/migrate.sh sdcli-scripts/lib/*.sh deployment/*.sh release/*.sh
while IFS= read -r test_file; do bash -n "$test_file" && bash "$test_file"; done < <(git ls-files 'tests/*.sh')
python3 -m unittest discover -s tests -p 'test_validation_report.py' -v
git diff --check
```

Expected: all tracked shell tests, all Python validation-report tests, syntax
checks, and whitespace checks pass.

- [ ] **Step 5: Commit**

```bash
git add release/release.sh docs/release-process.md README.md tests/test_offline_bundle.sh
git commit -m "feat: separate release verification and rebuild modes"
```

### Task 4: Perform final release-flow review and PR handoff

**Files:**
- Modify: `docs/release-process.md` only if final review finds a documented
  command inconsistent with the implemented interface.

**Interfaces:**
- Consumes: the completed feature branch and the new strict candidate command.
- Produces: a clean branch ready for remote PR; no release tarball, tag, or
  upload is created in this task.

- [ ] **Step 1: Inspect the implemented command help and provenance failure messages**

Run `release/release.sh` and `release/build-image.sh` with invalid arguments,
then use the fake engine fixture to confirm no side-effect command occurs.

- [ ] **Step 2: Re-run the full tracked suite and inspect the diff**

Run the Task 3 verification commands and `git diff origin/main...HEAD`.

Expected: the diff contains only release scripts, Docker build metadata, the
one release test fixture, operational documents, spec, and plan.

- [ ] **Step 3: Push branch and create remote PR**

Push `feature/release-provenance`, open a PR to `main`, and report the PR URL.
Do not merge until the release owner approves the PR.
