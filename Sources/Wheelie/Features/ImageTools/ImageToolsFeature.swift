import AppKit
import SwiftUI
import WheelieCore

/// Image tools on the outer ring: Crop, Adjust, Annotate, Frame and Redact for one photo,
/// Collage for two or more. Each opens an editor window; exports keep the original format.
enum ImageToolsFeature: WheelieFeature {
    static func wheelItems() -> [WheelItem] {
        [
            single("image.crop", "Crop", "crop", order: 40) { CropEditorView.open($0) },
            single("image.adjust", "Adjust", "slider.horizontal.3", order: 41) { AdjustEditorView.open($0) },
            single("image.annotate", "Annotate", "pencil.tip.crop.circle", order: 42) { AnnotateEditorView.open($0) },
            single("image.frame", "Frame", "photo.artframe", order: 43) { FrameEditorView.open($0) },
            single("image.redact", "Redact", "eye.slash", order: 44) { RedactEditorView.open($0) },
            WheelItem(id: "image.collage", label: "Collage", symbol: "square.grid.2x2", order: 45,
                      accepts: { files in files.count >= 2 && files.count <= CollageEditorView.maxImages
                                     && files.allSatisfy(isEditableImage) },
                      perform: { files in
                          CollageEditorView.open(files)
                          return .none
                      }),
        ]
    }

    /// Raster images ImageIO can decode (SVG is an "image" to UTType but not to ImageIO).
    static func isEditableImage(_ url: URL) -> Bool {
        FileKind(url: url) == .image && !["svg", "svgz"].contains(url.pathExtension.lowercased())
    }

    private static func single(_ id: String, _ label: String, _ symbol: String, order: Int,
                               open: @escaping @MainActor (URL) -> Void) -> WheelItem {
        WheelItem(id: id, label: label, symbol: symbol, order: order,
                  accepts: { files in files.count == 1 && isEditableImage(files[0]) },
                  perform: { files in
                      open(files[0])
                      return .none
                  })
    }
}
