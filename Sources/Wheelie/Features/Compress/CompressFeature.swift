import AppKit
import UniformTypeIdentifiers
import WheelieCore

/// Compress (images, video, audio, PDF) and Remove Metadata. Both open a small window:
/// "Compression Settings" and the metadata viewer with its "Remove Metadata" button.
enum CompressFeature: WheelieFeature {
    static func wheelItems() -> [WheelItem] {
        [
            WheelItem(id: "compress.compress", label: "Compress", symbol: "arrow.down.right.and.arrow.up.left",
                      ring: .outer, order: 20,
                      accepts: accepts,
                      perform: { files in
                          CompressionWindow.present(files)
                          return .none
                      }),
            WheelItem(id: "compress.metadata", label: "Metadata", symbol: "tag.slash",
                      ring: .outer, order: 21,
                      accepts: accepts,
                      perform: { files in
                          MetadataWindow.present(files)
                          return .none
                      }),
        ]
    }

    static func menuItems() -> [NSMenuItem] {
        [
            ClosureMenuItem("Compress Files…") { chooseFiles("Choose files to compress") { CompressionWindow.present($0) } },
            ClosureMenuItem("Remove Metadata…") { chooseFiles("Choose files to inspect or clean") { MetadataWindow.present($0) } },
        ]
    }

    /// Images, video, audio and PDFs, mixed freely. SVG is vector text, not something to recompress.
    static func accepts(_ files: [URL]) -> Bool {
        files.allAre(.image, .video, .audio, .pdf) && !files.contains { $0.pathExtension.lowercased() == "svg" }
    }

    @MainActor
    private static func chooseFiles(_ message: String, then open: ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = CompressInputs.contentTypes
        panel.message = message
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        let files = panel.urls.filter { accepts([$0]) }
        if !files.isEmpty { open(files) }
    }

    /// One window per tool and file set, so dropping the same files again focuses it.
    static func windowID(_ tool: String, _ files: [URL]) -> String {
        "compress.\(tool):" + files.map(\.path).joined(separator: "|")
    }
}

/// Ties a window's job to that one window. Closing the window (Cancel, Esc, ⌘W, the close button)
/// cancels the job, which also stops its ffmpeg/cwebp process. The job's own auto-close only ever
/// closes the window it ran in: window ids repeat when the same files are opened again.
@MainActor
final class WindowJob {
    private weak var window: NSWindow?
    private var observer: NSObjectProtocol?
    private var task: Task<Void, Never>?

    /// Call with the window the view was presented in (only when it was newly created).
    func attach(to window: NSWindow) {
        self.window = window
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.windowWillClose() }
        }
    }

    /// Runs `work` as this window's job; ignored while one is already running.
    func start(_ work: @escaping @MainActor () async -> Void) {
        guard task == nil else { return }
        task = Task { [weak self] in
            await work()
            self?.task = nil
        }
    }

    func cancel() { task?.cancel() }

    /// Closes the window this job belongs to, never another one that reuses its id.
    func closeOwnWindow() { window?.close() }

    private func windowWillClose() {
        cancel()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }
}

/// UserDefaults keys for the remembered compression choices.
enum CompressKey {
    static let mode = "compress.mode"                    // CompressionMode.rawValue
    static let imageStrength = "compress.image.strength" // CompressionStrength.rawValue
    static let videoStrength = "compress.video.strength" // CompressionStrength.rawValue (video and audio)
    static let imageSize = "compress.image.size"         // ImageSizeLimit.rawValue
    static let targetBytes = "compress.targetBytes"      // Int
    static let targetUnit = "compress.targetUnit"        // "KB" | "MB"
    static let targetPercent = "compress.targetPercent"  // Int 1...99
}
