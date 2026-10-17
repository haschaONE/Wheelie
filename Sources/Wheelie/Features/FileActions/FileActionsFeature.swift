import AppKit
import WheelieCore

/// File actions on the outer ring: copy paths, copy files, move, Terminal, AirDrop,
/// extract archives and read QR codes.
enum FileActionsFeature: WheelieFeature {
    static func wheelItems() -> [WheelItem] {
        [
            WheelItem(id: "fileactions.copyPath", label: "Copy Path", symbol: "link", order: 100,
                      accepts: allLocal, perform: copyPaths),
            WheelItem(id: "fileactions.copyFiles", label: "Copy", symbol: "doc.on.doc", order: 101,
                      accepts: allLocal, perform: copyFiles),
            WheelItem(id: "fileactions.move", label: "Move To…", symbol: "folder", order: 102,
                      accepts: allLocal, perform: move),
            WheelItem(id: "fileactions.airdrop", label: "AirDrop", symbol: "airplayaudio", order: 103,
                      accepts: allLocal, perform: { files in try AirDropShare.share(files); return .none }),
            WheelItem(id: "fileactions.terminal", label: "Terminal", symbol: "terminal", order: 104,
                      accepts: allLocal, perform: openTerminal),
            WheelItem(id: "fileactions.extract", label: "Extract", symbol: "archivebox", order: 105,
                      accepts: { !$0.isEmpty && $0.allSatisfy(ArchiveExtractor.canExtract) },
                      perform: extract),
            WheelItem(id: "fileactions.qr", label: "QR Code", symbol: "qrcode.viewfinder", order: 106,
                      accepts: { $0.allSatisfy(\.isFileURL) && $0.allAre(.image, .pdf) },
                      perform: { files in await QRCodeResultsWindow.show(files); return .none }),
        ]
    }

    private static func allLocal(_ files: [URL]) -> Bool {
        !files.isEmpty && files.allSatisfy(\.isFileURL)
    }

    // MARK: Clipboard

    static func copyPaths(_ files: [URL]) throws -> WheelOutcome {
        guard allLocal(files) else { throw FileActionError.notLocal(verb: "have their paths copied") }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(FileActions.pathList(files), forType: .string) else {
            throw FileActionError.clipboardFailed("paths")
        }
        return .message(files.count == 1 ? "Copied path" : "Copied \(files.count) paths")
    }

    /// Writes file URLs so ⌘V in Finder pastes copies of the items.
    static func copyFiles(_ files: [URL]) throws -> WheelOutcome {
        guard allLocal(files) else { throw FileActionError.notLocal(verb: "be copied") }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.writeObjects(files.map { $0 as NSURL }) else {
            throw FileActionError.clipboardFailed("files")
        }
        return .message("Copied \(FileActions.countPhrase(files))")
    }

    // MARK: Move

    static func move(_ files: [URL]) async throws -> WheelOutcome {
        guard allLocal(files) else { throw FileActionError.notLocal(verb: "be moved") }
        guard let destination = await chooseDestination(for: files) else { return .none }
        let moved = try await Task.detached(priority: .userInitiated) {
            try FileActions.move(files, to: destination)
        }.value
        return .outputs(moved)
    }

    private static func chooseDestination(for files: [URL]) async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Move Here"
        let what = files.count == 1 ? "“\(files[0].lastPathComponent)”" : FileActions.countPhrase(files)
        panel.message = "Choose a destination folder for \(what)."
        panel.directoryURL = files.first?.deletingLastPathComponent()
        let delegate = MoveDestinationValidator(items: files)
        panel.delegate = delegate
        NSApp.activate(ignoringOtherApps: true)
        let response = await withCheckedContinuation { cont in
            panel.begin { cont.resume(returning: $0) }
        }
        return withExtendedLifetime(delegate) { response == .OK ? panel.url : nil }
    }

    /// Keeps the "Move To…" panel open with an explanation instead of failing after it closes:
    /// moved folders are greyed out, and a destination inside one (or where everything already is)
    /// is refused in place.
    private final class MoveDestinationValidator: NSObject, NSOpenSavePanelDelegate {
        let items: [URL]
        private let movedFolders: Set<String>

        init(items: [URL]) {
            self.items = items
            movedFolders = Set(items.map { $0.standardizedFileURL.path })
        }

        func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
            !movedFolders.contains(url.standardizedFileURL.path)
        }

        func panel(_ sender: Any, validate url: URL) throws {
            try FileActions.validateMove(items, to: url)
            if FileActions.itemsNeedingMove(items, to: url).isEmpty {
                throw FileActionError.alreadyInDestination(url.lastPathComponent)
            }
        }
    }

    // MARK: Terminal

    static func openTerminal(_ files: [URL]) async throws -> WheelOutcome {
        guard allLocal(files) else { throw FileActionError.notLocal(verb: "open a terminal") }
        let stored = UserDefaults.standard.string(forKey: SettingsKey.terminalApp) ?? ""
        let bundleID = stored.isEmpty ? TerminalApps.defaultBundleID : stored
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            throw FileActionError.appMissing(TerminalApps.name(for: bundleID))
        }
        let folders = FileActions.terminalFolders(for: files)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.open(folders, withApplicationAt: appURL, configuration: configuration)
        return .message("Opened in \(appName(appURL))")
    }

    private static func appName(_ appURL: URL) -> String {
        let bundle = Bundle(url: appURL)
        return bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? appURL.deletingPathExtension().lastPathComponent
    }

    // MARK: Extract

    struct ExtractError: LocalizedError {
        let failed: Int, total: Int, first: String
        var errorDescription: String? { total == 1 ? first : "\(failed) of \(total) archives failed: \(first)" }
    }

    /// Extracts each archive into its own new folder; throws if any failed (the others stay extracted).
    static func extract(_ files: [URL]) async throws -> WheelOutcome {
        var outputs: [URL] = []
        var errors: [String] = []
        for archive in files {
            do { outputs.append(try await ArchiveExtractor.extract(archive)) }
            catch { errors.append(files.count == 1 ? error.localizedDescription
                                                   : "\(archive.lastPathComponent): \(error.localizedDescription)") }
        }
        if let first = errors.first { throw ExtractError(failed: errors.count, total: files.count, first: first) }
        return .outputs(outputs)
    }
}
