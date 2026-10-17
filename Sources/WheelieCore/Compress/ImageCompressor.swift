import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Image compression. Keeps the format where it has a lossy or palette mode:
/// JPEG/HEIC/AVIF via ImageIO quality, WebP via cwebp, PNG via palette quantization,
/// GIF via ffmpeg palettes. Other formats (TIFF, BMP, RAW…) become JPEG, or PNG when they have alpha.
enum ImageCompressor {
    enum Codec: Equatable {
        case lossy(UTType)   // JPEG, HEIC, AVIF
        case webp
        case png
        case gif

        var fileExtension: String {
            switch self {
            case .lossy(let type):
                if type == .jpeg { return "jpg" }
                return type.preferredFilenameExtension ?? "jpg"
            case .webp: return "webp"
            case .png: return "png"
            case .gif: return "gif"
            }
        }
    }

    /// Longest edge used for Strong presets when no explicit size was chosen (≈ 9 MP for 4:3).
    static let strongPresetMaxEdge = 3072

    static func codec(forType type: String?, hasAlpha: Bool) -> Codec {
        switch type {
        case UTType.jpeg.identifier: return .lossy(.jpeg)
        case UTType.heic.identifier, UTType.heif.identifier, "public.heics": return .lossy(.heic)
        case "public.avif": return .lossy(UTType("public.avif") ?? .heic)
        case "org.webmproject.webp": return .webp
        case UTType.png.identifier: return .png
        case UTType.gif.identifier: return .gif
        default: return hasAlpha ? .png : .lossy(.jpeg)
        }
    }

    // Quality ladders, best first.
    static let lossyLevels: [Double] = stride(from: 0.95, through: 0.099, by: -0.05).map { ($0 * 100).rounded() / 100 }
    static let webpLevels: [Int] = Array(stride(from: 95, through: 10, by: -5))
    static let paletteLevels: [Int] = [256, 192, 128, 96, 64, 48, 32, 24, 16]
    static let gifLevels: [Int] = [256, 128, 64, 32, 16]

    static func presetQuality(_ strength: CompressionStrength) -> Double {
        switch strength { case .light: return 0.8; case .balanced: return 0.6; case .strong: return 0.4 }
    }
    static func presetWebP(_ strength: CompressionStrength) -> Int {
        switch strength { case .light: return 80; case .balanced: return 65; case .strong: return 45 }
    }
    static func presetColors(_ strength: CompressionStrength) -> Int {
        switch strength { case .light: return 256; case .balanced: return 128; case .strong: return 64 }
    }

    static func compress(_ source: URL, options: CompressionOptions, cap: Int64, targeted: Bool,
                         workDir: URL) async throws -> (url: URL, ext: String) {
        guard let src = CGImageSourceCreateWithURL(source as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { throw CompressionError.unreadable(source.lastPathComponent) }
        let type = CGImageSourceGetType(src) as String?
        let index = CGImageSourceGetPrimaryImageIndex(src)
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0
        else { throw CompressionError.unreadable(source.lastPathComponent) }
        let hasAlpha = props[kCGImagePropertyHasAlpha] as? Bool ?? false
        let codec = codec(forType: type, hasAlpha: hasAlpha)
        let frames = CGImageSourceGetCount(src)
        if frames > 1, codec == .png || codec == .webp { throw CompressionError.animated }

        let strength = options.imageStrength
        var limit = options.imageSize.maxPixels ?? Int.max
        if !targeted, strength == .strong { limit = min(limit, strongPresetMaxEdge) }
        let longest = max(width, height)
        let baseEdge = min(longest, limit)

        let output = workDir.appendingPathComponent("output").appendingPathExtension(codec.fileExtension)
        let data: Data

        if codec == .gif {
            let gif = GIFEncoder(source: source, width: width, height: height, animated: frames > 1,
                                 loopCount: loopCount(src), workDir: workDir)
            let baseScale = Double(baseEdge) / Double(longest)
            if targeted {
                data = try await BudgetSearch.run(levels: gifLevels.count, scales: BudgetSearch.imageScales, cap: cap) { level, scale in
                    try await gif.encode(colors: gifLevels[level], scale: baseScale * scale)
                }
            } else {
                guard let encoded = try await gif.encode(colors: presetColors(strength), scale: baseScale) else {
                    throw CompressionError.imageFailed
                }
                data = encoded
            }
        } else {
            let decoder = Decoder(source: src, index: index, baseEdge: baseEdge)
            let metadata = preservedProperties(props)
            let dpi = props[kCGImagePropertyDPIWidth] as? Double
            func encode(_ image: CGImage, level: Int?) async throws -> Data? {
                switch codec {
                case .lossy(let type):
                    let quality = level.map { lossyLevels[$0] } ?? presetQuality(strength)
                    return encodeImageIO(image, type: type, quality: quality, properties: metadata)
                case .webp:
                    let quality = level.map { webpLevels[$0] } ?? presetWebP(strength)
                    return try await encodeWebP(image, quality: quality, workDir: workDir)
                case .png:
                    let colors = level.map { paletteLevels[$0] } ?? presetColors(strength)
                    return PalettePNG.encode(image, maxColors: colors, dither: true, dpi: dpi)
                case .gif:
                    return nil
                }
            }
            let levelCount: Int
            switch codec {
            case .lossy: levelCount = lossyLevels.count
            case .webp: levelCount = webpLevels.count
            default: levelCount = paletteLevels.count
            }
            if targeted {
                data = try await BudgetSearch.run(levels: levelCount, scales: BudgetSearch.imageScales, cap: cap) { level, scale in
                    guard let image = decoder.image(scale: scale) else { return nil }
                    return try await encode(image, level: level)
                }
            } else {
                guard let image = decoder.image(scale: 1), let encoded = try await encode(image, level: nil) else {
                    throw CompressionError.imageFailed
                }
                data = encoded
            }
        }

        guard let check = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(check) > 0,
              CGImageSourceCopyPropertiesAtIndex(check, 0, nil) != nil
        else { throw CompressionError.imageFailed }
        try data.write(to: output, options: .atomic)
        return (output, codec.fileExtension)
    }

    /// Decodes the source with EXIF orientation applied, at `baseEdge * scale` on the long side.
    final class Decoder {
        let source: CGImageSource
        let index: Int
        let baseEdge: Int
        private var cache: (scale: Double, image: CGImage)?

        init(source: CGImageSource, index: Int, baseEdge: Int) {
            self.source = source
            self.index = index
            self.baseEdge = baseEdge
        }

        func image(scale: Double) -> CGImage? {
            if let cache, cache.scale == scale { return cache.image }
            let edge = Int((Double(baseEdge) * scale).rounded())
            guard edge >= 16 else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: edge,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else { return nil }
            cache = (scale, image)
            return image
        }
    }

    /// EXIF/GPS/IPTC/TIFF survive compression (dates and places matter in photo libraries);
    /// orientation is baked into the pixels, maker notes and thumbnails are dropped.
    static func preservedProperties(_ props: [CFString: Any]) -> [CFString: Any] {
        var out: [CFString: Any] = [kCGImagePropertyOrientation: 1]
        let drop: Set<String> = [kCGImagePropertyTIFFOrientation as String, kCGImagePropertyExifPixelXDimension as String,
                                 kCGImagePropertyExifPixelYDimension as String, kCGImagePropertyTIFFTileWidth as String,
                                 kCGImagePropertyTIFFTileLength as String]
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary,
                    kCGImagePropertyIPTCDictionary, kCGImagePropertyTIFFDictionary] {
            guard let dict = props[key] as? [String: Any] else { continue }
            out[key] = dict.filter { !drop.contains($0.key) }
        }
        return out
    }

    static func encodeImageIO(_ image: CGImage, type: UTType, quality: Double, properties: [CFString: Any]) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        var props = properties
        props[kCGImageDestinationLossyCompressionQuality] = quality
        let input = type == .jpeg ? Converter.flattened(image) : image
        CGImageDestinationAddImage(dest, input, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// cwebp only reads PNG/JPEG/TIFF/WebP and can't apply EXIF orientation, so feed it a lossless temp PNG.
    static func encodeWebP(_ image: CGImage, quality: Int, workDir: URL) async throws -> Data? {
        guard Tools.locate("cwebp") != nil else { throw ToolError.missing("cwebp") }
        let input = workDir.appendingPathComponent("webp-input-\(image.width)x\(image.height).png")
        if !FileManager.default.fileExists(atPath: input.path) {
            try Converter.writeImage(image, to: input, type: .png)
        }
        let out = workDir.appendingPathComponent("webp-\(quality).webp")
        try await Tools.run("cwebp", ["-quiet", "-q", String(quality), "-m", "5", "-alpha_q", String(max(quality, 50)),
                                      "-metadata", "icc", input.path, "-o", out.path])
        defer { try? FileManager.default.removeItem(at: out) }
        return try Data(contentsOf: out)
    }

    static func loopCount(_ src: CGImageSource) -> Int? {
        guard let props = CGImageSourceCopyProperties(src, nil) as? [CFString: Any],
              let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        else { return nil }
        return gif[kCGImagePropertyGIFLoopCount] as? Int
    }
}

/// Re-palettizes GIFs (animated or not) with ffmpeg; fewer colors and ordered dithering compress best with LZW.
struct GIFEncoder {
    let source: URL
    let width: Int
    let height: Int
    let animated: Bool
    let loopCount: Int?
    let workDir: URL

    func encode(colors: Int, scale: Double) async throws -> Data? {
        let w = Int((Double(width) * scale).rounded()), h = Int((Double(height) * scale).rounded())
        guard w >= 8, h >= 8 else { return nil }
        var filters: [String] = []
        if w != width || h != height { filters.append("scale=\(w):\(h):flags=lanczos") }
        let stats = animated ? "diff" : "full"
        filters.append("split[a][b];[a]palettegen=max_colors=\(colors):stats_mode=\(stats)[p];"
                       + "[b][p]paletteuse=dither=bayer:bayer_scale=3" + (animated ? ":diff_mode=rectangle" : ""))
        let out = workDir.appendingPathComponent("gif-\(colors)-\(w).gif")
        // GIFs without a loop count play once; ffmpeg's -loop -1 means "no loop", 0 "forever".
        let loop = loopCount.map(String.init) ?? "-1"
        try await Tools.run("ffmpeg", ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", source.path,
                                       "-vf", filters.joined(separator: ","), "-loop", loop, "-f", "gif", out.path])
        defer { try? FileManager.default.removeItem(at: out) }
        return try Data(contentsOf: out)
    }
}
