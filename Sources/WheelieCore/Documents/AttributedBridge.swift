import AppKit

/// Typography used when Wheelie lays out a document itself (Markdown/DOCX/EPUB/PDF-reflow → PDF/RTF/ODT).
struct DocTheme {
    var bodyFamily = "Helvetica Neue"
    var codeFamily = "Menlo"
    var bodySize: CGFloat = 11
    var headingSizes: [CGFloat] = [22, 17, 14, 12.5, 11.5, 11]
    var contentWidth: CGFloat = 451 // A4 minus 72pt margins
    var contentHeight: CGFloat = 697

    // Fixed colours: documents must not pick up the dark-mode system palette.
    static let ink = NSColor.black
    static let muted = NSColor(white: 0.35, alpha: 1)
    static let linkColor = NSColor(srgbRed: 0, green: 0.33, blue: 0.8, alpha: 1)

    func font(size: CGFloat, bold: Bool = false, italic: Bool = false, code: Bool = false) -> NSFont {
        let base = NSFont(name: code ? codeFamily : bodyFamily, size: size)
            ?? (code ? NSFont.monospacedSystemFont(ofSize: size, weight: .regular) : NSFont.systemFont(ofSize: size))
        var traits: NSFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        guard !traits.isEmpty else { return base }
        let descriptor = base.fontDescriptor.withSymbolicTraits(base.fontDescriptor.symbolicTraits.union(traits))
        return NSFont(descriptor: descriptor, size: size) ?? base
    }
}

/// DocModel → NSAttributedString, with real NSTextLists, NSTextTables and image attachments,
/// so the Cocoa writers (RTF, ODT, DOC) and the PDF paginator get proper structure.
enum AttributedBuilder {
    static let pageBreak = "\u{0C}"

    static func build(_ model: DocModel, theme: DocTheme = DocTheme()) -> NSAttributedString {
        let out = NSMutableAttributedString()
        var counter = ListCounter()
        var imageIndex = 0
        var activeLists: [Int: NSTextList] = [:]

        func paragraphStyle(spacingBefore: CGFloat = 0, after: CGFloat = 6) -> NSMutableParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.paragraphSpacingBefore = spacingBefore
            style.paragraphSpacing = after
            style.lineHeightMultiple = 1.15
            return style
        }

        var previousWasList = false
        for block in model.blocks {
            var isList = false
            if case .paragraph(let p) = block, case .listItem = p.kind { isList = true } else {
                counter.reset()
                activeLists = [:]
            }
            defer { previousWasList = isList }
            switch block {
            case .paragraph(let p):
                let style = paragraphStyle(spacingBefore: previousWasList && !isList ? 6 : 0)
                style.alignment = nsAlignment(p.alignment)
                var size = theme.bodySize
                var bold = false
                var prefix = ""
                var color = DocTheme.ink
                switch p.kind {
                case .heading(let level):
                    size = theme.headingSizes[min(max(level, 1), 6) - 1]
                    bold = true
                    style.paragraphSpacingBefore = level <= 2 ? 14 : 10
                    style.paragraphSpacing = 6
                    style.headerLevel = level
                case .listItem(let ordered, let level):
                    let n = counter.next(level: level, ordered: ordered)
                    activeLists = activeLists.filter { $0.key <= level }
                    if n == 1 { activeLists[level] = nil }
                    let list = activeLists[level] ?? NSTextList(markerFormat: ordered ? NSTextList.MarkerFormat("{decimal}.")
                                                                    : (level % 2 == 1 ? .disc : .circle), options: 0)
                    activeLists[level] = list
                    style.textLists = (1...level).compactMap { activeLists[$0] }
                    let indent = CGFloat(level) * 22
                    style.headIndent = indent
                    style.firstLineHeadIndent = indent - 22
                    style.tabStops = [NSTextTab(textAlignment: .right, location: indent - 6), NSTextTab(textAlignment: .left, location: indent)]
                    style.paragraphSpacing = 3
                    prefix = "\t" + list.marker(forItemNumber: n) + "\t"
                case .quote:
                    style.headIndent = 20
                    style.firstLineHeadIndent = 20
                    color = DocTheme.muted
                case .body:
                    break
                }
                let base: [NSAttributedString.Key: Any] = [.font: theme.font(size: size, bold: bold), .paragraphStyle: style,
                                                           .foregroundColor: color]
                if !prefix.isEmpty { out.append(NSAttributedString(string: prefix, attributes: base)) }
                appendRuns(p.runs, to: out, size: size, bold: bold, base: base, theme: theme)
                out.append(NSAttributedString(string: "\n", attributes: base))

            case .image(let image):
                imageIndex += 1
                let style = paragraphStyle(spacingBefore: 4, after: 8)
                style.alignment = .center
                out.append(attachment(for: image, index: imageIndex, maxWidth: theme.contentWidth, maxHeight: theme.contentHeight - 24,
                                      attributes: [.paragraphStyle: style, .font: theme.font(size: theme.bodySize)]))
                out.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: style, .font: theme.font(size: theme.bodySize)]))

            case .table(let table):
                out.append(spacer(theme))
                out.append(tableString(table, theme: theme))
                out.append(spacer(theme))

            case .code(let code):
                let block = NSTextBlock()
                block.backgroundColor = NSColor(white: 0.95, alpha: 1)
                block.setWidth(6, type: .absoluteValueType, for: .padding)
                block.setValue(100, type: .percentageValueType, for: .width)
                let style = paragraphStyle(after: 8)
                style.textBlocks = [block]
                let attributes: [NSAttributedString.Key: Any] = [.font: theme.font(size: theme.bodySize - 1.5, code: true),
                                                                 .paragraphStyle: style, .foregroundColor: DocTheme.ink]
                // One paragraph per block keeps the background continuous; U+2028 breaks lines inside it.
                let text = code.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\u{2028}")
                out.append(NSAttributedString(string: text + "\n", attributes: attributes))

            case .rule:
                let block = NSTextBlock()
                block.setWidth(0.75, type: .absoluteValueType, for: .border, edge: .maxY)
                block.setBorderColor(NSColor(white: 0.7, alpha: 1), for: .maxY)
                block.setValue(100, type: .percentageValueType, for: .width)
                let style = paragraphStyle(spacingBefore: 4, after: 10)
                style.textBlocks = [block]
                out.append(NSAttributedString(string: "\u{00A0}\n", attributes: [.paragraphStyle: style, .font: theme.font(size: 4)]))

            case .pageBreak:
                out.append(NSAttributedString(string: pageBreak + "\n", attributes: [.font: theme.font(size: theme.bodySize)]))
            }
        }
        return out
    }

    /// A short empty paragraph: TextKit ignores paragraph spacing at table edges.
    private static func spacer(_ theme: DocTheme) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 0
        return NSAttributedString(string: "\n", attributes: [.font: theme.font(size: 5), .paragraphStyle: style])
    }

    private static func appendRuns(_ runs: [DocRun], to out: NSMutableAttributedString, size: CGFloat, bold: Bool,
                                   base: [NSAttributedString.Key: Any], theme: DocTheme) {
        for run in runs.merged() {
            var attributes = base
            let isCode = run.style.contains(.code)
            var runSize = isCode ? size * 0.92 : size
            if run.style.contains(.superscript) || run.style.contains(.subscript) {
                runSize *= 0.75
                attributes[.superscript] = run.style.contains(.superscript) ? 1 : -1
            }
            attributes[.font] = theme.font(size: runSize, bold: bold || run.style.contains(.bold),
                                           italic: run.style.contains(.italic), code: isCode)
            if run.style.contains(.underline) { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if run.style.contains(.strike) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if isCode { attributes[.backgroundColor] = NSColor(white: 0.93, alpha: 1) }
            if let link = run.link, let url = URL(string: link) {
                attributes[.link] = url
                attributes[.foregroundColor] = DocTheme.linkColor
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            // Hard breaks stay inside the paragraph.
            out.append(NSAttributedString(string: run.text.replacingOccurrences(of: "\n", with: "\u{2028}"), attributes: attributes))
        }
    }

    static func attachment(for image: DocImage, index: Int, maxWidth: CGFloat, maxHeight: CGFloat = .greatestFiniteMagnitude,
                           attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let wrapper = FileWrapper(regularFileWithContents: image.data)
        wrapper.preferredFilename = "image\(index).\(image.fileExtension)"
        let attachment = NSTextAttachment(fileWrapper: wrapper)
        let size = image.displaySize(maxWidth: Double(maxWidth), maxHeight: Double(maxHeight))
        if let nsImage = NSImage(data: image.data) {
            nsImage.size = size
            attachment.attachmentCell = NSTextAttachmentCell(imageCell: nsImage)
        }
        attachment.bounds = CGRect(origin: .zero, size: size)
        let result = NSMutableAttributedString(attachment: attachment)
        result.addAttributes(attributes, range: NSRange(location: 0, length: result.length))
        return result
    }

    private static func tableString(_ table: DocTable, theme: DocTheme) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let columns = max(table.columnCount, 1)
        let cellCount = table.rows.count * columns
        // TextKit tables get very slow beyond a few thousand cells: fall back to tab-separated lines.
        if cellCount > 4000 {
            let style = NSMutableParagraphStyle()
            style.tabStops = (1...columns).map { NSTextTab(textAlignment: .left, location: CGFloat($0) * 90) }
            for (r, row) in table.rows.enumerated() {
                let line = row.map { $0.plainText.replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\t")
                out.append(NSAttributedString(string: line + "\n", attributes: [
                    .font: theme.font(size: theme.bodySize - 2, bold: r < table.headerRows), .paragraphStyle: style]))
            }
            return out
        }
        let textTable = NSTextTable()
        textTable.numberOfColumns = columns
        textTable.collapsesBorders = true
        textTable.setContentWidth(100, type: .percentageValueType)
        for (r, row) in table.rows.enumerated() {
            for c in 0..<columns {
                let block = NSTextTableBlock(table: textTable, startingRow: r, rowSpan: 1, startingColumn: c, columnSpan: 1)
                block.setWidth(0.5, type: .absoluteValueType, for: .border)
                block.setBorderColor(NSColor(white: 0.6, alpha: 1))
                block.setWidth(4, type: .absoluteValueType, for: .padding)
                if r < table.headerRows { block.backgroundColor = NSColor(white: 0.94, alpha: 1) }
                let style = NSMutableParagraphStyle()
                style.textBlocks = [block]
                let header = r < table.headerRows
                let base: [NSAttributedString.Key: Any] = [.font: theme.font(size: theme.bodySize - 1, bold: header), .paragraphStyle: style,
                                                           .foregroundColor: DocTheme.ink]
                let runs = c < row.count ? row[c] : []
                if runs.isEmpty {
                    out.append(NSAttributedString(string: "\u{00A0}", attributes: base))
                } else {
                    appendRuns(runs, to: out, size: theme.bodySize - 1, bold: header, base: base, theme: theme)
                }
                out.append(NSAttributedString(string: "\n", attributes: base))
            }
        }
        return out
    }

    static func nsAlignment(_ alignment: DocAlignment) -> NSTextAlignment {
        switch alignment {
        case .natural: return .natural
        case .center: return .center
        case .right: return .right
        case .justified: return .justified
        }
    }
}

/// NSAttributedString (RTF, DOC, ODT, Cocoa-imported HTML, ...) → DocModel, recovering headings from
/// font sizes, lists from NSTextList, tables from NSTextTableBlock and images from attachments.
enum AttributedReader {
    static func read(_ text: NSAttributedString) -> DocModel {
        let string = text.string as NSString
        let bodySize = dominantFontSize(text)
        var blocks: [DocBlock] = []
        var codeLines: [String] = []
        var table: (object: NSTextTable, rows: [Int: [Int: [DocRun]]])?

        func flushCode() {
            if !codeLines.isEmpty { blocks.append(.code(codeLines.joined(separator: "\n"))); codeLines = [] }
        }
        func flushTable() {
            guard let current = table else { return }
            let rowIndexes = current.rows.keys.sorted()
            let rows = rowIndexes.map { r -> [[DocRun]] in
                let cells = current.rows[r] ?? [:]
                let maxColumn = cells.keys.max() ?? -1
                return (0...max(maxColumn, 0)).map { (cells[$0] ?? []).trimmed() }
            }
            let headerRows = rows.first.map { row in row.allSatisfy { cell in cell.isEmpty || cell.allSatisfy { $0.style.contains(.bold) } } } == true && rows.count > 1 ? 1 : 0
            let cleaned = rows.enumerated().map { index, row in
                index < headerRows ? row.map { $0.map { DocRun($0.text, style: $0.style.subtracting(.bold), link: $0.link) } } : row
            }
            blocks.append(.table(DocTable(rows: cleaned, headerRows: headerRows)))
            table = nil
        }

        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: [.byParagraphs, .substringNotRequired]) { _, range, _, _ in
            let paragraphText = string.substring(with: range)
            let style = range.location < text.length
                ? text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle : nil

            // Tables.
            if let cell = style?.textBlocks.compactMap({ $0 as? NSTextTableBlock }).last {
                flushCode()
                if table?.object !== cell.table { flushTable(); table = (cell.table, [:]) }
                var runs = runsIn(text, range: range, bodySize: bodySize, dropBold: false)
                if var existing = table?.rows[cell.startingRow]?[cell.startingColumn] {
                    existing.append(DocRun("\n"))
                    existing += runs
                    runs = existing
                }
                table?.rows[cell.startingRow, default: [:]][cell.startingColumn] = runs
                return
            }
            flushTable()

            if paragraphText.contains(AttributedBuilder.pageBreak) {
                flushCode()
                blocks.append(.pageBreak)
                return
            }
            if range.length == 0 || paragraphText.trimmingCharacters(in: .whitespaces).isEmpty {
                flushCode()
                return
            }

            // Code: every visible character in a fixed-pitch font.
            if isMonospaced(text, range: range) && style?.textLists.isEmpty != false {
                codeLines.append(paragraphText.replacingOccurrences(of: "\u{2028}", with: "\n"))
                return
            }
            flushCode()

            // Split around image attachments.
            var segmentStart = range.location
            var segments: [NSRange] = []
            var images: [(Int, DocImage)] = []
            text.enumerateAttribute(.attachment, in: range) { value, attachmentRange, _ in
                guard let attachment = value as? NSTextAttachment, let image = image(from: attachment) else { return }
                segments.append(NSRange(location: segmentStart, length: attachmentRange.location - segmentStart))
                images.append((segments.count, image))
                segmentStart = NSMaxRange(attachmentRange)
            }
            segments.append(NSRange(location: segmentStart, length: NSMaxRange(range) - segmentStart))

            for (index, segment) in segments.enumerated() {
                if let image = images.first(where: { $0.0 == index })?.1 { blocks.append(.image(image)) }
                guard segment.length > 0 else { continue }
                let segmentText = string.substring(with: segment)
                if segmentText.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\u{FFFC}", with: "").isEmpty { continue }
                var kind = DocParagraph.Kind.body
                var contentRange = segment
                if let lists = style?.textLists, !lists.isEmpty, index == 0 {
                    let ordered = !unorderedFormats.contains(lists.last!.markerFormat)
                    kind = .listItem(ordered: ordered, level: lists.count)
                    // Strip the "\t•\t" marker prefix the text system stores in the string.
                    let prefix = segmentText.range(of: #"^\t?[^\t\n]{0,12}\t"#, options: .regularExpression)
                    if let prefix {
                        let length = NSRange(prefix, in: segmentText).length
                        contentRange = NSRange(location: segment.location + length, length: segment.length - length)
                    }
                } else if let level = headingLevel(text, range: segment, style: style, bodySize: bodySize) {
                    kind = .heading(level)
                }
                var dropBold = false
                if case .heading = kind { dropBold = true }
                let runs = runsIn(text, range: contentRange, bodySize: bodySize, dropBold: dropBold).trimmed()
                guard !runs.isEmpty else { continue }
                var alignment = DocAlignment.natural
                switch style?.alignment {
                case .center?: alignment = .center
                case .right?: alignment = .right
                case .justified?: alignment = .justified
                default: break
                }
                blocks.append(.paragraph(DocParagraph(kind, runs: runs, alignment: alignment)))
            }
        }
        flushCode()
        flushTable()
        return DocModel(blocks: blocks)
    }

    static let unorderedFormats: Set<NSTextList.MarkerFormat> = [.disc, .circle, .square, .hyphen, .check, .box, .diamond]

    /// Most common font size, weighted by characters.
    static func dominantFontSize(_ text: NSAttributedString) -> CGFloat {
        var counts: [CGFloat: Int] = [:]
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if let font = value as? NSFont { counts[(font.pointSize * 2).rounded() / 2, default: 0] += range.length }
        }
        return counts.max { $0.value < $1.value }?.key ?? 12
    }

    static func headingLevel(_ text: NSAttributedString, range: NSRange, style: NSParagraphStyle?, bodySize: CGFloat) -> Int? {
        if let level = style?.headerLevel, level > 0 { return min(level, 6) }
        guard range.length <= 200 else { return nil }
        var maxSize: CGFloat = 0
        var allBold = true
        text.enumerateAttribute(.font, in: range) { value, r, _ in
            guard let font = value as? NSFont else { return }
            let visible = (text.string as NSString).substring(with: r).trimmingCharacters(in: .whitespaces)
            guard !visible.isEmpty else { return }
            maxSize = max(maxSize, font.pointSize)
            if !font.fontDescriptor.symbolicTraits.contains(.bold) { allBold = false }
        }
        let ratio = maxSize / max(bodySize, 1)
        if ratio >= 1.75 { return 1 }
        if ratio >= 1.35 { return 2 }
        if ratio >= 1.15 { return 3 }
        if ratio >= 1.05 && allBold { return 4 }
        return nil
    }

    static func isMonospaced(_ text: NSAttributedString, range: NSRange) -> Bool {
        var mono = true
        var any = false
        text.enumerateAttribute(.font, in: range) { value, r, stop in
            let visible = (text.string as NSString).substring(with: r).trimmingCharacters(in: .whitespaces)
            guard !visible.isEmpty else { return }
            any = true
            if let font = value as? NSFont, font.isFixedPitch || font.fontDescriptor.symbolicTraits.contains(.monoSpace) { return }
            mono = false
            stop.pointee = true
        }
        return any && mono
    }

    static func runsIn(_ text: NSAttributedString, range: NSRange, bodySize: CGFloat, dropBold: Bool) -> [DocRun] {
        var runs: [DocRun] = []
        let string = text.string as NSString
        text.enumerateAttributes(in: range) { attributes, r, _ in
            var chunk = string.substring(with: r)
            chunk = chunk.replacingOccurrences(of: "\u{FFFC}", with: "").replacingOccurrences(of: "\u{2028}", with: "\n")
                .replacingOccurrences(of: "\r", with: "")
            guard !chunk.isEmpty else { return }
            var style: DocStyle = []
            if let font = attributes[.font] as? NSFont {
                let traits = font.fontDescriptor.symbolicTraits
                if traits.contains(.bold) && !dropBold { style.insert(.bold) }
                if traits.contains(.italic) { style.insert(.italic) }
                if font.isFixedPitch || traits.contains(.monoSpace) { style.insert(.code) }
            }
            if let underline = attributes[.underlineStyle] as? Int, underline != 0, attributes[.link] == nil { style.insert(.underline) }
            if let strike = attributes[.strikethroughStyle] as? Int, strike != 0 { style.insert(.strike) }
            let superscript = (attributes[.superscript] as? Int) ?? 0
            let offset = (attributes[.baselineOffset] as? CGFloat) ?? 0
            if superscript > 0 || offset > 1 { style.insert(.superscript) }
            if superscript < 0 || offset < -1 { style.insert(.subscript) }
            var link: String?
            if let url = attributes[.link] as? URL { link = url.absoluteString } else if let s = attributes[.link] as? String { link = s }
            runs.append(DocRun(chunk, style: style, link: link))
        }
        return runs.merged()
    }

    /// Only in-memory data: a symlink/folder wrapper is skipped (asking it for `regularFileContents`
    /// raises, and its cell image may come from a file outside the document).
    static func image(from attachment: NSTextAttachment) -> DocImage? {
        if let wrapper = attachment.fileWrapper {
            guard wrapper.isRegularFile, let data = wrapper.regularFileContents else { return nil }
            return DocImage(data: data)
        }
        if let data = attachment.contents { return DocImage(data: data) }
        if let image = attachment.image ?? (attachment.attachmentCell as? NSTextAttachmentCell)?.image,
           let tiff = image.tiffRepresentation {
            return DocImage(data: tiff)
        }
        return nil
    }
}
