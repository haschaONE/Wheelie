import SwiftUI
import WheelieCore

/// Converts between seconds and x positions on a timeline of `width` points.
struct VideoToolsTimelineGeometry {
    /// Coordinate space of the timeline; overlay gestures should use it.
    static let space = "videoTimeline"

    let width: CGFloat
    let duration: Double

    func x(_ time: Double) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(min(max(0, time), duration) / duration) * width
    }

    func time(_ x: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return min(max(0, Double(x / width)), 1) * duration
    }
}

/// Scrubbable filmstrip with a playhead. Editors draw their handles, markers and
/// ranges in `overlay`, using the geometry and the `VideoToolsTimelineGeometry.space` coordinate space.
struct VideoToolsTimeline<Overlay: View>: View {

    @ObservedObject var player: VideoToolsPlayer
    var height: CGFloat = 54
    /// Called with the time of a click (a drag shorter than 3 points).
    var onTap: ((Double) -> Void)?
    var overlay: (VideoToolsTimelineGeometry) -> Overlay

    init(player: VideoToolsPlayer, height: CGFloat = 54, onTap: ((Double) -> Void)? = nil,
         @ViewBuilder overlay: @escaping (VideoToolsTimelineGeometry) -> Overlay) {
        self.player = player
        self.height = height
        self.onTap = onTap
        self.overlay = overlay
    }

    var body: some View {
        GeometryReader { geo in
            let g = VideoToolsTimelineGeometry(width: geo.size.width, duration: player.duration)
            ZStack(alignment: .topLeading) {
                VideoToolsFilmstrip(thumbnails: player.thumbnails, height: height)
                    .frame(width: geo.size.width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named(VideoToolsTimelineGeometry.space))
                            .onChanged { player.scrub(to: g.time($0.location.x)) }
                            .onEnded { value in
                                player.endScrub()
                                if abs(value.translation.width) < 3 { onTap?(g.time(value.location.x)) }
                            }
                    )
                overlay(g)
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 2, height: height + 8)
                    .shadow(color: .black.opacity(0.6), radius: 1.5)
                    .offset(x: g.x(player.currentTime) - 1, y: -4)
                    .allowsHitTesting(false)
            }
            .coordinateSpace(name: VideoToolsTimelineGeometry.space)
        }
        .frame(height: height)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Video timeline. Drag to scrub.")
        .accessibilityValue(VideoToolTimecode.format(player.currentTime))
        .accessibilityAdjustableAction { direction in
            player.step(direction == .increment ? 1 : -1, seconds: true)
        }
    }
}

extension VideoToolsTimeline where Overlay == EmptyView {
    init(player: VideoToolsPlayer, height: CGFloat = 54, onTap: ((Double) -> Void)? = nil) {
        self.init(player: player, height: height, onTap: onTap) { _ in EmptyView() }
    }
}

struct VideoToolsFilmstrip: View {
    let thumbnails: [CGImage?]
    let height: CGFloat

    var body: some View {
        GeometryReader { geo in
            let count = max(thumbnails.count, 1)
            let cell = geo.size.width / CGFloat(count)
            HStack(spacing: 0) {
                ForEach(0..<count, id: \.self) { index in
                    ZStack {
                        Color(white: 0.16)
                        if index < thumbnails.count, let image = thumbnails[index] {
                            Image(decorative: image, scale: 1)
                                .resizable()
                                .scaledToFill()
                        }
                    }
                    .frame(width: cell, height: height)
                    .clipped()
                }
            }
        }
        .accessibilityLabel("Video thumbnail timeline")
    }
}

/// Play/pause, frame stepping and the time readout.
struct VideoToolsTransportBar<Trailing: View>: View {
    @ObservedObject var player: VideoToolsPlayer
    var trailing: Trailing

    init(player: VideoToolsPlayer, @ViewBuilder trailing: () -> Trailing) {
        self.player = player
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 10) {
            Button { player.step(-1) } label: { Image(systemName: "backward.frame.fill") }
                .help("Previous frame (←)")
                .accessibilityLabel("Previous frame")
            Button { player.togglePlay() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 16)
            }
            .help(player.isPlaying ? "Pause preview (Space)" : "Play preview (Space)")
            .accessibilityLabel(player.isPlaying ? "Pause preview (Space)" : "Play preview (Space)")
            .disabled(!player.canPlay)
            Button { player.step(1) } label: { Image(systemName: "forward.frame.fill") }
                .help("Next frame (→)")
                .accessibilityLabel("Next frame")
            Text("\(VideoToolTimecode.format(player.currentTime)) / \(VideoToolTimecode.format(player.duration))")
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .accessibilityLabel("Playhead position \(VideoToolTimecode.format(player.currentTime)) of \(VideoToolTimecode.format(player.duration))")
            Spacer(minLength: 8)
            trailing
        }
        .buttonStyle(.borderless)
        .disabled(player.state != .ready)
    }
}

extension VideoToolsTransportBar where Trailing == EmptyView {
    init(player: VideoToolsPlayer) {
        self.init(player: player) { EmptyView() }
    }
}

/// Text field for a time ("1:05.25", "65.25" or "65.25s"); commits on Return or focus loss.
struct VideoToolsTimeField: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(title, text: $text)
            .font(.system(.body, design: .monospaced))
            .frame(width: 92)
            .focused($focused)
            .onSubmit(commit)
            .onChange(of: focused) { if !focused { commit() } }
            .onChange(of: value) { if !focused { text = VideoToolTimecode.format(value) } }
            .onAppear { text = VideoToolTimecode.format(value) }
            .accessibilityLabel("\(title) time in seconds")
    }

    private func commit() {
        if let parsed = VideoToolTimecode.parse(text) {
            value = min(max(parsed, range.lowerBound), range.upperBound)
        }
        text = VideoToolTimecode.format(value)
    }
}

/// Integer pixel field; commits on Return or focus loss.
struct VideoToolsPixelField: View {
    let title: String
    @Binding var value: Int
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(title).foregroundStyle(.secondary)
            TextField(title, text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(width: 58)
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { if !focused { commit() } }
                .onChange(of: value) { if !focused { text = String(value) } }
                .onAppear { text = String(value) }
                .accessibilityLabel(title)
        }
    }

    private func commit() {
        if let parsed = Int(text.trimmingCharacters(in: .whitespaces)) { value = parsed }
        text = String(value)
    }
}
