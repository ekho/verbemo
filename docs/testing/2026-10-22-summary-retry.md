# macOS summary retry and CLI diagnostics: issue #8

Scope: `codex/8-summary-retry`, based on `b8b09601bb7d0b87effd775af7f24219c6dc671e`.
Upstream scope and attribution are in [the provenance note](../history/summary-retry-upstream.md).

## Automated checks

`VERBEMO_REQUIRE_LOCALVQE=1 swift test --no-parallel` passed: **1057 tests in 149 suites**, 144.528 seconds. The final test report is present. Twenty optional interactive/gallery tests were skipped. Local log: `/tmp/verbemo-8-full-final.log`.

Focused coverage includes:

- Real subprocess failures with a long banner, exact/reformatted/partial/numbered meeting echoes, separate stdout/stderr, bounded diagnostic tails, quoted/unclosed credential values, and quota/timeout words that belong to the meeting rather than the service error.
- Concrete Claude/Codex sign-in errors, unrelated MCP/authentication chatter, login advice and fallback for both names and summary.
- The actual `ProcessSession` command with unchanged-fingerprint and legacy failures; success preserves the transcript and does not repeat completed stages. Permanent failures stop background retries; deferred failures remain recoverable. Existing fingerprint-change tests also pass.
- Root session claims for archived versions, unreadable claims/configuration, pending diarization, and a recordings directory literally named `transcripts`.
- Configuration becoming unreadable during an attempt: completed artifacts survive, unfinished work reports a pause, and a completed final stage still reports success.
- The actual AppKit button action and completion/failure/deferred sheets, using isolated `Home`, `SessionFixture` and fake models.

The initial diagnostic and manual-processing tests failed against the old behavior (20 and 12 issues respectively). Review added regressions for partial echoes, quoted secrets, archive-root detection and stale outcomes; they failed before their fixes. The first full run failed only in a new test fixture that wrote the wrong persisted diarization representation. That fixture was corrected to use `DiarizationState.write`; the final full run above passed. A second review confirmed the last two edge fixes, without a second broad review.

## Actual CLI and window checks

A separate ad-hoc-signed app, `.build/Verbemo-SummaryRetry.app`, uses bundle ID `name.ekho.verbemo.summaryretry8`. Its Info.plist pins `CFFIXED_USER_HOME` to `.build/summary-retry-home`; it does not replace the installed app. The profile disables automatic recording, calendar integration, transcription and live transcription. Only synthetic transcripts and local fake Claude/Codex executables are used. No real meeting, key or paid model request is needed.

The real `process` command recovered both names and summary from a legacy failed session. Its fake CLI call log contained one naming call and one summary call. Local log: `/tmp/verbemo-8-cli-runtime.log`.

Computer Use in the real application verified:

1. **Completed:** Finish processing recovered names and summary, displayed “Processing completed”, showed the synthetic summary and named speakers, and removed the now-unneeded Finish processing action.
2. **Failed again:** the fake CLI returned a long banner, an echoed transcript and “ERROR: Not logged in”. The window reported failure and pointed to `transcribe.log`; the log contained login advice without the echoed transcript.
3. **Deferred:** a connection failure produced the deferred message with the log location.
4. **Selected version:** selected the older transcript in the version popup and finished it. The window stayed on that version and displayed its new summary and names. SHA-256 comparisons showed the current version's transcript, summary and names were unchanged; the archive received its own result files.

The selected-version check used the final debug executable, SHA-256 `d66db5e01d87f93cbb56f2b773545af44e1e893b2208dc1e51a63901d3914e0c`. The three outcome checks and initial CLI check ran before the final two edge fixes (unclosed quoted credentials and config changing during the final call); those edge fixes are covered by the final suite. Native GUI checks are separate from the AppKit tests.

Screenshot and accessibility evidence for the final selected-version check are saved locally under `/Users/ekho/.codex/visualizations/2026/10/22/01a16355-da81-7aa2-b32e-78353514e23c/summary-retry-selected-version.{png,ax.txt}`. The synthetic profile remains in this managed worktree for inspection.

## Packaged application

`make app -o localvqe -o nemotron` completed successfully. It rebuilt the universal arm64/x86_64 Swift application and packaged the unchanged, previously built native helpers. Strict ad-hoc signing, architecture checks, macOS 14.2 compatibility and the Nemotron relative dependency closure passed. The resulting `.build/Verbemo.app` is version 0.6.1/build 542; its executable SHA-256 is `2c11f2d59a820cead2852f10871a8877fd2772aec8f601467bc71ffe6c6e0880`. Local log: `/tmp/verbemo-8-universal.log`.

The packaged release binary was built and verified but was not used for the GUI scenarios above; those used the isolated debug bundle. The test app was quit after validation. No Developer ID credentials or notarization were used.

## Limits

Real Claude/Codex authentication, live provider responses, physical audio capture and Windows were not exercised. Diagnostic filtering covers the tested echo and credential formats; future CLI output formats can require new cases. No release, notarization, merge or replacement of the user's installed app was performed.
