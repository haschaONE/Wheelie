import AVFoundation
import AppKit
import SwiftUI
import WheelieCore

/// Maps between the preview's view points and the video's pixel grid.
struct VideoToolsPixelMapping {
    /// Coordinate space of preview overlays (origin = preview's top-left).
    static let space = "videoPreview"

    /// Where the picture is drawn, in the preview's coordinates.
    let videoRect: CGRect
    /// Displayed frame size in pixels.
    let pixelSize: CGSize

    var scaleX: CGFloat { videoRect.width / max(pixelSize.width, 1) }
    var scaleY: CGFloat { videoRect.height / max(pixelSize.height, 1) }

    func pixelPoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - videoRect.minX) / scaleX, y: (p.y - videoRect.minY) / scaleY)
    }

    func viewRect(_ r: CGRect) -> CGRect {
        CGRect(x: videoRect.minX + r.minX * scaleX, y: videoRect.minY + r.minY * scaleY,
               width: r.width * scaleX, height: r.height * scaleY)
    }

    func pixelDelta(_ size: CGSize) -> CGSize { CGSize(width: size.width / scaleX, height: size.height / scaleY) }
}

/// Aspect-fit preview of the player (or ffmpeg still frames), with an overlay that
/// receives the pixel mapping (crop rectangle, redaction boxes).
struct VideoToolsPreview<Overlay: View>: View {
    @ObservedObject var player: VideoToolsPlayer
    /// Shown when AVFoundation can't play the file, e.g. "…You can still export the selected range."
    var unavailableMessage: String
    var overlay: (VideoToolsPixelMapping) -> Overlay

    init(player: VideoToolsPlayer, unavailableMessage: String,
         @ViewBuilder overlay: @escaping (VideoToolsPixelMapping) -> Overlay) {
        self.player = player
        self.unavailableMessage = unavailableMessage
        self.overlay = overlay
    }

    var body: some View {
        GeometryReader { geo in
            let rect = Self.fit(aspect: player.displayAspect, in: geo.size)
            let mapping = VideoToolsPixelMapping(videoRect: rect, pixelSize: player.pixelSize)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8).fill(Color.black)
                switch player.state {
                case .loading:
                    ProgressView("Loading video…")
                        .controlSize(.small)
                        .foregroundStyle(.white)
                        .frame(width: geo.size.width, height: geo.size.height)
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.white)
                        .padding()
                        .frame(width: geo.size.width, height: geo.size.height)
                case .ready:
                    picture
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                        .accessibilityLabel("Video preview at \(VideoToolTimecode.format(player.currentTime))")
                    overlay(mapping)
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                        .coordinateSpace(name: VideoToolsPixelMapping.space)
                    if !player.canPlay {
                        Text(unavailableMessage)
                            .font(.caption)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(.black.opacity(0.65), in: Capsule())
                            .foregroundStyle(.white)
                            .frame(width: geo.size.width)
                            .padding(.top, 8)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
        // Overlay handles may sit on the edge, so only the backdrop is rounded, not clipped.
        .padding(4)
    }

    @ViewBuilder private var picture: some View {
        if player.canPlay, let avPlayer = player.player {
            VideoToolsPlayerLayer(player: avPlayer)
        } else if let still = player.stillFrame {
            Image(decorative: still, scale: 1).resizable()
        } else {
            ProgressView().controlSize(.small)
        }
    }

    static func fit(aspect: Double, in size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0, aspect > 0 else { return .zero }
        var w = size.width, h = size.width / aspect
        if h > size.height { h = size.height; w = h * aspect }
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }
}

extension VideoToolsPreview where Overlay == EmptyView {
    init(player: VideoToolsPlayer, unavailableMessage: String) {
        self.init(player: player, unavailableMessage: unavailableMessage) { _ in EmptyView() }
    }
}

/// AVPlayerLayer host. It ignores the mouse so SwiftUI overlays get every event.
struct VideoToolsPlayerLayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerLayerHostView {
        let view = PlayerLayerHostView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: PlayerLayerHostView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }

    final class PlayerLayerHostView: NSView {
        let playerLayer = AVPlayerLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer = CALayer()
            layer?.backgroundColor = NSColor.black.cgColor
            playerLayer.videoGravity = .resizeAspect
            layer?.addSublayer(playerLayer)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            CATransaction.commit()
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
