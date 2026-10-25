import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let screenshotHub = UTType(exportedAs: "com.memz233.screenshothub.document", conformingTo: .package)
}

nonisolated struct ScreenshotGroup: Codable, Equatable, Identifiable, Sendable {
    static func filenameComponent(_ name: String) -> String {
        let component = name.components(separatedBy: .init(charactersIn: "/\\:\n\r\t"))
            .joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return String(component.prefix(80))
    }
    
    var id = UUID()
    var name: String
}

nonisolated struct ScreenshotSnapshot: Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    var configuration: ScreenshotConfiguration
    var screenshotData: Data
    var sourceName: String
    var watchScreenshotData: Data?
    var watchSourceName = ""
    var groupID: UUID?
}

struct ScreenshotHubDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.screenshotHub] }
    
    var draft = ScreenshotDraft()
    var snapshots: [ScreenshotSnapshot] = []
    var groups: [ScreenshotGroup] = []
    var frames: [String: DeviceFrameImages] = [:]
    
    init() {
        var configuration = draft.configuration
        try? storeFrame(for: &configuration)
        draft.configuration = configuration
    }
    
    init(configuration: ReadConfiguration) throws {
        try self.init(package: configuration.file)
    }
    
    init(package: FileWrapper) throws {
        guard package.isDirectory,
              let files = package.fileWrappers,
              let manifestData = files["manifest.json"]?.regularFileContents,
              let screenshots = files["Screenshots"]?.fileWrappers,
              let storedFrames = files["Frames"]?.fileWrappers else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
        guard (1...4).contains(manifest.version) else { throw DocumentError.unsupportedVersion }
        guard Set(manifest.snapshots.map(\.id)).count == manifest.snapshots.count else {
            throw CocoaError(.fileReadCorruptFile)
        }
        groups = manifest.groups ?? []
        let groupIDs = Set(groups.map(\.id))
        guard groupIDs.count == groups.count,
              Set(groups.map { ScreenshotGroup.filenameComponent($0.name).lowercased() }).count == groups.count,
              groups.allSatisfy({ !ScreenshotGroup.filenameComponent($0.name).isEmpty }),
              manifest.snapshots.allSatisfy({ $0.groupID.map(groupIDs.contains) ?? true }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        for record in manifest.snapshots {
            let configuration = try record.configuration.configuration()
            let frameID = configuration.frameID
            guard let image = screenshots["\(record.id.uuidString).png"]?.regularFileContents,
                  NSBitmapImageRep(data: image) != nil else {
                throw CocoaError(.fileReadCorruptFile)
            }
            frames[frameID] = try Self.readFrame(for: configuration.frame!, from: storedFrames)
            if configuration.watch.needsEmbeddedFrame, let frame = configuration.watch.frame {
                frames[frame.id] = try Self.readFrame(for: frame, from: storedFrames)
            }
            let watchImage = try Self.readWatchScreenshot(hasScreenshot: record.hasWatchScreenshot,
                                                        filename: "\(record.id.uuidString)-Watch.png", from: screenshots)
            snapshots.append(.init(
                id: record.id,
                name: record.name,
                configuration: configuration,
                screenshotData: image,
                sourceName: record.sourceName,
                watchScreenshotData: watchImage,
                watchSourceName: record.watchSourceName ?? "",
                groupID: record.groupID
            ))
        }
        if let record = manifest.draft {
            draft.configuration = try record.configuration.configuration()
            draft.source = record.source
            draft.sourceName = record.sourceName
            draft.simulatorID = record.simulatorID
            draft.watchSource = record.watchSource ?? .file
            draft.watchSimulatorID = record.watchSimulatorID
            draft.watchSourceName = record.watchSourceName ?? ""
            draft.watchScreenshotData = try Self.readWatchScreenshot(hasScreenshot: record.hasWatchScreenshot,
                                                                     filename: "Draft-Watch.png", from: screenshots)
            if record.hasScreenshot {
                guard let image = screenshots["Draft.png"]?.regularFileContents,
                      NSBitmapImageRep(data: image) != nil else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                draft.screenshotData = image
            }
            frames[draft.configuration.frameID] = try Self.readFrame(for: draft.configuration.frame!, from: storedFrames)
            if draft.configuration.watch.needsEmbeddedFrame, let frame = draft.configuration.watch.frame {
                frames[frame.id] = try Self.readFrame(for: frame, from: storedFrames)
            }
        } else {
            guard manifest.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
            var configuration = draft.configuration
            try storeFrame(for: &configuration)
            draft.configuration = configuration
        }
    }
    
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        try package()
    }
    
    func package() throws -> FileWrapper {
        let records = try snapshots.map {
            try Manifest.Record(id: $0.id, name: $0.name,
                                configuration: .init($0.configuration), sourceName: $0.sourceName,
                                hasWatchScreenshot: $0.watchScreenshotData != nil, watchSourceName: $0.watchSourceName, groupID: $0.groupID)
        }
        let manifest = try Manifest(version: 4, snapshots: records, groups: groups, draft: .init(
            configuration: .init(draft.configuration),
            sourceName: draft.sourceName,
            source: draft.source,
            simulatorID: draft.simulatorID,
            hasScreenshot: draft.screenshotData != nil,
            hasWatchScreenshot: draft.watchScreenshotData != nil,
            watchSourceName: draft.watchSourceName,
            watchSource: draft.watchSource,
            watchSimulatorID: draft.watchSimulatorID
        ))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var screenshots = snapshots.reduce(into: [String: FileWrapper]()) {
            $0["\($1.id.uuidString).png"] = .init(regularFileWithContents: $1.screenshotData)
            if let data = $1.watchScreenshotData {
                $0["\($1.id.uuidString)-Watch.png"] = .init(regularFileWithContents: data)
            }
        }
        if let data = draft.screenshotData {
            screenshots["Draft.png"] = .init(regularFileWithContents: data)
        }
        if let data = draft.watchScreenshotData {
            screenshots["Draft-Watch.png"] = .init(regularFileWithContents: data)
        }
        let configurations = snapshots.map(\.configuration) + [draft.configuration]
        var frameIDs = Set(configurations.map(\.frameID))
        for configuration in configurations where configuration.watch.needsEmbeddedFrame {
            frameIDs.insert(configuration.watch.frameID)
        }
        var frameFiles: [String: FileWrapper] = [:]
        for id in frameIDs {
            guard let images = frames[id] else { throw ScreenshotRenderer.RenderError.missingFrame }
            frameFiles[id] = .init(directoryWithFileWrappers: [
                "bezel.png": .init(regularFileWithContents: images.bezel),
                "mask.png": .init(regularFileWithContents: images.mask)
            ])
        }
        return try .init(directoryWithFileWrappers: [
            "manifest.json": .init(regularFileWithContents: encoder.encode(manifest)),
            "Screenshots": .init(directoryWithFileWrappers: screenshots),
            "Frames": .init(directoryWithFileWrappers: frameFiles)
        ])
    }
    
    var orderedSnapshots: [ScreenshotSnapshot] {
        snapshots(in: nil) + groups.flatMap { snapshots(in: $0.id) }
    }
    
    func snapshots(in groupID: UUID?) -> [ScreenshotSnapshot] {
        snapshots.filter { $0.groupID == groupID }
    }
    
    func index(of snapshot: ScreenshotSnapshot) -> Int {
        (snapshots(in: snapshot.groupID).firstIndex { $0.id == snapshot.id } ?? 0) + 1
    }
    
    @discardableResult
    mutating func createGroup(named name: String = "Group") -> UUID {
        let group = ScreenshotGroup(name: availableGroupName(name))
        groups.append(group)
        return group.id
    }
    
    mutating func renameGroup(id: UUID, to name: String) {
        guard let index = groups.firstIndex(where: { $0.id == id }),
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        groups[index].name = availableGroupName(name, excluding: id)
    }
    
    mutating func deleteGroup(id: UUID) {
        groups.removeAll { $0.id == id }
        for index in snapshots.indices where snapshots[index].groupID == id {
            snapshots[index].groupID = nil
        }
    }
    
    @discardableResult
    mutating func moveSnapshot(id: UUID, to groupID: UUID?, before targetID: UUID? = nil) -> Bool {
        moveSnapshots(ids: [id], to: groupID, before: targetID)
    }
    
    @discardableResult
    mutating func moveSnapshots(ids: Set<UUID>, to groupID: UUID?, before targetID: UUID? = nil) -> Bool {
        guard !ids.isEmpty,
              groupID == nil || groups.contains(where: { $0.id == groupID }),
              ids.isSubset(of: Set(snapshots.map(\.id))) else { return false }
        if let targetID {
            guard !ids.contains(targetID),
                  snapshots.contains(where: { $0.id == targetID && $0.groupID == groupID }) else { return false }
        }
        let moving = orderedSnapshots.filter { ids.contains($0.id) }.map { snapshot in
            var snapshot = snapshot
            snapshot.groupID = groupID
            return snapshot
        }
        snapshots.removeAll { ids.contains($0.id) }
        let destination = targetID.flatMap { target in snapshots.firstIndex { $0.id == target } }
            ?? snapshots.lastIndex(where: { $0.groupID == groupID }).map { $0 + 1 }
            ?? snapshots.endIndex
        snapshots.insert(contentsOf: moving, at: destination)
        return true
    }
    
    private func availableGroupName(_ name: String, excluding groupID: UUID? = nil) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "Group" : String(trimmed.prefix(70))
        let existing = Set(groups.filter { $0.id != groupID }.map {
            ScreenshotGroup.filenameComponent($0.name).lowercased()
        })
        var candidate = base
        var suffix = 2
        while existing.contains(ScreenshotGroup.filenameComponent(candidate).lowercased()) {
            candidate = "\(base) \(suffix)"
            suffix += 1
        }
        return candidate
    }
    
    mutating func storeFrame(for configuration: inout ScreenshotConfiguration) throws {
        guard let frame = configuration.frame else { throw ScreenshotRenderer.RenderError.missingFrame }
        if frames[frame.id] == nil { frames[frame.id] = try .load(frameID: frame.id) }
        configuration.storedFrame = frame
        if configuration.watch.needsEmbeddedFrame {
            guard let watchFrame = configuration.watch.frame else { throw ScreenshotRenderer.RenderError.missingFrame }
            if frames[watchFrame.id] == nil { frames[watchFrame.id] = try .load(frameID: watchFrame.id) }
            configuration.watch.storedFrame = watchFrame
        }
    }
    
    private static func readFrame(
        for frame: DeviceFrame,
        from storedFrames: [String: FileWrapper]
    ) throws -> DeviceFrameImages {
        let frameID = frame.id
        guard !frameID.isEmpty, !frameID.contains("/"), frameID != ".", frameID != "..",
              let files = storedFrames[frameID]?.fileWrappers,
              let bezel = files["bezel.png"]?.regularFileContents,
              let mask = files["mask.png"]?.regularFileContents,
              let bezelBitmap = NSBitmapImageRep(data: bezel),
              let maskBitmap = NSBitmapImageRep(data: mask),
              CGFloat(bezelBitmap.pixelsWide) == frame.oriented(isLandscape: false).width,
              CGFloat(bezelBitmap.pixelsHigh) == frame.oriented(isLandscape: false).height,
              maskBitmap.pixelsWide == bezelBitmap.pixelsWide,
              maskBitmap.pixelsHigh == bezelBitmap.pixelsHigh else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return .init(bezel: bezel, mask: mask)
    }
    
    private static func readWatchScreenshot(
        hasScreenshot: Bool?,
        filename: String,
        from screenshots: [String: FileWrapper]
    ) throws -> Data? {
        guard hasScreenshot == true else { return nil }
        guard let data = screenshots[filename]?.regularFileContents, NSBitmapImageRep(data: data) != nil else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return data
    }
    
    private struct Manifest: Codable {
        var version: Int
        var snapshots: [Record]
        var groups: [ScreenshotGroup]?
        var draft: Draft?
        
        struct Draft: Codable {
            var configuration: StoredScreenshotConfiguration
            var sourceName: String
            var source: ScreenshotSource
            var simulatorID: String?
            var hasScreenshot: Bool
            var hasWatchScreenshot: Bool?
            var watchSourceName: String?
            var watchSource: ScreenshotSource?
            var watchSimulatorID: String?
        }
        
        struct Record: Codable {
            var id: UUID
            var name: String
            var configuration: StoredScreenshotConfiguration
            var sourceName: String
            var hasWatchScreenshot: Bool?
            var watchSourceName: String?
            var groupID: UUID?
        }
    }
    
    private enum DocumentError: LocalizedError {
        case unsupportedVersion
        
        var errorDescription: String? {
            "This document uses a newer format. Open it with the latest version of Screenshot Hub."
        }
    }
}
