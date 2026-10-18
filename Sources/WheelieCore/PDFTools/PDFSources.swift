import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Errors from the PDF tools. The message is shown to the user as is.
public struct PDFToolsError: LocalizedError, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }

    public static let noPages = PDFToolsError("This PDF has no pages.")
    public static let pageOrder = PDFToolsError("The page order must include every page exactly once.")
    public static let keepOnePage = PDFToolsError("Keep at least one page.")
    public static let rightAngles = PDFToolsError("Page rotations must be 90-degree turns for pages in this PDF.")

    static func unreadable(_ url: URL) -> PDFToolsError {
        PDFToolsError("“\(url.lastPathComponent)” cannot be read or is password-protected.")
    }
    static func unsupported(_ url: URL) -> PDFToolsError {
        PDFToolsError("“\(url.lastPathComponent)” isn't a PDF or an image.")
    }
    static func unreadableImage(_ url: URL) -> PDFToolsError {
        PDFToolsError("Could not read the image “\(url.lastPathComponent)”.")
    }
}

/// Opens the files the PDF tools work on. Images count as PDFs whose page is the size of
/// the image at 72 dpi (one pixel per point): one page, or one per page of a multi-page TIFF.
public enum PDFSourceLoader {
    /// True for files the PDF tools can turn into pages.
    public static func isPageSource(_ url: URL) -> Bool {
        let kind = FileKind(url: url)
        return kind == .pdf || kind == .image
    }

    /// Opens a PDF, or wraps an image in a PDF (one page per image page). Throws for locked
    /// or unreadable files.
    public static func document(for url: URL) throws -> PDFDocument {
        switch FileKind(url: url) {
        case .pdf:
            guard let doc = PDFDocument(url: url), !doc.isLocked else { throw PDFToolsError.unreadable(url) }
            return doc
        case .image:
            let data = try ImagesToPDF.data(from: [url], options: ImagePDFOptions())
            guard let doc = PDFDocument(data: data) else { throw PDFToolsError.unreadableImage(url) }
            return doc
        default:
            throw PDFToolsError.unsupported(url)
        }
    }

    /// Page count without loading PDFKit. It still opens and parses the file, so keep it
    /// off the main thread (and out of the wheel's `accepts`). Images count one page per
    /// image page (see `document(for:)`); nil when unreadable.
    public static func pageCount(of url: URL) -> Int? {
        switch FileKind(url: url) {
        case .pdf:
            guard let doc = CGPDFDocument(url as CFURL), !doc.isEncrypted || doc.isUnlocked else { return nil }
            return doc.numberOfPages
        case .image:
            return (try? EmbeddableImage.source(for: url)).map(EmbeddableImage.pageCount(of:))
        default:
            return nil
        }
    }

    /// An image's upright pixel size (EXIF orientation applied), a small upright thumbnail
    /// (both of its first page) and how many pages it makes.
    public static func imageSummary(_ url: URL, thumbnailPixels: CGFloat) -> (size: CGSize, thumbnail: CGImage, pages: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue
        else { return nil }
        let raw = (props[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        let turned = (5...8).contains(raw)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(16, thumbnailPixels),
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return (turned ? CGSize(width: height, height: width) : CGSize(width: width, height: height), thumbnail,
                EmbeddableImage.pageCount(of: source))
    }

    /// Finder's name order: "file 2" before "file 10", case-insensitive.
    public static func sortedByName(_ urls: [URL]) -> [URL] {
        urls.enumerated().sorted { a, b in
            let order = a.element.lastPathComponent.localizedStandardCompare(b.element.lastPathComponent)
            return order == .orderedSame ? a.offset < b.offset : order == .orderedAscending
        }.map(\.element)
    }

    /// A unique, not yet existing folder next to `source` (or in the "Save to" folder),
    /// named "<source name><suffix>", e.g. "report pages", then "report pages 2", ...
    public static func uniqueFolder(for source: URL, suffix: String,
                                    fileManager: FileManager = .default) -> URL {
        let dir = OutputNaming.preferredDirectory ?? source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent + suffix
        var candidate = dir.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base) \(n)", isDirectory: true)
            n += 1
        }
        return candidate
    }
}

// MARK: - Page geometry and rendering

public enum PDFPageGeometry {
    /// Rotation normalised to 0, 90, 180 or 270.
    public static func normalized(_ degrees: Int) -> Int { ((degrees % 360) + 360) % 360 }

    /// Size of the visible (crop) box as displayed, i.e. after `rotation`.
    public static func displayedSize(of page: PDFPage, rotation: Int? = nil) -> CGSize {
        let box = page.bounds(for: .cropBox).size
        let turn = normalized(rotation ?? page.rotation)
        return turn % 180 == 0 ? box : CGSize(width: box.height, height: box.width)
    }

    /// Renders the page (as displayed, with its rotation) on white.
    public static func render(_ page: PDFPage, scale: CGFloat) throws -> CGImage {
        let size = displayedSize(of: page)
        let width = max(1, Int((size.width * scale).rounded())), height = max(1, Int((size.height * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw PDFToolsError("A PDF page could not be rendered.") }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: CGFloat(width) / size.width, y: CGFloat(height) / size.height)
        page.draw(with: .cropBox, to: ctx)
        guard let image = ctx.makeImage() else { throw PDFToolsError("A PDF page could not be rendered.") }
        return image
    }

    /// A thumbnail whose longer side is `maxPixels`.
    public static func thumbnail(_ page: PDFPage, maxPixels: CGFloat) throws -> CGImage {
        let size = displayedSize(of: page)
        let longest = max(size.width, size.height, 1)
        return try render(page, scale: maxPixels / longest)
    }

    /// Page info for media boxes passed to `CGContext.beginPDFPage`.
    static func pageInfo(mediaBox: CGRect) -> CFDictionary {
        var box = mediaBox
        let data = Data(bytes: &box, count: MemoryLayout<CGRect>.size) as CFData
        return [kCGPDFContextMediaBox as String: data] as CFDictionary
    }
}

// MARK: - Images

/// An image ready to be drawn into a PDF. Kept undecoded where possible, so JPEG data is
/// embedded as is instead of being re-compressed.
struct EmbeddableImage {
    let image: CGImage
    let orientation: CGImagePropertyOrientation

    /// Pixel size after applying the EXIF orientation.
    var orientedSize: CGSize {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        switch orientation {
        case .left, .leftMirrored, .right, .rightMirrored: return CGSize(width: h, height: w)
        default: return CGSize(width: w, height: h)
        }
    }

    /// Formats PDF stores well as is (JPEG passes through; the others are lossless anyway).
    private static let directTypes: Set<String> = [
        UTType.jpeg.identifier, UTType.png.identifier, UTType.tiff.identifier, UTType.gif.identifier,
        UTType.bmp.identifier,
    ]

    /// Opens an image file; throws when it has no readable image.
    static func source(for url: URL) throws -> CGImageSource {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0
        else { throw PDFToolsError.unreadableImage(url) }
        return source
    }

    /// How many PDF pages the image makes. Every page of a TIFF (multi-page scans and faxes)
    /// becomes a page. Other formats with several images hold frames of one picture
    /// (animated GIF/PNG/HEIC) or sizes of an icon, so only their first image is used.
    static func pageCount(of source: CGImageSource) -> Int {
        let count = CGImageSourceGetCount(source)
        guard count > 1 else { return min(count, 1) }
        guard let type = CGImageSourceGetType(source) as String?, let uti = UTType(type), uti.conforms(to: .tiff)
        else { return 1 }
        return count
    }

    /// Image `index` of `source` (opened from `url`, named in errors).
    static func load(_ source: CGImageSource, at index: Int, url: URL) throws -> EmbeddableImage {
        guard index < CGImageSourceGetCount(source), let image = CGImageSourceCreateImageAtIndex(source, index, nil)
        else { throw PDFToolsError.unreadableImage(url) }
        let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let raw = (props?[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        let orientation = CGImagePropertyOrientation(rawValue: raw) ?? .up
        let type = CGImageSourceGetType(source) as String? ?? ""
        let opaque = [.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        // HEIC, WebP, AVIF… would be stored as large uncompressed pixels; re-encode opaque ones as JPEG.
        if !directTypes.contains(type), opaque, let jpeg = jpegImage(from: image) {
            return EmbeddableImage(image: jpeg, orientation: orientation)
        }
        return EmbeddableImage(image: image, orientation: orientation)
    }

    private static func jpegImage(from image: CGImage) -> CGImage? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(dest), let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Draws the image upright (EXIF orientation applied) filling `rect`.
    func draw(in rect: CGRect, context ctx: CGContext) {
        let rw = CGFloat(image.width), rh = CGFloat(image.height)
        let oriented = orientedSize
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.minY)
        ctx.scaleBy(x: rect.width / oriented.width, y: rect.height / oriented.height)
        ctx.concatenate(Self.transform(for: orientation, width: rw, height: rh))
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: rw, height: rh))
        ctx.restoreGState()
    }

    /// Maps the stored image (w × h, y up) onto its upright, oriented frame.
    static func transform(for orientation: CGImagePropertyOrientation, width w: CGFloat, height h: CGFloat) -> CGAffineTransform {
        switch orientation {
        case .up: return .identity
        case .upMirrored: return CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)
        case .down: return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case .downMirrored: return CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
        case .leftMirrored: return CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: h, ty: w)
        case .right: return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        case .rightMirrored: return CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case .left: return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        @unknown default: return .identity
        }
    }
}
