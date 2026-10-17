import SwiftUI
import WheelieCore

/// Split: split points on the timeline, a clip list, and export as separate clips
/// or with removed clips cut out ("join the rest into one video").
struct VideoSplitEditor: View {
    let url: URL
    let windowID: String
    @StateObject private var player: VideoToolsPlayer
    @StateObject private var exporter = VideoToolsExporter()
    @State private var points: [Double] = []
    @State private var removed: Set<Int> = []
    @State private var selectedClip: Int?
    @State private var mode: VideoSplitExportMode = .separate
    @State private var addError: String?
    @AppStorage("videoSplit.accurate") private var accurate = true

    init(url: URL, windowID: String) {
        self.url = url
        self.windowID = windowID
        _player = StateObject(wrappedValue: VideoToolsPlayer(url: url))
    }

    private var clips: [VideoClipRange] { VideoSplitPlan.clips(points: points, duration: player.duration) }
    private var keptCount: Int { clips.indices.filter { !removed.contains($0) }.count }

    private var exportLabel: String {
        switch mode {
        case .separate: return keptCount == 1 ? "Export 1 Clip" : "Export \(keptCount) Clips"
        case .joinRest: return "Export One Video"
        }
    }

    var body: some View {
        VideoToolsShell(windowID: windowID, exporter: exporter, player: player, exportLabel: exportLabel,
                         blocker: player.duration > 0
                            ? VideoSplitPlan.exportError(points: points, removed: removed, mode: mode, duration: player.duration)
                            : nil,
                         hint: "Click a clip in the timeline and press Delete to remove it. Space plays the result.",
                         onExport: export, onKey: handleKey) {
            VStack(spacing: 10) {
                VideoToolsPreview(player: player, unavailableMessage:
                    "Video preview is unavailable for this file. You can still split and export it.")
                    .frame(minHeight: 220)
                VideoToolsTimeline(player: player, onTap: selectClip(at:)) { g in
                    VideoSplitOverlay(geometry: g, clips: clips, removed: removed, selected: selectedClip,
                                      points: $points, height: 54, player: player, onRemovePoint: removePoint)
                }
                .padding(.horizontal, 12)
                .accessibilityIdentifier("videoSplitTimeline")
                VideoToolsTransportBar(player: player) {
                    if let addError {
                        Text(addError).font(.caption).foregroundStyle(.red).lineLimit(1)
                    }
                    Button {
                        addSplit()
                    } label: {
                        Label("Add Split at Playhead", systemImage: "scissors")
                    }
                    .help("Split the video at the playhead (S)")
                    Button("Clear Splits") {
                        points = []
                        removed = []
                        selectedClip = nil
                        syncSkips()
                    }
                    .disabled(points.isEmpty)
                }
            }
        } controls: {
            HStack(alignment: .top, spacing: 16) {
                clipList
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Export", selection: $mode) {
                        ForEach(VideoSplitExportMode.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.radioGroup)
                    Toggle("Accurate (re-encode)", isOn: $accurate)
                        .disabled(mode == .joinRest)
                        .help(mode == .joinRest
                              ? "Joining always re-encodes."
                              : "Off: copy the streams without re-encoding (fast, cuts snap to keyframes).")
                }
                .frame(width: 250, alignment: .leading)
            }
        }
        .frame(minWidth: 700, idealWidth: 880, minHeight: 620, idealHeight: 720)
        .onChange(of: points) { syncSkips() }
    }

    private var clipList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(clips.enumerated()), id: \.offset) { index, clip in
                        clipRow(index, clip).id(index)
                    }
                }
            }
            .frame(height: 112)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .onChange(of: selectedClip) { if let selectedClip { proxy.scrollTo(selectedClip) } }
        }
    }

    private func clipRow(_ index: Int, _ clip: VideoClipRange) -> some View {
        let isRemoved = removed.contains(index)
        return HStack(spacing: 10) {
            Text("Clip \(index + 1)").fontWeight(.medium)
            Text("\(VideoToolTimecode.format(clip.start)) – \(VideoToolTimecode.format(clip.end))")
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(VideoToolTimecode.compact(clip.duration, maxFractionDigits: 2) + " s")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button(isRemoved ? "Restore" : "Remove") { toggleRemoved(index) }
                .buttonStyle(.borderless)
                .accessibilityLabel(isRemoved ? "Restore clip \(index + 1)" : "Remove clip \(index + 1)")
        }
        .strikethrough(isRemoved)
        .opacity(isRemoved ? 0.55 : 1)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(selectedClip == index ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture {
            selectedClip = index
            player.seek(to: clip.start)
        }
    }

    // MARK: Editing

    private func addSplit() {
        let t = player.currentTime
        if let error = VideoSplitPlan.insertionError(t, into: points, duration: player.duration) {
            addError = error
            return
        }
        addError = nil
        // The clip containing t becomes two; later clip indices shift by one.
        let clipIndex = points.filter { $0 < t }.count
        removed = Set(removed.flatMap { i -> [Int] in
            if i < clipIndex { return [i] }
            if i == clipIndex { return [i, i + 1] }
            return [i + 1]
        })
        points.append(t)
        points.sort()
        selectedClip = clipIndex + 1
        syncSkips()
    }

    private func removePoint(_ index: Int) {
        guard points.indices.contains(index) else { return }
        // Clips index and index+1 merge; the merged clip stays removed only if both were.
        let bothRemoved = removed.contains(index) && removed.contains(index + 1)
        removed = Set(removed.compactMap { i -> Int? in
            if i < index { return i }
            if i == index || i == index + 1 { return bothRemoved ? index : nil }
            return i - 1
        })
        points.remove(at: index)
        selectedClip = nil
        addError = nil
        syncSkips()
    }

    private func toggleRemoved(_ index: Int) {
        if removed.contains(index) { removed.remove(index) } else { removed.insert(index) }
        selectedClip = index
        syncSkips()
    }

    private func selectClip(at time: Double) {
        selectedClip = clips.firstIndex { time >= $0.start && time < $0.end } ?? clips.indices.last
    }

    private func syncSkips() {
        player.skipRanges = clips.indices.filter { removed.contains($0) }.map { clips[$0].start...clips[$0].end }
    }

    private func handleKey(_ key: VideoToolsKey) -> Bool {
        switch key {
        case .character("s"): addSplit()
        case .delete:
            guard let selectedClip else { return false }
            toggleRemoved(selectedClip)
        default: return false
        }
        return true
    }

    private func export() {
        let (url, points, removed, mode, accurate) = (url, points, removed, mode, accurate)
        exporter.start(windowID: windowID, title: "Split", sources: [url]) { progress in
            try await VideoToolOps.split(url, points: points, removed: removed, mode: mode, accurate: accurate,
                                         progress: progress)
        }
    }
}

/// Clip shading, numbers and draggable split markers on the timeline.
struct VideoSplitOverlay: View {
    let geometry: VideoToolsTimelineGeometry
    let clips: [VideoClipRange]
    let removed: Set<Int>
    let selected: Int?
    @Binding var points: [Double]
    let height: CGFloat
    let player: VideoToolsPlayer
    let onRemovePoint: (Int) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(clips.enumerated()), id: \.offset) { index, clip in
                let x0 = geometry.x(clip.start), x1 = geometry.x(clip.end)
                ZStack(alignment: .bottomLeading) {
                    if removed.contains(index) {
                        Rectangle().fill(.black.opacity(0.62))
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white.opacity(0.8))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    if selected == index {
                        RoundedRectangle(cornerRadius: 4).strokeBorder(Color.accentColor, lineWidth: 3)
                    }
                    if clips.count > 1, x1 - x0 > 18 {
                        Text("\(index + 1)")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 4)
                            .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(.white)
                            .padding(3)
                    }
                }
                .frame(width: max(1, x1 - x0), height: height, alignment: .bottomLeading)
                .offset(x: x0)
                .accessibilityElement()
                .accessibilityLabel(removed.contains(index) ? "Clip removed at \(VideoToolTimecode.format(clip.start))"
                                                            : "Clip \(index + 1) at \(VideoToolTimecode.format(clip.start))")
            }
        }
        .allowsHitTesting(false)
        ForEach(Array(points.enumerated()), id: \.offset) { index, point in
            marker(index: index)
                .offset(x: geometry.x(point) - 5)
        }
    }

    private func marker(index: Int) -> some View {
        ZStack {
            Capsule().fill(Color.white).frame(width: 3, height: height + 6)
            Circle().fill(Color.white).frame(width: 10, height: 10).offset(y: -height / 2 - 3)
        }
        .frame(width: 10, height: height)
        .shadow(color: .black.opacity(0.5), radius: 1)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .named(VideoToolsTimelineGeometry.space))
                .onChanged { value in
                    guard points.indices.contains(index) else { return }
                    let gap = VideoSplitPlan.minimumGap
                    let lower = (index > 0 ? points[index - 1] : 0) + gap
                    let upper = (index + 1 < points.count ? points[index + 1] : geometry.duration) - gap
                    guard lower <= upper else { return }
                    let t = min(max(geometry.time(value.location.x), lower), upper)
                    points[index] = t
                    player.scrub(to: t)
                }
                .onEnded { _ in player.endScrub() }
        )
        .contextMenu {
            Button("Remove Split Point") { onRemovePoint(index) }
        }
        .videoCursor(.resizeLeftRight)
        .help("Drag to move this split. Right-click to remove it.")
        .accessibilityElement()
        .accessibilityLabel("Split point \(index + 1)")
        .accessibilityValue(points.indices.contains(index) ? VideoToolTimecode.format(points[index]) : "")
        .accessibilityAction(named: "Remove Split Point") { onRemovePoint(index) }
    }
}
