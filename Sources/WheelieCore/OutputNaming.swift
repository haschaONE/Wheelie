import Foundation
import os

public enum OutputNaming {
    /// The "Save to" folder as the app set it (nil = next to the original), even while it's
    /// unavailable. Lock-protected: the main thread sets it while jobs read it in the background.
    public static var configuredDirectory: URL? {
        get { configured.withLock { $0 } }
        set { configured.withLock { $0 = newValue } }
    }

    /// Where outputs go when no directory is passed; nil = next to the original.
    /// Set by the app from the "Save to" setting. Reads fall back to nil (next to the original)
    /// while that folder is missing or read-only, e.g. an unplugged external drive, so results
    /// aren't sent to a dead path; the Settings window explains why.
    public static var preferredDirectory: URL? {
        get {
            guard let dir = configuredDirectory, OutputLocation.isUsableFolder(dir) else { return nil }
            return dir
        }
        set { configuredDirectory = newValue }
    }

    private static let configured = OSAllocatedUnfairLock<URL?>(initialState: nil)

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
