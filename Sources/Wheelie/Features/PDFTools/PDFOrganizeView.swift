import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import WheelieCore

/// "Organize": every page of the dropped PDFs (and images) in one grid. Reorder by drag,
/// rotate, delete, duplicate, then save one new PDF.
@MainActor
final class PDFOrganizeModel: ObservableObject {
    struct SourceFile: Identifiable {
        let id: Int
        let url: URL
        var pageCount: Int
        var name: String { url.lastPathComponent }
    }

    let windowID: String
    let urls: [URL]
    let thumbnails = PageThumbnails()

    @Published var files: [SourceFile] = []
    /// Order of `files` (indices); pages are grouped by it.
    @Published var fileOrder: [Int]
    @Published var plan = PDFPagePlan()
    @Published var selection: Set<UUID> = []
    @Published var zoom: Double = 150
    @Published var equalWidths = false
    @Published var isLoading = true
    @Published var isSaving = false
    @Published var error: String?

    private var undoStack: [PDFPagePlan] = []
    private var anchor: UUID?
    private var dragged: Set<UUID> = []

    static let zoomRange: ClosedRange<Double> = 90...320

    init(urls: [URL], windowID: String) {
        self.urls = urls
        self.windowID = windowID
        fileOrder = Array(urls.indices)
    }

    var pageCounts: [Int] { files.map(\.pageCount) }
    var canUndo: Bool { !undoStack.isEmpty }
    var hasSelection: Bool { !selection.isEmpty }

    func load() {
        let urls = self.urls
        Task {
            do {
                let counts = try await runDetached { try urls.map { try PDFSourceLoader.document(for: $0).pageCount } }
                files = counts.enumerated().map { SourceFile(id: $0.offset, url: urls[$0.offset], pageCount: $0.element) }
                plan = .identity(pageCounts: counts, fileOrder: fileOrder)
                if plan.isEmpty { error = PDFToolsError.noPages.message }
                thumbnails.load(urls)
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

    func fileName(_ index: Int) -> String { files.indices.contains(index) ? files[index].name : "" }

    // MARK: Editing (each step can be undone)

    private func edit(_ change: (inout PDFPagePlan) -> Void) {
        let before = plan
        change(&plan)
        guard plan != before else { return }
        undoStack.append(before)
        if undoStack.count > 100 { undoStack.removeFirst() }
        error = nil
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        plan = previous
        selection = selection.filter { id in plan.pages.contains { $0.id == id } }
    }

    func rotateSelection() { edit { $0.rotate(selection) } }
    func rotate(_ id: UUID) { edit { $0.rotate([id]) } }

    func deleteSelection() {
        guard hasSelection else { return }
        edit { $0.delete(selection) }
        selection = []
    }

    func duplicateSelection() {
        guard hasSelection else { return }
        var added: [UUID] = []
        edit { added = $0.duplicate(selection) }
        selection = Set(added)
    }

    func resetOrder() {
        edit { $0.resetOrder(pageCounts: pageCounts, fileOrder: fileOrder) }
        selection = []
    }

    func moveFiles(from source: IndexSet, to destination: Int) {
        fileOrder.move(fromOffsets: source, toOffset: destination)
        let order = fileOrder
        edit { $0.regroup(fileOrder: order) }
    }

    func sortFilesByName() {
        let sorted = PDFSourceLoader.sortedByName(fileOrder.map { urls[$0] })
        fileOrder = sorted.compactMap { url in urls.firstIndex(of: url) }
        let order = fileOrder
        edit { $0.regroup(fileOrder: order) }
    }

    // MARK: Selection

    func click(_ id: UUID) {
        dragged = []   // a drag that ended outside the grid never reported its drop
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            anchor = id
        } else if flags.contains(.shift), let anchor, let a = plan.index(of: anchor), let b = plan.index(of: id) {
            selection = Set(plan.pages[min(a, b)...max(a, b)].map(\.id))
        } else {
            selection = [id]
            anchor = id
        }
    }

    func selectAll() { selection = Set(plan.pages.map(\.id)) }

    // MARK: Drag to reorder

    func beginDrag(_ id: UUID) {
        if !selection.contains(id) { selection = [id]; anchor = id }
        dragged = selection
        undoStack.append(plan)
    }

    func dragEntered(_ target: UUID) {
        guard !dragged.isEmpty, !dragged.contains(target) else { return }
        withAnimation(.easeInOut(duration: 0.18)) { plan.move(dragged, onto: target) }
    }

    func endDrag() {
        if let last = undoStack.last, last == plan { undoStack.removeLast() }
        dragged = []
    }

    // MARK: Save

    func save() {
        guard !isSaving, !isLoading else { return }
        do { try plan.validate(pageCounts: pageCounts) } catch {
            self.error = error.localizedDescription
            return
        }
        let urls = self.urls, plan = self.plan, equal = equalWidths
        let nameSource = urls[fileOrder.first ?? 0]
        isSaving = true
        error = nil
        Task {
            let result = await AppServices.shared.run("Organize PDF", sources: urls) {
                let output = try await runDetached {
                    try PDFOrganizer.organize(files: urls, plan: plan, equalizeWidths: equal, nameSource: nameSource)
                }
                return .outputs([output])
            }
            isSaving = false
            switch result {
            case .success: close()
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }
}

struct PDFOrganizeView: View {
    @StateObject var model: PDFOrganizeModel
    @ObservedObject private var thumbnails: PageThumbnails

    init(model: PDFOrganizeModel) {
        _model = StateObject(wrappedValue: model)
        thumbnails = model.thumbnails
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                if model.files.count > 1 {
                    fileList.frame(width: 230)
                    Divider()
                }
                grid
            }
            Divider()
            footer
        }
        .frame(minWidth: 640, minHeight: 460)
        .onAppear { model.load() }
        .onDisappear { model.thumbnails.cancel() }
        .closesWindowOnCommandW(model.windowID) { model.close() }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button { model.rotateSelection() } label: { Label("Rotate", systemImage: "rotate.right") }
                .keyboardShortcut("r", modifiers: .command)
                .help("Turn the selected pages 90 degrees clockwise (⌘R)")
                .disabled(!model.hasSelection)
            Button { model.duplicateSelection() } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                .keyboardShortcut("d", modifiers: .command)
                .help("Duplicate the selected pages (⌘D)")
                .disabled(!model.hasSelection)
            Button { model.deleteSelection() } label: { Label("Delete", systemImage: "trash") }
                .keyboardShortcut(.delete, modifiers: [])
                .help("Remove the selected pages from the new PDF (Delete)")
                .disabled(!model.hasSelection)
            Divider().frame(height: 18)
            Button { model.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!model.canUndo)
            Button { model.resetOrder() } label: { Label("Reset Order", systemImage: "arrow.counterclockwise") }
                .help("Put every page back in its original order")
                .accessibilityIdentifier("pdfOrganizerResetOrder")
                .disabled(model.isLoading)
            Spacer(minLength: 12)
            Button { model.zoom = max(PDFOrganizeModel.zoomRange.lowerBound, model.zoom - 30) } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("-", modifiers: .command)
            .help("Smaller thumbnails")
            Slider(value: $model.zoom, in: PDFOrganizeModel.zoomRange)
                .frame(width: 130)
                .accessibilityLabel("Thumbnail size")
            Button { model.zoom = min(PDFOrganizeModel.zoomRange.upperBound, model.zoom + 30) } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("=", modifiers: .command)
            .help("Larger thumbnails")
        }
        .labelStyle(.titleAndIcon)
        .controlSize(.regular)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background {
            Button("Select All") { model.selectAll() }
                .keyboardShortcut("a", modifiers: .command)
                .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
        }
    }

    // MARK: Files

    private var fileList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Files")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.top, 10)
            List {
                ForEach(model.fileOrder, id: \.self) { index in
                    HStack(spacing: 8) {
                        Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                        Image(nsImage: NSWorkspace.shared.icon(forFile: model.urls[index].path))
                            .resizable().frame(width: 20, height: 20)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(model.fileName(index)).lineLimit(1).truncationMode(.middle)
                            let count = model.files.first { $0.id == index }?.pageCount ?? 0
                            Text(count == 1 ? "1 page" : "\(count) pages").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .help("Drag to change the order of the files")
                }
                .onMove { model.moveFiles(from: $0, to: $1) }
            }
            .listStyle(.sidebar)
            .accessibilityIdentifier("orderedSourceList")
            Button { model.sortFilesByName() } label: {
                Label("Order the files by name, as Finder lists them", systemImage: "textformat.abc")
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .buttonStyle(.link)
            .font(.callout)
            .padding(12)
            .accessibilityIdentifier("sortSourcesByName")
        }
    }

    // MARK: Grid

    private var grid: some View {
        ScrollView {
            if model.isLoading {
                ProgressView("Loading pages…").padding(40)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: model.zoom + 16), spacing: 14)], spacing: 18) {
                ForEach(Array(model.plan.pages.enumerated()), id: \.element.id) { position, page in
                    pageCell(page, position: position + 1)
                }
            }
            .padding(18)
            .accessibilityIdentifier("pdfOrganizerGrid")
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .contentShape(Rectangle())
        .onTapGesture { model.selection = [] }
        .onDrop(of: [.text], isTargeted: nil) { _ in model.endDrag(); return true }
    }

    private func pageCell(_ page: PlannedPage, position: Int) -> some View {
        let fileName = model.files.count > 1 ? model.fileName(page.file) : nil
        return OrganizePageCell(page: page, position: position, image: thumbnails.images[page.key],
                                fileName: fileName, selected: model.selection.contains(page.id),
                                side: model.zoom, onRotate: { model.rotate(page.id) })
            .onTapGesture { model.click(page.id) }
            .onDrag {
                model.beginDrag(page.id)
                return NSItemProvider(object: page.id.uuidString as NSString)
            }
            .onDrop(of: [.text], delegate: PageDropDelegate(target: page.id, model: model))
    }

    // MARK: Footer

    private var footer: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Make all pages the same width", isOn: $model.equalWidths)
                    .accessibilityIdentifier("pdfOrganizerEqualWidths")
                Text("Pages are scaled proportionally to match the narrowest page; their heights may still differ.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 330, alignment: .leading)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                InlineError(message: model.error)
                Text(status).font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            Button("Cancel") { model.close() }
                .keyboardShortcut(.cancelAction)
            Button {
                model.save()
            } label: {
                if model.isSaving { ProgressView().controlSize(.small).padding(.horizontal, 30) }
                else { Text("Save Organized PDF") }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .buttonStyle(.borderedProminent)
            .disabled(model.isLoading || model.isSaving || model.plan.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var status: String {
        let count = model.plan.count
        let pages = count == 1 ? "1 page" : "\(count) pages"
        return model.selection.isEmpty ? pages : "\(pages), \(model.selection.count) selected"
    }
}

/// One page in the organizer grid.
struct OrganizePageCell: View {
    let page: PlannedPage
    let position: Int
    let image: CGImage?
    let fileName: String?
    let selected: Bool
    let side: CGFloat
    let onRotate: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 5) {
            PageThumbnailView(image: image, rotation: page.rotation, side: side)
                .padding(7)
                .background(RoundedRectangle(cornerRadius: 9).fill(selected ? Color.accentColor.opacity(0.2) : .clear))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2.5))
                .overlay(alignment: .topTrailing) {
                    if hovering {
                        Button(action: onRotate) {
                            Image(systemName: "rotate.right")
                                .font(.system(size: 12, weight: .semibold))
                                .padding(6)
                                .background(.regularMaterial, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .help("Rotate 90 degrees clockwise")
                        .padding(4)
                        .accessibilityIdentifier("pdfOrganizerRotatePage")
                    }
                }
            Text("\(position)")
                .font(.callout.weight(.semibold))
                .monospacedDigit()
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: side + 14)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help("Drag to change its position, or use Rotate to turn it clockwise")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var caption: String {
        var text = fileName.map { "\($0), page \(page.page + 1)" } ?? "Originally page \(page.page + 1)"
        if page.rotation != 0 { text += " · \(page.rotation)°" }
        return text
    }

    private var accessibilityText: String {
        var text = "Page \(position), originally page \(page.page + 1)"
        if let fileName { text += " of \(fileName)" }
        if page.rotation != 0 { text += ", rotated \(page.rotation) degrees clockwise" }
        return text
    }
}

/// Live reordering while a page is dragged over the others.
struct PageDropDelegate: DropDelegate {
    let target: UUID
    let model: PDFOrganizeModel

    func dropEntered(info: DropInfo) {
        MainActor.assumeIsolated { model.dragEntered(target) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated { model.endDrag() }
        return true
    }
}

enum PDFOrganizeWindow {
    @MainActor
    static func open(_ files: [URL]) {
        let id = PDFWindowID.make("pdf.organize", files)
        let title = "Organize " + describeFiles(files)
        let model = PDFOrganizeModel(urls: files, windowID: id)
        AppServices.shared.presentWindow(id: id, title: title, size: CGSize(width: 980, height: 680)) {
            PDFOrganizeView(model: model)
        }
    }
}
