# Independent library panes — 2026-10-20

## Change

The library now uses one `NSSplitViewController` for its source list, table and
inspector. The window toolbar belongs to the outer SwiftUI view. The two pane
toggles have separate state, and the center table absorbs changes in available
space. Hosted content does not determine the window's minimum dimensions.

Side panes start at 215 and 390 points. Their holding priority is above the
center pane's but below AppKit's divider tracking priority. Initial frames,
rather than `preferredContentSize`, seed the widths without creating constraints
that prevent dragging. Closing the inspector goes through the inline editor's
save/validation check.

The embedded split view supplies an explicit `mouseDown` override that forwards
to AppKit. Native QA confirmed that a plain `NSSplitView` received the correct
hit-tested coordinates but did not start divider tracking in the SwiftUI
window; the explicit responder override restored tracking on both dividers.
Collapse animations run sequentially and coalesce rapid requests to the latest
state, so AppKit never saves an intermediate animation width as the pane width.

## Automated checks

```sh
xcrun swiftc -swift-version 5 -parse-as-library \
  Sources/PaperShelf/Views/LibrarySplitView.swift \
  Tests/AppHarnesses/LibrarySplitLayout.swift \
  -o .build/LibrarySplitLayout
.build/LibrarySplitLayout
plutil -lint Localization/en.lproj/Localizable.strings
git diff --check
```

The isolated AppKit harness uses unshown windows and a real SwiftUI table. It
checks all four visibility combinations at 980 points, initial hidden panes,
custom widths across opposite-pane toggles, window shrinkage, native visibility
feedback and a long scrollable inspector that must not enlarge the window.
Divider tests use AppKit's mouse tracking loop with down/drag/up events, including
both dividers inside the SwiftUI hosting root. A rapid show-left/hide-right
sequence must preserve both custom pane widths after reopening.

## Native application checks

Tests use the QA bundle and a copy of the two-paper synthetic library at
`/tmp/papershelf-split-qa/library.sqlite`. Production references and PDFs are not
test fixtures.

- At a 980 × 672 point window, selecting a paper preserves the window size.
- The three content panes start below the toolbar, with no overlapping controls.
- All four pane visibility combinations keep the toolbar controls in place.
- `⌥⌘S` and `⌥⌘I` independently toggle the two panes.
- `⌘F` reveals the source list and focuses its search field.
- A focused title edit is saved when the inspector is hidden and remains saved
  when it is reopened.
- An empty required title prevents hiding the inspector and displays an inline
  validation message; Escape restores the saved title.
- Metadata and annotation tabs remain functional.
- Expanding the window preserves side pane widths and gives the center table
  the additional space.
- In the final build, pointer dragging changed the left pane from 215 to 264.5
  points and the right pane from 390 to 420.5 points. Each drag preserved the
  opposite pane width.
- Hiding the left pane, then rapidly showing it and hiding the right pane,
  followed by reopening the right pane, preserved the custom widths of 264.5
  and 420.5 points.
- The final layout harness, localization lint and whitespace check passed.

## Deployment

`./script/build_and_run.sh --verify` completed packaging, signing and launch
verification for `dist/PaperShelf.app`. The production window displayed the
original 21 references, the independent pane controls and the selected paper's
metadata after restart. No production reference data was edited during QA.
