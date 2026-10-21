# macOS UX follow-up — Issue #24

Scope: [Issue #24](https://github.com/ekho/verbemo/issues/24), following the native 0.3.0 (528) audit. Existing meeting files, transcript versions, processing and recovery remain the data model. No new dependencies or Windows UI changes.

## Changes and evidence

| Audit | Result | Check |
| --- | --- | --- |
| F01 | Plain tab hosts isolate stack layout from the frame owned by NSTabView. | First transcript rows intersect the viewport at first open and after repeated tab switches; native Debug first open without resizing. Final package check is recorded in the issue. The original blank release was observed natively; the first-open unit test alone did not reproduce it before the fix. |
| F02 | Production first run is a short permissions page in ApplicationWindow. Models/providers live in their settings sections. | Hosted setup test; native first run → Command-comma → first setup menu → Later, all in one product window. |
| F03 | One version picker inside the Parakeet card; title, description and accessibility name follow v2/v3. | Config/card regression and native v2 selection. |
| F04 | Processing, Attention, empty library and empty search explain their state. | Filter tests and native empty Processing/Attention. Sidebar filters are retained. |
| F05 | Inactive local/cloud/summary provider fields are hidden; stored values survive toggles. | Config roundtrip test, existing setup suites and native disabled services. |
| F06 | Friendly language/theme/audio names retain original represented config values; live help describes the selected final service. Numbered voices retain explicit unknown status. | Existing configuration suites, unknown-speaker regression, native General/model descriptions. |
| F07 | A native split controller limits the library to 220–340 points and leaves the rest for reading. Calendar details collapse by default. | Wide split regression, compact first-open and native zoom. Short participant content starts at the top; native finding reproduced with a failing geometry assertion, then fixed with the existing flipped stack. |
| F08 | Local date/range replaces raw ISO timestamps. New calendar snapshots retain the source time zone and show it when different. | Local, foreign-zone, overnight and invalid-time tests; metadata roundtrip. Old snapshots have no source-zone information and keep local display. |
| F09 | Rename edits the heading; Enter saves, Escape cancels. Confirmations/errors use window sheets or an inline error. | Rename keeps the directory; native Rename/Escape and model-delete Cancel sheet; existing session deletion tests. System permissions/file pickers remain native. |
| F10 | Registered login item offers Manage in macOS rather than another registration attempt. | Native General label/action and source routing; real login registration was not changed during acceptance. |
| F11 | Installed and available model files are separated with a shared readiness predicate; partial caches remain visible as incomplete. Model sizes use the same SI formatter. | Partial Parakeet/live regressions, storage suites and native cancelled download. Advertised sizes are estimates, installed sizes are measured. |
| F12 | Ordinary page headings are static labels, with a contextual return button only when navigation needs it. | Navigation suite and native settings/library. |
| F13 | About content starts at the top of the scroll area. | Native wide About in light appearance. |
| F14 | External editor is an explicit action in the common meeting menu; no duplicate persistent opener in embedded details. | Menu ordering/availability tests and native meeting menu. |
| F15 | Participants and Transcript share calendar participant selection; unlinking restores manual naming. | Bidirectional persisted mapping test and native unlink/map roundtrip. |

## Verification

- `VERBEMO_REQUIRE_LOCALVQE=1 swift test --no-parallel`: 951 tests in 138 suites passed, including required local audio assets. One preceding run missed the old asynchronous `on_stop` hook log within its two-second wait; that test then passed in isolation and the full rerun passed. Its intermittent cause was not established or changed in this UX patch.
- `git diff --check`.
- Native evidence is in the local artifact folder `verbemo-issue24-native` under the 2026-10-21 visualizations directory. Fixtures are fictional; the installed production app and its recordings were not modified.
- One independent read-only review found two important issues (unknown voice numbering and partial caches classified as installed); focused regressions failed before their fixes and passed afterwards.
- The linked issue/PR records final package source/hash, installed native checks, CI and delivery. A source test is not installed GUI or audio acceptance.

## Limits

No new real recording, paid provider, model accuracy/diarization calibration, fresh system permission grant, actual login-item registration change, VoiceOver session, physical Intel run, Windows GUI or update-cycle test was performed for this macOS-only follow-up. A local/CI ad-hoc package is an unsigned preview, not Developer ID/notarized stable acceptance. System permission dialogs and native file pickers are intentionally separate macOS surfaces.
