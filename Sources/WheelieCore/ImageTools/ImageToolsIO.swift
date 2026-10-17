import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Errors from the image tools (crop, adjust, annotate, frame, redact, collage).
public enum ImageToolError: LocalizedError, Equatable {
    case unreadable(String)
    case renderFailed(String)
    case writeFailed(String)
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let name): return "Couldn't read \(name)."
        case .renderFailed(let what): return "Couldn't create the \(what)."
        case .writeFailed(let name): return "Couldn't save \(name)."
        case .invalid(let message): return message
        }
    }
}

/// A source photo with EXIF orientation baked into its pixels, plus what export
/// needs to keep the original format, color profile and metadata.
public struct SourceImage: @unchecked Sendable {
    public let url: URL
    /// Upright pixels in the file's own color space and bit depth.
    public let image: CGImage
    /// UTType identifier of the file, e.g. "public.jpeg".
    public let typeIdentifier: String
    /// Image properties from the file (EXIF, TIFF, GPS, IPTC, DPI…).
    public let properties: [CFString: Any]
    /// Number of frames/pages (> 1 for animated GIFs and multi-page TIFFs).
    public let frameCount: Int

    public var size: CGSize { CGSize(width: image.width, height: image.height) }
}

public enum ImageToolsIO {
    // MARK: Loading

    /// Loads the first frame at full fidelity and bakes EXIF orientation into the pixels.
    public static func load(_ url: URL) throws -> SourceImage {
        let name = url.lastPathComponent
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0,
              let raw = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { throw ImageToolError.unreadable(name) }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)
            .flatMap { CGImagePropertyOrientation(rawValue: $0.uint32Value) } ?? .up
        let upright = orientation == .up ? raw : try ImageCrop.applyingEXIFOrientation(orientation, to: raw)
        let type = CGImageSourceGetType(src) as String?
            ?? UTType(filenameExtension: url.pathExtension)?.identifier ?? UTType.png.identifier
        return SourceImage(url: url, image: upright, typeIdentifier: type, properties: props,
                           frameCount: CGImageSourceGetCount(src))
    }

    /// Fast, upright, downscaled decode (8-bit) — for previews and collage cells.
    public static func loadThumbnail(_ url: URL, maxPixelSize: Int) throws -> CGImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ImageToolError.unreadable(url.lastPathComponent)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
            throw ImageToolError.unreadable(url.lastPathComponent)
        }
        return image
    }

    /// Pixel size of an image file after orientation, without decoding it.
    public static func pixelSize(of url: URL) -> CGSize? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue
        else { return nil }
        let o = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return o >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    /// Scales an image down so its longer side is at most `maxPixelSize` (never up).
    public static func downscaled(_ image: CGImage, maxPixelSize: Int) -> CGImage {
        let long = max(image.width, image.height)
        guard long > maxPixelSize, maxPixelSize > 0 else { return image }
        let s = CGFloat(maxPixelSize) / CGFloat(long)
        let size = CGSize(width: max(1, (CGFloat(image.width) * s).rounded()),
                          height: max(1, (CGFloat(image.height) * s).rounded()))
        return (try? ImageCrop.resized(image, to: size)) ?? image
    }

    // MARK: Bitmap contexts

    /// RGB (or gray) color space to render `image` into, keeping its profile when CoreGraphics can.
    public static func workingColorSpace(for image: CGImage?) -> CGColorSpace {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let cs = image?.colorSpace else { return srgb }
        switch cs.model {
        case .rgb where cs.supportsOutput: return cs
        case .indexed:
            if let base = cs.baseColorSpace, base.model == .rgb, base.supportsOutput { return base }
            return srgb
        default: return srgb
        }
    }

    /// A y-up bitmap context. `like` picks color space and bit depth (16-bit sources stay 16-bit).
    public static func makeContext(width: Int, height: Int, like image: CGImage?, alpha: Bool = true,
                                   colorSpace: CGColorSpace? = nil) throws -> CGContext {
        guard width > 0, height > 0, width <= 32_768, height <= 32_768 else {
            throw ImageToolError.invalid("The image would be too large (\(width) × \(height) pixels).")
        }
        let space = colorSpace ?? workingColorSpace(for: image)
        let deep = (image?.bitsPerComponent ?? 8) > 8
        let alphaInfo: CGImageAlphaInfo = alpha ? .premultipliedLast : .noneSkipLast
        if deep, let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 16, bytesPerRow: 0,
                                     space: space, bitmapInfo: alphaInfo.rawValue) {
            ctx.interpolationQuality = .high
            return ctx
        }
        if let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                               space: space, bitmapInfo: alphaInfo.rawValue) {
            ctx.interpolationQuality = .high
            return ctx
        }
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: srgb, bitmapInfo: alphaInfo.rawValue)
        else { throw ImageToolError.renderFailed("image canvas") }
        ctx.interpolationQuality = .high
        return ctx
    }

    /// Flips a y-up bitmap context so (0,0) is the top-left corner, matching the tools' pixel space.
    public static func flipToTopLeft(_ ctx: CGContext, height: Int) {
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
    }

    /// Draws an image into `rect` of a top-left (flipped) context without turning it upside down.
    public static func draw(_ image: CGImage, in rect: CGRect, context ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    // MARK: Pixels

    /// True when any pixel is not fully opaque.
    public static func hasTransparency(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: break
        }
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data
        else { return true }
        ctx.setBlendMode(.copy)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let bytes = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
        for i in stride(from: 3, to: w * h * 4, by: 4) where bytes[i] < 255 { return true }
        return false
    }

    // MARK: Export

    /// Formats that can store an alpha channel.
    static let alphaCapable: Set<String> = [
        UTType.png.identifier, UTType.tiff.identifier, UTType.heic.identifier, "public.heif",
        UTType.gif.identifier, UTType.webP.identifier, "public.avif", "public.jpeg-2000",
        UTType.ico.identifier, UTType.icns.identifier, "com.adobe.photoshop-image",
    ]

    /// Where the result goes, and how to encode it.
    public struct ExportPlan: Equatable, Sendable {
        public var type: UTType
        public var fileExtension: String
        /// ImageIO can't write WebP; route it through `cwebp`.
        public var useCWebP: Bool
    }

    /// Keeps the source format when it's writable and can hold the result; otherwise PNG.
    public static func plan(sourceType: String, sourceExtension: String, transparent: Bool,
                            cwebpAvailable: Bool = Tools.locate("cwebp") != nil) -> ExportPlan {
        let png = ExportPlan(type: .png, fileExtension: "png", useCWebP: false)
        let type = UTType(sourceType) ?? UTType(filenameExtension: sourceExtension) ?? .png
        if transparent && !alphaCapable.contains(type.identifier) { return png }
        let ext = sourceExtension.isEmpty ? (type.preferredFilenameExtension ?? "png") : sourceExtension
        if type.conforms(to: .webP) || ext.lowercased() == "webp" {
            return cwebpAvailable ? ExportPlan(type: .webP, fileExtension: ext, useCWebP: true) : png
        }
        let writable = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
        guard writable.contains(type.identifier), type != .pdf else { return png }
        return ExportPlan(type: type, fileExtension: ext, useCWebP: false)
    }

    /// Metadata to carry over: EXIF/TIFF/GPS/IPTC/DPI, with orientation reset (pixels are upright now)
    /// and stale pixel dimensions removed. Thumbnails are never copied.
    public static func carriedMetadata(from properties: [CFString: Any]) -> [CFString: Any] {
        var out: [CFString: Any] = [kCGImagePropertyOrientation: 1]
        for key in [kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight] {
            if let v = properties[key] { out[key] = v }
        }
        if var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif[kCGImagePropertyExifPixelXDimension] = nil
            exif[kCGImagePropertyExifPixelYDimension] = nil
            exif[kCGImagePropertyExifSubjectArea] = nil
            out[kCGImagePropertyExifDictionary] = exif
        }
        if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            out[kCGImagePropertyTIFFDictionary] = tiff
        }
        for key in [kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary] {
            if let v = properties[key] { out[key] = v }
        }
        return out
    }

    /// Encodes `image` with ImageIO. The color space travels as an embedded ICC profile.
    public static func write(_ image: CGImage, to url: URL, type: UTType, metadata: [CFString: Any] = [:]) throws {
        var image = image
        if !alphaCapable.contains(type.identifier) { image = opaque(image) }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw ImageToolError.writeFailed(url.lastPathComponent)
        }
        var props = metadata
        props[kCGImageDestinationLossyCompressionQuality] = 0.92
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: url)
            throw ImageToolError.writeFailed(url.lastPathComponent)
        }
    }

    /// Removes the alpha channel (composited on white) for formats without transparency.
    static func opaque(_ image: CGImage) -> CGImage {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return image
        default: break
        }
        guard let ctx = try? makeContext(width: image.width, height: image.height, like: image, alpha: false) else { return image }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage() ?? image
    }

    /// Writes the edited image next to the source (via `OutputNaming`) as "<name><suffix>.<ext>",
    /// keeping the source format when possible (PNG when it can't hold the result's transparency).
    /// Returns the URL written.
    public static func export(_ image: CGImage, source: SourceImage, suffix: String,
                              preserveMetadata: Bool = true, forceType: UTType? = nil) async throws -> URL {
        let plan: ExportPlan
        if let forceType {
            plan = ExportPlan(type: forceType, fileExtension: forceType.preferredFilenameExtension ?? "png", useCWebP: false)
        } else {
            plan = Self.plan(sourceType: source.typeIdentifier, sourceExtension: source.url.pathExtension,
                             transparent: hasTransparency(image))
        }
        let output = OutputNaming.uniqueURL(for: source.url, ext: plan.fileExtension, suffix: suffix)
        let metadata = preserveMetadata ? carriedMetadata(from: source.properties) : [kCGImagePropertyOrientation: 1]
        if plan.useCWebP {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wheelie-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let png = dir.appendingPathComponent("edited.png")
            try write(image, to: png, type: .png)
            do {
                try await Tools.run("cwebp", ["-quiet", "-q", "90", "-metadata", "icc", png.path, "-o", output.path])
            } catch {
                try? FileManager.default.removeItem(at: output)
                throw error
            }
        } else {
            try write(image, to: output, type: plan.type, metadata: metadata)
        }
        return output
    }
}

/// A color stored as sRGB components so settings stay Codable.
public struct RGBAColor: Codable, Hashable, Sendable {
    public var red: Double, green: Double, blue: Double, alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }

    /// From a hex value like 0xFF8800.
    public init(hex: UInt32, alpha: Double = 1) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, alpha: alpha)
    }

    public init?(cgColor: CGColor) {
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let c = cgColor.converted(to: srgb, intent: .defaultIntent, options: nil),
              let comps = c.components, comps.count >= 3
        else { return nil }
        self.init(red: Double(comps[0]), green: Double(comps[1]), blue: Double(comps[2]),
                  alpha: Double(comps.count > 3 ? comps[3] : 1))
    }

    public var cgColor: CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }

    public func withAlpha(_ a: Double) -> RGBAColor { RGBAColor(red: red, green: green, blue: blue, alpha: a) }

    /// Relative luminance, for picking a readable text color on top.
    public var luminance: Double { 0.2126 * red + 0.7152 * green + 0.0722 * blue }

    public static let black = RGBAColor(red: 0, green: 0, blue: 0)
    public static let white = RGBAColor(red: 1, green: 1, blue: 1)
    public static let clear = RGBAColor(red: 0, green: 0, blue: 0, alpha: 0)
}
