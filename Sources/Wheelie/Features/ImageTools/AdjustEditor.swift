import AppKit
import SwiftUI
import WheelieCore

@MainActor
final class AdjustModel: ObservableObject {
    let url: URL
    let windowID: String
    let zoom = CanvasZoom()

    @Published private(set) var source: SourceImage?
    @Published private(set) var preview: CGImage?
    @Published private(set) var adjusted: CGImage?
    @Published private(set) var presetThumbnails: [String: CGImage] = [:]
    @Published private(set) var formatLabel = ""
    @Published var settings = AdjustSettings() { didSet { if settings != oldValue { renderPreview() } } }
    @Published var comparing = false
    @Published var loadError: String?
    @Published var error: String?
    @Published var busy = false

    private var rendering = false
    private var pending = false

    init(url: URL, windowID: String) {
        self.url = url
        self.windowID = windowID
    }

    func load() async {
        guard source == nil else { return }
        do {
            let (source, preview) = try await ImageEditorUI.load(url, previewSize: 1800)
            self.source = source
            self.preview = preview
            formatLabel = await ImageEditorUI.formatLabel(for: source, preview: preview)
            renderPreview()
            renderThumbnails(from: preview)
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Pixel radii (sharpening) shrink with the preview so it matches the export.
    private var detailScale: CGFloat {
        guard let source, let preview else { return 1 }
        return CGFloat(preview.width) / CGFloat(max(source.image.width, 1))
    }

    /// Latest-wins rendering on the shared GPU context.
    private func renderPreview() {
        guard let preview else { return }
        if rendering { pending = true; return }
        rendering = true
        let current = settings, scale = detailScale
        Task {
            let output = await Task.detached(priority: .userInitiated) {
                try? ImageAdjust.render(preview, current, detailScale: scale)
            }.value
            adjusted = output
            rendering = false
            if pending {
                pending = false
                renderPreview()
            }
        }
    }

    private func renderThumbnails(from preview: CGImage) {
        Task {
            let thumbs = await Task.detached(priority: .utility) { () -> [String: CGImage] in
                let small = ImageToolsIO.downscaled(preview, maxPixelSize: 180)
                var out: [String: CGImage] = [:]
                for preset in ImageAdjust.presets {
                    out[preset.id] = try? ImageAdjust.render(small, preset.settings, detailScale: 0.1)
                }
                return out
            }.value
            presetThumbnails = thumbs
        }
    }

    var selectedPresetID: String? { ImageAdjust.presets.first { $0.settings == settings }?.id }

    func apply(_ preset: AdjustPreset) { settings = preset.settings }

    func reset() {
        settings = AdjustSettings()
        error = nil
    }

    func close() { AppServices.shared.closeWindow(id: windowID) }

    func export() {
        guard let source, !busy else { return }
        guard !settings.isIdentity else {
            error = "Move a slider or pick a preset first."
            return
        }
        let current = settings
        busy = true
        error = nil
        Task {
            error = await ImageEditorUI.runExport("Adjust", sources: [url], windowID: windowID) {
                let image = try await Task.detached(priority: .userInitiated) {
                    try ImageAdjust.render(source.image, current)
                }.value
                return [try await ImageToolsIO.export(image, source: source, suffix: " adjust")]
            }
            busy = false
        }
    }
}

struct AdjustEditorView: View {
    static func open(_ url: URL) {
        let id = "image.adjust:" + url.path
        AppServices.shared.presentWindow(id: id, title: ImageEditorUI.title("Adjust", [url]), size: ImageEditorUI.windowSize) {
            AdjustEditorView(url: url, windowID: id)
        }
    }

    @StateObject private var model: AdjustModel

    init(url: URL, windowID: String) {
        _model = StateObject(wrappedValue: AdjustModel(url: url, windowID: windowID))
    }

    private struct SliderSpec: Identifiable {
        let title: String
        let key: WritableKeyPath<AdjustSettings, Double>
        var range: ClosedRange<Double> = -1...1
        var format: ((Double) -> String)?
        var id: String { title }
    }

    private static let light: [SliderSpec] = [
        SliderSpec(title: "Exposure", key: \.exposure, range: -2...2, format: { String(format: "%+.2f EV", $0) }),
        SliderSpec(title: "Contrast", key: \.contrast),
        SliderSpec(title: "Brightness", key: \.brightness),
        SliderSpec(title: "Highlights", key: \.highlights),
        SliderSpec(title: "Shadows", key: \.shadows),
    ]
    private static let color: [SliderSpec] = [
        SliderSpec(title: "Saturation", key: \.saturation),
        SliderSpec(title: "Vibrance", key: \.vibrance),
        SliderSpec(title: "Warmth", key: \.warmth),
        SliderSpec(title: "Tint", key: \.tint),
    ]
    private static let detail: [SliderSpec] = [
        SliderSpec(title: "Sharpness", key: \.sharpness, range: 0...1),
        SliderSpec(title: "Vignette", key: \.vignette, range: 0...1),
    ]

    var body: some View {
        EditorChrome(status: status, error: model.error, busy: model.busy, canExport: model.source != nil,
                     onCancel: model.close, onExport: model.export) {
            toolbar
        } canvas: {
            if let preview = model.preview {
                ZoomableCanvas(imageSize: CGSize(width: preview.width, height: preview.height), zoom: model.zoom) { size in
                    AdjustCanvas(model: model, displaySize: size)
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
        guard let source = model.source else { return nil }
        return "\(source.image.width) × \(source.image.height) px · \(model.formatLabel)" + ImageEditorUI.frameNote(source)
    }

    @ViewBuilder private var toolbar: some View {
        CompareButton(comparing: $model.comparing)
            .disabled(model.source == nil)
        Button { model.reset() } label: { Label("Reset", systemImage: "arrow.counterclockwise") }
            .help("Reset all adjustments")
            .disabled(model.settings.isIdentity)
        if model.comparing {
            Text("Original").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
        }
        Spacer()
        ZoomControls(zoom: model.zoom)
    }

    @ViewBuilder private var sidebar: some View {
        SidebarSection("Presets") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 8) {
                ForEach(ImageAdjust.presets) { preset in
                    PresetTile(name: preset.name, thumbnail: model.presetThumbnails[preset.id],
                               selected: model.selectedPresetID == preset.id) { model.apply(preset) }
                }
            }
        }
        sliders("Light", Self.light)
        sliders("Color", Self.color)
        sliders("Detail", Self.detail)
        Text("Double-click a slider's name to reset it. Hold Compare to see the original.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func sliders(_ title: String, _ specs: [SliderSpec]) -> some View {
        SidebarSection(title) {
            ForEach(specs) { spec in
                if let format = spec.format {
                    SliderRow(title: spec.title, value: $model.settings[dynamicMember: spec.key], range: spec.range, format: format)
                } else {
                    SliderRow(title: spec.title, value: $model.settings[dynamicMember: spec.key], range: spec.range)
                }
            }
        }
        .disabled(model.source == nil)
    }
}

/// Shows the original while pressed.
struct CompareButton: View {
    @Binding var comparing: Bool

    var body: some View {
        Label("Compare", systemImage: "square.split.2x1")
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(comparing ? Color.accentColor : Color.primary.opacity(0.08)))
            .foregroundStyle(comparing ? Color.white : Color.primary)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in if !comparing { comparing = true } }
                .onEnded { _ in comparing = false })
            .help("Hold to compare with the original")
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Hold to compare with the original")
    }
}

private struct PresetTile: View {
    let name: String
    let thumbnail: CGImage?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.06))
                    .frame(height: 52)
                    .frame(maxWidth: .infinity)
                    .overlay {
                        if let thumbnail {
                            Image(decorative: thumbnail, scale: 1)
                                .resizable()
                                .scaledToFill()
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
                Text(name).font(.caption).lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .help(name)
    }
}

private struct AdjustCanvas: View {
    @ObservedObject var model: AdjustModel
    let displaySize: CGSize

    var body: some View {
        let image = model.comparing ? model.preview : (model.adjusted ?? model.preview)
        if let image {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.high)
                .frame(width: displaySize.width, height: displaySize.height)
                .background {
                    if ImageCrop.hasAlpha(image) { Checkerboard() }
                }
        }
    }
}
