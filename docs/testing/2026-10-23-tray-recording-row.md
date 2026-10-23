# Tray recording row — 2026-10-23

Local macOS follow-up to the [previous tray menu](2026-10-22-tray-menu.md).
The user requested recording controls inside the first row and removal of the
separate recording commands and transcription status.

## Behavior

- Idle: Start recording, with an inline record button.
- Recording: status and elapsed time, with pause and finish buttons.
- Paused: paused status and elapsed time, with resume and finish buttons.
- Clicking an active status opens the current recording in the existing main
  window. It does not pause or stop recording.
- Each embedded action closes the menu before dispatching the existing command.
- Command-R starts or finishes recording; Command-P pauses or resumes. Hidden
  native menu items retain these shortcuts without adding visible rows.
- Embedded buttons have localized accessibility labels and shortcut tooltips.
- Transcription status and its menu-only navigation callback are removed.
  Processing changes still refresh the meeting library.

## Verification

Focused AppKit checks cover state transitions, inline actions, shortcuts,
returning from settings to the current recording, right alignment, icon
visibility restoration and Russian/English localization. The final focused
run passed 42 tests in four suites.

The full `swift test --no-parallel` run passed 1,172 tests in 171 suites,
with 23 opt-in tests skipped. The final Swift Testing completion report is
present in the log. `git diff --check` passed.

Computer Use operated the production `MenuBarController` in a separate AppKit
fixture, `name.ekho.verbemo.trayqa`, with synthetic recording state. Clicks
verified start, pause, resume, finish and the current-recording callback.
The first row and its icons changed appropriately; the timer updated while
the menu was open. Clicking the status left recording active. The accessibility
tree exposed the embedded buttons and their changing labels.

Logs: `/tmp/verbemo-tray-final-focused.log` and
`/tmp/verbemo-tray-final-full.log`.

## Limits

The fixture dispatches synthetic actions; it does not capture audio or open a
personal meeting. Current-recording page routing is checked by AppKit tests.
Physical calls, spoken VoiceOver, Windows, installation and release were not
tested or performed.

Keyboard commands were checked through `NSMenu.performKeyEquivalent`.
Live keyboard attempts through Computer Use closed the popup before delivering
events to its view, so no live keyboard acceptance is claimed. Individual Tab
navigation between embedded controls is not provided; use Command-P/Command-R.
