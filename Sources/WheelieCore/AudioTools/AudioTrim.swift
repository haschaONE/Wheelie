import Foundation

public struct TrimSettings: Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var fadeIn: Double
    public var fadeOut: Double

    public init(start: Double, end: Double, fadeIn: Double = 0, fadeOut: Double = 0) {
        self.start = start
        self.end = end
        self.fadeIn = fadeIn
        self.fadeOut = fadeOut
    }

    public var duration: Double { max(0, end - start) }
}

/// A stretch of silence reported by ffmpeg's silencedetect. `end` is nil when it runs to the end of the file.
public struct SilenceInterval: Sendable, Equatable {
    public var start: Double
    public var end: Double?

    public init(start: Double, end: Double?) {
        self.start = start
        self.end = end
    }
}

public enum AudioTrim {
    public static let minimumDuration = 0.05
    public static let thresholdRange: ClosedRange<Double> = -80 ... -10
    public static let defaultThreshold = -50.0
    public static let maximumFade = 30.0
    /// Silence shorter than this at either end is left alone.
    public static let minimumSilence = 0.05

    // MARK: Validation

    /// Clamps the range into the file and checks it is long enough.
    public static func validated(_ settings: TrimSettings, duration: Double) throws -> TrimSettings {
        var s = settings
        s.start = max(0, s.start)
        if duration > 0 { s.end = min(s.end, duration) }
        guard s.end - s.start >= minimumDuration else {
            throw AudioToolError.invalidSettings("Choose a positive time range within the file's duration.")
        }
        s.fadeIn = min(max(0, s.fadeIn), maximumFade)
        s.fadeOut = min(max(0, s.fadeOut), maximumFade)
        // Fades can't overlap past the clip's length.
        let total = s.fadeIn + s.fadeOut
        if total > s.duration {
            let scale = s.duration / total
            s.fadeIn *= scale
            s.fadeOut *= scale
        }
        return s
    }

    public static func validateThreshold(_ db: Double) throws {
        guard thresholdRange.contains(db) else {
            throw AudioToolError.invalidSettings("Choose a silence threshold between −80 and −10 dB.")
        }
    }

    // MARK: Arguments

    /// afade chain for a clip that starts at t = 0, or nil without fades.
    public static func fadeFilter(_ settings: TrimSettings) -> String? {
        var filters: [String] = []
        if settings.fadeIn > 0.0005 {
            filters.append("afade=t=in:st=0:d=\(AudioFFmpeg.num(settings.fadeIn))")
        }
        if settings.fadeOut > 0.0005 {
            let start = max(0, settings.duration - settings.fadeOut)
            filters.append("afade=t=out:st=\(AudioFFmpeg.num(start)):d=\(AudioFFmpeg.num(settings.fadeOut))")
        }
        return filters.isEmpty ? nil : filters.joined(separator: ",")
    }

    public static func arguments(input: URL, output: URL, info: AudioInfo, settings: TrimSettings,
                                 encoding: AudioEncoding) -> [String] {
        var args = AudioFFmpeg.baseArguments
        if settings.start > 0 { args += ["-ss", AudioFFmpeg.num(settings.start)] }
        args += ["-t", AudioFFmpeg.num(settings.duration), "-i", input.path]
        args += AudioFFmpeg.streamMaps(info, encoding: encoding, keepVideo: false)
        if let fades = fadeFilter(settings) { args += ["-af", fades] }
        args += encoding.codecArguments
        if let rate = encoding.requiredSampleRate { args += ["-ar", "\(rate)"] }
        args.append(output.path)
        return args
    }

    /// Writes "<name> trimmed.<ext>" (or `output`). Returns the file written.
    @discardableResult
    public static func trim(_ url: URL, settings: TrimSettings, info: AudioInfo? = nil,
                            output: URL? = nil, encoding: AudioEncoding? = nil) async throws -> URL {
        let info = try await AudioProbe.resolve(info, for: url)
        let settings = try validated(settings, duration: info.duration)
        let encoding = encoding ?? AudioEncoding.matching(info, source: url)
        let output = output ?? OutputNaming.uniqueURL(for: url, ext: encoding.fileExtension, suffix: " trimmed")
        try await AudioFFmpeg.run(arguments(input: url, output: output, info: info, settings: settings,
                                            encoding: encoding), output: output)
        return output
    }

    // MARK: Silence detection

    public static func silenceArguments(input: URL, info: AudioInfo, thresholdDB: Double,
                                        minimumSilence: Double = minimumSilence) -> [String] {
        ["-nostdin", "-hide_banner", "-nostats", "-loglevel", "info", "-i", input.path,
         "-map", "0:\(info.audioStreamIndex)", "-vn",
         "-af", "silencedetect=noise=\(AudioFFmpeg.num(thresholdDB))dB:d=\(AudioFFmpeg.num(minimumSilence))",
         "-f", "null", "-"]
    }

    /// Parses silencedetect's "silence_start: x" / "silence_end: y | silence_duration: z" lines.
    public static func parseSilences(_ stderr: String) -> [SilenceInterval] {
        var result: [SilenceInterval] = []
        for line in stderr.split(whereSeparator: \.isNewline) {
            if let value = number(after: "silence_start:", in: line) {
                result.append(SilenceInterval(start: max(0, value), end: nil))
            } else if let value = number(after: "silence_end:", in: line) {
                if let last = result.indices.last, result[last].end == nil {
                    result[last].end = value
                } else {
                    // An end without a start: silence from the very beginning.
                    result.append(SilenceInterval(start: 0, end: value))
                }
            }
        }
        return result
    }

    private static func number(after key: String, in line: Substring) -> Double? {
        guard let range = line.range(of: key) else { return nil }
        let rest = line[range.upperBound...].drop { $0 == " " }
        let token = rest.prefix { "0123456789.eE+-".contains($0) }
        return Double(token)
    }

    /// The span between leading and trailing silence. Nil when everything is silent.
    /// Silence in the middle is kept.
    public static func audibleRange(silences: [SilenceInterval], duration: Double,
                                    tolerance: Double = 0.05) -> ClosedRange<Double>? {
        var start = 0.0
        var end = duration
        if let first = silences.first, first.start <= tolerance {
            guard let firstEnd = first.end, firstEnd < duration - tolerance else { return nil }
            start = firstEnd
        }
        if let last = silences.last, last.end == nil || (last.end ?? 0) >= duration - tolerance {
            end = min(end, last.start)
        }
        guard end - start >= minimumDuration else { return nil }
        return start...end
    }

    /// Runs silencedetect and returns the audible span.
    public static func detectAudibleRange(_ url: URL, thresholdDB: Double, info: AudioInfo? = nil) async throws -> ClosedRange<Double> {
        try validateThreshold(thresholdDB)
        let info = try await AudioProbe.resolve(info, for: url)
        let output = try await Tools.capture("ffmpeg", silenceArguments(input: url, info: info, thresholdDB: thresholdDB))
        guard let range = audibleRange(silences: parseSilences(output.stderr), duration: info.duration) else {
            throw AudioToolError.silent("The audio is silent at this threshold. Lower the threshold or turn off automatic trimming.")
        }
        return range
    }
}
