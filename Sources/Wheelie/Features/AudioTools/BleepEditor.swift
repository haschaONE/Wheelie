import AppKit
import SwiftUI
import WheelieCore

@MainActor
final class BleepEditorModel: AudioEditorModel {
    static let minimumLength = 0.05

    @Published private(set) var ranges: [BleepRange] = [] { didSet { settingsChanged() } }
    @Published var selection: UUID?
    @Published var style: BleepStyle = .beep { didSet { if style != oldValue { settingsChanged() } } }
    @Published var volume: Double = 0.3 { didSet { if volume != oldValue { settingsChanged() } } }
    @Published var hearBleeps = true { didSet { if hearBleeps != oldValue { previewModeChanged() } } }

    private var previewURL: URL?
    private var previewKey: String?
    /// The range "Bleep Entire Audio" made. While it still ends at the end of the previewed file, it runs to
    /// the end of every selected file, however long each one is.
    private var wholeFileRange: UUID?

    var settings: BleepSettings {
        let open = ranges.map { range -> BleepRange in
            guard range.id == wholeFileRange, range.end >= primaryDuration else { return range }
            return BleepRange(id: range.id, start: range.start, end: .infinity)
        }
        return BleepSettings(ranges: open, style: style, volume: volume)
    }
    override var canExport: Bool { super.canExport && !ranges.isEmpty }
    var selected: BleepRange? { ranges.first { $0.id == selection } }
    var sortedRanges: [BleepRange] { ranges.sorted { $0.start < $1.start } }

    // MARK: Editing

    @discardableResult
    func addRange(start: Double, end: Double) -> UUID {
        let a = max(0, min(start, end)), b = min(primaryDuration, max(start, end))
        let range = BleepRange(start: a, end: max(b, min(primaryDuration, a + Self.minimumLength)))
        ranges.append(range)
        selection = range.id
        error = nil
        return range.id
    }

    func addAtPlayhead() {
        let length = min(1, primaryDuration)
        let start = min(player.currentTime, max(0, primaryDuration - length))
        addRange(start: start, end: start + length)
    }

    func bleepEntireAudio() {
        let range = BleepRange(start: 0, end: primaryDuration)
        wholeFileRange = range.id
        ranges = [range]
        selection = range.id
    }

    func setStart(_ id: UUID, _ value: Double) {
        guard let i = ranges.firstIndex(where: { $0.id == id }) else { return }
        let end = ranges[i].end
        ranges[i] = BleepRange(id: id, start: min(max(0, value), end - Self.minimumLength), end: end)
    }

    func setEnd(_ id: UUID, _ value: Double) {
        guard let i = ranges.firstIndex(where: { $0.id == id }) else { return }
        let start = ranges[i].start
        ranges[i] = BleepRange(id: id, start: start, end: max(min(primaryDuration, value), start + Self.minimumLength))
    }

    /// Moves a range keeping its length.
    func move(_ id: UUID, toStart value: Double) {
        guard let i = ranges.firstIndex(where: { $0.id == id }) else { return }
        let length = ranges[i].duration
        let start = min(max(0, value), max(0, primaryDuration - length))
        ranges[i] = BleepRange(id: id, start: start, end: start + length)
    }

    func delete(_ id: UUID) {
        ranges.removeAll { $0.id == id }
        if selection == id { selection = nil }
    }

    override func deleteSelection() -> Bool {
        guard let selection else { return false }
        delete(selection)
        return true
    }

    // MARK: Preview

    private var key: String {
        let merged = AudioBleep.merged(settings.ranges, duration: primaryDuration)
        return "\(style.rawValue)-\(volume)-" + merged.map { "\($0.lowerBound)-\($0.upperBound)" }.joined(separator: ",")
    }

    override func togglePlayback() {
        if player.isPlaying { player.pause(); return }
        guard hearBleeps, !ranges.isEmpty else {
            player.use(primary)
            player.play()
            return
        }
        if let previewURL, previewKey == key {
            player.use(previewURL)
            player.play()
        } else {
            renderPreview(thenPlay: true, delay: 0)
        }
    }

    private func previewModeChanged() {
        if !hearBleeps || ranges.isEmpty {
            player.use(primary)
        } else if let previewURL, previewKey == key {
            tasks["preview"]?.cancel()          // a render for other settings must not replace it
            player.use(previewURL)
        } else if player.isPlaying {
            renderPreview(thenPlay: false, delay: 0)
        }
    }

    private func settingsChanged() {
        guard info != nil else { return }
        if ranges.isEmpty {
            tasks["preview"]?.cancel()
            player.use(primary)
            return
        }
        guard hearBleeps, player.isPlaying, player.source != primary else { return }
        renderPreview(thenPlay: false, delay: 0.4)
    }

    private func renderPreview(thenPlay: Bool, delay: Double) {
        guard let info else { return }
        let url = primary, settings = settings, key = key
        let output = AudioPreview.temporaryURL(in: temp.directory, prefix: "bleep", info: info)
        debounce("preview", delay: delay) { [weak self] in
            guard let self else { return }
            self.player.isPreparing = true
            defer { if !Task.isCancelled { self.player.isPreparing = false } }
            do {
                try await AudioBleep.bleep(url, settings: settings, info: info, output: output,
                                           encoding: .preview(forDuration: info.duration))
                guard !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: output)
                    return
                }
                // The bleeps changed meanwhile: this render is for settings no longer shown.
                guard self.key == key else {
                    try? FileManager.default.removeItem(at: output)
                    if thenPlay, self.hearBleeps, !self.ranges.isEmpty { self.renderPreview(thenPlay: true, delay: 0) }
                    return
                }
                let old = self.previewURL
                self.previewURL = output
                self.previewKey = key
                if self.hearBleeps, !self.ranges.isEmpty {
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
                self.error = "Could not play the bleep preview. \(error.localizedDescription)"
                if thenPlay {
                    self.player.use(url)
                    self.player.play()
                }
            }
        }
    }

    override func export() {
        guard !ranges.isEmpty else {
            error = "Add at least one bleep range."
            return
        }
        let settings = settings
        runExport("Bleep Audio") { [weak self] in
            guard let self else { return [] }
            return try await self.forEachFile { url, info in
                try await AudioBleep.bleep(url, settings: settings, info: info)
            }
        }
    }
}

struct BleepEditorView: View {
    @StateObject var model: BleepEditorModel

    var body: some View {
        AudioEditorScaffold(model: model) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(spacing: 4) {
                    TimeRuler(timeline: model.timeline)
                    WaveformLane(timeline: model.timeline, player: model.player, peaks: model.waveform?.combined,
                                 gain: displayGain, isLoading: model.isLoading) { g in
                        BleepTint(model: model, geometry: g)
                    }
                    .frame(minHeight: 120)
                    BleepLane(model: model, timeline: model.timeline)
                        .frame(height: 34)
                }
                TransportBar(player: model.player, timeline: model.timeline, duration: model.info?.duration ?? 0,
                             playHelp: "Play or pause the timeline preview (Space)",
                             onPlay: { model.togglePlayback() }) {
                    Button {
                        model.addAtPlayhead()
                    } label: {
                        Label("Add Bleep at Playhead", systemImage: "plus")
                    }
                    Button("Bleep Entire Audio") { model.bleepEntireAudio() }
                } trailing: { EmptyView() }
                if let note = model.waveformNote {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
                HStack(alignment: .top, spacing: 24) {
                    rangeList
                    sound.frame(width: 270)
                }
            }
        } footer: {
            ExportButton(model: model, title: "Save Bleeped Copy")
        }
    }

    private var displayGain: Float {
        guard let max = model.waveform?.maximum, max > 0.001 else { return 1 }
        return min(20, 0.95 / max)
    }

    private var rangeList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.ranges.isEmpty ? "No bleeps yet" : "Bleeps (\(model.ranges.count))").font(.headline)
            if model.ranges.isEmpty {
                Text("Drag across the Bleep layer to add a section, then drag a clip or either edge to adjust it. Delete removes the selected bleep.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(model.sortedRanges.enumerated()), id: \.element.id) { index, range in
                            rangeRow(index: index, range: range)
                        }
                    }
                }
                .frame(maxHeight: 92)
            }
            if let selected = model.selected {
                HStack(spacing: 8) {
                    Text("Start").foregroundStyle(.secondary)
                    TimeField(label: "Start", value: Binding(get: { model.selected?.start ?? selected.start },
                                                             set: { model.setStart(selected.id, $0) }))
                    Text("End").foregroundStyle(.secondary)
                    TimeField(label: "End", value: Binding(get: { model.selected?.end ?? selected.end },
                                                           set: { model.setEnd(selected.id, $0) }))
                    Button(role: .destructive) { model.delete(selected.id) } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .help("Delete the selected bleep (Delete)")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rangeRow(index: Int, range: BleepRange) -> some View {
        let isSelected = model.selection == range.id
        return HStack(spacing: 8) {
            Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 18)
            Text("\(Timecode.string(range.start)) – \(Timecode.string(range.end))").font(.callout.monospacedDigit())
            Text(String(format: "%.2f s", range.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Spacer()
            Button { model.delete(range.id) } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Delete this bleep")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture {
            model.selection = range.id
            model.player.seek(to: range.start)
        }
    }

    private var sound: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sound").font(.headline)
            Picker("Style", selection: $model.style) {
                ForEach(BleepStyle.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            HStack(spacing: 6) {
                Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                Slider(value: $model.volume, in: 0.05...1)
                    .accessibilityLabel("Beep volume")
                Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                Text("\(Int((model.volume * 100).rounded()))%").font(.caption.monospacedDigit()).frame(width: 34)
            }
            .disabled(model.style != .beep)
            Text(model.style == .beep ? "A 1 kHz tone replaces the audio in each bleep." : "Each bleep is muted.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Hear bleeps when playing", isOn: $model.hearBleeps)
                .help("Play renders a preview with the bleeps applied")
        }
    }
}

/// Red columns over the waveform where bleeps are.
private struct BleepTint: View {
    @ObservedObject var model: BleepEditorModel
    let geometry: TimelineGeometry

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(model.ranges) { range in
                let x0 = geometry.x(range.start), x1 = geometry.x(range.end)
                Rectangle()
                    .fill(Color.red.opacity(model.selection == range.id ? 0.3 : 0.2))
                    .frame(width: max(1, x1 - x0), height: geometry.height)
                    .offset(x: x0)
            }
        }
        .frame(width: geometry.width, height: geometry.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

/// The bleep layer: drag on empty space to add, drag a clip to move, drag its ends to resize.
private struct BleepLane: View {
    @ObservedObject var model: BleepEditorModel
    @ObservedObject var timeline: TimelineController

    private enum Drag {
        case create(anchor: Double)
        case move(id: UUID, grab: Double)
        case resizeStart(UUID)
        case resizeEnd(UUID)
    }

    @State private var drag: Drag?
    @State private var draft: ClosedRange<Double>?
    private let edge: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let g = TimelineGeometry(viewport: timeline.viewport, width: geo.size.width, height: geo.size.height)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.red.opacity(0.05))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
                if model.ranges.isEmpty && draft == nil {
                    Text("Drag here to add a bleep")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: g.width, height: g.height)
                }
                ForEach(model.ranges) { range in
                    clip(range, g)
                }
                if let draft {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.red.opacity(0.45))
                        .frame(width: max(2, g.x(draft.upperBound) - g.x(draft.lowerBound)), height: g.height - 6)
                        .offset(x: g.x(draft.lowerBound), y: 3)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .coordinateSpace(name: "bleepLane")
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("bleepLane"))
                .onChanged { value in changed(value, g) }
                .onEnded { value in ended(value, g) })
            .onContinuousHover(coordinateSpace: .named("bleepLane")) { phase in
                switch phase {
                case .active(let point):
                    switch hit(point.x, g) {
                    case .resizeStart, .resizeEnd: NSCursor.resizeLeftRight.set()
                    case .move: NSCursor.openHand.set()
                    default: NSCursor.arrow.set()
                    }
                case .ended:
                    NSCursor.arrow.set()
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Bleep layer. Drag to add a bleep.")
        }
    }

    private func clip(_ range: BleepRange, _ g: TimelineGeometry) -> some View {
        let x0 = g.x(range.start), x1 = g.x(range.end)
        let selected = model.selection == range.id
        return RoundedRectangle(cornerRadius: 4)
            .fill(Color.red.opacity(selected ? 0.9 : 0.7))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(selected ? 0.9 : 0), lineWidth: 2))
            .overlay(alignment: .leading) {
                if x1 - x0 > 54 {
                    Text(model.style == .beep ? "BLEEP" : "MUTE")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.leading, 8)
                }
            }
            .frame(width: max(3, x1 - x0), height: g.height - 6)
            .offset(x: x0, y: 3)
            .accessibilityElement()
            .accessibilityLabel("Bleep from \(Timecode.string(range.start)) to \(Timecode.string(range.end))")
            .accessibilityHint("Drag to move. Drag either end to change duration.")
            .accessibilityAction(named: "Delete") { model.delete(range.id) }
            .accessibilityAction { model.selection = range.id }
    }

    private func hit(_ x: CGFloat, _ g: TimelineGeometry) -> Drag? {
        // Prefer the selected range, then the topmost (latest) one.
        var ordered = Array(model.ranges.reversed())
        if let selection = model.selection, let i = ordered.firstIndex(where: { $0.id == selection }) {
            ordered.insert(ordered.remove(at: i), at: 0)
        }
        for range in ordered {
            let x0 = g.x(range.start), x1 = g.x(range.end)
            if abs(x - x0) <= edge { return .resizeStart(range.id) }
            if abs(x - x1) <= edge { return .resizeEnd(range.id) }
            if x > x0 && x < x1 { return .move(id: range.id, grab: g.time(x) - range.start) }
        }
        return nil
    }

    private func changed(_ value: DragGesture.Value, _ g: TimelineGeometry) {
        if drag == nil {
            NSApp.keyWindow?.makeFirstResponder(nil)
            drag = hit(value.startLocation.x, g) ?? .create(anchor: g.time(value.startLocation.x))
            switch drag {
            case .move(let id, _), .resizeStart(let id), .resizeEnd(let id): model.selection = id
            default: break
            }
        }
        let t = g.time(value.location.x)
        switch drag {
        case .create(let anchor):
            if abs(value.translation.width) > 3 { draft = min(anchor, t)...max(anchor, t) }
        case .move(let id, let grab):
            if abs(value.translation.width) > 1 { model.move(id, toStart: t - grab) }
        case .resizeStart(let id):
            model.setStart(id, t)
        case .resizeEnd(let id):
            model.setEnd(id, t)
        case nil:
            break
        }
    }

    private func ended(_ value: DragGesture.Value, _ g: TimelineGeometry) {
        defer { drag = nil; draft = nil }
        switch drag {
        case .create(let anchor):
            if let draft, draft.upperBound - draft.lowerBound >= BleepEditorModel.minimumLength {
                model.addRange(start: draft.lowerBound, end: draft.upperBound)
            } else {
                // A click on empty space: deselect and move the playhead there.
                model.selection = nil
                model.player.seek(to: anchor)
            }
        default:
            break
        }
    }
}
