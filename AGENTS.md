# Verbemo agent instructions

## Repository ownership and upstream exchange

- `ekho/verbemo` is the independent product repository. Use it for development, issues and pull requests.
- In the Verbemo checkout, `origin` points to `git@github.com:ekho/verbemo.git`, `upstream` to `git@github.com:gsamat/amanu.git`, and `amanu` to `git@github.com:ekho/amanu.git`.
- Keep `ekho/amanu` as the upstream-facing fork. Prepare focused upstream contributions there from `upstream/master`.
- Verbemo's initial `master` includes the local speaker diarization work from `codex/local-speaker-diarization`. `codex/amanu-baseline` preserves the original fork's `master`.
- Verbemo uses its own application identity and common release route. Publish only to `ekho/verbemo` using `docs/releasing.md`; imported historical destinations are not release targets.
- Preserve the original copyright notices and license files.

## Shared platform source and release route

- Windows sources are integrated into the same source base as macOS. The pinned
  source commit and exact import scope are recorded in `docs/windows-source-import.md`.
  Develop both platforms from the prepared Verbemo branch; a separate historical
  Windows release branch is no longer required.
- The independent release route is implemented according to
  `docs/superpowers/specs/2026-10-19-verbemo-independent-releases-design.md` and
  `docs/superpowers/plans/2026-10-19-verbemo-independent-releases.md`.
  Both platforms must use one source commit, the root `VERSION`, one
  `Verbemo <VERSION>` release and one `verbemo-v<VERSION>` tag in `ekho/verbemo`.
- Windows installers must use `Verbemo-<VERSION>-windows-x64-Setup.exe`; portable
  archives use `Verbemo-<VERSION>-windows-x64-Portable.zip`. The Velopack channel
  can remain `stable`. Preserve already published assets and tags.
- Follow `docs/releasing.md` for the common release CLI and its validation
  limits. No own public release is established by source changes or local builds.
  Historical manifests under `docs/history/` are provenance, not active routes.
- Merges to `master` automatically prepare a version from Conventional Commits,
  build/test both platforms at the version commit, and publish the complete
  signed release. Keep the manual prepare/publish/resume recovery route.
- Apple Developer Program membership is deferred. Continue local macOS ad-hoc
  builds and testing; retain signed-release preparation. Actual Developer ID
  signing and notarization await the user's own credentials.

## Windows testing

- The user has connected a Windows computer to Codex for Amanu development and testing. Treat it as an available testing environment, but confirm that the host is online and the project is accessible before relying on it.
- For changes to the Windows app, run the relevant build and tests on Windows. When behavior depends on the Windows graphical interface, launch the app there and verify the actual flow with Computer Use when available.
- Mac-only checks or CI results do not establish that the Windows app works. Report which checks ran on the Windows host and any checks that could not run.
- If the current chat runs on another host, use the connected Windows host or arrange a handoff of the chat to it before Windows-specific validation. If the host is unavailable, state the blocker instead of claiming Windows verification.
