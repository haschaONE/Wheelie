import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WheelieCore

@MainActor
final class FrameModel: ObservableObject {
    let url: URL
    let windowID: String
    let zoom = CanvasZoom()

    @Published private(set) var source: SourceImage?
    @Published private(set) var rendered: CGImage?
    @Published var loadError: String?
    @Published var error: String?
    @Published var busy = false
    @Published var settings = FrameSettings() { didSet { if settings != oldValue { renderPreview() } } }
    @Published var customColor = RGBAColor(hex: 0x5856D6)
    @Published private(set) var backgroundName: String?

    private var preview: CGImage?
    private var backgroundImage: CGImage?
    private var backgroundPreview: CGImage?
    private var rendering = false
    private var pending = false

    init(url: URL, windowID: String) {
        self.url = url
        self.windowID = windowID
    }

    func load() async {
        guard source == nil else { return }
        do {
            let (source, preview) = try await ImageEditorUI.load(url, previewSize: 1400)
            self.source = source
            self.preview = preview
            renderPreview()
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Preview = the same frame around a downscaled copy (all lengths are relative).
    private func renderPreview() {
        guard let preview else { return }
        if rendering { pending = true; return }
        rendering = true
        var s = settings
        s.scale = 1
        let previewSettings = s
        let background = backgroundPreview
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> Result<CGImage, Error> in
                Result { try FrameRenderer.render(preview, previewSettings, backgroundImage: background) }
            }.value
            switch result {
            case .success(let image):
                rendered = image
                if error != nil && !busy { error = nil }
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

    var outputSize: CGSize? {
        guard let source else { return nil }
        return try? FrameLayout.layout(imageSize: source.size, settings: settings).canvas
    }

    func setBackground(_ background: FrameBackground) { settings.background = background }

    func setCustomColor(_ color: RGBAColor) {
        customColor = color
        settings.background = .solid(color)
    }

    func chooseBackgroundImage() {
        guard let file = ImageEditorUI.chooseImage(message: "Choose an image background") else { return }
        Task {
            do {
                let (full, small) = try await Task.detached(priority: .userInitiated) { () -> (CGImage, CGImage) in
                    let full = try ImageToolsIO.loadThumbnail(file, maxPixelSize: 6000)
                    return (full, ImageToolsIO.downscaled(full, maxPixelSize: 1600))
                }.value
                backgroundImage = full
                backgroundPreview = small
                backgroundName = file.lastPathComponent
                if settings.background == .image { renderPreview() } else { settings.background = .image }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func reset() {
        settings = FrameSettings()
        error = nil
    }

    func close() { AppServices.shared.closeWindow(id: windowID) }

    func export() {
        guard let source, !busy else { return }
        if settings.background == .image && backgroundImage == nil {
            error = "Choose a background image."
            return
        }
        let current = settings, background = backgroundImage
        busy = true
        error = nil
        Task {
            error = await ImageEditorUI.runExport("Frame", sources: [url], windowID: windowID) {
                let image = try await Task.detached(priority: .userInitiated) {
                    try FrameRenderer.render(source.image, current, backgroundImage: background)
                }.value
                return [try await ImageToolsIO.export(image, source: source, suffix: " frame",
                                                      preserveMetadata: false, forceType: .png)]
            }
            busy = false
        }
    }
}

struct FrameEditorView: View {
    static func open(_ url: URL) {
        let id = "image.frame:" + url.path
        AppServices.shared.presentWindow(id: id, title: ImageEditorUI.title("Frame", [url]), size: ImageEditorUI.windowSize) {
            FrameEditorView(url: url, windowID: id)
        }
    }

    @StateObject private var model: FrameModel

    init(url: URL, windowID: String) {
        _model = StateObject(wrappedValue: FrameModel(url: url, windowID: windowID))
    }

    var body: some View {
        EditorChrome(status: status, error: model.error, busy: model.busy, canExport: model.source != nil,
                     onCancel: model.close, onExport: model.export) {
            toolbar
        } canvas: {
            if let image = model.rendered {
                ZoomableCanvas(imageSize: CGSize(width: image.width, height: image.height), zoom: model.zoom) { size in
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: size.width, height: size.height)
                        .background { if model.settings.background == .transparent { Checkerboard() } }
                        .accessibilityLabel("Frame preview")
                }
            } else {
                CanvasPlaceholder(error: model.loadError)
            }
        } sidebar: {
            sidebar
        }
        .background(EditorKeyMonitor(keys: EditorKeys(export: model.export, close: model.close, zoom: model.zoom)))
        .task { await model.load() }
    }

    private var status: String? {
        guard let size = model.outputSize else { return nil }
        return "\(Int(size.width)) × \(Int(size.height)) px · PNG" + ImageEditorUI.frameNote(model.source)
    }

    @ViewBuilder private var toolbar: some View {
        Picker("Canvas", selection: $model.settings.canvasRatio) {
            ForEach(CanvasRatio.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.menu)
        .frame(width: 140)
        .help("Canvas ratio")
        Button { model.reset() } label: { Label("Reset", systemImage: "arrow.counterclockwise") }
            .help("Restore the default frame")
        Spacer()
        ZoomControls(zoom: model.zoom)
    }

    private func gradientFill(_ g: FrameGradient) -> AnyShapeStyle {
        let t = g.angle * .pi / 180
        let dx = cos(t) / 2, dy = sin(t) / 2
        return AnyShapeStyle(LinearGradient(colors: g.colors.map { Color($0) },
                                            startPoint: UnitPoint(x: 0.5 - dx, y: 0.5 - dy),
                                            endPoint: UnitPoint(x: 0.5 + dx, y: 0.5 + dy)))
    }

    @ViewBuilder private var sidebar: some View {
        SidebarSection("Background") {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 6), count: 6), alignment: .leading, spacing: 6) {
                ForEach(FrameLayout.gradients) { g in
                    ColorSwatch(fill: gradientFill(g), selected: model.settings.background == .gradient(g.id),
                                size: 24, help: g.name) { model.setBackground(.gradient(g.id)) }
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 6), count: 7), alignment: .leading, spacing: 6) {
                ForEach(FrameLayout.solids, id: \.name) { solid in
                    ColorSwatch(fill: AnyShapeStyle(Color(solid.color)), selected: model.settings.background == .solid(solid.color),
                                size: 22, help: solid.name) { model.setBackground(.solid(solid.color)) }
                }
            }
            HStack(spacing: 6) {
                ColorPicker("Custom background", selection: Binding(get: { Color(model.customColor) },
                                                                    set: { model.setCustomColor(RGBAColor($0)) }),
                            supportsOpacity: false)
                    .labelsHidden()
                    .help("Choose a custom background color")
                Text("Custom").font(.callout).fixedSize()
                Spacer(minLength: 4)
                Button { model.setBackground(.transparent) } label: { Text("None") }
                    .help("Transparent background")
                Button { model.chooseBackgroundImage() } label: { Label("Image…", systemImage: "photo") }
                    .help("Choose an image background")
            }
            .controlSize(.small)
            if model.settings.background == .image, let name = model.backgroundName {
                HStack {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                    Text(name).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Change") { model.chooseBackgroundImage() }.controlSize(.small)
                        .help("Change image background")
                }
                .font(.caption)
            }
        }
        SidebarSection("Canvas") {
            ChoiceGrid(items: CanvasRatio.allCases, label: { $0.label }, selection: $model.settings.canvasRatio)
            SliderRow(title: "Padding", value: $model.settings.padding, range: 0...0.4, defaultValue: 0.08, format: percent)
            SliderRow(title: "Corner radius", value: $model.settings.cornerRadius, range: 0...0.15, defaultValue: 0.02, format: percent)
        }
        SidebarSection("Shadow") {
            SliderRow(title: "Opacity", value: $model.settings.shadowOpacity, range: 0...1, defaultValue: 0.35, format: percent)
            SliderRow(title: "Blur", value: $model.settings.shadowRadius, range: 0...0.15, defaultValue: 0.03, format: percent)
            SliderRow(title: "Offset", value: $model.settings.shadowOffset, range: 0...0.1, defaultValue: 0.012, format: percent)
        }
        SidebarSection("Size") {
            Picker("Output scale", selection: $model.settings.scale) {
                Text("50%").tag(0.5)
                Text("100%").tag(1.0)
                Text("200%").tag(2.0)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text("Lengths are a share of the photo's longer side. Saved as PNG.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func percent(_ v: Double) -> String {
        v < 0.1 && v > 0 ? String(format: "%.1f%%", v * 100) : "\(Int((v * 100).rounded()))%"
    }
}
