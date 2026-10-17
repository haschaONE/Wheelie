import AppKit
import WheelieCore

/// PDF tools on the outer ring: Organize, Combine, Split, Make PDF (images → one PDF)
/// and Recognize (text recognition for scans). Logic lives in `WheelieCore/PDFTools`.
enum PDFToolsFeature: WheelieFeature {
    static func wheelItems() -> [WheelItem] {
        [
            // 1+ PDFs, optionally with images (which become pages).
            WheelItem(id: "pdf.organize", label: "Organize", symbol: "square.grid.2x2", order: 50,
                      accepts: { files in files.allAre(.pdf, .image) && files.contains { FileKind(url: $0) == .pdf } },
                      perform: { files in
                          PDFOrganizeWindow.open(files)
                          return .none
                      }),
            // 2+ PDFs and/or images, merged at once in Finder name order.
            WheelItem(id: "pdf.merge", label: "Combine", symbol: "doc.on.doc", order: 51,
                      accepts: { files in files.count >= 2 && files.allAre(.pdf, .image) },
                      perform: { files in
                          .outputs([try await runDetached { try PDFMerger.combine(files) }])
                      }),
            // A single PDF with at least two pages.
            WheelItem(id: "pdf.split", label: "Split", symbol: "rectangle.split.2x1", order: 52,
                      accepts: { files in
                          files.count == 1 && files.allAre(.pdf) && (PDFSourceLoader.pageCount(of: files[0]) ?? 0) >= 2
                      },
                      perform: { files in
                          PDFSplitWindow.open(files[0])
                          return .none
                      }),
            // 1+ images into one PDF.
            WheelItem(id: "pdf.create", label: "Make PDF", symbol: "doc.badge.plus", order: 53,
                      accepts: { files in files.allAre(.image) },
                      perform: { files in
                          PDFCreateWindow.open(files)
                          return .none
                      }),
            // Scanned PDFs and images.
            WheelItem(id: "pdf.ocr", label: "Recognize", symbol: "text.viewfinder", order: 54,
                      accepts: { files in files.allAre(.pdf, .image) },
                      perform: { files in
                          PDFRecognizeWindow.open(files)
                          return .none
                      }),
        ]
    }
}
