# OpenAI upload duration guard (#6)

Contract checked on **2026-10-22** for `gpt-4o-transcribe-diarize`:

- [OpenAI's file transcription guide](https://developers.openai.com/api/docs/guides/speech-to-text)
  documents a **25 MB** file limit. This fix retains Verbemo's existing
  `25 * 1_048_576` byte threshold and 15% size margin when slicing.
- [The transcription API reference](https://developers.openai.com/api/reference/resources/audio/subresources/transcriptions/methods/create)
  requires `chunking_strategy` for this model above 30 seconds. Verbemo continues
  to send `auto` and request `diarized_json` for timed speaker segments.
- Neither those pages nor [the model page](https://developers.openai.com/api/docs/models/gpt-4o-transcribe-diarize)
  specifies a 1400-second maximum. That number is an **observed rejection**
  reported in [Amanu PR #18](https://github.com/gsamat/amanu/pull/18), not a
  documented or independently verified current service guarantee.
- **1390 seconds** is therefore a defensive cut length, leaving ten seconds
  below that observed rejection for AAC padding. The shorter of this duration
  and the existing size-based estimate wins. Every encoded file is checked
  before uploading: positive finite duration, at most 1400 seconds, and at most
  the byte threshold. Unexpected encoding expansion fails locally and retains
  the source audio rather than sending an oversized request.

The guide also marks this model deprecated, with shutdown on February 26, 2027.
Model migration is separate work; this fix keeps the selected model and response
format unchanged.

## Cache and recovery

The cache key includes a slicing version and each piece's actual source offset
and duration (sample coverage, excluding AAC padding), alongside the existing
audio name, model, language, byte limit, count and piece number. Changing a cut
with the same number of pieces cannot reuse an answer for the previous range.
Old keys without boundaries are not trusted; interrupted runs with only those
keys will upload again once. New successful responses remain reusable after a
later piece fails, including after constructing a new engine.

Speaker labels remain separate per request, and timestamps are shifted by
source offsets rather than padded encoded durations. Source audio is never
deleted by this engine. Existing coordinator scratch cleanup still owns cache
retirement after a transcript is saved or explicitly regenerated.

## Verification scope

`OpenAIEngineTests` uses generated audio and `StubHTTP` with a dummy key. It
covers a real 1401-second AAC file below the byte limit, both ceiling orders,
short inputs and the duration boundary, invalid durations/unreadable input,
actual encoded sizes and container durations, retry after a second-piece error,
legacy caches, changed boundaries with unchanged piece counts, and an encoded
piece that cannot fit the byte budget. `FormEngineHTTPTests` covers the short
one-request path; `TranscriptionScratchTests` covers existing cleanup.

No real OpenAI request, personal recording, recognition-quality evaluation, or
packaged-app flow was used for this change. HTTP stubs establish local request,
cache and assembly behavior, not live service acceptance. Windows is outside
this macOS issue's scope.

Local verification on 2026-10-22 (Apple Silicon, Swift 6.4, Xcode 27.1), based
on `f08bf3458731ffb570b2de52b28df67e388c9e87`:

| Command | Result |
| --- | --- |
| `swift test --no-parallel --filter 'OpenAIEngineTests\|FormEngineHTTPTests\|TranscriptionScratchTests'` | 22 tests in 3 suites passed, 24.840 s |
| `swift test --no-parallel` | Final report: 1031 tests in 145 suites passed, 132.521 s; 23 opt-in/asset-dependent tests skipped |
| `swift build` | Debug build passed |
| `git diff --check` | Passed |

Skipped cases cover native model/corpus downloads and inference, LocalVQE
assets/integration, private audio evaluation, calendar acceptance and window
screenshots. The two new regressions for long under-limit audio and unreadable
audio were observed failing before the production change; existing focused
tests passed in that same run. Independent read-only review found no issues.

## Upstream credit

The tighter-ceiling approach and 1390-second guard are adapted from Dmitry
Tsoy's [Amanu PR #18](https://github.com/gsamat/amanu/pull/18), source commit
`31b8ec434224ad6ead27c37dec8db51694a1b757`, reviewed at PR head
`101b41816fe7cd359a453d3d4653a19df028e20b`. Cache-boundary identity, validation
and regression coverage are adapted for current Verbemo. The unrelated
`MicRecorder` change is excluded. Existing copyright and MIT license files
are preserved.
