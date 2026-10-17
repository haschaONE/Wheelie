import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum VisualizerStyle: String, CaseIterable, Sendable, Identifiable {
    case waveform, bars, spectrum, circle
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .waveform: return "Waveform"
        case .bars: return "Bars"
        case .spectrum: return "Spectrum"
        case .circle: return "Circle"
        }
    }
    public var symbol: String {
        switch self {
        case .waveform: return "waveform"
        case .bars: return "chart.bar.fill"
        case .spectrum: return "rectangle.split.3x1"
        case .circle: return "circle.dashed"
        }
    }
}

public struct VisualizerCanvas: Sendable, Equatable, Hashable, Identifiable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public var id: String { "\(width)x\(height)" }

    public static let square = VisualizerCanvas(width: 1080, height: 1080)
    public static let landscape = VisualizerCanvas(width: 1920, height: 1080)
    public static let portrait = VisualizerCanvas(width: 1080, height: 1920)
    public static let presets: [VisualizerCanvas] = [.square, .landscape, .portrait]

    public var label: String {
        switch self {
        case .square: return "Square 1080 × 1080"
        case .landscape: return "Landscape 16:9 · 1920 × 1080"
        case .portrait: return "Portrait 9:16 · 1080 × 1920"
        default: return "\(width) × \(height)"
        }
    }

    /// Same aspect, scaled (for quick previews); dimensions stay even.
    public func scaled(_ factor: Double) -> VisualizerCanvas {
        VisualizerCanvas(width: Self.even(Double(width) * factor), height: Self.even(Double(height) * factor))
    }

    static func even(_ value: Double) -> Int { max(2, Int((value / 2).rounded()) * 2) }
}

public struct VisualizerColor: Sendable, Equatable, Hashable {
    public var red: Double, green: Double, blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// "0xRRGGBB" for ffmpeg color options.
    public var ffmpeg: String {
        func byte(_ v: Double) -> Int { Int((min(1, max(0, v)) * 255).rounded()) }
        return String(format: "0x%02X%02X%02X", byte(red), byte(green), byte(blue))
    }

    public static let defaultForeground = VisualizerColor(red: 1, green: 0.55, blue: 0.16)
    public static let defaultBackground = VisualizerColor(red: 0.07, green: 0.08, blue: 0.13)
}

public struct VisualizerSettings: Sendable, Equatable {
    public var style: VisualizerStyle
    public var canvas: VisualizerCanvas
    public var foreground: VisualizerColor
    public var background: VisualizerColor
    /// Image drawn behind the visualization (scaled to fill). Nil = solid background colour.
    public var backgroundImage: URL?
    /// Darkens the background image so the visualization stands out.
    public var dimImage: Bool
    public var frameRate: Int
    /// Gain on the analysed signal only (see `AudioVisualizer.levelBoost(forPeak:)`); the audio track is untouched.
    public var levelBoost: Double

    public init(style: VisualizerStyle = .waveform, canvas: VisualizerCanvas = .square,
                foreground: VisualizerColor = .defaultForeground, background: VisualizerColor = .defaultBackground,
                backgroundImage: URL? = nil, dimImage: Bool = true, frameRate: Int = 30, levelBoost: Double = 1) {
        self.style = style
        self.canvas = canvas
        self.foreground = foreground
        self.background = background
        self.backgroundImage = backgroundImage
        self.dimImage = dimImage
        self.frameRate = frameRate
        self.levelBoost = levelBoost
    }
}

public enum AudioVisualizer {
    /// Sample rate the visualization branch works at (the Hilbert filter needs a fixed one).
    static let analysisRate = 44100

    /// Gain for the analysis branch so quiet recordings still fill the frame (never turns loud ones down).
    public static func levelBoost(forPeak peak: Double) -> Double {
        guard peak.isFinite, peak > 0 else { return 1 }
        return min(8, max(1, 0.9 / peak))
    }

    /// Bar layout: whole-pixel bars that fit the width. Returns (bar count, bar width, gap).
    static func barLayout(width: Int) -> (count: Int, width: Int, gap: Int) {
        let barWidth = max(6, width / 64)
        return (max(8, width / barWidth), barWidth, max(2, barWidth / 4))
    }

    /// Graph fragment from `[input]` to a white-on-black luminance mask `[mask]` the size of the canvas.
    public static func maskGraph(style: VisualizerStyle, canvas: VisualizerCanvas, fps: Int, input: String,
                                 levelBoost: Double = 1) -> String {
        let w = canvas.width, h = canvas.height
        let short = min(w, h)
        var fmt = "aformat=sample_rates=\(analysisRate)"
        // The waveform's sqrt scale and the spectrum's log scale already lift quiet audio.
        if levelBoost > 1.01, style == .bars || style == .circle { fmt += ",volume=\(AudioFFmpeg.num(levelBoost))" }
        switch style {
        case .waveform:
            let bandH = VisualizerCanvas.even(Double(short) * 0.55)
            return "[\(input)]\(fmt),showwaves=s=\(w)x\(bandH):mode=cline:draw=full:scale=sqrt:colors=white:rate=\(fps)"
                + ",format=gray,pad=\(w):\(h):0:(oh-ih)/2:black[mask]"
        case .bars:
            // A few dozen chunky bars: analyse at one pixel per bar, blow up without smoothing, cut gaps.
            let bandH = VisualizerCanvas.even(Double(short) * 0.5)
            let bars = barLayout(width: w)
            let used = bars.count * bars.width
            return "[\(input)]\(fmt),aformat=channel_layouts=mono,showfreqs=s=\(bars.count)x\(bandH):mode=bar"
                + ":ascale=cbrt:fscale=log:win_size=4096:averaging=2:colors=white:rate=\(fps)"
                + ",scale=\(used):\(bandH):flags=neighbor"
                + ",drawgrid=w=\(bars.width):h=\(bandH + 8):t=\(bars.gap):c=black"
                + ",format=gray,pad=\(w):\(h):\((w - used) / 2):(oh-ih)/2:black[mask]"
        case .spectrum:
            // Rendered narrow and stretched, so it scrolls at a lively pace.
            let sw = VisualizerCanvas.even(Double(w) / 4), sh = VisualizerCanvas.even(Double(h) / 2)
            return "[\(input)]\(fmt),aformat=channel_layouts=mono,showspectrum=s=\(sw)x\(sh):slide=scroll:mode=combined"
                + ":color=intensity:scale=log:fscale=log:drange=70:fps=\(fps)"
                + ",format=gray,scale=\(w):\(h):flags=bicubic[mask]"
        case .circle:
            // The signal against its Hilbert transform (90° phase shift) traces circles in a vectorscope.
            let size = VisualizerCanvas.even(Double(short) * 0.8)
            let taps = 511
            return "[\(input)]\(fmt),aformat=channel_layouts=mono,asplit[vzdry][vzwet];"
                + "hilbert=sample_rate=\(analysisRate):taps=\(taps)[vzir];"
                + "[vzwet][vzir]afir=irnorm=-1[vzshift];[vzdry]adelay=\((taps - 1) / 2)S[vzdelay];"
                + "[vzdelay][vzshift]join=inputs=2:channel_layout=stereo,"
                // Peaks arrive at ~0.9 after the level boost; the Hilbert branch can overshoot, so leave room.
                + "avectorscope=s=\(size)x\(size):mode=lissajous_xy:draw=line:scale=lin:zoom=0.75:rate=\(fps)"
                + ":rc=255:gc=255:bc=255:ac=255:rf=25:gf=25:bf=25:af=25"
                + ",format=gray,pad=\(w):\(h):(ow-iw)/2:(oh-ih)/2:black[mask]"
        }
    }

    /// Full filter graph: audio input 0 (and image input 1 when `hasImage`) -> [video].
    public static func filterGraph(settings: VisualizerSettings, canvas: VisualizerCanvas? = nil,
                                   duration: Double, audioStream: Int, hasImage: Bool) -> String {
        let c = canvas ?? settings.canvas
        let fps = settings.frameRate
        let size = "\(c.width)x\(c.height)"
        let d = AudioFFmpeg.num(max(0.1, duration) + 0.5)
        var graph = maskGraph(style: settings.style, canvas: c, fps: fps, input: "0:\(audioStream)",
                              levelBoost: settings.levelBoost) + ";"
        graph += "color=c=\(settings.foreground.ffmpeg):s=\(size):r=\(fps):d=\(d)[ink];[ink][mask]alphamerge[fg];"
        if hasImage {
            graph += "[1:v]scale=\(c.width):\(c.height):force_original_aspect_ratio=increase,crop=\(c.width):\(c.height)"
                + ",setsar=1,fps=\(fps)"
                + (settings.dimImage ? ",format=rgb24,colorchannelmixer=rr=0.5:gg=0.5:bb=0.5" : "") + "[bg];"
        } else {
            graph += "color=c=\(settings.background.ffmpeg):s=\(size):r=\(fps):d=\(d)[bg];"
        }
        graph += "[bg][fg]overlay=shortest=1:format=auto,format=yuv420p[video]"
        return graph
    }

    public static func arguments(input: URL, output: URL, info: AudioInfo, settings: VisualizerSettings) -> [String] {
        let duration = info.duration
        var args = AudioFFmpeg.baseArguments + ["-i", input.path]
        if let image = settings.backgroundImage {
            args += ["-loop", "1", "-framerate", "\(settings.frameRate)", "-t", AudioFFmpeg.num(duration + 0.5),
                     "-i", image.path]
        }
        args += ["-filter_complex", filterGraph(settings: settings, duration: duration,
                                                audioStream: info.audioStreamIndex,
                                                hasImage: settings.backgroundImage != nil)]
        args += ["-map", "[video]", "-map", "0:\(info.audioStreamIndex)",
                 "-c:v", "libx264", "-preset", "faster", "-crf", "20", "-pix_fmt", "yuv420p",
                 "-r", "\(settings.frameRate)", "-c:a", "aac", "-b:a", "192k",
                 "-t", AudioFFmpeg.num(duration), "-shortest", "-movflags", "+faststart", output.path]
        return args
    }

    /// Writes "<name> visualizer.mp4" (or `output`).
    @discardableResult
    public static func render(_ url: URL, settings: VisualizerSettings, info: AudioInfo? = nil,
                              output: URL? = nil) async throws -> URL {
        let info = try await AudioProbe.resolve(info, for: url)
        guard info.duration > 0 else { throw AudioToolError.unreadable("This file has no playable duration.") }
        let output = output ?? OutputNaming.uniqueURL(for: url, ext: "mp4", suffix: " visualizer")
        try await AudioFFmpeg.run(arguments(input: url, output: output, info: info, settings: settings), output: output)
        return output
    }

    /// Renders one PNG frame of the visualization at `time`, at `scale` of the canvas size.
    public static func previewFrame(_ url: URL, settings: VisualizerSettings, info: AudioInfo, at time: Double,
                                    scale: Double = 0.4, output: URL) async throws {
        // Run up to the frame so history-based styles (spectrum, circle trails) look as they will in the video.
        let lead = settings.style == .spectrum ? 6.0 : 0.6
        let t = min(max(0, time), max(0, info.duration - 0.05))
        let start = max(0, t - lead)
        let length = max(0.1, t - start + 1.0 / Double(settings.frameRate))
        let canvas = settings.canvas.scaled(scale)
        var args = AudioFFmpeg.baseArguments + ["-ss", AudioFFmpeg.num(start), "-t", AudioFFmpeg.num(length), "-i", url.path]
        if let image = settings.backgroundImage {
            args += ["-loop", "1", "-framerate", "\(settings.frameRate)", "-t", AudioFFmpeg.num(length + 0.5), "-i", image.path]
        }
        args += ["-filter_complex", filterGraph(settings: settings, canvas: canvas, duration: length,
                                                audioStream: info.audioStreamIndex,
                                                hasImage: settings.backgroundImage != nil)]
        // image2 with -update rewrites the file per frame; the last one written is the frame at `time`.
        args += ["-map", "[video]", "-update", "1", "-c:v", "png", "-f", "image2", output.path]
        try await AudioFFmpeg.run(args, output: output)
    }

    /// Saves embedded cover art as PNG in `directory`; nil when the file has none.
    public static func extractCoverArt(_ url: URL, info: AudioInfo, into directory: URL) async throws -> URL? {
        guard let index = info.coverArtStreamIndex else { return nil }
        let output = directory.appendingPathComponent("cover-\(UUID().uuidString).png")
        try await AudioFFmpeg.run(AudioFFmpeg.baseArguments + ["-i", url.path, "-map", "0:\(index)",
                                                               "-frames:v", "1", "-update", "1", output.path],
                                  output: output)
        return output
    }

    /// Re-encodes any image ImageIO can read (HEIC, WebP, ...) as PNG so ffmpeg can use it.
    public static func preparedImage(_ url: URL, into directory: URL) throws -> URL {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw AudioToolError.unreadable("Could not read the image.")
        }
        let output = directory.appendingPathComponent("background-\(UUID().uuidString).png")
        guard let dest = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw AudioToolError.unreadable("Could not read the image.")
        }
        // Honour EXIF orientation.
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: max(image.width, image.height)]
        let oriented = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) ?? image
        CGImageDestinationAddImage(dest, oriented, nil)
        guard CGImageDestinationFinalize(dest) else { throw AudioToolError.unreadable("Could not read the image.") }
        return output
    }
}
