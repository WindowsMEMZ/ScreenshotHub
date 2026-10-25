import AppKit
import SwiftUI

@main
struct ValidateDocument {
    @MainActor
    static func main() async throws {
        if CommandLine.arguments.count > 2 {
            _ = NSApplication.shared
            let catalog = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
            for frame in DeviceFrame.all {
                for suffix in ["", "Mask"] {
                    let name = frame.id + suffix
                    let image = NSImage(contentsOf: catalog.appendingPathComponent("\(name).imageset/image.png"))!
                    precondition(image.setName(.init(name)))
                }
            }
        }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let emptyPackage = try ScreenshotHubDocument().package()
        let emptyDocument = try ScreenshotHubDocument(package: emptyPackage)
        precondition(emptyDocument.snapshots.isEmpty)
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 48, pixelsHigh: 80,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32
        )!
        for y in 0..<80 {
            for x in 0..<48 {
                bitmap.setColor(.init(calibratedRed: Double(x) / 48, green: 0.5, blue: Double(y) / 80, alpha: 1), atX: x, y: y)
            }
        }
        let source = bitmap.representation(using: .png, properties: [:])!
        let importedPNG = try DeviceFrameImages.pngData(for: NSImage(data: source)!)
        let importedBitmap = NSBitmapImageRep(data: importedPNG)!
        precondition(importedBitmap.pixelsWide == 48 && importedBitmap.pixelsHigh == 80,
                     "Storing imported images must preserve their original pixel dimensions.")
        let sourceBitmap = NSBitmapImageRep(data: source)!
        for (x, y) in [(0, 0), (47, 79)] {
            let original = sourceBitmap.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
            let stored = importedBitmap.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
            precondition(abs(original.redComponent - stored.redComponent) < 0.005
                         && abs(original.greenComponent - stored.greenComponent) < 0.005
                         && abs(original.blueComponent - stored.blueComponent) < 0.005,
                         "Importing a screenshot must preserve its pixels and orientation.")
        }
        var document = ScreenshotHubDocument()
        for family in DeviceFamily.canvasFamilies {
            var configuration = ScreenshotConfiguration()
            configuration.selectFamily(family)
            configuration.title = "测试 🧑🏽‍💻 快照\n保留全部配置。"
            configuration.highlightRange = (configuration.title as NSString).range(of: "🧑🏽‍💻 快照")
            configuration.themeColor = .init(.sRGB, red: 0.2, green: 0.4, blue: 0.6)
            configuration.textColor = .init(.sRGB, red: 0.1, green: 0.2, blue: 0.3)
            configuration.backgroundColor = .init(.sRGB, red: 0.8, green: 0.7, blue: 0.6)
            configuration.fontScale = 0.048
            configuration.deviceScale = 0.9
            configuration.deviceOffset = -0.02
            configuration.showsShadow = family != .mac
            configuration.usesSourceScreenCutouts = family == .iPhone
            try document.storeFrame(for: &configuration)
            document.snapshots.append(.init(name: "相同/名称", configuration: configuration,
                                            screenshotData: source, sourceName: "设备 \(family.label)"))
        }
        document.draft = .init(
            configuration: document.snapshots[2].configuration,
            screenshotData: source,
            sourceName: "Draft image.png",
            source: .file,
            simulatorID: "PHONE"
        )
        var duplicate = document.snapshots[0]
        duplicate.id = UUID()
        document.snapshots.append(duplicate)
        precondition(document.frames.count == 3)
        let url = directory.appendingPathComponent("RoundTrip.sshub", isDirectory: true)
        try document.package().write(to: url, options: .atomic, originalContentsURL: nil)
        let reopened = try ScreenshotHubDocument(package: readPackage(at: url))
        precondition(reopened.snapshots.map(\.id) == document.snapshots.map(\.id))
        precondition(reopened.frames == document.frames)
        precondition(reopened.draft == document.draft,
                     "Draft images, names, source, device selection, and every composition field must survive reopening.")
        let stored = try StoredScreenshotConfiguration(document.snapshots[0].configuration)
        var oldConfiguration = try JSONSerialization.jsonObject(with: JSONEncoder().encode(stored)) as! [String: Any]
        oldConfiguration.removeValue(forKey: "usesSourceScreenCutouts")
        oldConfiguration.removeValue(forKey: "variantCategories")
        oldConfiguration.removeValue(forKey: "exportsWatchVariant")
        let decoded = try JSONDecoder().decode(StoredScreenshotConfiguration.self,
                                               from: JSONSerialization.data(withJSONObject: oldConfiguration))
        let oldComposition = try decoded.configuration()
        precondition(!oldComposition.usesSourceScreenCutouts,
                     "Documents written before source cutout support must retain their original bezel rendering.")
        precondition(oldComposition.variantCategories.isEmpty, "Older documents must open with variants disabled.")
        precondition(!oldComposition.exportsWatchVariant, "Older documents must not enable standalone Watch export.")
        var liveDraft = document
        liveDraft.draft.source = .simulator
        let liveURL = directory.appendingPathComponent("DeviceHubDraft.sshub", isDirectory: true)
        try liveDraft.package().write(to: liveURL, options: .atomic, originalContentsURL: nil)
        let liveCopy = try ScreenshotHubDocument(package: readPackage(at: liveURL))
        precondition(liveCopy.draft == liveDraft.draft)
        var runningDraft = liveCopy.draft
        runningDraft.restoreSource(runningSimulatorIDs: ["IPAD", "PHONE"])
        precondition(runningDraft == liveCopy.draft, "A running saved device must keep its Device Hub source.")
        for devices in [[], ["IPAD"]] as [[String]] {
            var stoppedDraft = liveCopy.draft
            stoppedDraft.restoreSource(runningSimulatorIDs: devices)
            precondition(stoppedDraft.source == .file && stoppedDraft.simulatorID == nil)
            precondition(stoppedDraft.screenshotData == source && stoppedDraft.configuration == liveCopy.draft.configuration,
                         "An unavailable device must fall back to the saved image without changing the composition or using another device.")
        }
        var noDeviceDraft = liveCopy.draft
        noDeviceDraft.simulatorID = nil
        noDeviceDraft.restoreSource(runningSimulatorIDs: ["PHONE"])
        precondition(noDeviceDraft.source == .file)
        var fileDraft = reopened.draft
        fileDraft.restoreSource(runningSimulatorIDs: [])
        precondition(fileDraft == reopened.draft, "Image drafts must restore without simulator discovery.")
        var draftOnly = ScreenshotHubDocument()
        draftOnly.frames = document.frames
        draftOnly.draft = liveCopy.draft
        let draftOnlyCopy = try ScreenshotHubDocument(package: draftOnly.package())
        precondition(draftOnlyCopy.snapshots.isEmpty && draftOnlyCopy.draft == draftOnly.draft)
        precondition(draftOnlyCopy.frames.count == 1 && draftOnlyCopy.frames[draftOnly.draft.configuration.frameID] != nil,
                     "A document without snapshots must still embed the draft's frame.")
        draftOnly.draft.screenshotData = nil
        draftOnly.draft.sourceName = ""
        let removedImageCopy = try ScreenshotHubDocument(package: draftOnly.package())
        precondition(removedImageCopy.draft.screenshotData == nil)
        let packageWithoutImage = try draftOnly.package()
        precondition(packageWithoutImage.fileWrappers!["Screenshots"]!.fileWrappers!.isEmpty)
        let legacy = try document.package()
        var legacyManifest = try JSONSerialization.jsonObject(with: legacy.fileWrappers!["manifest.json"]!.regularFileContents!) as! [String: Any]
        legacyManifest["version"] = 1
        legacyManifest.removeValue(forKey: "draft")
        try replaceManifest(in: legacy, with: legacyManifest)
        let migrated = try ScreenshotHubDocument(package: legacy)
        precondition(migrated.snapshots == document.snapshots && migrated.draft.source == .file)
        let migratedCopy = try ScreenshotHubDocument(package: migrated.package())
        precondition(migratedCopy.snapshots == migrated.snapshots && migratedCopy.draft == migrated.draft)
        let missingDraftImage = try document.package()
        let draftScreenshots = missingDraftImage.fileWrappers!["Screenshots"]!
        draftScreenshots.removeFileWrapper(draftScreenshots.fileWrappers!["Draft.png"]!)
        expectInvalid(missingDraftImage)
        let missingDraftFrame = try draftOnly.package()
        let draftFrames = missingDraftFrame.fileWrappers!["Frames"]!
        draftFrames.removeFileWrapper(draftFrames.fileWrappers!.values.first!)
        expectInvalid(missingDraftFrame)
        let missingDraft = try document.package()
        var missingDraftManifest = try JSONSerialization.jsonObject(with: missingDraft.fileWrappers!["manifest.json"]!.regularFileContents!) as! [String: Any]
        missingDraftManifest.removeValue(forKey: "draft")
        try replaceManifest(in: missingDraft, with: missingDraftManifest)
        expectInvalid(missingDraft)
        for (original, restored) in zip(document.snapshots, reopened.snapshots) {
            precondition(original.name == restored.name && original.sourceName == restored.sourceName)
            precondition(original.screenshotData == restored.screenshotData)
            let before = try JSONEncoder().encode(StoredScreenshotConfiguration(original.configuration))
            let after = try JSONEncoder().encode(StoredScreenshotConfiguration(restored.configuration))
            let beforeObject = try JSONSerialization.jsonObject(with: before) as! NSDictionary
            let afterObject = try JSONSerialization.jsonObject(with: after) as! NSDictionary
            precondition(beforeObject == afterObject, "Every editable field must survive a package saved to disk.")
        }
        var edited = reopened
        let frozenImage = edited.snapshots[0].screenshotData
        edited.snapshots[0].configuration.title = "修改后的标题"
        edited.snapshots[0].configuration.highlightRange = .init(location: 0, length: 2)
        edited.snapshots[0].configuration.selectFamily(.mac)
        var editedConfiguration = edited.snapshots[0].configuration
        try edited.storeFrame(for: &editedConfiguration)
        edited.snapshots[0].configuration = editedConfiguration
        let editedCopy = try ScreenshotHubDocument(package: edited.package())
        precondition(editedCopy.snapshots[0].configuration.title == "修改后的标题")
        precondition(editedCopy.snapshots[0].configuration.family == .mac)
        precondition(editedCopy.snapshots[0].screenshotData == frozenImage,
                     "Changing a snapshot's composition must keep its captured screen immutable.")
        
        var portable = ScreenshotHubDocument()
        var snapshot = reopened.snapshots[0]
        var archivedFrame = snapshot.configuration.frame!
        archivedFrame = .init(id: "ArchivedFrame", name: archivedFrame.name, family: archivedFrame.family,
                              width: archivedFrame.width, height: archivedFrame.height,
                              screenX: archivedFrame.screenX, screenY: archivedFrame.screenY,
                              screenWidth: archivedFrame.screenWidth, screenHeight: archivedFrame.screenHeight,
                              isLandscape: archivedFrame.isLandscape)
        snapshot.configuration.storedFrame = archivedFrame
        snapshot.configuration.frameID = archivedFrame.id
        portable.frames[archivedFrame.id] = reopened.frames[reopened.snapshots[0].configuration.frameID]
        portable.snapshots = [snapshot]
        let portableCopy = try ScreenshotHubDocument(package: portable.package())
        precondition(!DeviceFrame.all.contains { $0.id == archivedFrame.id })
        let portablePNG = try SnapshotImageExporter.imageData(for: portableCopy.snapshots[0], frameImages: portableCopy.frames[archivedFrame.id])
        let exported = NSBitmapImageRep(data: portablePNG)!
        precondition(exported.pixelsWide == 1284 && exported.pixelsHigh == 2778 && !exported.hasAlpha,
                     "Embedded frame assets must render without a corresponding asset in the installed app.")
        
        let folder = try await SnapshotImageExporter.exportAll(reopened, to: directory)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
        precondition(files.count == reopened.snapshots.count)
        for (index, file) in files.enumerated() {
            let png = NSBitmapImageRep(data: try Data(contentsOf: file))!
            let resolution = reopened.snapshots[index].configuration.resolution
            let category = reopened.snapshots[index].configuration.family == .iPhone
                ? "iPhone with Face ID (large display)" : resolution.id
            precondition(file.lastPathComponent == "\(index + 1)-\(reopened.snapshots[index].configuration.family.label)-\(category).png",
                         "Batch filenames must include the stable index, device type, and matching output variant.")
            precondition(png.pixelsWide == resolution.width && png.pixelsHigh == resolution.height && !png.hasAlpha)
            let single = try SnapshotImageExporter.imageData(for: reopened.snapshots[index], frameImages: reopened.frames[reopened.snapshots[index].configuration.frameID])
            let batchData = try Data(contentsOf: file)
            precondition(batchData == single, "Single and batch export must use the same composition.")
        }
        let secondFolder = try await SnapshotImageExporter.exportAll(portableCopy, to: directory)
        precondition(secondFolder != folder && FileManager.default.fileExists(atPath: files[0].path))
        var deleted = reopened
        deleted.snapshots.removeAll { $0.configuration.family == .iPad }
        let savedFrames = try deleted.package().fileWrappers!["Frames"]!.fileWrappers!
        let usedFrames = Set(deleted.snapshots.map(\.configuration.frameID) + [deleted.draft.configuration.frameID])
        precondition(Set(savedFrames.keys) == usedFrames, "Only frames used by snapshots or the draft should remain.")
        
        let missingScreenshot = try reopened.package()
        missingScreenshot.fileWrappers!["Screenshots"]!.removeFileWrapper(missingScreenshot.fileWrappers!["Screenshots"]!.fileWrappers!.values.first!)
        expectInvalid(missingScreenshot)
        let missingMask = try reopened.package()
        let frame = missingMask.fileWrappers!["Frames"]!.fileWrappers!.values.first!
        frame.removeFileWrapper(frame.fileWrappers!["mask.png"]!)
        expectInvalid(missingMask)
        let unsupported = try reopened.package()
        var manifest = try JSONSerialization.jsonObject(with: unsupported.fileWrappers!["manifest.json"]!.regularFileContents!) as! [String: Any]
        manifest["version"] = 99
        unsupported.removeFileWrapper(unsupported.fileWrappers!["manifest.json"]!)
        let newManifest = FileWrapper(regularFileWithContents: try JSONSerialization.data(withJSONObject: manifest))
        newManifest.preferredFilename = "manifest.json"
        unsupported.addFileWrapper(newManifest)
        expectInvalid(unsupported)
        try await validateFramePreviewQuality(source: source)
        try validateWatchMaskResolutions()
        try await validateRenderingPerformance(source: source, directory: directory)
        try await validateGroups(source: source, directory: directory)
        try validateWatchDocument(source: source, directory: directory)
        try await validateVariants(source: source, directory: directory)
        try await validateWatchVariants(source: source, directory: directory)
        print("Validated paired Watch screenshots/frames/clocks and legacy migration, persisted image/Device Hub drafts, draft-only packages, missing-device fallback, legacy migration, empty documents, on-disk .sshub round trips, snapshot ordering, Unicode highlights and colors, immutable captured screens, editable frames, portable embedded assets, single/batch PNG parity, collision-free export folders, unused-frame cleanup, and corrupt/unsupported package rejection.")
    }
    
    @MainActor
    static func validateFramePreviewQuality(source: Data) async throws {
        for frameID in ["DeviceFrame15", "DeviceFrame20"] {
            var document = ScreenshotHubDocument()
            var configuration = ScreenshotConfiguration()
            configuration.frameID = frameID
            configuration.showsShadow = false
            configuration.usesSourceScreenCutouts = true
            try document.storeFrame(for: &configuration)
            let frame = configuration.frame!
            let images = document.frames[frameID]!
            let bezel = ScreenshotRenderer.image(for: images.bezel)!
            let original = NSBitmapImageRep(data: images.bezel)!.cgImage!
            let thumbnailContext = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 83, pixelsHigh: 180,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32
            )!
            let context = NSGraphicsContext(bitmapImageRep: thumbnailContext)!.cgContext
            context.scaleBy(x: 180 / configuration.resolution.size.height, y: 180 / configuration.resolution.size.height)
            let graphics = NSGraphicsContext(cgContext: context, flipped: true)
            for _ in 0..<3 {
                _ = bezel.cgImage(forProposedRect: nil, context: graphics, hints: nil)
                let native = try DeviceFrameImages.nativeCGImage(for: bezel)
                precondition(native.width == original.width && native.height == original.height,
                             "Cached frame extraction must retain native pixels after thumbnail rendering.")
            }
            let reference = ScreenshotPreviewRequest(
                configuration: configuration, screenshotData: source,
                frameImages: images, maximumDimension: 1800
            )
            let referencePreview = try await ScreenshotPreviewRenderer.shared.render(reference)
            let referenceSnapshot = ScreenshotSnapshot(name: "Reference", configuration: configuration,
                                                       screenshotData: source, sourceName: "Phone")
            let referenceExport = try SnapshotImageExporter.imageData(for: referenceSnapshot, frameImages: images)
            var record = try JSONSerialization.jsonObject(with: JSONEncoder().encode(frame)) as! [String: Any]
            record["id"] = "Preview-quality-\(frameID)"
            let isolatedFrame = try JSONDecoder().decode(DeviceFrame.self, from: JSONSerialization.data(withJSONObject: record))
            var request = reference
            request.configuration.frameID = isolatedFrame.id
            request.configuration.storedFrame = isolatedFrame
            for dimension: CGFloat in [180, 650, 1100, 1800] {
                request.maximumDimension = dimension
                let preview = try await ScreenshotPreviewRenderer.shared.render(request)
                if dimension == 1800 {
                    precondition(preview.image.dataProvider!.data! as Data == referencePreview.image.dataProvider!.data! as Data,
                                 "Retina preview pixels must not depend on whether a thumbnail was rendered first.")
                }
            }
            var snapshot = referenceSnapshot
            snapshot.configuration = request.configuration
            let export = try SnapshotImageExporter.imageData(for: snapshot, frameImages: images)
            precondition(export == referenceExport, "Thumbnail rendering must not reduce exported frame quality.")
        }
        print("Validated native iPhone frame extraction and identical Retina preview/export pixels after thumbnail and smaller-preview rendering.")
    }
    
    @MainActor
    static func validateWatchMaskResolutions() throws {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 300, pixelsHigh: 650,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32
        )!
        let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
        let frames = DeviceFrame.all.filter { $0.family == .appleWatch }
        for frame in frames {
            let images = try DeviceFrameImages.load(frameID: frame.id)
            let original = NSBitmapImageRep(data: images.mask)!.cgImage!
            var configuration = ScreenshotConfiguration()
            configuration.watch.isEnabled = true
            configuration.watch.frameID = frame.id
            configuration.watch.storedFrame = frame
            for scale: CGFloat in [1, 0.5, 0.125] {
                let width = Int(CGFloat(original.width) * scale)
                let height = Int(CGFloat(original.height) * scale)
                let context = CGContext(
                    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )!
                context.draw(original, in: .init(x: 0, y: 0, width: width, height: height))
                let reduced = context.makeImage()!
                let data = NSBitmapImageRep(cgImage: reduced).representation(using: .png, properties: [:])!
                let screen = frame.screenRect.insetBy(dx: -2, dy: -2)
                if scale == 0.125 {
                    precondition(reduced.cropping(to: screen) == nil,
                                 "The reduced-resolution fixture must exercise the previously crashing crop.")
                }
                let mask = try ScreenshotRenderer.watchScreenMask(
                    configuration: configuration,
                    frameImages: .init(bezel: images.bezel, mask: data),
                    graphics: graphics
                )
                let expected = CGRect(
                    x: screen.minX * CGFloat(width) / frame.width,
                    y: screen.minY * CGFloat(height) / frame.height,
                    width: screen.width * CGFloat(width) / frame.width,
                    height: screen.height * CGFloat(height) / frame.height
                ).integral
                precondition(mask.width == Int(expected.width) && mask.height == Int(expected.height),
                             "Watch mask cropping must convert frame coordinates to bitmap pixels for \(frame.id).")
                let pixels = NSBitmapImageRep(cgImage: mask)
                precondition(pixels.colorAt(x: mask.width / 2, y: mask.height / 2)!.alphaComponent > 0.99,
                             "The cropped mask must retain the center of the Watch screen.")
            }
            var record = try JSONSerialization.jsonObject(with: JSONEncoder().encode(frame)) as! [String: Any]
            record["screenX"] = frame.width * 2
            configuration.watch.storedFrame = try JSONDecoder().decode(DeviceFrame.self, from: JSONSerialization.data(withJSONObject: record))
            do {
                _ = try ScreenshotRenderer.watchScreenMask(configuration: configuration, frameImages: images, graphics: graphics)
                preconditionFailure("An out-of-bounds Watch screen must report an error instead of crashing.")
            } catch is ScreenshotRenderer.RenderError {}
        }
        print("Validated \(frames.count) Watch masks at native, half, and one-eighth resolution, plus invalid-crop error handling.")
    }
    
    @MainActor
    static func validateRenderingPerformance(source: Data, directory: URL) async throws {
        var document = ScreenshotHubDocument()
        var configuration = document.draft.configuration
        configuration.variantCategories = [.dynamicIslandLarge]
        configuration.watch.isEnabled = true
        configuration.exportsWatchVariant = true
        try document.storeFrame(for: &configuration)
        let snapshot = ScreenshotSnapshot(name: "Progress", configuration: configuration, screenshotData: source,
                                          sourceName: "Phone", watchScreenshotData: source)
        let request = ScreenshotPreviewRequest(
            configuration: configuration,
            screenshotData: source,
            watchScreenshotData: source,
            frameImages: document.frames[configuration.frameID],
            watchFrameImages: document.frames[configuration.watch.frameID],
            maximumDimension: 650
        )
        let clock = ContinuousClock()
        let start = clock.now
        let first = try await ScreenshotPreviewRenderer.shared.render(request)
        let coldDuration = start.duration(to: clock.now)
        let cachedStart = clock.now
        let cached = try await ScreenshotPreviewRenderer.shared.render(request)
        let cachedDuration = cachedStart.duration(to: clock.now)
        precondition(first.image === cached.image, "Repeated preview requests must reuse the rendered image.")
        var changedRequest = request
        changedRequest.configuration.title = "Updated preview"
        let changed = try await ScreenshotPreviewRenderer.shared.render(changedRequest)
        precondition(changed.image !== cached.image, "Configuration edits must invalidate the cached preview.")
        var liveRequest = request
        liveRequest.streamsPhone = true
        liveRequest.streamsWatch = true
        let live = try await ScreenshotPreviewRenderer.shared.render(liveRequest)
        precondition(live.watchOverlay != nil && live.watchScreenMask != nil,
                     "Live phone/Watch previews must keep separate overlays and an interaction mask.")
        liveRequest.streamsPhone = false
        let liveWatch = try await ScreenshotPreviewRenderer.shared.render(liveRequest)
        precondition(liveWatch.watchOverlay != nil && liveWatch.watchScreenMask != nil)
        var tabletRequest = liveRequest
        tabletRequest.configuration.selectFamily(.iPad)
        try document.storeFrame(for: &tabletRequest.configuration)
        tabletRequest.frameImages = document.frames[tabletRequest.configuration.frameID]
        tabletRequest.streamsPhone = true
        tabletRequest.streamsWatch = false
        let tablet = try await ScreenshotPreviewRenderer.shared.render(tabletRequest)
        precondition(tablet.watchOverlay == nil && tablet.watchScreenMask == nil,
                     "Switching canvas family must not leave a Watch overlay in the tablet preview.")
        let cancelledPreview = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ScreenshotPreviewRenderer.shared.render(request)
        }
        do {
            _ = try await cancelledPreview.value
            preconditionFailure("Cancelled preview requests must not render or return cached results.")
        } catch is CancellationError {}
        
        var reports: [SnapshotExportProgress] = []
        var ticks = 0
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(5))
                ticks += 1
            }
        }
        defer { heartbeat.cancel() }
        let folder = try await SnapshotImageExporter.exportSnapshots([snapshot], frames: document.frames, to: directory) {
            precondition(Thread.isMainThread, "Progress delivery must be safe for UI state updates.")
            reports.append($0)
        }
        heartbeat.cancel()
        precondition(reports.map(\.completedCount) == [0, 1, 2, 3])
        precondition(reports.allSatisfy { $0.totalCount == 3 })
        precondition(reports.last?.fractionCompleted == 1)
        precondition(ticks > 3, "Main-actor work must continue while images are rendering and encoding.")
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        precondition(Set(reports.compactMap(\.filename)) == Set(files), "Progress must include primary, phone variant, and Watch output.")
        let beforeCancellation = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
        let cancellation = Task {
            try await SnapshotImageExporter.exportSnapshots([snapshot], frames: document.frames, to: directory) { progress in
                if progress.completedCount == 1 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do {
            _ = try await cancellation.value
            preconditionFailure("Cancellation must stop the batch.")
        } catch is CancellationError {}
        let afterCancellation = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
        precondition(beforeCancellation == afterCancellation, "Cancelled exports must remove their partial folder.")
        print("Validated preview cache reuse/invalidation/cancellation, main-actor responsiveness (\(ticks) heartbeats), per-image variant progress, and cancelled-export cleanup. Cold preview: \(coldDuration); cached: \(cachedDuration).")
    }
    
    @MainActor
    static func validateGroups(source: Data, directory: URL) async throws {
        var document = ScreenshotHubDocument()
        var configuration = document.draft.configuration
        configuration.variantCategories = [.dynamicIslandLarge]
        try document.storeFrame(for: &configuration)
        document.snapshots = (1...5).map {
            .init(name: "Snapshot \($0)", configuration: configuration, screenshotData: source, sourceName: "Fixture")
        }
        let ids = document.snapshots.map(\.id)
        let firstGroup = document.createGroup(named: "GroupName")
        let secondGroup = document.createGroup(named: "中文/组")
        let emptyGroup = document.createGroup(named: "Empty")
        let duplicate = document.createGroup(named: "中文-组")
        precondition(document.groups.last!.name == "中文-组 2", "Names that export to the same filename must be disambiguated.")
        document.deleteGroup(id: duplicate)
        precondition(document.moveSnapshot(id: ids[0], to: firstGroup))
        precondition(document.moveSnapshot(id: ids[2], to: firstGroup))
        precondition(document.moveSnapshot(id: ids[4], to: secondGroup))
        precondition(document.moveSnapshot(id: ids[2], to: firstGroup, before: ids[0]))
        precondition(document.snapshots(in: firstGroup).map(\.id) == [ids[2], ids[0]])
        precondition(document.snapshots(in: nil).map(\.id) == [ids[1], ids[3]])
        precondition(document.orderedSnapshots.map(\.id) == [ids[1], ids[3], ids[2], ids[0], ids[4]])
        let beforeInvalidMove = document.snapshots
        precondition(!document.moveSnapshot(id: ids[0], to: UUID()))
        precondition(!document.moveSnapshot(id: UUID(), to: firstGroup))
        precondition(!document.moveSnapshot(id: ids[0], to: firstGroup, before: ids[1]))
        precondition(!document.moveSnapshot(id: ids[0], to: firstGroup, before: ids[0]))
        precondition(document.snapshots == beforeInvalidMove, "Stale or foreign drops must not remove or reorder snapshots.")
        var batch = document
        precondition(batch.moveSnapshots(ids: [ids[1], ids[2], ids[4]], to: emptyGroup))
        precondition(batch.snapshots(in: emptyGroup).map(\.id) == [ids[1], ids[2], ids[4]],
                     "Mixed-group selections must move as a block in visible list order.")
        precondition(batch.moveSnapshots(ids: [ids[1], ids[4]], to: firstGroup, before: ids[0]))
        precondition(batch.snapshots(in: firstGroup).map(\.id) == [ids[1], ids[4], ids[0]])
        precondition(batch.moveSnapshots(ids: [ids[1], ids[4]], to: firstGroup))
        precondition(batch.snapshots(in: firstGroup).map(\.id) == [ids[0], ids[1], ids[4]],
                     "Moving a selection within one group must preserve the block order.")
        let unchanged = batch.snapshots
        precondition(!batch.moveSnapshots(ids: [ids[1], UUID()], to: secondGroup))
        precondition(!batch.moveSnapshots(ids: [ids[1], ids[4]], to: firstGroup, before: ids[4]))
        precondition(!batch.moveSnapshots(ids: [], to: nil))
        precondition(!batch.moveSnapshots(ids: [ids[1], ids[4]], to: UUID()))
        precondition(batch.snapshots == unchanged, "Invalid multi-item drops must be atomic.")
        precondition(batch.moveSnapshots(ids: [ids[1], ids[2], ids[4]], to: nil, before: ids[3]))
        precondition(batch.snapshots(in: nil).map(\.id) == [ids[1], ids[4], ids[2], ids[3]])
        precondition(batch.snapshots.count == 5 && Set(batch.snapshots.map(\.id)).count == 5)
        let batchCopy = try ScreenshotHubDocument(package: batch.package())
        precondition(batchCopy.snapshots == batch.snapshots && batchCopy.groups == batch.groups)
        precondition(batchCopy.snapshots.allSatisfy { $0.screenshotData == source })
        let url = directory.appendingPathComponent("Groups.sshub", isDirectory: true)
        try document.package().write(to: url, options: .atomic, originalContentsURL: nil)
        let restored = try ScreenshotHubDocument(package: readPackage(at: url))
        precondition(restored.groups == document.groups && restored.snapshots == document.snapshots)
        precondition(restored.groups.contains { $0.id == emptyGroup }, "Empty groups must survive saving.")
        let expected = [
            "1-iPhone-iPhone with Face ID (large display).png",
            "2-iPhone-iPhone with Face ID (large display).png",
            "GroupName-1-iPhone-iPhone with Face ID (large display).png",
            "GroupName-2-iPhone-iPhone with Face ID (large display).png",
            "中文-组-1-iPhone-iPhone with Face ID (large display).png"
        ]
        let expectedVariants = expected.map { $0.replacingOccurrences(of: "Face ID", with: "Dynamic Island") }
        let folder = try await SnapshotImageExporter.exportAll(restored, to: directory)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        precondition(Set(names) == Set(expected + expectedVariants), "Every group and Root must number independently without overwrites.")
        let selected = restored.snapshots.first { $0.id == ids[0] }!
        precondition(SnapshotImageExporter.filename(for: selected, in: restored) + ".png" == expected[3])
        let selectedFolder = try await SnapshotImageExporter.exportSnapshots(
            [selected], frames: restored.frames, groups: restored.groups, orderedSnapshots: restored.snapshots, to: directory
        )
        let selectedNames = try FileManager.default.contentsOfDirectory(atPath: selectedFolder.path)
        precondition(Set(selectedNames) == Set([expected[3], expectedVariants[3]]),
                     "Selected export must retain the snapshot's group and index from the full document.")
        let multiple = restored.orderedSnapshots.filter { [ids[0], ids[3]].contains($0.id) }
        let multipleFolder = try await SnapshotImageExporter.exportSnapshots(
            multiple, frames: restored.frames, groups: restored.groups, orderedSnapshots: restored.snapshots, to: directory
        )
        let multipleNames = try FileManager.default.contentsOfDirectory(atPath: multipleFolder.path)
        precondition(Set(multipleNames) == Set([expected[1], expected[3], expectedVariants[1], expectedVariants[3]]),
                     "Multi-selection export must keep each group's original indices and all enabled variants.")
        precondition(SnapshotImageExporter.filename(for: selected, index: 2, groupName: "GroupName", isWatchVariant: true)
                     == "GroupName-2-iPhone-Apple Watch")
        var edited = restored
        edited.renameGroup(id: firstGroup, to: "Renamed")
        precondition(edited.groups.first!.name == "Renamed")
        precondition(edited.snapshots(in: firstGroup).map(\.id) == [ids[2], ids[0]])
        precondition(edited.moveSnapshot(id: ids[2], to: nil, before: ids[3]))
        precondition(edited.snapshots(in: nil).map(\.id) == [ids[1], ids[2], ids[3]])
        edited.deleteGroup(id: firstGroup)
        precondition(edited.snapshots.count == 5 && !edited.groups.contains { $0.id == firstGroup })
        precondition(edited.snapshots(in: nil).contains { $0.id == ids[0] })
        precondition(edited.snapshots.allSatisfy { $0.screenshotData == source }, "Grouping must preserve captured images.")
        let copy = try ScreenshotHubDocument(package: edited.package())
        precondition(copy.groups == edited.groups && copy.snapshots == edited.snapshots)
        var legacy = document
        legacy.groups = []
        for index in legacy.snapshots.indices { legacy.snapshots[index].groupID = nil }
        for version in 1...3 {
            let package = try legacy.package()
            var manifest = try JSONSerialization.jsonObject(with: package.fileWrappers!["manifest.json"]!.regularFileContents!) as! [String: Any]
            manifest["version"] = version
            manifest.removeValue(forKey: "groups")
            try replaceManifest(in: package, with: manifest)
            let migrated = try ScreenshotHubDocument(package: package)
            precondition(migrated.groups.isEmpty && migrated.snapshots.allSatisfy { $0.groupID == nil })
        }
        for malformed in ["missing", "duplicate", "collision"] {
            let package = try document.package()
            var manifest = try JSONSerialization.jsonObject(with: package.fileWrappers!["manifest.json"]!.regularFileContents!) as! [String: Any]
            var groups = manifest["groups"] as! [[String: Any]]
            if malformed == "missing" { groups.removeFirst() }
            else if malformed == "duplicate" { groups.append(groups[0]) }
            else { groups[1]["name"] = "GroupName" }
            manifest["groups"] = groups
            try replaceManifest(in: package, with: manifest)
            expectInvalid(package)
        }
        print("Validated group creation, safe names, single/multi-item cross-group drops, atomic invalid drops, stable block ordering, multi-selection export, Root moves, deletion without image loss, empty groups, disk persistence, three legacy formats, corrupt references, per-group export numbering, all variants, and stable selected export names.")
    }
    
    @MainActor
    static func validateWatchVariants(source: Data, directory: URL) async throws {
        let sizes = WatchConfiguration.screenshotResolutions
        precondition(sizes.map(\.id) == ["422x514", "410x502", "416x496", "396x484", "368x448", "312x390"])
        for resolution in sizes {
            precondition(WatchConfiguration.closestScreenshotResolution(to: resolution) == resolution)
        }
        for (source, expected) in [
            (ScreenshotResolution(width: 374, height: 446), ScreenshotResolution(width: 368, height: 448)),
            (.init(width: 384, height: 480), .init(width: 396, height: 484)),
            (.init(width: 450, height: 550), .init(width: 422, height: 514))
        ] {
            precondition(WatchConfiguration.closestScreenshotResolution(to: source) == expected)
        }
        var configuration = ScreenshotConfiguration()
        configuration.exportsWatchVariant = true
        precondition(!configuration.hasWatchVariant && configuration.variantCount == 0)
        configuration.watch.isEnabled = true
        precondition(configuration.hasWatchVariant && configuration.variantCount == 1)
        configuration.family = .iPad
        precondition(!configuration.hasWatchVariant)
        configuration.selectFamily(.iPhone)
        precondition(!configuration.exportsWatchVariant)
        configuration.exportsWatchVariant = true
        
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/WatchClock/Centered-watchOS.png")
        let originalData = try Data(contentsOf: fixture)
        let original = NSBitmapImageRep(data: originalData)!
        for resolution in sizes {
            let input = try SnapshotImageExporter.variantImageData(from: original, resolution: resolution, backgroundColor: .black)
            let snapshot = ScreenshotSnapshot(name: "Raw Watch", configuration: configuration, screenshotData: source,
                                               sourceName: "Phone", watchScreenshotData: input)
            let output = try SnapshotImageExporter.watchImageData(for: snapshot)
            precondition(output == input, "Exact supported dimensions with the clock disabled must preserve the original PNG bytes.")
        }
        var snapshot = ScreenshotSnapshot(name: "Watch/原图", configuration: configuration, screenshotData: source,
                                          sourceName: "Phone", watchScreenshotData: originalData)
        let resizedData = try SnapshotImageExporter.watchImageData(for: snapshot)
        let resized = NSBitmapImageRep(data: resizedData)!
        precondition(resized.pixelsWide == 368 && resized.pixelsHigh == 448 && !resized.hasAlpha)
        let reference = try SnapshotImageExporter.variantImageData(
            from: original, resolution: .init(width: 368, height: 448), backgroundColor: .black
        )
        precondition(resizedData == reference, "Unsupported screen sizes must scale the raw screen, without a bezel or phone canvas.")
        
        let exactInput = try SnapshotImageExporter.variantImageData(
            from: original, resolution: .init(width: 416, height: 496), backgroundColor: .black
        )
        snapshot.watchScreenshotData = exactInput
        snapshot.configuration.watch.clock.isEnabled = true
        snapshot.configuration.watch.clock.time = "9:41"
        let inputBitmap = NSBitmapImageRep(data: exactInput)!
        let inputImage = inputBitmap.cgImage!
        guard let layout = WatchClockRenderer.analyze(inputImage),
              let patch = try WatchClockRenderer.patch(
                configuration: snapshot.configuration.watch.clock,
                sourceSize: .init(width: 416, height: 496), source: inputImage, layout: layout
              ) else { preconditionFailure("The real watchOS fixture must retain its recognizable clock.") }
        let clockData = try SnapshotImageExporter.watchImageData(for: snapshot)
        let clockBitmap = NSBitmapImageRep(data: clockData)!
        precondition(clockBitmap.pixelsWide == 416 && clockBitmap.pixelsHigh == 496)
        var changes = CGRect.null
        for y in 0..<496 {
            for x in 0..<416 {
                let before = inputBitmap.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
                let after = clockBitmap.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
                if abs(before.redComponent - after.redComponent) > 0.02
                    || abs(before.greenComponent - after.greenComponent) > 0.02
                    || abs(before.blueComponent - after.blueComponent) > 0.02 {
                    changes = changes.union(.init(x: x, y: y, width: 1, height: 1))
                }
            }
        }
        precondition(!changes.isNull && changes.width > 10 && changes.height > 5,
                     "Standalone export must include the configured replacement time.")
        precondition(patch.rect(in: .init(x: 0, y: 0, width: 416, height: 496)).insetBy(dx: -1, dy: -1).contains(changes),
                     "Only the clock region may change; the raw screen orientation and all other pixels must remain intact.")
        snapshot.configuration.watch.scale = 0.65
        snapshot.configuration.watch.horizontalPosition = 0
        snapshot.configuration.watch.frameID = snapshot.configuration.watch.availableFrames.last!.id
        snapshot.configuration.title = "This must not appear in the Watch variant"
        let changedLayoutData = try SnapshotImageExporter.watchImageData(for: snapshot)
        precondition(changedLayoutData == clockData,
                     "Standalone Watch output must be independent of canvas layout, titles, and bezel selection.")
        
        var document = ScreenshotHubDocument()
        var storedConfiguration = snapshot.configuration
        try document.storeFrame(for: &storedConfiguration)
        snapshot.configuration = storedConfiguration
        document.snapshots = [snapshot]
        document.draft = .init(configuration: storedConfiguration, screenshotData: source, watchScreenshotData: exactInput)
        let restored = try ScreenshotHubDocument(package: document.package())
        precondition(restored.snapshots[0].configuration.exportsWatchVariant && restored.draft.configuration.exportsWatchVariant)
        let folder = try await SnapshotImageExporter.exportSnapshots(restored.snapshots, frames: restored.frames, to: directory)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        precondition(names.count == 2 && names.contains("1-iPhone-Apple Watch.png"),
                     "A Watch-only variant selection must export both the original phone composition and standalone Watch.")
        let exported = try Data(contentsOf: folder.appendingPathComponent("1-iPhone-Apple Watch.png"))
        precondition(exported == clockData)
        var combined = restored
        combined.snapshots[0].configuration.variantCategories = [.dynamicIslandLarge]
        let combinedFolder = try await SnapshotImageExporter.exportAll(combined, to: directory)
        let combinedNames = try FileManager.default.contentsOfDirectory(atPath: combinedFolder.path)
        precondition(combinedNames.count == 3
                     && combinedNames.contains("1-iPhone-Apple Watch.png")
                     && combinedNames.contains("1-iPhone-iPhone with Dynamic Island (large display).png"),
                     "Watch and phone resolution variants must export together without filename collisions.")
        var disabled = restored
        disabled.snapshots[0].configuration.watch.isEnabled = false
        let disabledFolder = try await SnapshotImageExporter.exportAll(disabled, to: directory)
        let disabledNames = try FileManager.default.contentsOfDirectory(atPath: disabledFolder.path)
        precondition(disabledNames.count == 1, "Removing the Watch must suppress its variant even if its stored preference remains enabled.")
        var missing = restored
        missing.snapshots[0].watchScreenshotData = nil
        let beforeFailure = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        do {
            _ = try await SnapshotImageExporter.exportAll(missing, to: directory)
            preconditionFailure("Missing Watch data must fail export rather than create a placeholder variant.")
        } catch { }
        let afterFailure = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        precondition(Set(beforeFailure) == Set(afterFailure))
        let output = URL(fileURLWithPath: "/tmp/ScreenshotHubWatchValidation", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try clockData.write(to: output.appendingPathComponent("Watch-variant-clock.png"))
        try resizedData.write(to: output.appendingPathComponent("Watch-variant-resized.png"))
        print("Validated six standalone Watch sizes, nearest-size matching, exact PNG preservation, clock-only pixel changes, frame independence, variant persistence, selected/batch export, disabled-Watch suppression, and missing-screen cleanup.")
    }
    
    @MainActor
    static func validateVariants(source: Data, directory: URL) async throws {
        let expected: [Int: [Int]] = [
            1260: [1260, 1284, 1206, 1170],
            1290: [1290, 1284, 1206, 1170],
            1320: [1320, 1284, 1206, 1170],
            1284: [1290, 1284, 1206, 1170],
            1242: [1260, 1242, 1206, 1170],
            1179: [1260, 1242, 1179, 1170],
            1206: [1260, 1242, 1206, 1170],
            1170: [1260, 1242, 1179, 1170],
            1125: [1260, 1242, 1179, 1125],
            1080: [1260, 1242, 1179, 1080]
        ]
        precondition(DeviceFamily.iPhone.resolutions.count == 14)
        var configuration = ScreenshotConfiguration()
        configuration.variantCategories = Set(PhoneResolutionCategory.allCases)
        for resolution in DeviceFamily.iPhone.resolutions where !PhoneResolutionCategory.duo.resolutions.contains(resolution) {
            configuration.resolution = resolution
            let closest = PhoneResolutionCategory.allCases.filter { $0 != .duo }
                .map { $0.closestResolution(to: resolution).width }
            precondition(closest == expected[resolution.width], "Each category must choose its nearest pixel dimensions.")
            precondition(configuration.variantResolutions.count == 3)
            precondition(!configuration.variantResolutions.contains(resolution), "Same-category variants must never be exported.")
            let data = try JSONEncoder().encode(StoredScreenshotConfiguration(configuration))
            let copy = try JSONDecoder().decode(StoredScreenshotConfiguration.self, from: data).configuration()
            precondition(copy.resolution == resolution && copy.variantCategories == configuration.variantCategories,
                         "All ten resolutions and their variants must survive storage.")
        }
        configuration.selectResolution(.init(width: 1206, height: 2622))
        precondition(!configuration.variantCategories.contains(.dynamicIslandMedium))
        precondition(configuration.variantResolutions.map(\.width) == [1260, 1242, 1170])
        try await validateDuoVariants(source: source, directory: directory)
        configuration.selectFamily(.iPad)
        precondition(configuration.variantCategories.isEmpty && configuration.variantResolutions.isEmpty)
        configuration.variantCategories = [.dynamicIslandLarge]
        precondition(configuration.variantResolutions.isEmpty, "Variants apply only to iPhone snapshots.")
        
        var document = ScreenshotHubDocument()
        for width in [1284, 1242] {
            var configuration = ScreenshotConfiguration()
            configuration.selectResolution(DeviceFamily.iPhone.resolutions.first { $0.width == width }!)
            configuration.variantCategories = Set(configuration.availableVariantCategories)
            configuration.watch.isEnabled = width == 1284
            try document.storeFrame(for: &configuration)
            document.snapshots.append(.init(
                name: "Variants/相同名称",
                configuration: configuration,
                screenshotData: source,
                sourceName: "Phone",
                watchScreenshotData: width == 1284 ? source : nil
            ))
        }
        document.draft.configuration = document.snapshots[0].configuration
        let url = directory.appendingPathComponent("Variants.sshub", isDirectory: true)
        try document.package().write(to: url, options: .atomic, originalContentsURL: nil)
        let restored = try ScreenshotHubDocument(package: readPackage(at: url))
        precondition(restored.snapshots == document.snapshots && restored.draft == document.draft)
        let folder = try await SnapshotImageExporter.exportAll(restored, to: directory)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        precondition(names.count == 8, "Batch export must include each original and its three enabled variants.")
        let expectedCategories = [
            "iPhone with Dynamic Island (large display)", "iPhone with Face ID (large display)",
            "iPhone with Dynamic Island (medium display)", "iPhone with Face ID (medium display)"
        ]
        let expectedNames = (1...2).flatMap { index in
            expectedCategories.map { "\(index)-iPhone-\($0).png" }
        }
        precondition(Set(names) == Set(expectedNames), "Originals and variants must use distinct category-name suffixes.")
        for (index, snapshot) in restored.snapshots.enumerated() {
            let originalData = try SnapshotImageExporter.imageData(
                for: snapshot,
                frameImages: restored.frames[snapshot.configuration.frameID],
                watchFrameImages: restored.frames[snapshot.configuration.watch.frameID]
            )
            let original = NSBitmapImageRep(data: originalData)!
            for resolution in [snapshot.configuration.resolution] + snapshot.configuration.variantResolutions {
                let name = "\(SnapshotImageExporter.filename(for: snapshot, index: index + 1, resolution: resolution)).png"
                precondition(names.contains(name))
                let data = try Data(contentsOf: folder.appendingPathComponent(name))
                let bitmap = NSBitmapImageRep(data: data)!
                precondition(bitmap.pixelsWide == resolution.width && bitmap.pixelsHigh == resolution.height && !bitmap.hasAlpha)
                if resolution == snapshot.configuration.resolution {
                    precondition(data == originalData, "Enabling variants must not change the original PNG.")
                } else {
                    let scaled = try SnapshotImageExporter.variantImageData(
                        from: original,
                        resolution: resolution,
                        backgroundColor: NSColor(snapshot.configuration.backgroundColor)
                    )
                    precondition(data == scaled, "Variants must scale the captured composition, including its Watch.")
                }
            }
        }
        let selectedFolder = try await SnapshotImageExporter.exportSnapshots(
            [restored.snapshots[0]], frames: restored.frames, to: directory
        )
        let selectedFiles = try FileManager.default.contentsOfDirectory(atPath: selectedFolder.path)
        precondition(selectedFiles.count == 4,
                     "Selected-snapshot export must include only that snapshot and its enabled variants.")
        var broken = restored
        broken.snapshots[1].screenshotData = Data()
        let beforeFailure = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        do {
            _ = try await SnapshotImageExporter.exportAll(broken, to: directory)
            preconditionFailure("Invalid screenshots must fail export.")
        } catch { }
        let afterFailure = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        precondition(Set(beforeFailure) == Set(afterFailure), "Failed exports must remove partial originals and variants.")
        
        let pixels = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 100, pixelsHigh: 200,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32
        )!
        for y in 0..<200 {
            for x in 0..<100 {
                let color: NSColor = (30..<70).contains(x) && (80..<120).contains(y)
                    ? .init(calibratedRed: 1, green: 0, blue: 0, alpha: 1)
                    : (y < 100 ? .init(calibratedRed: 0, green: 1, blue: 0, alpha: 1)
                        : .init(calibratedRed: 0, green: 0, blue: 1, alpha: 1))
                pixels.setColor(color, atX: x, y: y)
            }
        }
        for resolution in [
            ScreenshotResolution(width: 200, height: 200), .init(width: 100, height: 400),
            .init(width: 100, height: 100), .init(width: 400, height: 400)
        ] {
            let data = try SnapshotImageExporter.variantImageData(from: pixels, resolution: resolution, backgroundColor: .white)
            let scaled = NSBitmapImageRep(data: data)!
            let scale = min(Double(resolution.width) / 100, Double(resolution.height) / 200)
            let left = Int((Double(resolution.width) - 100 * scale) / 2)
            let top = Int((Double(resolution.height) - 200 * scale) / 2)
            let topColor = scaled.colorAt(x: left + 10, y: top + 10)!.usingColorSpace(.sRGB)!
            let bottomColor = scaled.colorAt(x: left + 10, y: top + Int(200 * scale) - 10)!.usingColorSpace(.sRGB)!
            precondition(topColor.greenComponent > 0.95 && bottomColor.blueComponent > 0.95,
                         "Scaling must retain the complete image and its orientation.")
            var redBounds = CGRect.null
            for y in 0..<resolution.height {
                for x in 0..<resolution.width {
                    let color = scaled.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
                    if color.redComponent > 0.8 && color.greenComponent < 0.3 && color.blueComponent < 0.3 {
                        redBounds = redBounds.union(.init(x: x, y: y, width: 1, height: 1))
                    }
                }
            }
            precondition(abs(redBounds.width - redBounds.height) <= 1 && abs(redBounds.width - 40 * scale) <= 2,
                         "Variants must use the same scale on both axes.")
            precondition(redBounds.midX == Double(resolution.width) / 2 && redBounds.midY == Double(resolution.height) / 2)
            let edge = scaled.colorAt(x: 0, y: 0)!.usingColorSpace(.sRGB)!
            precondition(edge.redComponent > 0.95 && edge.greenComponent > 0.95 && edge.blueComponent > 0.95)
        }
        print("Validated fourteen grouped iPhone resolutions, Duo frame restrictions and Watch-only variants, all nearest-category choices, cross-category selection, draft/snapshot persistence, legacy defaults, original/variant export parity, selected export, paired Watch scaling, aspect preservation, orientation, background margins, and failed-export cleanup.")
    }
    
    @MainActor
    static func validateDuoVariants(source: Data, directory: URL) async throws {
        var document = ScreenshotHubDocument()
        var configuration = ScreenshotConfiguration()
        configuration.watch.isEnabled = true
        configuration.exportsWatchVariant = true
        for resolution in PhoneResolutionCategory.duo.resolutions {
            configuration.variantCategories = Set(PhoneResolutionCategory.allCases)
            configuration.selectResolution(resolution)
            precondition(configuration.resolutionCategory == .duo)
            precondition(configuration.variantCategories.isEmpty && configuration.availableVariantCategories.isEmpty)
            configuration.variantCategories = Set(PhoneResolutionCategory.allCases)
            precondition(configuration.variantResolutions.isEmpty && configuration.variantCount == 1,
                         "Duo must only export the Watch variant, including with stale phone selections.")
            let isOuter = min(resolution.width, resolution.height) == 1398
            let expectedIDs = isOuter ? ["DeviceFrame119", "DeviceFrame121"] : ["DeviceFrame118", "DeviceFrame120"]
            precondition(configuration.availableFrames.map(\.id) == expectedIDs,
                         "Both orientations must offer only the matching Duo screen and its two finishes.")
            precondition(configuration.frame.map { expectedIDs.contains($0.id) } == true,
                         "Switching screens must select a compatible frame.")
            for frame in configuration.availableFrames {
                precondition(frame.isLandscape == resolution.isLandscape)
                precondition(frame.screenWidth == resolution.size.width && frame.screenHeight == resolution.size.height)
                configuration.frameID = frame.id
                let data = try JSONEncoder().encode(StoredScreenshotConfiguration(configuration))
                let copy = try JSONDecoder().decode(StoredScreenshotConfiguration.self, from: data).configuration()
                precondition(copy.resolution == resolution && copy.frame == frame && copy.hasWatchVariant)
                precondition(copy.availableVariantCategories.isEmpty && copy.variantResolutions.isEmpty)
                var legacy = try StoredScreenshotConfiguration(configuration)
                legacy.frame = frame.oriented(isLandscape: false)
                let migrated = try legacy.configuration()
                precondition(migrated.frame == frame, "Older Duo documents must derive the correct frame orientation.")
            }
            var incompatible = try StoredScreenshotConfiguration(configuration)
            incompatible.frame = DeviceFrame.all.first { $0.id == (isOuter ? "DeviceFrame118" : "DeviceFrame119") }!
            incompatible.frameID = incompatible.frame.id
            do {
                _ = try incompatible.configuration()
                preconditionFailure("Stored Duo configurations must reject the wrong screen frame.")
            } catch let error as CocoaError {
                precondition(error.code == .fileReadCorruptFile)
            }
            try document.storeFrame(for: &configuration)
            document.snapshots.append(.init(
                name: "Duo \(resolution.id)",
                configuration: configuration,
                screenshotData: source,
                sourceName: "Duo",
                watchScreenshotData: source
            ))
            configuration.watch.isEnabled = false
            precondition(configuration.variantCount == 0)
            configuration.watch.isEnabled = true
        }
        configuration.selectResolution(PhoneResolutionCategory.faceIDLarge.resolutions[0])
        precondition(configuration.availableVariantCategories.count == 3)
        precondition(!configuration.availableVariantCategories.contains(.duo), "Duo must not become a phone export variant.")
        let restored = try ScreenshotHubDocument(package: document.package())
        let folder = try await SnapshotImageExporter.exportAll(restored, to: directory)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        precondition(names.count == 8, "Each Duo snapshot must export its primary image and only the Watch variant.")
        for (index, snapshot) in restored.snapshots.enumerated() {
            let name = "\(index + 1)-iPhone-iPhone Duo.png"
            let data = try Data(contentsOf: folder.appendingPathComponent(name))
            let bitmap = NSBitmapImageRep(data: data)!
            precondition(bitmap.pixelsWide == snapshot.configuration.resolution.width
                         && bitmap.pixelsHigh == snapshot.configuration.resolution.height)
            let watchName = "\(index + 1)-iPhone-Apple Watch.png"
            let watchData = try Data(contentsOf: folder.appendingPathComponent(watchName))
            let expectedWatchData = try SnapshotImageExporter.watchImageData(for: snapshot)
            precondition(watchData == expectedWatchData)
        }
        print("Validated all four Duo resolutions, inner/outer frame filtering, both finishes, persistence, stale variant suppression, and primary/Watch batch exports.")
    }
    
    @MainActor
    static func validateWatchDocument(source: Data, directory: URL) throws {
        var document = ScreenshotHubDocument()
        var legacyWatch = try JSONSerialization.jsonObject(with: JSONEncoder().encode(document.draft.configuration.watch)) as! [String: Any]
        legacyWatch.removeValue(forKey: "horizontalPosition")
        legacyWatch["offsetX"] = -0.02
        legacyWatch["offsetY"] = -0.1
        legacyWatch["scale"] = 0.22
        legacyWatch["clock"] = ["isEnabled": true, "time": "10:09", "x": 0.6, "y": 0.1, "fontScale": 0.09]
        let migratedWatch = try JSONDecoder().decode(WatchConfiguration.self, from: JSONSerialization.data(withJSONObject: legacyWatch))
        precondition(migratedWatch.isValid && migratedWatch.clock.time == "10:09")
        precondition(migratedWatch.scale == WatchConfiguration.scaleRange.lowerBound)
        let encodedClock = try JSONSerialization.jsonObject(with: JSONEncoder().encode(migratedWatch.clock)) as! [String: Any]
        precondition(Set(encodedClock.keys) == ["isEnabled", "time"])
        var configuration = document.draft.configuration
        configuration.watch.isEnabled = true
        configuration.watch.clock.isEnabled = true
        configuration.watch.clock.time = "10:08"
        configuration.watch.horizontalPosition = 0.4
        try document.storeFrame(for: &configuration)
        document.draft = .init(configuration: configuration, screenshotData: source, sourceName: "Phone.png",
                               source: .simulator, simulatorID: "PHONE", watchScreenshotData: source,
                               watchSourceName: "Watch.png", watchSource: .simulator, watchSimulatorID: "WATCH")
        document.snapshots = [.init(name: "Phone and Watch", configuration: configuration,
                                    screenshotData: source, sourceName: "Phone",
                                    watchScreenshotData: source, watchSourceName: "Watch")]
        let url = directory.appendingPathComponent("PhoneAndWatch.sshub", isDirectory: true)
        try document.package().write(to: url, options: .atomic, originalContentsURL: nil)
        let restored = try ScreenshotHubDocument(package: readPackage(at: url))
        precondition(restored.draft == document.draft && restored.snapshots == document.snapshots)
        precondition(restored.frames.count == 2 && restored.frames[configuration.watch.frameID] != nil)
        var stoppedWatch = restored.draft
        stoppedWatch.restoreWatchSource(runningSimulatorIDs: ["ANOTHER-WATCH"])
        precondition(stoppedWatch.watchSource == .file && stoppedWatch.watchSimulatorID == nil)
        precondition(stoppedWatch.source == .simulator && stoppedWatch.simulatorID == "PHONE")
        precondition(stoppedWatch.watchScreenshotData == source)
        var runningWatch = restored.draft
        runningWatch.restoreWatchSource(runningSimulatorIDs: ["WATCH"])
        precondition(runningWatch == restored.draft)
        let missingWatch = try document.package()
        let screenshots = missingWatch.fileWrappers!["Screenshots"]!
        screenshots.removeFileWrapper(screenshots.fileWrappers!["Draft-Watch.png"]!)
        expectInvalid(missingWatch)
        let missingBezel = try document.package()
        let frames = missingBezel.fileWrappers!["Frames"]!
        frames.removeFileWrapper(frames.fileWrappers![configuration.watch.frameID]!)
        expectInvalid(missingBezel)
        var edited = restored
        edited.snapshots[0].configuration.watch.clock.time = "9:41"
        let copy = try ScreenshotHubDocument(package: edited.package())
        precondition(copy.snapshots[0].watchScreenshotData == source)
        precondition(copy.snapshots[0].configuration.watch.clock.time == "9:41")
        let png = try SnapshotImageExporter.imageData(for: copy.snapshots[0], frameImages: copy.frames[configuration.frameID],
                                                     watchFrameImages: copy.frames[configuration.watch.frameID])
        let bitmap = NSBitmapImageRep(data: png)!
        precondition(bitmap.pixelsWide == 1284 && bitmap.pixelsHigh == 2778 && !bitmap.hasAlpha)
        let oldPackage = try ScreenshotHubDocument().package()
        var manifest = try JSONSerialization.jsonObject(with: oldPackage.fileWrappers!["manifest.json"]!.regularFileContents!) as! [String: Any]
        manifest["version"] = 2
        var draft = manifest["draft"] as! [String: Any]
        var oldConfiguration = draft["configuration"] as! [String: Any]
        oldConfiguration.removeValue(forKey: "watch")
        draft["configuration"] = oldConfiguration
        for key in ["hasWatchScreenshot", "watchSourceName", "watchSource", "watchSimulatorID"] { draft.removeValue(forKey: key) }
        manifest["draft"] = draft
        try replaceManifest(in: oldPackage, with: manifest)
        let oldDocument = try ScreenshotHubDocument(package: oldPackage)
        precondition(!oldDocument.draft.configuration.watch.isEnabled && oldDocument.draft.watchSource == .file)
    }
    
    static func replaceManifest(in package: FileWrapper, with manifest: [String: Any]) throws {
        package.removeFileWrapper(package.fileWrappers!["manifest.json"]!)
        let wrapper = FileWrapper(regularFileWithContents: try JSONSerialization.data(withJSONObject: manifest))
        wrapper.preferredFilename = "manifest.json"
        package.addFileWrapper(wrapper)
    }
    
    static func readPackage(at url: URL) throws -> FileWrapper {
        // FileWrapper's URL initializer requires Launch Services, unavailable in the test sandbox.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        if !isDirectory.boolValue { return try .init(regularFileWithContents: Data(contentsOf: url)) }
        let children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
        var wrappers: [String: FileWrapper] = [:]
        for child in children { wrappers[child.lastPathComponent] = try readPackage(at: child) }
        return .init(directoryWithFileWrappers: wrappers)
    }
    
    static func expectInvalid(_ package: FileWrapper) {
        do {
            _ = try ScreenshotHubDocument(package: package)
            preconditionFailure("Invalid packages must fail to open.")
        } catch { }
    }
}
