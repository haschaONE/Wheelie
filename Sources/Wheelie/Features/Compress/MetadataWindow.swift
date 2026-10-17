import AppKit
import SwiftUI
import WheelieCore

@MainActor
enum MetadataWindow {
    static func present(_ files: [URL]) {
        let id = CompressFeature.windowID("metadata", files)
        let model = MetadataModel(files: files, windowID: id)
        let title = files.count == 1 ? "Metadata — \(files[0].lastPathComponent)" : "Metadata — \(files.count) Files"
        AppServices.shared.presentWindow(id: id, title: title, size: CGSize(width: 520, height: 560)) {
            MetadataView(model: model)
        }
    }
}

@MainActor
final class MetadataModel: ObservableObject {
    let files: [URL]
    let windowID: String
    @Published var selection: URL
    @Published private(set) var groups: [URL: [MetadataGroup]] = [:]
    @Published private(set) var isRunning = false
    @Published private(set) var finished = false
    @Published private(set) var error: String?

    init(files: [URL], windowID: String) {
        self.files = files
        self.windowID = windowID
        selection = files[0]
    }

    var hasImages: Bool { files.contains { FileKind(url: $0) == .image } }

    func load() async {
        for file in files where groups[file] == nil {
            groups[file] = await MetadataReader.read(file)
        }
    }

    func removeMetadata() async {
        guard !isRunning else { return }
        isRunning = true
        error = nil
        defer { isRunning = false }
        let title = files.count == 1 ? "Remove Metadata from \(files[0].lastPathComponent)" : "Remove Metadata from \(files.count) files"
        let result = await AppServices.shared.run(title, sources: files) { [files] in
            var outputs: [URL] = []
            var failures: [String] = []
            for file in files {
                do { outputs.append(try await MetadataStripper.strip(file)) }
                catch { failures.append(files.count == 1 ? error.localizedDescription
                                                         : "\(file.lastPathComponent): \(error.localizedDescription)") }
            }
            if !failures.isEmpty, outputs.isEmpty {
                throw MetadataBatchError(message: failures.joined(separator: "\n"))
            }
            if !failures.isEmpty {
                self.error = failures.joined(separator: "\n")
            }
            return .outputs(outputs)
        }
        switch result {
        case .success:
            guard error == nil else { return }
            finished = true
            try? await Task.sleep(for: .seconds(1.2))
            AppServices.shared.closeWindow(id: windowID)
        case .failure(let failure):
            error = failure.localizedDescription
        }
    }
}

struct MetadataBatchError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct MetadataView: View {
    @ObservedObject var model: MetadataModel

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer.padding(16)
        }
        .frame(minWidth: 420, minHeight: 360)
        .task { await model.load() }
    }

    @ViewBuilder private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: model.selection.path))
                .resizable().frame(width: 32, height: 32)
            if model.files.count > 1 {
                Picker("File", selection: $model.selection) {
                    ForEach(model.files, id: \.self) { Text($0.lastPathComponent).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.selection.lastPathComponent).font(.headline).lineLimit(1).truncationMode(.middle)
                    Text(ByteSize.string(ByteSize.of(model.selection))).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    @ViewBuilder private var content: some View {
        if let groups = model.groups[model.selection] {
            if groups.isEmpty {
                ContentUnavailableView {
                    Label("No readable metadata found.", systemImage: "checkmark.shield")
                } description: {
                    Text("Removing metadata still writes a clean copy, in case the file holds data Wheelie can't read.")
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(groups) { group in
                            GroupBox {
                                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                                    ForEach(group.entries, id: \.self) { entry in
                                        GridRow {
                                            Text(entry.label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                                            Text(entry.value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                    }
                                }
                                .padding(4)
                            } label: {
                                Label(group.title, systemImage: group.category.symbol).font(.headline)
                            }
                        }
                    }
                    .padding(16)
                }
            }
        } else {
            ProgressView("Reading metadata…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).lineLimit(4)
            } else if model.finished {
                Label("Metadata Removed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Text("Remove metadata now and save a new file. Location, camera, author and editing details are removed; "
                     + "the original stays unchanged."
                     + (model.hasImages ? " For photos, hidden camera data such as HDR gain maps and depth is removed too." : ""))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if model.isRunning { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { AppServices.shared.closeWindow(id: model.windowID) }
                    .keyboardShortcut(.cancelAction)
                Button(model.files.count == 1 ? "Remove Metadata" : "Remove Metadata from \(model.files.count) Files") {
                    Task { await model.removeMetadata() }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(model.isRunning || model.finished)
                Button("Close") { AppServices.shared.closeWindow(id: model.windowID) }
                    .keyboardShortcut("w", modifiers: .command)
                    .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
            }
        }
    }
}
