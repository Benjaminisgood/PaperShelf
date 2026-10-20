import AppKit
import SwiftUI

/// One native split owns all three panes; the window toolbar stays outside it.
struct LibrarySplitView<Sidebar: View, Content: View, Inspector: View>: NSViewControllerRepresentable {
    @Binding var showingSidebar: Bool
    @Binding var showingInspector: Bool
    @Environment(\.locale) private var locale
    @Environment(\.colorScheme) private var colorScheme
    private let sidebar: Sidebar
    private let content: Content
    private let inspector: Inspector

    init(showingSidebar: Binding<Bool>, showingInspector: Binding<Bool>,
         @ViewBuilder sidebar: () -> Sidebar,
         @ViewBuilder content: () -> Content,
         @ViewBuilder inspector: () -> Inspector) {
        _showingSidebar = showingSidebar
        _showingInspector = showingInspector
        self.sidebar = sidebar()
        self.content = content()
        self.inspector = inspector()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(sidebar: $showingSidebar, inspector: $showingInspector)
    }

    func makeNSViewController(context: Context) -> LibrarySplitController {
        let controller = LibrarySplitController(
            sidebar: hosted(sidebar), content: hosted(content), inspector: hosted(inspector),
            showingSidebar: showingSidebar, showingInspector: showingInspector
        )
        controller.sidebarVisibilityChanged = { [weak coordinator = context.coordinator] in coordinator?.sidebar.wrappedValue = $0 }
        controller.inspectorVisibilityChanged = { [weak coordinator = context.coordinator] in coordinator?.inspector.wrappedValue = $0 }
        return controller
    }

    func updateNSViewController(_ controller: LibrarySplitController, context: Context) {
        context.coordinator.sidebar = $showingSidebar
        context.coordinator.inspector = $showingInspector
        controller.update(sidebar: hosted(sidebar), content: hosted(content), inspector: hosted(inspector))
        controller.setVisibility(sidebar: showingSidebar, inspector: showingInspector)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsViewController: LibrarySplitController, context: Context) -> CGSize? {
        // The split fills the space proposed by SwiftUI. Measuring the hosted
        // editor instead would turn its scrollable contents into window size.
        CGSize(width: proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 980,
               height: proposal.height.flatMap { $0.isFinite ? $0 : nil } ?? 620)
    }

    private func hosted<V: View>(_ view: V) -> AnyView {
        AnyView(view
            .environment(\.locale, locale)
            .environment(\.colorScheme, colorScheme)
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            .clipped())
    }

    final class Coordinator {
        var sidebar: Binding<Bool>
        var inspector: Binding<Bool>
        init(sidebar: Binding<Bool>, inspector: Binding<Bool>) {
            self.sidebar = sidebar
            self.inspector = inspector
        }
    }
}

@MainActor
final class LibrarySplitController: NSSplitViewController {
    let sidebarHost: NSHostingController<AnyView>
    let contentHost: NSHostingController<AnyView>
    let inspectorHost: NSHostingController<AnyView>
    private(set) var sidebarItem: NSSplitViewItem!
    private(set) var inspectorItem: NSSplitViewItem!
    var sidebarVisibilityChanged: ((Bool) -> Void)?
    var inspectorVisibilityChanged: ((Bool) -> Void)?

    private var requestedSidebar: Bool
    private var requestedInspector: Bool
    private var applyingVisibility = false
    private var animatingVisibility = false
    private var animateNextVisibility = true
    private var sidebarRevision = 0
    private var inspectorRevision = 0
    private var observations: [NSKeyValueObservation] = []

    init(sidebar: AnyView, content: AnyView, inspector: AnyView,
         showingSidebar: Bool, showingInspector: Bool) {
        sidebarHost = NSHostingController(rootView: sidebar)
        contentHost = NSHostingController(rootView: content)
        inspectorHost = NSHostingController(rootView: inspector)
        requestedSidebar = showingSidebar
        requestedInspector = showingInspector
        super.init(nibName: nil, bundle: nil)
        splitView = LibraryNativeSplitView()

        // A table's total column widths and an editor's longest text must not
        // become minimum window widths. NSSplitViewItem owns pane dimensions.
        for host in [sidebarHost, contentHost, inspectorHost] {
            host.sizingOptions = []
        }
        // Seed native pane sizes before adding the items. The split controller
        // then owns these widths, including user resizing and later restores.
        sidebarHost.view.frame = NSRect(x: 0, y: 0, width: 215, height: 620)
        inspectorHost.view.frame = NSRect(x: 0, y: 0, width: 390, height: 620)
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarHost)
        inspectorItem = NSSplitViewItem(inspectorWithViewController: inspectorHost)
        configure(sidebarItem, minimum: 190, maximum: 320)
        configure(inspectorItem, minimum: 330, maximum: 620)
        // Inspector dismissal goes through the toolbar's field-save check.
        // Its divider remains resizable, but cannot dismiss an invalid draft.
        inspectorItem.canCollapse = false
        sidebarItem.isCollapsed = !showingSidebar
        inspectorItem.isCollapsed = !showingInspector
        let center = NSSplitViewItem(viewController: contentHost)
        center.minimumThickness = 280
        center.holdingPriority = .defaultLow

        splitView.isVertical = true
        splitView.dividerStyle = .thin
        addSplitViewItem(sidebarItem)
        addSplitViewItem(center)
        addSplitViewItem(inspectorItem)

        observations = [
            sidebarItem.observe(\.isCollapsed, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.sidebarChanged() }
            },
            inspectorItem.observe(\.isCollapsed, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.inspectorChanged() }
            }
        ]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func configure(_ item: NSSplitViewItem, minimum: CGFloat, maximum: CGFloat) {
        item.minimumThickness = minimum
        item.maximumThickness = maximum
        item.canCollapse = true
        item.canCollapseFromWindowResize = false
        item.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        item.allowsFullHeightLayout = false
        // Keep side widths ahead of the center's 250, but below AppKit's
        // dragThatCannotResizeWindow (490), so users can still drag dividers.
        item.holdingPriority = .init(260)
        item.preferredThicknessFraction = NSSplitViewItem.unspecifiedDimension
    }

    func update(sidebar: AnyView, content: AnyView, inspector: AnyView) {
        sidebarHost.rootView = sidebar
        contentHost.rootView = content
        inspectorHost.rootView = inspector
    }

    func setVisibility(sidebar: Bool, inspector: Bool, animated: Bool = true) {
        let changeSidebar = requestedSidebar != sidebar
        let changeInspector = requestedInspector != inspector
        guard changeSidebar || changeInspector else { return }
        requestedSidebar = sidebar
        requestedInspector = inspector
        animateNextVisibility = animated
        if changeSidebar { sidebarRevision += 1 }
        if changeInspector { inspectorRevision += 1 }
        applyRequestedVisibility()
    }

    private func applyRequestedVisibility() {
        // Overlapping native collapse animations can remember an intermediate
        // pane width. Finish one transition before applying the latest request.
        guard !animatingVisibility else { return }
        let sidebar = requestedSidebar
        let inspector = requestedInspector
        let changeSidebar = sidebarItem.isCollapsed == sidebar
        let changeInspector = inspectorItem.isCollapsed == inspector
        guard changeSidebar || changeInspector else { return }
        applyingVisibility = true
        if changeSidebar && !sidebar { resignFocus(in: sidebarHost.view) }
        if changeInspector && !inspector { resignFocus(in: inspectorHost.view) }
        if animateNextVisibility && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            animatingVisibility = true
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                if changeSidebar { sidebarItem.animator().isCollapsed = !sidebar }
                if changeInspector { inspectorItem.animator().isCollapsed = !inspector }
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.animatingVisibility = false
                    self.applyRequestedVisibility()
                }
            }
        } else {
            if changeSidebar { sidebarItem.isCollapsed = !sidebar }
            if changeInspector { inspectorItem.isCollapsed = !inspector }
        }
        applyingVisibility = false
    }

    private func sidebarChanged() {
        guard !applyingVisibility else { return }
        let revision = sidebarRevision
        let visible = !sidebarItem.isCollapsed
        if !visible { resignFocus(in: sidebarHost.view) }
        // KVO can fire during a SwiftUI update or AppKit layout. Publish only
        // after that transaction, and discard superseded native transitions.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.sidebarRevision == revision, !self.sidebarItem.isCollapsed == visible else { return }
            self.sidebarVisibilityChanged?(visible)
        }
    }

    private func inspectorChanged() {
        guard !applyingVisibility else { return }
        let revision = inspectorRevision
        let visible = !inspectorItem.isCollapsed
        if !visible { resignFocus(in: inspectorHost.view) }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.inspectorRevision == revision, !self.inspectorItem.isCollapsed == visible else { return }
            self.inspectorVisibilityChanged?(visible)
        }
    }

    private func resignFocus(in pane: NSView) {
        guard let window = pane.window, let responder = window.firstResponder as? NSView,
              responder === pane || responder.isDescendant(of: pane) else { return }
        window.makeFirstResponder(nil)
    }
}

/// Explicit mouse handling lets AppKit track divider drags through SwiftUI's
/// representable host on macOS 27. Keep the native tracking implementation.
private final class LibraryNativeSplitView: NSSplitView {
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
    }
}
