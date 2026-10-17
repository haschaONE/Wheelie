import Foundation

/// Entry point for the Compress tool: one file in, one smaller file out ("<name> compressed.<ext>").
public enum Compressor {
    /// Compresses one file. Never delivers a file that is not smaller than the original
    /// (or larger than the requested target); throws `CompressionError.wouldExceed` instead.
    public static func compress(_ source: URL, options: CompressionOptions,
                                outputDirectory: URL? = nil) async throws -> CompressionResult {
        let original = ByteSize.of(source)
        guard original > 0 else { throw CompressionError.unreadable(source.lastPathComponent) }
        let target = options.targetBytes(forOriginal: original)
        if target != nil, original < 1024 { throw CompressionError.tooSmall }
        // The budget every engine aims for: the target, and always strictly below the original.
        let cap = min(target ?? Int64.max, original - 1)

        let work = try TempDir.make("wheelie-compress")
        defer { try? FileManager.default.removeItem(at: work) }

        let produced: (url: URL, ext: String)
        switch FileKind(url: source) {
        case .image:
            produced = try await ImageCompressor.compress(source, options: options, cap: cap,
                                                          targeted: target != nil, workDir: work)
        case .video, .audio:
            produced = try await MediaCompressor.compress(source, options: options, cap: cap,
                                                          targeted: target != nil, workDir: work)
        case .pdf:
            produced = try PDFCompressor.compress(source, strength: options.imageStrength, cap: cap,
                                                  targeted: target != nil, workDir: work)
        case .unknown:
            throw CompressionError.unsupported(source.lastPathComponent)
        }

        let size = ByteSize.of(produced.url)
        guard size > 0, size < original, size <= (target ?? Int64.max) else {
            throw CompressionError.wouldExceed
        }
        let output = OutputNaming.uniqueURL(for: source, ext: produced.ext, suffix: " compressed", in: outputDirectory)
        try FileManager.default.moveItem(at: produced.url, to: output)
        return CompressionResult(source: source, output: output, originalBytes: original, compressedBytes: size)
    }
}

/// Finds the best-quality encoding that fits a byte budget.
enum BudgetSearch {
    /// `levels` are ordered best quality first; `scales` are tried in order (1.0 first).
    /// `encode(level, scale)` returns the encoded bytes (or nil to skip that scale).
    /// Assumes size shrinks as the level index grows; binary-searches within each scale.
    static func run(levels: Int, scales: [Double], cap: Int64,
                    encode: (Int, Double) async throws -> Data?) async throws -> Data {
        precondition(levels > 0)
        var smallest = Int64.max
        for scale in scales {
            guard let worst = try await encode(levels - 1, scale) else { continue }
            smallest = min(smallest, Int64(worst.count))
            guard Int64(worst.count) <= cap else { continue }
            var lo = 0, hi = levels - 1
            var best = worst
            while lo < hi {
                let mid = (lo + hi) / 2
                guard let data = try await encode(mid, scale) else { break }
                if Int64(data.count) <= cap { best = data; hi = mid } else { lo = mid + 1 }
            }
            return best
        }
        throw CompressionError.targetUnreachable(smallest: smallest == .max ? 0 : smallest)
    }

    static let imageScales: [Double] = [1, 0.75, 0.56, 0.42, 0.32, 0.24, 0.18, 0.13, 0.1]
}
