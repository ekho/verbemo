# Calendar selection implementation plan

**Goal:** One calendar checklist controls all macOS event consumers.

**Architecture:** Extend the existing config schema and filter CalendarWatcher's
EventKit query. Add a small native settings view using the existing layout and
config observation helpers.

**Spec:** ../specs/2026-10-26-calendar-selection-design.md

## Tasks

- [x] Add a failing settings test for the default all-calendars control.
- [x] Add `calendar_ids` to Config.Key, SettingsSchema, Config and documentation;
  preserve the distinction between absent and empty, and reject malformed values.
- [x] Filter the calendars passed to EventKit, returning no events for an empty
  result. Test bestMatch, justStarted, meetings and search at that boundary;
  resolve continues to use the same filtered search.
- [x] Add CalendarSettingsView to the calendar page: native checkboxes, account
  names, all/explicit modes, permission/empty/missing states, write errors, and
  inventory refresh. Test actual control actions and persisted values.
- [x] Add the same permission button and checklist to initial setup. Share the
  runtime CalendarWatcher, remove automatic permission requests, and test startup,
  explicit grants and selection persistence between both screens.
- [x] Run focused and full Swift tests; inspect narrow/wide native layout with
  synthetic data and report separately from live calendar acceptance.

## Review focus

Permission follow-up: remove startup/search/recording-form requests, share one
CalendarWatcher between runtime, initial setup and settings, and test that only
explicit permission-button actions request access. Both initial setup and calendar
settings offer the same checklist; already granted access works without prompting.

Empty or unavailable selection must never cause an unfiltered EventKit query.
Duplicate titles and renamed calendars must preserve identifier-based choice.
Invalid config must not silently enable every calendar. Failed writes must not
leave a checkbox claiming an unsaved selection. Reopening settings must reflect
new calendars and externally changed settings without altering saved meetings.
