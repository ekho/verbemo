# Call integrations on macOS

`Packages/CallIntegrations` is an independent Swift package without third-party
dependencies. `CallIntegrations` contains the public `CallIntegration` protocol
and Codable/Sendable observations; `KTalkIntegration` implements the protocol.
Future providers implement `id`, `application`, `observe()` and `stop()` and are
registered in `CallIntegrationMonitor.configuredProviders()`. Recording decisions
and microphone privacy consume the common types, never KTalk objects or CDP.

An observation carries a timestamp, participation (`unknown`, `idle`, `preparing`,
`inCall`), source, optional call identity/title/URL, optional participant roster,
local participant ID and local microphone/camera mute. `nil` roster is unknown;
an empty array is a known empty roster. A nil mute is unknown, never unmuted.
Providers own their transport lifecycle and must return unknown on failure.

## KTalk

Set `call_integrations.ktalk.enabled` to true and, for CDP, set `space_url` to an
exact HTTPS space origin. Settings are in Advanced and require restarting
Verbemo. Existing Accessibility permission is optional. The adapter never opens
a debug port, changes installed KTalk files, reads session tokens, joins a call,
or requests system permission. To use CDP, fully quit KTalk and explicitly start
it with the diagnostic flags used in the research:

```sh
open -a '/Applications/Толк.app' --args --remote-debugging-address=127.0.0.1 --remote-debugging-port=9333
```

This port gives other local processes access to the KTalk session. Close it by
fully quitting and reopening KTalk normally. Missing CDP triggers AX fallback.
AX recognizes participation but does **not** claim a complete roster or local
mute. Missing controls, ambiguous windows and unsupported schemas mean unknown.
The adapter depends on internal KTalk 3.8 web objects and UI labels.

## Recording and privacy

Enabled integrations replace their own application's raw microphone trigger.
Other call apps keep the existing detection. A muted call remains in progress;
prejoin does not start recording. Unknown observation suspends the end-of-call
clock for a tracked call and cannot release the manual-stop hold. Existing
duration and silence backstops remain active.

Observed call metadata is saved under `call` in session JSON, with source and
observation time. It is separate from calendar invitees and does not automatically
assign speaker identities. Context is refreshed during an associated recording;
loss of observation clears the currently reported roster.

While an integration is enabled, every recording has a microphone gate, including
manual/calendar recordings and recordings of other apps. This covers recordings
started before joining a call. Before a call is associated, fresh confirmed idle
state permits the mic; unknown state blocks it even in an unrelated recording.
For an associated call, the local mic gets a **1.5-second permission lease**,
renewed only by explicit fresh unmuted observations of the same call.
The audio callback checks expiry independently of
the UI thread. CDP requests are bounded to 700 ms and the monitor waits 200 ms
between samples; these are polling intervals, not guaranteed mute-event times.

Local PCM is held in memory for **2 seconds**, before file writing and live ASR.
Mute/unknown/lease expiry invalidates held buffers permanently, even after
unmute. Manual pause also invalidates pending buffers. Stop writes pending frames
as silence, never raw audio. The remote track is unaffected and recorded track
frames remain aligned. Local live transcription receives audio about two seconds
later; the existing live preview timestamps reflect delivery time. This
intentionally loses up to the final two seconds before mute,
pause, uncertainty or stop. AX-only fallback keeps the local mic silent.

Polling cannot prove that a very short mute/unmute entirely between samples did
not happen. This mode is not a vendor-supported instantaneous privacy interlock;
use Verbemo's own pause for that guarantee until a reliable mute event source is
qualified. A real call acceptance test is separate from deterministic PCM tests.

## Verification

```sh
swift test --package-path Packages/CallIntegrations
swift build --package-path Packages/CallIntegrations --product call-integration-probe
python3 Packages/CallIntegrations/Tests/test_transport.py \
  Packages/CallIntegrations/.build/debug/call-integration-probe
swift test --filter 'MicrophonePrivacy|CallIntegration|AutoRecord|RecordingSessionTests|SettingsSchemaTests|SettingsDocumentationTests'
```

The probe takes an explicit space, port and sample count and prints JSON through
the universal interface without audio capture or Accessibility:

```sh
swift run --package-path Packages/CallIntegrations call-integration-probe \
  https://SPACE.ktalk.ru 9333 20
```

Its stdout contains participant names and should be treated as private. Network
tests use a synthetic loopback HTTP/WebSocket server; PCM tests inspect actual
CAF samples and the live-audio relay. Windows is not implemented by this package.

CI and the common release workflow run both the package tests and the native
transport fixture separately from the application tests.
