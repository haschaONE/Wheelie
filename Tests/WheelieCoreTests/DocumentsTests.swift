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

// MARK: - Fixtures

let sampleMarkdown = """
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

func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wheelie-docs-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

func fileSize(_ url: URL) throws -> Int {
    try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
}

/// Text content of any output format, for assertions.
func readBack(_ url: URL) throws -> String {
    switch url.pathExtension.lowercased() {
    case "pdf": return PDFDocument(url: url)?.string ?? ""
    case "docx": return try NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML], documentAttributes: nil).string
    case "odt": return try NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.openDocument], documentAttributes: nil).string
    case "rtf": return try NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil).string
    default: return try String(contentsOf: url, encoding: .utf8)
    }
}

/// Heading (24pt bold), a paragraph with a bold word, a two-item bullet list.
func makeRichText() -> NSAttributedString {
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
func makeTextPDF(at url: URL) throws {
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

func makePNG(at url: URL, size: Int, height: Int? = nil) throws {
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
func makeEPUB(at url: URL, encrypted: Bool = false) throws {
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
    <?xml version="1.0" encoding="UTF-8"?><html xmlns="http://www.w3.org/1999/xhtml"><head><title>One</title></head>\
    <body><h1>Chapter One</h1><p>Alpha paragraph with <em>emphasis</em>.</p><p><img src="../images/pic.png" alt="pic"/></p></body></html>
    """)
    zip.add("OEBPS/text/ch2.xhtml", """
    <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Two</title></head>\
    <body><h1>Chapter Two</h1><p>Beta paragraph with a non&nbsp;breaking space.</p></body></html>
    """)
    zip.add("OEBPS/images/pic.png", try Data(contentsOf: png), compress: false)
    try zip.write(to: url)
}
