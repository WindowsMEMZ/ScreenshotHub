import AppKit
import SwiftUI

struct SnapshotRow: View {
    let snapshot: ScreenshotSnapshot
    let frameImages: DeviceFrameImages?
    var watchFrameImages: DeviceFrameImages? = nil
    
    @State private var thumbnail: NSImage?
    
    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 42, height: 60)
            .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 4) {
                Text(snapshot.name.isEmpty ? "Untitled Snapshot" : snapshot.name)
                    .lineLimit(2)
                Text(snapshot.configuration.resolution.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if snapshot.configuration.variantCount > 0 {
                    Text("\(snapshot.configuration.variantCount) variants")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .task(id: previewRequest) {
            thumbnail = nil
            do {
                let rendered = try await ScreenshotPreviewRenderer.shared.render(previewRequest)
                try Task.checkCancellation()
                thumbnail = .init(cgImage: rendered.image, size: .zero)
            } catch {}
        }
    }
    
    private var previewRequest: ScreenshotPreviewRequest {
        .init(
            configuration: snapshot.configuration,
            screenshotData: snapshot.screenshotData,
            watchScreenshotData: snapshot.watchScreenshotData,
            frameImages: frameImages,
            watchFrameImages: watchFrameImages,
            maximumDimension: 180
        )
    }
}
