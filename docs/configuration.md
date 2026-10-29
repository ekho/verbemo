# CLI and configuration

Current Verbemo command and settings reference, adapted from the imported
application. See [Privacy](../PRIVACY.md) for processing data flows.

## CLI

### macOS

First launch creates `~/.local/bin/verbemo`, pointing into the installed app so
scripts use the same signed program as the UI.

```sh
verbemo doctor                 # check permissions, engines, and configuration
verbemo record start           # ask the running app to start recording
verbemo record stop
verbemo sessions               # list recordings and outstanding work
verbemo process <folder>       # finish or retry one meeting
verbemo process --diarize <folder>  # request or retry local speaker diarization
verbemo process --skip-diarization <folder>  # finish without a pending diarization pass
verbemo format-transcripts     # rebuild AssemblyAI Markdown from saved transcripts
verbemo setup                  # reopen first-run setup
```

Run `verbemo --help` or `verbemo <command> --help` for the complete command-line
interface. Most people never need it: recording and post-processing are
automatic, and the app exposes the same controls.

### Windows

Recording, import, retry, and configuration are available in the app and system
tray. A public Verbemo command-line interface is not included in Windows.
The bundled `transcribe-cli.exe` and live worker processes are internal
transcription components. Claude Code and Codex CLIs are optional summary
backends, separate from an Verbemo CLI.

## Configuration

Both platforms expose configuration through Settings, including an Advanced
tab. Most shared settings use the same names, but platform paths, credentials,
app identifiers, and hooks differ. Settings saves only overrides of defaults.

| | macOS | Windows |
| --- | --- | --- |
| Configuration | `~/.config/verbemo/config.json` | `%LOCALAPPDATA%\Verbemo Data\config.json` |
| Default recordings | `~/Verbemo Recordings` | `%USERPROFILE%\Verbemo Recordings` |
| API keys entered in Settings | `~/.config/verbemo/keys/` | Windows Credential Manager (`Verbemo/…`) |
| Call app identifiers | Bundle IDs, such as `us.zoom` | Executable names, such as `Zoom.exe` |

### macOS

Settings writes `~/.config/verbemo/config.json`. The file is optional and stores
only values that differ from the defaults. A compact example:

```json
{
  "recordings_dir": "~/Verbemo Recordings",
  "keep_audio": false,
  "interface_language": "auto",
  "transcription": {
    "enabled": true,
    "engine": "auto",
    "cloud": "assemblyai",
    "language": "ru",
    "assemblyai": { "api_key_path": "~/.config/verbemo/keys/assemblyai" }
  },
  "auto_record": {
    "enabled": true,
    "mic_activity": true,
    "calendar": false,
    "start_delay_seconds": 12,
    "stop_delay_seconds": 15,
    "min_duration_seconds": 45,
    "silence_stop_minutes": 10,
    "max_duration_minutes": 300,
    "apps": ["us.zoom", "com.google.Chrome"],
    "ignore_apps": []
  },
  "summary": {
    "enabled": true,
    "backend": "auto",
    "language": "ru"
  },
  "on_stop": "my-hook"
}
```

- `recordings_dir` selects the session folder; `keep_audio` retains the compact
  stereo archive after a successful transcript; `on_stop` is a shell command
  run after processing. The legacy `analytics` field is ignored; product statistics are disabled.
- `mcp.enabled` defaults to `false`; explicit local enable creates a protected
  token. Synced configuration alone never creates one. `mcp.port` defaults to
  `52763` and accepts integers from `1024` to `65535`. The server binds only
  `127.0.0.1` while Verbemo runs. Port changes, token rotation, library changes
  and unreadable configuration revoke access and active transfers. The
  `verbemo mcp [--output-dir <private-client-directory>]` stdio bridge reads
  these settings; it does not start the app. See [MCP connections](mcp.md).
- `on_stop` gets the session folder as its only argument and runs once per
  transcript, after naming and summarizing have had their pass — done,
  turned off, failed, or deferred for want of a model (a summary that arrives
  later does not run it again). It never runs while an verbemo is still
  finishing the session, and a crash in between is made good by the next
  launch. With transcription off it runs once the recording is archived; a
  recording that could not be transcribed does not run it.
- `transcription.*` covers `enabled`, `engine`, `cloud`, `local_engine`, `model`, and `language`.
  `local_engine` is `parakeet` by default, `whisper`, or `gigaam`; Whisper
  downloads about 550 MB once. GigaAM v3 downloads about 260 MB and runs
  locally through Handy's `transcribe.cpp` Metal/CPU runtime. It is Russian-only;
  Verbemo splits long recordings into 20-second pieces to stay inside its trained
  utterance window.
  Provider overrides are `transcription.openai.model`,
  `transcription.openai.api_key_path`,
  `transcription.assemblyai.api_key`,
  `transcription.assemblyai.api_key_path`, and
  `transcription.assemblyai.speech_model`, plus
  `transcription.elevenlabs.api_key` and
  `transcription.elevenlabs.api_key_path`. Choose `elevenlabs` as
  `transcription.cloud` or `transcription.engine` to use Scribe v2. It sends
  the microphone and system channels separately, with speaker diarization on
  each; a mono import uses the same diarization. Set `ELEVENLABS_API_KEY` or
  save a key in `~/.config/verbemo/keys/elevenlabs`. `live_transcription.enabled`
  controls the on-device preview.
- `transcription.local_diarization` enables local batch speaker diarization on
  Apple Silicon for Parakeet, Whisper, and GigaAM. It defaults to `false`.
  The separate Diarization section sits below the local transcription models
  and is available when On this Mac is selected. Choose a speaker model with
  the same radio cards, then download it explicitly before offline use.
  `transcription.diarization_model` selects `nemotron-3` (default, meetings up
  to eight speakers, about 107 MB), `ls-eend-ami` (meetings up to four speakers,
  about 45 MB), or `community-1` (compact alternative, about 21 MB).
  An existing saved processing request without this field retains Community-1.
  The ordinary call microphone stays `me`; the system track can
  become `them A`, `them B`, and so on. Local mono imports use `speaker A/B`.
  Uncertain or overlapping speech is shown as an unidentified speaker.
  Parakeet and Whisper use validated word timings; GigaAM and missing-word
  fallback recognize separate bounded voice intervals without inventing word
  timestamps. This affects the final transcript, not the live preview.
  `transcription.diarization_threshold` defaults to `0.6` and is clamped to
  `0.3…1.2`; it controls Community-1 clustering, not a promised accuracy
  percentage, and does not affect the other models.
  The evaluation procedure is in
  [Local diarization evaluation](testing/local-diarization-evaluation.md).
  Diarization retains a lossless 16 kHz PCM source and processing sidecars for
  repeatable retries. Float32 mono audio uses about 3.7 MiB per minute in
  addition to the compact archive. With `keep_audio=false`, audio is retained
  while diarization is unfinished and removed after completion or explicit
  skip. Recordings shows the separate stage and retry/skip actions.
  `process --diarize` requests a pass even with the automatic switch off;
  `--diarize`, `--skip-diarization`, and `--again` cannot be combined.
  `sessions --pending` includes unfinished diarization with an existing text.
  Local diarization sends no audio or text to a provider; separately configured
  cloud naming and summaries retain the data flows described below.
- `auto_record.*` covers `enabled`, `mic_activity`, `calendar`,
  `start_delay_seconds`, `stop_delay_seconds`, `min_duration_seconds`,
  `max_duration_minutes`, `silence_stop_minutes`, `apps`, and `ignore_apps`.
  On macOS, `apps` accepts app names (such as `Comet` or `Comet Helper`) as
  well as bundle-id prefixes; browser helpers resolve to the whole browser
  for audio capture. `auto_record.any_app` (off by default) records microphone
  activity from apps outside this list too. Dictation tools and `ignore_apps`
  still stay excluded. Turn it on in Advanced settings; turning it off restores
  the configured call list. An explicit `apps: []` in the config also accepts
  any app, while clearing the list field in Settings restores the standard list.
- `speaker_names.*` covers `enabled`, `backend`, and `model`. Naming sends
  the transcript wherever `summary.backend` does, and to no model when
  summaries are off, unless `speaker_names.backend` names a backend of its own.
- `summary.*` covers `enabled`, `backend`, `language`, `model`,
  `openai_model`, `openai_base_url`, `ollama_model`, `ollama_base_url`,
  `template`, `api_key_path`, `openai_api_key_path`, and
  `openai_compatible_api_key_path`. The two Base URLs
  allow OpenAI-compatible servers and a non-default Ollama host; only a
  loopback Ollama URL keeps the transcript on your computer, and any other host
  must be reached over https — plain http is refused for remote servers. The OpenAI
  key is not automatically forwarded to remote third-party servers:
  `summary.openai_api_key_path` names it for
  summaries while `openai_base_url` is OpenAI's own, and
  `transcription.openai.api_key_path` names it for transcription (an older
  config's `summary.openai_api_key_path` still counts for transcription while
  the summary talks to OpenAI). A compatible server uses
  `summary.openai_compatible_api_key_path`, or one pasted in Setup, which is
  kept in `~/.config/verbemo/keys/openai-compatible`. For a loopback compatible
  endpoint, Verbemo falls back to the OpenAI key when no dedicated compatible
  key is configured or saved; remote third-party endpoints get no automatic fallback.
  `verbemo doctor` walks the configured summary backend,
  including whether Ollama is answering and has the chosen model. `template` contains
  the complete summary instructions and starts with Verbemo's built-in default.
  In Settings → Setup → My own key, choose OpenAI, Anthropic, or
  OpenAI-compatible. The compatible option exposes the server URL and uses its
  dedicated key, with the loopback fallback described above.
  `summary.openai_compatible: false` selects OpenAI’s API while keeping
  a saved custom URL; `true` selects that URL. Older configs infer the choice
  from `openai_base_url` when the setting is absent.
- `mic_voice_processing` enables Apple's capture-time voice processing;
  `offline_echo_cancellation` (on by default) instead cleans a copy of the mic
  after recording, using system audio as the playback reference. It never
  opens a playback device or changes the archived source audio. Transcription
  uses a separate cache for cleaned audio; the first re-transcription of an
  older recording therefore needs a new provider request. Reference silence
  before playback and after a one-second acoustic-tail holdoff keeps the
  original microphone samples exactly. If playback occurs later, the model
  still consumes leading silence from the start so its delay-estimation clock
  remains aligned with the recording; an entirely silent reference is detected
  first and skips the model;
  `transcript_echo_filter` removes proven duplicate far-end speech later;
  `system_audio` is `app` or `all`; `calendar` controls meeting context; and
  `user_name` replaces “me” in named transcripts. `user_email` accepts an array
  of your addresses (for example `["work@example.com", "personal@example.com"]`);
  a legacy single string remains readable. The settings editor adds addresses
  with Enter or Add, accepts pasted lists separated by commas, semicolons or
  newlines, and removes each address separately. Matching ignores surrounding
  whitespace, case and duplicate addresses. It links that known microphone
  voice to a unique participant in a confirmed calendar event by an
  exact email match (ignoring surrounding whitespace and case). It is optional
  and stays local. Manual assignments and explicit unlinking take precedence;
  unidentified or remote voices are never inferred from the email.
  On macOS, first granting calendar access adds addresses explicitly identified
  by EventKit as the current user. Later, **Get from calendars** / **Взять из
  календарей** merges discovered addresses into the list using access granted
  by the permission button above. Automatic discovery
  runs only once, including for already granted access after upgrading, so
  deleted addresses do not reappear on launch. Discovery
  reads attendees and organizers in events within one year before and after
  today, excludes subscribed and delegated sources, and never guesses from
  account titles or participant names. Some accounts may yield no address;
  manual entry remains available. Windows has no calendar discovery.
- On macOS, Settings → Calendar lets you choose calendars for automatic matching,
  manual event selection, and calendar-triggered recording. `calendar_ids` stores
  their local EventKit identifiers. Omit it to use all calendars, including new
  ones; an explicit array uses only those calendars, and `[]` uses none. Changes
  apply without restarting and leave saved meeting details unchanged. Unavailable
  identifiers remain selected but cannot match events; after a full calendar sync
  or account reconnection, check the selection if macOS assigned new identifiers.
  Initial setup also offers calendar permission and the same calendar selection.
  Access is requested only by the permission button on either screen, never
  automatically at startup, when opening a recording, or while searching for events.
  Without access, recordings work without calendar context or calendar triggers.
- `interface_theme` is `system` (default), `light`, or `dark`. It changes only Verbemo; System follows the operating system.
- `interface_language` is `auto`, `en`, or `ru`. `dock_icon`, `menu_bar_icon`,
  and `window` control where Verbemo appears.

For Anthropic summaries, `summary.api_key_path` names the key file;
`ANTHROPIC_API_KEY` takes precedence. The OpenAI and compatible-server key-file
settings above are separate. The OpenAI key is not automatically forwarded to
remote third-party endpoints; loopback compatible endpoints can use the OpenAI
fallback described above.

Inline and file-based API keys remain supported for compatibility, but the UI
never displays an inline secret. Environment variables take precedence.

### Windows

Settings writes `%LOCALAPPDATA%\Verbemo Data\config.json`. The recordings folder
is under your user profile by default, outside Documents to avoid OneDrive's
automatic Documents backup. No Amanu data is migrated automatically.
API keys are entered in Settings and kept in Windows Credential Manager;
the macOS key-file paths and environment-variable instructions above do not
apply to Windows.

A compact Windows example for local processing:

```json
{
  "keep_audio": true,
  "interface_language": "auto",
  "transcription": {
    "engine": "parakeet",
    "local_engine": "parakeet"
  },
  "summary": {
    "backend": "ollama",
    "ollama_base_url": "http://127.0.0.1:11434",
    "ollama_model": "qwen3:8b"
  },
  "speaker_names": { "backend": "summary" }
}
```

Download Parakeet in Settings and make the selected Ollama model available
before using this example offline.

- `transcription.*` supports `enabled`, `engine`, `cloud`, `local_engine`,
  `language`, `openai.model`, and `assemblyai.speech_model`. Choose `parakeet`,
  `whisper`, or `gigaam` for local processing, or `assemblyai`, `openai`, or
  `elevenlabs` for a specific cloud engine. `auto` uses the configured cloud
  engine when available and otherwise the selected local engine.
- `summary.*` supports `enabled`, `backend`, `language`, `model`,
  `openai_model`, `openai_base_url`, `ollama_model`, `ollama_base_url`, and
  `template`. Backend names are `auto`, `claude-cli`, `anthropic-api`,
  `codex-cli`, `openai-api`, `ollama`, and `none`. `auto` tries them in that
  order, ending with Ollama. With the default `openai_model`, Codex uses its
  own configured model; a different Windows `summary.openai_model` also
  overrides the Codex CLI model. On macOS, this setting applies only
  to the OpenAI API.
- `speaker_names.*` supports `enabled`, `backend`, and `model`. The default
  backend `summary` follows the summary route and asks no model when summaries
  are disabled. An explicit backend chooses a separate naming route.
- `auto_record.*` uses executable names in `apps` and `ignore_apps`; the default
  start delay is 3 seconds on Windows and 12 seconds on macOS. Other controls
  cover `enabled`, `mic_activity`, `stop_delay_seconds`, `min_duration_seconds`,
  `silence_stop_minutes`, and `max_duration_minutes`. Windows has no calendar
  trigger.
- `live_transcription.enabled` controls the separate local streaming model.
  `system_audio` is `app` or `all`; `transcript_echo_filter` removes duplicate
  far-end speech. Apple's `mic_voice_processing` and LocalVQE's
  `offline_echo_cancellation` are macOS-only settings.
- `start_at_login`, `tray_icon`, and `taskbar_icon` control Windows startup and
  appearance. `recordings_dir`, `keep_audio`, `interface_language`,
  and `user_name` have the same purposes as on macOS.
- `on_stop` is an object with `executable` and `arguments`, rather than a shell
  command. `{session}` in an argument expands to the meeting folder. For
  example, `{"executable":"notepad.exe","arguments":["{session}\\summary.md"]}`
  opens the summary after processing. It runs once per session and does not
  wait for the launched application to close.
