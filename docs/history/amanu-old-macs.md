# Old Macs

What amanu does on a Mac that is not a recent Apple Silicon one, what sets each
limit, and — kept strictly separate — which of it has been measured and which is
only expected.

## Two limits, and they are not the same line

They get conflated constantly, so start here:

- **macOS 14.2 or later.** A software floor. It applies to every Mac.
- **Apple Silicon for local transcription.** A hardware floor. It applies to
  nothing else — recording, archiving, naming, summaries and the whole
  interface are architecture-blind.

macOS 14 runs on Intel Macs from 2018–2020. **The OS floor does not exclude
Intel by itself**, and an Intel Mac new enough to run macOS 14.2 is a machine
amanu can work on — with cloud transcription.

## What the macOS 14.2 floor is made of

The system-audio tap is the load-bearing API. Read out of the SDK headers rather
than from memory:

| What amanu calls | Its own availability |
|---|---|
| `AudioHardwareCreateProcessTap` — the system-audio tap | `macos(14.2)` |
| `EKEventStore.requestFullAccessToEvents` | `macos(14.0)` |
| `SMAppService` — the login item | `macos(13.0)` |

Per-process microphone detection uses a macOS 14.4 API behind an availability
check. On 14.2 and 14.3, recording still works, but automatic call detection is
less precise and `doctor` tells the user to start recordings by hand.

FluidAudio declares macOS 14, Sparkle sits lower, and the bundled LocalVQE
library builds for 14.2. The package, bundle metadata, native library and
Sparkle feed therefore use 14.2. Release packaging inspects every embedded
Mach-O slice and nested bundle, and fails if any of them requires a newer OS.

Worth saying plainly: the 14.2 deployment target has been compile- and
artifact-checked, but has not yet been exercised on a real macOS 14 machine.

## Intel

### It builds, and the build is universal

**Measured.** `swift build -c release --arch arm64 --arch x86_64` succeeds. Two
`--arch` flags move the product to `.build/apple/Products/Release/amanu`, and
`lipo -archs` reports `x86_64 arm64`. Sparkle's xcframework already ships a
`macos-arm64_x86_64` slice, so the framework inside the bundle is universal too
— its binary was checked, not just the directory name. `make app` fails if a
slice is missing rather than shipping half an application.

### Local transcription is impossible there, and not because it is slow

**Measured, and this is the part that surprises people.** FluidAudio refuses
before Core ML is ever involved: `guard SystemInfo.isAppleSilicon else { throw
ASRError.unsupportedPlatform(...) }` in `AsrModels`, and the same guard in the
streaming manager for the live model. `SystemInfo.isAppleSilicon` is
`#if arch(arm64)` — compile-time, per slice.

That makes it a **library refusal, not a capability probe**. Consequences worth
spelling out, because each one has been guessed wrong at least once:

- There is no CPU fallback, so there is nothing to be slow with. It does not
  run badly; it does not run.
- A powerful discretionary GPU in a 2019 Mac Pro changes nothing. Nothing is
  asked of the GPU.
- It is decided when the slice is compiled, not when the Mac is inspected. The
  x86_64 slice has the answer baked in.

So on Intel: **a cloud engine or nothing.** A key is not a preference there, it
is the feature. Which cloud is a real choice — AssemblyAI or OpenAI, whichever
has a key — but *having* one is not.

### What the program does about it

One `Platform.supportsLocalModels` — compile-time, per slice — is asked once,
and everything that would otherwise reach for a local model asks it:

- the queue picks the configured cloud engine and says so in the log;
- `doctor` reports what will actually run, including the case worth naming out
  loud: *local transcription needs Apple Silicon and there is no AssemblyAI
  key* — naming whichever provider is selected, so the sentence tells you which
  key to go and get;
- Setup shows the **On this Mac** switch disabled, saying it needs Apple
  Silicon, rather than hiding it. A missing option looks like a bug; a
  switched-off one with a reason does not. The two provider cards are on screen
  as they are everywhere else, and the cloud switch is the only one that moves;
- the live-transcript switch and its setting are not offered at all, and the
  status window's live section is hidden.

The engine matrix is a pure function with tests for both halves — necessarily,
since a test run only ever happens on one of them.

## Measured, and not measured

Be strict about this. The distinction is the only reason the document is worth
anything.

**Measured.** The universal build, above. And the x86_64 slice running
correctly: under Rosetta, `arch -x86_64 …/Amanu doctor` reports the cloud
engine — `assemblyai · key ok · expecting ru+en · audio leaves this machine` —
while `arch -arm64` with the same configuration reports parakeet. That
exercises every branch of the platform split for real.

**Not measured: OpenAI on Intel, by anybody.** The engine has been run against
the real API, one request and a sliced meeting both, but only on Apple Silicon.
Nothing in it is architecture-dependent — it is HTTPS and JSON, and the slicing
goes through the same `AVAudioFile` path the mix already uses — so the same
behaviour is what one would predict. It is a prediction.

**Not measured: amanu has never run on an Intel Mac.** Nobody has one here.
Two things follow.

- **Rosetta does not close this gap.** It runs the x86_64 slice on Apple
  Silicon hardware, which is the wrong half of the question. It tests the code
  path, not the machine.
- **The system-audio tap on Intel hardware is an expectation, not a result.**
  Nothing in that path is architecture-dependent and process taps are an OS
  feature rather than a chip feature, so identical behaviour is what one would
  predict. This project has been wrong about that tap before:
  `.issues/rca-002-system-tap-silent-outside-launchagent.md` is an entire
  investigation into it returning digital silence in a situation nobody had
  thought to distinguish. Until somebody records a meeting on an Intel Mac and
  finds a far-end track with something on it, this stays in the *expected*
  column.

Do not claim Intel support in release notes until that has happened. "It
compiles and the platform split is tested" is true and is not the same claim.

## The update feed has no idea about architecture

**Reasoned, and it is a trap for later.** The appcast advertises one enclosure
to everyone; Sparkle filters on version, not on slice. So the moment an Intel
Mac is running amanu, **every subsequent release must stay universal**. Ship one
arm64-only build after that and the feed cheerfully offers it to an Intel
machine that cannot execute it.

v0.2.0 shipped arm64-only — `lipo -archs` on that bundle says `arm64`, and its
release notes say Apple Silicon, which was accurate. From the first universal
release onward, dropping back is a one-way mistake. If a release ever genuinely
must be single-arch, the feed needs per-architecture filtering first, and that
is a change to `scripts/release.sh` and to the appcast, not a judgement call at
release time.

## If you want to go lower still

- **macOS 14.0 and 14.1.** Cost the system-audio tap. That is half the product:
  a meeting recorder that records only your own voice. Not worth it.
- **macOS 13.** Costs the system-audio tap (14.2) and full calendar access
  (14.0). The tap is half the product — a meeting recorder that records only
  your own voice. Not worth it.
- **Local transcription on Intel.** Needs a different ASR engine. FluidAudio
  will not serve it at any macOS version, and the guard is not something to
  patch out: it is there because the models are Apple-Silicon Core ML packages.
