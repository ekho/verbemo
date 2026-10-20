# Native interface validation

Issue #21; implementation PR [#23](https://github.com/ekho/verbemo/pull/23).
The approved HTML remains the interaction reference, not a shipped web surface.

## Verified before the final review-fix commit

- macOS full suite with required LocalVQE: **940 tests / 137 suites** passed;
  universal LocalVQE and Nemotron helpers verified. Debug build passed.
- Actual Windows11 in Parallels, .NET10.0.402: **Core157/157, Live/WPF88/88**
  passed; Debug build had zero warnings/errors.
- Release-script114, workflow17 and automatic-version24 tests passed before
  the review fixes; release tooling was unchanged by those fixes.
- Corrupt Windows transcript entries (`null` segment or text) are rejected
  before model access; focused tests failed with NullReferenceException first,
  then the full Windows suites passed with the guard. Previous summary survives.
- One independent whole-branch review: no Critical and twelve Important
  findings. All Important findings fixed with focused RED→GREEN checks, then
  full platform suites. No second review cycle.
- Native macOS CUA smoke in a separately identified app with isolated HOME and
  synthetic meetings: same-window navigation, compact library/detail return,
  shared menu availability, participant selector persistence, deletion Undo, dark theme,
  narrow settings/About and model descriptions. The installed app was untouched.
- Actual Windows isolated preview displayed the fixture library/calendar and
  absent-summary state. General navigation was physically confirmed by the user.
  Parallels input automation was unreliable; this does not establish all Windows
  GUI flows. Those source paths have actual Windows WPF tests.

## Rulings and practical limits

- One integrated PR retains per-stage verification instead of the plan's original
  nine PRs. First-run/permission setup may keep its separate host; normal app
  sections share one window.
- Windows uses its existing root reservation under the primary-instance mutex.
  Any future independent processing writer must join that reservation protocol.
- Native partial acceptance is sufficient only for the authorized unsigned
  preview. Ad-hoc/unsigned packages require manual installation and can trigger
  Gatekeeper/SmartScreen warnings. No signed stable update is claimed.
- Real recording/pause/hide/reopen/audio, model network download/cancel/resume,
  permitted-calendar event opening/repeating events, physical Intel execution,
  installer/uninstaller/update and screen-reader acceptance were not performed.
  Unit/CI checks do not establish these outcomes or diarization quality.

## Deferred minors

- Embedded macOS copying exposes Text/Markdown; the existing RTF helper is not
  reachable from that surface.
- Windows live document-stage activity and enum-derived RU tooltip localization
  remain to be polished.

The final commit's CI packages and the automatic common version-commit release
must pass separately. Local pre-fix build521 is not a deliverable for this change.
