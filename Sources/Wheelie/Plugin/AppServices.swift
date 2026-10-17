import AppKit
import SwiftUI
import WheelieCore

extension Notification.Name {
    /// userInfo["urls"]: [URL] — files a job just wrote.
    static let wheelieOutputsProduced = Notification.Name("wheelie.outputsProduced")
    /// userInfo["id"]: UUID, ["title"]: String, ["sources"]: [URL]
    static let wheelieJobStarted = Notification.Name("wheelie.jobStarted")
    /// userInfo["id"]: UUID, ["error"]: String? (nil on success)
    static let wheelieJobFinished = Notification.Name("wheelie.jobFinished")
    /// object: String? — id of the wheel item under the cursor (nil when none).
    static let wheelieHighlightChanged = Notification.Name("wheelie.highlightChanged")
}

/// UserDefaults keys. The Settings window (ShellFeature) edits these; everyone reads them.
enum SettingsKey {
    static let wheelEnabled = "wheelOnDrag"             // Bool, default true
    static let triggerModifier = "triggerModifier"      // "shift" | "control" | "option" | "command", default "shift"
    static let outputLocation = "outputLocation"        // "original" | "downloads" | "custom", default "original"
    static let customOutputFolder = "customOutputFolder" // String path, used when outputLocation == "custom"
    static let playSounds = "playSounds"                // Bool, default true
    static let addResultsToFloat = "addResultsToFloat"  // Bool, default false
    static let revealResults = "revealResults"          // Bool, default false
    static let terminalApp = "terminalApp"              // bundle id, default "com.apple.Terminal"
}

struct HistoryRecord: Identifiable {
    let id = UUID()
    let title: String
    let sources: [URL]
    var outputs: [URL] = []
    var error: String?
    let date = Date()
}

/// Shared services for features: running jobs, history, windows, settings.
@MainActor
final class AppServices: ObservableObject {
    static let shared = AppServices()

    @Published private(set) var history: [HistoryRecord] = []
    @Published private(set) var activeJobs = 0

    private var windows: [String: NSWindow] = [:]
    private var windowDelegates: [String: WindowCloseDelegate] = [:]

    private init() {}

    // MARK: Jobs

    /// Runs work with history, notifications and the busy indicator.
    /// The wheel uses this for every item; editors call it from their Export button.
    @discardableResult
    func run(_ title: String, sources: [URL],
             _ work: @escaping @MainActor () async throws -> WheelOutcome) async -> Result<WheelOutcome, Error> {
        let id = UUID()
        activeJobs += 1
        NotificationCenter.default.post(name: .wheelieJobStarted, object: nil,
                                        userInfo: ["id": id, "title": title, "sources": sources])
        defer { activeJobs -= 1 }
        do {
            let outcome = try await work()
            if case .outputs(let urls) = outcome {
                record(HistoryRecord(title: title, sources: sources, outputs: urls))
                announce(urls)
            }
            NotificationCenter.default.post(name: .wheelieJobFinished, object: nil, userInfo: ["id": id])
            return .success(outcome)
        } catch {
            record(HistoryRecord(title: title, sources: sources, error: error.localizedDescription))
            NotificationCenter.default.post(name: .wheelieJobFinished, object: nil,
                                            userInfo: ["id": id, "error": error.localizedDescription])
            return .failure(error)
        }
    }

    private func record(_ record: HistoryRecord) {
        history.insert(record, at: 0)
        history = Array(history.prefix(15))
    }

    private func announce(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NotificationCenter.default.post(name: .wheelieOutputsProduced, object: nil, userInfo: ["urls": urls])
        if UserDefaults.standard.bool(forKey: SettingsKey.revealResults) {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    // MARK: Windows

    /// Shows (or re-focuses) a standard window. Editors use one window per tool + file set.
    func presentWindow<V: View>(id: String, title: String, size: CGSize, resizable: Bool = true,
                                @ViewBuilder content: () -> V) {
        if let existing = windows[id] {
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            return
        }
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        if resizable { style.insert(.resizable) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style,
                              backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content())
        window.setContentSize(size)
        window.center()
        let delegate = WindowCloseDelegate { [weak self] in
            self?.windows[id] = nil
            self?.windowDelegates[id] = nil
        }
        window.delegate = delegate
        windows[id] = window
        windowDelegates[id] = delegate
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func closeWindow(id: String) {
        windows[id]?.close()
    }

    func window(id: String) -> NSWindow? { windows[id] }

    // MARK: Settings

    /// Re-reads settings that affect core behaviour. Call after changing them.
    func applySettings() {
        let defaults = UserDefaults.standard
        switch defaults.string(forKey: SettingsKey.outputLocation) ?? "original" {
        case "downloads":
            OutputNaming.preferredDirectory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        case "custom":
            OutputNaming.preferredDirectory = defaults.string(forKey: SettingsKey.customOutputFolder).map { URL(fileURLWithPath: $0) }
        default:
            OutputNaming.preferredDirectory = nil
        }
    }

    func bool(_ key: String, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? value
    }
}

private final class WindowCloseDelegate: NSObject, NSWindowDelegate {
    let onClose: () -> Void
    init(onClose: @escaping () -> Void) { self.onClose = onClose }
    func windowWillClose(_ notification: Notification) { onClose() }
}
