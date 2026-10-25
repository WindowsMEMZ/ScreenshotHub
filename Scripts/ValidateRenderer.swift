import AppKit
import SwiftUI

@main
struct ValidateRenderer {
    @MainActor
    static func main() throws {
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
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let sourceBitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 600,
            pixelsHigh: 1000,
            bitsPerSample: 8,
            samplesPerPixel: 3,
            hasAlpha: false,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 32
        )!
        for y in 0..<1000 {
            for x in 0..<600 {
                sourceBitmap.setColor(.init(
                    calibratedRed: CGFloat(x) / 600,
                    green: 0.35,
                    blue: CGFloat(y) / 1000,
                    alpha: 1
                ), atX: x, y: y)
            }
        }
        for y in 65..<95 {
            for x in 225..<375 {
                sourceBitmap.setColor(.init(calibratedRed: 0, green: 0, blue: 0, alpha: 1), atX: x, y: y)
            }
        }
        let screenshot = NSImage(size: sourceBitmap.size)
        screenshot.addRepresentation(sourceBitmap)
        try sourceBitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("input.png"))
        
        precondition(!DeviceFrame.all.isEmpty)
        try validateIPadSimulatorMatching()
        try validateDuoSimulatorMatching()
        try validatePreviewResolution(screenshot: screenshot, output: output)
        precondition(Set(DeviceFrame.all.map(\.id)).count == DeviceFrame.all.count)
        for id in ["DeviceFrame15", "DeviceFrame18", "DeviceFrame21", "DeviceFrame92", "DeviceFrame110"] {
            var configuration = ScreenshotConfiguration()
            configuration.frameID = id
            configuration.usesSourceScreenCutouts = true
            let live = try ScreenshotRenderer.render(configuration: configuration, screenshot: screenshot, maximumDimension: 1100)
            configuration.usesSourceScreenCutouts = false
            let still = try ScreenshotRenderer.render(configuration: configuration, screenshot: screenshot, maximumDimension: 1100)
            let screen = ScreenshotRenderer.screenRect(configuration: configuration)
            try live.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("\(id)-source-island.png"))
            try still.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("\(id)-static-island.png"))
            func color(_ bitmap: NSBitmapImageRep, y: CGFloat) -> NSColor {
                let x = Int(screen.midX / configuration.resolution.size.width * CGFloat(bitmap.pixelsWide))
                let y = Int((screen.minY + screen.height * y) / configuration.resolution.size.height * CGFloat(bitmap.pixelsHigh))
                return bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
            }
            let oldPosition = color(live, y: 0.035)
            precondition(oldPosition.greenComponent > 0.3,
                         "Source rendering must expose the screenshot beneath the baked island for \(id).")
            let actualPosition = color(live, y: 0.08)
            precondition(max(actualPosition.redComponent, actualPosition.greenComponent, actualPosition.blueComponent) < 0.03,
                         "The source island must remain at its actual position for \(id): \(actualPosition)")
            let stillPosition = color(still, y: 0.035)
            precondition(stillPosition.greenComponent < 0.1,
                         "Imported screenshots must retain the original bezel artwork for \(id).")
        }
        var count = 0
        for family in DeviceFamily.canvasFamilies {
            for resolution in family.resolutions {
                var configuration = ScreenshotConfiguration()
                configuration.selectFamily(family)
                configuration.resolution = resolution
                configuration.selectCompatibleFrame()
                let data = try ScreenshotRenderer.pngData(configuration: configuration, screenshot: screenshot)
                let bitmap = NSBitmapImageRep(data: data)!
                precondition(bitmap.pixelsWide == resolution.width && bitmap.pixelsHigh == resolution.height)
                precondition(!bitmap.hasAlpha)
                try data.write(to: output.appendingPathComponent("\(family.label)-\(resolution.id).png"))
                count += 1
            }
        }
        
        for frame in DeviceFrame.all where frame.family != .appleWatch {
            var configuration = ScreenshotConfiguration()
            configuration.selectFamily(frame.family)
            if frame.family == .iPad {
                configuration.resolution = frame.family.resolutions.first { $0.isLandscape == frame.isLandscape }!
            }
            configuration.frameID = frame.id
            configuration.usesSourceScreenCutouts = frame.family == .iPhone
            let bitmap = try ScreenshotRenderer.render(configuration: configuration, screenshot: screenshot, maximumDimension: 650)
            precondition(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
            let overlay = try ScreenshotRenderer.render(
                configuration: configuration,
                screenshot: nil,
                maximumDimension: 650,
                screenIsTransparent: true
            )
            precondition(overlay.hasAlpha)
            let hitMask = PreviewScreenMask(image: overlay.cgImage!)
            let screen = ScreenshotRenderer.screenRect(configuration: configuration)
            precondition(hitMask.contains(.init(x: screen.midX, y: screen.midY), canvasSize: configuration.resolution.size))
            precondition(!hitMask.contains(.zero, canvasSize: configuration.resolution.size))
            precondition(!hitMask.contains(.init(x: configuration.resolution.size.width / 2,
                                                y: configuration.resolution.size.height * 0.09),
                                          canvasSize: configuration.resolution.size))
            for y in stride(from: 0, to: overlay.pixelsHigh, by: 11) {
                for x in stride(from: 0, to: overlay.pixelsWide, by: 11) {
                    let point = CGPoint(
                        x: (CGFloat(x) + 0.5) / CGFloat(overlay.pixelsWide) * configuration.resolution.size.width,
                        y: (CGFloat(y) + 0.5) / CGFloat(overlay.pixelsHigh) * configuration.resolution.size.height
                    )
                    precondition(hitMask.contains(point, canvasSize: configuration.resolution.size)
                                 == (overlay.colorAt(x: x, y: y)!.alphaComponent < 0.5),
                                 "Interaction must respect the bezel and camera mask for \(frame.id)")
                }
            }
            let composite = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: overlay.pixelsWide,
                pixelsHigh: overlay.pixelsHigh,
                bitsPerSample: 8,
                samplesPerPixel: 3,
                hasAlpha: false,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 32
            )!
            let graphics = NSGraphicsContext(bitmapImageRep: composite)!
            let context = graphics.cgContext
            context.translateBy(x: 0, y: CGFloat(composite.pixelsHigh))
            context.scaleBy(x: CGFloat(composite.pixelsWide) / configuration.resolution.size.width,
                            y: -CGFloat(composite.pixelsHigh) / configuration.resolution.size.height)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            NSColor(configuration.backgroundColor).setFill()
            NSBezierPath(rect: .init(origin: .zero, size: configuration.resolution.size)).fill()
            let rect = ScreenshotRenderer.screenRect(configuration: configuration)
            let fill = max(rect.width / screenshot.size.width, rect.height / screenshot.size.height)
            let target = CGRect(
                x: rect.midX - screenshot.size.width * fill / 2,
                y: rect.midY - screenshot.size.height * fill / 2,
                width: screenshot.size.width * fill,
                height: screenshot.size.height * fill
            )
            context.saveGState()
            screenshot.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            context.restoreGState()
            let overlayImage = NSImage(size: overlay.size)
            overlayImage.addRepresentation(overlay)
            overlayImage.draw(in: .init(origin: .zero, size: configuration.resolution.size),
                              from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
            var largestDifference: CGFloat = 0
            var differenceLocation = CGPoint.zero
            var totalDifference: CGFloat = 0
            var sampleCount = 0
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 7) {
                for x in stride(from: 0, to: bitmap.pixelsWide, by: 7) {
                    let expected = bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                    let actual = composite.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
                    let difference = max(abs(expected.redComponent - actual.redComponent),
                                         abs(expected.greenComponent - actual.greenComponent),
                                         abs(expected.blueComponent - actual.blueComponent))
                    totalDifference += difference
                    sampleCount += 1
                    let alpha = overlay.colorAt(x: x, y: y)!.alphaComponent
                    if (alpha == 0 || alpha == 1) && difference > largestDifference {
                        largestDifference = difference
                        differenceLocation = .init(x: x, y: y)
                    }
                }
            }
            if largestDifference >= 0.035 {
                try composite.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("composite.png"))
                try overlay.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("overlay.png"))
                try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("expected.png"))
            }
            precondition(totalDifference / CGFloat(sampleCount) < 0.004, "Preview differences must be confined to antialiased edges.")
            precondition(largestDifference < 0.035, "Layered preview must match export for \(frame.id): \(largestDifference) at \(differenceLocation)")

            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("\(frame.id).png"))
        }
        
        var configuration = ScreenshotConfiguration()
        let withShadow = try ScreenshotRenderer.pngData(configuration: configuration, screenshot: screenshot)
        configuration.showsShadow = false
        let withoutShadow = try ScreenshotRenderer.pngData(configuration: configuration, screenshot: screenshot)
        precondition(withShadow != withoutShadow)
        try withoutShadow.write(to: output.appendingPathComponent("without-shadow.png"))
        let shadowBitmap = NSBitmapImageRep(data: withShadow)!
        let plainBitmap = NSBitmapImageRep(data: withoutShadow)!
        for (x, y, adjacentX, adjacentY) in [(1283, 1389, 1282, 1389), (642, 2777, 642, 2776)] {
            let color = shadowBitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
            let plain = plainBitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
            let adjacent = shadowBitmap.colorAt(x: adjacentX, y: adjacentY)!.usingColorSpace(.deviceRGB)!
            precondition(plain.redComponent - color.redComponent > 0.02, "The reference shadow must continue to the canvas edge.")
            precondition(abs(color.redComponent - adjacent.redComponent) < 0.015, "The shadow must not leave an abrupt blank strip.")
        }
        for family in DeviceFamily.canvasFamilies {
            for (scale, offset) in [(0.55, -0.08), (1.1, 0.08)] {
                var variant = ScreenshotConfiguration()
                variant.selectFamily(family)
                variant.deviceScale = scale
                variant.deviceOffset = offset
                let shadow = try ScreenshotRenderer.render(configuration: variant, screenshot: screenshot, maximumDimension: 900)
                variant.showsShadow = false
                let plain = try ScreenshotRenderer.render(configuration: variant, screenshot: screenshot, maximumDimension: 900)
                let shadowData = shadow.representation(using: .png, properties: [:])!
                precondition(shadowData != plain.representation(using: .png, properties: [:])!)
                try shadowData.write(to: output.appendingPathComponent("\(family.label)-layout-\(Int(scale * 100)).png"))
            }
        }
        configuration.title = "记录 👨‍👩‍👧‍👦 的精彩瞬间"
        configuration.highlightRange = (configuration.title as NSString).range(of: "精彩")
        precondition(configuration.highlightedText == "精彩")
        _ = try ScreenshotRenderer.pngData(configuration: configuration, screenshot: screenshot)
        configuration.highlightRange = .init(location: 10000, length: 10000)
        _ = try ScreenshotRenderer.pngData(configuration: configuration, screenshot: screenshot)
        print("Validated \(count) output resolutions, \(DeviceFrame.all.filter { $0.family != .appleWatch }.count) primary frame masks, opaque PNGs, shadow scaling and edge continuity, Unicode highlighting, and layered streaming preview/export parity, and screen interaction masks.")
    }
    
    @MainActor
    static func validateIPadSimulatorMatching() throws {
        var configuration = ScreenshotConfiguration()
        configuration.selectFamily(.iPad)
        configuration.frameID = "DeviceFrame03"
        let screenSizes = Set(DeviceFrame.all.filter { $0.family == .iPad }.map {
            ScreenshotResolution(width: Int($0.screenWidth), height: Int($0.screenHeight))
        })
        for resolution in screenSizes {
            configuration.matchSimulatorScreen(resolution.size)
            let frame = configuration.frame!
            precondition(frame.screenWidth == resolution.size.width && frame.screenHeight == resolution.size.height,
                         "The simulator must use a frame matching its complete native screen.")
            precondition(configuration.resolution.isLandscape == resolution.isLandscape)
            let source = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: resolution.width, pixelsHigh: resolution.height,
                bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32
            )!
            let context = NSGraphicsContext(bitmapImageRep: source)!.cgContext
            let size = resolution.size
            context.setFillColor(NSColor.white.cgColor)
            context.fill(.init(origin: .zero, size: size))
            let edges: [(CGRect, NSColor, CGPoint)] = [
                (.init(x: 0, y: size.height * 0.96, width: size.width, height: size.height * 0.04),
                 .red, .init(x: 0.5, y: 0.02)),
                (.init(x: 0, y: 0, width: size.width, height: size.height * 0.04),
                 .green, .init(x: 0.5, y: 0.98)),
                (.init(x: 0, y: 0, width: size.width * 0.04, height: size.height),
                 .blue, .init(x: 0.02, y: 0.5)),
                (.init(x: size.width * 0.96, y: 0, width: size.width * 0.04, height: size.height),
                 .yellow, .init(x: 0.98, y: 0.5))
            ]
            for (rect, color, _) in edges {
                context.setFillColor(color.cgColor)
                context.fill(rect)
            }
            let screenshot = NSImage(cgImage: source.cgImage!, size: size)
            let output = try ScreenshotRenderer.render(configuration: configuration, screenshot: screenshot, maximumDimension: 1100)
            let screen = ScreenshotRenderer.screenRect(configuration: configuration)
            let scale = CGFloat(output.pixelsWide) / configuration.resolution.size.width
            for (_, color, point) in edges {
                let x = Int((screen.minX + screen.width * point.x) * scale)
                let y = Int((screen.minY + screen.height * point.y) * scale)
                let actual = output.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
                let expected = color.usingColorSpace(.sRGB)!
                precondition(abs(actual.redComponent - expected.redComponent) < 0.03
                             && abs(actual.greenComponent - expected.greenComponent) < 0.03
                             && abs(actual.blueComponent - expected.blueComponent) < 0.03,
                             "Every native iPad screen edge must remain visible after frame matching.")
            }
        }
        configuration.resolution = .init(width: 2064, height: 2752)
        configuration.frameID = "DeviceFrame83"
        configuration.matchSimulatorScreen(.init(width: 2752, height: 2064))
        precondition(configuration.frameID == "DeviceFrame82", "Rotation must preserve the selected bezel model and color.")
        configuration.matchSimulatorScreen(.init(width: 2064, height: 2752))
        precondition(configuration.frameID == "DeviceFrame83")
        let previous = configuration
        for size in [CGSize.zero, .init(width: CGFloat.infinity, height: 10), .init(width: 10, height: CGFloat.nan)] {
            configuration.matchSimulatorScreen(size)
            precondition(configuration == previous)
        }
        configuration.selectFamily(.iPhone)
        let phone = configuration
        configuration.matchSimulatorScreen(.init(width: 2064, height: 2752))
        precondition(configuration == phone)
        print("Validated native iPad screen/frame matching, all four visible edges, orientation changes, bezel model/color preservation, and invalid-size rejection.")
    }
    
    @MainActor
    static func validateDuoSimulatorMatching() throws {
        var configuration = ScreenshotConfiguration()
        for resolution in PhoneResolutionCategory.duo.resolutions {
            configuration.matchSimulatorScreen(resolution.size)
            precondition(configuration.resolution == resolution)
            let frame = configuration.frame!
            precondition(frame.isDuo && frame.isLandscape == resolution.isLandscape)
            precondition(frame.screenWidth == resolution.size.width && frame.screenHeight == resolution.size.height)
            precondition((frame.width > frame.height) == resolution.isLandscape)
            precondition(frame.oriented(isLandscape: false).oriented(isLandscape: resolution.isLandscape) == frame)
            let source = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: resolution.width, pixelsHigh: resolution.height,
                bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32
            )!
            let context = NSGraphicsContext(bitmapImageRep: source)!.cgContext
            let size = resolution.size
            context.setFillColor(NSColor.white.cgColor)
            context.fill(.init(origin: .zero, size: size))
            let edges: [(CGRect, NSColor, CGPoint)] = [
                (.init(x: 0, y: size.height * 0.96, width: size.width, height: size.height * 0.04),
                 .red, .init(x: 0.5, y: 0.02)),
                (.init(x: 0, y: 0, width: size.width, height: size.height * 0.04),
                 .green, .init(x: 0.5, y: 0.98)),
                (.init(x: 0, y: 0, width: size.width * 0.04, height: size.height),
                 .blue, .init(x: 0.02, y: 0.5)),
                (.init(x: size.width * 0.96, y: 0, width: size.width * 0.04, height: size.height),
                 .yellow, .init(x: 0.98, y: 0.5))
            ]
            for (rect, color, _) in edges {
                context.setFillColor(color.cgColor)
                context.fill(rect)
            }
            let screenshot = NSImage(cgImage: source.cgImage!, size: size)
            for usesCutouts in [false, true] {
                configuration.usesSourceScreenCutouts = usesCutouts
                let output = try ScreenshotRenderer.render(configuration: configuration, screenshot: screenshot, maximumDimension: 1100)
                let screen = ScreenshotRenderer.screenRect(configuration: configuration)
                precondition((screen.width > screen.height) == resolution.isLandscape)
                let scale = CGFloat(output.pixelsWide) / size.width
                for (_, color, point) in edges {
                    let actual = output.colorAt(x: Int((screen.minX + screen.width * point.x) * scale),
                                                y: Int((screen.minY + screen.height * point.y) * scale))!.usingColorSpace(.sRGB)!
                    let expected = color.usingColorSpace(.sRGB)!
                    precondition(abs(actual.redComponent - expected.redComponent) < 0.03
                                 && abs(actual.greenComponent - expected.greenComponent) < 0.03
                                 && abs(actual.blueComponent - expected.blueComponent) < 0.03,
                                 "Duo rotation must keep the screen upright and all four source edges visible.")
                }
                let overlay = try ScreenshotRenderer.render(configuration: configuration, screenshot: nil,
                                                            maximumDimension: 650, screenIsTransparent: true)
                let mask = PreviewScreenMask(image: overlay.cgImage!)
                precondition(mask.contains(.init(x: screen.midX, y: screen.midY), canvasSize: size))
                precondition(!mask.contains(.zero, canvasSize: size))
            }
        }
        configuration.frameID = "DeviceFrame120"
        for resolution in PhoneResolutionCategory.duo.resolutions.reversed() {
            configuration.matchSimulatorScreen(resolution.size)
            precondition(configuration.frame!.name.contains("Star White"), "Folding and rotation must preserve the finish.")
        }
        let previous = configuration
        for size in [CGSize.zero, .init(width: CGFloat.infinity, height: 10),
                     .init(width: 10, height: CGFloat.nan), .init(width: 1206, height: 2622)] {
            configuration.matchSimulatorScreen(size)
            precondition(configuration == previous)
        }
        print("Validated Duo simulator inner/outer transitions, all orientations, rotated bezel/screen geometry, source cutouts, masks, visible screen edges, finish preservation, and invalid-size rejection.")
    }
    
    @MainActor
    static func validatePreviewResolution(screenshot: NSImage, output: URL) throws {
        for family in DeviceFamily.canvasFamilies {
            for resolution in family.resolutions {
                let canvas = resolution.size
                for viewport: CGSize in [.init(width: 360, height: 650), .init(width: 950, height: 900)] {
                    let fit = min(viewport.width / canvas.width, viewport.height / canvas.height)
                    var previous: CGFloat = 0
                    for scale: CGFloat in [1, 2, 3] {
                        let dimension = PreviewRenderSizing.maximumDimension(canvasSize: canvas, viewportSize: viewport,
                                                                            displayScale: scale)
                        let needed = min(max(canvas.width, canvas.height), max(canvas.width, canvas.height) * fit * scale)
                        precondition(dimension >= needed && dimension <= max(canvas.width, canvas.height)
                                     && dimension >= previous,
                                     "Preview pixels must cover the fitted viewport at its display scale, capped at export resolution.")
                        previous = dimension
                    }
                }
            }
        }
        var configuration = ScreenshotConfiguration()
        configuration.title = "清晰记录每个瞬间\nSharper screenshot previews"
        configuration.fontScale = 0.035
        configuration.highlightRange = (configuration.title as NSString).range(of: "清晰")
        let canvas = configuration.resolution.size
        let viewport = CGSize(width: 600, height: 900)
        let fit = min(viewport.width / canvas.width, viewport.height / canvas.height) * 2
        let size = CGSize(width: (canvas.width * fit).rounded(), height: (canvas.height * fit).rounded())
        let dimension = PreviewRenderSizing.maximumDimension(canvasSize: canvas, viewportSize: viewport, displayScale: 2)
        precondition(dimension > 1100, "A tall Retina preview must not retain the old 1100-pixel limit.")
        let full = try ScreenshotRenderer.render(configuration: configuration, screenshot: screenshot)
        let old = try ScreenshotRenderer.render(configuration: configuration, screenshot: screenshot, maximumDimension: 1100)
        let improved = try ScreenshotRenderer.render(configuration: configuration, screenshot: screenshot, maximumDimension: dimension)
        func display(_ bitmap: NSBitmapImageRep, name: String) throws -> [UInt8] {
            var pixels = [UInt8](repeating: 0, count: Int(size.width * size.height) * 4)
            let image = pixels.withUnsafeMutableBytes { buffer -> CGImage in
                let context = CGContext(data: buffer.baseAddress, width: Int(size.width), height: Int(size.height),
                                        bitsPerComponent: 8, bytesPerRow: Int(size.width) * 4,
                                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.interpolationQuality = .high
                context.draw(bitmap.cgImage!, in: .init(origin: .zero, size: size))
                return context.makeImage()!
            }
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
                .write(to: output.appendingPathComponent(name))
            return pixels
        }
        let reference = try display(full, name: "Preview-export-reference.png")
        let previous = try display(old, name: "Preview-1100.png")
        let current = try display(improved, name: "Preview-Retina.png")
        func headlineError(_ pixels: [UInt8]) -> Double {
            var error = 0.0
            let count = Int(size.width * size.height * 0.175)
            for index in 0..<count {
                for channel in 0..<3 {
                    let difference = Double(Int(pixels[index * 4 + channel]) - Int(reference[index * 4 + channel])) / 255
                    error += difference * difference
                }
            }
            return error / Double(count * 3)
        }
        let previousError = headlineError(previous)
        let currentError = headlineError(current)
        precondition(currentError < previousError,
                     "Retina preview text must match the full-resolution export more closely than the old enlarged preview.")
        print("Validated display-scale preview resolution; headline MSE reduced from \(previousError) to \(currentError).")
    }
}
