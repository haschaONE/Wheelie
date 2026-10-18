import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Broad category of an input file; decides which output formats the wheel offers.
public enum FileKind: String, Sendable {
    case image, video, audio, pdf
    /// Word processing / text: docx, doc, rtf, rtfd, odt, html, Markdown, txt, Pages (LibreOffice).
    case document
    /// EPUB books.
    case ebook
    /// pptx, ppt, key, odp (LibreOffice only).
    case presentation
    /// csv, tsv, xlsx (built in); xls, numbers, ods (LibreOffice).
    case spreadsheet
    case unknown

    /// Extensions decided without asking UTType (unknown to it on some systems, or misclassified).
    static let byExtension: [String: FileKind] = {
        var map: [String: FileKind] = [:]
        for ext in ["webp", "avif", "heic", "heif", "svg", "jxl", "ico", "icns", "dng"] { map[ext] = .image }
        for ext in ["mkv", "webm", "avi", "flv", "wmv", "m4v", "mts", "m2ts", "3gp", "mpg", "mpeg"] { map[ext] = .video }
        for ext in ["opus", "ogg", "oga", "wma", "aif", "aiff", "caf", "amr"] { map[ext] = .audio }
        for ext in ["docx", "docm", "dotx", "doc", "rtf", "rtfd", "odt", "html", "htm", "xhtml",
                    "md", "markdown", "mdown", "mkd", "txt", "text", "pages"] { map[ext] = .document }
        map["epub"] = .ebook
        for ext in ["pptx", "ppt", "pps", "ppsx", "key", "odp"] { map[ext] = .presentation }
        for ext in ["xlsx", "xlsm", "xls", "csv", "tsv", "numbers", "ods"] { map[ext] = .spreadsheet }
        return map
    }()

    /// Document formats that are folders on disk (packages); any other folder is `.unknown`.
    static let packageExtensions: Set<String> = ["rtfd", "pages", "key", "numbers"]

    public init(url: URL) {
        let ext = url.pathExtension.lowercased()
        if url.hasDirectoryPath && !FileKind.packageExtensions.contains(ext) { self = .unknown; return }
        if let kind = FileKind.byExtension[ext] { self = kind; return }
        guard let type = UTType(filenameExtension: ext) else { self = .unknown; return }
        if type.conforms(to: .pdf) { self = .pdf }
        else if type.conforms(to: .image) { self = .image }
        else if type.conforms(to: .movie) || type.conforms(to: .video) { self = .video }
        else if type.conforms(to: .audio) { self = .audio }
        else { self = .unknown }
    }
}

public enum OutputFormat: String, CaseIterable, Sendable, Identifiable {
    // Declaration order is the petal order on the wheel (ConvertFeature uses allCases' index),
    // arranged so each kind's targets read in a sensible order around the ring.
    case png, jpeg, heic, webp, avif, tiff
    case mp4, mov, webm, mkv, avi
    case gif, bmp, ico, icns
    case pdf
    case docx, markdown, html, txt, rtf, odt
    case csv, xlsx
    case mp3, m4a, wav, flac, aiff, opus

    /// The inner ring fits this many petals.
    public static let maxPetals = 9

    public var id: String { rawValue }

    public var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .markdown: return "md"
        default: return rawValue
        }
    }

    public var label: String {
        switch self {
        case .jpeg: return "JPG"
        case .txt: return "Text"
        case .webp: return "WebP"
        case .docx: return "Word"
        case .markdown: return "Markdown"
        case .xlsx: return "Excel"
        case .opus: return "Opus"
        default: return rawValue.uppercased()
        }
    }

    /// SF Symbol shown on the wheel petal.
    public var symbol: String {
        switch self {
        case .png, .jpeg, .heic, .webp, .avif, .tiff, .bmp: return "photo"
        case .ico, .icns: return "app.dashed"
        case .pdf: return "doc.richtext"
        case .mp4, .mov, .webm, .mkv, .avi: return "film"
        case .gif: return "sparkles.rectangle.stack"
        case .mp3, .m4a, .wav, .flac, .aiff, .opus: return "waveform"
        case .txt: return "text.alignleft"
        case .docx: return "doc.text"
        case .markdown: return "number"
        case .html: return "chevron.left.forwardslash.chevron.right"
        case .rtf: return "textformat"
        case .odt: return "doc"
        case .csv: return "tablecells"
        case .xlsx: return "tablecells.fill"
        }
    }

    /// Extensions that already are this format (used to hide no-op targets).
    var equivalentExtensions: Set<String> {
        switch self {
        case .jpeg: return ["jpg", "jpeg"]
        case .tiff: return ["tif", "tiff"]
        case .heic: return ["heic", "heif"]
        case .markdown: return ["md", "markdown", "mdown", "mkd"]
        case .html: return ["html", "htm", "xhtml"]
        case .txt: return ["txt", "text"]
        case .xlsx: return ["xlsx", "xlsm"]
        case .aiff: return ["aiff", "aif"]
        default: return [rawValue]
        }
    }

    // MARK: Matrix

    /// Every target a kind can be converted to, most useful first (before availability checks).
    static func ranked(for kind: FileKind) -> [OutputFormat] {
        switch kind {
        case .image: return [.png, .jpeg, .heic, .webp, .pdf, .avif, .tiff, .gif, .bmp, .ico, .icns]
        case .video: return [.mp4, .mov, .gif, .webm, .mkv, .mp3, .m4a, .wav, .avi]
        case .audio: return [.mp3, .m4a, .wav, .flac, .aiff, .opus]
        case .pdf: return [.docx, .png, .jpeg, .txt, .markdown, .html, .rtf, .odt]
        case .document: return [.pdf, .docx, .markdown, .html, .txt, .rtf, .odt]
        case .ebook: return [.pdf, .docx, .markdown, .html, .txt, .rtf]
        case .spreadsheet: return [.pdf, .xlsx, .csv, .html]
        case .presentation: return [.pdf, .png, .jpeg]
        case .unknown: return []
        }
    }

    /// Image targets ordered for the source, so the `maxPetals` cut drops what that source least needs
    /// (there are more image targets than petals): photos lose ICNS, icon sources (PNG/ICO/ICNS) lose BMP,
    /// vector SVG loses GIF/BMP, and animated GIF (plus MP4/WebM) loses HEIC/TIFF/BMP. Every target stays
    /// reachable from some common source.
    static func imageRanking(for ext: String) -> [OutputFormat] {
        switch ext {
        case "png", "ico", "icns":
            return [.png, .jpeg, .heic, .webp, .pdf, .avif, .ico, .icns, .tiff, .gif, .bmp]
        case "svg", "svgz":
            return [.png, .jpeg, .pdf, .ico, .icns, .webp, .heic, .avif, .tiff, .gif, .bmp]
        case "gif":
            // Animated GIF → video is the common request; offer it right after the stills.
            return [.png, .jpeg, .mp4, .webm, .webp, .avif, .pdf, .ico, .icns, .gif, .heic, .tiff, .bmp]
        default:
            return ranked(for: .image)
        }
    }

    /// Whether the encoder for this format exists on this Mac.
    var isAvailable: Bool {
        switch self {
        case .avif: return Converter.canEncodeAVIF
        default: return true
        }
    }

    /// Wheel targets for a kind: available formats, most useful first, at most `maxPetals`.
    public static func targets(for kind: FileKind) -> [OutputFormat] {
        var list = ranked(for: kind).filter(\.isAvailable)
        if kind == .presentation && !LibreOffice.isInstalled { list = [] }
        return Array(list.prefix(maxPetals))
    }

    /// Everything `Converter.convert` accepts for this file (uncapped; depends on extension and installed tools).
    public static func allTargets(for url: URL) -> [OutputFormat] {
        let kind = FileKind(url: url)
        let ext = url.pathExtension.lowercased()
        if LibreOffice.requiredExtensions.contains(ext) && !LibreOffice.isInstalled { return [] }
        var list = ranked(for: kind).filter(\.isAvailable)
        switch kind {
        case .image:
            list = imageRanking(for: ext).filter(\.isAvailable)
        case .spreadsheet where ["csv", "tsv"].contains(ext):
            list = [.pdf, .xlsx, .html, .csv]
        default:
            break
        }
        return list
    }

    /// Formats valid for every file in the selection, minus formats every file already has,
    /// in usefulness order and capped to the ring's `maxPetals`.
    public static func targets(for urls: [URL]) -> [OutputFormat] {
        guard let first = urls.first else { return [] }
        var common = allTargets(for: first)
        for url in urls.dropFirst() {
            let allowed = Set(allTargets(for: url))
            common = common.filter(allowed.contains)
            if common.isEmpty { return [] }
        }
        let exts = Set(urls.map { $0.pathExtension.lowercased() })
        return Array(common.filter { !exts.isSubset(of: $0.equivalentExtensions) }.prefix(maxPetals))
    }
}
