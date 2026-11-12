# KTalk automatic recording fallback — 2026-11-12

## Report and installed state

The reported symptom was that recording never started automatically, rather
than a started recording containing silence. Inspection found Verbemo 0.23.0
(734), KTalk 3.8.0.13562, automatic recording and KTalk integration enabled,
and no listener on the configured loopback CDP port 9333. Verbemo displayed
that it was waiting for a confirmed KTalk call. Microphone access was allowed.
The latest manually started recording had a fallback period with reason
`unavailable`, so fallback capture had been reached through manual start.

The failed call was no longer active. These observations do not establish the
exact integration state or microphone activity at the time of that call.

## Reproduction and cause

The regression runs the real `AutoRecordController`, `CallIntegrationBridge`
and `MicActivityMonitor.evaluate` against one synthetic KTalk helper holding
the microphone and an unknown integration observation, with a fixed clock.
It requires the automatic start callback after the configured start delay.

```sh
swift test --no-parallel --filter \
  CallIntegrationRecordingTests/unknownCallIntegrationFallsBackToMicrophoneAutostart
```

Before the fix it failed twice: `starts == 1`, actual `starts == 0`.
Removing call metadata and output-device activity preserved the failure.
The minimal test ran in 0.002 seconds, excluding compilation and test launch.

`AutoRecordController.tick` excluded every enabled integration's application
from ordinary microphone detection, including unknown and expired observations.
With no confirmed call, neither detection path could start the session. The
fallback audio implementation was never reached. `CallIntegrationBridge`
preserves an incoming active microphone signal, and the normal start timer
does not independently veto unknown integration state.

The fix excludes an application's ordinary trigger only while its integration
has a known observation between zero and five seconds old. Existing user app
filters, confirmed prejoin/idle suppression, and manual-stop holds remain in
effect. Unknown observations still suspend the end-of-call clock for a
previously tracked integration call.

## Verification

- The regression and related detection, manual-stop and participant fallback
  suites passed: 41 tests / 5 suites in 2.529 seconds.
- Regression cases include unknown observations and expired in-call, idle and
  prejoin observations. Fresh idle/prejoin still suppress raw microphone starts.
- Full `swift test --no-parallel` passed: 1482 tests / 201 suites in 310.027
  seconds. Optional hardware/model and gallery checks remain skipped; this is
  not evidence of a new real call.
- `make app MACOS_PREVIEW=1` passed. The universal x86_64/arm64 application,
  nested signatures, macOS 14.2 compatibility and Nemotron helper verification
  passed. The installed executable matches the built executable.

## Local installation

Verbemo 0.23.0 (736), built from `92a871b` plus this working-tree fix, was installed
and launched through LaunchServices. The preview marker was preserved, and the
configuration file hash was unchanged. Build 734 was retained at
`.build/installed-backups/Verbemo-0.23.0-734-before-ktalk-autostart.app`.

The fresh ad-hoc build does not match the old permission grants. The macOS TCC
log explicitly reports `Failed to match existing code requirement` for
Microphone, Calendar and AudioCapture. Initially the UI blocked automatic
recording until microphone access was restored; the system-audio badge retained
an earlier successful check and did not prove access for this new build.

Toggling the existing microphone grant and restarting did not restore access.
A reset scoped to `Microphone name.ekho.verbemo`, followed by a restart, produced
a real TCC microphone request. After the user granted it, the installed UI was
verified showing `Микрофон разрешён` and `Автозапись включена`.

A new system-audio test emitted `AUTHREQ_PROMPTING` for `kTCCServiceAudioCapture`.
That first attempt returned silence. After the user granted access, a fresh
test passed and the installed UI showed `Звук системы: недавняя проверка звуком
пройдена`. This verifies the built-in system-audio tone probe on build 736;
a new real call is still needed for end-to-end recording acceptance.

No calendar reset was performed. During the later call check the installed UI
also showed calendar access granted. Calendar-triggered recording is disabled
in the inspected configuration and was not tested.

KTalk was verified outside a call, quit and relaunched through LaunchServices
with `--remote-debugging-address=127.0.0.1 --remote-debugging-port=9333`.
`lsof` confirms a listener bound only to `127.0.0.1:9333`; `/json/version` and
`/json/list` respond. This establishes endpoint availability, not participant
capture during a real call. The flags apply to this KTalk launch only.
The initial endpoint check did not inspect participation or capture audio; the
subsequent live checks are recorded below.

## Live call follow-up

A new single-participant room was created in the installed KTalk 3.8.0.13562.
Before joining, Verbemo 736 automatically started ordinary microphone/system
recording, with `trigger: mic-activity` and no call metadata. Its microphone
meter showed a signal, and readback of the completed two-channel AAC file found
channel 1 peak -32.21 dBFS (RMS -60.41 dBFS). Channel 2 was effectively silent,
as expected without a remote speaker. Capture had no failure; after the test
recording was paused for diagnosis, it eventually ended with reason `silence`.

The KTalk call was joined with its microphone and camera off. The native
integration probe still returned `unknown` twice despite the joined UI, a
working loopback endpoint and matching space origin. A minimal check asserting
`inCall` failed in 0.205 seconds. A read-only projection of field types showed
`joined: true`, valid participant fields, and an absent `roomInfo.title`.
The production expression returned `unsupported_schema` solely because the
room title was not a string; the other same-space window had no conference.

The title is already optional in `CallInfo`. The follow-up fix makes it optional
in both the shared JavaScript projection and the Swift room decoder, preserving
the required participation, room identity and participant validation. The same
expression is used by observation and direct-audio startup verification.

`unnamedRoomPreservesParticipationThroughProjection` executes the actual
JavaScript expression with JavaScriptCore, then decodes it with `KTalkModel`.
Both prejoin and joined cases failed before the fix (`unknown`, missing call)
and passed after it in 0.008 seconds. Repeating the native probe against the same
live call then returned `inCall` with source `application`. A bounded direct-audio
probe completed successfully with one track, a heartbeat and four PCM chunks
(16,384 samples, zero peak while KTalk was muted), and cleaned up its capture.

Follow-up package verification passed: 13 Swift tests / 4 suites, six native
HTTP/WebSocket transport tests, and three JavaScript audio-capture tests.
The full root `swift test --no-parallel` run also passed again: 1482 tests /
201 suites in 298.335 seconds.

## Installed build 740 call checks — 2026-11-13

`make app MACOS_PREVIEW=1` passed again from commit `422ecef`, producing
Verbemo 0.23.0 (740), universal x86_64/arm64. Bundle signatures, macOS 14.2
compatibility and the Nemotron helper checks passed. This local build replaced
736; the previous bundle remains at
`.build/installed-backups/Verbemo-0.23.0-736-before-unnamed-call.app`.
The installed executable matches the built executable, and the configuration
hash still matches the pre-test configuration.

The first native UI check joined an unnamed room with KTalk's microphone and
camera off. Verbemo automatically entered direct capture and displayed the
KTalk source badges. No participant track was produced in this muted-from-start
room. On exit, capture attempted its fallback, which failed because the new
ad-hoc build initially lacked its microphone grant. The 74-second session ended
as `capture-failed`; a running timer alone was not treated as audio acceptance.

After invoking Verbemo's microphone permission action, its UI showed microphone
and calendar access granted again, without another permission reset. A fresh
system-audio tone probe passed on November 13. Calendar recording was not tested.

With the microphone enabled in KTalk, ordinary recording automatically started
while the prejoin integration observation was unknown. The call was then joined
and left through the native UI. Verbemo stopped automatically with
`stop_reason: call-ended`, duration 118 seconds, and no capture failure. The
saved two-channel AAC file decoded successfully: microphone peak -35.47 dBFS,
RMS -58.95 dBFS; the other channel was effectively silent without a remote
speaker. This confirms the prejoin fallback tradeoff also occurs on the installed
client; it is not merely a hypothetical limitation.

A recording that already started through the ordinary path did not switch to
direct capture when the integration subsequently recognized the call. To verify
direct audio separately, that test recording was stopped and a new recording
was started manually inside the recognized call, with the user's permission to
transmit microphone audio into the otherwise empty room. The camera remained off.

The installed UI showed separate KTalk participant tracks, and the manifest
contained one growing participant file. Closing the room disconnected the CDP
socket; Verbemo switched to ordinary microphone/system capture. Its source label
changed to fallback and the physical microphone file grew. The recording was
then stopped manually and saved without a capture failure. Its 141-second
metadata contains a direct period from 213 to 116,671 ms and a fallback period
from 116,766 to 140,900 ms, retaining the participant track.

Both saved compressed tracks decoded successfully: the direct KTalk track had
5,587,456 samples, peak -53.23 dBFS and RMS -77.13 dBFS; the physical microphone
fallback had 1,147,200 samples, peak -51.20 dBFS and RMS -64.64 dBFS. These are
nonzero input signals, not confirmation of intelligible speech. The user did not
confirm speaking the requested test phrase before this probe ended. No remote
participant joined, and the system track had no audio samples. The native test
therefore establishes direct local audio persistence and fallback after room
closure, not remote speech or continuity after a transport failure mid-call.
The direct track metadata identifies it as local, with a 48 kHz sample rate and
512 missing frames; this probe does not establish gap-free capture.

## Limits

Direct participant audio requires KTalk's explicitly enabled local diagnostic
port. The code fix does not open that port or change KTalk or user settings;
the separate user-approved local restart is recorded above.
Permission renewal after installation is described above. Ordinary detection
can treat prejoin microphone use as a call when exact participation is
unavailable, and that recording retains its ordinary source after recognition.
Remote participant speech, intelligibility of local speech and fallback
continuity during an ongoing call remain unverified. Native direct autostart was
observed in a muted room; nonzero direct audio was verified in a separate manual
recording. Windows is unchanged.
