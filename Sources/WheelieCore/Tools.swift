import Foundation

public enum ToolError: LocalizedError {
    case missing(String)
    case failed(tool: String, status: Int32, stderr: String)

    public var errorDescription: String? {
        switch self {
        case .missing(let name):
            return "\(name) not found. Install it with: brew install \(name == "cwebp" ? "webp" : name)"
        case .failed(let tool, let status, let stderr):
            let tail = stderr.split(separator: "\n").suffix(3).joined(separator: "\n")
            return "\(tool) exited with \(status): \(tail)"
        }
    }
}

public enum Tools {
    static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]

    public static func locate(_ name: String) -> URL? {
        let env = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        for dir in searchPaths + env {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    /// Runs a tool to completion off the main thread; throws with stderr on non-zero exit.
    public static func run(_ name: String, _ arguments: [String]) async throws {
        _ = try await capture(name, arguments)
    }

    /// Like `run`, but returns stdout and stderr (ffprobe, ffmpeg loudnorm/silencedetect output, ...).
    /// `name` is looked up with `locate`, or used as-is when it is an absolute path.
    @discardableResult
    public static func capture(_ name: String, _ arguments: [String]) async throws -> (stdout: String, stderr: String) {
        let exe = name.hasPrefix("/") ? URL(fileURLWithPath: name) : locate(name)
        guard let exe, FileManager.default.isExecutableFile(atPath: exe.path) else { throw ToolError.missing(name) }
        let isFFmpeg = ["ffmpeg", "ffprobe"].contains(exe.lastPathComponent)
        let finalArguments = isFFmpeg ? try hardenFFmpegInputs(arguments, probe: exe.lastPathComponent == "ffprobe") : arguments
        return try await withCheckedThrowingContinuation { cont in
            let process = Process()
            process.executableURL = exe
            process.arguments = finalArguments
            process.standardInput = FileHandle.nullDevice
            let outPipe = Pipe(), errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            // Drain both pipes continuously so a chatty tool can't fill one and block.
            let outData = LockedData(), errData = LockedData()
            outPipe.fileHandleForReading.readabilityHandler = { outData.append($0.availableData) }
            errPipe.fileHandleForReading.readabilityHandler = { errData.append($0.availableData) }
            process.terminationHandler = { p in
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                outData.append(outPipe.fileHandleForReading.readDataToEndOfFile())
                errData.append(errPipe.fileHandleForReading.readDataToEndOfFile())
                let stdout = String(decoding: outData.value, as: UTF8.self)
                let stderr = String(decoding: errData.value, as: UTF8.self)
                if p.terminationStatus == 0 {
                    cont.resume(returning: (stdout, stderr))
                } else {
                    cont.resume(throwing: ToolError.failed(tool: exe.lastPathComponent, status: p.terminationStatus, stderr: stderr))
                }
            }
            do { try process.run() } catch { cont.resume(throwing: error) }
        }
    }
}

public struct UnsafeMediaInputError: LocalizedError {
    public let file: String
    public var errorDescription: String? { "\(file) is a playlist, not a media file, and was not opened." }
}

extension Tools {
    /// Demuxers ffmpeg/ffprobe may use for a local file. Playlist and manifest demuxers
    /// (hls, dash, concat, sdp, ...) are deliberately absent, so a file can never make
    /// ffmpeg open other files or URLs, whatever its contents or extension.
    static let mediaDemuxers = [
        "mov", "mp4", "m4a", "3gp", "3g2", "mj2", "matroska", "webm", "avi", "asf", "flv", "mpegts",
        "mpeg", "mpegvideo", "mxf", "dv", "nut", "ogg", "mp3", "wav", "w64", "flac", "aac", "ac3", "eac3",
        "dts", "truehd", "aiff", "caf", "amr", "au", "ape", "wv", "tta", "mpc", "mpc8", "tak", "voc",
        "m4v", "h264", "hevc", "mjpeg", "ivf", "obu", "yuv4mpegpipe", "gif", "apng", "image2",
        "png_pipe", "jpeg_pipe", "webp_pipe", "bmp_pipe", "tiff_pipe", "gif_pipe", "svg_pipe",
        "psd_pipe", "ppm_pipe", "pam_pipe", "j2k_pipe", "jpegxl_pipe", "qoi_pipe", "dpx_pipe",
        "exr_pipe", "srt", "ass", "webvtt",
    ]

    /// Applies the demuxer allowlist and a local-only protocol list to every file input.
    /// ffmpeg: each `-i <file>`; an explicit `-f X` we pass (e.g. our own concat list) is
    /// added to that input's allowlist. ffprobe: options are prepended for its one input.
    static func hardenFFmpegInputs(_ arguments: [String], probe: Bool = false) throws -> [String] {
        let fm = FileManager.default
        func guardFile(_ path: String) throws {
            if looksLikePlaylist(path) { throw UnsafeMediaInputError(file: (path as NSString).lastPathComponent) }
        }
        let allow = mediaDemuxers.joined(separator: ",")
        if probe {
            for arg in arguments where fm.fileExists(atPath: arg) { try guardFile(arg) }
            return ["-protocol_whitelist", "file,pipe", "-format_whitelist", allow] + arguments
        }
        var result: [String] = []
        var explicitFormat: String?
        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            if arg == "-f", index + 1 < arguments.count { explicitFormat = arguments[index + 1] }
            if arg == "-i", index + 1 < arguments.count {
                let input = arguments[index + 1]
                if fm.fileExists(atPath: input) {
                    if explicitFormat == nil { try guardFile(input) }
                    let list = explicitFormat.map { "\($0),\(allow)" } ?? allow
                    result += ["-protocol_whitelist", "file,pipe", "-format_whitelist", list]
                }
                explicitFormat = nil
                result += [arg, input]
                index += 2
                continue
            }
            result.append(arg)
            index += 1
        }
        return result
    }

    /// Only for a friendly error; the demuxer allowlist is the actual protection.
    static func looksLikePlaylist(_ path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        var head = String(decoding: (try? handle.read(upToCount: 1024)) ?? Data(), as: UTF8.self)
        if head.hasPrefix("\u{FEFF}") { head.removeFirst() }
        head = head.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return head.hasPrefix("#extm3u") || head.hasPrefix("#ext-x-") || head.hasPrefix("ffconcat")
            || head.hasPrefix("<?xml") && head.contains("<mpd")
    }
}

final class LockedData: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
    var value: Data { lock.lock(); defer { lock.unlock() }; return data }
}
