# Release process

This is an engineering-only process. `docs/CHANGELOG.md` is deliberately not
included in the customer offline bundle.

## Version policy

Use `MAJOR.MINOR.PATCH`:

- `PATCH`: backward-compatible corrections only.
- `MINOR`: backward-compatible migration capability or workflow additions.
- `MAJOR`: a breaking configuration, runtime, or supported-pair change.

The next release after `1.0.0` is `1.1.0`, because it adds validation,
reliability, and persistent-state capabilities without breaking the existing
offline installation interface.

## Information the release owner confirms

Before a release, the engineer or release owner confirms:

1. The proposed version.
2. The concise `Added`, `Changed`, `Fixed`, and `Compatibility` notes in
   `docs/CHANGELOG.md`.
3. The intended `main` source commit.
4. After the bundle is verified, approval to create and push the annotated Git
   tag `v<version>`.
5. The distribution destination, if the artifact is to be uploaded or shared.

## Online build and offline delivery

The publisher and the customer use different modes:

- **Publisher online build:** a connected Linux/amd64 build host creates the
  image. The current Dockerfile downloads its base packages, `yq`, and jTDS
  from the internet.
- **Customer offline install/run:** the customer downloads the finished
  bundle, runs `podman load`, and supplies its own approved vendor RPMs,
  wallet, configuration, and migration data. No registry or internet access is
  needed for this step.

`podman save` exports image layers only. It does not export a running
container, `/u01/data` volume, customer configuration, wallets, logs, or test
data. The bundle also uses an explicit runtime-file allow-list.

## Scripted release steps

Run release commands from a clean, up-to-date local `main` checkout on the
connected Linux/amd64 publisher host. The commands have deliberately separate
responsibilities:

| Command | Behaviour |
| --- | --- |
| `./release/build-image.sh 1.1.0` | Online build of a clean, labelled local image. |
| `./release/release.sh 1.1.0` | Package an existing validated local image; no build and no test suite. |
| `./release/release.sh 1.1.0 --verify` | Run the full tracked test suite, then package the existing validated image. |
| `./release/release.sh 1.1.0 --rebuild` | Online rebuild, provenance inspection, then package. |
| `./release/release.sh 1.1.0 --verify --rebuild` | Full release-candidate workflow: test, online build, provenance inspection, and offline bundle. |

For a real 1.1.0 release candidate, use:

```bash
./release/release.sh 1.1.0 --verify --rebuild
```

The default package-only command requires local image
`sdcli-autokit:<version>` with these matching OCI labels:

- `org.opencontainers.image.version=<version>`
- `org.opencontainers.image.revision=<current Git SHA>`
- `org.opencontainers.image.created=<UTC build time>`
- `org.opencontainers.image.platform=linux/amd64`

If the image is absent, labels are missing, the actual OS/CPU is not
Linux/amd64, or version/commit/platform does not match, the package command
stops before image export and tells the maintainer to rebuild. It also checks
the tag's image ID again immediately after export and rejects the bundle if
the tag changed during the operation. This prevents a routine package command
from silently using an arbitrary locally tagged image while preserving the
customer-required `sdcli-autokit:<version>` tag inside the archive.

`build-offline.sh` is retained for compatibility and means “build an offline
delivery bundle,” not “build an image without internet.” It also requires the
same validated existing image. `RELEASE_SKIP_TESTS=true` exists only for the
automated test fixture and must not be used for a real release.

Preflight checks the version format, a clean tracked Git worktree, an exact
changelog entry, and absence of the target tarball and checksum. It does not
modify source files, create a tag, build an image, or upload anything.

The build creates:

```text
dist/
├── sdcli-autokit-1.1.0-linux-amd64.tar.gz
└── sdcli-autokit-1.1.0-linux-amd64.tar.gz.sha256
```

The build prints the absolute artifact paths and the bundle file tree. The
bundle contains `VERSION`, `SOURCE_COMMIT`, and `IMAGE_ID`. `SOURCE_COMMIT` is
the exact Git SHA bound to the image; `IMAGE_ID` identifies the immutable local
image that was exported. The bundle does not contain the engineering changelog.

After verifying the checksum and artifact tree, create the release tag only
with the release owner's approval:

```bash
git tag -a v1.1.0 -m "Release 1.1.0"
git push origin v1.1.0
```

Report the absolute `dist/` directory, tarball path, checksum path, source
commit, image ID, image labels, and printed tree to the release owner.
Uploading or distributing the artifact requires separate approval and a
specified destination.
