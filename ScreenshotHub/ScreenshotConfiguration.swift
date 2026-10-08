import AppKit
import SwiftUI
    
nonisolated struct ScreenshotResolution: Sendable, Codable, Hashable, Identifiable {
    let width: Int
    let height: Int
    
    var id: String { "\(width)x\(height)" }
    var label: String { "\(width) × \(height)" }
    var isLandscape: Bool { width > height }
    var size: CGSize { .init(width: width, height: height) }
}
    
nonisolated enum PhoneResolutionCategory: String, Sendable, CaseIterable, Codable, Identifiable {
    case dynamicIslandLarge
    case faceIDLarge
    case dynamicIslandMedium
    case faceIDMedium
    
    var id: Self { self }
    var label: String {
        switch self {
        case .dynamicIslandLarge: "iPhone with Dynamic Island (large display)"
        case .faceIDLarge: "iPhone with Face ID (large display)"
        case .dynamicIslandMedium: "iPhone with Dynamic Island (medium display)"
        case .faceIDMedium: "iPhone with Face ID (medium display)"
        }
    }
    var resolutions: [ScreenshotResolution] {
        switch self {
        case .dynamicIslandLarge:
            [
                .init(width: 1260, height: 2736),
                .init(width: 1290, height: 2796),
                .init(width: 1320, height: 2868)
            ]
        case .faceIDLarge:
            [.init(width: 1284, height: 2778), .init(width: 1242, height: 2688)]
        case .dynamicIslandMedium:
            [.init(width: 1179, height: 2556), .init(width: 1206, height: 2622)]
        case .faceIDMedium:
            [
                .init(width: 1170, height: 2532),
                .init(width: 1125, height: 2436),
                .init(width: 1080, height: 2340)
            ]
        }
    }
    
    func closestResolution(to source: ScreenshotResolution) -> ScreenshotResolution {
        resolutions.min {
            let left = pow(Double($0.width - source.width), 2) + pow(Double($0.height - source.height), 2)
            let right = pow(Double($1.width - source.width), 2) + pow(Double($1.height - source.height), 2)
            return left < right
        }!
    }
}
    
nonisolated enum DeviceFamily: String, Sendable, CaseIterable, Identifiable, Codable {
    case iPhone
    case iPad
    case mac
    case appleWatch
    
    static var canvasFamilies: [Self] { [.iPhone, .iPad, .mac] }
    
    var id: Self { self }
    var label: String {
        switch self {
        case .mac: "Mac"
        case .appleWatch: "Apple Watch"
        default: rawValue
        }
    }
    var symbol: String {
        switch self {
        case .iPhone: "iphone"
        case .iPad: "ipad"
        case .mac: "laptopcomputer"
        case .appleWatch: "applewatch"
        }
    }
    var resolutions: [ScreenshotResolution] {
        switch self {
        case .iPhone:
            PhoneResolutionCategory.allCases.flatMap(\.resolutions)
        case .iPad:
            [
                .init(width: 2064, height: 2752), .init(width: 2752, height: 2064),
                .init(width: 2048, height: 2732), .init(width: 2732, height: 2048)
            ]
        case .appleWatch: []
        case .mac:
            [
                .init(width: 1280, height: 800), .init(width: 1440, height: 900),
                .init(width: 2560, height: 1600), .init(width: 2880, height: 1800)
            ]
        }
    }
}
    
nonisolated struct DeviceFrame: Sendable, Codable, Equatable, Identifiable {
    static let all: [Self] = {
        guard let url = Bundle.main.url(forResource: "DeviceFrames", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let frames = try? JSONDecoder().decode([Self].self, from: data) else { return [] }
        return frames
    }()
    
    let id: String
    let name: String
    let family: DeviceFamily
    let width: CGFloat
    let height: CGFloat
    let screenX: CGFloat
    let screenY: CGFloat
    let screenWidth: CGFloat
    let screenHeight: CGFloat
    let isLandscape: Bool
    
    var displayName: String {
        name.replacingOccurrences(of: " · 竖屏", with: " · Portrait")
            .replacingOccurrences(of: " · 横屏", with: " · Landscape")
    }
    var size: CGSize { .init(width: width, height: height) }
    var screenRect: CGRect {
        .init(x: screenX, y: screenY, width: screenWidth, height: screenHeight)
    }
}
    
nonisolated struct ScreenshotConfiguration: Sendable, Equatable {
    var family = DeviceFamily.iPhone
    var resolution = PhoneResolutionCategory.faceIDLarge.resolutions[0]
    var variantCategories: Set<PhoneResolutionCategory> = []
    var exportsWatchVariant = false
    var frameID = DeviceFrame.all.first { $0.name.contains("Pro Max - Silver") }?.id ?? ""
    var title = "Make every moment\nworth keeping."
    var highlightRange = NSRange(location: 5, length: 12)
    var themeColor = Color.accentColor
    var textColor = Color.black
    var backgroundColor = Color(red: 0.95, green: 0.95, blue: 0.95)
    var fontScale = 0.052
    var deviceScale = 1.0
    var deviceOffset = 0.0
    var showsShadow = true
    var usesSourceScreenCutouts = false
    var storedFrame: DeviceFrame?
    var watch = WatchConfiguration()
    
    var availableFrames: [DeviceFrame] {
        var frames = DeviceFrame.all
        if let storedFrame {
            if let index = frames.firstIndex(where: { $0.id == storedFrame.id }) {
                frames[index] = storedFrame
            } else {
                frames.append(storedFrame)
            }
        }
        return frames.filter {
            $0.family == family && (family != .iPad || $0.isLandscape == resolution.isLandscape)
        }
    }
    var frame: DeviceFrame? { availableFrames.first { $0.id == frameID } }
    var resolutionCategory: PhoneResolutionCategory? {
        guard family == .iPhone else { return nil }
        return PhoneResolutionCategory.allCases.first { $0.resolutions.contains(resolution) }
    }
    var availableVariantCategories: [PhoneResolutionCategory] {
        guard family == .iPhone else { return [] }
        return PhoneResolutionCategory.allCases.filter { $0 != resolutionCategory }
    }
    var variantResolutions: [ScreenshotResolution] {
        availableVariantCategories.filter { variantCategories.contains($0) }
            .map { $0.closestResolution(to: resolution) }
    }
    var hasWatchVariant: Bool { family == .iPhone && watch.isEnabled && exportsWatchVariant }
    var variantCount: Int { variantResolutions.count + (hasWatchVariant ? 1 : 0) }
    var highlightedText: String {
        let string = title as NSString
        guard highlightRange.location != NSNotFound,
              highlightRange.location <= string.length,
              highlightRange.length <= string.length - highlightRange.location else { return "" }
        return string.substring(with: highlightRange)
    }
    
    mutating func selectFamily(_ family: DeviceFamily) {
        guard let resolution = family.resolutions.first else { return }
        self.family = family
        self.resolution = family == .iPhone ? PhoneResolutionCategory.faceIDLarge.resolutions[0] : resolution
        variantCategories.removeAll()
        exportsWatchVariant = false
        selectCompatibleFrame()
    }
    
    mutating func selectResolution(_ resolution: ScreenshotResolution) {
        self.resolution = resolution
        if let resolutionCategory { variantCategories.remove(resolutionCategory) }
        selectCompatibleFrame()
    }
    
    mutating func selectCompatibleFrame() {
        if !availableFrames.contains(where: { $0.id == frameID }) {
            frameID = availableFrames.first?.id ?? ""
        }
    }
    
    mutating func matchSimulatorScreen(_ size: CGSize) {
        guard family == .iPad, size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
        let previousFrame = frame
        let isLandscape = size.width > size.height
        if resolution.isLandscape != isLandscape,
           let rotatedResolution = family.resolutions.first(where: {
               $0.isLandscape == isLandscape && max($0.width, $0.height) == max(resolution.width, resolution.height)
           }) {
            resolution = rotatedResolution
        }
        let frames = availableFrames
        let aspect = size.width / size.height
        guard let closest = frames.min(by: {
            let left = abs(log(($0.screenWidth / $0.screenHeight) / aspect))
            let right = abs(log(($1.screenWidth / $1.screenHeight) / aspect))
            if abs(left - right) > 0.000001 { return left < right }
            let leftSize = pow($0.screenWidth - size.width, 2) + pow($0.screenHeight - size.height, 2)
            let rightSize = pow($1.screenWidth - size.width, 2) + pow($1.screenHeight - size.height, 2)
            return leftSize < rightSize
        }) else { return }
        let matchingFrames = frames.filter { $0.screenWidth == closest.screenWidth && $0.screenHeight == closest.screenHeight }
        let previousName = previousFrame?.displayName.components(separatedBy: " · ").first
        frameID = matchingFrames.first { $0.displayName.components(separatedBy: " · ").first == previousName }?.id ?? closest.id
    }
}
