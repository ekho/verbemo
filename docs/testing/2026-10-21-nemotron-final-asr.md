# Shared Nemotron ASR — macOS acceptance

## Contract

The live and final-transcription settings are independent. Both use `NemotronModelStore`, the existing `FluidAudio/nemotron-multilingual/<latin|multilingual>/1120ms` directory, and FluidAudio’s language-to-directory mapping. No 2240/4480 variant is introduced. A ready cache returns immediately without invoking the downloader.

`SharedDownloads` is reused with progress as a generic payload. Requests are coalesced by the canonical physical variant path. Each caller reserves a cancellable consumer while holding the registry lock, before suspending; only the last cancellation stops the transfer. This also protects a consumer that joined but has not yet begun awaiting the result. A file lock outside the resource directory also prevents different processes or a deletion from writing the same cache concurrently. An incomplete marker survives failure or interruption. Repair clears FluidAudio’s completion marker and retains complete assets for its existing downloader to reuse.

Final ASR reads ten-second PCM buffers, processes them without real-time pacing, and calls `finishWithTokenTimings()` for the final partial chunk. FluidAudio token timings become word timings and existing Verbemo segment grouping. Invalid times are not fabricated: the existing per-turn diarization fallback remains available. Each track/pass has its own manager and mutable decoder state. Provenance includes Nemotron 3.5 ASR, physical variant, 1120 ms, and the language prompt in the processing fingerprint.

The Files and Models page contains one shared ASR resource. Disabling either mode does not delete its files. Deletion uses the same lock and refresh notification as downloading; the existing settings guard prevents deleting a selected/active model. Nemotron 3 diarization is a different model and remains a separate resource.

## Automated evidence

- Shared-store tests cover existing live cache reuse, a fresh store instance/restart surrogate, physical language aliases, concurrent callers/progress, cancellation with a remaining consumer, full cancellation, errors, repair preserving model-file identity, incomplete assets, deletion readiness, and a second process finishing under the lock.
- Engine tests cover bounded buffers, independent passes, final flush, native times, invalid timing fallback, resolver/config identity, new/imported session processing with injected diarization, and retained transcript versions.
- AppKit settings tests cover selection-triggered fetching, live/final independence, one operation, readiness in both controls, one catalogue entry, and shared deletion updates.
- Opt-in real-model tests require an explicit model root and fixture audio. They never infer a personal recordings/cache path. Ordinary suite runs skip these checks.

## Runtime fixtures and limits

Audio is generated locally using macOS Milena, not taken from personal meetings. The short fixture is 24.726 seconds; the long fixture is 2345.434 seconds (39:05). Model files were already present from live transcription: 22 files, 664,144,423 bytes, only `multilingual/1120ms`. Inode, modification time, size, and SHA-256 snapshots are compared after runtime checks.

The short real-model run produced eight segments and fifty native-timed words, including the last phrase. Cold preparation plus recognition took 17.56 seconds. This is evidence of working inference and timestamps, not an accuracy benchmark. A wording error in the synthetic transcript (“сохранения” for “сохранение”) was observed.

### Completed automated checks

- Focused integration/store/AppKit subset: **71 tests passed**, 11.496 seconds (`journal-nemotron-core-tests-4.log`).
- Full suite with the real dual-stream live check: **1014 tests in 143 suites passed**, 156.247 seconds (`journal-nemotron-final-tests.log`). The real live case took 53.545 seconds and verified both speakers, pause/resume blocks and final cleanup. Optional screenshot galleries remain skipped.
- Real long final-ASR check: **593 segments, 4061 words**, including “Приемка завершена” at the end, in **50.247 seconds** for **2345.434 seconds** of input (`journal-nemotron-full-runtime.log`). Every word has a positive native-timed interval within the resampled audio clock; source/resampled length tolerance is one 16 kHz sample. The full run containing this check had only the old identical-audio live-fixture failures, corrected in the subsequent full pass above.
- The model snapshot after short/long final and real live processing exactly matches the initial snapshot: all **22 files / 664,144,423 bytes** have the same paths, inode numbers, modification times and SHA-256. There is still only `multilingual/1120ms`.
- `git diff --check` passed. No dependency update.

### Validation corrections

The first full run caught omitted engine vocabulary/localization allow-list entries, a deletion API test caller and the explicit retranscription menu list; these were fixed. The first long check used a source-duration comparison without allowing the final resampling sample (a 37-microsecond difference); the assertion now uses one 16 kHz sample. The initial live fixture fed identical speech to both sides, so the existing echo filter correctly hid one side. It now feeds different synthetic replies, and the real check passes. Logs for these attempts are retained with the final results.

Evidence is under `/Users/ekho/.codex/visualizations/2026/10/21/01a15cf6-bbab-7133-b45a-14151459b489/native/nemotron/`. Generated audio remains under `/tmp/verbemo-nemotron-acceptance/`; the reference scripts and recognized JSON are retained with the evidence.

## Packaged native acceptance

The ad-hoc universal Journal preview used the existing isolated `journal-preview-home`, not personal recordings or the installed app. Summaries and speaker naming were disabled during inference checks; no cloud ASR or LLM requests were needed.

- Selected Nemotron in Settings → Transcription with live transcription off: the final selection persisted, live remained off, both controls immediately reported the existing 664 MB cache.
- Restarted the app; final Nemotron remained selected and ready. Enabling live transcription immediately reused the ready resource. Files and Models showed one Nemotron ASR resource and its total size once; Nemotron 3 diarization remained a separate model.
- Imported `short-ru.aiff` through the native file picker and processing queue. Actual Nemotron ASR + Nemotron 3 diarization produced 6 final segments, 50 native-timed words and one confirmed speaker, with the final phrase preserved.
- Published a completed synthetic manual session with distinct microphone/system PCM tracks and a 1000 ms system-track offset. The app's launch queue processed it with actual ASR/diarization: 14 final segments, two confirmed speakers, both final phrases preserved, and chronological segment times within the meeting. This checks the completed-recording path, not live microphone/screen capture hardware.
- Both sessions show version history with Nemotron engine/model provenance. Word times survive in diarization artifacts. The shared player streams the archived stereo meeting once, retaining track offsets.
- Native acceptance exposed unconnected Journal timestamp labels. They are now accessible buttons connected to the existing meeting player, disabled without audio. Clicking `00:10` in the imported transcript yielded playback position `10.058657941` and the Pause action in AX. No second player/export was added.
- All 22 model files still match the pre-run inode, path, byte size, modification time and SHA-256 after final/live inference and GUI restart. Only `multilingual/1120ms` exists.

`native-results.json`, screenshots and accessibility snapshots accompany the logs in the evidence directory. Network failure, cancellation and deletion are covered with injected test downloads and disposable miniature caches; the user's 664 MB resource was not deleted to manufacture another download.

### Final regression checks

- After timestamp playback: **48 tests / 6 suites passed**, 14.911 seconds (`journal-nemotron-playback-tests.log`).
- Review found a cancellation race between joining a download and registering its continuation. Consumer reservation is now atomic with lookup. A deterministic regression test cancels one consumer before the second starts waiting.
- Final full suite after that fix: **1016 tests / 143 suites passed**, 109.254 seconds (`journal-nemotron-complete-tests.log`). Optional real-model tests are skipped in this ordinary final run; the earlier actual short, long and dual-stream checks above remain separate evidence.
- The only subsequent source adjustment fixes the Files and Models name-column width so the long Nemotron label cannot collide with the size. Verified in the packaged GUI.

No long natural Russian meeting, noisy conversational accuracy benchmark, or new physical microphone/screen-capture recording was checked. The 39-minute Russian test is synthetic speech; it establishes chunked inference, flushing and timing behavior, not real-world recognition quality.

The final executable identity is recorded in `delivery.json` beside the evidence. All temporary test preferences were restored to their original values. The two synthetic meetings retain manually authored explanatory summary text, explicitly labelled as such, so restoring automatic-summary preferences does not invoke a CLI or cloud model on startup; summary generation was not part of this check.

## Delivery boundary

This continues the Journal design acceptance. This validation itself did not authorize a PR. The subsequent explicit user request now authorizes committing the accumulated branch and creating a PR after #27. Merge, release and replacement of `/Applications/Verbemo.app` remain outside the task. The separate pinned-home `Verbemo-Journal.app` is the acceptance deliverable.
