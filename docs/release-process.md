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

## Scripted release steps

Run the recommended command from a clean, up-to-date local `main` checkout on
the connected Linux/amd64 build host:

```bash
./release/release.sh 1.1.0
```

`release.sh` runs preflight, the full tracked test suite, and then
`build-offline.sh`. `build-offline.sh` runs the same lightweight preflight
itself, so invoking it directly cannot bypass the release metadata and
clean-worktree checks. `RELEASE_SKIP_TESTS=true` exists only for automated
tests and must not be used for a real release.

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
bundle contains `VERSION` and `SOURCE_COMMIT`; `SOURCE_COMMIT` is the exact
Git SHA used for the build. It does not contain the engineering changelog.

After verifying the checksum and artifact tree, create the release tag only
with the release owner's approval:

```bash
git tag -a v1.1.0 -m "Release 1.1.0"
git push origin v1.1.0
```

Report the absolute `dist/` directory, tarball path, checksum path, source
commit, and printed tree to the release owner. Uploading or distributing the
artifact requires separate approval and a specified destination.
