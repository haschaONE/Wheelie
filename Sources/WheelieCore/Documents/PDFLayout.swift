import AppKit

/// Paginates an attributed string into a PDF with TextKit 1 (one NSTextContainer per page) drawn into
/// a CGPDFContext. Works off the main thread: no views, no NSPrintOperation.
public enum PDFLayout {
    public struct PageSetup: Sendable {
        public var size: CGSize
        public var margin: CGFloat

        public init(size: CGSize, margin: CGFloat = 72) {
            self.size = size
            self.margin = margin
        }

        public static let a4 = PageSetup(size: CGSize(width: 595.28, height: 841.89))
        public static let letter = PageSetup(size: CGSize(width: 612, height: 792))

        /// US Letter where the region uses it, A4 elsewhere.
        public static var current: PageSetup {
            let letterRegions: Set<String> = ["US", "CA", "MX", "PH", "CL", "CO", "VE", "PR", "GT", "CR", "PA", "DO", "SV", "NI", "HN", "BO"]
            let region = Locale.current.region?.identifier ?? "US"
            return letterRegions.contains(region) ? .letter : .a4
        }

        var contentSize: CGSize { CGSize(width: size.width - 2 * margin, height: size.height - 2 * margin) }
    }

    /// Writes `text` to `url`; "\u{0C}" (form feed) starts a new page. Returns the page count.
    @discardableResult
    public static func write(_ text: NSAttributedString, to url: URL, title: String? = nil,
                             setup: PageSetup = .current) throws -> Int {
        var mediaBox = CGRect(origin: .zero, size: setup.size)
        var info: [CFString: Any] = [kCGPDFContextCreator: "Wheelie"]
        if let title { info[kCGPDFContextTitle] = title }
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, info as CFDictionary) else {
            throw ConversionError.writeFailed(url)
        }
        var pages = 0
        do {
            let sections = split(text)
            for section in sections {
                pages += try render(section, in: context, setup: setup, pagesSoFar: pages)
            }
            if pages == 0 {
                context.beginPDFPage(nil)
                context.endPDFPage()
                pages = 1
            }
            context.closePDF()
        } catch {
            context.closePDF()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return pages
    }

    /// Splits on form-feed paragraphs so each section starts on a fresh page.
    static func split(_ text: NSAttributedString) -> [NSAttributedString] {
        let string = text.string as NSString
        var sections: [NSAttributedString] = []
        var start = 0
        var search = NSRange(location: 0, length: string.length)
        while true {
            let found = string.range(of: AttributedBuilder.pageBreak, options: [], range: search)
            if found.location == NSNotFound { break }
            sections.append(text.attributedSubstring(from: NSRange(location: start, length: found.location - start)))
            var next = NSMaxRange(found)
            if next < string.length, string.character(at: next) == 0x0A { next += 1 }
            start = next
            search = NSRange(location: next, length: string.length - next)
        }
        sections.append(text.attributedSubstring(from: NSRange(location: start, length: string.length - start)))
        return sections.filter { $0.string.trimmingCharacters(in: .whitespacesAndNewlines).count > 0 || $0.containsAttachments }
    }

    private static func render(_ text: NSAttributedString, in context: CGContext, setup: PageSetup, pagesSoFar: Int) throws -> Int {
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        layout.allowsNonContiguousLayout = false
        storage.addLayoutManager(layout)

        var containers: [NSTextContainer] = []
        var emptyStreak = 0
        while true {
            let container = NSTextContainer(size: setup.contentSize)
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            containers.append(container)
            let range = layout.glyphRange(for: container)
            if NSMaxRange(range) >= layout.numberOfGlyphs { break }
            // Something taller than a page (giant table row) can never fit: stop instead of looping.
            emptyStreak = range.length == 0 ? emptyStreak + 1 : 0
            if emptyStreak >= 3 { break }
            if pagesSoFar + containers.count > DocumentLimits.maxPDFPages {
                throw DocumentError.tooLarge("The document has more than \(DocumentLimits.maxPDFPages) pages.")
            }
        }

        let origin = CGPoint(x: setup.margin, y: setup.margin)
        var drawn = 0
        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            for container in containers {
                let glyphs = layout.glyphRange(for: container)
                if glyphs.length == 0 && drawn > 0 { continue }
                context.beginPDFPage(nil)
                context.saveGState()
                context.translateBy(x: 0, y: setup.size.height)
                context.scaleBy(x: 1, y: -1)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
                layout.drawBackground(forGlyphRange: glyphs, at: origin)
                layout.drawGlyphs(forGlyphRange: glyphs, at: origin)
                NSGraphicsContext.restoreGraphicsState()
                context.restoreGState()
                addLinks(layout: layout, container: container, glyphs: glyphs, storage: storage, context: context, setup: setup)
                context.endPDFPage()
                drawn += 1
            }
        }
        return drawn
    }

    private static func addLinks(layout: NSLayoutManager, container: NSTextContainer, glyphs: NSRange,
                                 storage: NSTextStorage, context: CGContext, setup: PageSetup) {
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        storage.enumerateAttribute(.link, in: characters) { value, range, _ in
            let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
            guard let url else { return }
            let linkGlyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            layout.enumerateEnclosingRects(forGlyphRange: linkGlyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                           in: container) { rect, _ in
                let pdfRect = CGRect(x: setup.margin + rect.minX, y: setup.size.height - setup.margin - rect.maxY,
                                     width: rect.width, height: rect.height)
                context.setURL(url as CFURL, for: pdfRect)
            }
        }
    }
}

extension NSAttributedString {
    var containsAttachments: Bool {
        var found = false
        enumerateAttribute(.attachment, in: NSRange(location: 0, length: length)) { value, _, stop in
            if value != nil { found = true; stop.pointee = true }
        }
        return found
    }
}
