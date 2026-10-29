# macOS transcript scrolling accessibility crash

The reported Verbemo 0.17.1 (602) crash occurred while scrolling a transcript on
macOS 26.7.1 (25G241), arm64. Its main-thread stack enters
`NSWindow.accessibilityParent`, `NSAccessibilityUnignoredAncestor`, and
`objc_opt_respondsToSelector`, ending in a pointer-authentication SIGTRAP.

## Reproduction and cause

A separate native app compiled the repository's `MeetingTranscriptView.swift`
and `MeetingSpeakerView.swift` with minimal domain stubs and 1,000 synthetic
segments. No user recordings, configuration, credentials, providers, or capture
devices were used. Computer Use scrolled the actual table; a timer queried the
accessibility parents of its application windows, increasing the frequency of
the query seen in the original crash.

AppKit creates an invisible `NSComboBoxWindow` during `NSComboBox.init`, even
when the dropdown is never opened. Transcript row reuse releases old controls,
but a surviving dropdown window can keep an unretained accessibility-parent
reference to the old `NSComboBoxCell`.

Before the fix, Zombies reported `NSComboBoxCell respondsToSelector:` sent to a
deallocated instance. A subsequent ordinary-memory run crashed in
`NSWindow.accessibilityParent` / `objc_opt_respondsToSelector` at the same
instruction as the original report. The supplied second crash report identifies
this diagnostic app as `name.ekho.verbemo.scroll-repro`, PID 96105.

The previous dropdown-dismissal fix in PR #65 remains necessary for selection
callbacks but does not cover controls retired by scrolling.

## Change and checks

`SpeakerAssignmentChoice` captures only windows created during its own native
initialization whose accessibility parent is its own cell. Its main-actor
deinitializer clears those references before the superclass releases the cell.
It uses public AppKit APIs and does not change assignment or storage behavior.

- The new regression test failed before the change for both inline Transcript
  and Participants editors: a retired window still returned the old cell.
- After the change, all 11 `SpeakerAssignmentTests` passed, including existing
  dropdown dismissal, Escape, free-text, persistence, and save-failure coverage.
- `swift test --no-parallel` completed with its final report: 1,317 tests in
  179 suites passed after 272.401 seconds; 25 opt-in tests were skipped.
- The same native harness passed repeated scrolling and accessibility queries
  with Zombies (31,022 queries, no deallocated-object messages) and ordinary
  memory (26,771 queries, no crash). Retired-window parents were observed as nil
  in both runs. The diagnostic app was stopped afterwards.
- Independent read-only review found no confirmed consequential issues. It
  also compiled the changed source with Swift 6.4 for macOS 14.2 and verified
  the generated deinitializer's backward-compatibility helper and weak import.

Local receipts are under `/tmp/verbemo-scroll-repro/`, with red/green test logs
at `/tmp/verbemo-0171-red.log` and `/tmp/verbemo-0171-green.log`. The full-suite
log is `/tmp/verbemo-0171-full.log`.

These checks cover the native view sources and synthetic data. At the time of
these checks, the installed Verbemo app was not replaced and no release was
published. A real macOS 14.2 run or full VoiceOver session was not performed.
Windows code was unchanged.
