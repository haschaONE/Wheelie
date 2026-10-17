import AppKit
import SwiftUI
import WheelieCore

@MainActor
final class RedactModel: ObservableObject {
    let url: URL
    let windowID: String
    let zoom = CanvasZoom()

    @Published private(set) var source: SourceImage?
    @Published private(set) var preview: CGImage?
    @Published private(set) var formatLabel = ""
    @Published var loadError: String?
    @Published var error: String?
    @Published var busy = false
    @Published var rects: [RedactionRect] = []
    @Published var selection: UUID?
    @Published var style: RedactionStyle = .blackBox { didSet { prepareEffect() } }
    @Published private(set) var effects: [RedactionStyle: CGImage] = [:]
    @Published private(set) var detecting: RedactionDetector.Kind?
    @Published var detectionMessage: String?
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    private var undoStack: [[RedactionRect]] = []
    private var redoStack: [[RedactionRect]] = []

    private enum Drag {
        case move(UUID, CGRect, CGPoint, moved: Bool)
        case resize(UUID, CropHandle, changed: Bool)
        case create(CGPoint, UUID?)
    }
    private var drag: Drag?

    init(url: URL, windowID: String) {
        self.url = url
        self.windowID = windowID
    }

    func load() async {
        guard source == nil else { return }
        do {
            let (source, preview) = try await ImageEditorUI.load(url, previewSize: 2000)
            self.source = source
            self.preview = preview
            formatLabel = await ImageEditorUI.formatLabel(for: source, preview: preview)
            if isMultiFrame { error = "Redact one still photo at a time. Export the frames or pages first." }
            prepareEffect()
        } catch {
            loadError = error.localizedDescription
        }
    }

    var isMultiFrame: Bool { (source?.frameCount ?? 1) > 1 }
    var imageSize: CGSize { source?.size ?? CGSize(width: 1, height: 1) }
    var bounds: CGRect { CGRect(origin: .zero, size: imageSize) }

    private func index(of id: UUID?) -> Int? {
        guard let id else { return nil }
        return rects.firstIndex { $0.id == id }
    }

    var selectedRect: RedactionRect? { index(of: selection).map { rects[$0] } }

    /// Whole-photo blur/pixelation at preview size, shown through each rectangle.
    private func prepareEffect() {
        guard let preview, style != .blackBox, effects[style] == nil else { return }
        let current = style
        Task {
            let image = await Task.detached(priority: .userInitiated) { Redactor.effectImage(preview, style: current) }.value
            if let image { effects[current] = image }
        }
    }

    // MARK: Undo

    private func checkpoint() {
        undoStack.append(rects)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
        canUndo = true
        canRedo = false
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(rects)
        rects = previous
        if index(of: selection) == nil { selection = nil }
        canUndo = !undoStack.isEmpty
        canRedo = true
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(rects)
        rects = next
        if index(of: selection) == nil { selection = nil }
        canUndo = true
        canRedo = !redoStack.isEmpty
    }

    func deleteSelection() {
        guard let i = index(of: selection) else { return }
        checkpoint()
        rects.remove(at: i)
        selection = nil
    }

    func removeAll() {
        guard !rects.isEmpty else { return }
        checkpoint()
        rects.removeAll()
        selection = nil
    }

    // MARK: Canvas interaction (pixel coordinates)

    func dragChanged(start: CGPoint, current: CGPoint, handleRadius: CGFloat, minSize: CGFloat) {
        if drag == nil {
            if let sel = selectedRect, let handle = CropHandle.hit(start, rect: sel.rect, radius: handleRadius) {
                drag = .resize(sel.id, handle, changed: false)
            } else if let hit = rects.lastIndex(where: { $0.rect.insetBy(dx: -handleRadius / 2, dy: -handleRadius / 2).contains(start) }) {
                selection = rects[hit].id
                drag = .move(rects[hit].id, rects[hit].rect, start, moved: false)
            } else {
                selection = nil
                drag = .create(start, nil)
            }
        }
        switch drag {
        case .move(let id, let original, let origin, let moved):
            let d = CGSize(width: current.x - origin.x, height: current.y - origin.y)
            if !moved {
                guard hypot(d.width, d.height) >= handleRadius / 4 else { return }
                checkpoint()
                drag = .move(id, original, origin, moved: true)
            }
            if let i = index(of: id) { rects[i].rect = CropGeometry.move(original, by: d, in: bounds) }
        case .resize(let id, let handle, let changed):
            guard let i = index(of: id) else { return }
            if !changed {
                checkpoint()
                drag = .resize(id, handle, changed: true)
            }
            rects[i].rect = CropGeometry.resize(rects[i].rect, handle: handle, to: current, ratio: nil, in: bounds, minSize: minSize)
        case .create(let origin, let id):
            let rect = CropGeometry.spanning(from: origin, to: current, ratio: nil, in: bounds)
            if let i = index(of: id) {
                rects[i].rect = rect
            } else if rect.width >= minSize && rect.height >= minSize {
                checkpoint()
                let item = RedactionRect(rect: rect)
                rects.append(item)
                selection = item.id
                drag = .create(origin, item.id)
            }
        case nil:
            break
        }
    }

    func dragEnded() { drag = nil }

    func cursor(at p: CGPoint, handleRadius: CGFloat) -> NSCursor {
        if let sel = selectedRect, let handle = CropHandle.hit(p, rect: sel.rect, radius: handleRadius) {
            if handle.isCorner { return .crosshair }
            return handle.movesLeft || handle.movesRight ? .resizeLeftRight : .resizeUpDown
        }
        return rects.contains { $0.rect.contains(p) } ? .openHand : .crosshair
    }

    func handleKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty, let i = index(of: selection) else { return false }
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        let delta: CGSize
        switch event.keyCode {
        case 123: delta = CGSize(width: -step, height: 0)
        case 124: delta = CGSize(width: step, height: 0)
        case 125: delta = CGSize(width: 0, height: step)
        case 126: delta = CGSize(width: 0, height: -step)
        default: return false
        }
        rects[i].rect = CropGeometry.move(rects[i].rect, by: delta, in: bounds)
        return true
    }

    // MARK: Detection

    func detect(_ kind: RedactionDetector.Kind) {
        guard let source, detecting == nil else { return }
        detecting = kind
        detectionMessage = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try RedactionDetector.detect(kind, in: source.image) }
            }.value
            detecting = nil
            let noun = kind == .faces ? "face" : "text area"
            switch result {
            case .success(let found):
                let new = RedactionDetector.newRects(found, excluding: rects.map(\.rect))
                if found.isEmpty {
                    detectionMessage = kind == .faces ? "No faces found." : "No text found."
                } else if new.isEmpty {
                    detectionMessage = found.count == 1 ? "The \(noun) found is already covered."
                                                        : "All \(found.count) \(noun)s found are already covered."
                } else {
                    checkpoint()
                    rects += new.map { RedactionRect(rect: $0) }
                    detectionMessage = "Added \(new.count) \(noun)\(new.count == 1 ? "" : "s"). Check the edges before saving."
                }
            case .failure(let failure):
                detectionMessage = "Could not detect \(kind == .faces ? "faces" : "text"): \(failure.localizedDescription)"
            }
        }
    }

    // MARK: Export

    func close() { AppServices.shared.closeWindow(id: windowID) }

    func export() {
        guard let source, !busy else { return }
        guard !isMultiFrame else {
            error = "Redact one still photo at a time. Export the frames or pages first."
            return
        }
        guard !rects.isEmpty else {
            error = "Draw a rectangle over the area to hide."
            return
        }
        let settings = RedactSettings(rects: rects, style: style)
        busy = true
        error = nil
        Task {
            error = await ImageEditorUI.runExport("Redact", sources: [url], windowID: windowID) {
                let image = try await Task.detached(priority: .userInitiated) {
                    try Redactor.render(source.image, settings)
                }.value
                // Metadata (location, camera, embedded thumbnails) is left out on purpose.
                return [try await ImageToolsIO.export(image, source: source, suffix: " redact", preserveMetadata: false)]
            }
            busy = false
        }
    }
}

struct RedactEditorView: View {
    static func open(_ url: URL) {
        let id = "image.redact:" + url.path
        AppServices.shared.presentWindow(id: id, title: ImageEditorUI.title("Redact", [url]), size: ImageEditorUI.windowSize) {
            RedactEditorView(url: url, windowID: id)
        }
    }

    @StateObject private var model: RedactModel

    init(url: URL, windowID: String) {
        _model = StateObject(wrappedValue: RedactModel(url: url, windowID: windowID))
    }

    var body: some View {
        EditorChrome(status: status, error: model.error, busy: model.busy, exportTitle: "Export",
                     canExport: model.source != nil && !model.rects.isEmpty && !model.isMultiFrame,
                     onCancel: model.close, onExport: model.export) {
            toolbar
        } canvas: {
            if let preview = model.preview {
                ZoomableCanvas(imageSize: model.imageSize, zoom: model.zoom) { size in
                    RedactCanvas(model: model, zoom: model.zoom, preview: preview, displaySize: size)
                }
            } else {
                CanvasPlaceholder(error: model.loadError)
            }
        } sidebar: {
            sidebar
        }
        .background(EditorKeyMonitor(keys: EditorKeys(export: model.export, close: model.close, delete: model.deleteSelection,
                                                      undo: model.undo, redo: model.redo, zoom: model.zoom,
                                                      other: model.handleKey)))
        .task { await model.load() }
    }

    private var status: String? {
        guard model.source != nil else { return nil }
        let n = model.rects.count
        return n == 0 ? "Draw rectangles to cover areas." : "\(n) area\(n == 1 ? "" : "s") · \(model.formatLabel)"
    }

    @ViewBuilder private var toolbar: some View {
        Picker("Style", selection: $model.style) {
            ForEach(RedactionStyle.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .frame(width: 260)
        .labelsHidden()
        Divider().frame(height: 18)
        Group {
            Button { model.detect(.faces) } label: { Label("Faces", systemImage: "face.smiling") }
                .help("Find faces and cover them")
            Button { model.detect(.text) } label: { Label("Text", systemImage: "text.viewfinder") }
                .help("Find text and cover it")
        }
        .disabled(model.source == nil || model.detecting != nil)
        Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
            .buttonStyle(.borderless)
            .help("Undo (⌘Z)")
            .disabled(!model.canUndo)
        Button { model.deleteSelection() } label: { Image(systemName: "trash") }
            .buttonStyle(.borderless)
            .help("Delete Redaction (Delete)")
            .disabled(model.selection == nil)
        Spacer()
        ZoomControls(zoom: model.zoom)
    }

    @ViewBuilder private var sidebar: some View {
        SidebarSection("Style") {
            Picker("Style", selection: $model.style) {
                ForEach(RedactionStyle.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            Text(styleNote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        SidebarSection("Find Automatically") {
            HStack {
                Button { model.detect(.faces) } label: { Label("Find Faces", systemImage: "face.smiling") }
                Button { model.detect(.text) } label: { Label("Find Text", systemImage: "text.viewfinder") }
            }
            .disabled(model.source == nil || model.detecting != nil)
            if let kind = model.detecting {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(kind == .faces ? "Looking for faces…" : "Looking for text…").font(.caption)
                }
            } else if let message = model.detectionMessage {
                Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        SidebarSection("Areas") {
            Text(model.rects.isEmpty ? "Drag on the photo to draw a rectangle over the area to hide."
                                     : "\(model.rects.count) area\(model.rects.count == 1 ? "" : "s"). Drag to move, drag the handles to resize.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Delete Selected") { model.deleteSelection() }.disabled(model.selection == nil)
                Button("Remove All") { model.removeAll() }.disabled(model.rects.isEmpty)
            }
        }
        SidebarSection("Privacy") {
            Text("The saved copy permanently replaces the covered pixels and leaves out metadata such as location and camera details. The original stays unchanged.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var styleNote: String {
        switch model.style {
        case .blackBox: return "Covers each area with solid black. Best for sensitive information."
        case .blur: return "Blur softens details. Use Black Box for sensitive information."
        case .pixelate: return "Replaces each area with large blocks of color."
        }
    }
}

private struct RedactCanvas: View {
    @ObservedObject var model: RedactModel
    @ObservedObject var zoom: CanvasZoom
    let preview: CGImage
    let displaySize: CGSize

    var body: some View {
        let s = displaySize.width / max(model.imageSize.width, 1)
        let mag = max(zoom.magnification, 0.1)
        let hitRadius = (10 / mag) / s
        let shapes = Path { p in for r in model.rects { p.addRect(r.rect.scaled(by: s)) } }
        ZStack(alignment: .topLeading) {
            Image(decorative: preview, scale: 1)
                .resizable()
                .interpolation(s > 1.5 ? .none : .high)
                .frame(width: displaySize.width, height: displaySize.height)
            if model.style == .blackBox {
                shapes.fill(Color.black)
            } else if let effect = model.effects[model.style] {
                Image(decorative: effect, scale: 1)
                    .resizable()
                    .frame(width: displaySize.width, height: displaySize.height)
                    .mask(shapes.fill(Color.black))
            } else {
                shapes.fill(Color.gray.opacity(0.8))
            }
            shapes.stroke(Color.white.opacity(0.8), style: StrokeStyle(lineWidth: 1 / mag, dash: [4 / mag, 3 / mag]))
            if let selected = model.selectedRect {
                let rect = selected.rect.scaled(by: s)
                Path(rect).stroke(Color.accentColor, lineWidth: 2 / mag)
                ForEach(CropHandle.allCases, id: \.self) { h in
                    Circle()
                        .fill(Color.white)
                        .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 1 / mag))
                        .frame(width: 9 / mag, height: 9 / mag)
                        .position(h.point(in: rect))
                }
            }
        }
        .frame(width: displaySize.width, height: displaySize.height)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    model.dragChanged(start: v.startLocation.scaled(by: 1 / s), current: v.location.scaled(by: 1 / s),
                                      handleRadius: hitRadius, minSize: max(2, (6 / mag) / s))
                }
                .onEnded { _ in model.dragEnded() }
        )
        .onContinuousHover { phase in
            switch phase {
            case .active(let p): model.cursor(at: p.scaled(by: 1 / s), handleRadius: hitRadius).set()
            case .ended: NSCursor.arrow.set()
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Redaction preview. Draw rectangles to cover areas.")
    }
}
