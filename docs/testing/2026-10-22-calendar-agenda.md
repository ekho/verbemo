# Calendar agenda HTML — 2026-10-22

Base: `99d752b` (Verbemo 0.7.0). Local working-tree validation, not a published release.

Both calendar views now render HTML as native formatted text before computing the
100-character preview. Paragraphs, line breaks, emphasis, lists, links and HTML
entities remain readable; expanding/collapsing preserves formatting. Plain-text
notes retain literal punctuation and newlines. Saved calendar metadata is unchanged.

macOS uses Foundation's HTML parser after an allowlist removes resource-loading
markup and attributes. Windows uses HtmlAgilityPack 1.12.4 and creates WPF runs and
hyperlinks directly. Neither path loads invitation images or scripts. Links only
accept HTTP, HTTPS and mailto. The Windows package includes the parser's MIT license.

## Checks

- macOS regression tests failed on the original implementation (literal tags and
  missing formatting), then passed after the fix.
- Final macOS focused run: 28 tests in four suites passed, including calendar
  rendering, metadata and adjacent meeting UI cases.
- Before release, the change was rebased onto `9a40b80` (0.7.2). The expanded
  calendar, event picker, automatic recording and adjacent UI selection passed:
  64 tests in eight suites (`/tmp/verbemo-agenda-rebase-tests.log`). Windows
  sources were unchanged by that rebase.
- Full macOS run: 1077 tests in 153 suites, one failed test with two assertions:
  `DiarizationLifecycleTests.inferenceFaultThenRetry` (stop-hook file not ready).
  Its separate rerun passed all 33 tests. There were 23 opt-in skipped tests.
  The full run is not claimed green.
- Windows clean build succeeded on the Windows 11 Parallels host using its existing
  .NET 10.0.402 x64 SDK. All four agenda regression tests passed. Tests inspect
  formatted WPF content with `TextRange`, and raise the real expansion button event.
- Windows Core suite: 157 passed. No Core production code changed.
- Final Windows Live suite on the clean build: 100 passed, two failed out of 102:
  `MeetingPlayerTests.Native_seek_waits_for_loading_and_stays_paused_after_unload`
  and `InterfaceRegressionTests.Undo_stays_outside_compact_panels_and_disappears_after_undo`.
  All four agenda tests also passed within this full run. See
  `~/Documents/VerbemoAgendaQA/live-final.log` for the failures.
  Both failed tests passed on their separate rerun (two tests, six seconds);
  `~/Documents/VerbemoAgendaQA/unrelated-recheck.log` records that result.
  The complete Live run remains reported as failed, not replaced by this rerun.
- `git diff --check` passed.

Local logs: `/tmp/verbemo-agenda-final-focused.log`,
`/tmp/verbemo-agenda-full.log`, `/tmp/verbemo-agenda-diarization-recheck.log`, and
`~/Documents/VerbemoAgendaQA/{red,focused-final,core}.log`.

## Native UI and limits

A separate ad-hoc macOS app (`name.ekho.verbemo.agendacheck`) used a dedicated home
under `.build/agenda-check-home`. Computer Use confirmed bold/italic text, a link,
a numbered list, and expansion followed by collapse in the actual meeting view.

The Windows debug app used `VERBEMO_TEST_DATA` and synthetic saved metadata under
`VerbemoValidation/jobs/agenda-6280-green/profile`. Computer Use confirmed the
formatted preview in the actual meeting view. Input through the Parallels surface
did not activate the expansion button, so manual Windows expansion is unverified;
its automated WPF action test passed. No actual meeting/calendar data was used,
no recording was started, and no external link was opened.

An exploratory Windows Live run reused stale DLLs after an archive restored old
source timestamps. It is excluded from final-change evidence; the successful
agenda run used a new empty build directory.
