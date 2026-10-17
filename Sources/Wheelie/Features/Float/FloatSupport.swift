import AppKit
import Quartz
import QuickLookThumbnailing
import WheelieCore

// MARK: - Thumbnails

/// Quick Look thumbnails for Float items, cached by path + modification date.
/// Returns the Finder icon right away and calls back when the thumbnail is ready.
@MainActor
final class FloatThumbnails {
    static let shared = FloatThumbnails()

    private var cache: [String: NSImage] = [:]
    private var waiting: [String: [(NSImage) -> Void]] = [:]
    private let pixelSide: CGFloat = 128

    private func key(for url: URL) -> String {
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return url.path + "|" + String(date?.timeIntervalSinceReferenceDate ?? 0)
    }

    func cached(_ url: URL) -> NSImage? { cache[key(for: url)] }

    @discardableResult
    func image(for url: URL, completion: @escaping (NSImage) -> Void) -> NSImage {
        let key = key(for: url)
        if let image = cache[key] { return image }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        if waiting[key] != nil {
            waiting[key]?.append(completion)
            return icon
        }
        waiting[key] = [completion]
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: pixelSide / 2, height: pixelSide / 2),
                                                   scale: 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            let cgImage = representation?.cgImage
            DispatchQueue.main.async {
                FloatThumbnails.shared.finish(key: key, cgImage: cgImage, icon: icon)
            }
        }
        return icon
    }

    private func finish(key: String, cgImage: CGImage?, icon: NSImage) {
        let image = cgImage.map { NSImage(cgImage: $0, size: NSSize(width: CGFloat($0.width) / 2, height: CGFloat($0.height) / 2)) } ?? icon
        if cache.count > 400 { cache.removeAll() }
        cache[key] = image
        let callbacks = waiting.removeValue(forKey: key) ?? []
        if cgImage != nil { callbacks.forEach { $0(image) } }
    }
}

// MARK: - Shapes

enum FloatShape {
    static let floatingRadius: CGFloat = 14
    static let tabRadius: CGFloat = 13

    /// Rounded rect; corners on `squareEdge` stay square (flush with the screen edge).
    static func path(in rect: NSRect, radius: CGFloat, squareEdge: FloatEdge?) -> NSBezierPath {
        let left: CGFloat = squareEdge == .left ? 0 : radius
        let right: CGFloat = squareEdge == .right ? 0 : radius
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX + left, y: rect.minY))
        path.line(to: NSPoint(x: rect.maxX - right, y: rect.minY))
        if right > 0 {
            path.appendArc(withCenter: NSPoint(x: rect.maxX - right, y: rect.minY + right), radius: right,
                           startAngle: 270, endAngle: 360)
        }
        path.line(to: NSPoint(x: rect.maxX, y: rect.maxY - right))
        if right > 0 {
            path.appendArc(withCenter: NSPoint(x: rect.maxX - right, y: rect.maxY - right), radius: right,
                           startAngle: 0, endAngle: 90)
        }
        path.line(to: NSPoint(x: rect.minX + left, y: rect.maxY))
        if left > 0 {
            path.appendArc(withCenter: NSPoint(x: rect.minX + left, y: rect.maxY - left), radius: left,
                           startAngle: 90, endAngle: 180)
        }
        path.line(to: NSPoint(x: rect.minX, y: rect.minY + left))
        if left > 0 {
            path.appendArc(withCenter: NSPoint(x: rect.minX + left, y: rect.minY + left), radius: left,
                           startAngle: 180, endAngle: 270)
        }
        path.close()
        return path
    }

    /// Stretchable mask for the material view (keeps the window shadow in shape too).
    static func maskImage(radius: CGFloat, squareEdge: FloatEdge?) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            path(in: rect, radius: radius, squareEdge: squareEdge).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    /// Fits an image of `size` inside `rect`, centred, keeping its aspect ratio.
    static func aspectFit(_ size: NSSize, in rect: NSRect) -> NSRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let scale = min(rect.width / size.width, rect.height / size.height)
        let fitted = NSSize(width: size.width * scale, height: size.height * scale)
        return NSRect(x: rect.midX - fitted.width / 2, y: rect.midY - fitted.height / 2,
                      width: fitted.width, height: fitted.height)
    }
}

// MARK: - Small views

/// Container that lets clicks on its empty parts fall through to the Float's background.
class FloatPassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

/// Label that never takes clicks.
final class FloatLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    static func make(size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> FloatLabel {
        let label = FloatLabel(labelWithString: "")
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.isSelectable = false
        label.drawsBackground = false
        return label
    }
}

/// Borderless symbol button that works on the first click into an inactive Float.
final class FloatButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    static func symbol(_ name: String, help: String, target: AnyObject?, action: Selector) -> FloatButton {
        let button = FloatButton(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.image = NSImage(systemSymbolName: name, accessibilityDescription: help)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = help
        button.setAccessibilityLabel(help)
        button.target = target
        button.action = action
        return button
    }

    func setSymbol(_ name: String, help: String) {
        image = NSImage(systemSymbolName: name, accessibilityDescription: help)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        toolTip = help
        setAccessibilityLabel(help)
    }
}

/// Material background; never hit-tested so the root view receives background clicks.
final class FloatMaterialView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Hairline outline following the Float's shape.
final class FloatBorderView: NSView {
    var squareEdge: FloatEdge? { didSet { needsDisplay = true } }
    var radius: CGFloat = FloatShape.floatingRadius { didSet { needsDisplay = true } }
    var highlight: NSColor? { didSet { needsDisplay = true } }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let width: CGFloat = highlight == nil ? 1 : 2.5
        let path = FloatShape.path(in: bounds.insetBy(dx: width / 2, dy: width / 2), radius: radius - width / 2,
                                   squareEdge: squareEdge)
        path.lineWidth = width
        (highlight ?? NSColor.white.withAlphaComponent(isDark ? 0.14 : 0.5)).setStroke()
        path.stroke()
    }

    private var isDark: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

// MARK: - Menu items

/// Status-menu item that disables itself when `isAvailable` is false
/// (the status menu auto-enables items, so this validates instead of setting isEnabled).
final class FloatMenuItem: NSMenuItem, NSMenuItemValidation {
    private let handler: () -> Void
    private let isAvailable: () -> Bool

    init(_ title: String, isAvailable: @escaping () -> Bool = { true }, handler: @escaping () -> Void) {
        self.handler = handler
        self.isAvailable = isAvailable
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func fire() { handler() }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { isAvailable() }
}

// MARK: - Quick Look

/// Data source for the shared Quick Look panel. Holds plain values only.
final class FloatQuickLookSource: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    var urls: [URL] = []
    /// Screen rects of the items' thumbnails, for the zoom transition.
    var frames: [URL: NSRect] = [:]
    var images: [URL: NSImage] = [:]

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        urls.indices.contains(index) ? urls[index] as NSURL : nil
    }

    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: (any QLPreviewItem)!) -> NSRect {
        guard let url = item.previewItemURL else { return .zero }
        return frames[url] ?? .zero
    }

    func previewPanel(_ panel: QLPreviewPanel!, transitionImageFor item: (any QLPreviewItem)!,
                      contentRect: UnsafeMutablePointer<NSRect>!) -> Any! {
        guard let url = item.previewItemURL else { return nil }
        return images[url]
    }
}
