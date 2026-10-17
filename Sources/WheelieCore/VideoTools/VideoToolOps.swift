import CoreGraphics
import Foundation
import ImageIO

/// The video tools' exports. Every function probes the source, validates, writes new
/// files via `OutputNaming` (never touching the original) and returns them.
/// `directory` overrides the output folder (nil = the "Save to" setting / next to the source).
public enum VideoToolOps {
    public typealias Progress = VideoToolRunner.Progress

    static func probeVideo(_ url: URL) async throws -> VideoToolInfo {
        let info = try await VideoToolProbe.probe(url)
        guard info.hasVideo else { throw VideoToolError.noVideoTrack }
        return info
    }

    // MARK: Trim

    /// True when a stream copy starting at `start` is frame-exact: the start is 0 or on a keyframe.
    public static func canStreamCopy(start: Double, keyframes: [Double], frameDuration: Double) -> Bool {
        if start <= 0.001 { return true }
        let tolerance = max(0.001, frameDuration / 2)
        return keyframes.contains { abs($0 - start) <= tolerance }
    }

    /// `accurate`: re-encode for frame-exact cuts unless the start already sits on a keyframe.
    /// Not accurate: stream copy, which starts at the keyframe before `start`.
    public static func trim(_ source: URL, start: Double, end: Double, accurate: Bool = true,
                            directory: URL? = nil, progress: Progress? = nil) async throws -> URL {
        let info = try await probeVideo(source)
        let range = try validatedRange(start: start, end: end, duration: info.duration)
        return try await exportRange(source, info: info, range: range, accurate: accurate, suffix: " trimmed",
                                     directory: directory, progress: progress)
    }

    static func validatedRange(start: Double, end: Double, duration: Double) throws -> VideoClipRange {
        let s = max(0, start), e = min(end, duration)
        guard duration > 0, s < duration, e - s >= VideoSplitPlan.minimumGap - 1e-6 else {
            throw VideoToolError.invalidRange
        }
        return VideoClipRange(start: s, end: e)
    }

    static func exportRange(_ source: URL, info: VideoToolInfo, range: VideoClipRange, accurate: Bool,
                            suffix: String, directory: URL?, progress: Progress?) async throws -> URL {
        var copy = !accurate
        if accurate {
            let keyframes = range.start > 0.001
                ? ((try? await VideoToolProbe.keyframeTimes(source, near: range.start)) ?? []) : []
            copy = canStreamCopy(start: range.start, keyframes: keyframes, frameDuration: info.frameDuration)
        }
        let encoding = copy ? nil : VideoToolEncoding.matching(source)
        let ext = encoding?.fileExtension ?? source.pathExtension
        let output = OutputNaming.uniqueURL(for: source, ext: ext.isEmpty ? "mp4" : ext, suffix: suffix, in: directory)
        let args = VideoToolArgs.trim(input: source, output: output, start: range.start, duration: range.duration,
                                      encoding: encoding)
        try await VideoToolRunner.ffmpeg(args, expectedDuration: range.duration, cleanup: [output], progress: progress)
        return output
    }

    // MARK: Split

    /// Separate clips are named "name-1", "name-2", … after their position in the full split.
    public static func split(_ source: URL, points: [Double], removed: Set<Int> = [],
                             mode: VideoSplitExportMode, accurate: Bool = true,
                             directory: URL? = nil, progress: Progress? = nil) async throws -> [URL] {
        let info = try await probeVideo(source)
        if let message = VideoSplitPlan.exportError(points: points, removed: removed, mode: mode, duration: info.duration) {
            throw VideoToolError(message)
        }
        let clips = VideoSplitPlan.clips(points: points, duration: info.duration)
        let kept = clips.indices.filter { !removed.contains($0) }
        switch mode {
        case .separate:
            let total = kept.reduce(0) { $0 + clips[$1].duration }
            var done = 0.0
            var outputs: [URL] = []
            do {
                for index in kept {
                    let clip = clips[index]
                    let base = done
                    var sub: Progress?
                    if let report = progress {
                        sub = { @Sendable fraction in report((base + fraction * clip.duration) / max(total, 0.001)) }
                    }
                    outputs.append(try await exportRange(source, info: info, range: clip, accurate: accurate,
                                                         suffix: "-\(index + 1)", directory: directory, progress: sub))
                    done += clip.duration
                }
            } catch {
                for url in outputs { try? FileManager.default.removeItem(at: url) }
                throw error
            }
            return outputs
        case .joinRest:
            let ranges = kept.map { clips[$0] }
            let encoding = VideoToolEncoding.matching(source)
            let output = OutputNaming.uniqueURL(for: source, ext: encoding.fileExtension, suffix: " edited", in: directory)
            let args = VideoToolArgs.keepRanges(input: source, output: output, ranges: ranges, hasAudio: info.hasAudio,
                                                encoding: encoding)
            try await VideoToolRunner.ffmpeg(args, expectedDuration: ranges.reduce(0) { $0 + $1.duration },
                                             cleanup: [output], progress: progress)
            return [output]
        }
    }

    // MARK: Join

    public enum JoinResolution: String, CaseIterable, Sendable {
        case first, largest
    }

    public static let joinCountMessage = "Select at least two videos to join."
    public static let joinVideoMessage = "Every selected file must contain a video track."

    /// Output frame size for a join: the first clip's, or the largest; even sides.
    public static func joinSize(_ infos: [VideoToolInfo], resolution: JoinResolution) -> (width: Int, height: Int) {
        let pick: VideoToolInfo?
        switch resolution {
        case .first: pick = infos.first
        case .largest: pick = infos.max { $0.displayWidth * $0.displayHeight < $1.displayWidth * $1.displayHeight }
        }
        let w = max(2, (pick?.displayWidth ?? 1280) / 2 * 2)
        let h = max(2, (pick?.displayHeight ?? 720) / 2 * 2)
        return (w, h)
    }

    /// Frame rate for a join: the first clip's (30 when unknown).
    public static func joinFrameRate(_ infos: [VideoToolInfo]) -> Double {
        guard let fps = infos.first?.fps, fps >= 1, fps <= 120 else { return 30 }
        return fps
    }

    /// Re-encodes every clip to H.264/AAC at one size and frame rate and concatenates them.
    public static func join(_ sources: [URL], resolution: JoinResolution = .first,
                            directory: URL? = nil, progress: Progress? = nil) async throws -> URL {
        guard sources.count >= 2, let first = sources.first else { throw VideoToolError(joinCountMessage) }
        var infos: [VideoToolInfo] = []
        for source in sources {
            let info = try await VideoToolProbe.probe(source)
            guard info.hasVideo else { throw VideoToolError(joinVideoMessage) }
            infos.append(info)
        }
        let size = joinSize(infos, resolution: resolution)
        let exts = Set(sources.map { $0.pathExtension.lowercased() })
        let ext = exts.count == 1 && ["mp4", "m4v", "mov"].contains(exts.first!) ? exts.first! : "mp4"
        let encoding = VideoToolEncoding(fileExtension: ext, videoArgs: VideoToolEncoding.x264, audioArgs: VideoToolEncoding.aac,
                                     muxArgs: VideoToolEncoding.faststart)
        let output = OutputNaming.uniqueURL(for: first, ext: ext, suffix: " joined", in: directory)
        let inputs = zip(sources, infos).map { VideoToolArgs.JoinInput(url: $0, duration: $1.duration, hasAudio: $1.hasAudio) }
        let args = VideoToolArgs.join(inputs: inputs, output: output, width: size.width, height: size.height,
                                      fps: joinFrameRate(infos), encoding: encoding)
        try await VideoToolRunner.ffmpeg(args, expectedDuration: infos.reduce(0) { $0 + $1.duration },
                                         cleanup: [output], progress: progress)
        return output
    }

    // MARK: Speed

    public static func changeSpeed(_ source: URL, factor: Double, keepPitch: Bool = true,
                                   directory: URL? = nil, progress: Progress? = nil) async throws -> URL {
        guard VideoSpeed.range.contains(factor) else { throw VideoToolError(VideoSpeed.rangeMessage) }
        let info = try await probeVideo(source)
        let encoding = VideoToolEncoding.matching(source)
        let output = OutputNaming.uniqueURL(for: source, ext: encoding.fileExtension,
                                            suffix: VideoSpeed.fileSuffix(factor), in: directory)
        let args = VideoToolArgs.speed(input: source, output: output, factor: factor, keepPitch: keepPitch,
                                       info: info, encoding: encoding)
        try await VideoToolRunner.ffmpeg(args, expectedDuration: info.duration / factor, cleanup: [output],
                                         progress: progress)
        return output
    }

    // MARK: Mute

    /// Copies the video without its audio. Throws `noAudioTrack` when there is nothing to remove.
    public static func mute(_ source: URL, directory: URL? = nil) async throws -> URL {
        let info = try await probeVideo(source)
        guard info.hasAudio else { throw VideoToolError.noAudioTrack }
        let ext = source.pathExtension.isEmpty ? "mp4" : source.pathExtension
        let output = OutputNaming.uniqueURL(for: source, ext: ext, suffix: " muted", in: directory)
        try await VideoToolRunner.ffmpeg(VideoToolArgs.mute(input: source, output: output), cleanup: [output])
        return output
    }

    public static let muteNoneMessage = "None of these videos has an audio track."

    /// Mutes several videos. Videos that are already silent are skipped; this throws when
    /// nothing could be muted or when any file failed for another reason.
    public static func mute(_ sources: [URL], directory: URL? = nil) async throws -> [URL] {
        var outputs: [URL] = []
        var silent = 0
        var errors: [String] = []
        for source in sources {
            do {
                outputs.append(try await mute(source, directory: directory))
            } catch let error as VideoToolError where error == .noAudioTrack {
                silent += 1
            } catch {
                errors.append(error.localizedDescription)
            }
        }
        if let first = errors.first {
            throw VideoToolError(sources.count == 1 ? first : "\(errors.count) of \(sources.count) failed: \(first)")
        }
        if outputs.isEmpty {
            throw silent == 1 ? VideoToolError.noAudioTrack : VideoToolError(muteNoneMessage)
        }
        return outputs
    }

    // MARK: Crop

    /// `rect` is in displayed pixels; it is snapped to even values.
    public static func crop(_ source: URL, rect: VideoCropRect, directory: URL? = nil,
                            progress: Progress? = nil) async throws -> URL {
        let info = try await probeVideo(source)
        let (W, H) = (info.displayWidth, info.displayHeight)
        if let message = VideoCropMath.validationError(rect, width: W, height: H) { throw VideoToolError(message) }
        let snapped = VideoCropMath.even(rect.cgRect, width: W, height: H)
        let encoding = VideoToolEncoding.matching(source)
        let output = OutputNaming.uniqueURL(for: source, ext: encoding.fileExtension, suffix: " cropped", in: directory)
        let args = VideoToolArgs.crop(input: source, output: output, rect: snapped, encoding: encoding)
        try await VideoToolRunner.ffmpeg(args, expectedDuration: info.duration, cleanup: [output], progress: progress)
        return output
    }

    // MARK: Snapshots

    public static let snapshotEmptyMessage = "Add a frame to save."

    /// Saves full-resolution frames as "<name> 00m12s.png".
    public static func snapshots(_ source: URL, times: [Double], format: VideoSnapshotFormat = .png,
                                 directory: URL? = nil, progress: Progress? = nil) async throws -> [URL] {
        guard !times.isEmpty else { throw VideoToolError(snapshotEmptyMessage) }
        let info = try await probeVideo(source)
        let last = max(0, info.duration - info.frameDuration)
        var outputs: [URL] = []
        do {
            for (index, time) in times.sorted().enumerated() {
                let t = min(max(0, time), last)
                let output = OutputNaming.uniqueURL(for: source, ext: format.rawValue,
                                                    suffix: " " + VideoToolTimecode.fileStamp(t), in: directory)
                try await extractFrame(to: output, at: t, nearEnd: t > info.duration - 1) { time, window in
                    VideoToolArgs.snapshot(input: source, output: output, time: time, format: format,
                                           lastFrameWithin: window)
                }
                outputs.append(output)
                progress?(Double(index + 1) / Double(times.count))
            }
        } catch {
            for url in outputs { try? FileManager.default.removeItem(at: url) }
            throw error
        }
        return outputs
    }

    /// Writes one frame. Containers often report a duration a little past the last frame; when
    /// nothing comes out near the end, the last frame of the final second is used instead.
    static func extractFrame(to output: URL, at time: Double, nearEnd: Bool,
                             arguments: (_ time: Double, _ lastFrameWithin: Double?) -> [String]) async throws {
        var firstError: Error?
        do {
            try await VideoToolRunner.ffmpeg(arguments(time, nil), cleanup: [output])
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            firstError = error
        }
        if exists(output) { return }
        guard nearEnd else { throw firstError ?? VideoToolError.noFrame }
        try? FileManager.default.removeItem(at: output)
        let from = max(0, time - 1)
        try await VideoToolRunner.ffmpeg(arguments(from, time - from + 0.5), cleanup: [output])
        guard exists(output) else { throw VideoToolError.noFrame }
    }

    static func exists(_ url: URL) -> Bool {
        ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0
    }

    // MARK: Redact

    public static func redact(_ source: URL, boxes: [VideoRedactBox], style: VideoRedactStyle,
                              directory: URL? = nil, progress: Progress? = nil) async throws -> URL {
        let info = try await probeVideo(source)
        let (W, H) = (info.displayWidth, info.displayHeight)
        if let message = VideoRedactPlan.validationError(boxes, width: W, height: H, duration: info.duration) {
            throw VideoToolError(message)
        }
        let snapped = boxes.map { box -> VideoRedactBox in
            var b = box
            b.rect = VideoCropMath.even(box.rect.cgRect, width: W, height: H)
            b.end = min(box.end, info.duration)
            return b
        }
        let encoding = VideoToolEncoding.matching(source)
        let output = OutputNaming.uniqueURL(for: source, ext: encoding.fileExtension, suffix: " redacted", in: directory)
        let args = VideoToolArgs.redact(input: source, output: output, boxes: snapped, style: style,
                                        duration: info.duration, encoding: encoding)
        try await VideoToolRunner.ffmpeg(args, expectedDuration: info.duration, cleanup: [output], progress: progress)
        return output
    }
}

/// Frames decoded by ffmpeg, for files AVFoundation can't read.
public enum VideoToolFrames {
    /// One frame at `time`, at most `maxHeight` pixels tall. `duration` (when known) limits
    /// the end-of-file fallback to times in the last second.
    public static func frame(_ url: URL, at time: Double, maxHeight: Int, duration: Double? = nil) async throws -> CGImage {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wheelie-frame-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let output = dir.appendingPathComponent("frame.jpg")
        let nearEnd = duration.map { time > $0 - 1 } ?? true
        try await VideoToolOps.extractFrame(to: output, at: max(0, time), nearEnd: nearEnd) { t, window in
            VideoToolArgs.thumbnail(input: url, output: output, time: t, maxHeight: maxHeight, lastFrameWithin: window)
        }
        guard let src = CGImageSourceCreateWithURL(output as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw VideoToolError.noFrame }
        return image
    }
}
