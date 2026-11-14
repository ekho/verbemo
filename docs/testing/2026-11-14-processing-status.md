# macOS processing presentation: #104, #110, #119

Base: `eb066f906eab69d5efdc24e962fbd68c17487aab` (`master`, 0.23.6),
including the merged post-recording error and layout changes.

## Scope

- #104: shared stage symbols and accessible badges in the meeting list and
  inspector; only a running registered operation animates. Waiting, cancellation,
  failures and completed results remain static. Reduce Motion disables the pulse.
- #110: empty result tabs describe the selected version's real stage. The summary
  tab uses the existing guarded summary action and provider sheet. Saved and
  archived materials remain readable during another version's processing.
- #119: diarization status, total/confirmed speaker counts and recovery actions
  belong to the transcript group. Reasons wrap, and unfinished diarization is
  not labelled ready. Archived versions cannot retry the current version's work.

The operation registry carries an optional artifact directory for presentation;
claim, cancellation, shutdown, audio retention and processing ownership are unchanged.

## Automated checks

Host: macOS, Swift 6.4.2 / Xcode 27.2. Tests use isolated homes and synthetic audio.

```sh
swift test --build-system native --scratch-path .build/index-build --no-parallel
```

Final whole-suite result: **1499 tests in 206 suites passed**, 289.985 seconds.
The optional WindowGallery suite remained skipped. An earlier whole-suite run
exposed one obsolete flat-row layout assertion; the final run includes its
adaptation to the grouped inspector and the unreadable-state regression test.

Focused checks cover real registry stage transitions, direct summary work,
cancellation, target-version preservation, one guarded provider sheet, saved
materials across meeting/version switches, failed/skipped diarization, inaccessible
saved state, speaker counts, wrapped reasons, layout and Reduce Motion.

## Native GUI checks

A temporary application loaded the test bundle and the real `ApplicationWindow`,
`MeetingLibraryController`, `TranscriptionCoordinator` and status bar. Its homes,
recordings, recognizer, diarization runtime and summary provider were isolated
fixtures. No installed app or user recordings were changed.

Observed with Computer Use:

- Russian UI at 1100×720 and 760×600 points; light and dark appearance. English
  summary tab and disabled/enabled action at 760×600. Selected and unselected list
  rows retained legible distinct status symbols.
- Actual coordinator transcription showed a document symbol and matching tab,
  inspector and status-bar activity. Summary waited for transcription.
- Synthetic diarization failure retained the transcript, showed the reason and
  `Speakers: 1` together, and stopped activity. Retry reached the injected runtime;
  skip continued to summary work. The long reason wrapped in the narrow inspector.
- Manual summary opened the existing provider sheet. Return started the injected
  provider. Activity appeared in the list, tab, inspector and status bar; cancellation
  returned to a static state and re-enabled the action.
- Completing the injected summary produced readable text, a ready list icon and
  zero running tasks. Switching meetings and current/archived versions displayed
  the corresponding saved summaries. Completed diarization showed two confirmed
  speakers and three transcript speaker identifiers without a duplicate footer.
- Accessibility names/help and keyboard submission were observed in the native
  accessibility tree. The retry/download wording reflects absent fixture models;
  no model download was performed.

## Limits

No real microphone/system capture, native recognition, downloaded diarization
model, paid/cloud inference or spoken VoiceOver session was exercised. Reduce
Motion was tested through the injected preference, without changing the user's
system setting. Windows sources were not changed or tested. No install or stable
release was performed.
