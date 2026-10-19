# Independent release acceptance — 2026-10-19

Local macOS build and capture-free GUI checks are verified. Actual Windows
acceptance is deferred by the user's priority amendment; signed publication is
still gated on both platforms and the project's own credentials. No public
release, signed installer or working audio/transcription pipeline is established
by this record. See [the release runbook](../releasing.md) for the common route.

## Exact macOS build

| Field | Verified value |
| --- | --- |
| Runtime/screenshot source | `8bc6f6be2bf6d5830dc1f1e8f3b5f122170db942` |
| Version / build | `0.1.0` / `476` |
| Bundle / executable | `.build/Verbemo.app` / `Contents/MacOS/Verbemo` |
| Bundle identifier | `name.ekho.verbemo` |
| Executable SHA-256 | `27ef52ccc35ab154827fd8effc5af77a7651203471dff3e0ff69654cb4b8a52a` |
| Executable bytes | 28,650,272 |
| Info.plist SHA-256 | `1e121d932ff45caa301e3ea19efced114f23ff7ea5c3618743467ef62fd2edf0` |
| Advertised minimum macOS | 14.2; all bundled Mach-O minimum versions checked |
| Host | Apple M3 Pro arm64, macOS 26.7.1 (25G241), Apple Swift 6.4 |
| Signature | Ad-hoc, no Team ID, flags `0x2(adhoc)` |
| Updates | Own Sparkle feed, public key absent, automatic checks disabled |

Main executable, LocalVQE, Whisper, CTranscribe and Sparkle each contain arm64
and x86_64. The bundled NeMo helper is arm64, as required for the Apple Silicon
local model route. A universal binary is not physical Intel acceptance.

## Source and automated checks

The initial clean source was `7a1734e7762da186dbe159e7105f6b997c8ce5e0`
(build 475). Its full local Swift result is retained below. The subsequent
`8bc6f6b` correction changes documentation and its coverage tests; app source
is unchanged. Both source revisions passed clean-source validation before
acceptance files were added.

| Command | Actual local result / scope |
| --- | --- |
| `python3 scripts/release.py preflight --ref <full SHA> --version 0.1.0` | Exit 0 on both clean revisions; correct version, full history, own origin and build 475/476 |
| `python3 -m unittest discover -s Tests/scripts -p 'test_*.py'` | 70/70 on `7a1734e`, 21.129 s; embedded-repository warning from a fixture |
| `python3 -m unittest discover -s windows/tests -p 'test_*.py'` | 7/7 on macOS, 0.079 s; workflow/source tests, not Windows execution |
| `python3 landing/tests/check.py` | Passed; repeated after adding the actual screenshots |
| `node landing/tests/browser.cjs` | Passed 12 macOS desktop/iPhone/Windows user-agent × EN/RU × light/dark combinations; repeated after screenshot integration |
| `python3 Tests/scripts/test_independent_product.py --all` | Passed; repeated after documentation/screenshot changes |
| `make verify-localvqe` | Passed: universal library, 16 kHz, 256-sample hops, 159-tensor graph |
| `VERBEMO_REQUIRE_LOCALVQE=1 swift test --no-parallel` | **Failed** on `7a1734e`: 865 tests in 115 suites, 845 passed, 18 skipped, two failed tests / six issues, 56.219 s |
| `swift test --no-parallel --filter SettingsDocumentationTests` | Owner reproduced two tests / six issues, then passed 3/3 after `8bc6f6b`; independent scoped review accepted the correction |
| `VERBEMO_SPARKLE_PUBLIC_KEY= make app SIGN_ID=-` | Exit 0 on both clean revisions; final bundle is `0.1.0 (476)` |
| `codesign --verify --deep --strict --verbose=2 .build/Verbemo.app` | Exit 0 for final bundle; ad-hoc only |
| `python3 scripts/verify-macos-compatibility.py .build/Verbemo.app 14.2` | Passed full bundle minimum-version checks |
| `python3 scripts/verify-nemotron-diar.py .build/Verbemo.app/Contents/Helpers/NeMoSpeech --skip-licenses --minimum 14.2` | Passed seven arm64 Mach-O files and relative dependency closure |
| `.build/Verbemo.app/Contents/MacOS/Verbemo --help` | Exit 0; packaged CLI help |

The full Swift failures came from tests still looking for all settings only in
the concise README. The complete reference already existed in
[configuration.md](../configuration.md). The correction checks its README link,
every schema setting in the actual reference and full provider key-file paths;
it does not remove settings from coverage. The failed full run is not relabeled
as passing by the focused result. A final full macOS CI result remains separate.

The 18 explicit skips cover seven opt-in model download, native model, private
corpus/audio, live model and Whisper timing evaluations, plus eleven opt-in
window/gallery captures. No opt-in download or inference evaluation was enabled.
Expected fixture warnings and mocked network-error paths appear in the Swift log.
Home-isolation, DoctorSummary, MeetingEgress and Setup suites passed before the
controller ran real `doctor`.

Bundle resources were checked for nonempty icons, compiled assets, LocalVQE
model/verification, NeMo verification, original license/notices and 22 third-party
license files. Architecture, plist, signature, resource and CLI checks inspect the
actual bundle. They do not establish signing trust or model quality.

## Actual macOS runtime

The controller performed these native CUA checks on the exact final bundle;
the acceptance implementer inspected the original images and structured results.

| Check | Actual result |
| --- | --- |
| Controlled state | Own `~/.config/verbemo`, empty dedicated test recordings directory; capture, calendar, live transcription, cloud/local transcription, summary and naming routes disabled |
| Packaged `doctor` | Exit 0; transcription disabled; system-audio grant unknown until first use |
| LaunchServices launch | `open .build/Verbemo.app` exit 0; main ready, Settings Setup and Advanced tabs, About observed in EN and RU |
| Identity / About | `Verbemo 0.1.0 (476)`, own source/support/origin links and original MIT attribution observed |
| Second LaunchServices open | Exit 0, one existing Verbemo process, PID 28993 unchanged; direct process/IPC admission not established by this check |
| Language / quit | Own normal quit verified, only own interface language changed EN→RU, then RU launch checked; final own process absent |
| Own CLI link | Existing `~/.local/bin/verbemo` points to this bundle; no new installation claimed for this final run |
| Permissions | GUI microphone, system audio and calendar still not asked; no grant action clicked |
| Login item | GUI still offers Install / Включить; registration and login startup untested |
| Final state | Own config left RU with processing disabled, dedicated recordings directory empty, no own process |
| Concurrent Amanu | **Skipped**: prior Amanu PID was already absent at final baseline, cause/time unknown; controller did not restart the user's app with its auto-settings |

`doctor` microphone “ok” is not proof of the new GUI identity's permission.
No record, import, key, grant, login-registration, model-download, inference or
update action was requested. Settings performs installed CLI version discovery
and loopback Ollama discovery; third-party CLI external behavior was not network
instrumented. The previous `a892e581` coexistence check is historical evidence for
that earlier bundle only, not acceptance of concurrent Amanu at `8bc6f6b`.
Neither `/Applications/Amanu.app` nor user Amanu data was replaced by this task;
`/Applications/Verbemo.app` was absent at final baseline.

Native automation had cold-binding timeouts and one stale About close index with
no effect before retry; an initial baseline assertion stopped before any config
write/doctor when the old Amanu process was absent. These harness limits do not
establish a product defect. No stopped app binding was queried after final quit.

## Original screenshot evidence

All six files are the original native bound-window CUA JPEG bytes, copied without
cropping, conversion or retouching. Both site languages show their actual main
window in the existing layout; Settings/About remain available as evidence.
Images show an idle app with processing off, not recorded audio or ASR output.
The [provenance manifest](../../landing/assets/screenshots/macos/0.1.0-476/provenance.json)
records the source/build, executable hash, original dimensions, byte counts and
SHA-256 of each file. Landing checks verify all six byte hashes.

| Window | English | Russian | Pixels |
| --- | --- | --- | --- |
| Main, ready | [EN](../../landing/assets/screenshots/macos/0.1.0-476/main-en.jpg) | [RU](../../landing/assets/screenshots/macos/0.1.0-476/main-ru.jpg) | 640 × 468 |
| Settings, Setup tab | [EN](../../landing/assets/screenshots/macos/0.1.0-476/settings-en.jpg) | [RU](../../landing/assets/screenshots/macos/0.1.0-476/settings-ru.jpg) | 1528 × 1576 |
| About | [EN](../../landing/assets/screenshots/macos/0.1.0-476/about-en.jpg) | [RU](../../landing/assets/screenshots/macos/0.1.0-476/about-ru.jpg) | 680 × 650 |

Historical macOS/Windows screenshots remain inactive. No Windows screenshot is
advertised as final Verbemo acceptance.

## Windows, credentials and publication gates

New Windows native build/GUI/installer/update acceptance is **deferred**, as
requested by the user. Concrete gaps are tracked in
[issue #2, native build/package](https://github.com/ekho/verbemo/issues/2) and
[issue #3, actual GUI/install/update lifecycle](https://github.com/ekho/verbemo/issues/3).
Earlier managed/source results and preliminary raw GUI observations remain bound
to their earlier revisions; none is promoted to final installed acceptance here.
CI may run naturally after push, but does not replace the deferred actual checks.

The controller verified cleanup of its Windows test processes, reset its own
controlled configuration, empty recordings and absent own Run entry, restored
idle pause and the original suspended VM state. Restoring the original full-window
view from temporary Coherence was not established. No new Windows work ran in
this acceptance task.

The actual macOS signed-build entry point was invoked on each clean source with
all six signing/notary/Sparkle variables removed from its child environment:

```sh
scripts/build-macos-release.sh --version 0.1.0 \
  --source-commit <full current SHA> --output <new test output directory>
```

Both runs exited 1 with `missing VERBEMO_SIGN_ID; signed releases require your own
credentials`, before builds/network/Keychain access, and created no output
directory. This verifies refusal of missing inputs; it does not inspect or certify
credentials on the machine. Apple membership is deferred. Actual Developer ID,
hardened-runtime release signing, notarization, Sparkle two-version update,
Windows Authenticode and installed lifecycle checks remain **open**.

The common two-platform signed publication gate is unchanged. No publication,
release asset/tag replacement, catalog publication or merge was performed.

## PR and CI revision boundaries

The controller verified `ekho`, pushed initial source `8bc6f6b` and opened
[draft PR #4](https://github.com/ekho/verbemo/pull/4).
[Initial CI run 39274074192](https://github.com/ekho/verbemo/actions/runs/39274074192)
uses exact SHA `8bc6f6be2bf6d5830dc1f1e8f3b5f122170db942`.
At the updated snapshot, macOS LocalVQE and the full Swift test step completed
successfully on `8bc6f6b`; the CI test count has not been extracted. The universal
development build was in progress. Windows installer metadata / preflight passed,
with its development build/tests still in progress. Remaining steps had no result.
The overall CI run is **pending**, not complete success.

This evidence/screenshot commit and subsequent task 10 changes produce later PR
heads. Their exact CI, final whole-branch review and review readiness must be
recorded by the controller after task 10; the initial run does not validate a
later head. Actual runtime/screenshots remain explicitly bound to build 476.
