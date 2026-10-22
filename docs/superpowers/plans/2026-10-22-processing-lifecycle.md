# macOS processing lifecycle implementation plan

Spec: GitHub issue #42. Approved scope and implementation/merge authority are in the issue.

- [x] Add a process-local operation registry with generation IDs, canonical meeting roots, waiting/running/cancelling snapshots, cancellation handles, admission closure and completion barriers. Test queued cancellation, cleanup, nesting, close and generation/session isolation first.
- [x] Register queued and direct transcription/diarization plus archive work. Keep the current serial processing barrier and SessionClaim. Cancellation must not publish incomplete transcripts or spend attempts; engine/native cleanup completes before removal.
- [x] Connect post-processing, explicit summaries, sweep and import; preserve captured provider requests and import restart semantics. Test cancellation propagation to children and no implicit rerun.
- [x] Document ownership of recording/live, shared model downloads and subprocesses for #7/#30; integrate current master/#29 and resolve review findings.
- [x] Build the macOS debug executable and run the full integrated Swift suite.
- [ ] Complete the isolated synthetic native macOS smoke.
- [ ] Pass required CI on the final PR head, merge into master, and record the exact merge commit in #42/#7/#30.

No Windows product changes, Journal cancel UI or AppKit/signal exit integration.
