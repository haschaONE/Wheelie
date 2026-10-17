import Foundation

public enum OutputNaming {
    /// Where outputs go when no directory is passed; nil = next to the original.
    /// Set by the app from the "Save to" setting.
    nonisolated(unsafe) public static var preferredDirectory: URL?

    /// `photo.png` -> `photo.jpg`; if taken, `photo 2.jpg`, `photo 3.jpg`, ...
    /// `suffix` is appended to the base name (e.g. "-p3" for PDF page 3).
    public static func uniqueURL(for source: URL, ext: String, suffix: String = "",
                                 in directory: URL? = nil,
                                 fileManager: FileManager = .default) -> URL {
        let dir = directory ?? preferredDirectory ?? source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent + suffix
        var candidate = dir.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        // attributesOfItem doesn't follow a final symlink, so a dangling link counts as taken
        // (fileExists would say "free" and the write would go through the link).
        while (try? fileManager.attributesOfItem(atPath: candidate.path)) != nil {
            candidate = dir.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }
}
