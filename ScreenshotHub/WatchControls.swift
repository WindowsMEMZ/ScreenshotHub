import AppKit
import SwiftUI
import UniformTypeIdentifiers
    
struct WatchDeviceControls: View {
    @Binding var configuration: WatchConfiguration

    var body: some View {
        Section {
            Toggle("Include Apple Watch", isOn: $configuration.isEnabled)
        } header: {
            Label("Apple Watch", systemImage: "applewatch")
        }
    }
}

struct WatchContentControls: View {
    @Binding var configuration: WatchConfiguration
    @Binding var screenshotData: Data?
    @Binding var sourceName: String
    @Binding var source: ScreenshotSource
    var isDraft: Bool
    var feed: SimulatorFeed
    var onRetry: () -> Void
    
    @State private var isImporting = false
    @State private var errorMessage: String?
    
    var body: some View {
        Section {
            DeviceFramePicker(title: "Watch Frame", selection: $configuration.frameID,
                              frames: configuration.availableFrames)
            if isDraft {
                Picker("Screenshot Source", selection: $source) {
                    Text("Image File").tag(ScreenshotSource.file)
                    Text("Device Hub").tag(ScreenshotSource.simulator)
                }
            }
            if source == .file {
                LabeledContent("Screenshot") {
                    Button(screenshotData == nil ? "Choose Image…" : sourceName) { isImporting = true }
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if screenshotData != nil {
                    Button("Remove Watch Screenshot", role: .destructive) {
                        screenshotData = nil
                        sourceName = ""
                    }
                }
            } else {
                watchSimulatorControls
            }
            Toggle("Replace Displayed Time", isOn: $configuration.clock.isEnabled)
            if configuration.clock.isEnabled {
                TextField("Time", text: $configuration.clock.time)
                    .onChange(of: configuration.clock.time) { _, value in
                        if value.count > 8 { configuration.clock.time = String(value.prefix(8)) }
                    }
            }
            DisclosureGroup("Watch Layout") {
                InspectorSlider(title: "Size", value: $configuration.scale,
                                range: WatchConfiguration.scaleRange,
                                display: "\(Int(configuration.scale * 100))%")
                InspectorSlider(title: "Horizontal Position", value: $configuration.horizontalPosition,
                                range: 0...1, display: "\(Int(configuration.horizontalPosition * 100))%")
            }
        } header: {
            Label("Apple Watch", systemImage: "applewatch")
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.image]) { result in
            do { try importImage(result.get()) }
            catch { errorMessage = error.localizedDescription }
        }
        .alert("Unable to Import Watch Screenshot", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }
    
    @ViewBuilder
    private var watchSimulatorControls: some View {
        LabeledContent("Apple Watch") {
            HStack(spacing: 8) {
                Picker("Apple Watch", selection: Binding(
                    get: { feed.selectedDeviceID }, set: { feed.selectedDeviceID = $0 }
                )) {
                    Text(feed.devices.isEmpty ? "No Running Apple Watches" : "Select an Apple Watch")
                        .tag(nil as String?)
                    ForEach(feed.devices) { device in
                        Text(device.label).tag(Optional(device.id))
                    }
                }
                .labelsHidden()
                Button("Refresh Watch List", systemImage: "arrow.clockwise") {
                    Task { await feed.refreshDevices() }
                }
                .labelStyle(.iconOnly)
                .help("Refresh Watch List")
            }
        }
        if let message = feed.listError ?? feed.captureError ?? feed.inputError {
            Text(message).font(.caption).foregroundStyle(.red)
            Button("Retry Connection", action: onRetry)
        } else if feed.devices.isEmpty {
            Text("Start an Apple Watch simulator in Device Hub.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func importImage(_ url: URL) throws {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
        guard let image = NSImage(data: try Data(contentsOf: url)), image.size.width > 0, image.size.height > 0 else {
            throw SimulatorClient.ClientError.invalidScreenshot
        }
        screenshotData = try DeviceFrameImages.pngData(for: image)
        sourceName = url.lastPathComponent
    }
}
