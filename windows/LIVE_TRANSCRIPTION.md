# Windows live transcription

The live transcript is a local preview using a separate streaming model and
native worker. It is independent of the selected final transcript engine.
Download its model explicitly in Settings before offline use; a managed-only
build does not supply the complete native runtime.

For actual Windows testing, use an exact packaged app/native-runtime directory,
a disposable own data directory containing the verified model, and approved
microphone/system WAV fixtures. The source harness is
`tests/Verbemo.Live.Harness/Program.cs`; it takes application directory, model/data
directory, microphone WAV, system WAV, then optional duration and output JSON.
Fixtures must be mono PCM16 at 16 kHz. The harness feeds packets through the
production coordinator and child decoders at their arrival times and records
lag, stop time, channel text and errors. Read its current argument handling
before invocation; do not point it at a private meeting or the user's real profile.

Separately test real device capture, pause/stop, device changes and simultaneous
final processing on Windows. Preserve source/model/runtime hashes, input duration,
CPU/memory/lag and actual transcripts locally with the report. A successful
worker launch, synthetic smoke test or nonempty transcript does not establish
quality, language accuracy or performance on the user's hardware.

See [the Windows acceptance checklist](BETA.md). No live-transcript acceptance
is claimed by this document; final GUI/audio validation requires the real host.
