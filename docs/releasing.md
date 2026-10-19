# Releasing Verbemo

Both platforms come from one clean full-history checkout and exact source SHA,
root `VERSION`, build number (`git rev-list --count`), GitHub release named
`Verbemo <VERSION>` and tag `verbemo-v<VERSION>` in `ekho/verbemo`.
The source version is currently `0.1.0`; this does not mean an own public release
exists. No site, domain, SSH server or analytics backend is needed.

## Local development and signed prerequisites

`make app SIGN_ID=-` builds an ad-hoc macOS app without release credentials.
Apple Developer Program enrollment is deferred. Continue local runtime testing;
Developer ID signing/notarization awaits the user's own credentials.
Ad-hoc builds cannot satisfy the signed release gate.

On Windows, `windows/scripts/Build-Release.ps1 -Development` accepts the required
version, full current SHA and new output directory described in
[Windows build instructions](../windows/README.md). It produces an unsigned,
`publishable: false` receipt and is for local tests only.

Signed macOS builds require these own values, never the imported author's keys:

- `VERBEMO_SIGN_ID`: an available `Developer ID Application: ...` identity.
- `VERBEMO_SPARKLE_PUBLIC_KEY` and `VERBEMO_SPARKLE_PRIVATE_KEY_FILE`: matching
  Ed25519 key material; the private file is a readable base64 seed/key.
- `VERBEMO_NOTARY_KEY_FILE`, `VERBEMO_NOTARY_KEY_ID`,
  `VERBEMO_NOTARY_ISSUER_ID`: own App Store Connect notarization credentials.

The common workflow imports temporary credentials from own GitHub secrets
`VERBEMO_MACOS_CERTIFICATE_BASE64`, `VERBEMO_MACOS_CERTIFICATE_PASSWORD`,
`VERBEMO_NOTARY_KEY_BASE64`, `VERBEMO_SPARKLE_PRIVATE_KEY_BASE64` and own vars
`VERBEMO_SIGN_ID`, `VERBEMO_SPARKLE_PUBLIC_KEY`, `VERBEMO_NOTARY_KEY_ID`,
`VERBEMO_NOTARY_ISSUER_ID`. Windows signing uses
`VERBEMO_WINDOWS_CERTIFICATE_BASE64` and `VERBEMO_WINDOWS_CERTIFICATE_PASSWORD`.
The PFX must contain the own private key and code-signing certificate; the
Windows signing step verifies Authenticode and timestamp metadata.
Missing or invalid credentials fail signed preflight explicitly. Keep secrets
out of Git, command-line arguments and diagnostic logs. Back up release keys
securely; changing Sparkle trust keys requires a separately planned migration.

## Prepare and dry-run

The only common workflow is [.github/workflows/release.yml](../.github/workflows/release.yml).
Its `ref`, `version`, `operation` inputs resolve a source ref once and check out
the exact SHA on both platforms. `prepare` is the default: it builds/tests both
signed platform sets, combines them without collisions, validates them and
retains `release-artifacts`. It does not create a public release.
`publish` performs the same preparation before publication. `resume` verifies
an already published release and only finishes latest promotion; it does not build.

From a clean committed source checkout, inspect the resolved identity:

```sh
version=$(cat VERSION)
source_commit=$(git rev-parse HEAD)
build_number=$(git rev-list --count HEAD)
python3 scripts/release.py preflight --ref "$source_commit" --version "$version"
gh workflow run release.yml --repo ekho/verbemo --ref "$source_commit" \
  -f ref="$source_commit" -f version="$version" -f operation=prepare
```

Running the signed workflow needs the credentials above. Download its actual
`release-artifacts` into a new directory and set `VERBEMO_RELEASE_ARTIFACTS` to
that directory. Offline validation does not publish or require GitHub access:

```sh
: "${VERBEMO_RELEASE_ARTIFACTS:?set to the complete downloaded release-artifacts directory}"
python3 scripts/release.py prepare --artifacts "$VERBEMO_RELEASE_ARTIFACTS" \
  --version "$version" --source-commit "$source_commit" --build-number "$build_number" --dry-run
python3 scripts/release.py prepare --artifacts "$VERBEMO_RELEASE_ARTIFACTS" \
  --version "$version" --source-commit "$source_commit" --build-number "$build_number"
```

`--dry-run` validates both receipts and prospective metadata without writing
`release-manifest.json` or `SHA256SUMS`. Ordinary `prepare` writes/checks these
files and refuses conflicting existing metadata. Neither mode signs, notarizes,
builds or publishes. `make release` / `make release-dry` are retired guidance
entry points, intentionally exiting with status 2; use the explicit common CLI.

The exact common set is:

- `Verbemo-<VERSION>-macos-universal.dmg`, `appcast.xml`, `macos-build.json`.
- `Verbemo-<VERSION>-windows-x64-Setup.exe`,
  `Verbemo-<VERSION>-windows-x64-Portable.zip`,
  `Verbemo-<VERSION>-stable-full.nupkg`, `assets.stable.json`,
  `releases.stable.json`, `windows-build.json`.
- `release-manifest.json` and one `SHA256SUMS` covering all other files.

Both receipts must match source/version/build and every byte hash/size. Extra
files, missing platforms, unsigned Development receipts, feed/package mismatch
or incomplete signature validation block publication. Put generated package
catalog metadata outside this closed artifact directory.

## Publish and verify

Publication is an explicit consequential action. Use the prepared directory
only after release approval, with `GH_TOKEN` supplied securely:

```sh
python3 scripts/release.py publish --artifacts "$VERBEMO_RELEASE_ARTIFACTS"
```

The publisher checks repository identity, stable version/build floor and exact
tag commit, creates or resumes a matching draft, uploads missing assets without
clobbering and verifies bytes. It publishes with latest disabled, verifies the
public asset URLs and downloads, then promotes latest after a fresh floor check.
No platform-specific tag/release or separate update repository is used.

The workflow serializes publishers in concurrency group `verbemo-release`.
GitHub REST has no atomic conditional latest mutation: manual/external
publishers must coordinate with that same release process. Fresh checks reduce
race windows but do not provide a cross-client atomic lock. Do not run an
external publisher concurrently or claim that latest is race-proof.

Updates use:

- macOS: `https://github.com/ekho/verbemo/releases/latest/download/appcast.xml`.
- Windows: `https://github.com/ekho/verbemo/releases/latest/download/`, channel `stable`.

Every feed package is in that same release. Windows checks/downloads while idle;
the pending update installs at the next normal **primary** startup, before
recording/processing begins. Secondary launches cannot autoapply. There is no
Restart now action and an interactive check never applies, exits or restarts.
Finish work, quit normally and relaunch. Portable packages do not self-update.

After actual verified publication, prepare README/site links locally:

```sh
python3 scripts/update-readme-downloads.py --write --public
python3 scripts/update-site-download-links.py landing --public
```

These read-only network checks validate the latest own release's exact source
tag, complete common manifest, both receipts, signatures metadata, all files,
checksums and public bytes. No trusted latest release means Releases-page links;
malformed existing release evidence fails rather than advertising an installer.
`--artifacts` uses a locally verified complete set for preparation, but does not
establish public availability. Review/commit the resulting local files through
the normal source workflow. No site deployment is performed.

The **Published README downloads** workflow checks trusted `master` code against
that same public evidence and has read-only permissions. `GITHUB_TOKEN` release
events do not start downstream release-triggered workflows; after publication
and the reviewed README change, dispatch `readme-downloads.yml` explicitly if no
push-triggered check ran. It never writes a bot commit or bypasses protection.

## Failure recovery

Keep exact validated artifacts, receipts and logs. Before publication, rerun
`publish` with that same directory: it reads existing draft bytes, uploads only
missing matching assets and refuses conflicting bytes or identity. An ambiguous
network error stops the invocation; inspect remote state before another attempt.

After publication, do not rebuild, overwrite assets or move the tag. Resume
verification/promotion only:

```sh
python3 scripts/release.py resume --tag "verbemo-v$version"
```

`resume` requires exactly one published release, downloads its public complete
set, verifies receipts/checksums/source tag and checks the stable floor before
promoting latest. A newer version/build blocks rollback. If public bytes or
identity conflict, stop and investigate; ship a new version rather than repair
an immutable published package. A README/site failure is fixed by the local
link helpers and a reviewed documentation commit, not by replacing release bytes.

## Acceptance limits and package catalogs

Source tests, receipt validation and CI packaging do not establish installed
GUI/audio/model quality, physical Intel support, Windows installer/uninstaller
behavior or a two-version update. Run actual platform acceptance against the
exact final build, recording source SHA, artifact hashes and results. macOS
local ad-hoc verification is separate from signed/notarized release acceptance.
Final site screenshots must be captured after Task9 from that exact verified
Verbemo build; old branded Windows shots stay inactive until real replacements.

[Package metadata preparation](../windows/packaging/README.md) requires actual
complete artifacts and verified signature metadata. Historical Amanu manifests
retain their own publisher and hashes under `docs/history/amanu-packaging/`.
No catalog publication, catalog PR or package install command is performed or
claimed by this runbook. WinGet identity/publisher metadata and actual catalog
acceptance remain separate gates.
