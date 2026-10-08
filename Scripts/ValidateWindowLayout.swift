import AppKit
import SwiftUI

@main
struct ValidateWindowLayout {
    @MainActor
    static func main() throws {
        _ = NSApplication.shared
        let initialInspectorSelection = InspectorSelection.load()
        defer { initialInspectorSelection.save() }
        InspectorSelection().save()
        validateInspectorSelection()
        validateWorkspacePersistence()
        let runsAsApp = Bundle.main.object(forInfoDictionaryKey: "NativeDragValidation") as? Bool == true
        if runsAsApp {
            freopen("/tmp/ScreenshotHub-native-drag-app-validation.log", "w", stdout)
            freopen("/tmp/ScreenshotHub-native-drag-app-validation.log", "a", stderr)
        }
        if CommandLine.arguments.contains("--split-view-only") {
            validateWorkspaceSplitView()
            validateToolbarOverlap()
            return
        }
        precondition(!DeviceFrame.all.isEmpty, "The test must load the production device registry.")
        validateDeviceFrameGroups()
        let catalogPath = runsAsApp ? Bundle.main.object(forInfoDictionaryKey: "ValidationAssetCatalog") as! String
            : CommandLine.arguments[1]
        let catalog = URL(fileURLWithPath: catalogPath, isDirectory: true)
        for frame in DeviceFrame.all {
            for suffix in ["", "Mask"] {
                let name = frame.id + suffix
                let image = NSImage(contentsOf: catalog.appendingPathComponent("\(name).imageset/image.png"))!
                precondition(image.setName(.init(name)))
            }
        }
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 24, pixelsHigh: 48,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32
        )!
        let data = bitmap.representation(using: .png, properties: [:])!
        var populated = ScreenshotHubDocument()
        var configuration = ScreenshotConfiguration()
        configuration.watch.isEnabled = true
        configuration.watch.clock.isEnabled = true
        configuration.title = String(repeating: "A long headline with highlighted text. ", count: 20)
        try populated.storeFrame(for: &configuration)
        populated.draft = .init(configuration: configuration, screenshotData: data, sourceName: "Draft Layout Validation",
                                watchScreenshotData: data, watchSourceName: "Watch Layout Validation")
        populated.snapshots = [.init(
            name: String(repeating: "A long snapshot name ", count: 8),
            configuration: configuration,
            screenshotData: data,
            sourceName: "Layout Validation"
        )]
        
        let groupID = populated.createGroup(named: String(repeating: "A long group name ", count: 6))
        populated.moveSnapshot(id: populated.snapshots[0].id, to: groupID)
        populated.createGroup(named: "Empty Group")
        var rootSnapshot = populated.snapshots[0]
        rootSnapshot.id = UUID()
        rootSnapshot.name = "Top Level Snapshot"
        rootSnapshot.groupID = nil
        populated.snapshots.append(rootSnapshot)
        
        for document in [ScreenshotHubDocument(), populated] {
            let host = NSHostingView(rootView: DocumentView(document: document, expectedDraft: document.draft))
            let window = NSWindow(
                contentRect: .init(x: 0, y: 0, width: 1280, height: 982),
                styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: true
            )
            window.toolbar = NSToolbar(identifier: "DocumentLayoutValidation")
            window.toolbarStyle = .unified
            window.contentView = host
            window.layoutIfNeeded()
            guard let controller = splitController(in: host) else {
                preconditionFailure("The actual document must mount the production workspace.")
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            precondition(window.title == "Draft", "The selected draft must keep its window title: \(window.title)")
            validateInspectorTabs(window: window, controller: controller)
            for _ in 0..<3 {
                for width in Array(stride(from: 960, through: 1600, by: 8))
                    + Array(stride(from: 1600, through: 960, by: -8)) {
                    window.setContentSize(.init(width: width, height: 982))
                    window.layoutIfNeeded()
                    RunLoop.current.run(until: Date().addingTimeInterval(0.001))
                    window.layoutIfNeeded()
                    precondition(abs(host.bounds.width - CGFloat(width)) < 1,
                                 "The document must accept the requested window width: \(width)")
                    validateColumns(controller, width: CGFloat(width), sidebar: true, inspector: true)
                    validateTitlebarBackgrounds(controller, window: window)
                }
            }
            guard let outline = outlineView(in: controller.splitViewItems[0].viewController.view) else {
                preconditionFailure("The sidebar must mount a native outline view.")
            }
            precondition(outline.allowsMultipleSelection, "Snapshots must support native multiple selection.")
            let levels = (0..<outline.numberOfRows).map { outline.level(forRow: $0) }
            precondition(levels == (document.snapshots.isEmpty ? [0] : [0, 0, 0, 1, 0]),
                         "Root must be invisible; top-level snapshots and groups must be peers, with grouped snapshots nested: \(levels)")
            if !document.snapshots.isEmpty {
                outline.selectRowIndexes(.init(integer: 1), byExtendingSelection: false)
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                precondition(window.title == "Top Level Snapshot", "Selecting a snapshot must update the window title.")
                validateInspectorTabs(window: window, controller: controller)
                outline.selectRowIndexes(.init(integer: 0), byExtendingSelection: false)
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                precondition(window.title == "Draft")
                outline.selectRowIndexes(.init([1, 3]), byExtendingSelection: false)
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                precondition(outline.selectedRowIndexes == .init([1, 3]),
                             "A top-level snapshot and a grouped snapshot must remain selected together.")
                outline.selectAll(nil)
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                precondition(outline.selectedRowIndexes == .init([1, 3]),
                             "Select All must select snapshots across groups while excluding Draft and group rows: \(Array(outline.selectedRowIndexes))")
                try validateSnapshotDragging(outline: outline)
            }
            window.contentView = nil
        }
        print("Validated hierarchical snapshot rows, hidden Root, native multiple selection, and 972 full-height document window resizes with titlebar backgrounds outside the preview.")
        if runsAsApp {
            fflush(stdout)
            let window = NSWindow(contentRect: .init(x: 200, y: 200, width: 420, height: 100),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.title = "Snapshot Drag Validation"
            window.contentView = NSTextField(labelWithString: "Native snapshot drag validation passed.")
            window.makeKeyAndOrderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { NSApplication.shared.terminate(nil) }
            NSApplication.shared.run()
        }
    }
    
    @MainActor
    private static func validateDeviceFrameGroups() {
        for family in DeviceFamily.allCases {
            let frames = DeviceFrame.all.filter { $0.family == family }
            let groups = DeviceFrameGroup.groups(for: frames)
            let groupedFrames = groups.flatMap(\.frames)
            precondition(groupedFrames.count == frames.count)
            precondition(Set(groupedFrames.map(\.id)) == Set(frames.map(\.id)),
                         "Grouping must retain every frame without changing identifiers.")
            precondition(Set(groups.map(\.id)).count == groups.count)
        }
        let phones = DeviceFrameGroup.groups(for: DeviceFrame.all.filter { $0.family == .iPhone })
        for model in ["iPhone 17", "iPhone 17 Pro", "iPhone 17 Pro Max"] {
            let group = phones.first { $0.name == model }!
            precondition(group.frames.count > 1)
            precondition(group.frames.allSatisfy { $0.name.hasPrefix(model + " - ") },
                         "Different iPhone models must have separate menus.")
        }
        let watches = DeviceFrameGroup.groups(for: DeviceFrame.all.filter { $0.family == .appleWatch })
        for size in ["42mm", "46mm"] {
            let group = watches.first { $0.name == "Apple Watch S10 - " + size }!
            precondition(group.frames.count > 1)
            precondition(group.frames.allSatisfy { $0.name.contains(" - " + size + " - ") })
        }
        let reference = DeviceFrame.all.first { $0.family == .iPhone }!
        let embedded = DeviceFrame(id: "EmbeddedLegacyFrame", name: "Retired Phone - Silver",
                                   family: .iPhone, width: reference.width, height: reference.height,
                                   screenX: reference.screenX, screenY: reference.screenY,
                                   screenWidth: reference.screenWidth, screenHeight: reference.screenHeight,
                                   isLandscape: reference.isLandscape)
        var configuration = ScreenshotConfiguration()
        configuration.storedFrame = embedded
        configuration.frameID = embedded.id
        let groups = DeviceFrameGroup.groups(for: configuration.availableFrames)
        precondition(groups.first { $0.name == "Retired Phone" }?.frames == [embedded],
                     "Frames embedded in existing documents must remain selectable.")
        precondition(configuration.frame?.id == embedded.id)
        print("Validated frame model groups, color and band variants, Watch case sizes, and embedded document frames.")
    }

    @MainActor
    private static func validateInspectorSelection() {
        let suiteName = "ScreenshotHub.InspectorValidation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        precondition(InspectorSelection.load(from: defaults).isVisible)
        var selection = InspectorSelection()
        precondition(selection.tab == .device && selection.isVisible)
        selection.select(.content)
        selection.setVisible(false)
        precondition(selection.tab == nil && selection.displayedTab == .content)
        selection.toggleVisibility()
        precondition(selection.tab == .content, "Reopening the inspector must restore its last tab.")
        selection.select(nil)
        selection.select(.device)
        precondition(selection.tab == .device && selection.isVisible)
        selection.setVisible(false)
        selection.save(to: defaults)
        selection = .load(from: defaults)
        precondition(!selection.isVisible, "A hidden inspector must remain hidden after reopening.")
        selection.toggleVisibility()
        selection.save(to: defaults)
        precondition(InspectorSelection.load(from: defaults).isVisible,
                     "An expanded inspector must remain expanded after reopening.")
    }

    @MainActor
    private static func validateWorkspacePersistence() {
        let suiteName = "ScreenshotHub.WorkspaceValidation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        func makeWindow(inspector: Bool, width: CGFloat = 1280) -> (NSWindow, WorkspaceSplitController) {
            let controller = WorkspaceSplitController(
                sidebar: AnyView(Text("Snapshots")),
                preview: AnyView(Color.clear),
                inspector: AnyView(Text("Inspector")),
                defaults: defaults
            )
            controller.setVisibility(sidebar: true, inspector: inspector)
            let window = NSWindow(
                contentRect: .init(x: 0, y: 0, width: width, height: 820),
                styleMask: [.titled, .resizable], backing: .buffered, defer: true
            )
            window.contentViewController = controller
            window.setContentSize(.init(width: width, height: 820))
            window.layoutIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            window.layoutIfNeeded()
            return (window, controller)
        }
        func validateWidths(_ controller: WorkspaceSplitController, sidebar: CGFloat, inspector: CGFloat) {
            let sidebarWidth = controller.splitViewItems[0].viewController.view.bounds.width
            let inspectorWidth = controller.splitViewItems[2].viewController.view.bounds.width
            precondition(abs(sidebarWidth - sidebar) <= 1,
                         "Expected restored sidebar width \(sidebar), got \(sidebarWidth).")
            precondition(abs(inspectorWidth - inspector) <= 1,
                         "Expected restored inspector width \(inspector), got \(inspectorWidth).")
        }
        for widths in [(245.0, 375.0), (195, 320)] {
            let (window, controller) = makeWindow(inspector: true)
            controller.splitView.setPosition(widths.0, ofDividerAt: 0)
            controller.splitView.setPosition(1280 - widths.1 - controller.splitView.dividerThickness, ofDividerAt: 1)
            window.layoutIfNeeded()
            validateWidths(controller, sidebar: widths.0, inspector: widths.1)
            let storedInspectorWidth = defaults.double(forKey: "workspaceInspectorWidth")
            for visible in [false, true] {
                controller.setVisibility(sidebar: true, inspector: visible, animated: true)
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
                window.layoutIfNeeded()
                precondition(defaults.double(forKey: "workspaceInspectorWidth") == storedInspectorWidth,
                             "Animation frames must not overwrite the saved inspector width.")
                RunLoop.current.run(until: Date().addingTimeInterval(0.25))
                window.layoutIfNeeded()
                precondition(controller.splitViewItems[2].isCollapsed == !visible)
                if visible { validateWidths(controller, sidebar: widths.0, inspector: widths.1) }
            }
            for visible in [false, true, false] {
                controller.setVisibility(sidebar: true, inspector: visible, animated: true)
                RunLoop.current.run(until: Date().addingTimeInterval(0.04))
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.35))
            window.layoutIfNeeded()
            precondition(controller.splitViewItems[2].isCollapsed,
                         "Rapid animation reversals must settle at the latest visibility.")
            window.contentViewController = nil

            let (reopenedWindow, reopenedController) = makeWindow(inspector: false, width: 1500)
            precondition(reopenedController.splitViewItems[2].isCollapsed)
            reopenedController.setVisibility(sidebar: true, inspector: true)
            reopenedWindow.layoutIfNeeded()
            validateWidths(reopenedController, sidebar: widths.0, inspector: widths.1)
            reopenedController.splitViewItems[2].isCollapsed = true
            reopenedWindow.layoutIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            reopenedController.splitViewItems[2].isCollapsed = false
            reopenedWindow.layoutIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            validateWidths(reopenedController, sidebar: widths.0, inspector: widths.1)
            reopenedWindow.contentViewController = nil

            let (expandedWindow, expandedController) = makeWindow(inspector: true, width: 1100)
            validateWidths(expandedController, sidebar: widths.0, inspector: widths.1)
            expandedWindow.contentViewController = nil
        }
        print("Validated persisted sidebar and inspector widths, animated collapse/expansion, rapid reversals, and workspace recreation.")
    }

    @MainActor
    private static func validateInspectorTabs(window: NSWindow, controller: WorkspaceSplitController) {
        func findPicker(in view: NSView) -> NSSegmentedControl? {
            if let control = view as? NSSegmentedControl,
               control.accessibilityIdentifier() == "InspectorTabs" { return control }
            return view.subviews.lazy.compactMap { findPicker(in: $0) }.first
        }
        func picker() -> NSSegmentedControl {
            guard let picker = window.toolbar?.items.lazy.compactMap({ item in
                item.view.flatMap { findPicker(in: $0) }
            }).first else { preconditionFailure("The native inspector tab picker must be in the toolbar.") }
            return picker
        }
        precondition(picker().segmentCount == 2 && picker().isSelected(forSegment: 0))
        let title = window.title
        precondition(!title.isEmpty)
        for index in 0..<2 {
            precondition(picker().label(forSegment: index)?.isEmpty != false,
                         "Inspector tabs must display icons without text labels.")
            precondition(picker().image(forSegment: index) != nil)
            precondition(picker().toolTip(forSegment: index) != nil)
        }
        func select(_ index: Int, enabled: Bool) {
            let control = picker()
            control.setSelected(enabled, forSegment: index)
            precondition(control.sendAction(control.action!, to: control.target))
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            window.layoutIfNeeded()
            precondition(window.title == title, "Switching or hiding inspector tabs must preserve the selected item title.")
        }
        select(1, enabled: true)
        precondition(picker().isSelected(forSegment: 1) && !picker().isSelected(forSegment: 0))
        precondition(!controller.splitViewItems[2].isCollapsed)
        select(1, enabled: false)
        precondition(!picker().isSelected(forSegment: 0) && !picker().isSelected(forSegment: 1))
        precondition(controller.splitViewItems[2].isCollapsed,
                     "Deselecting the active tab must collapse the inspector.")
        select(0, enabled: true)
        precondition(picker().isSelected(forSegment: 0) && !controller.splitViewItems[2].isCollapsed)
        // Native divider gestures must keep the toolbar selection in sync too.
        controller.splitViewItems[2].isCollapsed = true
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        precondition(!picker().isSelected(forSegment: 0) && !picker().isSelected(forSegment: 1))
        controller.splitViewItems[2].isCollapsed = false
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        precondition(picker().isSelected(forSegment: 0))
        print("Validated native inspector tab switching, exclusive selection, deselection, and divider visibility synchronization.")
    }

    @MainActor
    private static func validateSnapshotDragging(outline: NSOutlineView) throws {
        guard let source = outline.dataSource else { preconditionFailure("Missing outline data source.") }
        let first = outline.item(atRow: 1)!
        let second = outline.item(atRow: 3)!
        let firstGroup = outline.item(atRow: 2)!
        let emptyGroup = outline.item(atRow: 4)!
        precondition(source.outlineView?(outline, pasteboardWriterForItem: outline.item(atRow: 0)!) as? NSPasteboardItem == nil)
        precondition(source.outlineView?(outline, pasteboardWriterForItem: emptyGroup) as? NSPasteboardItem == nil)
        let writers = [first, second].map { item -> NSPasteboardItem in
            guard let writer = source.outlineView?(outline, pasteboardWriterForItem: item) as? NSPasteboardItem else {
                preconditionFailure("Snapshots must supply native pasteboard writers.")
            }
            return writer
        }
        let rect = outline.rect(ofRow: 1)
        precondition(outline.canDragRows(with: .init([1, 3]), at: .init(x: rect.midX, y: rect.midY)),
                     "The native outline must recognize snapshot rows as drag sources.")
        for writer in writers {
            let ids = try JSONDecoder().decode([UUID].self, from: writer.data(forType: SnapshotOutlineList.pasteboardType)!)
            precondition(ids.count == 1, "Each dragged row must publish exactly one snapshot identifier.")
        }
        precondition(outline.registeredDraggedTypes.contains(SnapshotOutlineList.pasteboardType))
        let cell = outline.view(atColumn: 0, row: 1, makeIfNecessary: true)!
        precondition(cell.subviews.allSatisfy { view in
            view.hitTest(.init(x: view.bounds.midX, y: view.bounds.midY)) == nil
        }, "Snapshot content must not intercept native row drag events.")
        let pasteboard = NSPasteboard(name: .init("ScreenshotHub.DragValidation.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        guard pasteboard.writeObjects(writers) else {
            precondition(Bundle.main.object(forInfoDictionaryKey: "NativeDragValidation") as? Bool != true,
                         "Native drag writers must publish their data to the pasteboard.")
            print("Validated native drag recognition, payloads, and hit testing. Pasteboard service is unavailable; run the native validation app for system drag/drop checks.")
            return
        }
        let info = DraggingInfo(pasteboard: pasteboard)
        precondition(source.outlineView?(outline, validateDrop: info, proposedItem: emptyGroup,
                                        proposedChildIndex: NSOutlineViewDropOnItemIndex) == .move)
        precondition(source.outlineView?(outline, acceptDrop: info, item: emptyGroup,
                                        childIndex: NSOutlineViewDropOnItemIndex) == true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        precondition(source.outlineView?(outline, numberOfChildrenOfItem: emptyGroup) == 2)
        precondition(source.outlineView?(outline, numberOfChildrenOfItem: firstGroup) == 0)
        precondition(outline.selectedRowIndexes == .init([3, 4]), "Moving rows must preserve the multi-selection.")
        precondition(source.outlineView?(outline, child: 0, ofItem: emptyGroup) as? NSObject === first as? NSObject)
        precondition(source.outlineView?(outline, child: 1, ofItem: emptyGroup) as? NSObject === second as? NSObject)
        precondition(source.outlineView?(outline, validateDrop: info, proposedItem: first,
                                        proposedChildIndex: NSOutlineViewDropOnItemIndex) == [])
        precondition(source.outlineView?(outline, validateDrop: info, proposedItem: nil, proposedChildIndex: 1) == .move)
        precondition(source.outlineView?(outline, acceptDrop: info, item: nil, childIndex: 1) == true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        precondition(source.outlineView?(outline, numberOfChildrenOfItem: emptyGroup) == 0)
        precondition(outline.selectedRowIndexes == .init([1, 2]))
        precondition(source.outlineView?(outline, child: 1, ofItem: nil) as? NSObject === first as? NSObject)
        precondition(source.outlineView?(outline, child: 2, ofItem: nil) as? NSObject === second as? NSObject)
        outline.collapseItem(firstGroup)
        pasteboard.clearContents()
        precondition(pasteboard.writeObjects([writers[0]]))
        precondition(source.outlineView?(outline, validateDrop: info, proposedItem: firstGroup,
                                        proposedChildIndex: NSOutlineViewDropOnItemIndex) == .move)
        precondition(source.outlineView?(outline, acceptDrop: info, item: firstGroup,
                                        childIndex: NSOutlineViewDropOnItemIndex) == true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        precondition(outline.isItemExpanded(firstGroup), "Dropping into a collapsed group must reveal the moved snapshot.")
        let invalid = NSPasteboardItem()
        invalid.setData(try JSONEncoder().encode([UUID()]), forType: SnapshotOutlineList.pasteboardType)
        pasteboard.clearContents()
        precondition(pasteboard.writeObjects([invalid]))
        precondition(source.outlineView?(outline, validateDrop: info, proposedItem: emptyGroup,
                                        proposedChildIndex: NSOutlineViewDropOnItemIndex) == [])
        precondition(source.outlineView?(outline, acceptDrop: info, item: emptyGroup,
                                        childIndex: NSOutlineViewDropOnItemIndex) == false)
        let malformed = NSPasteboardItem()
        malformed.setData(Data("invalid".utf8), forType: SnapshotOutlineList.pasteboardType)
        pasteboard.clearContents()
        precondition(pasteboard.writeObjects([malformed]))
        precondition(source.outlineView?(outline, validateDrop: info, proposedItem: emptyGroup,
                                        proposedChildIndex: NSOutlineViewDropOnItemIndex) == [])
        print("Validated native drag sources, real pasteboard data, multi-item drops into empty groups, stable ordering/selection, top-level drops, collapsed-group expansion, and invalid payload rejection.")
    }
    
    @MainActor
    private static func outlineView(in view: NSView) -> NSOutlineView? {
        if let outline = view as? NSOutlineView { return outline }
        for child in view.subviews {
            if let outline = outlineView(in: child) { return outline }
        }
        return nil
    }
    
    @MainActor
    private static func validateWorkspaceSplitView() {
        let host = NSHostingView(rootView: workspace(sidebar: true, inspector: true, revision: 0))
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 1280, height: 982),
            styleMask: [.titled, .resizable], backing: .buffered, defer: true
        )
        window.contentView = host
        window.layoutIfNeeded()
        guard let controller = splitController(in: host) else {
            preconditionFailure("The production workspace split controller must be mounted.")
        }
        var resizes = 0
        let widths = Array(stride(from: 900, through: 1600, by: 7)) + [1234, 1258]
        for revision in 0..<3 {
            for visibility in [(true, true), (true, false), (false, true), (false, false)] {
                host.rootView = workspace(sidebar: visibility.0, inspector: visibility.1, revision: revision)
                for width in widths + widths.reversed() {
                    window.setContentSize(.init(width: width, height: 982))
                    window.layoutIfNeeded()
                    RunLoop.current.run(until: Date().addingTimeInterval(0.001))
                    window.layoutIfNeeded()
                    validateColumns(controller, width: CGFloat(width), sidebar: visibility.0, inspector: visibility.1)
                    resizes += 1
                }
            }
        }
        host.rootView = workspace(sidebar: true, inspector: true, revision: 0)
        window.setContentSize(.init(width: 1280, height: 982))
        window.layoutIfNeeded()
        for sidebarWidth in [180.0, 220, 280] {
            controller.splitView.setPosition(sidebarWidth, ofDividerAt: 0)
            for inspectorWidth in [310.0, 340, 400] {
                controller.splitView.setPosition(1280 - inspectorWidth - controller.splitView.dividerThickness, ofDividerAt: 1)
                window.layoutIfNeeded()
                validateColumns(controller, width: 1280, sidebar: true, inspector: true)
                precondition(abs(controller.splitViewItems[0].viewController.view.bounds.width - sidebarWidth) <= 1)
                precondition(abs(controller.splitViewItems[2].viewController.view.bounds.width - inspectorWidth) <= 1)
            }
        }
        let previewViewport = controller.splitViewItems[1].viewController.view
        for topInset in [0.0, 28, 52, 80] {
            previewViewport.additionalSafeAreaInsets = .init(top: topInset, left: 0, bottom: 0, right: 0)
            for width in [900.0, 1258, 1600] {
                window.setContentSize(.init(width: width, height: 982))
                window.layoutIfNeeded()
                validateColumns(controller, width: width, sidebar: true, inspector: true)
                let host = hostingView(in: previewViewport)!
                precondition(abs(host.bounds.height - (previewViewport.bounds.height - previewViewport.safeAreaInsets.top)) < 1,
                             "The toolbar inset must reduce the usable preview height.")
            }
        }
        window.contentView = nil
        print("Validated \(resizes) workspace resizes, sidebar/inspector visibility, content changes, divider widths, and toolbar safe-area insets.")
    }
    
    @MainActor
    private static func validateToolbarOverlap() {
        let controller = WorkspaceSplitController(
            sidebar: AnyView(Text("Snapshots")),
            preview: AnyView(Color.blue),
            inspector: AnyView(Text("Inspector"))
        )
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 1280, height: 982),
            styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: true
        )
        window.toolbar = NSToolbar(identifier: "PreviewLayoutValidation")
        window.contentViewController = controller
        for style in [NSWindow.ToolbarStyle.unified, .unifiedCompact] {
            window.toolbarStyle = style
            for width in [900.0, 1258, 1600] {
                window.setContentSize(.init(width: width, height: 982))
                window.layoutIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.001))
                window.layoutIfNeeded()
                let viewport = controller.splitViewItems[1].viewController.view
                let host = hostingView(in: viewport)!
                let frame = host.convert(host.bounds, to: nil)
                precondition(frame.height > 0)
                precondition(frame.maxY <= window.contentLayoutRect.maxY + 1,
                             "The native toolbar must not cover the preview: \(frame), \(window.contentLayoutRect)")
            }
        }
        window.contentViewController = nil
        print("Validated preview bounds below unified and compact native toolbars.")
    }
    
    @MainActor
    private static func splitController(in view: NSView) -> WorkspaceSplitController? {
        if let split = view as? NSSplitView, let controller = split.delegate as? WorkspaceSplitController {
            return controller
        }
        for child in view.subviews {
            if let controller = splitController(in: child) { return controller }
        }
        return nil
    }
    
    @MainActor
    private static func workspace(sidebar: Bool, inspector: Bool, revision: Int) -> AnyView {
        AnyView(WorkspaceSplitView(
            sidebar: Text(String(repeating: "A long snapshot name ", count: 8 + revision)),
            preview: Color.clear.overlay {
                Color.blue.aspectRatio(revision == 1 ? 1.6 : 0.46, contentMode: .fit)
            },
            inspector: ScrollView {
                Text(String(repeating: "Inspector text that wraps during horizontal resizing. ", count: 80 + revision))
            },
            showsSidebar: .constant(sidebar),
            showsInspector: .constant(inspector)
        ).frame(minWidth: 900, maxWidth: .infinity, minHeight: 650, maxHeight: .infinity))
    }
    
    @MainActor
    private static func validateColumns(_ controller: WorkspaceSplitController, width: CGFloat, sidebar: Bool, inspector: Bool) {
        precondition(abs(controller.splitView.bounds.width - width) < 1)
        precondition(abs(controller.splitView.bounds.height - 982) < 1,
                     "The workspace must fill the available window height.")
        let items = controller.splitViewItems
        precondition(items[0].isCollapsed == !sidebar && items[2].isCollapsed == !inspector)
        for item in items {
            let column = item.viewController.view
            guard let host = hostingView(in: column) else {
                preconditionFailure("Every production column must use a SwiftUI hosting view.")
            }
            precondition(host.sizingOptions.isEmpty, "Content must not change the native column constraints.")
            precondition(host.sceneBridgingOptions.isEmpty,
                         "Column hosts must not override the document window title or toolbar.")
            if !item.isCollapsed {
                precondition(column.bounds.width >= item.minimumThickness - 1)
                if item.maximumThickness != NSSplitViewItem.unspecifiedDimension {
                    precondition(column.bounds.width <= item.maximumThickness + 1)
                }
            }
        }
        let viewport = items[1].viewController.view
        let previewHost = hostingView(in: viewport)!
        let previewFrame = previewHost.convert(previewHost.bounds, to: viewport)
        let safeFrame = viewport.safeAreaRect
        precondition(abs(previewFrame.minX - safeFrame.minX) < 1 && abs(previewFrame.maxX - safeFrame.maxX) < 1)
        precondition(abs(previewFrame.minY - safeFrame.minY) < 1 && abs(previewFrame.maxY - safeFrame.maxY) < 1,
                     "Preview content must remain inside the toolbar safe area.")
        let frames = items.map { item in
            let view = item.viewController.view
            return view.convert(view.bounds, to: controller.splitView)
        }
        precondition(abs(frames[1].minX - (sidebar ? frames[0].maxX : 0)) <= controller.splitView.dividerThickness,
                     "The sidebar and preview must remain adjacent: \(frames)")
        precondition(abs(frames[1].maxX - (inspector ? frames[2].minX : width)) <= controller.splitView.dividerThickness,
                     "The preview and inspector must remain adjacent: \(frames)")
    }
    
    @MainActor
    private static func validateTitlebarBackgrounds(_ controller: WorkspaceSplitController, window: NSWindow) {
        precondition(window.contentView!.safeAreaInsets.top > 0,
                     "The fixture must include a real toolbar safe area.")
        let backgrounds = titlebarBackgrounds(in: controller.splitView)
        precondition(!backgrounds.isEmpty, "The fixture must exercise AppKit's automatic split titlebar backgrounds.")
        for background in backgrounds {
            let frame = background.convert(background.bounds, to: nil)
            precondition(frame.minY >= window.contentLayoutRect.maxY - 1,
                         "Split titlebar glass must not extend below the actual toolbar: \(frame), \(window.contentLayoutRect)")
        }
        let viewport = controller.splitViewItems[1].viewController.view
        let host = hostingView(in: viewport)!
        let frame = host.convert(host.bounds, to: nil)
        precondition(frame.maxY <= window.contentLayoutRect.maxY + 1,
                     "Preview content must remain below the actual toolbar.")
    }
    
    @MainActor
    private static func titlebarBackgrounds(in view: NSView) -> [NSView] {
        var result: [NSView] = []
        if String(describing: type(of: view)) == "NSTitlebarBackgroundView" { result.append(view) }
        for child in view.subviews { result.append(contentsOf: titlebarBackgrounds(in: child)) }
        return result
    }
    
    @MainActor
    private static func hostingView(in view: NSView) -> NSHostingView<AnyView>? {
        if let host = view as? NSHostingView<AnyView> { return host }
        for child in view.subviews {
            if let host = hostingView(in: child) { return host }
        }
        return nil
    }
    
    private struct DocumentView: View {
        @State var document: ScreenshotHubDocument
        let expectedDraft: ScreenshotDraft
        
        var body: some View {
            ContentView(document: $document)
                .onChange(of: document.draft) { _, draft in
                    precondition(draft == expectedDraft, "Opening a saved draft must not overwrite its image or composition with window defaults.")
                }
        }
    }
}

private final class DraggingInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .move }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    
    init(pasteboard: NSPasteboard) { draggingPasteboard = pasteboard }
    
    func resetSpringLoading() {}
    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func enumerateDraggingItems(
        options: NSDraggingItemEnumerationOptions,
        for view: NSView?,
        classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
}
