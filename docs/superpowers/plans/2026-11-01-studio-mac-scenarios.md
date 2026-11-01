# Studio macOS — B2–B5

> **For agentic workers:** Use superpowers:executing-plans sequentially in the existing epic branch after B1 delivery. One fresh final reviewer, no per-task delegation. User authorized Mac #73 and separate Windows #75–#77; no new approval gate between portions.

**Goal:** Complete the remaining macOS #73 function map using the accepted Studio structure and existing native contracts.
**Architecture:** Keep AppKit owners of navigation, settings application, recording, processing and native controls. Reuse the SwiftUI meeting header. Shared visual tokens may serve existing native screens; no UI framework migration, new settings schema, providers or integrations.
**Spec:** docs/ux/redesign-2026-10/{03-structure-and-flows,04-component-spec,06-implementation-and-coverage}.md. All eighteen functions remain reachable.

## Global Constraints

- Existing `codex/67-cross-platform-ux-redesign`; macOS14.2. No merge, release, provider use, real capture, model download/deletion, personal profile changes or Windows implementation.
- Synthetic isolated data. Settings schema coverage, selected-versus-active values, masked secrets, restart requirements, processing guards, selected artifact and delete/undo contracts remain intact.
- Settings search remains outside the accepted scope. No new integration, endpoint or EventKit work.
- Final platform/user acceptance remains #74, with explicitly unverified hardware/accessibility/minimum-runtime checks retained.

## Review Focus

- Settings navigation must preserve meeting/filter/query/version/tab/reading context and respect explicit later selection.
- Narrow category navigation and wide sidebar must not grow the window or hide recording/queue controls; resize and library visibility preferences must survive return.
- Every schema setting remains represented once; disabled/read-only controls, secrets and selected/active providers remain truthful.
- Explicit calendar choice replaces a draft title; delayed initial load preserves manual input. Cancel has no recording/file side effect.
- Dismissing a notice changes visibility only, never cancels work or discards ready artifacts; materially changed state must be shown again.
- Composite action images, labels and keyboard focus must remain legible and operable in both themes and minimum/wide windows.
- Remaining function map is evidence of reachability and verified interaction, not proof of real inference/audio/update/install.

### Task 1: B2 settings navigation
**Files:** ApplicationWindow.swift, SidebarView.swift; SettingsNavigationTests.swift, JournalWorkspaceTests.swift.
**Consumes:** existing navigation destinations, SidebarView host, library reading-context owner from B1.
**Produces:** wide settings categories in place of the meeting list; explicit return to the previous meeting; narrow category overview then selected page with a return to all categories. Native window/split sizing remains owned by AppKit.
- [x] RED native wide/narrow navigation, context return, categories/meeting selection exclusivity, resizing and hidden-library preference. Replace legacy test assumptions that expose the library while settings categories occupy its place.
- [x] Implement category presentation and return using existing destinations/controls; preserve direct links to recording/calendar/MCP and global recording/queue.
- [x] GREEN navigation/workspace/recording/library tests; commit feat(ui): organize Studio settings navigation.

### Task 2: B2 settings style and scope
**Files:** JournalStyle.swift, StudioStyle.swift, SettingsController.swift, SetupLayout.swift where needed; focused settings/schema/model/MCP tests.
**Consumes:** existing SettingsPage, SettingsSchema, SettingsApplier and SetupForm coverage.
- [x] Audit represented paths against schema before changes; every existing path stays covered once.
- [x] Reuse Studio colors across native surfaces, readable headings and compact rows; keep controls usable at760. Place a clear profile/future-operation scope statement on settings pages; ready meeting artifacts are unchanged by those settings.
- [x] Verify masked secrets, restart/failed-save notices, model/storage reachability, selected/active values. No searches or new fields.
- [x] GREEN appropriate settings/coverage/layout suites; commit feat(ui): apply Studio settings components.

### Task 3: B3 new and current recording
**Files:** NewRecordingSheet.swift, ApplicationWindow.swift/RecordingBar.swift only if gaps remain; NewRecordingSheetTests.swift, RecordingWorkspaceTests.swift.
- [x] RED explicit event selection overwrites a manually edited draft; delayed initial suggestion does not. Preserve calendar filtering, access/unavailable/empty/error states and start-time revalidation.
- [x] Implement the accepted distinction using existing picker callbacks; title remains full width. Cancel creates nothing.
- [x] Verify one active session, pause/stop/open current controls across library/settings/hide/show using synthetic callbacks. No real microphone/calendar authorization or capture.
- [x] GREEN recording/calendar tests; commit fix(ui): honor explicit calendar titles for new recordings.

### Task 4: B4 results and processing
**Files:** MeetingLibraryController.swift, shared native action-image helper only if needed; relevant meeting/action/cancellation tests.
- [x] RED dismissible result notices and composite transcript/summary regeneration icons; content/state changes re-show relevant notices.
- [x] Reuse #72 result/participant/player components. Dismiss only presentation; keep busy/stale/cancel/retry guards, old ready results and selected artifact.
- [x] Verify ready/pending/deferred/failed/cancelled states with existing synthetic fixtures and operations; avoid provider jobs.
- [x] GREEN result/controller/action/cancellation tests; commit feat(ui): refine Studio result actions and notices.

### Task 5: B5 remaining entries and function map
**Files:** existing import/setup/models/MCP/about/menu/action UI only for confirmed gaps; focused tests and coverage/evidence docs.
- [ ] Audit all F01–F18 against actual native entry points. Direct Import opens native file selection; Cancel has no import side effect.
- [ ] Verify storage/models, access/setup, MCP, menu/tray, About/version and rename/folder/editor/delete/undo through isolated synthetic tests and native UI where applicable. Do not execute external editors, update/install, real model deletion/download or grant access merely for a visual check.
- [ ] Fix confirmed scope gaps using existing controls, guards and action images; no speculative redesign.
- [ ] GREEN relevant existing suites; commit bounded fixes only if needed, then update the map with precise checks/limits.

### Task 6: whole-map verification and delivery
**Files:** evidence-73/B2–B5 and final coverage report, issue73/74 updates; product changes only for reproduced material review findings.
- [ ] Full swift test --no-parallel; universal make app SIGN_ID=-; separate source-pinned synthetic Review, code signature/minimum metadata check.
- [ ] Native GUI RU/EN/light/dark/minimum/wide: settings categories/back/resize; every settings page and scope; new-recording draft/Cancel; result notices/actions; import Cancel; About; remaining safe entries. Check persisted state where actually changed and reset test state.
- [ ] One fresh whole-change review; sort findings, RED/GREEN material fixes, full suite after fixes. No second reviewer.
- [ ] Record all skipped/unverified checks, rulings and deferred minors. Update F01–F18 and GitHub accurately; push same epic branch. Close #73 only when its Mac map is complete; #74 remains final user/platform acceptance. No merge/release.
