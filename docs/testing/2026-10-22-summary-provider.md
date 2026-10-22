# One-run summary provider (#28)

Scope: macOS Journal summary regeneration only. Existing provider integrations,
credential storage, speaker naming, Windows behavior and signed release policy
remain outside this feature. The final branch must include the completed #8
CLI-diagnostics/manual-processing change before merge and preview publication.

## Behavior

The sheet offers the configured chain, Codex, Claude Code, OpenAI-compatible API,
Anthropic API and Ollama. A choice captures settings and backend closures before
launch, including endpoint/key pairing, models, template and language. A change
to Codex's own config stops a one-run request until the user makes a fresh choice.
The disclosure lists the possible destinations. Explicit service choices never
fall back. Global settings and other meetings are not changed by the job.

Access checks use CLI authentication status, existing API model-list probes and
the selected Ollama model list. These checks do not include the transcript or
generate paid text. They cannot guarantee that a later generation will succeed.
Generation rechecks access before each candidate receives text.

All sheet requests persist `summary_manual` under the selected version's metadata
before contacting a service. This write is required. Background and generic
finish-processing attempts cannot pick these jobs up with different settings;
repeat through the summary sheet instead. The open sheet retains its request for
an explicit retry. Retranscription clears the marker for the new transcript.
No credentials or request payloads are persisted by this feature.

The selected archive shares the root session claim. Summary output is replaced
atomically only after a successful completion and cancellation check. Previous
summary bytes survive errors and cancelled or late replies.

## Development verification

- Baseline: 15 existing summary/egress tests passed.
- Independent implementation: full Swift run passed 1045 tests in 149 suites;
  subsequent review added regressions and fixes, so this is not final combined
  branch evidence.
- Focused regressions cover immutable prompts/routes, parallel jobs, failed access,
  explicit retries, no configured/background fallback, selected archive/root claim,
  required metadata write, and cancellation of a backend that ignores cancellation.
- Review reproduced a configured-choice background reroute and a key-resolution
  mismatch. The fixes block all sheet jobs from background pickup and derive the
  endpoint and key file from the same configuration snapshot.

## Native development check

A separate `name.ekho.verbemo.summary28` ad-hoc debug bundle uses a pinned
`CFFIXED_USER_HOME` at `/tmp/verbemo28-native/home`. It contains two fictional
meetings, a loopback fake Ollama and executable fake Codex/Claude tools. Actual
provider keys, personal meetings and paid requests are not used.

Observed in the real window: provider menu and destination disclosure; one-run
Ollama generation with automatic summary disabled; refusal by fake Codex before
any transcript call; explicit retry through the same Codex choice; cancellation
of an in-flight Ollama reply with the prior summary still displayed. The other
meeting remained unchanged. The initial native check exposed a generic LLMError
message; final integration must replace it using #8's diagnosis.

Final combined revision, checks and release evidence will be recorded after #8
is ready. Windows runtime, real cloud authentication and VoiceOver speech are not
established by these macOS synthetic checks.
