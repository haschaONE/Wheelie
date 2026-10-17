import SwiftUI
import WheelieCore

/// Snapshot: scrub, add frames at the playhead, save them at full resolution as PNG or JPG.
struct VideoSnapshotEditor: View {
    struct Frame: Identifiable, Equatable {
        let id = UUID()
        let time: Double
    }

    let url: URL
    let windowID: String
    @StateObject private var player: VideoToolsPlayer
    @StateObject private var exporter = VideoToolsExporter()
    @State private var frames: [Frame] = []
    @State private var images: [UUID: CGImage] = [:]
    @State private var selected: UUID?
    @AppStorage("videoSnapshot.format") private var format: VideoSnapshotFormat = .png

    init(url: URL, windowID: String) {
        self.url = url
        self.windowID = windowID
        _player = StateObject(wrappedValue: VideoToolsPlayer(url: url))
    }

    private var exportLabel: String {
        switch frames.count {
        case 0: return "Save Frames"
        case 1: return "Save 1 Frame"
        default: return "Save \(frames.count) Frames"
        }
    }

    var body: some View {
        VideoToolsShell(windowID: windowID, exporter: exporter, player: player, exportLabel: exportLabel,
                         blocker: frames.isEmpty ? VideoToolOps.snapshotEmptyMessage : nil,
                         hint: "Press F to add the frame at the playhead.",
                         onExport: export, onKey: handleKey) {
            VStack(spacing: 10) {
                VideoToolsPreview(player: player, unavailableMessage:
                    "Video preview is unavailable for this file. You can still scrub and save frames.")
                    .frame(minHeight: 240)
                VideoToolsTimeline(player: player) { g in
                    ForEach(frames) { frame in
                        Image(systemName: "arrowtriangle.down.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(frame.id == selected ? Color.accentColor : Color.white)
                            .shadow(color: .black.opacity(0.6), radius: 1)
                            .offset(x: g.x(frame.time) - 4.5, y: -3)
                            .allowsHitTesting(false)
                    }
                }
                .padding(.horizontal, 12)
                VideoToolsTransportBar(player: player) {
                    Button {
                        addFrame()
                    } label: {
                        Label("Add Frame", systemImage: "plus.viewfinder")
                    }
                    .help("Add the frame at the playhead (F)")
                }
            }
        } controls: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker("Format", selection: $format) {
                        ForEach(VideoSnapshotFormat.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                    Spacer()
                    if player.info != nil {
                        Text("Full resolution: \(Int(player.pixelSize.width)) × \(Int(player.pixelSize.height))")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                strip
            }
        }
        .frame(minWidth: 680, idealWidth: 860, minHeight: 620, idealHeight: 700)
    }

    private var strip: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                if frames.isEmpty {
                    Label("Scrub to a moment, then click Add Frame. Frames appear here.", systemImage: "photo.on.rectangle")
                        .foregroundStyle(.secondary)
                        .frame(height: 88)
                        .padding(.horizontal, 12)
                }
                ForEach(frames) { frame in thumb(frame) }
            }
            .padding(6)
        }
        .frame(height: 104)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
    }

    private func thumb(_ frame: Frame) -> some View {
        let time = VideoToolTimecode.format(frame.time)
        return VStack(spacing: 3) {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    Color.black
                    if let image = images[frame.id] {
                        Image(decorative: image, scale: 1).resizable().scaledToFit()
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(width: 112, height: 63)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(selected == frame.id ? Color.accentColor : .clear, lineWidth: 2))
                Button { remove(frame.id) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.6))
                }
                .buttonStyle(.borderless)
                .padding(3)
                .help("Remove frame at \(time)")
                .accessibilityLabel("Remove frame at \(time)")
            }
            Text(time).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            selected = frame.id
            player.seek(to: frame.time)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Preview frame at \(time)")
    }

    private func addFrame() {
        let t = min(player.currentTime, max(0, player.duration - player.frameDuration))
        if let existing = frames.first(where: { abs($0.time - t) < player.frameDuration / 2 }) {
            selected = existing.id
            return
        }
        let frame = Frame(time: t)
        frames.append(frame)
        frames.sort { $0.time < $1.time }
        selected = frame.id
        Task {
            if let image = await player.frameImage(at: t, maxHeight: 126) { images[frame.id] = image }
        }
    }

    private func remove(_ id: UUID) {
        guard let index = frames.firstIndex(where: { $0.id == id }) else { return }
        frames.remove(at: index)
        images[id] = nil
        if selected == id { selected = frames.isEmpty ? nil : frames[min(index, frames.count - 1)].id }
    }

    private func handleKey(_ key: VideoToolsKey) -> Bool {
        switch key {
        case .character("f"), .character("a"): addFrame()
        case .delete:
            guard let selected else { return false }
            remove(selected)
        default: return false
        }
        return true
    }

    private func export() {
        let (url, times, format) = (url, frames.map(\.time), format)
        exporter.start(windowID: windowID, title: "Snapshots", sources: [url]) { progress in
            try await VideoToolOps.snapshots(url, times: times, format: format, progress: progress)
        }
    }
}
