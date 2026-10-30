# UX70 prototype A implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Make the user-selected structure A reviewable as a self-contained, interactive wireframe.

**Architecture:** One offline HTML artifact with embedded synthetic UX69 data, CSS and JavaScript. A small state model owns selection, per-version assignments, search and simulated jobs; DOM rendering presents that state. No product imports, network calls, user files or credentials.

**Tech Stack:** HTML, CSS, browser JavaScript; Node built-in assert/vm for a focused model self-check; Computer Use for real browser interactions.

**Spec:** `docs/ux/redesign-2026-10/03-structure-and-flows.md`, option A selected by the user on 30.10.2026.

## Global Constraints

- Use `codex/67-cross-platform-ux-redesign`; no native app changes, migration, merge or release.
- A: hideable meeting list, meeting workspace, contextual details, separate settings page; final visual style belongs to #71.
- Reuse fictional UX69 content: 180-turn/9-speaker meeting, incorrect assignment, genuine unknown speaker, two versions, title/transcript/summary search terms.
- Assignment affects one speaker in one selected version. Unknown, stale and busy changes are refused.
- All recording, processing, playback and persistence are demonstrations. Reload resets the demo; reopening a meeting retains in-session edits/context.
- Search is a demonstration of the proposed feature, not an implementation in Verbemo.
- Verify wide and 760×600 content frames, RU/EN, keyboard focus, light/dark wireframes. Windows presentation can be previewed; Windows GUI acceptance remains unperformed.

## Review Focus

- Assignment after switching meeting/version must not change another result; model self-check and browser cancel/reopen.
- Search-hit navigation must select the right source, preserve the library query and return to reading; model scope check and browser exercise.
- Recording/job state must survive settings navigation; model check and browser exercise.
- Error/cancel must preserve previous summary; model checks for both plus browser cancel/error/retry.
- Hidden list, details and settings categories must remain reachable at minimum size; browser layout/focus check, not claimed from model tests.

### Task 1: Build and verify the offline wireframe

**Files:**
- Create `docs/ux/redesign-2026-10/prototype-a.html`: data, state, views and interactions.
- Create `docs/ux/redesign-2026-10/prototype-a.test.cjs`: model self-check, no browser dependency.
- Create `docs/ux/redesign-2026-10/prototype-a-review.md`: entry point, tested scenarios, limits and user acceptance steps.
- Modify `docs/ux/redesign-2026-10/03-structure-and-flows.md` and the epic plan: selected A and current evidence.

**Interfaces:**
- Embedded `fixture-data` JSON contains only the five generated synthetic meetings.
- `globalThis.UX70` exposes `createState(data)`, `search(state, query, local)`, `assign(state, request)`, `select(state, meetingId, versionId)`, `startJob(state, kind)`, `finishJob(state, outcome)`, `remove(state)` and `undo(state)` for the focused checks. Rendering is browser-only.
- View state is keyed by meeting/version/tab; recording and jobs live outside navigation.

- [x] Write self-check for search scopes, version assignment/isolation, stale/busy/unknown refusal, job outcomes, recording independence and delete/undo; run it and observe missing artifact failure.
- [x] Build the self-contained artifact, reusing data from the UX69 fixture generator in a new temporary directory. Check: no remote resources or product data dependencies.
- [x] Run `node docs/ux/redesign-2026-10/prototype-a.test.cjs`. Expected: all named checks pass.
- [x] Open the actual artifact with Computer Use. Exercise reading, assignment/cancel/unlink, both search scopes/empty state, version switch, settings/back, recording navigation, processing outcomes and delete/undo. Inspect wide/minimum frames and focus; record actual scope.
- [x] Review the artifact against the spec with a fresh reviewer; fix material issues and repeat affected checks. User's selection authorizes this mockup work; no further implementation-method confirmation is needed.
- [x] Update evidence/docs and GitHub #70/#67, commit with Conventional Commits + co-author, push the epic branch. Keep #70 open for user acceptance and #71 unstarted.

## Scope rulings

This is a disposable design prototype, not product implementation. Verification is the focused model self-check plus browser interactions; Swift/WPF suites cannot validate this artifact and are not run. System dialogs, real file import, real audio, model execution, OS menus and credentials are outside the simulation; their placements remain in the function map. No installed dependencies are needed.

## Execution evidence

Model checks: 9/9 PASS. Browser scenarios and seven inspected screenshots: `docs/ux/redesign-2026-10/prototype-a-review.md`. Fresh reviewer scored all six material findings resolved after the correction batch. Native suites were not run under the prototype scope ruling. User acceptance of #70 remains pending.
