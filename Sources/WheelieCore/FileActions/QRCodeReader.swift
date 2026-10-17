import CoreGraphics
import Foundation
import ImageIO
import Vision

/// One decoded code: what it says and where it was found.
public struct QRCodeResult: Identifiable, Hashable, Sendable {
    public let id: Int
    public let payload: String
    /// Display name such as "QR", "EAN-13", "Data Matrix".
    public let symbology: String
    public let source: URL
    /// 1-based PDF page; nil for images.
    public let page: Int?

    public init(id: Int, payload: String, symbology: String, source: URL, page: Int?) {
        self.id = id
        self.payload = payload
        self.symbology = symbology
        self.source = source
        self.page = page
    }

    /// "ticket.pdf, page 2" or "poster.png".
    public var location: String {
        page.map { "\(source.lastPathComponent), page \($0)" } ?? source.lastPathComponent
    }

    /// A web, mail, phone or similar link the payload can be opened as.
    public var link: URL? { QRCodeReader.openableURL(payload) }
}

public struct QRScanFailure: Hashable, Sendable {
    public let source: URL
    public let message: String
}

public struct QRScanReport: Sendable {
    public var results: [QRCodeResult] = []
    public var failures: [QRScanFailure] = []
    /// Images plus PDF pages looked at.
    public var scanned = 0
}

/// Finds QR codes and other barcodes in images and PDF pages with Vision.
public enum QRCodeReader {
    /// PDF pages are rendered at this scale so small codes still decode.
    public static let pdfScale: CGFloat = 2
    /// Longest side of a rendered page, to bound memory on poster-sized pages.
    static let maxRenderedSide: CGFloat = 6000

    public struct Code: Hashable, Sendable {
        public let payload: String
        public let symbology: String
    }

    /// Codes in one image, top-to-bottom then left-to-right, without duplicates.
    public static func codes(in image: CGImage) throws -> [Code] {
        let request = VNDetectBarcodesRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let observations = (request.results ?? []).sorted {
            let a = $0.boundingBox, b = $1.boundingBox
            return abs(a.midY - b.midY) > 0.02 ? a.midY > b.midY : a.minX < b.minX
        }
        var seen = Set<Code>()
        var codes: [Code] = []
        for observation in observations {
            guard let payload = observation.payloadStringValue, !payload.isEmpty else { continue }
            let code = Code(payload: payload, symbology: displayName(observation.symbology))
            if seen.insert(code).inserted { codes.append(code) }
        }
        return codes
    }

    /// Scans every image (first frame) and every PDF page. Calls `progress(done, total)` after each
    /// image or page. Stops early, returning what it found so far, when the current task is cancelled.
    public static func scan(_ files: [URL], progress: ((Int, Int) -> Void)? = nil) -> QRScanReport {
        enum Source { case image(URL), pdf(URL, CGPDFDocument) }
        var report = QRScanReport()
        var sources: [Source] = []
        var total = 0
        for file in files {
            if FileKind(url: file) == .pdf {
                guard let doc = CGPDFDocument(file as CFURL) else {
                    report.failures.append(QRScanFailure(source: file, message: "The PDF couldn't be opened."))
                    continue
                }
                if doc.isEncrypted, !doc.isUnlocked, !doc.unlockWithPassword("") {
                    report.failures.append(QRScanFailure(source: file, message: "The PDF is password-protected."))
                    continue
                }
                sources.append(.pdf(file, doc))
                total += doc.numberOfPages
            } else {
                sources.append(.image(file))
                total += 1
            }
        }

        var nextID = 0
        func add(_ codes: [Code], from file: URL, page: Int?) {
            for code in codes {
                report.results.append(QRCodeResult(id: nextID, payload: code.payload, symbology: code.symbology,
                                                   source: file, page: page))
                nextID += 1
            }
        }
        func step() {
            report.scanned += 1
            progress?(report.scanned, total)
        }

        for source in sources {
            if Task.isCancelled { break }
            switch source {
            case .image(let file):
                defer { step() }
                guard let image = loadImage(file) else {
                    report.failures.append(QRScanFailure(source: file, message: "The image couldn't be read."))
                    continue
                }
                do { add(try codes(in: image), from: file, page: nil) }
                catch { report.failures.append(QRScanFailure(source: file, message: error.localizedDescription)) }
            case .pdf(let file, let doc):
                guard doc.numberOfPages > 0 else { continue }
                for number in 1...doc.numberOfPages {
                    if Task.isCancelled { break }
                    defer { step() }
                    let codes = autoreleasepool { () -> [Code]? in
                        guard let page = doc.page(at: number), let image = render(page, scale: pdfScale) else { return nil }
                        return try? Self.codes(in: image)
                    }
                    guard let codes else {
                        report.failures.append(QRScanFailure(source: file, message: "Page \(number) couldn't be read."))
                        continue
                    }
                    add(codes, from: file, page: number)
                }
            }
        }
        return report
    }

    static func loadImage(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Renders a page's crop box on white, in grayscale (Vision doesn't need colour).
    public static func render(_ page: CGPDFPage, scale: CGFloat) -> CGImage? {
        let box = page.getBoxRect(.cropBox)
        guard box.width > 0, box.height > 0 else { return nil }
        var s = scale
        let longest = max(box.width, box.height) * s
        if longest > maxRenderedSide { s *= maxRenderedSide / longest }
        let width = Int((box.width * s).rounded(.up)), height = Int((box.height * s).rounded(.up))
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: s, y: s)
        ctx.translateBy(x: -box.minX, y: -box.minY)
        ctx.drawPDFPage(page)
        return ctx.makeImage()
    }

    static func displayName(_ symbology: VNBarcodeSymbology) -> String {
        switch symbology {
        case .qr: return "QR"
        case .microQR: return "Micro QR"
        case .aztec: return "Aztec"
        case .dataMatrix: return "Data Matrix"
        case .pdf417: return "PDF417"
        case .microPDF417: return "MicroPDF417"
        case .ean8: return "EAN-8"
        case .ean13: return "EAN-13"
        case .upce: return "UPC-E"
        case .code39, .code39Checksum, .code39FullASCII, .code39FullASCIIChecksum: return "Code 39"
        case .code93, .code93i: return "Code 93"
        case .code128: return "Code 128"
        case .itf14: return "ITF-14"
        case .i2of5, .i2of5Checksum: return "ITF"
        case .codabar: return "Codabar"
        default:
            let raw = symbology.rawValue
            return raw.hasPrefix("VNBarcodeSymbology") ? String(raw.dropFirst("VNBarcodeSymbology".count)) : raw
        }
    }

    static let openableSchemes: Set<String> = ["http", "https", "mailto", "tel", "sms", "facetime", "facetime-audio", "maps"]

    /// The payload as a link worth an "Open" button, or nil. Only well-known, harmless schemes;
    /// a bare `www.` host gets https.
    public static func openableURL(_ payload: String) -> URL? {
        let text = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: \.isWhitespace) else { return nil }
        if text.lowercased().hasPrefix("www."), text.contains(".") {
            return URL(string: "https://" + text)
        }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              openableSchemes.contains(scheme) else { return nil }
        if scheme == "http" || scheme == "https" { return (url.host ?? "").isEmpty ? nil : url }
        return url
    }
}
