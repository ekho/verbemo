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
  unsigned preview as a GitHub prerelease. Previews must never become `latest`
  or feed stable automatic updates. Keep explicit signed stable publication and
  the manual prepare/publish/resume recovery route.
- Apple Developer Program membership is deferred. Continue local macOS ad-hoc
  builds and testing; retain signed-release preparation. Actual Developer ID
  signing and notarization await the user's own credentials.

## Windows testing

- The user has connected a Windows computer to Codex for Amanu development and testing. Treat it as an available testing environment, but confirm that the host is online and the project is accessible before relying on it.
- For changes to the Windows app, run the relevant build and tests on Windows. When behavior depends on the Windows graphical interface, launch the app there and verify the actual flow with Computer Use when available.
- Mac-only checks or CI results do not establish that the Windows app works. Report which checks ran on the Windows host and any checks that could not run.
- If the current chat runs on another host, use the connected Windows host or arrange a handoff of the chat to it before Windows-specific validation. If the host is unavailable, state the blocker instead of claiming Windows verification.

## Swift and macOS development

- Follow the deployment target and toolchain requirements in `Package.swift` and
  CI, using the existing SwiftPM/Makefile build route. Before adopting an API,
  verify its availability on the minimum supported macOS and the compiler
  actually in use; the manifest's tools version does not identify that compiler.
- Preserve the current AppKit/SwiftUI split: AppKit owns editing, selection, menus
  and command routing. Reuse existing bridges, controls, `StudioStyle` and
  `localised` helpers.
- Keep UI state on `MainActor` and respect actor and `Sendable` boundaries. Prefer
  `async`/`await` for ordinary asynchronous work. New `@unchecked Sendable` or
  other concurrency escape hatches require a documented safety invariant, not
  just suppression of a diagnostic.
- Preserve audio callback, queue and buffer-lifetime contracts documented in the
  audio code. Keep blocking native recognition on `DedicatedThread.run`, with
  its callers' cancellation handling and error propagation intact.
- Prefer Observation for suitable new SwiftUI state. Existing `ObservableObject`
  integration is valid; migrate it only for a concrete benefit with regression
  coverage.
- Use semantic controls with accessible names and keyboard operation. For changed
  UI, verify narrow windows, light and dark appearances, and applicable VoiceOver
  behavior; reuse the existing layout and accessibility tests.
- Handle recoverable failures from files, network and user input explicitly;
  avoid forced unwraps and `try!` on external data. Follow existing component
  boundaries and injectable dependencies to keep logic testable.
- Use Swift Testing and isolated fixtures. Run root tests with
  `swift test --no-parallel`: `.serialized` alone does not isolate shared AppKit
  state across suites. When `Packages/CallIntegrations` changes, also run its
  separate package and transport checks from `.github/workflows/ci.yml`.
  Follow `docs/ci.md` for build/test scope and `docs/pitfalls.md` for runtime
  checks. Report automated, UI and real-audio validation separately.

## Swift code navigation

- When Serena is available, use its symbol overview, declarations and references
  to narrow Swift code reads. Setup and troubleshooting: `docs/agent-code-navigation.md`.
- Cross-check references with `rg` before changing shared APIs or removing code.
  An empty reference or diagnostic result does not establish that indexing is
  complete or that the code builds. Follow the existing build/test requirements.
