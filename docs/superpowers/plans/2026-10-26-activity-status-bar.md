# Activity Status Bar Implementation Plan

> **For agentic workers:** Use the dispatching-parallel-agents skill for independent platform tasks; the parent integrates and reviews both implementations.

**Goal:** Implement the approved persistent activity status bar on macOS and Windows.
**Architecture:** Native UI consumes the existing runtime and processing ownership. Counts distinguish waiting and running, exclude bookkeeping parents, and retain cancelling work until cleanup finishes. No second scheduler.
**Tech Stack:** AppKit/Swift and WPF/C#; existing Swift Testing and xUnit.
**Spec:** `docs/superpowers/specs/2026-10-26-activity-status-bar-design.md`

## Global Constraints

- Both platforms; EN/RU; minimum window width; native accessibility and themes.
- Preserve existing settings, recording, processing, cancellation, data and release behavior.
- Use unknown for unverified permissions and never confuse silence with loss of capture.
- Use an isolated synthetic profile for GUI checks; never launch a test against user recordings.

## Review Focus

- Multiple simultaneous or nested operations must not double-count work or hide a running job.
- Cancellation/completion must clear stale job text only after work actually finishes.
- Optional access, disabled system audio and unreadable configuration must not falsely report readiness.
- Narrow windows and long Russian titles must leave auto-record/access/navigation usable.
- UI timers and subscriptions must stop on teardown and refresh after reopening/settings changes.

### Task 1: macOS status bar

Files: `Sources/verbemo/UI/ApplicationWindow.swift`, `SidebarView.swift`, new `ActivityStatusBar.swift`, `Sources/verbemo/Verbemo.swift` and minimal existing queue/library projection hooks; `Tests/verbemoTests/ActivityStatusBarTests.swift` and affected Journal tests.

- [x] Read runtime/queue/access sources and their callers; define a small status projection.
- [x] Add failing tests for queue counting, readiness, transitions and minimum-width navigation.
- [x] Implement the native bar and wire existing callbacks; remove sidebar duplication.
- [x] Run focused tests, normal build and full Swift suite; inspect an isolated GUI.

### Task 2: Windows status bar

Files: `windows/src/Verbemo.App/ApplicationWindow.cs`, `VerbemoRuntime.cs`, `ProcessingCoordinator.cs`, minimal status view/projection, and `windows/tests/Verbemo.Live.Tests/ActivityStatusBarTests.cs`.

- [x] Read existing runtime, ownership, access and meter contracts.
- [x] Add meaningful tests for state/count transitions, access and navigation/layout.
- [x] Implement the native bar and runtime projection; remove sidebar duplication.
- [x] Build/test on Windows and launch/inspect the isolated Windows GUI; full interactive acceptance is limited by guest input through Computer Use (see verification report).

### Task 3: integrated verification

- [x] Review both diffs against the shared spec, including the five review-focus cases.
- [x] Fix material defects and rerun affected checks.
- [x] Record exact results and limits in `docs/testing/2026-10-26-activity-status-bar.md`.

Execution decision: proceed under the user's explicit “делай для обеих платформ”; no additional approval gate. Independent platform sources may be edited in parallel; the parent owns docs and macOS, the Windows worker owns `windows/`.
