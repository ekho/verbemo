# Activity status bar

Approved direction: the user requested a bottom status bar and then authorized implementation for both macOS and Windows on 2026-10-26.

Use a native, persistent, compact bar across the full main window. Move the sidebar auto-record control into it. Show enabled versus blocked automatic recording, required access (including an honest unknown state), running and waiting work separately, the current meeting and processing stage, and recording/paused state with elapsed time. Include compact readings from the existing microphone/system meters and actionable warnings. Long job titles truncate with full accessible text/tooltips; critical controls remain usable at the minimum window size. Localize all new text in English/Russian and preserve native keyboard/accessibility behavior.

Click recording to open the live meeting, work to open processing/current meeting details, access to open recording/settings access controls, and warnings to open attention/details. Keep existing recording pause/stop controls. Optional calendar access matters only when enabled. A permission check must never imply that sound is being captured; unknown system-audio access is not granted. Progress percentages are shown only when supplied by existing processing.

Approach: project the existing runtime, queue ownership, permission checks and measured audio values into native UI. A separate scheduler/status registry or a new cross-platform UI framework would duplicate ownership and introduce drift. No new dependencies, recognition requests, data migrations, release or installation changes.

Verification: focused state/count/navigation/layout tests; normal macOS build/test; Windows build/test on the available Windows VM; isolated synthetic-profile GUI checks on both platforms when available. Report hardware, real provider, screen-reader and packaging limits separately.
