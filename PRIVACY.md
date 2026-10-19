# Privacy

Verbemo has no account and no hosted meeting library. Recordings and the files
made from them live in the recordings folder on your computer. What leaves the
computer depends on the transcription, speaker-naming, and summary backends you
choose.

## Meeting content

- Recording is local. Microphone audio, system audio, and optional live
  transcription are captured and stored on your computer.
- Parakeet, Whisper, and GigaAM transcription run locally. The optional live
  transcript uses a separate local streaming model on both platforms. Ollama
  summaries run locally when its Base URL is localhost/loopback; another host
  receives the summary input.
- Optional macOS local batch diarization also runs on the computer. Its
  separate model download sends no meeting content. It stores a lossless audio
  source, timed ASR output, and speaker-assignment sidecars in the meeting
  folder for recovery and repeatable retries. With audio retention disabled,
  audio stays until the requested stage completes or is explicitly skipped.
  Deleting the meeting deletes these artifacts too. It does not create a
  voice-identity database or recognize people across meetings. Cloud naming
  and summaries still follow the backend choices described below.
- If you enable AssemblyAI, OpenAI, or ElevenLabs transcription, Verbemo uploads
  the meeting audio to that provider.
- If you select Claude Code, Codex, Anthropic, or OpenAI for summaries or
  speaker naming, Verbemo gives that backend the transcript and the available
  meeting context: title, call application, and, on macOS, calendar participants.
  Those CLI tools or APIs may send the material to their provider under the
  terms of the account you use.
- Speaker naming goes wherever summaries go. With summaries turned off it asks
  no model at all and fills in only your own name, unless
  `speaker_names.backend` names a backend for it.
- API keys stay on your computer and are sent only to the provider they
  authenticate. macOS Settings stores keys under `~/.config/verbemo/keys/`;
  Windows uses Windows Credential Manager (`Verbemo/…`).

Calendar access is optional on macOS; Windows has no calendar integration. Verbemo
reads events to identify a meeting, name its recording, and optionally start it
at the scheduled time. Calendar context stays local unless it is included in a
request to a cloud or CLI model as described above.

## Product and website analytics

Verbemo does not collect or send usage statistics. There is no installation
identifier, event queue or analytics backend. Legacy analytics fields cannot
enable reporting. The website sends no page-view or download-click events.
See [analytics behavior](docs/analytics.md).

## Updates and model downloads

macOS Sparkle uses `https://github.com/ekho/verbemo/releases/latest/download/appcast.xml`.
Installed Windows copies use `https://github.com/ekho/verbemo/releases/latest/download/`
on the stable channel. Pending Windows updates install only at the next normal
primary startup, before recording or processing starts. Portable copies do not
self-update. Models download from their hosting services, including Hugging Face.
These requests expose normal network metadata to the destination and do not
include meeting content. No own public release is established by these source URLs.

Use [Verbemo issues](https://github.com/ekho/verbemo/issues) for support; do not
post private meeting content or credentials there.
