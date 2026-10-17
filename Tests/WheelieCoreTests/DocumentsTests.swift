import AppKit
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import XCTest
@testable import WheelieCore

// MARK: - Matrix

final class MatrixTests: XCTestCase {
    private func targets(_ names: String...) -> [OutputFormat] {
        OutputFormat.targets(for: names.map { URL(fileURLWithPath: "/tmp/" + $0) })
    }

    func testNewKinds() {
        let cases: [(String, FileKind)] = [
            ("a.docx", .document), ("a.doc", .document), ("a.rtf", .document), ("a.odt", .document), ("a.md", .document),
            ("a.markdown", .document), ("a.html", .document), ("a.htm", .document), ("a.txt", .document), ("a.pages", .document),
            ("a.epub", .ebook), ("a.pptx", .presentation), ("a.key", .presentation), ("a.odp", .presentation),
            ("a.xlsx", .spreadsheet), ("a.csv", .spreadsheet), ("a.numbers", .spreadsheet), ("a.ods", .spreadsheet),
            ("a.svg", .image), ("a.ico", .image), ("a.avif", .image), ("a.cr2", .image), ("a.opus", .audio), ("a.aiff", .audio),
            ("a.m4v", .video), ("a.zip", .unknown), ("a.swift", .unknown),
        ]
        for (name, kind) in cases {
            XCTAssertEqual(FileKind(url: URL(fileURLWithPath: "/tmp/" + name)), kind, name)
        }
        XCTAssertEqual(FileKind(url: URL(fileURLWithPath: "/tmp/Folder", isDirectory: true)), .unknown)
        XCTAssertEqual(FileKind(url: URL(fileURLWithPath: "/tmp/notes.md", isDirectory: true)), .unknown)
        XCTAssertEqual(FileKind(url: URL(fileURLWithPath: "/tmp/Notes.rtfd", isDirectory: true)), .document)
    }

    func testEveryKindFitsTheRing() {
        let kinds: [FileKind] = [.image, .video, .audio, .pdf, .document, .ebook, .presentation, .spreadsheet, .unknown]
        for kind in kinds {
            XCTAssertLessThanOrEqual(OutputFormat.targets(for: kind).count, OutputFormat.maxPetals, kind.rawValue)
        }
        for name in ["a.png", "a.gif", "a.jpg", "a.svg", "a.mov", "a.mp3", "a.pdf", "a.docx", "a.md", "a.epub", "a.csv", "a.xlsx", "a.pptx"] {
            let list = targets(name)
            XCTAssertLessThanOrEqual(list.count, OutputFormat.maxPetals, name)
            XCTAssertEqual(Set(list).count, list.count, "duplicates for \(name)")
        }
        XCTAssertEqual(OutputFormat.targets(for: .video).count, 9)
        XCTAssertEqual(OutputFormat.targets(for: .unknown), [])
    }

    func testImageTargets() {
        let png = targets("a.png")
        XCTAssertFalse(png.contains(.png))
        XCTAssertEqual(Array(png.prefix(4)), [.jpeg, .heic, .webp, .pdf])
        XCTAssertTrue(png.contains(.ico))
        XCTAssertTrue(png.contains(.gif))
        XCTAssertEqual(png.contains(.avif), Converter.canEncodeAVIF)
        XCTAssertTrue(targets("a.gif").contains(.mp4))
        XCTAssertFalse(targets("a.gif").contains(.gif))
        XCTAssertTrue(targets("a.svg").contains(.png))
    }

    func testDocumentTargets() {
        XCTAssertEqual(targets("a.docx"), [.pdf, .markdown, .html, .txt, .rtf, .odt])
        XCTAssertEqual(targets("a.md"), [.pdf, .docx, .html, .txt, .rtf, .odt])
        XCTAssertEqual(targets("a.txt"), [.pdf, .docx, .markdown, .html, .rtf, .odt])
        XCTAssertEqual(targets("a.html").first, .pdf)
        XCTAssertFalse(targets("a.htm").contains(.html))
        XCTAssertEqual(targets("a.epub"), [.pdf, .docx, .markdown, .html, .txt, .rtf])
        XCTAssertEqual(targets("a.pdf"), [.docx, .png, .jpeg, .txt, .markdown, .html, .rtf, .odt])
        XCTAssertEqual(targets("a.csv"), [.pdf, .xlsx, .html])
        XCTAssertEqual(targets("a.xlsx"), [.pdf, .csv, .html])
        let office = LibreOffice.isInstalled
        XCTAssertEqual(targets("a.pptx"), office ? [.pdf, .png, .jpeg] : [])
        XCTAssertEqual(targets("a.key").isEmpty, !office)
        XCTAssertEqual(targets("a.numbers").isEmpty, !office)
        XCTAssertEqual(targets("a.pages").isEmpty, !office)
    }

    func testMixedSelections() {
        XCTAssertEqual(targets("a.docx", "b.md"), [.pdf, .docx, .markdown, .html, .txt, .rtf, .odt])
        XCTAssertEqual(targets("a.png", "b.docx"), [.pdf])
        XCTAssertEqual(targets("a.epub", "b.pdf"), [.docx, .markdown, .html, .txt, .rtf])
        XCTAssertEqual(targets("a.mov", "b.mp3"), [.mp3, .m4a, .wav])
        XCTAssertEqual(targets("a.md", "b.markdown"), [.pdf, .docx, .html, .txt, .rtf, .odt])
    }

    func testLabelsAndSymbols() {
        for format in OutputFormat.allCases {
            XCTAssertFalse(format.label.isEmpty)
            XCTAssertLessThanOrEqual(format.label.count, 12)
            XCTAssertNotNil(NSImage(systemSymbolName: format.symbol, accessibilityDescription: nil), format.rawValue)
        }
        XCTAssertEqual(OutputFormat.markdown.fileExtension, "md")
        XCTAssertEqual(OutputFormat.docx.label, "Word")
    }
}

// MARK: - Documents

final class DocumentConversionTests: XCTestCase {
    func testRichTextSourcesToEveryTarget() async throws {
        let dir = try makeTempDir()
        let rich = makeRichText()
        let sources: [(String, NSAttributedString.DocumentType)] = [("report.docx", .officeOpenXML), ("report.rtf", .rtf),
                                                                     ("report.html", .html), ("report.odt", .openDocument)]
        for (name, type) in sources {
            let url = dir.appendingPathComponent(name)
            try rich.data(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: type]).write(to: url)
            for format in OutputFormat.targets(for: [url]) {
                let outputs = try await Converter.convert(url, to: format)
                XCTAssertEqual(outputs.count, 1, "\(name) → \(format)")
                let out = outputs[0]
                XCTAssertGreaterThan(try fileSize(out), 0, "\(name) → \(format)")
                XCTAssertTrue(try readBack(out).contains("Quarterly Report"), "\(name) → \(format)")
                XCTAssertTrue(try readBack(out).contains("Second item"), "\(name) → \(format)")
            }
        }
    }

    func testCocoaDocxHeadingsAndLists() throws {
        let dir = try makeTempDir()
        let rich = makeRichText()
        let url = dir.appendingPathComponent("cocoa.docx")
        try rich.data(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]).write(to: url)
        let model = try DocxReader.read(url)
        let markdown = MarkdownWriter.render(model)
        XCTAssertTrue(markdown.contains("# Quarterly Report"), markdown)
        XCTAssertTrue(markdown.contains("**bold**"), markdown)
        XCTAssertTrue(markdown.contains("Second item"), markdown)
    }

    func testMarkdownConversions() async throws {
        let dir = try makeTempDir()
        try makePNG(at: dir.appendingPathComponent("pic.png"), size: 40)
        let md = dir.appendingPathComponent("notes.md")
        try sampleMarkdown.write(to: md, atomically: true, encoding: .utf8)

        let html = try String(contentsOf: try await Converter.convert(md, to: .html)[0], encoding: .utf8)
        XCTAssertTrue(html.contains("<h1>Project Notes</h1>"), html)
        XCTAssertTrue(html.contains("<strong>bold</strong>"))
        XCTAssertTrue(html.contains("<em>italic</em>"))
        XCTAssertTrue(html.contains("<code>inline</code>"))
        XCTAssertTrue(html.contains("<a href=\"https://example.com\">a link</a>"))
        XCTAssertTrue(html.contains("<ul>") && html.contains("<ol>"))
        XCTAssertTrue(html.contains("<table>"))
        XCTAssertTrue(html.contains("<pre><code>let x = 1</code></pre>"))
        XCTAssertTrue(html.contains("data:image/png;base64,"))

        let docx = try await Converter.convert(md, to: .docx)[0]
        let cocoa = try NSAttributedString(url: docx, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil)
        XCTAssertTrue(cocoa.string.contains("Project Notes"))
        XCTAssertTrue(cocoa.string.contains("let x = 1"))
        let zip = try ZipArchive(url: docx)
        XCTAssertTrue(zip.contains("word/media/image1.png"))
        let reread = try DocxReader.read(docx)
        XCTAssertTrue(reread.blocks.contains { if case .paragraph(let p) = $0 { return p.kind == .heading(1) && p.text == "Project Notes" } else { return false } })
        XCTAssertTrue(reread.blocks.contains { if case .paragraph(let p) = $0, case .listItem(true, 1) = p.kind { return true } else { return false } })
        XCTAssertTrue(reread.blocks.contains { if case .paragraph(let p) = $0, case .listItem(false, 2) = p.kind { return true } else { return false } })
        XCTAssertTrue(reread.blocks.contains { if case .table(let t) = $0 { return t.rows.count == 3 } else { return false } })
        XCTAssertTrue(reread.blocks.contains { if case .image = $0 { return true } else { return false } })

        let pdf = try await Converter.convert(md, to: .pdf)[0]
        let doc = try XCTUnwrap(PDFDocument(url: pdf))
        XCTAssertGreaterThanOrEqual(doc.pageCount, 1)
        let text = doc.string ?? ""
        XCTAssertTrue(text.contains("Project Notes"))
        XCTAssertTrue(text.contains("Cell B2"))
        XCTAssertNotNil(doc.page(at: 0)?.annotations.first { $0.url?.absoluteString == "https://example.com" }, "link annotation")

        let txt = try String(contentsOf: try await Converter.convert(md, to: .txt)[0], encoding: .utf8)
        XCTAssertTrue(txt.contains("• Apple"), txt)
        XCTAssertTrue(txt.contains("1. First"), txt)

        let rtf = try await Converter.convert(md, to: .rtf)[0]
        XCTAssertTrue(try NSAttributedString(url: rtf, options: [:], documentAttributes: nil).string.contains("Project Notes"))
        let odt = try await Converter.convert(md, to: .odt)[0]
        XCTAssertTrue(try NSAttributedString(url: odt, options: [.documentType: NSAttributedString.DocumentType.openDocument],
                                             documentAttributes: nil).string.contains("Project Notes"))
    }

    func testMarkdownRoundTrip() throws {
        let model = try MarkdownReader.parse(sampleMarkdown)
        let again = try MarkdownReader.parse(MarkdownWriter.render(model))
        XCTAssertEqual(again.plainText, model.plainText)
        let md = MarkdownWriter.render(model)
        XCTAssertTrue(md.contains("# Project Notes"))
        XCTAssertTrue(md.contains("- Apple"))
        XCTAssertTrue(md.contains("    - Nested"))
        XCTAssertTrue(md.contains("1. First"))
        XCTAssertTrue(md.contains("| Col A | Col B |"))
        XCTAssertTrue(md.contains("[a link](https://example.com)"))
        XCTAssertEqual(MarkdownWriter.inline([DocRun("2*3 [x]")]), "2\\*3 \\[x\\]")
        XCTAssertEqual(MarkdownWriter.inline([DocRun("bold ", style: .bold), DocRun("x")]), "**bold** x")
    }

    func testHTMLToMarkdown() async throws {
        let dir = try makeTempDir()
        try makePNG(at: dir.appendingPathComponent("logo.png"), size: 20)
        let url = dir.appendingPathComponent("page.html")
        try """
        <html><head><meta charset="windows-1252"><title>Page Title</title><style>p{color:red}</style></head>
        <body><h2>Café menu</h2><p>Hello <b>bold</b>&nbsp;and <span style="font-style: italic">styled</span>.</p>
        <ul><li>One<ul><li>Inner</li></ul></li><li>Two</li></ul><img src="logo.png" alt="Logo">
        <table><tr><th>Name</th><th>Price</th></tr><tr><td>Tea</td><td>3</td></tr></table><script>alert(1)</script></body></html>
        """.write(to: url, atomically: true, encoding: .utf8)
        let md = try String(contentsOf: try await Converter.convert(url, to: .markdown)[0], encoding: .utf8)
        XCTAssertTrue(md.contains("## Café menu"), md)
        XCTAssertTrue(md.contains("**bold**"), md)
        XCTAssertTrue(md.contains("*styled*"), md)
        XCTAssertTrue(md.contains("- One\n    - Inner\n- Two"), md)
        XCTAssertTrue(md.contains("![Logo](data:image/png;base64,"), md)
        XCTAssertTrue(md.contains("| Name | Price |"), md)
        XCTAssertFalse(md.contains("alert"), md)
    }

    func testEPUBConversions() async throws {
        let dir = try makeTempDir()
        let epub = dir.appendingPathComponent("book.epub")
        try makeEPUB(at: epub)

        let pdf = try await Converter.convert(epub, to: .pdf)[0]
        let doc = try XCTUnwrap(PDFDocument(url: pdf))
        XCTAssertGreaterThanOrEqual(doc.pageCount, 2, "chapters start on new pages")
        let text = doc.string ?? ""
        let one = try XCTUnwrap(text.range(of: "Chapter One"))
        let two = try XCTUnwrap(text.range(of: "Chapter Two"))
        XCTAssertLessThan(one.lowerBound, two.lowerBound, "spine order")
        XCTAssertTrue(text.contains("Beta paragraph"))

        let txt = try String(contentsOf: try await Converter.convert(epub, to: .txt)[0], encoding: .utf8)
        XCTAssertLessThan(try XCTUnwrap(txt.range(of: "Alpha paragraph")).lowerBound, try XCTUnwrap(txt.range(of: "Beta paragraph")).lowerBound)

        let html = try String(contentsOf: try await Converter.convert(epub, to: .html)[0], encoding: .utf8)
        XCTAssertTrue(html.contains("<h1>Chapter One</h1>"))
        XCTAssertTrue(html.contains("<title>Test Book</title>"))
        XCTAssertTrue(html.contains("data:image/png;base64,"), "chapter image resolved inside the archive")

        let docx = try await Converter.convert(epub, to: .docx)[0]
        XCTAssertTrue(try ZipArchive(url: docx).contains("word/media/image1.png"))
        let cocoa = try NSAttributedString(url: docx, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil)
        XCTAssertTrue(cocoa.string.contains("Chapter Two"))

        let md = try String(contentsOf: try await Converter.convert(epub, to: .markdown)[0], encoding: .utf8)
        XCTAssertTrue(md.contains("# Chapter One") && md.contains("# Chapter Two"))
        XCTAssertTrue(md.contains("breaking space"), "XHTML with HTML entities falls back to tidy")
    }

    func testEncryptedEPUBIsRejected() async throws {
        let dir = try makeTempDir()
        let epub = dir.appendingPathComponent("drm.epub")
        try makeEPUB(at: epub, encrypted: true)
        do {
            _ = try await Converter.convert(epub, to: .txt)
            XCTFail("expected failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Encrypted"), error.localizedDescription)
        }
    }

    func testPDFReflow() async throws {
        let dir = try makeTempDir()
        let pdf = dir.appendingPathComponent("paper.pdf")
        try makeTextPDF(at: pdf)

        let md = try String(contentsOf: try await Converter.convert(pdf, to: .markdown)[0], encoding: .utf8)
        XCTAssertTrue(md.contains("# Research Paper"), md)
        XCTAssertTrue(md.contains("## Introduction"), md)
        // The long paragraph spans several PDF lines but comes back as one paragraph.
        let paragraph = try XCTUnwrap(md.components(separatedBy: "\n").first { $0.hasPrefix("This paragraph") })
        XCTAssertTrue(paragraph.contains("final sentence of the paragraph."), md)
        XCTAssertTrue(md.contains("**important**"), md)
        XCTAssertTrue(md.contains("- First bullet"), md)
        XCTAssertTrue(md.contains("![](data:image/"), "embedded picture cropped from the page: \(md.prefix(400))")
        XCTAssertFalse(md.contains("Page 1 of"), "running footer removed")

        let docx = try await Converter.convert(pdf, to: .docx)[0]
        XCTAssertTrue(try ZipArchive(url: docx).names.contains { $0.hasPrefix("word/media/") })
        let cocoa = try NSAttributedString(url: docx, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil)
        XCTAssertTrue(cocoa.string.contains("Introduction"))

        for format in [OutputFormat.html, .rtf, .odt, .txt] {
            let out = try await Converter.convert(pdf, to: format)[0]
            XCTAssertTrue(try readBack(out).contains("Research Paper"), "\(format)")
        }
    }

    func testScannedPDFIsRecognised() async throws {
        let dir = try makeTempDir()
        let pdf = dir.appendingPathComponent("scan.pdf")
        let image = NSImage(size: NSSize(width: 600, height: 300), flipped: false) { rect in
            NSColor.white.setFill(); rect.fill()
            NSAttributedString(string: "HELLO WHEELIE", attributes: [.font: NSFont.boldSystemFont(ofSize: 56), .foregroundColor: NSColor.black])
                .draw(at: CGPoint(x: 40, y: 120))
            return true
        }
        let doc = PDFDocument()
        doc.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
        XCTAssertTrue(doc.write(to: pdf))
        XCTAssertTrue((PDFDocument(url: pdf)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let txt = try String(contentsOf: try await Converter.convert(pdf, to: .txt)[0], encoding: .utf8)
        XCTAssertTrue(txt.uppercased().contains("WHEELIE"), txt)
    }

    func testTallImageDoesNotStallPagination() throws {
        let dir = try makeTempDir()
        let ctx = CGContext(data: nil, width: 100, height: 3000, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.3, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 3000))
        let model = DocModel(blocks: [.paragraph(DocParagraph(runs: [DocRun("Before")])),
                                      .image(try XCTUnwrap(DocImage(cgImage: ctx.makeImage()!))),
                                      .paragraph(DocParagraph(runs: [DocRun("After tall image")]))])
        let url = dir.appendingPathComponent("tall.pdf")
        try PDFLayout.write(AttributedBuilder.build(model), to: url, setup: .a4)
        XCTAssertTrue(PDFDocument(url: url)?.string?.contains("After tall image") == true)
        let docx = dir.appendingPathComponent("tall.docx")
        try DocxWriter.write(model, to: docx, setup: .a4)
        let xml = try XCTUnwrap(try ZipArchive(url: docx).readString("word/document.xml"))
        let cy = try XCTUnwrap(xml.range(of: #"cy="(\d+)""#, options: .regularExpression)).lowerBound
        let value = Int(xml[cy...].dropFirst(4).prefix { $0.isNumber }) ?? .max
        XCTAssertLessThanOrEqual(value, Int(PDFLayout.PageSetup.a4.contentSize.height * 12700))
    }

    func testPlainTextAndPagination() async throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("long.txt")
        let paragraphs = (1...120).map { "Paragraph \($0): " + String(repeating: "lorem ipsum dolor sit amet ", count: 6) }
        try paragraphs.joined(separator: "\n\n").write(to: url, atomically: true, encoding: .utf8)
        let pdf = try await Converter.convert(url, to: .pdf)[0]
        let doc = try XCTUnwrap(PDFDocument(url: pdf))
        XCTAssertGreaterThan(doc.pageCount, 3)
        let size = try XCTUnwrap(doc.page(at: 0)).bounds(for: .mediaBox).size
        XCTAssertTrue([PDFLayout.PageSetup.a4.size, PDFLayout.PageSetup.letter.size].contains { abs($0.width - size.width) < 1 && abs($0.height - size.height) < 1 })
        XCTAssertTrue(doc.string?.contains("Paragraph 120") == true)
        let docx = try await Converter.convert(url, to: .docx)[0]
        let cocoa = try NSAttributedString(url: docx, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil)
        XCTAssertTrue(cocoa.string.contains("Paragraph 120"))
    }
}

// MARK: - Spreadsheets

final class SpreadsheetTests: XCTestCase {
    let csvText = "Name,Amount,Code\r\nAlice,12.5,00123\r\n\"Bob, Jr.\",7,\"say \"\"hi\"\"\"\r\nCarol,-3,x\n"

    func testCSVParsing() throws {
        let rows = try CSV.parse(csvText, delimiter: ",")
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows[2], ["Bob, Jr.", "7", "say \"hi\""])
        XCTAssertEqual(CSV.detectDelimiter("a;b;c\n1;2;3\n"), ";")
        XCTAssertEqual(CSV.detectDelimiter("a\tb\n1\t2\n"), "\t")
        XCTAssertTrue(CSV.isNumber("12.5"))
        XCTAssertFalse(CSV.isNumber("00123"))
        XCTAssertEqual(try CSV.parse(CSV.write(Sheet(name: "s", rows: rows)), delimiter: ","), rows)
    }

    func testCSVConversions() async throws {
        let dir = try makeTempDir()
        let csv = dir.appendingPathComponent("sales.csv")
        try csvText.write(to: csv, atomically: true, encoding: .utf8)

        let pdf = try await Converter.convert(csv, to: .pdf)[0]
        let doc = try XCTUnwrap(PDFDocument(url: pdf))
        XCTAssertGreaterThanOrEqual(doc.pageCount, 1)
        XCTAssertTrue(doc.string?.contains("Bob, Jr.") == true)

        let html = try String(contentsOf: try await Converter.convert(csv, to: .html)[0], encoding: .utf8)
        XCTAssertTrue(html.contains("<th>Name</th>") && html.contains("<td>Alice</td>"))

        let xlsx = try await Converter.convert(csv, to: .xlsx)[0]
        let sheets = try XLSX.read(xlsx)
        XCTAssertEqual(sheets.count, 1)
        XCTAssertEqual(sheets[0].rows, try CSV.parse(csvText, delimiter: ","))

        // And back: XLSX → CSV / PDF / HTML.
        let back = try await Converter.convert(xlsx, to: .csv)
        XCTAssertEqual(try CSV.parse(String(contentsOf: back[0], encoding: .utf8), delimiter: ","), sheets[0].rows)
        let xlsxPDF = try await Converter.convert(xlsx, to: .pdf)[0]
        XCTAssertTrue(PDFDocument(url: xlsxPDF)?.string?.contains("Carol") == true)
    }

    func testWideAndLongSheetPaginates() throws {
        let dir = try makeTempDir()
        let rows = [(0..<14).map { "Column \($0)" }] + (0..<400).map { r in (0..<14).map { "r\(r)c\($0)" } }
        let url = dir.appendingPathComponent("big.pdf")
        try TablePDF.write([Sheet(name: "Big", rows: rows)], to: url, title: "Big")
        let doc = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertGreaterThan(doc.pageCount, 3)
        let size = try XCTUnwrap(doc.page(at: 0)).bounds(for: .mediaBox).size
        XCTAssertGreaterThan(size.width, size.height, "wide tables go landscape")
        XCTAssertTrue(doc.page(at: 2)?.string?.contains("Column 0") == true, "header row repeats")
        XCTAssertTrue(doc.string?.contains("r399c13") == true)
    }

    func testXLSXDatesAndSharedStrings() throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("dates.xlsx")
        var zip = ZipWriter()
        zip.add("xl/workbook.xml", "<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets><sheet name=\"Data\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>")
        zip.add("xl/_rels/workbook.xml.rels", "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"x/worksheet\" Target=\"worksheets/sheet1.xml\"/></Relationships>")
        zip.add("xl/sharedStrings.xml", "<sst xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><si><t>When</t></si><si><r><t>Rich </t></r><r><t>text</t></r></si></sst>")
        zip.add("xl/styles.xml", "<styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><cellXfs><xf numFmtId=\"0\"/><xf numFmtId=\"14\"/></cellXfs></styleSheet>")
        zip.add("xl/worksheets/sheet1.xml", "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData><row r=\"1\"><c r=\"A1\" t=\"s\"><v>0</v></c><c r=\"C1\" t=\"s\"><v>1</v></c></row><row r=\"2\"><c r=\"A2\" s=\"1\"><v>45292</v></c><c r=\"B2\" t=\"b\"><v>1</v></c><c r=\"C2\"><v>0.1</v></c></row></sheetData></worksheet>")
        try zip.write(to: url)
        let sheet = try XCTUnwrap(XLSX.read(url).first)
        XCTAssertEqual(sheet.name, "Data")
        XCTAssertEqual(sheet.rows, [["When", "", "Rich text"], ["2024-01-01", "TRUE", "0.1"]])
    }
}

// MARK: - Images & media

final class ImageFormatTests: XCTestCase {
    func testIconAndLegacyFormats() async throws {
        let dir = try makeTempDir()
        let png = dir.appendingPathComponent("logo.png")
        try makePNG(at: png, size: 300, height: 200)
        for (format, minimumImages) in [(OutputFormat.ico, 6), (.icns, 5), (.bmp, 1), (.gif, 1)] {
            let out = try await Converter.convert(png, to: format)[0]
            XCTAssertEqual(out.pathExtension, format.fileExtension)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(out as CFURL, nil), "\(format)")
            XCTAssertGreaterThanOrEqual(CGImageSourceGetCount(source), minimumImages, "\(format)")
            XCTAssertNotNil(CGImageSourceCreateImageAtIndex(source, 0, nil), "\(format)")
        }
        // Icons are square even from a 3:2 source.
        let ico = try await Converter.convert(png, to: .ico)[0]
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(ico as CFURL, nil))
        let largest = (0..<CGImageSourceGetCount(source)).compactMap { CGImageSourceCreateImageAtIndex(source, $0, nil) }.max { $0.width < $1.width }
        XCTAssertEqual(largest?.width, 256)
        XCTAssertEqual(largest?.height, 256)
    }

    func testAVIF() async throws {
        try XCTSkipUnless(Converter.canEncodeAVIF, "no AVIF encoder")
        let dir = try makeTempDir()
        let png = dir.appendingPathComponent("photo.png")
        try makePNG(at: png, size: 64)
        let out = try await Converter.convert(png, to: .avif)[0]
        XCTAssertGreaterThan(try fileSize(out), 0)
        XCTAssertNotNil(try Converter.loadImage(out))
    }

    func testSVGInput() async throws {
        let dir = try makeTempDir()
        let svg = dir.appendingPathComponent("shape.svg")
        try """
        <svg xmlns="http://www.w3.org/2000/svg" width="120" height="80" viewBox="0 0 120 80">
        <rect width="120" height="80" fill="#ff6600"/><circle cx="60" cy="40" r="30" fill="#0044ff"/></svg>
        """.write(to: svg, atomically: true, encoding: .utf8)
        let png = try await Converter.convert(svg, to: .png)[0]
        let image = try Converter.loadImage(png)
        XCTAssertEqual(image.width, 1024)
        XCTAssertEqual(image.height, 683)
        for format in [OutputFormat.jpeg, .webp, .pdf, .ico] {
            let out = try await Converter.convert(svg, to: format)[0]
            XCTAssertGreaterThan(try fileSize(out), 0, "\(format)")
        }
    }

    func testAnimatedGIFToVideo() async throws {
        try XCTSkipIf(Tools.locate("ffmpeg") == nil, "ffmpeg not installed")
        let dir = try makeTempDir()
        let gif = dir.appendingPathComponent("anim.gif")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(gif as CFURL, UTType.gif.identifier as CFString, 3, nil))
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for i in 0..<3 {
            let ctx = CGContext(data: nil, width: 33, height: 21, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.setFillColor(CGColor(red: CGFloat(i) / 2, green: 0.5, blue: 0.2, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 33, height: 21))
            CGImageDestinationAddImage(dest, ctx.makeImage()!, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let mp4 = try await Converter.convert(gif, to: .mp4)[0]
        XCTAssertGreaterThan(try fileSize(mp4), 0)
        let probe = try await Tools.capture("ffprobe", ["-v", "error", "-show_entries", "stream=width,height", "-of", "csv=p=0", mp4.path])
        XCTAssertEqual(probe.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "32,20")

        if Tools.locate("gif2webp") != nil {
            let webp = try await Converter.convert(gif, to: .webp)[0]
            XCTAssertEqual(CGImageSourceCreateWithURL(webp as CFURL, nil).map(CGImageSourceGetCount), 3, "animation kept")
        }
    }
}

final class ZipTests: XCTestCase {
    func testRoundTripAndSafety() throws {
        var writer = ZipWriter()
        writer.add("mimetype", "application/epub+zip", compress: false)
        writer.add("dir/big.txt", String(repeating: "wheelie ", count: 5000))
        writer.add("dir/ünïcode.txt", "hi")
        let archive = try ZipArchive(data: writer.data())
        XCTAssertEqual(archive.names, ["mimetype", "dir/big.txt", "dir/ünïcode.txt"])
        XCTAssertEqual(try archive.readString("dir/big.txt")?.count, 40_000)
        XCTAssertEqual(try archive.readString("DIR/ÜNÏCODE.TXT".lowercased()), "hi")
        XCTAssertNil(try archive.read("missing"))
        XCTAssertEqual(CRC32.checksum(Data("123456789".utf8)), 0xCBF4_3926)

        var evil = ZipWriter()
        evil.add("../escape.txt", "x")
        XCTAssertThrowsError(try ZipArchive(data: evil.data()))
        XCTAssertThrowsError(try ZipArchive(data: Data("not a zip at all, just text".utf8)))
    }

    func testSystemUnzipAcceptsOurArchives() async throws {
        let dir = try makeTempDir()
        let url = dir.appendingPathComponent("test.zip")
        var writer = ZipWriter()
        writer.add("a.txt", String(repeating: "abc", count: 1000))
        writer.add("b/c.txt", "small")
        try writer.write(to: url)
        let result = try await Tools.capture("/usr/bin/unzip", ["-tq", url.path])
        XCTAssertTrue(result.stdout.contains("No errors"), result.stdout)
    }
}

// MARK: - Security

final class DocumentSecurityTests: XCTestCase {
    // 1. Decompression bombs

    /// One deflated entry whose headers claim `declaredSize` bytes (CRC unchecked by the reader).
    private func rawZip(name: String, deflated: Data, declaredSize: UInt32) -> Data {
        func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
        func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)] }
        let nameBytes = Array(name.utf8)
        var out: [UInt8] = le32(0x0403_4b50) + le16(20) + le16(0) + le16(8) + le16(0) + le16(0) + le32(0)
        out += le32(UInt32(deflated.count)) + le32(declaredSize) + le16(UInt16(nameBytes.count)) + le16(0) + nameBytes
        out += Array(deflated)
        let cdOffset = UInt32(out.count)
        var central: [UInt8] = le32(0x0201_4b50) + le16(20) + le16(20) + le16(0) + le16(8) + le16(0) + le16(0) + le32(0)
        central += le32(UInt32(deflated.count)) + le32(declaredSize) + le16(UInt16(nameBytes.count)) + le16(0) + le16(0) + le16(0)
        central += le16(0) + le32(0) + le32(0) + nameBytes
        out += central
        out += le32(0x0605_4b50) + le16(0) + le16(0) + le16(1) + le16(1) + le32(UInt32(central.count)) + le32(cdOffset) + le16(0)
        return Data(out)
    }

    func testLyingEntrySizeIsCutOffEarly() async throws {
        let bomb = try (Data(count: 50 * 1024 * 1024) as NSData).compressed(using: .zlib) as Data
        XCTAssertLessThan(bomb.count, 200_000)
        let archive = try ZipArchive(data: rawZip(name: "word/document.xml", deflated: bomb, declaredSize: 10))
        let start = Date()
        XCTAssertThrowsError(try archive.read("word/document.xml")) { error in
            XCTAssertTrue(error.localizedDescription.contains("larger than its header"), error.localizedDescription)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5, "stopped after the first chunk, not after inflating 50 MB")

        // The same bomb as a .docx: refused, nothing written.
        let dir = try makeTempDir()
        let docx = dir.appendingPathComponent("bomb.docx")
        try rawZip(name: "word/document.xml", deflated: bomb, declaredSize: 10).write(to: docx)
        do {
            _ = try await Converter.convert(docx, to: .txt)
            XCTFail("expected failure")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("bomb.txt").path))
    }

    func testInflationBudgetCoversEveryRead() throws {
        // Honest headers but a small budget: inflation stops at the budget, not at the end of the entry.
        let big = try (Data(count: 8 * 1024 * 1024) as NSData).compressed(using: .zlib) as Data
        let archive = try ZipArchive(data: rawZip(name: "big.bin", deflated: big, declaredSize: 8 * 1024 * 1024), budget: 1024 * 1024)
        XCTAssertThrowsError(try archive.read("big.bin")) { error in
            XCTAssertTrue(error.localizedDescription.contains("safety limit"), error.localizedDescription)
        }
        // Re-reading one entry (an image referenced thousands of times) draws from the same budget.
        var writer = ZipWriter()
        writer.add("img.bin", Data(repeating: 7, count: 1024 * 1024))
        let repeated = try ZipArchive(data: writer.data(), budget: 3 * 1024 * 1024 + 10)
        for _ in 0..<3 { XCTAssertEqual(try repeated.read("img.bin")?.count, 1024 * 1024) }
        XCTAssertThrowsError(try repeated.read("img.bin"))
    }

    // 2. DTDs / entity expansion

    private let lol = """
    <!DOCTYPE lolz [<!ENTITY lol "lololololololololol"><!ENTITY lol2 "&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;">\
    <!ENTITY lol3 "&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;&lol2;"><!ENTITY lol4 "&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;&lol3;">]>
    """

    private func docx(documentXML: Data) throws -> URL {
        let url = try makeTempDir().appendingPathComponent("evil.docx")
        var zip = ZipWriter()
        zip.add("[Content_Types].xml", "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"/>")
        zip.add("word/document.xml", documentXML)
        try zip.write(to: url)
        return url
    }

    private func bombDocument(padding: Int) -> String {
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!--" + String(repeating: "x", count: padding) + "-->\n" + lol
            + "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body><w:p><w:r><w:t>&lol4;</w:t></w:r></w:p></w:body></w:document>"
    }

    private func assertRefuses(_ body: () throws -> Any, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("DTD") || message.contains("encoding"), message, file: file, line: line)
        }
    }

    func testEntityBombAfterPaddingIsRefused() throws {
        let url = try docx(documentXML: Data(bombDocument(padding: 5 * 1024).utf8))
        assertRefuses { try DocxReader.read(url) }
        // Control: the same document without the DTD reads fine.
        let clean = bombDocument(padding: 5 * 1024).replacingOccurrences(of: lol, with: "").replacingOccurrences(of: "&lol4;", with: "fine")
        let model = try DocxReader.read(try docx(documentXML: Data(clean.utf8)))
        XCTAssertEqual(model.plainText.trimmingCharacters(in: .whitespacesAndNewlines), "fine")
    }

    func testUTF16EntityBombIsRefused() throws {
        let text = bombDocument(padding: 10).replacingOccurrences(of: "UTF-8", with: "UTF-16")
        var withBOM = Data([0xFF, 0xFE])
        withBOM.append(text.data(using: .utf16LittleEndian)!)
        assertRefuses { try DocxReader.read(try self.docx(documentXML: withBOM)) }
        assertRefuses { try DocxReader.read(try self.docx(documentXML: text.data(using: .utf16BigEndian)!)) }
        assertRefuses { try XML.document(text.data(using: .utf16LittleEndian)!, what: "Test") }
        // Unknown declared encodings and EBCDIC are refused outright.
        assertRefuses { try XML.document(Data("<?xml version=\"1.0\" encoding=\"UTF-7\"?><a/>".utf8), what: "Test") }
        assertRefuses { try XML.document(Data([0x4C, 0x6F, 0xA7, 0x94, 0x93]), what: "Test") }
    }

    func testDTDsRefusedInSpreadsheetsAndEPUB() throws {
        let dir = try makeTempDir()
        // XLSX shared strings with a late DTD.
        let xlsx = dir.appendingPathComponent("evil.xlsx")
        var zip = ZipWriter()
        zip.add("xl/workbook.xml", "<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheets><sheet name=\"S\" sheetId=\"1\"/></sheets></workbook>")
        zip.add("xl/sharedStrings.xml", "<!--" + String(repeating: "p", count: 6000) + "-->" + lol + "<sst><si><t>&lol4;</t></si></sst>")
        try zip.write(to: xlsx)
        assertRefuses { try XLSX.read(xlsx) }

        // EPUB chapter with an internal subset after padding.
        let epub = dir.appendingPathComponent("evil.epub")
        try makeEPUB(at: epub)
        let original = try ZipArchive(url: epub)
        var rebuilt = ZipWriter()
        for name in original.names {
            var data = try original.read(name)!
            if name.hasSuffix("ch2.xhtml") {
                data = Data(("<!--" + String(repeating: "q", count: 6000) + "-->" + lol.replacingOccurrences(of: "lolz", with: "html")
                             + "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body><p>&lol4;</p></body></html>").utf8)
            }
            rebuilt.add(name, data, compress: name != "mimetype")
        }
        try rebuilt.write(to: epub)
        assertRefuses { try EPUBReader.read(epub) }
        // Package XML may not have any DOCTYPE at all.
        assertRefuses { try XML.document(Data("<!DOCTYPE container><container/>".utf8), what: "Test") }

        // HTML with an internal subset is refused; a plain HTML5 doctype is fine.
        let html = dir.appendingPathComponent("evil.html")
        try "<!DOCTYPE html [<!ENTITY x \"y\">]><html><body><p>&x;</p></body></html>".write(to: html, atomically: true, encoding: .utf8)
        assertRefuses { try HTMLReader.read(html) }
        try "<!DOCTYPE html><html><body><p>ok</p></body></html>".write(to: html, atomically: true, encoding: .utf8)
        XCTAssertEqual(try HTMLReader.read(html).plainText.trimmingCharacters(in: .whitespacesAndNewlines), "ok")
    }

    // 3. Link schemes

    func testUnsafeLinksNeverReachOutputs() async throws {
        let dir = try makeTempDir()
        let html = dir.appendingPathComponent("links.html")
        try """
        <html><body><p><a href="javascript:alert(1)">evil</a> <a href="JaVaScRiPt:alert(2)">caps</a>
        <a href="file:///etc/passwd">local</a> <a href="data:text/html,hi">data</a> <a href=" javascript:alert(3)">space</a>
        <a href="https://safe.example/ok">safe</a> <a href="#top">anchor</a></p></body></html>
        """.write(to: html, atomically: true, encoding: .utf8)
        let md = dir.appendingPathComponent("links.md")
        try "[evil](javascript:alert(1)) [local](file:///etc/passwd) [rel](../../etc/passwd) <javascript:alert(4)> [safe](https://safe.example/ok)\n"
            .write(to: md, atomically: true, encoding: .utf8)
        let docx = dir.appendingPathComponent("links.docx")
        var zip = ZipWriter()
        zip.add("word/_rels/document.xml.rels", """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="r1" Type="x/hyperlink" Target="javascript:alert(1)" TargetMode="External"/>\
        <Relationship Id="r2" Type="x/hyperlink" Target="file:///etc/passwd" TargetMode="External"/>\
        <Relationship Id="r3" Type="x/hyperlink" Target="https://safe.example/ok" TargetMode="External"/></Relationships>
        """)
        zip.add("word/document.xml", """
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><w:body><w:p>\
        <w:hyperlink r:id="r1"><w:r><w:t>evil</w:t></w:r></w:hyperlink><w:r><w:t xml:space="preserve"> </w:t></w:r>\
        <w:hyperlink r:id="r2"><w:r><w:t>local</w:t></w:r></w:hyperlink><w:r><w:t xml:space="preserve"> </w:t></w:r>\
        <w:r><w:fldChar w:fldCharType="begin"/></w:r><w:r><w:instrText>HYPERLINK "javascript:alert(5)"</w:instrText></w:r>\
        <w:r><w:fldChar w:fldCharType="separate"/></w:r><w:r><w:t>field</w:t></w:r><w:r><w:fldChar w:fldCharType="end"/></w:r>\
        <w:r><w:t xml:space="preserve"> </w:t></w:r><w:hyperlink r:id="r3"><w:r><w:t>safe</w:t></w:r></w:hyperlink></w:p></w:body></w:document>
        """)
        try zip.write(to: docx)
        let rtf = dir.appendingPathComponent("links.rtf")
        let rich = NSMutableAttributedString(string: "evil ", attributes: [.link: URL(string: "javascript:alert(1)")!])
        rich.append(NSAttributedString(string: "local ", attributes: [.link: URL(string: "file:///etc/passwd")!]))
        rich.append(NSAttributedString(string: "safe", attributes: [.link: URL(string: "https://safe.example/ok")!]))
        try rich.data(from: NSRange(location: 0, length: rich.length),
                      documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]).write(to: rtf)

        let checked: Set<OutputFormat> = [.html, .markdown, .docx, .pdf, .rtf, .odt]
        for source in [html, md, docx, rtf] {
            for format in OutputFormat.targets(for: [source]) where checked.contains(format) {
                let out = try await Converter.convert(source, to: format)[0]
                let label = "\(source.lastPathComponent) → \(format)"
                let targets = try linkTargets(of: out)
                XCTAssertTrue(targets.allSatisfy { $0.hasPrefix("https://") || $0.hasPrefix("#") }, "\(label): \(targets)")
                if format != .odt {
                    XCTAssertTrue(targets.contains("https://safe.example/ok"), "\(label) keeps the safe link: \(targets)")
                }
                let raw = try rawText(of: out).lowercased()
                for bad in ["javascript:alert(1)", "javascript:alert(5)", "file:///etc", "data:text"] {
                    XCTAssertFalse(raw.contains(bad), "\(label) contains \(bad)")
                }
                XCTAssertTrue(try readBack(out).contains("evil"), "\(label) keeps the link text")
            }
        }
        XCTAssertNil(LinkPolicy.sanitize("java\tscript:alert(1)"))
        XCTAssertNil(LinkPolicy.sanitize("vbscript:x"))
        XCTAssertNil(LinkPolicy.sanitize("https://"))
        XCTAssertEqual(LinkPolicy.sanitize("mailto:a@b.c"), "mailto:a@b.c")
        XCTAssertNil(DocRun("x", link: "javascript:1").link)
    }

    /// Every link target a reader of `url` would follow.
    private func linkTargets(of url: URL) throws -> [String] {
        func matches(_ pattern: String, in text: String) -> [String] {
            let regex = try! NSRegularExpression(pattern: pattern)
            return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
                Range($0.range(at: 1), in: text).map { String(text[$0]) }
            }
        }
        let text = try rawText(of: url)
        switch url.pathExtension {
        case "pdf":
            let doc = try XCTUnwrap(PDFDocument(url: url))
            return (0..<doc.pageCount).flatMap { doc.page(at: $0)!.annotations.compactMap { $0.url?.absoluteString } }
        case "html": return matches(#"href\s*=\s*"([^"]*)""#, in: text)
        case "md": return matches(#"(?<!!)\[[^\]]*\]\(([^)]*)\)"#, in: text)
        case "docx": return matches(#"Target="([^"]*)" TargetMode="External""#, in: text)
        case "rtf": return matches(#"HYPERLINK\s+"([^"]*)""#, in: text)
        case "odt": return matches(#"xlink:href="([^"]*)""#, in: text)
        default: return []
        }
    }

    /// All text inside a file: the file itself, or every XML part of a zip package.
    private func rawText(of url: URL) throws -> String {
        if ["docx", "odt"].contains(url.pathExtension) {
            let zip = try ZipArchive(url: url)
            return try zip.names.filter { $0.hasSuffix(".xml") || $0.hasSuffix(".rels") }.compactMap { try zip.readString($0) }.joined()
        }
        return String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    // 4. Local files pulled in by reference

    func testImageReferencesStayInsideTheDocumentFolder() async throws {
        let root = try makeTempDir()
        let docDir = root.appendingPathComponent("doc"), secretDir = root.appendingPathComponent("secret")
        try FileManager.default.createDirectory(at: docDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secretDir, withIntermediateDirectories: true)
        let secret = secretDir.appendingPathComponent("secret.png")
        try makePNG(at: secret, size: 33, height: 17)
        try makePNG(at: docDir.appendingPathComponent("sibling.png"), size: 20)
        try FileManager.default.createSymbolicLink(at: docDir.appendingPathComponent("link.png"), withDestinationURL: secret)
        try FileManager.default.createSymbolicLink(at: docDir.appendingPathComponent("sublink"), withDestinationURL: secretDir)
        let refs = [secret.path, "file://" + secret.path, "../secret/secret.png", "%2E%2E/secret/secret.png", "link.png",
                    "sublink/secret.png", "sibling.png"]

        let html = docDir.appendingPathComponent("page.html")
        try ("<html><body>" + refs.map { "<p>x</p><img src=\"\($0)\">" }.joined() + "</body></html>")
            .write(to: html, atomically: true, encoding: .utf8)
        let md = docDir.appendingPathComponent("notes.md")
        try refs.map { "x\n\n![img](\($0))\n" }.joined(separator: "\n").write(to: md, atomically: true, encoding: .utf8)

        for source in [html, md] {
            let model = try DocumentConverter.load(source, kind: .document).model
            let images = model.blocks.compactMap { block -> DocImage? in if case .image(let i) = block { return i } else { return nil } }
            XCTAssertEqual(images.map { "\($0.pixelWidth)x\($0.pixelHeight)" }, ["20x20"], "\(source.lastPathComponent): only the sibling")
            let docx = try await Converter.convert(source, to: .docx)[0]
            XCTAssertEqual(try ZipArchive(url: docx).names.filter { $0.hasPrefix("word/media/") }.count, 1, "\(source.lastPathComponent) → DOCX")
            let pdf = try await Converter.convert(source, to: .pdf)[0]
            XCTAssertEqual(drawnImageSizes(pdf), ["20x20"], "\(source.lastPathComponent) → PDF")
        }
    }

    func testRTFDWithSymlinkedAttachmentDoesNotLeakOrCrash() async throws {
        let root = try makeTempDir()
        let secret = root.appendingPathComponent("secret.png")
        try makePNG(at: secret, size: 33, height: 17)
        let rtfd = root.appendingPathComponent("doc.rtfd")
        try FileManager.default.createDirectory(at: rtfd, withIntermediateDirectories: true)
        try makePNG(at: rtfd.appendingPathComponent("ok.png"), size: 20)
        try FileManager.default.createSymbolicLink(at: rtfd.appendingPathComponent("link.png"), withDestinationURL: secret)
        try ("{\\rtf1\\ansi\\ansicpg1252 Hello {{\\NeXTGraphic link.png \\width660 \\height340}\u{00AC}} and "
             + "{{\\NeXTGraphic ok.png \\width400 \\height400}\u{00AC}} end}")
            .write(to: rtfd.appendingPathComponent("TXT.rtf"), atomically: true, encoding: .windowsCP1252)
        let model = try DocumentConverter.load(rtfd, kind: .document).model
        let images = model.blocks.compactMap { block -> DocImage? in if case .image(let i) = block { return i } else { return nil } }
        XCTAssertEqual(images.map(\.pixelWidth), [20])
        let docx = try await Converter.convert(rtfd, to: .docx)[0]
        XCTAssertEqual(try ZipArchive(url: docx).names.filter { $0.hasPrefix("word/media/") }.count, 1)
        let pdf = try await Converter.convert(rtfd, to: .pdf)[0]
        XCTAssertTrue(PDFDocument(url: pdf)?.string?.contains("Hello") == true)
        XCTAssertEqual(drawnImageSizes(pdf), ["20x20"], "only ok.png is drawn (the cell may paint it twice in one spot)")
    }

    /// Distinct sizes (points) of the pictures painted on every page of a PDF.
    private func drawnImageSizes(_ url: URL) -> Set<String> {
        guard let doc = PDFDocument(url: url) else { return [] }
        let rects = (0..<doc.pageCount).flatMap { PDFReflow.imageRects(doc.page(at: $0)!) }
        return Set(rects.map { "\(Int($0.width.rounded()))x\(Int($0.height.rounded()))" })
    }
}

// MARK: - Fixtures

private let sampleMarkdown = """
---
title: Front Matter Title
---
# Project Notes

Some **bold**, *italic*, `inline` code and [a link](https://example.com).
A soft-wrapped second line.

## Lists

- Apple
- Banana
    - Nested

1. First
2. Second

> A quoted remark.

```
let x = 1
```

| Col A | Col B |
| --- | --- |
| Cell A1 | Cell B1 |
| Cell A2 | Cell B2 |

![Picture](pic.png)

---

The end.
"""

private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wheelie-docs-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func fileSize(_ url: URL) throws -> Int {
    try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
}

/// Text content of any output format, for assertions.
private func readBack(_ url: URL) throws -> String {
    switch url.pathExtension.lowercased() {
    case "pdf": return PDFDocument(url: url)?.string ?? ""
    case "docx": return try NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil).string
    case "odt": return try NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.openDocument], documentAttributes: nil).string
    case "rtf": return try NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil).string
    default: return try String(contentsOf: url, encoding: .utf8)
    }
}

/// Heading (24pt bold), a paragraph with a bold word, a two-item bullet list.
private func makeRichText() -> NSAttributedString {
    let out = NSMutableAttributedString()
    out.append(NSAttributedString(string: "Quarterly Report\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 24)]))
    let body: [NSAttributedString.Key: Any] = [.font: NSFont(name: "Helvetica", size: 12)!]
    out.append(NSAttributedString(string: "Revenue grew and the outlook is ", attributes: body))
    out.append(NSAttributedString(string: "bold", attributes: [.font: NSFont(name: "Helvetica-Bold", size: 12)!]))
    out.append(NSAttributedString(string: " for next year. This sentence makes the body text the dominant size.\n", attributes: body))
    let list = NSTextList(markerFormat: .disc, options: 0)
    let style = NSMutableParagraphStyle()
    style.textLists = [list]
    for item in ["First item", "Second item"] {
        out.append(NSAttributedString(string: "\t•\t\(item)\n", attributes: body.merging([.paragraphStyle: style]) { $1 }))
    }
    return out
}

/// Two-page PDF: title, heading, a long wrapped paragraph with a bold word, bullets, a picture,
/// and a "Page N of 2" footer on each page.
private func makeTextPDF(at url: URL) throws {
    var model = DocModel(title: "Paper")
    let long = "This paragraph is long enough to wrap across several lines of the page, so the reflow has to join "
        + "those lines back together into a single paragraph without inserting breaks, and it mentions an "
    model.blocks = [
        .paragraph(DocParagraph(.heading(1), runs: [DocRun("Research Paper")])),
        .paragraph(DocParagraph(.heading(2), runs: [DocRun("Introduction")])),
        .paragraph(DocParagraph(runs: [DocRun(long), DocRun("important", style: .bold),
                                       DocRun(" detail before the final sentence of the paragraph.")])),
        .paragraph(DocParagraph(runs: [DocRun("A second paragraph follows the first one.")])),
        .paragraph(DocParagraph(.listItem(ordered: false, level: 1), runs: [DocRun("First bullet")])),
        .paragraph(DocParagraph(.listItem(ordered: false, level: 1), runs: [DocRun("Second bullet")])),
    ]
    let ctx = CGContext(data: nil, width: 300, height: 200, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0.1, green: 0.5, blue: 0.9, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
    model.blocks.append(.image(DocImage(cgImage: ctx.makeImage()!, displayWidth: 150)!))
    model.blocks.append(.paragraph(DocParagraph(runs: [DocRun("Text after the picture.")])))
    model.blocks.append(.pageBreak)
    model.blocks.append(.paragraph(DocParagraph(.heading(2), runs: [DocRun("Results")])))
    model.blocks.append(.paragraph(DocParagraph(runs: [DocRun("The results section has its own text on page two.")])))
    let body = AttributedBuilder.build(model)
    let raw = dirOf(url).appendingPathComponent("raw-" + url.lastPathComponent)
    try PDFLayout.write(body, to: raw)
    // Redraw each page with a "Page N of M" footer so the running-footer filter has something to remove.
    let doc = PDFDocument(url: raw)!
    var box = CGRect(origin: .zero, size: doc.page(at: 0)!.bounds(for: .mediaBox).size)
    let context = CGContext(url as CFURL, mediaBox: &box, nil)!
    for i in 0..<doc.pageCount {
        let page = doc.page(at: i)!
        context.beginPDFPage(nil)
        page.draw(with: .mediaBox, to: context)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Page \(i + 1) of \(doc.pageCount)",
                                                                       attributes: [.font: NSFont(name: "Helvetica", size: 9)!]))
        context.textPosition = CGPoint(x: box.width / 2 - 25, y: 30)
        CTLineDraw(line, context)
        context.endPDFPage()
    }
    context.closePDF()
}

private func dirOf(_ url: URL) -> URL { url.deletingLastPathComponent() }

private func makePNG(at url: URL, size: Int, height: Int? = nil) throws {
    let h = height ?? size
    let ctx = CGContext(data: nil, width: size, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 1, green: 0.4, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: size / 2, height: h))
    ctx.setFillColor(CGColor(red: 0, green: 0.3, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: size / 2, y: 0, width: size - size / 2, height: h / 2))
    try Converter.writeImage(ctx.makeImage()!, to: url, type: .png)
}

/// EPUB 3 with two chapters (manifest lists chapter two first; the spine decides), an image,
/// and a chapter that uses an HTML entity XML can't parse.
private func makeEPUB(at url: URL, encrypted: Bool = false) throws {
    let dir = try makeTempDir()
    let png = dir.appendingPathComponent("pic.png")
    try makePNG(at: png, size: 24)
    var zip = ZipWriter()
    zip.add("mimetype", "application/epub+zip", compress: false)
    zip.add("META-INF/container.xml", """
    <?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">\
    <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
    """)
    if encrypted {
        zip.add("META-INF/encryption.xml", """
        <encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container" xmlns:enc="http://www.w3.org/2001/04/xmlenc#">\
        <enc:EncryptedData><enc:EncryptionMethod Algorithm="http://www.w3.org/2001/04/xmlenc#aes128-cbc"/></enc:EncryptedData></encryption>
        """)
    }
    zip.add("OEBPS/content.opf", """
    <?xml version="1.0" encoding="UTF-8"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">\
    <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Test Book</dc:title><dc:identifier id="id">x</dc:identifier></metadata>\
    <manifest><item id="c2" href="text/ch2.xhtml" media-type="application/xhtml+xml"/>\
    <item id="c1" href="text/ch1.xhtml" media-type="application/xhtml+xml"/>\
    <item id="img" href="images/pic.png" media-type="image/png"/></manifest>\
    <spine><itemref idref="c1"/><itemref idref="c2"/></spine></package>
    """)
    zip.add("OEBPS/text/ch1.xhtml", """
    <?xml version="1.0" encoding="UTF-8"?><!DOCTYPE html><html xmlns="http://www.w3.org/1999/xhtml"><head><title>One</title></head>\
    <body><h1>Chapter One</h1><p>Alpha paragraph with <em>emphasis</em>.</p><p><img src="../images/pic.png" alt="pic"/></p></body></html>
    """)
    zip.add("OEBPS/text/ch2.xhtml", """
    <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Two</title></head>\
    <body><h1>Chapter Two</h1><p>Beta paragraph with a non&nbsp;breaking space.</p></body></html>
    """)
    zip.add("OEBPS/images/pic.png", try Data(contentsOf: png), compress: false)
    try zip.write(to: url)
}
