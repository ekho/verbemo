# Verbemo agent instructions

## Repository ownership and upstream exchange

- `ekho/verbemo` is the independent product repository. Use it for development, issues and pull requests.
- In the Verbemo checkout, `origin` points to `git@github.com:ekho/verbemo.git`, `upstream` to `git@github.com:gsamat/amanu.git`, and `amanu` to `git@github.com:ekho/amanu.git`.
- Keep `ekho/amanu` as the upstream-facing fork. Prepare focused upstream contributions there from `upstream/master`.
- Verbemo's initial `master` includes the local speaker diarization work from `codex/local-speaker-diarization`. `codex/amanu-baseline` preserves the original fork's `master`.
- Existing application identifiers, signing, update feeds and release destinations still belong to the imported Amanu baseline. Prepare Verbemo's own release route before publishing; do not use the inherited upstream publication destinations for Verbemo.
- Preserve the original copyright notices and license files.

The release guidance below describes the imported Amanu baseline and must be
adapted explicitly when preparing Verbemo releases.

## Windows release source

- The current Windows app and release scripts live on `origin/codex/ready-0.6.3`, including the versioned installer implementation merged in PR #29. The branch name reflects its origin, not the version of the next release.
- Before preparing a Windows release, fetch that branch and use a clean checkout based on its latest commit. Until the Windows source is integrated into `master`, do not use the old Windows workflow on `master` or stale untracked `windows/` files in a local macOS checkout.
- Dispatch `windows-beta.yml` with an explicit `--ref` pointing to the prepared Windows release branch. Set its root `VERSION` to the agreed shared release version and commit the release changes before building; local packaging rejects a version that differs from `VERSION`.
- Follow `docs/releasing.md` for the release route and post-publication download-link checks.

## Release installer filenames

- Future Windows releases must publish the installer with its version in the filename: `Amanu-<version>-Setup.exe` (for example, `Amanu-0.6.4-Setup.exe`), using the root `VERSION` file.
- Apply this name in Windows packaging and publication, website download links and `/win.exe`, checksums, and package manifests. The Velopack channel can remain `stable`; `stable` alone is not a sufficient installer filename.
- Preserve already published release assets; apply this naming convention when preparing the next Windows release.

## Windows testing

- The user has connected a Windows computer to Codex for Amanu development and testing. Treat it as an available testing environment, but confirm that the host is online and the project is accessible before relying on it.
- For changes to the Windows app, run the relevant build and tests on Windows. When behavior depends on the Windows graphical interface, launch the app there and verify the actual flow with Computer Use when available.
- Mac-only checks or CI results do not establish that the Windows app works. Report which checks ran on the Windows host and any checks that could not run.
- If the current chat runs on another host, use the connected Windows host or arrange a handoff of the chat to it before Windows-specific validation. If the host is unavailable, state the blocker instead of claiming Windows verification.
