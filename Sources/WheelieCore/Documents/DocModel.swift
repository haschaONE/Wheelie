import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Format-neutral document used between readers (Markdown, HTML, DOCX, EPUB, PDF reflow,
/// attributed strings) and writers (Markdown, HTML, DOCX, text, attributed strings → PDF/RTF/ODT).
public struct DocModel: Sendable {
    public var title: String?
    public var blocks: [DocBlock]

    public init(title: String? = nil, blocks: [DocBlock] = []) {
        self.title = title
        self.blocks = blocks
    }

    /// Plain text of every paragraph, list item, code block and table cell.
    public var plainText: String { TextWriter.render(self) }
}

public struct DocStyle: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let bold = DocStyle(rawValue: 1 << 0)
    public static let italic = DocStyle(rawValue: 1 << 1)
    public static let underline = DocStyle(rawValue: 1 << 2)
    public static let strike = DocStyle(rawValue: 1 << 3)
    public static let code = DocStyle(rawValue: 1 << 4)
    public static let superscript = DocStyle(rawValue: 1 << 5)
    public static let `subscript` = DocStyle(rawValue: 1 << 6)
}

/// A span of text with one style. "\n" inside a run is a hard line break.
/// `link` always passes `LinkPolicy` (http/https/mailto/#anchor) — every writer relies on that.
public struct DocRun: Equatable, Sendable {
    public var text: String
    public var style: DocStyle
    public private(set) var link: String?

    public init(_ text: String, style: DocStyle = [], link: String? = nil) {
        self.text = text
        self.style = style
        self.link = LinkPolicy.sanitize(link)
    }
}

public enum DocAlignment: Sendable { case natural, center, right, justified }

public struct DocParagraph: Sendable {
    public enum Kind: Equatable, Sendable {
        case body
        case heading(Int)                        // 1...6
        case listItem(ordered: Bool, level: Int) // level 1...
        case quote
    }

    public var kind: Kind
    public var runs: [DocRun]
    public var alignment: DocAlignment

    public init(_ kind: Kind = .body, runs: [DocRun], alignment: DocAlignment = .natural) {
        self.kind = kind
        self.runs = runs
        self.alignment = alignment
    }

    public var text: String { runs.map(\.text).joined() }
}

public struct DocImage: Sendable {
    /// Encoded image (PNG, JPEG, GIF, ...). Writers re-encode anything that isn't PNG/JPEG/GIF.
    public var data: Data
    /// Preferred filename extension: "png", "jpg", "gif".
    public var fileExtension: String
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// Preferred display width in points, when the source says so.
    public var displayWidth: Double?
    public var alt: String

    /// Validates `data` with ImageIO; nil when it isn't a readable image.
    public init?(data: Data, alt: String = "", displayWidth: Double? = nil) {
        guard data.count <= DocumentLimits.maxImageBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0
        else { return nil }
        let type = CGImageSourceGetType(source) as String? ?? ""
        switch type {
        case UTType.png.identifier: fileExtension = "png"; self.data = data
        case UTType.jpeg.identifier: fileExtension = "jpg"; self.data = data
        case UTType.gif.identifier: fileExtension = "gif"; self.data = data
        default:
            // TIFF, HEIC, WebP, BMP...: re-encode as PNG so every writer can embed it.
            guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let png = DocImage.encode(image, as: .png) else { return nil }
            fileExtension = "png"
            self.data = png
        }
        pixelWidth = width
        pixelHeight = height
        self.displayWidth = displayWidth
        self.alt = alt
    }

    public init?(cgImage: CGImage, alt: String = "", displayWidth: Double? = nil, jpeg: Bool = false) {
        guard let data = DocImage.encode(cgImage, as: jpeg ? .jpeg : .png) else { return nil }
        self.data = data
        fileExtension = jpeg ? "jpg" : "png"
        pixelWidth = cgImage.width
        pixelHeight = cgImage.height
        self.displayWidth = displayWidth
        self.alt = alt
    }

    public var mimeType: String {
        switch fileExtension {
        case "jpg": return "image/jpeg"
        case "gif": return "image/gif"
        default: return "image/png"
        }
    }

    /// Size in points: the preferred width (if any), else 72 dpi pixels, scaled down to fit the box.
    public func displaySize(maxWidth: Double, maxHeight: Double = .infinity) -> CGSize {
        let aspect = Double(pixelHeight) / Double(max(pixelWidth, 1))
        var width = min(displayWidth ?? Double(pixelWidth), maxWidth)
        if width * aspect > maxHeight { width = maxHeight / aspect }
        return CGSize(width: width, height: width * aspect)
    }

    static func encode(_ image: CGImage, as type: UTType, quality: Double = 0.85) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}

public struct DocTable: Sendable {
    /// rows → cells → runs. The first `headerRows` rows are headers.
    public var rows: [[[DocRun]]]
    public var headerRows: Int

    public init(rows: [[[DocRun]]], headerRows: Int = 0) {
        self.rows = rows
        self.headerRows = headerRows
    }

    public var columnCount: Int { rows.map(\.count).max() ?? 0 }
}

public enum DocBlock: Sendable {
    case paragraph(DocParagraph)
    case image(DocImage)
    case table(DocTable)
    case code(String)
    case rule
    case pageBreak
}

/// Safety limits; every reader enforces them so a hostile file can't exhaust memory.
public enum DocumentLimits {
    public static let maxArchiveBytes = 512 * 1024 * 1024
    public static let maxExpandedBytes = 1024 * 1024 * 1024
    public static let maxArchiveEntries = 20_000
    public static let maxImageBytes = 64 * 1024 * 1024
    public static let maxTextCharacters = 40_000_000
    public static let maxBlocks = 500_000
    public static let maxNesting = 200
    public static let maxPDFPages = 5_000
    public static let maxTableCells = 2_000_000
}

public enum DocumentError: LocalizedError {
    case unreadable(String)
    case malformed(String)
    case tooLarge(String)
    case unsupported(String)
    case needsLibreOffice(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let message), .malformed(let message), .tooLarge(let message), .unsupported(let message):
            return message
        case .needsLibreOffice(let ext):
            return "LibreOffice is required to convert .\(ext) files. Install it from libreoffice.org."
        }
    }
}

// MARK: Run helpers

extension Array where Element == DocRun {
    var plainText: String { map(\.text).joined() }

    /// Joins neighbours with identical style and link; drops empty runs.
    func merged() -> [DocRun] {
        var out: [DocRun] = []
        for run in self where !run.text.isEmpty {
            if let last = out.last, last.style == run.style, last.link == run.link {
                out[out.count - 1].text += run.text
            } else {
                out.append(run)
            }
        }
        return out
    }

    /// Trims leading/trailing whitespace across the run list.
    func trimmed() -> [DocRun] {
        var runs = merged()
        while let first = runs.first {
            let text = String(first.text.drop(while: { $0.isWhitespace }))
            if text.isEmpty { runs.removeFirst() } else { runs[0].text = text; break }
        }
        while let last = runs.last {
            var text = last.text
            while let c = text.last, c.isWhitespace { text.removeLast() }
            if text.isEmpty { runs.removeLast() } else { runs[runs.count - 1].text = text; break }
        }
        return runs
    }
}

extension DocModel {
    /// Number of non-empty text blocks; used by tests and sanity checks.
    var isEmpty: Bool {
        !blocks.contains { block in
            switch block {
            case .paragraph(let p): return !p.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .image, .table, .code: return true
            case .rule, .pageBreak: return false
            }
        }
    }

    /// Wraps a whole plain-text file: blank lines separate paragraphs, single newlines stay hard breaks.
    static func fromPlainText(_ text: String) -> DocModel {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var blocks: [DocBlock] = []
        for chunk in normalized.components(separatedBy: "\n\n") {
            if chunk.contains("\u{0C}") {
                let pages = chunk.components(separatedBy: "\u{0C}")
                for (i, page) in pages.enumerated() {
                    if i > 0 { blocks.append(.pageBreak) }
                    let t = page.trimmingCharacters(in: .newlines)
                    if !t.isEmpty { blocks.append(.paragraph(DocParagraph(runs: [DocRun(t)]))) }
                }
                continue
            }
            let t = chunk.trimmingCharacters(in: .newlines)
            if !t.isEmpty { blocks.append(.paragraph(DocParagraph(runs: [DocRun(t)]))) }
        }
        return DocModel(blocks: blocks)
    }
}

/// DocModel → plain text.
enum TextWriter {
    static func render(_ model: DocModel) -> String {
        var out: [(text: String, isList: Bool)] = []
        var counters = ListCounter()
        for block in model.blocks {
            switch block {
            case .paragraph(let p):
                let text = p.text
                if case .listItem(let ordered, let level) = p.kind {
                    let n = counters.next(level: level, ordered: ordered)
                    let indent = String(repeating: "    ", count: max(0, level - 1))
                    out.append((indent + (ordered ? "\(n). " : "• ") + text, true))
                    continue
                }
                counters.reset()
                if case .quote = p.kind {
                    out.append((text.split(separator: "\n", omittingEmptySubsequences: false).map { "  " + $0 }.joined(separator: "\n"), false))
                } else {
                    out.append((text, false))
                }
            case .code(let code):
                counters.reset()
                out.append((code.hasSuffix("\n") ? String(code.dropLast()) : code, false))
            case .table(let table):
                counters.reset()
                out.append((table.rows.map { $0.map { $0.plainText.replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\t") }
                    .joined(separator: "\n"), false))
            case .image, .rule:
                counters.reset()
            case .pageBreak:
                counters.reset()
                out.append(("\u{0C}", false))
            }
        }
        // Blank line between blocks, single newline between consecutive list items.
        var result = ""
        var previousWasList = false
        for (index, block) in out.enumerated() {
            if index > 0 { result += (block.isList && previousWasList) ? "\n" : "\n\n" }
            result += block.text
            previousWasList = block.isList
        }
        return result.replacingOccurrences(of: "\n\n\u{0C}\n\n", with: "\n\u{0C}\n") + "\n"
    }
}

/// Numbering for nested lists: `next(level:ordered:)` increments that level, resets deeper ones,
/// and restarts when the list type at that level changes (a bullet list followed by a numbered one).
struct ListCounter {
    private var counts: [Int: (n: Int, ordered: Bool)] = [:]

    mutating func next(level: Int, ordered: Bool) -> Int {
        counts = counts.filter { $0.key <= level }
        let previous = counts[level]
        let n = previous.map { $0.ordered == ordered ? $0.n + 1 : 1 } ?? 1
        counts[level] = (n, ordered)
        return n
    }

    mutating func reset() { counts = [:] }
}
