import AppKit
import WheelieCore

/// Float: a floating shelf for files. Drop files on the wheel's "Float" petal (or onto
/// a Float) to park them; drag them out later into Finder, Mail, a browser or the wheel.
/// Floats stay above other windows on every Space, dock to screen edges as slim tabs,
/// and come back after relaunch.
enum FloatFeature: WheelieFeature {
    static func wheelItems() -> [WheelItem] {
        [
            WheelItem(id: "float.add", label: "Float", symbol: "square.stack.3d.up.fill", ring: .outer, order: 50,
                      accepts: { files in !files.isEmpty && files.allSatisfy(\.isFileURL) },
                      perform: { files in
                          FloatManager.shared.deliver(files)
                          return .message(files.count == 1 ? "Floating 1 item" : "Floating \(files.count) items")
                      }),
        ]
    }

    static func menuItems() -> [NSMenuItem] {
        let manager = FloatManager.shared
        return [
            FloatMenuItem("New Float") { manager.newEmptyFloat() },
            FloatMenuItem("Show All Floats", isAvailable: { manager.hasFloats }) {
                manager.showAll()
            },
            FloatMenuItem("Close All Floats", isAvailable: { manager.hasFloats }) {
                manager.closeAll()
            },
        ]
    }

    static func start() {
        FloatManager.shared.start()
    }
}
