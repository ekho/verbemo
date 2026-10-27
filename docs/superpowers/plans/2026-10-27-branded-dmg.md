# Branded DMG Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Ship the Issue #48 Journal-style DMG through reviewed PR and merge.

**Architecture:** One shell packaging entry point invokes a pinned dmgbuild
configuration and an AppKit background renderer. Existing release scripts keep
ownership of signing, receipts and publication.

**Tech Stack:** Bash, Python/dmgbuild, Swift/AppKit, Python unittest.

**Spec:** `docs/superpowers/specs/2026-10-27-branded-dmg-design.md`

## Global Constraints

- Preserve release filenames, Preview volume suffix and signing order.
- Use existing app artwork; 660 × 420 points with 1×/2× background representations.
- No Windows application changes; no stable publication or new credentials.

## Review Focus

- Spaces and Unicode in source/output paths must survive packaging.
- Existing output must not be overwritten, including on failure.
- Symlinks, permissions and signatures must survive packaging and copying.
- Background aliases must resolve inside the final image after remounting.
- Both release paths must retain their validation and signing sequence.

### Task 1: Shared DMG packaging and acceptance

**Files:** Add `Packaging/dmg/{background.swift,settings.py,requirements.txt}`,
`scripts/build-dmg.sh`, `Tests/macos-scripts/test_dmg.py`; update both macOS
packaging scripts, CI/release workflows and `docs/releasing.md`.

**Interfaces:** `bash scripts/build-dmg.sh <app> <volume-name> <output.dmg>`.
Consumes a signed app; produces a checked UDZO image without modifying the app.

- [ ] Add tests that run the builder on a tiny signed bundle, mount the result,
  check Applications, background metadata and Retina representations, copy the
  app and verify its signature. Include spaces/Unicode and rejected overwrite.
- [ ] Run `python3 -m unittest discover -s Tests/macos-scripts -p test_dmg.py`;
  expect failure because the shared builder is absent.
- [ ] Implement the builder, layout, background and pinned dependencies; run the
  same tests and expect success.
- [ ] Integrate both release scripts and dependency installation in CI. Run the
  release-script suite and macOS packaging tests; expect no failures.
- [ ] Package a real Verbemo app and inspect in Finder, light/dark, then remount
  and copy out to an isolated temporary destination.
- [ ] Commit with Conventional Commits and Co-Authored-By. Obtain independent
  whole-branch review, address actionable findings, create PR, require green CI
  for its exact head, merge, and verify the merge and issue closure.
