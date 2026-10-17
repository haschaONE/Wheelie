import Foundation

public enum ChannelOutput: String, CaseIterable, Sendable, Identifiable {
    case mono, stereo
    public var id: String { rawValue }
    public var label: String { self == .mono ? "Mono" : "Stereo" }
    public var count: Int { self == .mono ? 1 : 2 }
}

/// Channel conversion settings.
/// - `leftVolume` / `rightVolume`: linear gain (0...2) on the source's left and right channels. For a mono
///   source going to stereo they set the two output channels; for mono -> mono only `leftVolume` applies.
/// - `balance`: -1 (left only) ... 0 (centre) ... 1 (right only). In stereo it turns the other side down;
///   in a mono mix it sets how much of each channel goes into the mix.
/// - `swapped`: left and right trade places (stereo sources going to stereo).
public struct ChannelSettings: Sendable, Equatable {
    public var output: ChannelOutput
    public var leftVolume: Double
    public var rightVolume: Double
    public var balance: Double
    public var swapped: Bool

    public init(output: ChannelOutput = .stereo, leftVolume: Double = 1, rightVolume: Double = 1,
                balance: Double = 0, swapped: Bool = false) {
        self.output = output
        self.leftVolume = leftVolume
        self.rightVolume = rightVolume
        self.balance = balance
        self.swapped = swapped
    }

    public static let volumeRange: ClosedRange<Double> = 0...2
}

public enum AudioChannels {
    public static func validate(_ s: ChannelSettings) throws {
        guard ChannelSettings.volumeRange.contains(s.leftVolume), ChannelSettings.volumeRange.contains(s.rightVolume),
              (-1...1).contains(s.balance) else {
            throw AudioToolError.invalidSettings("Choose valid audio channel settings.")
        }
    }

    /// Gain matrix: `matrix[out][in]`, with `in` being the source's (at most two) channels.
    public static func matrix(sourceChannels: Int, settings s: ChannelSettings) -> [[Double]] {
        let b = min(1, max(-1, s.balance))
        let balanceLeft = min(1, 1 - b)    // stereo: turn the left down as balance moves right
        let balanceRight = min(1, 1 + b)
        if sourceChannels <= 1 {
            switch s.output {
            case .mono: return [[s.leftVolume]]
            case .stereo: return [[s.leftVolume * balanceLeft], [s.rightVolume * balanceRight]]
            }
        }
        let l = s.leftVolume, r = s.rightVolume
        switch s.output {
        case .mono:
            let wl = 0.5 * (1 - b), wr = 0.5 * (1 + b)
            return [[wl * l, wr * r]]
        case .stereo:
            return s.swapped
                ? [[0, r * balanceLeft], [l * balanceRight, 0]]
                : [[l * balanceLeft, 0], [0, r * balanceRight]]
        }
    }

    /// e.g. "aformat=channel_layouts=stereo,pan=stereo|c0=0.8*c0|c1=1.2*c1"
    public static func filter(info: AudioInfo, settings: ChannelSettings) -> String {
        let source = min(info.channels, 2)
        var prefix = ""
        if info.channels > 2 {
            // Downmix surround to stereo first; with an unknown layout use the first two channels.
            if info.channelLayout != nil { prefix = "aformat=channel_layouts=stereo," }
        }
        let rows = matrix(sourceChannels: source, settings: settings)
        let layout = settings.output == .mono ? "mono" : "stereo"
        let specs = rows.enumerated().map { out, gains -> String in
            let terms = gains.enumerated().compactMap { input, gain -> String? in
                abs(gain) < 0.00005 ? nil : "\(AudioFFmpeg.num(gain))*c\(input)"
            }
            return "c\(out)=" + (terms.isEmpty ? "0*c0" : terms.joined(separator: "+"))
        }
        return prefix + "pan=\(layout)|" + specs.joined(separator: "|")
    }

    /// One source channel (0 = left, 1 = right) at `gain`, centred, for "play this channel" previews.
    public static func soloFilter(info: AudioInfo, channel: Int, gain: Double) -> String {
        let prefix = info.channels > 2 && info.channelLayout != nil ? "aformat=channel_layouts=stereo," : ""
        let index = min(max(0, channel), max(0, min(info.channels, 2) - 1))
        return prefix + "pan=mono|c0=\(AudioFFmpeg.num(gain))*c\(index)"
    }

    public static func arguments(input: URL, output: URL, info: AudioInfo, settings: ChannelSettings,
                                 encoding: AudioEncoding, keepVideo: Bool = true) -> [String] {
        var args = AudioFFmpeg.baseArguments + ["-i", input.path]
        args += AudioFFmpeg.streamMaps(info, encoding: encoding, keepVideo: keepVideo)
        args += ["-af", filter(info: info, settings: settings)]
        args += encoding.codecArguments
        if let rate = encoding.requiredSampleRate { args += ["-ar", "\(rate)"] }
        if info.hasVideo && keepVideo && isMP4Family(output) { args += ["-movflags", "+faststart"] }
        args.append(output.path)
        return args
    }

    static func isMP4Family(_ url: URL) -> Bool {
        ["mp4", "m4v", "mov", "m4a"].contains(url.pathExtension.lowercased())
    }

    /// Writes "<name> mono.<ext>" / "<name> stereo.<ext>" (or `output`). Video is stream-copied.
    @discardableResult
    public static func convert(_ url: URL, settings: ChannelSettings, info: AudioInfo? = nil,
                               output: URL? = nil, encoding: AudioEncoding? = nil,
                               keepVideo: Bool = true) async throws -> URL {
        try validate(settings)
        let info = try await AudioProbe.resolve(info, for: url)
        let encoding = encoding ?? AudioEncoding.matching(info, source: url)
        let output = output ?? OutputNaming.uniqueURL(for: url, ext: encoding.fileExtension,
                                                      suffix: " " + settings.output.rawValue)
        try await AudioFFmpeg.run(arguments(input: url, output: output, info: info, settings: settings,
                                            encoding: encoding, keepVideo: keepVideo), output: output)
        return output
    }

    /// Renders one source channel on its own (preview).
    public static func renderSolo(_ url: URL, info: AudioInfo, channel: Int, gain: Double, output: URL) async throws {
        let encoding = AudioEncoding.preview(forDuration: info.duration)
        let args = AudioFFmpeg.baseArguments + ["-i", url.path, "-vn", "-map", "0:\(info.audioStreamIndex)",
                                                "-af", soloFilter(info: info, channel: channel, gain: gain)]
            + encoding.codecArguments + [output.path]
        try await AudioFFmpeg.run(args, output: output)
    }
}
