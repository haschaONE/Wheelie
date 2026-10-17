import AppKit

/// A self-contained feature. Each lives in `Sources/Wheelie/Features/<Name>/`.
@MainActor
protocol WheelieFeature {
    /// Everything this feature can put on the wheel; filtered per drag via `accepts`.
    static func wheelItems() -> [WheelItem]
    /// Extra entries for the menu bar menu's "Tools" section.
    static func menuItems() -> [NSMenuItem]
    /// Called once at launch, after the status item exists.
    static func start()
}

extension WheelieFeature {
    static func wheelItems() -> [WheelItem] { [] }
    static func menuItems() -> [NSMenuItem] { [] }
    static func start() {}
}

@MainActor
enum FeatureRegistry {
    static let features: [any WheelieFeature.Type] = [
        ConvertFeature.self,
        FileActionsFeature.self,
        CompressFeature.self,
        FloatFeature.self,
        VideoToolsFeature.self,
        AudioToolsFeature.self,
        ImageToolsFeature.self,
        PDFToolsFeature.self,
        DocumentsFeature.self,
        ShellFeature.self,
    ]

    static func items(for files: [URL]) -> [WheelItem] {
        features.flatMap { $0.wheelItems() }
            .filter { $0.accepts(files) }
            .sorted { ($0.ring, $0.order, $0.label) < ($1.ring, $1.order, $1.label) }
    }

    static func startAll() { features.forEach { $0.start() } }

    /// Tools-section items. ShellFeature's (Settings, How to Use) go in the menu footer instead.
    static func menuItems() -> [NSMenuItem] {
        features.filter { $0 != ShellFeature.self }.flatMap { $0.menuItems() }
    }
}

/// NSMenuItem that runs a closure, so features don't need an @objc target.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func fire() { handler() }
}
