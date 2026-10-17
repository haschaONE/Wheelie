import Foundation

/// The parts of `ffprobe -show_format -show_streams -show_chapters` the compress and metadata tools need.
public struct MediaProbe: Sendable {
    public struct Stream: Sendable {
        public var index: Int
        public var type: String            // video, audio, subtitle, data, attachment
        public var codec: String
        public var width: Int
        public var height: Int
        public var bitRate: Int?
        public var channels: Int
        public var rotation: Int
        public var isAttachedPicture: Bool
        public var tags: [String: String]

        /// Size as displayed (rotation applied).
        public var displaySize: (width: Int, height: Int) {
            abs(rotation) % 180 == 90 ? (height, width) : (width, height)
        }
    }

    public var duration: Double
    public var size: Int64
    public var bitRate: Int?
    public var formatName: String
    public var streams: [Stream]
    public var formatTags: [String: String]
    public var chapterCount: Int

    /// Real video streams (cover art excluded).
    public var videoStreams: [Stream] { streams.filter { $0.type == "video" && !$0.isAttachedPicture } }
    public var audioStreams: [Stream] { streams.filter { $0.type == "audio" } }
    public var subtitleStreams: [Stream] { streams.filter { $0.type == "subtitle" } }
    public var hasArtwork: Bool { streams.contains { $0.isAttachedPicture } }

    /// Audio bitrate of the first audio stream, in kbit/s, estimated from the container when missing.
    public var audioKbps: Int? {
        if let rate = audioStreams.first?.bitRate { return rate / 1000 }
        guard videoStreams.isEmpty else { return nil }
        if let rate = bitRate { return rate / 1000 }
        return duration > 0 ? Int(Double(size) * 8 / duration / 1000) : nil
    }

    public static func probe(_ url: URL) async throws -> MediaProbe {
        let (out, _) = try await Tools.capture("ffprobe", ["-v", "error", "-print_format", "json", "-show_format",
                                                          "-show_streams", "-show_chapters", url.path])
        guard let probe = parse(Data(out.utf8)) else { throw CompressionError.unreadable(url.lastPathComponent) }
        return probe
    }

    static func parse(_ json: Data) -> MediaProbe? {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return nil }
        let format = root["format"] as? [String: Any] ?? [:]
        let streams = (root["streams"] as? [[String: Any]] ?? []).map { s -> Stream in
            let disposition = s["disposition"] as? [String: Any] ?? [:]
            let sideData = s["side_data_list"] as? [[String: Any]] ?? []
            let tags = stringTags(s["tags"])
            var rotation = sideData.compactMap { int($0["rotation"]) }.first ?? 0
            if rotation == 0, let rotate = tags["rotate"].flatMap(Int.init) { rotation = rotate }
            return Stream(index: int(s["index"]) ?? 0,
                          type: s["codec_type"] as? String ?? "",
                          codec: s["codec_name"] as? String ?? "",
                          width: int(s["width"]) ?? 0,
                          height: int(s["height"]) ?? 0,
                          bitRate: int(s["bit_rate"]),
                          channels: int(s["channels"]) ?? 0,
                          rotation: rotation,
                          isAttachedPicture: int(disposition["attached_pic"]) == 1,
                          tags: tags)
        }
        return MediaProbe(duration: double(format["duration"]) ?? 0,
                          size: Int64(int(format["size"]) ?? 0),
                          bitRate: int(format["bit_rate"]),
                          formatName: format["format_name"] as? String ?? "",
                          streams: streams,
                          formatTags: stringTags(format["tags"]),
                          chapterCount: (root["chapters"] as? [Any])?.count ?? 0)
    }

    private static func stringTags(_ value: Any?) -> [String: String] {
        guard let dict = value as? [String: Any] else { return [:] }
        return dict.reduce(into: [:]) { result, pair in
            if let s = pair.value as? String { result[pair.key] = s } else { result[pair.key] = "\(pair.value)" }
        }
    }

    private static func int(_ value: Any?) -> Int? {
        if let n = value as? Int { return n }
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) ?? Double(s).map { Int($0) } }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }
}
