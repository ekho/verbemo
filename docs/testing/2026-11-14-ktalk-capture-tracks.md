# Current KTalk tracks on macOS (#122)

Base: `73b7da1` on `origin/master`, including PR #133 (`30193e2`).
Local host: macOS 26.7.1, Xcode Swift 6.4.2; deployment target remains macOS 14.2.

## Capture contract

The current-recording page reads `RecordingSession.capturedParticipantTracks`.
That list comes from the recorder's active entries, after a PCM chunk has been
validated and written successfully. A track announcement or call/calendar roster
does not confirm capture. Silent PCM confirms capture, including mute and Verbemo
pause; a live-transcription sink is not required.

Each entry has a monotonic receipt timestamp. After three seconds without PCM it
is omitted on the next UI update (the existing recording timer runs every second).
Metadata/name changes do not extend that lease. A replacement generation needs
its own PCM; removal, closure, fallback, failure and a stopped recording clear
current tracks. Previously written files and metadata remain unchanged.

The page shows local/remote roles and provider-supplied names, with an explicit
unknown-name label. Internal source/participant IDs are not displayed. A bounded,
keyboard-scrollable list replaces device meters during direct capture; the
ordinary device meters return for microphone/system fallback. Preparation after
source loss is distinct from initial preparation. Source updates also run when
recording state changes, clearing the previous recording's presentation promptly.

No transport, mute/privacy gate, pause, autostart, recording-format, fallback or
transcription behavior is changed. Packages/CallIntegrations and Windows sources
are unchanged.

## Automated evidence

Commands use the repository's native SwiftPM scratch directory prepared by Serena:

```sh
swift test --no-parallel --build-system native --scratch-path .build/index-build
python3 Tests/scripts/test_independent_product.py --all
git diff --check
```

The full root run passed **1,535 tests in 213 suites** in 319.822 seconds, with
35 opt-in/resource-dependent skips. The independence guard passed.

The initial focused UI run exposed an AppKit constraint being activated before
its row had a common ancestor; the attachment order was corrected. The next run
passed 15 tests in three suites. A subsequent UI-only change reuses the existing
`FlippedStackView` so short lists start at the top; final focused verification
passed **30 tests in six suites** in 3.400 seconds, including recording-workspace
and audio-meter regressions.
The temporary UI entry point was removed; the final `swift build --build-tests`
with the same native backend and scratch directory passed in 44.78 seconds.

New checks exercise first PCM versus metadata/heartbeat, silence without ASR,
freshness expiry, name updates, pause, replacement, removal, retained physical
files, source-loss preparation and fallback, saved participant audio, and AppKit
source/track presentation at 760 and 1,340 points with live transcription off.
They also verify accessible labels and preservation of title editing while tracks
change. Existing recording tests cover pause redaction, fallback failure and saved
track offsets.

## Native UI

A temporary `.app` host loads the built test bundle with an isolated test home and
synthetic participant names. It uses the actual `ApplicationWindow` and
`LiveTranscriptView`; no diagnostic UI is added to the product. The installed
Verbemo and personal recordings are not changed.

Computer Use verified Russian and English light/dark presentation, 760-point width, local,
remote and unknown labels, no tracks, replacement, initial preparation, source
loss, fallback and failure. Live transcription remained off. A long list scrolled
with Page Down and retained visible recording controls. Pause/resume presentation
and accessibility labels were inspected; spoken VoiceOver was not exercised.

## Required live acceptance — pending

KTalk 3.8.0 is installed and already listens on loopback port 9333. The inspected
window displayed a saved recording; no isolated live test call was prepared.
No permissions, diagnostic ports, meetings or installed bundles were changed.

Before merging, run an explicitly authorized test call with the user's second
device: receive local and remote PCM, observe names independently of ASR, pause
and resume, interrupt this test's direct source, confirm physical microphone/system
fallback, stop/save and check that earlier participant audio remains readable.
Permission to transmit live microphone audio into that test room has been requested.
Synthetic tests and CI do not satisfy this live criterion.

No real KTalk audio, physical fallback, subjective listening, macOS 14.2 runtime,
Windows runtime or paid provider was tested. This is not a release or installation.
