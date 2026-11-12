# Call integration modules

The user approved CDP + Accessibility fusion for KTalk and requires a universal
interface for future calling-app modules. Implement the first adapter on macOS.

## Design

A dependency-free local Swift package exposes `CallIntegration` and value types
for provider/application identity, observation time, participation, call metadata,
participants, source and availability. A separate `KTalkIntegration` target owns
CDP, Accessibility and source arbitration. Verbemo consumes only the common
contract; the composition root constructs the concrete provider.

Use an explicit opt-in configuration. Never enable a debug port, restart KTalk,
extract a session token or prompt for Accessibility automatically. Missing CDP
and denied AX are ordinary unknown states. Windows is outside this macOS adapter.

Prefer fresh CDP participation; use AX if CDP is unavailable/unsupported. Missing
controls are unknown, not idle. Never attach an old roster to a new/unknown call.
Ambiguous simultaneous calls remain unknown. A disconnected observer cannot
finish an automatic recording or reset a manual-stop hold. Explicit idle/prejoin
can start the existing stop-delay clock. Preserve silence/duration backstops.

The app polls integrations off the recording timer, applies the existing
whitelist/ignore settings, excludes managed applications from the raw microphone
trigger, and uses a fresh integration observation for trigger/context. Keep
calendar metadata separate from observed call metadata. Other calling apps keep
their existing microphone-based behavior.

## Alternatives

- Extending `MicActivityMonitor` with KTalk details is smaller initially but
  violates the requested boundary and loses unknown/metadata information.
- A dynamically loaded plugin host or external Node helper adds deployment and
  lifecycle machinery without a current need.
- Chosen implementation: native Swift package, a small common protocol, separate
  vendor target and a thin application bridge. This is the implementation choice
  for the already approved combined approach, not a new product capability.

## Local microphone privacy (additional user requirement)

The interface carries local mute separately from participation. For recordings
associated with an integration, microphone audio is allowed only while a fresh
observation explicitly says unmuted. Muted, stale, unknown, stopped observation
or a different call closes it. System audio continues. Apply this before both
file writing and live ASR, including manual pause/resume and route rebuilds.
Polling has latency: use a bounded in-memory holdback for local PCM, invalidate
pending audio on mute/uncertainty, and expire permission on the audio callback
even if the UI thread stalls. Held audio must never be flushed raw on stop.
Document and measure the observation/holdback timing; do not promise an
instantaneous or vendor-guaranteed mute event.

## Verification

Focused tests cover source priority, stale/unavailable observations, prejoin,
muted calls, safe URLs, schema changes, target identity and participant freshness.
App tests cover false-start prevention, fallback, unknown during recording,
manual-stop hold, metadata and unchanged behavior of other apps. Build the app;
separate transport/live acceptance from synthetic tests. No publish/merge.
