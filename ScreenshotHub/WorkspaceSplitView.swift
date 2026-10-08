import AppKit
import SwiftUI

struct WorkspaceSplitView<Sidebar: View, Preview: View, Inspector: View>: NSViewControllerRepresentable {
    var sidebar: Sidebar
    var preview: Preview
    var inspector: Inspector
    @Binding var showsSidebar: Bool
    @Binding var showsInspector: Bool
    
    func makeNSViewController(context: Context) -> WorkspaceSplitController {
        let controller = WorkspaceSplitController(
            sidebar: AnyView(sidebar.environment(\.self, context.environment)),
            preview: AnyView(preview.environment(\.self, context.environment)),
            inspector: AnyView(inspector.environment(\.self, context.environment))
        )
        updateVisibility(controller)
        return controller
    }
    
    func updateNSViewController(_ controller: WorkspaceSplitController, context: Context) {
        controller.updateContent(
            sidebar: AnyView(sidebar.environment(\.self, context.environment)),
            preview: AnyView(preview.environment(\.self, context.environment)),
            inspector: AnyView(inspector.environment(\.self, context.environment))
        )
        updateVisibility(controller)
    }
    
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsViewController: WorkspaceSplitController,
        context: Context
    ) -> CGSize? {
        proposal.viewportSize(idealSize: .init(width: 1280, height: 820))
    }
    
    private func updateVisibility(_ controller: WorkspaceSplitController) {
        controller.onVisibilityChange = { sidebar, inspector in
            if showsSidebar != sidebar { showsSidebar = sidebar }
            if showsInspector != inspector { showsInspector = inspector }
        }
        controller.setVisibility(
            sidebar: showsSidebar,
            inspector: showsInspector,
            animated: controller.view.window?.isVisible == true
        )
    }
}

final class WorkspaceSplitController: NSSplitViewController {
    private static let sidebarWidthKey = "workspaceSidebarWidth"
    private static let inspectorWidthKey = "workspaceInspectorWidth"

    private static func width(
        for key: String,
        in defaults: UserDefaults,
        fallback: CGFloat,
        range: ClosedRange<CGFloat>
    ) -> CGFloat {
        let width = CGFloat(defaults.double(forKey: key))
        return width.isFinite && range.contains(width) ? width : fallback
    }

    private let sidebarHost: NSHostingView<AnyView>
    private let previewHost: NSHostingView<AnyView>
    private let inspectorHost: NSHostingView<AnyView>
    private let defaults: UserDefaults
    private var sidebarWidth: CGFloat
    private var inspectorWidth: CGFloat
    
    init(
        sidebar: AnyView,
        preview: AnyView,
        inspector: AnyView,
        defaults: UserDefaults = .standard
    ) {
        sidebarHost = .init(rootView: sidebar)
        previewHost = .init(rootView: preview)
        inspectorHost = .init(rootView: inspector)
        self.defaults = defaults
        sidebarWidth = Self.width(for: Self.sidebarWidthKey, in: defaults, fallback: 220, range: 180...280)
        inspectorWidth = Self.width(for: Self.inspectorWidthKey, in: defaults, fallback: 340, range: 310...400)
        super.init(nibName: nil, bundle: nil)
        
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.frame = .init(x: 0, y: 0, width: 1280, height: 820)
        
        // Column bounds belong to AppKit. SwiftUI's content measurements must not
        // change split-view constraints while a window constraint pass is running.
        for host in [sidebarHost, previewHost, inspectorHost] {
            host.sizingOptions = []
            // Only the outer document view owns the window title and toolbar.
            // Replacing an inspector tab must not bridge an empty title into it.
            host.sceneBridgingOptions = []
        }
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: columnController(host: sidebarHost))
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 280
        sidebarItem.holdingPriority = .init(251)
        sidebarItem.preferredThicknessFraction = sidebarWidth / 1280
        sidebarItem.canCollapseFromWindowResize = false
        
        let previewItem = NSSplitViewItem(viewController: columnController(host: previewHost, respectsSafeArea: true))
        previewItem.minimumThickness = 360
        previewItem.holdingPriority = .defaultLow
        
        let inspectorItem = NSSplitViewItem(inspectorWithViewController: columnController(host: inspectorHost))
        inspectorItem.minimumThickness = 310
        inspectorItem.maximumThickness = 400
        inspectorItem.holdingPriority = .init(252)
        inspectorItem.preferredThicknessFraction = inspectorWidth / 1280
        inspectorItem.canCollapseFromWindowResize = false
        
        addSplitViewItem(sidebarItem)
        addSplitViewItem(previewItem)
        addSplitViewItem(inspectorItem)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(saveWidths),
            name: NSSplitView.didResizeSubviewsNotification,
            object: splitView
        )
        visibilityObservations = [sidebarItem, inspectorItem].map { item in
            item.observe(\.isCollapsed) { [weak self] item, _ in
                guard let self, !isApplyingVisibility, inspectorAnimationID == nil else { return }
                hasPendingVisibilityChange = true
                if !item.isCollapsed {
                    needsRestoreWidths = true
                    view.needsLayout = true
                }
                // Divider gestures must update bindings after the native layout pass.
                Task { @MainActor [weak self] in
                    guard let self, hasPendingVisibilityChange else { return }
                    defer { hasPendingVisibilityChange = false }
                    onVisibilityChange?(!splitViewItems[0].isCollapsed, !splitViewItems[2].isCollapsed)
                }
            }
        }
    }
    
    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    var onVisibilityChange: ((Bool, Bool) -> Void)?
    private var visibilityObservations: [NSKeyValueObservation] = []
    private var isApplyingVisibility = false
    private var hasPendingVisibilityChange = false
    private var hasRestoredWidths = false
    private var isRestoringWidths = false
    private var needsRestoreWidths = false
    private var inspectorAnimationID: UUID?

    override func viewDidLayout() {
        super.viewDidLayout()
        guard view.window != nil, inspectorAnimationID == nil,
              !hasRestoredWidths || needsRestoreWidths else { return }
        hasRestoredWidths = true
        needsRestoreWidths = false
        restoreWidths()
    }
    
    func updateContent(sidebar: AnyView, preview: AnyView, inspector: AnyView) {
        sidebarHost.rootView = sidebar
        previewHost.rootView = preview
        inspectorHost.rootView = inspector
    }
    
    func setVisibility(sidebar: Bool, inspector: Bool, animated: Bool = false) {
        guard !hasPendingVisibilityChange else { return }
        // Programmatic changes already came from SwiftUI. Echoing their deferred
        // notifications can overwrite a newer tab selection before it is mounted.
        isApplyingVisibility = true
        defer { isApplyingVisibility = false }
        let isExpanding = (sidebar && splitViewItems[0].isCollapsed) || (inspector && splitViewItems[2].isCollapsed)
        if hasRestoredWidths, isExpanding {
            needsRestoreWidths = true
            view.needsLayout = true
        }
        if splitViewItems[0].isCollapsed == sidebar { splitViewItems[0].isCollapsed = !sidebar }
        guard splitViewItems[2].isCollapsed == inspector else { return }
        guard animated, hasRestoredWidths, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            inspectorAnimationID = nil
            splitViewItems[2].isCollapsed = !inspector
            return
        }
        let animationID = UUID()
        inspectorAnimationID = animationID
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            splitViewItems[2].animator().isCollapsed = !inspector
        } completionHandler: { [weak self] in
            guard let self, inspectorAnimationID == animationID else { return }
            inspectorAnimationID = nil
            needsRestoreWidths = true
            view.needsLayout = true
        }
    }

    private func restoreWidths() {
        isRestoringWidths = true
        defer { isRestoringWidths = false }
        if !splitViewItems[0].isCollapsed {
            splitView.setPosition(sidebarWidth, ofDividerAt: 0)
        }
        if !splitViewItems[2].isCollapsed {
            let preview = splitViewItems[1].viewController.view
            let inspector = splitViewItems[2].viewController.view
            // Overlay dividers can occupy no space between column frames.
            let dividerWidth = max(0, inspector.frame.minX - preview.frame.maxX)
            splitView.setPosition(splitView.bounds.width - inspectorWidth - dividerWidth, ofDividerAt: 1)
        }
    }

    @objc private func saveWidths() {
        guard view.window != nil, hasRestoredWidths,
              inspectorAnimationID == nil, !needsRestoreWidths,
              !isRestoringWidths, !isApplyingVisibility else { return }
        let sidebar = splitViewItems[0]
        let inspector = splitViewItems[2]
        if !sidebar.isCollapsed, sidebar.viewController.view.bounds.width != sidebarWidth {
            sidebarWidth = sidebar.viewController.view.bounds.width
            defaults.set(sidebarWidth, forKey: Self.sidebarWidthKey)
        }
        if !inspector.isCollapsed, inspector.viewController.view.bounds.width != inspectorWidth {
            inspectorWidth = inspector.viewController.view.bounds.width
            defaults.set(inspectorWidth, forKey: Self.inspectorWidthKey)
        }
    }
    
    private func columnController(
        host: NSHostingView<AnyView>,
        respectsSafeArea: Bool = false
    ) -> NSViewController {
        let controller = NSViewController()
        if respectsSafeArea {
            let viewport = NSView()
            viewport.clipsToBounds = true
            host.clipsToBounds = true
            // AppKit reserves the toolbar area; SwiftUI receives only the usable viewport.
            host.safeAreaRegions = []
            host.translatesAutoresizingMaskIntoConstraints = false
            viewport.addSubview(host)
            let safeArea = viewport.safeAreaLayoutGuide
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor),
                host.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor),
                host.topAnchor.constraint(equalTo: safeArea.topAnchor),
                host.bottomAnchor.constraint(equalTo: safeArea.bottomAnchor)
            ])
            controller.view = viewport
        } else {
            controller.view = host
        }
        return controller
    }
}
