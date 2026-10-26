# Seeing the Journal pages

`Tests/verbemoTests/WindowShots.swift` renders pages of the real
`ApplicationWindow` to PNG files for human layout review. It also writes a view
listing for the transcription settings page. The suite checks that its fixture
controls exist, but does not compare pixels or establish GUI acceptance.

```sh
mkdir -p /tmp/shots
VERBEMO_SHOTS=/tmp/shots swift test --filter 'Window(Shots|Gallery)'
```

The directory must already exist. Without `VERBEMO_SHOTS`, both suites are
skipped. `WindowShots` captures content without window chrome; `WindowGallery`
includes the title bar. Both use the Journal's normal 1340×820 content size and
760×680 for narrow captures. The calendar checklist also has a standalone
settings-component fixture at 680/500-point widths.

Use separate directories for the two languages; filenames are the same:

```sh
mkdir -p /tmp/shots-en /tmp/shots-ru
VERBEMO_SHOTS=/tmp/shots-en swift test --filter 'Window(Shots|Gallery)'
VERBEMO_SHOTS_LANGUAGE=ru VERBEMO_SHOTS=/tmp/shots-ru swift test --filter 'Window(Shots|Gallery)'
```

The New recording fixture also renders the attached form with a synthetic calendar event or a timestamp title; it never reads real calendars or starts capture.

## What comes out

`{light,dark}` below means one file per appearance. Settings pages are
`general`, `recording`, `transcription`, `summary`, `calendar` and `storage`.

| File | Contents |
| --- | --- |
| `setup-permissions-{light,dark}.png` and `-narrow` | First-run microphone, call-audio and calendar permissions inside Journal, with calendar access not yet requested. |
| `setup-permissions-switched-to-dark.png`, `setup-permissions-switched-back-to-light.png` | The same permissions page through an appearance change. |
| `settings-{page}-{light,dark}.png` and `-narrow` | Each of the six settings pages. |
| `settings-storage-{light,dark}-narrow-bottom.png` | Storage scrolled to the model files at the bottom. |
| `calendar-selection-{light,dark}.png` and `-narrow` | Calendar settings component at 680/500 points, with synthetic calendars and an explicit selection; no real EventKit access. |
| `setup-calendar-selection-{light,dark}.png`, `-narrow` and `-narrow-bottom` | The same synthetic calendar selection on the initial setup page, with granted calendar access. |
| `settings-transcription-switched-to-light.png`, `settings-transcription-switched-back-to-dark.png` | Transcription settings through an appearance change. |
| `settings-transcription-cloud-only-{light,dark}.png` and `-narrow` | Cloud-only transcription with local speaker separation unavailable. |
| `settings-transcription-{light,dark}-narrow-diarization-error.png` | A long speaker-model error. |
| `settings-transcription-{light,dark}-narrow-{local,diarization}-progress.png` | Posed download progress; no download starts. |
| `about-{light,dark}.png` | About inside Journal. |
| `journal-empty-{light,dark}.png` | An empty meeting library. |
| `journal-live-{light,dark}.png` and `-narrow` | Active recording controls and a synthetic live transcript. |
| `journal-meeting-{completed,pending,failed}-{light,dark}.png` | Transcript and inspector, including speakers and processing state. |
| `journal-meeting-summary-{light,dark}.png` and `-narrow` | The selected meeting's summary. |
| `journal-meeting-inspector-{light,dark}-narrow.png` | The inspector opened at minimum width. |
| `journal-meeting-versions-{light,dark}-narrow.png` | Current and archived transcript versions. |
| `tree.txt` | Every view on the transcription settings page, with its frame and control state. |

## How to read them

Compare appearance-switch captures against the matching page built in the
final appearance. Stale layer colours are a reason to inspect the live app;
small rendering differences alone are not an automated failure.

Compare English and Russian from the same revision and machine. Look for
clipped labels, inaccessible controls and unexpected row growth. `tree.txt`
gives exact frames for the transcription page when a visual gap is hard to
measure.

`cacheDisplay` has known limits: an offscreen `NSSwitch` can look off regardless
of its actual state, and AppKit controls can draw differently from the active
app. Read the switch state in `tree.txt` or verify it in the running app.
Gallery title-bar buttons can appear inactive. The capture helper retains its
painted background so dark text and surfaces are not flattened onto transparency.

## Isolation and limits

Both suites use a fresh application home and a separate temporary pasteboard.
Meeting files, names, summaries, transcripts and the live conversation are
synthetic. The gallery creates its own meeting directory and removes it after
capture. Where an audio source is needed, it writes valid silent test audio;
it does not record or play audio. Download progress and errors are posed in
existing controls without fetching a model.

Microphone, system-audio and login-item status still comes from this Mac;
the calendar-selection fixtures simulate calendar permission. These
pictures cannot establish permission prompts, real capture, model downloads,
playback, keyboard interaction or Windows behavior. They are macOS offscreen
layout evidence, not a substitute for running the actual application.

Keep generated PNGs out of git: compare captures from the same machine before
and after a change. Website screenshots must come from the final macOS bundle
and actual Windows app, with source/build/language provenance. Do not relabel
historical or offscreen fixture captures as release acceptance evidence.

New recording: `new-recording-{calendar,timestamp}-{light,dark}.png` (form contents, without sheet chrome).
