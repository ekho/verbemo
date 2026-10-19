# Windows runtime acceptance

Run this on an available Windows host using the exact final Verbemo source and
packages. Record source SHA, version/build, Setup/Portable hashes, Windows build,
CPU architecture and real results. A macOS build, managed test or CI package is
not an actual Windows GUI or installer acceptance result.

1. Use a disposable validation profile. Confirm Verbemo has its own data/model
   paths and does not read/write or migrate Amanu's data automatically.
2. Install Setup, launch the app and inspect Setup, Settings/Advanced, About,
   tray and recordings windows in English and Russian. Verify own source/support/
   origin links and visible MIT attribution. Exercise actual controls.
3. With explicit microphone/system-audio permission and approved test input,
   record both sides of a short call, stop, transcribe, check speaker assignment,
   retry a failure and inspect a summary with the chosen backend.
4. Download the separate final and live models before an offline test.
   Verify [live transcription](LIVE_TRANSCRIPTION.md) using actual native workers.
5. Test portable launch, Setup upgrade and uninstall without losing settings or
   recordings. Portable copies do not self-update.
6. With two real local versions and a controlled own test feed, verify check/
   download does not apply, exit or restart, including during recording/processing.
   After normal Quit, the next primary startup installs before runtime starts.
   A secondary launch must not autoapply or stop a live primary. Do not publish
   test packages/feed through a public release to run this check.

Report unavailable cases as unavailable. Do not label a raw managed executable,
missing MSVC/native runtime or preliminary source build as final packaged acceptance.
