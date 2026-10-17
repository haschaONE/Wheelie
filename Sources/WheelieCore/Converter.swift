import AppKit
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

public enum ConversionError: LocalizedError {
    case unsupported(FileKind, OutputFormat)
    case unreadable(URL)
    case writeFailed(URL)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let kind, let format): return "Can't convert \(kind.rawValue) to \(format.label)."
        case .unreadable(let url): return "Couldn't read \(url.lastPathComponent)."
        case .writeFailed(let url): return "Couldn't write \(url.lastPathComponent)."
        }
    }
}

public enum Converter {
    /// Converts one file next to the original. Returns the files written
    /// (several for multi-page PDF -> image, multi-sheet workbook -> CSV).
    public static func convert(_ source: URL, to format: OutputFormat) async throws -> [URL] {
        let kind = FileKind(url: source)
        guard OutputFormat.allTargets(for: source).contains(format) else {
            throw ConversionError.unsupported(kind, format)
        }
        switch kind {
        case .image:
            if format == .mp4 || format == .webm { return [try await convertMedia(source, to: format)] }
            return [try await convertImage(source, to: format)]
        case .pdf:
            if format == .png || format == .jpeg { return try convertPDF(source, to: format) }
            return try await DocumentConverter.convert(source, to: format)
        case .video, .audio:
            return [try await convertMedia(source, to: format)]
        case .document, .ebook, .spreadsheet, .presentation:
            return try await DocumentConverter.convert(source, to: format)
        case .unknown:
            throw ConversionError.unsupported(kind, format)
        }
    }

    // MARK: Images

    static func convertImage(_ source: URL, to format: OutputFormat) async throws -> URL {
        let output = OutputNaming.uniqueURL(for: source, ext: format.fileExtension)
        do {
            try await writeImageFormat(source, to: output, format: format)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        return output
    }

    private static func writeImageFormat(_ source: URL, to output: URL, format: OutputFormat) async throws {
        switch format {
        case .webp:
            if source.pathExtension.lowercased() == "gif", imageCount(source) > 1, Tools.locate("gif2webp") != nil {
                try await Tools.run("gif2webp", ["-quiet", "-q", "80", "-m", "4", source.path, "-o", output.path])
                return
            }
            // cwebp reads PNG/JPEG/TIFF/WebP only; route anything else through a temp PNG.
            let readable = ["png", "jpg", "jpeg", "tif", "tiff", "webp"].contains(source.pathExtension.lowercased())
            try await withTemporaryPNG(of: readable ? nil : source) { png in
                try await Tools.run("cwebp", ["-quiet", "-q", "85", "-metadata", "icc", (png ?? source).path, "-o", output.path])
            }
        case .pdf:
            guard let data = try? Data(contentsOf: source), let image = NSImage(data: data), let page = PDFPage(image: image) else {
                throw ConversionError.unreadable(source)
            }
            let doc = PDFDocument()
            doc.insert(page, at: 0)
            guard doc.write(to: output) else { throw ConversionError.writeFailed(output) }
        case .avif:
            if imageIOWrites(avifType) {
                try writeImage(try loadImage(source), to: output, type: UTType(avifType) ?? .png, quality: 0.75)
            } else {
                guard let encoder = try await ffmpegAV1Encoder() else {
                    throw ConversionError.unsupported(.image, .avif)
                }
                try await withTemporaryPNG(of: source) { png in
                    try await Tools.run("ffmpeg", ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", png!.path,
                                                   "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2", "-c:v", encoder, "-crf", "32",
                                                   "-pix_fmt", "yuv420p", "-frames:v", "1", "-still-picture", "1", output.path])
                }
            }
        case .ico:
            try writeIcon(try loadImage(source), to: output)
        case .icns:
            try await writeICNS(try loadImage(source), to: output)
        case .bmp:
            try writeImage(try loadImage(source), to: output, type: .bmp)
        case .gif:
            try writeImage(try loadImage(source), to: output, type: .gif)
        default:
            var image = try loadImage(source)
            if format == .jpeg { image = flattened(image) }
            try writeImage(image, to: output, type: utType(for: format))
        }
    }

    static func utType(for format: OutputFormat) -> UTType {
        switch format {
        case .png: return .png
        case .jpeg: return .jpeg
        case .heic: return .heic
        case .tiff: return .tiff
        case .gif: return .gif
        case .bmp: return .bmp
        case .ico: return .ico
        case .icns: return .icns
        default: return .png
        }
    }

    static let avifType = "public.avif"

    static func imageIOWrites(_ type: String) -> Bool {
        (CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []).contains(type)
    }

    /// ImageIO's AVIF encoder when the system has one; otherwise ffmpeg (checked for an AV1
    /// encoder when converting, so the wheel never launches a process while it's open).
    public static let canEncodeAVIF: Bool = imageIOWrites(avifType) || Tools.locate("ffmpeg") != nil

    /// First AV1 encoder in `ffmpeg -encoders`, via `Tools.capture` like every other ffmpeg call.
    static func ffmpegAV1Encoder() async throws -> String? {
        let list = try await Tools.capture("ffmpeg", ["-hide_banner", "-encoders"]).stdout
        return ["libsvtav1", "libaom-av1", "librav1e"].first { list.contains(" \($0) ") }
    }

    static func imageCount(_ url: URL) -> Int {
        CGImageSourceCreateWithURL(url as CFURL, nil).map(CGImageSourceGetCount) ?? 0
    }

    static func loadImage(_ url: URL) throws -> CGImage {
        if url.pathExtension.lowercased() == "svg" { return try rasterizeSVG(url) }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int
        else { throw ConversionError.unreadable(url) }
        // A full-size "thumbnail" is the ImageIO way to bake in EXIF orientation.
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
            throw ConversionError.unreadable(url)
        }
        return image
    }

    /// SVG via AppKit's SVG image rep, rendered at ≥ 2x and at least 1024 px on the long side.
    /// Loaded from bytes so there's no base folder for references (CoreSVG only renders data: images).
    static func rasterizeSVG(_ url: URL) throws -> CGImage {
        guard let data = try? Data(contentsOf: url), let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 else {
            throw ConversionError.unreadable(url)
        }
        let longest = max(image.size.width, image.size.height)
        let scale = min(max(2, 1024 / longest), 8192 / longest)
        let size = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw ConversionError.unreadable(url) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: CGRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let result = context.makeImage() else { throw ConversionError.unreadable(url) }
        return result
    }

    static func writeImage(_ image: CGImage, to url: URL, type: UTType, quality: Double = 0.9) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw ConversionError.writeFailed(url)
        }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ConversionError.writeFailed(url) }
    }

    /// JPEG has no alpha; composite onto white so transparent areas don't turn black.
    static func flattened(_ image: CGImage) -> CGImage {
        guard image.alphaInfo != .none, image.alphaInfo != .noneSkipFirst, image.alphaInfo != .noneSkipLast,
              let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return image }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(.white)
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage() ?? image
    }

    /// Centres the image on a transparent square canvas of `side` pixels, keeping its aspect ratio.
    static func squareIcon(_ image: CGImage, side: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        let scale = CGFloat(side) / CGFloat(max(image.width, image.height))
        let w = CGFloat(image.width) * scale, h = CGFloat(image.height) * scale
        ctx.draw(image, in: CGRect(x: (CGFloat(side) - w) / 2, y: (CGFloat(side) - h) / 2, width: w, height: h))
        return ctx.makeImage()
    }

    /// Windows icon with the standard sizes up to 256 px that the source can fill.
    /// (ImageIO's ICO writer takes at most six images.)
    static func writeIcon(_ image: CGImage, to url: URL) throws {
        let longest = max(image.width, image.height)
        var sizes = [16, 24, 32, 48, 64, 256].filter { $0 <= max(longest, 16) }
        if sizes.isEmpty { sizes = [16] }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.ico.identifier as CFString, sizes.count, nil) else {
            throw ConversionError.writeFailed(url)
        }
        for side in sizes {
            guard let icon = squareIcon(image, side: side) else { throw ConversionError.writeFailed(url) }
            CGImageDestinationAddImage(dest, icon, nil)
        }
        guard CGImageDestinationFinalize(dest) else { throw ConversionError.writeFailed(url) }
    }

    /// macOS icon via `iconutil` from a generated .iconset (16–512 pt, 1x and 2x); ImageIO as a fallback.
    static func writeICNS(_ image: CGImage, to url: URL) async throws {
        let entries: [(name: String, side: Int)] = [16, 32, 128, 256, 512].flatMap { pt in
            [("icon_\(pt)x\(pt).png", pt), ("icon_\(pt)x\(pt)@2x.png", pt * 2)]
        }
        if Tools.locate("iconutil") != nil {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wheelie-icns-\(UUID().uuidString)")
            let iconset = dir.appendingPathComponent("icon.iconset")
            try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            for entry in entries {
                guard let icon = squareIcon(image, side: entry.side) else { throw ConversionError.writeFailed(url) }
                try writeImage(icon, to: iconset.appendingPathComponent(entry.name), type: .png)
            }
            try await Tools.run("iconutil", ["-c", "icns", iconset.path, "-o", url.path])
            return
        }
        let sides = [16, 32, 64, 128, 256, 512, 1024]
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.icns.identifier as CFString, sides.count, nil) else {
            throw ConversionError.writeFailed(url)
        }
        for side in sides {
            guard let icon = squareIcon(image, side: side) else { throw ConversionError.writeFailed(url) }
            CGImageDestinationAddImage(dest, icon, nil)
        }
        guard CGImageDestinationFinalize(dest) else { throw ConversionError.writeFailed(url) }
    }

    /// Runs `body` with a temporary PNG copy of `source` (nil source → body gets nil).
    static func withTemporaryPNG(of source: URL?, _ body: (URL?) async throws -> Void) async throws {
        guard let source else { return try await body(nil) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let png = dir.appendingPathComponent("input.png")
        try writeImage(try loadImage(source), to: png, type: .png)
        try await body(png)
    }

    // MARK: PDF

    /// PDF pages → images. `naming` overrides the file the outputs are named after (presentations
    /// rendered to a temporary PDF still get "Slides-p1.png").
    static func convertPDF(_ source: URL, to format: OutputFormat, naming: URL? = nil) throws -> [URL] {
        guard let doc = PDFDocument(url: source) else { throw ConversionError.unreadable(source) }
        let name = naming ?? source
        var outputs: [URL] = []
        for index in 0..<doc.pageCount {
            guard let page = doc.page(at: index) else { continue }
            let suffix = doc.pageCount > 1 ? "-p\(index + 1)" : ""
            let output = OutputNaming.uniqueURL(for: name, ext: format.fileExtension, suffix: suffix)
            try writeImage(try render(page, scale: 2), to: output, type: utType(for: format))
            outputs.append(output)
        }
        return outputs
    }

    static func render(_ page: PDFPage, scale: CGFloat) throws -> CGImage {
        let bounds = page.bounds(for: .mediaBox)
        let rotated = page.rotation % 180 != 0
        let size = CGSize(width: (rotated ? bounds.height : bounds.width) * scale,
                          height: (rotated ? bounds.width : bounds.height) * scale)
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw ConversionError.writeFailed(URL(fileURLWithPath: "page")) }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(origin: .zero, size: size))
        ctx.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: ctx)
        guard let image = ctx.makeImage() else { throw ConversionError.writeFailed(URL(fileURLWithPath: "page")) }
        return image
    }

    // MARK: Video / audio (ffmpeg)

    static func ffmpegArguments(for format: OutputFormat) -> [String] {
        switch format {
        case .mp4, .mov:
            return ["-c:v", "libx264", "-crf", "23", "-preset", "medium", "-pix_fmt", "yuv420p",
                    "-c:a", "aac", "-b:a", "160k", "-movflags", "+faststart"]
        case .webm:
            return ["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-row-mt", "1", "-c:a", "libopus", "-b:a", "128k"]
        case .mkv:
            return ["-map", "0:v:0?", "-map", "0:a?", "-c:v", "libx264", "-crf", "20", "-preset", "medium", "-pix_fmt", "yuv420p",
                    "-c:a", "aac", "-b:a", "192k"]
        case .avi:
            return ["-c:v", "mpeg4", "-q:v", "3", "-tag:v", "XVID", "-pix_fmt", "yuv420p", "-c:a", "libmp3lame", "-q:a", "3"]
        case .gif:
            return ["-an", "-vf", "fps=15,scale='min(720,iw)':-2:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse",
                    "-loop", "0"]
        case .mp3: return ["-vn", "-c:a", "libmp3lame", "-q:a", "2"]
        case .m4a: return ["-vn", "-c:a", "aac", "-b:a", "192k"]
        case .wav: return ["-vn", "-c:a", "pcm_s16le"]
        case .flac: return ["-vn", "-c:a", "flac"]
        case .aiff: return ["-vn", "-c:a", "pcm_s16be"]
        case .opus: return ["-vn", "-c:a", "libopus", "-b:a", "128k"]
        default: return []
        }
    }

    /// Animated GIF → video: even dimensions for 4:2:0, no audio track.
    static func gifVideoArguments(for format: OutputFormat) -> [String] {
        let scale = ["-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2"]
        switch format {
        case .webm: return scale + ["-an", "-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-pix_fmt", "yuv420p"]
        default: return scale + ["-an", "-c:v", "libx264", "-crf", "22", "-preset", "medium", "-pix_fmt", "yuv420p", "-movflags", "+faststart"]
        }
    }

    static func convertMedia(_ source: URL, to format: OutputFormat) async throws -> URL {
        let output = OutputNaming.uniqueURL(for: source, ext: format.fileExtension)
        let input = ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", source.path]
        do {
            if FileKind(url: source) == .image {
                try await Tools.run("ffmpeg", input + gifVideoArguments(for: format) + [output.path])
            } else if format == .mkv {
                // Matroska holds nearly any codec: remux losslessly, re-encode only if that fails.
                do {
                    try await Tools.run("ffmpeg", input + ["-map", "0:v?", "-map", "0:a?", "-map", "0:s?", "-c", "copy", output.path])
                } catch {
                    try await Tools.run("ffmpeg", input + ffmpegArguments(for: format) + [output.path])
                }
            } else {
                try await Tools.run("ffmpeg", input + ffmpegArguments(for: format) + [output.path])
            }
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        return output
    }
}
