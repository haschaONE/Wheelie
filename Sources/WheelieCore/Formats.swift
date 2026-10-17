import Foundation
import UniformTypeIdentifiers

/// Broad category of an input file; decides which output formats the wheel offers.
public enum FileKind: String, Sendable {
    case image, video, audio, pdf, unknown

    public init(url: URL) {
        let ext = url.pathExtension.lowercased()
        // ImageIO reads WebP/AVIF, but UTType may not know the extension on every system.
        if ["webp", "avif", "heic", "heif"].contains(ext) { self = .image; return }
        guard let type = UTType(filenameExtension: ext) else { self = .unknown; return }
        if type.conforms(to: .pdf) { self = .pdf }
        else if type.conforms(to: .image) { self = .image }
        else if type.conforms(to: .movie) || type.conforms(to: .video) || ["mkv", "webm", "avi", "flv", "wmv"].contains(ext) { self = .video }
        else if type.conforms(to: .audio) || ["opus", "ogg"].contains(ext) { self = .audio }
        else { self = .unknown }
    }
}

public enum OutputFormat: String, CaseIterable, Sendable, Identifiable {
    case png, jpeg, heic, webp, tiff, pdf
    case mp4, mov, webm, gif
    case mp3, m4a, wav, flac
    case txt

    public var id: String { rawValue }

    public var fileExtension: String {
        self == .jpeg ? "jpg" : rawValue
    }

    public var label: String {
        switch self {
        case .jpeg: return "JPG"
        case .txt: return "Text"
        default: return rawValue.uppercased()
        }
    }

    /// SF Symbol shown on the wheel petal.
    public var symbol: String {
        switch self {
        case .png, .jpeg, .heic, .webp, .tiff: return "photo"
        case .pdf: return "doc.richtext"
        case .mp4, .mov, .webm: return "film"
        case .gif: return "sparkles.rectangle.stack"
        case .mp3, .m4a, .wav, .flac: return "waveform"
        case .txt: return "text.alignleft"
        }
    }

    /// Extensions that already are this format (used to hide no-op targets).
    var equivalentExtensions: Set<String> {
        switch self {
        case .jpeg: return ["jpg", "jpeg"]
        case .tiff: return ["tif", "tiff"]
        case .heic: return ["heic", "heif"]
        default: return [rawValue]
        }
    }

    public static func targets(for kind: FileKind) -> [OutputFormat] {
        switch kind {
        case .image: return [.png, .jpeg, .heic, .webp, .tiff, .pdf]
        case .video: return [.mp4, .mov, .webm, .gif, .mp3, .m4a]
        case .audio: return [.mp3, .m4a, .wav, .flac]
        case .pdf: return [.png, .jpeg, .txt]
        case .unknown: return []
        }
    }

    /// Formats valid for every file in the selection, minus formats every file already has.
    public static func targets(for urls: [URL]) -> [OutputFormat] {
        guard let first = urls.first else { return [] }
        var common = targets(for: FileKind(url: first))
        for url in urls.dropFirst() {
            let allowed = Set(targets(for: FileKind(url: url)))
            common = common.filter(allowed.contains)
        }
        let exts = Set(urls.map { $0.pathExtension.lowercased() })
        return common.filter { !exts.isSubset(of: $0.equivalentExtensions) }
    }
}
