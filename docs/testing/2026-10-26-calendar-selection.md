# macOS calendar selection verification

Change: one calendar checklist on initial setup and Settings → Calendar controls
automatic meeting matching, manual event search/selection, and calendar-triggered
recording. Only the permission buttons request access. Base: `b599f90` (0.12.0).

## Automated checks

- The initial settings test failed because the all-calendars control was absent.
- Permission regressions also failed before the fix: reads requested permission,
  existing access needed an explicit request, and disabled features read events.
- Initial focused run: 71 tests across 9 suites passed, covering calendar queries,
  settings, persistence, unavailable calendars, malformed values, write failure,
  permission changes, and the screenshot fixture.
- Onboarding/permission focused run: 60 tests in 7 suites passed. Another run
  including both screenshot fixtures passed 22 tests in 4 suites.
- Full `swift test --no-parallel` after the onboarding/permission changes: 1198
  tests in 173 suites; 1176 passed and 22 optional tests skipped, no issues,
  exit 0 (194.219 seconds). Only the permission-row explanatory text was
  shortened afterwards to fit the narrow layout.
- Final focused run after that text change: 88 tests in 6 suites passed,
  including setup, calendar settings, startup, shutdown and both screenshot
  fixtures; exit 0 (26.564 seconds).
- Screenshot fixtures render light/dark settings at 680/500-point widths and
  initial setup at 1340/760 points, with permission absent or granted. They
  assert that long calendar titles do not widen the narrow settings page.
- Read-only review found a stale EventKit authorization-state issue and inaccurate
  malformed-value diagnostics. Both were fixed and re-reviewed. The permission
  and onboarding follow-up, including the shared grant state, had no findings.
- `git diff --check` passed.

New tests use temporary homes and an EventKit IO fixture. They do not save events
or calendars. Real watcher filtering, conversion, settings controls and config
writes run against synthetic input. Existing saved meeting metadata is untouched.

## Evidence and limits

Logs: `/private/tmp/verbemo-calendar-focused.log`,
`/private/tmp/verbemo-calendar-onboarding-focused.log`,
`/private/tmp/verbemo-calendar-onboarding-shots.log`,
`/private/tmp/verbemo-calendar-onboarding-full.log`, and
`/private/tmp/verbemo-calendar-onboarding-final.log`.

PNG files are in the task's visualization directory under `calendar-selection/`.
These are offscreen settings-component and initial-setup renders with synthetic
calendars and calendar permissions. Microphone/system-audio status comes from
this Mac. The renders do not establish real permission-dialog or EventKit
synchronization acceptance. Full VoiceOver interaction was not tested.

The installed application was not replaced and no release was published.
Windows was not changed; it currently has no calendar integration.
