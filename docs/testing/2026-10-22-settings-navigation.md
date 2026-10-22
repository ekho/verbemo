# macOS settings navigation — 2026-10-22

Base: `18a26b6` (Verbemo 0.8.0). Local working-tree validation only.

Each settings tab previously called `SetupForm.reload()` and the controller's
full refresh. This checked machine state, launched tool discovery and rebuilt
the hidden model inventory before returning an already constructed page.

Tabs now reuse their pages. Configuration/download observers still update them;
entering settings or reopening their hidden window refreshes machine state.
Opening Storage still rereads the model inventory, including externally added
files. Navigating while hidden defers machine checks until the window opens.
Returning to Summary also rechecks an edited Ollama endpoint/model once, while
unchanged tabs avoid that work. Cached model controls consume fresh inventory
state so externally removed files restore the Download action.

## Checks

- The regression test failed on the original implementation: five tab changes
  made five machine checks and replaced the hidden model rows.
- The initial fix passed 37 focused navigation, settings and model tests.
- Final `VERBEMO_REQUIRE_LOCALVQE=1 swift test --no-parallel` passed 1095 tests in
  155 suites, with 20 opt-in tests skipped and a final completion report.
- A final visibility guard avoids refreshing twice when a hidden window opens;
  focused checks were repeated after that change.
- Independent review found stale cached download buttons after external model
  removal and stale Ollama status after connection settings changed. Both were
  reproduced with failing tests and fixed. The first focused review run passed
  63 tests in seven suites; lifecycle coverage also checks that a hidden window
  defers connection checks and that entering Summary does not check twice.
  Final independent review reported no remaining findings; the full run above
  includes all review fixes.
- Computer Use exercised all six settings tabs and the return to General in a
  separate AppKit bundle (`name.ekho.verbemo.settings-review-c636`) using the
  production ApplicationWindow and settings controls. Its process Home was
  forcibly sandboxed, with empty credentials and tool/model discovery disabled.
  The temporary harness source was restored before the full test run.
- `git diff --check` passed.

One isolated five-tab sample changed from 416 ms to 282 ms, but a later full-suite
sample took 426 ms. These samples do not establish a stable speedup percentage;
the regression assertions protect removal of repeated work without a flaky
wall-clock threshold.

Logs: `/tmp/verbemo-settings-{baseline,focused,full,final-focused}.log`.
Review logs: `/tmp/verbemo-settings-{storage-red,ollama-red,review-focused,release-final-full}.log`.

## Limits

The installed application was not replaced. Actual recordings, model downloads,
spoken VoiceOver and Windows were not tested. Windows sources are unchanged.
