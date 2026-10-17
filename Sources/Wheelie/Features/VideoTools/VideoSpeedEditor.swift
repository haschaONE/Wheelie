import SwiftUI
import WheelieCore

/// Speed: 0.25×–4× with presets; the preview plays at the chosen rate.
struct VideoSpeedEditor: View {
    let url: URL
    let windowID: String
    @StateObject private var player: VideoToolsPlayer
    @StateObject private var exporter = VideoToolsExporter()
    @State private var speed: Double = 2
    @AppStorage("videoSpeed.keepPitch") private var keepPitch = true

    init(url: URL, windowID: String) {
        self.url = url
        self.windowID = windowID
        _player = StateObject(wrappedValue: VideoToolsPlayer(url: url))
    }

    private var blocker: String? {
        if !VideoSpeed.range.contains(speed) { return VideoSpeed.rangeMessage }
        if abs(speed - 1) < 0.001 { return "Choose a speed other than 1×." }
        return nil
    }

    /// The slider works on log2(speed) so 0.5× and 2× sit equally far from 1×.
    private var sliderValue: Binding<Double> {
        Binding(get: { log2(speed) },
                set: { setSpeed((pow(2, $0) * 20).rounded() / 20) })
    }

    var body: some View {
        VideoToolsShell(windowID: windowID, exporter: exporter, player: player,
                         exportLabel: "Export at \(VideoSpeed.label(speed))", blocker: blocker,
                         hint: player.canPlay ? "The preview plays at the chosen speed." : nil,
                         onExport: export, onKey: handleKey) {
            VStack(spacing: 10) {
                VideoToolsPreview(player: player, unavailableMessage:
                    "Video preview is unavailable for this file. You can still export at the selected speed.")
                    .frame(minHeight: 240)
                    .accessibilityLabel("Video speed preview at \(VideoSpeed.label(speed))")
                VideoToolsTimeline(player: player)
                    .padding(.horizontal, 12)
                VideoToolsTransportBar(player: player)
            }
        } controls: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Slider(value: sliderValue, in: -2...2) {
                        Text("Speed")
                    } minimumValueLabel: {
                        Text("0.25×").font(.caption)
                    } maximumValueLabel: {
                        Text("4×").font(.caption)
                    }
                    .accessibilityValue(VideoSpeed.label(speed))
                    Text(VideoSpeed.label(speed))
                        .font(.system(.title3, design: .monospaced).weight(.semibold))
                        .frame(width: 70, alignment: .trailing)
                }
                HStack(spacing: 6) {
                    ForEach(VideoSpeed.presets, id: \.self) { preset in
                        Button(VideoSpeed.label(preset)) { setSpeed(preset) }
                            .buttonStyle(.bordered)
                            .tint(abs(speed - preset) < 0.001 ? .accentColor : nil)
                            .accessibilityAddTraits(abs(speed - preset) < 0.001 ? .isSelected : [])
                    }
                    Spacer()
                    Toggle("Keep pitch", isOn: $keepPitch)
                        .disabled(!player.hasAudio)
                        .help(player.hasAudio ? "Off: the audio speeds up or slows down like tape, changing its pitch."
                                              : "This video has no audio.")
                }
                Text("New length \(VideoToolTimecode.format(player.duration / speed)) (was \(VideoToolTimecode.format(player.duration)))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 680, idealWidth: 860, minHeight: 600, idealHeight: 680)
        .onAppear {
            player.rate = Float(speed)
            player.keepPitch = keepPitch
        }
        .onChange(of: keepPitch) { player.keepPitch = keepPitch }
    }

    private func setSpeed(_ value: Double) {
        speed = min(max(value, VideoSpeed.range.lowerBound), VideoSpeed.range.upperBound)
        player.rate = Float(speed)
    }

    private func handleKey(_ key: VideoToolsKey) -> Bool {
        switch key {
        case .character("+"), .character("="):
            setSpeed(VideoSpeed.presets.first { $0 > speed + 0.001 } ?? speed)
        case .character("-"):
            setSpeed(VideoSpeed.presets.last { $0 < speed - 0.001 } ?? speed)
        default: return false
        }
        return true
    }

    private func export() {
        let (url, speed, keepPitch) = (url, speed, keepPitch)
        exporter.start(windowID: windowID, title: "Speed \(VideoSpeed.label(speed))", sources: [url]) { progress in
            [try await VideoToolOps.changeSpeed(url, factor: speed, keepPitch: keepPitch, progress: progress)]
        }
    }
}
