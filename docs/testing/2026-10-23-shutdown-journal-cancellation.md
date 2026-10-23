# macOS shutdown and Journal cancellation (#7 / #30)

This branch implements both consumers of the merged #42 lifecycle. Acceptance is
reported separately below. Windows source and runtime, merge and release are outside
this change. Upstream safe-quit attribution is in [history](../history/2026-10-23-safe-quit-upstream.md).

## Automated verification

The serial Swift suite runs with `VERBEMO_REQUIRE_LOCALVQE=1`; the final delivery
run passed **1,162 tests / 171 suites in 133.113 seconds**, including the two
AppKit request-gate regressions (`/tmp/verbemo-7-30-delivery-full.log`). Opt-in UI galleries and
external/native-model checks remain explicitly skipped; the real Whisper check
below is separate from these tests.

| Issue | Deterministic coverage |
| --- | --- |
| #7 | Admission closes before capture stop; original handoff and live transitions are awaited; an older retired preload cannot outlive finish; running cleanup blocks exit; repeated requests prepare/reply once; the outer request gate rejects reentrant AppKit terminate and resets after a declined quit; committed Finder recycling releases its claim before completion; an unanswered OS permission does not gate exit or open Settings afterward. |
| #30 | Waiting cancellation never starts; running cancellation stays visible through cleanup; canonical session/run targeting excludes general work and foreign claims; two meetings, repeated clicks, selection/window changes, simultaneous runs and newer generations stay isolated; completed/cancelled/failed results remain distinguishable after entry removal; quick later runs invalidate both pending callbacks and an already displayed old result. |
| Integration | Existing #28/#29/#42 tests exercise queued/direct ASR/diarization, automatic/manual summaries and sweep children, import/staging and summary-sheet cancellation, shared download consumers, serial engine/cache reuse, preservation of source audio/published and archived versions/prior summaries/manual names/per-run requests, explicit retry and later recovery without cancellation consuming attempts. |

The new regressions were checked red before green. Deliberately removing the
admission/live/handoff/Finder barriers produced five failed assertions. Permission
fixtures reproduced both waiting forever for an OS reply and opening Settings
after stopping. Journal fixtures reproduced swallowed errors reported as success,
a new run hidden between polls, and a stale already displayed outcome after a fast
successful retry. `python3 Tests/scripts/test_independent_product.py --all` passed;
`python3 -m unittest discover -s Tests/scripts -p test_package_metadata.py -v`
passed all three metadata tests. `git diff --check` passed.

## Isolated native environment

QA bundle: `/tmp/verbemo730-smoke/Verbemo-QA730.app`, identifier
`name.ekho.verbemo.qa730`, isolated `CFFIXED_USER_HOME` under the same directory.
It uses the final Swift debug executable and unchanged bundled native frameworks,
is ad-hoc signed and strict-verified. Final signed executable SHA-256:
`562256566811c5ca9ecd519da320f0ec3baf5a5d9d7aa87028343ed9989105cd`.
This is a development smoke bundle, not a universal release-package claim.

Auto-record and calendar are off. All meeting names, transcripts and summaries
are fictional; audio comes from macOS `say`, repeated into an 18:27.51 mono WAV.
Provider checks/generation use isolated fake Codex/Claude commands; real API keys
are empty. No user recordings, working app or clipboard were modified. No copying
or pasteboard action was used. GUI actions used Computer Use against the QA app.

## #30 native results

- The independent B meeting offers no cancel action while A owns a sweep-child
  summary operation. Selecting A exposes `meeting.cancel-processing`.
- Cancel was exercised on both explicit finish-processing and automatic sweep
  work. The explicit path showed the disabled `Отменяется…` button and status
  before a cancelled result. Completion retained the old summary and transcript.
- The final sweep-child run's directly launched fake child PID 75715 exited,
  `.transcribing.json` disappeared, and SHA-256 checks retained A's metadata,
  transcript JSON/Markdown and old summary, plus all four B artifacts. Receipt:
  `/tmp/verbemo730-smoke/final-cancelled.json`.
- Explicit retry selected Codex for one summary in the existing #28 sheet. The
  fake child PID 76418 finished, the new summary appeared, and the old cancellation
  status disappeared. A's transcript and B's complete artifacts stayed unchanged;
  B's old summary was also inspected in the actual window. Receipt:
  `/tmp/verbemo730-smoke/final-retried.json`.

The first UI connection stalled long enough for the initial fake-provider request
to time out; that attempt is not cancellation evidence. A later smoke caught an
old cancellation status surviving a fast successful retry. It was reproduced by a
regression, fixed, and the completed flow above repeated on the final binary.
Fake CLI evidence proves real GUI/subprocess/claim behavior, not a Codex service
response, cloud inference or diarization quality. Selection/window-close races
and shared downloads have deterministic evidence, not a claimed physical call test.

## #7 native results

Whisper model: `large-v3-turbo-q5_0`, official pinned 574,041,195-byte model copied
into the isolated home. Host: macOS 26.7.1, arm64. Each counted inference exit has
an actual sample containing `whisper_full`; the samples also show
`whisper_encode_internal` and `ggml_metal_synchronize`. The runtime used Metal;
the optional Core ML encoder was absent and was not the tested route.

| Route on final binary | Result / receipt |
| --- | --- |
| AppKit Command-Q during real inference | PID 75531 exited; no claim/transcript, original WAV hash retained, no transcription attempts/failure marker, no new crash report. `guarded-cmdq.json`, `ui-cmdq.sample`. |
| SIGTERM immediately after an inference sample | PID 74678, same preservation/cleanup checks passed. `guarded-term.json` and `.sample`. |
| SIGINT immediately after an inference sample | PID 74729, same checks passed. `guarded-int.json` and `.sample`. |
| Repeated SIGTERM, SIGTERM, SIGINT during inference | PID 74607, all signals requested; same cleanup/preservation checks passed. `guarded-repeat.json` and `.sample`. |
| Idle Command-Q | Process exit checked after the summary flow and before the inference tests. `idle-quit.json`. |
| Recovery next launch | After the final Command-Q, the same pending recording (without resetting the fixture) entered real Whisper inference on PID 77381. SIGTERM then passed the same cleanup/preservation checks. `guarded-recovery.json`, `.sample`, `.stderr`. |

All receipts above are under `/tmp/verbemo730-smoke`. They compare new crash
reports against the retained earlier failing test, not against an empty directory.

The initial repeated-signal smoke reproduced a real SIGABRT in Metal static
teardown, with a stale claim. The crash belonged to QA PID 71719. A minimal
AppKit probe established why: a second `terminate` during a deferred quit calls
`exit` without consulting the delegate again. `VerbemoApplication` now guards
that outer entry. The same native probe changed from `request2 → willTerminate`
without cleanup to `request2 → cleanup complete → willTerminate`, and all final
Whisper runs above passed. That earlier failure is retained, not counted as passing.

## Unverified acceptance and blockers

- **Dock Quit:** Computer Use could not bind to `com.apple.dock` and returned
  `timeoutReached` after 206.6 seconds. The app had completed its synthetic work
  by then, so that attempt is not a Dock-during-inference pass. The shared AppKit
  entry, principal class and reentrant behavior have the separate evidence above.
- **Physical capture/live:** no isolated synthetic microphone input was configured.
  The recorder follows the system input; changing the shared route could disturb
  the user's working recorder. No physical capture/live or real active-call test
  was performed. Handoff/retiree behavior has gated deterministic tests instead.
- No real cloud inference, Community-1/Nemotron inference, recognition-quality,
  full VoiceOver or Windows runtime acceptance is established here. No signed
  release or preview publication was requested or performed.

Issues remain open for these explicit acceptance gaps. CI must validate the final
PR head's tests and universal build separately from this local debug/native evidence.
