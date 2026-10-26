# Multiple calendar email addresses

The Calendar settings editor now shows individual addresses with remove buttons,
an add field and an Add button. Enter also adds; comma, semicolon and newline
separated lists are accepted. Invalid input stays in the field, duplicate
addresses are collapsed, and failed saves preserve the stored list. The same
manual editor is available in Windows settings for saved calendar metadata.

`user_email` now writes an array and still reads legacy single strings. Owner
matching checks all configured addresses, ignoring case and surrounding spaces.
Two matching calendar identities remain ambiguous. Manual assignments and
explicit unlinking continue to take precedence; only the known microphone voice
can be linked. These addresses are not added to model requests.

On macOS, the first successful calendar authorization imports addresses marked
`EKParticipant.isCurrentUser`, including organizers. Already authorized users
receive this once after upgrading; this also covers a first grant made in System
Settings after an initial denial. A marker in setup state prevents subsequent
automatic imports, including after deleting every address or resetting setup.
**Взять из календарей** explicitly merges another discovery result into the list.

Discovery uses public EventKit APIs, scans events within ±1 year and excludes
subscribed calendars and delegated accounts. It does not infer identities from
names or calendar/account titles. Accounts without suitable events may return
no address; manual entry remains necessary for those accounts. Windows has no
live calendar integration.

References: [Apple: isCurrentUser](https://developer.apple.com/documentation/eventkit/ekparticipant/iscurrentuser),
[Apple: EKParticipant](https://developer.apple.com/documentation/eventkit/ekparticipant).

## Verification

- A new multiple-address owner test failed against the original implementation
  and passed after the change.
- Full macOS `swift test --disable-sandbox --no-parallel`: **1192 tests in 173
  suites passed**, 249.818 seconds. Log: `/tmp/verbemo-emails-all-tests.log`.
  Existing opt-in suites remain skipped.
- After the accessibility and already-granted permission fixes: **94 tests in
  5 suites passed**, including email, calendar and setup coverage. Log:
  `/tmp/verbemo-emails-final-focused.log`.
- Windows 11 Parallels VM: built the app with the existing .NET 10.0.402 x64 SDK.
  Targeted tests passed (14 Core, 19 Live); the complete suite then passed
  **163 Core + 124 Live tests, zero failed or skipped**. Sources were transferred
  into the isolated `VerbemoValidation/jobs/emails-20261026` directory and checked
  against the archive used for the run. Logs: `focused-tests.log`, `all-tests.log`
  in that Windows directory.
- Native macOS Computer Use exercised the isolated `Verbemo-Emails.app` bundle,
  with `CFFIXED_USER_HOME` pinned to `.build/emails-home`. Verified adding a pasted
  list with Enter, deduplication, removing an individual address, persisted JSON,
  and exposed accessibility controls. The installed app/profile was not replaced.
- Read-only review identified the System Settings authorization gap; it was
  corrected before the final focused run.
- The first PR CI run exposed an existing Windows summary UI test race. A
  diagnostic run on the Windows VM confirmed that a settings-triggered reload
  cleared the synthetic meeting selection before the model was called. The
  fixture now configures summary settings before creating the window, preserving
  the error-display and old-summary assertions without changing product code.
  All **124 Live tests passed in five consecutive full runs** after the fix.
  Log: `/tmp/verbemo-live-ci-fix.log`.

## Limits

Real EventKit account discovery and a fresh system permission grant were not
exercised. Automated tests cover extraction rules, one-time import, failed saves,
manual edits, legacy configuration and speaker matching with synthetic data.

The Windows debug app was launched with `VERBEMO_TEST_DATA` set to a separate
profile. Computer Use could retrieve the Parallels screenshot, but guest input
did not change the visible UI; manual Windows acceptance remains unverified.
The Windows control was exercised by native WPF tests on the VM.

The macOS test bundle was signed ad hoc. No release, installation replacement,
Developer ID signing or notarization was performed.
