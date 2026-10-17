import Foundation

/// EBU R128 loudness target for ffmpeg's loudnorm.
public struct LoudnessTarget: Sendable, Equatable {
    /// Integrated loudness, LUFS.
    public var integrated: Double
    /// Loudness range, LU.
    public var range: Double
    /// Maximum true peak, dBTP.
    public var truePeak: Double

    public init(integrated: Double, range: Double, truePeak: Double) {
        self.integrated = integrated
        self.range = range
        self.truePeak = truePeak
    }

    public static let integratedRange: ClosedRange<Double> = -70 ... -5
    public static let rangeRange: ClosedRange<Double> = 1...50
    public static let truePeakRange: ClosedRange<Double> = -9...0

    public var isValid: Bool {
        Self.integratedRange.contains(integrated) && Self.rangeRange.contains(range) && Self.truePeakRange.contains(truePeak)
    }
}

public enum LoudnessPreset: String, CaseIterable, Sendable, Identifiable {
    case streaming, podcast, broadcast, custom

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .streaming: return "Streaming"
        case .podcast: return "Podcast"
        case .broadcast: return "Broadcast"
        case .custom: return "Custom"
        }
    }

    public var target: LoudnessTarget? {
        switch self {
        case .streaming: return LoudnessTarget(integrated: -14, range: 11, truePeak: -1)
        case .podcast: return LoudnessTarget(integrated: -16, range: 11, truePeak: -1)
        case .broadcast: return LoudnessTarget(integrated: -23, range: 20, truePeak: -1)
        case .custom: return nil
        }
    }

    public var detail: String {
        switch self {
        case .streaming: return "−14 LUFS, what Spotify, YouTube and Tidal play back at. Good for music."
        case .podcast: return "−16 LUFS, the usual level for podcasts and spoken audio on Apple Podcasts and elsewhere."
        case .broadcast: return "−23 LUFS (EBU R128), the European TV and radio standard. Quieter, with more headroom."
        case .custom: return "Your own target. The true peak limit keeps the result from clipping after encoding."
        }
    }

    /// The preset matching `target`, or `.custom`.
    public static func matching(_ target: LoudnessTarget) -> LoudnessPreset {
        allCases.first { $0.target == target } ?? .custom
    }
}

/// Input measurements from loudnorm's first pass (print_format=json).
public struct LoudnessMeasurement: Sendable, Equatable {
    public var integrated: Double
    public var truePeak: Double
    public var range: Double
    public var threshold: Double
    /// Gain loudnorm suggests applying in dynamic mode, for the target it measured with.
    public var targetOffset: Double

    public init(integrated: Double, truePeak: Double, range: Double, threshold: Double, targetOffset: Double = 0) {
        self.integrated = integrated
        self.truePeak = truePeak
        self.range = range
        self.threshold = threshold
        self.targetOffset = targetOffset
    }

    public var isSilent: Bool { !integrated.isFinite || integrated <= -70 }
}

public enum AudioNormalize {
    public static let defaultTarget = LoudnessPreset.podcast.target!

    public static func validate(_ target: LoudnessTarget) throws {
        guard target.isValid else {
            throw AudioToolError.invalidSettings("Choose a target from −70 to −5 LUFS, a loudness range from 1 to 50 LU, and a true peak from −9 to 0 dBTP.")
        }
    }

    static func targetOptions(_ t: LoudnessTarget) -> String {
        "I=\(AudioFFmpeg.num(t.integrated)):LRA=\(AudioFFmpeg.num(t.range)):TP=\(AudioFFmpeg.num(t.truePeak))"
    }

    // MARK: Pass 1

    public static func measureArguments(input: URL, info: AudioInfo, target: LoudnessTarget) -> [String] {
        ["-nostdin", "-hide_banner", "-nostats", "-loglevel", "info", "-i", input.path,
         "-map", "0:\(info.audioStreamIndex)", "-vn",
         "-af", "loudnorm=\(targetOptions(target)):print_format=json", "-f", "null", "-"]
    }

    /// Parses the JSON block loudnorm prints at the end of stderr.
    public static func parseMeasurement(_ stderr: String) throws -> LoudnessMeasurement {
        let fail = AudioToolError.unreadable("Couldn't measure the loudness of this audio.")
        // The JSON follows the "[Parsed_loudnorm_0 @ ...]" line; take the last {...} block.
        let scope: Substring
        if let marker = stderr.range(of: "Parsed_loudnorm", options: .backwards) {
            scope = stderr[marker.lowerBound...]
        } else {
            scope = stderr[...]
        }
        guard let open = scope.firstIndex(of: "{"), let close = scope[open...].firstIndex(of: "}") else { throw fail }
        let json = String(scope[open...close])
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { throw fail }
        func value(_ key: String) -> Double? {
            if let s = object[key] as? String { return Double(s.trimmingCharacters(in: .whitespaces)) }
            if let d = object[key] as? Double { return d }
            return nil
        }
        guard let i = value("input_i"), let tp = value("input_tp"), let lra = value("input_lra"),
              let thresh = value("input_thresh") else { throw fail }
        return LoudnessMeasurement(integrated: i, truePeak: tp, range: lra, threshold: thresh,
                                   targetOffset: value("target_offset") ?? 0)
    }

    public static func measure(_ url: URL, target: LoudnessTarget = defaultTarget,
                               info: AudioInfo? = nil) async throws -> LoudnessMeasurement {
        let info = try await AudioProbe.resolve(info, for: url)
        let output = try await Tools.capture("ffmpeg", measureArguments(input: url, info: info, target: target))
        return try parseMeasurement(output.stderr)
    }

    // MARK: Pass 2

    /// Gain linear mode would apply, in dB.
    public static func gain(target: LoudnessTarget, measurement m: LoudnessMeasurement) -> Double {
        target.integrated - m.integrated
    }

    /// Whether loudnorm can normalize with a single gain change (keeping dynamics), mirroring its own rule:
    /// the boosted true peak must stay under the limit and the input's range must fit the target range.
    public static func isLinear(target: LoudnessTarget, measurement m: LoudnessMeasurement) -> Bool {
        guard !m.isSilent, m.range > 0 else { return false }
        return m.truePeak + gain(target: target, measurement: m) <= target.truePeak && m.range <= target.range
    }

    static func clamp(_ v: Double, _ r: ClosedRange<Double>) -> Double { min(max(v, r.lowerBound), r.upperBound) }

    /// Second-pass filter using the measured input values.
    public static func applyFilter(target: LoudnessTarget, measurement m: LoudnessMeasurement) -> String {
        "loudnorm=\(targetOptions(target))"
            + ":measured_I=\(AudioFFmpeg.num(clamp(m.integrated, -99...0)))"
            + ":measured_LRA=\(AudioFFmpeg.num(clamp(m.range, 0...99)))"
            + ":measured_TP=\(AudioFFmpeg.num(clamp(m.truePeak, -99...99)))"
            + ":measured_thresh=\(AudioFFmpeg.num(clamp(m.threshold, -99...0)))"
            + ":offset=\(AudioFFmpeg.num(clamp(m.targetOffset, -99...99)))"
            + ":linear=true:print_format=none"
    }

    public static func arguments(input: URL, output: URL, info: AudioInfo, target: LoudnessTarget,
                                 measurement: LoudnessMeasurement, encoding: AudioEncoding,
                                 keepVideo: Bool = true) -> [String] {
        var args = AudioFFmpeg.baseArguments + ["-i", input.path]
        args += AudioFFmpeg.streamMaps(info, encoding: encoding, keepVideo: keepVideo)
        args += ["-af", applyFilter(target: target, measurement: measurement)]
        args += encoding.codecArguments
        // loudnorm works at 192 kHz; go back to the source rate.
        args += ["-ar", "\(encoding.outputSampleRate(for: info))"]
        if info.hasVideo && keepVideo && AudioChannels.isMP4Family(output) { args += ["-movflags", "+faststart"] }
        args.append(output.path)
        return args
    }

    /// Two-pass normalization to "<name> normalized.<ext>" (or `output`).
    @discardableResult
    public static func normalize(_ url: URL, target: LoudnessTarget, info: AudioInfo? = nil,
                                 measurement: LoudnessMeasurement? = nil,
                                 output: URL? = nil, encoding: AudioEncoding? = nil,
                                 keepVideo: Bool = true) async throws -> URL {
        try validate(target)
        let info = try await AudioProbe.resolve(info, for: url)
        let measured: LoudnessMeasurement
        if let measurement { measured = measurement } else { measured = try await measure(url, target: target, info: info) }
        guard !measured.isSilent else {
            throw AudioToolError.silent("\(url.lastPathComponent) is silent, so there's nothing to normalize.")
        }
        let encoding = encoding ?? AudioEncoding.matching(info, source: url)
        let output = output ?? OutputNaming.uniqueURL(for: url, ext: encoding.fileExtension, suffix: " normalized")
        try await AudioFFmpeg.run(arguments(input: url, output: output, info: info, target: target,
                                            measurement: measured, encoding: encoding, keepVideo: keepVideo),
                                  output: output)
        return output
    }
}
