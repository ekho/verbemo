# Studio library search — implementation plan

> **For agentic workers:** Use superpowers:executing-plans sequentially in the existing epic branch. Steps use checkbox syntax. One fresh whole-change reviewer after the final task; no per-task delegation.

**Goal:** Finish B1 of macOS#73: real current transcript/summary library search, contextual result navigation and honest empty/error states.
**Architecture:** A cancellable background scan reads one current meeting at a time and returns one prioritized hit per meeting. No persistent index or full-library document cache; this keeps storage unchanged and avoids retaining all transcript text. Existing inventory sorting/filtering, version ownership, native text search and player remain owners of their state.
**Tech Stack:** Foundation/CryptoKit, AppKit, existing SwiftUI header, Swift Testing; no dependencies.
**Spec:** [components](../../ux/redesign-2026-10/04-component-spec.md), [scope/map](../../ux/redesign-2026-10/06-implementation-and-coverage.md), accepted current-only global search in visual-directions.html UX70.search. User01.11 explicitly split Windows75–77, completed72 and authorized73.

## Global Constraints

- Existing codex/67-cross-platform-ux-redesign; no master merge/release. macOS14.2, same storage/provider/processing contracts.
- Current transcript/summary only; selected-version local search remains separate. Preserve title/folder/date/invite search and filter ordering.
- No model/audio/network operations; use isolated synthetic data. Never mask unreadable material as proven absence.
- Background reads reject nonregular/symlink artifacts and artifacts over32MiB; report incomplete search instead of silently dropping them. This is a bounded reader, no new setting.

## Review Focus

- Emoji/non-ASCII offsets and Markdown formatting must not produce broken snippets or route to the wrong visible phrase.
- Late query/root/data results must not overwrite current state; cancellation and shutdown must await owned work.
- Archived text must not leak into current-only results; a stale/current-version mismatch must refresh without changing another artifact.
- Missing/invalid/oversize/unreadable data must not crash or falsely report complete zero results.
- Filtering, selection, copy, active recording, delete/undo and reading positions retain existing behavior.

### Task 1: Current-material reader and matcher
**Files:** create Sources/verbemo/UI/MeetingLibrarySearch.swift; modify MarkdownPreview.swift with nonisolated plain text conversion; create Tests/verbemoTests/MeetingLibrarySearchTests.swift.
**Interfaces:** Input(dir:URL,title:String,metadata:[String]); Hit(source:Source,segment:Int?,excerpt:String,query:String,revision:String?); Outcome(hits:[URL:Hit],unreadable:Int). Source title/metadata/transcript/summary. static search(_ inputs:[Input],query:String) throws -> Outcome; static revision(_ data:Data)->String. All payloads Sendable.
- [x] RED actual current-only fixture: transcript-only/summary-only, archived-only excluded, emoji/exact literal/non-overlap, title/metadata priority, empty query, malformed and absent files, symlink, oversized artifact and cancellation; no disk writes.
- [x] Run swift test --no-parallel --filter MeetingLibrarySearchTests; confirm expected missing implementation/failing behavior.
- [x] Implement one-meeting-at-a-time scan, first literal case-insensitive UTF16 match, bounded160-character contextual excerpt; ready JSON first, Markdown fallback only when JSON absent; summary visible Markdown text. Error count is explicit.
- [x] GREEN reader tests; commit feat(search): search current library artifacts.

### Task 2: Cancellable native integration
**Files:** MeetingLibraryController.swift; MeetingLibraryControllerTests.swift and StudioLibraryTests.swift.
**Consumes:** Task1 Input/Outcome; existing reload/scans, settled, filter and deletion guards.
**Produces:** background search task ownership with generation/root/query guards; current hits accessible through native rows, no test-only product API.
- [x] RED real native library queries find transcript/summary content; stale fast query/root changes cannot replace current result; refresh sees changed content. Existing title filter remains immediately useful.
- [x] Query debounce150ms; cancel old workers and track/await owned tasks on termination. Rebuild on explicit refresh/session changes/assignment/rename/delete/undo. Do not read whole artifacts on main-thread keystrokes.
- [x] Update settled to wait current scan/search. Apply filter to current result IDs; preserve sorting and selected matching meeting; show searching/incomplete status honestly.
- [x] GREEN Task1+controller/recording/workspace tests; commit feat(search): integrate cancellable library queries.

### Task 3: Results, navigation and empty states
**Files:** MeetingListView.swift, MeetingLibraryController.swift, StudioLibraryTests.swift/MeetingLibraryControllerTests.swift.
**Consumes:** Hit.source/segment/query/revision. Uses selected current artifact and existing setMeetingSearchQuery/moveMeetingSearch behavior.
- [x] RED snippets expose source; native row heights fit at220/400; selecting a content hit opens current correct tab/segment and highlights. Changed revision is rejected/refreshed. Empty query result differs from empty inventory/filter.
- [x] Render up to two lines of contextual source/excerpt; size with same native label metrics. Meaningful accessible labels; placeholder honestly lists title/text/summary.
- [x] Route explicit/keyboard selection through current-version and revision checks, existing local search highlight/navigation. No writes, no second player. Metadata/title matches preserve reading version.
- [x] Distinguish empty inventory, pending query, no matches, unreadable results and empty filter. Reset search/filter button has clear label.
- [x] GREEN reader/controller/workspace/recording/density suites; commit feat(ui): reveal contextual library search results.

### Task 4: Delivery evidence
**Files:** evidence-73/B1/, coverage map, issue73 progress; no Windows source.
- [x] Required full swift test --no-parallel, universal make app SIGN_ID=-, source-pinned isolated Review and codesign/minimum validation. Record skipped tests explicitly.
- [x] Native GUI RU/EN/light/dark/minimum/wide, transcript-only and summary-only search, result click/highlight, no matches/reset, filter/query, refresh, hide/show; hashes before/after read-only search identical.
- [x] Fresh whole-change review as executing-plans requires; fix material findings with RED/GREEN, repeat impacted checks, preserve exact revision provenance.
- [x] Evidence/coverage/issues and commits pushed same epic branch. Mark B1 only after proofs; continue B2–B5 sequentially. #73 remains open until the whole Mac map is covered, #74 final acceptance separate.

Delivery checkpoint: source d738306, Review660; evidence-73/B1/report.md and verify.py. All full tests were executed in Task4; its final validator checks the pinned logs/source/package/captures instead of repeating the unchanged suite only for ledger bookkeeping. B1 is complete; Mac73 B2–B5 remain.
