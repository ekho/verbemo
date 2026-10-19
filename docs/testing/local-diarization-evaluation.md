# Local diarization evaluation

The [original evaluation protocol and dated measurements](../history/amanu-local-diarization-evaluation.md)
remain available with their original evidence. Current opt-in tests use the
`VERBEMO_` prefix; ordinary tests do not download models or process private meetings.

Prepare an explicitly approved local corpus, verified model directory and a new
output file, then set `VERBEMO_DIAR_EVAL_RUN=1`, `VERBEMO_DIAR_EVAL_CORPUS`,
`VERBEMO_DIAR_EVAL_MODELS` and `VERBEMO_DIAR_EVAL_REPORT` before running
`swift test --no-parallel --filter DiarizationEvaluationTests`.
Read `Tests/verbemoTests/Transcription/DiarizationEvaluationTests.swift` for the
current corpus schema and scoring rules. Use absolute paths and a disposable
fixture directory. Record model identity/hash, source commit, runtime platform,
corpus, scored duration and alignment settings with the result.

A successful model load or synthetic fixture does not prove production Russian
meeting quality, real-time speed, or a particular speaker count on new audio.
