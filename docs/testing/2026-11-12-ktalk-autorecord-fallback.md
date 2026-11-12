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

A new system-audio test emitted `AUTHREQ_PROMPTING` for `kTCCServiceAudioCapture`
and awaits the user's response to that separate macOS prompt. Calendar remains
enabled in System Settings, but its old grant does not match this binary; no
calendar reset was performed. System-audio permission restoration and a new
call must precede claiming installed runtime acceptance.

KTalk was verified outside a call, quit and relaunched through LaunchServices
with `--remote-debugging-address=127.0.0.1 --remote-debugging-port=9333`.
`lsof` confirms a listener bound only to `127.0.0.1:9333`; `/json/version` and
`/json/list` respond. This establishes endpoint availability, not participant
capture during a real call. The flags apply to this KTalk launch only.
No additional integration-state or participant-capture probe was performed.

## Limits

Direct participant audio requires KTalk's explicitly enabled local diagnostic
port. The code fix does not open that port or change KTalk or user settings;
the separate user-approved local restart is recorded above.
Permission renewal after installation is described above. Ordinary detection
can treat prejoin microphone use as a call when exact participation is
unavailable. No new live multi-person call or
physical-device fallback acceptance has been performed. Windows is unchanged.
