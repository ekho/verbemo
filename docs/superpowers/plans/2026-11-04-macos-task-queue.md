# macOS Task Queue Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans or superpowers:subagent-driven-development. Steps use checkbox syntax for tracking.

**Goal:** Add a live list of background jobs above the macOS activity counter, with removal and cancellation for individual jobs.

**Architecture:** The existing `ProcessingOperations` registry owns jobs and their outcomes. The status bar passes the same filtered snapshots to the counter and an AppKit popover. The popover requests actions on one run, and the activity messages report the outcome.

**Tech stack:** Swift, AppKit, Swift Testing.

**Spec:** [Очередь задач в Журнале macOS](../specs/2026-11-04-macos-task-queue-design.md)

## Global constraints

Support macOS at 760 pt in both appearances and languages. Reuse runtime ownership, existing import feedback and the existing Processing destination. Preserve audio, completed results and other meetings. Automatic discovery can queue unfinished work in a later pass.

## Review focus

- A stale waiting row can cross into running before the click is handled. Only the waiting-state action may remove it.
- A run already awaiting an engine can need cleanup before it leaves the registry.
- Cancellation can race successful completion. Keep the actual outcome and never target a replacement run.
- A status tick during confirmation must preserve the decision, keyboard focus and scroll position.
- Multiple unrelated jobs can finish while the popover is open or closed. Keep the feedback attributed to the correct action.

## Tasks

- [x] In `ProcessingOperationsTests`, cover removal of a waiting reservation, refusal of a stale waiting snapshot after the job starts, and waiting-task cleanup. Run the tests before adding `removeWaiting(_ snapshot: Snapshot) async -> Completion?` in `ProcessingOperations.swift`. Share the existing locked cancellation path and wait on the retained completion handle after a successful request.
- [x] In `ActivityStatusBarTests`, drive the real counter button and popover with an injected registry. Assert navigation stays on the meeting until the footer link is used, the two action types reach the correct run, the other runs remain available, and Escape returns focus to the counter. Cover completion racing confirmation and the empty, scrolling and long-title states.
- [x] Implement `ActivityQueuePopover.swift` and wire it from `ActivityStatusBar.swift`, `ApplicationWindow.swift` and `Verbemo.swift`. Keep visible rows keyed by run ID, keep the footer link outside the scroll view and route results to the existing activity message surface.
- [ ] Run the focused and full macOS tests with `swift test --no-parallel`. Inspect the native popover in a synthetic profile at 760 pt, in both appearances and languages. Review the complete diff, including the preceding meeting-scoping fix.
- [ ] Commit with Conventional Commits and co-author attribution. Push to `ekho/verbemo`, open a PR against `master`, wait for CI on the PR head, then squash merge and verify the merge SHA.
