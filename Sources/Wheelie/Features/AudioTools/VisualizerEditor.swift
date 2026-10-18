import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import WheelieCore

@MainActor
final class VisualizerEditorModel: AudioEditorModel {
    enum Backdrop: String, CaseIterable, Identifiable {
        case color, coverArt, image
        var id: String { rawValue }
        var label: String {
            switch self {
            case .color: return "Color"
            case .coverArt: return "Cover Art"
            case .image: return "Image"
            }
        }
    }

    @Published var style: VisualizerStyle = .waveform { didSet { if style != oldValue { refresh() } } }
    @Published var canvas: VisualizerCanvas = .square { didSet { if canvas != oldValue { refresh() } } }
    @Published var foreground = VisualizerColor.defaultForeground { didSet { if foreground != oldValue { refresh() } } }
    @Published var background = VisualizerColor.defaultBackground { didSet { if background != oldValue { refresh() } } }
    @Published var backdrop: Backdrop = .color { didSet { if backdrop != oldValue { refresh() } } }
    @Published var dimImage = true { didSet { if dimImage != oldValue { refresh() } } }
    @Published private(set) var coverArt: URL?
    @Published private(set) var customImage: URL?
    @Published private(set) var customImageName: String?
    @Published private(set) var previewImage: NSImage?
    @Published private(set) var isRenderingPreview = false
    @Published private(set) var previewError: String?

    private var previewFile: URL?
    private var loaded = false
    private var playheadWatch: AnyCancellable?

    var backgroundImage: URL? {
        switch backdrop {
        case .color: return nil
        case .coverArt: return coverArt
        case .image: return customImage
        }
    }

    var settings: VisualizerSettings {
        VisualizerSettings(style: style, canvas: canvas, foreground: foreground, background: background,
                           backgroundImage: backgroundImage, dimImage: dimImage,
                           levelBoost: AudioVisualizer.levelBoost(forPeak: Double(waveform?.maximum ?? 1)))
    }

    override var canExport: Bool {
        super.canExport && !(backdrop == .image && customImage == nil)
    }

    override func didLoad() async {
        if let info, info.coverArtStreamIndex != nil {
            coverArt = try? await AudioVisualizer.extractCoverArt(primary, info: info, into: temp.directory)
            if coverArt != nil { backdrop = .coverArt }
        }
        // Start the preview somewhere with sound rather than at 0:00.
        player.seek(to: min(primaryDuration * 0.25, 20))
        loaded = true
        refresh(delay: 0)
        // When the playhead comes to rest, show that moment.
        playheadWatch = player.$currentTime.combineLatest(player.$isPlaying)
            .dropFirst()
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] _, playing in
                guard !playing else { return }
                MainActor.assumeIsolated { self?.refresh(delay: 0) }
            }
    }

    /// Re-renders the still preview at the playhead.
    func refresh(delay: Double = 0.25) {
        guard loaded, let info else { return }
        if backdrop == .image && customImage == nil {
            previewError = "Choose an image for the visualization."
            return
        }
        if previewError != nil { previewError = nil }
        let url = primary, settings = settings, time = player.currentTime
        let output = temp.url("frame", ext: "png")
        debounce("frame", delay: delay) { [weak self] in
            guard let self else { return }
            self.isRenderingPreview = true
            defer { if !Task.isCancelled { self.isRenderingPreview = false } }
            do {
                try await AudioVisualizer.previewFrame(url, settings: settings, info: info, at: time, scale: 0.4, output: output)
                guard !Task.isCancelled else { return }
                if let image = NSImage(contentsOf: output) {
                    self.previewImage = image
                    if let old = self.previewFile { try? FileManager.default.removeItem(at: old) }
                    self.previewFile = output
                } else {
                    self.previewError = "Could not render the preview."
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.previewError = "Could not render the preview. \(error.localizedDescription)"
            }
        }
    }

    func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a background image"
        guard let window = AppServices.shared.window(id: windowID) else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { self?.useImage(url) }
        }
    }

    /// Decoding and re-encoding a big photo takes a while, so it runs off the main thread.
    private func useImage(_ url: URL) {
        let directory = temp.directory
        tasks["image"]?.cancel()
        isRenderingPreview = true
        tasks["image"] = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try AudioVisualizer.preparedImage(url, into: directory) }
            }.value
            guard let self else { return }
            guard !Task.isCancelled else {
                if case .success(let prepared) = result { try? FileManager.default.removeItem(at: prepared) }
                return
            }
            self.isRenderingPreview = false
            switch result {
            case .success(let prepared):
                // The previous image stays in the temp folder: an export may still be reading it.
                self.customImage = prepared
                self.customImageName = url.lastPathComponent
                self.error = nil
                if self.backdrop == .image { self.refresh(delay: 0) } else { self.backdrop = .image }
            case .failure(let failure):
                self.error = failure.localizedDescription
            }
        }
    }

    override func export() {
        let settings = settings
        let mode = backdrop, primary = primary, cover = coverArt, tempDir = temp.directory
        runExport("Audio Visualizer") { [weak self] in
            guard let self else { return [] }
            return try await self.forEachFile { url, info in
                var s = settings
                if url != primary {
                    // Each file gets its own level boost and cover art.
                    let peak = try? await WaveformExtractor.extract(url, buckets: 64, info: info).maximum
                    s.levelBoost = AudioVisualizer.levelBoost(forPeak: Double(peak ?? 1))
                }
                if mode == .coverArt {
                    s.backgroundImage = url == primary
                        ? cover
                        : try? await AudioVisualizer.extractCoverArt(url, info: info, into: tempDir)
                }
                return try await AudioVisualizer.render(url, settings: s, info: info)
            }
        }
    }
}

extension VisualizerColor {
    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(red: Double(ns.redComponent), green: Double(ns.greenComponent), blue: Double(ns.blueComponent))
    }

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue) }
}

struct VisualizerEditorView: View {
    @StateObject var model: VisualizerEditorModel

    private let swatches: [VisualizerColor] = [
        .defaultForeground,
        VisualizerColor(red: 1, green: 1, blue: 1),
        VisualizerColor(red: 0.35, green: 0.85, blue: 1),
        VisualizerColor(red: 1, green: 0.35, blue: 0.6),
        VisualizerColor(red: 0.55, green: 0.95, blue: 0.4),
        VisualizerColor(red: 0.7, green: 0.55, blue: 1),
    ]

    var body: some View {
        AudioEditorScaffold(model: model) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 20) {
                    previewPane
                    settingsPane.frame(width: 300)
                }
                VStack(spacing: 4) {
                    WaveformLane(timeline: model.timeline, player: model.player, peaks: model.waveform?.combined,
                                 gain: displayGain, isLoading: model.isLoading)
                        .frame(height: 56)
                    TransportBar(player: model.player, timeline: model.timeline, duration: model.info?.duration ?? 0,
                                 onPlay: { model.togglePlayback() }) {
                        Text("Move the playhead to preview another moment.").font(.caption).foregroundStyle(.secondary)
                    } trailing: { EmptyView() }
                }
            }
        } footer: {
            ExportButton(model: model, title: "Create Video")
        }
    }

    private var displayGain: Float {
        guard let max = model.waveform?.maximum, max > 0.001 else { return 1 }
        return min(20, 0.95 / max)
    }

    private var previewPane: some View {
        let aspect = CGFloat(model.canvas.width) / CGFloat(model.canvas.height)
        return ZStack {
            RoundedRectangle(cornerRadius: 8).fill(model.background.color)
            if let image = model.previewImage {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            }
            if model.isRenderingPreview {
                ProgressView().controlSize(.small)
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(8)
            }
            if let error = model.previewError {
                Text(error)
                    .font(.callout)
                    .padding(10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
        .frame(maxWidth: .infinity, maxHeight: 360)
        .accessibilityLabel("Waveform visualization preview")
    }

    private var settingsPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Visualization style").font(.headline)
                Picker("Visualization style", selection: $model.style) {
                    ForEach(VisualizerStyle.allCases) { style in
                        Label(style.label, systemImage: style.symbol).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Colors").font(.headline)
                HStack(spacing: 8) {
                    ColorPicker("Foreground", selection: Binding(get: { model.foreground.color },
                                                                 set: { model.foreground = VisualizerColor($0) }),
                                supportsOpacity: false)
                    ForEach(swatches, id: \.self) { swatch in
                        Button { model.foreground = swatch } label: {
                            Circle().fill(swatch.color).frame(width: 14, height: 14)
                                .overlay(Circle().strokeBorder(Color.primary.opacity(model.foreground == swatch ? 0.8 : 0.2)))
                        }
                        .buttonStyle(.plain)
                        .help("Use this foreground color")
                    }
                }
                ColorPicker("Background", selection: Binding(get: { model.background.color },
                                                             set: { model.background = VisualizerColor($0) }),
                            supportsOpacity: false)
                    .disabled(model.backdrop != .color)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Background").font(.headline)
                Picker("Background", selection: $model.backdrop) {
                    ForEach(VisualizerEditorModel.Backdrop.allCases) { backdrop in
                        Text(backdrop.label).tag(backdrop)
                            .disabled(backdrop == .coverArt && model.coverArt == nil)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if model.backdrop == .coverArt && model.coverArt == nil {
                    Text("This file has no cover art.").font(.caption).foregroundStyle(.secondary)
                }
                if model.backdrop == .image {
                    HStack {
                        Button(model.customImage == nil ? "Choose Image…" : "Change Image…") { model.chooseImage() }
                        if let name = model.customImageName {
                            Text(name).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                    }
                }
                if model.backdrop != .color {
                    Toggle("Dim the image", isOn: $model.dimImage)
                }
                if model.isMultiFile && model.backdrop == .coverArt {
                    Text("Each file uses its own cover art; files without art use the background color.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Size").font(.headline)
                Picker("Size", selection: $model.canvas) {
                    ForEach(VisualizerCanvas.presets) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                Text("30 fps · H.264 video with AAC audio (MP4)").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
