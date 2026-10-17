import AppKit
import SwiftUI
import WheelieCore

/// Trim: in/out handles on the timeline, numeric fields, looping preview of the selection.
struct VideoTrimEditor: View {
    let url: URL
    let windowID: String
    @StateObject private var player: VideoToolsPlayer
    @StateObject private var exporter = VideoToolsExporter()
    @State private var start: Double = 0
    @State private var end: Double = 0
    @AppStorage("videoTrim.accurate") private var accurate = true

    init(url: URL, windowID: String) {
        self.url = url
        self.windowID = windowID
        _player = StateObject(wrappedValue: VideoToolsPlayer(url: url))
    }

    private var minimumLength: Double { VideoSplitPlan.minimumGap }

    private var blocker: String? {
        guard player.duration > 0 else { return nil }
        if end - start < minimumLength - 1e-6 { return VideoToolError.invalidRange.message }
        if start <= 0.001 && end >= player.duration - 0.001 {
            return "Drag the yellow handles, or press I and O, to choose the part to keep."
        }
        return nil
    }

    var body: some View {
        VideoToolsShell(windowID: windowID, exporter: exporter, player: player,
                         exportLabel: "Export Trimmed Video", blocker: blocker,
                         hint: "Press I and O to set the start and end at the playhead.",
                         onExport: export, onKey: handleKey) {
            VStack(spacing: 10) {
                VideoToolsPreview(player: player, unavailableMessage:
                    "Video preview is unavailable for this file. You can still export the selected range.")
                    .frame(minHeight: 240)
                VideoToolsTimeline(player: player) { g in
                    VideoTrimRangeOverlay(geometry: g, start: $start, end: $end, height: 54,
                                      minimumLength: minimumLength, player: player)
                }
                .padding(.horizontal, 12)
                VideoToolsTransportBar(player: player) {
                    Button("Play Selection") { player.seek(to: start); player.play() }
                        .disabled(!player.canPlay)
                }
            }
        } controls: {
            HStack(spacing: 18) {
                HStack(spacing: 6) {
                    Text("Start")
                    VideoToolsTimeField(title: "Start", value: startBinding, range: 0...max(0, end - minimumLength))
                    Button { setStart(player.currentTime) } label: { Image(systemName: "arrow.right.to.line") }
                        .help("Set start to the playhead (I)")
                        .accessibilityLabel("Set start to the playhead")
                }
                HStack(spacing: 6) {
                    Text("End")
                    VideoToolsTimeField(title: "End", value: endBinding, range: min(player.duration, start + minimumLength)...max(player.duration, 0))
                    Button { setEnd(player.currentTime) } label: { Image(systemName: "arrow.left.to.line") }
                        .help("Set end to the playhead (O)")
                        .accessibilityLabel("Set end to the playhead")
                }
                Text("Length \(VideoToolTimecode.format(max(0, end - start)))")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("Accurate (re-encode)", isOn: $accurate)
                    .help(accurate
                          ? "Cuts on the exact frames. Re-encodes unless the start is already on a keyframe."
                          : "Copies the streams without re-encoding: fast and lossless, but the start snaps to the keyframe before it.")
            }
            .buttonStyle(.borderless)
        }
        .frame(minWidth: 680, idealWidth: 860, minHeight: 560, idealHeight: 660)
        .onChange(of: player.duration) {
            if end == 0 { end = player.duration }
            updateLoop()
        }
    }

    private var startBinding: Binding<Double> {
        Binding(get: { start }, set: { setStart($0) })
    }

    private var endBinding: Binding<Double> {
        Binding(get: { end }, set: { setEnd($0) })
    }

    private func setStart(_ t: Double) {
        start = min(max(0, t), max(0, end - minimumLength))
        updateLoop()
        player.seek(to: start)
    }

    private func setEnd(_ t: Double) {
        end = max(min(player.duration, t), min(player.duration, start + minimumLength))
        updateLoop()
        player.seek(to: max(start, end - player.frameDuration))
    }

    private func updateLoop() {
        player.loopRange = end > start ? start...end : nil
    }

    private func handleKey(_ key: VideoToolsKey) -> Bool {
        switch key {
        case .character("i"): setStart(player.currentTime)
        case .character("o"): setEnd(player.currentTime)
        default: return false
        }
        return true
    }

    private func export() {
        let (url, start, end, accurate) = (url, start, end, accurate)
        exporter.start(windowID: windowID, title: "Trim", sources: [url]) { progress in
            [try await VideoToolOps.trim(url, start: start, end: end, accurate: accurate, progress: progress)]
        }
    }
}

/// Dims everything outside start...end and adds draggable yellow handles on both ends.
struct VideoTrimRangeOverlay: View {
    let geometry: VideoToolsTimelineGeometry
    @Binding var start: Double
    @Binding var end: Double
    let height: CGFloat
    let minimumLength: Double
    let player: VideoToolsPlayer

    var body: some View {
        let x0 = geometry.x(start), x1 = geometry.x(end)
        ZStack(alignment: .topLeading) {
            Rectangle().fill(.black.opacity(0.55))
                .frame(width: max(0, x0), height: height)
            Rectangle().fill(.black.opacity(0.55))
                .frame(width: max(0, geometry.width - x1), height: height)
                .offset(x: x1)
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Color.yellow, lineWidth: 3)
                .frame(width: max(x1 - x0, 4), height: height)
                .offset(x: x0)
        }
        .allowsHitTesting(false)
        handle(isStart: true).offset(x: x0 - 12)
        handle(isStart: false).offset(x: x1)
    }

    private func handle(isStart: Bool) -> some View {
        UnevenRoundedRectangle(topLeadingRadius: isStart ? 5 : 0, bottomLeadingRadius: isStart ? 5 : 0,
                               bottomTrailingRadius: isStart ? 0 : 5, topTrailingRadius: isStart ? 0 : 5)
            .fill(Color.yellow)
            .frame(width: 12, height: height)
            .overlay(Image(systemName: isStart ? "chevron.compact.left" : "chevron.compact.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.black.opacity(0.7)))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(VideoToolsTimelineGeometry.space))
                    .onChanged { value in
                        let t = geometry.time(value.location.x + (isStart ? 6 : -6))
                        if isStart {
                            start = min(max(0, t), max(0, end - minimumLength))
                            player.scrub(to: start)
                        } else {
                            end = max(min(geometry.duration, t), min(geometry.duration, start + minimumLength))
                            player.scrub(to: max(start, end - player.frameDuration))
                        }
                        player.loopRange = start...end
                    }
                    .onEnded { _ in player.endScrub() }
            )
            .videoCursor(.resizeLeftRight)
            .accessibilityElement()
            .accessibilityLabel(isStart ? "Trim start" : "Trim end")
            .accessibilityValue(VideoToolTimecode.format(isStart ? start : end))
            .accessibilityAdjustableAction { direction in
                let step = direction == .increment ? 0.1 : -0.1
                if isStart { start = min(max(0, start + step), max(0, end - minimumLength)) }
                else { end = max(min(geometry.duration, end + step), start + minimumLength) }
            }
    }
}

extension View {
    /// Shows `cursor` while the pointer is over the view.
    func videoCursor(_ cursor: NSCursor) -> some View {
        onHover { inside in
            if inside { cursor.push() } else { NSCursor.pop() }
        }
    }
}
