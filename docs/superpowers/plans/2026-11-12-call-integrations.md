# Call Integrations Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to implement task by task.

**Goal:** Encapsulate KTalk observation behind a reusable call-integration contract and connect it to Verbemo.
**Architecture:** Local Swift package with common `CallIntegrations` and vendor `KTalkIntegration` targets. Application bridge owns polling and adapts observations to existing recording decisions.
**Tech Stack:** Swift 6, Foundation URLSession WebSocket, AppKit Accessibility, Swift Testing.
**Spec:** ../specs/2026-11-12-call-integrations-design.md

## Global constraints

- Explicit opt-in; no debug-port opening, automatic restart or token extraction.
- Unknown and stale observations never mean ended. No stale roster reuse.
- macOS adapter only; no changes to Windows behavior.
- Preserve manual recording, stop hold, silence/duration limits and other apps.

## Review focus

- Disconnect or permission loss during recording must not end it.
- Target URL and debugger URL must stay within the explicit space and loopback.
- An overlay or empty AX tree cannot prove call exit.
- New room/session cannot inherit previous participants.
- Disabled/ignored integration cannot trigger or enrich a recording.

## Tasks

- [x] Package contract and KTalk resolver: tests for priority, prejoin, unknown, schema validation, room identity and freshness; implement minimal value types and resolver.
- [x] Live transports: native bounded CDP requests with reconnect, strict endpoint validation, read-only model projection; AX polling and restoration; test parsing/failure paths and cancellation.
- [x] Application bridge: opt-in settings, service lifecycle, filtered microphone trigger, unknown-aware stop clocks and call metadata separate from calendar; add recording regression tests.
- [x] Run focused package/app tests and app build, inspect final diff and document run instructions and verification limits.

Implementation stays in this session. After local implementation and disclosure
of its verification limits, the user explicitly authorized PR and merge to
`ekho/verbemo:master`. Preserve the opt-in default and the documented limitations.

## Execution ledger

- Baseline: `origin/master` 8579d3e; original checkout and diagnostic scripts preserved. Baseline 36 tests passed.
- Resolver and model tests observed RED on unknown/no-op stubs, then GREEN. Package 8 tests passed.
- Privacy lease and PCM filter tests observed RED on no-op stubs. CAF and live relay exercise actual post-filter samples. Root 94 focused tests passed after schema documentation/default-placeholder corrections.
- Native URLSession transport test passed against a synthetic HTTP/WebSocket server: mute, unmute, error→unknown, reconnect. This is not a live KTalk call.
- Ruling: native Swift package instead of a Node sidecar — avoids an extra shipped runtime; cost is maintaining the internal model projection in Swift resources.
- Ruling: unknown local mute closes microphone; AX-only fallback records remote audio — prevents private speech retention; cost is missing local speech without CDP.
- Ruling: 2-second in-memory holdback with 1.5-second permission lease — covers ordinary polling delay; cost is loss of up to final 2 seconds near mute/pause/stop and delayed local live transcription. Polling still cannot certify very short toggles between samples.
- Independent review found three issues: an idle-started recording had no gate, manual-start stop hold lost the integration ID, and a new CDP call could inherit permission at the same room URL. Each was reproduced RED and fixed; 61 focused tests passed. Added a regression for unknown startup becoming idle and then a muted call.
- Final full ordinary suite: 1448 tests in 194 suites passed; explicit app build passed. Opt-in hardware/model/gallery checks remain outside this result.
- Added separate package/transport checks to CI and release workflows. Path-selection tests passed (3); existing workflow-safety tests passed (18). These are local checks, not a remote CI run.
- The polling privacy limitation is also shown beside the opt-in setting. After that wording change, 36 settings/documentation tests passed and rebuilt the app/tests.
- Final diff checked. Evidence and remaining acceptance work: `docs/testing/2026-11-12-call-integrations.md`. No real call, hardware or Windows acceptance claimed; installed applications and user settings unchanged.
