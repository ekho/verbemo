# macOS cosmetic follow-up, 13 November 2026

Scope: #105, #111, #113, #114, #117, #118, #120, #121. Native AppKit
presentation only; existing search, assignment, playback, calendar and settings
actions remain in their current owners.

## Control inventory (#117)

| Surface | Result |
| --- | --- |
| Library and in-meeting search | Existing search field moved unchanged to `StudioSearchField`; shared with calendar search |
| Calendar picker, both entry points | Same `CalendarEventPicker` in `NewRecordingSheet` and `MeetingLibraryController`; Studio search, borderless native choice, adaptive date frame, autohiding native scroller |
| New recording title | `StudioTextField` uses the existing Studio input bezel, palette and height |
| Email entry | Same Studio text field; validation and add/remove actions unchanged |
| Schema-based single-line text, number and list settings | Same Studio field; native settings popup uses the borderless presentation of the version selector |
| OpenAI-compatible/Ollama URL and model fields | Same Studio field; existing delegates and validation retained |
| Transcript version selector | Existing reference appearance retained |
| Speaker name/participant combo | Existing native editable combo and full-width option menu retained |
| Passwords and multiline vocabulary | Specialized native editors retained, including masking and multiline sizing |

No new dependency or alternate calendar implementation. The root package targets
macOS 14.2; local compilation uses Xcode 27.2 / Swift 6.4.2.

## Automated checks during implementation

- Final `swift test --no-parallel`: 1487 tests in 202 suites passed (256.019 s).
  The completion marker was checked in addition to the process exit status.
- `python3 Tests/scripts/test_independent_product.py --all`: passed.
- Transcript layout, editing and reading: 32 tests passed.
- Library: 4 tests passed, including overlay and legacy scrollers at 220/400 pt,
  long titles, scrolling and selection. Row text stays clear of the scroller.
- Calendar, recording draft, settings navigation, workspace: 61 tests passed.

The opt-in `CalendarAcceptanceTests` uses synthetic events, meeting folders,
long names, a silent audio fixture and sandbox configuration. It does not read
the user's calendars or recordings, launch providers, or capture microphone/system audio.
English and Russian entry points permit separate interactive runs.

## Native UI acceptance

Computer Use exercised the actual AppKit views in a separate, ad-hoc signed
`Verbemo Cosmetic Review.app`. A temporary host loaded the test bundle and invoked
`CalendarAcceptanceTests.interactiveJournal` inside an AppKit event loop, with the
language scope covering both the fixture task and native events. The temporary
launcher is excluded from the product and from the final test sources. The copied
SwiftPM helper alone exited before completing the fixture; those launch attempts
are not counted as successful acceptance runs.

Both completed runs used a fresh `Home.process` sandbox. The installed app was
not replaced. Screenshots and Accessibility dumps contain synthetic content only.

| Scope | Observed result |
| --- | --- |
| #105 | No redundant library heading; search, filtering control, selection and scroll remain available. The library retains an Accessibility group name. |
| #111 | Pencil and speaker name stay aligned with long names; editor opens by click and Space, Return applies an edited name, Escape cancels. Clicking `00:06` changes playback to six seconds and starts the silent fixture. |
| #113 | Toolbar, workspace, inspector and status dividers follow the same Studio line color in light and dark appearances. |
| #114 | Native library scrolling works at the pane edge with long titles; text remains clear of the scrollbar in a narrow window. Overlay and legacy geometry are separately covered by the automated library test. |
| #117 | Search, recording title, email, URL/model fields and popup controls use the shared presentation. Paste, Tab, Return and focus rings work. A synthetic email is added with Return; a long model name is preserved after leaving its field. |
| #118 | Calendar heading, inset date control and framed results inspected in the real popover. Search, no results, date increment, twenty long results, keyboard scrolling to the last row and Return selection work. The same picker was exercised from the inspector and new-recording sheet. |
| #120 | Processing labels are visibly heavier than values; disabled and Ollama configurations were inspected. The existing configuration-driven text assertions still pass. |
| #121 | Inspector starts with the calendar chooser and close button, without the redundant headings. Link, unlink, close and reopen work. The inspector retains its Accessibility group name. |

Russian and English windows were inspected in both appearances. Russian narrow
layouts were exercised down to a 760 pt window; the inspector switches to the
existing compact presentation and the transcript stacks its metadata above text.

The two [RU](evidence/2026-11-13-cosmetic/ru-result.json) /
[EN](evidence/2026-11-13-cosmetic/en-result.json) fixture results were checked with
assertions: each has one recording draft, the original meeting title, the manual
speaker name `Имя вручную`, and both transcript versions. Calendar linking and
unlinking in the RU run left no calendar metadata attached to the meeting.

### Screenshots

- [RU dark transcript](evidence/2026-11-13-cosmetic/ru-dark-transcript.jpg),
  [speaker editor](evidence/2026-11-13-cosmetic/ru-dark-speaker-editor.jpg),
  [linked inspector](evidence/2026-11-13-cosmetic/ru-dark-linked-inspector.jpg).
- [RU light calendar results](evidence/2026-11-13-cosmetic/ru-light-calendar-results.jpg),
  [narrow transcript](evidence/2026-11-13-cosmetic/ru-light-narrow-transcript.jpg),
  [narrow inspector](evidence/2026-11-13-cosmetic/ru-light-narrow-inspector.jpg),
  [library scrollbar](evidence/2026-11-13-cosmetic/ru-light-library-scroll.jpg).
- [RU settings inputs](evidence/2026-11-13-cosmetic/ru-light-settings-inputs.jpg),
  [new recording](evidence/2026-11-13-cosmetic/ru-dark-new-recording.jpg),
  [long selected event](evidence/2026-11-13-cosmetic/ru-dark-long-event.jpg).
- [EN dark transcript](evidence/2026-11-13-cosmetic/en-dark-transcript.jpg),
  [light transcript](evidence/2026-11-13-cosmetic/en-light-transcript.jpg),
  [model inputs](evidence/2026-11-13-cosmetic/en-dark-model-inputs.jpg),
  [new recording](evidence/2026-11-13-cosmetic/en-dark-new-recording.jpg).

Accessibility labels and keyboard behavior were checked; spoken VoiceOver output
was not. Real audio capture, EventKit access, provider execution and Windows were
not exercised by this macOS presentation-only change. The silent playback fixture
does not establish microphone or system-audio acceptance. The GUI run used the
host's existing scrollbar preference; both scrollbar styles were tested through
AppKit geometry assertions, without changing the user's system preference.
