# macOS Preview Update Check Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans for inline implementation. Steps use checkbox syntax for tracking.

**Goal:** Let macOS Preview users discover a newer Preview in About and start its DMG download in their browser.

**Architecture:** Mark the Preview bundle during packaging. A Swift service selects a compatible GitHub release, coalesces requests and schedules daily checks. The About page renders state and opens the selected URL through AppKit.

**Tech stack:** Swift, AppKit, Foundation, Python `unittest` and Swift Testing.

**Spec:** `docs/superpowers/specs/2026-11-04-macos-preview-update-check-design.md`.

## Global constraints

- Enable the browser flow only for macOS Preview. Stable checks remain on Sparkle.
- Check in the background once per 24 hours while Verbemo runs. Persist the last automatic attempt across launches.
- Run manual checks immediately and coalesce concurrent requests. Show results in About without a popup.
- Use the exact `Verbemo-<VERSION>-macos-universal.dmg` asset for the published `verbemo-v<VERSION>` prerelease. Open its HTTPS GitHub URL only on Download.

## Review focus

- A local unsigned bundle resembles a Preview. Task 1 verifies that it lacks the Preview marker.
- A Preview and a Sparkle signing key describe conflicting channels. Task 1 verifies that packaging rejects the combination.
- A stable release, draft, malformed tag or Preview without a DMG can sit above a valid Preview. Task 2 covers mixed releases and a later results page.
- A release record can contain a misleading or external asset URL. Task 2 covers exact GitHub origin, tag and filename matching.
- A manual click can race a background request. Task 3 exercises a delayed shared response and checks that the manual result is visible.

### Task 1: Mark the Preview bundle

**Files:** `Makefile`, `scripts/build-macos-plist.py`, `scripts/build-macos-preview.sh`, `Tests/scripts/test_update_feed_location.py`.

- [x] Extend `UpdateFeedLocationTests` with Preview and conflict cases. Assert `VerbemoPreview` is `true` only with `--preview`, and invoking `--preview` with a valid Sparkle key exits with an error.
- [x] Run `python3 -m unittest discover -s Tests/scripts -p test_update_feed_location.py` and see the new Preview test fail.
- [x] Accept `--preview` in the plist generator. Pass it through `make app MACOS_PREVIEW=1` from the Preview packaging script and check the resulting marker before creating the DMG.
- [x] Rerun the focused tests and validate Preview script syntax with `bash -n scripts/build-macos-preview.sh`.

### Task 2: Resolve the latest downloadable Preview

**Files:** `Sources/verbemo/Updates/PreviewRelease.swift`, `Tests/verbemoTests/PreviewReleaseTests.swift`.

- [x] Test that version `0.21.10` beats `0.21.9`, equal or older versions yield no update, stable/draft/malformed entries and entries without a matching uploaded DMG are skipped, and external or mismatched asset URLs are refused. Test that a valid Preview can be found via a GitHub `next` page.
- [x] Run the focused Swift suite and see the missing implementation failure. Verified in a temporary Swift package using the same test source and HTTP stub.
- [x] Implement `PreviewRelease`, carrying `version: String` and `downloadURL: URL`, and `latest(after:session:)` using GitHub's public release list. Compare numeric version triples and validate the URL against the exact asset path. Follow pagination only on the same GitHub API endpoint.
- [x] Rerun the focused Swift suite against the production source in the temporary package. All four tests passed. The full Verbemo package will be checked with Task 3.

### Task 3: Schedule checks and wire About

**Files:** `Sources/verbemo/Updates/PreviewUpdates.swift`, `Sources/verbemo/Verbemo.swift`, `Sources/verbemo/UI/ApplicationWindow.swift`, `Sources/verbemo/UI/AboutPage.swift`, `Tests/verbemoTests/PreviewUpdatesTests.swift`.

- [x] Test daily scheduling with injected time and isolated defaults. Assert that a restarted service within 24 hours skips the automatic request, a manual click starts immediately, and a manual click during a delayed background request shares its outcome. Distinguish an empty result from a request failure.
- [x] Run the focused suite and see the missing implementation failure in the temporary Swift package.
- [x] Implement the main-actor `PreviewUpdates` service. Start it during normal launch only for a bundle with `VerbemoPreview == true`. Render checking, available, up-to-date and failed states in About using existing localized strings conventions. Start the browser handoff only when the Download button is clicked.
- [x] Run the focused Swift tests, update-gate tests and existing About action test in the Verbemo package. All 13 passed. Run the resolver against public GitHub and confirm the direct asset returns HTTP 200 after redirect.
- [x] Open an isolated ad-hoc debug bundle with Preview metadata and verify that About offers the published update and Download.
- [ ] Confirm the download in a real browser and verify the offline error in the running app.
