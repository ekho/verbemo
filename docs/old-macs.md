# Older Macs and Intel

Verbemo targets macOS 14.2 or later and builds a universal Apple Silicon/Intel
application. A universal binary does not establish that capture, permissions,
updates or processing work on physical Intel hardware. Local transcription and
the live transcript require Apple Silicon; Intel needs a cloud transcription
backend. Cloud and CLI summaries still send their configured input to a provider.

The process tap sets the macOS 14.2 floor. Automatic microphone activity detection
uses a newer API behind an availability check; on 14.2/14.3, start recording
manually when `verbemo doctor` reports that limitation. Package verification
checks bundle metadata and native slices against the declared deployment target.
Actual old-macOS and physical Intel runtime acceptance remains to be measured.

[Imported dated measurements](history/amanu-old-macs.md) retain the original
Amanu paths, build results and limitations. They are not final Verbemo acceptance.
For a new run, record source SHA, exact bundle/hash, OS/hardware, architecture,
permission context, both capture tracks and selected processing engines.
Rosetta diagnosis on an Apple Silicon Mac is useful, but does not replace a
physical Intel recording test. See [the live pass](testing/live-pass.md).
