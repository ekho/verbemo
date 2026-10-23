# Speaker assignment workspace

User request: restore Participants as a third meeting tab, minimize clicks to map diarized voices, keep transcript names compact with clickable link status, and identify the owner through a configured calendar email. Implement the existing native controls on both platforms; do not change raw transcript labels, recognition or release behavior.

1. Add focused regression tests for tab placement, inline editing, assignment persistence and exact owner email matching. Preserve existing lock, version and manual-name tests.
2. Move existing speaker content out of the inspector into Participants. Show editable participant/name choices and voice examples without expansion; reuse meeting playback for auditioning.
3. Share assignment controls with transcript rows: text by default, linked/unlinked icon with tooltip and hand cursor, editable choice on activation, Enter/focus loss to save and Escape to cancel. Free names must work without calendar data. Keep unknown grouped speech unidentified.
4. Add `user_email` beside `user_name` in settings and documentation. Match a unique normalized email only in a confirmed invitation and only to literal `me`; preserve manual choices and explicit unlinking. Keep email local and out of model/analytics payloads.
5. Run macOS targeted/full tests and actual UI checks in synthetic isolated data. Verify Windows build/tests on the available VM and UI when Computer Use permits. Review integration, commit with Conventional Commits and Co-Authored-By, push branch and create/attach PR.

No model changes, migration of transcript IDs, paid API calls, release or merge.
