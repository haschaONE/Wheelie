import AppKit
import SwiftUI
import WheelieCore

enum CompressionMode: String, CaseIterable, Identifiable {
    case preset, fileSize, percentage

    var id: String { rawValue }

    var label: String {
        switch self {
        case .preset: return "Preset"
        case .fileSize: return "Target Size"
        case .percentage: return "Percentage"
        }
    }
}

@MainActor
enum CompressionWindow {
    static func present(_ files: [URL]) {
        let id = CompressFeature.windowID("compress", files)
        let model = CompressionModel(files: files, windowID: id)
        AppServices.shared.presentWindow(id: id, title: "Compression Settings", size: CGSize(width: 500, height: 560)) {
            CompressionSettingsView(model: model)
        }
    }
}

@MainActor
final class CompressionModel: ObservableObject {
    enum State {
        case pending, working
        case done(CompressionResult)
        case failed(String)
    }

    struct Item: Identifiable {
        let url: URL
        let kind: FileKind
        let bytes: Int64
        var state: State = .pending
        var id: URL { url }
    }

    @Published var items: [Item]
    @Published private(set) var isRunning = false
    @Published var finished = false
    let windowID: String

    init(files: [URL], windowID: String) {
        self.windowID = windowID
        items = files.map { Item(url: $0, kind: FileKind(url: $0), bytes: ByteSize.of($0)) }
    }

    var hasImages: Bool { items.contains { $0.kind == .image || $0.kind == .pdf } }
    var hasMedia: Bool { items.contains { $0.kind == .video || $0.kind == .audio } }
    var hasRasterImages: Bool { items.contains { $0.kind == .image } }
    var totalBytes: Int64 { items.reduce(0) { $0 + $1.bytes } }
    var smallestBytes: Int64 { items.map(\.bytes).min() ?? 0 }

    var results: [CompressionResult] {
        items.compactMap { if case .done(let r) = $0.state { return r } else { return nil } }
    }

    var failures: [String] {
        items.compactMap { if case .failed(let message) = $0.state { return message } else { return nil } }
    }

    /// Overall reduction across finished files, 0...1.
    var totalReduction: Double? {
        let done = results
        guard !done.isEmpty else { return nil }
        let before = done.reduce(0) { $0 + $1.originalBytes }, after = done.reduce(0) { $0 + $1.compressedBytes }
        return before > 0 ? max(0, 1 - Double(after) / Double(before)) : nil
    }

    func compress(options: CompressionOptions) async {
        guard !isRunning else { return }
        // Re-running retries what didn't finish; if everything finished, start over.
        var indices = items.indices.filter { if case .done = items[$0].state { return false } else { return true } }
        if indices.isEmpty { indices = Array(items.indices) }
        for i in indices { items[i].state = .pending }
        isRunning = true
        defer { isRunning = false }

        let sources = indices.map { items[$0].url }
        let title = sources.count == 1 ? "Compress \(sources[0].lastPathComponent)" : "Compress \(sources.count) files"
        let outcome = await AppServices.shared.run(title, sources: sources) { [self] in
            var outputs: [URL] = []
            var firstError: Error?
            for i in indices {
                items[i].state = .working
                do {
                    let result = try await Compressor.compress(items[i].url, options: options)
                    items[i].state = .done(result)
                    outputs.append(result.output)
                } catch {
                    items[i].state = .failed(error.localizedDescription)
                    firstError = firstError ?? error
                }
            }
            if outputs.isEmpty, let firstError { throw firstError }
            return .outputs(outputs)
        }
        if case .success = outcome, failures.isEmpty {
            finished = true
            try? await Task.sleep(for: .seconds(1.6))
            AppServices.shared.closeWindow(id: windowID)
        }
    }
}

struct CompressionSettingsView: View {
    @ObservedObject var model: CompressionModel

    @AppStorage(CompressKey.mode) private var modeRaw = CompressionMode.preset.rawValue
    @AppStorage(CompressKey.imageStrength) private var imageStrengthRaw = CompressionStrength.balanced.rawValue
    @AppStorage(CompressKey.videoStrength) private var videoStrengthRaw = CompressionStrength.balanced.rawValue
    @AppStorage(CompressKey.imageSize) private var imageSizeRaw = ImageSizeLimit.original.rawValue
    @AppStorage(CompressKey.targetBytes) private var targetBytes = 2_000_000
    @AppStorage(CompressKey.targetUnit) private var targetUnit = "MB"
    @AppStorage(CompressKey.targetPercent) private var targetPercent = 50

    @State private var targetText = ""
    @State private var targetTextInvalid = false

    private var mode: CompressionMode { CompressionMode(rawValue: modeRaw) ?? .preset }
    private var unitBytes: Double { targetUnit == "KB" ? 1_000 : 1_000_000 }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    FileSizeList(model: model)
                } header: {
                    HStack {
                        Text(model.items.count == 1 ? "Original" : "\(model.items.count) Files")
                        Spacer()
                        Text(ByteSize.string(model.totalBytes)).monospacedDigit()
                            .accessibilityIdentifier("compressionOriginalSize")
                    }
                }

                Section("Compression") {
                    Picker("Compression mode", selection: $modeRaw) {
                        ForEach(CompressionMode.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("compressionTargetMode")

                    switch mode {
                    case .preset: presetControls
                    case .fileSize: targetSizeControls
                    case .percentage: percentageControls
                    }
                }

                if model.hasRasterImages {
                    Section {
                        Picker("Image size", selection: $imageSizeRaw) {
                            ForEach(ImageSizeLimit.allCases) { Text($0.label).tag($0.rawValue) }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(model.isRunning || model.finished)

            Divider()
            footer.padding(16)
        }
        .frame(minWidth: 440, minHeight: 420)
    }

    // MARK: Controls

    @ViewBuilder private var presetControls: some View {
        if model.hasImages {
            strengthPicker(model.hasMedia ? "Images & PDFs" : "Strength", selection: $imageStrengthRaw)
        }
        if model.hasMedia {
            strengthPicker(model.hasImages ? "Video & audio" : "Strength", selection: $videoStrengthRaw)
        }
    }

    private func strengthPicker(_ title: String, selection: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(title, selection: selection) {
                ForEach(CompressionStrength.allCases) { Text($0.label).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            Text((CompressionStrength(rawValue: selection.wrappedValue) ?? .balanced).summary)
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private static let numberFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 2
        f.usesGroupingSeparator = false
        return f
    }()

    /// Shows the stored byte target in the chosen unit.
    private func syncTargetText() {
        targetText = Self.numberFormatter.string(from: NSNumber(value: Double(targetBytes) / unitBytes)) ?? ""
        targetTextInvalid = false
    }

    /// Parses as you type (so ⌘↩ never uses a stale value); accepts "2,5" and "2.5".
    private func parseTargetText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let value = Self.numberFormatter.number(from: trimmed)?.doubleValue
            ?? Double(trimmed.replacingOccurrences(of: ",", with: "."))
        guard let value, value.isFinite, value > 0 else { targetTextInvalid = true; return }
        targetTextInvalid = false
        targetBytes = Int((value * unitBytes).rounded())
    }

    @ViewBuilder private var targetSizeControls: some View {
        LabeledContent("Target file size") {
            HStack(spacing: 6) {
                TextField("Target file size", text: $targetText)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
                    .onChange(of: targetText) { _, text in parseTargetText(text) }
                Picker("Unit", selection: $targetUnit) {
                    Text("KB").tag("KB")
                    Text("MB").tag("MB")
                }
                .labelsHidden()
                .fixedSize()
                .onChange(of: targetUnit) { _, _ in syncTargetText() }
            }
        }
        .onAppear { syncTargetText() }
        Text(targetSizeHint).font(.caption).foregroundStyle(targetSizeError == nil ? Color.secondary : Color.red)
    }

    @ViewBuilder private var percentageControls: some View {
        LabeledContent("File size reduction") {
            HStack(spacing: 8) {
                Slider(value: Binding(get: { Double(targetPercent) }, set: { targetPercent = Int($0.rounded()) }),
                       in: 1...99, step: 1)
                    .frame(width: 180)
                    .accessibilityIdentifier("compressionTargetPercentage")
                Text("\(targetPercent)%").monospacedDigit().frame(width: 40, alignment: .trailing)
            }
        }
        Text(percentageHint).font(.caption).foregroundStyle(percentageError == nil ? Color.secondary : Color.red)
    }

    // MARK: Validation & hints

    private var targetSizeError: String? {
        if targetTextInvalid { return "Enter a target size between 1 KB and 1 TB." }
        if targetBytes < 1_000 { return "Enter a target size of at least 1 KB." }
        if targetBytes > 1_000_000_000_000 { return "Enter a target size between 1 KB and 1 TB." }
        return nil
    }

    private var targetSizeHint: String {
        if let targetSizeError { return targetSizeError }
        let size = ByteSize.string(Int64(targetBytes))
        if model.items.count == 1 {
            if Int64(targetBytes) >= model.totalBytes {
                return "The original is already smaller than \(size). The output will just be smaller than the original."
            }
            return "Output will be at most \(size)."
        }
        return "Each file will be at most \(size), and always smaller than its original."
    }

    private var percentageError: String? {
        guard (1...99).contains(targetPercent) else { return "Choose a reduction from 1% to 99%." }
        if model.smallestBytes * Int64(100 - targetPercent) / 100 < 1_000 {
            return "Choose a reduction from 1% to 99% that leaves at least 1 KB per file."
        }
        return nil
    }

    private var percentageHint: String {
        if let percentageError { return percentageError }
        if model.items.count == 1 {
            return "Output will be at most \(ByteSize.string(model.totalBytes * Int64(100 - targetPercent) / 100))."
        }
        return "The target is calculated separately from each original file."
    }

    private var validationError: String? {
        switch mode {
        case .preset: return nil
        case .fileSize: return targetSizeError
        case .percentage: return percentageError
        }
    }

    private var options: CompressionOptions {
        let goal: CompressionGoal
        switch mode {
        case .preset: goal = .preset
        case .fileSize: goal = .maxBytes(Int64(targetBytes))
        case .percentage: goal = .reduction(targetPercent)
        }
        return CompressionOptions(goal: goal,
                                  imageStrength: CompressionStrength(rawValue: imageStrengthRaw) ?? .balanced,
                                  mediaStrength: CompressionStrength(rawValue: videoStrengthRaw) ?? .balanced,
                                  imageSize: ImageSizeLimit(rawValue: imageSizeRaw) ?? .original)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            status
            Spacer()
            Button("Cancel") { AppServices.shared.closeWindow(id: model.windowID) }
                .keyboardShortcut(.cancelAction)
            Button(model.isRunning ? "Compressing…" : "Compress") {
                Task { await model.compress(options: options) }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .buttonStyle(.borderedProminent)
            .disabled(model.isRunning || model.finished || validationError != nil)
            // ⌘W closes too (menu-bar apps have no File menu).
            Button("Close") { AppServices.shared.closeWindow(id: model.windowID) }
                .keyboardShortcut("w", modifiers: .command)
                .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
        }
    }

    @ViewBuilder private var status: some View {
        if model.isRunning {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Compressing…").foregroundStyle(.secondary)
            }
        } else if let reduction = model.totalReduction {
            VStack(alignment: .leading, spacing: 2) {
                Text("File size reduction: \(Int((reduction * 100).rounded()))%")
                    .fontWeight(.medium)
                    .accessibilityIdentifier("compressionReductionPercentage")
                if !model.failures.isEmpty {
                    Text("\(model.failures.count) file\(model.failures.count == 1 ? "" : "s") could not be compressed.")
                        .font(.caption).foregroundStyle(.red)
                }
            }
        } else if let failure = model.failures.first {
            Text(failure).font(.caption).foregroundStyle(.red).lineLimit(3).textSelection(.enabled)
        }
    }
}

/// Original sizes, and after compressing the new size and reduction per file.
private struct FileSizeList: View {
    @ObservedObject var model: CompressionModel

    var body: some View {
        if model.items.count > 5 {
            ScrollView { rows }.frame(height: 150)
        } else {
            rows
        }
    }

    private var rows: some View {
        VStack(spacing: 6) {
            ForEach(model.items) { item in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                            .resizable().frame(width: 18, height: 18)
                        Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(ByteSize.string(item.bytes)).monospacedDigit().foregroundStyle(.secondary)
                        state(item.state)
                    }
                    if case .failed(let message) = item.state {
                        Text(message).font(.caption).foregroundStyle(.red).lineLimit(2)
                            .padding(.leading, 26).textSelection(.enabled)
                    }
                }
            }
        }
    }

    @ViewBuilder private func state(_ state: CompressionModel.State) -> some View {
        switch state {
        case .pending:
            EmptyView()
        case .working:
            ProgressView().controlSize(.small)
        case .done(let result):
            HStack(spacing: 4) {
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                Text(ByteSize.string(result.compressedBytes)).monospacedDigit()
                Text("−\(Int((result.reduction * 100).rounded()))%").monospacedDigit().foregroundStyle(.green)
            }
        case .failed(let message):
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(message)
        }
    }
}
