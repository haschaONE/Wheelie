import AppKit
import SwiftUI
import WheelieCore

/// Opens (or focuses) the QR code results window for a set of images/PDFs and scans them.
@MainActor
enum QRCodeResultsWindow {
    static func show(_ files: [URL]) async {
        let id = "fileactions.qr:" + FileActions.stableHash(files)
        let services = AppServices.shared
        if let existing = services.window(id: id) {
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let model = QRCodeResultsModel(files: files)
        let title = files.count == 1 ? "QR Codes — \(files[0].lastPathComponent)" : "QR Codes — \(files.count) files"
        services.presentWindow(id: id, title: title, size: CGSize(width: 540, height: 440)) {
            QRCodeResultsView(model: model) { services.closeWindow(id: id) }
        }
        if let window = services.window(id: id) {
            model.closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { model.cancel() }
            }
        }
        await model.run()
    }
}

@MainActor
final class QRCodeResultsModel: ObservableObject {
    let files: [URL]
    @Published private(set) var results: [QRCodeResult] = []
    @Published private(set) var failures: [QRScanFailure] = []
    @Published private(set) var isLoading = true
    @Published private(set) var done = 0
    @Published private(set) var total = 0
    @Published private(set) var copiedID: Int?
    @Published private(set) var copiedAll = false
    var closeObserver: NSObjectProtocol?
    private var scanTask: Task<QRScanReport, Never>?
    private var resetWork: DispatchWorkItem?

    init(files: [URL]) { self.files = files }

    func run() async {
        let files = self.files
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            QRCodeReader.scan(files) { done, total in
                Task { @MainActor in
                    self?.done = done
                    self?.total = total
                }
            }
        }
        scanTask = task
        let report = await task.value
        results = report.results
        failures = report.failures
        isLoading = false
    }

    func cancel() {
        scanTask?.cancel()
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
    }

    func copy(_ result: QRCodeResult) {
        put(result.payload)
        copiedAll = false
        copiedID = result.id
        scheduleReset()
    }

    func copyAll() {
        put(results.map(\.payload).joined(separator: "\n"))
        copiedID = nil
        copiedAll = true
        scheduleReset()
    }

    func open(_ result: QRCodeResult) {
        guard let link = result.link else { return }
        NSWorkspace.shared.open(link)
    }

    private func put(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func scheduleReset() {
        resetWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.copiedID = nil
            self?.copiedAll = false
        }
        resetWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    var summary: String {
        guard !isLoading, !results.isEmpty else { return "" }
        let found = results.count == 1 ? "1 code" : "\(results.count) codes"
        let sources = Set(results.map(\.source)).count
        return "Found \(found) in \(sources == 1 ? "1 file" : "\(sources) files")"
    }
}

struct QRCodeResultsView: View {
    @ObservedObject var model: QRCodeResultsModel
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack(spacing: 10) {
                Text(model.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                if model.results.count > 1 {
                    Button(model.copiedAll ? "Copied" : "Copy All", action: model.copyAll)
                }
                Button("Done", action: close)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 420, minHeight: 300)
        .background {
            // No main menu in a menu-bar app, so wire up the usual close shortcuts here.
            Button("Close", action: close).keyboardShortcut(.cancelAction).opacity(0)
            Button("Close Window", action: close).keyboardShortcut("w", modifiers: .command).opacity(0)
        }
    }

    @ViewBuilder private var content: some View {
        if model.isLoading && model.results.isEmpty {
            VStack(spacing: 12) {
                if model.total > 0 {
                    ProgressView(value: Double(model.done), total: Double(model.total))
                        .frame(width: 220)
                } else {
                    ProgressView()
                }
                Text(model.total > 1 ? "Reading QR codes… \(model.done) of \(model.total)" : "Reading QR codes…")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        } else if model.results.isEmpty {
            VStack(spacing: 8) {
                ContentUnavailableView("No QR codes found", systemImage: "qrcode.viewfinder",
                                       description: Text(emptyDescription))
                if !model.failures.isEmpty { failureList.frame(maxHeight: 140) }
            }
        } else {
            List {
                ForEach(model.results) { result in
                    QRCodeRow(result: result, copied: model.copiedID == result.id,
                              copy: { model.copy(result) }, open: { model.open(result) })
                }
                if !model.failures.isEmpty {
                    Section("Couldn't read") { failureRows }
                }
            }
            .listStyle(.inset)
        }
    }

    private var emptyDescription: String {
        model.files.count == 1
            ? "Wheelie didn't find a QR code or barcode in “\(model.files[0].lastPathComponent)”."
            : "Wheelie didn't find a QR code or barcode in these \(model.files.count) files."
    }

    private var failureList: some View {
        List { failureRows }.listStyle(.inset)
    }

    @ViewBuilder private var failureRows: some View {
        ForEach(model.failures, id: \.self) { failure in
            Label {
                Text("\(failure.source.lastPathComponent): \(failure.message)")
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        }
    }
}

private struct QRCodeRow: View {
    let result: QRCodeResult
    let copied: Bool
    let copy: () -> Void
    let open: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: result.symbology == "QR" ? "qrcode" : "barcode")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(result.payload)
                    .font(.body)
                    .lineLimit(4)
                    .textSelection(.enabled)
                Text("\(result.location) · \(result.symbology)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if let link = result.link {
                Button(action: open) {
                    Label("Open", systemImage: "arrow.up.right.square")
                }
                .help(link.absoluteString)
            }
            Button(action: copy) {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .frame(minWidth: 64)
            }
            .accessibilityLabel("Copy QR code text from \(result.location)")
        }
        .padding(.vertical, 4)
    }
}
