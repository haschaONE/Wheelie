import AppKit
import SwiftUI
import WheelieCore

/// Zoom/pan state shared by every lane of one editor (the Channels editor stacks two).
@MainActor
final class TimelineController: ObservableObject {
    @Published var viewport = TimelineViewport(duration: 1)
    private var frames: [UUID: CGRect] = [:]

    func setDuration(_ duration: Double) { viewport.setDuration(duration) }

    func register(_ id: UUID, frame: CGRect) { frames[id] = frame }
    func unregister(_ id: UUID) { frames[id] = nil }

    /// Keeps the playhead on screen while zoomed in.
    func follow(_ time: Double) {
        var next = viewport
        next.reveal(time)
        if next != viewport { viewport = next }
    }

    func zoom(by factor: Double, around anchor: Double?) {
        var next = viewport
        next.zoom(by: factor, around: anchor)
        viewport = next
    }

    func reset() { viewport.reset() }

    /// Scroll over a lane pans; with ⌘ or ⌥ it zooms around the pointer.
    func handleScroll(at point: CGPoint, event: NSEvent) -> Bool {
        guard let frame = frames.values.first(where: { $0.contains(point) }), frame.width > 0 else { return false }
        var dx = Double(event.scrollingDeltaX), dy = Double(event.scrollingDeltaY)
        if !event.hasPreciseScrollingDeltas { dx *= 10; dy *= 10 }
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
            let anchor = viewport.time(atFraction: Double((point.x - frame.minX) / frame.width))
            zoom(by: exp(dy * 0.01), around: anchor)
            return true
        }
        guard viewport.isZoomed else { return false }
        let delta = abs(dx) >= abs(dy) ? dx : dy
        var next = viewport
        next.pan(by: -delta / Double(frame.width) * viewport.length)
        viewport = next
        return true
    }
}

/// Maps between seconds and points inside one lane.
struct TimelineGeometry {
    let viewport: TimelineViewport
    let width: CGFloat
    let height: CGFloat

    func x(_ time: Double) -> CGFloat { CGFloat(viewport.fraction(of: time)) * width }
    func time(_ x: CGFloat) -> Double { viewport.time(atFraction: Double(x / max(width, 1))) }
    /// Seconds covered by `points` of width.
    func seconds(_ points: CGFloat) -> Double { Double(points / max(width, 1)) * viewport.length }
}

/// Draws peaks for the visible part of the timeline; one bar per point column.
struct WaveformCanvas: View {
    let peaks: [Float]
    let viewport: TimelineViewport
    var gain: Float = 1
    /// Peaks are drawn clipped here (a limiter's ceiling).
    var ceiling: Float = 1
    var color: Color = .accentColor

    var body: some View {
        Canvas { context, size in
            let count = peaks.count
            guard count > 0, size.width > 0 else { return }
            let mid = size.height / 2
            let half = size.height / 2 - 2
            let columns = Int(size.width.rounded(.up))
            let perSecond = Double(count) / viewport.duration
            var path = Path()
            for column in 0..<columns {
                let t0 = viewport.start + Double(column) / Double(size.width) * viewport.length
                let t1 = viewport.start + Double(column + 1) / Double(size.width) * viewport.length
                let b0 = min(count - 1, max(0, Int(t0 * perSecond)))
                let b1 = min(count, max(b0 + 1, Int((t1 * perSecond).rounded(.up))))
                var peak: Float = 0
                for i in b0..<b1 where peaks[i] > peak { peak = peaks[i] }
                let h = max(0.5, CGFloat(min(ceiling, peak * gain)) * half)
                path.addRect(CGRect(x: CGFloat(column), y: mid - h, width: 1, height: h * 2))
            }
            context.fill(path, with: .color(color))
        }
    }
}

/// One waveform lane: drag to move the playhead, pinch to zoom, double-click to reset the zoom.
/// `overlay` draws tool-specific things (trim handles, bleep ranges) above the waveform.
struct WaveformLane<Overlay: View>: View {
    @ObservedObject var timeline: TimelineController
    let player: AudioPlayback
    var peaks: [Float]?
    var gain: Float = 1
    var ceiling: Float = 1
    var color: Color = .accentColor
    /// Drawn behind `peaks` (e.g. the original under a normalized preview).
    var backgroundPeaks: [Float]? = nil
    var isLoading = false
    var accessibilityName = "Audio waveform layer. Drag to move the playhead."
    @ViewBuilder var overlay: (TimelineGeometry) -> Overlay

    @State private var id = UUID()
    @State private var pinchBase: TimelineViewport?
    @State private var pinchAnchor = 0.0

    var body: some View {
        GeometryReader { geo in
            let g = TimelineGeometry(viewport: timeline.viewport, width: geo.size.width, height: geo.size.height)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
                Rectangle()
                    .fill(Color(nsColor: .separatorColor))
                    .frame(height: 1)
                    .offset(y: geo.size.height / 2)
                if let backgroundPeaks {
                    WaveformCanvas(peaks: backgroundPeaks, viewport: timeline.viewport, color: .secondary.opacity(0.35))
                }
                if let peaks {
                    WaveformCanvas(peaks: peaks, viewport: timeline.viewport, gain: gain, ceiling: ceiling, color: color)
                } else if isLoading {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Loading waveform").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }
                overlay(g)
                PlayheadView(player: player, geometry: g)
                    .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .coordinateSpace(name: "lane")
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("lane")).onChanged { value in
                NSApp.keyWindow?.makeFirstResponder(nil)
                player.seek(to: g.time(value.location.x))
            })
            .simultaneousGesture(MagnifyGesture().onChanged { value in
                if pinchBase == nil {
                    pinchBase = timeline.viewport
                    pinchAnchor = g.time(value.startLocation.x)
                }
                var next = pinchBase!
                next.zoom(by: value.magnification, around: pinchAnchor)
                timeline.viewport = next
            }.onEnded { _ in pinchBase = nil })
            .simultaneousGesture(TapGesture(count: 2).onEnded { timeline.reset() })
            .onAppear { timeline.register(id, frame: geo.frame(in: .global)) }
            .onChange(of: geo.frame(in: .global)) { _, frame in timeline.register(id, frame: frame) }
            .onDisappear { timeline.unregister(id) }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(accessibilityName)
            .help("Drag to move the playhead. Pinch or ⌘-scroll to zoom, scroll to pan, double-click to reset the zoom.")
        }
    }
}

extension WaveformLane where Overlay == EmptyView {
    init(timeline: TimelineController, player: AudioPlayback, peaks: [Float]?, gain: Float = 1,
         color: Color = .accentColor, isLoading: Bool = false) {
        self.init(timeline: timeline, player: player, peaks: peaks, gain: gain, color: color,
                  isLoading: isLoading, overlay: { _ in EmptyView() })
    }
}

struct PlayheadView: View {
    @ObservedObject var player: AudioPlayback
    let geometry: TimelineGeometry

    var body: some View {
        let x = geometry.x(player.currentTime)
        if x >= -2, x <= geometry.width + 2 {
            ZStack(alignment: .top) {
                Rectangle().fill(Color.primary).frame(width: 1.5)
                Triangle().fill(Color.primary).frame(width: 9, height: 6)
            }
            .frame(width: 9, height: geometry.height)
            .offset(x: x - 4.5)
            .accessibilityHidden(true)
        }
    }
}

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            p.closeSubpath()
        }
    }
}

/// Time labels above the lanes.
struct TimeRuler: View {
    @ObservedObject var timeline: TimelineController

    var body: some View {
        Canvas { context, size in
            let vp = timeline.viewport
            let maxLabels = max(1, Double(size.width) / 78)
            let steps = [0.01, 0.02, 0.05, 0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200]
            let step = steps.first { vp.length / $0 <= maxLabels } ?? 7200
            let decimals = step < 0.1 ? 2 : (step < 1 ? 1 : 0)
            var t = (vp.start / step).rounded(.up) * step
            while t <= vp.end + 1e-9 {
                let x = CGFloat(vp.fraction(of: t)) * size.width
                context.fill(Path(CGRect(x: x, y: size.height - 4, width: 1, height: 4)), with: .color(.secondary))
                if x < size.width - 30 {
                    context.draw(Text(Timecode.string(t, decimals: decimals)).font(.system(size: 9).monospacedDigit())
                                    .foregroundColor(.secondary),
                                 at: CGPoint(x: x + 3, y: 0), anchor: .topLeading)
                }
                t += step
            }
        }
        .frame(height: 14)
        .accessibilityHidden(true)
    }
}

/// Play/pause, time, and zoom controls under the lanes.
struct TransportBar<Leading: View, Trailing: View>: View {
    @ObservedObject var player: AudioPlayback
    @ObservedObject var timeline: TimelineController
    let duration: Double
    var playHelp = "Play or pause (Space)"
    let onPlay: () -> Void
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onPlay) {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 18)
            }
            .help(playHelp)
            .accessibilityLabel(player.isPlaying ? "Pause preview (Space)" : "Play preview (Space)")
            .disabled(!player.canPlay)
            Text("\(Timecode.string(player.currentTime)) / \(Timecode.string(duration))")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel("Playback position \(Timecode.string(player.currentTime))")
            if player.isPreparing {
                ProgressView().controlSize(.small)
                Text("Updating preview…").font(.caption).foregroundStyle(.secondary)
            }
            leading()
            Spacer(minLength: 8)
            trailing()
            ControlGroup {
                Button { timeline.zoom(by: 0.5, around: player.currentTime) } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .help("Zoom out")
                .disabled(!timeline.viewport.isZoomed)
                Button { timeline.zoom(by: 2, around: player.currentTime) } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .help("Zoom in (or pinch on the waveform)")
                .disabled(timeline.viewport.length <= timeline.viewport.minimumLength * 1.01)
            }
            .frame(width: 70)
            if timeline.viewport.isZoomed {
                Button("Fit") { timeline.reset() }
                    .help("Show the whole file (or double-click the waveform)")
            }
        }
        .controlSize(.regular)
    }
}

/// Play/stop button for one of several previews; only this small view follows the player's state.
struct PreviewToggle: View {
    @ObservedObject var player: AudioPlayback
    let active: Bool
    var iconOnly = false
    let title: String
    let activeTitle: String
    let help: String
    let action: () -> Void

    var body: some View {
        let playing = active && player.isPlaying
        Button(action: action) {
            if iconOnly {
                Image(systemName: playing ? "stop.fill" : "play.fill").frame(width: 14)
            } else {
                Label(playing ? activeTitle : title, systemImage: playing ? "stop.fill" : "play.fill")
            }
        }
        .help(playing ? activeTitle : help)
        .accessibilityLabel(playing ? activeTitle : title)
        .disabled(!player.canPlay)
    }
}

extension TransportBar where Leading == EmptyView, Trailing == EmptyView {
    init(player: AudioPlayback, timeline: TimelineController, duration: Double, playHelp: String = "Play or pause (Space)",
         onPlay: @escaping () -> Void) {
        self.init(player: player, timeline: timeline, duration: duration, playHelp: playHelp, onPlay: onPlay,
                  leading: { EmptyView() }, trailing: { EmptyView() })
    }
}
