import Foundation

/// How an audio tool writes its result: codec arguments chosen to match the source.
public struct AudioEncoding: Sendable, Equatable {
    /// Output arguments for the audio, e.g. ["-c:a", "libmp3lame", "-b:a", "192k"]. May also name the
    /// muxer ("-f", "ipod") for an extension ffmpeg doesn't recognise.
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

    // MARK: Codec and container

    /// An encoder choice: ffmpeg arguments and the codec they produce.
    struct Choice: Equatable {
        var arguments: [String]
        var codec: String
        var sampleRate: Int? = nil
    }

    static let littleEndianPCM: Set<String> = ["pcm_s16le", "pcm_s24le", "pcm_s32le", "pcm_f32le", "pcm_f64le", "pcm_u8"]
    static let bigEndianPCM: Set<String> = ["pcm_s16be", "pcm_s24be", "pcm_s32be", "pcm_f32be", "pcm_f64be", "pcm_s8"]
    static let compandedPCM: Set<String> = ["pcm_mulaw", "pcm_alaw"]
    static let losslessCodecs: Set<String> = ["flac", "alac", "wavpack", "ape", "tta", "tak", "truehd", "mlp", "shorten"]
    /// Containers that hold every codec we write.
    static let anyCodecContainers: Set<String> = ["mkv", "mka"]

    /// Audio codecs each container (by output extension) holds, among the codecs we encode to; checked
    /// against ffmpeg's muxers. An extension missing here has no muxer for any encoder we have (amr, dts,
    /// ape, ...) or no muxer at all (snd), and the result gets another extension.
    static let containerCodecs: [String: Set<String>] = {
        var map: [String: Set<String>] = [:]
        func add(_ extensions: [String], _ codecs: Set<String>) { for ext in extensions { map[ext] = codecs } }
        add(["mp3"], ["mp3"])
        add(["wav"], littleEndianPCM.union(compandedPCM).union(["mp3", "mp2", "aac", "ac3", "eac3", "flac"]))
        add(["aif", "aiff", "aifc"], bigEndianPCM.union(compandedPCM).union(["pcm_s16le", "pcm_u8"]))
        add(["au"], bigEndianPCM.union(compandedPCM))
        add(["flac"], ["flac"])
        add(["ogg", "oga"], ["opus", "flac"])
        add(["opus", "webm"], ["opus"])
        add(["m4a", "m4b", "m4r", "m4v"], ["aac", "alac", "ac3"])
        add(["mp4"], ["aac", "alac", "mp3", "mp2", "ac3", "eac3", "opus", "flac"])
        add(["mov"], pcmCodecs.union(compandedPCM).union(["aac", "alac", "mp3", "mp2", "ac3", "eac3"]))
        add(["3gp", "3g2", "aac"], ["aac"])
        add(["wma", "asf", "wmv"], ["aac", "mp3", "mp2", "ac3", "eac3", "pcm_s16le"])
        add(["flv"], ["aac", "mp3"])
        add(["avi"], compandedPCM.union(["mp3", "mp2", "aac", "ac3", "eac3", "pcm_s16le", "pcm_u8"]))
        add(["ts", "mts", "m2ts"], ["aac", "mp2", "mp3", "ac3", "eac3", "opus"])
        add(["mpg", "mpeg", "vob"], ["mp2", "mp3", "ac3"])
        add(["mp2"], ["mp2"])
        add(["wv"], ["wavpack"])
        add(["tta"], ["tta"])
        add(["caf"], littleEndianPCM.union(compandedPCM).union(["pcm_s16be", "pcm_f32be", "alac", "flac", "mp3", "mp2", "ac3"]))
        add(["ac3"], ["ac3"])
        add(["eac3"], ["eac3"])
        return map
    }()

    /// Muxers for extensions ffmpeg can't pick one for by name.
    static let muxers = ["m4r": "ipod"]

    static func holds(_ container: String, _ codec: String) -> Bool {
        anyCodecContainers.contains(container) || containerCodecs[container]?.contains(codec) == true
    }

    /// Re-encoding in the source's own codec, when we have an encoder for it.
    static func sourceCodecChoice(_ info: AudioInfo) -> Choice? {
        let codec = info.codec
        if pcmCodecs.contains(codec) || compandedPCM.contains(codec) { return Choice(arguments: ["-c:a", codec], codec: codec) }
        switch codec {
        case "mp3":
            return Choice(arguments: ["-c:a", "libmp3lame", "-b:a", lossyBitRate(info.bitRate, default: 192)], codec: "mp3")
        case "aac":
            return Choice(arguments: ["-c:a", "aac", "-b:a", lossyBitRate(info.bitRate, default: 192, maximum: 320)], codec: "aac")
        case "alac", "flac", "wavpack", "tta":
            return Choice(arguments: ["-c:a", codec], codec: codec)
        case "opus", "vorbis":
            return Choice(arguments: ["-c:a", "libopus", "-b:a", lossyBitRate(info.bitRate, default: 128, maximum: 256)],
                          codec: "opus", sampleRate: 48000)
        case "ac3", "eac3":
            return Choice(arguments: ["-c:a", codec, "-b:a", info.bitRate.map { "\(max(192, $0 / 1000))k" } ?? "384k"],
                          codec: codec)
        case "mp2":
            return Choice(arguments: ["-c:a", "mp2", "-b:a", lossyBitRate(info.bitRate, default: 192, maximum: 384)], codec: "mp2")
        default:
            return nil
        }
    }

    /// The codec a container is normally written with; nil when no encoder we have fits it.
    static func usualChoice(for container: String) -> Choice? {
        switch container {
        case "mp3", "avi": return Choice(arguments: ["-c:a", "libmp3lame", "-b:a", "192k"], codec: "mp3")
        case "wav": return Choice(arguments: ["-c:a", "pcm_s16le"], codec: "pcm_s16le")
        case "aif", "aiff", "aifc", "au": return Choice(arguments: ["-c:a", "pcm_s16be"], codec: "pcm_s16be")
        case "flac": return Choice(arguments: ["-c:a", "flac"], codec: "flac")
        case "ogg", "oga", "opus", "webm":
            return Choice(arguments: ["-c:a", "libopus", "-b:a", "128k"], codec: "opus", sampleRate: 48000)
        case "mp2", "mpg", "mpeg", "vob": return Choice(arguments: ["-c:a", "mp2", "-b:a", "192k"], codec: "mp2")
        case "ac3", "eac3": return Choice(arguments: ["-c:a", container, "-b:a", "384k"], codec: container)
        case "wv": return Choice(arguments: ["-c:a", "wavpack"], codec: "wavpack")
        case "tta": return Choice(arguments: ["-c:a", "tta"], codec: "tta")
        case "caf": return Choice(arguments: ["-c:a", "alac"], codec: "alac")
        default:
            return holds(container, "aac") ? Choice(arguments: ["-c:a", "aac", "-b:a", "192k"], codec: "aac") : nil
        }
    }

    /// Re-encodes in the source's codec where we have an encoder and the container can hold it, otherwise in
    /// the container's usual codec. `url` is the source. Its extension is kept unless nothing we can encode
    /// fits that container (AMR, DTS, Monkey's Audio, ...): then the result is M4A, FLAC for lossless
    /// audio, or Matroska for movies.
    public static func matching(_ info: AudioInfo, source url: URL) -> AudioEncoding {
        let ext = url.pathExtension.lowercased()
        let preferred = sourceCodecChoice(info)
        var container = ext
        var choice: Choice?
        if let preferred, holds(ext, preferred.codec) {
            choice = preferred
        } else {
            choice = usualChoice(for: ext)
        }
        if choice == nil {
            let lossless = losslessCodecs.contains(info.codec) || info.codec.hasPrefix("pcm_")
            if info.hasVideo {
                container = "mkv"
                choice = preferred ?? usualChoice(for: "mkv")
            } else if let preferred, holds("m4a", preferred.codec) {
                container = "m4a"
                choice = preferred
            } else if lossless {
                container = "flac"
                choice = usualChoice(for: "flac")
            } else {
                container = "m4a"
                choice = usualChoice(for: "m4a")
            }
        }
        let picked = choice ?? Choice(arguments: ["-c:a", "aac", "-b:a", "192k"], codec: "aac")
        var arguments = picked.arguments
        if let muxer = muxers[container] { arguments += ["-f", muxer] }
        let art = ["mp3", "m4a", "flac"].contains(container) && !info.hasVideo
        return AudioEncoding(codecArguments: arguments, fileExtension: container, carriesCoverArt: art,
                             requiredSampleRate: picked.sampleRate)
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
    /// For movies whose other streams must survive too, use `audioArguments`.
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

    /// Maps, filter and codec options for re-encoding the first audio stream through `filter`.
    /// For a movie with `keepVideo`, every other stream (video, the other audio tracks, subtitles,
    /// attachments) is stream-copied as it is; only that one audio stream, the output's first, is filtered
    /// and re-encoded.
    public static func audioArguments(_ info: AudioInfo, encoding: AudioEncoding, keepVideo: Bool,
                                      filter: String?, sampleRate: Int?) -> [String] {
        guard info.hasVideo && keepVideo else {
            var args = streamMaps(info, encoding: encoding, keepVideo: false)
            if let filter { args += ["-af", filter] }
            args += encoding.codecArguments
            if let sampleRate { args += ["-ar", "\(sampleRate)"] }
            return args
        }
        var args = ["-map", "0:v?", "-map", "0:\(info.audioStreamIndex)"]
        for index in info.otherAudioStreamIndices { args += ["-map", "0:\(index)"] }
        args += ["-map", "0:s?", "-map", "0:t?", "-c", "copy"]
        if let filter { args += ["-filter:a:0", filter] }
        args += firstAudioStreamOnly(encoding.codecArguments)
        if let sampleRate { args += ["-ar:a:0", "\(sampleRate)"] }
        return args
    }

    /// Narrows audio codec options to the output's first audio stream: "-c:a" -> "-c:a:0".
    static func firstAudioStreamOnly(_ arguments: [String]) -> [String] {
        arguments.map { ["-c:a", "-b:a", "-q:a"].contains($0) ? $0 + ":0" : $0 }
    }

    /// Runs ffmpeg writing `output`. Cancelling the calling task stops ffmpeg. On failure or cancellation
    /// the partial output is deleted and the error rethrown; an empty result counts as a failure too
    /// (ffmpeg exits 0 when, say, a trim starts past the end of the audio).
    public static func run(_ arguments: [String], output: URL) async throws {
        do {
            try await AudioProcess.ffmpeg(arguments)
            let size = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.int64Value ?? 0
            guard size > 0 else {
                throw AudioToolError.unreadable("The result was empty, so nothing was saved. The chosen range may lie past the end of the audio.")
            }
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

/// ffmpeg for the audio tools, stopped when the calling task is cancelled, so a replaced preview render
/// doesn't keep decoding the whole file. Same input hardening as `Tools.run`.
enum AudioProcess {
    static func ffmpeg(_ arguments: [String]) async throws {
        guard let exe = Tools.locate("ffmpeg") else { throw ToolError.missing("ffmpeg") }
        let finalArguments = try Tools.hardenFFmpegInputs(arguments)
        try Task.checkCancellation()
        let handle = AudioProcessHandle()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let process = Process()
                process.executableURL = exe
                process.arguments = finalArguments
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = FileHandle.nullDevice
                let errPipe = Pipe()
                process.standardError = errPipe
                let errData = LockedData()
                errPipe.fileHandleForReading.readabilityHandler = { errData.append($0.availableData) }
                process.terminationHandler = { p in
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    errData.append(errPipe.fileHandleForReading.readDataToEndOfFile())
                    if handle.wasCancelled {
                        cont.resume(throwing: CancellationError())
                    } else if p.terminationStatus == 0 {
                        cont.resume()
                    } else {
                        cont.resume(throwing: ToolError.failed(tool: "ffmpeg", status: p.terminationStatus,
                                                               stderr: String(decoding: errData.value, as: UTF8.self)))
                    }
                }
                guard handle.attach(process) else {
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    cont.resume(throwing: CancellationError())
                    return
                }
                do {
                    try process.run()
                    // Cancelled between attach and launch: terminate() was a no-op then.
                    if handle.wasCancelled { process.terminate() }
                } catch {
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    cont.resume(throwing: error)
                }
            }
        } onCancel: {
            handle.cancel()
        }
    }
}

/// The running ffmpeg, so task cancellation can stop it.
final class AudioProcessHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    var wasCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    /// False when cancelled before the process started.
    func attach(_ process: Process) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { return false }
        self.process = process
        return true
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let p = process
        lock.unlock()
        if let p, p.isRunning { p.terminate() }
    }
}
