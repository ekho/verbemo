# macOS calendar context: #115 and #116

Base: `97b78c2` (`master`, 0.24.0), including merged PR #130
(`d4827f50193b832753c943dd82cf2d602702455f`).
Host: macOS 26.7.1, Xcode 27.2 / Swift 6.4.2; deployment target remains macOS 14.2.

## Invitees (#115)

The inspector uses the existing sorted `CalendarParticipant` values. A nonblank
name is the label; otherwise it uses the email, then a localized unnamed-invitee
label. A usable email produces a native Studio button exposed as an accessible
link, with the full address as its tooltip/help and a `mailto` destination.
Missing addresses produce ordinary text. Long links truncate inside the pane;
their full labels and addresses remain available to accessibility, and the full
address remains in the tooltip. Show all / Show less retain their existing state.

URL components and percent encoding keep recipient delimiters, query characters
and fragments inside the address, rather than introducing recipients or message
headers. Control characters do not produce a link. Activating a link delegates to
NSWorkspace; failure to open produces the standard system beep.

No participant IDs, sorting, self identities, manual voice assignments, stored
metadata or export formats change.

## Initial event position (#116)

Only opening the shared picker requests an initial scroll, after the current
asynchronous load completes. It never selects or associates an event.

1. For a saved recording, use its start time. For a new draft, use the instant
   the picker opens, leaving its existing date and suggestion rules intact.
2. Prefer an event whose half-open interval contains that instant (`start <= t < end`).
3. Otherwise minimize the distance to either interval boundary. Equal candidates
   retain the incoming list order; the existing link does not override time.
4. Search, date changes and ordinary reloads do not request another initial scroll.
   Cancelled loads cannot apply their result or scroll to a new context.

The current local-calendar query still determines the day, including overlapping
overnight events and daylight-saving boundaries. Ranking compares absolute Dates;
it does not reinterpret an event's time-zone label or change calendar integration.

## Automated verification

```sh
swift test --build-system native --scratch-path .build/index-build --no-parallel \
  --filter 'CalendarEventPickerTests|MeetingCalendarViewTests|MeetingCalendarMetadataTests|SpeakerParticipantMappingTests|OneToOneParticipantTests|NewRecordingSheetTests'
swift test --build-system native --scratch-path .build/index-build --no-parallel
```

The focused run passed 51 tests in 6 suites. It covers name/email/missing values,
encoded recipient targets, accessibility metadata/focus, 270-point link layout in
both appearances, expansion, identity order and existing manual mappings. Picker
checks cover delayed loads, no implicit selection, a distant existing link,
search/date/manual-scroll preservation, cancelled responses, empty results,
interval distance and ties, an overnight event on a 25-hour New York day, and the
new-draft path. Existing association, unlink, title and archive regressions pass.

The final full root run passed **1,508 tests in 209 suites** in 319 seconds;
29 opt-in or resource-dependent checks were skipped. The temporary UI entry point
was absent from this build. Packages/CallIntegrations was not changed.

## Native UI verification and limits

A temporary app loaded the test bundle and the real workspace, picker and draft
controllers. It used an isolated test home, 24 hourly synthetic events per day,
seven synthetic invitees and a saved recording at 18:15. The temporary entry point
was removed before the final full-suite build. No installed app, personal
recording, EventKit event, mail setting or real audio source was changed.

Computer Use/accessibility verified invitee labels and addresses, expansion and
collapse, selection with Down/Return, change/unlink of a saved association,
search, native scrolling and date increment, and the new-recording draft through
its stubbed start callback. The saved picker initially scrolled to y=824 with
row 18 visible and no selected row; the new draft positioned around opening time.
Changing the linked event to 23:00 and unlinking retained the manual speaker name.
Email activation was intercepted only in the fixture and recorded the synthetic
mailto URL; no mail client was launched.

RU/EN, light/dark and 760-point compact layout were exercised. Native AppKit view
snapshots showed bounded long values and the full seven-invitee list. Computer
Use's window raster was blank even though accessibility and AppKit view snapshots
were populated; compositor screenshots and a visibly rendered hover tooltip are
therefore not claimed. Tooltip values are covered by tests and accessibility.
Invitee keyboard focus is checked programmatically; this host's ordinary Tab loop
skips native buttons. Full Keyboard Access and spoken VoiceOver were not exercised.
Real EventKit sync, mail-client handling, audio and Windows were not tested.
