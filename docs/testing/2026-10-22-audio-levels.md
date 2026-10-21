# macOS audio levels (#26)

## Behavior

Journal's two source placeholders are now read-only native level indicators.
Each shows the peak already measured by its recorder, on a −60…0 dBFS scale.
There is no extra capture, audio copy, or dispatch to the UI from the capture
callback. The recorder's existing lock holds a few scalar values; a main-run-loop
timer polls the mounted live view every 100 ms, with immediate lifecycle refreshes.
Peak hold is bounded to 200 ms, including while the view is hidden. A source with
no measurement for 500 ms becomes unavailable instead of retaining its last bar.

States are localized in English and Russian:

- Signal: a finite measured peak, with its dBFS value (values below −60 are labeled).
- Silence: an actual measured zero, not inferred from absent buffers.
- Paused: capture continues but the recording writes silence; both meters are empty.
- Off: the recorder is not running.
- Unavailable: no fresh, measurable samples, including startup and route rebuilding.

Pause/resume, capture attachment/restart, stop and system tap scope changes clear
the accumulated peak. Empty buffers do not refresh the meter. Existing silence
watchdog semantics and recording/transcription configuration remain in place.
No new per-source enable/disable controls were added. A hardware mute that delivers
zero samples is indistinguishable from digital silence without device-specific
information; the meters do not claim to detect such a mute.

The shared peak reader now respects interleaved PCM stride. The regression test
previously read 0.125 instead of the actual 0.75 peak in the final right-channel
sample. Pause buffers are zeroed across the complete audio buffer list without
modifying the captured buffer.

## Automated and build evidence

Base: `f08bf3458731ffb570b2de52b28df67e388c9e87` (`origin/master`). Work was isolated
in `codex/26-audio-levels`; no Windows sources or issue #6 changes are included.

- Baseline: 12 tests in `AudioLevelTests` and `RecordingSessionTests` passed.
- Focused run: 23 tests in six suites passed before the additional int16 and
  bounded-hold cases were added.
- Final `swift test --no-parallel`: **1031 tests in 147 suites passed**, 122.346 s.
  The log contains 21 opt-in skipped test cases (model/corpus/hardware acceptance
  and screenshot galleries). These are not claimed as executed acceptance.
- `make app`: succeeded with the ordinary build recipe. Ad-hoc signed application
  contains `x86_64 arm64`, passes code-signature verification and the macOS 14.2
  compatibility check. Native helper verification also passed.
- `git diff --check`: passed.
- Independent read-only review found an obsolete test requiring the old missing
  feature placeholders; it was removed because the new Journal meter tests cover
  the replacement behavior. No production-code findings were reported.

Tests cover float and int16 peaks, planar/interleaved stereo, a clipped negative
int16 sample, source independence, bounded peak hold, expiry, invalid measurements,
pause/resume/off/reset, untouched input buffers, localized AX values and narrow
window layout. They do not substitute for physical device switching.

Local logs: `/tmp/verbemo-26-full-final.log`, `/tmp/verbemo-26-universal.log`.
The first full run failed solely on the obsolete placeholder assertion. An initial
debug-only packaging attempt reached its universal-architecture check and failed
as expected for arm64; the subsequent ordinary universal build passed. Copied CMake
caches initially referenced the original checkout; only the generated build
directories in this worktree were recreated before that successful build.

## Native capture and accessibility evidence

Checks used a separate `name.ekho.verbemo.audiolevels26` bundle, with
`LSEnvironment.CFFIXED_USER_HOME` pinned to the worktree's
`.build/audio-levels-home`. The installed application was not replaced. Calendar,
automatic recording, transcription, live text, summaries and speaker naming were
disabled in the test profile. Only explicitly created test recordings were used.

The GUI capture checks ran on the arm64 debug build (executable SHA-256
`f232f7ce71525c1f84efe2932db8378a0013a91142a514be52c59ebb5ffd2010`). The independently
built universal release executable has SHA-256
`add71bf9491861e686809c3bb09d65c300d9dce04801981df4b1ec3e259297a9`.
The universal build was not substituted for the debug build during capture.

Observed through the native UI:

- A fresh test recording showed separate microphone and system indicators.
- Playing a generated 440 Hz tone through the real output/tap path produced
  `Signal · −36 dBFS` on the system indicator, independently of the microphone.
- Pause immediately changed both to `Paused` with empty bars. Resume returned to
  current microphone measurements and actual system silence; replaying the tone
  restored the system signal. Stop returned to the saved meeting.
- Both AX elements expose `level indicator`, localized source label, the dBFS
  scale help, numeric value and a readable value description. The implementation
  sends no explicit VoiceOver announcements or live-region events.
- A second short native test showed microphone `−39 dBFS` and system `−12 dBFS`
  during system speech. This is not a controlled microphone calibration test.

The first recording's metadata reports 197 s elapsed and 135 s paused. The normal
archive path produced a readable 192.453 s stereo `audio.m4a` with microphone on
channel 0 and system on channel 1. Decoding that saved file with ffmpeg gave:

| Saved interval | Microphone peak | System peak |
| --- | ---: | ---: |
| 24–38 s (test tone) | 0.000476 | 0.015157 |
| 60–170 s (inside pause) | 0 | 0 |
| 183–190 s (tone after resume) | 0.000829 | 0.015154 |

Both test sessions were stopped; no recording markers, transcript or summary
artifacts remained. The Bluetooth input/output route was used as configured;
device defaults were not changed. Test audio was not added to Git.

Local screenshots, AX snapshots and numeric measurements are under
`/Users/ekho/.codex/visualizations/2026/10/21/01a16055-69c3-76c3-9a5f-97712ab581be/audio-levels/`
(`signal`, `paused`, `resumed`, `resumed-signal`, `stopped`, and
`recording-measurements.json`). The parent directory follows the chat creation
date; checks took place on October 22 in Europe/Moscow.

## Remaining acceptance limits

- Full VoiceOver narration/navigation is **not verified**. The OS toggle was
  enabled and first-run onboarding appeared, but the UI driver repeatedly timed
  out and entered the tutorial. A live-text checkbox was briefly toggled in the
  isolated profile during this attempt; it reported a missing local model and was
  immediately disabled again. No transcript was produced. The VoiceOver toggle
  was verified back at its original **off** state and the tutorial was closed.
  AX semantics above were verified separately. In particular, quiet behavior
  during focused VoiceOver updates still needs a human check.
- Physical microphone unplug/replug, switching devices during capture, denied
  permissions and a lost system tap were not exercised on hardware. Their stale
  reading/reset behavior has unit coverage and code review only.
- No long meeting, speech-quality evaluation, Intel runtime, Windows host test,
  Developer ID signing, notarization, merge or release was performed.
