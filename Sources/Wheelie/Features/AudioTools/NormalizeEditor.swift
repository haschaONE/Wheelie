import SwiftUI
import WheelieCore

@MainActor
final class NormalizeEditorModel: AudioEditorModel {
    enum Listen: String, CaseIterable, Identifiable {
        case original, normalized
        var id: String { rawValue }
        var label: String { self == .original ? "Original" : "Normalized" }
    }

    @Published var preset: LoudnessPreset = .podcast {
        didSet {
            if preset != oldValue, let t = preset.target, t != target { target = t }
        }
    }
    @Published var target = AudioNormalize.defaultTarget {
        didSet {
            guard target != oldValue else { return }
            let matching = LoudnessPreset.matching(target)
            if matching != preset { preset = matching }
            targetChanged()
        }
    }
    @Published var showAdvanced = false
    @Published private(set) var measurement: LoudnessMeasurement?
    @Published private(set) var measuredTarget: LoudnessTarget?
    @Published private(set) var isMeasuring = false
    @Published private(set) var measureError: String?
    @Published var listen: Listen = .original { didSet { if listen != oldValue { listenChanged() } } }

    private var previewURL: URL?
    private var previewTarget: LoudnessTarget?

    override var canExport: Bool { super.canExport && target.isValid }

    override func didLoad() async {
        guard let info else { return }
        isMeasuring = true
        defer { isMeasuring = false }
        do {
            let t = target
            let m = try await AudioNormalize.measure(primary, target: t, info: info)
            measurement = m
            measuredTarget = t
            if m.isSilent { measureError = "This audio is silent, so there's nothing to normalize." }
        } catch {
            measureError = "Couldn't measure the loudness. You can still normalize this audio. \(error.localizedDescription)"
        }
    }

    var gain: Double? { measurement.map { AudioNormalize.gain(target: target, measurement: $0) } }
    var isLinear: Bool { measurement.map { AudioNormalize.isLinear(target: target, measurement: $0) } ?? false }

    /// Scale for the normalized waveform; peaks are drawn clipped at the true-peak ceiling.
    var previewGain: Float {
        guard let gain else { return 1 }
        return Float(min(pow(10, gain / 20), 100))
    }

    var previewCeiling: Float { Float(pow(10, target.truePeak / 20)) }

    var resultDescription: String {
        guard let measurement, let gain, !measurement.isSilent else { return "" }
        let change = abs(gain) < 0.05 ? "Already at the target" : "\(signed(gain)) dB"
        if isLinear {
            return "\(change), applied as one gain change, so the dynamics stay exactly as they are."
        }
        if measurement.truePeak + gain > target.truePeak {
            return "\(change) would push peaks past \(minus(target.truePeak)) dBTP, so loud moments are gently limited."
        }
        if measurement.range > target.range {
            return "The input's \(String(format: "%.1f", measurement.range)) LU range is wider than the \(String(format: "%.0f", target.range)) LU target, so quiet and loud parts are evened out."
        }
        return "\(change), with light dynamic adjustment."
    }

    // MARK: Preview

    override func togglePlayback() {
        if player.isPlaying { player.pause(); return }
        if listen == .normalized { ensurePreview(thenPlay: true) } else { player.play() }
    }

    private func listenChanged() {
        if listen == .original {
            player.use(primary)
        } else {
            ensurePreview(thenPlay: player.isPlaying)
        }
    }

    private func targetChanged() {
        guard listen == .normalized else { return }
        ensurePreview(thenPlay: false, delay: 0.5)
    }

    private func ensurePreview(thenPlay: Bool, delay: Double = 0) {
        guard let info, let measurement, !measurement.isSilent, target.isValid else {
            if thenPlay { player.play() }
            return
        }
        if let previewURL, previewTarget == target {
            player.use(previewURL)
            if thenPlay { player.play() }
            return
        }
        let url = primary, target = target
        let output = AudioPreview.temporaryURL(in: temp.directory, prefix: "normalized", info: info)
        debounce("preview", delay: delay) { [weak self] in
            guard let self else { return }
            self.player.isPreparing = true
            defer { if !Task.isCancelled { self.player.isPreparing = false } }
            do {
                try await AudioNormalize.normalize(url, target: target, info: info, measurement: measurement,
                                                   output: output, encoding: .preview(forDuration: info.duration),
                                                   keepVideo: false)
                guard !Task.isCancelled else { return }
                let old = self.previewURL
                self.previewURL = output
                self.previewTarget = target
                if self.listen == .normalized {
                    let wasPlaying = self.player.isPlaying
                    self.player.use(output)
                    if thenPlay || wasPlaying { self.player.play() }
                }
                if let old {
                    self.player.forget(old)
                    try? FileManager.default.removeItem(at: old)
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.error = "Normalized audio preview is unavailable. You can still export with these settings."
            }
        }
    }

    override func export() {
        let target = target
        let reuse = measuredTarget == target ? measurement : nil
        let primary = primary
        runExport("Normalize Volume") { [weak self] in
            guard let self else { return [] }
            try AudioNormalize.validate(target)
            return try await self.forEachFile { url, info in
                try await AudioNormalize.normalize(url, target: target, info: info,
                                                   measurement: url == primary ? reuse : nil)
            }
        }
    }
}

struct NormalizeEditorView: View {
    @StateObject var model: NormalizeEditorModel

    var body: some View {
        AudioEditorScaffold(model: model) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(spacing: 4) {
                    TimeRuler(timeline: model.timeline)
                    WaveformLane(timeline: model.timeline, player: model.player,
                                 peaks: model.waveform?.combined,
                                 gain: model.listen == .normalized ? model.previewGain : 1,
                                 ceiling: model.listen == .normalized ? model.previewCeiling : 1,
                                 color: model.listen == .normalized ? .green : .accentColor,
                                 backgroundPeaks: model.listen == .normalized ? model.waveform?.combined : nil,
                                 isLoading: model.isLoading) { _ in EmptyView() }
                        .frame(minHeight: 120)
                }
                TransportBar(player: model.player, timeline: model.timeline, duration: model.info?.duration ?? 0,
                             onPlay: { model.togglePlayback() }) {
                    Picker("Listen to", selection: $model.listen) {
                        ForEach(NormalizeEditorModel.Listen.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 190)
                    .help("Compare the original with the normalized result")
                    .accessibilityIdentifier("normalizationPlaybackToggle")
                } trailing: { EmptyView() }
                if let note = model.waveformNote {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
                measured
                Divider()
                targetSettings
            }
        } footer: {
            ExportButton(model: model, title: "Save Normalized Copy")
        }
    }

    private var measured: some View {
        SettingRow(title: "Input loudness") {
            if model.isMeasuring {
                ProgressView().controlSize(.small)
                Text("Measuring loudness…").foregroundStyle(.secondary)
            } else if let m = model.measurement, !m.isSilent {
                HStack(spacing: 18) {
                    Metric(value: minus(m.integrated), unit: "LUFS", caption: "Integrated")
                    Metric(value: minus(m.truePeak), unit: "dBTP", caption: "True peak")
                    Metric(value: String(format: "%.1f", m.range), unit: "LU", caption: "Loudness range")
                }
            } else if let error = model.measureError {
                Text(error).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var targetSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingRow(title: "Target") {
                Picker("Target", selection: $model.preset) {
                    ForEach(LoudnessPreset.allCases) { preset in
                        Text(presetTitle(preset)).tag(preset)
                    }
                }
                .labelsHidden()
                .frame(width: 260)
            }
            SettingRow(title: "") {
                Text(model.preset.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SettingRow(title: "") {
                DisclosureGroup("Advanced", isExpanded: $model.showAdvanced) {
                    VStack(alignment: .leading, spacing: 8) {
                        advancedRow("Integrated", value: $model.target.integrated, range: LoudnessTarget.integratedRange, unit: "LUFS")
                        advancedRow("Loudness range", value: $model.target.range, range: LoudnessTarget.rangeRange, unit: "LU")
                        advancedRow("True peak", value: $model.target.truePeak, range: LoudnessTarget.truePeakRange, unit: "dBTP", step: 0.5)
                        Text("Choose a target from −70 to −5 LUFS, a loudness range from 1 to 50 LU, and a true peak from −9 to 0 dBTP.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 6)
                }
                .frame(maxWidth: 460, alignment: .leading)
            }
            if !model.resultDescription.isEmpty {
                SettingRow(title: "Result") {
                    Text(model.resultDescription).fixedSize(horizontal: false, vertical: true)
                }
            }
            if model.info?.hasVideo == true {
                SettingRow(title: "") {
                    Text("The video is copied unchanged; only the audio track is normalized.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func presetTitle(_ preset: LoudnessPreset) -> String {
        switch preset {
        case .streaming: return "Streaming (−14 LUFS)"
        case .podcast: return "Podcast (−16 LUFS)"
        case .broadcast: return "Broadcast (−23 LUFS, EBU R128)"
        case .custom: return "Custom (\(minus(model.target.integrated)) LUFS)"
        }
    }

    private func advancedRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, unit: String,
                             step: Double = 1) -> some View {
        HStack(spacing: 8) {
            Text(title).frame(width: 110, alignment: .leading)
            Slider(value: value, in: range, step: step).frame(width: 160).accessibilityLabel(title)
            NumberField(label: title, value: value, range: range, unit: unit, step: step, decimals: 1)
        }
    }
}

private struct Metric: View {
    let value: String
    let unit: String
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.title3.monospacedDigit().weight(.semibold))
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
            Text(caption).font(.caption2).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
