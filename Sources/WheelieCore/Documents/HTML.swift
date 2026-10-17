import Foundation

/// HTML / XHTML → DocModel. XHTML (EPUB chapters) is parsed strictly; anything else goes through
/// Foundation's HTML tidy. CSS is ignored except a few inline `style` properties.
enum HTMLReader {
    /// Returns the bytes of a referenced resource (image), or nil. `href` is the raw attribute value.
    typealias Resolver = (_ href: String) -> Data?

    static func read(_ url: URL) throws -> DocModel {
        guard let data = try? Data(contentsOf: url) else { throw ConversionError.unreadable(url) }
        return try parse(decode(data), baseURL: url.deletingLastPathComponent())
    }

    static func parse(_ html: String, baseURL: URL?) throws -> DocModel {
        try parse(html, xhtml: false, resolver: fileResolver(baseURL: baseURL))
    }

    /// `xhtml: true` tries a strict XML parse first (keeps SVG, MathML and EPUB markup intact).
    static func parse(_ source: String, xhtml: Bool, resolver: Resolver?) throws -> DocModel {
        guard source.count <= DocumentLimits.maxTextCharacters else {
            throw DocumentError.tooLarge("The document text exceeds the conversion limit.")
        }
        // Refuses internal DTD subsets / entity declarations anywhere; strips harmless DOCTYPEs.
        let html = try XMLSafety.prepare(source, what: "The HTML document", htmlDoctype: true)
        var document: XMLDocument?
        if xhtml { document = try? XMLDocument(data: Data(html.utf8), options: [.nodeLoadExternalEntitiesNever]) }
        if document == nil {
            document = try? XMLDocument(data: Data(withUTF8Meta(html).utf8), options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever])
        }
        guard let root = document?.rootElement() else { throw DocumentError.malformed("The HTML document is malformed.") }
        var walker = Walker(resolver: resolver)
        let title = root.descendants("title").first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = root.descendants("body").first ?? root
        try walker.walk(body, depth: 0)
        walker.flush()
        return DocModel(title: title?.isEmpty == false ? title : nil, blocks: walker.blocks)
    }

    /// Resolves `<img src>` only to regular files inside the document's folder (see `LocalResource`).
    static func fileResolver(baseURL: URL?) -> Resolver {
        guard let folder = baseURL else { return { _ in nil } }
        return { href in LocalResource.read(href, inside: folder) }
    }

    /// Bytes → String: BOM / BOM-less UTF-16/32 and declared XML encodings first (as a parser would),
    /// then UTF-8, a declared charset, then Windows-1252.
    static func decode(_ data: Data) -> String {
        let b = [UInt8](data.prefix(4))
        if b.starts(with: [0xFE, 0xFF]) || b.starts(with: [0xFF, 0xFE]) || b.starts(with: [0x00, 0x3C]) || b.starts(with: [0x3C, 0x00])
            || b.starts(with: [0x00, 0x00]) || b.starts(with: [0xEF, 0xBB, 0xBF]) || String(decoding: data.prefix(5), as: UTF8.self) == "<?xml",
            let s = try? XMLSafety.decode(data, what: "The HTML document") { return s }
        if let s = String(data: data, encoding: .utf8) { return s }
        let head = String(decoding: data.prefix(2048), as: UTF8.self).lowercased()
        if head.contains("charset=utf-16") || data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
           let s = String(data: data, encoding: .utf16) { return s }
        if head.contains("shift_jis"), let s = String(data: data, encoding: .shiftJIS) { return s }
        return String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
    }

    /// Tidy only decodes UTF-8 when the document says so via http-equiv; replace any charset declaration.
    static func withUTF8Meta(_ html: String) -> String {
        let meta = "<meta http-equiv=\"Content-Type\" content=\"text/html; charset=utf-8\">"
        var text = html.replacingOccurrences(of: #"<meta[^>]*charset[^>]*>"#, with: "", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"<\?xml[^>]*\?>"#, with: "", options: .regularExpression)
        if let head = text.range(of: #"<head(\s[^>]*)?>"#, options: [.regularExpression, .caseInsensitive]) {
            text.insert(contentsOf: meta, at: head.upperBound)
        } else if let html = text.range(of: #"<html(\s[^>]*)?>"#, options: [.regularExpression, .caseInsensitive]) {
            text.insert(contentsOf: "<head>\(meta)</head>", at: html.upperBound)
        } else {
            text = "<html><head>\(meta)</head><body>\(text)</body></html>"
        }
        return text
    }

    struct Walker {
        let resolver: Resolver?
        var blocks: [DocBlock] = []

        private var runs: [DocRun] = []
        private var kind: DocParagraph.Kind = .body
        private var alignment: DocAlignment = .natural
        private var style: DocStyle = []
        private var link: String?
        private var lists: [Bool] = []   // ordered flags, innermost last
        private var quoteDepth = 0
        private var lastWasSpace = true

        init(resolver: Resolver?) { self.resolver = resolver }

        static let skipped: Set<String> = ["head", "script", "style", "noscript", "template", "iframe", "object",
                                           "embed", "video", "audio", "canvas", "select", "button", "input", "textarea", "map"]
        static let blockElements: Set<String> = ["p", "div", "section", "article", "header", "footer", "main", "aside",
                                                 "figure", "figcaption", "address", "center", "nav", "dl", "dt", "dd",
                                                 "details", "summary", "form", "fieldset", "legend", "body", "html", "hgroup", "caption"]
        /// Everything that ends the paragraph in progress.
        static let breaking: Set<String> = blockElements.union(["h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "menu", "li",
                                                                "blockquote", "pre", "hr", "table"])

        mutating func walk(_ node: XMLNode, depth: Int) throws {
            guard depth < DocumentLimits.maxNesting else {
                throw DocumentError.tooLarge("The document is nested too deeply.")
            }
            guard blocks.count < DocumentLimits.maxBlocks else {
                throw DocumentError.tooLarge("The document has too many blocks.")
            }
            if node.kind == .text {
                appendText(node.stringValue ?? "")
                return
            }
            guard let element = node as? XMLElement else {
                for child in node.children ?? [] { try walk(child, depth: depth + 1) }
                return
            }
            let name = element.local.lowercased()
            if Walker.skipped.contains(name) { return }

            // Close the parent's pending paragraph before this block's alignment applies.
            if Walker.breaking.contains(name) { flush() }
            let saved = (style, link, alignment)
            defer { style = saved.0; link = saved.1; alignment = saved.2 }
            applyInlineStyle(element)
            if let align = (element.attr("align") ?? cssValue(element, "text-align"))?.lowercased() {
                switch align {
                case "center": alignment = .center
                case "right": alignment = .right
                case "justify": alignment = .justified
                default: break
                }
            }

            switch name {
            case "h1", "h2", "h3", "h4", "h5", "h6":
                let previous = kind
                flush()
                kind = .heading(Int(String(name.last!)) ?? 1)
                try walkChildren(element, depth)
                flush()
                kind = previous
            case "ul", "ol", "menu":
                flush()
                lists.append(name == "ol")
                try walkChildren(element, depth)
                flush()
                lists.removeLast()
            case "li":
                let previous = kind
                flush()
                kind = .listItem(ordered: lists.last ?? false, level: max(lists.count, 1))
                try walkChildren(element, depth)
                flush()
                kind = previous
            case "blockquote":
                flush()
                quoteDepth += 1
                try walkChildren(element, depth)
                flush()
                quoteDepth -= 1
            case "pre":
                flush()
                let text = element.stringValue ?? ""
                blocks.append(.code(text.hasSuffix("\n") ? String(text.dropLast()) : text))
            case "br":
                runs.append(DocRun("\n", style: style, link: link))
                lastWasSpace = true
            case "hr":
                flush()
                blocks.append(.rule)
            case "img", "image":
                let src = element.attr("src") ?? element.attr("href") ?? ""
                addImage(src: src, alt: element.attr("alt") ?? "", width: element.attr("width"))
            case "svg":
                // Covers are often an <svg> wrapping one <image>; other inline SVG is dropped.
                for image in element.descendants("image") {
                    addImage(src: image.attr("href") ?? "", alt: "", width: nil)
                }
            case "table":
                flush()
                if let table = try readTable(element, depth: depth) { blocks.append(.table(table)) }
            case "a":
                if let href = LinkPolicy.sanitize(element.attr("href")) { link = href }
                try walkChildren(element, depth)
            default:
                if Walker.blockElements.contains(name) {
                    flush()
                    try walkChildren(element, depth)
                    flush()
                } else {
                    try walkChildren(element, depth)
                }
            }
        }

        private mutating func walkChildren(_ element: XMLElement, _ depth: Int) throws {
            for child in element.children ?? [] { try walk(child, depth: depth + 1) }
        }

        private mutating func applyInlineStyle(_ element: XMLElement) {
            switch element.local.lowercased() {
            case "b", "strong": style.insert(.bold)
            case "i", "em", "cite", "var", "dfn": style.insert(.italic)
            case "u", "ins": style.insert(.underline)
            case "s", "strike", "del": style.insert(.strike)
            case "code", "kbd", "samp", "tt": style.insert(.code)
            case "sup": style.insert(.superscript)
            case "sub": style.insert(.subscript)
            default: break
            }
            if let weight = cssValue(element, "font-weight")?.lowercased() {
                if weight == "bold" || weight == "bolder" || (Int(weight) ?? 0) >= 600 { style.insert(.bold) }
                else if weight == "normal" || (Int(weight) ?? 1000) < 600 { style.remove(.bold) }
            }
            if let fontStyle = cssValue(element, "font-style")?.lowercased() {
                if fontStyle == "italic" || fontStyle == "oblique" { style.insert(.italic) } else if fontStyle == "normal" { style.remove(.italic) }
            }
            if let decoration = (cssValue(element, "text-decoration") ?? cssValue(element, "text-decoration-line"))?.lowercased() {
                if decoration.contains("underline") { style.insert(.underline) }
                if decoration.contains("line-through") { style.insert(.strike) }
            }
        }

        private func cssValue(_ element: XMLElement, _ property: String) -> String? {
            guard let css = element.attr("style") else { return nil }
            for declaration in css.split(separator: ";") {
                let parts = declaration.split(separator: ":", maxSplits: 1)
                if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == property {
                    return parts[1].trimmingCharacters(in: .whitespaces)
                }
            }
            return nil
        }

        private mutating func appendText(_ raw: String) {
            // Collapse whitespace like a browser: runs of spaces/newlines become one space.
            var text = ""
            text.reserveCapacity(raw.count)
            for c in raw {
                if c.isWhitespace && c != "\u{00A0}" {
                    if !lastWasSpace { text.append(" "); lastWasSpace = true }
                } else {
                    text.append(c)
                    lastWasSpace = false
                }
            }
            if !text.isEmpty { runs.append(DocRun(text, style: style, link: link)) }
        }

        private mutating func addImage(src: String, alt: String, width: String?) {
            let image: DocImage?
            if src.hasPrefix("data:") {
                image = DataURI.image(src, alt: alt)
            } else {
                image = resolver?(src).flatMap { DocImage(data: $0, alt: alt, displayWidth: width.flatMap { Double($0) }) }
            }
            guard let image else { return }
            let pending = kind
            flush()
            blocks.append(.image(image))
            kind = pending
        }

        private mutating func readTable(_ table: XMLElement, depth: Int) throws -> DocTable? {
            var rows: [[[DocRun]]] = []
            var headerRows = 0
            var sawBody = false
            func collectRows(_ element: XMLElement, header: Bool) throws {
                for child in element.elements {
                    switch child.local.lowercased() {
                    case "thead": try collectRows(child, header: true)
                    case "tbody", "tfoot": sawBody = true; try collectRows(child, header: false)
                    case "tr":
                        var cells: [[DocRun]] = []
                        var allHeader = true
                        for cell in child.elements where ["td", "th"].contains(cell.local.lowercased()) {
                            if cell.local.lowercased() != "th" { allHeader = false }
                            var inner = Walker(resolver: nil)
                            try inner.walk(cell, depth: depth + 1)
                            inner.flush()
                            let text = inner.blocks.compactMap { block -> [DocRun]? in
                                switch block {
                                case .paragraph(let p): return p.runs
                                case .code(let c): return [DocRun(c, style: .code)]
                                default: return nil
                                }
                            }
                            var joined: [DocRun] = []
                            for (i, part) in text.enumerated() {
                                if i > 0 { joined.append(DocRun("\n")) }
                                joined += part
                            }
                            cells.append(joined.trimmed())
                            let span = Int(cell.attr("colspan") ?? "1") ?? 1
                            if span > 1 { cells += Array(repeating: [], count: min(span - 1, 100)) }
                        }
                        if !cells.isEmpty {
                            if (header || (allHeader && rows.count == headerRows && !sawBody)) { headerRows += 1 }
                            rows.append(cells)
                        }
                    default: break
                    }
                }
            }
            try collectRows(table, header: false)
            guard !rows.isEmpty else { return nil }
            guard rows.reduce(0, { $0 + $1.count }) <= DocumentLimits.maxTableCells else {
                throw DocumentError.tooLarge("A document table is too large.")
            }
            return DocTable(rows: rows, headerRows: min(headerRows, 1))
        }

        mutating func flush() {
            let trimmed = runs.trimmed()
            if !trimmed.isEmpty {
                var paragraphKind = kind
                if quoteDepth > 0, paragraphKind == .body { paragraphKind = .quote }
                blocks.append(.paragraph(DocParagraph(paragraphKind, runs: trimmed, alignment: alignment)))
            }
            runs = []
            lastWasSpace = true
        }
    }
}

/// DocModel → standalone HTML5 page with light CSS; images embedded as data URIs.
enum HTMLWriter {
    static func render(_ model: DocModel) -> String {
        var body = ""
        var openLists: [Bool] = []   // ordered flags; each open list has an open <li>
        func closeList() { body += openLists.removeLast() ? "</li></ol>\n" : "</li></ul>\n" }
        for block in model.blocks {
            if case .paragraph(let p) = block, case .listItem(let ordered, let level) = p.kind {
                while openLists.count > level { closeList() }
                if openLists.count == level {
                    if openLists.last == ordered { body += "</li>\n" } else { closeList() }
                }
                var needsItem = false
                while openLists.count < level {
                    if needsItem { body += "<li>" }
                    let isOrdered = openLists.count == level - 1 ? ordered : false
                    body += isOrdered ? "<ol>\n" : "<ul>\n"
                    openLists.append(isOrdered)
                    needsItem = true
                }
                body += "<li>" + inline(p.runs)
                continue
            }
            while !openLists.isEmpty { closeList() }
            switch block {
            case .paragraph(let p):
                let align = alignStyle(p.alignment)
                switch p.kind {
                case .heading(let level): body += "<h\(level)\(align)>\(inline(p.runs))</h\(level)>\n"
                case .quote: body += "<blockquote><p>\(inline(p.runs))</p></blockquote>\n"
                default: body += "<p\(align)>\(inline(p.runs))</p>\n"
                }
            case .image(let image):
                let width = image.displayWidth.map { " width=\"\(Int($0))\"" } ?? ""
                body += "<figure><img src=\"\(DataURI.string(for: image))\" alt=\"\(escape(image.alt))\"\(width)></figure>\n"
            case .table(let table):
                body += "<table>\n"
                for (index, row) in table.rows.enumerated() {
                    let tag = index < table.headerRows ? "th" : "td"
                    body += "<tr>" + row.map { "<\(tag)>\(inline($0))</\(tag)>" }.joined() + "</tr>\n"
                }
                body += "</table>\n"
            case .code(let code):
                body += "<pre><code>\(escape(code))</code></pre>\n"
            case .rule:
                body += "<hr>\n"
            case .pageBreak:
                body += "<div style=\"break-after: page\"></div>\n"
            }
        }
        while !openLists.isEmpty { closeList() }
        let title = escape(model.title ?? "Document")
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(title)</title>
        <style>
        body { font: 16px/1.55 -apple-system, "Helvetica Neue", Helvetica, Arial, sans-serif; max-width: 46em; margin: 2em auto; padding: 0 1em; color: #222; }
        img { max-width: 100%; height: auto; }
        figure { margin: 1em 0; }
        pre { background: #f5f5f5; padding: .8em; overflow-x: auto; }
        code { font-family: ui-monospace, Menlo, monospace; font-size: .92em; }
        blockquote { margin-left: 0; padding-left: 1em; border-left: 3px solid #ccc; color: #555; }
        table { border-collapse: collapse; margin: 1em 0; }
        th, td { border: 1px solid #ccc; padding: .3em .6em; text-align: left; vertical-align: top; }
        th { background: #f3f3f3; }
        @media (prefers-color-scheme: dark) { body { background: #1e1e1e; color: #ddd; } pre, th { background: #2a2a2a; } }
        </style>
        </head>
        <body>
        \(body)</body>
        </html>

        """
    }

    static func alignStyle(_ alignment: DocAlignment) -> String {
        switch alignment {
        case .center: return " style=\"text-align: center\""
        case .right: return " style=\"text-align: right\""
        case .justified: return " style=\"text-align: justify\""
        case .natural: return ""
        }
    }

    static func inline(_ runs: [DocRun]) -> String {
        var out = ""
        for run in runs.merged() {
            var text = escape(run.text).replacingOccurrences(of: "\n", with: "<br>")
            if run.style.contains(.code) { text = "<code>\(text)</code>" }
            if run.style.contains(.superscript) { text = "<sup>\(text)</sup>" }
            if run.style.contains(.subscript) { text = "<sub>\(text)</sub>" }
            if run.style.contains(.strike) { text = "<s>\(text)</s>" }
            if run.style.contains(.underline) { text = "<u>\(text)</u>" }
            if run.style.contains(.italic) { text = "<em>\(text)</em>" }
            if run.style.contains(.bold) { text = "<strong>\(text)</strong>" }
            if let link = run.link { text = "<a href=\"\(escape(link))\">\(text)</a>" }
            out += text
        }
        return out
    }

    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for c in text {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(c)
            }
        }
        return out
    }
}
