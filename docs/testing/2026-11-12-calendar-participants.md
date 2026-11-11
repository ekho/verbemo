# Calendar participant ordering and one-to-one matching

Calendar attendees are sorted by email, ignoring case and surrounding spaces.
Attendees without an email come last. The order applies to the invitation list
and participant choices on macOS and Windows.

A confirmed event with exactly two attendees can identify the other attendee
when exactly one attendee matches a configured self email and the completed
transcript has one known remote voice. Multiple remote voices, unknown voices,
ambiguous self identities and unfinished local diarization remain unassigned.
Manual names, participant choices and explicit unlinking take precedence.
Automatic links are refreshed when the event or self emails change, including
archived transcript versions. Raw speaker labels are preserved.

## Verification

- Regression tests failed against the previous behavior on both platforms.
- macOS: full `swift test --no-parallel` passed **1429 tests in 190 suites**.
  Existing opt-in model, audio and screenshot checks were not enabled.
  Log: `/tmp/verbemo-calendar-all-tests.log`.
- After fixing Markdown refresh following a conflicting manual assignment,
  the focused macOS run passed **43 tests in 5 suites**.
  Log: `/tmp/verbemo-calendar-final-focused.log`.
- Windows 11 Parallels VM, .NET 10.0.402 x64: Debug app build and **214 Core +
  211 Live tests passed**, zero failures or skips in the completed runs.
  Isolated checkout: `C:\Windows\Temp\VerbemoCalendar-20261112`.
  Results: `calendar-all-complete.trx` in Core TestResults and
  `calendar-live-final.trx` in Live TestResults.
- Native macOS QA used a separate app identity and synthetic profile. Checked
  the collapsed and expanded invitation order, email order in the participant
  menu, automatic guest mapping, and explicit unlink surviving meeting changes.
- The Windows QA app launched with an isolated synthetic profile. Startup
  persisted both automatic participant links, confirmed in `speakers.json`.
  Computer Use clicks and keyboard input through Parallels did not operate the
  guest controls, so Windows GUI interaction acceptance remains unverified.

No real meetings, model inference or paid provider calls were used for this QA.
