import Foundation

/// Errors from the file actions (copy, move, Terminal, AirDrop, extract).
public enum FileActionError: LocalizedError, Equatable {
    /// `verb` completes "Only local files and folders can …", e.g. "be moved".
    case notLocal(verb: String)
    case destinationNotFolder
    case destinationInsideSource(String)
    case alreadyInDestination(String)
    case partial(done: Int, total: Int, verb: String, first: String)
    case clipboardFailed(String)
    case appMissing(String)
    case airDropUnavailable

    public var errorDescription: String? {
        switch self {
        case .notLocal(let verb):
            return "Only local files and folders can \(verb)."
        case .destinationNotFolder:
            return "The destination must be an existing local folder."
        case .destinationInsideSource(let name):
            return "Choose a destination outside “\(name)”."
        case .alreadyInDestination(let name):
            return "No items were moved: they're already in “\(name)”."
        case .partial(let done, let total, let verb, let first):
            return "\(verb) \(done) of \(total). \(first)"
        case .clipboardFailed(let what):
            return "The \(what) couldn't be placed on the clipboard."
        case .appMissing(let name):
            return "\(name) isn't installed. Choose another terminal app in Wheelie's settings."
        case .airDropUnavailable:
            return "AirDrop isn't available for these items on this Mac."
        }
    }
}

public enum FileActions {
    // MARK: Paths and descriptions

    /// Newline-separated POSIX paths, in the given order (what "Copy Path" puts on the clipboard).
    public static func pathList(_ urls: [URL]) -> String {
        urls.map { $0.standardizedFileURL.path }.joined(separator: "\n")
    }

    /// True for a folder (following symlinks), false for files and missing paths.
    public static func isDirectory(_ url: URL, fileManager: FileManager = .default) -> Bool {
        var isDir: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Bundles such as `Foo.app` are folders on disk but files to the user.
    public static func isPackage(_ url: URL) -> Bool {
        (try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.isPackageKey]).isPackage) == true
    }

    /// "1 file", "3 files", "2 folders", "4 items" (mixed).
    public static func countPhrase(_ urls: [URL], fileManager: FileManager = .default) -> String {
        let folders = urls.filter { isDirectory($0, fileManager: fileManager) && !isPackage($0) }.count
        let noun: String
        if folders == 0 { noun = urls.count == 1 ? "file" : "files" }
        else if folders == urls.count { noun = urls.count == 1 ? "folder" : "folders" }
        else { noun = "items" }
        return "\(urls.count) \(noun)"
    }

    /// Folders a terminal should open in: each folder itself, or the parent of a file (or package).
    /// Deduplicated, in the original order.
    public static func terminalFolders(for urls: [URL], fileManager: FileManager = .default) -> [URL] {
        var seen = Set<String>()
        var folders: [URL] = []
        for url in urls {
            let item = url.standardizedFileURL
            let folder = isDirectory(item, fileManager: fileManager) && !isPackage(item)
                ? item : item.deletingLastPathComponent()
            if seen.insert(folder.path).inserted { folders.append(folder) }
        }
        return folders
    }

    /// Short, stable hex digest of a set of paths (FNV-1a), for window ids.
    public static func stableHash(_ urls: [URL]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in pathList(urls).utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    // MARK: Unique naming

    /// Extensions treated as one unit when numbering, so `backup.tar.gz` -> `backup 2.tar.gz`.
    static let compoundExtensions = ["tar.gz", "tar.bz2", "tar.xz", "tar.zst", "tar.lz", "tar.z"]

    /// "photo.png" -> ("photo", "png"); "backup.tar.gz" -> ("backup", "tar.gz");
    /// "Folder" -> ("Folder", ""); ".zshrc" -> (".zshrc", "").
    public static func splitName(_ name: String) -> (base: String, ext: String) {
        let lower = name.lowercased()
        for ext in compoundExtensions where lower.hasSuffix("." + ext) && lower.count > ext.count + 1 {
            let base = String(name.dropLast(ext.count + 1))
            return (base, String(name.suffix(ext.count)))
        }
        let ns = name as NSString
        let ext = ns.pathExtension
        let base = ns.deletingPathExtension
        guard !ext.isEmpty, !base.isEmpty else { return (name, "") }
        return (base, ext)
    }

    /// True if something (even a dangling symlink) occupies `url`.
    static func isTaken(_ url: URL, fileManager: FileManager) -> Bool {
        fileManager.fileExists(atPath: url.path) || (try? fileManager.attributesOfItem(atPath: url.path)) != nil
    }

    /// `name` in `directory`, or `name 2`, `name 3`… when taken. With `keepsExtension`, the number goes
    /// before the extension (`photo 2.png`); otherwise after the whole name (folders: `v1.2 2`).
    public static func uniqueURL(named name: String, in directory: URL, keepsExtension: Bool = true,
                                 fileManager: FileManager = .default) -> URL {
        let (base, ext) = keepsExtension ? splitName(name) : (name, "")
        func candidate(_ n: Int) -> URL {
            let stem = n == 1 ? base : "\(base) \(n)"
            return directory.appendingPathComponent(ext.isEmpty ? stem : "\(stem).\(ext)")
        }
        var n = 1
        while isTaken(candidate(n), fileManager: fileManager) { n += 1 }
        return candidate(n)
    }

    /// A new folder name in `directory`: `name`, `name 2`, `name 3`…
    public static func uniqueFolderURL(named name: String, in directory: URL,
                                       fileManager: FileManager = .default) -> URL {
        uniqueURL(named: name, in: directory, keepsExtension: false, fileManager: fileManager)
    }

    // MARK: Move

    private static func resolved(_ url: URL) -> URL {
        URL(fileURLWithPath: url.path).standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func resourceID(_ url: URL) -> NSObject? {
        (try? URL(fileURLWithPath: url.path).resourceValues(forKeys: [.fileResourceIdentifierKey]))?
            .fileResourceIdentifier as? NSObject
    }

    /// Throws unless `destination` is an existing folder outside every moved folder.
    public static func validateMove(_ items: [URL], to destination: URL,
                                    fileManager: FileManager = .default) throws {
        guard !items.isEmpty, items.allSatisfy(\.isFileURL) else { throw FileActionError.notLocal(verb: "be moved") }
        guard destination.isFileURL, isDirectory(destination, fileManager: fileManager) else {
            throw FileActionError.destinationNotFolder
        }
        let dest = resolved(destination)
        // Every folder from the destination up to the root, by path and by file identity
        // (catches symlinks, firmlinks and case differences).
        var ancestors: [(path: String, id: NSObject?)] = []
        var cursor = dest
        while true {
            ancestors.append((cursor.path, resourceID(cursor)))
            let parent = cursor.deletingLastPathComponent()
            if parent.path == cursor.path || cursor.path == "/" { break }
            cursor = parent
        }
        for item in items where isDirectory(item, fileManager: fileManager) {
            let source = resolved(item)
            let id = resourceID(source)
            let inside = ancestors.contains { ancestor in
                ancestor.path == source.path || (id != nil && ancestor.id?.isEqual(id) == true)
            }
            if inside { throw FileActionError.destinationInsideSource(item.lastPathComponent) }
        }
    }

    /// The items that aren't already directly inside `destination`.
    public static func itemsNeedingMove(_ items: [URL], to destination: URL) -> [URL] {
        let dest = resolved(destination)
        let destID = resourceID(dest)
        return items.filter { item in
            let parent = resolved(item.deletingLastPathComponent())
            if parent.path == dest.path { return false }
            if let destID, let parentID = resourceID(parent), parentID.isEqual(destID) { return false }
            return true
        }
    }

    /// Moves `items` into `destination` without ever overwriting (`name 2.ext` on a clash).
    /// Items already in `destination` are skipped. Returns the new locations.
    /// Throws `.partial` if some moves failed (the others stay moved).
    public static func move(_ items: [URL], to destination: URL,
                            fileManager: FileManager = .default) throws -> [URL] {
        try validateMove(items, to: destination, fileManager: fileManager)
        let pending = itemsNeedingMove(items, to: destination)
        guard !pending.isEmpty else { throw FileActionError.alreadyInDestination(destination.lastPathComponent) }

        var moved: [URL] = []
        var errors: [String] = []
        for item in pending {
            let keepsExtension = !isDirectory(item, fileManager: fileManager) || isPackage(item)
            // moveItem refuses to replace an existing item, so a racing file can't be overwritten.
            let target = uniqueURL(named: item.lastPathComponent, in: destination,
                                   keepsExtension: keepsExtension, fileManager: fileManager)
            do {
                try fileManager.moveItem(at: item, to: target)
                moved.append(target)
            } catch {
                errors.append(error.localizedDescription)
            }
        }
        if let first = errors.first {
            throw FileActionError.partial(done: moved.count, total: pending.count, verb: "Moved", first: first)
        }
        return moved
    }
}

/// Names for the Terminal action's error messages; one catalog with the Settings window.
public enum TerminalApps {
    public static let defaultBundleID = TerminalCatalog.defaultBundleID

    public static func name(for bundleID: String) -> String {
        TerminalCatalog.app(for: bundleID).name
    }
}
