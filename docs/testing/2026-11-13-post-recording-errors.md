# macOS post-recording errors (#124–#126)

Base: `c9ff557` (includes cosmetic PR #127). Swift 6.4.2, macOS arm64.
Original recordings and the installed app/configuration were not changed.

## #124: input and recovery

The matching 82-second recording was available locally. Its saved transcript
contains 15 microphone (`me`) segments. Its saved system-track ASR has zero
segments. The diarizer consumes `diarization-source-them.caf`, the durable
system-track PCM after audio preparation, not the microphone transcript.

Both prepared tracks contain 1,323,024 mono samples at 16 kHz. The remote track
has 7,378 nonzero samples, peak 0.000030517578125 (one PCM16 step), RMS
0.000002278954. The microphone peak is 0.05673218, RMS 0.004971995. These are
signal measurements, not a claim about the intelligibility of quiet speech.

An isolated copy of the remote input was converted to PCM16 WAV and passed to
the installed local Nemotron helper with the cached Nemotron 3 model, `metal`,
`v3-offline`, JSON output and an empty offline model cache/index. It exited
successfully with zero segments. A local `say` speech control returned one
segment. The original input hash was unchanged. No audio or meeting text was
sent to a service or included in this repository.

`NemotronDiarizationRunner` translates an empty native result to
`noSpeechDetected`. The pipeline accepts that result as silence only for exact
digital zeros without recognized text. This input is nonzero, so the failure
is retained for a deliberate retry/skip. `failInference` records the first
failure as `pending`, with its reason and attempt count. The UI previously
displayed that as ordinary waiting and omitted it from attention indicators.

The fix distinguishes a failed attempt from an unstarted request in the
inspector, library and attention notice. Retry budgets, silence safeguards,
model behavior and saved data formats are unchanged. The original capture's
build and the source of the one-step residual signal are not established;
there is no evidence here of a KTalk or model defect.

Regression coverage reproduces the failed presentation before the fix, and
checks a speaking microphone plus nonzero remote track: failure, explicit
failed retry, unchanged transcript/source, reopening, explicit skip, retained
audio and subsequent summary through an injected local test backend. Existing
successful retry/version and cancellation tests remain in scope.

## #125: summary state

The original recording has no saved summary status or summary file. Its
unfinished diarization prevents `PostProcessor.outstanding` from admitting
summary work. The inspector previously described this as “Waiting: Preparing
summary”. Separately, any live session claim with ready text could make that
summary icon active, even during naming or diarization.

Summary presentation now reads the shared operation registry, including direct
operations outside the transcription queue. Only the running summary stage
animates. Queued work, cancellation, unfinished transcription/diarization,
speaker naming, an external writer, deferral and unstarted work have distinct
labels. The registry enters the summary stage at the call to the summarizer
and leaves it before cleanup; admission/access checks remain post-processing.
The library and inspector share this presentation. Waiting library icons show
a clock, including when there is no active queue entry.

Before the fix, the focused presentation tests failed ten assertions. Coverage
also checks actual manual summary generation and cancellation with a retained
previous summary, for current and archived transcript versions.

## #126: unavailable participant editor

The UI disables both free text and the dropdown while the selected transcript's
diarization is nonfinal. The save path independently enforces the same rule,
plus meeting ownership, queued retranscription and transcript freshness. The
original pending failure therefore explains the unavailable `me` field; it
does not establish a focus or persistence regression.

The Participants tab now explains the actual blocker (processing, queued
retranscription, unreadable state, or unfinished diarization). The same reason
is attached to the disabled field's tooltip/accessibility help. The existing
write guards are shared with this explanation and remain in force.

The regression test failed for missing explanation with `pending` and `failed`
states before the fix. `completed` and `skipped` already allowed editing. The
test covers both `me` and an ordinary speaker without a calendar, attempted
writes while blocked, preserved prior names, skipping, Return to save, Escape
to discard, and reopening. Existing tests cover calendar menus, selected
versions, one-to-one mapping, stale writes and save failures.

## Validation

On 2026-11-14, the complete standard root suite passed: **1493 tests in 203
suites**, 260.583 seconds, exit 0. Command:

```sh
swift test --build-system native --scratch-path .build/index-build --no-parallel
```

The first full run exposed one existing assertion for the old Russian summary
label; it was updated to require the explicit unstarted state, then the entire
suite was rerun successfully. Environment-gated native/model-download, calendar
acceptance and screenshot-gallery tests remained skipped by their normal gates.

Focused tests passed: 63 for the diarization/recovery change, 95 for summary
presentation/lifecycle, and 54 for participant editing and its existing callers.
The new tests were first run against the previous behavior and reproduced the
missing failure/blocked-state explanations.

Computer Use exercised the real `ApplicationWindow` and
`MeetingLibraryController` in an isolated native AppKit host loading the test
bundle. It used disposable synthetic audio, an injected no-speech diarizer and
a gated local summary backend; no external AI provider or real account was used.
The native host was needed because nesting AppKit's event loop inside the test
runner prevented asynchronous UI actions from progressing.

Observed through actual clicks and the accessibility tree:

- Pending failed attempt: explicit retry/skip guidance, static summary waiting
  state, empty queue, and disabled participant field with the same explanation.
- Retry: attempt count increased from one to two and the failure remained
  actionable. Skip: diarization became skipped, the real summary operation
  appeared as one running task, and participant editing explained the active
  processing lock.
- Completing the injected backend: summary became ready, queue returned to
  zero, and participant editing became available.
- Without a calendar: the `me` field accepted a name; Return saved it, Escape
  restored it after an unsaved edit, and the dropdown opened with “Not matched”.
- A new process reopened the same fixture and displayed the saved name and
  summary. Light appearance at 1100 points wide and dark appearance at 760
  points wide were visually checked. Accessibility names, disabled states and
  help were inspected; spoken VoiceOver output was not tested.

The fixture's prepared diarization sources and transcript remained byte-for-byte
unchanged after skip and naming. Normal successful cleanup compressed its raw
tracks into `audio.m4a`, retaining both channels and their metadata.

Limitations: no new hardware recording/call, no real cloud summary request,
no Windows runtime verification, no installed-app replacement or stable
release. Real-audio evidence is the isolated offline native diarizer probe
described above, separate from the deterministic UI/test backends.
