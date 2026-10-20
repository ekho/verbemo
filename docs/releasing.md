# Releasing Verbemo

Both platforms come from one clean full-history checkout and exact source SHA,
root `VERSION`, build number (`git rev-list --count`), GitHub release named
`Verbemo <VERSION>` and tag `verbemo-v<VERSION>` in `ekho/verbemo`.
Read the source version from `VERSION`; a committed version does not establish
a public release. No site, domain, SSH server or analytics backend is needed.

## Local development and signed prerequisites

`make app SIGN_ID=-` builds an ad-hoc macOS app without release credentials.
Apple Developer Program enrollment is deferred. Continue local runtime testing;
Developer ID signing/notarization awaits the user's own credentials.
Ad-hoc builds cannot satisfy the signed release gate.

On Windows, `windows/scripts/Build-Release.ps1 -Development` accepts the required
version, full current SHA and new output directory described in
[Windows build instructions](../windows/README.md). It produces an unsigned,
`publishable: false` receipt, accepted only for local tests and explicit unsigned
previews. Signed stable publication still rejects that receipt.

`distribution=preview` is the default workflow mode. macOS uses ad-hoc signing,
without notarization or a Sparkle key; Windows uses `-Development`. The publisher
marks the common GitHub release as a prerelease, attaches an unsigned-build
notice, verifies all public files and never promotes it to `latest`. These
packages require manual installation; Gatekeeper/SmartScreen can warn or block
them. Ad-hoc macOS identity can also change between builds, prompting for
permissions again. Existing stable updates, README/site direct download links
and catalog metadata remain restricted to signed stable release evidence.

`distribution=signed` retains Developer ID/notarization/Sparkle and Windows
Authenticode requirements. No missing credential silently changes that mode.

To package a local macOS preview from a clean committed checkout:

```sh
bash scripts/build-macos-preview.sh --version "$(cat VERSION)" \
  --source-commit "$(git rev-parse HEAD)" --output /tmp/verbemo-preview-artifacts
```

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
It runs automatically after a push/merge to `master`. The accepted automatic
release policy supersedes the original manual-only policy in the October 19
design. The user-approved October 20 preview policy now makes merging a
releasable change authorize an unsigned public **prerelease** by default.

The automatic path is:

1. Read the full history and published **own** releases (`verbemo-v*`), including
   previews: a published preview reserves its version and exact source tag.
2. Analyze commits since the last own release with the Conventional Commits
   preset: `fix`/`perf` -> PATCH, `feat` -> MINOR, `!`/`BREAKING CHANGE` -> MAJOR.
   Choose the largest change. Other types alone produce no release. Breaking
   changes also bump MAJOR before 1.0; they are not silently downgraded to MINOR.
3. Commit `VERSION`, `CHANGELOG.md` and `docs/release-notes-verbemo-v<VERSION>.md`
   as `chore(release): <VERSION>` with the exact parent in `Release-Source` and
   the selected `Release-Channel` (`preview` or `signed`).
   Push normally to `master`; a concurrent merge rejects the push without
   overwriting anyone's work. The newer merge's run (or a manual `auto` run)
   recalculates from the current branch.
4. Test/build both platforms at that exact version commit, then aggregate
   and validate their complete artifact set.
5. Use the existing publisher to create the tag/draft after successful builds,
   attach the generated release notes and all files, verify and publish. Only a
   signed stable release can promote `latest`. A failed platform prevents publication.

Before the first own release, use the most recent `VERSION` adoption commit as
the history boundary and the current root version as the version floor. This
excludes inherited Amanu history and tags. For example, a feature since the own
`0.1.0` adoption produces `0.2.0`, not a version derived from legacy `v*` or
`windows-v*` tags. A manually changed version after an own release requires
explicit reconciliation instead of guessing the intended number.

Version preparation and publication share the `verbemo-release` concurrency
group. When changes arrive during a build, successful publication explicitly
dispatches another `auto` run to process the newer `master`. GitHub may replace
an older pending run with a newer one; the next run reads current `master` and
includes all changes since the last release. Only one release runs at a time.

The bot needs Actions write permissions enabled for `GITHUB_TOKEN`, with
`contents: write` for the version commit and publisher, and `actions: write`
only for the publisher's follow-up dispatch. Branch rules must permit the
version commit; the workflow never force-pushes or bypasses protection. All
signing requirements above remain mandatory for `distribution=signed`. Missing
credentials stop that build; only explicit previews accept unsigned/ad-hoc receipts.

The version commit uses `GITHUB_TOKEN`, whose push does not start another CI
run. The release workflow therefore tests the exact version commit itself,
including a complete Swift test report, script/workflow tests, landing checks
and the product-independence guard. PR CI also tests the version tooling.
It builds unsigned packages on both platforms and validates their combined
preview receipts, source identity and file hashes without publishing.
Use Conventional Commit messages in the final history: with squash merges,
make the PR title the intended final commit message.

The analyzer and notes generator are pinned semantic-release plugins; their
orchestrator is intentionally omitted because the existing publisher owns
release state. Install their lockfile with Node 24 and
`npm --prefix scripts/release-automation ci --legacy-peer-deps --ignore-scripts`.
The Conventional Commits preset is pinned to 9.3.1: preset 10 requires a newer
writer than release-notes-generator 14 currently uses. No package lifecycle
scripts run. Tests use isolated local Git repositories and never publish:

```sh
npm --prefix scripts/release-automation test
```

Manual workflow `ref`, `version`, `operation`, `distribution` inputs resolve a source ref once and check out
the exact SHA on both platforms. `prepare` is the default: it builds/tests both
platform sets in the selected distribution mode, combines them without collisions, validates them and
retains `release-artifacts`. It does not create a public release.
`publish` performs the same preparation before publication. `resume` verifies
an already published release; it only finishes latest promotion for signed
stable releases and never promotes previews. It does not build.
`auto` ignores the version input and reads current `master`, using the same
version/release policy as an ordinary merge. Manual `prepare`, `publish` and
`resume` still require an explicit version.

```sh
gh workflow run release.yml --repo ekho/verbemo --ref master -f operation=auto
```

The same dispatch can explicitly select `-f distribution=signed` when own
credentials are configured. A signed release uses a new version after any
published preview; it cannot replace or promote that preview in place.

From a clean committed source checkout, inspect the resolved identity:

```sh
version=$(cat VERSION)
source_commit=$(git rev-parse HEAD)
build_number=$(git rev-list --count HEAD)
python3 scripts/release.py preflight --ref "$source_commit" --version "$version"
gh workflow run release.yml --repo ekho/verbemo --ref master \
  -f ref="$source_commit" -f version="$version" -f operation=prepare -f distribution=preview
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

For preview artifacts, add `--prerelease` to each `prepare` command (including
`--dry-run`). The stable default rejects unsigned artifacts. The prepared
manifest records `prerelease: true`, which publication and resume validate.

`--dry-run` validates both receipts and prospective metadata without writing
`release-manifest.json` or `SHA256SUMS`. Ordinary `prepare` writes/checks these
files and refuses conflicting existing metadata. Neither mode signs, notarizes,
builds or publishes. `make release` / `make release-dry` are retired guidance
entry points, intentionally exiting with status 2; use the explicit common CLI.

The exact signed common set is:

- `Verbemo-<VERSION>-macos-universal.dmg`, `appcast.xml`, `macos-build.json`.
- `Verbemo-<VERSION>-windows-x64-Setup.exe`,
  `Verbemo-<VERSION>-windows-x64-Portable.zip`,
  `Verbemo-<VERSION>-stable-full.nupkg`, `assets.stable.json`,
  `releases.stable.json`, `windows-build.json`.
- `release-manifest.json` and one `SHA256SUMS` covering all other files.

The preview set has the same names except that it omits `appcast.xml`. Its
macOS receipt explicitly records ad-hoc signing and no notarization/Sparkle;
its Windows receipt records unsigned Development output. Windows packaging
keeps the `stable` channel file names, but those files are confined to the
prerelease and never become the stable update source through `latest`.

Both receipts must match source/version/build and every byte hash/size. Extra
files, missing platforms, feed/package mismatch or incomplete validation block
publication. Signed mode also rejects unsigned Development receipts. Put generated package
catalog metadata outside this closed artifact directory.

## Publish and verify

Automatic publication follows the merge policy above. For a manual publication,
use the prepared directory only after release approval, with `GH_TOKEN` supplied
securely:

```sh
python3 scripts/release.py publish --artifacts "$VERBEMO_RELEASE_ARTIFACTS"
```

The publisher checks repository identity, stable version/build floor and exact
tag commit, creates or resumes a matching draft, uploads missing assets without
clobbering and verifies bytes. It publishes with latest disabled, verifies the
public asset URLs and downloads, then promotes latest after a fresh floor check
only for a signed stable release. Preview publication never mutates latest.
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
Local preview artifacts are rejected by these helpers and by catalog preparation.

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

If an automatic build failed before draft creation, a new `auto` run reuses the
unpublished version commit and its source SHA, even if newer commits have since
arrived. It does not bump again. After that version is successfully published,
the follow-up run includes the queued changes. If a draft already exists, the
automatic planner stops rather than rebuilding potentially different signed
bytes: rerun the failed publication job with that run's retained artifacts, or
use the existing manual CLI with the exact downloaded set. After publication,
use `resume` as below. Retention remains seven days; do not delete or move tags
to retry a failed release.

A distribution-mode change is the exception before any tag/draft exists: the
planner creates a new candidate at current source with a `Release-Channel`
marker, regenerating notes from the last published release (or own VERSION
adoption). It keeps the pending number unless new changes require a higher
SemVer bump. This lets the initial unsigned mode replace the unbuilt signed
0.2.0 candidate with source that actually supports previews. Once a tag or
draft reserves that version, mode/source changes are refused.

After publication, do not rebuild, overwrite assets or move the tag. Resume
verification/promotion only:

```sh
python3 scripts/release.py resume --tag "verbemo-v$version"
```

`resume` requires exactly one published release, downloads its public complete
set and verifies receipts/checksums/source tag. Signed stable releases also
check the stable floor before promoting latest; previews never promote it.
A newer stable version/build blocks rollback. If public bytes or
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
