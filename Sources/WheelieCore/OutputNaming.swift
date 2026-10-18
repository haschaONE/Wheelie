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
        var n = 1
        var url = candidate(for: source, ext: ext, suffix: suffix, in: directory, number: n)
        // attributesOfItem doesn't follow a final symlink, so a dangling link counts as taken
        // (fileExists would say "free" and the write would go through the link).
        while (try? fileManager.attributesOfItem(atPath: url.path)) != nil {
            n += 1
            url = candidate(for: source, ext: ext, suffix: suffix, in: directory, number: n)
        }
        return url
    }

    /// Like `uniqueURL`, but claims the name: an empty placeholder is created at the returned path
    /// with O_CREAT|O_EXCL, so two conversions running at the same time (logo.png and logo.tiff → JPG,
    /// or same-named files with "Save to" set) can never be handed the same output. The caller
    /// overwrites the placeholder with the real output, or removes it when the conversion fails.
    public static func reserveURL(for source: URL, ext: String, suffix: String = "", in directory: URL? = nil) throws -> URL {
        for n in 1...100_000 {
            let url = candidate(for: source, ext: ext, suffix: suffix, in: directory, number: n)
            // O_EXCL also fails on an existing symlink (dangling or not), so nothing is written through one.
            let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
            if fd >= 0 {
                close(fd)
                return url
            }
            guard errno == EEXIST else { throw ConversionError.writeFailed(url) }
        }
        throw ConversionError.writeFailed(candidate(for: source, ext: ext, suffix: suffix, in: directory, number: 1))
    }

    private static func candidate(for source: URL, ext: String, suffix: String, in directory: URL?, number: Int) -> URL {
        let dir = directory ?? preferredDirectory ?? source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent + suffix
        let name = number == 1 ? base : "\(base) \(number)"
        return dir.appendingPathComponent(name).appendingPathExtension(ext)
    }
}
