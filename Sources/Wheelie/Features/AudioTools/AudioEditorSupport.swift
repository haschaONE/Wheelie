import AppKit
import SwiftUI
import WheelieCore

// MARK: - Temp files

/// A private temp folder for one editor's previews; removed when the editor goes away.
final class TempWorkspace: Sendable {
    let directory: URL

    init() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("Wheelie-audio-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func url(_ prefix: String, ext: String) -> URL {
        directory.appendingPathComponent("\(prefix)-\(UUID().uuidString).\(ext)")
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}

// MARK: - Keyboard and scroll handling

/// Window-scoped shortcuts that work no matter which control has focus:
/// Space plays (unless typing), ⌘↩ exports, Esc / ⌘W close, Delete removes, ←/→ nudge, scroll pans the timeline.
@MainActor
final class AudioEditorKeyMonitor {
    let windowID: String
    var onSpace: (() -> Void)?
    var onExport: (() -> Void)?
    var onDelete: (() -> Bool)?
    var onArrow: ((_ direction: Double, _ large: Bool) -> Bool)?
    /// Point is in the window's SwiftUI global space (top-left origin). Return true when handled.
    var onScroll: ((_ point: CGPoint, _ event: NSEvent) -> Bool)?
    private var monitor: Any?

    init(windowID: String) { self.windowID = windowID }

    func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel]) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return handled ? nil : event
        }
        // Don't start with the caret in the first text field, so Space plays right away.
        DispatchQueue.main.async { [windowID] in
            AppServices.shared.window(id: windowID)?.makeFirstResponder(nil)
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let window = AppServices.shared.window(id: windowID), event.window === window else { return false }
        let editingText = window.firstResponder is NSText
        if event.type == .scrollWheel {
            guard let view = window.contentView, let onScroll else { return false }
            let p = view.convert(event.locationInWindow, from: nil)
            return onScroll(CGPoint(x: p.x, y: view.isFlipped ? p.y : view.bounds.height - p.y), event)
        }
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let code = event.keyCode
        if code == 49, mods.isEmpty, !editingText {                       // Space
            onSpace?()
            return true
        }
        if code == 36 || code == 76, mods == .command {                   // ⌘↩
            window.makeFirstResponder(nil)                                // commit a field being edited
            DispatchQueue.main.async { [weak self] in self?.onExport?() }
            return true
        }
        if code == 53 {                                                   // Esc
            if editingText { window.makeFirstResponder(nil); return true }
            AppServices.shared.closeWindow(id: windowID)
            return true
        }
        if mods == .command, event.charactersIgnoringModifiers?.lowercased() == "w" {
            AppServices.shared.closeWindow(id: windowID)
            return true
        }
        guard !editingText else { return false }
        if code == 51 || code == 117, mods.isEmpty {                      // Delete
            return onDelete?() ?? false
        }
        if code == 123 || code == 124, mods.isEmpty || mods == .shift {   // ← →
            return onArrow?(code == 123 ? -1 : 1, mods == .shift) ?? false
        }
        return false
    }
}

// MARK: - Base editor model

/// Shared state for the audio editors: probing, waveform, playback, export plumbing.
@MainActor
class AudioEditorModel: ObservableObject {
    let tool: AudioTool
    let files: [URL]
    let windowID: String
    var primary: URL { files[0] }

    @Published var info: AudioInfo?
    @Published var infos: [URL: AudioInfo] = [:]
    @Published var waveform: Waveform?
    @Published var isLoading = true
    /// Fatal: nothing can be done (no audio track, unreadable).
    @Published var loadError: String?
    /// Non-fatal note under the waveform.
    @Published var waveformNote: String?
    /// Inline error next to the export button.
    @Published var error: String?
    @Published var isExporting = false

    let player = AudioPlayback()
    let timeline = TimelineController()
    let temp = TempWorkspace()
    let keys: AudioEditorKeyMonitor
    private var started = false
    private var closeObserver: NSObjectProtocol?
    var tasks: [String: Task<Void, Never>] = [:]

    /// Channels the waveform is extracted with (2 for the Channels editor).
    var waveformChannels: Int { 1 }
    /// Shortest duration across the selected files (a trim range must fit every file).
    var duration: Double { files.compactMap { infos[$0]?.duration }.min() ?? info?.duration ?? 0 }
    /// Duration of the previewed file; the timeline and waveform span this.
    var primaryDuration: Double { info?.duration ?? 0 }
    var isMultiFile: Bool { files.count > 1 }
    var canExport: Bool { info != nil && loadError == nil && !isExporting }

    init(tool: AudioTool, files: [URL], windowID: String) {
        self.tool = tool
        self.files = files
        self.windowID = windowID
        self.keys = AudioEditorKeyMonitor(windowID: windowID)
    }

    func start() {
        guard !started else { return }
        started = true
        keys.onSpace = { [weak self] in self?.togglePlayback() }
        keys.onExport = { [weak self] in self?.export() }
        keys.onScroll = { [weak self] point, event in self?.timeline.handleScroll(at: point, event: event) ?? false }
        keys.onArrow = { [weak self] direction, large in
            guard let self, self.info != nil else { return false }
            self.player.seek(to: self.player.currentTime + direction * (large ? 5 : 1))
            return true
        }
        keys.onDelete = { [weak self] in self?.deleteSelection() ?? false }
        keys.install()
        player.onPlayheadMoved = { [weak self] time in self?.timeline.follow(time) }
        observeWindowClose(attempts: 5)
        tasks["load"] = Task { await self.load() }
    }

    /// SwiftUI's onDisappear isn't guaranteed when the window goes away; the close notification is.
    /// The window may not be registered yet on first appearance, so look again on the next turn.
    private func observeWindowClose(attempts: Int) {
        guard closeObserver == nil else { return }
        guard let window = AppServices.shared.window(id: windowID) else {
            if attempts > 0 {
                DispatchQueue.main.async { [weak self] in self?.observeWindowClose(attempts: attempts - 1) }
            }
            return
        }
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                                               object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdown() }
        }
    }

    func shutdown() {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        keys.remove()
        player.stop()
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        var probed: [URL: AudioInfo] = [:]
        var missing: [String] = []
        for file in files {
            do {
                probed[file] = try await AudioProbe.probe(file)
            } catch {
                if file == primary { loadError = error.localizedDescription }
                missing.append(file.lastPathComponent)
            }
        }
        infos = probed
        guard let primaryInfo = probed[primary] else {
            if loadError == nil { loadError = "This file has no playable audio." }
            return
        }
        if !missing.isEmpty, files.count > 1 {
            loadError = "One or more files have no audio track: " + missing.joined(separator: ", ")
        }
        guard primaryInfo.duration > 0 else {
            loadError = "This file has no playable duration."
            return
        }
        info = primaryInfo
        timeline.setDuration(primaryInfo.duration)

        let url = primary, channels = waveformChannels
        async let wave = WaveformExtractor.extract(url, channels: channels, info: primaryInfo)
        let playable = await player.load(url, info: primaryInfo, temp: temp)
        if !playable {
            waveformNote = "Audio preview is unavailable for this file. You can still export."
        }
        waveform = try? await wave
        if waveform == nil { waveformNote = waveformUnavailableMessage }
        await didLoad()
    }

    var waveformUnavailableMessage: String { "Waveform unavailable. You can still export." }

    // Hooks for subclasses.
    func didLoad() async {}
    func export() {}
    func deleteSelection() -> Bool { false }
    func togglePlayback() { player.toggle() }

    /// Runs `work` as a tracked job; closes the window on success, shows the error inline otherwise.
    func runExport(_ title: String, work: @escaping @MainActor () async throws -> [URL]) {
        guard canExport else { return }
        error = nil
        isExporting = true
        player.pause()
        Task {
            let result = await AppServices.shared.run(title, sources: files) { .outputs(try await work()) }
            isExporting = false
            switch result {
            case .success: AppServices.shared.closeWindow(id: windowID)
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }

    /// Runs `body` for every selected file; throws a summary when any failed.
    func forEachFile(_ body: (URL, AudioInfo) async throws -> URL) async throws -> [URL] {
        var outputs: [URL] = []
        var failures: [String] = []
        for file in files {
            guard let info = infos[file] else { continue }
            do {
                outputs.append(try await body(file, info))
            } catch {
                failures.append(files.count == 1 ? error.localizedDescription : "\(file.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if !failures.isEmpty {
            throw AudioToolError.unreadable(failures.count == files.count
                ? failures.joined(separator: "\n")
                : "\(failures.count) of \(files.count) failed. " + failures.joined(separator: "\n"))
        }
        return outputs
    }

    /// Cancels the previous task under `key` and runs a new one after `delay`.
    func debounce(_ key: String, delay: Double = 0.35, _ work: @escaping @MainActor () async -> Void) {
        tasks[key]?.cancel()
        tasks[key] = Task {
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled else { return }
            await work()
        }
    }
}

// MARK: - Formatting

struct TimecodeFormat: ParseableFormatStyle {
    var parseStrategy: TimecodeParser { TimecodeParser() }
    func format(_ value: Double) -> String { Timecode.string(value) }
}

struct TimecodeParser: ParseStrategy {
    func parse(_ value: String) throws -> Double {
        guard let seconds = Timecode.parse(value) else { throw CocoaError(.formatting) }
        return seconds
    }
}

func signed(_ value: Double, decimals: Int = 1) -> String {
    let text = String(format: "%.\(decimals)f", abs(value))
    if value > 0.00001 { return "+" + text }
    if value < -0.00001 { return "−" + text }
    return text
}

/// "−14" with a typographic minus.
func minus(_ value: Double, decimals: Int = 1) -> String {
    let text = String(format: "%.\(decimals)f", value)
    return text.replacingOccurrences(of: "-", with: "−")
}

// MARK: - Shared views

/// Header, content, footer. Every editor uses this so they look alike.
struct AudioEditorScaffold<Content: View, Footer: View>: View {
    @ObservedObject var model: AudioEditorModel
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        VStack(spacing: 0) {
            EditorHeader(model: model)
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 10)
            Divider()
            Group {
                if let loadError = model.loadError {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 28)).foregroundStyle(.orange)
                        Text(loadError).multilineTextAlignment(.center)
                        Button("Close") { AppServices.shared.closeWindow(id: model.windowID) }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.info == nil {
                    ProgressView("Loading audio…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    content()
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
            Divider()
            HStack(spacing: 12) {
                if let error = model.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                        .lineLimit(3)
                        .textSelection(.enabled)
                } else if model.isExporting {
                    ProgressView().controlSize(.small)
                    Text("Exporting…").foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button("Cancel") { AppServices.shared.closeWindow(id: model.windowID) }
                    .help("Close without saving (Esc)")
                footer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 640, minHeight: 440)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { model.start() }
        .onDisappear { model.shutdown() }
    }
}

struct EditorHeader: View {
    @ObservedObject var model: AudioEditorModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: model.tool.symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 34, height: 34)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(model.files.count == 1 ? model.primary.lastPathComponent
                                            : "\(model.primary.lastPathComponent) and \(model.files.count - 1) more")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Group {
                    if let info = model.info {
                        Text(info.summary)
                    } else if model.loadError == nil {
                        Text("Reading file…")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isMultiFile {
                Text("Previewing the first of \(model.files.count) files. Settings apply to every selected file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 260, alignment: .trailing)
            }
        }
    }
}

/// Primary action with ⌘↩ (handled by the key monitor) and a progress state.
struct ExportButton: View {
    @ObservedObject var model: AudioEditorModel
    let title: String
    var enabled = true

    var body: some View {
        Button {
            model.export()
        } label: {
            Text(title).frame(minWidth: 120)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!model.canExport || !enabled)
        .help("\(title) (⌘↩)")
    }
}

/// A labelled row in the settings area.
struct SettingRow<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 118, alignment: .trailing)
            content()
            Spacer(minLength: 0)
        }
    }
}

/// Seconds field ("1:02.50"); commits on Return or when focus leaves.
struct TimeField: View {
    let label: String
    @Binding var value: Double
    var width: CGFloat = 92

    var body: some View {
        TextField(label, value: $value, format: TimecodeFormat())
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .font(.body.monospacedDigit())
            .frame(width: width)
            .help("\(label) (minutes:seconds, or seconds)")
            .accessibilityLabel("\(label) in seconds")
    }
}

/// Number field with unit and clamping.
struct NumberField: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var unit: String = ""
    var step: Double = 1
    var decimals: Int = 1

    var body: some View {
        HStack(spacing: 4) {
            TextField(label, value: Binding(get: { value },
                                            set: { value = min(max($0, range.lowerBound), range.upperBound) }),
                      format: .number.precision(.fractionLength(0...decimals)))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .font(.body.monospacedDigit())
                .frame(width: 64)
                .accessibilityLabel(label)
            Stepper(label, value: Binding(get: { value },
                                          set: { value = min(max($0, range.lowerBound), range.upperBound) }),
                    in: range, step: step)
                .labelsHidden()
            if !unit.isEmpty { Text(unit).foregroundStyle(.secondary) }
        }
    }
}
