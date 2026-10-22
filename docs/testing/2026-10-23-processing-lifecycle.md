# macOS processing lifecycle: issue #42

`ProcessingOperations` owns each run through cancellation and cleanup. The integration preserves per-job summary/diarization requests, `SessionClaim`, reusable queue engines, original recordings and completed transcript versions. The consumer contract and exclusions for shutdown/Journal cancellation are in [processing-lifecycle.md](../processing-lifecycle.md).

## Automated evidence

Deterministic regressions cover waiting reservations; running cancellation and cleanup; close admission and recording handoff; repeated cancellation; completion/cancellation races; expired inherited task context; two meetings and later generations; nested stages; the serial barrier; cancelled sweep coalescing; explicit retry and later recovery; import children; current/archived summary preservation; speaker attempts; shared download consumers; native-release barriers; and direct hook process termination while holding the session claim.

Red/green checks reproduced publication and source deletion after a non-cooperative inference was cancelled, accidental engine preparation once per meeting, and closed admission bypassed by inherited context. Each was fixed before the passing runs. The shared Nemotron download UI fixture now waits for its injected install completion rather than depending on a one-second scheduler window; its product behavior is unchanged.

The final product sources include `master` PR #43 (per-job diarization) at `3065f65ced52223d634522281ec3f04ba0adf1ef`. The later `d355de02739d780803e7ee8e5bb10e3a70412d44` contains only version/changelog/release notes and was also integrated.

Local checks:

- `VERBEMO_REQUIRE_LOCALVQE=1 swift test --no-parallel`: **1,135 tests in 164 suites passed**, 144.788 seconds; `/tmp/verbemo-42-integrated-full.log`. Twenty opt-in interactive/gallery checks were skipped. SwiftPM also built the debug executable.
- After adding the global cancellation/cleanup barrier regression, `swift test --no-parallel --filter ProcessingOperationsTests`: **8 tests in 1 suite passed**, 0.004 seconds; `/tmp/verbemo-42-global-test.log`. Seven tests overlap the full run; no product source changed after it.
- `python3 Tests/scripts/test_independent_product.py --all`: passed.
- `git diff --check`: passed. Independent read-only review and an additional #29 integration review found no remaining substantial issue after fixes.

An earlier parallel run was aborted after subprocess timeouts while other builds were running. The first serial full run failed only the existing Nemotron UI timing fixture; it passed in isolation and the explicit fixture gate above removed the timing dependency. Neither earlier run is represented as passing.

## Native smoke

Pending the isolated native application result; this section must be completed before delivery.

## Scope and limitations

This work does not implement final AppKit/signal shutdown (#7) or the Journal cancellation action/status (#30). Live recording and its existing retirement tasks remain separately owned; #7 must await the original recording handoff and retain/drain older live retirees. The registry cannot claim completion of unrelated processes or services.

A user `on_stop` hook now waits for its directly launched process. A long hook holds the claim and serial transcription/diarization until exit/cancellation; a same-meeting CLI writer invoked by that hook sees a busy claim. The command owns arbitrary descendants. Shared downloads remain consumer-aware. Native inference and synchronous conversion must return before cleanup can complete; no timeout is described as successful cancellation.

Real Whisper/Metal/cloud inference, physical recording, recognition accuracy, full VoiceOver and Windows runtime are not verified by these lifecycle tests. Windows product code is unchanged. Local debug checks do not establish universal packaging, CI success or unsigned preview publication; those require their separate workflow evidence.
