import Foundation

/// How an audio tool writes its result: codec arguments chosen to match the source.
public struct AudioEncoding: Sendable, Equatable {
    /// Codec arguments, e.g. ["-c:a", "libmp3lame", "-b:a", "192k"].
    public var codecArguments: [String]
    /// Output extension, normally the source's.
    public var fileExtension: String
    /// The container can carry cover art as an attached picture.
    public var carriesCoverArt: Bool
    /// The encoder only accepts this sample rate (Opus).
    public var requiredSampleRate: Int?

    public init(codecArguments: [String], fileExtension: String, carriesCoverArt: Bool = false,
                requiredSampleRate: Int? = nil) {
        self.codecArguments = codecArguments
        self.fileExtension = fileExtension
        self.carriesCoverArt = carriesCoverArt
        self.requiredSampleRate = requiredSampleRate
    }

    /// 16-bit WAV: fast to write and AVAudioPlayer plays it. Used for short previews.
    public static let previewWAV = AudioEncoding(codecArguments: ["-c:a", "pcm_s16le"], fileExtension: "wav")
    /// AAC in M4A: used for previews of long files, where WAV would be huge.
    public static let previewAAC = AudioEncoding(codecArguments: ["-c:a", "aac", "-b:a", "160k"], fileExtension: "m4a")

    /// Preview format for a file of this length (WAV up to 20 minutes).
    public static func preview(forDuration duration: Double) -> AudioEncoding {
        duration <= 20 * 60 ? .previewWAV : .previewAAC
    }

    static let pcmCodecs: Set<String> = ["pcm_s16le", "pcm_s16be", "pcm_s24le", "pcm_s24be", "pcm_s32le", "pcm_s32be",
                                         "pcm_f32le", "pcm_f32be", "pcm_f64le", "pcm_f64be", "pcm_u8", "pcm_s8"]
    static let standardBitRates = [96, 128, 160, 192, 224, 256, 320]

    /// Smallest standard rate at or above the source's, so a re-encode doesn't lose much more.
    static func lossyBitRate(_ source: Int?, default fallback: Int, maximum: Int = 320) -> String {
        guard let source, source > 0 else { return "\(fallback)k" }
        let kbps = source / 1000
        let pick = standardBitRates.first { $0 >= kbps } ?? maximum
        return "\(min(pick, maximum))k"
    }

    /// Re-encodes in the source's codec where we have an encoder; otherwise the container's usual codec.
    /// `url` is the source (its extension is kept).
    public static func matching(_ info: AudioInfo, source url: URL) -> AudioEncoding {
        let ext = url.pathExtension.lowercased()
        let art = ["mp3", "m4a", "flac"].contains(ext) && !info.hasVideo
        func make(_ args: [String], sampleRate: Int? = nil) -> AudioEncoding {
            AudioEncoding(codecArguments: args, fileExtension: ext.isEmpty ? "m4a" : ext, carriesCoverArt: art,
                          requiredSampleRate: sampleRate)
        }
        let codec = info.codec
        if pcmCodecs.contains(codec) { return make(["-c:a", codec]) }
        switch codec {
        case "mp3": return make(["-c:a", "libmp3lame", "-b:a", lossyBitRate(info.bitRate, default: 192)])
        case "aac": return make(["-c:a", "aac", "-b:a", lossyBitRate(info.bitRate, default: 192, maximum: 320)])
        case "alac": return make(["-c:a", "alac"])
        case "flac": return make(["-c:a", "flac"])
        case "opus", "vorbis":
            return make(["-c:a", "libopus", "-b:a", lossyBitRate(info.bitRate, default: 128, maximum: 256)], sampleRate: 48000)
        case "ac3", "eac3":
            return make(["-c:a", codec, "-b:a", info.bitRate.map { "\(max(192, $0 / 1000))k" } ?? "384k"])
        default: break
        }
        switch ext {
        case "mp3": return make(["-c:a", "libmp3lame", "-b:a", "192k"])
        case "wav": return make(["-c:a", "pcm_s16le"])
        case "aif", "aiff", "aifc": return make(["-c:a", "pcm_s16be"])
        case "flac": return make(["-c:a", "flac"])
        case "ogg", "oga", "opus", "webm": return make(["-c:a", "libopus", "-b:a", "128k"], sampleRate: 48000)
        case "avi": return make(["-c:a", "libmp3lame", "-b:a", "192k"])
        default: return make(["-c:a", "aac", "-b:a", "192k"])
        }
    }

    /// Output sample rate for filters that change it (loudnorm upsamples to 192 kHz).
    public func outputSampleRate(for info: AudioInfo) -> Int {
        requiredSampleRate ?? info.sampleRate
    }
}

/// Shared ffmpeg plumbing for the audio tools.
public enum AudioFFmpeg {
    public static let baseArguments = ["-nostdin", "-hide_banner", "-loglevel", "error", "-y"]

    /// Maps the audio, plus video stream-copied (for movies) or cover art (for audio files that carry it).
    public static func streamMaps(_ info: AudioInfo, encoding: AudioEncoding, keepVideo: Bool) -> [String] {
        var args: [String] = []
        if info.hasVideo && keepVideo {
            args += ["-map", "0:v?", "-c:v", "copy"]
        } else if let art = info.coverArtStreamIndex, encoding.carriesCoverArt {
            args += ["-map", "0:\(art)", "-c:v", "copy", "-disposition:v:0", "attached_pic"]
        } else {
            args += ["-vn"]
        }
        args += ["-map", "0:\(info.audioStreamIndex)"]
        return args
    }

    /// Runs ffmpeg; on failure deletes the partial output and rethrows.
    public static func run(_ arguments: [String], output: URL) async throws {
        do {
            try await Tools.run("ffmpeg", arguments)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    /// "1.2345" with at most 4 decimals, never "-0", for filter expressions.
    public static func num(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        var text = String(format: "%.4f", value)
        while text.contains(".") && (text.hasSuffix("0") || text.hasSuffix(".")) { text.removeLast() }
        return text == "-0" ? "0" : text
    }
}
