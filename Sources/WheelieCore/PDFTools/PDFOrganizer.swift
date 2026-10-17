import CoreGraphics
import Foundation
import PDFKit

/// Builds organized PDFs from a page plan. Synchronous; call off the main thread.
public enum PDFOrganizer {
    /// The plan applied to already opened sources. Keep `sources` alive until the result is written.
    public static func makeDocument(sources: [PDFDocument], plan: PDFPagePlan,
                                    equalizeWidths: Bool = false) throws -> PDFDocument {
        try plan.validate(pageCounts: sources.map(\.pageCount))
        let pages = plan.pages.map { ref -> (PDFPage, Int) in
            let page = sources[ref.file].page(at: ref.page)!
            return (page, PDFPageGeometry.normalized(page.rotation + ref.rotation))
        }
        let scales = equalizeWidths
            ? PDFPageScaling.equalWidthScales(for: pages.map { PDFPageGeometry.displayedSize(of: $0.0, rotation: $0.1) })
            : pages.map { _ in CGFloat(1) }

        let output = PDFDocument()
        for (index, (page, rotation)) in pages.enumerated() {
            let result: PDFPage
            if scales[index] < 0.9999 {
                result = try scaledCopy(of: page, rotation: rotation, scale: scales[index])
            } else {
                guard let copy = page.copy() as? PDFPage else { throw PDFToolsError("Could not create the organized PDF.") }
                copy.rotation = rotation
                result = copy
            }
            output.insert(result, at: output.pageCount)
        }
        if let attributes = sources.first?.documentAttributes { output.documentAttributes = attributes }
        return output
    }

    /// Writes "<first name> organized.pdf" (unique) and checks it opens with every page.
    /// `nameSource` picks the name (default: the first file).
    @discardableResult
    public static func organize(files: [URL], plan: PDFPagePlan, equalizeWidths: Bool = false,
                                nameSource: URL? = nil, to destination: URL? = nil) throws -> URL {
        guard let first = nameSource ?? files.first else { throw PDFToolsError.noPages }
        let sources = try files.map(PDFSourceLoader.document(for:))
        let document = try makeDocument(sources: sources, plan: plan, equalizeWidths: equalizeWidths)
        let output = destination ?? OutputNaming.uniqueURL(for: first, ext: "pdf", suffix: " organized")
        try write(document, to: output, expectedPages: plan.count,
                  writeError: "PDFKit could not write the organized PDF.",
                  verifyError: "The organized PDF could not be verified.")
        withExtendedLifetime(sources) {}
        return output
    }

    /// Writes a document and re-opens it to make sure all pages made it. Removes the file on failure.
    static func write(_ document: PDFDocument, to url: URL, expectedPages: Int,
                      writeError: String, verifyError: String) throws {
        guard document.write(to: url) else {
            try? FileManager.default.removeItem(at: url)
            throw PDFToolsError(writeError)
        }
        guard let check = PDFDocument(url: url), check.pageCount == expectedPages else {
            try? FileManager.default.removeItem(at: url)
            throw PDFToolsError(verifyError)
        }
    }

    /// Redraws a page (rotation baked in) into a new page `scale` times its displayed size.
    /// Content stays vector; embedded images keep their encoding.
    static func scaledCopy(of page: PDFPage, rotation: Int, scale: CGFloat) throws -> PDFPage {
        guard let turned = page.copy() as? PDFPage else { throw PDFToolsError("Could not create the organized PDF.") }
        turned.rotation = rotation
        let size = PDFPageGeometry.displayedSize(of: turned)
        let box = CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale)
        let data = NSMutableData()
        var mediaBox = box
        guard let consumer = CGDataConsumer(data: data),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else { throw PDFToolsError("Could not create the organized PDF.") }
        ctx.beginPDFPage(PDFPageGeometry.pageInfo(mediaBox: box))
        ctx.scaleBy(x: scale, y: scale)
        turned.draw(with: .cropBox, to: ctx)
        ctx.endPDFPage()
        ctx.closePDF()
        guard let doc = PDFDocument(data: data as Data), let scaled = doc.page(at: 0)
        else { throw PDFToolsError("Could not create the organized PDF.") }
        return scaled
    }
}

/// "Combine": all pages of several PDFs and images, files in Finder name order.
public enum PDFMerger {
    /// One document with every page of `files`, in the given order. Images become pages
    /// the size of the image at 72 dpi.
    public static func merge(_ files: [URL]) throws -> PDFDocument {
        let sources = try files.map(PDFSourceLoader.document(for:))
        let counts = sources.map(\.pageCount)
        guard counts.contains(where: { $0 > 0 }) else { throw PDFToolsError.noPages }
        return try PDFOrganizer.makeDocument(sources: sources, plan: .identity(pageCounts: counts))
    }

    /// Sorts by name as Finder does and writes "<first name> combined.pdf".
    @discardableResult
    public static func combine(_ files: [URL], to destination: URL? = nil) throws -> URL {
        let ordered = PDFSourceLoader.sortedByName(files)
        guard let first = ordered.first else { throw PDFToolsError.noPages }
        let sources = try ordered.map(PDFSourceLoader.document(for:))
        let counts = sources.map(\.pageCount)
        guard counts.contains(where: { $0 > 0 }) else { throw PDFToolsError.noPages }
        let document = try PDFOrganizer.makeDocument(sources: sources, plan: .identity(pageCounts: counts))
        let output = destination ?? OutputNaming.uniqueURL(for: first, ext: "pdf", suffix: " combined")
        try PDFOrganizer.write(document, to: output, expectedPages: counts.reduce(0, +),
                               writeError: "PDFKit could not write the combined PDF.",
                               verifyError: "The combined PDF could not be verified.")
        withExtendedLifetime(sources) {}
        return output
    }
}
