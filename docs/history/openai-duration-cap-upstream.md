# OpenAI duration-cap upstream provenance

The tighter-ceiling approach and protective 1390-second cut originate in
Dmitry Tsoy's [Amanu PR #18](https://github.com/gsamat/amanu/pull/18), source
commit `31b8ec434224ad6ead27c37dec8db51694a1b757`, reviewed at head
`101b41816fe7cd359a453d3d4653a19df028e20b` on 2026-10-22.

That PR reports a service rejection above 1400 seconds; it is historical
evidence, not a documented current API guarantee. The link records attribution
and is not a Verbemo runtime, support, update or release destination.

See [current behavior and verification](../testing/openai-duration-cap.md).
The unrelated upstream MicRecorder change was not imported. Original license
files and copyright notices remain unchanged.
