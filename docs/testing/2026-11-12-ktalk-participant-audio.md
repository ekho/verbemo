# KTalk participant audio — 2026-11-12

## Scope and outcome

macOS implementation on `codex/ktalk-participant-audio`, based on `7d6fa25`.
The dedicated **Интеграция с KTalk / KTalk integration** page controls the existing opt-in setting.
A confirmed direct call records participant tracks (including local output), feeds live/final ASR with source identities, and bypasses acoustic diarization for those tracks. Ordinary sources retain their processing path. Loss of direct audio switches once to microphone/system capture; the fallback microphone is independent of KTalk mute. If fallback permissions/devices are unavailable, partial audio is preserved and the failure remains visible.

No Windows source, installed Verbemo application, user recordings, model choice, summary provider, or release was changed by this validation.

## Automated evidence

- Root `swift test --no-parallel`: **1480 tests / 201 suites passed after the review fixes in 316.802 seconds**. The preceding runtime-qualified revision also passed (1477 tests /201 suites, 328.365 seconds).
- `swift test --package-path Packages/CallIntegrations`: 12 tests / 4 suites passed.
- Native Foundation HTTP/WebSocket fixture: 6 tests passed, including anonymous worker targets, sustained polling, source replacement, error, installation timeout, changed-call refusal, and cleanup.
- AudioWorklet fixture: 3 tests passed, including a clone created muted then unmuted, generation replacement, call end, lease expiry, and removal of the injected binding.
- Focused stages exercised actual CAF writing, PCM gap/pause handling, known-speaker ASR routing, hybrid diarization, live epoch/queue cleanup, late-start/Stop races, fallback/device failures, recovery, AAC archive/reload, filename validation, and MCP projection.
- `swift build` passed. The isolated arm64 `.app` was ad-hoc signed; its existing native frameworks/helpers came from the installed app. This is development runtime evidence, not a universal release or notarization check.

The root run reports 28 intentionally skipped tests and six skipped suites, including optional hardware/model and gallery coverage. A passing suite is not evidence that those skipped paths ran. No paid cloud ASR request was made.

## Native application and real KTalk runtime

An isolated application identity and `CFFIXED_USER_HOME` kept settings, model files and recordings separate from the user's profile. Cached Nemotron models were cloned into that profile. Automatic recording, cloud summaries, calendar access and local diarization were off; live transcription and final Nemotron ASR were on. The configured ASR language remained Russian. The artificial speech fixture contained English phrases, so this verifies routing, decoding and attribution, not recognition quality across languages.

KTalk 3.8.0 / Chromium 152.0.7977.169 was launched temporarily with loopback CDP at `127.0.0.1:9333` and fake media devices. A previously authorized private test room was used, with only the local test participant. No real microphone or camera media was transmitted. Guest access was not changed. The fixture injected generated speech into KTalk's normal audio acquisition path; product capture used its existing processed output track.

Observed in native UI:

- Separate settings destination, exact Russian title, enabled state, space address, direct-source status and explicit fallback/mute explanation.
- Direct recording starts without Verbemo microphone permission.
- Live text appears under the KTalk participant's name; final text retains that name and timestamps with `speaker_names` disabled.
- Mute gives silence; unmute restores the same cloned track. Verbemo pause silences the recording. Audio continues with the KTalk call window minimized.
- Changing the fake input creates a second physical track generation while keeping one stable speaker identity.
- Saved audio appears in the normal meeting player with playback and timestamp seek controls. The files were decoded for numeric PCM checks; audible player output was not listened to in this run.
- An abrupt KTalk process loss closes direct capture. Missing fallback microphone permission produces a visible explanation in the attention list; saved partial audio is still transcribed.
- The corrected test app exits normally after recording. KTalk was restarted normally; its UI showed Online, and an independent loopback check confirmed port 9333 closed. The isolated Verbemo process no longer existed.

### Saved sample checks

The first acceptance recording lasted 163 seconds and archived two generations as independent mono M4A files. Both belong to the same local participant and stable speaker ID; no `mic` or `system` file exists. Metadata reports `transcription_input: participant-tracks`, one direct period and zero missing frames.

Decoded AAC audio was measured at 16 kHz using FFmpeg:

| Check | Result |
| --- | --- |
| First generation (offset 0.367 s, duration 49.408 s) | Peak 0.0; muted/silent |
| Replacement generation (offset 49.823 s, duration 112.9813 s) | Peak 0.74449 |
| Mute interior, meeting seconds 90–94 | Peak exactly 0.0 |
| Verbemo pause interior, seconds 127–144 | Peak exactly 0.0 |
| Speech, seconds 60–80 | Peak 0.73219 |
| Minimized call window, seconds 105–110 | Peak 0.71981 |
| After resume, seconds 153–160 | Peak 0.73212 |
| Final ASR | Three segments, one integration speaker, offsets approximately 00:53 / 01:37 / 02:31 |

A second 54-second recording began muted with a live artificial source, then unmuted **without** replacing that track. Its first five seconds decoded to zero; seconds 15–25 had peak 0.73622. Abrupt source loss preserved the one track and two final transcript segments. The recorded stop reason was `capture-failed`, with the explicit missing-fallback-microphone-permission explanation.

Numeric intervals avoid mute/pause boundaries and are not a claim of zero-latency mute detection. The capture reconciles KTalk state every 100 ms.

## Runtime findings fixed before delivery

1. **Anonymous CDP workers broke discovery.** Real KTalk includes worker targets with an empty URL. Decoding every URL before filtering rejected the complete list. The shared target filter now parses only relevant page URLs. The native fixture failed before and passed after the fix.
2. **A resource timeout expired a persistent WebSocket.** The previous 0.7-second URLSession resource deadline invalidated reused observation sockets and could stall subsequent polling/shutdown. Per-operation deadlines remain; the session no longer gives the socket a polling-length lifetime. A ten-observation native test reproduced the hang before the fix and passed afterward. The final native app exited normally.
3. **The packaged app omitted the capture resource.** The Makefile now copies `CallIntegrations_KTalkIntegration.bundle` into application resources. Actual packaged runtime successfully loaded it and captured audio.
4. **CDP removal left a JavaScript binding property behind.** Capture cleanup now deletes its own binding as well as stopping clones and closing the worklet context. Normal Stop and lease expiry are covered; the current runtime capture left neither its control nor its binding after Stop.
5. Updated the live source explanation for named KTalk tracks and removed duplicated restart wording in settings.

## Deliberate limits and implementation rulings

- Multiple real remote participants were verified in the earlier media research, but were not repeated through this final application build. This stage's real-room app validation used the local track. Multiple-source/identity/rejoin behavior is covered by synthetic module/app tests, not by a new multi-person meeting acceptance.
- Successful physical-device fallback is covered with controlled recorder doubles. The live app verified actual CDP loss and the permission-denied preservation path. It deliberately never opened a real microphone for this artificial-media test.
- Long meetings, Intel runtime, production networks, all cloud recognizers, and Windows were not run. No universal package/release, installation, merge or publish was performed.
- Hybrid GigaAM uses common per-track ASR plus ordinary-source diarization. Its optimized turns-first path publishes early and would omit known participant tracks; the cost is potentially more ASR work for hybrid GigaAM sessions.
- The implementation proceeded inline while the optional execution preference was pending, then the user explicitly selected inline execution with one final independent review. No implementation subagents were used.
- KTalk's internal participant/media objects are not a supported public media API. Strict validation and fallback handle known mismatches; an app update can require adapter changes.

## Final verification and independent review

At `ae7456b`, the final root suite passed (1477 tests / 201 suites, 328.365 seconds); final package, native transport and AudioWorklet checks passed. A fresh independent reviewer completed a read-only whole-branch review at that revision and found two Important defects, with no Critical or Minor findings: delayed PCM could escape a completed pause, and a delayed live start could mistake an already-direct capture for ordinary audio. Both were accepted for the single fix pass; regression and final-suite results follow below.

The reviewer explicitly set aside real-device fallback/multiple remote participants, cloud requests/long load/large conferences, and Windows/Intel/install/publication runtime validation. These remain the documented evidence limits, not implied successful checks.


### Review fixes

- **P1, delayed pause audio:** recorder redaction now intersects completed pause intervals with the PCM capture-frame timeline before writing files or forwarding live buffers. The session also preserves pauses completed during async preparation. Regression tests reproduced nonzero paused samples in both CAF and live output before the fix; afterward the matching samples were zero, including late participant registration and buffered audio delivered after preparation.
- **P2, delayed live start:** source selection accepts both preparing and already-direct capture. A regression holds the previous live transition, lets the new session reach direct, then releases the queue; it failed before and passed after the fix.

The single fix pass passed 44 related tests /7 suites in 1.301 seconds. No findings were deferred. The reviewer was not asked to re-review; fixes are verified by regressions and the post-fix full suite, following the agreed inline workflow. The real KTalk runtime evidence above predates these two fixes; their boundary/race cases were verified deterministically in tests.

Post-review full verification: `swift test --no-parallel` passed **1480 tests /201 suites in 316.802 seconds**, with the same 28 intentional test skips and six suite skips. Both Important findings are fixed; no Critical/Important finding or Minor was deferred. No second reviewer pass was performed.
