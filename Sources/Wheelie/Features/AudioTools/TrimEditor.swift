import SwiftUI
import WheelieCore

@MainActor
final class TrimEditorModel: AudioEditorModel {
    @Published private(set) var start: Double = 0
    @Published private(set) var end: Double = 0
    @Published var fadeIn: Double = 0
    @Published var fadeOut: Double = 0
    @Published var autoTrim = false {
        didSet {
            guard autoTrim != oldValue else { return }
            if autoTrim {
                detectSilence(after: 0)
            } else {
                tasks["silence"]?.cancel()
                isDetecting = false
                silenceNote = nil
            }
        }
    }
    @Published var threshold: Double = AudioTrim.defaultThreshold {
        didSet { if autoTrim && threshold != oldValue { detectSilence(after: 0.4) } }
    }
    @Published private(set) var isDetecting = false
    @Published private(set) var silenceNote: String?
    @Published private(set) var silenceNoteIsWarning = false

    override var waveformUnavailableMessage: String { "Waveform unavailable. You can still adjust the range." }
    var selectionDuration: Double { max(0, end - start) }

    override func didLoad() async {
        start = 0
        end = duration
    }

    func setStart(_ value: Double, fromUser: Bool = true) {
        if fromUser { autoTrim = false }
        start = min(max(0, value), max(0, end - AudioTrim.minimumDuration))
    }

    func setEnd(_ value: Double, fromUser: Bool = true) {
        if fromUser { autoTrim = false }
        end = max(min(duration, value), min(duration, start + AudioTrim.minimumDuration))
    }

    func selectAll() {
        autoTrim = false
        start = 0
        end = duration
    }

    func setStartToPlayhead() { setStart(player.currentTime) }
    func setEndToPlayhead() { setEnd(player.currentTime) }

    func playSelection() {
        if player.isPlaying { player.pause(); return }
        let from = (start..<end).contains(player.currentTime) && player.currentTime < end - 0.1 ? player.currentTime : start
        player.play(from: from, until: end, fadeIn: from == start ? min(fadeIn, selectionDuration) : 0,
                    fadeOut: min(fadeOut, selectionDuration))
    }

    private func detectSilence(after delay: Double) {
        guard let info else { return }
        let url = primary, threshold = threshold
        debounce("silence", delay: delay) { [weak self] in
            guard let self else { return }
            self.isDetecting = true
            self.silenceNote = nil
            defer { if !Task.isCancelled { self.isDetecting = false } }
            do {
                let range = try await AudioTrim.detectAudibleRange(url, thresholdDB: threshold, info: info)
                guard !Task.isCancelled, self.autoTrim else { return }
                self.start = range.lowerBound
                self.end = min(range.upperBound, self.duration)
                if self.isMultiFile {
                    self.silenceNote = "Each file is trimmed to its own audible range."
                    self.silenceNoteIsWarning = false
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.silenceNote = error.localizedDescription
                self.silenceNoteIsWarning = true
            }
        }
    }

    override func export() {
        let settings = TrimSettings(start: start, end: end, fadeIn: fadeIn, fadeOut: fadeOut)
        let auto = autoTrim, threshold = threshold
        runExport("Trim Audio") { [weak self] in
            guard let self else { return [] }
            return try await self.forEachFile { url, info in
                var s = settings
                if auto {
                    let range = try await AudioTrim.detectAudibleRange(url, thresholdDB: threshold, info: info)
                    s.start = range.lowerBound
                    s.end = range.upperBound
                } else {
                    s.end = min(s.end, info.duration)
                }
                return try await AudioTrim.trim(url, settings: s, info: info)
            }
        }
    }
}

struct TrimEditorView: View {
    @StateObject var model: TrimEditorModel

    var body: some View {
        AudioEditorScaffold(model: model) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(spacing: 4) {
                    TimeRuler(timeline: model.timeline)
                    WaveformLane(timeline: model.timeline, player: model.player, peaks: model.waveform?.combined,
                                 gain: displayGain, isLoading: model.isLoading) { g in
                        TrimOverlay(model: model, geometry: g)
                    }
                    .frame(minHeight: 150)
                }
                TransportBar(player: model.player, timeline: model.timeline, duration: model.duration,
                             onPlay: { model.togglePlayback() }) {
                    Button {
                        model.playSelection()
                    } label: {
                        Label("Play Selected Range", systemImage: "play.square")
                    }
                    .help("Play from the start to the end of the selection, with fades")
                } trailing: { EmptyView() }
                if let note = model.waveformNote {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
                settings
            }
        } footer: {
            ExportButton(model: model, title: "Save Trimmed Copy")
        }
    }

    private var displayGain: Float {
        guard let max = model.waveform?.maximum, max > 0.001 else { return 1 }
        return min(20, 0.95 / max)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingRow(title: "Range") {
                TimeField(label: "Start", value: Binding(get: { model.start }, set: { model.setStart($0) }))
                Button { model.setStartToPlayhead() } label: { Image(systemName: "arrow.right.to.line") }
                    .help("Set the start to the playhead")
                Text("to").foregroundStyle(.secondary)
                TimeField(label: "End", value: Binding(get: { model.end }, set: { model.setEnd($0) }))
                Button { model.setEndToPlayhead() } label: { Image(systemName: "arrow.left.to.line") }
                    .help("Set the end to the playhead")
                Text("Duration \(Timecode.string(model.selectionDuration))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button("Select All") { model.selectAll() }
            }
            SettingRow(title: "Fades") {
                Text("In").foregroundStyle(.secondary)
                NumberField(label: "Fade in", value: $model.fadeIn, range: 0...AudioTrim.maximumFade, unit: "s",
                            step: 0.5, decimals: 2)
                Text("Out").foregroundStyle(.secondary).padding(.leading, 8)
                NumberField(label: "Fade out", value: $model.fadeOut, range: 0...AudioTrim.maximumFade, unit: "s",
                            step: 0.5, decimals: 2)
            }
            SettingRow(title: "Silence") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Toggle("Trim silent ends automatically", isOn: $model.autoTrim)
                        if model.isDetecting {
                            ProgressView().controlSize(.small)
                            Text("Detecting silence").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 8) {
                        Text("Threshold").foregroundStyle(.secondary)
                        Slider(value: $model.threshold, in: AudioTrim.thresholdRange, step: 1)
                            .frame(width: 180)
                            .accessibilityLabel("Silence threshold in decibels")
                        NumberField(label: "Silence threshold", value: $model.threshold, range: AudioTrim.thresholdRange,
                                    unit: "dB", step: 1, decimals: 0)
                    }
                    .disabled(!model.autoTrim)
                    Text(model.silenceNote ?? "Anything quieter than the threshold at the start and end is removed. Choose a silence threshold between −80 and −10 dB.")
                        .font(.caption)
                        .foregroundStyle(model.silenceNoteIsWarning ? Color.orange : Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Dims what gets cut, draws fade ramps, and the two draggable handles.
private struct TrimOverlay: View {
    @ObservedObject var model: TrimEditorModel
    let geometry: TimelineGeometry

    var body: some View {
        let g = geometry
        let x0 = g.x(model.start), x1 = g.x(model.end)
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.black.opacity(0.35))
                .frame(width: max(0, min(g.width, x0)), height: g.height)
            Rectangle().fill(Color.black.opacity(0.35))
                .frame(width: max(0, g.width - max(0, x1)), height: g.height)
                .offset(x: max(0, x1))
            // Selection outline.
            Rectangle()
                .strokeBorder(Color.accentColor, lineWidth: 2)
                .frame(width: max(2, x1 - x0), height: g.height)
                .offset(x: x0)
                .allowsHitTesting(false)
            fadeRamp(from: x0, to: g.x(model.start + min(model.fadeIn, model.selectionDuration)), rising: true)
            fadeRamp(from: g.x(model.end - min(model.fadeOut, model.selectionDuration)), to: x1, rising: false)
            TrimHandle(title: "Start", time: model.start, geometry: g) { model.setStart($0) }
                .offset(x: x0 - TrimHandle.width / 2)
            TrimHandle(title: "End", time: model.end, geometry: g) { model.setEnd($0) }
                .offset(x: x1 - TrimHandle.width / 2)
        }
        .frame(width: g.width, height: g.height, alignment: .topLeading)
    }

    @ViewBuilder
    private func fadeRamp(from a: CGFloat, to b: CGFloat, rising: Bool) -> some View {
        if b - a > 1 {
            let h = geometry.height
            Path { p in
                // The shaded triangle is the volume taken away by the fade.
                p.move(to: CGPoint(x: a, y: 0))
                p.addLine(to: rising ? CGPoint(x: a, y: h) : CGPoint(x: b, y: h))
                p.addLine(to: CGPoint(x: b, y: 0))
                p.closeSubpath()
            }
            .fill(Color.black.opacity(0.2))
            .allowsHitTesting(false)
            Path { p in
                p.move(to: CGPoint(x: a, y: rising ? h : 0))
                p.addLine(to: CGPoint(x: b, y: rising ? 0 : h))
            }
            .stroke(Color.accentColor.opacity(0.8), lineWidth: 1)
            .allowsHitTesting(false)
        }
    }
}

/// A draggable trim edge. Arrow keys (via accessibility) nudge by 0.01 s.
private struct TrimHandle: View {
    static let width: CGFloat = 14
    let title: String
    let time: Double
    let geometry: TimelineGeometry
    let onChange: (Double) -> Void
    @State private var grabOffset: Double?

    var body: some View {
        ZStack {
            Rectangle().fill(Color.clear)
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.accentColor)
                .frame(width: 8, height: min(44, geometry.height * 0.4))
                .overlay(VStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { _ in Rectangle().fill(Color.white.opacity(0.85)).frame(width: 4, height: 1) }
                })
        }
        .frame(width: Self.width, height: geometry.height)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("lane"))
            .onChanged { value in
                if grabOffset == nil { grabOffset = time - geometry.time(value.startLocation.x) }
                onChange(geometry.time(value.location.x) + (grabOffset ?? 0))
            }
            .onEnded { _ in grabOffset = nil })
        .help("\(title) \(Timecode.string(time)) — drag to trim")
        .accessibilityElement()
        .accessibilityLabel("Trim \(title.lowercased())")
        .accessibilityValue(Timecode.string(time))
        .accessibilityHint("Drag to adjust, or use arrow keys for 0.01-second steps")
        .accessibilityAdjustableAction { direction in
            onChange(time + (direction == .increment ? 0.01 : -0.01))
        }
    }
}
