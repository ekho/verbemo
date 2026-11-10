# macOS system-audio recovery

The recorder can continue receiving silent PCM buffers after its native process tap stops delivering the call audio. File growth is not a sufficient liveness check. This change adds recovery; it does not establish which CoreAudio event triggered the reported historical failures.

After three seconds without measurable nonzero input, the recorder opens a second tap for the same capture scope. It keeps the original tap recording. A replacement is accepted only when it hears speech-level audio on observations at least 150 ms apart while the original remains silent. Ordinary silence, a paused recording, and unreadable sample levels do not establish a failed tap. An unsuccessful probe lasts at most two seconds, with attempts at least fifteen seconds apart.

Both callbacks use the existing serial queue. Promotion preserves the file and its original first-buffer time; audio timestamps trim overlap or pad a gap before the replacement's first frames. Stopping closes both native captures and drains callbacks before releasing the file. Probe expiry and process-list refresh cancel pending probes under the same lock used by promotion. Recovery never changes an app-scoped capture into global capture. A successful recovery or probe failure is appended to the meeting's existing `transcribe.log`.

The current recovery accepts the existing PCM format only. A format change is logged and leaves the original capture intact. This is a deliberate limitation, not verified recovery across arbitrary device/sample-rate changes. Audio lost before a successful probe cannot be reconstructed.

## Checks

Ordinary policy tests run with the normal macOS suite:

```sh
swift test --no-parallel --filter SystemAudioRecorderTests
```

Real CoreAudio checks require system-audio permission and an available output device. They play a quiet generated tone using `afplay`; they do not open or alter a user's meeting:

```sh
VERBEMO_TEST_SYSTEM_AUDIO=1 swift test --no-parallel --filter SystemAudioRecorderTests
```

The native regression disconnects the original tap from the test's source while the source continues playing. The original code failed: the recorded tail was all zeros and the recorder never heard sound again. The recovery code must restore audible samples into the same file, preserve its start and wall-clock duration, and release native resources on stop. A second failure mode detaches the tap from its aggregate, covering stopped callbacks and gap padding. A genuinely silent source must remain silent, retain its scope, and close its probe on stop. The CoreAudio object list is observed until removal is published, rather than assuming its update is synchronous with destruction.

Synthetic failure injection verifies recovery from those failure modes. It is not a reproduction of the original call application's triggering event or acceptance in a new real meeting.

On 2026-11-10, the full macOS suite with native audio checks enabled passed 1,422 tests in 189 suites on Apple Silicon with JBL Tune Beam 2. After adding the stopped-callback case and waiting for CoreAudio's asynchronous object-list updates, the focused suite passed all six tests (including both injected failure cases). The original recorder failed the silent-buffer case before the implementation changed. Model/GUI tests with their own opt-in requirements were not enabled by the audio flag.
