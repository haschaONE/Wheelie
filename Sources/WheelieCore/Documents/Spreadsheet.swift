import AppKit

/// A sheet of plain cell strings (CSV, XLSX first-class; others via LibreOffice).
struct Sheet {
    var name: String
    var rows: [[String]]

    var columnCount: Int { rows.map(\.count).max() ?? 0 }

    /// The first row is treated as a header when every cell is non-empty, non-numeric text.
    var hasHeader: Bool {
        guard rows.count > 1, let first = rows.first, !first.isEmpty else { return false }
        return !first.contains { CSV.isNumber($0) || $0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var table: DocTable {
        DocTable(rows: rows.map { $0.map { [DocRun($0)] } }, headerRows: hasHeader ? 1 : 0)
    }
}

enum CSV {
    static func read(_ url: URL) throws -> Sheet {
        guard let data = try? Data(contentsOf: url) else { throw ConversionError.unreadable(url) }
        guard data.count <= 256 * 1024 * 1024 else { throw DocumentError.tooLarge("The spreadsheet is too large to convert.") }
        let text = TextDecoding.decode(data)
        let delimiter: Character = url.pathExtension.lowercased() == "tsv" ? "\t" : detectDelimiter(text)
        let rows = try parse(text, delimiter: delimiter)
        return Sheet(name: url.deletingPathExtension().lastPathComponent, rows: rows)
    }

    /// Picks the delimiter (comma, semicolon, tab, pipe) that splits the first lines most consistently.
    static func detectDelimiter(_ text: String) -> Character {
        let sample = String(text.prefix(16_384))
        let lines = sample.split(whereSeparator: \.isNewline).prefix(10).map(String.init)
        var best: (Character, Int) = (",", 0)
        for candidate: Character in [",", ";", "\t", "|"] {
            let counts = lines.map { line -> Int in
                var inQuotes = false
                var count = 0
                for c in line { if c == "\"" { inQuotes.toggle() } else if c == candidate && !inQuotes { count += 1 } }
                return count
            }
            guard let first = counts.first, first > 0 else { continue }
            let consistent = counts.filter { $0 == first }.count
            let score = consistent * 100 + first
            if score > best.1 { best = (candidate, score) }
        }
        return best.0
    }

    /// RFC 4180: quoted fields, doubled quotes, embedded newlines, CRLF or LF.
    static func parse(_ text: String, delimiter: Character) throws -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var characters = 0
        var iterator = text.makeIterator()
        var pending: Character?
        func next() -> Character? {
            if let p = pending { pending = nil; return p }
            return iterator.next()
        }
        while let c = next() {
            if inQuotes {
                if c == "\"" {
                    if let following = next() {
                        if following == "\"" { field.append("\"") } else { inQuotes = false; pending = following }
                    } else { inQuotes = false }
                } else {
                    field.append(c)
                }
                continue
            }
            switch c {
            case "\"" where field.isEmpty: inQuotes = true
            case delimiter: row.append(field); field = ""
            case "\r\n", "\n", "\r":
                row.append(field); field = ""
                rows.append(row); row = []
            default: field.append(c)
            }
            characters += 1
            if characters > DocumentLimits.maxTextCharacters * 4 { throw DocumentError.tooLarge("The spreadsheet is too large to convert.") }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        guard rows.reduce(0, { $0 + $1.count }) <= DocumentLimits.maxTableCells else {
            throw DocumentError.tooLarge("The spreadsheet has too many cells to convert.")
        }
        return rows
    }

    static func write(_ sheet: Sheet) -> String {
        sheet.rows.map { row in
            row.map { value in
                value.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) || value.hasPrefix(" ") || value.hasSuffix(" ")
                    ? "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : value
            }.joined(separator: ",")
        }.joined(separator: "\r\n") + "\r\n"
    }

    static let numberPattern = try! NSRegularExpression(pattern: #"^-?(0|[1-9]\d*)(\.\d+)?([eE][-+]?\d+)?$"#)

    /// Strict number check (no thousands separators or leading zeros, so ZIP codes stay text).
    static func isNumber(_ value: String) -> Bool {
        guard !value.isEmpty, value.count < 30 else { return false }
        return numberPattern.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }
}

enum XLSX {
    // MARK: Reader

    static func read(_ url: URL) throws -> [Sheet] {
        let zip = try ZipArchive(url: url)
        guard let workbookData = try zip.read("xl/workbook.xml") else { throw DocumentError.malformed("The file is not an Excel workbook.") }
        let workbook = try XML.document(workbookData, what: "The workbook")
        var targets: [String: String] = [:]
        if let rels = try zip.read("xl/_rels/workbook.xml.rels") {
            for rel in try XML.document(rels, what: "The workbook").rootElement()?.children("Relationship") ?? [] {
                if let id = rel.attr("Id"), let target = rel.attr("Target") {
                    targets[id] = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
                }
            }
        }
        let shared = try sharedStrings(zip)
        let dateStyles = try dateStyleIndexes(zip)
        let date1904 = workbook.rootElement()?.child("workbookPr")?.attr("date1904").map { $0 == "1" || $0 == "true" } ?? false

        var sheets: [Sheet] = []
        // Rows are stored densely (empty strings up to each value's column) and every writer pads them
        // to the sheet's widest row, so the limit applies to the used area (rows × widest row), not to
        // the number of <c> elements: one value in column XFD per row would otherwise cost 16,384
        // strings per row from a file of a few bytes per row.
        var finishedArea = 0
        for (index, element) in (workbook.rootElement()?.child("sheets")?.children("sheet") ?? []).enumerated() {
            let name = element.attr("name") ?? "Sheet\(index + 1)"
            let id = element.attribute(forName: "r:id")?.stringValue ?? element.attr("id") ?? ""
            let path = targets[id] ?? "xl/worksheets/sheet\(index + 1).xml"
            guard let data = try zip.read(path) else { continue }
            let doc = try XML.document(data, what: "The worksheet")
            var rows: [[String]] = []
            var widest = 0
            func checkArea(rowCount: Int, columns: Int) throws {
                guard finishedArea + rowCount * max(columns, 1) <= DocumentLimits.maxTableCells else {
                    throw DocumentError.tooLarge("The spreadsheet has too many cells to convert.")
                }
            }
            var nextRow = 0
            for row in doc.rootElement()?.child("sheetData")?.children("row") ?? [] {
                // r is 1-based; a missing or non-positive one means "the next row".
                let rowIndex = row.attr("r").flatMap(Int.init).map { $0 > 0 ? $0 - 1 : nextRow } ?? nextRow
                nextRow = rowIndex + 1
                guard rowIndex < 1_048_576 else { continue }
                var cells: [String] = []
                var nextColumn = 0
                for cell in row.children("c") {
                    let column = cell.attr("r").map(columnIndex) ?? nextColumn
                    nextColumn = column + 1
                    guard column < 16_384 else { continue }
                    // Empty (styled-only) cells add nothing: a later value pads up to its column anyway,
                    // and trailing empties would be trimmed.
                    let text = value(of: cell, shared: shared, dateStyles: dateStyles, date1904: date1904)
                    guard !text.isEmpty else { continue }
                    // Check before materialising anything: padding rows above and padding cells to the left.
                    try checkArea(rowCount: max(rows.count, rowIndex + 1), columns: max(widest, column + 1))
                    while cells.count < column { cells.append("") }
                    cells.append(text)
                }
                // Empty rows are only materialised (as cheap empty arrays) when a later row has content.
                guard !cells.isEmpty else { continue }
                while rows.count < rowIndex { rows.append([]) }
                rows.append(cells)
                widest = max(widest, cells.count)
            }
            while let last = rows.last, last.isEmpty { rows.removeLast() }
            finishedArea += rows.count * max(rows.map(\.count).max() ?? 0, 1)
            sheets.append(Sheet(name: name, rows: rows))
        }
        guard !sheets.isEmpty else { throw DocumentError.malformed("The workbook has no readable sheets.") }
        return sheets
    }

    static func sharedStrings(_ zip: ZipArchive) throws -> [String] {
        guard let data = try zip.read("xl/sharedStrings.xml") else { return [] }
        let doc = try XML.document(data, what: "The workbook")
        return (doc.rootElement()?.children("si") ?? []).map { si in
            if let t = si.child("t") { return t.stringValue ?? "" }
            return si.children("r").compactMap { $0.child("t")?.stringValue }.joined()
        }
    }

    /// cellXfs indexes whose number format is a date/time.
    static func dateStyleIndexes(_ zip: ZipArchive) throws -> Set<Int> {
        guard let data = try zip.read("xl/styles.xml") else { return [] }
        let doc = try XML.document(data, what: "The workbook")
        guard let root = doc.rootElement() else { return [] }
        var customDates = Set<Int>()
        for format in root.child("numFmts")?.children("numFmt") ?? [] {
            guard let id = format.attr("numFmtId").flatMap(Int.init), let code = format.attr("formatCode")?.lowercased() else { continue }
            let stripped = code.replacingOccurrences(of: #"\[[^\]]*\]|"[^"]*""#, with: "", options: .regularExpression)
            if stripped.contains("y") || stripped.contains("d") || (stripped.contains("h") && stripped.contains("m")) { customDates.insert(id) }
        }
        var result = Set<Int>()
        for (index, xf) in (root.child("cellXfs")?.children("xf") ?? []).enumerated() {
            let id = xf.attr("numFmtId").flatMap(Int.init) ?? 0
            if (14...22).contains(id) || (45...47).contains(id) || customDates.contains(id) { result.insert(index) }
        }
        return result
    }

    static func value(of cell: XMLElement, shared: [String], dateStyles: Set<Int>, date1904: Bool) -> String {
        let raw = cell.child("v")?.stringValue ?? ""
        switch cell.attr("t") {
        case "s"?: return Int(raw).flatMap { $0 < shared.count ? shared[$0] : nil } ?? ""
        case "inlineStr"?:
            guard let inline = cell.child("is") else { return "" }
            if let t = inline.child("t") { return t.stringValue ?? "" }
            return inline.children("r").compactMap { $0.child("t")?.stringValue }.joined()
        case "b"?: return raw == "1" ? "TRUE" : "FALSE"
        case "str"?, "e"?: return raw
        default:
            guard let number = Double(raw) else { return raw }
            if let style = cell.attr("s").flatMap(Int.init), dateStyles.contains(style) { return formatDate(number, date1904: date1904) }
            return formatNumber(number)
        }
    }

    static func formatNumber(_ number: Double) -> String {
        if number == number.rounded(), abs(number) < 1e15 { return String(Int64(number)) }
        var text = String(format: "%.15g", number)
        if text.contains("e") { return text }
        while text.contains("."), text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    static func formatDate(_ serial: Double, date1904: Bool) -> String {
        let epoch = date1904 ? -24107.0 : -25569.0 // days from Unix epoch to 1904-01-01 / 1899-12-30
        let date = Date(timeIntervalSince1970: (serial + epoch) * 86_400)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        let hasTime = serial != serial.rounded()
        formatter.dateFormat = serial < 1 ? "HH:mm:ss" : (hasTime ? "yyyy-MM-dd HH:mm:ss" : "yyyy-MM-dd")
        return formatter.string(from: date)
    }

    /// "AB12" → 27 (zero-based column).
    static func columnIndex(_ reference: String) -> Int {
        var index = 0
        for c in reference.uppercased() {
            guard let ascii = c.asciiValue, ascii >= 65, ascii <= 90 else { break }
            // Excel stops at XFD; stop counting long before "ZZZZ…" could overflow.
            guard index <= 1_000_000 else { break }
            index = index * 26 + Int(ascii - 64)
        }
        return max(index - 1, 0)
    }

    static func columnName(_ index: Int) -> String {
        var n = index + 1
        var name = ""
        while n > 0 {
            let r = (n - 1) % 26
            name = String(UnicodeScalar(UInt8(65 + r))) + name
            n = (n - 1) / 26
        }
        return name
    }

    // MARK: Writer

    /// One worksheet per sheet; numbers stay numeric, the header row is bold and frozen.
    static func write(_ sheets: [Sheet], to url: URL) throws {
        let header = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
        let main = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
        let rel = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        var zip = ZipWriter()
        var overrides = ""
        var sheetEntries = ""
        var sheetRels = ""
        var usedNames = Set<String>()
        for (index, sheet) in sheets.enumerated() {
            let n = index + 1
            overrides += "<Override PartName=\"/xl/worksheets/sheet\(n).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
            var name = String(sheet.name.replacingOccurrences(of: #"[\[\]\*\?/\\:]"#, with: " ", options: .regularExpression).prefix(31))
            if name.trimmingCharacters(in: .whitespaces).isEmpty || usedNames.contains(name.lowercased()) { name = "Sheet\(n)" }
            usedNames.insert(name.lowercased())
            sheetEntries += "<sheet name=\"\(xmlEscape(name))\" sheetId=\"\(n)\" r:id=\"rId\(n)\"/>"
            sheetRels += "<Relationship Id=\"rId\(n)\" Type=\"\(rel)/worksheet\" Target=\"worksheets/sheet\(n).xml\"/>"
            zip.add("xl/worksheets/sheet\(n).xml", worksheet(sheet, header: header, main: main))
        }
        let styleRel = sheets.count + 1
        zip.add("[Content_Types].xml", header + """
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
        <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>\
        \(overrides)</Types>
        """)
        zip.add("_rels/.rels", header + """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="\(rel)/officeDocument" Target="xl/workbook.xml"/></Relationships>
        """)
        zip.add("xl/workbook.xml", header + "<workbook xmlns=\"\(main)\" xmlns:r=\"\(rel)\"><sheets>\(sheetEntries)</sheets></workbook>")
        zip.add("xl/_rels/workbook.xml.rels", header + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
                + sheetRels + "<Relationship Id=\"rId\(styleRel)\" Type=\"\(rel)/styles\" Target=\"styles.xml\"/></Relationships>")
        zip.add("xl/styles.xml", header + """
        <styleSheet xmlns="\(main)"><fonts count="2"><font><sz val="11"/><name val="Calibri"/></font>\
        <font><b/><sz val="11"/><name val="Calibri"/></font></fonts>\
        <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>\
        <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>\
        <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>\
        <cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>\
        <xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/></cellXfs>\
        <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>
        """)
        try zip.write(to: url)
    }

    private static func worksheet(_ sheet: Sheet, header: String, main: String) -> String {
        let bold = sheet.hasHeader
        var xml = header + "<worksheet xmlns=\"\(main)\">"
        if bold {
            xml += "<sheetViews><sheetView workbookViewId=\"0\"><pane ySplit=\"1\" topLeftCell=\"A2\" activePane=\"bottomLeft\" state=\"frozen\"/></sheetView></sheetViews>"
        }
        let columns = sheet.columnCount
        if columns > 0 {
            xml += "<cols>"
            for c in 0..<columns {
                let longest = sheet.rows.prefix(500).map { c < $0.count ? $0[c].count : 0 }.max() ?? 8
                xml += "<col min=\"\(c + 1)\" max=\"\(c + 1)\" width=\"\(min(max(longest + 2, 8), 60))\" customWidth=\"1\"/>"
            }
            xml += "</cols>"
        }
        xml += "<sheetData>"
        for (r, row) in sheet.rows.enumerated() {
            xml += "<row r=\"\(r + 1)\">"
            for (c, value) in row.enumerated() where !value.isEmpty {
                let ref = columnName(c) + String(r + 1)
                let style = bold && r == 0 ? " s=\"1\"" : ""
                if CSV.isNumber(value) {
                    xml += "<c r=\"\(ref)\"\(style)><v>\(value)</v></c>"
                } else {
                    xml += "<c r=\"\(ref)\"\(style) t=\"inlineStr\"><is><t xml:space=\"preserve\">\(xmlEscape(value))</t></is></c>"
                }
            }
            xml += "</row>"
        }
        return xml + "</sheetData></worksheet>"
    }
}

/// Draws sheets as paginated grids: header row repeated per page, landscape when wide,
/// cells wrapped to at most three lines.
enum TablePDF {
    static func write(_ sheets: [Sheet], to url: URL, title: String?) throws {
        let portrait = PDFLayout.PageSetup.current
        let fontSize: CGFloat = 8.5
        let font = NSFont(name: "Helvetica Neue", size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)
        let boldFont = NSFont(name: "Helvetica Neue Bold", size: fontSize) ?? NSFont.boldSystemFont(ofSize: fontSize)
        let padding: CGFloat = 3
        let lineHeight = ceil(font.ascender - font.descender + font.leading) + 1
        let maxLines = 3

        // Pick orientation from the widest sheet's natural width.
        let natural = sheets.map { naturalWidths($0, font: font, padding: padding) }
        let widest = natural.map { $0.reduce(0, +) }.max() ?? 0
        var setup = portrait
        if widest > portrait.contentSize.width * 1.05 {
            setup = PDFLayout.PageSetup(size: CGSize(width: portrait.size.height, height: portrait.size.width), margin: 36)
        } else {
            setup.margin = 48
        }
        let content = setup.contentSize

        var mediaBox = CGRect(origin: .zero, size: setup.size)
        var info: [CFString: Any] = [kCGPDFContextCreator: "Wheelie"]
        if let title { info[kCGPDFContextTitle] = title }
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, info as CFDictionary) else { throw ConversionError.writeFailed(url) }
        var pages = 0

        NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
            for (sheetIndex, sheet) in sheets.enumerated() {
                guard sheet.columnCount > 0 else { continue }
                var widths = natural[sheetIndex]
                let total = widths.reduce(0, +)
                if total > content.width {
                    // Shrink wide columns first; never below 28pt.
                    let scale = content.width / total
                    widths = widths.map { max($0 * scale, 28) }
                    let overflow = widths.reduce(0, +) - content.width
                    if overflow > 0 { widths = widths.map { $0 * content.width / (content.width + overflow) } }
                }
                let headerRow = sheet.hasHeader ? sheet.rows.first : nil
                let body = sheet.hasHeader ? Array(sheet.rows.dropFirst()) : sheet.rows
                var y: CGFloat = 0
                var pageOpen = false

                func paragraph(_ text: String, bold: Bool) -> NSAttributedString {
                    let style = NSMutableParagraphStyle()
                    style.lineBreakMode = .byWordWrapping
                    if !bold && CSV.isNumber(text.replacingOccurrences(of: ",", with: "")) { style.alignment = .right }
                    return NSAttributedString(string: text, attributes: [.font: bold ? boldFont : font, .paragraphStyle: style,
                                                                         .foregroundColor: NSColor.black])
                }
                func height(of row: [String], bold: Bool) -> CGFloat {
                    var lines = 1
                    for (c, value) in row.enumerated() where c < widths.count && !value.isEmpty {
                        let available = widths[c] - 2 * padding
                        let estimate = CGFloat(value.count) * fontSize * 0.52
                        if estimate <= available && !value.contains(where: \.isNewline) { continue }
                        let rect = paragraph(value, bold: bold).boundingRect(with: CGSize(width: available, height: .greatestFiniteMagnitude),
                                                                             options: [.usesLineFragmentOrigin])
                        lines = max(lines, min(maxLines, Int(ceil(rect.height / lineHeight - 0.05))))
                    }
                    return CGFloat(lines) * lineHeight + 2 * padding
                }
                func draw(_ row: [String], bold: Bool, rowHeight: CGFloat) {
                    var x = setup.margin
                    let top = setup.margin + y
                    if bold {
                        NSColor(white: 0.92, alpha: 1).setFill()
                        NSRect(x: x, y: top, width: widths.reduce(0, +), height: rowHeight).fill()
                    }
                    for (c, width) in widths.enumerated() {
                        let cell = NSRect(x: x, y: top, width: width, height: rowHeight)
                        NSColor(white: 0.75, alpha: 1).setStroke()
                        let path = NSBezierPath(rect: cell)
                        path.lineWidth = 0.4
                        path.stroke()
                        if c < row.count, !row[c].isEmpty {
                            let textRect = cell.insetBy(dx: padding, dy: padding)
                            NSGraphicsContext.saveGraphicsState()
                            NSBezierPath(rect: textRect).addClip()
                            paragraph(row[c], bold: bold).draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
                            NSGraphicsContext.restoreGraphicsState()
                        }
                        x += width
                    }
                    y += rowHeight
                }
                func beginPage() {
                    context.beginPDFPage(nil)
                    context.saveGState()
                    context.translateBy(x: 0, y: setup.size.height)
                    context.scaleBy(x: 1, y: -1)
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
                    pageOpen = true
                    pages += 1
                    y = 0
                    if sheets.count > 1 {
                        let caption = NSAttributedString(string: sheet.name, attributes: [.font: NSFont(name: "Helvetica Neue Bold", size: 11) ?? boldFont,
                                                                                         .foregroundColor: NSColor.black])
                        caption.draw(at: CGPoint(x: setup.margin, y: setup.margin))
                        y = 20
                    }
                    if let headerRow { draw(headerRow, bold: true, rowHeight: height(of: headerRow, bold: true)) }
                }
                func endPage() {
                    guard pageOpen else { return }
                    NSGraphicsContext.restoreGraphicsState()
                    context.restoreGState()
                    context.endPDFPage()
                    pageOpen = false
                }

                beginPage()
                for row in body {
                    let rowHeight = min(height(of: row, bold: false), content.height / 2)
                    if y + rowHeight > content.height {
                        endPage()
                        if pages >= DocumentLimits.maxPDFPages { break }
                        beginPage()
                    }
                    draw(row, bold: false, rowHeight: rowHeight)
                }
                endPage()
            }
        }
        if pages == 0 { context.beginPDFPage(nil); context.endPDFPage() }
        context.closePDF()
    }

    static func naturalWidths(_ sheet: Sheet, font: NSFont, padding: CGFloat) -> [CGFloat] {
        let columns = sheet.columnCount
        var widths = [CGFloat](repeating: 24, count: columns)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        for row in sheet.rows.prefix(300) {
            for (c, value) in row.enumerated() where !value.isEmpty {
                let longestLine = value.split(whereSeparator: \.isNewline).map(String.init).max { $0.count < $1.count } ?? value
                let width = min((longestLine as NSString).size(withAttributes: attributes).width + 2 * padding + 2, 220)
                widths[c] = max(widths[c], width)
            }
        }
        return widths
    }
}
