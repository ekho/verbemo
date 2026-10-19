# Product analytics

Verbemo does not collect or send product usage statistics. There is no analytics
backend, installation identifier, event queue, timer, or analytics transport.
This applies to macOS and Windows, including old configuration files containing
`"analytics": true`. The legacy field cannot enable reporting.

`verbemo analytics` reports the disabled state. `verbemo analytics off` has the
same effect; `verbemo analytics on` fails without modifying the configuration.
Old local analytics files are ignored and are never replayed or uploaded.

Meeting processing is separate: a provider or CLI that you explicitly select
may receive meeting data to transcribe or summarize it. Product analytics being
disabled does not change those integrations or their privacy controls.

Historical analytics designs describe the imported Amanu baseline, not current
Verbemo behavior. The static website also sends no page-view or download-click events and has no
analytics endpoint. A hosting provider can still receive ordinary HTTP metadata
when serving files; no public hosting domain is configured in this source.
