# Windows Journal validation

The Journal port was exercised on Windows 11 ARM64 (build 26200) in Parallels,
using the x64 .NET SDK 10.0.402. This is Windows runtime evidence under x64
emulation, not physical x64 hardware acceptance.

## Automated checks

```powershell
dotnet test windows/Verbemo.Windows.slnx -c Release
dotnet build windows/src/Verbemo.App/Verbemo.App.csproj -c Debug
```

The player preference, track-offset, list-refresh, timestamp-link and audio-level
tests do not require an audio output device. The native asynchronous seek test
does: `Native_seek_waits_for_loading_and_stays_paused_after_unload` is explicitly
skipped when Windows reports zero playback devices. GitHub's Windows Server
runner reported `audio-devices=0`, a paused clock and `NaturalDuration=Automatic`;
it did not complete native media opening. A green headless run therefore does
not establish playback acceptance.

Before release, also run on a Windows desktop with a playback device and require
one passed test, zero skipped:

```powershell
dotnet test windows/tests/Verbemo.Live.Tests/Verbemo.Live.Tests.csproj -c Release --filter FullyQualifiedName~Native_seek_waits_for_loading_and_stays_paused_after_unload
```

## Interactive checks on 2026-10-22

An isolated DEBUG profile was used via `VERBEMO_TEST_DATA`; release builds ignore
this override. The profile contained fictional meetings and silent WAV fixtures.
Automatic recording, live transcription, transcription and summaries were off.

Verified in the actual Windows interface:

- Light and dark Journal appearance; persistent meeting list while opening settings.
- Search, meeting selection and named-recording dialog cancellation.
- Compact window layout and keyboard-operated details-panel toggle.
- Playback to the end after a cold app start, and seeking while paused.
- A named local recording through start, pause, resume and stop; its completed
  metadata was saved in the isolated profile.
- Compact meeting-action menu typography.

This does not establish physical-device meter calibration, audio audibility,
external provider recognition quality, installer upgrade, screen-reader coverage,
or signed distribution. The existing common release route publishes unsigned
previews for manual installation.
