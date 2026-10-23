# macOS shutdown and Journal cancellation implementation plan

> **For agentic workers:** Use superpowers:executing-plans for shutdown and a bounded parallel worker for Journal; one whole-branch review at the end.

**Goal:** Implement issues #7 and #30 on the merged #42 lifecycle.
**Architecture:** Keep ProcessingOperations as the process-local owner. AppKit and signal quits close admission synchronously, save capture, await the original live transition and retirees, then cancel and await processing. Journal captures session/run snapshots and awaits their real completion without blocking other meetings.
**Tech Stack:** Swift concurrency, AppKit, existing Swift Testing; no new dependencies.
**Spec:** GitHub ekho/verbemo issues #7 and #30, updated 2026-10-23; docs/processing-lifecycle.md.

## Constraints and review focus

Preserve SessionClaim, source audio, published versions, manual names, summary/diarization per-run requests, shared downloads and serial engine reuse. No merge or release. No timeout establishes cleanup. External CLI is not owned by the GUI. Only isolated synthetic GUI data.

Review signal nested-loop deadlock; late recording handoff; live toggle/preload retirees; old cancellation callback/new generation; success racing cancellation.

## Execution

- [x] #7 RED: tests for synchronous admission close, ordered handoff/cleanup, repeated requests, retired live preload and original handoff.
- [x] #7 GREEN: AppTermination barrier; AppController live transition handle; AppDelegate single deferred response; signal next-run-loop quit; stop owned service/UI timers and consumers; EN/RU stopping status.
- [x] #30 RED/GREEN: completion on snapshots, canonical session/run cancellation, truthful result, local cancelling state, retry and selection/generation tests.
- [x] Focused tests, full serial Swift suite, relevant shared checks and build.
- [x] Isolated native Journal/child/claim/retry, AppKit Command-Q and signal smoke during real Whisper inference. [Evidence and gaps](../../testing/2026-10-23-shutdown-journal-cancellation.md) record Dock timeout and unavailable physical capture/live acceptance.
- [x] Fresh whole-branch review; fix substantial findings and additional native regressions; refresh master (still `e181114e16747aeab6758b79a825f5b5cd027075`).
- [ ] Commit/push, ready PR to master and final-head CI; keep acceptance gaps explicit and issues open. No merge or release.
