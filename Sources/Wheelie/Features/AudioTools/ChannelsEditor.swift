import SwiftUI
import WheelieCore

@MainActor
final class ChannelsEditorModel: AudioEditorModel {
    enum Preview: Equatable {
        case original
        /// One row's channel on its own.
        case row(Int)
        /// The complete Mono or Stereo output.
        case output
    }

    @Published var output: ChannelOutput = .stereo { didSet { settingsChanged() } }
    @Published var leftVolume: Double = 1 { didSet { settingsChanged() } }
    @Published var rightVolume: Double = 1 { didSet { settingsChanged() } }
    @Published var balance: Double = 0 { didSet { settingsChanged() } }
    @Published var swapped = false { didSet { settingsChanged() } }
    @Published private(set) var preview: Preview = .original

    /// Finished preview renders by settings key, newest last. Each is a full-length file, so only a few are kept.
    private var renders: [(key: String, url: URL)] = []
    private static let maximumRenders = 4

    private func cachedRender(_ key: String) -> URL? { renders.last { $0.key == key }?.url }

    /// Adds a render and deletes the oldest ones past the limit (never the one playing).
    private func storeRender(_ url: URL, for key: String) {
        renders.append((key, url))
        while renders.count > Self.maximumRenders,
              let index = renders.firstIndex(where: { $0.url != player.source }) {
            let evicted = renders.remove(at: index)
            player.forget(evicted.url)
            try? FileManager.default.removeItem(at: evicted.url)
        }
    }

    override var waveformChannels: Int { 2 }
    override var waveformUnavailableMessage: String { "Channel waveforms unavailable. You can still convert the audio." }
    var sourceChannels: Int { min(info?.channels ?? 2, 2) }
    var settings: ChannelSettings {
        ChannelSettings(output: output, leftVolume: leftVolume, rightVolume: rightVolume, balance: balance, swapped: swapped)
    }
    var balanceApplies: Bool { !(sourceChannels == 1 && output == .mono) }
    var swapApplies: Bool { sourceChannels == 2 && output == .stereo }

    override func didLoad() async {
        // The usual intent is to switch: stereo -> mono, mono -> stereo.
        output = (info?.channels ?? 2) >= 2 ? .mono : .stereo
    }

    struct Row: Identifiable {
        let id: Int
        let title: String
        let detail: String
        /// Source channel feeding this row.
        let channel: Int
        let isLeftVolume: Bool
    }

    var rows: [Row] {
        if sourceChannels >= 2 {
            let leftDest = output == .mono ? "Mixed into mono" : (swapped ? "Plays on the right" : "Plays on the left")
            let rightDest = output == .mono ? "Mixed into mono" : (swapped ? "Plays on the left" : "Plays on the right")
            return [Row(id: 0, title: "Left", detail: leftDest, channel: 0, isLeftVolume: true),
                    Row(id: 1, title: "Right", detail: rightDest, channel: 1, isLeftVolume: false)]
        }
        if output == .stereo {
            return [Row(id: 0, title: "Left", detail: "Copy of the mono channel", channel: 0, isLeftVolume: true),
                    Row(id: 1, title: "Right", detail: "Copy of the mono channel", channel: 0, isLeftVolume: false)]
        }
        return [Row(id: 0, title: "Mono", detail: "Single channel", channel: 0, isLeftVolume: true)]
    }

    func peaks(for row: Row) -> [Float]? {
        guard let waveform else { return nil }
        return waveform.channels.indices.contains(row.channel) ? waveform.channels[row.channel] : waveform.combined
    }

    /// Effective gain shown on a row's waveform.
    func displayGain(for row: Row) -> Float {
        let m = AudioChannels.matrix(sourceChannels: sourceChannels, settings: settings)
        let volume: Double
        if sourceChannels >= 2 {
            // Volume and balance this source channel ends up with in its destination.
            volume = m.map { $0.indices.contains(row.channel) ? $0[row.channel] : 0 }.max() ?? 1
            return Float(output == .mono ? volume * 2 : volume)
        }
        volume = m.indices.contains(row.id) ? m[row.id][0] : m[0][0]
        return Float(volume)
    }

    func volume(for row: Row) -> Binding<Double> {
        row.isLeftVolume ? Binding(get: { self.leftVolume }, set: { self.leftVolume = $0 })
                         : Binding(get: { self.rightVolume }, set: { self.rightVolume = $0 })
    }

    // MARK: Previews

    override func togglePlayback() {
        if player.isPlaying { player.pause() } else { play(preview) }
    }

    func toggle(_ target: Preview) {
        if preview == target, player.isPlaying { player.pause(); return }
        play(target)
    }

    private func play(_ target: Preview) {
        preview = target
        guard target != .original else {
            player.use(primary)
            player.play()
            return
        }
        guard let info else { return }
        let key = renderKey(target)
        if let url = cachedRender(key) {
            tasks["render"]?.cancel()
            player.use(url)
            player.play()
            return
        }
        render(target, info: info, key: key, thenPlay: true)
    }

    private func renderKey(_ target: Preview) -> String {
        switch target {
        case .original: return "original"
        case .row(let id):
            let row = rows.first { $0.id == id } ?? rows[0]
            return "row-\(row.channel)-\(AudioFFmpeg.num(Double(displayGain(for: row))))"
        case .output:
            let s = settings
            return "out-\(s.output.rawValue)-\(s.leftVolume)-\(s.rightVolume)-\(s.balance)-\(s.swapped)"
        }
    }

    private func render(_ target: Preview, info: AudioInfo, key: String, thenPlay: Bool) {
        let url = primary
        let settings = settings
        var row: Row?
        if case .row(let id) = target { row = rows.first { $0.id == id } }
        let gain = row.map { Double(displayGain(for: $0)) } ?? 1
        let output = AudioPreview.temporaryURL(in: temp.directory, prefix: "channel", info: info)
        debounce("render", delay: thenPlay ? 0 : 0.35) { [weak self] in
            guard let self else { return }
            self.player.isPreparing = true
            defer { if !Task.isCancelled { self.player.isPreparing = false } }
            do {
                if let row {
                    try await AudioChannels.renderSolo(url, info: info, channel: row.channel, gain: gain, output: output)
                } else {
                    try await AudioChannels.convert(url, settings: settings, info: info, output: output,
                                                    encoding: .preview(forDuration: info.duration), keepVideo: false)
                }
                guard !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: output)
                    return
                }
                self.storeRender(output, for: key)
                // The settings or the preview changed meanwhile: keep the render for later, but don't play it.
                guard self.preview == target, self.renderKey(target) == key else { return }
                let wasPlaying = self.player.isPlaying
                self.player.use(output)
                if thenPlay || wasPlaying { self.player.play() }
                self.error = nil
            } catch {
                guard !Task.isCancelled else { return }
                self.error = target == .output ? "Could not play the output preview. \(error.localizedDescription)"
                                               : "Could not play this audio channel. \(error.localizedDescription)"
            }
        }
    }

    private func settingsChanged() {
        // A playing preview follows the new settings; anything else re-renders on the next play.
        guard let info, preview != .original else { return }
        let key = renderKey(preview)
        if let url = cachedRender(key) {
            tasks["render"]?.cancel()           // a render for other settings must not replace it
            player.use(url)
        } else if player.isPlaying {
            render(preview, info: info, key: key, thenPlay: false)
        } else {
            preview = .original
            player.use(primary)
        }
    }

    override func export() {
        let settings = settings
        runExport(settings.output == .mono ? "Convert to Mono" : "Convert to Stereo") { [weak self] in
            guard let self else { return [] }
            return try await self.forEachFile { url, info in
                try await AudioChannels.convert(url, settings: settings, info: info)
            }
        }
    }
}

struct ChannelsEditorView: View {
    @StateObject var model: ChannelsEditorModel

    var body: some View {
        AudioEditorScaffold(model: model) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(spacing: 6) {
                    HStack(spacing: 0) {
                        Color.clear.frame(width: 120, height: 1)
                        TimeRuler(timeline: model.timeline)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    ForEach(model.rows) { row in
                        ChannelRowView(model: model, row: row)
                    }
                }
                TransportBar(player: model.player, timeline: model.timeline, duration: model.info?.duration ?? 0,
                             playHelp: "Play or pause the selected preview (Space)",
                             onPlay: { model.togglePlayback() }) {
                    Text(previewLabel).font(.caption).foregroundStyle(.secondary)
                } trailing: { EmptyView() }
                if let note = model.waveformNote {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
                settings
            }
        } footer: {
            ExportButton(model: model, title: model.output == .mono ? "Save Mono Copy" : "Save Stereo Copy")
        }
    }

    private var previewLabel: String {
        switch model.preview {
        case .original: return "Original"
        case .output: return "\(model.output.label) output"
        case .row(let id): return "\(model.rows.first { $0.id == id }?.title ?? "") channel"
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingRow(title: "Output") {
                Picker("Output", selection: $model.output) {
                    ForEach(ChannelOutput.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
                PreviewToggle(player: model.player, active: model.preview == .output,
                              title: "Play Output", activeTitle: "Stop Output Preview",
                              help: "Play the complete Mono or Stereo output with the selected volume balance") {
                    model.toggle(.output)
                }
                .accessibilityLabel("Output channel preview")
            }
            SettingRow(title: "Balance") {
                Text("L").foregroundStyle(.secondary)
                Slider(value: Binding(get: { model.balance },
                                      set: { model.balance = abs($0) < 0.04 ? 0 : $0 }), in: -1...1)
                    .frame(width: 220)
                    .accessibilityLabel("Volume balance")
                Text("R").foregroundStyle(.secondary)
                Text(balanceText).font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                Button("Centre") { model.balance = 0 }.disabled(model.balance == 0)
            }
            .disabled(!model.balanceApplies)
            SettingRow(title: "Channels") {
                Toggle("Swap left and right", isOn: $model.swapped)
                    .disabled(!model.swapApplies)
                    .help(model.swapApplies ? "The left channel plays on the right and vice versa" : "Needs a stereo file and stereo output")
            }
            if model.info?.hasVideo == true {
                Text(model.videoNote("converted"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var balanceText: String {
        let b = model.balance
        if abs(b) < 0.005 { return "Centre" }
        return "\(b < 0 ? "L" : "R") \(Int((abs(b) * 100).rounded()))%"
    }
}

private struct ChannelRowView: View {
    @ObservedObject var model: ChannelsEditorModel
    let row: ChannelsEditorModel.Row

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    PreviewToggle(player: model.player, active: model.preview == .row(row.id), iconOnly: true,
                                  title: "\(row.title) channel preview", activeTitle: "Stop channel preview",
                                  help: "Play the \(row.title.lowercased()) channel on its own") {
                        model.toggle(.row(row.id))
                    }
                    Text(row.title).font(.headline)
                }
                Text(row.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 4) {
                    Slider(value: model.volume(for: row), in: ChannelSettings.volumeRange)
                        .controlSize(.small)
                        .accessibilityLabel("\(row.title) volume")
                    Text("\(Int((model.volume(for: row).wrappedValue * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 36, alignment: .trailing)
                }
            }
            .frame(width: 110)
            WaveformLane(timeline: model.timeline, player: model.player, peaks: model.peaks(for: row),
                         gain: displayScale * model.displayGain(for: row),
                         color: row.id == 0 ? .accentColor : .teal, isLoading: model.isLoading)
                .frame(minHeight: 70)
                .accessibilityLabel("\(row.title) channel waveform")
        }
    }

    /// Normalizes the display so quiet files are still readable, without hiding volume differences.
    private var displayScale: Float {
        guard let max = model.waveform?.maximum, max > 0.001 else { return 1 }
        return min(20, 0.9 / max)
    }
}
