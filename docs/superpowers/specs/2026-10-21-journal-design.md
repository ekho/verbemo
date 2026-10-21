# Native Journal interface

The user approved applying the Journal prototype on 21 October 2026. The reference is `verbemo-journal.html` from the design conversation, with a sage meeting sidebar, warm paper document and optional inspector. Acceptance feedback replaces serif titles with the shared system font and removes the footer; active recording controls stay available above the document.

Implement in the existing macOS AppKit window. Preserve capture, import, versions, manual speaker names, calendar snapshots, playback, summary regeneration, deletion undo, model management, settings and onboarding. Do not replace native behavior with prototype data or rewrite processing. Windows and releases are outside this change.

The meeting list stays available while viewing settings or a live recording. Settings use horizontal page navigation in the main area. The document has Summary and Transcript tabs; people, calendar and processing state move to an inspector that remains reachable in a narrow window. Theme follows the existing persisted setting. Text, focus and accessibility remain native.

Acceptance revisions: Import has a visible button bezel. The clickable breadcrumb root is Meetings or Settings, without the product name. Summary generation belongs in the inspector; the meeting menu omits duplicate copy and summary-regeneration commands. One themed player sits below the title and above the result tabs, streams the whole meeting on its recorded timeline, and deduplicates archived stereo files. The calendar title opens the event; agenda and invitees are initially visible. Agendas over 100 characters stop at the last whole word within that boundary and expose Show in full. Up to four invitees appear initially with Show all for longer lists; the two disclosures expand independently.

Unavailable prototype functionality must visibly say **«Функция пока не реализована»** (English translation in English UI), with a separate implementation issue:

| Capability | Issue |
| --- | --- |
| Real microphone and system-audio levels | [#26](https://github.com/ekho/verbemo/issues/26) |
| Summary provider for one processing run | [#28](https://github.com/ekho/verbemo/issues/28) |
| Diarization model for one retranscription | [#29](https://github.com/ekho/verbemo/issues/29) |
| Cancellation of an individual processing job | [#30](https://github.com/ekho/verbemo/issues/30) |

Existing global configuration and retranscription engine selection remain functional. No fictional levels, completed work, identities, permission grants or processing destinations may be displayed as fact. Saved content retains its actual Markdown structure.

Acceptance: focused state/layout/placeholder regression tests, native build, and actual packaged GUI inspection with disposable synthetic recordings in both themes, including narrow width, settings, live view, missing features and core actions. Audio/cloud/model runtime acceptance must be reported separately from UI evidence.

Transcription-settings acceptance revision: group cloud and local models symmetrically under their switches, using the same bordered containers and option insets for speaker separation. Keep live transcription and meeting language in bordered blocks; reuse the language menu. More options is a disclosure row with a chevron, not a checkbox. A pending cloud-key editor can be closed with its switch and does not enable cloud processing before the key is accepted. Selecting a missing speaker model starts its download, with the existing progress, cancellation and retry controls; selecting a ready or already downloading model does not duplicate work.

Each cloud transcription card contains its own secure API-key editor. AssemblyAI, OpenAI and ElevenLabs retain separate existing key slots; choosing a provider restores that service's endpoint and key. Verification and errors belong to the field that submitted the key. A failed check preserves the saved key, and a late response cannot overwrite a newer edit or undo a later provider/cloud-switch choice. Stored secrets are not displayed in the editor or copied into configuration JSON.

## Standalone window removal during acceptance

`ApplicationWindow` is the only owner of an ordinary macOS app window. The old
`StatusWindow`, `RecordingsWindow`, `SettingsWindow`, `SetupWindow` and
`AboutWindow` implementations, fallback constructors and alternate layouts are
removed. Their active content lives in `LiveTranscriptContent`,
`MeetingLibraryController`, `SettingsController`, `SetupPage` and `AboutPage`.
Only controllers that present sheets receive the required existing host window.

The tray's Meetings command replaces Show window and Manage recordings. Settings
and About navigate within the same window. Recording, pause/resume, automatic
recording, import, Finder, conditional first-run/update actions and quit remain.
System pickers and confirmation/error sheets keep their existing behavior.

Tests and screenshot fixtures exercise the Journal pages; no legacy window is
recreated solely to retain an old test layout. Design acceptance remains open;
the subsequent explicit request authorizes a PR after #27, as recorded below.

## General-settings and sidebar acceptance revision

Remove the redundant Back to Meetings action and the configuration-file reveal
button. Use a native segmented selector for the settings sections, with a popup
at narrow widths. Theme, interface language and open-at-launch settings use the
same bordered containers as the other settings. Start at login uses the same
switch row as the adjacent menu-bar and Dock settings, with the existing
register/unregister operations. Keep recording guards, macOS approval handling
and recoverable errors; redraw the switch from the actual registration state.

The meeting sidebar has no date-group headings. Every row includes its own date,
time and duration. Import uses a full-height 40-point button.

The Summary section uses its heading switch as the sole off control. Remove the
Do not create a summary card; preserve the selected backend across off/on and
allow older backend=none settings to be enabled again from the switch.

Meeting hover and selection use the same row-sized rounded background. Hide
Summary/Transcript result controls when no meeting is selected, including an
unmatched search. Import centers its icon next to its title, like New recording.


## New-recording acceptance revision

The recording sheet uses a full-width editable name and one bottom row: Start with
an icon, Cancel with an icon, and a compact icon-only recording-settings button.
When calendar integration is enabled, reuse CalendarWatcher.bestMatch: prefer calls,
then the nearest start among ongoing events and starts within eight minutes;
exclude ended events. Present the selected event for confirmation on Start and
allow another event/date or no event. A custom title remains independent from the
calendar title and metadata. Keep a user's edited title when changing events.
Disabled integration, unavailable access or no match uses Recording <local date/time>.
Starting preserves the chosen event snapshot, agenda, participants and time zone
in the recording and final metadata. Settings and Cancel do not start capture;
concurrent recording dismisses the draft. The #27 revision below also supports
changing and clearing the calendar association after recording.


## Processing-inspector acceptance revision

Place retranscription and summary generation as icon-only buttons at the right
edge of their corresponding Processing rows. Keep their existing availability
checks, accessible action names, and tooltips. Remove the document action row and
the redundant From settings caption. Processing settings shows exactly three
labelled values: Transcription (configured model or cloud/local fallback),
Diarization (selected local model, built-in cloud diarization, or disabled), and
Summary (configured method or disabled), followed by Settings →.
Diarization is the primary term throughout the macOS interface; its settings
explain that it separates speech by speaker. Saved transcript provenance is not
presented as the current processing configuration.


## Exclusive transcription modes and Escape cancellation

Cloud and On this Mac are mutually exclusive. Enabling either disables the other;
both can remain off for recording without transcription. Keep the selected local
model and each provider's key when changing modes. Opening cloud setup without a
key disables local transcription and waits for key validation. When changing
between cloud providers, keep the last working cloud provider until the new key
is accepted. A delayed key response must not undo a later local selection.
Legacy auto configuration displays its primary available route without rewriting
settings merely by opening the page; the next mode selection stores one explicit
engine. Existing engine fallback behavior remains compatible with legacy files.

Escape cancels New recording even while its title field is being edited. Use the
same cancellation path as the Cancel button, including pending calendar tasks
and the single-completion guard; cancellation never starts capture.


## Calendar selection and chosen settings navigation

Issue #27 replaces the placeholder with one `CalendarEventPicker` in the saved-meeting inspector and New recording. The dropdown starts on the recording date; title search spans one year either side of that date and displays its range. `DD.MM.YYYY`, `YYYY-MM-DD` and `DD.MM` (recording year) search a specific local day, optionally followed by title words. Clear removes only the calendar association. EventKit access and event existence are checked before a selection is saved; the recording draft is checked again before starting. The persisted snapshot includes original time zone, agenda and invitees. Linking never renames the recording, maps voices, rewrites transcripts or removes manual names.

The user selected concept 1 with icons from concept 2: horizontal text tabs, a thin underline for the active section, and leading SF Symbols. At narrow widths the existing section menu remains available.

The subsequent explicit request authorizes committing all accumulated changes on `codex/verbemo-journal` and creating a PR after completing #27. It supersedes the earlier no-PR acceptance gate; merge and release remain outside this task.
