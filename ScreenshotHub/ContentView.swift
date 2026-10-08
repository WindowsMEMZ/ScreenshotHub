import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
    
struct ContentView: View {
    @Binding var document: ScreenshotHubDocument
    @Environment(\.displayScale) private var displayScale
    
    @State private var configuration = ScreenshotConfiguration()
    @State private var selection = SnapshotList.SnapshotSelection.draft
    @State private var selectedItems: Set<SnapshotList.SnapshotSelection> = [.draft]
    @State private var snapshotName = ""
    @State private var hasLoadedDraft = false
    @State private var hasRestoredDraftSource = false
    @State private var showsSnapshots = true
    @State private var inspectorSelection = InspectorSelection()
    @State private var screenshotSource = ScreenshotSource.file
    @State private var simulatorFeed = SimulatorFeed()
    @State private var simulatorRetry = 0
    @State private var watchFeed = SimulatorFeed(isWatch: true)
    @State private var watchRetry = 0
    @State private var watchSource = ScreenshotSource.file
    @State private var watchScreenshotData: Data?
    @State private var watchSourceName = ""
    @State private var watchScreenshot: NSImage?
    @State private var watchOverlay: CGImage?
    @State private var watchScreenMask: CGImage?
    @State private var isPreparingExport = false
    @State private var screenshot: NSImage?
    @State private var screenshotName = ""
    @State private var screenshotSize = ""
    @State private var loadedScreenshotData: Data?
    @State private var previewTask: Task<Void, Never>?
    @State private var previewRequest: ScreenshotPreviewRequest?
    @State private var isRenderingPreview = false
    @State private var exportProgress: SnapshotExportProgress?
    @State private var exportTask: Task<Void, Never>?
    @State private var preview: NSImage?
    @State private var previewMaximumDimension: CGFloat = 1100
    @State private var liveOverlay: CGImage?
    @State private var isImporting = false
    @State private var isExporting = false
    @State private var isDropTargeted = false
    @State private var exportDocument: PNGDocument?
    @State private var exportFilename = "Snapshot"
    @State private var errorMessage: String?
    
    private var workspace: some View {
        WorkspaceSplitView(
            sidebar: snapshotList,
            preview: previewPanel,
            inspector: configurationPanel,
            showsSidebar: $showsSnapshots,
            showsInspector: .init(
                get: { inspectorSelection.isVisible },
                set: { inspectorSelection.setVisible($0) }
            )
        )
        .frame(minWidth: 900, maxWidth: .infinity, minHeight: 650, maxHeight: .infinity)
        // AppKit positions its titlebar backgrounds relative to the full-height split view.
        .ignoresSafeArea(.container, edges: .top)
        .navigationTitle(isDraft ? "Draft" : snapshotName)
        .navigationSubtitle("\(configuration.resolution.label) px")
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Snapshots", systemImage: "sidebar.left") { showsSnapshots.toggle() }
            }
            ToolbarItem(placement: .primaryAction) {
                Button(
                    isPreparingExport ? "Processing…" : "Capture Snapshot",
                    systemImage: "camera",
                    action: createSnapshot
                )
                    .keyboardShortcut("k", modifiers: .command)
                    .disabled(!isDraft || !hasScreenshot || configuration.frame == nil || isPreparingExport)
            }
            ToolbarItem(placement: .primaryAction) {
                Menu("Export", systemImage: "square.and.arrow.up") {
                    Button(selectedSnapshots.count > 1 ? "Export Selected Snapshots…" : "Export Selected Snapshot…", action: exportSelectedSnapshot)
                        .keyboardShortcut("e", modifiers: .command)
                        .disabled(selectedSnapshots.isEmpty || isPreparingExport)
                    Button("Export All Snapshots…", action: exportAllSnapshots)
                        .disabled(document.snapshots.isEmpty || isPreparingExport)
                }
                .menuIndicator(.hidden)
            }
            ToolbarSpacer()
            ToolbarItem {
                InspectorTabPicker(selection: .init(
                    get: { inspectorSelection.tab },
                    set: { inspectorSelection.select($0) }
                ))
                .fixedSize()
            }
        }
        .focusedSceneValue(\.toggleInspector, { inspectorSelection.toggleVisibility() })
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.image]) { result in
            switch result {
            case .success(let url): importScreenshot(url)
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: .png,
            defaultFilename: exportFilename
        ) { result in
            switch result {
            case .success: break
            case .failure(let error): errorMessage = error.localizedDescription
            }
            exportDocument = nil
        }
        .alert("Unable to Complete Operation", isPresented: .init(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }
    
    private var synchronizedWorkspace: some View {
        workspace
        .onChange(of: configuration, initial: true) { _, _ in
            guard hasLoadedDraft else { return }
            saveSnapshotEdits()
            updatePreview()
        }
        .onChange(of: snapshotName) { _, name in
            guard let index = selectedSnapshotIndex, document.snapshots[index].name != name else { return }
            document.snapshots[index].name = name
        }
        .onChange(of: document.snapshots) { _, _ in synchronizeSelectedSnapshot() }
        .onChange(of: document.draft) { _, _ in synchronizeDraft() }
        .onChange(of: screenshotSource) { _, _ in
            if isDraft { configuration.usesSourceScreenCutouts = screenshotSource == .simulator }
            selectSimulatorFamily()
            saveDraftEdits()
            updatePreview()
        }
        .onChange(of: simulatorFeed.selectedDeviceID) { _, _ in
            guard hasRestoredDraftSource else { return }
            selectSimulatorFamily()
            saveDraftEdits()
            updatePreview()
        }
        .onChange(of: simulatorFeed.frameSize) { _, _ in
            guard isDraft, screenshotSource == .simulator else { return }
            matchSimulatorOrientation()
        }
        .onChange(of: watchSource) { _, _ in
            saveDraftEdits()
            updatePreview()
        }
        .onChange(of: watchScreenshotData) { _, data in
            watchScreenshot = data.flatMap(NSImage.init(data:))
            saveWatchScreenshot()
            updatePreview()
        }
        .onChange(of: watchSourceName) { _, _ in saveWatchScreenshot() }
        .onChange(of: watchFeed.selectedDeviceID) { _, _ in
            guard hasRestoredDraftSource else { return }
            saveDraftEdits()
        }
    }
    
    var body: some View {
        synchronizedWorkspace
        .onAppear { updatePreview() }
        .onDisappear {
            previewTask?.cancel()
            previewRequest = nil
            exportTask?.cancel()
        }
        .sheet(isPresented: .init(
            get: { exportProgress != nil },
            set: { _ in }
        )) {
            if let exportProgress {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Exporting Images").font(.headline)
                    ProgressView(value: Double(exportProgress.completedCount), total: Double(exportProgress.totalCount))
                    HStack {
                        Text("\(exportProgress.completedCount) of \(exportProgress.totalCount) images")
                            .monospacedDigit()
                        Spacer()
                        Text(exportProgress.fractionCompleted, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit()
                    }
                    .font(.caption)
                    Text(exportProgress.filename ?? "Preparing images…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack {
                        Spacer()
                        Button("Cancel", role: .cancel) { exportTask?.cancel() }
                    }
                }
                .padding(24)
                .frame(width: 420)
                .interactiveDismissDisabled()
            }
        }
        .task(id: isDraft && usesWatch && watchSource == .simulator && hasRestoredDraftSource) {
            guard isDraft, usesWatch, watchSource == .simulator, hasRestoredDraftSource else { return }
            await watchFeed.monitorDevices()
        }
        .task(id: SimulatorStreamKey(deviceID: liveWatchID, retry: watchRetry)) {
            guard let deviceID = liveWatchID else { return }
            await watchFeed.stream(deviceID: deviceID)
        }
        .task { await restoreDraftSource() }
        .task(id: isDraft && screenshotSource == .simulator && hasRestoredDraftSource) {
            guard isDraft, screenshotSource == .simulator, hasRestoredDraftSource else { return }
            await simulatorFeed.monitorDevices()
        }
        .task(id: SimulatorStreamKey(deviceID: liveSimulatorID, retry: simulatorRetry)) {
            guard let deviceID = liveSimulatorID else { return }
            await simulatorFeed.stream(deviceID: deviceID)
        }
    }
    
    private var snapshotList: some View {
        SnapshotList(
            document: $document,
            selection: .init(get: { selectedItems }, set: setSnapshotSelection),
            isPreparingExport: isPreparingExport,
            onExportSnapshot: exportSnapshot,
            onExportSnapshots: exportSnapshots,
            onDeleteSnapshots: deleteSnapshots,
            onDeleteSelection: deleteSelectedSnapshot
        )
    }
    
    private var configurationPanel: some View {
        Form {
            switch inspectorSelection.displayedTab {
            case .device: deviceConfiguration
            case .content: contentConfiguration
            }
        }
        .formStyle(.grouped)
        .id(inspectorSelection.displayedTab)
        .disabled(isPreparingExport)
    }

    @ViewBuilder
    private var deviceConfiguration: some View {
        Section {
            Picker("Device Type", selection: .init(
                get: { configuration.family },
                set: { configuration.selectFamily($0) }
            )) {
                ForEach(DeviceFamily.canvasFamilies) { family in
                    Text(family.label).tag(family)
                }
            }
            Picker("Output Resolution", selection: .init(
                get: { configuration.resolution },
                set: { configuration.selectResolution($0) }
            )) {
                if configuration.family == .iPhone {
                    ForEach(PhoneResolutionCategory.allCases) { category in
                        Section(category.label) {
                            ForEach(category.resolutions) { resolution in
                                Text(resolution.label).tag(resolution)
                            }
                        }
                    }
                } else {
                    ForEach(configuration.family.resolutions) { resolution in
                        Text(resolution.label).tag(resolution)
                    }
                }
            }
            ColorPicker("Canvas Background", selection: $configuration.backgroundColor, supportsOpacity: false)
        } header: {
            Label("Canvas", systemImage: "rectangle.portrait")
        }

        if configuration.family == .iPhone {
            Section {
                ForEach(configuration.availableVariantCategories) { category in
                    Toggle(isOn: .init(
                        get: { configuration.variantCategories.contains(category) },
                        set: { enabled in
                            if enabled {
                                configuration.variantCategories.insert(category)
                            } else {
                                configuration.variantCategories.remove(category)
                            }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(category.label)
                            Text(category.closestResolution(to: configuration.resolution).label + " px")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if usesWatch {
                    Toggle("Apple Watch", isOn: $configuration.exportsWatchVariant)
                }
            } header: {
                Label("Variants", systemImage: "square.stack")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Export enabled variants together with this snapshot.")
                    if usesWatch {
                        Text("Export the Watch screen with its replaced time, without a device frame. The closest supported resolution is chosen from the captured image.")
                    }
                }
            }

            WatchDeviceControls(configuration: $configuration.watch)
        }
    }

    @ViewBuilder
    private var contentConfiguration: some View {
        Section(isDraft ? "Draft" : "Edit Snapshot") {
            if isDraft {
                Text("Set up the canvas, text, and device, then capture a snapshot.")
                    .foregroundStyle(.secondary)
            } else {
                TextField("Snapshot Name", text: $snapshotName)
                Text("Changes are saved in the document.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        Section {
            if isDraft {
                Picker("Screenshot Source", selection: $screenshotSource) {
                    Text("Image File").tag(ScreenshotSource.file)
                    Text("Device Hub").tag(ScreenshotSource.simulator)
                }
            }
            if screenshotSource == .file {
                fileScreenshotControls
            } else {
                simulatorControls
            }
        } header: {
            Label("App Screenshot", systemImage: "photo")
        } footer: {
            Text(screenshotSource == .file
                 ? "Screenshots are scaled proportionally and cropped to fill the device screen."
                 : "Click the screen to interact. Drag to swipe, or hold for a long press.")
        }

        if isDraft, screenshotSource == .simulator {
            SimulatorStatusBarControls(feed: simulatorFeed)
        }

        if usesWatch {
            WatchContentControls(configuration: $configuration.watch, screenshotData: $watchScreenshotData,
                                 sourceName: $watchSourceName, source: $watchSource, isDraft: isDraft,
                                 feed: watchFeed, onRetry: { watchRetry &+= 1 })
        }

        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("Headline")
                HeadlineEditor(text: $configuration.title, selection: $configuration.highlightRange)
                    .frame(height: 108)
                    .background(.background)
                    .clipShape(.rect(cornerRadius: 6))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary)
                    }
            }
            LabeledContent("Highlight") {
                HStack(spacing: 8) {
                    Text(configuration.highlightedText.isEmpty ? "None" : configuration.highlightedText)
                        .foregroundStyle(configuration.highlightedText.isEmpty ? Color.secondary : configuration.themeColor)
                        .lineLimit(2)
                    if !configuration.highlightedText.isEmpty {
                        Button("Clear") { configuration.highlightRange = .init(location: 0, length: 0) }
                    }
                }
            }
            ColorPicker("Theme Color", selection: $configuration.themeColor, supportsOpacity: false)
            ColorPicker("Text Color", selection: $configuration.textColor, supportsOpacity: false)
            labeledSlider("Font Size", value: $configuration.fontScale, range: 0.025...0.085,
                          display: "\(Int(Double(min(configuration.resolution.width, configuration.resolution.height)) * configuration.fontScale)) px")
        } header: {
            Label("Text & Colors", systemImage: "textformat")
        } footer: {
            Text("Select text to highlight it with the theme color.")
        }

        Section {
            DeviceFramePicker(title: "Device Frame", selection: $configuration.frameID,
                              frames: configuration.availableFrames)
            Toggle("Device Shadow", isOn: $configuration.showsShadow)
            labeledSlider("Device Scale", value: $configuration.deviceScale, range: 0.55...1.1,
                          display: "\(Int(configuration.deviceScale * 100))%")
            labeledSlider("Vertical Position", value: $configuration.deviceOffset, range: -0.08...0.08,
                          display: "\(Int(configuration.deviceOffset * 100))%")
            Button("Reset Layout") {
                configuration.deviceScale = 1
                configuration.deviceOffset = 0
                configuration.fontScale = 0.052
            }
        } header: {
            Label("Device", systemImage: configuration.family.symbol)
        }
    }

    private var hasScreenshot: Bool {
        let phoneHasImage = screenshotSource == .file ? screenshot != nil : simulatorFeed.hasCurrentFrame
        let watchHasImage = !usesWatch || (watchSource == .file ? watchScreenshotData != nil : watchFeed.hasCurrentFrame)
        return phoneHasImage && watchHasImage
    }
    
    private var liveSimulatorID: String? {
        isDraft && screenshotSource == .simulator && hasRestoredDraftSource ? simulatorFeed.selectedDeviceID : nil
    }
    
    private var usesWatch: Bool { configuration.family == .iPhone && configuration.watch.isEnabled }
    private var liveWatchID: String? {
        isDraft && usesWatch && watchSource == .simulator && hasRestoredDraftSource ? watchFeed.selectedDeviceID : nil
    }
    private var hasLivePreview: Bool {
        screenshotSource == .simulator || (usesWatch && watchSource == .simulator)
    }
    
    @ViewBuilder
    private var fileScreenshotControls: some View {
        LabeledContent("Screenshot") {
            Button(screenshot == nil ? "Choose Image…" : screenshotName) { isImporting = true }
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .help("Choose an image, or drag an image onto this row.")
        .background(isDropTargeted ? Color.accentColor.opacity(0.12) : Color.clear)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            importScreenshot(url)
            return true
        } isTargeted: { isDropTargeted = $0 }
        if let screenshot {
            LabeledContent("Preview") {
                Image(nsImage: screenshot)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 48, height: 64)
                    .accessibilityLabel("Screenshot preview")
            }
            LabeledContent("Image Size", value: screenshotSize)
            if isDraft {
                Button("Remove Screenshot", role: .destructive) {
                    self.screenshot = nil
                    loadedScreenshotData = nil
                    screenshotName = ""
                    screenshotSize = ""
                    saveDraftEdits()
                    updatePreview()
                }
            }
        }
    }

    @ViewBuilder
    private var simulatorControls: some View {
        LabeledContent("Simulator") {
            HStack(spacing: 8) {
                Picker("Simulator", selection: $simulatorFeed.selectedDeviceID) {
                    Text(simulatorFeed.devices.isEmpty ? "No Running Simulators" : "Select a Simulator")
                        .tag(nil as String?)
                    ForEach(simulatorFeed.devices) { device in
                        Text(device.label).tag(Optional(device.id))
                    }
                }
                .labelsHidden()
                Button("Refresh Simulator List", systemImage: "arrow.clockwise") {
                    Task { await simulatorFeed.refreshDevices() }
                }
                .labelStyle(.iconOnly)
                .help("Refresh Simulator List")
            }
        }
        if let message = simulatorFeed.listError ?? simulatorFeed.captureError {
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
            if simulatorFeed.captureError != nil {
                Button("Retry Streaming") { simulatorRetry &+= 1 }
            }
        } else if simulatorFeed.devices.isEmpty {
            Text("Start an iPhone or iPad simulator in Device Hub. The list updates automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if simulatorFeed.hasCurrentFrame {
            LabeledContent("Stream") {
                Label("Live Compositing", systemImage: "dot.radiowaves.left.and.right")
                    .foregroundStyle(.tint)
            }
            LabeledContent("Image Size", value: simulatorFeed.imageSize)
        } else if simulatorFeed.selectedDeviceID != nil {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for screen frames…").font(.caption)
            }
        }
        if let inputError = simulatorFeed.inputError {
            Text(inputError)
                .font(.caption)
                .foregroundStyle(.red)
            Button("Retry Connection") { simulatorRetry &+= 1 }
        }
    }

    private var previewPanel: some View {
        Group {
            if hasLivePreview, let liveOverlay {
                SimulatorCanvasPreview(
                    feed: simulatorFeed,
                    overlay: liveOverlay,
                    screenRect: ScreenshotRenderer.screenRect(configuration: configuration),
                    canvasSize: configuration.resolution.size,
                    backgroundColor: NSColor(configuration.backgroundColor),
                    watchFeed: watchFeed,
                    watchOverlay: watchOverlay,
                    watchScreenRect: ScreenshotRenderer.watchScreenRect(configuration: configuration),
                    watchCrownRect: ScreenshotRenderer.watchCrownRect(configuration: configuration),
                    watchScreenMask: watchScreenMask,
                    watchClockConfiguration: configuration.watch.clock,
                    streamsPhone: screenshotSource == .simulator,
                    streamsWatch: usesWatch && watchSource == .simulator
                )
            } else if let preview {
                Color.clear.overlay {
                    Image(nsImage: preview)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .shadow(color: .black.opacity(0.12), radius: 14, y: 5)
                }
            } else if isRenderingPreview {
                ProgressView("Rendering Preview…")
            } else {
                ContentUnavailableView("Preview Unavailable", systemImage: "photo", description: Text("Select an available device frame."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGFloat.self) { geometry in
            PreviewRenderSizing.maximumDimension(canvasSize: configuration.resolution.size,
                                                  viewportSize: geometry.size, displayScale: displayScale)
        } action: { dimension in
            guard previewMaximumDimension != dimension else { return }
            previewMaximumDimension = dimension
            updatePreview()
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 16)
        .background(Color(nsColor: .underPageBackgroundColor))
    }
    
    private func labeledSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, display: String) -> some View {
        InspectorSlider(title: title, value: value, range: range, display: display)
    }
    
    private func importScreenshot(_ url: URL) {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            guard let image = NSImage(data: data), image.size.width > 0, image.size.height > 0,
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                errorMessage = "Unable to read this image. Choose a PNG, JPEG, or another supported image."
                return
            }
            let png = try DeviceFrameImages.pngData(for: image)
            screenshot = image
            loadedScreenshotData = png
            screenshotName = url.lastPathComponent
            screenshotSize = "\(cgImage.width) × \(cgImage.height) px · Click to replace"
            if let index = selectedSnapshotIndex {
                document.snapshots[index].screenshotData = png
                document.snapshots[index].sourceName = screenshotName
            }
            saveDraftEdits()
            updatePreview()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    
    private func updatePreview() {
        let request = ScreenshotPreviewRequest(
            configuration: configuration,
            screenshotData: loadedScreenshotData,
            watchScreenshotData: watchScreenshotData,
            frameImages: document.frames[configuration.frameID],
            watchFrameImages: document.frames[configuration.watch.frameID],
            maximumDimension: previewMaximumDimension,
            streamsPhone: screenshotSource == .simulator,
            streamsWatch: usesWatch && watchSource == .simulator
        )
        guard previewRequest != request else { return }
        previewRequest = request
        previewTask?.cancel()
        isRenderingPreview = true
        previewTask = Task {
            await Task.yield()
            guard !Task.isCancelled else { return }
            do {
                let rendered = try await ScreenshotPreviewRenderer.shared.render(request)
                try Task.checkCancellation()
                preview = .init(cgImage: rendered.image, size: .zero)
                liveOverlay = request.hasLivePreview ? rendered.image : nil
                watchOverlay = rendered.watchOverlay
                watchScreenMask = rendered.watchScreenMask
                isRenderingPreview = false
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                preview = nil
                liveOverlay = nil
                watchOverlay = nil
                watchScreenMask = nil
                isRenderingPreview = false
                previewRequest = nil
                errorMessage = error.localizedDescription
            }
        }
    }
    
    private func selectSimulatorFamily() {
        guard isDraft, hasRestoredDraftSource, screenshotSource == .simulator, let device = simulatorFeed.selectedDevice else { return }
        let family: DeviceFamily = device.isIPad ? .iPad : .iPhone
        if configuration.family != family { configuration.selectFamily(family) }
        matchSimulatorOrientation()
    }
    
    private func matchSimulatorOrientation() {
        guard configuration.family == .iPad, simulatorFeed.selectedDevice?.isIPad == true,
              let frame = simulatorFeed.currentFrame else { return }
        configuration.matchSimulatorScreen(.init(width: frame.width, height: frame.height))
    }
    
    private func createSnapshot() {
        guard isDraft, hasScreenshot, !isPreparingExport else { return }
        isPreparingExport = true
        let deviceID = screenshotSource == .simulator ? simulatorFeed.selectedDeviceID : nil
        Task {
            defer { isPreparingExport = false }
            do {
                let image: NSImage
                if let deviceID {
                    image = try await simulatorFeed.captureForExport(deviceID: deviceID)
                    matchSimulatorOrientation()
                } else if let screenshot {
                    image = screenshot
                } else {
                    return
                }
                guard isDraft else { return }
                let png = try DeviceFrameImages.pngData(for: image)
                let watchPNG: Data?
                let capturedWatchName: String
                if usesWatch, watchSource == .simulator, let watchID = watchFeed.selectedDeviceID {
                    let watchImage = try await watchFeed.captureForExport(deviceID: watchID)
                    watchPNG = try DeviceFrameImages.pngData(for: watchImage)
                    capturedWatchName = watchFeed.selectedDevice?.label ?? "Apple Watch"
                } else {
                    watchPNG = watchScreenshotData
                    capturedWatchName = watchSourceName
                }
                guard isDraft else { return }
                var savedConfiguration = configuration
                savedConfiguration.usesSourceScreenCutouts = deviceID != nil
                var updatedDocument = document
                try updatedDocument.storeFrame(for: &savedConfiguration)
                let name = nextSnapshotName
                let snapshot = ScreenshotSnapshot(
                    name: name,
                    configuration: savedConfiguration,
                    screenshotData: png,
                    sourceName: deviceID != nil ? simulatorFeed.selectedDevice?.label ?? "Simulator" : screenshotName,
                    watchScreenshotData: watchPNG,
                    watchSourceName: capturedWatchName
                )
                updatedDocument.snapshots.append(snapshot)
                document = updatedDocument
                selectSnapshot(.snapshot(snapshot.id))
            } catch is CancellationError {
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
    
    private var isDraft: Bool { selection == .draft }
    
    private var selectedSnapshotIndex: Int? {
        guard case .snapshot(let id) = selection else { return nil }
        return document.snapshots.firstIndex { $0.id == id }
    }
    
    private var selectedSnapshot: ScreenshotSnapshot? {
        selectedSnapshotIndex.map { document.snapshots[$0] }
    }
    
    private var selectedSnapshots: [ScreenshotSnapshot] {
        document.orderedSnapshots.filter { selectedItems.contains(.snapshot($0.id)) }
    }
    
    private func setSnapshotSelection(_ items: Set<SnapshotList.SnapshotSelection>) {
        var items = items
        if items.count > 1 { items.remove(.draft) }
        selectedItems = items
        guard !items.contains(selection) else { return }
        let next = selectedSnapshots.first.map { SnapshotList.SnapshotSelection.snapshot($0.id) } ?? .draft
        selectSnapshot(next, updatesListSelection: false)
    }
    
    private var nextSnapshotName: String {
        var number = document.snapshots.count + 1
        while document.snapshots.contains(where: { $0.name == "Snapshot \(number)" }) { number += 1 }
        return "Snapshot \(number)"
    }
    
    private func selectSnapshot(_ selection: SnapshotList.SnapshotSelection, updatesListSelection: Bool = true) {
        if updatesListSelection { selectedItems = [selection] }
        guard self.selection != selection else { return }
        saveSnapshotEdits()
        self.selection = selection
        previewTask?.cancel()
        previewRequest = nil
        preview = nil
        liveOverlay = nil
        watchOverlay = nil
        watchScreenMask = nil
        if isDraft {
            synchronizeDraft()
            snapshotName = ""
            selectSimulatorFamily()
        } else {
            screenshotSource = .file
            watchSource = .file
            synchronizeSelectedSnapshot()
        }
        updatePreview()
    }
    
    private func synchronizeSelectedSnapshot() {
        let validItems = Set(document.snapshots.map { SnapshotList.SnapshotSelection.snapshot($0.id) } + [.draft])
        selectedItems.formIntersection(validItems)
        guard !isDraft else { return }
        guard let snapshot = selectedSnapshot else {
            if let next = selectedSnapshots.first {
                selectSnapshot(.snapshot(next.id), updatesListSelection: false)
            } else {
                selectSnapshot(.draft)
            }
            return
        }
        if configuration != snapshot.configuration { configuration = snapshot.configuration }
        if snapshotName != snapshot.name { snapshotName = snapshot.name }
        screenshotName = snapshot.sourceName
        watchSourceName = snapshot.watchSourceName
        if watchScreenshotData != snapshot.watchScreenshotData {
            watchScreenshotData = snapshot.watchScreenshotData
            watchScreenshot = snapshot.watchScreenshotData.flatMap(NSImage.init(data:))
        }
        if loadedScreenshotData != snapshot.screenshotData {
            loadedScreenshotData = snapshot.screenshotData
            screenshot = NSImage(data: snapshot.screenshotData)
            screenshotSize = Self.screenshotSize(for: snapshot.screenshotData)
        }
        updatePreview()
    }
    
    private func saveSnapshotEdits() {
        if isDraft {
            saveDraftEdits()
            return
        }
        guard let index = selectedSnapshotIndex, document.snapshots[index].configuration != configuration else { return }
        do {
            var updatedConfiguration = configuration
            var updatedDocument = document
            try updatedDocument.storeFrame(for: &updatedConfiguration)
            updatedDocument.snapshots[index].configuration = updatedConfiguration
            document = updatedDocument
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    
    private func synchronizeDraft() {
        guard isDraft else { return }
        let draft = document.draft
        if configuration != draft.configuration { configuration = draft.configuration }
        if screenshotSource != draft.source { screenshotSource = draft.source }
        if simulatorFeed.selectedDeviceID != draft.simulatorID { simulatorFeed.selectedDeviceID = draft.simulatorID }
        screenshotName = draft.sourceName
        if watchSource != draft.watchSource { watchSource = draft.watchSource }
        if watchFeed.selectedDeviceID != draft.watchSimulatorID { watchFeed.selectedDeviceID = draft.watchSimulatorID }
        watchSourceName = draft.watchSourceName
        if watchScreenshotData != draft.watchScreenshotData {
            watchScreenshotData = draft.watchScreenshotData
            watchScreenshot = draft.watchScreenshotData.flatMap(NSImage.init(data:))
        }
        if loadedScreenshotData != draft.screenshotData {
            loadedScreenshotData = draft.screenshotData
            screenshot = draft.screenshotData.flatMap(NSImage.init(data:))
            screenshotSize = Self.screenshotSize(for: draft.screenshotData)
        }
        updatePreview()
    }
    
    private func saveWatchScreenshot() {
        if let index = selectedSnapshotIndex {
            if document.snapshots[index].watchScreenshotData != watchScreenshotData {
                document.snapshots[index].watchScreenshotData = watchScreenshotData
            }
            if document.snapshots[index].watchSourceName != watchSourceName {
                document.snapshots[index].watchSourceName = watchSourceName
            }
        } else { saveDraftEdits() }
    }
    
    private func saveDraftEdits() {
        guard isDraft, hasLoadedDraft else { return }
        do {
            var updatedDocument = document
            var updatedConfiguration = configuration
            try updatedDocument.storeFrame(for: &updatedConfiguration)
            let draft = ScreenshotDraft(
                configuration: updatedConfiguration,
                screenshotData: loadedScreenshotData,
                sourceName: screenshotName,
                source: screenshotSource,
                simulatorID: hasRestoredDraftSource ? simulatorFeed.selectedDeviceID : document.draft.simulatorID,
                watchScreenshotData: watchScreenshotData,
                watchSourceName: watchSourceName,
                watchSource: watchSource,
                watchSimulatorID: hasRestoredDraftSource ? watchFeed.selectedDeviceID : document.draft.watchSimulatorID
            )
            guard document.draft != draft else { return }
            updatedDocument.draft = draft
            document = updatedDocument
        } catch {
            errorMessage = error.localizedDescription
        }
    }
    
    private func restoreDraftSource() async {
        guard !hasRestoredDraftSource else { return }
        if !hasLoadedDraft {
            hasLoadedDraft = true
            synchronizeDraft()
        }
        let savedDraft = document.draft
        if savedDraft.source == .simulator {
            await simulatorFeed.refreshDevices(automaticallySelectsDevice: false)
            guard !Task.isCancelled else { return }
            if document.draft.source == savedDraft.source, document.draft.simulatorID == savedDraft.simulatorID {
                var restoredDraft = document.draft
                restoredDraft.restoreSource(runningSimulatorIDs: simulatorFeed.devices.map(\.id))
                document.draft = restoredDraft
                if isDraft { screenshotSource = restoredDraft.source }
            }
        }
        if savedDraft.watchSource == .simulator {
            await watchFeed.refreshDevices(automaticallySelectsDevice: false)
            guard !Task.isCancelled else { return }
            if document.draft.watchSource == savedDraft.watchSource, document.draft.watchSimulatorID == savedDraft.watchSimulatorID {
                var restoredDraft = document.draft
                restoredDraft.restoreWatchSource(runningSimulatorIDs: watchFeed.devices.map(\.id))
                document.draft = restoredDraft
                if isDraft { watchSource = restoredDraft.watchSource }
            }
        }
        hasRestoredDraftSource = true
        selectSimulatorFamily()
        saveDraftEdits()
        updatePreview()
    }
    
    private static func screenshotSize(for data: Data?) -> String {
        guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return "" }
        return "\(width) × \(height) px · Click to replace"
    }
    
    private func deleteSelectedSnapshot() {
        deleteSnapshots(Set(selectedSnapshots.map(\.id)))
    }
    
    private func deleteSnapshots(_ ids: Set<UUID>) {
        document.snapshots.removeAll { ids.contains($0.id) }
        synchronizeSelectedSnapshot()
    }
    
    private func exportSelectedSnapshot() {
        let snapshots = selectedSnapshots
        if snapshots.count == 1, let snapshot = snapshots.first { exportSnapshot(snapshot) }
        else if !snapshots.isEmpty { exportSnapshots(snapshots) }
    }
    
    private func exportSnapshot(_ snapshot: ScreenshotSnapshot) {
        guard !isPreparingExport else { return }
        if snapshot.configuration.variantCount > 0 {
            exportSnapshots([snapshot])
            return
        }
        isPreparingExport = true
        let frames = document.frames
        exportFilename = SnapshotImageExporter.filename(for: snapshot, in: document)
        exportTask = Task {
            defer {
                isPreparingExport = false
                exportTask = nil
            }
            do {
                let data = try await SnapshotImageExporter.prepareImageData(
                    for: snapshot,
                    frameImages: frames[snapshot.configuration.frameID],
                    watchFrameImages: frames[snapshot.configuration.watch.frameID]
                )
                try Task.checkCancellation()
                exportDocument = .init(data: data)
                isExporting = true
            } catch is CancellationError {
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
    
    private func exportAllSnapshots() {
        guard !document.snapshots.isEmpty, !isPreparingExport else { return }
        exportSnapshots(document.orderedSnapshots)
    }
    
    private func exportSnapshots(_ snapshots: [ScreenshotSnapshot]) {
        guard !snapshots.isEmpty, !isPreparingExport else { return }
        let exportSource = document
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export Snapshots"
        panel.message = "Choose an export location. Snapshots and enabled variants will be saved as PNG images in a new folder."
        panel.begin { response in
            guard response == .OK, let directory = panel.url, !isPreparingExport else { return }
            isPreparingExport = true
            exportProgress = .init(
                completedCount: 0,
                totalCount: snapshots.reduce(0) { $0 + 1 + $1.configuration.variantCount }
            )
            exportTask = Task {
                let hasAccess = directory.startAccessingSecurityScopedResource()
                defer {
                    if hasAccess { directory.stopAccessingSecurityScopedResource() }
                    isPreparingExport = false
                    exportProgress = nil
                    exportTask = nil
                }
                do {
                    let folder = try await SnapshotImageExporter.exportSnapshots(
                        snapshots, frames: exportSource.frames, groups: exportSource.groups,
                        orderedSnapshots: exportSource.snapshots, to: directory
                    ) { progress in
                        exportProgress = progress
                    }
                    NSWorkspace.shared.activateFileViewerSelecting([folder])
                } catch is CancellationError {
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
    
    private struct SimulatorStreamKey: Equatable {
        var deviceID: String?
        var retry: Int
    }
}
    

private struct PNGDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.png] }
    
    var data: Data
    
    init(data: Data) {
        self.data = data
    }
    
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        .init(regularFileWithContents: data)
    }
}
    
