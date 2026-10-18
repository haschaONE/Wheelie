import Foundation

/// Encoder settings for re-encoded video tool output, picked by container.
public struct VideoToolEncoding: Equatable, Sendable {
    public let fileExtension: String
    public let videoArgs: [String]
    public let audioArgs: [String]
    public let muxArgs: [String]

    static let x264 = ["-c:v", "libx264", "-preset", "fast", "-crf", "18", "-pix_fmt", "yuv420p"]
    static let aac = ["-c:a", "aac", "-b:a", "192k"]
    static let faststart = ["-movflags", "+faststart"]

    /// H.264 + AAC in MP4: the Join tool's output.
    public static let mp4 = VideoToolEncoding(fileExtension: "mp4", videoArgs: x264, audioArgs: aac, muxArgs: faststart)

    /// Keeps the source's container when ffmpeg can write it, else MP4.
    public static func matching(_ source: URL) -> VideoToolEncoding {
        let ext = source.pathExtension.lowercased()
        switch ext {
        case "mp4", "m4v", "mov":
            return VideoToolEncoding(fileExtension: ext, videoArgs: x264, audioArgs: aac, muxArgs: faststart)
        case "mkv", "ts", "m2ts", "mts":
            return VideoToolEncoding(fileExtension: ext, videoArgs: x264, audioArgs: aac, muxArgs: [])
        case "webm":
            return VideoToolEncoding(fileExtension: ext,
                                 videoArgs: ["-c:v", "libvpx-vp9", "-crf", "30", "-b:v", "0", "-row-mt", "1",
                                             "-deadline", "good", "-cpu-used", "4", "-pix_fmt", "yuv420p"],
                                 audioArgs: ["-c:a", "libopus", "-b:a", "128k"], muxArgs: [])
        case "avi":
            return VideoToolEncoding(fileExtension: ext, videoArgs: x264,
                                 audioArgs: ["-c:a", "libmp3lame", "-b:a", "192k"], muxArgs: [])
        default:
            return mp4
        }
    }

    /// Audio codecs the MP4/QuickTime muxer accepts, so copying them can't fail.
    static let mp4AudioCodecs: Set<String> = ["aac", "mp3", "mp2", "ac3", "eac3", "alac", "opus", "flac"]

    /// Audio settings when only the picture changes: copy the source's audio when this output keeps
    /// its container or can hold its codec (`codec` nil = unknown), else re-encode with `audioArgs`.
    /// WMV's WMA, 3GP's AMR and FLV's Nellymoser can't go into the MP4 they are written as.
    public func audioArgs(keeping source: URL, codec: String?) -> [String] {
        let copy = ["-c:a", "copy"]
        if source.pathExtension.lowercased() == fileExtension { return copy }
        if ["mp4", "m4v", "mov"].contains(fileExtension), let codec, Self.mp4AudioCodecs.contains(codec.lowercased()) {
            return copy
        }
        return audioArgs
    }
}

public enum VideoSnapshotFormat: String, CaseIterable, Sendable, Identifiable {
    case png, jpg
    public var id: String { rawValue }
    public var label: String { rawValue.uppercased() }
}

/// Pure ffmpeg argument builders for every video tool. They return everything after
/// the global options (`VideoToolArgs.global`), which `VideoToolRunner` adds.
public enum VideoToolArgs {
    public static let global = ["-nostdin", "-hide_banner", "-nostats", "-loglevel", "error", "-y"]

    /// Locale-independent number for ffmpeg: 2 -> "2", 1.5 -> "1.5", 1/3 -> "0.333333".
    public static func number(_ value: Double) -> String { VideoToolTimecode.compact(value, maxFractionDigits: 6) }

    // MARK: Trim / split

    /// One range of `input`. `encoding` nil = stream copy (fast, cuts on keyframes).
    public static func trim(input: URL, output: URL, start: Double, duration: Double,
                            encoding: VideoToolEncoding?) -> [String] {
        var args: [String] = []
        if start > 0 { args += ["-ss", number(start)] }
        args += ["-i", input.path, "-t", number(duration), "-map", "0:v:0", "-map", "0:a?"]
        if let encoding {
            args += encoding.videoArgs + encoding.audioArgs + encoding.muxArgs
        } else {
            args += ["-c", "copy", "-avoid_negative_ts", "make_zero"]
            if ["mp4", "m4v", "mov"].contains(output.pathExtension.lowercased()) { args += VideoToolEncoding.faststart }
        }
        return args + [output.path]
    }

    /// Keeps `ranges` of one file and joins them (the Split tool's "join the rest").
    public static func keepRanges(input: URL, output: URL, ranges: [VideoClipRange], hasAudio: Bool,
                                  encoding: VideoToolEncoding) -> [String] {
        let n = ranges.count
        var graph: [String] = []
        graph.append("[0:v:0]split=\(n)" + (0..<n).map { "[sv\($0)]" }.joined())
        if hasAudio { graph.append("[0:a:0]asplit=\(n)" + (0..<n).map { "[sa\($0)]" }.joined()) }
        var concatInputs = ""
        for (i, r) in ranges.enumerated() {
            let span = "start=\(number(r.start)):end=\(number(r.end))"
            graph.append("[sv\(i)]trim=\(span),setpts=PTS-STARTPTS[v\(i)]")
            concatInputs += "[v\(i)]"
            if hasAudio {
                graph.append("[sa\(i)]atrim=\(span),asetpts=PTS-STARTPTS[a\(i)]")
                concatInputs += "[a\(i)]"
            }
        }
        graph.append(concatInputs + "concat=n=\(n):v=1:a=\(hasAudio ? 1 : 0)[vout]" + (hasAudio ? "[aout]" : ""))
        var args = ["-i", input.path, "-filter_complex", graph.joined(separator: ";"), "-map", "[vout]"]
        if hasAudio { args += ["-map", "[aout]"] }
        args += encoding.videoArgs + (hasAudio ? encoding.audioArgs : []) + encoding.muxArgs
        return args + [output.path]
    }

    // MARK: Join

    public struct JoinInput: Sendable, Equatable {
        public var url: URL
        public var duration: Double
        public var hasAudio: Bool
        public init(url: URL, duration: Double, hasAudio: Bool) {
            self.url = url; self.duration = duration; self.hasAudio = hasAudio
        }
    }

    /// Letterboxes every clip into width×height at one frame rate and concatenates them.
    /// Non-square pixels are first resampled to square ones at their displayed shape, so anamorphic
    /// clips (HDV, DV, DVD) aren't squeezed by the final `setsar=1`.
    /// When any clip has audio, clips without it get silence so the streams line up.
    public static func join(inputs: [JoinInput], output: URL, width: Int, height: Int, fps: Double,
                            encoding: VideoToolEncoding = .mp4) -> [String] {
        let withAudio = inputs.contains { $0.hasAudio }
        var args: [String] = []
        for input in inputs { args += ["-i", input.url.path] }
        var graph: [String] = []
        var concatInputs = ""
        for (i, input) in inputs.enumerated() {
            graph.append("[\(i):v:0]scale='trunc(iw*sar/2)*2':ih,setsar=1,"
                         + "scale=\(width):\(height):force_original_aspect_ratio=decrease:force_divisible_by=2,"
                         + "pad=\(width):\(height):(ow-iw)/2:(oh-ih)/2:color=black,setsar=1,"
                         + "fps=\(number(fps)),format=yuv420p,setpts=PTS-STARTPTS[v\(i)]")
            concatInputs += "[v\(i)]"
            if withAudio {
                if input.hasAudio {
                    graph.append("[\(i):a:0]aresample=48000,aformat=sample_fmts=fltp:channel_layouts=stereo,"
                                 + "asetpts=PTS-STARTPTS[a\(i)]")
                } else {
                    graph.append("anullsrc=r=48000:cl=stereo,atrim=duration=\(number(max(input.duration, 0.01))),"
                                 + "aformat=sample_fmts=fltp[a\(i)]")
                }
                concatInputs += "[a\(i)]"
            }
        }
        graph.append(concatInputs + "concat=n=\(inputs.count):v=1:a=\(withAudio ? 1 : 0)[vout]" + (withAudio ? "[aout]" : ""))
        args += ["-filter_complex", graph.joined(separator: ";"), "-map", "[vout]"]
        if withAudio { args += ["-map", "[aout]"] }
        args += encoding.videoArgs + (withAudio ? encoding.audioArgs : []) + encoding.muxArgs
        return args + [output.path]
    }

    // MARK: Speed

    /// atempo only accepts 0.5...2, so bigger changes are chained: 4 -> [2, 2], 0.25 -> [0.5, 0.5].
    public static func atempoChain(_ factor: Double) -> [Double] {
        guard factor > 0, factor.isFinite else { return [] }
        var remaining = factor
        var chain: [Double] = []
        while remaining > 2 + 1e-9 { chain.append(2); remaining /= 2 }
        while remaining < 0.5 - 1e-9 { chain.append(0.5); remaining /= 0.5 }
        if abs(remaining - 1) > 1e-9 || chain.isEmpty { chain.append(remaining) }
        return chain
    }

    /// Audio filter for a speed change. Keeping pitch uses atempo; otherwise the
    /// samples are replayed faster or slower, like tape.
    public static func audioSpeedFilter(factor: Double, keepPitch: Bool, sampleRate: Int?) -> String {
        if keepPitch {
            return (["asetpts=PTS-STARTPTS"] + atempoChain(factor).map { "atempo=\(number($0))" }).joined(separator: ",")
        }
        let rate = sampleRate ?? 48000
        return "asetpts=PTS-STARTPTS,asetrate=\(number(Double(rate) * factor)),aresample=\(rate)"
    }

    public static func speed(input: URL, output: URL, factor: Double, keepPitch: Bool, info: VideoToolInfo,
                             encoding: VideoToolEncoding) -> [String] {
        var video = "setpts=(PTS-STARTPTS)/\(number(factor))"
        // Keep the source frame rate: drop frames when faster, repeat them when slower.
        if info.fps > 0 { video += ",fps=\(number(min(info.fps, 120)))" }
        var args = ["-i", input.path, "-map", "0:v:0", "-filter:v", video]
        if info.hasAudio {
            args += ["-map", "0:a:0", "-filter:a",
                     audioSpeedFilter(factor: factor, keepPitch: keepPitch, sampleRate: info.audioSampleRate)]
            args += encoding.videoArgs + encoding.audioArgs
        } else {
            args += encoding.videoArgs + ["-an"]
        }
        return args + encoding.muxArgs + [output.path]
    }

    // MARK: Mute

    /// Drops every audio stream and copies the rest untouched.
    public static func mute(input: URL, output: URL) -> [String] {
        var args = ["-i", input.path, "-map", "0:v", "-map", "0:s?", "-c", "copy", "-an"]
        if ["mp4", "m4v", "mov"].contains(output.pathExtension.lowercased()) { args += VideoToolEncoding.faststart }
        return args + [output.path]
    }

    // MARK: Crop

    /// `audioCodec`: the source's audio codec, which decides whether the audio can be copied.
    public static func crop(input: URL, output: URL, rect: VideoCropRect, encoding: VideoToolEncoding,
                            audioCodec: String? = nil) -> [String] {
        ["-i", input.path, "-map", "0:v:0", "-map", "0:a?",
         "-filter:v", "crop=\(rect.width):\(rect.height):\(rect.x):\(rect.y)"]
            + encoding.videoArgs + encoding.audioArgs(keeping: input, codec: audioCodec) + encoding.muxArgs + [output.path]
    }

    // MARK: Frames

    /// One full-resolution frame at `time` (accurate seek: decodes up to that frame).
    /// With `lastFrameWithin`, every frame in that many seconds overwrites the image, so it
    /// ends up holding the last one: the fallback when `time` is past the file's last frame.
    public static func snapshot(input: URL, output: URL, time: Double, format: VideoSnapshotFormat,
                                lastFrameWithin: Double? = nil) -> [String] {
        var args: [String] = []
        if time > 0 { args += ["-ss", number(time)] }
        args += ["-i", input.path, "-map", "0:v:0"] + frameLimit(lastFrameWithin) + ["-update", "1"]
        // JPEG needs full-range YUV; convert so limited-range sources don't make mjpeg refuse.
        if format == .jpg { args += ["-vf", "scale=out_range=full", "-q:v", "2"] }
        return args + [output.path]
    }

    /// A small JPEG frame for thumbnails and the preview of files AVFoundation can't play.
    public static func thumbnail(input: URL, output: URL, time: Double, maxHeight: Int,
                                 lastFrameWithin: Double? = nil) -> [String] {
        var args: [String] = []
        if time > 0 { args += ["-ss", number(time)] }
        return args + ["-i", input.path, "-map", "0:v:0"] + frameLimit(lastFrameWithin)
            + ["-update", "1", "-vf", "scale=-2:'min(\(maxHeight),ih)':out_range=full", "-q:v", "4", output.path]
    }

    static func frameLimit(_ window: Double?) -> [String] {
        window.map { ["-t", number($0)] } ?? ["-frames:v", "1"]
    }

    // MARK: Redact

    /// Filter graph from `[0:v:0]` to `[vout]` hiding every box during its time range.
    /// `between` covers frames *starting* inside the range, so a box's `start` must already be a cut
    /// before the first frame to hide (`VideoFrameTimes.cut`, as `VideoToolOps.redact` does). The
    /// end gets a microsecond of slack so six-decimal rounding can't drop a frame starting exactly there.
    public static func redactFilterGraph(boxes: [VideoRedactBox], style: VideoRedactStyle, duration: Double) -> String {
        func enable(_ box: VideoRedactBox) -> String? {
            let whole = box.start <= 0.0005 && box.end >= duration - 0.0005
            return whole ? nil : "enable='between(t,\(number(max(0, box.start))),\(number(box.end + 0.000001)))'"
        }
        var graph: [String] = []
        var current = "[0:v:0]"
        switch style {
        case .black:
            let boxesChain = boxes.map { box -> String in
                let r = box.rect
                return "drawbox=x=\(r.x):y=\(r.y):w=\(r.width):h=\(r.height):color=black:t=fill"
                    + (enable(box).map { ":" + $0 } ?? "")
            }
            graph.append(current + (boxesChain + ["format=yuv420p"]).joined(separator: ",") + "[vout]")
        case .blur, .pixelate:
            let n = boxes.count
            graph.append(current + "split=\(n + 1)[base]" + (0..<n).map { "[src\($0)]" }.joined())
            current = "[base]"
            for (i, box) in boxes.enumerated() {
                let r = box.rect
                var effect = "crop=\(r.width):\(r.height):\(r.x):\(r.y),"
                if style == .blur {
                    let sigma = min(60, max(6, Double(min(r.width, r.height)) / 5))
                    effect += "gblur=sigma=\(number(sigma.rounded())):steps=2"
                } else {
                    let block = min(64, max(6, max(r.width, r.height) / 12))
                    effect += "scale=\(max(1, r.width / block)):\(max(1, r.height / block)):flags=area,"
                        + "scale=\(r.width):\(r.height):flags=neighbor"
                }
                graph.append("[src\(i)]\(effect)[fx\(i)]")
                let next = "[ov\(i)]"
                graph.append("\(current)[fx\(i)]overlay=x=\(r.x):y=\(r.y)" + (enable(box).map { ":" + $0 } ?? "") + next)
                current = next
            }
            graph.append(current + "format=yuv420p[vout]")
        }
        return graph.joined(separator: ";")
    }

    public static func redact(input: URL, output: URL, boxes: [VideoRedactBox], style: VideoRedactStyle,
                              duration: Double, encoding: VideoToolEncoding, audioCodec: String? = nil) -> [String] {
        ["-i", input.path, "-filter_complex", redactFilterGraph(boxes: boxes, style: style, duration: duration),
         "-map", "[vout]", "-map", "0:a?"] + encoding.videoArgs + encoding.audioArgs(keeping: input, codec: audioCodec)
            + encoding.muxArgs + [output.path]
    }
}
