# Speaker assignment — 2026-10-23

The macOS and Windows meeting workspace has Summary, Transcript and Participants tabs. Assignment controls moved from the inspector to Participants and remain visible without expanding a speaker. Each voice has sample text, a playback action and an editable calendar-participant/name choice. The transcript keeps compact text labels until the link button is activated. A red crossed link denotes an unmatched identity; linked and unmatched states have tooltips and a hand cursor.

Assignments remain scoped to a transcript version. Free names work without a calendar. Calendar choices retain participant IDs, including duplicate names. Unknown grouped speech stays unidentified. The existing claim, lock and finished-diarization checks remain in the write path; custom names replace the identity in one speakers-file write. Raw transcript JSON is preserved.

`user_email` is optional and sits beside `user_name`. Only one exact email match (trimmed, case-insensitive) in a confirmed calendar snapshot can identify literal `me`. It cannot infer a person for mixed/remote or unknown diarization labels. Explicit manual names and unlinking override automatic matching. Removing an automatic identity preserves the configured own name. Email is not included in model requests or analytics.

## Local evidence

- New macOS regression tests initially failed for the missing Participants tab, missing inline link editor and missing email match. Existing mapping tests remain in place.
- Focused runs cover native AppKit controls, three-tab selection at 760/1340 widths, visible participant editors, calendar selection, manual input, duplicate save suppression, Escape, email ambiguity, manual unlink, empty names, version isolation, locks, unchanged raw transcript JSON, settings and playback. Final focused run: **104 tests in 13 suites passed**, including separate reruns of the suites that failed in the full run. Log: `/tmp/verbemo-participants-focused-final.log`.
- Final complete macOS run on code revision `3fb464d`: `swift test --skip-build --disable-sandbox --no-parallel` reported **1184 tests in 172 suites passed** in 138 seconds. There were 21 opt-in skipped test entries. Log: `/tmp/verbemo-participants-full-verified.log`.
- Earlier parallel execution encountered live-text/subprocess timing failures and was interrupted; an intermediate sequential run also found two old inspector assertions. The assertions were updated for Participants, and the final complete sequential run above is the acceptance result. The new failed-write regression also caught unsafe synchronous AppKit selection restoration; restoration is now deferred until after the native selection callback.
- Read-only independent review found mutable callback routing across versions, stale Markdown copying, own-name removal on unlink and Windows long-name/icon issues. These were corrected and re-reviewed without outstanding findings. The follow-up review also covered error restoration, Windows idle-refresh eligibility and ordering the initial queue scan before starting its worker.
- `git diff --check` passed.

## Windows and interactive limits

The available Windows 11 VM was initially suspended. It started, but no .NET SDK was found, host folder sharing was disabled, and its configured network could not reach the SDK download. A temporary read-only test share/NAT attempt did not provide usable network/DNS access. Original bridged network, disabled host sharing, idle pause and suspended state were restored and checked. No Windows build, test or GUI result is claimed from that VM; the PR CI must establish compilation and automated Windows test results.

An isolated macOS test window was attempted through a copied SwiftPM test helper. Computer Use could not address that helper reliably, so this is not claimed as interactive GUI acceptance. An offscreen native AppKit render of Participants at 1100×760 was visually inspected: assignment fields remain visible, sample text wraps, and the inspector contains no speaker editors (`/tmp/verbemo-participants-tab.png`). This is separate from interactive acceptance. No real recordings, calendar accounts, paid model requests, installation, merge or release were used.
