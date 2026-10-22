# One-run summary provider (#28)

Scope: macOS Journal summary regeneration only. Existing provider integrations,
credential storage, speaker naming, Windows behavior and signed release policy
remain outside this feature. The branch incorporates completed #8 / PR #37 at
`fc0b8f0ac514ce80678331e7a463e4d771dd602a` through a merge commit, preserving its
history and upstream attribution. Base: `d7b82fe174d82f70630ecb3918ca6bd07dde7cd6`.

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

## Integration with #8

Ordinary failed summary/naming work still supports explicit retry through the
Journal action and `verbemo process`. A one-run summary with no current output
instead reports an actionable refusal directing the user back to the provider
sheet. It cannot report successful completion or silently adopt the configured
chain. Other unfinished work can still complete.

The sheet uses #8's signed-out classification for a safe, localized login hint.
Raw CLI output is not displayed there. Summary and naming logs only promise a
next backend when one actually exists; one-run jobs never promise a background
retry.

## Verification

- Combined branch: `VERBEMO_REQUIRE_LOCALVQE=1 swift test --no-parallel` passed
  **1072 tests in 153 suites** (147.199 seconds). This includes the integration
  fixes below, before a final naming-log wording change and its added regression.
- After that final wording change, focused diagnostics/manual-processing/naming/
  integration checks passed **31 tests in 4 suites** (15.279 seconds).
- Independent review found no blocking issues in the combined change. Its last
  small finding (a single naming backend still promising fallback) was reproduced
  by a failing test and fixed; that regression now passes.
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
meeting remained unchanged.

The integrated debug bundle repeated the signed-out check: it showed a readable
Russian `codex login` instruction and retained Codex. The fake CLI generation
count stayed at 1 during failed preflight, then reached 2 after explicit retry.
Cancelling a delayed loopback response left the previous summary in place even
after the late reply, with no remaining session claim. The second meeting still
contained its original summary.

Separate real CLI processes against another isolated home verified `process`:
legacy failed summary -> exit 0 and a generated summary; one-run pending summary
-> exit 1 with “Create a new summary”, no generated output and no route fallback.

PR #36 records exact final CI and published-preview evidence after merge. These
local checks do not establish Windows runtime, real cloud authentication or
VoiceOver speech. UI screenshot suites are opt-in and were skipped in the full
Swift run; the native checks above were performed separately.
