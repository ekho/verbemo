# Current recording: meeting details and live-model recovery

## Behavior

- The active recording uses the Journal document and inspector. Opening it from
  the recording bar selects the active meeting and clears a conflicting filter
  or search. Saved meetings and Settings remain accessible during capture.
- At a wide window size, live text and meeting details are visible together.
  At the existing 760-point minimum width, the inspector button switches between
  the document and its details, as it does for saved meetings.
- The shared Rename action focuses the visible live title.
- Starting capture with missing model files does not initiate a network transfer.
  The live page offers an explicit Download model action instead.
- Enabling live transcription during capture, or choosing Download/Retry,
  downloads the shared Nemotron resource and proceeds to recognition in the same
  recording. Download progress is visible. Disabling live transcription cancels
  this consumer; a download needed by another consumer remains protected by the
  existing shared store.
- Sinks attach only when the recognizers are consuming audio. Live text starts
  from that point; it does not reconstruct speech from before model readiness.

## Verification

- Added regressions first: missing inspector, absent download action, and an
  explicit enable that never reached download/preload failed before the fix.
- Focused checks: 87 tests in 11 suites passed. The subsequent Rename and
  download-retirement checks passed 7 tests in 2 suites.
- Initial `swift test --no-parallel`: **1176 tests in 171 suites passed**, with
  23 opt-in skips. Log: `/tmp/verbemo-live-full.log`.
- Release-preparation review caught active-model progress resetting a saved
  summary's scroll position. A regression reproduced the reset before the fix;
  25 focused tests in 3 suites passed after preserving the selected document
  during unrelated active-recording updates. Independent re-review found no
  further issues.
- Final full run on the updated `0.11.1` base: **1177 tests in 171 suites
  passed**, with 23 opt-in skips. Log: `/tmp/verbemo-pr-final.log`. The full
  product-independence guard and 105 release/repository script tests also passed;
  script fixtures used `GIT_CONFIG_GLOBAL=/dev/null` to avoid inheriting the
  developer's GPG signing configuration in their temporary Git repositories.
- A separate ad-hoc-signed `Verbemo-Recording-QA.app` linked the compiled product
  objects into a native fixture with synthetic recordings and snapshots, a
  separate home, and no audio capture or network access. Computer Use verified
  the inspector, Download-to-progress and disable states, live text appearing
  without a resize, navigation through a saved meeting and Settings back to the
  active recording, and the inspector button at width 760.

## Limits

The GUI fixture simulates model progress and recognition output. Real model
download, CoreML inference, physical audio capture, and a natural meeting were
not rerun. The user's recording and model files were not modified. Windows
sources were unchanged and Windows checks were not run locally. These local
checks did not install or publish an application; release validation is separate.
