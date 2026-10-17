import AppKit
import SwiftUI
import WheelieCore

/// "Split": one PDF into several, by every page, every N pages, custom ranges, or the
/// pages you tick. More than one result goes into a new "<name> pages" folder (optional).
@MainActor
final class PDFSplitModel: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case everyPage, everyN, ranges, selected
        var id: String { rawValue }
        var label: String {
            switch self {
            case .everyPage: return "Every Page"
            case .everyN: return "Every N Pages"
            case .ranges: return "Custom Ranges"
            case .selected: return "Selected Pages"
            }
        }
    }

    let url: URL
    let windowID: String
    let thumbnails = PageThumbnails()

    @Published var pageCount = 0
    @Published var mode: Mode = .everyPage
    @Published var pagesPerFile = 2
    @Published var rangesText = ""
    @Published var selectedPages: Set<Int> = []   // zero-based
    @Published var intoFolder = true
    @Published var isLoading = true
    @Published var isSaving = false
    @Published var error: String?

    init(url: URL, windowID: String) {
        self.url = url
        self.windowID = windowID
    }

    var baseName: String { url.deletingPathExtension().lastPathComponent }
    var folderName: String { baseName + PDFSplitter.folderSuffix }

    func load() {
        let url = self.url
        Task {
            do {
                pageCount = try await runDetached { try PDFSourceLoader.document(for: url).pageCount }
                if pageCount == 0 { error = PDFToolsError.noPages.message }
                pagesPerFile = min(pagesPerFile, max(1, pageCount))
                thumbnails.load([url], maxPixels: 260)
            } catch {
                self.error = error.localizedDescription
            }
            isLoading = false
        }
    }

    func close() {
        thumbnails.cancel()
        AppServices.shared.closeWindow(id: windowID)
    }

    /// The split as currently set up, or why it can't be done.
    var splitMode: Result<PDFSplitMode, Error> {
        switch mode {
        case .everyPage: return .success(.everyPage)
        case .everyN: return .success(.everyNPages(pagesPerFile))
        case .ranges:
            return Result { .ranges(try PageRangeParser.parse(rangesText, pageCount: max(pageCount, 1))) }
        case .selected:
            return selectedPages.isEmpty ? .failure(PDFToolsError("Choose at least one page."))
                                         : .success(.extract(selectedPages.map { $0 + 1 }))
        }
    }

    var groups: Result<[[Int]], Error> {
        guard pageCount > 0 else { return .failure(PDFToolsError.noPages) }
        return splitMode.flatMap { mode in Result { try PDFSplitter.groups(for: mode, pageCount: pageCount) } }
    }

    /// Output file number (1-based) for each page, for the badges in the grid.
    var fileNumbers: [Int: [Int]] {
        guard case .success(let groups) = groups else { return [:] }
        var result: [Int: [Int]] = [:]
        for (number, group) in groups.enumerated() {
            for page in group { result[page, default: []].append(number + 1) }
        }
        return result
    }

    func toggle(_ page: Int) {
        if selectedPages.contains(page) { selectedPages.remove(page) } else { selectedPages.insert(page) }
    }

    func split() {
        guard !isSaving, !isLoading else { return }
        let mode: PDFSplitMode, count: Int
        switch (splitMode, groups) {
        case (.success(let m), .success(let g)):
            mode = m
            count = g.count
        case (.failure(let failure), _), (_, .failure(let failure)):
            error = failure.localizedDescription
            return
        }
        let url = self.url, folder = intoFolder && count > 1
        isSaving = true
        error = nil
        Task {
            let result = await AppServices.shared.run("Split PDF", sources: [url]) {
                .outputs(try await runDetached { try PDFSplitter.split(url, mode: mode, intoFolder: folder) })
            }
            isSaving = false
            switch result {
            case .success: close()
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }
}

struct PDFSplitView: View {
    @StateObject var model: PDFSplitModel
    @ObservedObject private var thumbnails: PageThumbnails

    init(model: PDFSplitModel) {
        _model = StateObject(wrappedValue: model)
        thumbnails = model.thumbnails
    }

    var body: some View {
        VStack(spacing: 0) {
            options
                .padding(16)
            Divider()
            pageGrid
            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 480)
        .onAppear { model.load() }
        .onDisappear { model.thumbnails.cancel() }
        .closesWindowOnCommandW(model.windowID) { model.close() }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Split", selection: $model.mode) {
                ForEach(PDFSplitModel.Mode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                switch model.mode {
                case .everyPage:
                    Text("Each page becomes its own PDF.")
                        .foregroundStyle(.secondary)
                case .everyN:
                    Stepper(value: $model.pagesPerFile, in: 1...max(1, model.pageCount)) {
                        HStack(spacing: 6) {
                            Text("Pages per file:")
                            TextField("", value: $model.pagesPerFile, format: .number)
                                .frame(width: 54)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    .fixedSize()
                case .ranges:
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Pages, like \(PageRangeParser.example)", text: $model.rangesText)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { model.split() }
                        Text("Each range becomes its own PDF. “7-” runs to the last page.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                case .selected:
                    HStack {
                        Text("Tick the pages to save together in one PDF.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Select All") { model.selectedPages = Set(0..<model.pageCount) }
                        Button("Select None") { model.selectedPages = [] }
                            .disabled(model.selectedPages.isEmpty)
                    }
                }
            }
            .frame(minHeight: 44, alignment: .topLeading)

            summary
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var summary: some View {
        switch model.groups {
        case .success(let groups):
            VStack(alignment: .leading, spacing: 6) {
                let names = groups.prefix(4).map { model.baseName + PDFSplitter.suffix(for: $0) + ".pdf" }
                let more = groups.count > 4 ? ", …" : ""
                Text(groups.count == 1 ? "Creates 1 PDF: " + names[0]
                                       : "Creates \(groups.count) PDFs: " + names.joined(separator: ", ") + more)
                    .font(.callout)
                    .lineLimit(2)
                    .truncationMode(.middle)
                if groups.count > 1 {
                    Toggle("Put them in a new folder “\(model.folderName)”", isOn: $model.intoFolder)
                } else {
                    Text("Saved next to the original.").font(.caption).foregroundStyle(.secondary)
                }
            }
        case .failure(let failure):
            if model.mode == .ranges && model.rangesText.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("Enter pages or ranges, like \(PageRangeParser.example).")
                    .font(.callout).foregroundStyle(.secondary)
            } else if !model.isLoading {
                InlineError(message: failure.localizedDescription)
            }
        }
    }

    private var pageGrid: some View {
        let numbers = model.fileNumbers
        return ScrollView {
            if model.isLoading { ProgressView("Loading pages…").padding(30) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 116), spacing: 12)], spacing: 14) {
                ForEach(0..<model.pageCount, id: \.self) { page in
                    SplitPageCell(page: page, image: thumbnails.images[PageKey(file: 0, page: page)],
                                  checkable: model.mode == .selected,
                                  checked: model.selectedPages.contains(page),
                                  fileNumbers: model.mode == .selected ? [] : numbers[page] ?? [])
                        .onTapGesture { if model.mode == .selected { model.toggle(page) } }
                }
            }
            .padding(16)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(model.pageCount == 1 ? "1 page" : "\(model.pageCount) pages")
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
            InlineError(message: model.error)
            Button("Cancel") { model.close() }
                .keyboardShortcut(.cancelAction)
            Button {
                model.split()
            } label: {
                if model.isSaving { ProgressView().controlSize(.small).padding(.horizontal, 8) } else { Text("Split") }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .buttonStyle(.borderedProminent)
            .disabled(model.isLoading || model.isSaving || (try? model.groups.get()) == nil)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

struct SplitPageCell: View {
    let page: Int
    let image: CGImage?
    let checkable: Bool
    let checked: Bool
    let fileNumbers: [Int]

    private static let tints: [Color] = [.blue, .orange, .green, .purple, .pink, .teal]

    var body: some View {
        VStack(spacing: 4) {
            PageThumbnailView(image: image, rotation: 0, side: 100)
                .padding(5)
                .background(RoundedRectangle(cornerRadius: 7).fill(highlight.opacity(0.18)))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(highlight, lineWidth: checked || !fileNumbers.isEmpty ? 2 : 0))
                .overlay(alignment: .topLeading) {
                    if checkable {
                        Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 18))
                            .foregroundStyle(checked ? Color.accentColor : .secondary)
                            .background(Circle().fill(.background))
                            .padding(4)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if !fileNumbers.isEmpty {
                        Text(fileNumbers.map(String.init).joined(separator: ", "))
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(highlight))
                            .padding(4)
                            .help("Goes into file \(fileNumbers.map(String.init).joined(separator: ", "))")
                    }
                }
            Text("\(page + 1)").font(.caption).monospacedDigit()
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Page \(page + 1)")
        .accessibilityAddTraits(checkable ? .isButton : [])
        .accessibilityValue(checkable ? (checked ? "selected" : "not selected") : "")
    }

    private var highlight: Color {
        if checkable { return checked ? .accentColor : .clear }
        guard let first = fileNumbers.first else { return .clear }
        return Self.tints[(first - 1) % Self.tints.count]
    }
}

enum PDFSplitWindow {
    @MainActor
    static func open(_ file: URL) {
        let id = PDFWindowID.make("pdf.split", [file])
        let model = PDFSplitModel(url: file, windowID: id)
        AppServices.shared.presentWindow(id: id, title: "Split “\(file.lastPathComponent)”",
                                         size: CGSize(width: 720, height: 620)) {
            PDFSplitView(model: model)
        }
    }
}
