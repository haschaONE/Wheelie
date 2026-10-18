import AppKit
import ImageIO
import PDFKit
import XCTest
@testable import WheelieCore

/// Regression tests for malformed or unusual inputs that used to crash, lose content or produce wrong output.
final class DocumentRobustnessTests: XCTestCase {
    // MARK: PDF reflow: unbalanced Form XObjects

    func testUnbalancedFormXObjectDoesNotCrashReflow() async throws {
        let dir = try tempDir()
        let text = "BT /F1 12 Tf 72 720 Td (Hello world, this is some body text.) Tj ET\n"
        // Form with more Q than q, followed by a bare cm on the page.
        let flat = dir.appendingPathComponent("flat.pdf")
        try handMadePDF(at: flat, page: text + "/Fm1 Do\n1 0 0 1 10 10 cm\nBT /F1 12 Tf 72 700 Td (More text here.) Tj ET\n",
                        forms: [("Fm1", "Q Q Q", [])])
        // Nested forms where the inner one is unbalanced.
        let nested = dir.appendingPathComponent("nested.pdf")
        try handMadePDF(at: nested, page: text + "q /Fm1 Do Q\n", forms: [("Fm1", "/Fm2 Do", ["Fm2"]), ("Fm2", "Q Q Q", [])])
        for url in [flat, nested] {
            let model = try PDFReflow.read(url, recognizeText: false)
            XCTAssertTrue(model.blocks.contains { if case .paragraph(let p) = $0 { return p.text.contains("Hello world") }; return false })
            let md = try String(contentsOf: try await Converter.convert(url, to: .markdown)[0], encoding: .utf8)
            XCTAssertTrue(md.contains("Hello world"), md)
        }
    }

    func testFormCannotPopThePageTransform() throws {
        let dir = try tempDir()
        // The page scales by 2, draws an unbalanced form, then paints an image: the image must still be scaled.
        let url = dir.appendingPathComponent("ctm.pdf")
        try handMadePDF(at: url, page: "BT /F1 12 Tf 72 720 Td (Body text for the page.) Tj ET\n2 0 0 2 0 0 cm\n/Fm1 Do\n50 0 0 40 10 10 cm\n/Im1 Do\n",
                        forms: [("Fm1", "Q Q", [])], image: true)
        let page = try XCTUnwrap(PDFDocument(url: url)?.page(at: 0))
        let rects = PDFReflow.imageRects(page)
        XCTAssertEqual(rects.count, 1)
        XCTAssertEqual(rects.first?.width ?? 0, 100, accuracy: 0.01)
        XCTAssertEqual(rects.first?.height ?? 0, 80, accuracy: 0.01)
        XCTAssertEqual(rects.first?.minX ?? 0, 20, accuracy: 0.01)
    }

    // MARK: PDF layout: table rows taller than a page

    func testTableRowTallerThanAPageIsNotTruncated() throws {
        let dir = try tempDir()
        let lines = (0..<400).map { "Line\($0)" }.joined(separator: "\n")
        let table = DocTable(rows: [[[DocRun("Header")], [DocRun("H2")]],
                                    [[DocRun(lines)], [DocRun("side")]],
                                    [[DocRun("After row")], [DocRun("x")]]], headerRows: 1)
        let model = DocModel(blocks: [.paragraph(DocParagraph(runs: [DocRun("Intro paragraph")])), .table(table),
                                      .paragraph(DocParagraph(runs: [DocRun("Closing paragraph")]))])
        let url = dir.appendingPathComponent("tall.pdf")
        try PDFLayout.write(AttributedBuilder.build(model), to: url, setup: .a4)
        let text = try XCTUnwrap(PDFDocument(url: url)?.string)
        for needle in ["Intro paragraph", "Line0", "Line56", "Line200", "Line399", "side", "After row", "Closing paragraph"] {
            XCTAssertTrue(text.contains(needle), needle)
        }
    }

    func testHTMLLayoutTableKeepsEveryParagraph() async throws {
        let dir = try tempDir()
        let paragraphs = (1...120).map { "<p>Para\($0) some words to fill the line.</p>" }.joined()
        let url = dir.appendingPathComponent("layout.html")
        try "<html><body><h1>Title</h1><table><tr><td>\(paragraphs)</td></tr></table><p>Footer text</p></body></html>"
            .write(to: url, atomically: true, encoding: .utf8)
        let pdf = try await Converter.convert(url, to: .pdf)[0]
        let text = try XCTUnwrap(PDFDocument(url: pdf)?.string)
        for n in [1, 56, 57, 100, 120] { XCTAssertTrue(text.contains("Para\(n) "), "Para\(n)") }
        XCTAssertTrue(text.contains("Footer text"))
    }

    func testCocoaTableWithTallCellIsNotTruncated() throws {
        let dir = try tempDir()
        let out = NSMutableAttributedString(string: "Intro\n", attributes: [.font: NSFont.systemFont(ofSize: 12)])
        let table = NSTextTable()
        table.numberOfColumns = 1
        for r in 0..<3 {
            let block = NSTextTableBlock(table: table, startingRow: r, rowSpan: 1, startingColumn: 0, columnSpan: 1)
            block.setWidth(0.5, type: .absoluteValueType, for: .border)
            let style = NSMutableParagraphStyle()
            style.textBlocks = [block]
            let count = r == 1 ? 150 : 1
            for i in 0..<count {
                out.append(NSAttributedString(string: "R\(r)P\(i)\n", attributes: [.font: NSFont.systemFont(ofSize: 12), .paragraphStyle: style]))
            }
        }
        out.append(NSAttributedString(string: "Outro\n", attributes: [.font: NSFont.systemFont(ofSize: 12)]))
        let url = dir.appendingPathComponent("cocoa.pdf")
        try PDFLayout.write(out, to: url, setup: .a4)
        let text = try XCTUnwrap(PDFDocument(url: url)?.string)
        for needle in ["Intro", "R0P0", "R1P0", "R1P49", "R1P149", "R2P0", "Outro"] { XCTAssertTrue(text.contains(needle), needle) }
    }

    func testShortTablesStayTables() throws {
        let table = DocTable(rows: [[[DocRun("a")], [DocRun("b")]], [[DocRun("c")], [DocRun("d")]]], headerRows: 0)
        let storage = NSTextStorage(attributedString: AttributedBuilder.build(DocModel(blocks: [.table(table)])))
        XCTAssertEqual(TableRows.unwrapOversized(in: storage, contentSize: PDFLayout.PageSetup.a4.contentSize), 0)
    }

    // MARK: Output names under concurrency

    func testConcurrentConversionsGetDistinctOutputs() async throws {
        let dir = try tempDir()
        let png = dir.appendingPathComponent("logo.png"), tiff = dir.appendingPathComponent("logo.tiff")
        try Converter.writeImage(solidImage(width: 400, height: 300), to: png, type: .png)
        try Converter.writeImage(solidImage(width: 400, height: 300), to: tiff, type: .tiff)
        for format in [OutputFormat.jpeg, .pdf] {
            let outputs = try await withThrowingTaskGroup(of: [URL].self) { group in
                for source in [png, tiff] { group.addTask { try await Converter.convert(source, to: format) } }
                return try await group.reduce(into: [URL]()) { $0 += $1 }
            }
            XCTAssertEqual(Set(outputs).count, 2, "\(format): \(outputs.map(\.lastPathComponent))")
            for output in outputs { XCTAssertGreaterThan(try fileSize(output), 0, output.lastPathComponent) }
        }
    }

    func testReservedNamesAreExclusiveAndFailuresCleanUp() async throws {
        let dir = try tempDir()
        let source = dir.appendingPathComponent("report.md")
        let lock = NSLock()
        var names: [URL] = []
        DispatchQueue.concurrentPerform(iterations: 24) { _ in
            let url = try? OutputNaming.reserveURL(for: source, ext: "pdf")
            lock.lock(); if let url { names.append(url) }; lock.unlock()
        }
        XCTAssertEqual(names.count, 24)
        XCTAssertEqual(Set(names).count, 24)
        XCTAssertEqual(OutputNaming.uniqueURL(for: source, ext: "pdf").lastPathComponent, "report 25.pdf")

        // A conversion that fails leaves nothing behind.
        let broken = dir.appendingPathComponent("broken.png")
        try Data("not an image".utf8).write(to: broken)
        do {
            _ = try await Converter.convert(broken, to: .jpeg)
            XCTFail("expected a failure")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("broken.jpg").path))
    }

    // MARK: DOCX list levels

    func testOutOfRangeListLevelsDoNotCrashWriters() async throws {
        let dir = try tempDir()
        let docx = dir.appendingPathComponent("lists.docx")
        let w = "xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\""
        var zip = ZipWriter()
        zip.add("word/numbering.xml", """
        <w:numbering \(w)><w:abstractNum w:abstractNumId="0"><w:lvl w:ilvl="0"><w:numFmt w:val="decimal"/></w:lvl></w:abstractNum>\
        <w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num></w:numbering>
        """)
        zip.add("word/styles.xml", """
        <w:styles \(w)><w:style w:type="paragraph" w:styleId="Odd"><w:name w:val="Odd List"/>\
        <w:pPr><w:numPr><w:ilvl w:val="-1"/><w:numId w:val="1"/></w:numPr></w:pPr></w:style></w:styles>
        """)
        func item(_ ilvl: String, _ text: String) -> String {
            "<w:p><w:pPr><w:numPr><w:ilvl w:val=\"\(ilvl)\"/><w:numId w:val=\"1\"/></w:numPr></w:pPr><w:r><w:t>\(text)</w:t></w:r></w:p>"
        }
        zip.add("word/document.xml", """
        <w:document \(w)><w:body>\(item("-1", "Minus one"))\(item("9223372036854775807", "Huge"))\
        <w:p><w:pPr><w:pStyle w:val="Odd"/></w:pPr><w:r><w:t>From style</w:t></w:r></w:p>\
        <w:p><w:pPr><w:outlineLvl w:val="-3"/></w:pPr><w:r><w:t>Negative outline</w:t></w:r></w:p></w:body></w:document>
        """)
        try zip.write(to: docx)

        let model = try DocxReader.read(docx)
        let kinds = model.blocks.compactMap { block -> DocParagraph.Kind? in
            if case .paragraph(let p) = block { return p.kind }
            return nil
        }
        XCTAssertEqual(kinds, [.listItem(ordered: true, level: 1), .listItem(ordered: false, level: 9),
                               .listItem(ordered: true, level: 1), .body])

        for format in [OutputFormat.html, .pdf, .rtf, .odt, .markdown, .txt, .docx] {
            let out = try await Converter.convert(docx, to: format)[0]
            XCTAssertTrue(try readBack(out).contains("Minus one"), "\(format)")
        }
        // Writers are defensive on their own too.
        let bad = DocModel(blocks: [.paragraph(DocParagraph(.listItem(ordered: false, level: 0), runs: [DocRun("zero")])),
                                    .paragraph(DocParagraph(.listItem(ordered: true, level: -4), runs: [DocRun("negative")])),
                                    .paragraph(DocParagraph(.heading(0), runs: [DocRun("heading")]))])
        XCTAssertTrue(HTMLWriter.render(bad).contains("negative"))
        XCTAssertTrue(AttributedBuilder.build(bad).string.contains("negative"))
        XCTAssertTrue(MarkdownWriter.render(bad).contains("# heading"))
    }

    // MARK: Image widths

    func testNonFiniteImageWidthsDoNotCrashWriters() async throws {
        let dir = try tempDir()
        try Converter.writeImage(solidImage(width: 40, height: 20), to: dir.appendingPathComponent("pic.png"), type: .png)
        for (index, width) in ["NaN", "nan", "inf", "-Infinity", "1e30", "-5", "0"].enumerated() {
            let html = dir.appendingPathComponent("page\(index).html")
            try "<html><body><p>Before</p><img src=\"pic.png\" width=\"\(width)\"><p>After</p></body></html>"
                .write(to: html, atomically: true, encoding: .utf8)
            let model = try HTMLReader.read(html)
            // Non-finite and non-positive widths are dropped; a huge finite one is kept and capped by the writers.
            for block in model.blocks where width != "1e30" { if case .image(let image) = block { XCTAssertNil(image.displayWidth, width) } }
            for format in [OutputFormat.docx, .html] {
                let out = try await Converter.convert(html, to: format)[0]
                XCTAssertTrue(try readBack(out).contains("After"), "\(width) → \(format)")
            }
        }
        // A DocImage built in code with a bad width still has a finite display size, and HTML stays sane.
        var image = try XCTUnwrap(DocImage(cgImage: solidImage(width: 40, height: 20)))
        for value in [Double.nan, .infinity, -3, 1e30] {
            image.displayWidth = value
            let size = image.displaySize(maxWidth: 400, maxHeight: 600)
            XCTAssertTrue(size.width.isFinite && size.width > 0 && size.height.isFinite, "\(value)")
            XCTAssertTrue(HTMLWriter.render(DocModel(blocks: [.image(image)])).contains("<img"))
            XCTAssertNoThrow(try DocxWriter.write(DocModel(blocks: [.image(image)]), to: dir.appendingPathComponent("w.docx"), setup: .a4))
        }
    }

    // MARK: XLSX used area

    func testFarRightCellsCountAgainstTheCellLimit() throws {
        let dir = try tempDir()
        let rows = (1...3000).map { "<row r=\"\($0)\"><c r=\"XFD\($0)\"><v>1</v></c></row>" }.joined()
        let hostile = dir.appendingPathComponent("wide.xlsx")
        try workbook(sheetData: rows).write(to: hostile)
        XCTAssertThrowsError(try XLSX.read(hostile)) { error in
            guard case DocumentError.tooLarge = error else { return XCTFail("\(error)") }
        }

        // Legitimate sparse sheets still read: one far-right value, and a styled empty row at the very bottom.
        let sparse = dir.appendingPathComponent("sparse.xlsx")
        try workbook(sheetData: """
        <row r="1"><c r="A1"><v>1</v></c><c r="XFD1"><v>2</v></c></row>\
        <row r="2"><c r="B2"><v>3</v></c></row><row r="1048576"><c r="A1048576" s="1"/><c r="C1048576" s="1"/></row>
        """).write(to: sparse)
        let sheet = try XCTUnwrap(XLSX.read(sparse).first)
        XCTAssertEqual(sheet.rows.count, 2)
        XCTAssertEqual(sheet.rows[0].count, 16_384)
        XCTAssertEqual(sheet.rows[0].last, "2")
        XCTAssertEqual(sheet.rows[1], ["", "3"])
        // Absurd column letters are skipped instead of overflowing.
        let letters = dir.appendingPathComponent("letters.xlsx")
        try workbook(sheetData: "<row r=\"1\"><c r=\"ZZZZZZZZZZZZZZZZZZZZ1\"><v>1</v></c><c r=\"B1\"><v>2</v></c></row>").write(to: letters)
        XCTAssertEqual(try XLSX.read(letters).first?.rows, [["", "2"]])
    }

    // MARK: Video dimensions

    func testOddDimensionVideoConvertsToMP4AndMOV() async throws {
        try XCTSkipIf(Tools.locate("ffmpeg") == nil || Tools.locate("ffprobe") == nil, "ffmpeg not installed")
        let dir = try tempDir()
        let source = dir.appendingPathComponent("odd.webm")
        try await Tools.run("ffmpeg", ["-nostdin", "-loglevel", "error", "-f", "lavfi", "-i", "color=c=blue:size=853x481:rate=10:duration=1",
                                       "-c:v", "libvpx-vp9", "-pix_fmt", "yuv420p", source.path])
        for format in [OutputFormat.mp4, .mov] {
            let out = try await Converter.convert(source, to: format)[0]
            let probe = try await Tools.capture("ffprobe", ["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height",
                                                            "-of", "csv=p=0", out.path]).stdout
            XCTAssertEqual(probe.trimmingCharacters(in: .whitespacesAndNewlines), "854,482", "\(format)")
        }
        XCTAssertTrue(Converter.ffmpegArguments(for: .mkv).contains(Converter.evenDimensions[1]))
    }

    // MARK: PDF → image

    func testPDFToImageRespectsCropBoxAndRefusesLockedPDFs() async throws {
        let dir = try tempDir()
        let pdf = dir.appendingPathComponent("cropped.pdf")
        let doc = PDFDocument()
        doc.insert(try XCTUnwrap(PDFPage(image: NSImage(cgImage: solidImage(width: 595, height: 842), size: NSSize(width: 595, height: 842)))), at: 0)
        doc.page(at: 0)?.setBounds(CGRect(x: 50, y: 50, width: 200, height: 150), for: .cropBox)
        XCTAssertTrue(doc.write(to: pdf))
        let png = try await Converter.convert(pdf, to: .png)[0]
        let image = try XCTUnwrap(CGImageSourceCreateWithURL(png as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        XCTAssertEqual(image.width, 400)
        XCTAssertEqual(image.height, 300)

        let locked = dir.appendingPathComponent("locked.pdf")
        XCTAssertTrue(doc.write(to: locked, withOptions: [.userPasswordOption: "secret", .ownerPasswordOption: "owner"]))
        XCTAssertTrue(PDFDocument(url: locked)?.isLocked == true)
        do {
            _ = try await Converter.convert(locked, to: .png)
            XCTFail("a locked PDF must not produce blank images")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("password"), error.localizedDescription)
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("locked") && $0 != "locked.pdf" }
        XCTAssertEqual(leftovers, [])
    }

    // MARK: Text encodings

    func testUTF16TextSourcesAreDecoded() async throws {
        let dir = try tempDir()
        let csvText = "Name,Größe\r\nÄpfel,3\r\nBirne,4\r\n"
        var outputs: [URL] = []
        for (name, encoding, bom) in [("le.csv", String.Encoding.utf16LittleEndian, Data([0xFF, 0xFE])),
                                      ("be.csv", .utf16BigEndian, Data([0xFE, 0xFF])),
                                      ("nobom.csv", .utf16LittleEndian, Data()),
                                      ("bom8.csv", .utf8, Data([0xEF, 0xBB, 0xBF]))] {
            let url = dir.appendingPathComponent(name)
            try (bom + csvText.data(using: encoding)!).write(to: url)
            XCTAssertEqual(try CSV.read(url).rows, [["Name", "Größe"], ["Äpfel", "3"], ["Birne", "4"]], name)
            outputs.append(url)
        }
        let txt = dir.appendingPathComponent("notes.txt")
        try (Data([0xFF, 0xFE]) + "Grüße aus Köln\nZweite Zeile\n".data(using: .utf16LittleEndian)!).write(to: txt)
        let md = try String(contentsOf: try await Converter.convert(txt, to: .markdown)[0], encoding: .utf8)
        XCTAssertTrue(md.contains("Grüße aus Köln"), md)
        XCTAssertFalse(md.contains("\0"))

        let markdown = dir.appendingPathComponent("readme.md")
        try (Data([0xFE, 0xFF]) + "# Überschrift\n\nText\n".data(using: .utf16BigEndian)!).write(to: markdown)
        let html = try String(contentsOf: try await Converter.convert(markdown, to: .html)[0], encoding: .utf8)
        XCTAssertTrue(html.contains("Überschrift"), html)
        // Windows-1252 still works for legacy files.
        let legacy = dir.appendingPathComponent("legacy.txt")
        try "Größe".data(using: .windowsCP1252)!.write(to: legacy)
        XCTAssertEqual(TextDecoding.decode(try Data(contentsOf: legacy)), "Größe")
    }

    // MARK: Wheel petals

    func testEveryImageTargetIsReachableFromTheWheel() {
        func targets(_ name: String) -> [OutputFormat] { OutputFormat.targets(for: [URL(fileURLWithPath: "/tmp/" + name)]) }
        let sources = ["a.png", "a.jpg", "a.heic", "a.webp", "a.tiff", "a.gif", "a.svg", "a.bmp", "a.ico", "a.dng"]
        let reachable = Set(sources.flatMap(targets))
        for format in OutputFormat.ranked(for: .image) where format.isAvailable {
            XCTAssertTrue(reachable.contains(format), "\(format) cannot be picked from the wheel")
        }
        for name in sources { XCTAssertLessThanOrEqual(targets(name).count, OutputFormat.maxPetals, name) }
        XCTAssertTrue(targets("a.svg").contains(.icns) && targets("a.svg").contains(.ico))
        XCTAssertTrue(targets("a.png").contains(.icns) && targets("a.png").contains(.ico))
        let gif = targets("a.gif")
        XCTAssertTrue(gif.contains(.mp4) && gif.contains(.ico) && gif.contains(.icns), "\(gif)")
        XCTAssertTrue(targets("a.jpg").contains(.bmp))
    }

    // MARK: Helpers

    private func solidImage(width: Int, height: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.9, green: 0.3, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    private func fileSize(_ url: URL) throws -> Int {
        try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    }

    private func readBack(_ url: URL) throws -> String {
        switch url.pathExtension.lowercased() {
        case "pdf": return PDFDocument(url: url)?.string ?? ""
        case "docx": return try NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil).string
        case "odt": return try NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.openDocument], documentAttributes: nil).string
        case "rtf": return try NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil).string
        default: return try String(contentsOf: url, encoding: .utf8)
        }
    }

    private func workbook(sheetData: String) -> ZipWriter {
        var zip = ZipWriter()
        zip.add("xl/workbook.xml", "<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets><sheet name=\"Data\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>")
        zip.add("xl/_rels/workbook.xml.rels", "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"x/worksheet\" Target=\"worksheets/sheet1.xml\"/></Relationships>")
        zip.add("xl/worksheets/sheet1.xml", "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>\(sheetData)</sheetData></worksheet>")
        return zip
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wheelie-robust-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// One-page PDF written by hand so the content streams can be malformed on purpose.
    /// `forms`: (name, content, names of other forms it uses). `image`: adds a 1×1 image XObject /Im1.
    private func handMadePDF(at url: URL, page content: String, forms: [(String, String, [String])], image: Bool = false) throws {
        var objects: [String] = []
        func reserve() -> Int { objects.append(""); return objects.count }
        let catalog = reserve(), pages = reserve(), pageObject = reserve()
        objects[catalog - 1] = "<< /Type /Catalog /Pages \(pages) 0 R >>"
        let font = reserve()
        objects[font - 1] = "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
        var formIDs: [String: Int] = [:]
        for (name, _, _) in forms { formIDs[name] = reserve() }
        for (name, body, uses) in forms {
            let resources = uses.isEmpty ? "" : " /Resources << /XObject << " + uses.map { "/\($0) \(formIDs[$0]!) 0 R" }.joined(separator: " ") + " >> >>"
            objects[formIDs[name]! - 1] = "<< /Type /XObject /Subtype /Form /BBox [0 0 612 792]\(resources) /Length \(body.utf8.count) >>\nstream\n\(body)\nendstream"
        }
        var xobjects = forms.map { "/\($0.0) \(formIDs[$0.0]!) 0 R" }
        if image {
            let id = reserve()
            objects[id - 1] = "<< /Type /XObject /Subtype /Image /Width 1 /Height 1 /ColorSpace /DeviceGray /BitsPerComponent 8 /Length 1 >>\nstream\n\u{7F}\nendstream"
            xobjects.append("/Im1 \(id) 0 R")
        }
        let contents = reserve()
        objects[contents - 1] = "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream"
        objects[pages - 1] = "<< /Type /Pages /Kids [\(pageObject) 0 R] /Count 1 >>"
        objects[pageObject - 1] = "<< /Type /Page /Parent \(pages) 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 \(font) 0 R >> /XObject << \(xobjects.joined(separator: " ")) >> >> /Contents \(contents) 0 R >>"
        var out = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(out.utf8.count)
            out += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = out.utf8.count
        out += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { out += String(format: "%010d 00000 n \n", offset) }
        out += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        try Data(out.utf8).write(to: url)
    }
}
