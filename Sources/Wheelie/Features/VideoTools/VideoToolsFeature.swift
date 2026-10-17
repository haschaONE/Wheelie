import AppKit
import SwiftUI
import WheelieCore

/// Video tools on the outer ring: Trim, Split, Join, Speed, Mute, Crop, Snapshot, Redact.
/// Every tool except Mute opens an editor window; exports go through `AppServices.run`.
enum VideoToolsFeature: WheelieFeature {
    nonisolated static let editorSize = CGSize(width: 860, height: 680)

    static func wheelItems() -> [WheelItem] {
        [
            editor("trim", label: "Trim", symbol: "scissors", order: 40, title: "Trim Video") {
                VideoTrimEditor(url: $0, windowID: $1)
            },
            editor("split", label: "Split", symbol: "rectangle.split.3x1", order: 41, title: "Split Video",
                   size: CGSize(width: 880, height: 720)) {
                VideoSplitEditor(url: $0, windowID: $1)
            },
            WheelItem(id: "video.join", label: "Join", symbol: "film.stack", order: 42,
                      accepts: { $0.count >= 2 && $0.allAre(.video) },
                      perform: { files in
                          openJoin(files)
                          return .none
                      }),
            editor("speed", label: "Speed", symbol: "speedometer", order: 43, title: "Change Video Speed") {
                VideoSpeedEditor(url: $0, windowID: $1)
            },
            WheelItem(id: "video.mute", label: "Mute", symbol: "speaker.slash", order: 44,
                      accepts: { $0.allAre(.video) },
                      perform: { files in .outputs(try await VideoToolOps.mute(files)) }),
            editor("crop", label: "Crop", symbol: "crop", order: 45, title: "Crop Video",
                   size: CGSize(width: 860, height: 700)) {
                VideoCropEditor(url: $0, windowID: $1)
            },
            editor("snapshot", label: "Snapshot", symbol: "camera", order: 46, title: "Video Snapshots",
                   size: CGSize(width: 860, height: 700)) {
                VideoSnapshotEditor(url: $0, windowID: $1)
            },
            editor("redact", label: "Redact", symbol: "eye.slash", order: 47, title: "Redact Video",
                   size: CGSize(width: 900, height: 720)) {
                VideoRedactEditor(url: $0, windowID: $1)
            },
        ]
    }

    /// A single-video tool that opens `content` in window "video.<tool>:<path>".
    private static func editor<V: View>(_ tool: String, label: String, symbol: String, order: Int, title: String,
                                        size: CGSize = editorSize,
                                        content: @escaping @MainActor (URL, String) -> V) -> WheelItem {
        WheelItem(id: "video.\(tool)", label: label, symbol: symbol, order: order,
                  accepts: { $0.count == 1 && $0.allAre(.video) },
                  perform: { files in
                      guard let file = files.first else { return .none }
                      let id = "video.\(tool):" + file.path
                      AppServices.shared.presentWindow(id: id, title: "\(title) — \(file.lastPathComponent)", size: size) {
                          content(file, id)
                      }
                      return .none
                  })
    }

    static func openJoin(_ files: [URL]) {
        let id = "video.join:" + files.map(\.path).joined(separator: "|")
        AppServices.shared.presentWindow(id: id, title: "Join \(files.count) Videos", size: CGSize(width: 900, height: 600)) {
            VideoJoinEditor(urls: files, windowID: id)
        }
    }

}
