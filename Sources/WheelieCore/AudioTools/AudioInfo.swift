import Foundation

/// Errors from the audio tools. Messages are shown inline in the editors and in the hub.
public enum AudioToolError: LocalizedError, Equatable {
    case noAudio(String)
    case unreadable(String)
    case invalidSettings(String)
    case silent(String)

    public var errorDescription: String? {
        switch self {
        case .noAudio(let name): return name.isEmpty ? "This file has no audio track." : "\(name) has no audio track."
        case .unreadable(let message): return message
        case .invalidSettings(let message): return message
        case .silent(let message): return message
        }
    }
}

/// What the audio tools need to know about a file, from ffprobe.
public struct AudioInfo: Sendable, Equatable {
    public var duration: Double
    public var channels: Int
    /// ffmpeg layout name ("stereo", "5.1(side)"); nil when the file doesn't say.
    public var channelLayout: String?
    public var sampleRate: Int
    /// ffmpeg codec name of the first audio stream ("mp3", "aac", "pcm_s16le", ...).
    public var codec: String
    /// Audio bit rate in bits per second, when known.
    public var bitRate: Int?
    /// Absolute stream index of the first audio stream.
    public var audioStreamIndex: Int
    /// True when the file has a real video stream (not just cover art).
    public var hasVideo: Bool
    /// Absolute stream index of embedded cover art (an attached picture), if any.
    public var coverArtStreamIndex: Int?
    public var videoWidth: Int?
    public var videoHeight: Int?
    public var formatName: String

    public init(duration: Double, channels: Int, channelLayout: String? = nil, sampleRate: Int, codec: String,
                bitRate: Int? = nil, audioStreamIndex: Int = 0, hasVideo: Bool = false,
                coverArtStreamIndex: Int? = nil, videoWidth: Int? = nil, videoHeight: Int? = nil,
                formatName: String = "") {
        self.duration = duration
        self.channels = channels
        self.channelLayout = channelLayout
        self.sampleRate = sampleRate
        self.codec = codec
        self.bitRate = bitRate
        self.audioStreamIndex = audioStreamIndex
        self.hasVideo = hasVideo
        self.coverArtStreamIndex = coverArtStreamIndex
        self.videoWidth = videoWidth
        self.videoHeight = videoHeight
        self.formatName = formatName
    }

    public var channelDescription: String {
        switch channels {
        case 1: return "Mono"
        case 2: return "Stereo"
        default: return channelLayout.map { "\($0) (\(channels) ch)" } ?? "\(channels) channels"
        }
    }

    public var codecDescription: String {
        if codec.hasPrefix("pcm_") { return "PCM" }
        switch codec {
        case "mp3": return "MP3"
        case "aac": return "AAC"
        case "alac": return "Apple Lossless"
        case "flac": return "FLAC"
        case "opus": return "Opus"
        case "vorbis": return "Vorbis"
        case "ac3": return "AC-3"
        case "eac3": return "E-AC-3"
        default: return codec.uppercased()
        }
    }

    /// "3:12 · 44.1 kHz · Stereo · MP3 192 kbps"
    public var summary: String {
        var parts = [Timecode.string(duration, decimals: duration < 600 ? 1 : 0)]
        let khz = Double(sampleRate) / 1000
        parts.append(khz == khz.rounded() ? "\(Int(khz)) kHz" : String(format: "%.1f kHz", khz))
        parts.append(channelDescription)
        if let bitRate, !codec.hasPrefix("pcm_"), !["flac", "alac"].contains(codec) {
            parts.append("\(codecDescription) \(bitRate / 1000) kbps")
        } else {
            parts.append(codecDescription)
        }
        if hasVideo, let w = videoWidth, let h = videoHeight { parts.append("Video \(w)×\(h)") }
        return parts.joined(separator: " · ")
    }
}

public enum AudioProbe {
    /// `given` when the caller already probed, otherwise a fresh probe.
    public static func resolve(_ given: AudioInfo?, for url: URL) async throws -> AudioInfo {
        if let given { return given }
        return try await probe(url)
    }

    /// Probes the first audio stream. Throws `AudioToolError.noAudio` when there is none.
    public static func probe(_ url: URL) async throws -> AudioInfo {
        let output: (stdout: String, stderr: String)
        do {
            output = try await Tools.capture("ffprobe", ["-v", "error", "-print_format", "json",
                                                         "-show_format", "-show_streams", url.path])
        } catch let error as ToolError {
            if case .missing = error { throw error }
            throw AudioToolError.unreadable("Couldn't read \(url.lastPathComponent).")
        }
        return try parse(json: Data(output.stdout.utf8), name: url.lastPathComponent)
    }

    /// Parses `ffprobe -print_format json -show_format -show_streams` output.
    public static func parse(json: Data, name: String = "") throws -> AudioInfo {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            throw AudioToolError.unreadable(name.isEmpty ? "Couldn't read this file." : "Couldn't read \(name).")
        }
        let streams = root["streams"] as? [[String: Any]] ?? []
        let format = root["format"] as? [String: Any] ?? [:]

        func number(_ value: Any?) -> Double? {
            if let d = value as? Double { return d }
            if let i = value as? Int { return Double(i) }
            if let s = value as? String { return Double(s) }
            return nil
        }
        func isAttachedPic(_ stream: [String: Any]) -> Bool {
            ((stream["disposition"] as? [String: Any])?["attached_pic"] as? Int) == 1
        }

        guard let audio = streams.first(where: { $0["codec_type"] as? String == "audio" }) else {
            throw AudioToolError.noAudio(name)
        }
        let videos = streams.filter { $0["codec_type"] as? String == "video" }
        let realVideo = videos.first { !isAttachedPic($0) }
        let art = videos.first { isAttachedPic($0) }

        var duration = number(format["duration"]) ?? number(audio["duration"]) ?? 0
        if duration <= 0, let d = number(audio["duration"]) { duration = d }
        let audioOnly = realVideo == nil && streams.filter({ $0["codec_type"] as? String == "audio" }).count == 1
        var bitRate = number(audio["bit_rate"]).map { Int($0) }
        if bitRate == nil, audioOnly, let formatRate = number(format["bit_rate"]) { bitRate = Int(formatRate) }
        let layout = (audio["channel_layout"] as? String).flatMap { $0.isEmpty || $0 == "unknown" ? nil : $0 }

        return AudioInfo(
            duration: max(0, duration),
            channels: max(1, (audio["channels"] as? Int) ?? 1),
            channelLayout: layout,
            sampleRate: Int(number(audio["sample_rate"]) ?? 44100),
            codec: audio["codec_name"] as? String ?? "unknown",
            bitRate: bitRate,
            audioStreamIndex: audio["index"] as? Int ?? 0,
            hasVideo: realVideo != nil,
            coverArtStreamIndex: art?["index"] as? Int,
            videoWidth: realVideo?["width"] as? Int,
            videoHeight: realVideo?["height"] as? Int,
            formatName: format["format_name"] as? String ?? "")
    }
}

/// Time formatting and parsing for timeline labels and numeric fields.
public enum Timecode {
    /// 75.5 -> "1:15.50"; 3725 -> "1:02:05.00". `decimals` 0...3.
    public static func string(_ seconds: Double, decimals: Int = 2) -> String {
        let value = seconds.isFinite ? max(0, seconds) : 0
        let scale = pow(10, Double(decimals))
        let total = (value * scale).rounded() / scale
        let hours = Int(total) / 3600
        let minutes = (Int(total) % 3600) / 60
        let secs = total - Double(hours * 3600 + minutes * 60)
        let width = decimals > 0 ? 3 + decimals : 2
        let secString = String(format: "%0\(width).\(decimals)f", secs)
        return hours > 0 ? String(format: "%d:%02d:", hours, minutes) + secString
                         : "\(minutes):" + secString
    }

    /// Accepts "75.5", "1:15.5", "1:02:05", "1:15,5" (comma decimal). Nil when unparseable.
    public static func parse(_ text: String) -> Double? {
        let cleaned = text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: "s", with: "")
        guard !cleaned.isEmpty else { return nil }
        let parts = cleaned.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count <= 3 else { return nil }
        var total = 0.0
        for (index, part) in parts.enumerated() {
            guard let value = Double(part.trimmingCharacters(in: .whitespaces)), value >= 0 else { return nil }
            if index < parts.count - 1, value != value.rounded() { return nil }
            total = total * 60 + value
        }
        return total
    }
}
