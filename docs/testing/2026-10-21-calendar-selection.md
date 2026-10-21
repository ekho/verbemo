# Calendar selection and settings tabs: final local checks

Scope: issue #27 and the chosen settings navigation, on `codex/verbemo-journal` based on `12b1a1c`. This report supersedes earlier Journal test totals and preview hashes. All checks use isolated synthetic meeting data.

## Behavior

- One searchable dropdown serves New recording and the saved-meeting inspector. It opens on the recording day; users can select a day, search by title or date, change the association, or clear it.
- Supported date prefixes: `DD.MM.YYYY`, `YYYY-MM-DD`, and `DD.MM` in the recording year, optionally followed by title words. Title-only search spans one year either side of the selected day; the actual interval and local time zone are shown. An explicit date reaches older events.
- EventKit authorization is checked on access; a selection is re-resolved before saving and again before recording starts. Denied access or a deleted event retains the previous snapshot. Local day boundaries respect daylight saving time; the saved snapshot retains the event time zone.
- Linking changes only calendar metadata under the existing session claim. Manual speaker names, transcript versions, results and the recording title remain independent. Calendar invitees are not assigned to voices by this control.
- Settings use horizontal text tabs with leading SF Symbols and an accent underline on the active section. A compact section menu remains available at narrow widths.

## Automated checks

`swift test --no-parallel`: **1024 tests in 145 suites passed**, 87.284 seconds. Log: `/tmp/journal-final-all-tests.log`. Optional interactive/gallery suites were skipped.

Focused coverage includes date/title search, invalid dates, a 25-hour daylight-saving day, stale responses, cancelling an in-flight selection, access errors, deleted events, selection/clearing, recording-start revalidation, and byte-for-byte preservation of manual names and two distinct transcript versions. Busy sessions reject metadata changes. Settings tests cover tab icons, selection, compact navigation and widths.

The opt-in `CalendarAcceptanceTests` fixture also compiles, but its standalone SwiftPM test host could not be bound by Computer Use. No successful interactive acceptance is claimed for that fixture. Its later completion guards require an explicit finish marker and a recording draft; the default suite skips it.

## Packaged app

`make app SIGN_ID=- -o localvqe -o nemotron` completed. The unchanged native dependency artifacts were reused. Universal arm64/x86_64 packaging, strict ad-hoc signature and native helper closure validation passed. This is not a notarized release.

The refreshed acceptance bundle is `.build/Verbemo-Journal.app`, identity `name.ekho.verbemo.journal`, version 0.3.1/build 531. Executable SHA-256: `418829cc5722b5fbfdcdec5e720b13f912c4c57c85b9f2ed5f896f7782fc109d`. Its Info.plist pins `CFFIXED_USER_HOME` to `.build/journal-preview-home`. The installed application and CLI link were not replaced.

Computer Use checks in that actual packaged app:

- All six settings tabs show their icons and labels; General has the active underline and Calendar switches correctly.
- With calendar integration temporarily off in the isolated profile, the event dropdown opens on 21.10.2026, matching the selected synthetic recording. Search accepts a date and Escape dismisses the popup. The disabled-integration explanation is visible.
- Clearing the saved demo association removes its calendar details. Manual speaker names remain visible; nonhidden audio, name and result files retain their hashes. The original synthetic metadata was then restored exactly.
- Calendar integration was restored to on. Configuration values match the saved acceptance-profile backup; serialization changed the immediate pre-check file hash. No recording or cloud request was started.

Screenshot/accessibility evidence is under `native/calendar-tabs/` in the local visualization directory: `settings-tabs`, `calendar-disabled`, `calendar-unlinked`, and `delivery.json`.

## Limits and delivery

Positive selection from a real EventKit store and a fresh macOS calendar-permission flow were **not** exercised in this check. Those paths have synthetic automated coverage; no real calendar was modified. Native calendar reads are not isolated by a pinned filesystem home alone.

Nemotron evidence is recorded separately in [the ASR report](2026-10-21-nemotron-final-asr.md): it includes a 39-minute synthetic Russian recording, not a long natural/noisy-speech accuracy benchmark. No new physical microphone/system-audio capture was performed here. Windows was not checked on a Windows host.

The user explicitly authorized committing the accumulated branch and creating a PR. No merge, release or installation over the user's application is authorized by this delivery.
