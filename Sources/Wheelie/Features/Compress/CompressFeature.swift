import AppKit
import UniformTypeIdentifiers
import WheelieCore

/// Compress (images, video, audio, PDF) and Remove Metadata. Both open a small window:
/// "Compression Settings" and the metadata viewer with its "Remove Metadata" button.
enum CompressFeature: WheelieFeature {
    static func wheelItems() -> [WheelItem] {
        [
            WheelItem(id: "compress.compress", label: "Compress", symbol: "arrow.down.right.and.arrow.up.left",
                      ring: .outer, order: 20,
                      accepts: accepts,
                      perform: { files in
                          CompressionWindow.present(files)
                          return .none
                      }),
            WheelItem(id: "compress.metadata", label: "Metadata", symbol: "tag.slash",
                      ring: .outer, order: 21,
                      accepts: accepts,
                      perform: { files in
                          MetadataWindow.present(files)
                          return .none
                      }),
        ]
    }

    static func menuItems() -> [NSMenuItem] {
        [
            ClosureMenuItem("Compress Files…") { chooseFiles("Choose files to compress") { CompressionWindow.present($0) } },
            ClosureMenuItem("Remove Metadata…") { chooseFiles("Choose files to inspect or clean") { MetadataWindow.present($0) } },
        ]
    }

    /// Images, video, audio and PDFs, mixed freely.
    static func accepts(_ files: [URL]) -> Bool {
        files.allAre(.image, .video, .audio, .pdf)
    }

    @MainActor
    private static func chooseFiles(_ message: String, then open: ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .audiovisualContent, .pdf]
        panel.message = message
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        let files = panel.urls.filter { accepts([$0]) }
        if !files.isEmpty { open(files) }
    }

    /// One window per tool and file set, so dropping the same files again focuses it.
    static func windowID(_ tool: String, _ files: [URL]) -> String {
        "compress.\(tool):" + files.map(\.path).joined(separator: "|")
    }
}

/// UserDefaults keys for the remembered compression choices.
enum CompressKey {
    static let mode = "compress.mode"                    // CompressionMode.rawValue
    static let imageStrength = "compress.image.strength" // CompressionStrength.rawValue
    static let videoStrength = "compress.video.strength" // CompressionStrength.rawValue (video and audio)
    static let imageSize = "compress.image.size"         // ImageSizeLimit.rawValue
    static let targetBytes = "compress.targetBytes"      // Int
    static let targetUnit = "compress.targetUnit"        // "KB" | "MB"
    static let targetPercent = "compress.targetPercent"  // Int 1...99
}
