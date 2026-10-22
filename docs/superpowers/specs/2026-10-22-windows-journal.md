# Windows Journal port

Port the approved native macOS Journal in `2026-10-21-journal-design.md` to the existing WPF app. The user requested an isolated worktree and delivery through the common release. The reference is current macOS source at `9e96f937cea7e8574db03617fbfee3789fa0217d`, including real source meters.

- Keep the sage meeting sidebar present on meeting, live, settings and About pages. Put New recording, Import, search and the existing filters there. Preserve selection and the current transcript version across navigation.
- Use the existing Journal light/dark palette, native Segoe UI typography and accessible Windows controls. Keep high contrast and keyboard focus usable.
- Put meeting date/duration, editable title, one meeting player and Summary/Transcript in the document. Put participants, saved calendar context, processing actions and processing configuration in a right inspector; expose the inspector at narrow widths without losing the meeting list.
- Navigate the existing five settings pages horizontally, with a dropdown in narrow windows. Embed first-run setup in the same window. Preserve all existing settings and provider capabilities.
- Provide a named recording dialog with Start, Cancel and recording settings. Keep pause/stop and real source levels visible during recording.
- Preserve source audio, transcript versions, manually assigned names, processing guards and recoverable deletion. Reuse existing Windows services and NAudio; add no dependency.

Windows has no calendar integration or local diarization engine. Show the actual platform capabilities and saved calendar snapshots; do not advertise unavailable macOS engines as Windows functionality. Live calendar integration and new recognition engines are outside this design port.

Acceptance: focused WPF state/layout and playback/meter tests, Windows build and full Core/Live suites, actual Windows GUI on an isolated synthetic profile in light/dark and narrow layouts, then cross-platform CI and common unsigned preview publication. Record limitations separately; VM execution does not establish physical x64 hardware, microphone calibration, installer upgrade or recognition quality.
