import SwiftUI
import WheelieCore

/// Facts and a thumbnail for each clip in the Join list, plus the preview of the selected one.
@MainActor
final class VideoJoinModel: ObservableObject {
    struct Clip: Identifiable, Hashable {
        let id = UUID()
        let url: URL
    }

    @Published var clips: [Clip]
    @Published private(set) var infos: [URL: VideoToolInfo] = [:]
    @Published private(set) var failures: [URL: String] = [:]
    @Published private(set) var thumbnails: [URL: CGImage] = [:]
    @Published private(set) var player: VideoToolsPlayer?
    private var loaded = false
    private var isTornDown = false

    init(urls: [URL]) { clips = urls.map { Clip(url: $0) } }

    func load() async {
        guard !loaded else { return }
        loaded = true
        for clip in clips {
            // Stop once the window has closed.
            guard !Task.isCancelled, !isTornDown else { return }
            do {
                let info = try await VideoToolProbe.probe(clip.url)
                infos[clip.url] = info
                if !info.hasVideo { failures[clip.url] = "No video track" }
                guard !Task.isCancelled, !isTornDown else { return }
                let time = min(1, info.duration / 2)
                thumbnails[clip.url] = try? await VideoToolFrames.frame(clip.url, at: time, maxHeight: 72,
                                                                        duration: info.duration, exact: false)
            } catch {
                failures[clip.url] = "Couldn't read this file"
            }
        }
    }

    func preview(_ clip: Clip?) {
        guard !isTornDown, player?.url != clip?.url else { return }
        // The old player's load may still be running; tearDown makes it stop without starting work.
        player?.tearDown()
        guard let clip else { player = nil; return }
        let model = VideoToolsPlayer(url: clip.url)
        player = model
        Task { await model.load() }
    }

    func tearDown() {
        isTornDown = true
        player?.tearDown()
    }

    func orderByName() {
        clips.sort { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
    }

    var orderedInfos: [VideoToolInfo] { clips.compactMap { infos[$0.url] } }

    func sizeLabel(_ resolution: VideoToolOps.JoinResolution) -> String {
        guard orderedInfos.count == clips.count, !clips.isEmpty else { return "" }
        let size = VideoToolOps.joinSize(orderedInfos, resolution: resolution)
        return "\(size.width) × \(size.height)"
    }
}

/// Join: reorderable clip list, output size choice, preview of the selected clip.
struct VideoJoinEditor: View {
    let windowID: String
    @StateObject private var model: VideoJoinModel
    @StateObject private var exporter = VideoToolsExporter()
    @State private var selection: VideoJoinModel.Clip.ID?
    @AppStorage("videoJoin.resolution") private var resolution: VideoToolOps.JoinResolution = .first

    init(urls: [URL], windowID: String) {
        self.windowID = windowID
        _model = StateObject(wrappedValue: VideoJoinModel(urls: urls))
    }

    private var selectedClip: VideoJoinModel.Clip? { model.clips.first { $0.id == selection } }

    private var blocker: String? {
        if model.clips.count < 2 { return VideoToolOps.joinCountMessage }
        if model.clips.contains(where: { model.infos[$0.url].map { !$0.hasVideo } ?? false }) {
            return VideoToolOps.joinVideoMessage
        }
        return nil
    }

    var body: some View {
        VideoToolsShell(windowID: windowID, exporter: exporter, player: nil,
                         exportLabel: "Join \(model.clips.count) Videos", blocker: blocker,
                         hint: "Drag clips to change the order.",
                         onExport: export, onKey: handleKey, onClose: { model.tearDown() }) {
            HStack(alignment: .top, spacing: 14) {
                clipList.frame(width: 320)
                previewPane
            }
        } controls: {
            HStack(spacing: 14) {
                Picker("Size", selection: $resolution) {
                    Text("Match first clip").tag(VideoToolOps.JoinResolution.first)
                    Text("Largest clip").tag(VideoToolOps.JoinResolution.largest)
                }
                .pickerStyle(.segmented)
                .frame(width: 300)
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
            }
        }
        .frame(minWidth: 760, idealWidth: 900, minHeight: 520, idealHeight: 600)
        .task { await model.load() }
        .onAppear { if selection == nil { selection = model.clips.first?.id } }
        .onChange(of: selection) { model.preview(selectedClip) }
        .onChange(of: model.clips) { if selectedClip == nil { selection = model.clips.first?.id } }
    }

    private var summary: String {
        let infos = model.orderedInfos
        guard infos.count == model.clips.count, !infos.isEmpty else { return "Loading file details…" }
        let total = infos.reduce(0) { $0 + $1.duration }
        var parts = ["H.264/AAC", model.sizeLabel(resolution),
                     VideoToolTimecode.compact(VideoToolOps.joinFrameRate(infos), maxFractionDigits: 2) + " fps",
                     VideoToolTimecode.format(total) + " total"]
        let withAudio = infos.filter(\.hasAudio).count
        if withAudio == 0 { parts.append("no audio") }
        else if withAudio < infos.count { parts.append("silence added for clips without audio") }
        return parts.joined(separator: " · ")
    }

    private var clipList: some View {
        VStack(alignment: .leading, spacing: 8) {
            List(selection: $selection) {
                ForEach(model.clips) { clip in
                    row(clip).tag(clip.id)
                }
                .onMove { model.clips.move(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            .accessibilityIdentifier("orderedSourceList")
            HStack {
                Button("Order by Name") { model.orderByName() }
                    .help("Order the files by name, as Finder lists them")
                    .accessibilityIdentifier("sortSourcesByName")
                Spacer()
                Button { move(-1) } label: { Image(systemName: "chevron.up") }
                    .disabled(index(of: selection) ?? 0 == 0)
                    .help("Move up")
                Button { move(1) } label: { Image(systemName: "chevron.down") }
                    .disabled((index(of: selection) ?? model.clips.count) >= model.clips.count - 1)
                    .help("Move down")
                Button { removeSelected() } label: { Image(systemName: "minus") }
                    .disabled(selection == nil || model.clips.count <= 2)
                    .help("Remove from the join (Delete)")
            }
            .buttonStyle(.bordered)
        }
    }

    private func row(_ clip: VideoJoinModel.Clip) -> some View {
        let info = model.infos[clip.url]
        return HStack(spacing: 10) {
            ZStack {
                Color.black
                if let thumb = model.thumbnails[clip.url] {
                    Image(decorative: thumb, scale: 1).resizable().scaledToFit()
                }
            }
            .frame(width: 64, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            VStack(alignment: .leading, spacing: 2) {
                Text(clip.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                if let failure = model.failures[clip.url] {
                    Text(failure).font(.caption).foregroundStyle(.red)
                } else if let info {
                    HStack(spacing: 4) {
                        Text("\(VideoToolTimecode.format(info.duration)) · \(info.displayWidth)×\(info.displayHeight)")
                        if !info.hasAudio {
                            Text("No audio").foregroundStyle(.orange)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    Text("Loading…").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Drag to change its position")
    }

    @ViewBuilder private var previewPane: some View {
        if let player = model.player {
            VideoJoinPreview(player: player)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.85))
                Text("Select a clip to preview it.").foregroundStyle(.secondary)
            }
        }
    }

    private func index(of id: VideoJoinModel.Clip.ID?) -> Int? { model.clips.firstIndex { $0.id == id } }

    private func move(_ delta: Int) {
        guard let i = index(of: selection) else { return }
        let j = i + delta
        guard model.clips.indices.contains(j) else { return }
        model.clips.swapAt(i, j)
    }

    private func removeSelected() {
        guard model.clips.count > 2, let i = index(of: selection) else { return }
        model.clips.remove(at: i)
        selection = model.clips[min(i, model.clips.count - 1)].id
    }

    private func handleKey(_ key: VideoToolsKey) -> Bool {
        switch key {
        case .playPause: model.player?.togglePlay()
        case .stepBack: model.player?.step(-1)
        case .stepForward: model.player?.step(1)
        case .jumpBack: model.player?.step(-1, seconds: true)
        case .jumpForward: model.player?.step(1, seconds: true)
        case .delete: removeSelected()
        default: return false
        }
        return true
    }

    private func export() {
        model.player?.pause()
        let urls = model.clips.map(\.url), resolution = resolution
        exporter.start(windowID: windowID, title: "Join", sources: urls) { progress in
            [try await VideoToolOps.join(urls, resolution: resolution, progress: progress)]
        }
    }
}

private struct VideoJoinPreview: View {
    @ObservedObject var player: VideoToolsPlayer

    var body: some View {
        VStack(spacing: 10) {
            VideoToolsPreview(player: player, unavailableMessage:
                "Video preview is unavailable for this file. You can still join it.")
                .frame(minHeight: 220)
            VideoToolsTimeline(player: player, height: 44)
                .padding(.horizontal, 4)
            VideoToolsTransportBar(player: player)
        }
    }
}
