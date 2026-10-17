import Foundation
import PDFKit
import Quartz

/// Recompresses the images inside a PDF (text and vectors stay intact) with a Quartz filter:
/// JPEG at a chosen quality and downsampling to a maximum resolution. Falls back to PDFKit's
/// JPEG/screen-optimisation write options when the filter can't be created.
enum PDFCompressor {
    struct Setting: Equatable {
        var quality: Double
        /// Images are downsampled to about this many pixels per inch of page.
        var resolution: Int
        /// Longest image edge in pixels.
        var maxImageSize: Int
    }

    /// Best quality first.
    static let ladder: [Setting] = [
        Setting(quality: 0.85, resolution: 300, maxImageSize: 6000),
        Setting(quality: 0.75, resolution: 220, maxImageSize: 4800),
        Setting(quality: 0.65, resolution: 150, maxImageSize: 3600),
        Setting(quality: 0.55, resolution: 150, maxImageSize: 3000),
        Setting(quality: 0.45, resolution: 120, maxImageSize: 2400),
        Setting(quality: 0.35, resolution: 100, maxImageSize: 2000),
        Setting(quality: 0.25, resolution: 80, maxImageSize: 1600),
        Setting(quality: 0.15, resolution: 72, maxImageSize: 1200),
        Setting(quality: 0.1, resolution: 50, maxImageSize: 800),
    ]

    static func preset(_ strength: CompressionStrength) -> Setting {
        switch strength {
        case .light: return Setting(quality: 0.75, resolution: 200, maxImageSize: 4000)
        case .balanced: return Setting(quality: 0.6, resolution: 150, maxImageSize: 3000)
        case .strong: return Setting(quality: 0.4, resolution: 110, maxImageSize: 2000)
        }
    }

    static func filterProperties(_ setting: Setting) -> [String: Any] {
        [
            "Name": "Wheelie Compress",
            "FilterType": 1,
            "Domains": ["Applications": true, "Printing": true],
            "FilterData": [
                "ColorSettings": [
                    "ImageSettings": [
                        "Compression Quality": setting.quality,
                        "ImageCompression": "ImageJPEGCompress",
                        "ImageScaleSettings": [
                            "ImageResolution": setting.resolution,
                            "ImageScaleInterpolate": true,
                            "ImageSizeMax": setting.maxImageSize,
                            "ImageSizeMin": 0,
                        ] as [String: Any],
                    ] as [String: Any],
                ],
            ],
        ]
    }

    static func open(_ source: URL) throws -> PDFDocument {
        guard let doc = PDFDocument(url: source) else { throw CompressionError.pdfLocked }
        if doc.isLocked { throw CompressionError.pdfLocked }
        guard doc.pageCount > 0 else { throw CompressionError.pdfFailed }
        return doc
    }

    static func write(_ doc: PDFDocument, setting: Setting, to url: URL) -> Bool {
        if let filter = QuartzFilter(properties: filterProperties(setting)) {
            if doc.write(to: url, withOptions: [PDFDocumentWriteOption(rawValue: "QuartzFilter"): filter]) { return true }
        }
        return doc.write(to: url, withOptions: [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true])
    }

    static func compress(_ source: URL, strength: CompressionStrength, cap: Int64, targeted: Bool,
                         workDir: URL) throws -> (url: URL, ext: String) {
        let doc = try open(source)
        let output = workDir.appendingPathComponent("output.pdf")
        if targeted {
            // Binary search the ladder for the best setting that fits.
            var lo = 0, hi = ladder.count - 1
            var smallest = Int64.max
            let probe = workDir.appendingPathComponent("probe.pdf")
            func size(at index: Int) throws -> Int64 {
                try? FileManager.default.removeItem(at: probe)
                guard write(doc, setting: ladder[index], to: probe) else { throw CompressionError.pdfFailed }
                let bytes = ByteSize.of(probe)
                smallest = min(smallest, bytes)
                return bytes
            }
            guard try size(at: hi) <= cap else { throw CompressionError.targetUnreachable(smallest: smallest) }
            try? FileManager.default.removeItem(at: output)
            try FileManager.default.moveItem(at: probe, to: output)
            while lo < hi {
                let mid = (lo + hi) / 2
                if try size(at: mid) <= cap {
                    hi = mid
                    try? FileManager.default.removeItem(at: output)
                    try FileManager.default.moveItem(at: probe, to: output)
                } else {
                    lo = mid + 1
                }
            }
        } else {
            guard write(doc, setting: preset(strength), to: output) else { throw CompressionError.pdfFailed }
        }
        guard let check = PDFDocument(url: output), check.pageCount == doc.pageCount else {
            throw CompressionError.pdfUnverified
        }
        return (output, "pdf")
    }
}
