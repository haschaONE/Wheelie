import Foundation

/// Archive types the Extract action understands, detected from the file name.
public enum ArchiveFormat: String, Sendable, CaseIterable {
    case zip, tar, gzip, sevenZip, rar

    /// Longest suffixes first so `.tar.gz` wins over `.gz`.
    static let suffixes: [(suffix: String, format: ArchiveFormat)] = [
        (".tar.bz2", .tar), (".tar.gz", .tar), (".tar.xz", .tar),
        (".tbz2", .tar), (".tgz", .tar), (".tbz", .tar), (".txz", .tar), (".tar", .tar),
        (".zip", .zip), (".gz", .gzip), (".7z", .sevenZip), (".rar", .rar),
    ]

    public init?(url: URL) {
        guard let match = Self.match(url.lastPathComponent) else { return nil }
        self = match.format
    }

    private static func match(_ name: String) -> (suffix: String, format: ArchiveFormat)? {
        let lower = name.lowercased()
        return suffixes.first { lower.hasSuffix($0.suffix) && lower.count > $0.suffix.count }
    }

    /// Name without the archive extension: `photos.tar.gz` -> `photos`, `notes.txt.gz` -> `notes.txt`.
    public static func baseName(of url: URL) -> String {
        let name = url.lastPathComponent
        guard let match = match(name) else { return url.deletingPathExtension().lastPathComponent }
        return String(name.dropLast(match.suffix.count))
    }
}

public enum ArchiveError: LocalizedError, Equatable {
    case unsupported(String)
    case toolMissing(ArchiveFormat)
    case unsafeEntry(String)
    case linkEscapes(String)
    case empty
    case unreadable(String)
    case quarantineFailed(String)
    case encrypted
    /// Extraction failed (`reason`) and the hidden staging folder couldn't be removed either.
    case cleanupFailed(folder: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let name):
            return "“\(name)” isn't an archive Wheelie can extract."
        case .toolMissing(let format):
            return "This Mac can't extract \(format.rawValue) archives (/usr/bin/tar is missing)."
        case .unsafeEntry(let path):
            return "The archive contains an unsafe path (“\(path)”), so it wasn't extracted."
        case .linkEscapes(let path):
            return "The archive contains a link that points outside its folder (“\(path)”), so it wasn't extracted."
        case .empty:
            return "The archive is empty."
        case .unreadable(let detail):
            return "The archive couldn't be read. \(detail)"
        case .quarantineFailed(let path):
            return "“\(path)” couldn't be marked as downloaded, so the archive wasn't extracted."
        case .encrypted:
            return "The archive is password-protected. Wheelie can't extract encrypted archives."
        case .cleanupFailed(let folder, let reason):
            return "\(reason) Wheelie also couldn't remove its hidden temporary folder “\(folder)” next to it; please delete it."
        }
    }
}

public enum ArchiveExtractor {
    enum Backend: Equatable {
        /// bsdtar (libarchive) for zip, tar*, 7z and rar: one parser both lists and extracts, and
        /// without -P it refuses `..`, absolute paths and writing through symlinks
        /// ("Cannot extract through symlink"). ditto, 7-Zip and unar don't all guarantee the latter.
        case libarchive
        case gunzip
    }

    static let tarTool = "/usr/bin/tar"
    static let gunzip = "/usr/bin/gunzip"

    static func backend(for format: ArchiveFormat) -> Backend? {
        switch format {
        case .gzip:
            return FileManager.default.isExecutableFile(atPath: gunzip) ? .gunzip : nil
        case .zip, .tar, .sevenZip, .rar:
            return FileManager.default.isExecutableFile(atPath: tarTool) ? .libarchive : nil
        }
    }

    /// Cheap check for the wheel: a known archive name whose extractor is available.
    public static func canExtract(_ url: URL) -> Bool {
        guard url.isFileURL, let format = ArchiveFormat(url: url) else { return false }
        return backend(for: format) != nil
    }

    /// True for a relative entry path that stays inside the extraction folder.
    public static func isSafeEntryPath(_ path: String) -> Bool {
        if path.hasPrefix("/") || path.hasPrefix("\\") { return false }
        let components = path.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        // bsdtar never expands `~`, so `~$Budget.xlsx` (an Office lock file) is just a name. Only a
        // top-level folder named exactly `~` is refused: it reads like the home folder in a shell.
        if components.first == "~" { return false }
        return !components.contains("..")
    }

    /// Extracts `archive` into a new folder named after it (`photos.zip` -> `photos/`, numbered if taken)
    /// in `directory` (default: the "Save to" folder or next to the archive). A single `.gz` file is
    /// decompressed to a file instead (`notes.txt.gz` -> `notes.txt`). Never overwrites anything.
    ///
    /// Safety: entry names are listed first and the archive is refused if any is absolute or contains
    /// `..`; extraction happens in a hidden staging folder that is checked for symlinks escaping it
    /// and is removed (read-only folders included) whenever the archive is refused.
    public static func extract(_ archive: URL, to directory: URL? = nil,
                               fileManager fm: FileManager = .default) async throws -> URL {
        guard let format = ArchiveFormat(url: archive) else {
            throw ArchiveError.unsupported(archive.lastPathComponent)
        }
        guard let backend = backend(for: format) else { throw ArchiveError.toolMissing(format) }
        let parent = directory ?? OutputNaming.preferredDirectory ?? archive.deletingLastPathComponent()
        let base = ArchiveFormat.baseName(of: archive)

        try await checkEntries(of: archive, backend: backend)

        let staging = parent.appendingPathComponent(".wheelie-extract-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let target: URL
        do {
            target = try await extractStaged(archive, format: format, backend: backend, base: base,
                                             staging: staging, parent: parent, fileManager: fm)
        } catch let failure {
            // Staging holds unchecked, unflagged content of a refused archive: it must not stay behind.
            do { try removeTree(staging, fileManager: fm) } catch {
                throw ArchiveError.cleanupFailed(folder: staging.lastPathComponent,
                                                 reason: failure.localizedDescription)
            }
            throw failure
        }
        // After the move only ignored, already checked and flagged items (.DS_Store) can remain.
        try? removeTree(staging, fileManager: fm)
        return target
    }

    /// bsdtar options that make it read zip entry names without the UTF-8 flag as CP437.
    static let oemZipNames = ["--options", "zip:hdrcharset=CP437"]

    private static func extractStaged(_ archive: URL, format: ArchiveFormat, backend: Backend, base: String,
                                      staging: URL, parent: URL, fileManager fm: FileManager) async throws -> URL {
        switch backend {
        case .libarchive:
            do {
                try await untar(archive, into: staging)
            } catch ToolError.failed(_, _, let stderr) where format == .zip && stderr.contains("Illegal byte sequence") {
                // Windows Explorer and 7-Zip store names in the OEM code page (CP437/CP850) without
                // the UTF-8 flag, and bsdtar can't create those raw bytes as names on APFS. Retry
                // reading them as CP437. Not on the first attempt: macOS zips store UTF-8 without
                // the flag too, and those would turn into mojibake.
                try removeTree(staging, fileManager: fm)
                try fm.createDirectory(at: staging, withIntermediateDirectories: true)
                try await checkEntries(of: archive, backend: backend, options: oemZipNames)
                do { try await untar(archive, into: staging, options: oemZipNames) }
                catch ToolError.failed(_, _, let stderr) { throw tarError(stderr) }
            } catch ToolError.failed(_, _, let stderr) {
                throw tarError(stderr)
            }
        case .gunzip:
            let file = staging.appendingPathComponent(base)
            do {
                try await runToFile(gunzip, ["-c", archive.path], output: file)
            } catch ToolError.failed(_, let status, let stderr) {
                // Status 2 is gzip's warning status: data after the gzip stream (block padding)
                // was ignored, and the output is complete.
                guard status == 2, isOnlyTrailingDataWarning(stderr) else {
                    throw ArchiveError.unreadable(brief(lastLines(stderr)))
                }
            }
            try propagateQuarantine(from: archive, to: file)
            let target = FileActions.uniqueURL(named: base, in: parent, fileManager: fm)
            try fm.moveItem(at: file, to: target)
            return target
        }

        try verifyContained(staging, fileManager: fm)
        try propagateQuarantine(from: archive, to: staging)

        // Finder zips carry an __MACOSX folder of AppleDouble files; it's not content.
        try? removeTree(staging.appendingPathComponent("__MACOSX"), fileManager: fm)
        let ignored: Set<String> = [".DS_Store"]
        let top = try fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: [.isSymbolicLinkKey])
            .filter { !ignored.contains($0.lastPathComponent) }
        guard !top.isEmpty else { throw ArchiveError.empty }

        // `Project.zip` holding just `Project/` becomes `Project/`, not `Project/Project/`.
        var source = staging
        if top.count == 1, top[0].lastPathComponent == base,
           (try? top[0].resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
           FileActions.isDirectory(top[0], fileManager: fm) {
            source = top[0]
            // A link may stay inside staging yet point to a sibling of the folder we keep.
            try verifyContained(source, fileManager: fm)
        }
        let target = FileActions.uniqueFolderURL(named: base, in: parent, fileManager: fm)
        try fm.moveItem(at: source, to: target)
        return target
    }

    /// Lists entries with the same parser that extracts them and refuses unsafe or empty archives.
    /// A listing failure refuses the archive.
    static func checkEntries(of archive: URL, backend: Backend, options: [String] = []) async throws {
        guard backend == .libarchive else { return }
        let listing = try await list(tarTool, ["-t"] + options + ["-f", archive.path])
        let entries = listing.split(whereSeparator: \.isNewline).filter { !$0.isEmpty }.map { unescapeListing(String($0)) }
        guard !entries.isEmpty else { throw ArchiveError.empty }
        if let bad = entries.first(where: { !isSafeEntryPath($0) }) { throw ArchiveError.unsafeEntry(bad) }
    }

    /// `tar -t` escapes what it can't print in the current locale (in the C locale a GUI app usually
    /// gets, every non-ASCII byte): `\\`, C escapes such as `\n`, and `\ooo` octal bytes. Without
    /// decoding, `Übersicht.txt` would be checked as `\303\234bersicht.txt` and refused as starting
    /// with a backslash. Bytes that aren't UTF-8 (e.g. CP437 names) become U+FFFD.
    static func unescapeListing(_ line: String) -> String {
        let simple: [UInt8: UInt8] = [UInt8(ascii: "\\"): UInt8(ascii: "\\"), UInt8(ascii: "a"): 7, UInt8(ascii: "b"): 8,
                                      UInt8(ascii: "f"): 12, UInt8(ascii: "n"): 10, UInt8(ascii: "r"): 13,
                                      UInt8(ascii: "t"): 9, UInt8(ascii: "v"): 11]
        func octal(_ byte: UInt8) -> UInt8? {
            (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(byte) ? byte - UInt8(ascii: "0") : nil
        }
        let input = Array(line.utf8)
        var bytes: [UInt8] = []
        var index = 0
        while index < input.count {
            let byte = input[index]
            if byte == UInt8(ascii: "\\"), index + 1 < input.count {
                if let value = simple[input[index + 1]] {
                    bytes.append(value); index += 2; continue
                }
                if index + 3 < input.count, let a = octal(input[index + 1]), a <= 3,
                   let b = octal(input[index + 2]), let c = octal(input[index + 3]) {
                    bytes.append(a << 6 | b << 3 | c); index += 4; continue
                }
            }
            bytes.append(byte)
            index += 1
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func list(_ tool: String, _ args: [String]) async throws -> String {
        do {
            return try await Tools.capture(tool, args).stdout
        } catch ToolError.failed(_, _, let stderr) {
            if isEncryptionError(stderr) { throw ArchiveError.encrypted }
            if stderr.localizedCaseInsensitiveContains("empty") { throw ArchiveError.empty }
            throw ArchiveError.unreadable(brief(lastLines(stderr)))
        }
    }

    /// `tar -x` into `staging`. No xattrs/mac metadata from the archive: it must not set (or clear)
    /// its own quarantine. stdin is /dev/null, so an encrypted entry fails instead of prompting.
    private static func untar(_ archive: URL, into staging: URL, options: [String] = []) async throws {
        try await Tools.run(tarTool, ["-x", "--no-same-owner", "--no-xattrs", "--no-mac-metadata"] + options
                                     + ["-f", archive.path, "-C", staging.path])
    }

    static func tarError(_ stderr: String) -> ArchiveError {
        if isEncryptionError(stderr) { return .encrypted }
        if stderr.contains("through symlink") { return .linkEscapes(brief(firstLine(stderr))) }
        return .unreadable(brief(lastLines(stderr)))
    }

    /// libarchive's messages for encrypted zip/7z/rar entries. Without a tty bsdtar asks for a
    /// passphrase thousands of times ("Enter passphrase:…Too many incorrect passphrases").
    static func isEncryptionError(_ stderr: String) -> Bool {
        let markers = ["passphrase", "encryption is not supported", "encrypted file is unsupported",
                       "is encrypted, but currently not supported", "unsupported encryption",
                       "encryption support unavailable"]
        return markers.contains { stderr.localizedCaseInsensitiveContains($0) }
    }

    /// gzip only warns (status 2) about bytes after the compressed stream, e.g. block padding.
    static func isOnlyTrailingDataWarning(_ stderr: String) -> Bool {
        let lines = stderr.split(whereSeparator: \.isNewline)
        return !lines.isEmpty && lines.allSatisfy {
            $0.hasSuffix("trailing garbage ignored") || $0.hasSuffix("trailing zero bytes ignored")
        }
    }

    /// Tool output for an error message: at most `limit` characters, keeping the end (the actual error).
    static func brief(_ text: String, limit: Int = 300) -> String {
        guard text.count > limit else { return text }
        return "…" + text.suffix(limit - 1)
    }

    static let quarantineName = "com.apple.quarantine"

    /// Like Archive Utility and ditto: everything extracted from a downloaded (quarantined)
    /// archive gets the archive's quarantine flag, so Gatekeeper still checks apps inside it.
    /// Fails closed: read-only items and unreadable folders are opened up just long enough to
    /// flag (then their modes are restored); anything that still can't be flagged throws.
    /// Symlinks are skipped — what they point to inside the tree is flagged itself.
    static func propagateQuarantine(from archive: URL, to root: URL) throws {
        let size = getxattr(archive.path, quarantineName, nil, 0, 0, 0)
        guard size > 0 else { return }
        var value = [UInt8](repeating: 0, count: size)
        guard getxattr(archive.path, quarantineName, &value, size, 0, 0) == size else {
            throw ArchiveError.quarantineFailed(archive.lastPathComponent)
        }
        try flag(root.path, value: value, relativeTo: root.path)
    }

    private static func flag(_ path: String, value: [UInt8], relativeTo root: String) throws {
        var info = stat()
        guard lstat(path, &info) == 0 else { throw ArchiveError.quarantineFailed(display(path, root)) }
        let type = info.st_mode & S_IFMT
        if type == S_IFLNK { return }
        let isDirectory = type == S_IFDIR
        let originalMode = info.st_mode & 0o7777
        // Owner needs write to set an xattr, and read+execute to list a folder.
        let needed: mode_t = isDirectory ? 0o700 : 0o200
        let opened = originalMode & needed != needed
        if opened, chmod(path, originalMode | needed) != 0 { throw ArchiveError.quarantineFailed(display(path, root)) }
        defer { if opened { _ = chmod(path, originalMode) } }

        if isDirectory {
            let children: [String]
            do { children = try FileManager.default.contentsOfDirectory(atPath: path) }
            catch { throw ArchiveError.quarantineFailed(display(path, root)) }
            for child in children {
                try flag((path as NSString).appendingPathComponent(child), value: value, relativeTo: root)
            }
        }
        if setxattr(path, quarantineName, value, value.count, 0, XATTR_NOFOLLOW) != 0 {
            throw ArchiveError.quarantineFailed(display(path, root))
        }
    }

    private static func display(_ path: String, _ root: String) -> String {
        guard path.hasPrefix(root + "/") else { return (path as NSString).lastPathComponent }
        return String(path.dropFirst(root.count + 1))
    }

    private static func lastLines(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).suffix(2).joined(separator: " ")
    }

    private static func firstLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
    }

    /// Throws if any symlink inside `root` points (or resolves) outside it. Fails closed: dangling
    /// links are followed as far as they exist and may only continue with plain names (no `..`), link
    /// loops are refused, and folders the owner can't list are opened for the check (their modes are
    /// restored afterwards) so no link can hide in one.
    static func verifyContained(_ root: URL, fileManager fm: FileManager = .default) throws {
        let rootPath = root.standardizedFileURL.path
        guard let realRoot = realPath(rootPath) else { throw ArchiveError.unreadable("Its folder couldn't be checked.") }
        var opened: [(path: String, mode: mode_t)] = []
        defer { restoreModes(opened) }
        var links: [String] = []
        try scan(realRoot, relative: "", needed: 0o500, opened: &opened, links: &links, fileManager: fm)
        for relative in links {
            guard let destination = readLink(realRoot + "/" + relative) else { throw ArchiveError.linkEscapes(relative) }
            // Lexically: the link's own folder plus its target must not climb above the root.
            var depth = relative.split(separator: "/").count - 1
            var escapes = destination.hasPrefix("/")
            for part in destination.split(separator: "/") where !escapes {
                if part == ".." { depth -= 1; escapes = depth < 0 }
                else if part != "." { depth += 1 }
            }
            // Physically: following every link in the chain, step by step, must stay inside too.
            if escapes || !resolvesInside(relative, root: realRoot) { throw ArchiveError.linkEscapes(relative) }
        }
    }

    /// Follows `relative` (inside the real path `root`) one component at a time, expanding every
    /// symlink before a later `..` is applied, as the kernel does. False if any step leaves `root`
    /// (even to come back in by name: that breaks once the folder is moved or renamed), on an
    /// absolute link, or on a link loop. A component that doesn't exist yet ends the physical walk:
    /// only plain names may follow it. A `..` after it is refused (fail closed), because a lexical
    /// pop there can't be checked: later names aren't followed through links (`y -> .`), and the
    /// missing name may exist by the time the link is used, so `nope/../y/..` could leave `root`.
    static func resolvesInside(_ relative: String, root: String) -> Bool {
        var resolved: [String] = []
        var pending = Array(relative.split(separator: "/").map(String.init).reversed())
        var hops = 0
        var missing = false
        while let part = pending.popLast() {
            if part.isEmpty || part == "." { continue }
            if part == ".." {
                if missing || resolved.isEmpty { return false }
                resolved.removeLast()
                continue
            }
            resolved.append(part)
            if missing { continue }
            let path = root + "/" + resolved.joined(separator: "/")
            var info = stat()
            guard lstat(path, &info) == 0 else {
                if errno == ENOENT || errno == ENOTDIR { missing = true; continue }
                return false
            }
            guard info.st_mode & S_IFMT == S_IFLNK else { continue }
            hops += 1
            guard hops <= 32, let target = readLink(path), !target.hasPrefix("/") else { return false }
            resolved.removeLast()
            pending.append(contentsOf: target.split(separator: "/").map(String.init).reversed())
        }
        return true
    }

    /// Collects every symlink under `path` (as paths relative to the walk's start) and gives the
    /// owner at least `needed` on every folder, recording changed modes in `opened`.
    private static func scan(_ path: String, relative: String, needed: mode_t,
                             opened: inout [(path: String, mode: mode_t)], links: inout [String],
                             fileManager fm: FileManager) throws {
        let shown = relative.isEmpty ? "." : relative
        var info = stat()
        guard lstat(path, &info) == 0 else { throw ArchiveError.unreadable("“\(shown)” couldn't be checked.") }
        switch info.st_mode & S_IFMT {
        case S_IFLNK:
            links.append(relative)
        case S_IFDIR:
            let mode = info.st_mode & 0o7777
            if mode & needed != needed {
                guard chmod(path, mode | needed) == 0 else { throw ArchiveError.unreadable("“\(shown)” couldn't be checked.") }
                opened.append((path, mode))
            }
            let children: [String]
            do { children = try fm.contentsOfDirectory(atPath: path) }
            catch { throw ArchiveError.unreadable("“\(shown)” couldn't be checked.") }
            for child in children {
                try scan(path + "/" + child, relative: relative.isEmpty ? child : relative + "/" + child,
                         needed: needed, opened: &opened, links: &links, fileManager: fm)
            }
        default:
            break
        }
    }

    private static func restoreModes(_ opened: [(path: String, mode: mode_t)]) {
        for item in opened.reversed() { _ = chmod(item.path, item.mode) }
    }

    /// Removes a tree an archive filled. Its folders may be read-only or unlistable (modes come from
    /// the archive), which would make a plain removal fail, so the owner gets rwx on each first.
    static func removeTree(_ url: URL, fileManager fm: FileManager = .default) throws {
        var info = stat()
        if lstat(url.path, &info) != 0, errno == ENOENT { return }
        var opened: [(path: String, mode: mode_t)] = []
        var links: [String] = []
        try? scan(url.path, relative: "", needed: 0o700, opened: &opened, links: &links, fileManager: fm)
        try fm.removeItem(at: url)
    }

    /// The link's target, or nil if it can't be read or isn't valid UTF-8 (a lossy decode could
    /// name a different file than the kernel follows, so callers treat nil as escaping).
    private static func readLink(_ path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let count = readlink(path, &buffer, buffer.count - 1)
        guard count >= 0 else { return nil }
        return String(bytes: buffer[..<count].map { UInt8(bitPattern: $0) }, encoding: .utf8)
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Runs a tool with stdout written to `output` (for binary output such as `gunzip -c`).
    static func runToFile(_ tool: String, _ arguments: [String], output: URL) async throws {
        guard FileManager.default.createFile(atPath: output.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: output.path])
        }
        let handle = try FileHandle(forWritingTo: output)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = handle
            let errPipe = Pipe()
            process.standardError = errPipe
            let errData = LockedData()
            errPipe.fileHandleForReading.readabilityHandler = { errData.append($0.availableData) }
            process.terminationHandler = { p in
                errPipe.fileHandleForReading.readabilityHandler = nil
                errData.append(errPipe.fileHandleForReading.readDataToEndOfFile())
                try? handle.close()
                if p.terminationStatus == 0 {
                    cont.resume()
                } else {
                    cont.resume(throwing: ToolError.failed(tool: (tool as NSString).lastPathComponent,
                                                           status: p.terminationStatus,
                                                           stderr: String(decoding: errData.value, as: UTF8.self)))
                }
            }
            do { try process.run() } catch {
                try? handle.close()
                cont.resume(throwing: error)
            }
        }
    }
}
