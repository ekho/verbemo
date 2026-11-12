# KTalk Participant Audio Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Record separate KTalk participant audio into ordinary Verbemo meetings, transcribe it with known speaker identities, and fall back automatically to ordinary capture when necessary.

**Architecture:** Extend the existing provider package with an audio stream, then feed a durable participant recorder and the existing transcription pipeline. A session owns the transition from direct audio to ordinary recording; timestamps and participant provenance survive that transition, archiving and retranscription.

**Tech Stack:** Swift 6, Foundation URLSession WebSocket, AVFoundation, existing AppKit settings, JavaScript AudioWorklet in KTalk, Swift Testing and the existing Python loopback transport fixture. No new third-party dependency.

**Spec:** `docs/superpowers/specs/2026-11-12-ktalk-participant-audio-design.md` (approved, with the settings title corrected to «Интеграция с KTalk»).

## Global Constraints

- Scope: macOS and `Packages/CallIntegrations`; preserve ordinary recordings and old meeting files.
- Exact Russian page title: **Интеграция с KTalk**; English: **KTalk integration**.
- Reuse `call_integrations.ktalk.enabled`, default false. Provider configuration changes retain restart semantics.
- Direct mode never starts a device microphone or system tap. Direct local mute produces silence.
- Automatic fallback records the microphone regardless of KTalk mute, including unknown mute. Verbemo pause always silences every source.
- Fallback is one-way until this recording ends; next recording retries direct capture.
- A confirmed call exit is not a capture failure; silence/mute alone never triggers fallback.
- Use configured ASR and existing summary/egress policy. Never infer that identical participant names are one person.
- Preserve original KTalk tracks, recovery ownership, manual names, transcript versions and audio retention rules.
- Use Conventional Commits with `Co-Authored-By: Codex <codex@openai.com>`; local commits only unless separately requested.

## Review Focus

- Stop/quit during async preparation or fallback: no late capture, duplicate session or lost saved audio (Task 5).
- Same display name, rejoin or replaced MediaStreamTrack: no identity conflation or borrowed ASR state (Tasks 1, 2, 4).
- Out-of-order/oversized/invalid PCM and queue overflow: bounded memory, explicit source failure, no corrupt CAF (Tasks 1, 2).
- A direct-plus-fallback meeting is archived/retranscribed: retain every source and timestamp, and diarize only ordinary sources (Tasks 3, 6).
- Missing OS capture permissions: direct starts independently; fallback reports failure and preserves partial data (Tasks 5, 7).

---

### Task 1: Provider-neutral PCM events and KTalk capture

**Files:**
- Create `Packages/CallIntegrations/Sources/CallIntegrations/CallAudio.swift`.
- Create `Packages/CallIntegrations/Sources/KTalkIntegration/KTalkAudioCapture.swift` and `Resources/capture.js`.
- Modify `Packages/CallIntegrations/Package.swift`, `KTalkIntegration.swift`, `KTalkCDP.swift`, `KTalkModel.swift` in that package.
- Add `CallAudioTests.swift`, `KTalkAudioTests.swift` under package tests; extend `Tests/test_transport.py` and probe where necessary.

**Interfaces:**
- `CallAudioTrack`: Codable/Sendable descriptor with `id: String`, `participant: CallParticipant`, `generation: Int`, `sampleRate: Int`.
- `CallAudioChunk`: Sendable data with `trackID: String`, `generation: Int`, `frameStart: Int64`, `sampleRate: Int`, `samples: [Float]`.
- `CallAudioEvent`: `.track(CallAudioTrack)`, `.audio(CallAudioChunk)`, `.removed(String)`, `.heartbeat(frame: Int64, sampleRate: Int)`, `.ended`.
- `CallAudioCapture: Sendable`: `var events: AsyncThrowingStream<CallAudioEvent, Error> { get }`, `func start() async throws`, `func stop() async`.
- `CallAudioIntegration: CallIntegration`: `func makeAudioCapture(for callID: String) async throws -> any CallAudioCapture`.
- KTalk conforms to the optional audio capability. Metadata-only providers remain valid.

- [x] Write failing tests for validated PCM (`[0, 0.5, -0.5]` accepted; NaN, negative frame, unknown generation and oversized payload rejected), origin/debugger validation and target/call-ID matching.
- [x] Run `swift test --package-path Packages/CallIntegrations`; confirm new cases fail for the intended missing behavior.
- [x] Implement the contract and a bounded single receiver for audio commands/events. Preserve the metadata observer. Resource JS uses one AudioContext, clones participant/output tracks, reconciles local mute including clones born disabled, and emits frame positions rather than arrival timestamps.
- [x] Cover lease expiry and explicit cleanup, participant removal versus transport failure, replacement generation and event/reply interleaving. Verify the fixture never calls `getUserMedia` or stops original tracks.
- [x] Run package tests plus the expanded loopback transport test. Commit `feat(ktalk): stream participant audio through the call integration`.

### Task 2: Durable participant audio and metadata

**Files:**
- Create `Sources/verbemo/Audio/ParticipantAudioRecorder.swift` and `Sources/verbemo/Sessions/CallAudioMetadata.swift`.
- Modify `Sources/verbemo/Transcription/TranscriptionInputs.swift` (`SessionMeta`).
- Add `Tests/verbemoTests/ParticipantAudioRecorderTests.swift` and `CallAudioMetadataTests.swift`.

**Interfaces:**
- `CallAudioMetadata`: Codable/Sendable versioned `call_audio` value with call/integration ID, periods and participant-track descriptors. Track descriptors reference generated keys in existing `files`/`start_offset_ms`, and carry separate speaker/participant IDs and display name.
- `ParticipantAudioRecorder` consumes Task 1 events, writes mono CAF, exposes thread-safe snapshots and an installable live sink keyed by track ID. Append/update/pause operations are serialized; pause is checked before persistence and live forwarding.
- `SessionMeta` gains known-participant track data while retaining existing initializer defaults and legacy `mic/system/source` decoding. Ordinary tracks remain distinguishable in hybrid sessions.

- [x] Add tests that decode actual CAF samples: a late first packet, a frame gap and a replacement preserve duration; pause writes zeros; names containing paths never become filenames. Reject unsupported metadata versions and broken references instead of returning an empty track list.
- [x] Run `swift test --filter 'ParticipantAudioRecorder|CallAudioMetadata'` and verify expected failures.
- [x] Implement generated file IDs, finite/sample-size validation, bounded gap writes and metadata snapshots. Keep departed participant history. One replaced stream retains its connection identity; rejoin with a new participant ID does not merge by name.
- [x] Run the focused tests and legacy `TranscriptionInputs` tests. Commit `feat(recording): persist participant audio on a shared timeline`.

### Task 3: Known-speaker final transcription

**Files:**
- Modify `TranscriptionInputs.swift`, `TranscriptionCoordinator.swift`, `EngineResolver.swift`, `TranscriptionEngine.swift` and applicable cloud engines in `Sources/verbemo/Transcription/`.
- Modify `SpeakerNames.swift`, `SpeakerNamer.swift`, `TranscriptVersions.swift` and `PostProcessor.swift` in `Sources/verbemo/Sessions/` only at relevant boundaries.
- Add `Tests/verbemoTests/ParticipantTranscriptionTests.swift`; extend cloud payload, speaker-name and transcript-version tests.

**Interfaces:**
- Known-participant inputs are dispatched per file even when the configured engine normally accepts mixed/multichannel input. Track IDs, not array order or recognizer labels, determine canonical speakers.
- Ordinary `mic/system` inputs in the same session retain the configured existing path. A combined result is sorted on the shared session timeline.
- Add `.integration` speaker-name provenance below manual corrections and above automatic guesses; preserve names in retranscription and archived versions.

- [x] With a fake engine, assert two known tracks get independent ASR calls, bogus engine speaker labels are ignored, offsets are applied, and the diarizer factory is never called for a direct-only session.
- [x] Add hybrid tests: known tracks plus fallback mic/system retain all text and correct time; only fallback is eligible for ordinary diarization/echo processing. Same-name participants remain distinct. Manual speaker correction survives retry.
- [x] Run `swift test --filter 'ParticipantTranscription|SpeakerNamer|TranscriptVersions'` to establish intended failures.
- [x] Implement per-source policy and include the transcription mode in cloud/cache fingerprints. Disable cloud speaker-label flags where supported. Preserve configured OpenAI model and document its internal diarizing-model exception; do not silently change providers/models.
- [x] Verify no local diarization preparation/model download for known-only audio, no model renaming of integration identities, and summary input contains the resulting names. Run focused engine and pipeline tests. Commit `feat(transcription): transcribe known participant tracks directly`.

### Task 4: Multiple live speakers

**Files:**
- Modify `LiveTranscriptionCoordinator.swift`, `LiveTranscriptState.swift`, `LiveTranscriptionTransitions.swift` in `Sources/verbemo/Transcription/`.
- Modify `Sources/verbemo/UI/LiveTranscriptContent.swift` and `LiveTranscriptView.swift` only where speaker representation changes.
- Extend live state, relay and lifecycle tests; add participant live-transcription cases.

**Interfaces:**
- A live speaker has a stable source ID and display label; `.you`/`.them` remain available for ordinary capture and existing tests.
- Live attachment accepts dynamic track registration/removal and a keyed sink, using shared model weights with per-source streaming state.
- A fallback transition closes direct preview streams before attaching ordinary sinks; already displayed entries remain on the same meeting clock.

- [x] Test independent partials for two equal names, late participant registration, ended streams, stale callbacks after stop and fallback, and bounded queue overflow.
- [x] Run existing live tests and the new cases before implementation.
- [x] Generalize the existing two-source coordinator without a second ASR implementation. Release departed managers; do not block authoritative file writing on live inference.
- [x] Run live state/transition/relay tests. Commit `feat(transcription): show live text for individual call participants`.

### Task 5: Session source selection and automatic fallback

**Files:**
- Modify `RecordingSession.swift`, `Verbemo.swift`, `Meetings/CallIntegrationMonitor.swift`, `CallIntegrationBridge.swift`, `AutoRecordController.swift`, `MeetingContext.swift`.
- Modify recording readiness/status owners as required by source-aware permissions.
- Extend `RecordingSessionTests.swift`, `CallIntegrationRecordingTests.swift`, `AutoRecordTests.swift`; add participant capture lifecycle tests with fake providers/recorders.

**Interfaces:**
- A session owns async source preparation and one-way direct → ordinary fallback; start/stop owners have a single in-flight operation and cancellation generation.
- The monitor exposes the configured provider's optional audio capability without spreading KTalk types into the application.
- Session manifests/meta merge participant recorder snapshots with ordinary `files`/offsets and capture periods. Pause covers both modes; normal fallback explicitly omits the KTalk privacy gate.

- [x] Assert direct start invokes neither `MicTrackRecorder.start` nor `SystemTrackRecorder.start`, including without OS microphone permission. Assert muted PCM/heartbeat does not trigger fallback.
- [x] Assert setup failure and mid-recording transport error start the ordinary pair once, retain direct files, record a transition and ignore KTalk mute. Permission/start failure preserves partial files and yields a visible stopped/error state.
- [x] Assert Stop/quit during preparation and fallback prevents late capture; confirmed call end does not start fallback; pause remains effective through transition; next session retries direct.
- [x] Run affected lifecycle suites to establish failing cases, implement transitions, then rerun them. Preserve existing automatic/manual-stop ownership and shutdown cleanup ordering.
- [x] Commit `feat(recording): switch KTalk sessions to ordinary capture on failure`.

### Task 6: Archive, recovery, playback and consumers

**Files:**
- Modify `Audio/TrackCompressor.swift`, `RecordingSession.swift` recovery, `Sessions/SessionInventory.swift`, `UI/MeetingPresentation.swift`, `UI/MeetingPlaybackView.swift` and MCP audio indexing only where needed.
- Extend `TrackCompressorTests.swift`, `MeetingPlaybackTests.swift`, recovery and MCP fixture tests.

**Interfaces:**
- `files` remains authoritative for physical audio. Participant archives retain one file per track with the original offsets and speaker mapping.
- Old two-channel archives remain readable. New metadata is atomically published before original files are removed.

- [x] Test real encoded audio from three participant tracks plus a fallback pair; every source survives compression, reloading and playback with its offset. Test interrupted archive write and crash recovery without final meta.
- [x] Test `keep_audio=false`, recording-only mode and retained audio for incomplete processing. MCP returns only validated referenced files; no filename derived from participant text.
- [x] Run those tests, implement the new archive branch and recovery metadata preservation, then rerun. Commit `feat(storage): preserve participant tracks across meeting processing`.

### Task 7: Dedicated KTalk settings and visible capture mode

**Files:**
- Modify `UI/ApplicationNavigationState.swift`, `ApplicationWindow.swift`, `SettingsPage.swift`, `SettingsController.swift`, `Settings/SettingsSchema.swift`, `Config.swift` and recording activity presentation.
- Update `docs/call-integrations.md`, `docs/configuration.md`; extend settings/navigation/documentation and activity tests.

**Interfaces:**
- Dedicated `.ktalk` destination, titled exactly «Интеграция с KTalk» / “KTalk integration”. Existing keys live there, not duplicated on General/Advanced.
- Readiness and source status distinguish direct KTalk, ordinary fallback and unavailable capture. Fallback explicitly states device mic is independent of KTalk mute.

- [x] Test page routing, preserving existing enabled/address settings, restart indication and both language labels. Test direct readiness without mic permission and actionable fallback failure.
- [x] Implement with existing AppKit/schema components. Keep diagnostic startup explicit and avoid extra configuration switches.
- [x] Run settings/navigation/activity/documentation tests. Commit `feat(settings): add the KTalk integration page`.

### Task 8: Integrated verification and delivery

**Files:** Add `docs/testing/2026-11-12-ktalk-participant-audio.md`; update this plan's checkboxes with actual evidence.

- [x] Run package tests, native loopback transport fixture, focused app suites and then the root macOS suite/build once integrated.
- [x] Build an isolated local app and inspect the native KTalk settings page and source-status flow. Do not replace the user's installed app or real recordings as a test fixture.
- [x] In a controlled KTalk room, use artificial media to verify multiple speakers, own track, mute/unmute including capture begun muted, participant replacement, minimized audio and final transcription/name association. Exercise CDP loss and fallback using controlled audio and verify saved samples, timestamps and visible status.
- [x] Verify shutdown leaves no injected capture or test CDP listener; restore the ordinary KTalk launch after the test. Record genuine runtime limits separately from synthetic test results.
- [x] Obtain independent whole-branch review, resolve findings, rerun only impacted checks, and report implementation, evidence and limits. Do not merge, publish or install a release without further instruction.

Runtime scope adjustment: the final app run used the local artificial track; remote multi-participant and successful ordinary fallback cases use controlled tests. See the explicit limits and measured PCM/ASR evidence in `docs/testing/2026-11-12-ktalk-participant-audio.md`.
