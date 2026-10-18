import CoreGraphics
import CoreText
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import XCTest
@testable import WheelieCore

final class PDFPagePlanTests: XCTestCase {
    func testIdentityAndEditing() {
        var plan = PDFPagePlan.identity(pageCounts: [3, 2])
        XCTAssertEqual(plan.pages.map(\.key), [PageKey(file: 0, page: 0), PageKey(file: 0, page: 1), PageKey(file: 0, page: 2),
                                              PageKey(file: 1, page: 0), PageKey(file: 1, page: 1)])
        XCTAssertTrue(plan.isPermutation(pageCounts: [3, 2]))
        let ids = plan.pages.map(\.id)

        plan.rotate([ids[0], ids[3]])
        plan.rotate([ids[3]])
        XCTAssertEqual(plan.pages.map(\.rotation), [90, 0, 0, 180, 0])
        plan.rotate([ids[3]], by: 270)
        XCTAssertEqual(plan.pages[3].rotation, 90)

        plan.delete([ids[1]])
        XCTAssertEqual(plan.count, 4)
        XCTAssertFalse(plan.isPermutation(pageCounts: [3, 2]))

        let copies = plan.duplicate([ids[0]])
        XCTAssertEqual(copies.count, 1)
        XCTAssertEqual(plan.count, 5)
        XCTAssertEqual(plan.pages[1].key, PageKey(file: 0, page: 0))
        XCTAssertEqual(plan.pages[1].rotation, 90, "a duplicate keeps the rotation")
        XCTAssertNotEqual(plan.pages[1].id, ids[0])

        // [p0, p0', p2, q0, q1] → drop p0 on q0 (forward: lands after it)
        plan.move([ids[0]], onto: ids[3])
        XCTAssertEqual(plan.pages.map(\.key), [PageKey(file: 0, page: 0), PageKey(file: 0, page: 2), PageKey(file: 1, page: 0),
                                              PageKey(file: 0, page: 0), PageKey(file: 1, page: 1)])
        XCTAssertEqual(plan.pages[3].id, ids[0])
        // Backward: q1 onto the first page lands before it.
        plan.move([ids[4]], onto: plan.pages[0].id)
        XCTAssertEqual(plan.pages[0].id, ids[4])
        plan.move([ids[4]], toOffset: 99)
        XCTAssertEqual(plan.pages.last?.id, ids[4])

        plan.regroup(fileOrder: [1, 0])
        XCTAssertEqual(plan.pages.map(\.file), [1, 1, 0, 0, 0])

        plan.resetOrder(pageCounts: [3, 2], fileOrder: [0, 1])
        XCTAssertEqual(plan.count, 5)
        XCTAssertTrue(plan.isPermutation(pageCounts: [3, 2]))
        XCTAssertEqual(plan.pages.map(\.rotation), [90, 0, 0, 90, 0], "reset keeps rotations")
    }

    func testValidation() throws {
        XCTAssertThrowsError(try PDFPagePlan(order: [0, 0, 1], pageCount: 3)) {
            XCTAssertEqual($0.localizedDescription, "The page order must include every page exactly once.")
        }
        XCTAssertThrowsError(try PDFPagePlan(order: [0, 1], pageCount: 3)) {
            XCTAssertEqual($0.localizedDescription, "The page order must include every page exactly once.")
        }
        XCTAssertThrowsError(try PDFPagePlan(order: [], pageCount: 0)) {
            XCTAssertEqual($0.localizedDescription, "This PDF has no pages.")
        }
        XCTAssertThrowsError(try PDFPagePlan(order: [1, 0], rotations: [0: 45], pageCount: 2))
        let plan = try PDFPagePlan(order: [2, 0, 1], rotations: [2: 90], pageCount: 3)
        XCTAssertEqual(plan.pages.map(\.page), [2, 0, 1])
        XCTAssertEqual(plan.pages.map(\.rotation), [90, 0, 0])

        XCTAssertThrowsError(try PDFPagePlan().validate(pageCounts: [2])) {
            XCTAssertEqual($0.localizedDescription, "Keep at least one page.")
        }
        XCTAssertThrowsError(try PDFPagePlan(pages: [PlannedPage(file: 0, page: 5)]).validate(pageCounts: [2]))
        XCTAssertThrowsError(try PDFPagePlan(pages: [PlannedPage(file: 1, page: 0)]).validate(pageCounts: [2]))
        XCTAssertNoThrow(try PDFPagePlan(pages: [PlannedPage(file: 0, page: 1)]).validate(pageCounts: [2]))
    }

    func testEqualWidthScales() {
        let scales = PDFPageScaling.equalWidthScales(for: [CGSize(width: 612, height: 792), CGSize(width: 306, height: 396),
                                                          CGSize(width: 842, height: 595)])
        XCTAssertEqual(scales[0], 0.5, accuracy: 0.0001)
        XCTAssertEqual(scales[1], 1, accuracy: 0.0001)
        XCTAssertEqual(scales[2], 306.0 / 842.0, accuracy: 0.0001)
        XCTAssertEqual(PDFPageScaling.equalWidthScales(for: []), [])
    }
}

final class PDFOrganizerTests: XCTestCase {
    func testOrganizeReordersRotatesDeletesAndDuplicates() throws {
        let dir = try pdfTempDir()
        let pdf = dir.appendingPathComponent("report.pdf")
        try makePDF(at: pdf, sizes: [CGSize(width: 100, height: 400), CGSize(width: 200, height: 400), CGSize(width: 300, height: 400)])
        let png = dir.appendingPathComponent("photo.png")
        try makeImage(at: png, width: 64, height: 48)

        var plan = PDFPagePlan.identity(pageCounts: [3, 1])
        let ids = plan.pages.map(\.id)
        plan.move([ids[2]], toOffset: 0)            // p3, p1, p2, img
        plan.rotate([ids[2]])                        // p3 turned 90°
        plan.delete([ids[1]])                        // p3, p1, img
        plan.duplicate([ids[3]])                     // p3, p1, img, img
        let out = try PDFOrganizer.organize(files: [pdf, png], plan: plan)
        XCTAssertEqual(out.lastPathComponent, "report organized.pdf")

        let doc = try XCTUnwrap(PDFDocument(url: out))
        XCTAssertEqual(doc.pageCount, 4)
        XCTAssertEqual(doc.page(at: 0)?.bounds(for: .cropBox).width, 300)
        XCTAssertEqual(doc.page(at: 0)?.rotation, 90)
        XCTAssertEqual(PDFPageGeometry.displayedSize(of: doc.page(at: 0)!), CGSize(width: 400, height: 300))
        XCTAssertEqual(doc.page(at: 1)?.bounds(for: .cropBox).width, 100)
        XCTAssertEqual(doc.page(at: 1)?.rotation, 0)
        XCTAssertEqual(doc.page(at: 2)?.bounds(for: .cropBox).size, CGSize(width: 64, height: 48), "image page = pixels at 72 dpi")
        XCTAssertEqual(doc.page(at: 3)?.bounds(for: .cropBox).size, CGSize(width: 64, height: 48))

        // Never overwrites: a second run gets a new name.
        let again = try PDFOrganizer.organize(files: [pdf, png], plan: plan)
        XCTAssertEqual(again.lastPathComponent, "report organized 2.pdf")
    }

    func testOrganizeRejectsBadPlans() throws {
        let dir = try pdfTempDir()
        let pdf = dir.appendingPathComponent("a.pdf")
        try makePDF(at: pdf, sizes: [CGSize(width: 100, height: 100)])
        XCTAssertThrowsError(try PDFOrganizer.organize(files: [pdf], plan: PDFPagePlan())) {
            XCTAssertEqual($0.localizedDescription, "Keep at least one page.")
        }
        XCTAssertThrowsError(try PDFOrganizer.organize(files: [pdf], plan: PDFPagePlan(pages: [PlannedPage(file: 0, page: 3)])))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("a organized.pdf").path))
    }

    func testEqualWidths() throws {
        let dir = try pdfTempDir()
        let pdf = dir.appendingPathComponent("mixed.pdf")
        try makePDF(at: pdf, sizes: [CGSize(width: 612, height: 792), CGSize(width: 306, height: 396), CGSize(width: 842, height: 595)])
        var plan = PDFPagePlan.identity(pageCounts: [3])
        plan.rotate([plan.pages[1].id])   // 306×396 turned: displayed 396 wide → the narrowest is now 396
        let out = try PDFOrganizer.organize(files: [pdf], plan: plan, equalizeWidths: true)
        let doc = try XCTUnwrap(PDFDocument(url: out))
        XCTAssertEqual(doc.pageCount, 3)
        let sizes = (0..<3).map { PDFPageGeometry.displayedSize(of: doc.page(at: $0)!) }
        for size in sizes { XCTAssertEqual(size.width, 396, accuracy: 0.5) }
        XCTAssertEqual(sizes[0].height, 792 * 396 / 612, accuracy: 0.5)
        XCTAssertEqual(sizes[1].height, 306, accuracy: 0.5)
        XCTAssertEqual(sizes[2].height, 595 * 396 / 842, accuracy: 0.5)
    }

    func testCombineUsesFinderNameOrder() throws {
        let dir = try pdfTempDir()
        let names = ["file 10.pdf": 110, "file 2.pdf": 102, "File 1.pdf": 101]
        for (name, width) in names {
            try makePDF(at: dir.appendingPathComponent(name), sizes: [CGSize(width: width, height: 200)])
        }
        let png = dir.appendingPathComponent("file 3.png")
        try makeImage(at: png, width: 64, height: 48)
        let files = ["file 10.pdf", "file 3.png", "File 1.pdf", "file 2.pdf"].map { dir.appendingPathComponent($0) }
        XCTAssertEqual(PDFSourceLoader.sortedByName(files).map(\.lastPathComponent),
                       ["File 1.pdf", "file 2.pdf", "file 3.png", "file 10.pdf"])

        let out = try PDFMerger.combine(files)
        XCTAssertEqual(out.lastPathComponent, "File 1 combined.pdf")
        let doc = try XCTUnwrap(PDFDocument(url: out))
        XCTAssertEqual((0..<doc.pageCount).map { doc.page(at: $0)!.bounds(for: .cropBox).width }, [101, 102, 64, 110])
    }
}

final class PDFSplitTests: XCTestCase {
    func testRangeParser() throws {
        XCTAssertEqual(try PageRangeParser.parse("1-3, 4, 7-9", pageCount: 10), [1...3, 4...4, 7...9])
        XCTAssertEqual(try PageRangeParser.parse(" 2 – 5 ; 8,", pageCount: 10), [2...5, 8...8])
        XCTAssertEqual(try PageRangeParser.parse("7-", pageCount: 10), [7...10])
        XCTAssertEqual(try PageRangeParser.parse("3-3", pageCount: 3), [3...3])

        for bad in ["", " , ", "abc", "0", "11", "1-11", "-3", "1-2-3", "2.5", "５"] {
            XCTAssertThrowsError(try PageRangeParser.parse(bad, pageCount: 10), "“\(bad)” should be rejected")
        }
        XCTAssertThrowsError(try PageRangeParser.parse("5-3", pageCount: 10)) {
            XCTAssertEqual($0.localizedDescription, "The range 5-3 runs backwards. Write it as 3-5.")
        }
        XCTAssertThrowsError(try PageRangeParser.parse("12", pageCount: 10)) {
            XCTAssertEqual($0.localizedDescription, "Page 12 doesn't exist; this PDF has 10 pages.")
        }
        XCTAssertEqual(PageRangeParser.describe([0, 1, 2, 4, 6, 7]), "1-3, 5, 7-8")
    }

    func testGroups() throws {
        XCTAssertEqual(try PDFSplitter.groups(for: .everyPage, pageCount: 3), [[0], [1], [2]])
        XCTAssertEqual(try PDFSplitter.groups(for: .everyNPages(2), pageCount: 5), [[0, 1], [2, 3], [4]])
        XCTAssertEqual(try PDFSplitter.groups(for: .ranges([1...2, 2...3]), pageCount: 3), [[0, 1], [1, 2]])
        XCTAssertEqual(try PDFSplitter.groups(for: .extract([3, 1, 3]), pageCount: 3), [[0, 2]])
        XCTAssertThrowsError(try PDFSplitter.groups(for: .everyNPages(0), pageCount: 3))
        XCTAssertThrowsError(try PDFSplitter.groups(for: .extract([]), pageCount: 3))
        XCTAssertThrowsError(try PDFSplitter.groups(for: .ranges([2...4]), pageCount: 3))
        XCTAssertThrowsError(try PDFSplitter.groups(for: .everyPage, pageCount: 0)) {
            XCTAssertEqual($0.localizedDescription, "This PDF has no pages.")
        }
    }

    func testSplitWritesFiles() throws {
        let dir = try pdfTempDir()
        let pdf = dir.appendingPathComponent("doc.pdf")
        try makePDF(at: pdf, sizes: (1...5).map { CGSize(width: 100 + $0, height: 200) })

        // Every page → a new folder "doc pages".
        let folders = try PDFSplitter.split(pdf, mode: .everyPage, intoFolder: true)
        XCTAssertEqual(folders.map(\.lastPathComponent), ["doc pages"])
        let files = try FileManager.default.contentsOfDirectory(atPath: folders[0].path).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        XCTAssertEqual(files, ["doc p1.pdf", "doc p2.pdf", "doc p3.pdf", "doc p4.pdf", "doc p5.pdf"])
        let p4 = try XCTUnwrap(PDFDocument(url: folders[0].appendingPathComponent("doc p4.pdf")))
        XCTAssertEqual(p4.pageCount, 1)
        XCTAssertEqual(p4.page(at: 0)?.bounds(for: .cropBox).width, 104)

        // A second folder split doesn't reuse the first folder.
        let second = try PDFSplitter.split(pdf, mode: .everyNPages(2), intoFolder: true)
        XCTAssertEqual(second.map(\.lastPathComponent), ["doc pages 2"])
        let chunks = try FileManager.default.contentsOfDirectory(at: second[0], includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        XCTAssertEqual(chunks.map(\.lastPathComponent), ["doc p1-2.pdf", "doc p3-4.pdf", "doc p5.pdf"])
        XCTAssertEqual(chunks.map { PDFDocument(url: $0)?.pageCount }, [2, 2, 1])

        // Custom ranges next to the original.
        let ranges = try PDFSplitter.split(pdf, mode: .ranges(try PageRangeParser.parse("1-3, 5", pageCount: 5)), intoFolder: false)
        XCTAssertEqual(ranges.map(\.lastPathComponent), ["doc p1-3.pdf", "doc p5.pdf"])
        XCTAssertEqual(ranges.map { PDFDocument(url: $0)?.pageCount }, [3, 1])
        XCTAssertEqual(ranges[0].deletingLastPathComponent().standardizedFileURL, dir.standardizedFileURL)

        // Extract selected pages into one file.
        let extracted = try PDFSplitter.split(pdf, mode: .extract([4, 1, 3]), intoFolder: false)
        XCTAssertEqual(extracted.map(\.lastPathComponent), ["doc p1, 3-4.pdf"])
        let doc = try XCTUnwrap(PDFDocument(url: extracted[0]))
        XCTAssertEqual((0..<doc.pageCount).map { doc.page(at: $0)!.bounds(for: .cropBox).width }, [101, 103, 104])

        XCTAssertEqual(PDFSourceLoader.pageCount(of: pdf), 5)
    }
}

final class ImagesToPDFTests: XCTestCase {
    func testPageSizes() {
        let landscape = CGSize(width: 400, height: 300), portrait = CGSize(width: 300, height: 400)
        func size(_ options: ImagePDFOptions, _ image: CGSize) -> CGSize { options.pageSize(for: image) }

        XCTAssertEqual(size(ImagePDFOptions(), landscape), CGSize(width: 400, height: 300))
        XCTAssertEqual(size(ImagePDFOptions(margin: .medium), landscape), CGSize(width: 472, height: 372))
        assertSize(size(ImagePDFOptions(pageSize: .a4), landscape), 841.89, 595.28)
        assertSize(size(ImagePDFOptions(pageSize: .a4), portrait), 595.28, 841.89)
        assertSize(size(ImagePDFOptions(pageSize: .a4, orientation: .portrait), landscape), 595.28, 841.89)
        assertSize(size(ImagePDFOptions(pageSize: .letter), portrait), 612, 792)
        assertSize(size(ImagePDFOptions(pageSize: .letter, orientation: .landscape), portrait), 792, 612)
        assertSize(size(ImagePDFOptions(pageSize: .letter, orientation: .automatic), landscape), 792, 612)
    }

    func testImagePlacement() {
        let letter = CGSize(width: 612, height: 792)
        let fit = ImagePDFOptions(pageSize: .letter, margin: .large, fit: .fit)
        let rect = fit.imageRect(for: CGSize(width: 400, height: 300), on: letter)
        XCTAssertEqual(rect.width, 468, accuracy: 0.01)      // 612 - 2×72
        XCTAssertEqual(rect.height, 351, accuracy: 0.01)
        XCTAssertEqual(rect.midX, 306, accuracy: 0.01)
        XCTAssertEqual(rect.midY, 396, accuracy: 0.01)

        var fill = fit
        fill.fit = .fill
        let filled = fill.imageRect(for: CGSize(width: 400, height: 300), on: letter)
        XCTAssertEqual(filled.height, 648, accuracy: 0.01)   // 792 - 2×72
        XCTAssertEqual(filled.width, 864, accuracy: 0.01)
        XCTAssertTrue(filled.contains(fill.contentRect(on: letter)))
    }

    func testCreateWritesOnePagePerImage() throws {
        let dir = try pdfTempDir()
        let a = dir.appendingPathComponent("scan 1.png"), b = dir.appendingPathComponent("scan 2.jpg")
        try makeImage(at: a, width: 400, height: 300)
        try makeImage(at: b, width: 400, height: 300, type: .jpeg, orientation: 6)   // shot rotated: upright 300×400

        let fitted = try ImagesToPDF.create([a, b], options: ImagePDFOptions())
        XCTAssertEqual(fitted.lastPathComponent, "scan 1.pdf")
        let doc = try XCTUnwrap(PDFDocument(url: fitted))
        XCTAssertEqual(doc.pageCount, 2)
        XCTAssertEqual(doc.page(at: 0)?.bounds(for: .mediaBox).size, CGSize(width: 400, height: 300))
        XCTAssertEqual(doc.page(at: 1)?.bounds(for: .mediaBox).size, CGSize(width: 300, height: 400))

        let a4 = try ImagesToPDF.create([a, b], options: ImagePDFOptions(pageSize: .a4, margin: .small))
        XCTAssertEqual(a4.lastPathComponent, "scan 1 2.pdf")
        let doc2 = try XCTUnwrap(PDFDocument(url: a4))
        assertSize(doc2.page(at: 0)!.bounds(for: .mediaBox).size, 841.89, 595.28)
        assertSize(doc2.page(at: 1)!.bounds(for: .mediaBox).size, 595.28, 841.89)

        // The rotated JPEG is drawn upright: its top strip (red in the stored image's left
        // column) ends up along the top of the page.
        let page = try PDFPageGeometry.render(doc.page(at: 1)!, scale: 1)
        let top = pixel(page, x: 150, y: 5), bottom = pixel(page, x: 150, y: 395)
        XCTAssertGreaterThan(top.r, 0.7); XCTAssertLessThan(top.g, 0.4)
        XCTAssertGreaterThan(bottom.r, 0.9); XCTAssertGreaterThan(bottom.g, 0.9)

        XCTAssertThrowsError(try ImagesToPDF.create([dir.appendingPathComponent("missing.png")], options: ImagePDFOptions()))
    }
}

final class TextRecognitionTests: XCTestCase {
    static let phrase = "Hello Wheelie 123"

    func testRecognizerFindsText() throws {
        XCTAssertFalse(TextRecognizer.supportedLanguages().isEmpty)
        let image = textImage(Self.phrase, width: 1200, height: 400)
        let lines = try TextRecognizer.recognize(image)
        XCTAssertTrue(lines.map(\.text).joined(separator: " ").contains(Self.phrase), "\(lines)")
        let english = try TextRecognizer.recognize(image, languages: ["en-US"])
        XCTAssertTrue(english.contains { $0.text.contains(Self.phrase) })
    }

    func testScannedPDFBecomesSearchable() throws {
        let dir = try pdfTempDir()
        let scan = dir.appendingPathComponent("scan.pdf")
        try makeScannedPDF(at: scan, text: Self.phrase)
        XCTAssertEqual(PDFDocument(url: scan)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "", "",
                       "fixture must have no text layer")

        var steps: [Int] = []
        let outputs = try SearchablePDF.process(scan, options: TextRecognitionOptions(output: .both)) { done, _ in steps.append(done) }
        XCTAssertEqual(outputs.map(\.lastPathComponent), ["scan searchable.pdf", "scan.txt"])
        XCTAssertEqual(steps, [0, 1, 2])

        let doc = try XCTUnwrap(PDFDocument(url: outputs[0]))
        XCTAssertEqual(doc.pageCount, 2)
        XCTAssertEqual(doc.page(at: 0)?.bounds(for: .mediaBox).size, CGSize(width: 612, height: 792))
        let pageText = doc.page(at: 0)?.string ?? ""
        XCTAssertTrue(pageText.contains(Self.phrase), pageText)
        XCTAssertTrue(doc.string?.contains(Self.phrase) == true)
        // The invisible text sits where the scan shows it: selecting it finds a box in the top half.
        let selection = try XCTUnwrap(doc.findString(Self.phrase, withOptions: []).first)
        let bounds = selection.bounds(for: doc.page(at: 0)!)
        XCTAssertGreaterThan(bounds.minY, 396)
        XCTAssertGreaterThan(bounds.width, 200)

        let text = try String(contentsOf: outputs[1], encoding: .utf8)
        XCTAssertTrue(text.contains(Self.phrase), text)
    }

    func testImageAndTextOnlyOutput() throws {
        let dir = try pdfTempDir()
        let png = dir.appendingPathComponent("note.png")
        try Converter.writeImage(textImage(Self.phrase, width: 1200, height: 300), to: png, type: .png)
        let outputs = try SearchablePDF.process(png, options: TextRecognitionOptions(languages: ["en-US"], output: .pdf))
        XCTAssertEqual(outputs.map(\.lastPathComponent), ["note searchable.pdf"])
        let doc = try XCTUnwrap(PDFDocument(url: outputs[0]))
        XCTAssertEqual(doc.page(at: 0)?.bounds(for: .mediaBox).size, CGSize(width: 1200, height: 300))
        XCTAssertTrue(doc.string?.contains(Self.phrase) == true, doc.string ?? "")

        // A page that already has text is kept, and its text goes to the .txt.
        let vector = dir.appendingPathComponent("typed.pdf")
        try makePDF(at: vector, sizes: [CGSize(width: 400, height: 200)], text: "Already searchable")
        let txt = try SearchablePDF.process(vector, options: TextRecognitionOptions(output: .text))
        XCTAssertEqual(txt.map(\.lastPathComponent), ["typed.txt"])
        XCTAssertTrue(try String(contentsOf: txt[0], encoding: .utf8).contains("Already searchable"))

        // A blank scan has nothing to find.
        let blank = dir.appendingPathComponent("blank.pdf")
        try makeScannedPDF(at: blank, text: "")
        XCTAssertThrowsError(try SearchablePDF.process(blank, options: TextRecognitionOptions()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("blank searchable.pdf").path))
    }

    /// Regression: Recognize used to redraw every page into a fresh PDF, dropping links,
    /// bookmarks, form fields and the title/author, even on pages it "kept as they are".
    func testSearchablePDFKeepsLinksBookmarksFormsAndMetadata() throws {
        let dir = try pdfTempDir()
        let raw = dir.appendingPathComponent("raw.pdf")
        try makeMixedPDF(at: raw, scanText: Self.phrase, typedText: "Already searchable")
        let doc = try XCTUnwrap(PDFDocument(url: raw))
        let scanPage = try XCTUnwrap(doc.page(at: 0)), typedPage = try XCTUnwrap(doc.page(at: 1))
        let web = PDFAnnotation(bounds: CGRect(x: 20, y: 20, width: 120, height: 20), forType: .link, withProperties: nil)
        web.url = URL(string: "https://example.com/scan")
        scanPage.addAnnotation(web)
        let field = PDFAnnotation(bounds: CGRect(x: 20, y: 100, width: 200, height: 24), forType: .widget, withProperties: nil)
        field.widgetFieldType = .text
        field.fieldName = "Signature"
        field.widgetStringValue = "Ada"
        scanPage.addAnnotation(field)
        let back = PDFAnnotation(bounds: CGRect(x: 20, y: 20, width: 120, height: 20), forType: .link, withProperties: nil)
        back.action = PDFActionGoTo(destination: PDFDestination(page: scanPage, at: CGPoint(x: 0, y: 792)))
        typedPage.addAnnotation(back)
        let root = PDFOutline()
        for (index, (label, page)) in [("Scan", scanPage), ("Typed", typedPage)].enumerated() {
            let item = PDFOutline()
            item.label = label
            item.destination = PDFDestination(page: page, at: CGPoint(x: 0, y: 792))
            root.insertChild(item, at: index)
        }
        doc.outlineRoot = root
        doc.documentAttributes = [PDFDocumentAttribute.titleAttribute: "Quarterly Report",
                                  PDFDocumentAttribute.authorAttribute: "Ada"]
        let source = dir.appendingPathComponent("report.pdf")
        XCTAssertTrue(doc.write(to: source))
        let before = try Data(contentsOf: source)

        // While it runs, nothing appears under the final name (no half-written file).
        let final = dir.appendingPathComponent("report searchable.pdf")
        var sawPartial = false
        let outputs = try SearchablePDF.process(source, options: TextRecognitionOptions()) { _, _ in
            if FileManager.default.fileExists(atPath: final.path) { sawPartial = true }
        }
        XCTAssertFalse(sawPartial, "the output must only appear once complete")
        XCTAssertEqual(outputs.map(\.lastPathComponent), ["report searchable.pdf"])
        XCTAssertEqual(try Data(contentsOf: source), before, "the original is never touched")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(),
                       ["raw.pdf", "report searchable.pdf", "report.pdf"], "no staging leftovers")

        let out = try XCTUnwrap(PDFDocument(url: outputs[0]))
        XCTAssertEqual(out.pageCount, 2)
        let page0 = try XCTUnwrap(out.page(at: 0)), page1 = try XCTUnwrap(out.page(at: 1))
        XCTAssertTrue(page0.string?.contains(Self.phrase) == true, page0.string ?? "")
        XCTAssertTrue(page1.string?.contains("Already searchable") == true)
        XCTAssertEqual(page0.bounds(for: .mediaBox), CGRect(x: 0, y: 0, width: 612, height: 792))

        let attributes = out.documentAttributes ?? [:]
        XCTAssertEqual(attributes[PDFDocumentAttribute.titleAttribute] as? String, "Quarterly Report")
        XCTAssertEqual(attributes[PDFDocumentAttribute.authorAttribute] as? String, "Ada")

        let outline = try XCTUnwrap(out.outlineRoot)
        XCTAssertEqual(outline.numberOfChildren, 2)
        XCTAssertEqual(outline.child(at: 0)?.label, "Scan")
        XCTAssertEqual(outline.child(at: 0)?.destination?.page.map(out.index(for:)), 0, "bookmark follows the replaced page")
        XCTAssertEqual(outline.child(at: 1)?.destination?.page.map(out.index(for:)), 1)

        // The recognized page keeps its link and its live form field.
        let link = page0.annotations.first { $0.url != nil }
        XCTAssertEqual(link?.url?.absoluteString, "https://example.com/scan")
        let widget = page0.annotations.first { $0.fieldName == "Signature" }
        XCTAssertEqual(widget?.widgetFieldType, .text)
        XCTAssertEqual(widget?.widgetStringValue, "Ada")
        // The kept page keeps its link, which still lands on the (replaced) first page.
        let goTo = page1.annotations.compactMap { $0.action as? PDFActionGoTo }.first
        XCTAssertEqual(goTo?.destination.page.map(out.index(for:)), 0)
    }

    /// The text layer of a rotated scan lines up with the text as displayed.
    func testRotatedScanGetsTextWhereItIsShown() throws {
        let dir = try pdfTempDir()
        let scan = dir.appendingPathComponent("turned.pdf")
        try makeRotatedScan(at: scan, text: Self.phrase)
        let outputs = try SearchablePDF.process(scan, options: TextRecognitionOptions(languages: ["en-US"]))
        let doc = try XCTUnwrap(PDFDocument(url: outputs[0]))
        let page = try XCTUnwrap(doc.page(at: 0))
        XCTAssertEqual(page.rotation, 90, "rotation is kept, not baked in")
        XCTAssertEqual(page.bounds(for: .mediaBox).size, CGSize(width: 612, height: 792))
        let selection = try XCTUnwrap(doc.findString(Self.phrase, withOptions: []).first)
        let bounds = selection.bounds(for: page)
        // Shown in the top half of the turned page = the left half of the unturned page,
        // running up the page.
        XCTAssertLessThan(bounds.maxX, 306, "\(bounds)")
        XCTAssertGreaterThan(bounds.height, bounds.width, "\(bounds)")
    }
}

final class MultiPageImageTests: XCTestCase {
    /// Regression: only the first page of a multi-page TIFF (scans, faxes) was used.
    func testEveryTIFFPageBecomesAPage() throws {
        let dir = try pdfTempDir()
        let tiff = dir.appendingPathComponent("fax.tiff")
        try makeMultiImage(at: tiff, type: .tiff, sizes: [(300, 400), (310, 410), (320, 420)])
        let png = dir.appendingPathComponent("photo.png")
        try makeImage(at: png, width: 64, height: 48)

        XCTAssertEqual(PDFSourceLoader.pageCount(of: tiff), 3)
        XCTAssertEqual(PDFSourceLoader.imageSummary(tiff, thumbnailPixels: 64)?.pages, 3)
        XCTAssertEqual(try PDFSourceLoader.document(for: tiff).pageCount, 3)

        let made = try ImagesToPDF.create([tiff, png], options: ImagePDFOptions())
        let doc = try XCTUnwrap(PDFDocument(url: made))
        XCTAssertEqual((0..<doc.pageCount).map { doc.page(at: $0)!.bounds(for: .mediaBox).size },
                       [CGSize(width: 300, height: 400), CGSize(width: 310, height: 410),
                        CGSize(width: 320, height: 420), CGSize(width: 64, height: 48)])

        let combined = try PDFMerger.combine([tiff, png])
        XCTAssertEqual(PDFDocument(url: combined)?.pageCount, 4)
    }

    /// Animation frames are not pages: an animated GIF is still one page.
    func testAnimatedImageUsesItsFirstFrame() throws {
        let dir = try pdfTempDir()
        let gif = dir.appendingPathComponent("spinner.gif")
        try makeMultiImage(at: gif, type: .gif, sizes: [(40, 30), (40, 30), (40, 30)])
        XCTAssertEqual(PDFSourceLoader.pageCount(of: gif), 1)
        XCTAssertEqual(try PDFSourceLoader.document(for: gif).pageCount, 1)
        let made = try ImagesToPDF.create([gif], options: ImagePDFOptions())
        XCTAssertEqual(PDFDocument(url: made)?.pageCount, 1)
    }
}

final class StagedOutputTests: XCTestCase {
    func testCommitMovesIntoPlaceWithoutOverwriting() throws {
        let dir = try pdfTempDir()
        let taken = dir.appendingPathComponent("a.pdf")
        try Data("original".utf8).write(to: taken)

        let staging = try StagedOutput(near: taken)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["a.pdf"],
                       "work in progress is not visible next to the output")
        let file = staging.file("output.pdf")
        try Data("new".utf8).write(to: file)

        // The name was taken after it was picked: the next free name is asked for.
        var calls = 0
        let result = try staging.commit(file) {
            calls += 1
            return calls == 1 ? taken : OutputNaming.uniqueURL(for: taken, ext: "pdf")
        }
        XCTAssertEqual(result.lastPathComponent, "a 2.pdf")
        XCTAssertEqual(try String(contentsOf: taken, encoding: .utf8), "original")
        XCTAssertEqual(try String(contentsOf: result, encoding: .utf8), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.directory.path))
    }

    func testDiscardLeavesNothingBehind() throws {
        let dir = try pdfTempDir()
        var staging: StagedOutput? = try StagedOutput(near: dir.appendingPathComponent("b.pdf"))
        let folder = try XCTUnwrap(staging?.directory)
        try Data("partial".utf8).write(to: folder.appendingPathComponent("output.pdf"))
        staging = nil   // e.g. an error was thrown mid-write
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])

        // A failed Make PDF leaves no output either.
        XCTAssertThrowsError(try ImagesToPDF.create([dir.appendingPathComponent("missing.png")], options: ImagePDFOptions()))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
    }
}

// MARK: - Fixtures

/// Page 1: a scan (image only) of `scanText`; page 2: real, selectable `typedText`.
private func makeMixedPDF(at url: URL, scanText: String, typedText: String) throws {
    let ctx = try XCTUnwrap(CGContext(url as CFURL, mediaBox: nil, nil))
    let page = CGRect(x: 0, y: 0, width: 612, height: 792)
    var box = page
    let info = [kCGPDFContextMediaBox as String: Data(bytes: &box, count: MemoryLayout<CGRect>.size) as CFData] as CFDictionary
    ctx.beginPDFPage(info)
    ctx.setFillColor(.white)
    ctx.fill(page)
    ctx.draw(textImage(scanText, width: 1224, height: 400), in: CGRect(x: 0, y: 492, width: 612, height: 200))
    ctx.endPDFPage()
    ctx.beginPDFPage(info)
    let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: typedText, attributes: [.init(kCTFontAttributeName as String): font]))
    ctx.textPosition = CGPoint(x: 40, y: 600)
    CTLineDraw(line, ctx)
    ctx.endPDFPage()
    ctx.closePDF()
}

/// A portrait page with /Rotate 90 whose scanned text reads upright as displayed
/// (landscape), in the top half of the displayed page.
private func makeRotatedScan(at url: URL, text: String) throws {
    let ctx = try XCTUnwrap(CGContext(url as CFURL, mediaBox: nil, nil))
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let info = [kCGPDFContextMediaBox as String: Data(bytes: &box, count: MemoryLayout<CGRect>.size) as CFData] as CFDictionary
    ctx.beginPDFPage(info)
    ctx.setFillColor(.white)
    ctx.fill(box)
    // Displayed (x, y) → page (612 - y, x): what a 90° clockwise display turn undoes.
    ctx.concatenate(CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 612, ty: 0))
    ctx.draw(textImage(text, width: 1224, height: 400), in: CGRect(x: 40, y: 380, width: 612, height: 200))
    ctx.endPDFPage()
    ctx.closePDF()
    let doc = try XCTUnwrap(PDFDocument(url: url))
    doc.page(at: 0)?.rotation = 90
    XCTAssertTrue(doc.write(to: url))
}

/// One image per size in a single file (TIFF pages, GIF frames).
private func makeMultiImage(at url: URL, type: UTType, sizes: [(Int, Int)]) throws {
    let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, sizes.count, nil))
    for (width, height) in sizes {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        CGImageDestinationAddImage(dest, try XCTUnwrap(ctx.makeImage()), nil)
    }
    XCTAssertTrue(CGImageDestinationFinalize(dest))
}

private func pdfTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wheelie-pdf-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func assertSize(_ size: CGSize, _ width: CGFloat, _ height: CGFloat, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(size.width, width, accuracy: 0.01, file: file, line: line)
    XCTAssertEqual(size.height, height, accuracy: 0.01, file: file, line: line)
}

/// One page per size, each with a vector frame (and optional real text).
private func makePDF(at url: URL, sizes: [CGSize], text: String? = nil) throws {
    let ctx = try XCTUnwrap(CGContext(url as CFURL, mediaBox: nil, nil))
    for size in sizes {
        var box = CGRect(origin: .zero, size: size)
        let info = [kCGPDFContextMediaBox as String: Data(bytes: &box, count: MemoryLayout<CGRect>.size) as CFData] as CFDictionary
        ctx.beginPDFPage(info)
        ctx.setStrokeColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        ctx.stroke(box.insetBy(dx: 4, dy: 4), width: 2)
        if let text {
            let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.init(kCTFontAttributeName as String): font]))
            ctx.textPosition = CGPoint(x: 20, y: size.height / 2)
            CTLineDraw(line, ctx)
        }
        ctx.endPDFPage()
    }
    ctx.closePDF()
}

/// Left column red, the rest white (so orientation is visible).
private func makeImage(at url: URL, width: Int, height: Int, type: UTType = .png, orientation: Int = 1) throws {
    let ctx = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    ctx.setFillColor(.white)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width / 8, height: height))
    let image = try XCTUnwrap(ctx.makeImage())
    let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(dest, image, [kCGImagePropertyOrientation: orientation,
                                             kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
    XCTAssertTrue(CGImageDestinationFinalize(dest))
}

/// Black text on white, large.
private func textImage(_ text: String, width: Int, height: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(.white)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let font = CTFontCreateWithName("Helvetica" as CFString, CGFloat(height) / 4, nil)
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
        .init(kCTFontAttributeName as String): font,
        .init(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
    ]))
    ctx.textPosition = CGPoint(x: CGFloat(width) * 0.08, y: CGFloat(height) * 0.4)
    CTLineDraw(line, ctx)
    return ctx.makeImage()!
}

/// A two-page "scan": page images only, no text layer. Text sits in the top half of page 1.
private func makeScannedPDF(at url: URL, text: String) throws {
    let ctx = try XCTUnwrap(CGContext(url as CFURL, mediaBox: nil, nil))
    let page = CGRect(x: 0, y: 0, width: 612, height: 792)
    for index in 0..<2 {
        var box = page
        let info = [kCGPDFContextMediaBox as String: Data(bytes: &box, count: MemoryLayout<CGRect>.size) as CFData] as CFDictionary
        ctx.beginPDFPage(info)
        ctx.setFillColor(.white)
        ctx.fill(page)
        if index == 0, !text.isEmpty {
            // 2× scan of the top half of the page.
            ctx.draw(textImage(text, width: 1224, height: 400), in: CGRect(x: 0, y: 492, width: 612, height: 200))
        }
        ctx.endPDFPage()
    }
    ctx.closePDF()
}

private func pixel(_ image: CGImage, x: Int, y: Int) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
    // Redraw into a known RGBA buffer; y counts from the top.
    var data = [UInt8](repeating: 0, count: 4)
    let ctx = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
    return (CGFloat(data[0]) / 255, CGFloat(data[1]) / 255, CGFloat(data[2]) / 255)
}
