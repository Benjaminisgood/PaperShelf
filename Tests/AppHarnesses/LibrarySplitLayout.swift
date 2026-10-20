import AppKit
import SwiftUI

/// Compile with LibrarySplitView.swift; uses an unshown window and no user data.
@main @MainActor
struct LibrarySplitLayout {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let controller = LibrarySplitController(
            sidebar: AnyView(Text("Library").frame(maxWidth: .infinity, maxHeight: .infinity)),
            content: AnyView(LayoutTestTable()),
            inspector: AnyView(Text(String(repeating: "A long reference title ", count: 20))
                .frame(maxWidth: .infinity, maxHeight: .infinity)),
            showingSidebar: true, showingInspector: true
        )
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 800),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: 1440, height: 800))
        settle(controller)
        check(controller, width: 1440, sidebar: true, inspector: true)
        let sidebarWidth = controller.sidebarHost.view.frame.width
        let inspectorWidth = controller.inspectorHost.view.frame.width
        precondition(abs(sidebarWidth - 215) < 2, "Unexpected initial sidebar width: \(sidebarWidth)")
        precondition(abs(inspectorWidth - 390) < 2, "Unexpected initial inspector width: \(inspectorWidth)")

        window.setContentSize(NSSize(width: 980, height: 620))
        settle(controller)
        for state in [(false, true), (false, false), (true, false), (true, true),
                      (true, false), (false, false), (false, true), (true, true)] {
            controller.setVisibility(sidebar: state.0, inspector: state.1, animated: false)
            settle(controller)
            check(controller, width: 980, sidebar: state.0, inspector: state.1)
        }
        precondition(abs(controller.sidebarHost.view.frame.width - sidebarWidth) < 2, "Sidebar width was not restored")
        precondition(abs(controller.inspectorHost.view.frame.width - inspectorWidth) < 2, "Inspector width was not restored")

        window.setContentSize(NSSize(width: 1600, height: 800))
        settle(controller)
        dragDivider(0, to: 310, in: controller, window: window)
        dragDivider(1, to: 1000, in: controller, window: window)
        settle(controller)
        check(controller, width: 1600, sidebar: true, inspector: true)
        let resizedSidebar = controller.sidebarHost.view.frame.width
        let resizedInspector = controller.inspectorHost.view.frame.width
        precondition(abs(resizedSidebar - 310) < 2, "Native divider resize did not change sidebar width")
        precondition(abs(resizedInspector - 600) < 2, "Native divider resize did not change inspector width")
        controller.setVisibility(sidebar: false, inspector: true, animated: false)
        settle(controller)
        precondition(abs(controller.inspectorHost.view.frame.width - resizedInspector) < 2, "Sidebar toggle resized the inspector")
        controller.setVisibility(sidebar: true, inspector: false, animated: false)
        settle(controller)
        precondition(abs(controller.sidebarHost.view.frame.width - resizedSidebar) < 2, "Inspector toggle lost the sidebar width")
        controller.setVisibility(sidebar: true, inspector: true, animated: false)
        settle(controller)
        precondition(abs(controller.inspectorHost.view.frame.width - resizedInspector) < 2, "Inspector width was not restored")
        window.setContentSize(NSSize(width: 980, height: 620))
        settle(controller)
        check(controller, width: 980, sidebar: true, inspector: true)
        dragDivider(1, to: 560, in: controller, window: window)
        dragDivider(0, to: 264, in: controller, window: window)
        let narrowSidebar = controller.sidebarHost.view.frame.width
        let narrowInspector = controller.inspectorHost.view.frame.width
        controller.setVisibility(sidebar: false, inspector: true, animated: false)
        settle(controller)
        controller.setVisibility(sidebar: true, inspector: true)
        controller.setVisibility(sidebar: true, inspector: false)
        settle(controller, duration: 0.7)
        controller.setVisibility(sidebar: true, inspector: true)
        settle(controller, duration: 0.4)
        check(controller, width: 980, sidebar: true, inspector: true)
        precondition(abs(controller.sidebarHost.view.frame.width - narrowSidebar) < 2, "Rapid toggles lost the sidebar width")
        precondition(abs(controller.inspectorHost.view.frame.width - narrowInspector) < 2, "Rapid toggles lost the inspector width")

        var sidebarEvents: [Bool] = []
        var inspectorEvents: [Bool] = []
        controller.sidebarVisibilityChanged = { sidebarEvents.append($0) }
        controller.inspectorVisibilityChanged = { inspectorEvents.append($0) }
        controller.sidebarItem.isCollapsed = true
        controller.inspectorItem.isCollapsed = true
        precondition(sidebarEvents.isEmpty && inspectorEvents.isEmpty, "Native state must be published asynchronously")
        settle(controller)
        precondition(sidebarEvents == [false] && inspectorEvents == [false], "Native collapse was not propagated")
        controller.setVisibility(sidebar: false, inspector: false, animated: false)
        controller.setVisibility(sidebar: true, inspector: true, animated: false)
        settle(controller)
        check(controller, width: 980, sidebar: true, inspector: true)
        precondition(sidebarEvents == [false] && inspectorEvents == [false], "Programmatic state was echoed into bindings")

        for state in [(false, true), (true, false), (false, false)] {
            let initiallyHidden = LibrarySplitController(sidebar: AnyView(Text("Sidebar")), content: AnyView(LayoutTestTable()),
                                                        inspector: AnyView(Text("Inspector")), showingSidebar: state.0, showingInspector: state.1)
            let hiddenWindow = NSWindow(contentRect: .zero, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            hiddenWindow.contentViewController = initiallyHidden
            hiddenWindow.setContentSize(NSSize(width: 980, height: 620))
            settle(initiallyHidden)
            check(initiallyHidden, width: 980, sidebar: state.0, inspector: state.1)
            initiallyHidden.setVisibility(sidebar: true, inspector: true, animated: false)
            settle(initiallyHidden)
            check(initiallyHidden, width: 980, sidebar: true, inspector: true)
            precondition(abs(initiallyHidden.sidebarHost.view.frame.width - 215) < 2, "First sidebar reveal has wrong width")
            precondition(abs(initiallyHidden.inspectorHost.view.frame.width - 390) < 2, "First inspector reveal has wrong width")
        }

        let model = LayoutTestModel()
        let root = NSHostingController(rootView: LayoutTestRoot(model: model))
        let hostingWindow = NSWindow(contentRect: .zero, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        hostingWindow.contentViewController = root
        hostingWindow.setContentSize(NSSize(width: 980, height: 620))
        settle(root)
        let initialFrame = hostingWindow.frame
        model.selected = true
        settle(root)
        precondition(hostingWindow.frame == initialFrame, "Selecting a tall inspector changed the SwiftUI window frame")
        precondition(abs(root.view.frame.width - 980) < 2 && abs(root.view.frame.height - 620) < 2)
        guard let hostedSplit = findSplit(in: root) else { preconditionFailure("Hosted split controller is missing") }
        dragDivider(0, to: 250, in: hostedSplit, window: hostingWindow)
        precondition(abs(hostedSplit.sidebarHost.view.frame.width - 250) < 2, "Mouse drag failed inside SwiftUI hosting root")
        dragDivider(1, to: hostedSplit.splitView.bounds.width - 420, in: hostedSplit, window: hostingWindow)
        precondition(abs(hostedSplit.inspectorHost.view.frame.width - 420) < 2, "Inspector mouse drag failed inside SwiftUI hosting root")
        precondition(!controller.inspectorItem.canCollapse, "Dragging must not bypass the inspector's save-before-hide action")
        print("Library split: startup and first-reveal widths, 980-point rapid toggles, native mouse divider dragging, independent custom widths, window resize limits, native bindings and SwiftUI tall-inspector sizing passed.")
    }

    private static func findSplit(in controller: NSViewController) -> LibrarySplitController? {
        if let split = controller as? LibrarySplitController { return split }
        return findSplit(in: controller.view)
    }

    private static func findSplit(in view: NSView) -> LibrarySplitController? {
        if let split = view as? NSSplitView, let controller = split.delegate as? LibrarySplitController { return controller }
        return view.subviews.lazy.compactMap { findSplit(in: $0) }.first
    }

    private static func dragDivider(_ index: Int, to position: CGFloat, in controller: LibrarySplitController, window: NSWindow) {
        let split = controller.splitView
        let divider = NSPoint(x: split.arrangedSubviews[index].frame.maxX, y: split.bounds.midY)
        precondition(split.hitTest(divider) === split, "Divider is covered by a child view")
        let from = split.convert(divider, to: nil)
        let to = split.convert(NSPoint(x: position, y: divider.y), to: nil)
        let timestamp = ProcessInfo.processInfo.systemUptime
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: from, modifierFlags: [], timestamp: timestamp,
                                      windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        let move = NSEvent.mouseEvent(with: .leftMouseDragged, location: to, modifierFlags: [], timestamp: timestamp + 0.05,
                                      windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 1)!
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: to, modifierFlags: [], timestamp: timestamp + 0.1,
                                    windowNumber: window.windowNumber, context: nil, eventNumber: 3, clickCount: 1, pressure: 0)!
        // Exercise AppKit's actual tracking loop, without ordering a window or
        // sending input to the user's active app.
        NSApp.postEvent(up, atStart: true)
        NSApp.postEvent(move, atStart: true)
        split.mouseDown(with: down)
        settle(controller)
    }

    private static func settle(_ controller: NSViewController, duration: TimeInterval = 0.12) {
        for _ in 0..<max(1, Int(ceil(duration / 0.02))) {
            controller.view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
        }
    }

    private static func check(_ controller: LibrarySplitController, width: CGFloat, sidebar: Bool, inspector: Bool) {
        precondition(!controller.sidebarItem.isCollapsed == sidebar)
        precondition(!controller.inspectorItem.isCollapsed == inspector)
        precondition(abs(controller.splitView.bounds.width - width) < 2, "Expected width \(width), got \(controller.splitView.bounds.width); sidebar \(sidebar), inspector \(inspector)")
        let visible = controller.splitViewItems.filter { !$0.isCollapsed }
        var priorEnd: CGFloat = 0
        for item in visible {
            let pane = item.viewController.view
            let frame = pane.convert(pane.bounds, to: controller.splitView)
            precondition(abs(frame.height - controller.splitView.bounds.height) < 2, "Pane height does not fill the split: \(frame)")
            precondition(frame.width >= item.minimumThickness - 1, "Pane smaller than its minimum: \(frame)")
            if item.maximumThickness != NSSplitViewItem.unspecifiedDimension {
                precondition(frame.width <= item.maximumThickness + 1, "Pane wider than its maximum: \(frame)")
            }
            precondition(frame.minX >= priorEnd - 1, "Overlapping panes: \(frame)")
            precondition(frame.maxX <= width + 1, "Pane extends outside the window: \(frame)")
            priorEnd = frame.maxX
        }
        precondition(abs(priorEnd - width) < 2, "Visible panes do not fill the window")
    }
}

private final class LayoutTestModel: ObservableObject {
    @Published var selected = false
}

private struct LayoutTestRoot: View {
    @ObservedObject var model: LayoutTestModel
    var body: some View {
        VStack(spacing: 0) {
            LibrarySplitView(showingSidebar: .constant(true), showingInspector: .constant(true)) {
                Text("Sidebar")
            } content: {
                LayoutTestTable()
            } inspector: {
                if model.selected {
                    ScrollView {
                        VStack {
                            ForEach(0..<50) { index in
                                TextField("Field \(index)", text: .constant(String(repeating: "Long title ", count: 20)), axis: .vertical)
                                    .lineLimit(1...6)
                            }
                        }.padding(22)
                    }
                } else {
                    Text("Select a reference")
                }
            }
            Text("Status").font(.caption).frame(height: 24)
        }.frame(minWidth: 980, minHeight: 620)
    }
}

private struct LayoutTestRow: Identifiable {
    let id = UUID()
    var title = String(repeating: "Very long title ", count: 12)
    var authors = "Author"
    var year = "2026"
    var journal = "Journal"
}

private struct LayoutTestTable: View {
    let rows = [LayoutTestRow()]
    var body: some View {
        Table(rows) {
            TableColumn("Title", value: \.title).width(min: 220, ideal: 400)
            TableColumn("Author", value: \.authors).width(min: 100, ideal: 150)
            TableColumn("Year", value: \.year).width(min: 48, ideal: 60)
            TableColumn("Journal", value: \.journal).width(min: 100, ideal: 180)
        }
    }
}
