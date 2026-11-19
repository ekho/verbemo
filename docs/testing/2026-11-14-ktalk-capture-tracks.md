# Current KTalk tracks on macOS (#122)

Base: `73b7da1` on `origin/master`, including PR #133 (`30193e2`).
The automated and synthetic UI checks ran on macOS 26.7.1 with Xcode Swift
6.4.2. The live call ran on macOS 26.7.3. The deployment target is macOS 14.2.

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

## Live acceptance on November 19

The installed KTalk desktop client (3.8.0.13562) and a Safari 27.2 guest joined
the same private test room on one Mac. The isolated test host used the branch's
actual KTalk integration, recording session, device recorders and current-recording
page. Live transcription was off. Each client sent a short test phrase through
its microphone while the other client was muted.

The page showed the direct KTalk source, the local role and name, and the
remote role and guest name. The recorder continued reporting both tracks during
Verbemo pause.
Stopping only the test's direct subscription kept the call connected. The session
reported preparation after source loss, then fallback. The list cleared and
the microphone and computer-audio meters returned.

After a normal stop, the 90-second meeting contained two indexed participant
CAF files and both fallback files. The metadata recorded direct and fallback
periods on the same timeline. All four files decoded with FFmpeg. The two
48 kHz mono participant files each retained 67.328 seconds and reported zero
missing frames. The table shows peak sample amplitudes in the interior of the
marked playback windows, using 1.0 as full scale.

| Stimulus | Local track | Remote track |
| --- | ---: | ---: |
| Remote phrase before pause | 0 | 0.423 |
| Phrase during pause | 0 | 0 |
| Remote phrase after resume | 0 | 0.367 |
| Local phrase | 0.044 | 0 |

All 139,560 samples inspected on **each** participant track during the pause
were exactly zero. After the source switch, the system file contained 21.813
seconds of stereo audio with a peak of 0.270 after downmix. The microphone file
contained 21.700 seconds of digital silence in this speaker-playback run.

A separate bounded run checked the physical input with the desktop KTalk
microphone still muted. The user was cued to speak near the Mac during fallback.
The saved built-in microphone file contained 45.600 seconds, 2,186,326 nonzero
samples and a peak of 0.575. The system file was silent in this one-client
room. Both completed fallback runs saved a normal stop reason and no capture failure.
The reason for the first microphone file's silence was not established.

An earlier Chrome attempt reached the room but failed to create a WebRTC
connection. The remote participant appeared in KTalk without a corresponding
track on Verbemo's page. During the first transition the macOS system-audio
permission prompt blocked the test host. Its time limit terminated the process,
leaving a recovery manifest. The completed runs above followed the permission grant.

The guest left, both room access settings were restored, and the local diagnostic
port was verified closed after KTalk restarted. The installed Verbemo was
reopened with its original auto-record setting. Test audio and identifying
metadata stayed in the private temporary test directory.

This acceptance used file decoding and sample measurements. Subjective
listening, spoken VoiceOver and a macOS 14.2 runtime were not exercised.
