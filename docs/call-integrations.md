# Call integrations on macOS

`Packages/CallIntegrations` is an independent Swift package without third-party
dependencies. `CallIntegrations` contains the public `CallIntegration` protocol
and Codable/Sendable observations; `KTalkIntegration` implements the protocol.
Future providers implement `id`, `application`, `observe()` and `stop()` and are
registered in `CallIntegrationMonitor.configuredProviders()`. Recording decisions
and audio capture consume the common types, never KTalk objects or CDP.
Providers with direct audio additionally implement `CallAudioIntegration`.

An observation carries a timestamp, participation (`unknown`, `idle`, `preparing`,
`inCall`), source, optional call identity/title/URL, optional participant roster,
local participant ID and local microphone/camera mute. `nil` roster is unknown;
an empty array is a known empty roster. A nil mute is unknown, never unmuted.
Providers own their transport lifecycle and must return unknown on failure.

## KTalk

Set `call_integrations.ktalk.enabled` to true and, for CDP, set `space_url` to an
exact HTTPS space origin. Settings have their own **KTalk integration** /
**Интеграция с KTalk** page and require restarting Verbemo. Existing Accessibility permission is optional. The adapter never opens
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

Fresh, known integration observations replace their own application's raw
microphone trigger. If the integration is unavailable or its observation is
older than five seconds, ordinary microphone-based detection remains available
for that application, so automatic recording can start with fallback capture.
This fallback has the same limits as ordinary detection: microphone use in a
prejoin screen can look like a call when exact participation is unavailable.
Other call apps keep the existing detection. A muted call remains in progress;
confirmed prejoin does not start recording. Unknown observation suspends the end-of-call
clock for a tracked call and cannot release the manual-stop hold. Existing
duration and silence backstops remain active.

Observed call metadata is saved under `call`, separately from calendar invitees.
Direct capture requires a fresh, unique joined application call. The session owns
asynchronous preparation, cancellation and one-way fallback. It does not report
active recording until a source is ready; Stop and quit wait for transport cleanup.

The CDP adapter clones existing KTalk output tracks, including the local outgoing
track. It does not request a new microphone or stop the original call tracks.
An AudioWorklet produces mono Float32 PCM on one audio clock, delivered via a
CDP binding. Metadata, frame ranges, sample rates, finite PCM, run/generation IDs,
message size and bounded queues are checked before disk writes. Heartbeats and
an expiring renderer lease detect transport failure without treating silence as
failure. Only the configured HTTPS origin and a loopback diagnostic socket are
accepted. Verbemo never exposes this endpoint as its own server.

Direct mode starts neither Verbemo device recorder and needs no microphone or
system-capture permission. The local clone follows KTalk mute, including a clone
created while muted. Verbemo pause writes zeros to all tracks and to live ASR.
KTalk's internal tracks and mute state are sampled; use Verbemo pause when you
need a capture boundary independent of KTalk's internal implementation.

Unavailable direct capture or transport failure closes the direct source, then
starts ordinary microphone and system capture in the same meeting. **Fallback
records the device microphone independently of KTalk mute or unknown state.**
The normal pause still applies. Device/permission failure stops the session and
persists `capture_failure` alongside all captured audio. Confirmed call exit does
not trigger fallback; automatic recording follows the existing end-of-call rules.
There is no automatic return to direct mode until the next recording.

`call_audio` version 1 supplements `files` and `start_offset_ms` with capture
periods, participant IDs/names, local/remote provenance, source generations,
sample rates and stable speaker IDs. Generated file keys never use participant
text. Replaced tracks have independent files on the same timeline. Both the
recovery manifest and final metadata preserve this index. Each nonempty source
is archived separately to AAC; metadata is atomically published before original
CAF files are removed. Empty tracks retain their empty CAF. Legacy ordinary
sessions keep their two-channel archive format. MCP exposes validated referenced
files through its existing authenticated audio interface.

Known tracks use per-track final ASR and dynamic live ASR consumers; identity
comes from KTalk, not acoustic speaker matching. Local diarization and cloud
speaker-label switches are bypassed where the existing provider supports it.
A configured OpenAI model that performs diarization internally is not replaced.
Hybrid fallback audio retains normal diarization settings and unknown labels
when identity cannot be established. Manual names survive retranscription.
Summary generation continues to consume the canonical transcript as before.

## Verification

```sh
swift test --package-path Packages/CallIntegrations
swift build --package-path Packages/CallIntegrations --product call-integration-probe
python3 Packages/CallIntegrations/Tests/test_transport.py \
  Packages/CallIntegrations/.build/debug/call-integration-probe
node --test Packages/CallIntegrations/Tests/audio_capture.test.mjs
swift test --no-parallel --filter 'Participant|CallIntegration|AutoRecord|RecordingSession|KTalkSettings|TrackCompressor|MCPQueries'
```

The probe takes an explicit space, port and sample count and prints JSON through
the universal interface without Accessibility. Add `--audio` for bounded direct-audio diagnostics
(metadata and sample/peak counts, not raw PCM):

```sh
swift run --package-path Packages/CallIntegrations call-integration-probe \
  https://SPACE.ktalk.ru 9333 20
```

Its stdout contains participant names and should be treated as private. Network
tests use a synthetic loopback HTTP/WebSocket server; PCM tests inspect actual
CAF samples and the live-audio relay. Windows is not implemented by this package.

CI and the common release workflow run both the package tests and the native
transport fixture separately from the application tests.
