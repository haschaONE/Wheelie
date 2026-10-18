import AppKit
import SwiftUI
import WheelieCore

@MainActor
final class AnnotateModel: ObservableObject {
    enum Tool: String, CaseIterable, Identifiable {
        case select, pen, highlighter, arrow, line, rectangle, ellipse, text, counter, blur

        var id: String { rawValue }
        var kind: AnnotationKind? { AnnotationKind(rawValue: rawValue) }

        var label: String {
            switch self {
            case .select: return "Select"
            case .pen: return "Pen"
            case .highlighter: return "Highlighter"
            case .arrow: return "Arrow"
            case .line: return "Line"
            case .rectangle: return "Rectangle"
            case .ellipse: return "Ellipse"
            case .text: return "Text"
            case .counter: return "Counter"
            case .blur: return "Blur Brush"
            }
        }

        var symbol: String {
            switch self {
            case .select: return "cursorarrow"
            case .pen: return "pencil.tip"
            case .highlighter: return "highlighter"
            case .arrow: return "arrow.up.right"
            case .line: return "line.diagonal"
            case .rectangle: return "rectangle"
            case .ellipse: return "circle"
            case .text: return "textformat"
            case .counter: return "1.circle"
            case .blur: return "drop"
            }
        }

        /// Single-key shortcut.
        var key: String {
            switch self {
            case .select: return "v"
            case .pen: return "p"
            case .highlighter: return "h"
            case .arrow: return "a"
            case .line: return "l"
            case .rectangle: return "r"
            case .ellipse: return "o"
            case .text: return "t"
            case .counter: return "n"
            case .blur: return "b"
            }
        }

        var hint: String {
            switch self {
            case .select: return "Click an annotation to select it, drag to move it. Delete removes it."
            case .pen: return "Drag on the image to draw. Drag a selected stroke to move it."
            case .highlighter: return "Drag over the image to highlight."
            case .arrow: return "Drag from the tail toward the arrowhead. Shift snaps to 45°. Drag an annotation to move it."
            case .line: return "Drag to draw a line. Shift snaps to 45°."
            case .rectangle: return "Drag to draw a rectangle. Shift makes a square."
            case .ellipse: return "Drag to draw an ellipse. Shift makes a circle."
            case .text: return "Click to add a text box, then type in the sidebar. Drag its border to move it and its side handles to change width."
            case .counter: return "Click to add numbered callouts; drag to move them."
            case .blur: return "Paint over details to blur them."
            }
        }
    }

    let url: URL
    let windowID: String
    let zoom = CanvasZoom()

    @Published private(set) var source: SourceImage?
    @Published private(set) var preview: CGImage?
    /// The preview photo with the annotations drawn in (nil while there are none).
    @Published private(set) var annotated: CGImage?
    @Published private(set) var formatLabel = ""
    @Published var loadError: String?
    @Published var error: String?
    @Published var busy = false

    @Published var document = AnnotationDocument() { didSet { renderOverlay() } }
    @Published private(set) var draft: Annotation? { didSet { renderOverlay() } }
    @Published var selection: UUID? { didSet { if selection != oldValue { selectionChanged(from: oldValue) } } }
    @Published var tool: Tool = .arrow { didSet { if tool != oldValue && tool != .select { selection = nil } } }

    @Published var color = RGBAColor(hex: 0xFF3B30) { didSet { applyToSelection("color") { $0.color = self.color } } }
    @Published var lineWidth: Double = 6 {
        didSet { applyToSelection("width", kinds: [.pen, .highlighter, .arrow, .line, .rectangle, .ellipse, .blur]) { $0.lineWidth = self.lineWidth } }
    }
    @Published var filled = false { didSet { applyToSelection("fill", kinds: [.rectangle, .ellipse]) { $0.filled = self.filled } } }
    @Published var fontSize: Double = 36 { didSet { applyToSelection("font", kinds: [.text]) { $0.fontSize = self.fontSize } } }
    @Published var bold = false { didSet { applyToSelection("bold", kinds: [.text]) { $0.bold = self.bold } } }
    @Published var counterSize: Double = 24 { didSet { applyToSelection("counter", kinds: [.counter]) { $0.fontSize = self.counterSize } } }
    /// Bumped to move keyboard focus into the text editor.
    @Published private(set) var focusTextRequest = 0
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    private var undoStack: [[Annotation]] = []
    private var redoStack: [[Annotation]] = []
    private var undoGroup: String?
    private var blurPreview: CGImage?
    private var suppressApply = false

    private enum Interaction {
        case move(UUID, Annotation, CGPoint, moved: Bool)
        case resizeText(UUID, Annotation, leftEdge: Bool, changed: Bool)
        case draw(origin: CGPoint, tolerance: CGFloat)
        case place
        case idle
    }
    private var interaction: Interaction?

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
            let long = max(source.size.width, source.size.height)
            suppressApply = true
            lineWidth = min(max((long / 250).rounded(), 2), 30)
            fontSize = min(max((long / 28).rounded(), 14), 200)
            counterSize = min(max((long / 45).rounded(), 12), 120)
            suppressApply = false
            formatLabel = await ImageEditorUI.formatLabel(for: source, preview: preview)
            blurPreview = await Task.detached(priority: .utility) { AnnotationRenderer.blurredCopy(of: preview) }.value
            renderOverlay()
        } catch {
            loadError = error.localizedDescription
        }
    }

    // MARK: Model helpers

    var imageSize: CGSize { source?.size ?? CGSize(width: 1, height: 1) }
    var scale: CGFloat { document.scale(for: imageSize) }

    private func index(of id: UUID?) -> Int? {
        guard let id else { return nil }
        return document.annotations.firstIndex { $0.id == id }
    }

    var selectedAnnotation: Annotation? { index(of: selection).map { document.annotations[$0] } }

    func bounds(of a: Annotation) -> CGRect { AnnotationGeometry.bounds(a, scale: scale) }
    func textBox(of a: Annotation) -> CGRect { AnnotationGeometry.textRect(a, scale: scale) }

    /// Draws the annotations onto the preview photo itself (not onto a transparent layer), so the
    /// highlighter's multiply blend looks as it will in the saved file.
    private func renderOverlay() {
        guard let preview, source != nil else { annotated = nil; return }
        var marks = document.annotations
        if let draft { marks.append(draft) }
        annotated = marks.isEmpty ? nil : try? AnnotationRenderer.preview(marks, on: preview, imageSize: imageSize,
                                                                           scale: scale, blurSource: blurPreview)
    }

    private func selectionChanged(from old: UUID?) {
        // Drop text boxes left empty.
        if let i = index(of: old), document.annotations[i].kind == .text,
           document.annotations[i].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            document.annotations.remove(at: i)
        }
        guard let a = selectedAnnotation else { return }
        suppressApply = true
        color = a.color
        switch a.kind {
        case .text:
            fontSize = a.fontSize
            bold = a.bold
        case .counter:
            counterSize = a.fontSize
        default:
            lineWidth = a.lineWidth
            filled = a.filled
        }
        suppressApply = false
    }

    private func applyToSelection(_ group: String, kinds: Set<AnnotationKind>? = nil, _ change: (inout Annotation) -> Void) {
        guard !suppressApply, let i = index(of: selection) else { return }
        var a = document.annotations[i]
        guard kinds?.contains(a.kind) ?? true else { return }
        let before = a
        change(&a)
        guard a != before else { return }
        checkpoint("\(group)-\(a.id)")
        document.annotations[i] = a
    }

    var selectedText: String {
        get { selectedAnnotation?.text ?? "" }
        set {
            guard let i = index(of: selection), document.annotations[i].kind == .text else { return }
            checkpoint("text-\(document.annotations[i].id)")
            document.annotations[i].text = newValue
        }
    }

    // MARK: Undo

    private func checkpoint(_ group: String?) {
        if let group, group == undoGroup { return }
        undoStack.append(document.annotations)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
        undoGroup = group
        updateUndoFlags()
    }

    private func updateUndoFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(document.annotations)
        document.annotations = previous
        undoGroup = nil
        if index(of: selection) == nil { selection = nil }
        updateUndoFlags()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(document.annotations)
        document.annotations = next
        undoGroup = nil
        if index(of: selection) == nil { selection = nil }
        updateUndoFlags()
    }

    func deleteSelection() {
        guard let i = index(of: selection) else { return }
        checkpoint(nil)
        document.annotations.remove(at: i)
        selection = nil
    }

    func removeAll() {
        guard !document.annotations.isEmpty else { return }
        checkpoint(nil)
        selection = nil
        document.annotations.removeAll()
    }

    // MARK: Canvas interaction (pixel coordinates)

    func dragChanged(start: CGPoint, current: CGPoint, tolerance: CGFloat, shift: Bool) {
        if interaction == nil { begin(at: start, tolerance: tolerance) }
        switch interaction {
        case .move(let id, let original, let origin, let moved):
            let d = CGSize(width: current.x - origin.x, height: current.y - origin.y)
            if !moved {
                guard hypot(d.width, d.height) >= tolerance / 3 else { return }
                checkpoint(nil)
                interaction = .move(id, original, origin, moved: true)
            }
            var a = original
            a.translate(by: d)
            if let i = index(of: id) { document.annotations[i] = a }

        case .resizeText(let id, let original, let leftEdge, let changed):
            if !changed {
                checkpoint(nil)
                interaction = .resizeText(id, original, leftEdge: leftEdge, changed: true)
            }
            let box = AnnotationGeometry.textRect(original, scale: scale)
            let minWidth = max(20, CGFloat(original.fontSize) * scale)
            var a = original
            if leftEdge {
                let x = min(current.x, box.maxX - minWidth)
                a.points[0].x = x
                a.textWidth = Double((box.maxX - x) / scale)
            } else {
                a.textWidth = Double(max(minWidth, current.x - box.minX) / scale)
            }
            if let i = index(of: id) { document.annotations[i] = a }

        case .draw:
            guard var d = draft else { return }
            if d.kind.isFreehand {
                if let last = d.points.last, hypot(current.x - last.x, current.y - last.y) >= max(0.5, tolerance / 8) {
                    d.points.append(current)
                }
            } else {
                d.points[1] = shift ? constrained(from: d.points[0], to: current, kind: d.kind) : current
            }
            draft = d

        case .place, .idle, nil:
            break
        }
    }

    func dragEnded(at point: CGPoint) {
        defer { interaction = nil }
        switch interaction {
        case .draw(let origin, let tolerance):
            guard let d = draft else { return }
            draft = nil
            if d.isMeaningful(scale: scale) {
                checkpoint(nil)
                document.annotations.append(d)
                if !d.kind.isFreehand { selection = d.id }
            } else if let hit = AnnotationGeometry.topmost(at: origin, in: document.annotations, tolerance: tolerance, scale: scale) {
                // A click (no real stroke) on an annotation selects it.
                selection = document.annotations[hit].id
            }
        case .place:
            if tool == .text { addText(at: point) } else if tool == .counter { addCounter(at: point) }
        default:
            break
        }
    }

    private func begin(at p: CGPoint, tolerance: CGFloat) {
        // Side handles of the selected text box change its width.
        if let a = selectedAnnotation, a.kind == .text {
            let box = textBox(of: a)
            let inRows = p.y >= box.minY - tolerance && p.y <= box.maxY + tolerance
            if inRows && abs(p.x - box.minX) <= tolerance * 1.5 {
                interaction = .resizeText(a.id, a, leftEdge: true, changed: false); return
            }
            if inRows && abs(p.x - box.maxX) <= tolerance * 1.5 {
                interaction = .resizeText(a.id, a, leftEdge: false, changed: false); return
            }
        }
        let hit = AnnotationGeometry.topmost(at: p, in: document.annotations, tolerance: tolerance, scale: scale)
        let freehandTool = tool.kind?.isFreehand == true
        if let hit, tool == .select || !freehandTool || document.annotations[hit].id == selection {
            let a = document.annotations[hit]
            selection = a.id
            if a.kind == .text && tool == .text { focusTextRequest += 1 }
            interaction = .move(a.id, a, p, moved: false)
            return
        }
        switch tool {
        case .select:
            selection = nil
            interaction = .idle
        case .text, .counter:
            interaction = .place
        default:
            guard let kind = tool.kind else { interaction = .idle; return }
            selection = nil
            draft = Annotation(kind: kind, points: kind.isFreehand ? [p] : [p, p], color: color,
                               lineWidth: lineWidth, filled: filled)
            interaction = .draw(origin: p, tolerance: tolerance)
        }
    }

    /// Shift: lines snap to 45°, boxes become squares.
    private func constrained(from s: CGPoint, to e: CGPoint, kind: AnnotationKind) -> CGPoint {
        let dx = e.x - s.x, dy = e.y - s.y
        if kind == .rectangle || kind == .ellipse {
            let side = max(abs(dx), abs(dy))
            return CGPoint(x: s.x + (dx < 0 ? -side : side), y: s.y + (dy < 0 ? -side : side))
        }
        let length = hypot(dx, dy)
        let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
        return CGPoint(x: s.x + cos(angle) * length, y: s.y + sin(angle) * length)
    }

    private func addText(at p: CGPoint) {
        let size = CGFloat(fontSize) * scale
        let width = min(max(imageSize.width - p.x, size * 3), max(size * 8, imageSize.width * 0.3))
        let a = Annotation(kind: .text, points: [CGPoint(x: p.x, y: max(0, p.y - size * 0.6))], color: color,
                           fontSize: fontSize, bold: bold, textWidth: Double(width / scale))
        checkpoint(nil)
        document.annotations.append(a)
        selection = a.id
        focusTextRequest += 1
    }

    private func addCounter(at p: CGPoint) {
        let a = Annotation(kind: .counter, points: [p], color: color, fontSize: counterSize,
                           number: document.nextCounterNumber)
        checkpoint(nil)
        document.annotations.append(a)
        selection = a.id
    }

    func cursor(at p: CGPoint, tolerance: CGFloat) -> NSCursor {
        if let a = selectedAnnotation, a.kind == .text {
            let box = textBox(of: a)
            if p.y >= box.minY - tolerance && p.y <= box.maxY + tolerance
                && (abs(p.x - box.minX) <= tolerance * 1.5 || abs(p.x - box.maxX) <= tolerance * 1.5) {
                return .resizeLeftRight
            }
        }
        if let hit = AnnotationGeometry.topmost(at: p, in: document.annotations, tolerance: tolerance, scale: scale),
           tool == .select || tool.kind?.isFreehand != true || document.annotations[hit].id == selection {
            return .openHand
        }
        switch tool {
        case .select: return .arrow
        case .text: return .iBeam
        default: return .crosshair
        }
    }

    /// Tool letters, arrow-key nudges.
    func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control])
        guard flags.isEmpty else { return false }
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        var delta: CGSize?
        switch event.keyCode {
        case 123: delta = CGSize(width: -step, height: 0)
        case 124: delta = CGSize(width: step, height: 0)
        case 125: delta = CGSize(width: 0, height: step)
        case 126: delta = CGSize(width: 0, height: -step)
        default: break
        }
        if let delta {
            guard let i = index(of: selection) else { return false }
            checkpoint("nudge-\(document.annotations[i].id)")
            document.annotations[i].translate(by: delta)
            return true
        }
        if let key = event.charactersIgnoringModifiers?.lowercased(), let t = Tool.allCases.first(where: { $0.key == key }) {
            tool = t
            return true
        }
        return false
    }

    // MARK: Export

    func close() { AppServices.shared.closeWindow(id: windowID) }

    func export() {
        guard let source, !busy else { return }
        let marks = document.annotations.filter { $0.isMeaningful(scale: scale) }
        guard !marks.isEmpty else {
            error = "Add at least one annotation."
            return
        }
        let doc = AnnotationDocument(annotations: marks, enlarge: document.enlarge)
        busy = true
        error = nil
        Task {
            error = await ImageEditorUI.runExport("Annotate", sources: [url], windowID: windowID) {
                let image = try await Task.detached(priority: .userInitiated) {
                    try AnnotationRenderer.render(source.image, doc)
                }.value
                return [try await ImageToolsIO.export(image, source: source, suffix: " annotate")]
            }
            busy = false
        }
    }
}

struct AnnotateEditorView: View {
    static func open(_ url: URL) {
        let id = "image.annotate:" + url.path
        AppServices.shared.presentWindow(id: id, title: ImageEditorUI.title("Annotate", [url]),
                                         size: CGSize(width: 1180, height: 780)) {
            AnnotateEditorView(url: url, windowID: id)
        }
    }

    @StateObject private var model: AnnotateModel
    @FocusState private var textFocused: Bool

    init(url: URL, windowID: String) {
        _model = StateObject(wrappedValue: AnnotateModel(url: url, windowID: windowID))
    }

    var body: some View {
        EditorChrome(status: status, error: model.error, busy: model.busy, exportTitle: "Export",
                     canExport: model.source != nil && !model.document.annotations.isEmpty,
                     onCancel: model.close, onExport: model.export) {
            toolbar
        } canvas: {
            if let preview = model.preview {
                ZoomableCanvas(imageSize: model.imageSize, zoom: model.zoom) { size in
                    AnnotateCanvas(model: model, zoom: model.zoom, preview: preview, displaySize: size)
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
        .onChange(of: model.focusTextRequest) { _, _ in textFocused = true }
        .task { await model.load() }
    }

    private var status: String? {
        guard let source = model.source else { return nil }
        let n = model.document.annotations.count
        return "\(n) annotation\(n == 1 ? "" : "s") · \(source.image.width) × \(source.image.height) px · \(model.formatLabel)" + ImageEditorUI.frameNote(source)
    }

    @ViewBuilder private var toolbar: some View {
        HStack(spacing: 2) {
            ForEach(AnnotateModel.Tool.allCases) { tool in
                Button { model.tool = tool } label: {
                    Image(systemName: tool.symbol)
                        .font(.system(size: 14))
                        .frame(width: 30, height: 26)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill(model.tool == tool ? Color.accentColor : Color.clear))
                        .foregroundStyle(model.tool == tool ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
                .help("\(tool.label) (\(tool.key.uppercased()))")
                .accessibilityLabel(tool.label)
            }
        }
        Divider().frame(height: 18)
        Group {
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .help("Undo last annotation (⌘Z)")
                .disabled(!model.canUndo)
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .help("Redo (⇧⌘Z)")
                .disabled(!model.canRedo)
            Button { model.deleteSelection() } label: { Image(systemName: "trash") }
                .help("Delete selected annotation (Delete)")
                .disabled(model.selection == nil)
        }
        .buttonStyle(.borderless)
        .font(.system(size: 14))
        Spacer()
        ZoomControls(zoom: model.zoom)
    }

    private var editingKind: AnnotationKind? { model.selectedAnnotation?.kind ?? model.tool.kind }

    @ViewBuilder private var sidebar: some View {
        SidebarSection(model.selectedAnnotation.map { "Selected \(AnnotateModel.Tool(rawValue: $0.kind.rawValue)?.label ?? "")" }
                       ?? model.tool.label) {
            Text(model.tool.hint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if editingKind != .blur {
            SidebarSection("Color") {
                ColorPaletteRow(color: $model.color)
            }
        }
        if let kind = editingKind, kind != .text, kind != .counter {
            SidebarSection(kind == .blur ? "Brush" : "Stroke") {
                SliderRow(title: "Width", value: $model.lineWidth, range: 1...80, defaultValue: 6,
                          format: { "\(Int($0.rounded())) px" })
                if kind == .rectangle || kind == .ellipse {
                    Toggle("Fill shape", isOn: $model.filled)
                }
            }
        }
        if editingKind == .text {
            SidebarSection("Text") {
                if model.selectedAnnotation?.kind == .text {
                    TextEditor(text: $model.selectedText)
                        .font(.body)
                        .frame(height: 76)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15)))
                        .focused($textFocused)
                        .accessibilityLabel("Text annotation")
                } else {
                    Text("Click the photo to add a text box.").font(.caption).foregroundStyle(.secondary)
                }
                SliderRow(title: "Font size", value: $model.fontSize, range: 8...300, defaultValue: 36,
                          format: { "\(Int($0.rounded())) px" })
                Toggle("Bold", isOn: $model.bold)
            }
        }
        if editingKind == .counter {
            SidebarSection("Counter") {
                SliderRow(title: "Size", value: $model.counterSize, range: 8...200, defaultValue: 24,
                          format: { "\(Int($0.rounded())) px" })
                Text("Next number: \(model.document.nextCounterNumber)").font(.caption).foregroundStyle(.secondary)
            }
        }
        SidebarSection("Options") {
            Toggle("Make drawn annotations a little larger", isOn: $model.document.enlarge)
                .help("Scales strokes, text and counters with the photo's size")
            Text("Scales strokes, text and counters with the photo's size, so they stay visible on large photos.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        SidebarSection("Edit") {
            HStack {
                Button("Undo") { model.undo() }.disabled(!model.canUndo)
                Button("Redo") { model.redo() }.disabled(!model.canRedo)
            }
            HStack {
                Button("Delete Selected") { model.deleteSelection() }.disabled(model.selection == nil)
                Button("Clear All") { model.removeAll() }
                    .disabled(model.document.annotations.isEmpty)
                    .help("Remove all drawn strokes")
            }
        }
        .disabled(model.source == nil)
    }
}

private struct AnnotateCanvas: View {
    @ObservedObject var model: AnnotateModel
    @ObservedObject var zoom: CanvasZoom
    let preview: CGImage
    let displaySize: CGSize

    var body: some View {
        let s = displaySize.width / max(model.imageSize.width, 1)
        let mag = max(zoom.magnification, 0.1)
        let tolerance = (6 / mag) / s
        ZStack(alignment: .topLeading) {
            Image(decorative: model.annotated ?? preview, scale: 1)
                .resizable()
                .interpolation(s > 1.5 ? .none : .high)
                .frame(width: displaySize.width, height: displaySize.height)
            if let selected = model.selectedAnnotation {
                selection(for: selected, s: s, mag: mag)
            }
        }
        .frame(width: displaySize.width, height: displaySize.height)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    model.dragChanged(start: v.startLocation.scaled(by: 1 / s), current: v.location.scaled(by: 1 / s),
                                      tolerance: tolerance, shift: NSEvent.modifierFlags.contains(.shift))
                }
                .onEnded { v in model.dragEnded(at: v.location.scaled(by: 1 / s)) }
        )
        .onContinuousHover { phase in
            switch phase {
            case .active(let p): model.cursor(at: p.scaled(by: 1 / s), tolerance: tolerance).set()
            case .ended: NSCursor.arrow.set()
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Annotation preview")
    }

    @ViewBuilder
    private func selection(for a: Annotation, s: CGFloat, mag: CGFloat) -> some View {
        let box = (a.kind == .text ? model.textBox(of: a) : model.bounds(of: a)).scaled(by: s)
            .insetBy(dx: -3 / mag, dy: -3 / mag)
        Path(box).stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.2 / mag, dash: [4 / mag, 3 / mag]))
        if a.kind == .text {
            ForEach([box.minX, box.maxX], id: \.self) { x in
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 6 / mag, height: min(22 / mag, box.height))
                    .position(x: x, y: box.midY)
                    .accessibilityLabel(x == box.minX ? "Resize text from left" : "Resize text from right")
            }
            if a.text.isEmpty {
                Text("Type in the sidebar")
                    .font(.system(size: 12 / mag))
                    .foregroundStyle(Color.accentColor)
                    .position(x: box.midX, y: box.midY)
            }
        }
    }
}
