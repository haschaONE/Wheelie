import Foundation
import UniformTypeIdentifiers

/// What "Compress Files…" and "Remove Metadata…" let users pick.
public enum CompressInputs {
    /// Images, audio/video and PDFs, plus the media extensions `FileKind` knows by name. macOS doesn't
    /// declare some of those (e.g. .mkv is a dynamic type conforming to nothing), and an open panel
    /// filtered by the broad types alone would grey them out even though both engines handle them.
    public static var contentTypes: [UTType] {
        var types: [UTType] = [.image, .audiovisualContent, .pdf]
        for (ext, kind) in FileKind.byExtension.sorted(by: { $0.key < $1.key })
        where [.image, .video, .audio].contains(kind) {
            guard let type = UTType(filenameExtension: ext), !types.contains(where: { type.conforms(to: $0) }) else { continue }
            types.append(type)
        }
        return types
    }
}

/// How hard a preset squeezes. Images/PDFs and video/audio have separate strengths in the UI.
public enum CompressionStrength: String, CaseIterable, Sendable, Identifiable {
    case light, balanced, strong

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .light: return "Light"
        case .balanced: return "Balanced"
        case .strong: return "Strong"
        }
    }

    public var summary: String {
        switch self {
        case .light: return "Best quality with moderate file-size savings."
        case .balanced: return "Smaller files with less quality loss."
        case .strong: return "Smaller files with more quality loss."
        }
    }
}

/// Optional cap on the longest edge of compressed images.
public enum ImageSizeLimit: String, CaseIterable, Sendable, Identifiable {
    case original, large, medium, small

    public var id: String { rawValue }

    /// Longest edge in pixels; nil keeps the original dimensions.
    public var maxPixels: Int? {
        switch self {
        case .original: return nil
        case .large: return 2560
        case .medium: return 1600
        case .small: return 1024
        }
    }

    public var label: String {
        switch self {
        case .original: return "Keep original dimensions"
        default: return "\(rawValue.capitalized) · \(maxPixels!) px longest edge"
        }
    }
}

/// What the user asked for: a quality preset or a size budget per file.
public enum CompressionGoal: Sendable, Equatable {
    case preset
    /// Every output must be at most this many bytes (computed separately for each file).
    case maxBytes(Int64)
    /// Every output must be at least this many percent smaller than its original (1...99).
    case reduction(Int)
}

public struct CompressionOptions: Sendable, Equatable {
    public var goal: CompressionGoal
    /// Used for images and PDFs.
    public var imageStrength: CompressionStrength
    /// Used for video and audio.
    public var mediaStrength: CompressionStrength
    public var imageSize: ImageSizeLimit

    public init(goal: CompressionGoal = .preset, imageStrength: CompressionStrength = .balanced,
                mediaStrength: CompressionStrength = .balanced, imageSize: ImageSizeLimit = .original) {
        self.goal = goal
        self.imageStrength = imageStrength
        self.mediaStrength = mediaStrength
        self.imageSize = imageSize
    }

    /// The size budget for one file: nil in preset mode.
    public func targetBytes(forOriginal original: Int64) -> Int64? {
        switch goal {
        case .preset: return nil
        case .maxBytes(let bytes): return bytes
        case .reduction(let percent):
            let clamped = Int64(min(max(percent, 1), 99))
            return original * (100 - clamped) / 100
        }
    }
}

public struct CompressionResult: Sendable {
    public let source: URL
    public let output: URL
    public let originalBytes: Int64
    public let compressedBytes: Int64

    /// 0...1, e.g. 0.64 for a file that became 64% smaller.
    public var reduction: Double {
        originalBytes > 0 ? max(0, 1 - Double(compressedBytes) / Double(originalBytes)) : 0
    }
}

public enum CompressionError: LocalizedError, Equatable {
    case wouldExceed
    case unreadable(String)
    case unsupported(String)
    case animated
    /// Multi-page TIFFs, image sequences: the output formats hold one image, so pages would be lost.
    case multiFrame(Int)
    case tooSmall
    case targetUnreachable(smallest: Int64)
    case targetTooSmallForDuration
    case targetTooSmallAfterAudio
    case videoDidNotFit
    case videoUnverified
    case pdfLocked
    case pdfFailed
    case pdfUnverified
    case imageFailed

    public var errorDescription: String? {
        switch self {
        case .wouldExceed: return "Compressed output would exceed the original or target file size."
        case .unreadable(let name): return "Couldn't read \(name)."
        case .unsupported(let name): return "\(name) can't be compressed."
        case .animated: return "Animated PNG and WebP images can't be compressed. Convert them to GIF or MP4 first."
        case .multiFrame(let count):
            return "This image has \(count) pages or frames, and compressing it would keep only the first. "
                + "Split it into single images first."
        case .tooSmall: return "This file is already smaller than 1 KB."
        case .targetUnreachable(let smallest):
            return "Could not reach the target size. Smallest attempt was \(ByteSize.string(smallest)). Try a larger target."
        case .targetTooSmallForDuration: return "The target is too small for this duration. Choose a larger size."
        case .targetTooSmallAfterAudio: return "The target is too small after audio and container overhead. Choose a larger size."
        case .videoDidNotFit: return "The encoder could not fit this video within the target. Choose a larger size."
        case .videoUnverified: return "The compressed video's duration or tracks could not be verified."
        case .pdfLocked: return "This PDF cannot be read or is password-protected."
        case .pdfFailed: return "Could not create the compressed PDF."
        case .pdfUnverified: return "The compressed PDF could not be verified."
        case .imageFailed: return "ImageIO could not create the compressed image."
        }
    }
}

public enum ByteSize {
    public static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Current size on disk. Uses FileManager, not URL resource values: those are cached per URL
    /// instance and go stale when the same URL is rewritten (as the budget searches do).
    /// Symlinks are followed: `attributesOfItem` alone would measure the link, not the file it points to.
    public static func of(_ url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }
}

/// The "Target Size" field: what users may type, and its limits.
public enum TargetSize {
    public static let minBytes: Int64 = 1_000
    public static let maxBytes: Int64 = 1_000_000_000_000

    /// Parses "2.5" / "2,5" (or anything `formatter` reads) in units of `unitBytes`. Returns nil for text
    /// that isn't a positive number or for sizes above `maxBytes`, so huge inputs ("1e20", 20 digits)
    /// never reach an integer conversion that would trap. Sizes below `minBytes` are returned so the
    /// caller can say "at least 1 KB".
    public static func parse(_ text: String, unitBytes: Double, formatter: NumberFormatter) -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let value = formatter.number(from: trimmed)?.doubleValue ?? Double(trimmed.replacingOccurrences(of: ",", with: ".")),
              value.isFinite, value > 0, unitBytes.isFinite, unitBytes > 0
        else { return nil }
        let bytes = (value * unitBytes).rounded()
        guard bytes.isFinite, bytes <= Double(maxBytes) else { return nil }
        return Int64(bytes)
    }
}

/// Small helpers shared by the compression and metadata engines.
enum TempDir {
    /// A fresh private temp folder; remove it when done.
    static func make(_ prefix: String = "wheelie") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
