import AppKit
import Combine
import SwiftUI
import WheelieCore

/// Watches job notifications and shows a small floating HUD for jobs that take
/// longer than a moment. Also triggers the done / failed sounds.
@MainActor
final class JobProgressController {
    static let shared = JobProgressController()

    private var board = JobBoard()
    private var observers: [AnyCancellable] = []
    private var timer: Timer?
    private var panel: ProgressHUDPanel?
    private var host: ShellFirstMouseHostingView<ProgressHUDView>?
    private var isHiding = false

    private let width: CGFloat = 310

    private init() {}

    func start() {
        guard observers.isEmpty else { return }
        observers.append(ShellFeature.observe(.wheelieJobStarted) { [weak self] note in
            guard let self, let id = note.userInfo?["id"] as? UUID else { return }
            let title = note.userInfo?["title"] as? String ?? "Working"
            let sources = note.userInfo?["sources"] as? [URL] ?? []
            self.board.start(id: id, title: title, sources: sources, at: Date())
            self.refresh()
        })
        observers.append(ShellFeature.observe(.wheelieOutputsProduced) { [weak self] note in
            guard let urls = note.userInfo?["urls"] as? [URL] else { return }
            self?.board.outputsProduced(urls)
        })
        observers.append(ShellFeature.observe(.wheelieJobFinished) { [weak self] note in
            guard let self, let id = note.userInfo?["id"] as? UUID else { return }
            let error = note.userInfo?["error"] as? String
            let finished = self.board.finish(id: id, error: error, at: Date())
            ShellFeedback.shared.jobFinished(finished?.feedback ?? (error == nil ? nil : .failure))
            self.refresh()
        })
    }

    // MARK: State

    private func refresh() {
        board.advance(to: Date())
        render()
        timer?.invalidate()
        timer = nil
        guard let deadline = board.nextDeadline() else { return }
        let fire = max(deadline, Date()).addingTimeInterval(0.02)
        let timer = Timer(fire: fire, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func select(_ entry: JobBoard.Entry) {
        let targets = entry.revealTargets.filter { FileManager.default.fileExists(atPath: $0.path) }
        if !targets.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(targets) }
        board.dismiss(id: entry.id)
        refresh()
    }

    private func dismiss(_ id: UUID) {
        board.dismiss(id: id)
        refresh()
    }

    private func hover(_ inside: Bool) {
        board.setHovering(inside, at: Date())
        refresh()
    }

    // MARK: Panel

    private func render() {
        let entries = board.visibleEntries
        guard !entries.isEmpty else { hide(); return }
        let view = ProgressHUDView(entries: entries,
                                   onSelect: { [weak self] in self?.select($0) },
                                   onDismiss: { [weak self] in self?.dismiss($0) },
                                   onHover: { [weak self] in self?.hover($0) })
        let panel = self.panel ?? makePanel(rootView: view)
        host?.rootView = view
        host?.layoutSubtreeIfNeeded()
        let height = ceil(host?.fittingSize.height ?? 80)
        panel.setFrame(frame(for: NSSize(width: width, height: height)), display: true)
        panel.invalidateShadow()

        if !panel.isVisible || isHiding {
            isHiding = false
            if !panel.isVisible { panel.alphaValue = 0 }
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                panel.animator().alphaValue = 1
            }
        }
    }

    private func hide() {
        guard let panel, panel.isVisible, !isHiding else { return }
        isHiding = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isHiding else { return }
                self.isHiding = false
                panel.orderOut(nil)
            }
        })
    }

    private func makePanel(rootView: ProgressHUDView) -> ProgressHUDPanel {
        let host = ShellFirstMouseHostingView(rootView: rootView)
        host.sizingOptions = []
        let panel = ProgressHUDPanel()
        panel.contentView = ShellUI.glassContainer(cornerRadius: 14, content: host)
        self.panel = panel
        self.host = host
        return panel
    }

    /// Under Wheelie's menu bar icon when it can be found, else the top-right corner.
    private func frame(for size: NSSize) -> NSRect {
        let statusWindows = NSApp.windows.filter { $0.className == "NSStatusBarWindow" && $0.isVisible }
        let anchor = statusWindows.count == 1 ? statusWindows[0].frame : nil
        let screen = anchor.flatMap { a in NSScreen.screens.first { $0.frame.intersects(a) } }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return NSRect(origin: .zero, size: size) }
        let margin: CGFloat = 8
        var x = anchor.map { $0.midX - size.width / 2 } ?? (visible.maxX - size.width - 12)
        x = min(max(x, visible.minX + margin), visible.maxX - size.width - margin)
        let top = visible.maxY - (anchor == nil ? 10 : 6)
        return NSRect(x: x, y: top - size.height, width: size.width, height: size.height)
    }
}

/// Borderless, non-activating floating panel: never takes focus from the user's app.
final class ProgressHUDPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 300, height: 80),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        setAccessibilityLabel("Wheelie progress")
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct ProgressHUDView: View {
    let entries: [JobBoard.Entry]
    let onSelect: (JobBoard.Entry) -> Void
    let onDismiss: (UUID) -> Void
    let onHover: (Bool) -> Void

    private let maxRows = 5

    var body: some View {
        let shown = Array(entries.suffix(maxRows))
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "steeringwheel")
                Text(headline)
                Spacer(minLength: 0)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.bottom, 2)

            ForEach(shown) { entry in
                ProgressHUDRow(entry: entry, onSelect: onSelect, onDismiss: onDismiss)
            }
            if entries.count > shown.count {
                Text("+\(entries.count - shown.count) more")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
            }
        }
        .padding(8)
        .frame(width: 310, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .onHover(perform: onHover)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Wheelie progress")
    }

    private var headline: String {
        let running = entries.filter(\.isRunning).count
        if running > 0 { return running == 1 ? "Working…" : "Working on \(running) jobs…" }
        let failed = entries.filter { $0.error != nil }.count
        if failed == entries.count { return failed == 1 ? "Couldn't finish" : "\(failed) jobs failed" }
        return failed > 0 ? "Finished with errors" : "Done"
    }
}

private struct ProgressHUDRow: View {
    let entry: JobBoard.Entry
    let onSelect: (JobBoard.Entry) -> Void
    let onDismiss: (UUID) -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            icon.frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    trailing
                }
                if !entry.sourceSummary.isEmpty {
                    Text(entry.sourceSummary)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                detail
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(Color.primary.opacity(hovering && !entry.isRunning ? 0.08 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { if !entry.isRunning { onSelect(entry) } }
        .help(helpText)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(entry.isRunning ? [] : .isButton)
    }

    @ViewBuilder private var icon: some View {
        if let first = entry.sources.first {
            Image(nsImage: NSWorkspace.shared.icon(forFile: first.path))
                .resizable()
                .interpolation(.high)
        } else {
            Image(systemName: "doc").font(.system(size: 20)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var trailing: some View {
        switch entry.state {
        case .running:
            Text(timerInterval: entry.startedAt...Date.distantFuture, countsDown: false)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 34, alignment: .trailing)
        case .succeeded:
            if hovering {
                dismissButton
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    .accessibilityLabel("Done")
            }
        case .failed:
            if hovering {
                dismissButton
            } else {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .accessibilityLabel("Failed")
            }
        }
    }

    private var dismissButton: some View {
        Button { onDismiss(entry.id) } label: {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Dismiss")
        .accessibilityLabel("Dismiss")
    }

    @ViewBuilder private var detail: some View {
        switch entry.state {
        case .running:
            ProgressView()
                .progressViewStyle(.linear)
                .controlSize(.small)
                .padding(.top, 2)
                .accessibilityLabel("In progress")
        case .succeeded:
            Text(savedText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        case .failed(let message):
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var savedText: String {
        switch entry.outputs.count {
        case 0: return "Done"
        case 1: return "Saved \(entry.outputs[0].lastPathComponent)"
        default: return "Saved \(entry.outputs.count) files"
        }
    }

    private var helpText: String {
        switch entry.state {
        case .running: return "\(entry.title) is running"
        case .succeeded: return entry.outputs.isEmpty ? "Click to show the file in Finder" : "Click to show the result in Finder"
        case .failed(let message): return message
        }
    }
}
