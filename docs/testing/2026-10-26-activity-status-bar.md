# Activity status bar verification — 2026-10-26

PR: [#55](https://github.com/ekho/verbemo/pull/55), branch `codex/activity-status-bar`. Initial local verification below predates integration onto master 0.12.1; refreshed integration evidence is recorded at the end.

Scope: native persistent status bars in AppKit and WPF. Both project existing recording, automatic-recording, permission, processing and audio-meter state; neither owns a second scheduler. The sidebar automatic-recording control moves to the bottom bar. Existing recording controls remain available.

## Source and regression review

An independent read-only review covered queue ownership, completion/cancellation, permission readiness, navigation, narrow layout, timers and cleanup. Fixes from that review:

- macOS checks calendar permission for calendar-triggered automatic recording even when general calendar integration is disabled; a current denial overrides the earlier in-process grant.
- Automatic recording reports when no enabled trigger can start a recording.
- A failed system-audio test invalidates the prior successful measurement. Unknown permission is not displayed as granted.
- Global queue/attention navigation clears an unrelated library search.
- Windows import ownership is visible during copying and duration detection, and is released on success, failure or cancellation.

The new macOS tests also caught and fixed a missing runtime-timer update when no recording was active. The regression failed before the fix and passed afterwards. Search navigation similarly reproduced two failures before the fix.

## macOS

- Native build and Swift Testing run on the local Mac using Xcode's Swift toolchain.
- Focused coverage includes running/waiting counts, excluded bookkeeping work, cancellation cleanup, recording/pause transitions, silence versus unavailable capture, access states, automatic-trigger readiness, timer-driven idle updates, global navigation, and long Russian job titles at 760/1340-point widths.
- GUI uses a separately identified, ad-hoc-signed `Verbemo Status QA` bundle with a fixed isolated home under `.build/statusbar-qa/home`. Recording, live transcription, automatic recording, calendar and providers are disabled in that profile.
- Actual GUI checks: bottom bar persists across library/settings; queue opens processing and clears an unrelated search; access opens the permission controls; the moved automatic-recording switch updates its corresponding settings control. Final built application binary was also inspected in light and dark themes, then the isolated app was closed.
- Offscreen AppKit fixture renders exercise active-recording layout. These are synthetic states, not evidence of hardware capture.

`swift test --no-parallel` completed successfully: Swift Testing reported **1186 tests in 172 suites**, 225.689 seconds, with 29 explicit opt-in skip messages. The disabled scenarios include hardware/model/external-provider and dedicated screenshot suites; their success is not claimed. Full log: `/tmp/verbemo-status-mac-final.log`. After removing an unused-result compiler warning in a test cleanup, the final focused suite also passed: **9 tests**, 5.733 seconds (`/tmp/verbemo-status-mac-focused-final.log`).

## Windows

The Windows 11 Parallels VM was resumed from suspension. A portable official .NET SDK and an isolated source/test directory were prepared under `C:\Windows\Temp\VerbemoStatusBar-20261026`; no global SDK installation or user recording profile was used.

- Windows 11 ARM64 10.0.26200 in Parallels, official .NET SDK **10.0.402 win-x64** under x64 emulation.
- Debug application build: **0 warnings, 0 errors**. Release application/test builds also succeeded.
- Focused status/queue tests: **26/26 passed**.
- Full Release solution tests: Core **157/157**, Live/WPF **120/120**, total **277 passed**, no failures or skips.
- TRX files were copied back and their counters independently parsed from `.build/statusbar-qa/windows-evidence/`; `results.json` records the SDK/OS and transferred-source ZIP SHA-256 `66f0cd3c99914825db50b3ca6f23484cbf993e97bac2f71d870abe087d873028`.
- Coverage includes import before queue entry, completion/failure/cancellation, concurrent direct work, deletion exclusions, access mapping, recording/pause/lost track, English/Russian minimum-width layout, automation toggle semantics and timer teardown.

GUI launch succeeded through `prlctl exec --current-user` with the Debug task DLL in the active console session and `%TEMP%\VerbemoStatusQA-20261026`. Computer Use showed the two synthetic Status QA fixtures and the bottom automatic-recording/access/audio-meter/warning controls. The Windows Start menu obscured the middle of the window, and guest clicks/key input through the available Parallels Computer Use surface did not take effect. **Full visual layout and interactive GUI acceptance remain unverified on Windows**; the WPF interaction/layout tests above are distinct evidence. Existing user applications were left alone.

Temporary VM networking used shared networking and guest DHCP for SDK/NuGet preparation. The original guest static address, route metrics and DNS order were verified restored, then the original bridged/default adapter, MAC and virtio model were restored. Private transfer/proxy servers and the exact QA process were stopped; the temporary read/execute grant for generated build files was removed with no failures. Restoration evidence is saved locally in `.build/statusbar-qa/windows-evidence/network-restored.txt`. The VM was verified **suspended**, matching its initial state (`vm-restored.txt`). The SDK-generated untrusted SYSTEM development certificate was identified by its creation timestamp and removed with its private key (`sdk-certificate-cleanup.txt`). Generated SDK/build artifacts remain in the task directory with SYSTEM ownership; the synthetic GUI profile remains under the test user’s temporary directory.

## Limits

No real microphone/system capture, permission grants or revocations, live call, external recognition provider, screen-reader session, signing/notarization, installer, release or deployment was exercised. Tests of recording and capture-loss presentation use synthetic inputs. macOS system-audio readiness remains based on the existing dated tone-test evidence because the OS does not provide a direct query for that permission; the tooltip explains this limitation.

## Integration before PR merge

The branch was rebased onto `f9839cb` (master, 0.12.1), retaining the participant-assignment workspace from PR #51 and the tray resume icon from PR #52. Independent source review found no regression in these overlaps. The updated macOS tree passed `swift test --no-parallel`: **1193 tests in 173 suites**, 147.152 seconds, with 29 opt-in skip messages; log `/tmp/verbemo-status-mac-integration.log`.

Integration review identified and resolved two Windows import status/error cases: repeated import reservation refusal now follows the UI's handled I/O error contract, and cancellation/failure publishes a terminal status after ownership is released so existing status consumers clear the import message. A repeated import cannot clear the existing owner's status. Independent follow-up source review confirmed both corrections without additional findings.

On the actual Windows VM, the added regressions first reproduced three failures (cancel, missing file, incompatible refusal exception). With the fix, the focused suite passed **27/27** and the full Release solution passed **159 Core + 139 Live/WPF = 298 tests**, no failures or skips. The verified Windows source archive has SHA-256 `2abbcc6f68d349e4a808acf3b27596e5a3b313d78d32136239dc5318e5498fe2` (rebased source plus the two import-fix files). Evidence is retained under `.build/statusbar-qa/windows-evidence/integration/`.

This integration pass found the VM already running and preserved that state. It used the existing task SDK/cache offline, without network, ACL or certificate changes. GUI acceptance was not repeated; the limitations above remain.

### Concurrent master update and CI test repair

During PR CI, master advanced to `260698b` (0.13.0, PR #53). Its existing Windows regression-test fix addresses the same failure observed in CI run `40372147833`: changing runtime settings after window creation could queue a library refresh that cleared the test's injected selection, preventing the intended summary operation. The upstream test configures settings before constructing the window and asserts the provider call; no assertion was removed or timeout increased.

Master was merged into the published feature branch without rewriting it, carrying that repair and the multiple-calendar-email feature. Subsequent native integration results and the final-revision CI/merge state are recorded on [PR #55](https://github.com/ekho/verbemo/pull/55).
