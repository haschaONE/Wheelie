import AppKit
import SwiftUI
import WheelieCore

/// "Make PDF": all dropped images in one PDF, one page each, with page size, orientation,
/// margins and fit. (The inner ring's PDF format makes one PDF per image instead.)
@MainActor
final class PDFCreateModel: ObservableObject {
    struct Item: Identifiable {
        let id = UUID()
        let url: URL
        var size: CGSize?
        var thumbnail: CGImage?
        /// Pages it makes (a multi-page TIFF makes one per page).
        var pages = 1
        var name: String { url.lastPathComponent }
    }

    let windowID: String
    @Published var items: [Item]
    @Published var selection: UUID?
    @Published var options: ImagePDFOptions {
        didSet { Self.store(options) }
    }
    @Published var isSaving = false
    @Published var error: String?

    init(urls: [URL], windowID: String) {
        self.windowID = windowID
        let items = urls.map { Item(url: $0) }
        self.items = items
        selection = items.first?.id
        options = Self.restore()
    }

    func load() {
        for item in items where item.thumbnail == nil {
            let url = item.url, id = item.id
            Task {
                let summary = (try? await runDetached { PDFSourceLoader.imageSummary(url, thumbnailPixels: 900) }) ?? nil
                guard let index = items.firstIndex(where: { $0.id == id }) else { return }
                guard let summary else {
                    error = "Could not read the image “\(url.lastPathComponent)”."
                    return
                }
                items[index].size = summary.size
                items[index].thumbnail = summary.thumbnail
                items[index].pages = summary.pages
            }
        }
    }

    func close() { AppServices.shared.closeWindow(id: windowID) }

    var selectedItem: Item? { items.first { $0.id == selection } ?? items.first }

    /// Pages in the PDF: one per image, one per page of a multi-page TIFF.
    var pageCount: Int { items.reduce(0) { $0 + $1.pages } }

    func move(from source: IndexSet, to destination: Int) { items.move(fromOffsets: source, toOffset: destination) }

    func sortByName() {
        let order = PDFSourceLoader.sortedByName(items.map(\.url))
        items.sort { (order.firstIndex(of: $0.url) ?? 0) < (order.firstIndex(of: $1.url) ?? 0) }
    }

    func removeSelected() {
        guard items.count > 1, let id = selection, let index = items.firstIndex(where: { $0.id == id }) else { return }
        items.remove(at: index)
        selection = items[min(index, items.count - 1)].id
    }

    func save() {
        guard !isSaving, !items.isEmpty else { return }
        let urls = items.map(\.url), options = self.options
        isSaving = true
        error = nil
        Task {
            let result = await AppServices.shared.run("Make PDF", sources: urls) {
                .outputs([try await runDetached { try ImagesToPDF.create(urls, options: options) }])
            }
            isSaving = false
            switch result {
            case .success: close()
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }

    // Remember the layout between uses.
    private static let defaultsKey = "pdf.create.options"

    private static func store(_ options: ImagePDFOptions) {
        UserDefaults.standard.set([options.pageSize.rawValue, options.orientation.rawValue,
                                   options.margin.rawValue, options.fit.rawValue], forKey: defaultsKey)
    }

    private static func restore() -> ImagePDFOptions {
        let values = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        guard values.count == 4 else { return ImagePDFOptions() }
        return ImagePDFOptions(pageSize: .init(rawValue: values[0]) ?? .fitImage,
                               orientation: .init(rawValue: values[1]) ?? .automatic,
                               margin: .init(rawValue: values[2]) ?? .none,
                               fit: .init(rawValue: values[3]) ?? .fit)
    }
}

struct PDFCreateView: View {
    @StateObject var model: PDFCreateModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                imageList.frame(width: 270)
                Divider()
                VStack(spacing: 0) {
                    preview
                    Divider()
                    settings.padding(16)
                }
            }
            Divider()
            footer
        }
        .frame(minWidth: 720, minHeight: 520)
        .onAppear { model.load() }
        .closesWindowOnCommandW(model.windowID) { model.close() }
    }

    private var imageList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Pages").font(.headline).padding(.horizontal, 12).padding(.top, 10)
            List(selection: $model.selection) {
                ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                    HStack(spacing: 8) {
                        Text("\(index + 1)").font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 20)
                        Group {
                            if let thumb = item.thumbnail {
                                Image(decorative: thumb, scale: 1).resizable().scaledToFit()
                            } else {
                                ProgressView().controlSize(.small)
                            }
                        }
                        .frame(width: 40, height: 40)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.name).lineLimit(1).truncationMode(.middle)
                            if let size = item.size {
                                Text("\(Int(size.width)) × \(Int(size.height))" + (item.pages > 1 ? " · \(item.pages) pages" : ""))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .tag(item.id)
                    .help("Drag to change the page order")
                    .contextMenu {
                        Button("Remove from PDF") { model.selection = item.id; model.removeSelected() }
                            .disabled(model.items.count < 2)
                    }
                }
                .onMove { model.move(from: $0, to: $1) }
            }
            .listStyle(.sidebar)
            .onDeleteCommand { model.removeSelected() }
            Button { model.sortByName() } label: {
                Label("Order the files by name, as Finder lists them", systemImage: "textformat.abc")
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.link)
            .font(.callout)
            .padding(12)
        }
    }

    private var preview: some View {
        GeometryReader { geo in
            if let item = model.selectedItem, let size = item.size {
                let options = model.options
                let page = options.pageSize(for: size)
                let content = options.contentRect(on: page)
                let rect = options.imageRect(for: size, on: page)
                let scale = max(0.01, min((geo.size.width - 40) / page.width, (geo.size.height - 56) / page.height))
                VStack(spacing: 10) {
                    ZStack(alignment: .topLeading) {
                        Rectangle().fill(Color.white)
                        Group {
                            if let thumb = item.thumbnail {
                                Image(decorative: thumb, scale: 1).resizable()
                                    .frame(width: rect.width * scale, height: rect.height * scale)
                                    .offset(x: (rect.minX - content.minX) * scale, y: (content.maxY - rect.maxY) * scale)
                            }
                        }
                        .frame(width: content.width * scale, height: content.height * scale, alignment: .topLeading)
                        .clipped()
                        .offset(x: content.minX * scale, y: (page.height - content.maxY) * scale)
                    }
                    .frame(width: page.width * scale, height: page.height * scale)
                    .shadow(color: .black.opacity(0.25), radius: 4, y: 1)
                    Text(caption(page: page))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                .frame(width: geo.size.width, height: geo.size.height)
            } else {
                ProgressView().frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .animation(.easeInOut(duration: 0.15), value: model.options)
    }

    private func caption(page: CGSize) -> String {
        let position = model.items.firstIndex { $0.id == model.selectedItem?.id } ?? 0
        let first = model.items.prefix(position).reduce(0) { $0 + $1.pages } + 1
        let pages = model.selectedItem?.pages ?? 1
        let inches = String(format: "%.2f × %.2f in", page.width / 72, page.height / 72)
        let which = pages > 1 ? "Pages \(first)–\(first + pages - 1)" : "Page \(first)"
        return "\(which) of \(model.pageCount) · \(inches)"
    }

    private var settings: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow {
                Text("Page size").gridColumnAlignment(.trailing)
                Picker("Page size", selection: $model.options.pageSize) {
                    ForEach(ImagePDFOptions.PageSize.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            GridRow {
                Text("Orientation")
                Picker("Orientation", selection: $model.options.orientation) {
                    ForEach(ImagePDFOptions.Orientation.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                .disabled(model.options.pageSize == .fitImage)
            }
            GridRow {
                Text("Margins")
                Picker("Margins", selection: $model.options.margin) {
                    ForEach(ImagePDFOptions.Margin.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            GridRow {
                Text("Image")
                Picker("Image", selection: $model.options.fit) {
                    ForEach(ImagePDFOptions.Fit.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                .disabled(model.options.pageSize == .fitImage)
                .help("Fit shows the whole image; Fill covers the page inside the margins and crops the rest")
            }
        }
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
                model.save()
            } label: {
                if model.isSaving { ProgressView().controlSize(.small).padding(.horizontal, 14) } else { Text("Make PDF") }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .buttonStyle(.borderedProminent)
            .disabled(model.isSaving || model.items.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

enum PDFCreateWindow {
    @MainActor
    static func open(_ files: [URL]) {
        let id = PDFWindowID.make("pdf.create", files)
        let model = PDFCreateModel(urls: files, windowID: id)
        AppServices.shared.presentWindow(id: id, title: "Make PDF from " + describeFiles(files, noun: "images"),
                                         size: CGSize(width: 860, height: 620)) {
            PDFCreateView(model: model)
        }
    }
}
