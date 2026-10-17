import Foundation

/// Markdown → DocModel, using Foundation's CommonMark/GFM parser for the hard parts
/// (inline emphasis, links, tables, nested lists) and mapping its presentation intents to blocks.
enum MarkdownReader {
    static func read(_ url: URL) throws -> DocModel {
        guard let data = try? Data(contentsOf: url) else { throw ConversionError.unreadable(url) }
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return try parse(text, folder: url.deletingLastPathComponent())
    }

    /// `folder` is where relative image references may be loaded from (see `LocalResource`).
    static func parse(_ source: String, folder: URL? = nil) throws -> DocModel {
        guard source.count <= DocumentLimits.maxTextCharacters else {
            throw DocumentError.tooLarge("The document text exceeds the conversion limit.")
        }
        let (text, title) = stripFrontMatter(source.replacingOccurrences(of: "\r\n", with: "\n"))

        let options = AttributedString.MarkdownParsingOptions(allowsExtendedAttributes: true, interpretedSyntax: .full,
                                                              failurePolicy: .returnPartiallyParsedIfPossible)
        let parsed: AttributedString
        do {
            // No base URL: references stay as written, so the image policy sees the original href.
            parsed = try AttributedString(markdown: text, options: options, baseURL: nil)
        } catch {
            return DocModel.fromPlainText(source)
        }

        var builder = Builder(folder: folder)
        for run in parsed.runs {
            let runText = String(parsed[run.range].characters)
            builder.add(runText, intent: run.presentationIntent, inline: run.inlinePresentationIntent,
                        link: run.link, imageURL: run.imageURL)
        }
        builder.flush()
        var model = DocModel(title: title, blocks: builder.blocks)
        if model.title == nil {
            model.title = model.blocks.lazy.compactMap { block -> String? in
                if case .paragraph(let p) = block, case .heading = p.kind { return p.text } else { return nil }
            }.first
        }
        return model
    }

    /// Removes a leading YAML front-matter block; returns its `title:` if present.
    static func stripFrontMatter(_ text: String) -> (String, String?) {
        guard text.hasPrefix("---\n") else { return (text, nil) }
        let body = text.dropFirst(4)
        guard let end = body.range(of: "\n---\n") ?? body.range(of: "\n...\n") else { return (text, nil) }
        let yaml = body[..<end.lowerBound]
        var title: String?
        for line in yaml.split(separator: "\n") where line.lowercased().hasPrefix("title:") {
            title = line.dropFirst(6).trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return (String(body[end.upperBound...]), title)
    }

    private struct Builder {
        let folder: URL?
        var blocks: [DocBlock] = []

        // Current block being accumulated, keyed by the innermost presentation identity.
        private var currentIdentity: Int?
        private var currentKind: DocParagraph.Kind = .body
        private var runs: [DocRun] = []
        private var codeText: String?
        private var htmlStyle: DocStyle = []

        // Table being accumulated.
        private var tableIdentity: Int?
        private var tableRows: [[[DocRun]]] = []
        private var tableHasHeader = false
        private var rowIdentity: Int?
        private var cellIdentity: Int?

        init(folder: URL?) { self.folder = folder }

        mutating func add(_ text: String, intent: PresentationIntent?, inline: InlinePresentationIntent?,
                          link: URL?, imageURL: URL?) {
            let components = intent?.components ?? []
            let inlineIntent = inline ?? []

            if inlineIntent.contains(.blockHTML) {
                flush()
                if let html = try? HTMLReader.parse(text, baseURL: folder) { blocks += html.blocks }
                return
            }

            // Tables: table > row > cell.
            if let table = components.first(where: { if case .table = $0.kind { return true } else { return false } }) {
                if tableIdentity != table.identity { flush(); tableIdentity = table.identity }
                let row = components.first { c in
                    switch c.kind { case .tableHeaderRow, .tableRow: return true; default: return false }
                }
                let cell = components.first { if case .tableCell = $0.kind { return true } else { return false } }
                if let row, row.identity != rowIdentity {
                    rowIdentity = row.identity
                    if case .tableHeaderRow = row.kind { tableHasHeader = true }
                    tableRows.append([])
                    cellIdentity = nil
                }
                if let cell, cell.identity != cellIdentity, !tableRows.isEmpty {
                    cellIdentity = cell.identity
                    tableRows[tableRows.count - 1].append([])
                }
                if !tableRows.isEmpty, !tableRows[tableRows.count - 1].isEmpty {
                    let r = tableRows.count - 1, c = tableRows[r].count - 1
                    tableRows[r][c] += inlineRuns(text, inline: inlineIntent, link: link)
                }
                return
            }

            guard let innermost = components.first else {
                // Stray text outside any block (rare): collect it as a body paragraph.
                if currentIdentity != nil { flush() }
                runs += inlineRuns(text, inline: inlineIntent, link: link)
                return
            }

            if case .thematicBreak = innermost.kind {
                flush()
                blocks.append(.rule)
                return
            }
            if innermost.identity != currentIdentity {
                flush()
                currentIdentity = innermost.identity
                currentKind = kind(for: components)
                if case .codeBlock = innermost.kind { codeText = "" }
            }
            if codeText != nil {
                codeText! += text
                return
            }
            if let imageURL {
                // Images become their own block, splitting the paragraph around them.
                let pendingKind = currentKind
                flushParagraph()
                if let image = loadImage(imageURL, alt: text) {
                    blocks.append(.image(image))
                } else {
                    runs.append(DocRun(text.isEmpty ? imageURL.lastPathComponent : text, link: imageURL.absoluteString))
                }
                currentKind = pendingKind
                return
            }
            runs += inlineRuns(text, inline: inlineIntent, link: link)
        }

        private func kind(for components: [PresentationIntent.IntentType]) -> DocParagraph.Kind {
            var listDepth = 0
            var ordered = false
            var orderedSet = false
            var quote = false
            var heading: Int?
            for component in components {
                switch component.kind {
                case .header(let level): heading = level
                case .orderedList:
                    listDepth += 1
                    if !orderedSet { ordered = true; orderedSet = true }
                case .unorderedList:
                    listDepth += 1
                    if !orderedSet { ordered = false; orderedSet = true }
                case .blockQuote: quote = true
                default: break
                }
            }
            if let heading { return .heading(min(max(heading, 1), 6)) }
            if listDepth > 0 { return .listItem(ordered: ordered, level: listDepth) }
            if quote { return .quote }
            return .body
        }

        private mutating func inlineRuns(_ text: String, inline: InlinePresentationIntent, link: URL?) -> [DocRun] {
            if inline.contains(.inlineHTML) {
                // Track a few formatting tags; drop the rest of the markup.
                let tag = text.lowercased().replacingOccurrences(of: " ", with: "")
                let map: [(String, DocStyle)] = [("b", .bold), ("strong", .bold), ("i", .italic), ("em", .italic),
                                                 ("u", .underline), ("s", .strike), ("del", .strike), ("code", .code),
                                                 ("sup", .superscript), ("sub", .subscript)]
                for (name, style) in map {
                    if tag == "<\(name)>" { htmlStyle.insert(style); return [] }
                    if tag == "</\(name)>" { htmlStyle.remove(style); return [] }
                }
                if tag.hasPrefix("<br") { return [DocRun("\n")] }
                return []
            }
            if inline.contains(.lineBreak) { return [DocRun("\n")] }
            if inline.contains(.softBreak) { return [DocRun(" ")] }
            var style = htmlStyle
            if inline.contains(.stronglyEmphasized) { style.insert(.bold) }
            if inline.contains(.emphasized) { style.insert(.italic) }
            if inline.contains(.code) { style.insert(.code) }
            if inline.contains(.strikethrough) { style.insert(.strike) }
            return [DocRun(text, style: style, link: link?.absoluteString)]
        }

        private func loadImage(_ url: URL, alt: String) -> DocImage? {
            if url.scheme == "data" { return DataURI.image(url.absoluteString, alt: alt) }
            guard let folder, let data = LocalResource.read(url.relativeString, inside: folder) else { return nil }
            return DocImage(data: data, alt: alt)
        }

        private mutating func flushParagraph() {
            let trimmed = runs.trimmed()
            if !trimmed.isEmpty { blocks.append(.paragraph(DocParagraph(currentKind, runs: trimmed))) }
            runs = []
        }

        mutating func flush() {
            if let code = codeText {
                blocks.append(.code(code.hasSuffix("\n") ? String(code.dropLast()) : code))
                codeText = nil
            } else {
                flushParagraph()
            }
            if tableIdentity != nil {
                if !tableRows.isEmpty {
                    blocks.append(.table(DocTable(rows: tableRows.map { $0.map { $0.trimmed() } }, headerRows: tableHasHeader ? 1 : 0)))
                }
                tableIdentity = nil
                tableRows = []
                tableHasHeader = false
                rowIdentity = nil
                cellIdentity = nil
            }
            currentIdentity = nil
            currentKind = .body
        }
    }
}

/// DocModel → Markdown (CommonMark + GFM tables/strikethrough). Images are embedded as data URIs
/// so the output is a single self-contained file.
enum MarkdownWriter {
    static func render(_ model: DocModel) -> String {
        var parts: [(text: String, tight: Bool)] = []
        var counter = ListCounter()
        for block in model.blocks {
            switch block {
            case .paragraph(let p):
                switch p.kind {
                case .heading(let level):
                    counter.reset()
                    let text = inline(p.runs).replacingOccurrences(of: "\n", with: " ")
                    parts.append((String(repeating: "#", count: level) + " " + text, false))
                case .listItem(let ordered, let level):
                    let n = counter.next(level: level, ordered: ordered)
                    let indent = String(repeating: "    ", count: max(0, level - 1))
                    let marker = ordered ? "\(n). " : "- "
                    let body = inline(p.runs).replacingOccurrences(of: "\n", with: "\n" + indent + "    ")
                    parts.append((indent + marker + body, true))
                case .quote:
                    counter.reset()
                    parts.append((inline(p.runs).split(separator: "\n", omittingEmptySubsequences: false)
                        .map { "> " + $0 }.joined(separator: "\n"), false))
                case .body:
                    counter.reset()
                    parts.append((escapeLineStart(inline(p.runs)), false))
                }
            case .image(let image):
                counter.reset()
                parts.append(("![\(escape(image.alt))](\(DataURI.string(for: image)))", false))
            case .table(let table):
                counter.reset()
                parts.append((renderTable(table), false))
            case .code(let code):
                counter.reset()
                let fence = code.contains("```") ? "~~~~" : "```"
                parts.append((fence + "\n" + code + "\n" + fence, false))
            case .rule:
                counter.reset()
                parts.append(("---", false))
            case .pageBreak:
                counter.reset()
            }
        }
        var out = ""
        var previousTight = false
        for (index, part) in parts.enumerated() {
            if index > 0 { out += part.tight && previousTight ? "\n" : "\n\n" }
            out += part.text
            previousTight = part.tight
        }
        return out + "\n"
    }

    static func renderTable(_ table: DocTable) -> String {
        let columns = max(table.columnCount, 1)
        func row(_ cells: [[DocRun]]) -> String {
            let texts = (0..<columns).map { i -> String in
                guard i < cells.count else { return "" }
                return inline(cells[i]).replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: "<br>")
            }
            return "| " + texts.joined(separator: " | ") + " |"
        }
        var lines: [String] = []
        let header = table.headerRows > 0 ? table.rows[0] : Array(repeating: [DocRun](), count: columns)
        lines.append(row(header))
        lines.append("|" + String(repeating: " --- |", count: columns))
        for r in table.rows.dropFirst(table.headerRows > 0 ? 1 : 0) { lines.append(row(r)) }
        return lines.joined(separator: "\n")
    }

    /// Inline Markdown for runs; whitespace is moved outside emphasis markers so they stay valid.
    static func inline(_ runs: [DocRun]) -> String {
        var out = ""
        for run in runs.merged() {
            if run.text == "\n" { out += "\\\n"; continue }
            var core = run.text
            var leading = "", trailing = ""
            while let c = core.first, c == " " || c == "\t" { leading.append(c); core.removeFirst() }
            while let c = core.last, c == " " || c == "\t" { trailing.insert(c, at: trailing.startIndex); core.removeLast() }
            if core.isEmpty { out += run.text; continue }

            var text: String
            if run.style.contains(.code) {
                let ticks = core.contains("`") ? "``" : "`"
                text = ticks + (core.hasPrefix("`") ? " " : "") + core + (core.hasSuffix("`") ? " " : "") + ticks
            } else {
                text = escape(core).replacingOccurrences(of: "\n", with: "\\\n")
                if run.style.contains(.superscript) { text = "<sup>\(text)</sup>" }
                if run.style.contains(.subscript) { text = "<sub>\(text)</sub>" }
                if run.style.contains(.strike) { text = "~~\(text)~~" }
                if run.style.contains(.italic) { text = "*\(text)*" }
                if run.style.contains(.bold) { text = "**\(text)**" }
            }
            if let link = run.link { text = "[\(text)](\(link.replacingOccurrences(of: " ", with: "%20").replacingOccurrences(of: ")", with: "%29")))" }
            out += leading + text + trailing
        }
        return out
    }

    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for c in text {
            switch c {
            case "\\", "*", "_", "`", "[", "]", "<", ">", "|", "~": out.append("\\"); out.append(c)
            default: out.append(c)
            }
        }
        return out
    }

    /// Escapes characters that would turn a body paragraph into a heading, list or quote.
    static func escapeLineStart(_ text: String) -> String {
        guard let first = text.first else { return text }
        if "#+-=".contains(first) { return "\\" + text }
        if let match = text.range(of: #"^\d+[.)]"#, options: .regularExpression) {
            let marker = text[match]
            return marker.dropLast() + "\\" + String(marker.last!) + text[match.upperBound...]
        }
        return text
    }
}

enum DataURI {
    static func string(for image: DocImage) -> String {
        "data:\(image.mimeType);base64,\(image.data.base64EncodedString())"
    }

    static func image(_ uri: String, alt: String = "") -> DocImage? {
        guard uri.hasPrefix("data:"), let comma = uri.firstIndex(of: ",") else { return nil }
        let header = uri[uri.index(uri.startIndex, offsetBy: 5)..<comma]
        let payload = String(uri[uri.index(after: comma)...])
        let data: Data?
        if header.hasSuffix(";base64") {
            data = Data(base64Encoded: payload.removingPercentEncoding ?? payload, options: .ignoreUnknownCharacters)
        } else {
            data = (payload.removingPercentEncoding ?? payload).data(using: .utf8)
        }
        return data.flatMap { DocImage(data: $0, alt: alt) }
    }
}
