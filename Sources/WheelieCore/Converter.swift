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
    /// (several for multi-page PDF -> image).
    public static func convert(_ source: URL, to format: OutputFormat) async throws -> [URL] {
        let kind = FileKind(url: source)
        guard OutputFormat.targets(for: kind).contains(format) else {
            throw ConversionError.unsupported(kind, format)
        }
        switch kind {
        case .image: return [try await convertImage(source, to: format)]
        case .pdf: return try convertPDF(source, to: format)
        case .video, .audio: return [try await convertMedia(source, to: format)]
        case .unknown: throw ConversionError.unsupported(kind, format)
        }
    }

    // MARK: Images

    static func convertImage(_ source: URL, to format: OutputFormat) async throws -> URL {
        let output = OutputNaming.uniqueURL(for: source, ext: format.fileExtension)
        switch format {
        case .webp:
            // cwebp reads PNG/JPEG/TIFF/WebP only; route anything else through a temp PNG.
            let readable = ["png", "jpg", "jpeg", "tif", "tiff", "webp"].contains(source.pathExtension.lowercased())
            var input = source
            var temp: URL?
            if !readable {
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let png = dir.appendingPathComponent("input.png")
                try writeImage(try loadImage(source), to: png, type: .png)
                input = png
                temp = dir
            }
            defer { if let temp { try? FileManager.default.removeItem(at: temp) } }
            try await Tools.run("cwebp", ["-quiet", "-q", "85", "-metadata", "icc", input.path, "-o", output.path])
        case .pdf:
            guard let image = NSImage(contentsOf: source), let page = PDFPage(image: image) else {
                throw ConversionError.unreadable(source)
            }
            let doc = PDFDocument()
            doc.insert(page, at: 0)
            guard doc.write(to: output) else { throw ConversionError.writeFailed(output) }
        default:
            var image = try loadImage(source)
            if format == .jpeg { image = flattened(image) }
            try writeImage(image, to: output, type: utType(for: format))
        }
        return output
    }

    static func utType(for format: OutputFormat) -> UTType {
        switch format {
        case .png: return .png
        case .jpeg: return .jpeg
        case .heic: return .heic
        case .tiff: return .tiff
        default: return .png
        }
    }

    static func loadImage(_ url: URL) throws -> CGImage {
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

    static func writeImage(_ image: CGImage, to url: URL, type: UTType) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw ConversionError.writeFailed(url)
        }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
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

    // MARK: PDF

    static func convertPDF(_ source: URL, to format: OutputFormat) throws -> [URL] {
        guard let doc = PDFDocument(url: source) else { throw ConversionError.unreadable(source) }
        if format == .txt {
            let output = OutputNaming.uniqueURL(for: source, ext: "txt")
            try (doc.string ?? "").write(to: output, atomically: true, encoding: .utf8)
            return [output]
        }
        var outputs: [URL] = []
        for index in 0..<doc.pageCount {
            guard let page = doc.page(at: index) else { continue }
            let suffix = doc.pageCount > 1 ? "-p\(index + 1)" : ""
            let output = OutputNaming.uniqueURL(for: source, ext: format.fileExtension, suffix: suffix)
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
        case .gif:
            return ["-an", "-vf", "fps=15,scale='min(720,iw)':-2:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse",
                    "-loop", "0"]
        case .mp3: return ["-vn", "-c:a", "libmp3lame", "-q:a", "2"]
        case .m4a: return ["-vn", "-c:a", "aac", "-b:a", "192k"]
        case .wav: return ["-vn", "-c:a", "pcm_s16le"]
        case .flac: return ["-vn", "-c:a", "flac"]
        default: return []
        }
    }

    static func convertMedia(_ source: URL, to format: OutputFormat) async throws -> URL {
        let output = OutputNaming.uniqueURL(for: source, ext: format.fileExtension)
        let args = ["-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", source.path]
            + ffmpegArguments(for: format) + [output.path]
        do {
            try await Tools.run("ffmpeg", args)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        return output
    }
}
