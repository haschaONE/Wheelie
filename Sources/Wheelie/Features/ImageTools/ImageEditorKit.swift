import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WheelieCore

// Shared building blocks for the image editor windows: zoomable canvas, keyboard handling,
// window chrome, sidebar controls and the export job wrapper.

enum ImageEditorUI {
    static let sidebarWidth: CGFloat = 272
    static let windowSize = CGSize(width: 1120, height: 760)
    static let accent = Color.accentColor

    /// Runs an export as a Wheelie job (history, progress, notifications). Closes the editor on
    /// success; returns the error message to show inline on failure.
    @MainActor
    static func runExport(_ title: String, sources: [URL], windowID: String,
                          work: @escaping @MainActor () async throws -> [URL]) async -> String? {
        let result = await AppServices.shared.run(title, sources: sources) { .outputs(try await work()) }
        switch result {
        case .success:
            AppServices.shared.closeWindow(id: windowID)
            return nil
        case .failure(let error):
            return error.localizedDescription
        }
    }

    /// Loads a source photo plus a downscaled preview off the main thread.
    static func load(_ url: URL, previewSize: Int) async throws -> (SourceImage, CGImage) {
        try await Task.detached(priority: .userInitiated) {
            let source = try ImageToolsIO.load(url)
            return (source, ImageToolsIO.downscaled(source.image, maxPixelSize: previewSize))
        }.value
    }

    /// "JPG", "PNG"… — the format a same-size edit of `source` will be saved in (if it stays as opaque as now).
    static func formatLabel(for source: SourceImage, preview: CGImage) async -> String {
        let transparent = await isTransparent(preview)
        return formatLabel(for: source, transparent: transparent, size: source.size,
                           cwebpAvailable: Tools.locate("cwebp") != nil)
    }

    /// The format an edit of `source` with the given transparency and pixel size will be saved in.
    static func formatLabel(for source: SourceImage, transparent: Bool, size: CGSize, cwebpAvailable: Bool) -> String {
        ImageToolsIO.plan(sourceType: source.typeIdentifier, sourceExtension: source.url.pathExtension,
                          transparent: transparent, pixelSize: size,
                          cwebpAvailable: cwebpAvailable).fileExtension.uppercased()
    }

    static func isTransparent(_ preview: CGImage) async -> Bool {
        await Task.detached(priority: .utility) { ImageToolsIO.hasTransparency(preview) }.value
    }

    /// Appended to the status line for animated GIFs and multi-page TIFFs.
    static func frameNote(_ source: SourceImage?) -> String {
        (source?.frameCount ?? 1) > 1 ? " · first frame only" : ""
    }

    static func title(_ tool: String, _ urls: [URL]) -> String {
        urls.count == 1 ? "\(tool) — \(urls[0].lastPathComponent)" : "\(tool) — \(urls.count) images"
    }

    /// Asks for an image file (background pictures and the like).
    @MainActor
    static func chooseImage(message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = message
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url : nil
    }
}

extension Color {
    init(_ rgba: RGBAColor) {
        self.init(.sRGB, red: rgba.red, green: rgba.green, blue: rgba.blue, opacity: rgba.alpha)
    }
}

extension RGBAColor {
    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self.init(red: Double(ns.redComponent), green: Double(ns.greenComponent), blue: Double(ns.blueComponent),
                  alpha: Double(ns.alphaComponent))
    }
}

extension CGRect {
    func scaled(by s: CGFloat) -> CGRect { CGRect(x: minX * s, y: minY * s, width: width * s, height: height * s) }
}

extension CGPoint {
    func scaled(by s: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }
}

// MARK: - Zoomable canvas

/// Zoom state of one canvas. Magnification 1 = zoomed to fit.
@MainActor
final class CanvasZoom: ObservableObject {
    @Published private(set) var magnification: CGFloat = 1
    weak var scrollView: NSScrollView?

    func setMagnification(_ value: CGFloat, centeredAt point: NSPoint? = nil) {
        guard let sv = scrollView else { return }
        let target = min(max(value, sv.minMagnification), sv.maxMagnification)
        let center = point ?? NSPoint(x: sv.documentVisibleRect.midX, y: sv.documentVisibleRect.midY)
        sv.setMagnification(target, centeredAt: center)
        sync()
    }

    func zoomIn() { setMagnification((scrollView?.magnification ?? 1) * 1.25) }
    func zoomOut() { setMagnification((scrollView?.magnification ?? 1) / 1.25) }
    func fit() { setMagnification(1) }

    func sync() {
        guard let sv = scrollView, abs(sv.magnification - magnification) > 0.001 else { return }
        magnification = sv.magnification
    }

    var percentLabel: String { "\(Int((magnification * 100).rounded()))%" }
}

/// Shows `content` fitted into the available space, inside a scroll view that pinch-zooms
/// (and ⌘+/⌘−) and pans with two-finger scrolling. `content` gets the fitted size in points;
/// gestures inside it use that unmagnified coordinate space.
struct ZoomableCanvas<Content: View>: View {
    let imageSize: CGSize
    @ObservedObject var zoom: CanvasZoom
    var padding: CGFloat = 24
    @ViewBuilder let content: (CGSize) -> Content

    var body: some View {
        GeometryReader { geo in
            let fitted = Self.fit(imageSize, into: CGSize(width: max(geo.size.width - padding * 2, 40),
                                                          height: max(geo.size.height - padding * 2, 40)))
            ZoomScrollView(documentSize: fitted, zoom: zoom, content: content(fitted))
        }
    }

    static func fit(_ size: CGSize, into box: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return box }
        let s = min(box.width / size.width, box.height / size.height)
        return CGSize(width: max(1, (size.width * s).rounded()), height: max(1, (size.height * s).rounded()))
    }
}

/// Keeps a smaller document centered in the scroll view.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return rect }
        if rect.width > doc.frame.width { rect.origin.x = (doc.frame.width - rect.width) / 2 }
        if rect.height > doc.frame.height { rect.origin.y = (doc.frame.height - rect.height) / 2 }
        return rect
    }
}

struct ZoomScrollView<Content: View>: NSViewRepresentable {
    let documentSize: CGSize
    let zoom: CanvasZoom
    let content: Content

    final class Coordinator: NSObject {
        var hosting: NSHostingView<Content>?
        var magnifyMonitor: Any?
        var observer: NSObjectProtocol?

        deinit {
            if let magnifyMonitor { NSEvent.removeMonitor(magnifyMonitor) }
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.contentView = CenteringClipView()
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.5
        scroll.maxMagnification = 16
        scroll.horizontalScrollElasticity = .allowed
        scroll.verticalScrollElasticity = .allowed

        let hosting = NSHostingView(rootView: content)
        hosting.sizingOptions = []
        hosting.frame = CGRect(origin: .zero, size: documentSize)
        scroll.documentView = hosting
        context.coordinator.hosting = hosting
        zoom.scrollView = scroll

        // Pinch-to-zoom, even when the SwiftUI content would swallow the magnify event.
        context.coordinator.magnifyMonitor = NSEvent.addLocalMonitorForEvents(matching: .magnify) { [weak scroll, weak zoom] event in
            guard let scroll, let zoom, event.window === scroll.window, let doc = scroll.documentView else { return event }
            let inScroll = scroll.convert(event.locationInWindow, from: nil)
            guard scroll.bounds.contains(inScroll) else { return event }
            let point = doc.convert(event.locationInWindow, from: nil)
            MainActor.assumeIsolated {
                zoom.setMagnification(scroll.magnification * (1 + event.magnification), centeredAt: point)
            }
            return nil
        }
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.observer = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
        ) { [weak zoom] _ in
            MainActor.assumeIsolated { zoom?.sync() }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let hosting = context.coordinator.hosting else { return }
        hosting.rootView = content
        if hosting.frame.size != documentSize {
            hosting.frame = CGRect(origin: .zero, size: documentSize)
        }
        if zoom.scrollView !== scroll { zoom.scrollView = scroll }
    }
}

/// Gray checkerboard shown behind transparent previews.
struct Checkerboard: View {
    var cell: CGFloat = 8

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.92)))
            let cols = Int(size.width / cell) + 1, rows = Int(size.height / cell) + 1
            var path = Path()
            for r in 0..<rows {
                for c in 0..<cols where (r + c) % 2 == 0 {
                    path.addRect(CGRect(x: CGFloat(c) * cell, y: CGFloat(r) * cell, width: cell, height: cell))
                }
            }
            ctx.fill(path, with: .color(Color(white: 0.78)))
        }
    }
}

// MARK: - Keyboard

/// Keyboard shortcuts for an editor window. The app is menu-less, so the editor handles
/// ⌘W, Esc, ⌘↩, ⌘Z and standard text editing keys itself.
struct EditorKeys {
    var export: (() -> Void)?
    var close: (() -> Void)?
    var delete: (() -> Void)?
    var undo: (() -> Void)?
    var redo: (() -> Void)?
    var zoom: CanvasZoom?
    /// Extra keys (arrow nudges…). Return true when handled.
    var other: ((NSEvent) -> Bool)?
}

struct EditorKeyMonitor: NSViewRepresentable {
    let keys: EditorKeys

    func makeNSView(context: Context) -> KeyMonitorView {
        let view = KeyMonitorView()
        view.keys = keys
        return view
    }

    func updateNSView(_ view: KeyMonitorView, context: Context) { view.keys = keys }
}

final class KeyMonitorView: NSView {
    var keys = EditorKeys()
    nonisolated(unsafe) private var monitor: Any?

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }
            return MainActor.assumeIsolated { self.handle(event) } ? nil : event
        }
    }

    override func removeFromSuperview() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        super.removeFromSuperview()
    }

    @MainActor
    private func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let editingText = window?.firstResponder is NSTextView
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if event.keyCode == 53 { // Esc
            if editingText {
                window?.makeFirstResponder(nil)
            } else {
                keys.close?()
            }
            return true
        }
        if (event.keyCode == 36 || event.keyCode == 76) && flags == .command {
            if editingText { window?.makeFirstResponder(nil) }
            keys.export?()
            return true
        }
        if (event.keyCode == 51 || event.keyCode == 117) && flags.isEmpty && !editingText, let delete = keys.delete {
            delete()
            return true
        }
        if flags.contains(.command) && !flags.contains(.control) && !flags.contains(.option) {
            let shift = flags.contains(.shift)
            switch key {
            case "w": keys.close?(); return true
            case "=", "+": keys.zoom?.zoomIn(); return keys.zoom != nil
            case "-": keys.zoom?.zoomOut(); return keys.zoom != nil
            case "0": keys.zoom?.fit(); return keys.zoom != nil
            case "z" where !editingText:
                if shift { keys.redo?() } else { keys.undo?() }
                return keys.undo != nil
            case "c" where editingText && !shift: return NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self)
            case "v" where editingText && !shift: return NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self)
            case "x" where editingText && !shift: return NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self)
            case "a" where editingText && !shift: return NSApp.sendAction(#selector(NSResponder.selectAll(_:)), to: nil, from: self)
            default: break
            }
        }
        if !editingText, let other = keys.other { return other(event) }
        return false
    }
}

// MARK: - Window chrome

/// Toolbar on top, canvas + sidebar in the middle, status/error and Cancel/Export at the bottom.
struct EditorChrome<Toolbar: View, Canvas: View, Sidebar: View>: View {
    var status: String?
    var error: String?
    var busy: Bool
    var exportTitle: String = "Export"
    var canExport: Bool
    let onCancel: () -> Void
    let onExport: () -> Void
    @ViewBuilder let toolbar: () -> Toolbar
    @ViewBuilder let canvas: () -> Canvas
    @ViewBuilder let sidebar: () -> Sidebar

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) { toolbar() }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            HStack(spacing: 0) {
                canvas()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .underPageBackgroundColor))
                    .clipped()
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) { sidebar() }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: ImageEditorUI.sidebarWidth)
            }
            Divider()
            HStack(spacing: 10) {
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .textSelection(.enabled)
                } else if let status {
                    Text(status).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if busy { ProgressView().controlSize(.small) }
                Button("Cancel", action: onCancel)
                    .help("Close without saving (Esc)")
                Button(exportTitle, action: onExport)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canExport || busy)
                    .help("Save a new file next to the original (⌘↩)")
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }
}

/// Zoom buttons for the toolbar.
struct ZoomControls: View {
    @ObservedObject var zoom: CanvasZoom

    var body: some View {
        HStack(spacing: 2) {
            Button { zoom.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }
                .help("Zoom out (⌘−)")
            Button { zoom.fit() } label: { Text(zoom.percentLabel).monospacedDigit().frame(minWidth: 40) }
                .help("Zoom to fit (⌘0)")
            Button { zoom.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }
                .help("Zoom in (⌘+). Pinch to zoom, scroll to pan.")
        }
        .buttonStyle(.borderless)
    }
}

/// Placeholder while loading, or the load error.
struct CanvasPlaceholder: View {
    var error: String?

    var body: some View {
        if let error {
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.secondary)
                Text(error).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding()
        } else {
            ProgressView("Loading image…")
        }
    }
}

// MARK: - Sidebar controls

struct SidebarSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}

/// Labeled slider with the current value; double-click the label to reset.
struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var defaultValue: Double = 0
    var format: (Double) -> String = { v in
        let n = Int((v * 100).rounded())
        return n > 0 ? "+\(n)" : "\(n)"
    }
    var onEditingChanged: (Bool) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value)).monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.callout)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { value = defaultValue }
            .help("Double-click to reset")
            Slider(value: $value, in: range, onEditingChanged: onEditingChanged)
                .controlSize(.small)
                .accessibilityLabel(title)
        }
    }
}

/// Whole-number text field; commits on Return or when focus leaves.
struct IntField: View {
    let label: String
    @Binding var value: Int
    var width: CGFloat = 70

    var body: some View {
        TextField(label, value: $value, format: .number.grouping(.never))
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .frame(width: width)
            .labelsHidden()
            .accessibilityLabel(label)
            .help(label)
    }
}

/// A round color well that shows selection.
struct ColorSwatch: View {
    let fill: AnyShapeStyle
    let selected: Bool
    var size: CGFloat = 22
    var help: String = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(fill)
                .frame(width: size, height: size)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 1))
                .padding(2)
                .overlay(Circle().strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Palette of common annotation colors plus a custom picker.
struct ColorPaletteRow: View {
    @Binding var color: RGBAColor
    static let palette: [(String, RGBAColor)] = [
        ("Red", RGBAColor(hex: 0xFF3B30)), ("Orange", RGBAColor(hex: 0xFF9500)), ("Yellow", RGBAColor(hex: 0xFFCC00)),
        ("Green", RGBAColor(hex: 0x34C759)), ("Blue", RGBAColor(hex: 0x007AFF)), ("Purple", RGBAColor(hex: 0xAF52DE)),
        ("Black", .black), ("White", .white),
    ]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Self.palette, id: \.0) { name, c in
                ColorSwatch(fill: AnyShapeStyle(Color(c)), selected: c == color, size: 18, help: name) { color = c }
            }
            ColorPicker("Custom color", selection: Binding(get: { Color(color) }, set: { color = RGBAColor($0) }),
                        supportsOpacity: true)
                .labelsHidden()
                .help("Choose a custom color")
        }
    }
}

/// Compact wrapping grid of text choices (aspect ratios, canvas ratios…).
struct ChoiceGrid<Item: Hashable>: View {
    let items: [Item]
    let label: (Item) -> String
    @Binding var selection: Item
    var columns = 4

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: columns), spacing: 4) {
            ForEach(items, id: \.self) { item in
                Button { selection = item } label: {
                    Text(label(item))
                        .font(.callout)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill(selection == item ? Color.accentColor : Color.primary.opacity(0.07)))
                        .foregroundStyle(selection == item ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
