import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WheelieCore

@MainActor
final class CollageModel: ObservableObject {
    struct Item: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        let thumbnail: CGImage
        /// nil = the collage's default (fill or fit).
        var fill: Bool?

        var name: String { url.lastPathComponent }
    }

    enum Format: String, CaseIterable, Identifiable {
        case png = "PNG", jpeg = "JPG"
        var id: String { rawValue }
    }

    static let previewWidth: CGFloat = 1400
    static let widths = [1024, 2048, 3072, 4096]

    let urls: [URL]
    let windowID: String
    let zoom = CanvasZoom()

    @Published var items: [Item] = [] { didSet { if items != oldValue { renderPreview() } } }
    @Published var settings = CollageSettings() { didSet { if settings != oldValue { renderPreview() } } }
    @Published var format: Format = .png
    @Published private(set) var preview: CGImage?
    @Published private(set) var layout: CollageLayoutResult?
    @Published private(set) var loading = true
    @Published var loadError: String?
    @Published var error: String?
    @Published var busy = false
    @Published var dropTarget: UUID?

    private var rendering = false
    private var pending = false

    init(urls: [URL], windowID: String) {
        self.urls = urls
        self.windowID = windowID
    }

    func load() async {
        guard items.isEmpty else { return }
        let urls = self.urls
        let loaded = await Task.detached(priority: .userInitiated) { () -> [(URL, CGImage?)] in
            urls.map { url in (url, try? ImageToolsIO.loadThumbnail(url, maxPixelSize: 900)) }
        }.value
        let failed = loaded.filter { $0.1 == nil }.map { $0.0.lastPathComponent }
        let good = loaded.compactMap { url, thumb in thumb.map { Item(url: url, thumbnail: $0) } }
        loading = false
        if good.count < 2 {
            loadError = "Couldn't read enough images for a collage" + (failed.isEmpty ? "." : ": \(failed.joined(separator: ", ")).")
            return
        }
        if !failed.isEmpty { error = "Skipped unreadable images: \(failed.joined(separator: ", "))." }
        items = good
    }

    var effectiveSettings: CollageSettings {
        var s = settings
        s.fillOverrides = [:]
        for (i, item) in items.enumerated() { if let fill = item.fill { s.fillOverrides[i] = fill } }
        return s
    }

    var transparentBackground: Bool { settings.background.alpha < 1 }
    var effectiveFormat: Format { transparentBackground ? .png : format }

    private func renderPreview() {
        guard items.count >= 2 else { preview = nil; layout = nil; return }
        if rendering { pending = true; return }
        rendering = true
        let thumbs = items.map(\.thumbnail)
        let s = effectiveSettings
        let scale = Self.previewWidth / CGFloat(max(s.outputWidth, 1))
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<(CGImage, CollageLayoutResult), Error> in
                Result {
                    let layout = try CollageLayout.layout(aspects: thumbs.map { CGFloat($0.width) / CGFloat(max($0.height, 1)) },
                                                          settings: s)
                    return (try CollageRenderer.render(thumbs, s, scale: scale), layout)
                }
            }.value
            switch result {
            case .success(let (image, layout)):
                preview = image
                self.layout = layout
                if !busy, let e = error, e.hasPrefix("Choose") || e.hasPrefix("The collage") { error = nil }
            case .failure(let failure):
                error = failure.localizedDescription
            }
            rendering = false
            if pending {
                pending = false
                renderPreview()
            }
        }
    }

    // MARK: Editing

    /// Changing the output width keeps the look: spacing, margin and corners scale along.
    func setOutputWidth(_ width: Int) {
        guard width != settings.outputWidth else { return }
        let f = Double(width) / Double(settings.outputWidth)
        var s = settings
        s.spacing = (s.spacing * f).rounded()
        s.margin = (s.margin * f).rounded()
        s.cornerRadius = (s.cornerRadius * f).rounded()
        s.outputWidth = width
        settings = s
    }

    func move(_ idString: String?, onto target: UUID) {
        guard let idString, let id = UUID(uuidString: idString),
              let from = items.firstIndex(where: { $0.id == id }),
              let to = items.firstIndex(where: { $0.id == target }), from != to else { return }
        let item = items.remove(at: from)
        items.insert(item, at: to)
    }

    func move(_ id: UUID, by offset: Int) {
        guard let from = items.firstIndex(where: { $0.id == id }) else { return }
        let to = min(max(from + offset, 0), items.count - 1)
        guard to != from else { return }
        let item = items.remove(at: from)
        items.insert(item, at: to)
    }

    func setFill(_ fill: Bool?, for id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].fill = fill
    }

    func remove(_ id: UUID) {
        guard items.count > 2 else { return }
        items.removeAll { $0.id == id }
    }

    func sortByName() {
        items.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func reverse() { items.reverse() }

    func close() { AppServices.shared.closeWindow(id: windowID) }

    // MARK: Export

    func export() {
        guard !busy else { return }
        guard items.count >= 2 else {
            error = "Add at least two images."
            return
        }
        let s = effectiveSettings
        let sources = items.map(\.url)
        let format = effectiveFormat
        busy = true
        error = nil
        Task {
            error = await ImageEditorUI.runExport("Collage", sources: sources, windowID: windowID) {
                let url = try await Task.detached(priority: .userInitiated) { () -> URL in
                    let image = try Self.renderFullSize(sources, settings: s)
                    let output = OutputNaming.uniqueURL(for: sources[0], ext: format == .png ? "png" : "jpg", suffix: " collage")
                    try ImageToolsIO.write(image, to: output, type: format == .png ? .png : .jpeg)
                    return output
                }.value
                return [url]
            }
            busy = false
        }
    }

    /// Lays out with the originals' shapes and decodes each photo only as large as its cell needs.
    nonisolated static func renderFullSize(_ urls: [URL], settings s: CollageSettings) throws -> CGImage {
        let sizes = urls.map { ImageToolsIO.pixelSize(of: $0) ?? CGSize(width: 1, height: 1) }
        let layout = try CollageLayout.layout(aspects: sizes.map { $0.width / max($0.height, 1) }, settings: s)
        var images: [CGImage] = []
        for (i, url) in urls.enumerated() {
            let size = sizes[i], cell = layout.cells[i]
            let drawn = s.fills(i) ? FrameRenderer.aspectFill(size, in: cell) : FrameRenderer.aspectFit(size, in: cell)
            let needed = Int(max(drawn.width, drawn.height).rounded(.up)) + 2
            images.append(try ImageToolsIO.loadThumbnail(url, maxPixelSize: min(needed, Int(max(size.width, size.height)))))
        }
        let wide = images.contains { $0.colorSpace?.isWideGamutRGB == true }
        let space = CGColorSpace(name: wide ? CGColorSpace.displayP3 : CGColorSpace.sRGB)!
        return try CollageRenderer.render(images, s, colorSpace: space)
    }
}

struct CollageEditorView: View {
    static let maxImages = 40

    static func open(_ urls: [URL]) {
        let id = "image.collage:" + urls.map(\.path).joined(separator: "|")
        AppServices.shared.presentWindow(id: id, title: ImageEditorUI.title("Collage", urls), size: CGSize(width: 1180, height: 780)) {
            CollageEditorView(urls: urls, windowID: id)
        }
    }

    @StateObject private var model: CollageModel

    init(urls: [URL], windowID: String) {
        _model = StateObject(wrappedValue: CollageModel(urls: urls, windowID: windowID))
    }

    var body: some View {
        EditorChrome(status: status, error: model.error, busy: model.busy, canExport: model.items.count >= 2 && model.layout != nil,
                     onCancel: model.close, onExport: model.export) {
            toolbar
        } canvas: {
            if let preview = model.preview {
                ZoomableCanvas(imageSize: CGSize(width: preview.width, height: preview.height), zoom: model.zoom) { size in
                    CollageCanvas(model: model, preview: preview, displaySize: size)
                }
            } else if model.loading || model.loadError != nil {
                CanvasPlaceholder(error: model.loadError)
            } else {
                ProgressView()
            }
        } sidebar: {
            sidebar
        }
        .background(EditorKeyMonitor(keys: EditorKeys(export: model.export, close: model.close, zoom: model.zoom)))
        .task { await model.load() }
    }

    private var status: String? {
        guard let layout = model.layout else { return nil }
        return "\(model.items.count) images · \(Int(layout.canvas.width)) × \(Int(layout.canvas.height)) px · \(model.effectiveFormat.rawValue)"
    }

    private static func symbol(_ kind: CollageLayoutKind) -> String {
        switch kind {
        case .grid: return "square.grid.2x2"
        case .rows: return "rectangle.split.1x2"
        case .columns: return "rectangle.split.2x1"
        case .featured: return "square.split.bottomrightquarter"
        }
    }

    @ViewBuilder private var toolbar: some View {
        HStack(spacing: 2) {
            ForEach(CollageLayoutKind.allCases) { kind in
                Button { model.settings.layout = kind } label: {
                    Label(kind.label, systemImage: Self.symbol(kind))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill(model.settings.layout == kind ? Color.accentColor : Color.clear))
                        .foregroundStyle(model.settings.layout == kind ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
                .help("\(kind.label) layout")
            }
        }
        Divider().frame(height: 18)
        Button { model.sortByName() } label: { Image(systemName: "textformat.abc") }
            .buttonStyle(.borderless)
            .help("Order the images by name, as Finder lists them")
        Button { model.reverse() } label: { Image(systemName: "arrow.left.arrow.right") }
            .buttonStyle(.borderless)
            .help("Reverse the order")
        Spacer()
        ZoomControls(zoom: model.zoom)
    }

    private var columnsBinding: Binding<Int> {
        Binding(get: { model.settings.columns }, set: { model.settings.columns = min(max($0, 0), 8) })
    }

    @ViewBuilder private var sidebar: some View {
        SidebarSection("Layout") {
            Picker("Layout", selection: $model.settings.layout) {
                ForEach(CollageLayoutKind.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            if model.settings.layout == .grid {
                Stepper(value: columnsBinding, in: 0...8) {
                    Text("Columns: \(model.settings.columns == 0 ? "Auto" : "\(model.settings.columns)")")
                }
            }
            if model.settings.layout == .grid || model.settings.layout == .featured {
                Text("Canvas").font(.callout)
                ChoiceGrid(items: CanvasRatio.allCases, label: { $0.label }, selection: $model.settings.canvasRatio)
            } else {
                Text("Rows and Columns keep every photo's shape and size the canvas to fit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        SidebarSection("Cells") {
            Picker("Cells", selection: $model.settings.fillCells) {
                Text("Fill cells (crop edges)").tag(true)
                Text("Fit whole images").tag(false)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .disabled(model.settings.layout == .rows || model.settings.layout == .columns)
        }
        SidebarSection("Spacing & background") {
            SliderRow(title: "Spacing", value: $model.settings.spacing, range: 0...Double(model.settings.outputWidth) / 16,
                      defaultValue: 16, format: { "\(Int($0)) px" })
            SliderRow(title: "Margin", value: $model.settings.margin, range: 0...Double(model.settings.outputWidth) / 8,
                      defaultValue: 16, format: { "\(Int($0)) px" })
            SliderRow(title: "Corner radius", value: $model.settings.cornerRadius, range: 0...Double(model.settings.outputWidth) / 16,
                      defaultValue: 0, format: { "\(Int($0)) px" })
            HStack(spacing: 6) {
                ForEach([("White", RGBAColor.white), ("Light Gray", RGBAColor(hex: 0xF2F2F7)),
                         ("Charcoal", RGBAColor(hex: 0x2C2C2E)), ("Black", RGBAColor.black)], id: \.0) { name, color in
                    ColorSwatch(fill: AnyShapeStyle(Color(color)), selected: model.settings.background == color,
                                help: name) { model.settings.background = color }
                }
                ColorSwatch(fill: AnyShapeStyle(Color.gray.opacity(0.12)), selected: model.transparentBackground,
                            help: "Transparent") {
                    model.settings.background = .clear
                }
                .overlay(Image(systemName: "circle.slash").font(.system(size: 13)).foregroundStyle(.secondary)
                    .allowsHitTesting(false))
                ColorPicker("Custom background color", selection: Binding(get: { Color(model.settings.background) },
                                                                          set: { model.settings.background = RGBAColor($0) }),
                            supportsOpacity: true)
                    .labelsHidden()
            }
        }
        SidebarSection("Output") {
            Text("Width in pixels").font(.callout)
            Picker("Width in pixels", selection: Binding(get: { model.settings.outputWidth }, set: { model.setOutputWidth($0) })) {
                ForEach(CollageModel.widths, id: \.self) { Text(verbatim: String($0)).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text("Format").font(.callout)
            Picker("Format", selection: $model.format) {
                ForEach(CollageModel.Format.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .disabled(model.transparentBackground)
            if model.transparentBackground {
                Text("A transparent background is saved as PNG.").font(.caption).foregroundStyle(.secondary)
            }
        }
        SidebarSection("Order") {
            Text("Drag photos in the preview or here to reorder. Right-click a photo to fit or fill it.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 4) {
                ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                    OrderRow(model: model, item: item, index: index)
                }
            }
        }
    }
}

private struct OrderRow: View {
    @ObservedObject var model: CollageModel
    let item: CollageModel.Item
    let index: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
            Image(decorative: item.thumbnail, scale: 1)
                .resizable()
                .scaledToFill()
                .frame(width: 30, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            Text(item.name).lineLimit(1).truncationMode(.middle).font(.callout)
            Spacer(minLength: 2)
            Menu {
                CellModeMenu(model: model, item: item)
            } label: {
                Text(item.fill.map { $0 ? "Fill" : "Fit" } ?? "Auto").font(.caption)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Fit or fill this image's cell")
            Button { model.move(item.id, by: -1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless)
                .disabled(index == 0)
            Button { model.move(item.id, by: 1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless)
                .disabled(index == model.items.count - 1)
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(model.dropTarget == item.id ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.04)))
        .draggable(item.id.uuidString) {
            Image(decorative: item.thumbnail, scale: 1).resizable().scaledToFit().frame(width: 60, height: 60)
        }
        .dropDestination(for: String.self) { ids, _ in
            model.move(ids.first, onto: item.id)
            return true
        } isTargeted: { targeted in
            if targeted { model.dropTarget = item.id } else if model.dropTarget == item.id { model.dropTarget = nil }
        }
    }
}

private struct CellModeMenu: View {
    @ObservedObject var model: CollageModel
    let item: CollageModel.Item

    var body: some View {
        Button("Fill Cell (crop edges)") { model.setFill(true, for: item.id) }
        Button("Fit Whole Image") { model.setFill(false, for: item.id) }
        Button("Use Collage Default") { model.setFill(nil, for: item.id) }
        Divider()
        Button("Move to First") {
            if let first = model.items.first, first.id != item.id { model.move(item.id.uuidString, onto: first.id) }
        }
        Button("Remove from Collage") { model.remove(item.id) }
            .disabled(model.items.count <= 2)
    }
}

private struct CollageCanvas: View {
    @ObservedObject var model: CollageModel
    let preview: CGImage
    let displaySize: CGSize

    var body: some View {
        ZStack(alignment: .topLeading) {
            Image(decorative: preview, scale: 1)
                .resizable()
                .interpolation(.high)
                .frame(width: displaySize.width, height: displaySize.height)
                .background { if model.transparentBackground { Checkerboard() } }
            if let layout = model.layout, layout.cells.count == model.items.count {
                let s = displaySize.width / max(layout.canvas.width, 1)
                ForEach(Array(zip(model.items, layout.cells)), id: \.0.id) { item, cell in
                    let rect = cell.scaled(by: s)
                    Rectangle()
                        .fill(Color.white.opacity(0.001))
                        .overlay(Rectangle().strokeBorder(Color.accentColor, lineWidth: model.dropTarget == item.id ? 3 : 0))
                        .frame(width: max(rect.width, 1), height: max(rect.height, 1))
                        .position(x: rect.midX, y: rect.midY)
                        .help(item.name)
                        .contextMenu { CellModeMenu(model: model, item: item) }
                        .draggable(item.id.uuidString) {
                            Image(decorative: item.thumbnail, scale: 1).resizable().scaledToFit().frame(width: 90, height: 90)
                        }
                        .dropDestination(for: String.self) { ids, _ in
                            model.move(ids.first, onto: item.id)
                            return true
                        } isTargeted: { targeted in
                            if targeted { model.dropTarget = item.id } else if model.dropTarget == item.id { model.dropTarget = nil }
                        }
                }
            }
        }
        .frame(width: displaySize.width, height: displaySize.height)
        .accessibilityLabel("Collage preview")
    }
}
