# Per-job macOS diarization: issue #29

The Journal retranscription sheet snapshots the existing local speaker model and threshold, or an explicit opt-out, into `transcribe.requested`. JSON jobs survive waiting, restart, configuration changes and retries; old engine-only markers remain readable. Version metadata records the choice. Settings and sibling jobs are untouched.

Existing model stores and generation fingerprints are reused. The sheet checks model files, platform/engine compatibility and the bundled Nemotron helper before queueing; execution checks again. Missing models are environmental failures and cannot retire a recording. A cloud service retains its own speaker-label behavior. Selecting a local model requires a local transcription engine.

Retranscription retains previous transcripts, names and summaries as versions. The new generation drops remote manual names, preserving the reliable local `me` identity. Pending replacements cannot be consumed by a stale speaker retry or skip.

## Automated evidence

Regressions cover all three model IDs; frozen threshold/model after config changes and a fresh coordinator; independent jobs in one queue; explicit opt-out with global diarization enabled; missing/cancelled model preparation; repeated missing-model failures; inference error/cancellation followed by restart with global diarization off; manual retry; legacy cloud/auto and malformed requests; incompatible speaker caches; old-version preservation; no remote-name transfer; and the AppKit selection controls.

The original snapshot regression failed because the marker contained only an engine string. Review regressions reproduced lost restart jobs, retired missing-model jobs, manual model/threshold substitution, a stale retry consuming a replacement, and stale skip removing raw input. These failures were checked before their respective fixes.

Local checks:

- `swift test --filter 'RetranscriptionDiarizationTests|SetupFormBehaviourTests.nemotronModesShareOneDownloadWithoutEnablingEachOther|DiarizationLifecycleTests|TranscriptVersionsTests|RetranscriptionTests'`: 78 tests in 5 suites passed; `/tmp/verbemo-29-focused-final.log`.
- After the mono-import badge fix, `swift test --filter 'MeetingPresentationTests|RetranscriptionDiarizationTests'`: 22 tests in 4 suites passed; `/tmp/verbemo-29-last-tests.log`. These sets overlap.
- A full serial run exercised 1,103 tests in 156 suites and failed only the existing shared Nemotron download UI timing test (two assertions). That exact test passed in the focused run above. This full local run is not claimed as passing; `/tmp/verbemo-29-full-final.log`.
- Read-only review identified the retry/restart/legacy availability cases above; subsequent review found the important findings closed. No Windows app code changed.

## Native runtime evidence

The separate ad-hoc application `.build/Verbemo-Issue29.app` uses bundle ID `name.ekho.verbemo.issue29` and pins `CFFIXED_USER_HOME` to `.build/issue29-home`. Auto recording, calendar reads, live recognition, speaker naming and summary generation are disabled. Input is 11 seconds of locally generated Russian speech (Milena), with an initial synthetic transcript and summary. Public Nemotron model files are cloned into this disposable profile; no personal recordings, credentials or paid service calls are used.

Computer Use verified:

- Missing LS-EEND AMI blocks the confirmation button and points to Files and Models.
- Installed Nemotron 3 becomes available after verification.
- Selecting Nemotron 3 with global diarization off persists that model and threshold 0.6. The saved job resumes after quitting/reopening the isolated app. Actual Nemotron 3.5 ASR and Nemotron 3 diarization produce four timed Russian segments and one confirmed speaker, with no rejected turns.
- Selecting Off with global diarization on creates a separate completed version without local diarization state; global enablement remains true.
- The initial synthetic transcript remains selectable and readable in the versions menu.

Local screenshots are under `/Users/ekho/.codex/visualizations/2026/10/22/01a16546-334b-7d42-b061-3aea832c6b18/diarization-*.png`. The real-model receipt is `/tmp/verbemo-29-real-receipt.json`.

LS-EEND AMI and Community-1 use synthetic/injected runtimes in automated checks. Their actual model inference, physical recording, accuracy on natural meetings, full VoiceOver speech and Windows runtime were not exercised. The Windows app source is unchanged. This report distinguishes native runtime checks from cross-platform CI/package checks and unsigned preview publication.
