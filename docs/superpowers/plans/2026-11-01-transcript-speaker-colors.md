# Transcript speaker colors Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans; implement this small acceptance refinement inline in the existing epic worktree.

**Goal:** Make speakers easier to distinguish through a full utterance background without a letter badge.

**Architecture:** Keep the reusable AppKit transcript cells and existing speaker ordering. Reuse Studio palette hues, with restrained dark-theme surfaces; draw the background across the whole cell.

**Tech Stack:** Swift, AppKit, Swift Testing.

**Spec:** `docs/ux/redesign-2026-10/08-transcript-speaker-colors.md` — direction approved by the user's “Да, реализуй”.

## Global Constraints

- Same epic branch; macOS only, no merge/release.
- Preserve names, edit/play actions, text selection, search and accepted geometry.
- Unknown speaker stays neutral; names carry identity independently of color.
- Synthetic profile only; preserve the existing acceptance baseline and Review670 bundle.

## Review Focus

Repeated/unknown speakers and cell reuse must not inherit another speaker's tint. Dynamic appearance and all palette entries must preserve 4.5:1 text contrast. Narrow wrapping, search highlights and edit actions must remain usable.

### Task 1: Transcript row tint and review candidate

**Files:** `Sources/verbemo/UI/StudioStyle.swift`, `Sources/verbemo/UI/MeetingTranscriptView.swift`, `Tests/verbemoTests/StudioDensityTests.swift`, acceptance evidence/docs.

**Interfaces:** Existing `MeetingTranscriptView.update`/`setSearch` and `StudioStyle` palette; no storage or external API changes.

- [x] Update density assertions to locate the speaker name; add rendered background/reuse and contrast checks. Observe failure on current code.
- [x] Add dynamic row surface colors; remove the transcript badge; fill the entire reusable cell.
- [x] Run focused density/reading/assignment/library checks and inspect the diff.
- [ ] Build a separately identified Review candidate, verify isolated profile/signature, inspect light/dark wide/narrow reading, search and editor behavior.
- [ ] Record evidence and commit/push to epic branch; hand back for repeat human acceptance.
