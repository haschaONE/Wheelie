import Foundation

/// Peak overview of an audio file: per channel, `bucketCount` peaks in 0...1 (absolute, 1 = full scale).
public struct Waveform: Sendable, Equatable {
    public var channels: [[Float]]
    public var duration: Double

    public init(channels: [[Float]], duration: Double) {
        self.channels = channels
        self.duration = duration
    }

    public var bucketCount: Int { channels.first?.count ?? 0 }

    /// Loudest channel per bucket, for a single overview lane.
    public var combined: [Float] {
        guard var result = channels.first else { return [] }
        for channel in channels.dropFirst() {
            for i in 0..<min(result.count, channel.count) where channel[i] > result[i] { result[i] = channel[i] }
        }
        return result
    }

    public var maximum: Float { channels.map { $0.max() ?? 0 }.max() ?? 0 }
}

public enum WaveformExtractor {
    /// Sensible bucket count: ~100 per second (zoomable), between 1,000 and 30,000.
    public static func bucketCount(forDuration duration: Double) -> Int {
        min(30_000, max(1_000, Int(duration * 100)))
    }

    /// Decode rate: high enough to keep transients, low enough that hours of audio stay small on disk.
    static func decodeRate(forDuration duration: Double) -> Int {
        duration <= 20 * 60 ? 8000 : (duration <= 2 * 3600 ? 4000 : 2000)
    }

    /// Decodes the first audio stream with ffmpeg to raw 16-bit PCM (mono mixdown, or up to two
    /// channels when `channels` is 2) and reduces it to peaks.
    public static func extract(_ url: URL, channels: Int = 1, buckets: Int? = nil,
                               info: AudioInfo? = nil) async throws -> Waveform {
        let info = try await AudioProbe.resolve(info, for: url)
        let outChannels = max(1, min(channels, info.channels, 2))
        let rate = decodeRate(forDuration: info.duration)
        let count = buckets ?? bucketCount(forDuration: info.duration)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wheelie-wave-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let raw = dir.appendingPathComponent("samples.raw")
        var args = AudioFFmpeg.baseArguments + ["-i", url.path, "-map", "0:\(info.audioStreamIndex)", "-vn"]
        if info.channels > 2, outChannels == 2, info.channelLayout != nil {
            args += ["-af", "aformat=channel_layouts=stereo"]
        } else if info.channels > 2, outChannels == 2 {
            args += ["-af", "pan=stereo|c0=c0|c1=c1"]
        }
        args += ["-ac", "\(outChannels)", "-ar", "\(rate)", "-f", "s16le", "-c:a", "pcm_s16le", raw.path]
        do {
            try await Tools.run("ffmpeg", args)
        } catch let error as ToolError {
            if case .missing = error { throw error }
            throw AudioToolError.unreadable("Could not read the audio waveform.")
        }
        let duration = info.duration
        return try await Task.detached(priority: .userInitiated) {
            let data = try Data(contentsOf: raw, options: .alwaysMapped)
            let peaks = data.withUnsafeBytes { bytes -> [[Float]] in
                let samples = bytes.bindMemory(to: Int16.self)
                return Self.peaks(int16: samples, channels: outChannels, buckets: count)
            }
            return Waveform(channels: peaks, duration: duration)
        }.value
    }

    /// Interleaved 16-bit samples -> `buckets` absolute peaks per channel.
    public static func peaks(int16 samples: UnsafeBufferPointer<Int16>, channels: Int, buckets: Int) -> [[Float]] {
        let frames = samples.count / max(channels, 1)
        guard frames > 0, buckets > 0 else { return Array(repeating: Array(repeating: 0, count: max(buckets, 0)), count: max(channels, 1)) }
        var result = Array(repeating: [Float](repeating: 0, count: buckets), count: channels)
        for bucket in 0..<buckets {
            let lower = frames * bucket / buckets
            var upper = frames * (bucket + 1) / buckets
            if upper <= lower { upper = min(lower + 1, frames) }
            for channel in 0..<channels {
                var peak: Int32 = 0
                var i = lower * channels + channel
                let end = upper * channels
                while i < end {
                    let v = abs(Int32(samples[i]))
                    if v > peak { peak = v }
                    i += channels
                }
                result[channel][bucket] = min(1, Float(peak) / 32767)
            }
        }
        return result
    }

    /// Interleaved float samples (-1...1) -> peaks; same bucketing as the 16-bit path.
    public static func peaks(interleaved samples: [Float], channels: Int, buckets: Int) -> [[Float]] {
        let ints = samples.map { Int16(max(-1, min(1, $0)) * 32767) }
        return ints.withUnsafeBufferPointer { peaks(int16: $0, channels: channels, buckets: buckets) }
    }
}
