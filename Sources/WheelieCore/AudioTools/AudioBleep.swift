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
    /// Times in seconds. An `end` of `.infinity` means "to the end of each file".
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
    /// An infinite end is clamped to `duration` (or stays infinite when the duration is unknown).
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

    /// Per-sample test for "t is inside a bleep range", as a balanced tree of `if`s so each sample costs
    /// O(log n) comparisons. `ranges` must be sorted and disjoint (see `merged`). A range that reaches
    /// `duration` stays on to the real end of the audio, which can run a little past the probed duration.
    /// Evaluates to 1 inside a range and 0 outside.
    public static func insideExpression(_ ranges: [ClosedRange<Double>], duration: Double) -> String {
        func node(_ lower: Int, _ upper: Int) -> String {
            guard lower < upper else { return "0" }
            let mid = (lower + upper) / 2
            let range = ranges[mid]
            let toEnd = !range.upperBound.isFinite || (duration > 0 && range.upperBound >= duration)
            let inside = toEnd ? "1" : "if(lte(t,\(AudioFFmpeg.num(range.upperBound))),1,\(node(mid + 1, upper)))"
            return "if(lt(t,\(AudioFFmpeg.num(range.lowerBound))),\(node(lower, mid)),\(inside))"
        }
        return node(0, ranges.count)
    }

    /// Filter graph from input 0's audio to [bleeped].
    /// Every sample inside a range is replaced: by silence, or by a sine tone at the chosen level. `aeval`
    /// works per sample, so a range starts and ends exactly where it was set, whatever the decoder's frame
    /// size (timeline `enable=` options are only checked once per frame, which let the start of a word
    /// through, or a short range be skipped entirely).
    public static func filterGraph(settings: BleepSettings, info: AudioInfo) throws -> String {
        let ranges = merged(settings.ranges, duration: info.duration)
        guard !ranges.isEmpty else { throw AudioToolError.invalidSettings("Add at least one bleep range.") }
        let inside = insideExpression(ranges, duration: info.duration)
        let replacement: String
        if settings.style == .beep, settings.volume > 0 {
            let amplitude = min(1, max(0, settings.volume))
            replacement = "\(AudioFFmpeg.num(amplitude))*sin(2*PI*\(AudioFFmpeg.num(settings.frequency))*t)"
        } else {
            replacement = "0"
        }
        return "[0:\(info.audioStreamIndex)]asetpts=PTS-STARTPTS,"
            + "aeval=exprs='if(\(inside),\(replacement),val(ch))':c=same[bleeped]"
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
