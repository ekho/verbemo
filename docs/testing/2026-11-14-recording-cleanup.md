# macOS recording cleanup: #108

Base: `3bfb282` (0.25.0), after recording-operations PR #132 merged.
Host: macOS 26.7.1, Swift 6.4.2 / Xcode 27.2; minimum deployment target remains macOS 14.2.

## Policy and recovery

Cleanup is off by default, with no age selected. Storage and models accepts a
positive whole number of elapsed 24-hour days from `meta.json.started`, then offers
audio-only or entire-recording cleanup. Checks run at launch and every 24 hours
while the app runs; the same action supports manual checking/retry.

Both modes use the existing macOS Trash route. Audio-only cleanup preserves the
metadata and every non-audio artifact, including transcript versions and summaries.
Claims, queued/running work, recording markers, open selections and import/merge
work protect recordings. Paths are normalized for busy checks; symbolic links and
unsafe audio metadata fail closed. A root or policy change stops subsequent moves.
Shutdown waits for an already requested Finder move.

The last report is written before each move, then records original/Trash paths,
failures and skipped items. Partial failure leaves completed moves in Trash and
other files in place. Retry only touches files still present. Disable cleanup
before restoring with Finder's Put Back or the paths in the report. Verbemo never
empties Trash; emptying it removes this recovery route and releases disk space.

## Automated verification

Focused checks cover default-off policy, invalid/missing age, the exact age boundary,
unreadable dates, modification-time independence, queued/claimed/recording/selected
protection, multiple participant tracks and retained originals, document byte
preservation, partial failure/retry/restore, whole-folder restore, symlinks/path
escape, failed report writes, disabling policy mid-run, root changes, daily checks,
duplicate requests and shutdown during a Finder operation. AppKit tests exercise
the real storage controls and missing-audio accessibility label.

The first completed focused run exposed path alias comparisons (`/var` versus
`/private/var`) and old assumptions about numeric defaults and storage help. The
full run also exposed the MCP settings snapshot assuming every number has a
default; it now preserves an absent value as null, as it already does for optional
text. After these fixes and the extra root/accessibility checks, the focused run
passed **72 tests in 9 suites** in 14.137 seconds, including application startup
and transcript reading-position preservation.

The final full run passed **1,532 tests in 212 suites** in 281.169 seconds, with
29 opt-in/resource-dependent tests skipped. Daily scheduling uses an injected short
interval in its test, rather than a 24-hour wait. The independence guard and
`git diff --check` also passed.

One earlier full run reported a reading-position failure after inventory refresh.
That test subsequently passed both on base `3bfb282` and on the changed source,
alone and after application startup. Its intermittent cause was not established.

On this host, `swift test --no-parallel` built the bundle but its generated
`swiftpm-testing-helper` remained idle before Swift Testing began. Native and Xcode
build backends showed the same symptom; its cause was not established. A temporary
AppKit host loaded the built test bundle and invoked `Testing.__swiftPMEntryPoint`
with `--no-parallel`, allowing the actual tests to run. This local workaround is
not a change to the product or CI and is not equivalent to a successful standard
SwiftPM test invocation. The temporary entry point was removed before committing.
The final `swift build --build-tests` without that entry point passed in 29.06 seconds.

## Native UI verification

A separate temporary app loaded the real application window/library from the test
bundle, with an isolated home and synthetic old, busy and recent recordings.
The installed app and personal recordings were not changed.

Computer Use checked Russian/light and Russian/dark storage settings, English/light
settings, a 760-point window and keyboard navigation. Enabling a mode without an
age showed the validation message and left cleanup off. An age of one day enabled
each mode explicitly. Help, partial-failure guidance and recovery instructions were
readable at the narrow width.

Audio-only cleanup moved three synthetic audio files through the actual macOS
Trash API and skipped the claimed recording. The saved transcript, summary and
transcript version remained readable; playback disappeared, retranscription was
disabled and the inspector said audio was not retained. Entire-recording cleanup
moved one eligible folder and skipped the claimed recording.

For both modes, the fixture disabled policy and restored only its recorded Trash
destinations to their original paths, without replacement. Restored audio regained
playback and its position advanced; the restored whole recording retained its
saved results. All synthetic items were restored at the end. Trash was not emptied.
The Finder Put Back menu itself was not exercised. Accessibility names and keyboard
actions were inspected; spoken VoiceOver was not run.

## Limits

No real microphone/system capture, live KTalk call, paid recognition, cloud summary,
subjective listening, physical full disk or forced process kill was tested. Failure
and interruption cases are controlled fixtures. macOS 14.2 and Windows were not
runtime-tested; Windows sources and Packages/CallIntegrations were unchanged.
No installed build or release is established by these checks.
