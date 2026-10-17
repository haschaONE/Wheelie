import AppKit
import SwiftUI
import WheelieCore

/// Crop: a draggable, resizable rectangle over the preview with ratio presets and pixel fields.
struct VideoCropEditor: View {
    let url: URL
    let windowID: String
    @StateObject private var player: VideoToolsPlayer
    @StateObject private var exporter = VideoToolsExporter()
    /// Crop in displayed pixels (fractional while dragging; snapped to even on export).
    @State private var rect: CGRect = .zero
    @State private var aspect: VideoCropAspect = .free

    init(url: URL, windowID: String) {
        self.url = url
        self.windowID = windowID
        _player = StateObject(wrappedValue: VideoToolsPlayer(url: url))
    }

    private var width: Int { Int(player.pixelSize.width) }
    private var height: Int { Int(player.pixelSize.height) }
    private var output: VideoCropRect { VideoCropMath.even(rect, width: width, height: height) }

    private var blocker: String? {
        guard player.info != nil else { return nil }
        if let message = VideoCropMath.validationError(output, width: width, height: height) { return message }
        if output == VideoCropMath.largest(ratio: nil, width: width, height: height) {
            return "Drag the corners or edges, or pick a ratio, to crop."
        }
        return nil
    }

    var body: some View {
        VideoToolsShell(windowID: windowID, exporter: exporter, player: player,
                         exportLabel: "Export Cropped Video", blocker: blocker,
                         hint: "Drag inside the rectangle to move it.",
                         onExport: export) {
            VStack(spacing: 10) {
                VideoToolsPreview(player: player, unavailableMessage:
                    "Video preview is unavailable for this file. You can still export the crop.") { mapping in
                    if rect.width > 0 {
                        VideoCropOverlay(mapping: mapping, rect: $rect, ratio: aspect.ratio, width: width, height: height)
                    }
                }
                .frame(minHeight: 280)
                VideoToolsTimeline(player: player, height: 44)
                    .padding(.horizontal, 12)
                VideoToolsTransportBar(player: player)
            }
        } controls: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Picker("Ratio", selection: $aspect) {
                        ForEach(VideoCropAspect.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 420)
                    Spacer()
                    Button("Reset") {
                        aspect = .free
                        rect = VideoCropMath.largest(ratio: nil, width: width, height: height).cgRect
                    }
                }
                HStack(spacing: 14) {
                    VideoToolsPixelField(title: "X", value: field(\.x))
                    VideoToolsPixelField(title: "Y", value: field(\.y))
                    VideoToolsPixelField(title: "Width", value: field(\.width))
                        .accessibilityLabel("Crop width in pixels")
                    VideoToolsPixelField(title: "Height", value: field(\.height))
                        .accessibilityLabel("Crop height in pixels")
                    Spacer()
                    Text("Output \(output.width) × \(output.height) px")
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(minWidth: 680, idealWidth: 860, minHeight: 620, idealHeight: 700)
        .onChange(of: player.info) {
            if rect == .zero { rect = VideoCropMath.largest(ratio: nil, width: width, height: height).cgRect }
        }
        .onChange(of: aspect) {
            rect = VideoCropMath.largest(ratio: aspect.ratio, width: width, height: height).cgRect
        }
    }

    /// Pixel field binding; a locked ratio keeps the other side in step.
    private func field(_ key: WritableKeyPath<VideoCropRect, Int>) -> Binding<Int> {
        Binding(get: { output[keyPath: key] }, set: { value in
            var r = output
            r[keyPath: key] = value
            var cg = r.cgRect
            if let ratio = aspect.ratio {
                if key == \.width { cg.size.height = cg.width / ratio }
                if key == \.height { cg.size.width = cg.height * ratio }
            }
            cg.size.width = min(max(cg.width, 2), CGFloat(width))
            cg.size.height = min(max(cg.height, 2), CGFloat(height))
            rect = VideoCropMath.even(cg, width: width, height: height).cgRect
        })
    }

    private func export() {
        let (url, crop) = (url, output)
        exporter.start(windowID: windowID, title: "Crop", sources: [url]) { progress in
            [try await VideoToolOps.crop(url, rect: crop, progress: progress)]
        }
    }
}

/// Dimmed surround, rule-of-thirds grid and eight resize handles.
struct VideoCropOverlay: View {
    let mapping: VideoToolsPixelMapping
    @Binding var rect: CGRect
    let ratio: Double?
    let width: Int
    let height: Int
    @State private var dragStart: CGRect?

    var body: some View {
        let view = mapping.viewRect(rect)
        ZStack(alignment: .topLeading) {
            Path { path in
                path.addRect(mapping.videoRect)
                path.addRect(view)
            }
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            Path { path in
                for i in 1...2 {
                    let x = view.minX + view.width * CGFloat(i) / 3
                    let y = view.minY + view.height * CGFloat(i) / 3
                    path.move(to: CGPoint(x: x, y: view.minY)); path.addLine(to: CGPoint(x: x, y: view.maxY))
                    path.move(to: CGPoint(x: view.minX, y: y)); path.addLine(to: CGPoint(x: view.maxX, y: y))
                }
            }
            .stroke(Color.white.opacity(0.35), lineWidth: 1)
            .allowsHitTesting(false)

            Rectangle()
                .strokeBorder(Color.white, lineWidth: 1.5)
                .background(Color.white.opacity(0.001))
                .frame(width: view.width, height: view.height)
                .offset(x: view.minX, y: view.minY)
                .gesture(moveGesture)
                .videoCursor(.openHand)
                .accessibilityElement()
                .accessibilityLabel("Crop selection. Drag to reposition.")
                .accessibilityValue("\(Int(rect.width)) by \(Int(rect.height)) pixels at \(Int(rect.minX)), \(Int(rect.minY))")

            ForEach(VideoCropHandle.allCases, id: \.self) { handle in
                let p = point(for: handle, in: view)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white)
                    .frame(width: isCorner(handle) ? 12 : 10, height: isCorner(handle) ? 12 : 10)
                    .shadow(color: .black.opacity(0.5), radius: 1)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
                    .offset(x: p.x - 11, y: p.y - 11)
                    .gesture(resizeGesture(handle))
                    .videoCursor(cursor(for: handle))
                    .accessibilityLabel("Resize crop")
            }
        }
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(VideoToolsPixelMapping.space))
            .onChanged { value in
                let start = dragStart ?? rect
                dragStart = start
                let d = mapping.pixelDelta(value.translation)
                rect = VideoCropMath.moved(start, dx: d.width, dy: d.height, width: width, height: height)
            }
            .onEnded { _ in dragStart = nil }
    }

    private func resizeGesture(_ handle: VideoCropHandle) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(VideoToolsPixelMapping.space))
            .onChanged { value in
                let start = dragStart ?? rect
                dragStart = start
                rect = VideoCropMath.resized(start, handle: handle, to: mapping.pixelPoint(value.location),
                                             ratio: ratio, width: width, height: height)
            }
            .onEnded { _ in dragStart = nil }
    }

    private func isCorner(_ h: VideoCropHandle) -> Bool { h.xDirection != 0 && h.yDirection != 0 }

    private func point(for h: VideoCropHandle, in r: CGRect) -> CGPoint {
        let x = h.xDirection < 0 ? r.minX : h.xDirection > 0 ? r.maxX : r.midX
        let y = h.yDirection < 0 ? r.minY : h.yDirection > 0 ? r.maxY : r.midY
        return CGPoint(x: x, y: y)
    }

    private func cursor(for h: VideoCropHandle) -> NSCursor {
        if h.yDirection == 0 { return .resizeLeftRight }
        if h.xDirection == 0 { return .resizeUpDown }
        return .crosshair
    }
}
