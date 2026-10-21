# Release Build and Offline Bundle Provenance Design

## Purpose

Make the release workflow safe to repeat by separating an internet-connected
publisher build from an offline customer installation. A routine package
command must not rebuild the image or run the full test suite, but it must
refuse to package an image whose version and source provenance are unknown.

This is a one-maintainer migration tool. The design deliberately avoids a
registry, CI service, signing infrastructure, or a new deployment platform.

## Scope and constraints

- The supported image is Linux/amd64 and Oracle SQL Developer 26.2.
- The publisher build host has internet access. It currently needs Oracle
  Linux package repositories, GitHub (for `yq`), and Maven Central (for jTDS).
- The customer has no internet or container-registry access. The customer
  downloads a tarball, runs `podman load`, and supplies its own restricted
  vendor RPMs, wallets, and configuration at runtime.
- The release bundle must never contain the engineering changelog, customer
  wallet, customer configuration, runtime data, logs, or mounted volumes.
- Existing `release/build-offline.sh` callers remain supported. Its name means
  “build an offline delivery bundle,” not “build an image without internet.”

## Terminology

| Term | Meaning |
| --- | --- |
| online image build | Publisher runs Docker/Podman build with internet access. |
| offline bundle | Customer-downloadable archive containing `image.tar` and runtime scripts. |
| offline install/run | Customer loads the archive and runs it without registry or internet access. |
| provenance | Image metadata that binds a release tag to a source Git commit and platform. |

## Components and responsibilities

### `release/build-image.sh <version>`

This new script is the only normal path for creating a release image. It:

1. Runs release preflight.
2. Invokes the existing `deployment/build.sh` using the chosen local engine.
3. Builds `sdcli-autokit:<version>` for Linux/amd64 in online mode.
4. Stamps the image with OCI labels for product version, source Git commit,
   target platform, and build timestamp.
5. Inspects and prints the immutable local image ID plus the labels.

The build receives the labels through Docker build arguments. The Dockerfile
does not copy the working tree, customer files, or volumes into the image.

### `release/build-offline.sh <version>`

This remains the bundle builder. It does not build an image. It:

1. Runs release preflight.
2. Inspects the existing local `sdcli-autokit:<version>` image.
3. Requires all release provenance labels to match the current Git commit,
   requested version, and `linux/amd64` platform.
4. Saves the validated image as `image.tar` and copies only the explicitly
   listed customer runtime files.
5. Includes `VERSION`, `SOURCE_COMMIT`, and `IMAGE_ID` in the archive,
   writes a SHA-256 checksum, and prints the staged bundle tree.

If an image does not exist, labels are absent, or a label does not match, this
script fails with an instruction to run `build-image.sh` or
`release.sh --rebuild`. It does not silently rebuild or package an arbitrary
locally tagged image.

### `release/release.sh <version> [--verify] [--rebuild]`

This is the maintainer entry point.

| Invocation | Behaviour |
| --- | --- |
| `release.sh 1.1.0` | Preflight and package an already validated local image. No tests, no image build. |
| `release.sh 1.1.0 --verify` | Run the complete tracked test suite, then package the existing validated image. |
| `release.sh 1.1.0 --rebuild` | Run an online clean image build, then package it. |
| `release.sh 1.1.0 --verify --rebuild` | Full release-candidate workflow: tests, online image build, provenance inspection, and offline bundle. |

Unknown or duplicate options fail before any build or archive is created.

`--verify` verifies the repository’s tracked automated suite. It does not
claim to perform a real customer-database migration. The release owner uses
the normal migration test procedure when a database-level acceptance test is
required.

## Data flow and isolation

```text
clean Git main ──> online build-image ──> labelled local image
                                      └──> image ID
labelled local image + explicitly listed runtime files
  └──> build-offline ──> image.tar + SOURCE_COMMIT + IMAGE_ID + checksum
                         └──> customer download / podman load / offline run
customer config, wallet, vendor RPMs, project data, logs
  └──> mounted or persisted under /u01/data at customer runtime only
```

`podman save` / `docker image save` exports image layers only. It does not
export a running container’s writable layer or named/bind-mounted volumes.
The release scripts also use an explicit runtime-file allow-list rather than
copying the repository wholesale. A manually committed or locally retagged
image remains possible in theory; required matching labels and a recorded
image ID make such a mistake detectable and prevent accidental reuse through
the normal workflow.

## Failure behaviour

- No Podman/Docker, unavailable daemon, no internet during online build, or
  build failure: stop before a bundle is written.
- Dirty tracked source, malformed version, absent changelog entry, or output
  collision: preflight failure.
- Missing/mismatched provenance: refuse package and state the exact expected
  and observed values.
- Existing tarball/checksum: refuse to overwrite it.
- A successful package prints the absolute tarball path, checksum path,
  source commit, image ID, image labels, and bundle tree.

## Documentation and release procedure

`docs/release-process.md` becomes the operational source of truth. It will
state the online/offline boundary, explain normal and strict commands, require
a clean up-to-date `main`, and list the final artifact evidence to report.

For the 1.1.0 release candidate, the documented command is:

```bash
./release/release.sh 1.1.0 --verify --rebuild
```

It creates local artifacts only. Creating/pushing `v1.1.0`, uploading an
archive, or sharing it with a customer remains a separate release-owner
decision.

## Verification

Automated tests use the existing fake container engine and cover only these
new decisions:

1. Default release packages a labelled existing image without calling build.
2. `--rebuild` invokes the online build and produces a labelled image before
   packaging.
3. Missing or mismatched provenance rejects packaging without rebuilding.
4. The bundle includes `IMAGE_ID` alongside existing release metadata.
5. Invalid command options fail without side effects.

The existing full tracked shell and Python test suites remain the release
verification command. A build requires a real Linux/amd64-capable container
engine and internet, so it is not performed by the fake-engine unit tests.

## Non-goals

- Offline image builds from a pre-staged base image and RPM repository.
- Registry publication, image signing, SBOM generation, or CI automation.
- Bundling Oracle, Microsoft, or other customer-licensed vendor packages.
- Automatically creating Git tags or uploading artifacts.
