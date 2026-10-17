import Foundation

public struct BleepRange: Sendable, Equatable, Identifiable, Hashable {
    public var id: UUID
    public var start: Double
    public var end: Double

    public init(id: UUID = UUID(), start: Double, end: Double) {
        self.id = id
        self.start = min(start, end)
        self.end = max(start, end)
    }

    public var duration: Double { end - start }
}

public enum BleepStyle: String, CaseIterable, Sendable, Identifiable {
    case beep, silence
    public var id: String { rawValue }
    public var label: String { self == .beep ? "Beep Tone" : "Silence" }
}

public struct BleepSettings: Sendable, Equatable {
    public var ranges: [BleepRange]
    public var style: BleepStyle
    /// Tone amplitude, 0...1 of full scale.
    public var volume: Double
    public var frequency: Double

    public init(ranges: [BleepRange] = [], style: BleepStyle = .beep, volume: Double = 0.3, frequency: Double = 1000) {
        self.ranges = ranges
        self.style = style
        self.volume = volume
        self.frequency = frequency
    }
}

public enum AudioBleep {
    public static let minimumRange = 0.02

    /// Sorted, clamped to the file, overlapping or touching ranges merged, tiny ones dropped.
    public static func merged(_ ranges: [BleepRange], duration: Double) -> [ClosedRange<Double>] {
        let clamped = ranges.compactMap { r -> ClosedRange<Double>? in
            let a = max(0, r.start), b = duration > 0 ? min(duration, r.end) : r.end
            return b - a >= minimumRange ? a...b : nil
        }.sorted { $0.lowerBound < $1.lowerBound }
        var result: [ClosedRange<Double>] = []
        for range in clamped {
            if let last = result.last, range.lowerBound <= last.upperBound {
                result[result.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }

    /// "between(t,1.5,2)+between(t,4,4.25)" — non-zero inside any range.
    public static func enableExpression(_ ranges: [ClosedRange<Double>]) -> String {
        ranges.map { "between(t,\(AudioFFmpeg.num($0.lowerBound)),\(AudioFFmpeg.num($0.upperBound)))" }
            .joined(separator: "+")
    }

    /// Filter graph from input 0's audio to [bleeped].
    /// Muting: `volume=0` enabled inside the ranges. Beep: a sine tone gated to the same ranges, mixed back in.
    public static func filterGraph(settings: BleepSettings, info: AudioInfo) throws -> String {
        let ranges = merged(settings.ranges, duration: info.duration)
        guard !ranges.isEmpty else { throw AudioToolError.invalidSettings("Add at least one bleep range.") }
        let expr = enableExpression(ranges)
        let source = "[0:\(info.audioStreamIndex)]asetpts=PTS-STARTPTS,volume=0:enable='\(expr)'"
        guard settings.style == .beep, settings.volume > 0 else { return source + "[bleeped]" }

        // sine's amplitude is 1/8 of full scale.
        let gain = min(1, max(0, settings.volume)) * 8
        let duration = max(info.duration, ranges.last!.upperBound) + 0.1
        var tone = "sine=frequency=\(AudioFFmpeg.num(settings.frequency)):sample_rate=\(info.sampleRate)"
            + ":duration=\(AudioFFmpeg.num(duration))"
            + ",volume=\(AudioFFmpeg.num(gain)),volume=0:enable='not(\(expr))'"
        if info.channels > 1 {
            let layout = info.channelLayout ?? "\(info.channels)c"
            tone += ",pan=\(layout)|" + (0..<info.channels).map { "c\($0)=c0" }.joined(separator: "|")
        }
        return source + "[muted];" + tone + "[tone];"
            + "[muted][tone]amix=inputs=2:duration=first:dropout_transition=0:normalize=0[bleeped]"
    }

    public static func arguments(input: URL, output: URL, info: AudioInfo, settings: BleepSettings,
                                 encoding: AudioEncoding) throws -> [String] {
        var args = AudioFFmpeg.baseArguments + ["-i", input.path,
                                                "-filter_complex", try filterGraph(settings: settings, info: info)]
        if let art = info.coverArtStreamIndex, encoding.carriesCoverArt {
            args += ["-map", "0:\(art)", "-c:v", "copy", "-disposition:v:0", "attached_pic"]
        }
        args += ["-map", "[bleeped]"]
        args += encoding.codecArguments
        args += ["-ar", "\(encoding.outputSampleRate(for: info))"]
        args.append(output.path)
        return args
    }

    /// Writes "<name> bleeped.<ext>" (or `output`).
    @discardableResult
    public static func bleep(_ url: URL, settings: BleepSettings, info: AudioInfo? = nil,
                             output: URL? = nil, encoding: AudioEncoding? = nil) async throws -> URL {
        let info = try await AudioProbe.resolve(info, for: url)
        let encoding = encoding ?? AudioEncoding.matching(info, source: url)
        let output = output ?? OutputNaming.uniqueURL(for: url, ext: encoding.fileExtension, suffix: " bleeped")
        let args = try arguments(input: url, output: output, info: info, settings: settings, encoding: encoding)
        try await AudioFFmpeg.run(args, output: output)
        return output
    }
}
