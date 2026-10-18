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
    /// The container's first timestamp; ffmpeg and AVPlayer count time from here.
    public var startTime: Double

    public init(duration: Double, width: Int, height: Int, rotation: Int = 0, fps: Double,
                hasVideo: Bool = true, hasAudio: Bool, videoCodec: String? = nil, audioCodec: String? = nil,
                audioSampleRate: Int? = nil, sampleAspectRatio: Double = 1, startTime: Double = 0) {
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
        self.startTime = startTime
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

    /// Horizontal stretch of one displayed pixel: the sample aspect ratio, inverted for a quarter
    /// turn (the rotation moves the stored horizontal axis to the vertical one).
    public var displayPixelAspect: Double {
        let sar = sampleAspectRatio > 0 && sampleAspectRatio.isFinite ? sampleAspectRatio : 1
        return isQuarterTurn ? 1 / sar : sar
    }

    /// Length of one frame in seconds (1/30 when the rate is unknown).
    public var frameDuration: Double { fps > 0 ? 1 / fps : 1.0 / 30 }
}

public enum VideoToolProbe {
    /// Runs `ffprobe -show_streams -show_format -of json`. When the container records no duration
    /// (browser MediaRecorder WebM, an unfinished recording), it is measured from the packets.
    public static func probe(_ url: URL) async throws -> VideoToolInfo {
        let (stdout, _) = try await Tools.capture("ffprobe", ["-v", "error", "-show_streams", "-show_format",
                                                              "-of", "json", url.path])
        var info: VideoToolInfo
        do {
            info = try parse(Data(stdout.utf8))
        } catch {
            throw VideoToolError("Couldn't read \(url.lastPathComponent).")
        }
        if info.hasVideo, info.duration <= 0,
           let (packets, _) = try? await Tools.capture("ffprobe", ["-v", "error", "-show_entries",
                                                                    "packet=pts_time,duration_time",
                                                                    "-of", "csv=p=0", url.path]) {
            info.duration = measuredDuration(packets, startTime: info.startTime) ?? 0
        }
        return info
    }

    /// End of the last packet in `pts_time,duration_time` lines, counted from `startTime`.
    public static func measuredDuration(_ csv: String, startTime: Double) -> Double? {
        var end: Double?
        for line in csv.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard let pts = fields.first.flatMap({ Double($0) }), pts.isFinite else { continue }
            var length = fields.count > 1 ? Double(fields[1]) ?? 0 : 0
            if !(length.isFinite && length > 0) { length = 0 }
            end = max(end ?? -.infinity, pts + length)
        }
        guard let end else { return nil }
        let duration = end - startTime
        return duration > 0 && duration <= VideoToolTimecode.maximumSeconds ? duration : nil
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

        var duration = seconds(format["duration"]) ?? 0
        if duration <= 0 {
            duration = streams.compactMap { seconds($0["duration"]) ?? tagDuration($0) }.max() ?? 0
        }

        var info = VideoToolInfo(duration: max(0, duration), width: 0, height: 0, fps: 0,
                                  hasVideo: video != nil, hasAudio: audio != nil)
        if let start = double(format["start_time"]), abs(start) <= VideoToolTimecode.maximumSeconds {
            info.startTime = start
        }
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
        // A crafted angle like 1e300 would trap converting to Int.
        guard let degrees, abs(degrees) <= 3600 else { return 0 }
        let quarter = Int((degrees / 90).rounded()) * 90
        return ((quarter % 360) + 360) % 360
    }

    /// A duration in seconds; absurd values (corrupt or crafted files) count as missing.
    static func seconds(_ value: Any?) -> Double? {
        double(value).flatMap { $0 > 0 && $0 <= VideoToolTimecode.maximumSeconds ? $0 : nil }
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
        return seconds(text.flatMap(VideoToolTimecode.parse))
    }

    // MARK: Frame times

    /// Start times of the video frames and keyframes around `time` (or in the whole file), read
    /// from packets without decoding and counted from the container's start time, as `-ss` counts.
    /// `startTime` is the file's `VideoToolInfo.startTime` (read_intervals take absolute timestamps).
    /// `frameDuration` nil = estimated from the frames.
    public static func frameTimes(_ url: URL, near time: Double? = nil, startTime: Double = 0,
                                  frameDuration: Double? = nil) async throws -> VideoFrameTimes {
        var args = ["-v", "error", "-select_streams", "v:0",
                    "-show_entries", "packet=pts_time,flags:format=start_time", "-of", "json"]
        if let time {
            // Reading starts at the keyframe before the window, so every frame up to `time` is
            // listed. The end is absolute: "+6" would count from that keyframe, which can be far
            // earlier on long GOPs (or at 0 in files without an index).
            let from = startTime + max(0, time - 3), to = startTime + time + 3
            args += ["-read_intervals", "\(VideoToolArgs.number(from))%\(VideoToolArgs.number(to))"]
        }
        let (stdout, _) = try await Tools.capture("ffprobe", args + [url.path])
        return try parseFrameTimes(Data(stdout.utf8), frameDuration: frameDuration)
    }

    /// Parses `-show_entries packet=pts_time,flags:format=start_time -of json`.
    public static func parseFrameTimes(_ data: Data, frameDuration: Double? = nil) throws -> VideoFrameTimes {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw VideoToolError("Unexpected ffprobe output.")
        }
        let format = root["format"] as? [String: Any] ?? [:]
        var origin = double(format["start_time"]) ?? 0
        if abs(origin) > VideoToolTimecode.maximumSeconds { origin = 0 }
        var starts = Set<Double>(), keys = Set<Double>()
        for packet in root["packets"] as? [[String: Any]] ?? [] {
            guard let pts = double(packet["pts_time"]) else { continue }
            let t = pts - origin
            starts.insert(t)
            if (packet["flags"] as? String)?.hasPrefix("K") == true { keys.insert(t) }
        }
        let sorted = starts.sorted()
        var fd = frameDuration ?? 0
        if !(fd > 0) {
            let gaps = zip(sorted, sorted.dropFirst()).map { $1 - $0 }.filter { $0 > 1e-6 }.sorted()
            fd = gaps.isEmpty ? 1.0 / 30 : gaps[gaps.count / 2]
        }
        return VideoFrameTimes(starts: sorted, keyframes: keys.sorted(), frameDuration: fd)
    }

    /// Keyframe start times, counted from the container's start time.
    /// With `near`, only a few seconds around that time are read, which is quick on long files.
    public static func keyframeTimes(_ url: URL, near time: Double? = nil, startTime: Double = 0) async throws -> [Double] {
        try await frameTimes(url, near: time, startTime: startTime).keyframes
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
    public static let unknownDuration = VideoToolError("Couldn't tell how long this video is. The file may be damaged or incomplete.")
}
