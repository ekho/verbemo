# Summary retry and CLI diagnostics provenance

Verbemo issue #8 adapts the relevant behavior from
[gsamat/amanu PR #20](https://github.com/gsamat/amanu/pull/20), authored by
[shooma](https://github.com/shooma), reviewed at head
`f4f61079e547619b862033f62c59fb7ba787ff4d` on 2026-10-22.

The upstream contribution supplied tail-first CLI diagnostics, removal of prompt
echoes, recognition of concrete Claude/Codex sign-in failures, and explicit retry
of permanently failed naming and summary stages. Its commits credit Claude Opus
5.5 as co-author. Original copyright notices and the MIT license are preserved.

Verbemo already had `retryFailed` and UI retry eligibility. This adaptation joins
CLI and UI manual completion, preserves fingerprint-based background recovery,
protects the root session when processing an archive, and reports the actual
outcome. Diagnostic filtering covers both streams, partial/numbered echoes and
credential values. It does not import upstream analytics reporting, UI layout,
or unrelated model selection changes.
