import AppKit
import SwiftUI
import WheelieCore

@MainActor
final class CropModel: ObservableObject {
    let url: URL
    let windowID: String
    let zoom = CanvasZoom()

    @Published private(set) var source: SourceImage?
    @Published private(set) var displayImage: CGImage?
    @Published var loadError: String?
    @Published var error: String?
    @Published var busy = false
    @Published var settings = CropSettings()
    @Published private(set) var aspect: CropAspect = .free
    @Published var resizeEnabled = false {
        didSet {
            guard resizeEnabled != oldValue else { return }
            if resizeEnabled {
                settings.outputWidth = Int(pixelCrop.width)
                settings.outputHeight = Int(pixelCrop.height)
            } else {
                settings.outputWidth = nil
                settings.outputHeight = nil
            }
        }
    }
    @Published var lockResizeRatio = true
    /// Format inputs that don't change while cropping (the label itself follows the output size,
    /// since icon formats only hold a few sizes).
    @Published private var previewTransparent = false
    private var cwebpAvailable = false

    /// Upright, unrotated preview; `displayImage` is it with the current turns/flips.
    private var preview: CGImage?

    private enum Drag {
        case move(CGRect, CGPoint)
        case resize(CropHandle)
        case create(CGPoint)
    }
    private var drag: Drag?

    init(url: URL, windowID: String) {
        self.url = url
        self.windowID = windowID
    }

    func load() async {
        guard source == nil else { return }
        do {
            let (source, preview) = try await ImageEditorUI.load(url, previewSize: 2400)
            self.source = source
            self.preview = preview
            cwebpAvailable = Tools.locate("cwebp") != nil
            previewTransparent = await ImageEditorUI.isTransparent(preview)
            refreshDisplay()
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func refreshDisplay() {
        guard let preview else { return }
        displayImage = try? ImageCrop.oriented(preview, quarterTurns: settings.quarterTurns,
                                               flipHorizontal: settings.flipHorizontal, flipVertical: settings.flipVertical)
    }

    // MARK: Geometry

    var sourceSize: CGSize { source?.size ?? CGSize(width: 1, height: 1) }
    var orientedSize: CGSize { settings.orientedSize(for: sourceSize) }
    var bounds: CGRect { CGRect(origin: .zero, size: orientedSize) }
    var cropRect: CGRect { settings.cropRect ?? bounds }
    var ratio: CGFloat? { aspect.ratio(for: orientedSize) }
    var pixelCrop: CGRect { settings.effectiveCrop(for: sourceSize) }
    var outputSize: CGSize { settings.outputSize(for: sourceSize) }

    /// "JPG", "PNG"… — what the crop at its current output size will be saved as.
    var formatLabel: String {
        guard let source else { return "" }
        return ImageEditorUI.formatLabel(for: source, transparent: previewTransparent, size: outputSize,
                                         cwebpAvailable: cwebpAvailable)
    }

    private func setCrop(_ rect: CGRect) {
        settings.cropRect = rect
        if resizeEnabled && lockResizeRatio, let w = settings.outputWidth {
            settings.outputHeight = ResizeMath.height(forWidth: w, original: pixelCrop.size)
        }
    }

    func selectAspect(_ newValue: CropAspect) {
        aspect = newValue
        if let r = ratio { setCrop(CropGeometry.constrain(cropRect, ratio: r, in: bounds)) }
    }

    func rotate(clockwise: Bool) {
        settings.rotate(clockwise: clockwise, sourceSize: sourceSize)
        // A fixed shape turns with the picture.
        switch aspect {
        case .sixteenNine: aspect = .nineSixteen
        case .nineSixteen: aspect = .sixteenNine
        case .fourThree, .threeTwo, .fourFive: aspect = .free
        default: break
        }
        refreshDisplay()
    }

    func flip(horizontal: Bool) {
        settings.flip(horizontal: horizontal, sourceSize: sourceSize)
        refreshDisplay()
    }

    func reset() {
        resizeEnabled = false
        settings = CropSettings()
        aspect = .free
        error = nil
        refreshDisplay()
        zoom.fit()
    }

    // MARK: Fields

    var cropWidth: Int {
        get { Int(pixelCrop.width) }
        set { setCrop(CropGeometry.setSize(cropRect, width: CGFloat(max(1, newValue)), height: nil, ratio: ratio, in: bounds)) }
    }

    var cropHeight: Int {
        get { Int(pixelCrop.height) }
        set { setCrop(CropGeometry.setSize(cropRect, width: nil, height: CGFloat(max(1, newValue)), ratio: ratio, in: bounds)) }
    }

    var outputWidth: Int {
        get { Int(outputSize.width) }
        set {
            let w = min(max(1, newValue), ResizeMath.maxSide)
            settings.outputWidth = w
            if lockResizeRatio { settings.outputHeight = min(ResizeMath.height(forWidth: w, original: pixelCrop.size), ResizeMath.maxSide) }
        }
    }

    var outputHeight: Int {
        get { Int(outputSize.height) }
        set {
            let h = min(max(1, newValue), ResizeMath.maxSide)
            settings.outputHeight = h
            if lockResizeRatio { settings.outputWidth = min(ResizeMath.width(forHeight: h, original: pixelCrop.size), ResizeMath.maxSide) }
        }
    }

    var resizePercent: Int {
        get { Int((outputSize.width / max(pixelCrop.width, 1) * 100).rounded()) }
        set {
            let p = Double(min(max(1, newValue), 1000))
            let size = ResizeMath.scaled(pixelCrop.size, percent: p)
            settings.outputWidth = min(size.width, ResizeMath.maxSide)
            settings.outputHeight = min(size.height, ResizeMath.maxSide)
        }
    }


    // MARK: Canvas interaction (pixel coordinates)

    func dragChanged(start: CGPoint, current: CGPoint, handleRadius: CGFloat, minSize: CGFloat) {
        if drag == nil {
            let isFull = settings.cropRect == nil || cropRect.integral == bounds.integral
            if let handle = CropHandle.hit(start, rect: cropRect, radius: handleRadius) {
                drag = .resize(handle)
            } else if cropRect.contains(start) && !isFull {
                drag = .move(cropRect, start)
            } else {
                drag = .create(start)
            }
        }
        switch drag {
        case .resize(let handle):
            setCrop(CropGeometry.resize(cropRect, handle: handle, to: current, ratio: ratio, in: bounds, minSize: minSize))
        case .move(let original, let origin):
            setCrop(CropGeometry.move(original, by: CGSize(width: current.x - origin.x, height: current.y - origin.y), in: bounds))
        case .create(let origin):
            let rect = CropGeometry.spanning(from: origin, to: current, ratio: ratio, in: bounds)
            if rect.width >= minSize && rect.height >= minSize { setCrop(rect) }
        case nil:
            break
        }
    }

    func dragEnded() {
        drag = nil
        if settings.cropRect != nil { setCrop(CropGeometry.integral(cropRect, in: bounds)) }
    }

    func cursor(at point: CGPoint, handleRadius: CGFloat) -> NSCursor {
        if let handle = CropHandle.hit(point, rect: cropRect, radius: handleRadius) {
            if handle.isCorner { return .crosshair }
            return handle.movesLeft || handle.movesRight ? .resizeLeftRight : .resizeUpDown
        }
        let isFull = settings.cropRect == nil || cropRect.integral == bounds.integral
        return cropRect.contains(point) && !isFull ? .openHand : .crosshair
    }

    /// Arrow keys nudge the crop (Shift: 10 pixels).
    func handleKey(_ event: NSEvent) -> Bool {
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        let delta: CGSize
        switch event.keyCode {
        case 123: delta = CGSize(width: -step, height: 0)
        case 124: delta = CGSize(width: step, height: 0)
        case 125: delta = CGSize(width: 0, height: step)
        case 126: delta = CGSize(width: 0, height: -step)
        default: return false
        }
        guard settings.cropRect != nil else { return false }
        setCrop(CropGeometry.move(cropRect, by: delta, in: bounds))
        return true
    }

    // MARK: Export

    func close() { AppServices.shared.closeWindow(id: windowID) }

    func export() {
        guard let source, !busy else { return }
        var final = settings
        final.cropRect = pixelCrop
        let cropSettings = final
        busy = true
        error = nil
        Task {
            error = await ImageEditorUI.runExport("Crop", sources: [url], windowID: windowID) {
                let image = try await Task.detached(priority: .userInitiated) {
                    try ImageCrop.render(source.image, cropSettings)
                }.value
                return [try await ImageToolsIO.export(image, source: source, suffix: " crop")]
            }
            busy = false
        }
    }
}

struct CropEditorView: View {
    static func open(_ url: URL) {
        let id = "image.crop:" + url.path
        AppServices.shared.presentWindow(id: id, title: ImageEditorUI.title("Crop", [url]), size: ImageEditorUI.windowSize) {
            CropEditorView(url: url, windowID: id)
        }
    }

    @StateObject private var model: CropModel

    init(url: URL, windowID: String) {
        _model = StateObject(wrappedValue: CropModel(url: url, windowID: windowID))
    }

    var body: some View {
        EditorChrome(status: status, error: model.error, busy: model.busy, canExport: model.source != nil,
                     onCancel: model.close, onExport: model.export) {
            toolbar
        } canvas: {
            if let image = model.displayImage {
                ZoomableCanvas(imageSize: model.orientedSize, zoom: model.zoom) { size in
                    CropCanvas(model: model, zoom: model.zoom, image: image, displaySize: size)
                }
            } else {
                CanvasPlaceholder(error: model.loadError)
            }
        } sidebar: {
            sidebar
        }
        .background(EditorKeyMonitor(keys: EditorKeys(export: model.export, close: model.close, zoom: model.zoom,
                                                      other: model.handleKey)))
        .task { await model.load() }
    }

    private var status: String? {
        guard model.source != nil else { return nil }
        return "\(model.outputWidth) × \(model.outputHeight) px · \(model.formatLabel)" + ImageEditorUI.frameNote(model.source)
    }

    private var aspectBinding: Binding<CropAspect> {
        Binding(get: { model.aspect }, set: { model.selectAspect($0) })
    }

    @ViewBuilder private var toolbar: some View {
        Picker("Aspect ratio", selection: aspectBinding) {
            ForEach(CropAspect.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.menu)
        .frame(width: 150)
        .help("Aspect ratio of the crop")
        Divider().frame(height: 18)
        Group {
            Button { model.rotate(clockwise: false) } label: { Image(systemName: "rotate.left") }
                .help("Rotate 90° left")
            Button { model.rotate(clockwise: true) } label: { Image(systemName: "rotate.right") }
                .help("Rotate 90° right")
            Button { model.flip(horizontal: true) } label: {
                Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
            }
            .help("Flip horizontally")
            Button { model.flip(horizontal: false) } label: {
                Image(systemName: "arrow.up.and.down.righttriangle.up.righttriangle.down")
            }
            .help("Flip vertically")
            Button { model.reset() } label: { Image(systemName: "arrow.counterclockwise") }
                .help("Reset crop, rotation and size")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 15))
        .disabled(model.source == nil)
        Spacer()
        ZoomControls(zoom: model.zoom)
    }

    @ViewBuilder private var sidebar: some View {
        SidebarSection("Crop") {
            HStack(spacing: 6) {
                Text("W").foregroundStyle(.secondary)
                IntField(label: "Crop width in pixels", value: $model.cropWidth)
                Text("H").foregroundStyle(.secondary)
                IntField(label: "Crop height in pixels", value: $model.cropHeight)
                Text("px").foregroundStyle(.secondary)
            }
            ChoiceGrid(items: CropAspect.allCases, label: { $0.label }, selection: aspectBinding)
            Text("Drag the corners or edges to crop, drag inside to move, or drag anywhere else to draw a new area. Arrow keys nudge.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        SidebarSection("Rotate & Flip") {
            HStack {
                Button { model.rotate(clockwise: false) } label: { Label("Left", systemImage: "rotate.left") }
                Button { model.rotate(clockwise: true) } label: { Label("Right", systemImage: "rotate.right") }
            }
            HStack {
                Button { model.flip(horizontal: true) } label: { Label("Flip H", systemImage: "arrow.left.and.right") }
                Button { model.flip(horizontal: false) } label: { Label("Flip V", systemImage: "arrow.up.and.down") }
            }
        }
        .disabled(model.source == nil)
        SidebarSection("Resize") {
            Toggle("Resize the result", isOn: $model.resizeEnabled)
            if model.resizeEnabled {
                HStack(spacing: 6) {
                    Text("W").foregroundStyle(.secondary)
                    IntField(label: "Output width in pixels", value: $model.outputWidth)
                    Button { model.lockResizeRatio.toggle() } label: {
                        Image(systemName: model.lockResizeRatio ? "lock.fill" : "lock.open")
                    }
                    .buttonStyle(.borderless)
                    .help(model.lockResizeRatio ? "Keep proportions (on)" : "Keep proportions (off)")
                    Text("H").foregroundStyle(.secondary)
                    IntField(label: "Output height in pixels", value: $model.outputHeight)
                }
                HStack(spacing: 6) {
                    Text("Scale").foregroundStyle(.secondary)
                    IntField(label: "Scale in percent", value: $model.resizePercent, width: 56)
                    Text("%").foregroundStyle(.secondary)
                    Spacer()
                    ForEach([25, 50, 200], id: \.self) { p in
                        Button("\(p)%") { model.resizePercent = p }.controlSize(.small)
                    }
                }
            }
        }
        .disabled(model.source == nil)
        if let source = model.source {
            SidebarSection("Original") {
                Text(verbatim: "\(source.image.width) × \(source.image.height) px").foregroundStyle(.secondary)
            }
        }
    }
}

struct CropCanvas: View {
    @ObservedObject var model: CropModel
    @ObservedObject var zoom: CanvasZoom
    let image: CGImage
    let displaySize: CGSize

    var body: some View {
        let s = displaySize.width / max(model.orientedSize.width, 1)   // points per pixel
        let rect = model.cropRect.scaled(by: s)
        let mag = max(zoom.magnification, 0.1)
        let handle = 10 / mag
        let hitRadius = (12 / mag) / s
        ZStack(alignment: .topLeading) {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(s > 1.5 ? .none : .high)
                .frame(width: displaySize.width, height: displaySize.height)
            Path { p in
                p.addRect(CGRect(origin: .zero, size: displaySize))
                p.addRect(rect)
            }
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
            Path { p in
                for i in 1...2 {
                    let x = rect.minX + rect.width * CGFloat(i) / 3
                    let y = rect.minY + rect.height * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: rect.minY)); p.addLine(to: CGPoint(x: x, y: rect.maxY))
                    p.move(to: CGPoint(x: rect.minX, y: y)); p.addLine(to: CGPoint(x: rect.maxX, y: y))
                }
            }
            .stroke(Color.white.opacity(0.6), lineWidth: 1 / mag)
            Path(rect).stroke(Color.white, lineWidth: 1.5 / mag)
            ForEach(CropHandle.allCases, id: \.self) { h in
                RoundedRectangle(cornerRadius: 2 / mag)
                    .fill(Color.white)
                    .overlay(RoundedRectangle(cornerRadius: 2 / mag).strokeBorder(Color.black.opacity(0.35), lineWidth: 0.5 / mag))
                    .frame(width: h.isCorner ? handle : handle * 0.8, height: h.isCorner ? handle : handle * 0.8)
                    .position(h.point(in: rect))
            }
        }
        .frame(width: displaySize.width, height: displaySize.height)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    model.dragChanged(start: v.startLocation.scaled(by: 1 / s), current: v.location.scaled(by: 1 / s),
                                      handleRadius: hitRadius, minSize: max(1, (12 / mag) / s))
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
        .accessibilityLabel("Crop selection. Drag to reposition.")
    }
}
