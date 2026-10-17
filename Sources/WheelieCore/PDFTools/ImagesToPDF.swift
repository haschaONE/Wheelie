import CoreGraphics
import Foundation
import PDFKit

/// Page layout for turning images into PDF pages. Sizes are in points; images count
/// one pixel per point (72 dpi).
public struct ImagePDFOptions: Equatable, Sendable {
    public enum PageSize: String, CaseIterable, Identifiable, Sendable {
        case fitImage, a4, letter
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .fitImage: return "Fit to Image"
            case .a4: return "A4"
            case .letter: return "US Letter"
            }
        }
        /// Portrait size; nil for `.fitImage`.
        public var portraitSize: CGSize? {
            switch self {
            case .fitImage: return nil
            case .a4: return CGSize(width: 595.2756, height: 841.8898)   // 210 × 297 mm
            case .letter: return CGSize(width: 612, height: 792)          // 8.5 × 11 in
            }
        }
    }

    public enum Orientation: String, CaseIterable, Identifiable, Sendable {
        case automatic, portrait, landscape
        public var id: String { rawValue }
        public var label: String { rawValue.capitalized }
    }

    public enum Fit: String, CaseIterable, Identifiable, Sendable {
        /// Whole image visible, centred.
        case fit
        /// Fills the area inside the margins; the overflow is cropped.
        case fill
        public var id: String { rawValue }
        public var label: String { self == .fit ? "Fit" : "Fill" }
    }

    public enum Margin: String, CaseIterable, Identifiable, Sendable {
        case none, small, medium, large
        public var id: String { rawValue }
        public var label: String { rawValue.capitalized }
        public var points: CGFloat {
            switch self {
            case .none: return 0
            case .small: return 18     // ¼ in
            case .medium: return 36    // ½ in
            case .large: return 72     // 1 in
            }
        }
    }

    public var pageSize: PageSize
    public var orientation: Orientation
    public var margin: Margin
    public var fit: Fit

    public init(pageSize: PageSize = .fitImage, orientation: Orientation = .automatic,
                margin: Margin = .none, fit: Fit = .fit) {
        self.pageSize = pageSize
        self.orientation = orientation
        self.margin = margin
        self.fit = fit
    }

    /// The page for an image of `imageSize` (pixels = points).
    public func pageSize(for imageSize: CGSize) -> CGSize {
        let inset = margin.points * 2
        guard let portrait = pageSize.portraitSize else {
            return CGSize(width: max(1, imageSize.width) + inset, height: max(1, imageSize.height) + inset)
        }
        let landscape: Bool
        switch orientation {
        case .portrait: landscape = false
        case .landscape: landscape = true
        case .automatic: landscape = imageSize.width > imageSize.height
        }
        return landscape ? CGSize(width: portrait.height, height: portrait.width) : portrait
    }

    /// Where the image goes on its page (PDF coordinates, origin bottom-left). With `.fill`
    /// it may extend past the margins; callers clip to `contentRect`.
    public func imageRect(for imageSize: CGSize, on page: CGSize) -> CGRect {
        let content = contentRect(on: page)
        guard pageSize != .fitImage, imageSize.width > 0, imageSize.height > 0 else { return content }
        let sx = content.width / imageSize.width, sy = content.height / imageSize.height
        let scale = fit == .fit ? min(sx, sy) : max(sx, sy)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: content.midX - size.width / 2, y: content.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    /// The page minus margins.
    public func contentRect(on page: CGSize) -> CGRect {
        let m = min(margin.points, page.width / 2 - 1, page.height / 2 - 1)
        return CGRect(x: 0, y: 0, width: page.width, height: page.height).insetBy(dx: max(0, m), dy: max(0, m))
    }
}

/// "Make PDF": several images into one PDF, one page each.
public enum ImagesToPDF {
    /// Writes "<first name>.pdf" (unique) and returns it.
    @discardableResult
    public static func create(_ images: [URL], options: ImagePDFOptions, to destination: URL? = nil) throws -> URL {
        guard let first = images.first else { throw PDFToolsError("Add at least one image.") }
        let output = destination ?? OutputNaming.uniqueURL(for: first, ext: "pdf")
        do {
            try write(images, options: options, to: output)
            guard let check = PDFDocument(url: output), check.pageCount == images.count else {
                throw PDFToolsError("The generated PDF could not be verified.")
            }
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        return output
    }

    /// The PDF as data (used to treat an image as a one-page PDF).
    public static func data(from images: [URL], options: ImagePDFOptions) throws -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data), let ctx = CGContext(consumer: consumer, mediaBox: nil, nil)
        else { throw PDFToolsError("Could not create the PDF.") }
        try draw(images, options: options, into: ctx)
        return data as Data
    }

    static func write(_ images: [URL], options: ImagePDFOptions, to url: URL) throws {
        guard let ctx = CGContext(url as CFURL, mediaBox: nil, nil) else { throw PDFToolsError("Could not create the PDF.") }
        try draw(images, options: options, into: ctx)
    }

    private static func draw(_ images: [URL], options: ImagePDFOptions, into ctx: CGContext) throws {
        defer { ctx.closePDF() }
        for url in images {
            let image = try EmbeddableImage.load(url)
            let size = image.orientedSize
            let page = options.pageSize(for: size)
            let box = CGRect(origin: .zero, size: page)
            ctx.beginPDFPage(PDFPageGeometry.pageInfo(mediaBox: box))
            ctx.saveGState()
            ctx.clip(to: options.contentRect(on: page))
            image.draw(in: options.imageRect(for: size, on: page), context: ctx)
            ctx.restoreGState()
            ctx.endPDFPage()
        }
    }
}
