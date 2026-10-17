import AppKit
import SwiftUI
import WheelieCore

@MainActor
final class WheelModel: ObservableObject {
    enum Phase: Equatable {
        case choosing
        case working(String)
        case done(String)
        case failed(String)
    }

    @Published var files: [URL] = []
    @Published var items: [WheelItem] = [] { didSet { split() } }
    @Published private(set) var inner: [WheelItem] = []
    @Published private(set) var outer: [WheelItem] = []
    @Published var phase: Phase = .choosing
    @Published var hovered: String? {
        didSet {
            guard hovered != oldValue else { return }
            NotificationCenter.default.post(name: .wheelieHighlightChanged, object: hovered)
        }
    }
    @Published var appeared = false

    /// Item picked by drop or click, with the files to use.
    var onChoose: ((WheelItem, [URL]) -> Void)?
    var onCancel: (() -> Void)?

    private func split() {
        inner = items.filter { $0.ring == .inner }
        outer = items.filter { $0.ring == .outer }
    }

    func item(id: String?) -> WheelItem? { items.first { $0.id == id } }
}

enum WheelGeometry {
    static let size: CGFloat = 560
    static let hubSize: CGFloat = 104
    static let innerRadius: CGFloat = 118
    static let innerPetal: CGFloat = 70
    static let outerRadius: CGFloat = 210
    static let outerPetal: CGFloat = 60

    /// Border between the inner and outer drop bands.
    static let ringBoundary: CGFloat = (innerRadius + innerPetal / 2 + outerRadius - outerPetal / 2) / 2
    static func limit(hasOuter: Bool) -> CGFloat {
        hasOuter ? outerRadius + outerPetal / 2 + 24 : innerRadius + innerPetal / 2 + 26
    }

    /// Petal centre offset from the wheel centre, y pointing down (SwiftUI space). Index 0 is at the top.
    static func offset(index: Int, count: Int, radius: CGFloat) -> CGSize {
        let angle = -Double.pi / 2 + Double(index) / Double(max(count, 1)) * 2 * .pi
        return CGSize(width: cos(angle) * radius, height: sin(angle) * radius)
    }

    /// Nearest petal by angle among `count` evenly spaced petals. `dx`/`dy` relative to centre, y down.
    static func angularIndex(dx: CGFloat, dy: CGFloat, count: Int) -> Int {
        let step = 2 * Double.pi / Double(count)
        let angle = atan2(Double(dy), Double(dx)) + Double.pi / 2   // 0 = top, clockwise
        return ((Int((angle / step).rounded()) % count) + count) % count
    }

    /// Which (ring, index) a point targets; nil inside the hub (cancel zone) or outside the wheel.
    static func target(dx: CGFloat, dy: CGFloat, innerCount: Int, outerCount: Int) -> (WheelRing, Int)? {
        let distance = hypot(dx, dy)
        guard distance > hubSize / 2, distance <= limit(hasOuter: outerCount > 0) else { return nil }
        let useInner = innerCount > 0 && (outerCount == 0 || distance <= ringBoundary)
        if useInner { return (.inner, angularIndex(dx: dx, dy: dy, count: innerCount)) }
        guard outerCount > 0 else { return nil }
        return (.outer, angularIndex(dx: dx, dy: dy, count: outerCount))
    }
}

/// Borderless, non-activating panel so the wheel floats over any app
/// mid-drag without stealing focus from the drag source.
final class WheelPanel: NSPanel {
    var allowsKey = false
    let dropView: WheelDropView

    init(model: WheelModel) {
        dropView = WheelDropView(model: model)
        super.init(contentRect: NSRect(x: 0, y: 0, width: WheelGeometry.size, height: WheelGeometry.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let host = NSHostingView(rootView: WheelView(model: model))
        host.frame = dropView.bounds
        host.autoresizingMask = [.width, .height]
        dropView.addSubview(host)
        contentView = dropView
    }

    override var canBecomeKey: Bool { allowsKey }

    override func cancelOperation(_ sender: Any?) {
        dropView.model.onCancel?()
    }

    func center(on point: NSPoint) {
        let half = WheelGeometry.size / 2
        var origin = NSPoint(x: point.x - half, y: point.y - half)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main {
            let f = screen.frame
            origin.x = min(max(origin.x, f.minX), f.maxX - WheelGeometry.size)
            origin.y = min(max(origin.y, f.minY), f.maxY - WheelGeometry.size)
        }
        setFrameOrigin(origin)
    }
}

/// One AppKit drag destination for the whole wheel (as Tangerine's
/// ConversionOverlayView does). The petal is picked by ring band + angle, so
/// whole wedges count, not just the petal circles. SwiftUI only draws.
final class WheelDropView: NSView {
    let model: WheelModel

    init(model: WheelModel) {
        self.model = model
        super.init(frame: NSRect(x: 0, y: 0, width: WheelGeometry.size, height: WheelGeometry.size))
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @MainActor
    func item(at windowPoint: NSPoint) -> WheelItem? {
        let p = convert(windowPoint, from: nil)
        let dx = p.x - bounds.midX
        let dy = -(p.y - bounds.midY)   // AppKit y is up; geometry uses y down
        guard let (ring, index) = WheelGeometry.target(dx: dx, dy: dy, innerCount: model.inner.count,
                                                       outerCount: model.outer.count) else { return nil }
        return ring == .inner ? model.inner[index] : model.outer[index]
    }

    private func update(_ sender: NSDraggingInfo) -> NSDragOperation {
        MainActor.assumeIsolated {
            guard model.phase == .choosing else { return [] }
            let target = item(at: sender.draggingLocation)
            if model.hovered != target?.id { model.hovered = target?.id }
            return target == nil ? [] : .copy
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func wantsPeriodicDraggingUpdates() -> Bool { false }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        MainActor.assumeIsolated {
            if model.phase == .choosing { model.hovered = nil }
        }
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        MainActor.assumeIsolated { model.phase == .choosing && item(at: sender.draggingLocation) != nil }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        MainActor.assumeIsolated {
            guard let target = item(at: sender.draggingLocation) else { return false }
            let urls = (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                              options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
            model.onChoose?(target, urls.isEmpty ? model.files : urls)
            return true
        }
    }
}

struct WheelView: View {
    @ObservedObject var model: WheelModel

    static let accent = Color(red: 0.36, green: 0.42, blue: 1.0)

    var body: some View {
        let limit = WheelGeometry.limit(hasOuter: !model.outer.isEmpty)
        ZStack {
            // Backdrop disk: also keeps the gaps between petals non-transparent,
            // so the window server routes drags there to us, not to the window below.
            Circle()
                .fill(RadialGradient(colors: [.black.opacity(0.30), .black.opacity(0.14)],
                                     center: .center, startRadius: 40, endRadius: limit))
                .frame(width: limit * 2, height: limit * 2)
                .scaleEffect(model.appeared ? 1 : 0.4)
                .opacity(model.appeared ? 1 : 0)
                .animation(.easeOut(duration: 0.18), value: model.appeared)

            ring(model.inner, radius: WheelGeometry.innerRadius, petal: WheelGeometry.innerPetal, delay: 0)
            ring(model.outer, radius: WheelGeometry.outerRadius, petal: WheelGeometry.outerPetal, delay: 0.08)

            HubView(model: model)
                .frame(width: WheelGeometry.hubSize, height: WheelGeometry.hubSize)
                .scaleEffect(model.appeared ? 1 : 0.5)
                .opacity(model.appeared ? 1 : 0)
                .animation(.spring(response: 0.3, dampingFraction: 0.75), value: model.appeared)
                .onTapGesture { if model.phase == .choosing { model.onCancel?() } }
        }
        .frame(width: WheelGeometry.size, height: WheelGeometry.size)
    }

    @ViewBuilder
    private func ring(_ items: [WheelItem], radius: CGFloat, petal: CGFloat, delay: Double) -> some View {
        if !items.isEmpty {
            Circle()
                .stroke(Self.accent.opacity(0.28), lineWidth: 2)
                .frame(width: radius * 2, height: radius * 2)
                .opacity(model.appeared ? 1 : 0)
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                PetalView(item: item, size: petal, hovered: model.hovered == item.id,
                          dimmed: isWorking && model.hovered != item.id)
                    .frame(width: petal, height: petal)
                    .offset(WheelGeometry.offset(index: index, count: items.count, radius: radius))
                    .scaleEffect(model.appeared ? 1 : 0.2)
                    .opacity(model.appeared ? 1 : 0)
                    .animation(.spring(response: 0.32, dampingFraction: 0.68).delay(delay + Double(index) * 0.02),
                               value: model.appeared)
                    .onTapGesture { if model.phase == .choosing { model.onChoose?(item, model.files) } }
                    .onHover { inside in
                        guard model.phase == .choosing else { return }
                        if inside { model.hovered = item.id } else if model.hovered == item.id { model.hovered = nil }
                    }
            }
        }
    }

    private var isWorking: Bool {
        if case .working = model.phase { return true }
        return false
    }
}

struct PetalView: View {
    let item: WheelItem
    let size: CGFloat
    let hovered: Bool
    let dimmed: Bool

    var body: some View {
        let small = size < 66
        ZStack {
            Circle().fill(.regularMaterial)
            Circle().fill(WheelView.accent.opacity(hovered ? 0.9 : 0.0))
            Circle().strokeBorder(WheelView.accent.opacity(hovered ? 1 : 0.4), lineWidth: 1.5)
            VStack(spacing: small ? 2 : 3) {
                Image(systemName: item.symbol).font(.system(size: small ? 15 : 17, weight: .semibold))
                Text(item.label)
                    .font(.system(size: small ? 9 : 11, weight: .bold, design: .rounded))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 4)
            }
            .foregroundStyle(hovered ? Color.white : Color.primary)
        }
        .shadow(color: .black.opacity(0.25), radius: hovered ? 10 : 5, y: 2)
        .scaleEffect(hovered ? 1.18 : 1)
        .opacity(dimmed ? 0.35 : 1)
        .animation(.spring(response: 0.22, dampingFraction: 0.6), value: hovered)
        .contentShape(Circle())
    }
}

struct HubView: View {
    @ObservedObject var model: WheelModel

    var body: some View {
        ZStack {
            Circle().fill(.thickMaterial)
            Circle().strokeBorder(WheelView.accent.opacity(0.5), lineWidth: 2)
            content
        }
        .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
        .contentShape(Circle())
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .choosing:
            VStack(spacing: 2) {
                if let first = model.files.first {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: first.path))
                        .resizable().frame(width: 40, height: 40)
                }
                Text(model.item(id: model.hovered).map { $0.label } ?? caption)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }
        case .working(let label):
            VStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(label).font(.system(size: 11, weight: .semibold, design: .rounded)).lineLimit(1)
            }
        case .done(let text):
            VStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 30)).foregroundStyle(.green)
                Text(text).font(.system(size: 10, weight: .semibold, design: .rounded))
                    .lineLimit(2).multilineTextAlignment(.center).padding(.horizontal, 6)
            }
        case .failed(let message):
            VStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 24)).foregroundStyle(.orange)
                Text(message).font(.system(size: 9)).multilineTextAlignment(.center).lineLimit(3).padding(.horizontal, 6)
            }
        }
    }

    private var caption: String {
        if model.items.isEmpty { return "Nothing to do" }
        return model.files.count == 1 ? (model.files[0].pathExtension.uppercased().nilIfEmpty ?? "Folder")
                                      : "\(model.files.count) items"
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
