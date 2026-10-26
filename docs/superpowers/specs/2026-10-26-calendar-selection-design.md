# Calendar selection on macOS

The user requested a choice of calendars in settings and confirmed one shared
selection for automatic matching, manual event selection, and calendar recording
triggers. Existing saved meeting metadata is not modified.

## Approach

Use a native checklist on Settings → Calendar. Show each calendar's title and
account, and persist EventKit identifiers rather than names. Filtering once in
CalendarWatcher's event query keeps all three consumers consistent; separate
per-consumer lists would add settings the user did not request.

`calendar_ids` is an optional array: absent means all calendars, including new
ones; an explicit array allows only those identifiers; `[]` means none. An
invalid value must not broaden access. Changes apply to subsequent queries
without restarting. The UI offers an explicit all-calendars checkbox and
individual calendar checkboxes. Selecting all individual rows still preserves
an explicit selection. Unavailable identifiers are retained, with a notice;
never silently substitute another calendar with the same title.

Calendar permission is requested only by a button on the initial setup screen
or Settings → Calendar. Both screens include the same calendar checklist.
Startup, opening either screen, the recording form, and event searches must never prompt. Already
granted access works immediately; runtime and settings share a CalendarWatcher
so a newly granted permission is usable even while EventKit reports a stale
`.notDetermined` status. Reuse the existing calendar permission row and refresh
on reopening either page, access changes, and
EventKit notifications. Missing permission and empty calendar lists have clear
states. Failed config writes restore the saved choice and show an error.

This is macOS-only: Windows currently has no calendar integration. No new
dependencies, calendar writes, migrations, release, or installed-app replacement.

## Verification

Test the EventKit query boundary, empty/unknown/malformed selections, unchanged
defaults, settings persistence and failed writes, and fresh calendar inventory.
Run focused tests, the Swift suite, and inspect the native settings layout with
synthetic calendars in an isolated profile. Live EventKit acceptance is separate.
