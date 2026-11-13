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
