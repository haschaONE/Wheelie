import Foundation

/// What the video tools need to know about a file, read with ffprobe.
public struct VideoToolInfo: Sendable, Equatable {
    /// Seconds.
    public var duration: Double
    /// Stored (coded) frame size, before rotation metadata is applied.
    public var width: Int
    public var height: Int
    /// Clockwise display rotation: 0, 90, 180 or 270.
    public var rotation: Int
    /// Frames per second of the first video stream (0 when unknown).
    public var fps: Double
    public var hasVideo: Bool
    public var hasAudio: Bool
    public var videoCodec: String?
    public var audioCodec: String?
    public var audioSampleRate: Int?
    /// Pixel aspect ratio of the stored frame (1 for square pixels).
    public var sampleAspectRatio: Double

    public init(duration: Double, width: Int, height: Int, rotation: Int = 0, fps: Double,
                hasVideo: Bool = true, hasAudio: Bool, videoCodec: String? = nil, audioCodec: String? = nil,
                audioSampleRate: Int? = nil, sampleAspectRatio: Double = 1) {
        self.duration = duration
        self.width = width
        self.height = height
        self.rotation = rotation
        self.fps = fps
        self.hasVideo = hasVideo
        self.hasAudio = hasAudio
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.audioSampleRate = audioSampleRate
        self.sampleAspectRatio = sampleAspectRatio
    }

    var isQuarterTurn: Bool { rotation == 90 || rotation == 270 }

    /// Frame size as shown (and as ffmpeg filters see it, since ffmpeg auto-rotates).
    public var displayWidth: Int { isQuarterTurn ? height : width }
    public var displayHeight: Int { isQuarterTurn ? width : height }

    /// Shape of the displayed picture, including non-square pixels.
    public var displayAspect: Double {
        guard displayWidth > 0, displayHeight > 0 else { return 16.0 / 9.0 }
        let sar = sampleAspectRatio > 0 ? sampleAspectRatio : 1
        return isQuarterTurn ? Double(displayWidth) / (Double(displayHeight) * sar)
                             : Double(displayWidth) * sar / Double(displayHeight)
    }

    /// Length of one frame in seconds (1/30 when the rate is unknown).
    public var frameDuration: Double { fps > 0 ? 1 / fps : 1.0 / 30 }
}

public enum VideoToolProbe {
    /// Runs `ffprobe -show_streams -show_format -of json`.
    public static func probe(_ url: URL) async throws -> VideoToolInfo {
        let (stdout, _) = try await Tools.capture("ffprobe", ["-v", "error", "-show_streams", "-show_format",
                                                              "-of", "json", url.path])
        do {
            return try parse(Data(stdout.utf8))
        } catch {
            throw VideoToolError("Couldn't read \(url.lastPathComponent).")
        }
    }

    /// Parses ffprobe's JSON. Attached cover art does not count as video.
    public static func parse(_ data: Data) throws -> VideoToolInfo {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw VideoToolError("Unexpected ffprobe output.")
        }
        let streams = root["streams"] as? [[String: Any]] ?? []
        let format = root["format"] as? [String: Any] ?? [:]

        let video = streams.first { stream in
            guard stream["codec_type"] as? String == "video" else { return false }
            let disposition = stream["disposition"] as? [String: Any]
            return (disposition?["attached_pic"] as? Int ?? 0) == 0
        }
        let audio = streams.first { $0["codec_type"] as? String == "audio" }

        var duration = double(format["duration"]) ?? 0
        if duration <= 0 {
            duration = streams.compactMap { double($0["duration"]) ?? tagDuration($0) }.max() ?? 0
        }

        var info = VideoToolInfo(duration: max(0, duration), width: 0, height: 0, fps: 0,
                                  hasVideo: video != nil, hasAudio: audio != nil)
        if let video {
            info.width = video["width"] as? Int ?? 0
            info.height = video["height"] as? Int ?? 0
            info.videoCodec = video["codec_name"] as? String
            let avg = rate(video["avg_frame_rate"])
            info.fps = avg > 0 && avg < 1000 ? avg : rate(video["r_frame_rate"])
            if info.fps >= 1000 { info.fps = 0 }
            info.rotation = rotation(of: video)
            if let sar = video["sample_aspect_ratio"] as? String {
                let r = rate(sar.replacingOccurrences(of: ":", with: "/"))
                if r > 0 { info.sampleAspectRatio = r }
            }
        }
        if let audio {
            info.audioCodec = audio["codec_name"] as? String
            info.audioSampleRate = (audio["sample_rate"] as? String).flatMap { Int($0) } ?? audio["sample_rate"] as? Int
        }
        return info
    }

    /// ffprobe reports the display matrix angle counter-clockwise; older files use a `rotate` tag (clockwise).
    static func rotation(of stream: [String: Any]) -> Int {
        var degrees: Double?
        for side in stream["side_data_list"] as? [[String: Any]] ?? [] {
            if let r = double(side["rotation"]) { degrees = -r; break }
        }
        if degrees == nil, let tags = stream["tags"] as? [String: Any], let r = double(tags["rotate"]) {
            degrees = r
        }
        guard let degrees else { return 0 }
        let quarter = Int((degrees / 90).rounded()) * 90
        return ((quarter % 360) + 360) % 360
    }

    static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String, let d = Double(text), d.isFinite { return d }
        return nil
    }

    /// "30000/1001" -> 29.97; "0/0" -> 0.
    static func rate(_ value: Any?) -> Double {
        guard let text = value as? String else { return 0 }
        let parts = text.split(separator: "/")
        if parts.count == 2, let n = Double(parts[0]), let d = Double(parts[1]), d != 0 { return n / d }
        return Double(text) ?? 0
    }

    /// Matroska keeps stream durations in a "DURATION" tag ("00:00:05.000000000").
    static func tagDuration(_ stream: [String: Any]) -> Double? {
        guard let tags = stream["tags"] as? [String: Any] else { return nil }
        let text = (tags["DURATION"] ?? tags["duration"]) as? String
        return text.flatMap(VideoToolTimecode.parse)
    }

    // MARK: Keyframes

    /// Presentation times of video keyframes, read from packet flags (no decoding).
    /// With `near`, only a few seconds around that time are read, which is quick on long files.
    public static func keyframeTimes(_ url: URL, near time: Double? = nil) async throws -> [Double] {
        var args = ["-v", "error", "-select_streams", "v:0", "-show_entries", "packet=pts_time,flags", "-of", "csv=p=0"]
        if let time {
            args += ["-read_intervals", "\(VideoToolArgs.number(max(0, time - 3)))%+6"]
        }
        let (stdout, _) = try await Tools.capture("ffprobe", args + [url.path])
        return parseKeyframes(stdout)
    }

    /// Lines look like `1.000000,K__`; returns the sorted keyframe times.
    public static func parseKeyframes(_ csv: String) -> [Double] {
        csv.split(whereSeparator: \.isNewline).compactMap { line -> Double? in
            let fields = line.split(separator: ",")
            guard fields.count >= 2, fields[1].hasPrefix("K"), let t = Double(fields[0]) else { return nil }
            return t
        }.sorted()
    }
}

/// An error whose message is shown to the user as-is.
public struct VideoToolError: LocalizedError, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }

    public static let noVideoTrack = VideoToolError("This file has no playable video track.")
    public static let noAudioTrack = VideoToolError("This file has no audio track.")
    public static let invalidRange = VideoToolError("Set a start and end within the file.")
    public static let noFrame = VideoToolError("No frame is available at this time. Choose an earlier frame.")
}
