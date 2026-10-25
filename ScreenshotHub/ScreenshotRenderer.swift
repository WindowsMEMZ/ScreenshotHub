import AppKit
import SwiftUI
    
nonisolated enum ScreenshotRenderer {
    private static let renderLock = NSRecursiveLock()
    // Rendering and image reuse share a lock because NSImage representations are lazy.
    nonisolated(unsafe) private static let decodedImages: NSCache<NSData, NSImage> = {
        let cache = NSCache<NSData, NSImage>()
        cache.totalCostLimit = 128 * 1024 * 1024
        cache.countLimit = 24
        return cache
    }()
    
    static func image(for data: Data) -> NSImage? {
        renderLock.lock()
        defer { renderLock.unlock() }
        let key = data as NSData
        if let image = decodedImages.object(forKey: key) { return image }
        guard let bitmap = NSBitmapImageRep(data: data), let cgImage = bitmap.cgImage else { return nil }
        let image = NSImage(cgImage: cgImage, size: .init(width: cgImage.width, height: cgImage.height))
        decodedImages.setObject(image, forKey: key, cost: cgImage.bytesPerRow * cgImage.height)
        return image
    }
    
    enum RenderError: LocalizedError {
        case missingFrame
        case bitmapCreation
        case pngEncoding
        case shadowCreation
        
        var errorDescription: String? {
            switch self {
            case .missingFrame: "Unable to load the device frame. Select another frame."
            case .bitmapCreation: "Unable to create the image. Try again."
            case .pngEncoding: "Unable to generate the PNG image."
            case .shadowCreation: "Unable to generate the device shadow. Try again."
            }
        }
    }
    
    static func render(
        configuration: ScreenshotConfiguration,
        screenshot: NSImage?,
        maximumDimension: CGFloat? = nil,
        screenIsTransparent: Bool = false,
        frameImages: DeviceFrameImages? = nil,
        watchScreenshot: NSImage? = nil,
        watchFrameImages: DeviceFrameImages? = nil,
        watchScreenIsTransparent: Bool = false,
        includesWatch: Bool = true,
        watchOnly: Bool = false
    ) throws -> NSBitmapImageRep {
        renderLock.lock()
        defer { renderLock.unlock() }
        guard let frame = configuration.frame,
              let bezel = frameImages.flatMap({ Self.image(for: $0.bezel) }) ?? NSImage(named: frame.id),
              let maskImage = frameImages.flatMap({ Self.image(for: $0.mask) }) ?? NSImage(named: "\(frame.id)Mask") else {
            throw RenderError.missingFrame
        }
        let size = configuration.resolution.size
        let scale = maximumDimension.map { min(1, $0 / max(size.width, size.height)) } ?? 1
        let width = Int((size.width * scale).rounded())
        let height = Int((size.height * scale).rounded())
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: screenIsTransparent || watchScreenIsTransparent || watchOnly ? 4 : 3,
            hasAlpha: screenIsTransparent || watchScreenIsTransparent || watchOnly,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 32
        ), let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw RenderError.bitmapCreation
        }
        let context = graphics.cgContext
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: CGFloat(width) / size.width, y: -CGFloat(height) / size.height)
        context.interpolationQuality = .high
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let drawingContext = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.current = drawingContext
        guard var mask = try? DeviceFrameImages.nativeCGImage(for: maskImage) else {
            throw RenderError.missingFrame
        }
        var renderedBezel = bezel
        if !watchOnly, frame.family == .iPhone, screenIsTransparent || configuration.usesSourceScreenCutouts {
            guard let originalBezel = try? DeviceFrameImages.nativeCGImage(for: bezel) else {
                throw RenderError.missingFrame
            }
            let images = try sourceScreenImages(
                bezel: originalBezel,
                mask: mask,
                frame: frame.oriented(isLandscape: false),
                key: "\(frame.id)-\(frame.screenRect)-\(frame.size)" + (frameImages.map {
                    "-\($0.bezel.hashValue)-\($0.mask.hashValue)"
                } ?? "")
            )
            renderedBezel = NSImage(cgImage: images.bezel, size: bezel.size)
            mask = images.mask
        }
        if !watchOnly, frame.isDuo, frame.isLandscape {
            let key = "\(frame.id)-\(frame.size)-\(screenIsTransparent || configuration.usesSourceScreenCutouts)"
                + (frameImages.map { "-\($0.bezel.hashValue)-\($0.mask.hashValue)" } ?? "")
            let images = try landscapeFrameImages(bezel: renderedBezel, mask: mask, key: key)
            renderedBezel = images.bezel
            mask = images.mask
        }
        if !watchOnly {
            NSColor(configuration.backgroundColor).setFill()
            NSBezierPath(rect: .init(origin: .zero, size: size)).fill()
        
            let deviceRect = deviceRect(configuration: configuration, frame: frame)
            let deviceSize = deviceRect.size
        
            if configuration.showsShadow {
                try DeviceShadowRenderer.draw(
                    frame: frame,
                    bezel: renderedBezel,
                    screenMask: mask,
                    in: deviceRect,
                    graphics: drawingContext,
                    cacheKey: frameImages.map {
                        "\(frame.id)-\($0.bezel.hashValue)-\($0.mask.hashValue)-\(frame.width)x\(frame.height)"
                    }.map { $0 + "-\(screenIsTransparent || configuration.usesSourceScreenCutouts)" }
                        ?? "\(frame.id)-\(frame.size)-\(screenIsTransparent || configuration.usesSourceScreenCutouts)"
                )
            }
        
            context.saveGState()
            // Core Graphics image masks use an upward Y axis, unlike the layout coordinates.
            context.translateBy(x: deviceRect.minX, y: deviceRect.maxY)
            context.scaleBy(x: 1, y: -1)
            context.clip(to: .init(origin: .zero, size: deviceSize), mask: mask)
            context.scaleBy(x: 1, y: -1)
            context.translateBy(x: -deviceRect.minX, y: -deviceRect.maxY)
            let deviceRatio = deviceSize.width / frame.width
            let screenRect = CGRect(
                x: deviceRect.minX + frame.screenX * deviceRatio,
                y: deviceRect.minY + frame.screenY * deviceRatio,
                width: frame.screenWidth * deviceRatio,
                height: frame.screenHeight * deviceRatio
            )
            if screenIsTransparent {
                context.clear(screenRect)
            } else if let screenshot {
                drawAspectFill(screenshot, in: screenRect)
            } else {
                drawPlaceholder(in: screenRect, themeColor: NSColor(configuration.themeColor))
            }
            context.restoreGState()
            renderedBezel.draw(in: deviceRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            drawTitle(configuration, canvasSize: size)
        }
        if includesWatch, configuration.family == .iPhone, configuration.watch.isEnabled {
            try drawWatch(configuration: configuration, screenshot: watchScreenshot,
                          images: watchFrameImages, isTransparent: watchScreenIsTransparent,
                          graphics: drawingContext)
        }
        bitmap.size = .init(width: width, height: height)
        return bitmap
    }
    
    nonisolated(unsafe) private static var sourceScreenFrames: [String: (bezel: CGImage, mask: CGImage)] = [:]
    nonisolated(unsafe) private static var landscapeFrames: [String: (bezel: NSImage, mask: CGImage)] = [:]
    
    private static func landscapeFrameImages(
        bezel: NSImage,
        mask: CGImage,
        key: String
    ) throws -> (bezel: NSImage, mask: CGImage) {
        if let images = landscapeFrames[key] { return images }
        func rotate(_ image: CGImage) throws -> CGImage {
            guard let context = CGContext(
                data: nil,
                width: image.height,
                height: image.width,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { throw RenderError.bitmapCreation }
            context.translateBy(x: 0, y: CGFloat(image.width))
            context.rotate(by: -.pi / 2)
            context.draw(image, in: .init(x: 0, y: 0, width: image.width, height: image.height))
            guard let rotated = context.makeImage() else { throw RenderError.bitmapCreation }
            return rotated
        }
        let rotatedBezel = try rotate(DeviceFrameImages.nativeCGImage(for: bezel))
        let images = (NSImage(cgImage: rotatedBezel, size: .init(width: rotatedBezel.width, height: rotatedBezel.height)),
                      try rotate(mask))
        if landscapeFrames.count >= 8 { landscapeFrames.removeAll(keepingCapacity: true) }
        landscapeFrames[key] = images
        return images
    }
    
    private static func sourceScreenImages(
        bezel: CGImage,
        mask: CGImage,
        frame: DeviceFrame,
        key: String
    ) throws -> (bezel: CGImage, mask: CGImage) {
        let key = "\(key)-\(bezel.width)x\(bezel.height)-\(mask.width)x\(mask.height)"
        if let images = sourceScreenFrames[key] { return images }
        let width = bezel.width
        let height = bezel.height
        let row = width * 4
        func pixels(for image: CGImage) throws -> [UInt8] {
            var pixels = [UInt8](repeating: 0, count: row * height)
            try pixels.withUnsafeMutableBytes { bytes in
                guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                              bitsPerComponent: 8, bytesPerRow: row,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                    throw RenderError.bitmapCreation
                }
                context.draw(image, in: .init(x: 0, y: 0, width: width, height: height))
            }
            return pixels
        }
        func image(from pixels: [UInt8]) throws -> CGImage {
            guard let provider = CGDataProvider(data: Data(pixels) as CFData),
                  let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                      bytesPerRow: row, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: .init(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                      provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
                throw RenderError.bitmapCreation
            }
            return image
        }
        var bezelPixels = try pixels(for: bezel)
        let screen = CGRect(x: frame.screenX * CGFloat(width) / frame.width,
                            y: frame.screenY * CGFloat(height) / frame.height,
                            width: frame.screenWidth * CGFloat(width) / frame.width,
                            height: frame.screenHeight * CGFloat(height) / frame.height)
        let left = max(0, Int(ceil(screen.minX)))
        let top = max(0, Int(ceil(screen.minY)))
        let right = min(width, Int(floor(screen.maxX)))
        let bottom = min(height, Int(floor(screen.minY + screen.height * 0.15)))
        let bandWidth = right - left
        let bandHeight = bottom - top
        guard bandWidth > 0, bandHeight > 0 else { return (bezel, mask) }
        var visited = [Bool](repeating: false, count: bandWidth * bandHeight)
        var cutouts: [CGRect] = []
        // Only detached artwork inside the screen is removable; the rim, rounded corners, and attached notches stay intact.
        for seed in visited.indices where !visited[seed] {
            visited[seed] = true
            let seedX = seed % bandWidth
            let seedY = seed / bandWidth
            guard bezelPixels[(top + seedY) * row + (left + seedX) * 4 + 3] > 0 else { continue }
            var pending = [seed]
            var minX = seedX, maxX = seedX, minY = seedY, maxY = seedY
            var touchesEdge = false
            while let index = pending.popLast() {
                let x = index % bandWidth
                let y = index / bandWidth
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
                if x == 0 || y == 0 || x == bandWidth - 1 || y == bandHeight - 1 { touchesEdge = true }
                for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                    let nextX = x + dx, nextY = y + dy
                    guard nextX >= 0, nextX < bandWidth, nextY >= 0, nextY < bandHeight else { continue }
                    let next = nextY * bandWidth + nextX
                    guard !visited[next] else { continue }
                    visited[next] = true
                    if bezelPixels[(top + nextY) * row + (left + nextX) * 4 + 3] > 0 { pending.append(next) }
                }
            }
            if !touchesEdge, minX > 2, minY > 2, maxX < bandWidth - 3, maxY < bandHeight - 3 {
                cutouts.append(.init(x: left + minX - 2, y: top + minY - 2,
                                     width: maxX - minX + 5, height: maxY - minY + 5))
            }
        }
        var images = (bezel: bezel, mask: mask)
        if !cutouts.isEmpty {
            var maskPixels = try pixels(for: mask)
            for rect in cutouts {
                for y in Int(rect.minY)..<Int(rect.maxY) {
                    for x in Int(rect.minX)..<Int(rect.maxX) {
                        let index = y * row + x * 4
                        for channel in 0..<4 {
                            bezelPixels[index + channel] = 0
                            maskPixels[index + channel] = 255
                        }
                    }
                }
            }
            images = try (image(from: bezelPixels), image(from: maskPixels))
        }
        if sourceScreenFrames.count >= 4 { sourceScreenFrames.removeAll(keepingCapacity: true) }
        sourceScreenFrames[key] = images
        return images
    }
    
    static func screenRect(configuration: ScreenshotConfiguration) -> CGRect {
        guard let frame = configuration.frame else { return .zero }
        let device = deviceRect(configuration: configuration, frame: frame)
        let ratio = device.width / frame.width
        return .init(
            x: device.minX + frame.screenX * ratio,
            y: device.minY + frame.screenY * ratio,
            width: frame.screenWidth * ratio,
            height: frame.screenHeight * ratio
        )
    }
    
    private static func deviceRect(configuration: ScreenshotConfiguration, frame: DeviceFrame) -> CGRect {
        let size = configuration.resolution.size
        let isLandscape = configuration.resolution.isLandscape
        let top = size.height * (isLandscape ? 0.29 : 0.175)
        let availableHeight = size.height * (isLandscape ? 0.65 : 0.79)
        let availableWidth = size.width * (configuration.family == .iPhone ? 0.84 : 0.92)
        let fit = min(availableWidth / frame.width, availableHeight / frame.height) * configuration.deviceScale
        let deviceSize = CGSize(width: frame.width * fit, height: frame.height * fit)
        let phone = CGRect(
            x: (size.width - deviceSize.width) / 2,
            y: top + (availableHeight - deviceSize.height) / 2 + size.height * configuration.deviceOffset,
            width: deviceSize.width,
            height: deviceSize.height
        )
        guard configuration.family == .iPhone, configuration.watch.isEnabled,
              let watchFrame = configuration.watch.frame else { return phone }
        return pairedDeviceRects(configuration: configuration, phone: phone, watchFrame: watchFrame).phone
    }
    
    private static func pairedDeviceRects(
        configuration: ScreenshotConfiguration,
        phone: CGRect,
        watchFrame: DeviceFrame
    ) -> (phone: CGRect, watch: CGRect) {
        let canvas = configuration.resolution.size
        let watchWidth = canvas.width * configuration.watch.scale
        let watchSize = CGSize(width: watchWidth, height: watchWidth * watchFrame.height / watchFrame.width)
        let watchLeft = phone.width * (0.5 + configuration.watch.horizontalPosition * 0.5)
        let combinedWidth = max(phone.width, watchLeft + watchSize.width)
        let phoneArea = phone.width * phone.height
        let watchArea = watchSize.width * watchSize.height
        let visualCenter = (phone.width / 2 * phoneArea + (watchLeft + watchSize.width / 2) * watchArea)
            / (phoneArea + watchArea)
        let radius = max(visualCenter, combinedWidth - visualCenter)
        let fit = min(1, canvas.width * 0.92 / (radius * 2))
        let left = canvas.width / 2 - visualCenter * fit
        let bottom = phone.midY + phone.height * fit / 2
        let phoneRect = CGRect(x: left, y: bottom - phone.height * fit,
                               width: phone.width * fit, height: phone.height * fit)
        let watchRect = CGRect(x: left + watchLeft * fit, y: bottom - watchSize.height * fit,
                               width: watchSize.width * fit, height: watchSize.height * fit)
        return (phoneRect, watchRect)
    }
    
    static func watchDeviceRect(configuration: ScreenshotConfiguration) -> CGRect {
        guard let watchFrame = configuration.watch.frame, let phoneFrame = configuration.frame else { return .zero }
        var phoneConfiguration = configuration
        phoneConfiguration.watch.isEnabled = false
        let phone = deviceRect(configuration: phoneConfiguration, frame: phoneFrame)
        return pairedDeviceRects(configuration: configuration, phone: phone, watchFrame: watchFrame).watch
    }
    
    static func watchCrownRect(configuration: ScreenshotConfiguration) -> CGRect {
        guard let frame = configuration.watch.frame else { return .zero }
        let device = watchDeviceRect(configuration: configuration)
        let ratio = device.width / frame.width
        return .init(x: device.minX + frame.width * 0.92 * ratio,
                     y: device.minY + (frame.screenY + frame.screenHeight * 0.18) * ratio,
                     width: frame.width * 0.08 * ratio,
                     height: frame.screenHeight * 0.21 * ratio)
    }
    
    static func watchScreenRect(configuration: ScreenshotConfiguration) -> CGRect {
        guard let frame = configuration.watch.frame else { return .zero }
        let device = watchDeviceRect(configuration: configuration)
        let ratio = device.width / frame.width
        return .init(x: device.minX + (frame.screenX - 2) * ratio, y: device.minY + (frame.screenY - 2) * ratio,
                     width: (frame.screenWidth + 4) * ratio, height: (frame.screenHeight + 4) * ratio)
    }
    
    static func watchScreenMask(
        configuration: ScreenshotConfiguration,
        frameImages: DeviceFrameImages? = nil,
        graphics: NSGraphicsContext
    ) throws -> CGImage {
        renderLock.lock()
        defer { renderLock.unlock() }
        guard let frame = configuration.watch.frame,
              let image = frameImages.flatMap({ Self.image(for: $0.mask) }) ?? NSImage(named: "\(frame.id)Mask"),
              let original = try? DeviceFrameImages.nativeCGImage(for: image) else {
            throw RenderError.missingFrame
        }
        let mask = try opaqueWatchMask(original, key: frame.id + (frameImages.map { "-\($0.mask.hashValue)" } ?? ""))
        guard frame.width.isFinite, frame.height.isFinite, frame.width > 0, frame.height > 0 else {
            throw RenderError.missingFrame
        }
        let screen = frame.screenRect.insetBy(dx: -2, dy: -2)
        // Frame geometry uses native device coordinates; image representations can have a different pixel size.
        let scaleX = CGFloat(mask.width) / frame.width
        let scaleY = CGFloat(mask.height) / frame.height
        let rect = CGRect(
            x: screen.minX * scaleX,
            y: screen.minY * scaleY,
            width: screen.width * scaleX,
            height: screen.height * scaleY
        ).integral
        guard !rect.isInfinite, !rect.isNull, !rect.isEmpty,
              let cropped = mask.cropping(to: rect) else {
            throw RenderError.bitmapCreation
        }
        return cropped
    }
    
    nonisolated(unsafe) private static var watchMasks: [String: CGImage] = [:]
    
    private static func opaqueWatchMask(_ original: CGImage, key: String) throws -> CGImage {
        let key = "\(key)-\(original.width)x\(original.height)"
        if let mask = watchMasks[key] { return mask }
        let width = original.width
        let height = original.height
        let row = width * 4
        var pixels = [UInt8](repeating: 0, count: row * height)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: row, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw RenderError.bitmapCreation }
        context.draw(original, in: .init(x: 0, y: 0, width: width, height: height))
        var horizontal = [UInt8](repeating: 0, count: width * height)
        // Cover the bezel's antialiased edge from underneath; inverse alpha would apply its transparency twice.
        for y in 0..<height {
            var count = (0..<min(3, width)).reduce(0) { $0 + (pixels[y * row + $1 * 4 + 3] > 0 ? 1 : 0) }
            for x in 0..<width {
                horizontal[y * width + x] = count > 0 ? 1 : 0
                if x >= 2 { count -= pixels[y * row + (x - 2) * 4 + 3] > 0 ? 1 : 0 }
                if x + 3 < width { count += pixels[y * row + (x + 3) * 4 + 3] > 0 ? 1 : 0 }
            }
        }
        var covered = [UInt32](repeating: 0, count: width * height)
        for x in 0..<width {
            var count = (0..<min(3, height)).reduce(0) { $0 + Int(horizontal[$1 * width + x]) }
            for y in 0..<height {
                covered[y * width + x] = count > 0 ? .max : 0
                if y >= 2 { count -= Int(horizontal[(y - 2) * width + x]) }
                if y + 3 < height { count += Int(horizontal[(y + 3) * width + x]) }
            }
        }
        let data = covered.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData),
              let mask = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                 bytesPerRow: row, space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: .init(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                 provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            throw RenderError.bitmapCreation
        }
        if watchMasks.count >= 8 { watchMasks.removeAll(keepingCapacity: true) }
        watchMasks[key] = mask
        return mask
    }
    
    private static func drawWatch(
        configuration: ScreenshotConfiguration,
        screenshot: NSImage?,
        images: DeviceFrameImages?,
        isTransparent: Bool,
        graphics: NSGraphicsContext
    ) throws {
        guard let frame = configuration.watch.frame,
              let bezel = images.flatMap({ Self.image(for: $0.bezel) }) ?? NSImage(named: frame.id),
              let maskImage = images.flatMap({ Self.image(for: $0.mask) }) ?? NSImage(named: "\(frame.id)Mask"),
              let originalMask = try? DeviceFrameImages.nativeCGImage(for: maskImage) else {
            throw RenderError.missingFrame
        }
        let mask = try opaqueWatchMask(originalMask, key: frame.id + (images.map { "-\($0.mask.hashValue)" } ?? ""))
        let device = watchDeviceRect(configuration: configuration)
        let screen = watchScreenRect(configuration: configuration)
        let context = graphics.cgContext
        if configuration.showsShadow {
            try DeviceShadowRenderer.draw(frame: frame, bezel: bezel, screenMask: mask, in: device, graphics: graphics,
                                          cacheKey: images.map { "\(frame.id)-\($0.bezel.hashValue)-\($0.mask.hashValue)" })
        }
        context.saveGState()
        context.translateBy(x: device.minX, y: device.maxY)
        context.scaleBy(x: 1, y: -1)
        context.clip(to: .init(origin: .zero, size: device.size), mask: mask)
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: -device.minX, y: -device.maxY)
        if isTransparent {
            context.clear(screen)
        } else {
            if let screenshot { drawAspectFill(screenshot, in: screen) }
            else { drawPlaceholder(in: screen, themeColor: NSColor(configuration.themeColor)) }
            if configuration.watch.clock.isEnabled, let screenshot,
               let source = screenshot.cgImage(forProposedRect: nil, context: graphics, hints: nil),
               let layout = WatchClockRenderer.layout(for: screenshot, source: source),
               let patch = try WatchClockRenderer.patch(configuration: configuration.watch.clock,
                                                         sourceSize: .init(width: source.width, height: source.height),
                                                         source: source, layout: layout) {
                let image = NSImage(size: .init(width: patch.image.width, height: patch.image.height))
                image.addRepresentation(NSBitmapImageRep(cgImage: patch.image))
                let fit = max(screen.width / CGFloat(source.width), screen.height / CGFloat(source.height))
                let sourceRect = CGRect(x: screen.midX - CGFloat(source.width) * fit / 2,
                                        y: screen.midY - CGFloat(source.height) * fit / 2,
                                        width: CGFloat(source.width) * fit, height: CGFloat(source.height) * fit)
                image.draw(in: patch.rect(in: sourceRect), from: .zero, operation: .sourceOver,
                           fraction: 1, respectFlipped: true, hints: nil)
            }
        }
        context.restoreGState()
        bezel.draw(in: device, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
    
    static func pngData(
        configuration: ScreenshotConfiguration,
        screenshot: NSImage,
        frameImages: DeviceFrameImages? = nil,
        watchScreenshot: NSImage? = nil,
        watchFrameImages: DeviceFrameImages? = nil
    ) throws -> Data {
        let bitmap = try render(configuration: configuration, screenshot: screenshot, frameImages: frameImages,
                                watchScreenshot: watchScreenshot, watchFrameImages: watchFrameImages)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw RenderError.pngEncoding
        }
        return data
    }
    
    private static func drawAspectFill(_ image: NSImage, in rect: CGRect) {
        let scale = max(rect.width / image.size.width, rect.height / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        image.draw(
            in: .init(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height),
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )
    }
    
    private static func drawTitle(_ configuration: ScreenshotConfiguration, canvasSize: CGSize) {
        let fontSize = min(canvasSize.width, canvasSize.height) * configuration.fontScale
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = fontSize * 0.28
        paragraph.lineBreakMode = .byWordWrapping
        let text = NSMutableAttributedString(string: configuration.title, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: NSColor(configuration.textColor),
            .paragraphStyle: paragraph
        ])
        let range = configuration.highlightRange
        if range.location != NSNotFound, range.location <= text.length, range.length <= text.length - range.location {
            text.addAttribute(.foregroundColor, value: NSColor(configuration.themeColor), range: range)
        }
        let isLandscape = configuration.resolution.isLandscape
        let rect = CGRect(
            x: canvasSize.width * 0.07,
            y: canvasSize.height * (isLandscape ? 0.045 : 0.05),
            width: canvasSize.width * 0.86,
            height: canvasSize.height * (isLandscape ? 0.20 : 0.105)
        )
        let measured = text.boundingRect(with: rect.size, options: [.usesLineFragmentOrigin, .usesFontLeading])
        text.draw(with: rect.offsetBy(dx: 0, dy: max(0, (rect.height - measured.height) / 2)), options: [.usesLineFragmentOrigin, .usesFontLeading])
    }
    
    private static func drawPlaceholder(in rect: CGRect, themeColor: NSColor) {
        NSColor(white: 0.98, alpha: 1).setFill()
        NSBezierPath(rect: rect).fill()
        let fontSize = rect.width * 0.055
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let text = NSAttributedString(string: "Your app,\ncoming soon.", attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: themeColor,
            .paragraphStyle: paragraph
        ])
        text.draw(in: .init(x: rect.minX, y: rect.midY - fontSize * 1.5, width: rect.width, height: fontSize * 4))
    }
}
