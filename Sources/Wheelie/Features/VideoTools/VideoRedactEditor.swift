import AppKit
import SwiftUI
import WheelieCore

/// Redact: draw rectangles on the preview, give each a time range (fields or timeline
/// lanes) and hide them with blur, pixelation or black boxes.
struct VideoRedactEditor: View {
    let url: URL
    let windowID: String
    @StateObject private var player: VideoToolsPlayer
    @StateObject private var exporter = VideoToolsExporter()
    @State private var boxes: [VideoRedactBox] = []
    @State private var selected: UUID?
    @AppStorage("videoRedact.style") private var style: VideoRedactStyle = .blur

    init(url: URL, windowID: String) {
        self.url = url
        self.windowID = windowID
        _player = StateObject(wrappedValue: VideoToolsPlayer(url: url))
    }

    private var selectedIndex: Int? { boxes.firstIndex { $0.id == selected } }

    var body: some View {
        VideoToolsShell(windowID: windowID, exporter: exporter, player: player,
                         exportLabel: "Save Redacted Copy",
                         blocker: boxes.isEmpty ? VideoRedactPlan.emptyMessage : nil,
                         hint: "Drag on the video to add a rectangle. Delete removes the selected one.",
                         onExport: export, onKey: handleKey) {
            VStack(spacing: 8) {
                VideoToolsPreview(player: player, unavailableMessage:
                    "Video preview is unavailable for this file. Scrub the timeline to place rectangles; you can still export.") { mapping in
                    VideoRedactCanvas(mapping: mapping, boxes: $boxes, selected: $selected, style: style,
                                      time: player.currentTime, duration: player.duration)
                }
                .frame(minHeight: 240)
                .accessibilityLabel("Redaction preview. Draw rectangles to cover areas.")
                VideoToolsTimeline(player: player, height: 44)
                    .padding(.horizontal, 12)
                if !boxes.isEmpty {
                    VideoRedactLanes(boxes: $boxes, selected: $selected, player: player)
                        .padding(.horizontal, 12)
                }
                VideoToolsTransportBar(player: player) {
                    Button {
                        addAtPlayhead()
                    } label: {
                        Label("Add at Playhead", systemImage: "plus.rectangle")
                    }
                    .help("Add a rectangle that starts at the playhead")
                }
            }
        } controls: {
            HStack(spacing: 14) {
                Picker("Style", selection: $style) {
                    ForEach(VideoRedactStyle.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
                .help("Blur softens details. Use Black for sensitive information.")
                Divider().frame(height: 20)
                if let index = selectedIndex {
                    selectedControls(index)
                } else {
                    Text(boxes.isEmpty ? "Drag on the video to draw a rectangle." : "Select a rectangle to set when it shows.")
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(minWidth: 760, idealWidth: 900, minHeight: 640, idealHeight: 720)
    }

    @ViewBuilder private func selectedControls(_ index: Int) -> some View {
        let duration = player.duration
        HStack(spacing: 6) {
            Text("From")
            VideoToolsTimeField(title: "Start", value: Binding(
                get: { boxes[videoSafe: index]?.start ?? 0 },
                set: { v in update(index) { $0.start = min(v, $0.end - 0.05) } }),
                range: 0...max(0, duration))
            Button { update(index) { $0.start = min(player.currentTime, $0.end - 0.05) } } label: {
                Image(systemName: "arrow.right.to.line")
            }
            .help("Start at the playhead")
            Text("to")
            VideoToolsTimeField(title: "End", value: Binding(
                get: { boxes[videoSafe: index]?.end ?? 0 },
                set: { v in update(index) { $0.end = max(v, $0.start + 0.05) } }),
                range: 0...max(0, duration))
            Button { update(index) { $0.end = max(player.currentTime, $0.start + 0.05) } } label: {
                Image(systemName: "arrow.left.to.line")
            }
            .help("End at the playhead")
            Button("Entire Video") { update(index) { $0.start = 0; $0.end = duration } }
            Button(role: .destructive) { deleteSelected() } label: { Image(systemName: "trash") }
                .help("Delete Redaction (Delete)")
                .accessibilityLabel("Delete Redaction")
        }
        .buttonStyle(.borderless)
    }

    private func update(_ index: Int, _ change: (inout VideoRedactBox) -> Void) {
        guard boxes.indices.contains(index) else { return }
        var box = boxes[index]
        change(&box)
        box.start = max(0, box.start)
        box.end = min(player.duration, box.end)
        boxes[index] = box
    }

    private func addAtPlayhead() {
        let size = player.pixelSize
        let rect = CGRect(x: size.width * 0.35, y: size.height * 0.35, width: size.width * 0.3, height: size.height * 0.3)
        let box = VideoRedactBox(rect: VideoCropMath.even(rect, width: Int(size.width), height: Int(size.height)),
                                 start: min(player.currentTime, max(0, player.duration - 0.05)), end: player.duration)
        boxes.append(box)
        selected = box.id
    }

    private func deleteSelected() {
        guard let index = selectedIndex else { return }
        boxes.remove(at: index)
        selected = boxes.isEmpty ? nil : boxes[min(index, boxes.count - 1)].id
    }

    private func handleKey(_ key: VideoToolsKey) -> Bool {
        guard key == .delete, selected != nil else { return false }
        deleteSelected()
        return true
    }

    private func export() {
        let (url, boxes, style) = (url, boxes, style)
        exporter.start(windowID: windowID, title: "Redact", sources: [url]) { progress in
            [try await VideoToolOps.redact(url, boxes: boxes, style: style, progress: progress)]
        }
    }
}

private extension Array {
    subscript(videoSafe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// Draw, select, move and resize redaction rectangles on the preview.
struct VideoRedactCanvas: View {
    let mapping: VideoToolsPixelMapping
    @Binding var boxes: [VideoRedactBox]
    @Binding var selected: UUID?
    let style: VideoRedactStyle
    let time: Double
    let duration: Double
    @State private var draft: CGRect?
    @State private var dragStart: CGRect?

    private var width: Int { Int(mapping.pixelSize.width) }
    private var height: Int { Int(mapping.pixelSize.height) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Empty-area drags draw a new rectangle; clicks deselect.
            Rectangle()
                .fill(Color.white.opacity(0.001))
                .frame(width: mapping.videoRect.width, height: mapping.videoRect.height)
                .offset(x: mapping.videoRect.minX, y: mapping.videoRect.minY)
                .gesture(drawGesture)
                .videoCursor(.crosshair)

            ForEach(boxes) { box in
                if box.isActive(at: time) || box.id == selected {
                    boxView(box)
                }
            }

            if let draft {
                let r = mapping.viewRect(draft)
                Rectangle()
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                    .foregroundStyle(Color.white)
                    .frame(width: r.width, height: r.height)
                    .offset(x: r.minX, y: r.minY)
                    .allowsHitTesting(false)
            }
        }
    }

    private func boxView(_ box: VideoRedactBox) -> some View {
        let r = mapping.viewRect(box.rect.cgRect)
        let isSelected = box.id == selected
        let active = box.isActive(at: time)
        let number = (boxes.firstIndex { $0.id == box.id } ?? 0) + 1
        return ZStack(alignment: .topLeading) {
            VideoRedactSwatch(style: style)
                .opacity(active ? 1 : 0.35)
                .frame(width: r.width, height: r.height)
                .overlay(Rectangle().strokeBorder(isSelected ? Color.accentColor : Color.white.opacity(0.7),
                                                  style: StrokeStyle(lineWidth: isSelected ? 2 : 1, dash: active ? [] : [4, 3])))
                .contentShape(Rectangle())
                .gesture(moveGesture(box.id))
                .onTapGesture { selected = box.id }
                .videoCursor(.openHand)
                .accessibilityElement()
                .accessibilityLabel("Redaction rectangle \(number)")
                .accessibilityValue("\(VideoToolTimecode.format(box.start)) to \(VideoToolTimecode.format(box.end))")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            if isSelected {
                ForEach([VideoCropHandle.topLeft, .topRight, .bottomLeft, .bottomRight], id: \.self) { handle in
                    let p = CGPoint(x: handle.xDirection < 0 ? 0 : r.width, y: handle.yDirection < 0 ? 0 : r.height)
                    Circle()
                        .fill(Color.white)
                        .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 1.5))
                        .frame(width: 11, height: 11)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                        .offset(x: p.x - 10, y: p.y - 10)
                        .gesture(resizeGesture(box.id, handle))
                        .videoCursor(.crosshair)
                        .accessibilityLabel("Resize redaction \(number)")
                }
            }
        }
        .offset(x: r.minX, y: r.minY)
    }

    private var drawGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(VideoToolsPixelMapping.space))
            .onChanged { value in
                let a = clamp(mapping.pixelPoint(value.startLocation))
                let b = clamp(mapping.pixelPoint(value.location))
                draft = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
            }
            .onEnded { _ in
                defer { draft = nil }
                guard let draft, draft.width >= 8, draft.height >= 8 else {
                    selected = nil
                    return
                }
                let box = VideoRedactBox(rect: VideoCropMath.even(draft, width: width, height: height),
                                         start: 0, end: duration)
                boxes.append(box)
                selected = box.id
            }
    }

    private func moveGesture(_ id: UUID) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(VideoToolsPixelMapping.space))
            .onChanged { value in
                guard let index = boxes.firstIndex(where: { $0.id == id }) else { return }
                selected = id
                let start = dragStart ?? boxes[index].rect.cgRect
                dragStart = start
                let d = mapping.pixelDelta(value.translation)
                let moved = VideoCropMath.moved(start, dx: d.width, dy: d.height, width: width, height: height)
                boxes[index].rect = VideoCropMath.even(moved, width: width, height: height)
            }
            .onEnded { _ in dragStart = nil }
    }

    private func resizeGesture(_ id: UUID, _ handle: VideoCropHandle) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(VideoToolsPixelMapping.space))
            .onChanged { value in
                guard let index = boxes.firstIndex(where: { $0.id == id }) else { return }
                let start = dragStart ?? boxes[index].rect.cgRect
                dragStart = start
                let resized = VideoCropMath.resized(start, handle: handle, to: mapping.pixelPoint(value.location),
                                                    ratio: nil, width: width, height: height, minimum: 8)
                boxes[index].rect = VideoCropMath.even(resized, width: width, height: height)
            }
            .onEnded { _ in dragStart = nil }
    }

    private func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(0, p.x), CGFloat(width)), y: min(max(0, p.y), CGFloat(height)))
    }
}

/// Approximate look of each style in the preview (the export uses ffmpeg filters).
struct VideoRedactSwatch: View {
    let style: VideoRedactStyle

    var body: some View {
        switch style {
        case .black:
            Rectangle().fill(Color.black)
        case .blur:
            Rectangle().fill(.ultraThinMaterial)
                .overlay(Rectangle().fill(Color.white.opacity(0.18)))
        case .pixelate:
            Canvas { context, size in
                let cell: CGFloat = max(6, min(size.width, size.height) / 6)
                var y: CGFloat = 0, row = 0
                while y < size.height {
                    var x: CGFloat = 0, column = 0
                    while x < size.width {
                        let shade = 0.35 + 0.25 * Double((row * 7 + column * 3) % 5) / 4
                        context.fill(Path(CGRect(x: x, y: y, width: cell, height: cell)),
                                     with: .color(Color(white: shade).opacity(0.92)))
                        x += cell; column += 1
                    }
                    y += cell; row += 1
                }
            }
        }
    }
}

/// One lane per rectangle under the timeline: drag the bar to move its time range, its ends to resize it.
struct VideoRedactLanes: View {
    @Binding var boxes: [VideoRedactBox]
    @Binding var selected: UUID?
    @ObservedObject var player: VideoToolsPlayer
    @State private var dragStart: (start: Double, end: Double)?

    private let laneHeight: CGFloat = 16

    var body: some View {
        ScrollView(.vertical) {
            GeometryReader { geo in
                let g = VideoToolsTimelineGeometry(width: geo.size.width, duration: player.duration)
                ZStack(alignment: .topLeading) {
                    ForEach(Array(boxes.enumerated()), id: \.element.id) { index, box in
                        lane(index: index, box: box, geometry: g)
                            .offset(y: CGFloat(index) * (laneHeight + 3))
                    }
                    Rectangle()
                        .fill(Color.white.opacity(0.8))
                        .frame(width: 1, height: CGFloat(boxes.count) * (laneHeight + 3))
                        .offset(x: g.x(player.currentTime))
                        .allowsHitTesting(false)
                }
                .coordinateSpace(name: "videoRedactLanes")
            }
            .frame(height: CGFloat(boxes.count) * (laneHeight + 3))
        }
        .frame(height: min(CGFloat(boxes.count), 4) * (laneHeight + 3))
    }

    private func lane(index: Int, box: VideoRedactBox, geometry g: VideoToolsTimelineGeometry) -> some View {
        let x0 = g.x(box.start), x1 = g.x(box.end)
        let isSelected = box.id == selected
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.secondary.opacity(0.12))
                .frame(width: g.width, height: laneHeight)
                .allowsHitTesting(false)
            RoundedRectangle(cornerRadius: 3)
                .fill(isSelected ? Color.accentColor : Color.gray.opacity(0.7))
                .overlay(Text("\(index + 1)").font(.caption2.weight(.semibold)).foregroundStyle(.white), alignment: .leading)
                .frame(width: max(6, x1 - x0), height: laneHeight)
                .offset(x: x0)
                .gesture(timeGesture(box.id, geometry: g, edge: nil))
                .simultaneousGesture(TapGesture().onEnded { select(box) })
                .accessibilityElement()
                .accessibilityLabel("Redaction layer \(index + 1)")
                .accessibilityValue("\(VideoToolTimecode.format(box.start)) to \(VideoToolTimecode.format(box.end))")
            edgeHandle(box.id, geometry: g, start: true).offset(x: x0 - 4)
            edgeHandle(box.id, geometry: g, start: false).offset(x: max(x0 + 6, x1) - 4)
        }
        .frame(height: laneHeight)
    }

    private func edgeHandle(_ id: UUID, geometry g: VideoToolsTimelineGeometry, start: Bool) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.001))
            .frame(width: 8, height: laneHeight)
            .contentShape(Rectangle())
            .gesture(timeGesture(id, geometry: g, edge: start))
            .videoCursor(.resizeLeftRight)
    }

    /// edge: nil moves the whole range, true the start, false the end.
    private func timeGesture(_ id: UUID, geometry g: VideoToolsTimelineGeometry, edge: Bool?) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("videoRedactLanes"))
            .onChanged { value in
                guard let index = boxes.firstIndex(where: { $0.id == id }) else { return }
                selected = id
                let origin = dragStart ?? (boxes[index].start, boxes[index].end)
                dragStart = origin
                let dt = g.time(abs(value.translation.width)) * (value.translation.width < 0 ? -1 : 1)
                let duration = g.duration
                var box = boxes[index]
                switch edge {
                case nil:
                    let length = origin.end - origin.start
                    box.start = min(max(0, origin.start + dt), max(0, duration - length))
                    box.end = box.start + length
                    player.scrub(to: box.start)
                case true?:
                    box.start = min(max(0, origin.start + dt), origin.end - 0.05)
                    player.scrub(to: box.start)
                case false?:
                    box.end = max(min(duration, origin.end + dt), origin.start + 0.05)
                    player.scrub(to: box.end)
                }
                boxes[index] = box
            }
            .onEnded { _ in
                dragStart = nil
                player.endScrub()
            }
    }

    private func select(_ box: VideoRedactBox) {
        selected = box.id
        if !box.isActive(at: player.currentTime) { player.seek(to: box.start) }
    }
}
