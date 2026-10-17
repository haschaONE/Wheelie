import Foundation

/// DocModel → DOCX (WordprocessingML) with real Word styles (Title/Heading 1–6, Quote, Code),
/// numbered/bulleted lists, hyperlinks, tables and inline images.
enum DocxWriter {
    static func write(_ model: DocModel, to url: URL, setup: PDFLayout.PageSetup = .current) throws {
        try data(model, setup: setup).write(to: url, options: .atomic)
    }

    static func data(_ model: DocModel, setup: PDFLayout.PageSetup = .current) throws -> Data {
        var state = State(contentWidth: Double(setup.contentSize.width), contentHeight: Double(setup.contentSize.height))
        var body = ""
        var listRun: (numId: Int, topOrdered: Bool?)?

        for (index, block) in model.blocks.enumerated() {
            if case .paragraph(let p) = block, case .listItem = p.kind {} else { listRun = nil }
            // A top-level item of the other type (bullets → numbers) starts a new Word list.
            if case .paragraph(let p) = block, case .listItem(let ordered, 1) = p.kind,
               let run = listRun, let top = run.topOrdered, top != ordered { listRun = nil }
            switch block {
            case .paragraph(let p):
                var properties = ""
                switch p.kind {
                case .heading(let level): properties += "<w:pStyle w:val=\"Heading\(min(max(level, 1), 6))\"/>"
                case .quote: properties += "<w:pStyle w:val=\"Quote\"/>"
                case .listItem(_, let level):
                    if listRun == nil { listRun = state.newList(from: model.blocks, start: index) }
                    properties += "<w:pStyle w:val=\"ListParagraph\"/><w:numPr><w:ilvl w:val=\"\(min(level, 9) - 1)\"/><w:numId w:val=\"\(listRun!.numId)\"/></w:numPr>"
                case .body: break
                }
                properties += justification(p.alignment)
                body += "<w:p>" + (properties.isEmpty ? "" : "<w:pPr>\(properties)</w:pPr>") + state.runs(p.runs) + "</w:p>"
            case .image(let image):
                body += "<w:p><w:pPr><w:jc w:val=\"center\"/></w:pPr><w:r>\(state.drawing(image))</w:r></w:p>"
            case .table(let table):
                body += state.table(table)
            case .code(let code):
                let lines = code.components(separatedBy: "\n")
                let runs = lines.enumerated().map { i, line in
                    (i > 0 ? "<w:r><w:br/></w:r>" : "") + "<w:r><w:t xml:space=\"preserve\">\(xmlEscape(line))</w:t></w:r>"
                }.joined()
                body += "<w:p><w:pPr><w:pStyle w:val=\"Code\"/></w:pPr>\(runs)</w:p>"
            case .rule:
                body += "<w:p><w:pPr><w:pBdr><w:bottom w:val=\"single\" w:sz=\"6\" w:space=\"1\" w:color=\"A0A0A0\"/></w:pBdr></w:pPr></w:p>"
            case .pageBreak:
                body += "<w:p><w:r><w:br w:type=\"page\"/></w:r></w:p>"
            }
        }
        if case .table? = model.blocks.last { body += "<w:p/>" }

        let twips = { (points: CGFloat) in Int((points * 20).rounded()) }
        let sectPr = "<w:sectPr><w:pgSz w:w=\"\(twips(setup.size.width))\" w:h=\"\(twips(setup.size.height))\"/>"
            + "<w:pgMar w:top=\"\(twips(setup.margin))\" w:right=\"\(twips(setup.margin))\" w:bottom=\"\(twips(setup.margin))\" "
            + "w:left=\"\(twips(setup.margin))\" w:header=\"708\" w:footer=\"708\" w:gutter=\"0\"/></w:sectPr>"
        let document = xmlHeader + "<w:document \(namespaces)><w:body>\(body)\(sectPr)</w:body></w:document>"

        var zip = ZipWriter()
        zip.add("[Content_Types].xml", contentTypes(state))
        zip.add("_rels/.rels", xmlHeader + """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>\
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>\
        <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>\
        </Relationships>
        """)
        zip.add("word/document.xml", document)
        zip.add("word/_rels/document.xml.rels", relationships(state))
        zip.add("word/styles.xml", styles)
        zip.add("word/numbering.xml", numbering(state))
        zip.add("word/settings.xml", xmlHeader + "<w:settings xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:defaultTabStop w:val=\"720\"/><w:compat><w:compatSetting w:name=\"compatibilityMode\" w:uri=\"http://schemas.microsoft.com/office/word\" w:val=\"15\"/></w:compat></w:settings>")
        let now = ISO8601DateFormatter().string(from: Date())
        zip.add("docProps/core.xml", xmlHeader + """
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" \
        xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" \
        xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><dc:title>\(xmlEscape(model.title ?? ""))</dc:title>\
        <dc:creator>Wheelie</dc:creator><dcterms:created xsi:type="dcterms:W3CDTF">\(now)</dcterms:created>\
        <dcterms:modified xsi:type="dcterms:W3CDTF">\(now)</dcterms:modified></cp:coreProperties>
        """)
        zip.add("docProps/app.xml", xmlHeader + "<Properties xmlns=\"http://schemas.openxmlformats.org/officeDocument/2006/extended-properties\"><Application>Wheelie</Application></Properties>")
        for (index, image) in state.images.enumerated() {
            zip.add("word/media/image\(index + 1).\(image.fileExtension)", image.data, compress: false)
        }
        return zip.data()
    }

    // MARK: State

    struct State {
        let contentWidth: Double
        let contentHeight: Double
        var images: [DocImage] = []
        var links: [String] = []
        var linkIDs: [String: Int] = [:]
        /// Per list: level → ordered flag.
        var lists: [[Int: Bool]] = []

        init(contentWidth: Double, contentHeight: Double) {
            self.contentWidth = contentWidth
            self.contentHeight = contentHeight
        }

        mutating func newList(from blocks: [DocBlock], start: Int) -> (numId: Int, topOrdered: Bool?) {
            var levels: [Int: Bool] = [:]
            for block in blocks[start...] {
                guard case .paragraph(let p) = block, case .listItem(let ordered, let level) = p.kind else { break }
                if level == 1, let top = levels[1], top != ordered { break }
                if levels[level] == nil { levels[level] = ordered }
            }
            lists.append(levels)
            return (lists.count, levels[1])
        }

        mutating func linkID(_ url: String) -> String {
            if let id = linkIDs[url] { return "rIdLink\(id)" }
            links.append(url)
            linkIDs[url] = links.count
            return "rIdLink\(links.count)"
        }

        mutating func runs(_ runs: [DocRun]) -> String {
            var xml = ""
            for run in runs.merged() {
                let content = runXML(run)
                if let link = run.link, URL(string: link)?.scheme != nil {
                    xml += "<w:hyperlink r:id=\"\(linkID(link))\" w:history=\"1\">\(content)</w:hyperlink>"
                } else {
                    xml += content
                }
            }
            return xml
        }

        private func runXML(_ run: DocRun) -> String {
            var properties = ""
            if run.link != nil { properties += "<w:rStyle w:val=\"Hyperlink\"/>" }
            if run.style.contains(.code) { properties += "<w:rFonts w:ascii=\"Consolas\" w:hAnsi=\"Consolas\" w:cs=\"Consolas\"/>" }
            if run.style.contains(.bold) { properties += "<w:b/><w:bCs/>" }
            if run.style.contains(.italic) { properties += "<w:i/><w:iCs/>" }
            if run.style.contains(.strike) { properties += "<w:strike/>" }
            if run.style.contains(.underline) { properties += "<w:u w:val=\"single\"/>" }
            if run.style.contains(.superscript) { properties += "<w:vertAlign w:val=\"superscript\"/>" }
            else if run.style.contains(.subscript) { properties += "<w:vertAlign w:val=\"subscript\"/>" }
            let rPr = properties.isEmpty ? "" : "<w:rPr>\(properties)</w:rPr>"
            var content = ""
            var buffer = ""
            func flushText() {
                if !buffer.isEmpty { content += "<w:t xml:space=\"preserve\">\(xmlEscape(buffer))</w:t>"; buffer = "" }
            }
            for c in run.text {
                switch c {
                case "\n", "\u{2028}": flushText(); content += "<w:br/>"
                case "\t": flushText(); content += "<w:tab/>"
                default: buffer.append(c)
                }
            }
            flushText()
            return "<w:r>\(rPr)\(content)</w:r>"
        }

        mutating func drawing(_ image: DocImage) -> String {
            images.append(image)
            let n = images.count
            let size = image.displaySize(maxWidth: contentWidth, maxHeight: contentHeight - 24)
            let cx = Int(size.width * 12700), cy = Int(size.height * 12700)
            let alt = xmlEscape(image.alt)
            return """
            <w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="\(cx)" cy="\(cy)"/>\
            <wp:docPr id="\(n)" name="Picture \(n)" descr="\(alt)"/><wp:cNvGraphicFramePr>\
            <a:graphicFrameLocks xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" noChangeAspect="1"/></wp:cNvGraphicFramePr>\
            <a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">\
            <a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">\
            <pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">\
            <pic:nvPicPr><pic:cNvPr id="\(n)" name="image\(n).\(image.fileExtension)" descr="\(alt)"/><pic:cNvPicPr/></pic:nvPicPr>\
            <pic:blipFill><a:blip r:embed="rIdImg\(n)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>\
            <pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>\
            </pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing>
            """
        }

        mutating func table(_ table: DocTable) -> String {
            let columns = max(table.columnCount, 1)
            let totalTwips = Int(contentWidth * 20)
            let columnWidth = totalTwips / columns
            var xml = "<w:tbl><w:tblPr><w:tblStyle w:val=\"TableGrid\"/><w:tblW w:w=\"5000\" w:type=\"pct\"/>"
                + "<w:tblLook w:val=\"04A0\" w:firstRow=\"1\" w:lastRow=\"0\" w:firstColumn=\"0\" w:lastColumn=\"0\" w:noHBand=\"0\" w:noVBand=\"1\"/></w:tblPr><w:tblGrid>"
            xml += String(repeating: "<w:gridCol w:w=\"\(columnWidth)\"/>", count: columns) + "</w:tblGrid>"
            for (r, row) in table.rows.enumerated() {
                let header = r < table.headerRows
                xml += "<w:tr>" + (header ? "<w:trPr><w:tblHeader/></w:trPr>" : "")
                for c in 0..<columns {
                    var cellRuns = c < row.count ? row[c] : []
                    if header { cellRuns = cellRuns.map { DocRun($0.text, style: $0.style.union(.bold), link: $0.link) } }
                    xml += "<w:tc><w:tcPr><w:tcW w:w=\"\(columnWidth)\" w:type=\"dxa\"/></w:tcPr><w:p>\(runs(cellRuns))</w:p></w:tc>"
                }
                xml += "</w:tr>"
            }
            return xml + "</w:tbl>"
        }
    }

    // MARK: Parts

    static let xmlHeader = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
    static let namespaces = """
    xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" \
    xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
    xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" \
    xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
    xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"
    """

    static func justification(_ alignment: DocAlignment) -> String {
        switch alignment {
        case .center: return "<w:jc w:val=\"center\"/>"
        case .right: return "<w:jc w:val=\"right\"/>"
        case .justified: return "<w:jc w:val=\"both\"/>"
        case .natural: return ""
        }
    }

    static func contentTypes(_ state: State) -> String {
        xmlHeader + """
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Default Extension="png" ContentType="image/png"/>\
        <Default Extension="jpg" ContentType="image/jpeg"/>\
        <Default Extension="gif" ContentType="image/gif"/>\
        <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\
        <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>\
        <Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>\
        <Override PartName="/word/settings.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml"/>\
        <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>\
        <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>\
        </Types>
        """
    }

    static func relationships(_ state: State) -> String {
        var xml = xmlHeader + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
        let base = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"
        xml += "<Relationship Id=\"rIdStyles\" Type=\"\(base)styles\" Target=\"styles.xml\"/>"
        xml += "<Relationship Id=\"rIdNumbering\" Type=\"\(base)numbering\" Target=\"numbering.xml\"/>"
        xml += "<Relationship Id=\"rIdSettings\" Type=\"\(base)settings\" Target=\"settings.xml\"/>"
        for (index, image) in state.images.enumerated() {
            xml += "<Relationship Id=\"rIdImg\(index + 1)\" Type=\"\(base)image\" Target=\"media/image\(index + 1).\(image.fileExtension)\"/>"
        }
        for (index, link) in state.links.enumerated() {
            xml += "<Relationship Id=\"rIdLink\(index + 1)\" Type=\"\(base)hyperlink\" Target=\"\(xmlEscape(link))\" TargetMode=\"External\"/>"
        }
        return xml + "</Relationships>"
    }

    static func numbering(_ state: State) -> String {
        var xml = xmlHeader + "<w:numbering xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">"
        let bullets = ["\u{2022}", "\u{25E6}", "\u{25AA}"]
        let orderedFormats = ["decimal", "lowerLetter", "lowerRoman"]
        for (index, levels) in state.lists.enumerated() {
            xml += "<w:abstractNum w:abstractNumId=\"\(index)\"><w:multiLevelType w:val=\"hybridMultilevel\"/>"
            for ilvl in 0..<9 {
                let ordered = levels[ilvl + 1] ?? levels.sorted { $0.key < $1.key }.last(where: { $0.key <= ilvl + 1 })?.value ?? false
                let indent = 720 * (ilvl + 1)
                if ordered {
                    xml += "<w:lvl w:ilvl=\"\(ilvl)\"><w:start w:val=\"1\"/><w:numFmt w:val=\"\(orderedFormats[ilvl % 3])\"/>"
                        + "<w:lvlText w:val=\"%\(ilvl + 1).\"/><w:lvlJc w:val=\"left\"/><w:pPr><w:ind w:left=\"\(indent)\" w:hanging=\"360\"/></w:pPr></w:lvl>"
                } else {
                    xml += "<w:lvl w:ilvl=\"\(ilvl)\"><w:start w:val=\"1\"/><w:numFmt w:val=\"bullet\"/>"
                        + "<w:lvlText w:val=\"\(bullets[ilvl % 3])\"/><w:lvlJc w:val=\"left\"/><w:pPr><w:ind w:left=\"\(indent)\" w:hanging=\"360\"/></w:pPr>"
                        + "<w:rPr><w:rFonts w:ascii=\"Arial\" w:hAnsi=\"Arial\" w:hint=\"default\"/></w:rPr></w:lvl>"
                }
            }
            xml += "</w:abstractNum>"
        }
        for index in state.lists.indices {
            xml += "<w:num w:numId=\"\(index + 1)\"><w:abstractNumId w:val=\"\(index)\"/></w:num>"
        }
        return xml + "</w:numbering>"
    }

    static let styles: String = {
        let headingSizes = [32, 26, 24, 22, 22, 21]
        var headings = ""
        for level in 1...6 {
            headings += """
            <w:style w:type="paragraph" w:styleId="Heading\(level)"><w:name w:val="heading \(level)"/><w:basedOn w:val="Normal"/>\
            <w:next w:val="Normal"/><w:uiPriority w:val="9"/><w:qFormat/><w:pPr><w:keepNext/><w:keepLines/>\
            <w:spacing w:before="\(level <= 2 ? 360 : 240)" w:after="80"/><w:outlineLvl w:val="\(level - 1)"/></w:pPr>\
            <w:rPr><w:b/><w:bCs/>\(level >= 5 ? "<w:i/>" : "")<w:color w:val="1F3864"/><w:sz w:val="\(headingSizes[level - 1])"/><w:szCs w:val="\(headingSizes[level - 1])"/></w:rPr></w:style>
            """
        }
        return xmlHeader + """
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\
        <w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:eastAsia="Calibri" w:cs="Calibri"/>\
        <w:sz w:val="22"/><w:szCs w:val="22"/><w:lang w:val="en-US"/></w:rPr></w:rPrDefault>\
        <w:pPrDefault><w:pPr><w:spacing w:after="160" w:line="264" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>\
        <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>\
        <w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/>\
        <w:pPr><w:spacing w:after="240"/></w:pPr><w:rPr><w:sz w:val="52"/><w:szCs w:val="52"/></w:rPr></w:style>\
        \(headings)\
        <w:style w:type="paragraph" w:styleId="Quote"><w:name w:val="Quote"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/>\
        <w:pPr><w:ind w:left="720" w:right="720"/></w:pPr><w:rPr><w:i/><w:iCs/><w:color w:val="595959"/></w:rPr></w:style>\
        <w:style w:type="paragraph" w:styleId="Code"><w:name w:val="Code"/><w:basedOn w:val="Normal"/><w:qFormat/>\
        <w:pPr><w:shd w:val="clear" w:color="auto" w:fill="F2F2F2"/><w:spacing w:after="160" w:line="240" w:lineRule="auto"/></w:pPr>\
        <w:rPr><w:rFonts w:ascii="Consolas" w:hAnsi="Consolas" w:cs="Consolas"/><w:sz w:val="19"/><w:szCs w:val="19"/></w:rPr></w:style>\
        <w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="List Paragraph"/><w:basedOn w:val="Normal"/><w:qFormat/>\
        <w:pPr><w:spacing w:after="60"/><w:ind w:left="720"/><w:contextualSpacing/></w:pPr></w:style>\
        <w:style w:type="character" w:default="1" w:styleId="DefaultParagraphFont"><w:name w:val="Default Paragraph Font"/><w:uiPriority w:val="1"/><w:semiHidden/></w:style>\
        <w:style w:type="character" w:styleId="Hyperlink"><w:name w:val="Hyperlink"/><w:basedOn w:val="DefaultParagraphFont"/>\
        <w:rPr><w:color w:val="0563C1"/><w:u w:val="single"/></w:rPr></w:style>\
        <w:style w:type="table" w:default="1" w:styleId="TableNormal"><w:name w:val="Normal Table"/><w:semiHidden/>\
        <w:tblPr><w:tblInd w:w="0" w:type="dxa"/><w:tblCellMar><w:top w:w="0" w:type="dxa"/><w:left w:w="108" w:type="dxa"/>\
        <w:bottom w:w="0" w:type="dxa"/><w:right w:w="108" w:type="dxa"/></w:tblCellMar></w:tblPr></w:style>\
        <w:style w:type="table" w:styleId="TableGrid"><w:name w:val="Table Grid"/><w:basedOn w:val="TableNormal"/>\
        <w:pPr><w:spacing w:after="0" w:line="240" w:lineRule="auto"/></w:pPr><w:tblPr><w:tblBorders>\
        <w:top w:val="single" w:sz="4" w:space="0" w:color="auto"/><w:left w:val="single" w:sz="4" w:space="0" w:color="auto"/>\
        <w:bottom w:val="single" w:sz="4" w:space="0" w:color="auto"/><w:right w:val="single" w:sz="4" w:space="0" w:color="auto"/>\
        <w:insideH w:val="single" w:sz="4" w:space="0" w:color="auto"/><w:insideV w:val="single" w:sz="4" w:space="0" w:color="auto"/>\
        </w:tblBorders></w:tblPr></w:style>\
        </w:styles>
        """
    }()
}

/// Escapes XML text and drops characters XML 1.0 forbids (control characters from PDFs, etc.).
func xmlEscape(_ text: String) -> String {
    var out = ""
    out.reserveCapacity(text.count)
    for scalar in text.unicodeScalars {
        switch scalar {
        case "&": out += "&amp;"
        case "<": out += "&lt;"
        case ">": out += "&gt;"
        case "\"": out += "&quot;"
        case "\t", "\n", "\r": out.unicodeScalars.append(scalar)
        default:
            let v = scalar.value
            if v < 0x20 || v == 0xFFFE || v == 0xFFFF { continue }
            out.unicodeScalars.append(scalar)
        }
    }
    return out
}

/// DOCX → DocModel. Reads paragraphs, heading/quote/code styles, lists (numbering.xml), runs
/// (bold/italic/underline/strike/super/sub/monospace), hyperlinks, tables, inline images and text boxes.
enum DocxReader {
    static func read(_ url: URL) throws -> DocModel {
        let zip = try ZipArchive(url: url)
        var documentPath = "word/document.xml"
        if let rels = try zip.read("_rels/.rels"), let doc = try? XML.document(rels, what: "The document"),
           let target = doc.rootElement()?.children("Relationship").first(where: { ($0.attr("Type") ?? "").hasSuffix("/officeDocument") })?.attr("Target") {
            documentPath = target.hasPrefix("/") ? String(target.dropFirst()) : target
        }
        guard let documentData = try zip.read(documentPath) else {
            throw DocumentError.malformed("The file is not a Word document.")
        }
        let folder = (documentPath as NSString).deletingLastPathComponent
        let relsPath = (folder.isEmpty ? "" : folder + "/") + "_rels/" + (documentPath as NSString).lastPathComponent + ".rels"
        var context = Context(zip: zip, folder: folder)
        if let data = try zip.read(relsPath) { context.loadRelationships(try XML.document(data, what: "The document")) }
        if let data = try zip.read((folder.isEmpty ? "" : folder + "/") + "styles.xml") { context.loadStyles(try XML.document(data, what: "The document")) }
        if let data = try zip.read((folder.isEmpty ? "" : folder + "/") + "numbering.xml") { context.loadNumbering(try XML.document(data, what: "The document")) }

        let document = try XML.document(documentData, what: "The document")
        guard let body = document.rootElement()?.child("body") else { throw DocumentError.malformed("The Word document has no body.") }
        try context.walkBlocks(body.elements, depth: 0)
        context.promoteLargeParagraphsToHeadings()

        var title: String?
        if let core = try zip.read("docProps/core.xml"), let doc = try? XML.document(core, what: "The document") {
            title = doc.rootElement()?.child("title")?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            if title?.isEmpty == true { title = nil }
        }
        return DocModel(title: title, blocks: context.blocks)
    }

    struct Relationship { let target: String; let type: String; let external: Bool }
    struct StyleInfo {
        var name = ""
        var basedOn: String?
        var outlineLevel: Int?
        var bold = false
        var italic = false
        var size: Double?
        var numId: Int?
        var numLevel = 0
    }

    struct Context {
        let zip: ZipArchive
        let folder: String
        var relationships: [String: Relationship] = [:]
        var styles: [String: StyleInfo] = [:]
        var defaultParagraphStyle: String?
        /// numId → (ilvl → ordered)
        var numbering: [Int: [Int: Bool]] = [:]
        var blocks: [DocBlock] = []
        var imageCache: [String: DocImage] = [:]
        var defaultSize: Double = 11
        /// Body paragraphs with their largest run size and character count, for size-based headings.
        var paragraphSizes: [(block: Int, size: Double, characters: Int, allBold: Bool)] = []

        init(zip: ZipArchive, folder: String) {
            self.zip = zip
            self.folder = folder
        }

        var paragraphStyleStack: [String?] = []

        /// Documents formatted by hand (or by Cocoa's writer) have no heading styles: treat short
        /// paragraphs set clearly larger than the body text as headings.
        mutating func promoteLargeParagraphsToHeadings() {
            var weights: [Double: Int] = [:]
            for entry in paragraphSizes { weights[(entry.size * 2).rounded() / 2, default: 0] += entry.characters }
            guard let body = weights.max(by: { $0.value < $1.value })?.key, body > 0 else { return }
            for entry in paragraphSizes where entry.characters <= 200 {
                let ratio = entry.size / body
                let level: Int
                if ratio >= 1.75 { level = 1 } else if ratio >= 1.35 { level = 2 } else if ratio >= 1.15 { level = 3 } else { continue }
                guard case .paragraph(var p) = blocks[entry.block] else { continue }
                p.kind = .heading(level)
                p.runs = p.runs.map { DocRun($0.text, style: $0.style.subtracting(.bold), link: $0.link) }
                blocks[entry.block] = .paragraph(p)
            }
        }

        mutating func loadRelationships(_ doc: XMLDocument) {
            for rel in doc.rootElement()?.children("Relationship") ?? [] {
                guard let id = rel.attr("Id"), let target = rel.attr("Target") else { continue }
                relationships[id] = Relationship(target: target, type: rel.attr("Type") ?? "",
                                                 external: rel.attr("TargetMode")?.lowercased() == "external")
            }
        }

        mutating func loadStyles(_ doc: XMLDocument) {
            if let size = doc.rootElement()?.child("docDefaults")?.child("rPrDefault")?.child("rPr")?.child("sz")?.attr("val").flatMap(Double.init) {
                defaultSize = size / 2
            }
            for style in doc.rootElement()?.children("style") ?? [] {
                guard let id = style.attr("styleId") else { continue }
                var info = StyleInfo()
                info.name = style.child("name")?.attr("val")?.lowercased() ?? id.lowercased()
                info.basedOn = style.child("basedOn")?.attr("val")
                if let pPr = style.child("pPr") {
                    if let level = pPr.child("outlineLvl")?.attr("val").flatMap(Int.init) { info.outlineLevel = level }
                    if let numPr = pPr.child("numPr") {
                        info.numId = numPr.child("numId")?.attr("val").flatMap(Int.init)
                        info.numLevel = numPr.child("ilvl")?.attr("val").flatMap(Int.init) ?? 0
                    }
                }
                if let rPr = style.child("rPr") {
                    info.bold = flag(rPr.child("b"))
                    info.italic = flag(rPr.child("i"))
                    info.size = rPr.child("sz")?.attr("val").flatMap(Double.init).map { $0 / 2 }
                }
                if style.attr("type") == "paragraph", style.attr("default") == "1" { defaultParagraphStyle = id }
                styles[id] = info
            }
        }

        mutating func loadNumbering(_ doc: XMLDocument) {
            guard let root = doc.rootElement() else { return }
            var abstract: [String: [Int: Bool]] = [:]
            for definition in root.children("abstractNum") {
                guard let id = definition.attr("abstractNumId") else { continue }
                var levels: [Int: Bool] = [:]
                for level in definition.children("lvl") {
                    let ilvl = level.attr("ilvl").flatMap(Int.init) ?? 0
                    let format = level.child("numFmt")?.attr("val") ?? "bullet"
                    levels[ilvl] = !(format == "bullet" || format == "none")
                }
                abstract[id] = levels
            }
            for num in root.children("num") {
                guard let id = num.attr("numId").flatMap(Int.init), let abstractId = num.child("abstractNumId")?.attr("val") else { continue }
                numbering[id] = abstract[abstractId] ?? [:]
            }
        }

        /// Follows basedOn up to 10 levels for a style property.
        func resolve<T>(_ styleId: String?, _ property: (StyleInfo) -> T?) -> T? {
            var current = styleId
            for _ in 0..<10 {
                guard let id = current, let style = styles[id] else { return nil }
                if let value = property(style) { return value }
                current = style.basedOn
            }
            return nil
        }

        // MARK: Blocks

        mutating func walkBlocks(_ elements: [XMLElement], depth: Int) throws {
            guard depth < DocumentLimits.maxNesting else { throw DocumentError.tooLarge("DOCX content is nested too deeply.") }
            for element in elements {
                guard blocks.count < DocumentLimits.maxBlocks else { throw DocumentError.tooLarge("The document has too many blocks.") }
                switch element.local {
                case "p": try paragraph(element, depth: depth)
                case "tbl": if let table = try table(element, depth: depth) { blocks.append(.table(table)) }
                case "sdt": if let content = element.child("sdtContent") { try walkBlocks(content.elements, depth: depth + 1) }
                case "customXml", "ins", "smartTag": try walkBlocks(element.elements, depth: depth + 1)
                default: break
                }
            }
        }

        mutating func paragraph(_ p: XMLElement, depth: Int) throws {
            let pPr = p.child("pPr")
            let styleId = pPr?.child("pStyle")?.attr("val") ?? defaultParagraphStyle
            let styleName = styleId.flatMap { styles[$0]?.name } ?? ""
            var kind = DocParagraph.Kind.body
            var isCode = false

            let outline = pPr?.child("outlineLvl")?.attr("val").flatMap(Int.init) ?? resolve(styleId) { $0.outlineLevel }
            if styleName == "title" {
                kind = .heading(1)
            } else if styleName.hasPrefix("heading "), let level = Int(styleName.dropFirst(8)) {
                kind = .heading(min(max(level, 1), 6))
            } else if let outline, outline < 9 {
                kind = .heading(min(outline + 1, 6))
            } else if styleName.contains("quote") || styleName == "block text" {
                kind = .quote
            } else if styleName.contains("code") || styleName.contains("preformatted") || styleName == "source code" || styleName == "plain text" {
                isCode = true
            }

            // Lists: direct numPr, else the style's.
            var numId = pPr?.child("numPr")?.child("numId")?.attr("val").flatMap(Int.init)
            var ilvl = pPr?.child("numPr")?.child("ilvl")?.attr("val").flatMap(Int.init)
            if numId == nil, let styleNum = resolve(styleId, { $0.numId }) {
                numId = styleNum
                ilvl = ilvl ?? resolve(styleId) { $0.numLevel }
            }
            if let numId, numId != 0, case .body = kind {
                let level = ilvl ?? 0
                let ordered = numbering[numId]?[level] ?? false
                kind = .listItem(ordered: ordered, level: min(level + 1, 9))
            }

            var alignment = DocAlignment.natural
            switch pPr?.child("jc")?.attr("val") {
            case "center"?: alignment = .center
            case "right"?, "end"?: alignment = .right
            case "both"?, "distribute"?: alignment = .justified
            default: break
            }

            var collector = RunCollector()
            var pendingBoxes: [XMLElement] = []
            paragraphStyleStack.append(styleId)
            defer { paragraphStyleStack.removeLast() }
            try collectRuns(p.elements, into: &collector, boxes: &pendingBoxes, link: nil, depth: depth)
            collector.finish()

            for segment in collector.segments {
                switch segment {
                case .runs(let runs):
                    var trimmed = runs.trimmed()
                    guard !trimmed.isEmpty else { continue }
                    if isCode {
                        blocks.append(.code(trimmed.plainText))
                        continue
                    }
                    if case .heading = kind { trimmed = trimmed.map { DocRun($0.text, style: $0.style.subtracting(.bold), link: $0.link) } }
                    if case .body = kind {
                        paragraphSizes.append((blocks.count, collector.maxSize, trimmed.plainText.count, collector.allBold))
                    }
                    blocks.append(.paragraph(DocParagraph(kind, runs: trimmed, alignment: alignment)))
                case .image(let image):
                    blocks.append(.image(image))
                case .pageBreak:
                    blocks.append(.pageBreak)
                }
            }
            for box in pendingBoxes { try walkBlocks(box.elements, depth: depth + 1) }
            // Merge consecutive code paragraphs into one block.
            if isCode, blocks.count >= 2, case .code(let last) = blocks[blocks.count - 1], case .code(let previous) = blocks[blocks.count - 2] {
                blocks.removeLast(2)
                blocks.append(.code(previous + "\n" + last))
            }
        }

        struct RunCollector {
            enum Segment { case runs([DocRun]), image(DocImage), pageBreak }
            var segments: [Segment] = []
            var current: [DocRun] = []
            /// Complex-field state: instruction text and whether we're past the separator.
            var fieldStack: [(instruction: String, separated: Bool)] = []
            /// Largest run size with visible text, and whether every visible run is bold.
            var maxSize: Double = 0
            var allBold = true

            var fieldLink: String? {
                for field in fieldStack.reversed() where field.separated {
                    let instruction = field.instruction.trimmingCharacters(in: .whitespaces)
                    if instruction.uppercased().hasPrefix("HYPERLINK") {
                        let parts = instruction.components(separatedBy: "\"")
                        if parts.count >= 2, URL(string: parts[1])?.scheme != nil { return parts[1] }
                    }
                }
                return nil
            }
            var inFieldInstruction: Bool { fieldStack.last.map { !$0.separated } ?? false }

            mutating func append(_ run: DocRun) { current.append(run) }
            mutating func flush() { if !current.isEmpty { segments.append(.runs(current)); current = [] } }
            mutating func finish() { flush() }
        }

        mutating func collectRuns(_ elements: [XMLElement], into collector: inout RunCollector, boxes: inout [XMLElement],
                                  link: String?, depth: Int) throws {
            guard depth < DocumentLimits.maxNesting else { throw DocumentError.tooLarge("DOCX content is nested too deeply.") }
            for element in elements {
                switch element.local {
                case "r":
                    try run(element, into: &collector, boxes: &boxes, link: link)
                case "hyperlink":
                    var target = link
                    if let id = element.attribute(forName: "r:id")?.stringValue ?? element.attr("id"),
                       let rel = relationships[id], rel.external { target = rel.target }
                    try collectRuns(element.elements, into: &collector, boxes: &boxes, link: target, depth: depth + 1)
                case "ins", "smartTag", "customXml", "fldSimple", "moveTo", "dir", "bdo":
                    var target = link
                    if element.local == "fldSimple", let instruction = element.attr("instr"), instruction.uppercased().contains("HYPERLINK") {
                        let parts = instruction.components(separatedBy: "\"")
                        if parts.count >= 2 { target = parts[1] }
                    }
                    try collectRuns(element.elements, into: &collector, boxes: &boxes, link: target, depth: depth + 1)
                case "sdt":
                    if let content = element.child("sdtContent") {
                        try collectRuns(content.elements, into: &collector, boxes: &boxes, link: link, depth: depth + 1)
                    }
                case "oMath", "oMathPara":
                    let text = element.descendants("t").compactMap(\.stringValue).joined()
                    if !text.isEmpty { collector.append(DocRun(text, style: .italic, link: link)) }
                default:
                    break // del, moveFrom, bookmarks, proofErr, commentRange...
                }
            }
        }

        mutating func run(_ r: XMLElement, into collector: inout RunCollector, boxes: inout [XMLElement], link: String?) throws {
            let rPr = r.child("rPr")
            var style: DocStyle = []
            let paragraphStyle = paragraphStyleStack.last ?? nil
            let size = rPr?.child("sz")?.attr("val").flatMap(Double.init).map { $0 / 2 }
                ?? resolve(rPr?.child("rStyle")?.attr("val")) { $0.size } ?? resolve(paragraphStyle) { $0.size } ?? defaultSize
            if let charStyle = rPr?.child("rStyle")?.attr("val") {
                let name = styles[charStyle]?.name ?? charStyle.lowercased()
                if resolve(charStyle, { $0.bold ? true : nil }) == true || name == "strong" { style.insert(.bold) }
                if resolve(charStyle, { $0.italic ? true : nil }) == true || name == "emphasis" { style.insert(.italic) }
                if name.contains("code") || name.contains("verbatim") || (name.contains("html") && name.contains("type")) { style.insert(.code) }
            }
            if let rPr {
                if let b = rPr.child("b") { if flag(b) { style.insert(.bold) } else { style.remove(.bold) } }
                if let i = rPr.child("i") { if flag(i) { style.insert(.italic) } else { style.remove(.italic) } }
                if let u = rPr.child("u"), let val = u.attr("val"), val != "none", link == nil { style.insert(.underline) }
                if flag(rPr.child("strike")) || flag(rPr.child("dstrike")) { style.insert(.strike) }
                switch rPr.child("vertAlign")?.attr("val") {
                case "superscript"?: style.insert(.superscript)
                case "subscript"?: style.insert(.subscript)
                default: break
                }
                if let font = rPr.child("rFonts")?.attr("ascii")?.lowercased(),
                   ["courier", "consolas", "menlo", "monaco", "mono", "lucida console", "source code"].contains(where: font.contains) {
                    style.insert(.code)
                }
                if flag(rPr.child("vanish")) { return }
            }
            for child in r.elements {
                let activeLink = link ?? collector.fieldLink
                switch child.local {
                case "t":
                    if collector.inFieldInstruction { continue }
                    let text = child.stringValue ?? ""
                    if text.contains(where: { !$0.isWhitespace }) {
                        collector.maxSize = max(collector.maxSize, size)
                        if !style.contains(.bold) && resolve(paragraphStyle, { $0.bold ? true : nil }) != true { collector.allBold = false }
                    }
                    collector.append(DocRun(text, style: style, link: activeLink))
                case "instrText":
                    if !collector.fieldStack.isEmpty { collector.fieldStack[collector.fieldStack.count - 1].instruction += child.stringValue ?? "" }
                case "fldChar":
                    switch child.attr("fldCharType") {
                    case "begin"?: collector.fieldStack.append(("", false))
                    case "separate"?: if !collector.fieldStack.isEmpty { collector.fieldStack[collector.fieldStack.count - 1].separated = true }
                    case "end"?: if !collector.fieldStack.isEmpty { collector.fieldStack.removeLast() }
                    default: break
                    }
                case "tab", "ptab":
                    collector.append(DocRun("\t", style: style, link: activeLink))
                case "br", "cr":
                    if child.attr("type") == "page" {
                        collector.flush()
                        collector.segments.append(.pageBreak)
                    } else {
                        collector.append(DocRun("\n", style: style))
                    }
                case "noBreakHyphen":
                    collector.append(DocRun("\u{2011}", style: style, link: activeLink))
                case "sym":
                    if let code = child.attr("char"), let value = UInt32(code, radix: 16), let scalar = Unicode.Scalar(value), value >= 0x20, value < 0xF000 {
                        collector.append(DocRun(String(Character(scalar)), style: style, link: activeLink))
                    }
                case "drawing", "pict", "object":
                    for image in images(in: child) {
                        collector.flush()
                        collector.segments.append(.image(image))
                    }
                    boxes += child.descendants("txbxContent")
                case "AlternateContent":
                    // Prefer the modern Choice branch; Fallback duplicates it as VML.
                    if let choice = child.child("Choice") {
                        for image in images(in: choice) {
                            collector.flush()
                            collector.segments.append(.image(image))
                        }
                        boxes += choice.descendants("txbxContent")
                    }
                default:
                    break
                }
            }
        }

        mutating func images(in element: XMLElement) -> [DocImage] {
            var result: [DocImage] = []
            var widthPoints: Double?
            if let extent = element.descendants("extent").first, let cx = extent.attr("cx").flatMap(Double.init) {
                widthPoints = cx / 12700
            }
            let ids = element.descendants("blip").compactMap { $0.attribute(forName: "r:embed")?.stringValue ?? $0.attr("embed") }
                + element.descendants("imagedata").compactMap { $0.attribute(forName: "r:id")?.stringValue ?? $0.attr("id") }
            for id in ids {
                guard let rel = relationships[id], !rel.external else { continue }
                let path = resolvePath(rel.target)
                if var cached = imageCache[path] {
                    cached.displayWidth = widthPoints
                    result.append(cached)
                    continue
                }
                guard let data = try? zip.read(path), var image = DocImage(data: data) else { continue }
                image.displayWidth = widthPoints
                image.alt = element.descendants("docPr").first?.attr("descr") ?? ""
                imageCache[path] = image
                result.append(image)
            }
            return result
        }

        func resolvePath(_ target: String) -> String {
            if target.hasPrefix("/") { return String(target.dropFirst()) }
            var parts = folder.split(separator: "/").map(String.init)
            for component in target.split(separator: "/") {
                if component == ".." { if !parts.isEmpty { parts.removeLast() } } else if component != "." { parts.append(String(component)) }
            }
            return parts.joined(separator: "/")
        }

        mutating func table(_ tbl: XMLElement, depth: Int) throws -> DocTable? {
            var rows: [[[DocRun]]] = []
            var headerRows = 0
            for tr in tbl.children("tr") {
                var cells: [[DocRun]] = []
                for tc in tr.elements where tc.local == "tc" || tc.local == "sdt" {
                    let cell = tc.local == "sdt" ? (tc.child("sdtContent")?.child("tc") ?? tc) : tc
                    var inner = Context(zip: zip, folder: folder)
                    inner.relationships = relationships
                    inner.styles = styles
                    inner.numbering = numbering
                    inner.defaultParagraphStyle = defaultParagraphStyle
                    try inner.walkBlocks(cell.elements.filter { $0.local != "tcPr" }, depth: depth + 1)
                    var runs: [DocRun] = []
                    for block in inner.blocks {
                        var text: [DocRun] = []
                        switch block {
                        case .paragraph(let p): text = p.runs
                        case .code(let c): text = [DocRun(c, style: .code)]
                        case .table(let nested): text = [DocRun(nested.rows.map { $0.map(\.plainText).joined(separator: " | ") }.joined(separator: "\n"))]
                        default: continue
                        }
                        if !runs.isEmpty { runs.append(DocRun("\n")) }
                        runs += text
                    }
                    if cell.child("tcPr")?.child("vMerge").map({ $0.attr("val") != "restart" }) == true { runs = [] }
                    cells.append(runs.trimmed())
                    let span = cell.child("tcPr")?.child("gridSpan")?.attr("val").flatMap(Int.init) ?? 1
                    if span > 1 { cells += Array(repeating: [], count: min(span - 1, 60)) }
                }
                if tr.child("trPr")?.child("tblHeader") != nil, rows.count == headerRows { headerRows += 1 }
                rows.append(cells)
                guard rows.count * max(cells.count, 1) <= DocumentLimits.maxTableCells else {
                    throw DocumentError.tooLarge("A document table is too large.")
                }
            }
            guard !rows.isEmpty else { return nil }
            if headerRows == 0, rows.count > 1, let first = rows.first,
               first.allSatisfy({ cell in !cell.isEmpty && cell.allSatisfy { $0.style.contains(.bold) || $0.text.trimmingCharacters(in: .whitespaces).isEmpty } }) {
                headerRows = 1
            }
            if headerRows > 0 {
                rows[0] = rows[0].map { $0.map { DocRun($0.text, style: $0.style.subtracting(.bold), link: $0.link) } }
            }
            return DocTable(rows: rows, headerRows: min(headerRows, 1))
        }
    }

    /// OOXML on/off property: present without w:val, or val not false/0/off.
    static func flag(_ element: XMLElement?) -> Bool {
        guard let element else { return false }
        guard let value = element.attr("val")?.lowercased() else { return true }
        return !(value == "0" || value == "false" || value == "off" || value == "none")
    }
}

