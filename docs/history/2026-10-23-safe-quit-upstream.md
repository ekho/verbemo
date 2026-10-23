# Safe macOS quit: upstream attribution

The safe-quit adaptation for Verbemo issue #7 draws on dm0xa's proposal in
[gsamat/amanu PR #10](https://github.com/gsamat/amanu/pull/10), head
`da5d9c94bffd354743ca99ac8f7005f90a8f1cf0` (closed without merge).

It retains the central ideas: defer AppKit termination until native inference
has unwound, close admission before the recording handoff can enqueue work,
and schedule signal-triggered termination through the run loop rather than
inside the main dispatch queue's signal handler. The reported upstream Metal
abort and upstream tests are provenance, not evidence of this Verbemo build.

Verbemo uses its merged ProcessingOperations registry instead of porting the
upstream drain-only shutdown. Its additional barriers retain live retirees and
serialize the original begin/toggle/finish/enqueue transitions. Both source
projects' existing copyright and license notices remain intact.

The Verbemo native repeated-signal test additionally reproduced AppKit bypassing
the delegate on a second terminate while its deferred reply was pending. The
Verbemo-specific application subclass guards that outer entry; a standalone
AppKit probe and real Whisper/Metal repetitions verify this addition.
