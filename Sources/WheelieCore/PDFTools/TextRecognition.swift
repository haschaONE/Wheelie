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

/// Makes scanned PDFs and images searchable: recognized text is laid over each scanned page
/// as invisible text, so it can be selected and searched.
///
/// The output is the source document with only the recognized pages swapped, so links,
/// bookmarks, form fields and the title/author survive, and pages that get no text layer
/// (they already have text, or nothing was found on them) are written exactly as they were.
public enum SearchablePDF {
    /// Longest side of the image handed to Vision.
    static let maxRenderPixels: CGFloat = 4096

    /// Recognizes every page of `source` (a PDF or an image) and writes
    /// "<name> searchable.pdf" and/or "<name>.txt". `progress(done, total)` is called
    /// after each page. Throws `CancellationError` when the task is cancelled.
    /// The PDF is built in a staging folder and only appears under its name once complete.
    public static func process(_ source: URL, options: TextRecognitionOptions,
                               progress: (Int, Int) -> Void = { _, _ in }) throws -> [URL] {
        let document = try PDFSourceLoader.document(for: source)
        let total = document.pageCount
        guard total > 0 else { throw PDFToolsError.noPages }
        let isImage = FileKind(url: source) == .image
        let wantsPDF = options.output != .text, wantsText = options.output != .pdf

        let pdfName = { OutputNaming.uniqueURL(for: source, ext: "pdf", suffix: " searchable") }
        let staging = wantsPDF ? try StagedOutput(near: pdfName()) : nil

        // Recognized pages as one-page PDFs, kept on disk in the staging folder (not in memory).
        var replacements: [(index: Int, page: PDFDocument)] = []
        var pageTexts: [String] = []
        var foundText = false
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
                if let staging, !lines.isEmpty {
                    let url = staging.file("page \(index + 1).pdf")
                    replacements.append((index, try searchablePage(page, lines: lines, writingTo: url)))
                }
                return lines.isEmpty ? existing : lines.map(\.text).joined(separator: "\n")
            }
            if !text.isEmpty { foundText = true }
            pageTexts.append(text)
            progress(index + 1, total)
        }
        guard foundText else {
            throw PDFToolsError("No text was found in “\(source.lastPathComponent)”.")
        }

        var outputs: [URL] = []
        do {
            if let staging {
                let pages = try replacements.map { item -> (index: Int, page: PDFPage) in
                    guard let page = item.page.page(at: 0) else { throw PDFToolsError("Could not add the text layer to a page.") }
                    return (item.index, page)
                }
                try replacePages(in: document, with: pages)
                let temp = staging.file("searchable.pdf")
                guard document.write(to: temp) else { throw PDFToolsError("PDFKit could not write the searchable PDF.") }
                guard PDFDocument(url: temp)?.pageCount == total else {
                    throw PDFToolsError("The searchable PDF could not be verified.")
                }
                outputs.append(try staging.commit(temp, to: pdfName))
            }
            withExtendedLifetime(replacements) {}
            if wantsText {
                let url = OutputNaming.uniqueURL(for: source, ext: "txt")
                try pageTexts.joined(separator: "\n\n").appending("\n").write(to: url, atomically: true, encoding: .utf8)
                outputs.append(url)
            }
        } catch {
            outputs.forEach { try? FileManager.default.removeItem(at: $0) }
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

    /// A one-page PDF at `url`: the page's own content with the same boxes and rotation (so
    /// its annotations and the bookmarks pointing at it still line up), plus the invisible
    /// text layer.
    static func searchablePage(_ page: PDFPage, lines: [RecognizedLine], writingTo url: URL) throws -> PDFDocument {
        let failed = PDFToolsError("Could not add the text layer to a page.")
        guard let content = page.pageRef, let ctx = CGContext(url as CFURL, mediaBox: nil, nil) else { throw failed }
        let boxes: [(PDFDisplayBox, CFString)] = [(.mediaBox, kCGPDFContextMediaBox), (.cropBox, kCGPDFContextCropBox),
                                                  (.bleedBox, kCGPDFContextBleedBox), (.trimBox, kCGPDFContextTrimBox),
                                                  (.artBox, kCGPDFContextArtBox)]
        var info: [String: Any] = [:]
        for (box, key) in boxes {
            var rect = page.bounds(for: box)
            info[key as String] = Data(bytes: &rect, count: MemoryLayout<CGRect>.size) as CFData
        }
        ctx.beginPDFPage(info as CFDictionary)
        // Only the content stream: annotations (links, form fields…) move over as live objects.
        ctx.drawPDFPage(content)
        ctx.saveGState()
        ctx.concatenate(displayToPage(page))
        drawInvisibleText(lines, pageSize: PDFPageGeometry.displayedSize(of: page), into: ctx)
        ctx.restoreGState()
        ctx.endPDFPage()
        ctx.closePDF()
        guard let doc = PDFDocument(url: url), let result = doc.page(at: 0) else { throw failed }
        for (box, _) in boxes { result.setBounds(page.bounds(for: box), for: box) }
        result.rotation = page.rotation
        return doc
    }

    /// Maps the page as displayed (crop box, rotation applied, origin bottom-left) to the
    /// page's own coordinates. PDF rotation turns the page clockwise for display.
    static func displayToPage(_ page: PDFPage) -> CGAffineTransform {
        let crop = page.bounds(for: .cropBox)
        let w = crop.width, h = crop.height
        let turn: CGAffineTransform
        switch PDFPageGeometry.normalized(page.rotation) {
        case 90: turn = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: w, ty: 0)    // (w - y, x)
        case 180: turn = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)  // (w - x, h - y)
        case 270: turn = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: h)   // (y, h - x)
        default: turn = .identity
        }
        return turn.concatenating(CGAffineTransform(translationX: crop.minX, y: crop.minY))
    }

    /// Swaps pages in place: their annotations move to the new page, and bookmarks and
    /// links that pointed at an old page point at its replacement.
    static func replacePages(in document: PDFDocument, with replacements: [(index: Int, page: PDFPage)]) throws {
        guard !replacements.isEmpty else { return }
        var map: [ObjectIdentifier: PDFPage] = [:]
        var originals: [PDFPage] = []   // keeps the identifiers valid
        for (index, page) in replacements {
            guard let original = document.page(at: index) else { throw PDFToolsError("Could not read PDF page \(index + 1).") }
            map[ObjectIdentifier(original)] = page
            originals.append(original)
        }
        func retarget(_ destination: PDFDestination?) -> PDFDestination? {
            guard let destination, let page = destination.page, let target = map[ObjectIdentifier(page)] else { return nil }
            let moved = PDFDestination(page: target, at: destination.point)
            moved.zoom = destination.zoom
            return moved
        }
        func retarget(_ action: PDFAction?) -> PDFAction? {
            guard let goTo = action as? PDFActionGoTo, let destination = retarget(goTo.destination) else { return nil }
            return PDFActionGoTo(destination: destination)
        }
        func walk(_ item: PDFOutline) {
            if let action = retarget(item.action) {
                item.action = action
            } else if let destination = retarget(item.destination) {
                item.destination = destination
            }
            for child in 0..<item.numberOfChildren { item.child(at: child).map(walk) }
        }
        if let root = document.outlineRoot { walk(root) }
        for index in 0..<document.pageCount {
            for annotation in document.page(at: index)?.annotations ?? [] {
                if let action = retarget(annotation.action) {
                    annotation.action = action
                } else if let destination = retarget(annotation.destination) {
                    annotation.destination = destination
                }
            }
        }
        for (original, (index, page)) in zip(originals, replacements) {
            let moved = original.annotations
            let fieldNames = moved.map(\.fieldName)
            for annotation in moved {
                original.removeAnnotation(annotation)
                page.addAnnotation(annotation)
            }
            document.removePage(at: index)
            document.insert(page, at: index)
            // Removing the old page drops its form fields' names (PDFKit would then write
            // made-up ones like "text2"); put them back so the fields keep their identity.
            for (annotation, name) in zip(moved, fieldNames) where name != nil && annotation.fieldName != name {
                annotation.fieldName = name
            }
        }
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
