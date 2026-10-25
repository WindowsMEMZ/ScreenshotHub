import SwiftUI
import Foundation

struct StoredScreenshotConfiguration: Codable {
    var family: DeviceFamily
    var resolution: ScreenshotResolution
    var variantCategories: Set<PhoneResolutionCategory>?
    var exportsWatchVariant: Bool?
    var frameID: String
    var frame: DeviceFrame
    var title: String
    var highlightLocation: Int
    var highlightLength: Int
    var themeColor: StoredColor
    var textColor: StoredColor
    var backgroundColor: StoredColor
    var fontScale: Double
    var deviceScale: Double
    var deviceOffset: Double
    var showsShadow: Bool
    var usesSourceScreenCutouts: Bool?
    var watch: WatchConfiguration?
    
    init(_ configuration: ScreenshotConfiguration) throws {
        guard let frame = configuration.frame else { throw ScreenshotRenderer.RenderError.missingFrame }
        family = configuration.family
        resolution = configuration.resolution
        variantCategories = configuration.variantCategories
        exportsWatchVariant = configuration.exportsWatchVariant
        frameID = configuration.frameID
        self.frame = frame
        title = configuration.title
        highlightLocation = configuration.highlightRange.location
        highlightLength = configuration.highlightRange.length
        themeColor = .init(configuration.themeColor)
        textColor = .init(configuration.textColor)
        backgroundColor = .init(configuration.backgroundColor)
        fontScale = configuration.fontScale
        deviceScale = configuration.deviceScale
        deviceOffset = configuration.deviceOffset
        showsShadow = configuration.showsShadow
        usesSourceScreenCutouts = configuration.usesSourceScreenCutouts
        watch = configuration.watch
    }
    
    func configuration() throws -> ScreenshotConfiguration {
        guard family.resolutions.contains(resolution), frameID == frame.id,
              frame.isCompatible(with: resolution, family: family),
              (0.025...0.085).contains(fontScale), (0.55...1.1).contains(deviceScale),
              (-0.08...0.08).contains(deviceOffset),
              frame.width.isFinite, frame.height.isFinite, frame.width > 0, frame.height > 0,
              frame.screenX.isFinite, frame.screenY.isFinite, frame.screenX >= 0, frame.screenY >= 0,
              frame.screenWidth.isFinite, frame.screenHeight.isFinite,
              frame.screenWidth > 0, frame.screenHeight > 0,
              frame.screenX + frame.screenWidth <= frame.width,
              frame.screenY + frame.screenHeight <= frame.height,
              themeColor.isValid, textColor.isValid, backgroundColor.isValid,
              watch?.isValid != false else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var configuration = ScreenshotConfiguration()
        configuration.family = family
        configuration.resolution = resolution
        configuration.variantCategories = variantCategories ?? []
        configuration.exportsWatchVariant = exportsWatchVariant ?? false
        configuration.frameID = frameID
        configuration.storedFrame = frame
        configuration.title = title
        let length = (title as NSString).length
        configuration.highlightRange = highlightLocation >= 0 && highlightLocation <= length
            && highlightLength >= 0 && highlightLength <= length - highlightLocation
            ? .init(location: highlightLocation, length: highlightLength) : .init(location: 0, length: 0)
        configuration.themeColor = themeColor.color
        configuration.textColor = textColor.color
        configuration.backgroundColor = backgroundColor.color
        configuration.fontScale = fontScale
        configuration.deviceScale = deviceScale
        configuration.deviceOffset = deviceOffset
        configuration.showsShadow = showsShadow
        configuration.usesSourceScreenCutouts = usesSourceScreenCutouts ?? false
        configuration.watch = watch ?? .init()
        return configuration
    }
    
    struct StoredColor: Codable, Equatable {
        var linearRed: Float
        var linearGreen: Float
        var linearBlue: Float
        var opacity: Float
        
        init(_ color: Color) {
            let resolved = color.resolve(in: .init())
            linearRed = resolved.linearRed
            linearGreen = resolved.linearGreen
            linearBlue = resolved.linearBlue
            opacity = resolved.opacity
        }
        
        var isValid: Bool {
            [linearRed, linearGreen, linearBlue, opacity].allSatisfy(\.isFinite) && (0...1).contains(opacity)
        }
        var color: Color {
            .init(.init(colorSpace: .sRGBLinear, red: linearRed, green: linearGreen, blue: linearBlue, opacity: opacity))
        }
    }
}
