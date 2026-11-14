# macOS workspace behavior: #109, #112, #123

Base: `baf4192` (`master`, 0.23.7), including PRs #127, #128 and #129.
Host: macOS with Xcode 27.2 / Swift 6.4.2; deployment target remains macOS 14.2.
All fixtures use isolated test homes. The installed app and user data are untouched.

## #109 — library hover

Row-local tracking flags outlived their tracking areas during scrolling. Rows now
reconcile hover with the window pointer and clipped visible bounds on scroll,
tracking-area replacement and mouse events. Delayed enter/exit events cannot
reinstate a stale flag. Selection still has its independent drawing path.

`MeetingHoverTests` failed before the fix in both appearances (10 assertions).
The final regression checks scroll in both directions, delayed enter/exit events,
leaving the list, offscreen selection, and tracking-area replacement. Together
with the existing hover/selection painting check, 2 tests / 4 cases pass:

```sh
swift test --build-system native --scratch-path .build/index-build --no-parallel \
  --filter 'MeetingHoverTests|JournalWorkspaceTests/hoveredMeeting'
```

Native GUI: a temporary `.app` loads the existing test bundle and real workspace
controllers with 40 synthetic meetings. Repeated large and small scrolls in both
directions, library refresh, light/dark appearance and an offscreen selected
meeting showed no accumulated highlights. Instrumented native cursor coordinates
identified exactly one hovered row. Computer Use's scroll marker differs from the
stationary native cursor; pointer exit is established by the regression test,
not by that overlay. Physical trackpad momentum was not separately exercised.
