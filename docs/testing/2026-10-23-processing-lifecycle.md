# macOS processing lifecycle: issue #42

`ProcessingOperations` owns each run through cancellation and cleanup. The integration preserves per-job summary/diarization requests, `SessionClaim`, reusable queue engines, original recordings and completed transcript versions. The consumer contract and exclusions for shutdown/Journal cancellation are in [processing-lifecycle.md](../processing-lifecycle.md).

## Automated evidence

Deterministic regressions cover waiting reservations; running cancellation and cleanup; close admission and recording handoff; repeated cancellation; completion/cancellation races; expired inherited task context; two meetings and later generations; nested stages; the serial barrier; cancelled sweep coalescing; explicit retry and later recovery; import children; current/archived summary preservation; speaker attempts; shared download consumers; native-release barriers; and direct hook process termination while holding the session claim.

Red/green checks reproduced publication and source deletion after a non-cooperative inference was cancelled, accidental engine preparation once per meeting, and closed admission bypassed by inherited context. Each was fixed before the passing runs. The shared Nemotron download UI fixture now waits for its injected install completion rather than depending on a one-second scheduler window; its product behavior is unchanged.

The final product sources include `master` PR #43 (per-job diarization) at `3065f65ced52223d634522281ec3f04ba0adf1ef`. The later version commits and PR #46 were also integrated through `27fea1b` (0.9.1). The final import cancellation closure first unwraps an immutable owner; this removes the captured weak-variable error seen with the CI Swift compiler (Xcode 26.6), while preserving cancellation/restart behavior. Local checks use Xcode 27.1 / Swift 6.4; CI compiler acceptance remains a separate gate.

Final local check after #46 and the import capture fix: `VERBEMO_REQUIRE_LOCALVQE=1 swift test --no-parallel` — **1,140 tests in 165 suites passed**, 149.335 seconds, with 20 opt-in/gallery skips; `/tmp/verbemo-42-current-master-full.log`. The debug build used for the repeated native smoke below comes from these product sources.

Earlier local checks:

- `VERBEMO_REQUIRE_LOCALVQE=1 swift test --no-parallel`: **1,135 tests in 164 suites passed**, 144.788 seconds; `/tmp/verbemo-42-integrated-full.log`. Twenty opt-in interactive/gallery checks were skipped. SwiftPM also built the debug executable.
- After adding the global cancellation/cleanup barrier regression, `swift test --no-parallel --filter ProcessingOperationsTests`: **8 tests in 1 suite passed**, 0.004 seconds; `/tmp/verbemo-42-global-test.log`. Seven tests overlap the full run; no product source changed after it.
- `python3 Tests/scripts/test_independent_product.py --all`: passed.
- `git diff --check`: passed. Independent read-only review and an additional #29 integration review found no remaining substantial issue after fixes.

An earlier parallel run was aborted after subprocess timeouts while other builds were running. The first serial full run failed only the existing Nemotron UI timing fixture; it passed in isolation and the explicit fixture gate above removed the timing dependency. Neither earlier run is represented as passing. Initial PR CI run `39858753764` failed during compilation on the mutable weak capture in the import cancellation handler; it did not run the Swift tests or finish packaging. The immutable owner fix above is part of the final source, and the final-head workflow must establish CI success.

## Native smoke

Computer Use exercised the real ad-hoc application `.build/lifecycle42-smoke/Verbemo-Lifecycle42.app`, bundle ID `name.ekho.verbemo.lifecycle42`, with `CFFIXED_USER_HOME` pinned to `.build/lifecycle42-smoke/home`. Two fictional meetings contain synthetic transcripts and existing summaries. Auto recording, calendar, transcription, live recognition, automatic summaries and speaker naming are disabled. The profile supplies its own local fake Codex/Claude commands; no user credentials or paid/cloud calls are used.

The final binary includes the #46 integration and import capture fix: debug executable SHA-256 `559c01894a4eb9aec61e9512ab585188fefb3bb6263a0b2f9d5b71a2dc6f5454`; ad-hoc signed executable SHA-256 `e4dbf6df4b02553356c47b240964f2be4852fd98ff763ffe7e8d6e4b1b8a1380`.

Verified through the actual Journal window and summary sheet:

- Open the first meeting, choose Codex for this summary only and start the fake provider in hold mode. The sheet shows processing with its provider/create controls disabled. A live child PID 4193 and the app's session claim were confirmed independently.
- Click Cancel. The sheet closes and the old summary remains visible. The fake child receives SIGTERM and exits; its completion marker exists and the claim is gone. SHA-256 checks retain the prior summary, transcript JSON/Markdown and metadata, and all four artifacts of the independent meeting.
- Explicitly open the sheet again and choose the same provider in success mode. The child PID 4467 exits normally, the claim is released, and the new Russian summary appears. The regenerate action is available again. Transcripts, metadata and the independent meeting remain unchanged.
- Select the independent meeting; its old summary is still displayed. Quit only the isolated app after processing completed.

Receipts: `/tmp/verbemo42-smoke/running-checks.json`, `cancelled-checks.json` and `succeeded-checks.json`; baseline under `.build/lifecycle42-smoke/baseline.json`. AX observations and screenshots were obtained through Computer Use. Earlier app-selection calls stalled and were interrupted; they launched no summary and are not counted as successful smoke. The completed flow was repeated after the final integration/fix.

This checks the existing summary-sheet cancellation wired into the shared lifecycle, not the future Journal cancellation action from #30. The fake command establishes real GUI/subprocess/claim behavior, not an actual Codex service response or native speech inference.

## Scope and limitations

This work does not implement final AppKit/signal shutdown (#7) or the Journal cancellation action/status (#30). Live recording and its existing retirement tasks remain separately owned; #7 must await the original recording handoff and retain/drain older live retirees. The registry cannot claim completion of unrelated processes or services.

A user `on_stop` hook now waits for its directly launched process. A long hook holds the claim and serial transcription/diarization until exit/cancellation; a same-meeting CLI writer invoked by that hook sees a busy claim. The command owns arbitrary descendants. Shared downloads remain consumer-aware. Native inference and synchronous conversion must return before cleanup can complete; no timeout is described as successful cancellation.

Real Whisper/Metal/cloud inference, physical recording, recognition accuracy, full VoiceOver and Windows runtime are not verified by these lifecycle tests. Windows product code is unchanged. Local debug checks do not establish universal packaging, CI success or unsigned preview publication; those require their separate workflow evidence.
