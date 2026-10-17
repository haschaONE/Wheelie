import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Vision

/// A line of recognized text. `box` is normalized to the image (0…1, origin bottom-left).
public struct RecognizedLine: Equatable, Sendable {
    public var text: String
    public var box: CGRect
    public var confidence: Float

    public init(text: String, box: CGRect, confidence: Float = 1) {
        self.text = text
        self.box = box
        self.confidence = confidence
    }
}

/// Vision text recognition (accurate, with language correction).
public enum TextRecognizer {
    /// Language codes Vision can read, e.g. "en-US", "de-DE", "zh-Hans".
    public static func supportedLanguages() -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        return (try? request.supportedRecognitionLanguages()) ?? []
    }

    /// Recognizes text lines. Empty `languages` = detect the language automatically.
    public static func recognize(_ image: CGImage, languages: [String] = []) throws -> [RecognizedLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if languages.isEmpty {
            request.automaticallyDetectsLanguage = true
        } else {
            request.automaticallyDetectsLanguage = false
            request.recognitionLanguages = languages
        }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let best = observation.topCandidates(1).first else { return nil }
            let text = best.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return RecognizedLine(text: text, box: observation.boundingBox, confidence: best.confidence)
        }
    }
}

/// What "Recognize" writes.
public struct TextRecognitionOptions: Equatable, Sendable {
    public enum Output: String, CaseIterable, Identifiable, Sendable {
        case pdf, text, both
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .pdf: return "Searchable PDF"
            case .text: return "Text File"
            case .both: return "Both"
            }
        }
    }

    /// Empty = automatic language detection.
    public var languages: [String]
    public var output: Output
    /// Pages that already have selectable text are kept as they are (no second text layer).
    public var skipPagesWithText: Bool
    /// Render scale for recognition (2 = 144 dpi for PDF pages).
    public var renderScale: CGFloat

    public init(languages: [String] = [], output: Output = .pdf, skipPagesWithText: Bool = true,
                renderScale: CGFloat = 2) {
        self.languages = languages
        self.output = output
        self.skipPagesWithText = skipPagesWithText
        self.renderScale = renderScale
    }
}

/// Makes scanned PDFs and images searchable: each page is drawn as it was, with the
/// recognized text laid over it as invisible text, so it can be selected and searched.
public enum SearchablePDF {
    /// Longest side of the image handed to Vision.
    static let maxRenderPixels: CGFloat = 4096

    /// Recognizes every page of `source` (a PDF or an image) and writes
    /// "<name> searchable.pdf" and/or "<name>.txt". `progress(done, total)` is called
    /// after each page. Throws `CancellationError` when the task is cancelled.
    public static func process(_ source: URL, options: TextRecognitionOptions,
                               progress: (Int, Int) -> Void = { _, _ in }) throws -> [URL] {
        let document = try PDFSourceLoader.document(for: source)
        let total = document.pageCount
        guard total > 0 else { throw PDFToolsError.noPages }
        let isImage = FileKind(url: source) == .image
        let wantsPDF = options.output != .text, wantsText = options.output != .pdf

        var outputs: [URL] = []
        let fm = FileManager.default
        var pdfContext: CGContext?
        if wantsPDF {
            let url = OutputNaming.uniqueURL(for: source, ext: "pdf", suffix: " searchable")
            guard let ctx = CGContext(url as CFURL, mediaBox: nil, nil) else { throw PDFToolsError("Could not create the PDF.") }
            pdfContext = ctx
            outputs.append(url)
        }
        var pageTexts: [String] = []
        var foundText = false
        do {
            progress(0, total)
            for index in 0..<total {
                try Task.checkCancellation()
                let text: String = try autoreleasepool {
                    guard let page = document.page(at: index) else { throw PDFToolsError("Could not read PDF page \(index + 1).") }
                    let existing = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    var lines: [RecognizedLine] = []
                    if !(options.skipPagesWithText && !existing.isEmpty) {
                        lines = try recognize(page, options: options, isImage: isImage)
                    }
                    if let ctx = pdfContext { drawPage(page, lines: lines, into: ctx) }
                    return lines.isEmpty ? existing : lines.map(\.text).joined(separator: "\n")
                }
                if !text.isEmpty { foundText = true }
                pageTexts.append(text)
                progress(index + 1, total)
            }
            pdfContext?.closePDF()
            pdfContext = nil
            guard foundText else {
                throw PDFToolsError("No text was found in “\(source.lastPathComponent)”.")
            }
            if wantsPDF, let url = outputs.first {
                guard let check = PDFDocument(url: url), check.pageCount == total else {
                    throw PDFToolsError("The searchable PDF could not be verified.")
                }
            }
            if wantsText {
                let url = OutputNaming.uniqueURL(for: source, ext: "txt")
                try pageTexts.joined(separator: "\n\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
                outputs.append(url)
            }
        } catch {
            pdfContext?.closePDF()
            outputs.forEach { try? fm.removeItem(at: $0) }
            throw error
        }
        return outputs
    }

    /// Renders the page and runs Vision on it.
    static func recognize(_ page: PDFPage, options: TextRecognitionOptions, isImage: Bool) throws -> [RecognizedLine] {
        let size = PDFPageGeometry.displayedSize(of: page)
        let longest = max(size.width, size.height, 1)
        // Image pages are one pixel per point already; PDF pages get the render scale.
        let wanted = isImage ? 1 : options.renderScale
        let scale = min(wanted, maxRenderPixels / longest)
        do {
            let image = try PDFPageGeometry.render(page, scale: scale)
            return try TextRecognizer.recognize(image, languages: options.languages)
        } catch {
            throw PDFToolsError("Text recognition could not read a scanned PDF page: \(error.localizedDescription)")
        }
    }

    /// Draws the page as displayed (rotation baked in) plus an invisible text layer.
    static func drawPage(_ page: PDFPage, lines: [RecognizedLine], into ctx: CGContext) {
        let size = PDFPageGeometry.displayedSize(of: page)
        let box = CGRect(origin: .zero, size: size)
        ctx.beginPDFPage(PDFPageGeometry.pageInfo(mediaBox: box))
        ctx.saveGState()
        page.draw(with: .cropBox, to: ctx)
        ctx.restoreGState()
        drawInvisibleText(lines, pageSize: size, into: ctx)
        ctx.endPDFPage()
    }

    /// Lays each line over its box: font size from the box height, stretched to the box width.
    public static func drawInvisibleText(_ lines: [RecognizedLine], pageSize: CGSize, into ctx: CGContext) {
        guard !lines.isEmpty else { return }
        let unit = CTFontCreateWithName("Helvetica" as CFString, 1, nil)
        let unitHeight = max(0.5, CTFontGetAscent(unit) + CTFontGetDescent(unit))
        ctx.saveGState()
        ctx.setTextDrawingMode(.invisible)
        for line in lines {
            let rect = CGRect(x: line.box.minX * pageSize.width, y: line.box.minY * pageSize.height,
                              width: line.box.width * pageSize.width, height: line.box.height * pageSize.height)
            guard rect.width > 0, rect.height > 0 else { continue }
            let fontSize = rect.height / unitHeight
            let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
            let attributed = NSAttributedString(string: line.text,
                                                attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            let ctLine = CTLineCreateWithAttributedString(attributed)
            let natural = CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
            guard natural > 0 else { continue }
            ctx.textMatrix = CGAffineTransform(scaleX: rect.width / natural, y: 1)
            ctx.textPosition = CGPoint(x: rect.minX, y: rect.minY + CTFontGetDescent(font))
            CTLineDraw(ctLine, ctx)
        }
        ctx.textMatrix = .identity   // not part of the graphics state
        ctx.restoreGState()
    }
}
