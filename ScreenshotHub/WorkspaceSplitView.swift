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
        controller.setVisibility(sidebar: showsSidebar, inspector: showsInspector)
    }
}

final class WorkspaceSplitController: NSSplitViewController {
    private let sidebarHost: NSHostingView<AnyView>
    private let previewHost: NSHostingView<AnyView>
    private let inspectorHost: NSHostingView<AnyView>
    
    init(sidebar: AnyView, preview: AnyView, inspector: AnyView) {
        sidebarHost = .init(rootView: sidebar)
        previewHost = .init(rootView: preview)
        inspectorHost = .init(rootView: inspector)
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
        sidebarItem.preferredThicknessFraction = 220.0 / 1280
        sidebarItem.canCollapseFromWindowResize = false
        
        let previewItem = NSSplitViewItem(viewController: columnController(host: previewHost, respectsSafeArea: true))
        previewItem.minimumThickness = 360
        previewItem.holdingPriority = .defaultLow
        
        let inspectorItem = NSSplitViewItem(inspectorWithViewController: columnController(host: inspectorHost))
        inspectorItem.minimumThickness = 310
        inspectorItem.maximumThickness = 400
        inspectorItem.holdingPriority = .init(252)
        inspectorItem.preferredThicknessFraction = 340.0 / 1280
        inspectorItem.canCollapseFromWindowResize = false
        
        addSplitViewItem(sidebarItem)
        addSplitViewItem(previewItem)
        addSplitViewItem(inspectorItem)
        visibilityObservations = [sidebarItem, inspectorItem].map { item in
            item.observe(\.isCollapsed) { [weak self] _, _ in
                guard let self, !isApplyingVisibility else { return }
                // Divider gestures must update bindings after the native layout pass.
                Task { @MainActor [weak self] in
                    guard let self else { return }
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
    
    func updateContent(sidebar: AnyView, preview: AnyView, inspector: AnyView) {
        sidebarHost.rootView = sidebar
        previewHost.rootView = preview
        inspectorHost.rootView = inspector
    }
    
    func setVisibility(sidebar: Bool, inspector: Bool) {
        // Programmatic changes already came from SwiftUI. Echoing their deferred
        // notifications can overwrite a newer tab selection before it is mounted.
        isApplyingVisibility = true
        defer { isApplyingVisibility = false }
        if splitViewItems[0].isCollapsed == sidebar { splitViewItems[0].isCollapsed = !sidebar }
        if splitViewItems[2].isCollapsed == inspector { splitViewItems[2].isCollapsed = !inspector }
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
