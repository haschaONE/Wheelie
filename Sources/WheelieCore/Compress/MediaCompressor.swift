import Foundation

/// Video → H.264/AAC MP4 (CRF presets or two-pass to a size budget).
/// Audio → same family where it has a lossy codec (MP3, Opus), AAC/M4A otherwise.
enum MediaCompressor {
    static func compress(_ source: URL, options: CompressionOptions, cap: Int64, targeted: Bool,
                         workDir: URL) async throws -> (url: URL, ext: String) {
        let probe = try await MediaProbe.probe(source)
        if probe.videoStreams.isEmpty {
            guard !probe.audioStreams.isEmpty else { throw CompressionError.unreadable(source.lastPathComponent) }
            return try await compressAudio(source, probe: probe, strength: options.mediaStrength,
                                           cap: targeted ? cap : nil, workDir: workDir)
        }
        return try await compressVideo(source, probe: probe, strength: options.mediaStrength,
                                       cap: targeted ? cap : nil, workDir: workDir)
    }

    static let ffmpegBase = ["-nostdin", "-hide_banner", "-loglevel", "error", "-y"]

    // MARK: Video

    struct VideoPlan: Equatable {
        enum RateControl: Equatable { case crf(Int), bitrate(kbps: Int) }
        var rate: RateControl
        var audioKbps: Int
        /// Cap on the shorter display edge (1080 = "1080p"); nil keeps the size.
        var maxShortEdge: Int?
        var maxFPS: Int?
    }

    static func presetPlan(_ strength: CompressionStrength, sourceAudioKbps: Int?) -> VideoPlan {
        let audio: Int
        switch strength {
        case .light: audio = 160
        case .balanced: audio = 128
        case .strong: audio = 96
        }
        let capped = sourceAudioKbps.map { max(64, min(audio, $0 / 16 * 16)) } ?? audio
        switch strength {
        case .light: return VideoPlan(rate: .crf(23), audioKbps: capped, maxShortEdge: nil, maxFPS: nil)
        case .balanced: return VideoPlan(rate: .crf(27), audioKbps: capped, maxShortEdge: nil, maxFPS: nil)
        case .strong: return VideoPlan(rate: .crf(31), audioKbps: capped, maxShortEdge: 1080, maxFPS: 30)
        }
    }

    /// Splits a byte budget into audio and video bitrates and picks a resolution the bitrate can carry.
    static func budgetPlan(targetBytes: Int64, duration: Double, audioStreams: Int, sourceAudioKbps: Int?) throws -> VideoPlan {
        guard duration > 0 else { throw CompressionError.videoUnverified }
        // ~3% for the MP4 container and index.
        let totalKbps = Double(targetBytes) * 8 * 0.97 / duration / 1000
        var audio = 0
        if audioStreams > 0 {
            switch totalKbps {
            case 2000...: audio = 128
            case 800..<2000: audio = 96
            case 300..<800: audio = 64
            default: audio = 32
            }
            if let source = sourceAudioKbps, source >= 32 { audio = min(audio, max(32, source / 16 * 16)) }
        }
        let video = Int(totalKbps) - audio * audioStreams
        guard video >= 40 else {
            if audioStreams > 0, totalKbps >= 40 { throw CompressionError.targetTooSmallAfterAudio }
            throw CompressionError.targetTooSmallForDuration
        }
        let edge: Int?
        switch video {
        case ..<300: edge = 360
        case 300..<700: edge = 480
        case 700..<1500: edge = 720
        case 1500..<3500: edge = 1080
        default: edge = nil
        }
        return VideoPlan(rate: .bitrate(kbps: video), audioKbps: audio, maxShortEdge: edge, maxFPS: video < 1500 ? 30 : nil)
    }

    /// Even dimensions (yuv420p needs them); optionally caps the shorter edge. Runs after autorotation.
    static func scaleFilter(maxShortEdge: Int?) -> String {
        guard let s = maxShortEdge else { return "scale=trunc(iw/2)*2:trunc(ih/2)*2" }
        return "scale=w='if(gte(iw,ih),-2,trunc(min(iw,\(s))/2)*2)':h='if(gte(iw,ih),trunc(min(ih,\(s))/2)*2,-2)'"
    }

    static func videoArguments(_ plan: VideoPlan, pass: Int?, passLog: URL?) -> [String] {
        var args = ["-map", "0:V:0", "-vf", scaleFilter(maxShortEdge: plan.maxShortEdge),
                    "-c:v", "libx264", "-preset", "medium", "-pix_fmt", "yuv420p"]
        if let fps = plan.maxFPS { args += ["-fpsmax", String(fps)] }
        switch plan.rate {
        case .crf(let crf): args += ["-crf", String(crf)]
        case .bitrate(let kbps): args += ["-b:v", "\(kbps)k"]
        }
        if let pass, let passLog { args += ["-pass", String(pass), "-passlogfile", passLog.path] }
        return args
    }

    static func compressVideo(_ source: URL, probe: MediaProbe, strength: CompressionStrength, cap: Int64?,
                              workDir: URL) async throws -> (url: URL, ext: String) {
        let output = workDir.appendingPathComponent("output.mp4")
        let audioCount = probe.audioStreams.count
        var plan = try cap.map {
            try budgetPlan(targetBytes: $0, duration: probe.duration, audioStreams: audioCount, sourceAudioKbps: probe.audioKbps)
        } ?? presetPlan(strength, sourceAudioKbps: probe.audioKbps)

        for attempt in 0..<2 {
            try await encodeVideo(source, plan: plan, hasAudio: audioCount > 0, output: output, workDir: workDir)
            try await verify(output, against: probe, expectVideo: true)
            guard let cap, case .bitrate(let kbps) = plan.rate else { break }
            let size = ByteSize.of(output)
            if size <= cap { break }
            // Overshot: scale the video bitrate down by the miss and try once more.
            let scaled = Int(Double(kbps) * Double(cap) / Double(size) * 0.95)
            guard attempt == 0, scaled >= 40 else { throw CompressionError.videoDidNotFit }
            plan.rate = .bitrate(kbps: scaled)
        }
        return (output, "mp4")
    }

    static func encodeVideo(_ source: URL, plan: VideoPlan, hasAudio: Bool, output: URL, workDir: URL) async throws {
        let audio = hasAudio ? ["-map", "0:a?", "-c:a", "aac", "-b:a", "\(plan.audioKbps)k"] : ["-an"]
        let tail = ["-sn", "-dn", "-map_metadata", "0", "-movflags", "+faststart", output.path]
        if case .bitrate = plan.rate {
            let log = workDir.appendingPathComponent("x264pass")
            try await Tools.run("ffmpeg", ffmpegBase + ["-i", source.path] + videoArguments(plan, pass: 1, passLog: log)
                                + ["-an", "-sn", "-dn", "-f", "null", "/dev/null"])
            try await Tools.run("ffmpeg", ffmpegBase + ["-i", source.path] + videoArguments(plan, pass: 2, passLog: log)
                                + audio + tail)
        } else {
            try await Tools.run("ffmpeg", ffmpegBase + ["-i", source.path] + videoArguments(plan, pass: nil, passLog: nil)
                                + audio + tail)
        }
    }

    /// Duration within 5% (or half a second) and the same video/audio tracks.
    static func verify(_ output: URL, against source: MediaProbe, expectVideo: Bool) async throws {
        guard let result = try? await MediaProbe.probe(output) else { throw CompressionError.videoUnverified }
        let tolerance = max(0.5, source.duration * 0.05)
        let durationOK = source.duration <= 0 || abs(result.duration - source.duration) <= tolerance
        let videoOK = !expectVideo || result.videoStreams.count == 1
        let audioOK = expectVideo ? result.audioStreams.count == source.audioStreams.count : result.audioStreams.count == 1
        guard durationOK, videoOK, audioOK else { throw CompressionError.videoUnverified }
    }

    // MARK: Audio

    enum AudioCodec: Equatable {
        case aac, mp3, opus

        var fileExtension: String {
            switch self { case .aac: return "m4a"; case .mp3: return "mp3"; case .opus: return "opus" }
        }

        var encoder: [String] {
            switch self {
            case .aac: return ["-c:a", "aac", "-movflags", "+faststart"]
            case .mp3: return ["-c:a", "libmp3lame", "-id3v2_version", "3"]
            case .opus: return ["-c:a", "libopus"]
            }
        }

        func preset(_ strength: CompressionStrength) -> Int {
            switch (self, strength) {
            case (.aac, .light): return 160
            case (.aac, .balanced): return 128
            case (.aac, .strong): return 96
            case (.mp3, .light): return 192
            case (.mp3, .balanced): return 128
            case (.mp3, .strong): return 96
            case (.opus, .light): return 128
            case (.opus, .balanced): return 96
            case (.opus, .strong): return 64
            }
        }

        /// MP3 only allows a fixed set of bitrates; others round down to 8 kbit/s steps.
        func snap(_ kbps: Int) -> Int {
            if self == .mp3 {
                let allowed = [32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
                return allowed.last { $0 <= kbps } ?? 32
            }
            return max(8, kbps / 8 * 8)
        }
    }

    static func audioCodec(for source: URL) -> AudioCodec {
        switch source.pathExtension.lowercased() {
        case "mp3": return .mp3
        case "opus": return .opus
        default: return .aac
        }
    }

    /// Lower than the source when it is already lossy: re-encoding at the same rate only costs quality.
    static func presetAudioKbps(_ codec: AudioCodec, strength: CompressionStrength, sourceKbps: Int?) -> Int {
        let ratio: Double
        switch strength { case .light: ratio = 0.8; case .balanced: ratio = 0.6; case .strong: ratio = 0.45 }
        var kbps = codec.preset(strength)
        if let source = sourceKbps, source > 0 { kbps = min(kbps, Int(Double(source) * ratio)) }
        return codec.snap(max(kbps, 32))
    }

    static func budgetAudioKbps(_ codec: AudioCodec, targetBytes: Int64, duration: Double) throws -> Int {
        guard duration > 0 else { throw CompressionError.videoUnverified }
        // ~3% and 8 KB for the container and tags.
        let kbps = (Double(targetBytes) * 0.97 - 8192) * 8 / duration / 1000
        guard kbps >= 24 else { throw CompressionError.targetTooSmallForDuration }
        return codec.snap(min(Int(kbps), 320))
    }

    static func compressAudio(_ source: URL, probe: MediaProbe, strength: CompressionStrength, cap: Int64?,
                              workDir: URL) async throws -> (url: URL, ext: String) {
        let codec = audioCodec(for: source)
        let output = workDir.appendingPathComponent("output").appendingPathExtension(codec.fileExtension)
        var kbps = try cap.map { try budgetAudioKbps(codec, targetBytes: $0, duration: probe.duration) }
            ?? presetAudioKbps(codec, strength: strength, sourceKbps: probe.audioKbps)
        for attempt in 0..<2 {
            var args = ffmpegBase + ["-i", source.path, "-map", "0:a:0", "-vn", "-sn", "-dn"] + codec.encoder
            args += ["-b:a", "\(kbps)k", "-map_metadata", "0"]
            if kbps < 48, codec != .opus { args += ["-ac", "1"] }
            try await Tools.run("ffmpeg", args + [output.path])
            try await verify(output, against: probe, expectVideo: false)
            guard let cap else { break }
            let size = ByteSize.of(output)
            if size <= cap { break }
            let lower = codec.snap(Int(Double(kbps) * Double(cap) / Double(size) * 0.95))
            guard attempt == 0, lower >= 24, lower < kbps else { throw CompressionError.targetUnreachable(smallest: size) }
            kbps = lower
        }
        return (output, codec.fileExtension)
    }
}
