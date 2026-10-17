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

    public var errorDescription: String? {
        switch self {
        case .unsupported(let name):
            return "“\(name)” isn't an archive Wheelie can extract."
        case .toolMissing(.rar):
            return "Extracting RAR archives needs unar or 7-Zip. Install one with: brew install unar"
        case .toolMissing:
            return "Extracting 7z archives needs 7-Zip or unar. Install one with: brew install sevenzip"
        case .unsafeEntry(let path):
            return "The archive contains an unsafe path (“\(path)”), so it wasn't extracted."
        case .linkEscapes(let path):
            return "The archive contains a link that points outside its folder (“\(path)”), so it wasn't extracted."
        case .empty:
            return "The archive is empty."
        case .unreadable(let detail):
            return "The archive couldn't be read. \(detail)"
        }
    }
}

public enum ArchiveExtractor {
    enum Backend: Equatable {
        case ditto, tar, gunzip
        case sevenZip(URL)
        case unar(URL)
    }

    static let ditto = "/usr/bin/ditto"
    static let tarTool = "/usr/bin/tar"
    static let gunzip = "/usr/bin/gunzip"
    static let zipinfo = "/usr/bin/zipinfo"

    static func backend(for format: ArchiveFormat) -> Backend? {
        func sevenZip() -> Backend? { (Tools.locate("7zz") ?? Tools.locate("7z")).map(Backend.sevenZip) }
        func unar() -> Backend? { Tools.locate("unar").map(Backend.unar) }
        switch format {
        case .zip: return .ditto
        case .tar: return .tar
        case .gzip: return .gunzip
        case .sevenZip: return sevenZip() ?? unar()
        case .rar: return unar() ?? sevenZip()
        }
    }

    /// Cheap check for the wheel: a known archive name whose extractor is available.
    public static func canExtract(_ url: URL) -> Bool {
        guard url.isFileURL, let format = ArchiveFormat(url: url) else { return false }
        return backend(for: format) != nil
    }

    /// True for a relative entry path that stays inside the extraction folder.
    public static func isSafeEntryPath(_ path: String) -> Bool {
        if path.hasPrefix("/") || path.hasPrefix("\\") || path.hasPrefix("~") { return false }
        let components = path.split(whereSeparator: { $0 == "/" || $0 == "\\" })
        return !components.contains("..")
    }

    /// Extracts `archive` into a new folder named after it (`photos.zip` -> `photos/`, numbered if taken)
    /// in `directory` (default: the "Save to" folder or next to the archive). A single `.gz` file is
    /// decompressed to a file instead (`notes.txt.gz` -> `notes.txt`). Never overwrites anything.
    ///
    /// Safety: entry names are listed first and the archive is refused if any is absolute or contains
    /// `..`; extraction happens in a hidden staging folder that is checked for symlinks escaping it.
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
        defer { try? fm.removeItem(at: staging) }

        switch backend {
        case .ditto:
            try await Tools.run(ditto, ["-x", "-k", archive.path, staging.path])
        case .tar:
            // bsdtar also refuses `..`, absolute paths and writing through symlinks by default.
            try await Tools.run(tarTool, ["-x", "-f", archive.path, "-C", staging.path])
        case .gunzip:
            let file = staging.appendingPathComponent(base)
            try await runToFile(gunzip, ["-c", archive.path], output: file)
            let target = FileActions.uniqueURL(named: base, in: parent, fileManager: fm)
            try fm.moveItem(at: file, to: target)
            return target
        case .sevenZip(let tool):
            try await Tools.run(tool.path, ["x", "-y", "-o" + staging.path, archive.path])
        case .unar(let tool):
            try await Tools.run(tool.path, ["-q", "-D", "-o", staging.path, archive.path])
        }

        try verifyContained(staging, fileManager: fm)

        let ignored: Set<String> = [".DS_Store", "__MACOSX"]
        let top = try fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: [.isSymbolicLinkKey])
            .filter { !ignored.contains($0.lastPathComponent) }
        guard !top.isEmpty else { throw ArchiveError.empty }

        // `Project.zip` holding just `Project/` becomes `Project/`, not `Project/Project/`.
        var source = staging
        if top.count == 1, top[0].lastPathComponent == base,
           (try? top[0].resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
           FileActions.isDirectory(top[0], fileManager: fm) {
            source = top[0]
        }
        let target = FileActions.uniqueFolderURL(named: base, in: parent, fileManager: fm)
        try fm.moveItem(at: source, to: target)
        return target
    }

    /// Lists entry names where a system tool can, and refuses unsafe or empty archives.
    /// 7z/rar extractors sanitise paths themselves; those are checked after extraction only.
    static func checkEntries(of archive: URL, backend: Backend) async throws {
        let listing: String
        switch backend {
        case .ditto:
            guard FileManager.default.isExecutableFile(atPath: zipinfo) else { return }
            listing = try await list(zipinfo, ["-1", archive.path])
        case .tar:
            listing = try await list(tarTool, ["-t", "-f", archive.path])
        case .gunzip, .sevenZip, .unar:
            return
        }
        let entries = listing.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
        guard !entries.isEmpty else { throw ArchiveError.empty }
        if let bad = entries.first(where: { !isSafeEntryPath($0) }) { throw ArchiveError.unsafeEntry(bad) }
    }

    private static func list(_ tool: String, _ args: [String]) async throws -> String {
        do {
            return try await Tools.capture(tool, args).stdout
        } catch ToolError.failed(_, _, let stderr) {
            if stderr.localizedCaseInsensitiveContains("empty") { throw ArchiveError.empty }
            let tail = stderr.split(whereSeparator: \.isNewline).suffix(2).joined(separator: " ")
            throw ArchiveError.unreadable(tail)
        }
    }

    /// Throws if any symlink inside `root` points (or resolves) outside it.
    static func verifyContained(_ root: URL, fileManager fm: FileManager = .default) throws {
        let rootPath = root.standardizedFileURL.path
        let realRoot = realPath(rootPath) ?? rootPath
        // The path-based enumerator yields relative paths and doesn't descend into symlinked folders.
        guard let walker = fm.enumerator(atPath: rootPath) else { return }
        while let relative = walker.nextObject() as? String {
            guard walker.fileAttributes?[.type] as? FileAttributeType == .typeSymbolicLink else { continue }
            let path = (rootPath as NSString).appendingPathComponent(relative)
            guard let destination = try? fm.destinationOfSymbolicLink(atPath: path) else { continue }
            // Lexically: the link's own folder plus its target must not climb above the root.
            var depth = relative.split(separator: "/").count - 1
            var escapes = destination.hasPrefix("/")
            for part in destination.split(separator: "/") where !escapes {
                if part == ".." { depth -= 1; escapes = depth < 0 }
                else if part != "." { depth += 1 }
            }
            // Physically: following every link in the chain must stay inside too.
            if !escapes, let real = realPath(path) {
                escapes = real != realRoot && !real.hasPrefix(realRoot + "/")
            }
            if escapes { throw ArchiveError.linkEscapes(relative) }
        }
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
