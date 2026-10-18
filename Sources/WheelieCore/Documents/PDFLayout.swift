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
        TableRows.unwrapOversized(in: storage, contentSize: setup.contentSize)
        // TextKit writes its own PDF link annotation for every .link it draws. Take the links out first and
        // annotate only the ones LinkPolicy allows, so no javascript:/file:/anchor target reaches the PDF.
        var links: [(range: NSRange, url: URL)] = []
        storage.enumerateAttribute(.link, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let url = LinkPolicy.externalURL(value) { links.append((range, url)) }
        }
        storage.removeAttribute(.link, range: NSRange(location: 0, length: storage.length))
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
            // Something taller than a page that TableRows could not unwrap can never fit. Fail loudly
            // instead of looping forever or writing a PDF that silently ends early.
            emptyStreak = range.length == 0 ? emptyStreak + 1 : 0
            if emptyStreak >= 3 {
                throw DocumentError.unsupported("Part of the document is taller than a page and cannot be laid out as a PDF.")
            }
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
                addLinks(links, layout: layout, container: container, glyphs: glyphs, context: context, setup: setup)
                context.endPDFPage()
                drawn += 1
            }
        }
        return drawn
    }

    private static func addLinks(_ links: [(range: NSRange, url: URL)], layout: NSLayoutManager, container: NSTextContainer,
                                 glyphs: NSRange, context: CGContext, setup: PageSetup) {
        let characters = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        for (linkRange, url) in links {
            let range = NSIntersectionRange(linkRange, characters)
            guard range.length > 0 else { continue }
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

/// TextKit 1 cannot split a table row across text containers once anything precedes it on the page:
/// the row is placed on one page and every line past the bottom edge is squashed onto it and never
/// drawn. Layout tables (an HTML body inside one `<td>`) and long Word cells hit this all the time.
/// Rows taller than a page are therefore taken out of their table and laid out as ordinary paragraphs
/// (each cell in turn); the rows around them stay tables.
enum TableRows {
    private struct Cell {
        let block: NSTextTableBlock
        var range: NSRange
    }

    private struct Table {
        let table: NSTextTable
        var rows: [Int: [Cell]] = [:]
    }

    /// Returns the number of rows that were unwrapped.
    @discardableResult
    static func unwrapOversized(in storage: NSTextStorage, contentSize: CGSize) -> Int {
        var total = 0
        // Unwrapping an outer row can expose an oversized row of a nested table: go again.
        for _ in 0..<4 {
            let unwrapped = unwrapOnce(in: storage, contentSize: contentSize)
            total += unwrapped
            if unwrapped == 0 { break }
        }
        return total
    }

    private static func unwrapOnce(in storage: NSTextStorage, contentSize: CGSize) -> Int {
        let full = NSRange(location: 0, length: storage.length)
        var tables: [ObjectIdentifier: Table] = [:]
        var order: [ObjectIdentifier] = []
        storage.enumerateAttribute(.paragraphStyle, in: full) { value, range, _ in
            // The outermost table block owns the paragraph; nested tables are handled on the next pass.
            guard let style = value as? NSParagraphStyle,
                  let block = style.textBlocks.lazy.compactMap({ $0 as? NSTextTableBlock }).first else { return }
            let id = ObjectIdentifier(block.table)
            if tables[id] == nil {
                tables[id] = Table(table: block.table)
                order.append(id)
            }
            var cells = tables[id]?.rows[block.startingRow] ?? []
            if let index = cells.firstIndex(where: { $0.block === block }) {
                cells[index].range = NSUnionRange(cells[index].range, range)
            } else {
                cells.append(Cell(block: block, range: range))
            }
            tables[id]?.rows[block.startingRow] = cells
        }
        guard !tables.isEmpty else { return 0 }

        // Measure every row in one container as wide as the page and endlessly tall, where no row is cut.
        let layout = NSLayoutManager()
        layout.allowsNonContiguousLayout = false
        let container = NSTextContainer(size: CGSize(width: contentSize.width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        defer { storage.removeLayoutManager(layout) }
        layout.ensureLayout(for: container)

        func height(of row: [Cell]) -> CGFloat {
            var rect = CGRect.null
            for cell in row {
                let glyphs = layout.glyphRange(forCharacterRange: cell.range, actualCharacterRange: nil)
                guard glyphs.length > 0 else { continue }
                let bounds = layout.boundsRect(for: cell.block, glyphRange: glyphs)
                if !bounds.isEmpty { rect = rect.union(bounds) }
                layout.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, _, _ in rect = rect.union(fragment) }
            }
            return rect.isNull ? 0 : rect.height
        }

        // Keep a little room for borders.
        let limit = contentSize.height - 4
        // Block → its replacement in the rewritten text: nil drops the block (the row is unwrapped).
        var replacements: [ObjectIdentifier: NSTextTableBlock?] = [:]
        var unwrapped = 0
        for id in order {
            guard let entry = tables[id] else { continue }
            let rowNumbers = entry.rows.keys.sorted()
            let oversized = Set(rowNumbers.filter { height(of: entry.rows[$0] ?? []) > limit })
            guard !oversized.isEmpty else { continue }
            unwrapped += oversized.count
            // Split the table at every oversized row. Each later run of normal rows becomes its own table,
            // numbered from zero, so TextKit never sees one table interrupted by plain paragraphs.
            var segment: (table: NSTextTable, firstRow: Int, endRow: Int)?
            var seenOversized = false
            for (position, r) in rowNumbers.enumerated() {
                let cells = entry.rows[r] ?? []
                if oversized.contains(r) {
                    for cell in cells { replacements[ObjectIdentifier(cell.block)] = .some(nil) }
                    segment = nil
                    seenOversized = true
                    continue
                }
                guard seenOversized else { continue }
                if segment == nil {
                    let end = rowNumbers[position...].first { oversized.contains($0) } ?? Int.max
                    segment = (copy(entry.table), r, end)
                }
                guard let current = segment else { continue }
                for cell in cells {
                    let span = max(1, min(cell.block.rowSpan, current.endRow - r))
                    replacements[ObjectIdentifier(cell.block)] = .some(copy(cell.block, table: current.table,
                                                                            row: r - current.firstRow, rowSpan: span))
                }
            }
        }
        guard !replacements.isEmpty else { return 0 }

        storage.beginEditing()
        storage.enumerateAttribute(.paragraphStyle, in: full) { value, range, _ in
            guard let style = value as? NSParagraphStyle,
                  style.textBlocks.contains(where: { replacements[ObjectIdentifier($0)] != nil }),
                  let mutable = style.mutableCopy() as? NSMutableParagraphStyle else { return }
            mutable.textBlocks = style.textBlocks.compactMap { block in
                guard let replacement = replacements[ObjectIdentifier(block)] else { return block }
                return replacement
            }
            // Cells laid out one after another need a little air between them.
            if mutable.textBlocks.isEmpty, style.paragraphSpacing < 4 { mutable.paragraphSpacing = 4 }
            storage.addAttribute(.paragraphStyle, value: mutable, range: range)
        }
        storage.endEditing()
        return unwrapped
    }

    private static let dimensions: [NSTextBlock.Dimension] = [.width, .minimumWidth, .maximumWidth, .height, .minimumHeight, .maximumHeight]
    private static let layers: [NSTextBlock.Layer] = [.padding, .border, .margin]
    private static let edges: [NSRectEdge] = [.minX, .minY, .maxX, .maxY]

    private static func copyAppearance(from source: NSTextBlock, to target: NSTextBlock) {
        for dimension in dimensions {
            target.setValue(source.value(for: dimension), type: source.valueType(for: dimension), for: dimension)
        }
        for layer in layers {
            for edge in edges {
                target.setWidth(source.width(for: layer, edge: edge), type: source.widthValueType(for: layer, edge: edge),
                                for: layer, edge: edge)
            }
        }
        for edge in edges {
            if let color = source.borderColor(for: edge) { target.setBorderColor(color, for: edge) }
        }
        target.backgroundColor = source.backgroundColor
        target.verticalAlignment = source.verticalAlignment
    }

    private static func copy(_ table: NSTextTable) -> NSTextTable {
        let result = NSTextTable()
        result.numberOfColumns = table.numberOfColumns
        result.layoutAlgorithm = table.layoutAlgorithm
        result.collapsesBorders = table.collapsesBorders
        result.hidesEmptyCells = table.hidesEmptyCells
        copyAppearance(from: table, to: result)
        return result
    }

    private static func copy(_ block: NSTextTableBlock, table: NSTextTable, row: Int, rowSpan: Int) -> NSTextTableBlock {
        let result = NSTextTableBlock(table: table, startingRow: row, rowSpan: rowSpan,
                                      startingColumn: block.startingColumn, columnSpan: block.columnSpan)
        copyAppearance(from: block, to: result)
        return result
    }
}
