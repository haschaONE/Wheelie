import AppKit
import SwiftUI
import WheelieCore

/// Runs an editor's export through `AppServices.run` with progress, cancel and inline errors.
@MainActor
final class VideoToolsExporter: ObservableObject {
    @Published private(set) var isExporting = false
    /// 0...1 while exporting.
    @Published private(set) var progress: Double = 0
    @Published var error: String?
    private var task: Task<Void, Never>?

    static let stoppedMessage = "Export stopped."

    /// `work` gets a progress callback (any thread) and returns the files it wrote.
    /// The window closes when the export succeeds.
    func start(windowID: String, title: String, sources: [URL],
               work: @escaping @MainActor (_ progress: @escaping VideoToolRunner.Progress) async throws -> [URL]) {
        guard !isExporting else { return }
        isExporting = true
        progress = 0
        error = nil
        task = Task { [weak self] in
            let report: VideoToolRunner.Progress = { value in
                Task { @MainActor in
                    guard let self, self.isExporting else { return }
                    self.progress = max(self.progress, value)
                }
            }
            let result = await AppServices.shared.run(title, sources: sources) {
                do {
                    return .outputs(try await work(report))
                } catch is CancellationError {
                    throw VideoToolError(VideoToolsExporter.stoppedMessage)
                }
            }
            guard let self else { return }
            self.isExporting = false
            self.task = nil
            switch result {
            case .success:
                AppServices.shared.closeWindow(id: windowID)
            case .failure(let error):
                self.error = error.localizedDescription
            }
        }
    }

    func cancel() { task?.cancel() }
}

/// Keys the editors react to (only when no text field is being edited, except export/close).
enum VideoToolsKey: Equatable {
    case playPause, stepBack, stepForward, jumpBack, jumpForward, delete, export, close
    case character(Character)
}

/// Common editor window layout: content, tool controls, and a footer with the
/// status line, Cancel and the primary Export button. Handles the keyboard.
struct VideoToolsShell<Content: View, Controls: View>: View {
    let windowID: String
    @ObservedObject var exporter: VideoToolsExporter
    let player: VideoToolsPlayer?
    let exportLabel: String
    /// Why export isn't possible yet (shown in the footer; disables the button).
    var blocker: String?
    /// Neutral hint shown when there is no blocker or error.
    var hint: String?
    let onExport: () -> Void
    /// Editor-specific keys; return true when handled.
    var onKey: (VideoToolsKey) -> Bool = { _ in false }
    /// Extra cleanup when the window closes (the shell already tears down `player`).
    var onClose: (() -> Void)?
    @ViewBuilder let content: () -> Content
    @ViewBuilder let controls: () -> Controls

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
            controls()
            Divider()
            footer
        }
        .padding(16)
        .background(VideoToolsKeyCatcher(handler: handle, onClose: {
            exporter.cancel()
            player?.tearDown()
            onClose?()
        }))
        .task { await player?.load() }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            status
            Spacer(minLength: 8)
            if exporter.isExporting {
                Button("Stop") { exporter.cancel() }
                    .help("Stop the export")
            } else {
                Button("Cancel") { AppServices.shared.closeWindow(id: windowID) }
                    .help("Close without exporting (Esc)")
            }
            Button(action: export) {
                if exporter.isExporting {
                    HStack(spacing: 6) {
                        ProgressView(value: exporter.progress)
                            .progressViewStyle(.linear)
                            .frame(width: 70)
                        Text("\(Int((exporter.progress * 100).rounded()))%")
                            .monospacedDigit()
                    }
                } else {
                    Text(exportLabel)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(blocker != nil || exporter.isExporting || player.map { $0.state != .ready } ?? false)
            .help("\(exportLabel) (⌘↩)")
            .accessibilityLabel(exporter.isExporting ? "Exporting, \(Int(exporter.progress * 100)) percent" : exportLabel)
        }
    }

    @ViewBuilder private var status: some View {
        if let error = exporter.error {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .lineLimit(3)
                .textSelection(.enabled)
        } else if let blocker {
            Text(blocker).foregroundStyle(.secondary).lineLimit(2)
        } else if let hint {
            Text(hint).foregroundStyle(.secondary).lineLimit(2)
        }
    }

    private func export() {
        guard blocker == nil, !exporter.isExporting else { return }
        if let player, player.state != .ready { return }
        player?.pause()
        onExport()
    }

    private func handle(_ key: VideoToolsKey) -> Bool {
        if onKey(key) { return true }
        switch key {
        case .playPause: player?.togglePlay()
        case .stepBack: player?.step(-1)
        case .stepForward: player?.step(1)
        case .jumpBack: player?.step(-1, seconds: true)
        case .jumpForward: player?.step(1, seconds: true)
        case .export: export()
        case .close:
            if exporter.isExporting { exporter.cancel() } else { AppServices.shared.closeWindow(id: windowID) }
        case .delete, .character: return false
        }
        return true
    }
}

/// Window-scoped key handling plus a close hook. Space/arrows/Delete/letters are left to
/// text fields while one is being edited; ⌘↩ ends editing first so the typed value counts.
struct VideoToolsKeyCatcher: NSViewRepresentable {
    let handler: (VideoToolsKey) -> Bool
    let onClose: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.handler = handler
        view.onClose = onClose
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.handler = handler
        view.onClose = onClose
    }

    final class CatcherView: NSView {
        var handler: ((VideoToolsKey) -> Bool)?
        var onClose: (() -> Void)?
        private var monitor: Any?
        private var closeObserver: NSObjectProtocol?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitors()
            guard let window else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === self.window else { return event }
                return self.process(event) ? nil : event
            }
            closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                                                   object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.onClose?()
                    self?.removeMonitors()
                }
            }
        }

        private func removeMonitors() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
            closeObserver = nil
        }

        private var isEditingText: Bool {
            guard let responder = window?.firstResponder else { return false }
            if let textView = responder as? NSTextView { return textView.isFieldEditor || textView.isEditable }
            return responder is NSTextField
        }

        private func process(_ event: NSEvent) -> Bool {
            guard let handler, let window else { return false }
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            let editing = isEditingText
            if (event.keyCode == 36 || event.keyCode == 76) && mods == .command {   // ⌘↩
                if editing { window.makeFirstResponder(nil) }
                DispatchQueue.main.async { _ = handler(.export) }
                return true
            }
            if event.keyCode == 53 && mods.isEmpty {                                 // Esc
                if editing { window.makeFirstResponder(nil); return true }
                return handler(.close)
            }
            if mods == .command && event.charactersIgnoringModifiers?.lowercased() == "w" {   // ⌘W
                return handler(.close)
            }
            guard !editing, mods.subtracting(.shift).isEmpty else { return false }
            // A focused list (Join) keeps its own arrow-key selection.
            let listFocused = window.firstResponder is NSTableView
            switch event.keyCode {
            case 49: return handler(.playPause)
            case 123 where !listFocused: return handler(mods.contains(.shift) ? .jumpBack : .stepBack)
            case 124 where !listFocused: return handler(mods.contains(.shift) ? .jumpForward : .stepForward)
            case 123, 124, 125, 126: return false
            case 51, 117: return handler(.delete)
            default:
                guard mods.isEmpty, let c = event.charactersIgnoringModifiers?.lowercased().first else { return false }
                return handler(.character(c))
            }
        }
    }
}
