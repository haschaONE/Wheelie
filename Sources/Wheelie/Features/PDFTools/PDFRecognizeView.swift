import AppKit
import SwiftUI
import WheelieCore

/// "Recognize": text recognition for scanned PDFs and images. Writes a searchable PDF
/// (the page as it was + an invisible text layer) and/or a plain-text file.
@MainActor
final class PDFRecognizeModel: ObservableObject {
    enum Status: Equatable {
        case waiting
        case working(done: Int, total: Int)
        case done(Int)
        case failed(String)
    }

    struct FileState: Identifiable {
        let id = UUID()
        let url: URL
        var status: Status = .waiting
    }

    struct Language: Identifiable, Hashable {
        let code: String
        let name: String
        var id: String { code }
    }

    let windowID: String
    let languages: [Language]
    @Published var files: [FileState]
    @Published var language: String { didSet { UserDefaults.standard.set(language, forKey: Self.languageKey) } }
    @Published var output: TextRecognitionOptions.Output {
        didSet { UserDefaults.standard.set(output.rawValue, forKey: Self.outputKey) }
    }
    @Published var skipPagesWithText = true
    @Published var isRunning = false
    @Published var error: String?
    private var task: Task<Void, Never>?

    private static let languageKey = "pdf.ocr.language"
    private static let outputKey = "pdf.ocr.output"

    init(urls: [URL], windowID: String) {
        self.windowID = windowID
        files = urls.map { FileState(url: $0) }
        let locale = Locale.current
        languages = TextRecognizer.supportedLanguages().map { code in
            Language(code: code, name: locale.localizedString(forIdentifier: code) ?? code)
        }
        let saved = UserDefaults.standard.string(forKey: Self.languageKey) ?? ""
        language = TextRecognizer.supportedLanguages().contains(saved) ? saved : ""
        output = UserDefaults.standard.string(forKey: Self.outputKey).flatMap(TextRecognitionOptions.Output.init) ?? .pdf
    }

    /// Pages done over pages known, for the overall progress bar.
    var overallProgress: Double {
        guard !files.isEmpty else { return 0 }
        let parts = files.map { file -> Double in
            switch file.status {
            case .waiting: return 0
            case .working(let done, let total): return total > 0 ? Double(done) / Double(total) : 0
            case .done, .failed: return 1
            }
        }
        return parts.reduce(0, +) / Double(files.count)
    }

    func start() {
        guard !isRunning else { return }
        let options = TextRecognitionOptions(languages: language.isEmpty ? [] : [language], output: output,
                                             skipPagesWithText: skipPagesWithText)
        let urls = files.map(\.url)
        for index in files.indices { files[index].status = .waiting }
        isRunning = true
        error = nil
        task = Task {
            var failures: [(file: String, message: String)] = []
            let result = await AppServices.shared.run("Recognize Text", sources: urls) { [weak self] in
                var outputs: [URL] = []
                for (index, url) in urls.enumerated() {
                    if Task.isCancelled { break }
                    self?.files[index].status = .working(done: 0, total: 0)
                    do {
                        let written = try await runDetached {
                            try SearchablePDF.process(url, options: options) { done, total in
                                Task { @MainActor in self?.report(index, done: done, total: total) }
                            }
                        }
                        outputs += written
                        self?.files[index].status = .done(written.count)
                    } catch is CancellationError {
                        self?.files[index].status = .waiting
                        break
                    } catch {
                        failures.append((url.lastPathComponent, error.localizedDescription))
                        self?.files[index].status = .failed(error.localizedDescription)
                    }
                }
                if outputs.isEmpty, let first = failures.first, !Task.isCancelled {
                    throw PDFToolsError(urls.count == 1 ? first.message : "\(first.file): \(first.message)")
                }
                return outputs.isEmpty ? .none : .outputs(outputs)
            }
            isRunning = false
            task = nil
            switch result {
            case .success where failures.isEmpty && !Task.isCancelled:
                close()
            case .success:
                if let first = failures.first {
                    error = failures.count == 1 ? "\(first.file): \(first.message)"
                                                : "\(failures.count) of \(urls.count) files failed."
                }
            case .failure(let failure):
                error = failure.localizedDescription
            }
        }
    }

    private func report(_ index: Int, done: Int, total: Int) {
        guard files.indices.contains(index), case .working = files[index].status else { return }
        files[index].status = .working(done: done, total: total)
    }

    func cancel() {
        task?.cancel()
    }

    /// Esc / Cancel: stop a run in progress, otherwise close.
    func cancelOrClose() {
        if isRunning { cancel() } else { close() }
    }

    func close() {
        task?.cancel()
        AppServices.shared.closeWindow(id: windowID)
    }
}

struct PDFRecognizeView: View {
    @StateObject var model: PDFRecognizeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            settings.padding(16)
            Divider()
            fileList
            Divider()
            footer
        }
        .frame(minWidth: 480, minHeight: 360)
        .onDisappear { model.cancel() }
        .closesWindowOnCommandW(model.windowID) { model.close() }
    }

    private var settings: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text("Language").gridColumnAlignment(.trailing)
                Picker("Language", selection: $model.language) {
                    Text("Automatic").tag("")
                    Divider()
                    ForEach(model.languages) { Text($0.name).tag($0.code) }
                }
                .labelsHidden()
                .frame(maxWidth: 260)
            }
            GridRow {
                Text("Save as")
                Picker("Save as", selection: $model.output) {
                    ForEach(TextRecognitionOptions.Output.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 340)
            }
            GridRow {
                Color.clear.frame(width: 1, height: 1)
                Toggle("Keep pages that already have selectable text as they are", isOn: $model.skipPagesWithText)
            }
        }
        .disabled(model.isRunning)
    }

    private var fileList: some View {
        List(model.files) { file in
            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: file.url.path))
                    .resizable().frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    statusText(file.status)
                }
                Spacer()
                statusIcon(file.status)
            }
            .padding(.vertical, 2)
        }
        .listStyle(.inset)
    }

    @ViewBuilder private func statusText(_ status: PDFRecognizeModel.Status) -> some View {
        switch status {
        case .waiting:
            Text(model.isRunning ? "Waiting" : "Ready").font(.caption).foregroundStyle(.secondary)
        case .working(let done, let total):
            Text(total == 0 ? "Opening…" : "Page \(min(done + 1, total)) of \(total)")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        case .done(let count):
            Text(count == 1 ? "Done" : "Done, \(count) files").font(.caption).foregroundStyle(.secondary)
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.red).lineLimit(2).textSelection(.enabled)
        }
    }

    @ViewBuilder private func statusIcon(_ status: PDFRecognizeModel.Status) -> some View {
        switch status {
        case .waiting: EmptyView()
        case .working(let done, let total):
            if total > 0 {
                ProgressView(value: Double(done), total: Double(total)).frame(width: 90)
            } else {
                ProgressView().controlSize(.small)
            }
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if model.isRunning {
                ProgressView(value: model.overallProgress).frame(maxWidth: 160)
            }
            InlineError(message: model.error)
            Spacer()
            Button(model.isRunning ? "Stop" : "Cancel") { model.cancelOrClose() }
                .keyboardShortcut(.cancelAction)
            Button("Recognize Text") { model.start() }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(model.isRunning)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

enum PDFRecognizeWindow {
    @MainActor
    static func open(_ files: [URL]) {
        let id = PDFWindowID.make("pdf.ocr", files)
        let model = PDFRecognizeModel(urls: files, windowID: id)
        let height = min(560, 250 + CGFloat(files.count) * 44)
        AppServices.shared.presentWindow(id: id, title: "Recognize Text in " + describeFiles(files),
                                         size: CGSize(width: 560, height: height)) {
            PDFRecognizeView(model: model)
        }
    }
}
