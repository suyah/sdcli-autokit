# Offline Container Distribution Design

## Purpose

This is a one-maintainer tool for running SQL Developer `sdcli` migrations, not a general release platform. The maintainer needs to build the container where internet access exists, then give a customer enough files to run it on a VM that cannot reach a registry or software repositories. The same files should work whether they arrive through Azure, AWS, GCP, OCI, an on-premises share, or removable media.

The image will not contain Oracle SQL Developer, Oracle Instant Client, Microsoft ODBC Driver 18, or Microsoft `mssql-tools18`. The customer downloads those RPMs from the [official sources in the README](../../../README.md#customer-provided-proprietary-artifacts-for-offline-installation) and keeps them in a separate local directory. This is a conservative distribution choice, not a claim that every version's license prohibits redistribution. A later decision to bundle any of them needs review of that version's terms.

## Workflow

1. On the maintainer's connected Linux/amd64 machine, run `release/build-offline.sh <version>`. It builds a runner image, saves it as `image.tar`, and packages the image, named deployment scripts, tracked migration scripts, README, and a plain `VERSION` file into `sdcli-autokit-<version>-linux-amd64.tar.gz`. It also writes a SHA-256 checksum file. It does not upload to a particular cloud provider or include arbitrary files from the build directory.
2. Transfer the bundle and checksum by any customer-approved method. On the customer VM, check the checksum, extract the bundle, and run `podman load -i image.tar`. No image build or registry pull happens there.
3. The customer places the six required RPM families (SQL Developer; Instant Client Basic, SQL*Plus, and Tools; `msodbcsql18`; `mssql-tools18`) and any needed RPM dependencies in one directory outside the extracted bundle. Run `deployment/run.sh --vendor-dir /absolute/path --accept-microsoft-eula`.
4. `run.sh` checks that the local image and RPM directory exist and that the six expected RPM filenames are present before creating or mounting a container. It then mounts the directory read-only. A small installer checks RPM headers, extracts SQL Developer using the existing method, and installs the other local RPMs with DNF repositories disabled. It checks the required command-line tools before reporting success. `start.sh` and `stop.sh` remain the normal daily controls.

The release build is responsible for its image. The customer is responsible for obtaining and verifying the vendor downloads under its own arrangements. The filename precheck and container-side RPM-header check confirm the six required package names and architecture; they are not a license checker or a cryptographic vendor-authenticity service. The README lists the versions actually tested together. An unsupported or missing dependency fails locally with a useful error instead of triggering a download.

## Small set of changes

- Remove the Microsoft and Oracle Instant Client install steps from `deployment/Dockerfile`. Keep the base runtime and `yq`. Fetch jTDS during the connected build rather than at customer startup, after checking its redistribution terms and retaining required notices. If that check fails, make the JAR another customer-provided file.
- Change `deployment/build.sh` to accept the versioned image tag and stop creating a customer volume. `release/build-offline.sh` only builds, exports, and packages explicitly named files; it does not handle cloud upload, SBOM generation, signing, or a release database. The maintainer checks the bundled `config.yaml` for customer-specific values before sharing it.
- Remove SQL Developer and jTDS downloads from `deployment/run.sh`. Mount vendor RPMs at `/vendor-rpms:ro` (with an SELinux label option only where needed). Put package checking and installation in `deployment/install-vendor.sh`; it reuses the current SQL Developer extraction and uses `dnf --disablerepo='*'` for Instant Client, Microsoft RPMs, and staged dependencies. Do not configure a vendor repository in the runner. Require the customer operator to pass the Microsoft EULA acknowledgement flag.
- Replace the current single volume over `/u01`. It hides image files under `/u01/app`. Persist only `/u01/data` and `/u01/log` as separate volumes; the installed vendor tools live in the container's writable layer. Keep migration scripts/config in the extracted bundle and copy them into the container as the current script does.
- Use the bundle's `VERSION` to select the saved image tag. Keep `.env` for the existing container/user/path settings, without software download URLs.

No package lock format, manifest parser, installation fingerprint, automatic rollback, cloud CLI integration, or release approval pipeline is needed. A release is a tarball and checksum; upgrading is an operator action.

## Failure and upgrade behavior

The script never silently replaces an existing container or deletes data. If the configured container name points to another image version, it stops and tells the operator to back up configuration, remove that container, and rerun with the intended bundle. The data and log volumes remain. Removing a container removes its locally installed vendor tools, so a replacement requires the RPM directory again.

If local RPM installation fails, the container may be left stopped and incomplete. The script reports the DNF error and does not run migrations. The operator can fix the RPM directory and retry, or remove the container and retry. Missing tools fail the final health check.

## Verification before handing over a release

- On the connected machine, build and inspect the image to confirm the four customer-supplied package families are absent. Check jTDS and other bundled software notices before distributing the image.
- Test the bundle checksum, extraction, and `podman load` on a clean Linux/amd64 VM without registry or repository access. With the customer-supplied RPMs, check `sdcli`, `sqlcmd`, `bcp`, `sqlplus`, `sqlldr`, and the migration scripts.
- Test stop/start and confirm data and logs persist. Record the exact vendor RPM versions used for this smoke test in the README. If the isolated-VM test has not happened, label the release unverified rather than implying that it works offline.
