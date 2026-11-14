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

## #112 — inspector width

The existing Studio columns and width constraint now use an AppKit divider with
a grip, resize cursor, keyboard focus and accessible splitter value. Dragging,
Left/Right, Home/End and accessibility adjustment share the same bounds. The
minimum is the former fixed 270-point inspector; the maximum uses the library's
480-point limit and retains at least the existing 420-point document minimum.
The existing compact layout (below 850 points inside the workspace) still switches
between document and details rather than squeezing both into the available space.

Width is kept for this controller/window, including hide/show and window resizing.
The left library has no autosave/persisted width; no new preference was introduced.

`InspectorResizeTests` covers both appearances: real drag event handlers, Tab and
arrows, accessible adjustment, min/max, shrink/expand, compact presentation and
hide/show. Its fixture starts at 760 points, opens the window, then expands to
1340 points and checks the initial pane visibility/width before dragging. Sizing
before opening left the first CI run in compact layout (197-point hidden pane),
so it did not exercise the intended divider. The key-view loop is settled before
checking Tab. Neighboring recording-workspace and library suites also pass.

Native GUI: dragged 270 → 400 → 480 points, adjusted with arrows, reached the
divider through Shift-Tab/Tab, verified Home/minimum and End/maximum, and restored
286 points after hide/show and a 1340 → 760 → 1340 window cycle. Light and dark
appearances, a 760×600 window, long event title/agenda/invitees and a multiline
diarization error were checked. The inspector scrolled to its last controls; its
close button restored the document and keyboard focus in the compact window.
Accessibility labels/value were inspected; spoken VoiceOver was not exercised.
