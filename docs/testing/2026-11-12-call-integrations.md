# Call integration implementation checks — 2026-11-12

Local macOS implementation on `codex/call-integrations`, based on `8579d3e`.
Worktree: `/Users/ekho/.codex/worktrees/call-integrations/verbemo`.
This local verification snapshot was captured before commit, PR and remote CI.
The original checkout and earlier diagnostic scripts were preserved.

## Results

| Check | Result | Local evidence |
| --- | --- | --- |
| Root `swift test --no-parallel` | 1448 tests in 194 suites passed, 256.814 s | `/private/tmp/verbemo-call-final-full.log` |
| `swift build --product verbemo` | Passed | `/private/tmp/verbemo-call-app-build.log` |
| `swift test --package-path Packages/CallIntegrations` | 8 tests passed | `/private/tmp/verbemo-call-package-final.log` |
| Native probe build | Passed | `/private/tmp/verbemo-probe-build.log` |
| Python loopback transport test | 1 test passed | `Packages/CallIntegrations/Tests/test_transport.py` |
| CI path selection | 3 tests passed | `/private/tmp/verbemo-call-ci-green.log` |
| Existing workflow safety suite | 18 tests passed | `/private/tmp/verbemo-call-workflows.log` |
| Settings and documentation after privacy-warning edit | 36 tests passed; app and tests rebuilt | `/private/tmp/verbemo-call-settings-final.log` |
| Whitespace/error-marker check | `git diff --check` passed | Local working diff |

The full suite uses its normal opt-in exclusions; this does not establish real
model, audio hardware or GUI-gallery acceptance. Workflow checks used the pinned
PyYAML 6.0.3 in a temporary uv environment; system Python lacked that dependency.

The transport fixture drives the actual Swift URLSession HTTP and WebSocket
client against a synthetic loopback server: muted call, unmuted call, protocol
error with no retained metadata, then reconnection. It does not contact KTalk.

Audio tests inspect actual CAF samples and the live-audio relay after the privacy
filter. They verify delayed mute, permission expiry, pause, unmute after a gap,
safe tail flushing, frame/padding preservation and unchanged remote-track mute.
Integration tests cover prejoin, recording started before a call, unknown at
startup, manual-stop hold, different calls at the same URL and separate calendar
and observed-participant metadata.

Independent review found three defects. Each was reproduced by a failing test
and fixed before the final full run: missing gate on idle-started recordings,
lost provider identity on manual stop, and permissive same-URL call matching.

## Acceptance still required

- Enable the opt-in module in a local test build and use a synthetic KTalk room.
  Verify join/leave, participant changes, minimize, CDP loss/reconnect and AX
  fallback with the native implementation. Earlier diagnostic-tool results do
  not establish acceptance of this new implementation.
- Record distinct local and remote test phrases while toggling KTalk mute; read
  back both CAF tracks and check the live transcript. Exercise microphone route
  changes and manual pause/resume on actual hardware.
- Qualify a mute event source before promising strict privacy for very short
  mute/unmute cycles: polling can miss a cycle entirely between observations.
  The 2-second PCM holdback covers ordinary detection delay, not that case.

Unknown mute blocks local audio; AX-only fallback therefore captures remote
audio only. The holdback can discard the last 2 seconds before mute, uncertainty,
pause or stop and delays local live transcription. Recorded track frame timing
is preserved; existing live-preview timestamps are based on delivery time.

Installed Verbemo and KTalk were not updated or restarted, no diagnostic port was
opened, and no user setting was enabled. Windows integration is outside this
macOS implementation and was not verified.

See [configuration and architecture](../call-integrations.md).
